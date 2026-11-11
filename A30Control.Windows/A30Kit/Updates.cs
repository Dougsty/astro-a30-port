// Picks the newest Windows release from the GitHub releases API and checks the download's SHA-256
// against the digest GitHub publishes for every release asset.
using System.Security.Cryptography;
using System.Text.Json;

namespace A30Kit;

public sealed record ReleaseAsset(string Name, string Url, string? Sha256);

public sealed record AvailableUpdate(Version Version, string Tag, string PageUrl, ReleaseAsset Setup);

public static class Updates
{
    public const string TagPrefix = "windows-v";
    public const string SetupPrefix = "A30Control-Setup-";

    /// Newest non-draft Windows release (prereleases only with includeBeta) that is newer than
    /// `current` and has a setup asset. Null when none, or when the JSON can't be read.
    public static AvailableUpdate? Pick(string releasesJson, Version current, bool includeBeta)
    {
        var mine = new Version(current.Major, current.Minor, Math.Max(current.Build, 0));
        AvailableUpdate? best = null;
        try
        {
            using var doc = JsonDocument.Parse(releasesJson);
            foreach (var r in doc.RootElement.EnumerateArray())
            {
                if (r.GetProperty("draft").GetBoolean()) continue;
                if (r.GetProperty("prerelease").GetBoolean() && !includeBeta) continue;
                var tag = r.GetProperty("tag_name").GetString() ?? "";
                if (!tag.StartsWith(TagPrefix) || !Version.TryParse(tag[TagPrefix.Length..], out var v)) continue;
                v = new Version(v.Major, v.Minor, Math.Max(v.Build, 0));
                if (v <= mine || (best != null && v <= best.Version)) continue;
                foreach (var a in r.GetProperty("assets").EnumerateArray())
                {
                    var name = a.GetProperty("name").GetString() ?? "";
                    if (!name.StartsWith(SetupPrefix) || !name.EndsWith(".exe")) continue;
                    string? sha = a.TryGetProperty("digest", out var d) && d.GetString() is string ds && ds.StartsWith("sha256:")
                        ? ds["sha256:".Length..].ToLowerInvariant() : null;
                    best = new AvailableUpdate(v, tag, r.GetProperty("html_url").GetString() ?? "",
                                               new ReleaseAsset(name, a.GetProperty("browser_download_url").GetString() ?? "", sha));
                    break;
                }
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException) { return null; }
        return best;
    }

    public static bool Sha256Matches(byte[] data, string expectedHex) =>
        Convert.ToHexString(SHA256.HashData(data)).Equals(expectedHex, StringComparison.OrdinalIgnoreCase);
}
