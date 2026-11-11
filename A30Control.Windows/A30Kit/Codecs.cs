// Typed values for the A30's CPP features and their byte encodings (read from the decompiled
// Logitech G app; see CLAUDE.md "Feature map" and "Writes").
using System.Text;

namespace A30Kit;

public enum FeatureId : ushort
{
    Root = 0x0000, FeatureSet = 0x0001, Profile = 0x0004,
    DeviceInfo = 0x0100, DeviceName = 0x0101, Battery = 0x0104, AutoSleep = 0x0108,
    Volume = 0x0200, Eq = 0x0201,
    MicMute = 0x0601,   // no GET for the mute state; the headset pushes it (swID 0)
    Sidetone = 0x0604, NoiseGate = 0x0608, Mix = 0x0609, Dongle = 0x060A, Tones = 0x060B,
    // iGenericDFU (0x010A) is intentionally absent: firmware updates are out of scope.
}

public enum CenturionError : byte
{
    InvalidFeature = 1, InvalidFunction, InvalidSize, InvalidSwId, InvalidParam, Timeout,
    LowResource, NotConnected, Busy, NotAvailable, Failed, Malformed, NotAuthorized = 14,
}

public enum A30ErrorKind { NotFound, NotConnectedToHost, OpenFailed, Timeout, Disconnected, Unsupported, BadReply, Device }

public sealed class A30Exception(A30ErrorKind kind, CenturionError? device = null, string? detail = null)
    : Exception(Describe(kind, device, detail))
{
    public A30ErrorKind Kind { get; } = kind;
    public CenturionError? DeviceError { get; } = device;

    static string Describe(A30ErrorKind k, CenturionError? d, string? detail) => k switch
    {
        A30ErrorKind.NotFound => "ASTRO A30 is not paired with this PC",
        A30ErrorKind.NotConnectedToHost => "ASTRO A30 is not connected to this PC (connect it in Bluetooth settings)",
        A30ErrorKind.OpenFailed => $"Could not open the control channel ({detail})",
        A30ErrorKind.Timeout => "The headset did not answer",
        A30ErrorKind.Disconnected => "Headset disconnected",
        A30ErrorKind.Unsupported => "Not available on this headset",
        A30ErrorKind.BadReply => "Unexpected reply from the headset",
        _ => d switch
        {
            CenturionError.NotConnected => "Not connected (game/chat balance needs the 2.4 GHz dongle)",
            CenturionError.InvalidFunction => "Not supported by this firmware",
            CenturionError.InvalidParam => "Value out of range",
            CenturionError.Busy => "Headset busy, try again",
            _ => $"Headset error {(int?)d} ({d})",
        },
    };
}

public enum ChargingState : byte { NotCharging, Slow, Fast, Full, Error }

/// GET_BATTERY_STATUS: [realSOC, userSOC, chargingState]. The official app shows userSOC, which moves
/// in 10 % steps and looks frozen while charging; realSOC moves 1 % at a time, so Percent is realSOC.
public sealed record Battery(int Percent, int User, ChargingState? Charging)
{
    public static Battery? Parse(byte[] a) => a.Length < 3 ? null
        : new(a[0], a[1], Enum.IsDefined((ChargingState)a[2]) ? (ChargingState)a[2] : null);

    public bool IsCharging => Charging is ChargingState.Slow or ChargingState.Fast or ChargingState.Full;
}

/// Studio/Gaming/Pro are named in the official app but not offered for the A30; its firmware accepts them.
public enum EqMode : byte { Custom = 0x04, Immersive = 0x80, Footstep = 0x81, Studio = 0x82, Gaming = 0x83, Pro = 0x84 }

/// HeadsetEQSet GET/SET_USER_EQ: [mode, band0..band4], band byte = dB × 10 (signed).
public sealed record EqSetting(byte Mode, int[] Bands)
{
    public static readonly string[] BandLabels = ["31 Hz", "63 Hz", "125 Hz", "250 Hz", "500 Hz"];
    public const int MinGain = -12, MaxGain = 12;

    public static EqSetting? Parse(byte[] a) => a.Length < 6 ? null
        : new(a[0], a[1..6].Select(b => (int)Math.Round((sbyte)b / 10.0, MidpointRounding.AwayFromZero)).ToArray());

    public byte[] ToWire() => [Mode, .. Bands.Select(db => unchecked((byte)(sbyte)(Math.Clamp(db, MinGain, MaxGain) * 10)))];

    /// Value equality (records compare arrays by reference).
    public bool Same(EqSetting? o) => o != null && Mode == o.Mode && Bands.SequenceEqual(o.Bands);
}

public enum Mic : byte { Internal = 0, Boom = 1 }
public enum NoiseGate : byte { Off, Night, Home, Tournament }
public enum Tones : byte { None, All, Minimal }
public enum SleepTimer : byte { Never = 0, Fifteen = 15, Thirty = 30, Sixty = 60 }

/// iHeadsetDongle GET_CONFIG: bit0 connected, bit1 Xbox mode, bit2 host type.
public readonly record struct DongleStatus(bool Connected, bool XboxMode, bool HostType)
{
    public static DongleStatus From(byte b) => new((b & 1) != 0, (b & 2) != 0, (b & 4) != 0);
}

public static class Labels
{
    public static string Label(this EqMode m) => m switch
    {
        EqMode.Custom => "Custom",
        EqMode.Immersive => "Immersive",
        EqMode.Footstep => "Footstep",
        EqMode.Studio => "Astro Studio",
        EqMode.Gaming => "Astro Gaming",
        EqMode.Pro => "Astro Pro",
        _ => m.ToString(),
    };
    public static string Label(this Mic m) => m == Mic.Boom ? "Boom mic" : "Internal mic";
    public static string Label(this NoiseGate g) => g.ToString();
    public static string Label(this Tones t) => t.ToString();
    public static string Label(this SleepTimer t) => t == SleepTimer.Never ? "Never" : $"{(int)t} minutes";
}

public static class Codec
{
    /// iFeatureSet GET_FEATURE_ID(0) on the A30: count, then count × (id(2) type ver). Position = feature index.
    public static List<ushort> ParseFeatureList(byte[] a)
    {
        var o = new List<ushort>();
        for (int i = 1; i + 4 <= a.Length; i += 4) o.Add((ushort)(a[i] << 8 | a[i + 1]));
        return o;
    }

    /// Sidetone / noise gate GET: [count, (mic, value)*].
    public static Dictionary<Mic, int> ParseMicValues(byte[] a)
    {
        var o = new Dictionary<Mic, int>();
        for (int i = 1; i + 2 <= a.Length; i += 2)
            if (Enum.IsDefined((Mic)a[i])) o[(Mic)a[i]] = a[i + 1];
        return o;
    }

    /// [len][utf8] starting at `start` (CPPDataUnpacker.getString()).
    public static string? ParseLengthString(byte[] a, int start = 0)
    {
        if (a.Length <= start) return null;
        int n = a[start];
        return a.Length < start + 1 + n ? null : Encoding.UTF8.GetString(a, start + 1, n);
    }

    /// iDeviceName GET_NAME: [maxLength, len, utf8].
    public static string? ParseName(byte[] a) => ParseLengthString(a, 1);

    /// GET_FIRMWARE_VERSION, e.g. 01 00 00 3b 05 "local" → "1.0.59" (same reading as the Mac app).
    public static string? ParseFirmware(byte[] a) => a.Length < 4 ? null : $"{a[0]}.{a[1]}.{a[2] << 8 | a[3]}";

    public static byte[] LengthPrefixed(string s)
    {
        var b = Encoding.UTF8.GetBytes(s);
        return [(byte)b.Length, .. b];
    }
}
