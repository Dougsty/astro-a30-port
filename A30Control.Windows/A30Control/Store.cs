using System.IO;
using System.Text.Json;

namespace A30Control;

public sealed record SavedEq(Guid Id, string Name, int[] Bands);

/// EQ + mic + balance bundle, like the official app's "Game"/"Media" profiles.
public sealed record Profile(Guid Id, string Name, byte EqMode, int[] Bands,
                             Dictionary<byte, int> Sidetone, Dictionary<byte, byte> NoiseGate, int? Balance);

public sealed class AppRule
{
    public string Exe { get; set; } = "";    // process name without ".exe"
    public string Name { get; set; } = "";
    public byte Mode { get; set; }
}

public sealed class Settings
{
    public List<SavedEq> SavedEqs { get; set; } = [];
    public List<Profile> Profiles { get; set; } = [];
    public List<AppRule> AppRules { get; set; } = [];
    public int[] LastCustomBands { get; set; } = [0, 0, 0, 0, 0];
    /// Survives quitting: put the sleep mode back to "never" on the next connect after Turn off.
    public bool RestoreSleepNever { get; set; }
    /// Last known EQ/mic/balance, for the dongle route (which can't read the headset).
    public Profile? LastState { get; set; }
    public bool CheckUpdates { get; set; } = true;
    /// Windows builds are all betas for now, so beta updates are on by default.
    public bool BetaUpdates { get; set; } = true;
}

/// %APPDATA%\A30Control\settings.json.
static class Store
{
    static string PathName => Path.Combine(Log.Dir, "settings.json");

    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(PathName)) ?? new(); }
        catch { return new(); }
    }

    public static void Save(Settings s)
    {
        try
        {
            Directory.CreateDirectory(Log.Dir);
            File.WriteAllText(PathName, JsonSerializer.Serialize(s, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception e) { Log.Write("settings not saved: " + e.Message); }
    }
}
