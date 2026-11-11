using System.Text;
using A30Kit;
using static T;

static class Iap2Tests
{
    const byte A = LinkPacket.ACK;
    static readonly byte[] Carbonite = Encoding.ASCII.GetBytes(Iap2Session.ProtocolName);

    static byte[] Ident(bool withCarbonite) => withCarbonite
        ? [.. Wire.IapParam(0, [.. "A30"u8, 0]),
           .. Wire.IapParam(3, [.. "A30SERIAL001"u8, 0]),
           .. Wire.IapParam(10, [.. Wire.IapParam(0, [1]), .. Wire.IapParam(1, [.. Carbonite, 0]), .. Wire.IapParam(2, [1])])]
        : Wire.IapParam(0, [.. "X"u8]);

    /// Control-message payloads of every Send (plain ACKs have none).
    static IEnumerable<string> SentPayloads(IEnumerable<Iap2Event> ev) =>
        ev.OfType<Iap2Event.Send>().Where(s => s.Bytes.Length > 10).Select(s => Wire.Hex(s.Bytes[9..^1]));

    public static void Run()
    {
        var s = new Iap2Session { Random = () => 0 };

        Events(s.Receive(Wire.Iap2Detect), "detect is echoed", Send("ff 55 02 00 ee 10"));
        Events(s.Receive(Fixtures.Syn), "SYN+ACK",
               Send("ff 5a 00 1a c0 2b 18 00 8a 01 05 00 84 05 dc 01 f4 1e 03 01 00 01 03 02 01 77"));
        Events(s.Receive(new LinkPacket(A, 0x18, 0x2b, 0).Encode()), "link up → AA00",
               Send("ff 5a 00 10 40 2c 18 01 12 40 40 00 06 aa 00 d0"));
        Check(s.LinkUp, "linkUp");

        // AuthenticationCertificate (609-byte cert) → ACK + 32-byte challenge
        var cert = new LinkPacket(A, 0x19, 0x2c, 1, Wire.ControlMsg(0xAA01, Wire.IapParam(0, Enumerable.Repeat((byte)0x30, 609).ToArray())));
        var aa02 = new LinkPacket(A, 0x2d, 0x19, 1, Wire.ControlMsg(0xAA02, Wire.IapParam(0, new byte[32]))).Encode();
        Events(s.Receive(cert.Encode()), "ACK cert + AA02 challenge", Send("ff 5a 00 09 40 2c 19 00 19"), Send(Wire.Hex(aa02)));
        Check(Wire.Hex(aa02[..9]) == "ff 5a 00 34 40 2d 19 01 ec", "AA02 header matches log");

        // AuthenticationResponse → ACK, AA05, 1D00
        var resp = new LinkPacket(A, 0x1a, 0x2d, 1, Wire.ControlMsg(0xAA03, Wire.IapParam(0, Enumerable.Repeat((byte)1, 64).ToArray())));
        Events(s.Receive(resp.Encode()), "auth succeeded + start identification",
               Send("ff 5a 00 09 40 2d 1a 00 17"),
               Send("ff 5a 00 10 40 2e 1a 01 0e 40 40 00 06 aa 05 cb"),
               Send("ff 5a 00 10 40 2f 1a 01 0d 40 40 00 06 1d 00 5d"));

        // IdentificationInformation with the EA protocol group → ACK, 1D02, EA00, ready
        var idp = new LinkPacket(A, 0x1b, 0x2f, 1, Wire.ControlMsg(0x1D01, Ident(true)));
        Events(s.Receive(idp.Encode()), "identification accepted + EA session started",
               Send("ff 5a 00 09 40 2f 1b 00 14"),
               Send("ff 5a 00 10 40 30 1b 01 0b 40 40 00 06 1d 02 5b"),
               Send("ff 5a 00 1b 40 31 1b 01 ff 40 40 00 11 ea 00 00 05 00 00 01 00 06 00 01 00 01 77"),
               "ready");
        Check(s.EaOpen, "eaOpen");
        Check(s.Identity.GetValueOrDefault(0) == "A30" && s.Identity.GetValueOrDefault(3) == "A30SERIAL001", "identity strings");

        // First CPP request over EA, exactly as logged
        Check(Wire.Hex(s.EaPacket(Wire.SppWrap(Wire.CppRequest(0, 0, 1, [0, 0]))))
              == "ff 5a 00 16 40 32 1b 03 01 00 01 13 a0 05 00 00 01 00 00 e1 06 5f", "EA request packet");

        // EA reply → ACK + eaData (EA session id stripped); retransmission → ACK only
        var reply = new LinkPacket(A, 0x1c, 0x32, 3, [0x00, 0x01, .. Bytes("13 a0 06 00 00 01 00 00 02 00 00")]).Encode();
        Events(s.Receive(reply), "EA reply", Send("ff 5a 00 09 40 32 1c 00 10"), "ea 13 a0 06 00 00 01 00 00 02 00 00");
        Events(s.Receive(reply), "duplicate only re-ACKed", Send("ff 5a 00 09 40 32 1c 00 10"));

        // Accessory reset
        Events(s.Receive(new LinkPacket(LinkPacket.RST, 0, 0, 0).Encode()), "RST", "reset");
        Check(!s.LinkUp && !s.EaOpen, "state cleared on RST");

        // A stale protocol id from before the RST must not make a non-carbonite identification ready
        var afterRst = s.Receive(new LinkPacket(A, 0x1d, 0x33, 1, Wire.ControlMsg(0x1D01, Ident(false))).Encode());
        Check(!afterRst.Any(e => e is Iap2Event.Ready) && !s.EaOpen, "RST clears the protocol id: no ready without carbonite");
        Check(SentPayloads(afterRst).Contains("40 40 00 06 1d 02"), "1D02 sent after RST re-identification");

        // Identification without our protocol → accepted, but never ready
        var t = new Iap2Session { Random = () => 0 };
        t.Receive(Fixtures.Syn);
        t.Receive(new LinkPacket(A, 0x18, 0x2b, 0).Encode());
        var ev = t.Receive(new LinkPacket(A, 0x19, 0x2c, 1, Wire.ControlMsg(0x1D01, Ident(false))).Encode());
        Check(!ev.Any(e => e is Iap2Event.Ready) && !t.EaOpen, "no ready without carbonite protocol");
        Check(SentPayloads(ev).Contains("40 40 00 06 1d 02"), "1D02 still sent without carbonite protocol");

        Resync();
    }

    /// A mid-session SYN restarts the link: SYN+ACK, a fresh AA00 after link-up, and EA stays closed
    /// until a new identification.
    static void Resync()
    {
        var s = new Iap2Session { Random = () => 0 };
        s.Receive(Fixtures.Syn);
        s.Receive(new LinkPacket(A, 0x18, 0x2b, 0).Encode());
        s.Receive(new LinkPacket(A, 0x19, 0x2c, 1, Wire.ControlMsg(0x1D01, Ident(true))).Encode());
        Check(s.EaOpen, "first session reaches eaOpen");

        var again = s.Receive(Fixtures.Syn);
        if (again.FirstOrDefault() is not Iap2Event.Send sa || Wire.Hex(sa.Bytes[..5]) != "ff 5a 00 1a c0")
        {
            Check(false, "SYN+ACK sent on re-sync");
            return;
        }
        Check(!s.LinkUp && !s.EaOpen, "SYN clears link and EA state");

        var linkUp = s.Receive(new LinkPacket(A, 0x18, sa.Bytes[5], 0).Encode());
        Check(SentPayloads(linkUp).Any(p => p.StartsWith("40 40 00 06 aa 00")), "re-sync re-sends AA00");
        Check(!s.EaOpen, "eaOpen false until re-identification");

        var plain = s.Receive(new LinkPacket(A, 0x1a, 0x33, 1, Wire.ControlMsg(0x1D01, Ident(false))).Encode());
        Check(!plain.Any(e => e is Iap2Event.Ready), "re-sync clears the protocol id");

        var reid = s.Receive(new LinkPacket(A, 0x1b, 0x34, 1, Wire.ControlMsg(0x1D01, Ident(true))).Encode());
        Check(reid.Any(e => e is Iap2Event.Ready) && s.EaOpen, "re-identification reopens EA");
    }
}
