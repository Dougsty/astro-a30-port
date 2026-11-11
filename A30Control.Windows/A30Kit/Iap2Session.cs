// Apple-device side of iAP2 toward the A30: detect, link sync, authentication (the accessory
// certificate is accepted without verification: we are not Apple), identification, then one
// External Accessory session that carries CPP traffic. Pure state machine: bytes in, events out.
namespace A30Kit;

public abstract record Iap2Event
{
    /// Write these bytes to the transport.
    public sealed record Send(byte[] Bytes) : Iap2Event { public override string ToString() => "send " + Wire.Hex(Bytes); }
    /// EA session started; CPP traffic may flow.
    public sealed record Ready : Iap2Event { public override string ToString() => "ready"; }
    /// Bytes the accessory sent on the EA session (EA session id stripped).
    public sealed record EaData(byte[] Bytes) : Iap2Event { public override string ToString() => "ea " + Wire.Hex(Bytes); }
    /// The accessory reset the link.
    public sealed record Reset : Iap2Event { public override string ToString() => "reset"; }
    public sealed record Log(string Text) : Iap2Event { public override string ToString() => "log " + Text; }
}

public sealed class Iap2Session
{
    public const string ProtocolName = "com.logitech.ag.carbonite";
    const int EaSessionId = 1;

    public bool LinkUp { get; private set; }
    public bool EaOpen { get; private set; }
    /// Top-level string params of IdentificationInformation (0 name, 2 maker, 3 serial, 4 fw…).
    public Dictionary<int, string> Identity { get; private set; } = new();
    /// Challenge byte source; tests replace it for deterministic output.
    public Func<byte> Random { get; set; } = () => (byte)System.Random.Shared.Next(256);

    readonly Iap2Splitter splitter = new();
    ControlParser control = new();
    byte txSeq = 0x2B, rxSeq;
    byte? lastRx;
    byte ctrlSession = 1, eaSession = 3;
    byte? eaProtocolId;

    public List<Iap2Event> Receive(byte[] bytes)
    {
        var o = new List<Iap2Event>();
        foreach (var f in splitter.Feed(bytes))
        {
            if (f is Iap2Frame.Detect && !LinkUp) o.Add(new Iap2Event.Send(Wire.Iap2Detect));
            else if (f is Iap2Frame.Packet p) o.AddRange(Link(p.P));
        }
        return o;
    }

    /// Link packet carrying `data` on the EA session, prefixed with our EA session id.
    public byte[] EaPacket(byte[] data)
    {
        txSeq++;
        return new LinkPacket(LinkPacket.ACK, txSeq, rxSeq, eaSession, [.. Wire.Be16(EaSessionId), .. data]).Encode();
    }

    List<Iap2Event> Link(LinkPacket p)
    {
        if ((p.Control & LinkPacket.RST) != 0)
        {
            ResetHandshake();
            return [new Iap2Event.Reset()];
        }
        if ((p.Control & LinkPacket.SYN) != 0)
        {
            // A SYN always starts a fresh link: forget everything from any earlier one.
            ResetHandshake();
            // payload: ver maxOut maxLen(2) rtx(2) cumAck(2) maxRtx maxCum, then (id type ver)*
            for (int i = 10; i + 3 <= p.Payload.Length; i += 3)
            {
                if (p.Payload[i + 1] == 0) ctrlSession = p.Payload[i];
                if (p.Payload[i + 1] == 2) eaSession = p.Payload[i];
            }
            rxSeq = p.Seq;
            lastRx = p.Seq;
            return [new Iap2Event.Send(new LinkPacket(LinkPacket.SYN | LinkPacket.ACK, txSeq, rxSeq, 0, p.Payload).Encode())];
        }
        var o = new List<Iap2Event>();
        if (!LinkUp && (p.Control & LinkPacket.ACK) != 0 && p.Ack == txSeq)
        {
            LinkUp = true;
            o.Add(SendControl(0xAA00));   // RequestAuthenticationCertificate
        }
        if (p.Payload.Length == 0) return o;
        if (p.Seq == lastRx)   // retransmission: re-ACK with the current rxSeq only
        {
            o.Add(new Iap2Event.Send(new LinkPacket(LinkPacket.ACK, txSeq, rxSeq, 0).Encode()));
            return o;
        }
        rxSeq = p.Seq;
        lastRx = p.Seq;
        o.Add(new Iap2Event.Send(new LinkPacket(LinkPacket.ACK, txSeq, rxSeq, 0).Encode()));
        if (p.Session == ctrlSession)
            foreach (var m in control.Feed(p.Payload)) o.AddRange(Handle(m));
        else if (p.Session == eaSession && p.Payload.Length >= 2)
            o.Add(new Iap2Event.EaData(p.Payload[2..]));
        else
            o.Add(new Iap2Event.Log($"data on unknown session {p.Session}: {Wire.Hex(p.Payload)}"));
        return o;
    }

    /// Forgets handshake and session state. Keeps txSeq (it keeps counting), Random and the splitter.
    void ResetHandshake()
    {
        LinkUp = false;
        EaOpen = false;
        eaProtocolId = null;
        Identity = new();
        control = new();
        lastRx = null;
        ctrlSession = 1;
        eaSession = 3;
    }

    Iap2Event SendControl(int id, byte[]? prm = null)
    {
        txSeq++;
        return new Iap2Event.Send(new LinkPacket(LinkPacket.ACK, txSeq, rxSeq, ctrlSession, Wire.ControlMsg(id, prm)).Encode());
    }

    List<Iap2Event> Handle(ControlMessage m)
    {
        switch (m.Id)
        {
            case 0xAA01:   // AuthenticationCertificate: auth 2.0 certs are ~900 B (20-byte challenge), 3.0 ~600 B
            {
                int certLen = m.Params.Count > 0 ? m.Params[0].Data.Length : 0;
                var challenge = Enumerable.Range(0, certLen > 800 ? 20 : 32).Select(_ => Random()).ToArray();
                return [SendControl(0xAA02, Wire.IapParam(0, challenge))];
            }
            case 0xAA03:   // AuthenticationResponse (not verified) → AuthenticationSucceeded, StartIdentification
                return [SendControl(0xAA05), SendControl(0x1D00)];
            case 0x1D01:   // IdentificationInformation
                foreach (var p in m.Params)
                {
                    if (Wire.IapText(p.Data) is string s) { Identity[p.Id] = s; continue; }
                    var sub = Wire.ParseParams(p.Data);
                    var idp = sub?.FirstOrDefault(x => x.Id == 0);
                    var namep = sub?.FirstOrDefault(x => x.Id == 1);
                    if (idp == null || idp.Data.Length != 1 || namep == null || Wire.IapText(namep.Data) != ProtocolName) continue;
                    eaProtocolId = idp.Data[0];
                }
                if (eaProtocolId is not byte proto)
                    return [SendControl(0x1D02), new Iap2Event.Log($"accessory does not offer {ProtocolName}")];
                EaOpen = true;
                return [SendControl(0x1D02),   // IdentificationAccepted
                        SendControl(0xEA00, [.. Wire.IapParam(0, [proto]), .. Wire.IapParam(1, Wire.Be16(EaSessionId))]),
                        new Iap2Event.Ready()];
            default:
                return [new Iap2Event.Log($"control message 0x{m.Id:X4} ignored")];
        }
    }
}
