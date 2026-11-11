using System.Diagnostics;
using System.IO;
using System.Net.Http;
using A30Kit;

namespace A30Control;

/// Checks this repo's GitHub releases and installs a newer Windows setup. Only the public releases
/// API is called (no user data); the download must match the SHA-256 digest GitHub publishes.
static class Updater
{
    const string ReleasesApi = "https://api.github.com/repos/Dougsty/astro-a30-port/releases?per_page=30";
    static readonly HttpClient Http = CreateClient();

    static HttpClient CreateClient()
    {
        var h = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        h.DefaultRequestHeaders.UserAgent.ParseAdd("A30Control-updater");
        h.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return h;
    }

    public static Version Current => typeof(Updater).Assembly.GetName().Version ?? new Version(0, 0, 0);

    static string InstallDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "A30 Control");

    /// Installed by the setup. Portable copies open the release page instead of self-updating.
    public static bool IsInstalled => Environment.ProcessPath?.StartsWith(InstallDir, StringComparison.OrdinalIgnoreCase) == true;

    public static async Task<AvailableUpdate?> CheckAsync(bool includeBeta) =>
        Updates.Pick(await Http.GetStringAsync(ReleasesApi), Current, includeBeta);

    /// Downloads the setup, checks the digest and starts it silently; the setup closes this app,
    /// installs over it and starts the new version.
    public static async Task InstallAsync(AvailableUpdate u)
    {
        if (u.Setup.Sha256 is not string sha) throw new InvalidOperationException("the release has no checksum");
        var bytes = await Http.GetByteArrayAsync(u.Setup.Url);
        if (!Updates.Sha256Matches(bytes, sha)) throw new InvalidOperationException("the download failed the checksum");
        var path = Path.Combine(Path.GetTempPath(), u.Setup.Name);
        await File.WriteAllBytesAsync(path, bytes);
        Process.Start(new ProcessStartInfo(path, "/S") { UseShellExecute = true });
    }

    public static void OpenPage(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
}
