using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using A30Kit;

namespace A30Control;

public enum Pane { Equalizer, Microphone, Mix, Extras, Settings }

public sealed class AppRuleRow(HeadsetModel model, AppRule rule)
{
    static readonly EqMode[] Modes = Enum.GetValues<EqMode>();
    public string Name => rule.Name;
    public string[] ModeLabels => HeadsetModel.EqModeLabels;
    public int ModeIndex { get => Array.IndexOf(Modes, (EqMode)rule.Mode); set { if (value >= 0) model.SetRuleMode(rule, Modes[value]); } }
    public ICommand RemoveCmd => new Relay(() => model.RemoveRule(rule));
}

/// Single source of truth for the tray panel and the window. Every change raises PropertyChanged("")
/// so WPF re-reads all bindings: the model is small, so no per-property plumbing.
public sealed class HeadsetModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    void Changed() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    static void Ui(Action a) => Application.Current.Dispatcher.InvokeAsync(a);
    static Visibility Vis(bool b) => b ? Visibility.Visible : Visibility.Collapsed;

    /// Windows toast (title, body); set by App to the tray icon's balloon.
    public Action<string, string> Notify { get; set; } = (_, _) => { };
    /// Quits the app (set by App); used right before a silent update installs over it.
    public Action RequestQuit { get; set; } = () => { };

    readonly A30Client a30 = new();
    readonly Settings settings = Store.Load();

    bool connected;
    string status = "Looking for ASTRO A30…";
    Battery? battery;
    bool? micMuted;   // pushed by the headset; null until the first toggle (no GET exists)
    string name = "ASTRO A30", firmware = "—", serial = "—";
    int? volume;
    bool? audioMuted;
    EqSetting? eq;
    List<EqMode> eqModes = Enum.GetValues<EqMode>().ToList();
    Dictionary<Mic, int> sidetone = new();
    Dictionary<Mic, NoiseGate> noiseGate = new();
    int? balance;
    DongleStatus dongle;
    SleepTimer? sleep;
    Tones? tones;
    string? banner;
    Pane pane = Pane.Equalizer;
    Mic micTab = Mic.Boom;

    public HeadsetModel()
    {
        a30.Log = Log.Write;
        a30.Closed += () => Ui(Disconnected);
        a30.Notification += (f, fn, a) => Ui(() => Notified(f, fn, a));
    }

    // ================= bindings

    public bool IsConnected => connected;
    public string Status => status;
    public Visibility ConnectedVisibility => Vis(connected);
    public Visibility DisconnectedVisibility => Vis(!connected && PowerOffRemaining == null);
    public string Name => name;
    public string NameUpper => name.ToUpperInvariant();
    public string Firmware => firmware;
    public string Serial => serial;
    public string DeviceLine => $"HEADSET FW VERSION: {firmware} · SERIAL {serial}";
    public string BatteryText => connected && battery != null ? $"{battery.Percent}%" : "";
    public Visibility ChargingVisibility => Vis(connected && battery?.IsCharging == true);
    public string? Banner => banner;
    public Visibility BannerVisibility => Vis(banner != null);

    public string TrayTooltip => !connected
        ? "A30 Control · " + status
        : $"{name} · {battery?.Percent.ToString() ?? "?"}%{(battery?.IsCharging == true ? " ⚡" : "")}{(micMuted == true ? " · mic muted" : "")}";

    public (bool Charging, bool Low, bool MicMuted) Badges =>
        (connected && battery?.IsCharging == true, connected && battery is { IsCharging: false, Percent: <= 20 }, micMuted == true);

    public Pane Pane { get => pane; set { pane = value; Changed(); } }
    public IEnumerable<Choice> Tabs => Enum.GetValues<Pane>().Select(p => new Choice(p.ToString().ToUpperInvariant(), p == pane, () => Pane = p));
    public Visibility EqualizerVisibility => Vis(pane == Pane.Equalizer);
    public Visibility MicrophoneVisibility => Vis(pane == Pane.Microphone);
    public Visibility MixVisibility => Vis(pane == Pane.Mix);
    public Visibility ExtrasVisibility => Vis(pane == Pane.Extras);
    public Visibility SettingsVisibility => Vis(pane == Pane.Settings);

    // EQ
    public bool IsCustom => eq?.Mode == (byte)EqMode.Custom;
    public IEnumerable<Choice> EqChoices => eqModes.Select(m => new Choice(m.Label(), eq?.Mode == (byte)m, () => SelectEq(m)));
    public IEnumerable<Choice> EqPills => eqModes.Select(m => new Choice(m.Label().Replace("Astro ", ""), eq?.Mode == (byte)m, () => SelectEq(m)));
    public IEnumerable<Choice> SavedEqChoices => settings.SavedEqs.Select(s =>
        new Choice(s.Name, false, () => ApplySavedEq(s), () => { settings.SavedEqs.Remove(s); Save(); Changed(); }));
    public Visibility SavedEqVisibility => Vis(settings.SavedEqs.Count > 0);
    public Visibility EditHintVisibility => Vis(!IsCustom);
    public double Band0 { get => Band(0); set => SetBand(0, value); }
    public double Band1 { get => Band(1); set => SetBand(1, value); }
    public double Band2 { get => Band(2); set => SetBand(2, value); }
    public double Band3 { get => Band(3); set => SetBand(3, value); }
    public double Band4 { get => Band(4); set => SetBand(4, value); }
    public string Band0Text => BandText(0);
    public string Band1Text => BandText(1);
    public string Band2Text => BandText(2);
    public string Band3Text => BandText(3);
    public string Band4Text => BandText(4);
    double Band(int i) => eq?.Bands.ElementAtOrDefault(i) ?? 0;
    string BandText(int i) { var v = (int)Band(i); return v > 0 ? $"+{v} dB" : $"{v} dB"; }

    // volume / mute
    public bool HasVolume => volume != null;
    public double VolumeValue { get => volume ?? 0; set => SetVolume((int)Math.Round(value)); }
    public string VolumeText => volume?.ToString() ?? "—";
    public string VolumeInfo => volume is int v ? $"{v} / 31" : "—";
    public bool HasAudioMute => audioMuted != null;
    public bool AudioMutedValue { get => audioMuted == true; set => SetAudioMuted(value); }

    // microphone
    public IEnumerable<Choice> MicChoices => Enum.GetValues<Mic>().Select(m => new Choice(m.Label(), m == micTab, () => { micTab = m; Changed(); }));
    public bool HasSidetone => sidetone.ContainsKey(micTab);
    public double SidetoneValue { get => sidetone.GetValueOrDefault(micTab); set => SetSidetone(micTab, (int)Math.Round(value)); }
    public string SidetoneText => sidetone.TryGetValue(micTab, out var v) ? $"{v}%" : "—";
    public bool HasBoomSidetone => sidetone.ContainsKey(Mic.Boom);
    public double BoomSidetoneValue { get => sidetone.GetValueOrDefault(Mic.Boom); set => SetSidetone(Mic.Boom, (int)Math.Round(value)); }
    public string BoomSidetoneText => sidetone.TryGetValue(Mic.Boom, out var v) ? $"{v}%" : "—";
    public bool HasNoiseGate => noiseGate.ContainsKey(micTab);
    public IEnumerable<Choice> NoiseGateChoices => Enum.GetValues<NoiseGate>().Select(g =>
        new Choice(g.Label(), noiseGate.TryGetValue(micTab, out var c) && c == g, () => SetNoiseGate(micTab, g)));

    // mix / dongle
    public bool DongleConnected => dongle.Connected;
    public string DongleText => dongle.Connected ? "Connected" : "Not connected";
    public Visibility NoDongleVisibility => Vis(!dongle.Connected);
    public bool CanBalance => dongle.Connected && balance != null;
    public double BalanceValue { get => balance ?? 10; set => SetBalance((int)Math.Round(value)); }
    public string BalanceText => dongle.Connected && balance is int b ? $"{b * 5}%" : "—";
    public string BalanceInfo => balance is int b ? $"{b * 5}% game" : "—";
    /// Base station mode = dongle host type (GET_CONFIG bit 2): 0 PC, 1 Xbox.
    public IEnumerable<Choice> BaseModeChoices =>
    [
        new Choice("PC", dongle.Connected && !dongle.HostType, () => SetBaseStationXbox(false)),
        new Choice("Xbox", dongle.Connected && dongle.HostType, () => SetBaseStationXbox(true)),
    ];

    // extras
    public IEnumerable<Choice> ProfileChoices => settings.Profiles.Select(p =>
        new Choice(p.Name, false, () => ApplyProfile(p), () => { settings.Profiles.Remove(p); Save(); Changed(); }));
    public Visibility NoProfilesVisibility => Vis(settings.Profiles.Count == 0);
    public static string[] EqModeLabels { get; } = Enum.GetValues<EqMode>().Select(m => m.Label()).ToArray();
    public IEnumerable<AppRuleRow> AppRules => settings.AppRules.Select(r => new AppRuleRow(this, r));
    public Visibility NoAppRulesVisibility => Vis(settings.AppRules.Count == 0);

    // settings
    public IEnumerable<Choice> SleepChoices => Enum.GetValues<SleepTimer>().Select(t => new Choice(t.Label(), sleep == t, () => SetSleep(t)));
    public IEnumerable<Choice> TonesChoices => Enum.GetValues<Tones>().Select(t => new Choice(t.Label(), tones == t, () => SetTones(t)));
    public bool LaunchAtLogin
    {
        get => Autostart.IsEnabled;
        set
        {
            try { Autostart.Set(value); } catch (Exception e) { Show("Start with Windows: " + e.Message); }
            Changed();
        }
    }

    // updates
    public Visibility UpdateVisibility => Vis(update != null);
    public string UpdateText => update == null ? "" : updating ? $"Downloading {update.Version.ToString(3)}…" : $"Version {update.Version.ToString(3)} is available";
    public string UpdateButtonText => Updater.IsInstalled && update?.Setup.Sha256 != null ? "Install" : "Download";
    public bool CanInstallUpdate => !updating;
    public string VersionText => $"A30 Control {Updater.Current.ToString(3)}";
    public bool CheckUpdates
    {
        get => settings.CheckUpdates;
        set { settings.CheckUpdates = value; Save(); Changed(); _ = CheckForUpdate(); }
    }
    public bool BetaUpdates
    {
        get => settings.BetaUpdates;
        set { settings.BetaUpdates = value; Save(); Changed(); _ = CheckForUpdate(); }
    }

    // turn off
    public int? PowerOffRemaining { get; private set; }
    public Visibility PowerOffVisibility => Vis(PowerOffRemaining != null);
    public Visibility TurnOffRowVisibility => Vis(PowerOffRemaining == null);
    public string PowerOffText => $"Turning off in {PowerOffRemaining}s";

    // ================= connection

    bool connecting;
    DateTime? suspendReconnectUntil;
    CancellationTokenSource? poll;

    public void Start()
    {
        Reconnect();
        _ = UpdateLoop();
    }

    public void Shutdown()
    {
        poll?.Cancel();
        a30.Disconnect();
    }

    /// At most one connect loop at a time; retries every 5 s.
    async void Reconnect()
    {
        if (connecting) return;
        connecting = true;
        try
        {
            while (true)
            {
                // After "Turn off", leave the headset alone so it can go idle and power down.
                if (suspendReconnectUntil is DateTime until)
                {
                    var wait = until - DateTime.Now;
                    if (wait > TimeSpan.Zero) await Task.Delay(wait);
                    suspendReconnectUntil = null;
                }
                connected = false;
                Changed();
                try
                {
                    var t = await Connector.OpenAsync(Log.Write);
                    await a30.ConnectAsync(t);
                    Log.Write($"connected ({a30.Link.Mode})");
                    connected = true;
                    status = a30.CanRead ? "Connected" : "Connected (2.4 GHz dongle)";
                    Changed();
                    await FinishTurnOffIfNeeded();
                    await RefreshAll();
                    if (!connected) continue;   // dropped during the refresh
                    StartPolling();
                    return;
                }
                catch (Exception e)
                {
                    status = e.Message;
                    Log.Write("connect failed: " + e.Message);
                    if (e is A30Exception { Kind: A30ErrorKind.Timeout })
                        Log.Write($"hint: no reply on the {a30.Link.Mode} path; if this keeps happening, send {Log.FilePath}");
                    Changed();
                    await Task.Delay(5000);
                }
            }
        }
        finally { connecting = false; }
    }

    void Disconnected()
    {
        poll?.Cancel();
        connected = false;
        status = "Headset disconnected";
        Changed();
        Reconnect();
    }

    /// Each read is independent, so one unsupported feature doesn't hide the rest.
    static async Task Try<T>(Func<Task<T>> read, Action<T> apply)
    {
        try { apply(await read()); }
        catch (Exception e) { Log.Write("read failed: " + e.Message); }
    }

    async Task RefreshAll()
    {
        if (!a30.CanRead)
        {
            // Over the dongle nothing can be read: show the last known state until the headset's own
            // notifications (a full burst whenever it links to the dongle) bring the real values.
            dongle = DongleStatus.From(0x01);
            if (settings.LastState is Profile p)
            {
                if (Enum.IsDefined((EqMode)p.EqMode)) eq = new EqSetting(p.EqMode, p.Bands.ToArray());
                sidetone = p.Sidetone.Where(kv => Enum.IsDefined((Mic)kv.Key)).ToDictionary(kv => (Mic)kv.Key, kv => kv.Value);
                noiseGate = p.NoiseGate.Where(kv => Enum.IsDefined((Mic)kv.Key) && Enum.IsDefined((NoiseGate)kv.Value))
                                       .ToDictionary(kv => (Mic)kv.Key, kv => (NoiseGate)kv.Value);
                balance = p.Balance;
            }
            Changed();
            return;
        }
        await Try(() => a30.BatteryAsync(), SetBattery);
        await Try(() => a30.NameAsync(), v => name = v);
        await Try(() => a30.FirmwareAsync(), v => firmware = v);
        await Try(() => a30.SerialAsync(), v => serial = v);
        volume = null; audioMuted = null;
        await Try(() => a30.VolumeAsync(), v => { volume = v.Level; audioMuted = v.Muted; });
        eq = null;
        await Try(() => a30.EqAsync(), StoreEq);
        await Try(() => a30.EqModesAsync(), m =>
        {
            // + the Astro Studio/Gaming/Pro modes the firmware accepts but doesn't list
            var listed = m.Where(b => Enum.IsDefined((EqMode)b)).Select(b => (EqMode)b).ToList();
            eqModes = [.. listed, .. new[] { EqMode.Studio, EqMode.Gaming, EqMode.Pro }.Where(x => !listed.Contains(x))];
        });
        sidetone = new(); await Try(() => a30.SidetoneAsync(), v => sidetone = v);
        noiseGate = new(); await Try(() => a30.NoiseGateAsync(), v => noiseGate = v);
        balance = null; await Try(() => a30.BalanceAsync(), v => balance = v);
        await Try(() => a30.DongleAsync(), v => dongle = v);
        sleep = null; await Try(() => a30.SleepAsync(), v => sleep = v);
        tones = null; await Try(() => a30.TonesAsync(), v => tones = v);
        Changed();
    }

    void StartPolling()
    {
        poll?.Cancel();
        var cts = poll = new CancellationTokenSource();
        _ = PollLoop(cts.Token);
    }

    async Task PollLoop(CancellationToken ct)
    {
        while (true)
        {
            try { await Task.Delay(60_000, ct); } catch (TaskCanceledException) { return; }
            if (!connected || !a30.CanRead) return;   // the dongle only pushes
            try { SetBattery(await a30.BatteryAsync()); }
            catch (A30Exception e) when (e.Kind == A30ErrorKind.Disconnected) { Disconnected(); return; }
            catch { }
            await Try(() => a30.DongleAsync(), v => dongle = v);
            await Try(() => a30.VolumeAsync(), v => { volume = v.Level; audioMuted = v.Muted; });
            Changed();
        }
    }

    /// Live updates pushed by the headset. Ignored while the user drags that control.
    void Notified(FeatureId f, byte fn, byte[] a)
    {
        if (fn != 0) return;
        switch (f)
        {
            case FeatureId.Volume when !debounce.ContainsKey("volume"):
                if (a.Length > 0) volume = a[0];
                if (a.Length > 1) audioMuted = a[1] != 0;
                break;
            case FeatureId.MicMute:
                if (a.Length > 0) SetMicMuted(a[0] != 0);
                break;
            case FeatureId.Battery:
                if (A30Kit.Battery.Parse(a) is A30Kit.Battery b) SetBattery(b);
                break;
            case FeatureId.Eq when !debounce.ContainsKey("eq") && eqWrites == 0:
                if (EqSetting.Parse(a) is EqSetting e) StoreEq(e);
                break;
            // Pushed with the full status burst when the headset links to the dongle.
            case FeatureId.Sidetone when !debounce.Keys.Any(k => k.StartsWith("sidetone")):
                foreach (var (m, v) in Codec.ParseMicValues(a)) sidetone[m] = v;
                break;
            case FeatureId.NoiseGate:
                foreach (var (m, v) in Codec.ParseMicValues(a))
                    if (Enum.IsDefined((NoiseGate)v)) noiseGate[m] = (NoiseGate)v;
                break;
            case FeatureId.Mix when !debounce.ContainsKey("balance"):
                if (a.Length > 0) balance = a[0];
                break;
            default:
                return;
        }
        Remember();
        Changed();
    }

    /// Last known settings, shown on the next start over the dongle (which can't read them).
    void Remember()
    {
        if (a30.CanRead || eq == null) return;
        settings.LastState = new Profile(Guid.Empty, "", eq.Mode, eq.Bands.ToArray(),
            sidetone.ToDictionary(kv => (byte)kv.Key, kv => kv.Value),
            noiseGate.ToDictionary(kv => (byte)kv.Key, kv => (byte)kv.Value), balance);
        Save();
    }

    // ================= writes: every SET is followed by a GET; the UI shows what the headset reports

    async Task Write(Func<Task> op, Func<Task> reread)
    {
        try { await op(); } catch (Exception e) { Show(e.Message); }
        if (a30.CanRead) { try { await reread(); } catch { } }
        else Remember();   // the dongle can't read back: trust what was sent
        Changed();
    }

    readonly Dictionary<string, CancellationTokenSource> debounce = new();

    /// Local update now, send after 150 ms without further changes (keyboard and drags alike).
    void Schedule(string key, Action commit)
    {
        if (debounce.TryGetValue(key, out var old)) old.Cancel();
        var cts = debounce[key] = new CancellationTokenSource();
        _ = Fire();

        async Task Fire()
        {
            try { await Task.Delay(150, cts.Token); } catch (TaskCanceledException) { return; }
            if (debounce.GetValueOrDefault(key) == cts) debounce.Remove(key);   // live notifications apply again
            commit();
        }
    }

    void StoreEq(EqSetting v)
    {
        eq = v;
        if (v.Mode == (byte)EqMode.Custom) { settings.LastCustomBands = v.Bands.ToArray(); Save(); }
    }

    async Task RereadEq() => StoreEq(await a30.EqAsync());

    public void SelectEq(EqMode m)
    {
        bool switching = eq?.Mode != (byte)m;
        var bands = m == EqMode.Custom ? settings.LastCustomBands.ToArray() : new int[5];
        WriteEq(new EqSetting((byte)m, bands), switching);
    }

    /// EQ writes pass through Immersive and the headset pushes a notification for each step; applying
    /// those mid-write made the preset list flash. So EQ notifications are ignored while a write is in
    /// flight and briefly after it.
    int eqWrites;

    async void WriteEq(EqSetting s, bool switching)
    {
        eqWrites++;
        eq = s;
        Changed();
        await Write(() => a30.SetEqAsync(s, switching), RereadEq);
        await Task.Delay(400);   // trailing notifications
        eqWrites--;
    }

    void SetBand(int i, double value)
    {
        if (eq == null || !IsCustom) return;
        int db = Math.Clamp((int)Math.Round(value), EqSetting.MinGain, EqSetting.MaxGain);
        if (eq.Bands[i] == db) return;
        eq.Bands[i] = db;
        Changed();
        Schedule("eq", CommitEq);
    }

    void CommitEq()
    {
        if (eq == null) return;
        if (IsCustom) { settings.LastCustomBands = eq.Bands.ToArray(); Save(); }
        WriteEq(eq with { Bands = eq.Bands.ToArray() }, switching: true);   // official pass-through
    }

    /// Drop unsent band edits and show what the headset has.
    public void RevertEq() => _ = Write(() => Task.CompletedTask, RereadEq);

    public void ResetFlat()
    {
        if (eq == null) return;
        eq = eq with { Bands = new int[5] };
        CommitEq();
    }

    void SetVolume(int v)
    {
        if (volume == v) return;
        volume = v;
        Changed();
        Schedule("volume", () => _ = Write(() => a30.SetVolumeAsync(v), RereadVolume));
    }

    async Task RereadVolume() { var r = await a30.VolumeAsync(); volume = r.Level; audioMuted = r.Muted; }

    void SetAudioMuted(bool m)
    {
        audioMuted = m;
        Changed();
        _ = Write(() => a30.SetAudioMutedAsync(m), RereadVolume);
    }

    void SetSidetone(Mic mic, int v)
    {
        if (sidetone.GetValueOrDefault(mic, -1) == v) return;
        sidetone[mic] = v;
        Changed();
        Schedule("sidetone" + mic, () => _ = Write(() => a30.SetSidetoneAsync(mic, v), async () => sidetone = await a30.SidetoneAsync()));
    }

    void SetNoiseGate(Mic mic, NoiseGate g)
    {
        noiseGate[mic] = g;
        Changed();
        _ = Write(() => a30.SetNoiseGateAsync(mic, g), async () => noiseGate = await a30.NoiseGateAsync());
    }

    void SetBalance(int v)
    {
        if (balance == v) return;
        balance = v;
        Changed();
        Schedule("balance", () => _ = Write(() => a30.SetBalanceAsync(v), async () => balance = await a30.BalanceAsync()));
    }

    void SetBaseStationXbox(bool xbox) => _ = Write(() => a30.SetBaseStationXboxAsync(xbox), async () =>
    {
        await Task.Delay(6000);   // the dongle drops and re-links after a mode change; read once it is back
        dongle = await a30.DongleAsync();
    });

    void SetSleep(SleepTimer t)
    {
        sleep = t;
        Changed();
        _ = Write(() => a30.SetSleepAsync(t), async () => sleep = await a30.SleepAsync());
    }

    void SetTones(Tones t)
    {
        tones = t;
        Changed();
        _ = Write(() => a30.SetTonesAsync(t), async () => tones = await a30.TonesAsync());
    }

    public void Rename(string n)
    {
        n = n.Trim();
        if (n.Length == 0) return;
        _ = Write(() => a30.SetNameAsync(n), async () => name = await a30.NameAsync());
    }

    /// Only reachable from Settings: warning, then "RESET" typed.
    public async void FactoryReset()
    {
        try
        {
            var s = await a30.SerialAsync();
            await a30.FactoryResetAsync(s);
            Show("Factory reset sent. Re-pair the headset if it disconnects.");
        }
        catch (Exception e) { Show(e.Message); }
        await RefreshAll();
    }

    // ================= turn off (no power-off command on the A30: 1-minute auto-sleep, then back to never)

    DateTime? powerOffStartedAt;
    CancellationTokenSource? powerOff;

    public async void TurnOff()
    {
        if (!connected || PowerOffRemaining != null) return;
        try { await a30.SetSleepMinutesAsync(1); } catch (Exception e) { Show(e.Message); return; }
        settings.RestoreSleepNever = true;
        Save();
        powerOffStartedAt = DateTime.Now;
        // Close the control channel and stay away, so our traffic doesn't keep the headset awake.
        suspendReconnectUntil = DateTime.Now.AddSeconds(135);
        poll?.Cancel();
        a30.Disconnect();
        connected = false;
        PowerOffRemaining = 120;   // measured on the Mac: ~2 min from SET 1 min to power-off
        Changed();
        var cts = powerOff = new CancellationTokenSource();
        try
        {
            while (PowerOffRemaining > 0)
            {
                await Task.Delay(1000, cts.Token);
                PowerOffRemaining--;
                Changed();
            }
        }
        catch (TaskCanceledException) { return; }
        PowerOffRemaining = null;
        Changed();
        Reconnect();   // waits out suspendReconnectUntil, then finds the headset off (or not)
    }

    public void CancelTurnOff()
    {
        powerOff?.Cancel();
        PowerOffRemaining = null;
        powerOffStartedAt = null;
        suspendReconnectUntil = null;
        Changed();
        Reconnect();   // reconnecting puts the sleep mode back to never
    }

    async Task FinishTurnOffIfNeeded()
    {
        if (!settings.RestoreSleepNever) return;
        try
        {
            await a30.SetSleepAsync(SleepTimer.Never);
            settings.RestoreSleepNever = false;
            Save();
            sleep = SleepTimer.Never;
        }
        catch { }
        if (powerOffStartedAt is DateTime t && DateTime.Now - t < TimeSpan.FromSeconds(180))
            Show("The headset didn't turn off. Pause any audio and try again.");
        powerOffStartedAt = null;
    }

    // ================= saved EQ curves and profiles (stored on this PC)

    public void SaveCurrentEq(string n)
    {
        if (eq == null || !IsCustom) return;
        settings.SavedEqs.Add(new SavedEq(Guid.NewGuid(), n, eq.Bands.ToArray()));
        Save();
        Changed();
    }

    void ApplySavedEq(SavedEq s)
    {
        settings.LastCustomBands = s.Bands.ToArray();
        Save();
        if (IsCustom && eq != null) { eq = eq with { Bands = s.Bands.ToArray() }; CommitEq(); }
        else SelectEq(EqMode.Custom);
    }

    public void SaveProfile(string n)
    {
        if (eq == null) return;
        settings.Profiles.Add(new Profile(Guid.NewGuid(), n, eq.Mode,
            IsCustom ? eq.Bands.ToArray() : settings.LastCustomBands.ToArray(),
            sidetone.ToDictionary(kv => (byte)kv.Key, kv => kv.Value),
            noiseGate.ToDictionary(kv => (byte)kv.Key, kv => (byte)kv.Value),
            dongle.Connected ? balance : null));
        Save();
        Changed();
    }

    void ApplyProfile(Profile p)
    {
        if (Enum.IsDefined((EqMode)p.EqMode))
        {
            var mode = (EqMode)p.EqMode;
            settings.LastCustomBands = p.Bands.ToArray();
            Save();
            if (mode == EqMode.Custom && IsCustom && eq != null) { eq = eq with { Bands = p.Bands.ToArray() }; CommitEq(); }
            else SelectEq(mode);
        }
        foreach (var (m, v) in p.Sidetone) if (Enum.IsDefined((Mic)m)) SetSidetone((Mic)m, v);
        foreach (var (m, g) in p.NoiseGate) if (Enum.IsDefined((Mic)m) && Enum.IsDefined((NoiseGate)g)) SetNoiseGate((Mic)m, (NoiseGate)g);
        if (p.Balance is int b && dongle.Connected) SetBalance(b);
        Show($"Profile {p.Name} applied");
    }

    // ================= EQ per app

    EqMode? restoreMode;   // mode to put back when leaving an app with a rule

    public void AppActivated(string process)
    {
        if (!connected || process.Equals("A30Control", StringComparison.OrdinalIgnoreCase)) return;
        var rule = settings.AppRules.FirstOrDefault(r => r.Exe.Equals(process, StringComparison.OrdinalIgnoreCase));
        if (rule != null && Enum.IsDefined((EqMode)rule.Mode))
        {
            if (restoreMode == null && eq != null && Enum.IsDefined((EqMode)eq.Mode)) restoreMode = (EqMode)eq.Mode;
            if (eq?.Mode != rule.Mode) SelectEq((EqMode)rule.Mode);
        }
        else if (restoreMode is EqMode prev)
        {
            restoreMode = null;
            if (eq?.Mode != (byte)prev) SelectEq(prev);
        }
    }

    public void AddAppRule(string exePath)
    {
        var exe = Path.GetFileNameWithoutExtension(exePath);
        if (settings.AppRules.Any(r => r.Exe.Equals(exe, StringComparison.OrdinalIgnoreCase))) return;
        var desc = FileVersionInfo.GetVersionInfo(exePath).FileDescription;
        settings.AppRules.Add(new AppRule { Exe = exe, Name = string.IsNullOrWhiteSpace(desc) ? exe : desc, Mode = (byte)EqMode.Footstep });
        Save();
        Changed();
    }

    public void SetRuleMode(AppRule r, EqMode m) { r.Mode = (byte)m; Save(); Changed(); }
    public void RemoveRule(AppRule r) { settings.AppRules.Remove(r); Save(); Changed(); }

    // ================= updates

    AvailableUpdate? update;
    bool updating;
    string? notifiedUpdate;

    async Task UpdateLoop()
    {
        await Task.Delay(TimeSpan.FromSeconds(10));
        while (true)
        {
            await CheckForUpdate();
            await Task.Delay(TimeSpan.FromHours(24));
        }
    }

    async Task CheckForUpdate()
    {
        if (!settings.CheckUpdates) { update = null; Changed(); return; }
        try { update = await Updater.CheckAsync(settings.BetaUpdates); }
        catch (Exception e) { Log.Write("update check failed: " + e.Message); return; }
        Changed();
        if (update == null || notifiedUpdate == update.Tag) return;
        notifiedUpdate = update.Tag;
        Log.Write($"update available: {update.Tag}");
        Notify("A30 Control update", $"Version {update.Version.ToString(3)} is available. Click to open A30 Control and install it.");
    }

    /// Installed copies download, verify and install silently; portable copies (or a release without
    /// a checksum) open the release page.
    public async void InstallUpdate()
    {
        if (update == null || updating) return;
        if (!Updater.IsInstalled || update.Setup.Sha256 == null) { Updater.OpenPage(update.PageUrl); return; }
        updating = true;
        Changed();
        try
        {
            await Updater.InstallAsync(update);
            Log.Write($"installing {update.Tag}");
            RequestQuit();
        }
        catch (Exception e)
        {
            Log.Write("update failed: " + e.Message);
            Show("Update failed: " + e.Message);
            updating = false;
            Changed();
        }
    }

    // ================= alerts and helpers

    bool alerted20, alerted10;

    void SetBattery(Battery b)
    {
        battery = b;
        if (b.IsCharging || b.Percent > 25) { alerted20 = alerted10 = false; return; }
        if (b.Percent <= 10 && !alerted10)
        {
            alerted10 = alerted20 = true;
            Notify($"A30 battery at {b.Percent}%", "Charge the headset soon.");
        }
        else if (b.Percent <= 20 && !alerted20)
        {
            alerted20 = true;
            Notify($"A30 battery at {b.Percent}%", "Battery is getting low.");
        }
    }

    void SetMicMuted(bool m)
    {
        if (micMuted == m) return;
        micMuted = m;
        Notify(m ? "Mic muted" : "Mic unmuted", "ASTRO A30");
    }

    async void Show(string msg)
    {
        banner = msg;
        Changed();
        await Task.Delay(4000);
        if (banner != msg) return;
        banner = null;
        Changed();
    }

    void Save() => Store.Save(settings);
}
