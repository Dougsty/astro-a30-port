using System.Text;
using A30Kit;
using static T;

static class FramingTests
{
    public static void Run()
    {
        Check(Wire.Crc16(Encoding.ASCII.GetBytes("123456789")) == 0x6F91, "crc check value");

        // CLAUDE.md worked example: GET_FEATURE(iEQSet) swId 1
        Check(Same(Wire.SppWrap(Wire.CppRequest(0, 0, 1, [0x02, 0x01])), Bytes("13 a0 05 00 00 01 02 01 d8 24")),
              "sppWrap worked example");

        // SPP parser across chunk boundaries, CRC 00 00 accepted
        var spp = new SppParser();
        Check(spp.Feed(Bytes("13 a0 06 00")).Count == 0, "partial frame yields nothing");
        var done = spp.Feed(Bytes("00 01 00 00 02 00 00"));
        Check(done.Count == 1 && Same(done[0], Bytes("00 00 01 00 00 02")), "frame completes");
        Check(spp.Feed(Bytes("13 a0 01 00 12 34")).Count == 0, "bad crc dropped");
        var good = spp.Feed(Wire.SppWrap([0x00, 0x07]));
        Check(good.Count == 1 && Same(good[0], [0x00, 0x07]), "good crc accepted");

        // CPL reassembly of the fragmented feature list
        var spp2 = new SppParser();
        var cpl = new CplReassembler();
        var messages = new List<byte[]>();
        foreach (var f in Fixtures.FeatureListFrames)
            foreach (var p in spp2.Feed(f))
                if (cpl.Feed(p) is byte[] m) messages.Add(m);
        Check(messages.Count == 1, "one reassembled message");
        Check(messages.FirstOrDefault()?.Length == 67, "reassembled length 2 + 65");
        if (messages.Count == 1 && CppReply.Parse(messages[0]) is { IsError: false } r)
        {
            Check(r.Index == 1 && r.Function == 1 && r.SwId == 2, "reply header");
            Check(r.Args.FirstOrDefault() == 0x10, "feature count 16");
        }
        else Check(false, "feature list parses as ok reply");

        // Error reply: FF featIdx fn|sw code
        var cpl2 = new CplReassembler();
        Check(CppReply.Parse(cpl2.Feed(Bytes("00 ff 00 06 05"))!)?.ToString() == "error idx=0 fn=0 sw=6 code=5", "error reply");

        // CPL continuity
        var cplGap = new CplReassembler();
        Check(cplGap.Feed(Bytes("04 01 02 03")) == null, "orphan fragment seq 2 dropped");
        var cplAbort = new CplReassembler();
        Check(cplAbort.Feed(Bytes("01 aa bb")) == null, "partial fragment buffered");
        Check(Same(cplAbort.Feed(Bytes("00 11 22")), [0x11, 0x22]), "single fragment after abort returns only its bytes");
        var cplMid = new CplReassembler();
        Check(cplMid.Feed(Bytes("01 aa")) == null, "seq 0 buffered");
        Check(cplMid.Feed(Bytes("05 bb")) == null, "seq 2 after seq 0 dropped");
        Check(Same(cplMid.Feed(Bytes("00 33")), [0x33]), "fresh message after gap");

        // iAP2 link packet: re-encoding the headset's own SYN reproduces it exactly
        var syn = new LinkPacket(LinkPacket.SYN, 0x18, 0, 0, Fixtures.Syn[9..25]);
        Check(Same(syn.Encode(), Fixtures.Syn), "SYN encode matches fixture");

        // Splitter: detect + SYN split mid-packet, then a corrupted packet is dropped
        var sp = new Iap2Splitter();
        byte[] stream = [.. Wire.Iap2Detect, .. Fixtures.Syn];
        Events(sp.Feed(stream[..10]), "detect first", "detect");
        Events(sp.Feed(stream[10..]), "SYN after second chunk", syn.ToString());
        var bad = Fixtures.Syn.ToArray();
        bad[12] ^= 0xFF;
        Check(sp.Feed(bad).Count == 0, "bad payload checksum dropped");
        Check(sp.Feed(Wire.Iap2Detect[..3]).Count == 0, "partial detect waits");
        Events(sp.Feed(Wire.Iap2Detect[3..]), "detect completes", "detect");

        // A bogus FF 5A header must not stall the valid SYN behind it
        var resync = new Iap2Splitter();
        var rOut = resync.Feed([.. Bytes("ff 5a ff ff 00 00 00 00 00"), .. Fixtures.Syn]);
        Check(rOut.LastOrDefault()?.ToString() == syn.ToString(), "valid SYN found after bogus header");
        Check(rOut.Count > 1 && rOut.SkipLast(1).All(f => f is Iap2Frame.Junk), "bogus header bytes reported as junk");

        // Control messages and params
        Check(Same(Wire.ControlMsg(0xAA00), Bytes("40 40 00 06 aa 00")), "control message");
        byte[] ps = [.. Wire.IapParam(0, [1]), .. Wire.IapParam(1, Encoding.ASCII.GetBytes("x.y"))];
        Check(Wire.ParseParams(ps)?.Select(p => p.Id).SequenceEqual([0, 1]) == true, "params roundtrip");
        Check(Wire.ParseParams([0x00, 0x09, 0x00]) == null, "malformed params rejected");
        var cp = new ControlParser();
        var msg = Wire.ControlMsg(0x1D02, Wire.IapParam(3, [7]));
        Check(cp.Feed(msg[..4]).Count == 0, "partial control message");
        var cm = cp.Feed(msg[4..]);
        Check(cm.Count == 1 && cm[0].Id == 0x1D02 && Same(cm[0].Params.FirstOrDefault()?.Data, [7]), "control message completes");
        Check(Wire.IapText([.. "A30"u8, 0]) == "A30", "text with NUL");
        Check(Wire.IapText([0x01, 0x02]) == null, "binary is not text");
    }
}
