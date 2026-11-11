// Typed API for the A30. Feature indexes come from the headset's own feature list at connect,
// never from constants, so a firmware that reorders features still works.
namespace A30Kit;

public sealed class A30Client
{
    // Replaced as a whole at connect (never mutated in place): the reader thread looks them up while
    // the UI thread connects.
    Dictionary<ushort, byte> index = new();
    Dictionary<byte, FeatureId> byIndex = new();

    public A30Client(HeadsetLink? link = null)
    {
        Link = link ?? new HeadsetLink();
        Link.Notification += (i, fn, a) =>
        {
            if (byIndex.TryGetValue(i, out var f)) Notification?.Invoke(f, fn, a);
        };
        Link.Closed += () => Closed?.Invoke();
    }

    public HeadsetLink Link { get; }
    public Action<string> Log { get => Link.Log; set => Link.Log = value; }
    /// Device-pushed report decoded to its feature: (feature, function, args).
    public event Action<FeatureId, byte, byte[]>? Notification;
    public event Action? Closed;

    public async Task ConnectAsync(ITransport t)
    {
        index = new();
        byIndex = new();
        await Link.OpenAsync(t);
        byte[] list;
        try { list = await Link.RequestAsync(1, 1, [0]); }   // iFeatureSet (always idx 1) GET_FEATURE_ID(0)
        catch { Link.Close(); throw; }
        var ids = Codec.ParseFeatureList(list);
        var built = new Dictionary<ushort, byte>();
        var reverse = new Dictionary<byte, FeatureId>();
        for (int i = 0; i < ids.Count; i++)
        {
            built[ids[i]] = (byte)i;
            if (Enum.IsDefined((FeatureId)ids[i])) reverse[(byte)i] = (FeatureId)ids[i];
        }
        index = built;
        byIndex = reverse;
    }

    public void Disconnect() => Link.Close();

    public bool Supports(FeatureId f) => index.ContainsKey((ushort)f);

    Task<byte[]> Call(FeatureId f, byte fn, params byte[] args) =>
        index.TryGetValue((ushort)f, out var i) ? Link.RequestAsync(i, fn, args)
                                                 : Task.FromException<byte[]>(new A30Exception(A30ErrorKind.Unsupported));

    static A30Exception Bad() => new(A30ErrorKind.BadReply);

    // ---- reads

    public async Task<Battery> BatteryAsync() => Battery.Parse(await Call(FeatureId.Battery, 0)) ?? throw Bad();
    public async Task<string> NameAsync() => Codec.ParseName(await Call(FeatureId.DeviceName, 0)) ?? throw Bad();
    public async Task<string> FirmwareAsync() => Codec.ParseFirmware(await Call(FeatureId.DeviceInfo, 1)) ?? throw Bad();
    public async Task<string> SerialAsync() => Codec.ParseLengthString(await Call(FeatureId.DeviceInfo, 2)) ?? throw Bad();

    /// iVolumeSet GET: [level 0–31, muted].
    public async Task<(int Level, bool? Muted)> VolumeAsync()
    {
        var a = await Call(FeatureId.Volume, 0);
        if (a.Length == 0) throw Bad();
        return (a[0], a.Length > 1 ? a[1] != 0 : (bool?)null);
    }

    public async Task<EqSetting> EqAsync() => EqSetting.Parse(await Call(FeatureId.Eq, 0)) ?? throw Bad();
    public async Task<byte[]> EqModesAsync() => (await Call(FeatureId.Eq, 2)).Skip(1).ToArray();
    public async Task<Dictionary<Mic, int>> SidetoneAsync() => Codec.ParseMicValues(await Call(FeatureId.Sidetone, 0));

    public async Task<Dictionary<Mic, NoiseGate>> NoiseGateAsync() =>
        Codec.ParseMicValues(await Call(FeatureId.NoiseGate, 0))
             .Where(kv => Enum.IsDefined((NoiseGate)kv.Value))
             .ToDictionary(kv => kv.Key, kv => (NoiseGate)kv.Value);

    public async Task<int> BalanceAsync() { var a = await Call(FeatureId.Mix, 0); return a.Length > 0 ? a[0] : throw Bad(); }
    public async Task<DongleStatus> DongleAsync() { var a = await Call(FeatureId.Dongle, 0); return DongleStatus.From(a.Length > 0 ? a[0] : (byte)0); }

    public async Task<SleepTimer> SleepAsync()
    {
        var a = await Call(FeatureId.AutoSleep, 0);
        return a.Length > 0 && Enum.IsDefined((SleepTimer)a[0]) ? (SleepTimer)a[0] : throw Bad();
    }

    public async Task<Tones> TonesAsync()
    {
        var a = await Call(FeatureId.Tones, 0);
        return a.Length > 0 && Enum.IsDefined((Tones)a[0]) ? (Tones)a[0] : throw Bad();
    }

    // ---- writes

    /// `switching`: the mode differs from the current one. Like the official app, a switch to any mode
    /// other than Immersive/Footstep first passes through Immersive.
    public async Task SetEqAsync(EqSetting s, bool switching)
    {
        bool direct = s.Mode is (byte)EqMode.Immersive or (byte)EqMode.Footstep;
        if (switching && !direct)
        {
            await Call(FeatureId.Eq, 1, new EqSetting((byte)EqMode.Immersive, new int[5]).ToWire());
            await Task.Delay(100);
        }
        await Call(FeatureId.Eq, 1, s.ToWire());
    }

    public Task SetSidetoneAsync(Mic mic, int percent) => Call(FeatureId.Sidetone, 1, (byte)mic, (byte)Math.Clamp(percent, 0, 100));
    public Task SetNoiseGateAsync(Mic mic, NoiseGate g) => Call(FeatureId.NoiseGate, 1, (byte)mic, (byte)g);
    /// iVolumeSet SET_MUTE_STATUS (fn 2): mutes the headset's audio output.
    public Task SetAudioMutedAsync(bool muted) => Call(FeatureId.Volume, 2, (byte)(muted ? 1 : 0));

    /// iDeviceName SET_NAME (fn 1): [len][utf8], max 48 bytes — the name shown in Bluetooth.
    public Task SetNameAsync(string name)
    {
        while (System.Text.Encoding.UTF8.GetByteCount(name) > 48) name = name[..^1];
        return Call(FeatureId.DeviceName, 1, Codec.LengthPrefixed(name));
    }

    /// iHeadsetDongle SET_CONFIG (fn 1): the official "Base station mode" for the A30 is the host type,
    /// 0 = PC, 1 = Xbox, read back as GET_CONFIG bit 2. The dongle drops and re-links for a few seconds.
    public Task SetBaseStationXboxAsync(bool xbox) => Call(FeatureId.Dongle, 1, (byte)(xbox ? 1 : 0));

    /// iVolumeSet SET_VOLUME_LEVEL: 0–31, same scale as the wheel.
    public Task SetVolumeAsync(int v) => Call(FeatureId.Volume, 1, (byte)Math.Clamp(v, 0, 31));
    /// iHeadsetMix SET_BALANCE: 0–20 (game share in 5 % steps); needs the 2.4 GHz dongle (else err 8).
    public Task SetBalanceAsync(int v) => Call(FeatureId.Mix, 1, (byte)Math.Clamp(v, 0, 20));
    /// Raw auto-sleep minutes (the official presets are 0/15/30/60; the firmware accepts 1…255).
    public Task SetSleepMinutesAsync(byte m) => Call(FeatureId.AutoSleep, 1, m, m);
    public Task SetSleepAsync(SleepTimer t) => Call(FeatureId.AutoSleep, 1, (byte)t, (byte)t);
    public Task SetTonesAsync(Tones t) => Call(FeatureId.Tones, 1, (byte)t);

    /// Erases all headset settings (iDeviceInfo FACTORY_RESET with the serial). Reached only through
    /// the warning + typed RESET confirmation in Settings.
    public Task FactoryResetAsync(string serial) => Call(FeatureId.DeviceInfo, 4, Codec.LengthPrefixed(serial));
}
