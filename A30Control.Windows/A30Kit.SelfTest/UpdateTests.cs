using A30Kit;
using static T;

static class UpdateTests
{
    // Trimmed shape of GET /repos/{owner}/{repo}/releases
    const string Json = """
    [
      {"tag_name":"windows-v1.1.0","draft":true,"prerelease":false,"html_url":"https://x/draft",
       "assets":[{"name":"A30Control-Setup-1.1.0.exe","browser_download_url":"https://x/d.exe","digest":"sha256:aa"}]},
      {"tag_name":"windows-v1.0.3","draft":false,"prerelease":true,"html_url":"https://x/103",
       "assets":[{"name":"A30Control-Setup-1.0.3.exe","browser_download_url":"https://x/103.exe","digest":"sha256:ABCDEF"},
                 {"name":"A30Control.exe","browser_download_url":"https://x/p.exe","digest":"sha256:00"}]},
      {"tag_name":"windows-v1.0.2","draft":false,"prerelease":false,"html_url":"https://x/102",
       "assets":[{"name":"A30Control-Setup-1.0.2.exe","browser_download_url":"https://x/102.exe"}]},
      {"tag_name":"v2.0.0","draft":false,"prerelease":false,"html_url":"https://x/mac",
       "assets":[{"name":"A30-Control-macOS-v2.0.0.zip","browser_download_url":"https://x/m.zip","digest":"sha256:11"}]},
      {"tag_name":"windows-v1.0.9","draft":false,"prerelease":false,"html_url":"https://x/noasset","assets":[]}
    ]
    """;

    public static void Run()
    {
        var beta = Updates.Pick(Json, new Version(1, 0, 1, 0), includeBeta: true);
        Check(beta?.Version == new Version(1, 0, 3) && beta.Setup.Url == "https://x/103.exe" && beta.Setup.Sha256 == "abcdef",
              "beta on: newest Windows prerelease with a setup asset (drafts, macOS tags and asset-less releases skipped)");
        Check(beta?.PageUrl == "https://x/103", "release page kept");

        var stable = Updates.Pick(Json, new Version(1, 0, 1, 0), includeBeta: false);
        Check(stable?.Version == new Version(1, 0, 2) && stable.Setup.Sha256 == null, "beta off: newest stable; missing digest → null");

        Check(Updates.Pick(Json, new Version(1, 0, 3, 0), includeBeta: true) == null, "same version (4-part assembly version) → no update");
        Check(Updates.Pick("not json", new Version(1, 0, 0), true) == null, "bad JSON → no update");

        byte[] data = "abc"u8.ToArray();
        Check(Updates.Sha256Matches(data, "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"), "sha256 match (case-insensitive)");
        Check(!Updates.Sha256Matches(data, "00"), "sha256 mismatch");
    }
}
