using A30Kit;
using static T;

static class CodecTests
{
    public static void Run()
    {
        Check(Codec.ParseFeatureList(Fixtures.FeatureListArgs()).SequenceEqual(new ushort[]
              { 0x0000, 0x0001, 0x0104, 0x0100, 0x0101, 0x0601, 0x060B, 0x0200,
                0x0604, 0x0608, 0x0609, 0x060A, 0x0108, 0x010A, 0x0201, 0x0004 }), "feature list order");

        var b = Battery.Parse(Bytes("2a 28 00"));
        Check(b is { Percent: 42, User: 40, Charging: ChargingState.NotCharging, IsCharging: false }, "battery: real SOC, user SOC");
        Check(Battery.Parse(Bytes("2a 28 02"))?.IsCharging == true, "fast charging");
        Check(Battery.Parse([0x01]) == null, "short battery reply");

        Check(EqSetting.Parse(Bytes("04 00 00 00 00 00"))?.Same(new EqSetting(4, [0, 0, 0, 0, 0])) == true, "eq decode flat");
        var e = new EqSetting(4, [-12, -1, 0, 5, 12]);
        Check(Same(e.ToWire(), Bytes("04 88 f6 00 32 78")), "eq encode dB×10 signed");
        Check(EqSetting.Parse(e.ToWire())?.Same(e) == true, "eq roundtrip");
        Check(Same(new EqSetting(4, [20, -20, 0, 0, 0]).ToWire(), Bytes("04 78 88 00 00 00")), "eq clamps ±12 dB");
        Check((EqMode)0x80 == EqMode.Immersive && (EqMode)0x81 == EqMode.Footstep && EqMode.Pro.Label() == "Astro Pro", "eq modes");

        var mv = Codec.ParseMicValues(Bytes("02 00 28 01 28"));
        Check(mv.Count == 2 && mv[Mic.Internal] == 40 && mv[Mic.Boom] == 40, "sidetone list");

        Check(!DongleStatus.From(0x00).Connected, "dongle off");
        var d = DongleStatus.From(0x05);
        Check(d.Connected && !d.XboxMode && d.HostType, "dongle bits");

        Check(Codec.ParseName(Bytes("30 09 41 53 54 52 4f 20 41 33 30")) == "ASTRO A30", "name");
        Check(Codec.ParseLengthString(Bytes("03 32 32 34")) == "224", "serial");
        Check(Same(Codec.LengthPrefixed("224"), Bytes("03 32 32 34")), "serial re-encoded for factory reset");
        Check(Codec.ParseLengthString(Bytes("05 41")) == null, "truncated string rejected");
        Check(Codec.ParseFirmware(Bytes("01 00 00 3b 05 6c 6f 63 61 6c")) == "1.0.59", "firmware");

        Check((CenturionError)8 == CenturionError.NotConnected && (CenturionError)14 == CenturionError.NotAuthorized, "errors");
        Check(new A30Exception(A30ErrorKind.Device, CenturionError.NotConnected).Message.Contains("dongle"), "NOT_CONNECTED message mentions the dongle");
        Check((SleepTimer)0 == SleepTimer.Never && SleepTimer.Thirty.Label() == "30 minutes", "sleep timer");
        Check((Tones)2 == Tones.Minimal && (NoiseGate)3 == NoiseGate.Tournament, "tones / noise gate");
        Check(!Enum.IsDefined((FeatureId)0x010A), "iGenericDFU is never addressable");
    }
}
