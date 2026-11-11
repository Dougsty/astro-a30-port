using A30Kit;

static class Fixtures
{
    /// Fragmented reply to FeatureSet.GET_FEATURE_ID[0], three SPP frames, CRC 00 00 (captured on Doug's A30).
    public static readonly byte[][] FeatureListFrames =
    [
        T.Bytes("13 a0 20 01 01 12 10 00 00 00 02 00 01 00 01 01 04 00 03 01 00 00 04 01 01 00 02 06 01 00 01 06 0b 00 01 00 00"),
        T.Bytes("13 a0 20 03 02 00 00 03 06 04 00 01 06 08 00 01 06 09 00 01 06 0a 00 01 01 08 00 03 01 0a 00 04 02 01 00 00 00"),
        T.Bytes("13 a0 06 04 03 00 04 00 03 00 00"),
    ];

    public static readonly byte[] Syn =
        T.Bytes("ff 5a 00 1a 80 18 00 00 f5 01 05 00 84 05 dc 01 f4 1e 03 01 00 01 03 02 01 77");

    /// The reassembled feature-list args (count + 16 × 4-byte entries).
    public static byte[] FeatureListArgs()
    {
        var spp = new SppParser();
        var cpl = new CplReassembler();
        byte[] args = [];
        foreach (var f in FeatureListFrames)
            foreach (var p in spp.Feed(f))
                if (cpl.Feed(p) is byte[] m && CppReply.Parse(m) is { IsError: false } r) args = r.Args;
        return args;
    }
}
