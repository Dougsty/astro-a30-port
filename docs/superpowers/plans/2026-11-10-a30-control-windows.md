# A30 Control for Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A self-contained `A30Control.exe` for Windows 10/11 with the same features as the macOS A30 Control app, built on this Mac.

**Architecture:** `A30Kit` (net8.0, no Windows APIs) is a direct port of the Swift `A30Control/Sources/A30Kit`: framing, iAP2, codecs, a transport-agnostic `HeadsetLink` that auto-detects iAP2 vs raw SPP, and the typed `A30Client`. `A30Kit.SelfTest` ports the Swift tests and runs on the Mac. The WPF app (`A30Control`) adds the WinRT RFCOMM transport, `HeadsetModel` (port of `HeadsetModel.swift`), tray icon + panel, the Command Center window and Windows integrations.

**Tech Stack:** C# 12 / .NET 8 SDK (per-user in `~/.dotnet`), WPF + WinForms `NotifyIcon`, WinRT `Windows.Devices.Bluetooth.Rfcomm`, System.Text.Json. No NuGet packages.

**Spec:** `docs/superpowers/specs/2026-11-10-a30-control-windows-design.md`

**Not a git repository:** there are no commit steps. Each task ends when its check passes.

**Deviation from the spec (simpler, same effect):** instead of `Directory.Build.props` redirecting `bin/obj`, every script compiles a snapshot copied to `~/Library/Caches/A30Control.Windows/src` (the Mac app's `build.sh` already does this to dodge iCloud Drive), so no build output lands in iCloud. The `.sln` is kept for opening the project in Visual Studio on Windows.

## Global Constraints

- Location: `A30Control.Windows/` at the repo root, next to `A30Control/`.
- Target frameworks: `A30Kit` and `A30Kit.SelfTest` → `net8.0`; app → `net8.0-windows10.0.19041.0` with `UseWPF`, `UseWindowsForms`, `EnableWindowsTargeting=true`.
- Publish: `-r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true` → `A30Control.Windows/dist/A30Control.exe`. No trimming (WPF).
- .NET SDK: installed with `dotnet-install.sh --channel 8.0 --install-dir ~/.dotnet`; scripts source `env.sh` for `DOTNET_ROOT`/`PATH`.
- Never call iGenericDFU (0x010A): `FeatureId` has no entry for it. Factory reset only after an OK/Cancel warning and typing `RESET`. No raw-command UI.
- Never force the Bluetooth connection: open RFCOMM only when `BluetoothDevice.ConnectionStatus == Connected`.
- Log every connection step and every frame (hex) to `%APPDATA%\A30Control\a30.log`, rotated at 1 MB.
- Settings in `%APPDATA%\A30Control\settings.json`.
- Repo content in English. Window 980×660 fixed (no maximize/resize), dark theme, accent `#ff4b1f`.
- Wire formats exactly as `CLAUDE.md` and the Swift sources (`A30Control/Sources/A30Kit/*.swift`), which are the reference for every port in this plan.

## Review Focus

1. Headset paired but not connected to the PC: the app must not page it or bring the link up; it shows "connect it in Bluetooth settings" and keeps retrying quietly. (Manual: checklist §2; code: `RfcommTransport.OpenAsync` status check, Task 6.)
2. Headset silent on both transports (no iAP2 detect, no SPP reply): connect fails with Timeout, the channel is closed, the loop retries every 5 s and the UI never freezes. (Test: Task 4, "silent headset".)
3. A swID-0 notification (volume wheel, EQ, battery) arriving while a request is in flight must not be taken as its reply. (Test: Task 4, "notification does not answer the pending request".)
4. Reply bytes split at arbitrary chunk boundaries (RFCOMM reads), including single bytes. (Test: Task 4, "reply split into single bytes".)
5. A second copy started (autostart + double-click): it exits at once so only one process holds the channel. (Manual: checklist §1; code: mutex in `App.OnStartup`, Task 6.)

---

### Task 1: Toolchain, solution, framing (SPP, CRC, CPL, iAP2 link packets)

**Files:**
- Create: `A30Control.Windows/env.sh`, `A30Control.Windows/selftest.sh`
- Create: `A30Control.Windows/A30Kit/A30Kit.csproj`, `A30Control.Windows/A30Kit/Framing.cs`
- Create: `A30Control.Windows/A30Kit.SelfTest/A30Kit.SelfTest.csproj`, `Program.cs`, `Fixtures.cs`, `FramingTests.cs`
- Create: `A30Control.Windows/A30Control.Windows.sln`

**Interfaces:**
- Produces (namespace `A30Kit`): `static class Wire { Hex, Be16, Rd16, Crc16, SppWrap, CppRequest, Iap2Detect, IapChecksum, IapParam, ControlMsg, ParseParams, IapText }`, `SppParser.Feed(byte[]) → List<byte[]>`, `CplReassembler.Feed(byte[]) → byte[]?`, `record CppReply(bool IsError, byte Index, byte Function, byte SwId, byte[] Args, byte Code)` with `static Parse(byte[]) → CppReply?`, `record LinkPacket(Control, Seq, Ack, Session, Payload)` with `Encode()` and consts `SYN/ACK/RST`, `Iap2Frame.{Detect, Packet(P), Junk(B)}`, `Iap2Splitter.Feed`, `record IapParam(int Id, byte[] Data)`, `record ControlMessage(int Id, List<IapParam> Params)`, `ControlParser.Feed`.
- Produces (SelfTest): `T.Check(bool, string)`, `T.Bytes(string)`, `T.Same(byte[]?, byte[])`, `T.Events(IEnumerable<object>, string, params string[])`, `T.Send(string hex)`, `Fixtures.FeatureListFrames`, `Fixtures.Syn`, `Fixtures.FeatureListArgs()`.

- [ ] **Step 1: Install the .NET 8 SDK per-user**

```bash
mkdir -p ~/Library/Caches/A30Control.Windows
curl -sSL https://dot.net/v1/dotnet-install.sh -o ~/Library/Caches/A30Control.Windows/dotnet-install.sh
bash ~/Library/Caches/A30Control.Windows/dotnet-install.sh --channel 8.0 --install-dir "$HOME/.dotnet"
"$HOME/.dotnet/dotnet" --list-sdks
```
Expected: one `8.0.x` SDK listed.

- [ ] **Step 2: Scripts and projects**

`A30Control.Windows/env.sh`:
```sh
# Shared by the build scripts: per-user .NET SDK, and a build snapshot outside iCloud Drive
# (iCloud evicts or touches files mid-build; see A30Control/build.sh).
export DOTNET_ROOT="$HOME/.dotnet" PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
SNAP="$HOME/Library/Caches/A30Control.Windows/src"
mkdir -p "$SNAP"
```

`A30Control.Windows/selftest.sh`:
```sh
#!/bin/sh
# Runs the A30Kit protocol selftest on this Mac (no headset needed).
set -e
cd "$(dirname "$0")"
. ./env.sh
rsync -a --delete --exclude dist --exclude bin --exclude obj ./ "$SNAP/"
dotnet run --project "$SNAP/A30Kit.SelfTest"
```

`A30Control.Windows/A30Kit/A30Kit.csproj`:
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
</Project>
```

`A30Control.Windows/A30Kit.SelfTest/A30Kit.SelfTest.csproj`:
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="../A30Kit/A30Kit.csproj" />
  </ItemGroup>
</Project>
```

```bash
cd A30Control.Windows && chmod +x selftest.sh && . ./env.sh
dotnet new sln -n A30Control.Windows
dotnet sln add A30Kit/A30Kit.csproj A30Kit.SelfTest/A30Kit.SelfTest.csproj
```

- [ ] **Step 3: Write the failing tests**

`A30Kit.SelfTest/Program.cs`:
```csharp
using System.Runtime.CompilerServices;

FramingTests.Run();
Console.WriteLine(T.Failures == 0 ? "selftest: all passed" : $"selftest: {T.Failures} failed");
return T.Failures == 0 ? 0 : 1;

/// Minimal runner, mirrors A30Control/Tests/SelfTest.swift.
static class T
{
    public static int Failures;

    public static void Check(bool cond, string msg, [CallerLineNumber] int line = 0)
    {
        if (cond) return;
        Failures++;
        Console.WriteLine($"FAIL line {line}: {msg}");
    }

    /// "13 a0 05" → [0x13, 0xa0, 0x05]
    public static byte[] Bytes(string s) =>
        s.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(x => Convert.ToByte(x, 16)).ToArray();

    public static bool Same(byte[]? a, byte[] b) => a != null && a.SequenceEqual(b);

    /// Compares event/frame lists by their ToString() forms ("send ff 5a …", "ready", …).
    public static void Events(IEnumerable<object> got, string msg, params string[] want)
    {
        var g = got.Select(x => x.ToString()!).ToArray();
        Check(g.SequenceEqual(want), $"{msg}\n  got:  {string.Join(" | ", g)}\n  want: {string.Join(" | ", want)}");
    }

    public static string Send(string hex) => "send " + hex;
}
```

`A30Kit.SelfTest/Fixtures.cs`:
```csharp
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
```

`A30Kit.SelfTest/FramingTests.cs` (port of `A30Control/Tests/FramingTests.swift`):
```csharp
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
```

- [ ] **Step 4: Run to verify it fails**

Run: `A30Control.Windows/selftest.sh`
Expected: build error, e.g. `The type or namespace name 'Wire' could not be found`.

- [ ] **Step 5: Implement `A30Kit/Framing.cs`** (port of `Framing.swift`)

```csharp
// Byte-level framing for the A30 control channel. Pure functions, no Bluetooth, so the selftest
// can exercise them without a headset. Layers (outside in):
// RFCOMM bytes → [iAP2 link packets → EA session data] → SPP frames → CPL → CPP.
using System.Text;

namespace A30Kit;

public static class Wire
{
    public static string Hex(IEnumerable<byte> d) => string.Join(" ", d.Select(b => b.ToString("x2")));

    public static byte[] Be16(int v) => [(byte)(v >> 8), (byte)v];

    internal static int Rd16(IReadOnlyList<byte> d, int o) => d[o] << 8 | d[o + 1];

    /// CRC-16/MCRF4XX (poly 0x8408 reflected, init 0xFFFF). Check value 0x6F91 for "123456789".
    public static ushort Crc16(IEnumerable<byte> d)
    {
        ushort c = 0xFFFF;
        foreach (var b in d)
        {
            c ^= b;
            for (int i = 0; i < 8; i++) c = (c & 1) != 0 ? (ushort)((c >> 1) ^ 0x8408) : (ushort)(c >> 1);
        }
        return c;
    }

    /// SPP frame: 13 | A0+lenHi | lenLo | payload | crcLo crcHi
    public static byte[] SppWrap(byte[] payload)
    {
        int n = payload.Length;
        var f = new List<byte>(n + 5) { 0x13, (byte)(0xA0 | ((n >> 8) & 0x0F)), (byte)n };
        f.AddRange(payload);
        var c = Crc16(f);
        f.Add((byte)c);
        f.Add((byte)(c >> 8));
        return f.ToArray();
    }

    /// CPL byte 0x00 (single fragment) + feature index + (fn << 4 | swId) + args.
    public static byte[] CppRequest(byte index, byte function, byte swId, byte[] args) =>
        [0x00, index, (byte)((function << 4) | (swId & 0x0F)), .. args];

    // ---- iAP2

    public static readonly byte[] Iap2Detect = [0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10];

    /// iAP2 checksum: two's complement of the byte sum.
    public static byte IapChecksum(IEnumerable<byte> d) => unchecked((byte)-d.Sum(b => (int)b));

    /// Control-message param: len(2) id(2) data.
    public static byte[] IapParam(int id, byte[] data) => [.. Be16(4 + data.Length), .. Be16(id), .. data];

    /// Control message: 40 40 len(2) msgId(2) params.
    public static byte[] ControlMsg(int id, byte[]? prm = null)
    {
        prm ??= [];
        return [0x40, 0x40, .. Be16(6 + prm.Length), .. Be16(id), .. prm];
    }

    /// Parses a run of params; null unless the bytes are exactly a well-formed run.
    public static List<IapParam>? ParseParams(byte[] d)
    {
        var o = new List<IapParam>();
        int i = 0;
        while (i + 4 <= d.Length)
        {
            int n = Rd16(d, i);
            if (n < 4 || i + n > d.Length) return null;
            o.Add(new IapParam(Rd16(d, i + 2), d[(i + 4)..(i + n)]));
            i += n;
        }
        return i == d.Length ? o : null;
    }

    /// Printable ASCII (one trailing NUL allowed), else null.
    public static string? IapText(byte[] d)
    {
        var s = d.Length > 0 && d[^1] == 0 ? d[..^1] : d;
        if (s.Length == 0 || s.Any(b => b < 0x20 || b >= 0x7F)) return null;
        return Encoding.ASCII.GetString(s);
    }
}

/// Reassembles SPP frames from a byte stream. Over the iAP2 EA session the A30 sends CRC 00 00,
/// so that is accepted as well as a correct CRC.
public sealed class SppParser
{
    readonly List<byte> buf = new();

    public List<byte[]> Feed(byte[] bytes)
    {
        buf.AddRange(bytes);
        var o = new List<byte[]>();
        int i = 0;
        while (i + 5 <= buf.Count)
        {
            if (buf[i] != 0x13 || (buf[i + 1] & 0xF0) != 0xA0) { i++; continue; }
            int n = (buf[i + 1] & 0x0F) << 8 | buf[i + 2];
            int end = i + 3 + n + 2;
            if (end > buf.Count) break;
            int rx = buf[end - 2] | buf[end - 1] << 8;
            if (rx == 0 || rx == Wire.Crc16(buf.GetRange(i, 3 + n))) o.Add(buf.GetRange(i + 3, n).ToArray());
            i = end;
        }
        buf.RemoveRange(0, i);
        return o;
    }
}

/// Joins CPL fragments (CPL bit0 = more follow, bits1-7 = fragment seq). Returns the CPP message
/// (CPL byte stripped) once the last fragment arrives. Fragments must arrive in order 0, 1, 2 …;
/// a gap or stray continuation drops the partial message; fragment 0 always starts fresh.
public sealed class CplReassembler
{
    List<byte> frag = new();
    int nextSeq;
    bool inProgress;

    public byte[]? Feed(byte[] payload)
    {
        if (payload.Length == 0) return null;
        byte cpl = payload[0];
        int seq = cpl >> 1;
        if (seq == 0) frag = new();
        else if (!inProgress || seq != nextSeq) { frag = new(); inProgress = false; return null; }
        frag.AddRange(payload.Skip(1));
        if (frag.Count > 4096) { frag = new(); inProgress = false; return null; }   // runaway guard
        if ((cpl & 1) != 0) { inProgress = true; nextSeq = (seq + 1) & 0x7F; return null; }
        var msg = frag.ToArray();
        frag = new();
        inProgress = false;
        return msg;
    }
}

/// CPP reply (CPL byte already stripped). Errors look like FF featIdx fn|sw code.
public sealed record CppReply(bool IsError, byte Index, byte Function, byte SwId, byte[] Args, byte Code)
{
    public static CppReply? Parse(byte[] m)
    {
        if (m.Length >= 4 && m[0] == 0xFF) return new(true, m[1], (byte)(m[2] >> 4), (byte)(m[2] & 0x0F), [], m[3]);
        if (m.Length < 2) return null;
        return new(false, m[0], (byte)(m[1] >> 4), (byte)(m[1] & 0x0F), m[2..], 0);
    }

    public override string ToString() => IsError
        ? $"error idx={Index} fn={Function} sw={SwId} code={Code}"
        : $"ok idx={Index} fn={Function} sw={SwId} args={Wire.Hex(Args)}";
}

/// iAP2 link packet: FF 5A len(2) control seq ack session hdrCks [payload payloadCks]
public sealed record LinkPacket(byte Control, byte Seq, byte Ack, byte Session, byte[] Payload)
{
    public const byte SYN = 0x80, ACK = 0x40, RST = 0x10;

    public LinkPacket(byte control, byte seq, byte ack, byte session) : this(control, seq, ack, session, []) { }

    public byte[] Encode()
    {
        int len = 9 + (Payload.Length == 0 ? 0 : Payload.Length + 1);
        var p = new List<byte> { 0xFF, 0x5A, (byte)(len >> 8), (byte)len, Control, Seq, Ack, Session };
        p.Add(Wire.IapChecksum(p));
        if (Payload.Length > 0) { p.AddRange(Payload); p.Add(Wire.IapChecksum(Payload)); }
        return p.ToArray();
    }

    public override string ToString() => "packet " + Wire.Hex(Encode());
}

public abstract record Iap2Frame
{
    public sealed record Detect : Iap2Frame { public override string ToString() => "detect"; }
    public sealed record Packet(LinkPacket P) : Iap2Frame { public override string ToString() => P.ToString(); }
    public sealed record Junk(byte B) : Iap2Frame { public override string ToString() => $"junk {B:x2}"; }
}

/// Splits the RFCOMM byte stream into iAP2 detect sequences and checksum-valid link packets.
public sealed class Iap2Splitter
{
    readonly List<byte> buf = new();

    public List<Iap2Frame> Feed(byte[] bytes)
    {
        buf.AddRange(bytes);
        var o = new List<Iap2Frame>();
        while (buf.Count >= 2)
        {
            if (buf.Count >= 6 && buf.Take(6).SequenceEqual(Wire.Iap2Detect))
            {
                buf.RemoveRange(0, 6);
                o.Add(new Iap2Frame.Detect());
                continue;
            }
            if (buf[0] == 0xFF && buf[1] == 0x5A)
            {
                if (buf.Count < 9) break;
                // Check the header checksum before trusting len: a false FF 5A or a corrupt length
                // must not make us wait for up to 64 KiB and swallow valid packets.
                if (Wire.IapChecksum(buf.Take(8)) != buf[8]) { o.Add(TakeJunk()); continue; }
                int len = Wire.Rd16(buf, 2);
                if (len < 9) { o.Add(TakeJunk()); continue; }
                if (buf.Count < len) break;
                var p = buf.GetRange(0, len).ToArray();
                buf.RemoveRange(0, len);
                byte[] payload = len > 10 ? p[9..(len - 1)] : [];
                if (payload.Length == 0 || Wire.IapChecksum(payload) == p[len - 1])
                    o.Add(new Iap2Frame.Packet(new LinkPacket(p[4], p[5], p[6], p[7], payload)));
                continue;
            }
            if (buf.Count < 6 && Wire.Iap2Detect.Take(buf.Count).SequenceEqual(buf)) break;   // partial detect
            o.Add(TakeJunk());
        }
        return o;
    }

    Iap2Frame TakeJunk()
    {
        var b = buf[0];
        buf.RemoveAt(0);
        return new Iap2Frame.Junk(b);
    }
}

public sealed record IapParam(int Id, byte[] Data);

public sealed record ControlMessage(int Id, List<IapParam> Params);

/// Reassembles iAP2 control messages that may span several link packets.
public sealed class ControlParser
{
    readonly List<byte> buf = new();

    public List<ControlMessage> Feed(byte[] bytes)
    {
        buf.AddRange(bytes);
        var o = new List<ControlMessage>();
        while (buf.Count >= 6)
        {
            if (buf[0] != 0x40 || buf[1] != 0x40) { buf.Clear(); break; }   // desync: drop buffer
            int n = Wire.Rd16(buf, 2);
            if (n < 6) { buf.Clear(); break; }
            if (buf.Count < n) break;
            o.Add(new ControlMessage(Wire.Rd16(buf, 4), Wire.ParseParams(buf.GetRange(6, n - 6).ToArray()) ?? []));
            buf.RemoveRange(0, n);
        }
        return o;
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `A30Control.Windows/selftest.sh`
Expected: `selftest: all passed`

---

### Task 2: iAP2 session (Apple-device role)

**Files:**
- Create: `A30Control.Windows/A30Kit/Iap2Session.cs`
- Create: `A30Control.Windows/A30Kit.SelfTest/Iap2Tests.cs`
- Modify: `A30Control.Windows/A30Kit.SelfTest/Program.cs` (add `Iap2Tests.Run();` after `FramingTests.Run();`)

**Interfaces:**
- Consumes: Task 1 `Wire`, `LinkPacket`, `Iap2Splitter`, `ControlParser`, `ControlMessage`.
- Produces: `abstract record Iap2Event { Send(byte[] Bytes), Ready, EaData(byte[] Bytes), Reset, Log(string Text) }` (ToString: `send <hex>`, `ready`, `ea <hex>`, `reset`, `log <text>`); `sealed class Iap2Session { const string ProtocolName; bool LinkUp; bool EaOpen; Dictionary<int,string> Identity; Func<byte> Random; List<Iap2Event> Receive(byte[]); byte[] EaPacket(byte[] data) }`.

- [ ] **Step 1: Write the failing test** — `A30Kit.SelfTest/Iap2Tests.cs` (port of `IAP2Tests.swift`; expected bytes are from the live Mac log)

```csharp
using System.Text;
using A30Kit;
using static T;

static class Iap2Tests
{
    const byte A = LinkPacket.ACK;
    static readonly byte[] Carbonite = Encoding.ASCII.GetBytes(Iap2Session.ProtocolName);

    static byte[] Ident(bool withCarbonite) => withCarbonite
        ? [.. Wire.IapParam(0, [.. "A30"u8, 0]),
           .. Wire.IapParam(3, [.. "A30SERIAL001"u8, 0]),
           .. Wire.IapParam(10, [.. Wire.IapParam(0, [1]), .. Wire.IapParam(1, [.. Carbonite, 0]), .. Wire.IapParam(2, [1])])]
        : Wire.IapParam(0, [.. "X"u8]);

    /// Control-message payloads of every Send (plain ACKs have none).
    static IEnumerable<string> SentPayloads(IEnumerable<Iap2Event> ev) =>
        ev.OfType<Iap2Event.Send>().Where(s => s.Bytes.Length > 10).Select(s => Wire.Hex(s.Bytes[9..^1]));

    public static void Run()
    {
        var s = new Iap2Session { Random = () => 0 };

        Events(s.Receive(Wire.Iap2Detect), "detect is echoed", Send("ff 55 02 00 ee 10"));
        Events(s.Receive(Fixtures.Syn), "SYN+ACK",
               Send("ff 5a 00 1a c0 2b 18 00 8a 01 05 00 84 05 dc 01 f4 1e 03 01 00 01 03 02 01 77"));
        Events(s.Receive(new LinkPacket(A, 0x18, 0x2b, 0).Encode()), "link up → AA00",
               Send("ff 5a 00 10 40 2c 18 01 12 40 40 00 06 aa 00 d0"));
        Check(s.LinkUp, "linkUp");

        // AuthenticationCertificate (609-byte cert) → ACK + 32-byte challenge
        var cert = new LinkPacket(A, 0x19, 0x2c, 1, Wire.ControlMsg(0xAA01, Wire.IapParam(0, Enumerable.Repeat((byte)0x30, 609).ToArray())));
        var aa02 = new LinkPacket(A, 0x2d, 0x19, 1, Wire.ControlMsg(0xAA02, Wire.IapParam(0, new byte[32]))).Encode();
        Events(s.Receive(cert.Encode()), "ACK cert + AA02 challenge", Send("ff 5a 00 09 40 2c 19 00 19"), Send(Wire.Hex(aa02)));
        Check(Wire.Hex(aa02[..9]) == "ff 5a 00 34 40 2d 19 01 ec", "AA02 header matches log");

        // AuthenticationResponse → ACK, AA05, 1D00
        var resp = new LinkPacket(A, 0x1a, 0x2d, 1, Wire.ControlMsg(0xAA03, Wire.IapParam(0, Enumerable.Repeat((byte)1, 64).ToArray())));
        Events(s.Receive(resp.Encode()), "auth succeeded + start identification",
               Send("ff 5a 00 09 40 2d 1a 00 17"),
               Send("ff 5a 00 10 40 2e 1a 01 0e 40 40 00 06 aa 05 cb"),
               Send("ff 5a 00 10 40 2f 1a 01 0d 40 40 00 06 1d 00 5d"));

        // IdentificationInformation with the EA protocol group → ACK, 1D02, EA00, ready
        var idp = new LinkPacket(A, 0x1b, 0x2f, 1, Wire.ControlMsg(0x1D01, Ident(true)));
        Events(s.Receive(idp.Encode()), "identification accepted + EA session started",
               Send("ff 5a 00 09 40 2f 1b 00 14"),
               Send("ff 5a 00 10 40 30 1b 01 0b 40 40 00 06 1d 02 5b"),
               Send("ff 5a 00 1b 40 31 1b 01 ff 40 40 00 11 ea 00 00 05 00 00 01 00 06 00 01 00 01 77"),
               "ready");
        Check(s.EaOpen, "eaOpen");
        Check(s.Identity.GetValueOrDefault(0) == "A30" && s.Identity.GetValueOrDefault(3) == "A30SERIAL001", "identity strings");

        // First CPP request over EA, exactly as logged
        Check(Wire.Hex(s.EaPacket(Wire.SppWrap(Wire.CppRequest(0, 0, 1, [0, 0]))))
              == "ff 5a 00 16 40 32 1b 03 01 00 01 13 a0 05 00 00 01 00 00 e1 06 5f", "EA request packet");

        // EA reply → ACK + eaData (EA session id stripped); retransmission → ACK only
        var reply = new LinkPacket(A, 0x1c, 0x32, 3, [0x00, 0x01, .. Bytes("13 a0 06 00 00 01 00 00 02 00 00")]).Encode();
        Events(s.Receive(reply), "EA reply", Send("ff 5a 00 09 40 32 1c 00 10"), "ea 13 a0 06 00 00 01 00 00 02 00 00");
        Events(s.Receive(reply), "duplicate only re-ACKed", Send("ff 5a 00 09 40 32 1c 00 10"));

        // Accessory reset
        Events(s.Receive(new LinkPacket(LinkPacket.RST, 0, 0, 0).Encode()), "RST", "reset");
        Check(!s.LinkUp && !s.EaOpen, "state cleared on RST");

        // A stale protocol id from before the RST must not make a non-carbonite identification ready
        var afterRst = s.Receive(new LinkPacket(A, 0x1d, 0x33, 1, Wire.ControlMsg(0x1D01, Ident(false))).Encode());
        Check(!afterRst.Any(e => e is Iap2Event.Ready) && !s.EaOpen, "RST clears the protocol id: no ready without carbonite");
        Check(SentPayloads(afterRst).Contains("40 40 00 06 1d 02"), "1D02 sent after RST re-identification");

        // Identification without our protocol → accepted, but never ready
        var t = new Iap2Session { Random = () => 0 };
        t.Receive(Fixtures.Syn);
        t.Receive(new LinkPacket(A, 0x18, 0x2b, 0).Encode());
        var ev = t.Receive(new LinkPacket(A, 0x19, 0x2c, 1, Wire.ControlMsg(0x1D01, Ident(false))).Encode());
        Check(!ev.Any(e => e is Iap2Event.Ready) && !t.EaOpen, "no ready without carbonite protocol");
        Check(SentPayloads(ev).Contains("40 40 00 06 1d 02"), "1D02 still sent without carbonite protocol");

        Resync();
    }

    /// A mid-session SYN restarts the link: SYN+ACK, a fresh AA00 after link-up, and EA stays closed
    /// until a new identification.
    static void Resync()
    {
        var s = new Iap2Session { Random = () => 0 };
        s.Receive(Fixtures.Syn);
        s.Receive(new LinkPacket(A, 0x18, 0x2b, 0).Encode());
        s.Receive(new LinkPacket(A, 0x19, 0x2c, 1, Wire.ControlMsg(0x1D01, Ident(true))).Encode());
        Check(s.EaOpen, "first session reaches eaOpen");

        var again = s.Receive(Fixtures.Syn);
        if (again.FirstOrDefault() is not Iap2Event.Send sa || Wire.Hex(sa.Bytes[..5]) != "ff 5a 00 1a c0")
        {
            Check(false, "SYN+ACK sent on re-sync");
            return;
        }
        Check(!s.LinkUp && !s.EaOpen, "SYN clears link and EA state");

        var linkUp = s.Receive(new LinkPacket(A, 0x18, sa.Bytes[5], 0).Encode());
        Check(SentPayloads(linkUp).Any(p => p.StartsWith("40 40 00 06 aa 00")), "re-sync re-sends AA00");
        Check(!s.EaOpen, "eaOpen false until re-identification");

        var plain = s.Receive(new LinkPacket(A, 0x1a, 0x33, 1, Wire.ControlMsg(0x1D01, Ident(false))).Encode());
        Check(!plain.Any(e => e is Iap2Event.Ready), "re-sync clears the protocol id");

        var reid = s.Receive(new LinkPacket(A, 0x1b, 0x34, 1, Wire.ControlMsg(0x1D01, Ident(true))).Encode());
        Check(reid.Any(e => e is Iap2Event.Ready) && s.EaOpen, "re-identification reopens EA");
    }
}
```

Add `Iap2Tests.Run();` to `Program.cs` after `FramingTests.Run();`.

- [ ] **Step 2: Run to verify it fails**

Run: `A30Control.Windows/selftest.sh`
Expected: build error `The type or namespace name 'Iap2Session' could not be found`.

- [ ] **Step 3: Implement `A30Kit/Iap2Session.cs`** (port of `IAP2Session.swift`)

```csharp
// Apple-device side of iAP2 toward the A30: detect, link sync, authentication (the accessory
// certificate is accepted without verification: we are not Apple), identification, then one
// External Accessory session that carries CPP traffic. Pure state machine: bytes in, events out.
namespace A30Kit;

public abstract record Iap2Event
{
    /// Write these bytes to the transport.
    public sealed record Send(byte[] Bytes) : Iap2Event { public override string ToString() => "send " + Wire.Hex(Bytes); }
    /// EA session started; CPP traffic may flow.
    public sealed record Ready : Iap2Event { public override string ToString() => "ready"; }
    /// Bytes the accessory sent on the EA session (EA session id stripped).
    public sealed record EaData(byte[] Bytes) : Iap2Event { public override string ToString() => "ea " + Wire.Hex(Bytes); }
    /// The accessory reset the link.
    public sealed record Reset : Iap2Event { public override string ToString() => "reset"; }
    public sealed record Log(string Text) : Iap2Event { public override string ToString() => "log " + Text; }
}

public sealed class Iap2Session
{
    public const string ProtocolName = "com.logitech.ag.carbonite";
    const int EaSessionId = 1;

    public bool LinkUp { get; private set; }
    public bool EaOpen { get; private set; }
    /// Top-level string params of IdentificationInformation (0 name, 2 maker, 3 serial, 4 fw…).
    public Dictionary<int, string> Identity { get; private set; } = new();
    /// Challenge byte source; tests replace it for deterministic output.
    public Func<byte> Random { get; set; } = () => (byte)System.Random.Shared.Next(256);

    readonly Iap2Splitter splitter = new();
    ControlParser control = new();
    byte txSeq = 0x2B, rxSeq;
    byte? lastRx;
    byte ctrlSession = 1, eaSession = 3;
    byte? eaProtocolId;

    public List<Iap2Event> Receive(byte[] bytes)
    {
        var o = new List<Iap2Event>();
        foreach (var f in splitter.Feed(bytes))
        {
            if (f is Iap2Frame.Detect && !LinkUp) o.Add(new Iap2Event.Send(Wire.Iap2Detect));
            else if (f is Iap2Frame.Packet p) o.AddRange(Link(p.P));
        }
        return o;
    }

    /// Link packet carrying `data` on the EA session, prefixed with our EA session id.
    public byte[] EaPacket(byte[] data)
    {
        txSeq++;
        return new LinkPacket(LinkPacket.ACK, txSeq, rxSeq, eaSession, [.. Wire.Be16(EaSessionId), .. data]).Encode();
    }

    List<Iap2Event> Link(LinkPacket p)
    {
        if ((p.Control & LinkPacket.RST) != 0)
        {
            ResetHandshake();
            return [new Iap2Event.Reset()];
        }
        if ((p.Control & LinkPacket.SYN) != 0)
        {
            // A SYN always starts a fresh link: forget everything from any earlier one.
            ResetHandshake();
            // payload: ver maxOut maxLen(2) rtx(2) cumAck(2) maxRtx maxCum, then (id type ver)*
            for (int i = 10; i + 3 <= p.Payload.Length; i += 3)
            {
                if (p.Payload[i + 1] == 0) ctrlSession = p.Payload[i];
                if (p.Payload[i + 1] == 2) eaSession = p.Payload[i];
            }
            rxSeq = p.Seq;
            lastRx = p.Seq;
            return [new Iap2Event.Send(new LinkPacket(LinkPacket.SYN | LinkPacket.ACK, txSeq, rxSeq, 0, p.Payload).Encode())];
        }
        var o = new List<Iap2Event>();
        if (!LinkUp && (p.Control & LinkPacket.ACK) != 0 && p.Ack == txSeq)
        {
            LinkUp = true;
            o.Add(SendControl(0xAA00));   // RequestAuthenticationCertificate
        }
        if (p.Payload.Length == 0) return o;
        if (p.Seq == lastRx)   // retransmission: re-ACK with the current rxSeq only
        {
            o.Add(new Iap2Event.Send(new LinkPacket(LinkPacket.ACK, txSeq, rxSeq, 0).Encode()));
            return o;
        }
        rxSeq = p.Seq;
        lastRx = p.Seq;
        o.Add(new Iap2Event.Send(new LinkPacket(LinkPacket.ACK, txSeq, rxSeq, 0).Encode()));
        if (p.Session == ctrlSession)
            foreach (var m in control.Feed(p.Payload)) o.AddRange(Handle(m));
        else if (p.Session == eaSession && p.Payload.Length >= 2)
            o.Add(new Iap2Event.EaData(p.Payload[2..]));
        else
            o.Add(new Iap2Event.Log($"data on unknown session {p.Session}: {Wire.Hex(p.Payload)}"));
        return o;
    }

    /// Forgets handshake and session state. Keeps txSeq (it keeps counting), Random and the splitter.
    void ResetHandshake()
    {
        LinkUp = false;
        EaOpen = false;
        eaProtocolId = null;
        Identity = new();
        control = new();
        lastRx = null;
        ctrlSession = 1;
        eaSession = 3;
    }

    Iap2Event SendControl(int id, byte[]? prm = null)
    {
        txSeq++;
        return new Iap2Event.Send(new LinkPacket(LinkPacket.ACK, txSeq, rxSeq, ctrlSession, Wire.ControlMsg(id, prm)).Encode());
    }

    List<Iap2Event> Handle(ControlMessage m)
    {
        switch (m.Id)
        {
            case 0xAA01:   // AuthenticationCertificate: auth 2.0 certs are ~900 B (20-byte challenge), 3.0 ~600 B
            {
                int certLen = m.Params.Count > 0 ? m.Params[0].Data.Length : 0;
                var challenge = Enumerable.Range(0, certLen > 800 ? 20 : 32).Select(_ => Random()).ToArray();
                return [SendControl(0xAA02, Wire.IapParam(0, challenge))];
            }
            case 0xAA03:   // AuthenticationResponse (not verified) → AuthenticationSucceeded, StartIdentification
                return [SendControl(0xAA05), SendControl(0x1D00)];
            case 0x1D01:   // IdentificationInformation
                foreach (var p in m.Params)
                {
                    if (Wire.IapText(p.Data) is string s) { Identity[p.Id] = s; continue; }
                    var sub = Wire.ParseParams(p.Data);
                    var idp = sub?.FirstOrDefault(x => x.Id == 0);
                    var namep = sub?.FirstOrDefault(x => x.Id == 1);
                    if (idp == null || idp.Data.Length != 1 || namep == null || Wire.IapText(namep.Data) != ProtocolName) continue;
                    eaProtocolId = idp.Data[0];
                }
                if (eaProtocolId is not byte proto)
                    return [SendControl(0x1D02), new Iap2Event.Log($"accessory does not offer {ProtocolName}")];
                EaOpen = true;
                return [SendControl(0x1D02),   // IdentificationAccepted
                        SendControl(0xEA00, [.. Wire.IapParam(0, [proto]), .. Wire.IapParam(1, Wire.Be16(EaSessionId))]),
                        new Iap2Event.Ready()];
            default:
                return [new Iap2Event.Log($"control message 0x{m.Id:X4} ignored")];
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `A30Control.Windows/selftest.sh`
Expected: `selftest: all passed`

---

### Task 3: Codecs (feature ids, errors, typed values)

**Files:**
- Create: `A30Control.Windows/A30Kit/Codecs.cs`
- Create: `A30Control.Windows/A30Kit.SelfTest/CodecTests.cs`
- Modify: `A30Control.Windows/A30Kit.SelfTest/Program.cs` (add `CodecTests.Run();` after `Iap2Tests.Run();`)

**Interfaces:**
- Produces: `enum FeatureId : ushort`, `enum CenturionError : byte`, `enum A30ErrorKind`, `class A30Exception(Kind, DeviceError)`, `enum ChargingState`, `record Battery(int Percent, int User, ChargingState? Charging)` + `Parse` + `IsCharging`, `enum EqMode : byte`, `record EqSetting(byte Mode, int[] Bands)` + `Parse`, `ToWire()`, `Same()`, `BandLabels`, `MinGain/MaxGain`, `enum Mic : byte { Internal, Boom }`, `enum NoiseGate`, `enum Tones`, `enum SleepTimer`, `record struct DongleStatus(Connected, XboxMode, HostType)` + `From(byte)`, `static class Labels` (`.Label()` extensions), `static class Codec { ParseFeatureList, ParseMicValues, ParseLengthString, ParseName, ParseFirmware, LengthPrefixed }`.

- [ ] **Step 1: Write the failing test** — `A30Kit.SelfTest/CodecTests.cs` (port of `CodecTests.swift`)

```csharp
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
```

Add `CodecTests.Run();` to `Program.cs`.

- [ ] **Step 2: Run to verify it fails**

Run: `A30Control.Windows/selftest.sh`
Expected: build error `The type or namespace name 'Battery' could not be found`.

- [ ] **Step 3: Implement `A30Kit/Codecs.cs`** (port of `Codecs.swift`)

```csharp
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `A30Control.Windows/selftest.sh`
Expected: `selftest: all passed`

---

### Task 4: HeadsetLink (iAP2 / raw SPP auto-detect, request queue) and A30Client (typed API)

**Files:**
- Create: `A30Control.Windows/A30Kit/ITransport.cs`, `A30Control.Windows/A30Kit/HeadsetLink.cs`, `A30Control.Windows/A30Kit/A30Client.cs`
- Create: `A30Control.Windows/A30Kit.SelfTest/FakeHeadset.cs`, `A30Control.Windows/A30Kit.SelfTest/LinkTests.cs`
- Modify: `A30Control.Windows/A30Kit.SelfTest/Program.cs` (add `await LinkTests.Run();` after `CodecTests.Run();`)

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `interface ITransport { event Action<byte[]>? Received; event Action? Closed; void Start(); Task SendAsync(byte[] bytes); void Close(); }` — `Closed` fires only when the link drops by itself, not after `Close()`.
  - `sealed class HeadsetLink { enum LinkMode { Unknown, Raw, Iap2 }; TimeSpan ProbeTime/RequestTimeout/OpenTimeout { init; }; Action<string> Log; event Action? Closed; event Action<byte, byte, byte[]>? Notification; LinkMode Mode; bool IsReady; Task OpenAsync(ITransport); Task<byte[]> RequestAsync(byte index, byte function, byte[]? args = null); void Close(); }`
  - `sealed class A30Client { A30Client(HeadsetLink? link = null); HeadsetLink Link; Action<string> Log; event Action<FeatureId, byte, byte[]>? Notification; event Action? Closed; Task ConnectAsync(ITransport); void Disconnect(); bool Supports(FeatureId); reads: BatteryAsync, NameAsync, FirmwareAsync, SerialAsync, VolumeAsync → (int Level, bool? Muted), EqAsync, EqModesAsync → byte[], SidetoneAsync → Dictionary<Mic,int>, NoiseGateAsync → Dictionary<Mic,NoiseGate>, BalanceAsync → int, DongleAsync → DongleStatus, SleepAsync → SleepTimer, TonesAsync → Tones; writes: SetEqAsync(EqSetting, bool switching), SetSidetoneAsync(Mic,int), SetNoiseGateAsync(Mic,NoiseGate), SetAudioMutedAsync(bool), SetNameAsync(string), SetBaseStationXboxAsync(bool), SetVolumeAsync(int), SetBalanceAsync(int), SetSleepMinutesAsync(byte), SetSleepAsync(SleepTimer), SetTonesAsync(Tones), FactoryResetAsync(string serial) }`

- [ ] **Step 1: Write the failing tests**

`A30Kit.SelfTest/FakeHeadset.cs`:
```csharp
using A30Kit;

/// Scripted headset speaking raw SPP. OnRequest(index, function, swId, args) returns the chunks to
/// send back (delivered in order on a worker thread), or null to stay silent.
sealed class FakeHeadset : ITransport
{
    public event Action<byte[]>? Received;
    public event Action? Closed;
    public readonly List<byte[]> Sent = new();
    public bool IsClosed;
    public Func<byte, byte, byte, byte[], byte[][]?>? OnRequest;

    public void Start() { }

    public Task SendAsync(byte[] b)
    {
        lock (Sent) Sent.Add(b);
        // raw request frame: 13 A0 len | CPL idx fn|sw args | crc crc
        if (b.Length >= 8 && b[0] == 0x13 && OnRequest?.Invoke(b[4], (byte)(b[5] >> 4), (byte)(b[5] & 0x0F), b[6..^2]) is byte[][] chunks)
            _ = Task.Run(() => { foreach (var c in chunks) Received?.Invoke(c); });
        return Task.CompletedTask;
    }

    public void Push(byte[] b) => Received?.Invoke(b);
    public void Close() => IsClosed = true;
    public void Drop() => Closed?.Invoke();

    public static byte[] Reply(byte idx, byte fn, byte sw, params byte[] args) => Wire.SppWrap([0x00, idx, (byte)(fn << 4 | sw), .. args]);
    public static byte[] Error(byte idx, byte fn, byte sw, byte code) => Wire.SppWrap([0x00, 0xFF, idx, (byte)(fn << 4 | sw), code]);
}
```

`A30Kit.SelfTest/LinkTests.cs`:
```csharp
using A30Kit;
using static T;

static class LinkTests
{
    static HeadsetLink NewLink() => new()
    {
        ProbeTime = TimeSpan.FromMilliseconds(50),
        RequestTimeout = TimeSpan.FromMilliseconds(200),
        OpenTimeout = TimeSpan.FromMilliseconds(300),
    };

    static async Task<Exception?> Throws(Task t)
    {
        try { await t; return null; } catch (Exception e) { return e; }
    }

    static async Task<string> Wait(Task<string> t) => await Task.WhenAny(t, Task.Delay(2000)) == t ? t.Result : "timeout";

    public static async Task Run()
    {
        // Raw SPP (no iAP2 detect within the probe time), as the Android app talks to the headset
        var h = new FakeHeadset { OnRequest = (i, fn, sw, a) => i == 7 && fn == 0 ? [FakeHeadset.Reply(7, 0, sw, 0x1e, 0x00)] : null };
        var link = NewLink();
        await link.OpenAsync(h);
        Check(link.Mode == HeadsetLink.LinkMode.Raw && link.IsReady, "no detect → raw mode");
        Check(Same(await link.RequestAsync(7, 0), [0x1e, 0x00]), "raw request answered");

        // Review focus 3: a swID-0 report arriving first must not answer the pending request
        var note = new TaskCompletionSource<string>();
        link.Notification += (i, fn, a) => note.TrySetResult($"{i} {fn} {Wire.Hex(a)}");
        h.OnRequest = (i, fn, sw, a) => [FakeHeadset.Reply(7, 0, 0, 0x10, 0x00), FakeHeadset.Reply(i, fn, sw, 0x2a, 0x28, 0x00)];
        Check(Same(await link.RequestAsync(2, 0), [0x2a, 0x28, 0x00]), "notification does not answer the pending request");
        Check(await Wait(note.Task) == "7 0 10 00", "swID-0 report raised as notification");

        // Review focus 4: reply split into single bytes
        h.OnRequest = (i, fn, sw, a) => FakeHeadset.Reply(i, fn, sw, 1, 2, 3).Select(b => new[] { b }).ToArray();
        Check(Same(await link.RequestAsync(4, 0), [1, 2, 3]), "reply split into single bytes");

        // Error reply
        h.OnRequest = (i, fn, sw, a) => [FakeHeadset.Error(i, fn, sw, 8)];
        var err = await Throws(link.RequestAsync(10, 1, [5])) as A30Exception;
        Check(err is { Kind: A30ErrorKind.Device, DeviceError: CenturionError.NotConnected }, "error reply → NOT_CONNECTED");

        // Link drop fails the pending request and raises Closed
        h.OnRequest = (i, fn, sw, a) => null;
        var closed = new TaskCompletionSource<string>();
        link.Closed += () => closed.TrySetResult("closed");
        var pending = link.RequestAsync(7, 0);
        h.Drop();
        Check((await Throws(pending) as A30Exception)?.Kind == A30ErrorKind.Disconnected, "drop fails the pending request");
        Check(await Wait(closed.Task) == "closed", "drop raises Closed");

        // iAP2 detect → iAP2 mode, detect echoed; an unfinished handshake times out and closes
        var h2 = new FakeHeadset();
        var link2 = NewLink();
        var open2 = link2.OpenAsync(h2);
        h2.Push(Wire.Iap2Detect);
        var e2 = await Throws(open2) as A30Exception;
        Check(link2.Mode == HeadsetLink.LinkMode.Iap2, "detect → iAP2 mode");
        Check(h2.Sent.Any(b => b.SequenceEqual(Wire.Iap2Detect)), "detect echoed");
        Check(e2?.Kind == A30ErrorKind.Timeout && h2.IsClosed, "unfinished iAP2 handshake times out and closes");

        // Review focus 2: silent headset → connect fails with Timeout and closes the channel
        var h3 = new FakeHeadset();
        var e3 = await Throws(new A30Client(NewLink()).ConnectAsync(h3)) as A30Exception;
        Check(e3?.Kind == A30ErrorKind.Timeout && h3.IsClosed, "silent headset: connect times out, channel closed");

        // A30Client over the real feature map
        var args = Fixtures.FeatureListArgs();
        var h4 = new FakeHeadset
        {
            OnRequest = (i, fn, sw, a) => (i, fn) switch
            {
                (1, 1) => [FakeHeadset.Reply(1, 1, sw, args)],
                (2, 0) => [FakeHeadset.Reply(2, 0, sw, 0x2a, 0x28, 0x02)],
                (7, 1) => [FakeHeadset.Reply(7, 1, sw)],
                (11, 1) => [FakeHeadset.Reply(11, 1, sw)],
                _ => null,
            },
        };
        var c = new A30Client(NewLink());
        await c.ConnectAsync(h4);
        Check(c.Supports(FeatureId.Mix) && c.Supports(FeatureId.Eq), "feature map from the headset");
        var bat = await c.BatteryAsync();
        Check(bat is { Percent: 42, IsCharging: true }, "battery via feature index 2");
        await c.SetVolumeAsync(40);
        var vol = h4.Sent.Last();
        Check(vol[4] == 7 && vol[5] >> 4 == 1 && vol[6] == 31, "volume clamped to 31 on idx 7 fn 1");
        await c.SetBaseStationXboxAsync(true);
        var dongle = h4.Sent.Last();
        Check(dongle[4] == 11 && dongle[5] >> 4 == 1 && dongle[6] == 1, "base station Xbox = SET_CONFIG [1] on idx 11");
        var nf = new TaskCompletionSource<string>();
        c.Notification += (f, fn, a) => nf.TrySetResult($"{f} {Wire.Hex(a)}");
        h4.Push(FakeHeadset.Reply(7, 0, 0, 0x05, 0x01));
        Check(await Wait(nf.Task) == "Volume 05 01", "notification mapped to FeatureId");
        Check(DongleStatus.From(0x05).HostType && !DongleStatus.From(0x01).HostType, "base station mode reads bit 2 (host type)");
    }
}
```

Add `await LinkTests.Run();` to `Program.cs` after `CodecTests.Run();`.

- [ ] **Step 2: Run to verify it fails**

Run: `A30Control.Windows/selftest.sh`
Expected: build error `The type or namespace name 'ITransport' could not be found`.

- [ ] **Step 3: Implement `A30Kit/ITransport.cs`**

```csharp
namespace A30Kit;

/// A byte pipe to the headset's control channel (RFCOMM on Windows, a fake in the selftest).
public interface ITransport
{
    event Action<byte[]>? Received;
    /// The channel dropped by itself (not raised after Close()).
    event Action? Closed;
    /// Begin delivering Received; called after the link has subscribed.
    void Start();
    Task SendAsync(byte[] bytes);
    void Close();
}
```

- [ ] **Step 4: Implement `A30Kit/HeadsetLink.cs`** (port of `HeadsetLink.swift` minus IOBluetooth, plus transport detection)

```csharp
// One CPP request in flight over an ITransport. The A30 greets an Apple host with the iAP2 detect
// (it does toward a Mac); without it we send raw SPP frames, as the Android app does. Either way a
// late detect switches to iAP2. Every frame is logged in hex for remote debugging.
namespace A30Kit;

public sealed class HeadsetLink
{
    public enum LinkMode { Unknown, Raw, Iap2 }

    public TimeSpan ProbeTime { get; init; } = TimeSpan.FromMilliseconds(1500);
    public TimeSpan RequestTimeout { get; init; } = TimeSpan.FromMilliseconds(1500);
    public TimeSpan OpenTimeout { get; init; } = TimeSpan.FromSeconds(8);
    public Action<string> Log { get; set; } = _ => { };
    /// An established link dropped (not raised for Close()).
    public event Action? Closed;
    /// Device-initiated reports (swID 0): (feature index, function, args).
    public event Action<byte, byte, byte[]>? Notification;
    public LinkMode Mode { get; private set; }
    public bool IsReady { get; private set; }

    sealed class Pending(byte index, byte function, byte[] args)
    {
        public readonly byte Index = index, Function = function;
        public readonly byte[] Args = args;
        public byte SwId;
        public readonly TaskCompletionSource<byte[]> Tcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    readonly object gate = new();
    ITransport? transport;
    int generation;
    Iap2Session session = new();
    SppParser spp = new();
    CplReassembler cpl = new();
    TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    Task sendChain = Task.CompletedTask;
    readonly Queue<Pending> queue = new();
    Pending? current;
    int consecutiveTimeouts;
    byte sw;

    public async Task OpenAsync(ITransport t)
    {
        Close();
        int gen;
        Task readyTask;
        lock (gate)
        {
            gen = ++generation;
            transport = t;
            session = new();
            spp = new();
            cpl = new();
            consecutiveTimeouts = 0;
            Mode = LinkMode.Unknown;
            IsReady = false;
            ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
            readyTask = ready.Task;
        }
        t.Received += b => { if (IsCurrent(gen)) OnReceived(b); };
        t.Closed += () =>
        {
            if (!IsCurrent(gen)) return;
            Log("transport closed");
            Teardown(new A30Exception(A30ErrorKind.Disconnected), notify: true);
        };
        t.Start();

        await Task.Delay(ProbeTime);
        lock (gate)
        {
            if (gen == generation && transport != null && Mode == LinkMode.Unknown)
            {
                Mode = LinkMode.Raw;
                IsReady = true;
                ready.TrySetResult();
                Log("no iAP2 detect: using raw SPP frames");
            }
        }
        if (await Task.WhenAny(readyTask, Task.Delay(OpenTimeout)) != readyTask)
        {
            Log("open timed out (iAP2 handshake did not finish)");
            Close();
            throw new A30Exception(A30ErrorKind.Timeout);
        }
        await readyTask;   // rethrows a teardown failure
    }

    public Task<byte[]> RequestAsync(byte index, byte function, byte[]? args = null)
    {
        lock (gate)
        {
            if (transport == null) return Task.FromException<byte[]>(new A30Exception(A30ErrorKind.Disconnected));
            var p = new Pending(index, function, args ?? []);
            queue.Enqueue(p);
            Pump();
            return p.Tcs.Task;
        }
    }

    public void Close()
    {
        ITransport? t;
        lock (gate) t = transport;
        t?.Close();
        Teardown(new A30Exception(A30ErrorKind.Disconnected), notify: false);
    }

    bool IsCurrent(int gen)
    {
        lock (gate) return gen == generation && transport != null;
    }

    void OnReceived(byte[] bytes)
    {
        var notes = new List<(byte Index, byte Function, byte[] Args)>();
        bool reset = false;
        lock (gate)
        {
            Log("rx " + Wire.Hex(bytes));
            var events = session.Receive(bytes);
            bool detect = events.Any(e => e is Iap2Event.Send s && s.Bytes.SequenceEqual(Wire.Iap2Detect));
            if (detect && Mode != LinkMode.Iap2)
            {
                Log(Mode == LinkMode.Raw ? "iAP2 detect after raw start: switching to iAP2" : "iAP2 detect: using iAP2");
                Mode = LinkMode.Iap2;
                IsReady = false;
            }
            if (Mode == LinkMode.Iap2)
            {
                foreach (var e in events)
                {
                    switch (e)
                    {
                        case Iap2Event.Send s: Write(s.Bytes); break;
                        case Iap2Event.Log l: Log(l.Text); break;
                        case Iap2Event.Ready: _ = BecomeReady(generation); break;
                        case Iap2Event.EaData d: Parse(d.Bytes, notes); break;
                        case Iap2Event.Reset: Log("iAP2 reset by accessory"); reset = true; break;
                    }
                }
            }
            else Parse(bytes, notes);   // raw SPP frames, and anything sent before the mode is known
        }
        foreach (var n in notes) Notification?.Invoke(n.Index, n.Function, n.Args);
        if (reset) Drop();
    }

    async Task BecomeReady(int gen)
    {
        await Task.Delay(300);   // the accessory needs a moment after EA00 before CPP traffic
        lock (gate)
        {
            if (gen != generation || transport == null) return;
            IsReady = true;
            ready.TrySetResult();
            Pump();
        }
    }

    /// Under gate. SPP frames → CPL → CPP replies: notifications out, the matching reply to `current`.
    void Parse(byte[] bytes, List<(byte, byte, byte[])> notes)
    {
        foreach (var payload in spp.Feed(bytes))
        {
            if (cpl.Feed(payload) is not byte[] m || CppReply.Parse(m) is not CppReply r) continue;
            // swID 0 is never used for requests, so these are always device-initiated notifications.
            if (!r.IsError && r.SwId == 0) { notes.Add((r.Index, r.Function, r.Args)); continue; }
            if (current is not Pending p) { Log($"unsolicited {r}"); continue; }
            if (r.Index != p.Index || r.SwId != p.SwId) { Log($"unmatched {r}"); continue; }
            current = null;
            consecutiveTimeouts = 0;
            if (r.IsError)
            {
                var code = Enum.IsDefined((CenturionError)r.Code) ? (CenturionError)r.Code : CenturionError.Failed;
                p.Tcs.TrySetException(new A30Exception(A30ErrorKind.Device, code));
            }
            else p.Tcs.TrySetResult(r.Args);
            Pump();
        }
    }

    /// Under gate. Sends stay in order.
    void Write(byte[] b)
    {
        var t = transport;
        if (t == null) return;
        Log("tx " + Wire.Hex(b));
        sendChain = sendChain.ContinueWith(_ => t.SendAsync(b)).Unwrap()
            .ContinueWith(x => { if (x.IsFaulted) Log("write failed: " + x.Exception?.GetBaseException().Message); });
    }

    /// Under gate. One request in flight; swId 1…15 (0 marks device notifications).
    void Pump()
    {
        if (current != null || !IsReady || queue.Count == 0) return;
        var p = queue.Dequeue();
        sw = (byte)(sw % 15 + 1);
        p.SwId = sw;
        current = p;
        var frame = Wire.SppWrap(Wire.CppRequest(p.Index, p.Function, p.SwId, p.Args));
        Write(Mode == LinkMode.Iap2 ? session.EaPacket(frame) : frame);
        _ = Task.Delay(RequestTimeout).ContinueWith(_ => OnTimeout(p));
    }

    void OnTimeout(Pending p)
    {
        bool drop = false;
        lock (gate)
        {
            if (current != p) return;
            consecutiveTimeouts++;
            Log($"timeout idx={p.Index} fn={p.Function}");
            if (consecutiveTimeouts >= 3) drop = true;
            else
            {
                current = null;
                p.Tcs.TrySetException(new A30Exception(A30ErrorKind.Timeout));
                Pump();
            }
        }
        if (drop) Drop();
    }

    /// The link is unusable: close the transport and report the drop.
    void Drop()
    {
        ITransport? t;
        lock (gate) t = transport;
        t?.Close();
        Teardown(new A30Exception(A30ErrorKind.Disconnected), notify: true);
    }

    /// Fails everything in flight. `notify` reports a drop of an established link to Closed.
    void Teardown(Exception e, bool notify)
    {
        bool wasReady;
        lock (gate)
        {
            wasReady = IsReady && transport != null;
            IsReady = false;
            transport = null;
            ready.TrySetException(e);
            current?.Tcs.TrySetException(e);
            current = null;
            while (queue.Count > 0) queue.Dequeue().Tcs.TrySetException(e);
        }
        if (notify && wasReady) Closed?.Invoke();
    }
}
```

- [ ] **Step 5: Implement `A30Kit/A30Client.cs`** (port of `A30.swift`)

```csharp
// Typed API for the A30. Feature indexes come from the headset's own feature list at connect,
// never from constants, so a firmware that reorders features still works.
namespace A30Kit;

public sealed class A30Client
{
    readonly Dictionary<ushort, byte> index = new();

    public A30Client(HeadsetLink? link = null)
    {
        Link = link ?? new HeadsetLink();
        Link.Notification += (i, fn, a) =>
        {
            foreach (var kv in index)
                if (kv.Value == i && Enum.IsDefined((FeatureId)kv.Key)) { Notification?.Invoke((FeatureId)kv.Key, fn, a); return; }
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
        index.Clear();
        await Link.OpenAsync(t);
        byte[] list;
        try { list = await Link.RequestAsync(1, 1, [0]); }   // iFeatureSet (always idx 1) GET_FEATURE_ID(0)
        catch { Link.Close(); throw; }
        var ids = Codec.ParseFeatureList(list);
        for (int i = 0; i < ids.Count; i++) index[ids[i]] = (byte)i;
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
```

- [ ] **Step 6: Run to verify it passes**

Run: `A30Control.Windows/selftest.sh`
Expected: `selftest: all passed`

---

### Task 5: Windows app shell, transport, model and tray

**Files:**
- Create: `A30Control.Windows/A30Control/A30Control.csproj`
- Create: `A30Control.Windows/icons.sh`, `A30Control.Windows/Tools/mkico.py`, `A30Control.Windows/build.sh`, `A30Control.Windows/build.ps1`
- Create: `A30Control.Windows/A30Control/Log.cs`, `Store.cs`, `WindowsIntegration.cs`, `RfcommTransport.cs`, `Choice.cs`, `HeadsetModel.cs`, `TrayIcon.cs`, `Theme.xaml`, `TrayPanel.xaml`, `TrayPanel.xaml.cs`, `App.xaml`, `App.xaml.cs`
- Generated by `icons.sh`: `A30Control.Windows/A30Control/Assets/app.ico`, `tray.png`, `logo.png`

**Interfaces:**
- Consumes: `A30Client` and the A30Kit types (Task 4).
- Produces: `HeadsetModel : INotifyPropertyChanged` with every binding listed in its code below (Task 6 binds to them); `Choice(Label, Selected, Apply, Remove?)` with `ApplyCmd`, `RemoveCmd`, `RemoveVisibility`; `AppRuleRow`; `App.Quitting`; styles/templates in `Theme.xaml`: brushes `Bg Panel Line Control Accent Text Muted Dim`, styles `Caps Hint Plain CCButton TrayCard TrayIcon TrayLabel TrayButton`, templates `ChoiceRow Pill Tab`.

- [ ] **Step 1: Project file and scripts**

`A30Control.Windows/A30Control/A30Control.csproj`:
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net8.0-windows10.0.19041.0</TargetFramework>
    <SupportedOSPlatformVersion>10.0.19041.0</SupportedOSPlatformVersion>
    <UseWPF>true</UseWPF>
    <UseWindowsForms>true</UseWindowsForms>
    <EnableWindowsTargeting>true</EnableWindowsTargeting>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <AssemblyName>A30Control</AssemblyName>
    <RootNamespace>A30Control</RootNamespace>
    <ApplicationIcon>Assets\app.ico</ApplicationIcon>
    <Version>1.0.0</Version>
  </PropertyGroup>
  <ItemGroup>
    <!-- WPF and WinForms both define Application, Button, Color…: WinForms is only used fully qualified. -->
    <Using Remove="System.Windows.Forms" />
    <Using Remove="System.Drawing" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\A30Kit\A30Kit.csproj" />
    <Resource Include="Assets\tray.png" />
    <Resource Include="Assets\logo.png" />
  </ItemGroup>
</Project>
```

`A30Control.Windows/Tools/mkico.py`:
```python
# Packs PNG files into one .ico (PNG-compressed entries, Windows Vista+). Usage: mkico.py out.ico a.png b.png ...
import struct, sys

out, pngs = sys.argv[1], sys.argv[2:]
datas = [open(p, 'rb').read() for p in pngs]
offset = 6 + 16 * len(datas)
entries = b''
for d in datas:
    w, h = struct.unpack('>II', d[16:24])   # IHDR width/height
    entries += struct.pack('<BBBBHHII', w % 256, h % 256, 0, 0, 1, 32, len(d), offset)
    offset += len(d)
open(out, 'wb').write(struct.pack('<HHH', 0, 1, len(datas)) + entries + b''.join(datas))
```

`A30Control.Windows/icons.sh`:
```sh
#!/bin/sh
# App icon, tray image and header logo from Doug's artwork, via the Mac app's prepicon tool.
set -e
cd "$(dirname "$0")"
C="$HOME/Library/Caches/A30Control.Windows/icons"
mkdir -p "$C" A30Control/Assets
cp ../A30Control/Tools/prepicon.swift ../A30Control/Assets/icon.png "$C/"   # snapshot outside iCloud
swiftc -O -o "$C/prepicon" "$C/prepicon.swift"
"$C/prepicon" "$C/icon.png" "$C"
for s in 16 24 32 48 256; do sips -z $s $s "$C/icon-1024.png" --out "$C/i$s.png" >/dev/null; done
python3 Tools/mkico.py A30Control/Assets/app.ico "$C/i16.png" "$C/i24.png" "$C/i32.png" "$C/i48.png" "$C/i256.png"
cp "$C/i32.png" A30Control/Assets/tray.png
cp "$C/logo.png" A30Control/Assets/logo.png
```

`A30Control.Windows/build.sh`:
```sh
#!/bin/sh
# Builds dist/A30Control.exe (Windows x64, self-contained, single file) on this Mac.
set -e
cd "$(dirname "$0")"
. ./env.sh
./icons.sh
rsync -a --delete --exclude dist --exclude bin --exclude obj ./ "$SNAP/"
dotnet run --project "$SNAP/A30Kit.SelfTest"
dotnet publish "$SNAP/A30Control/A30Control.csproj" -c Release -r win-x64 --self-contained \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o "$SNAP/../dist"
mkdir -p dist
cp "$SNAP/../dist/A30Control.exe" dist/
ls -lh dist/A30Control.exe
```

`A30Control.Windows/build.ps1`:
```powershell
# Same build on Windows (needs the .NET 8 SDK). Uses the icons already in A30Control/Assets.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
dotnet run --project A30Kit.SelfTest
dotnet publish A30Control/A30Control.csproj -c Release -r win-x64 --self-contained `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o dist
```

```bash
cd A30Control.Windows && chmod +x icons.sh build.sh && ./icons.sh && ls A30Control/Assets
. ./env.sh && dotnet sln add A30Control/A30Control.csproj
```
Expected: `app.ico logo.png tray.png`.

- [ ] **Step 2: Platform helpers**

`A30Control/Log.cs`:
```csharp
using System.IO;

namespace A30Control;

/// %APPDATA%\A30Control\a30.log, rotated at 1 MB — the file Doug sends back when something fails.
static class Log
{
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "A30Control");
    public static string FilePath => Path.Combine(Dir, "a30.log");
    static readonly object Gate = new();

    public static void Write(string s)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                var fi = new FileInfo(FilePath);
                if (fi.Exists && fi.Length > 1_000_000) File.Move(FilePath, FilePath + ".1", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {s}{Environment.NewLine}");
            }
            catch { }   // logging must never take the app down
        }
    }
}
```

`A30Control/Store.cs`:
```csharp
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
```

`A30Control/WindowsIntegration.cs`:
```csharp
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;

namespace A30Control;

/// "Start with Windows": HKCU\…\Run\A30Control.
static class Autostart
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool IsEnabled => Registry.CurrentUser.OpenSubKey(Key)?.GetValue("A30Control") is string;

    public static void Set(bool on)
    {
        using var k = Registry.CurrentUser.CreateSubKey(Key);
        if (on) k.SetValue("A30Control", $"\"{Environment.ProcessPath}\"");
        else k.DeleteValue("A30Control", throwOnMissingValue: false);
    }
}

/// Calls back with the process name of every newly focused window (EQ per app). Must be created on
/// the UI thread: out-of-context WinEvent hooks are delivered through its message loop.
sealed class ForegroundWatcher
{
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

    [DllImport("user32.dll")]
    static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint tid, uint flags);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    const uint EVENT_SYSTEM_FOREGROUND = 3;
    readonly WinEventProc proc;   // keeps the delegate alive for the hook

    public ForegroundWatcher(Action<string> onProcess)
    {
        proc = (_, _, hwnd, _, _, _, _) =>
        {
            GetWindowThreadProcessId(hwnd, out var pid);
            try { using var p = Process.GetProcessById((int)pid); onProcess(p.ProcessName); }
            catch { }
        };
        SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, proc, 0, 0, 0);
    }
}

static class Dark
{
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    /// Dark title bar (DWMWA_USE_IMMERSIVE_DARK_MODE = 20, Windows 10 2004+).
    public static void TitleBar(Window w)
    {
        int on = 1;
        DwmSetWindowAttribute(new WindowInteropHelper(w).Handle, 20, ref on, sizeof(int));
    }
}
```

`A30Control/RfcommTransport.cs`:
```csharp
using System.IO;
using A30Kit;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Devices.Enumeration;
using Windows.Networking.Sockets;

namespace A30Control;

/// The A30's control channel: the paired headset's Serial Port service (RFCOMM ch 26, UUID 0x1101).
sealed class RfcommTransport : ITransport
{
    public event Action<byte[]>? Received;
    public event Action? Closed;

    readonly StreamSocket socket;
    readonly Stream input, output;
    readonly CancellationTokenSource cts = new();

    RfcommTransport(StreamSocket s)
    {
        socket = s;
        input = s.InputStream.AsStreamForRead();
        output = s.OutputStream.AsStreamForWrite();
    }

    public static async Task<RfcommTransport> OpenAsync(Action<string> log)
    {
        var infos = await DeviceInformation.FindAllAsync(BluetoothDevice.GetDeviceSelectorFromPairingState(true));
        var info = infos.FirstOrDefault(i => i.Name.Contains("A30", StringComparison.OrdinalIgnoreCase))
                   ?? throw new A30Exception(A30ErrorKind.NotFound);
        using var dev = await BluetoothDevice.FromIdAsync(info.Id) ?? throw new A30Exception(A30ErrorKind.NotFound);
        // Opening RFCOMM on a disconnected headset pages it and brings the link up, overriding a manual
        // disconnect. Only attach to a headset Windows already has connected.
        if (dev.ConnectionStatus != BluetoothConnectionStatus.Connected) throw new A30Exception(A30ErrorKind.NotConnectedToHost);
        var res = await dev.GetRfcommServicesForIdAsync(RfcommServiceId.SerialPort, BluetoothCacheMode.Uncached);
        log($"{info.Name}: {res.Services.Count} serial port service(s), status {res.Error}");
        // ponytail: first Serial Port service; the A30 lists one (ch 26). Pick by SDP channel if a unit lists more.
        var svc = res.Services.FirstOrDefault() ?? throw new A30Exception(A30ErrorKind.OpenFailed, detail: res.Error.ToString());
        var s = new StreamSocket();
        try
        {
            await s.ConnectAsync(svc.ConnectionHostName, svc.ConnectionServiceName,
                                 SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication);
        }
        catch (Exception e)
        {
            s.Dispose();
            throw new A30Exception(A30ErrorKind.OpenFailed, detail: e.Message);
        }
        log($"RFCOMM open: {svc.ConnectionServiceName}");
        return new RfcommTransport(s);
    }

    public void Start() => _ = Task.Run(ReadLoop);

    async Task ReadLoop()
    {
        var buf = new byte[1024];
        try
        {
            while (true)
            {
                int n = await input.ReadAsync(buf, cts.Token);
                if (n <= 0) break;
                Received?.Invoke(buf[..n]);
            }
        }
        catch { }
        if (!cts.IsCancellationRequested) Closed?.Invoke();
    }

    public async Task SendAsync(byte[] bytes)
    {
        await output.WriteAsync(bytes);
        await output.FlushAsync();
    }

    public void Close()
    {
        cts.Cancel();
        socket.Dispose();
    }
}
```

`A30Control/Choice.cs`:
```csharp
using System.Windows;
using System.Windows.Input;

namespace A30Control;

sealed class Relay(Action action) : ICommand
{
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? p) => true;
    public void Execute(object? p) => action();
}

/// One selectable row/pill/tab: preset, mic, noise gate, sleep, tones, base mode, saved curve, profile.
public sealed class Choice(string label, bool selected, Action apply, Action? remove = null)
{
    public string Label { get; } = label;
    public bool Selected { get; } = selected;
    public ICommand ApplyCmd { get; } = new Relay(apply);
    public ICommand? RemoveCmd { get; } = remove == null ? null : new Relay(remove);
    public Visibility RemoveVisibility => RemoveCmd == null ? Visibility.Collapsed : Visibility.Visible;
}
```

- [ ] **Step 3: `A30Control/HeadsetModel.cs`** (port of `HeadsetModel.swift` + `Extras.swift` logic)

```csharp
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

    // turn off
    public int? PowerOffRemaining { get; private set; }
    public Visibility PowerOffVisibility => Vis(PowerOffRemaining != null);
    public Visibility TurnOffRowVisibility => Vis(PowerOffRemaining == null);
    public string PowerOffText => $"Turning off in {PowerOffRemaining}s";

    // ================= connection

    bool connecting;
    DateTime? suspendReconnectUntil;
    CancellationTokenSource? poll;

    public void Start() => Reconnect();

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
                    var t = await RfcommTransport.OpenAsync(Log.Write);
                    await a30.ConnectAsync(t);
                    Log.Write($"connected ({a30.Link.Mode})");
                    connected = true;
                    status = "Connected";
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
            if (!connected) return;
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
            default:
                return;
        }
        Changed();
    }

    // ================= writes: every SET is followed by a GET; the UI shows what the headset reports

    async Task Write(Func<Task> op, Func<Task> reread)
    {
        try { await op(); } catch (Exception e) { Show(e.Message); }
        try { await reread(); } catch { }
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
```

- [ ] **Step 4: Theme, tray icon, tray panel, App**

`A30Control/Theme.xaml`:
```xml
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="Bg" Color="#0E0E0E"/>
  <SolidColorBrush x:Key="Panel" Color="#171717"/>
  <SolidColorBrush x:Key="Line" Color="#2B2B2B"/>
  <SolidColorBrush x:Key="Control" Color="#222222"/>
  <SolidColorBrush x:Key="Accent" Color="#FF4B1F"/>
  <SolidColorBrush x:Key="Text" Color="#F2F2F2"/>
  <SolidColorBrush x:Key="Muted" Color="#A0A0A0"/>
  <SolidColorBrush x:Key="Dim" Color="#707070"/>

  <Style x:Key="Caps" TargetType="TextBlock">
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Foreground" Value="#D0D0D0"/>
  </Style>
  <Style x:Key="Hint" TargetType="TextBlock">
    <Setter Property="FontSize" Value="11"/>
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>

  <!-- No chrome: the whole content area is clickable. -->
  <Style x:Key="Plain" TargetType="Button">
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border Background="Transparent">
            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="CCButton" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{StaticResource Control}" BorderBrush="#333333" BorderThickness="1" Padding="14,9">
            <ContentPresenter HorizontalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2C2C2C"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- Selectable list row with a hairline underneath; optional ✕ to remove. -->
  <DataTemplate x:Key="ChoiceRow">
    <Border BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1">
      <Grid>
        <Button Command="{Binding ApplyCmd}" Style="{StaticResource Plain}" HorizontalContentAlignment="Stretch">
          <TextBlock x:Name="t" Text="{Binding Label}" Margin="8,11" FontSize="13" Foreground="{StaticResource Text}"/>
        </Button>
        <Button Command="{Binding RemoveCmd}" Style="{StaticResource Plain}" HorizontalAlignment="Right" Margin="0,0,8,0"
                Visibility="{Binding RemoveVisibility}" ToolTip="Remove">
          <TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Muted}"/>
        </Button>
      </Grid>
    </Border>
    <DataTemplate.Triggers>
      <DataTrigger Binding="{Binding Selected}" Value="True">
        <Setter TargetName="t" Property="Foreground" Value="{StaticResource Accent}"/>
        <Setter TargetName="t" Property="FontWeight" Value="SemiBold"/>
      </DataTrigger>
    </DataTemplate.Triggers>
  </DataTemplate>

  <!-- Tray EQ preset pill: orange when selected. -->
  <DataTemplate x:Key="Pill">
    <Button Command="{Binding ApplyCmd}" Style="{StaticResource Plain}" HorizontalContentAlignment="Stretch" Margin="3">
      <Border x:Name="b" CornerRadius="6" Background="#2E2E2E" Padding="0,5">
        <TextBlock x:Name="t" Text="{Binding Label}" HorizontalAlignment="Center" FontSize="12" Foreground="{StaticResource Text}"/>
      </Border>
    </Button>
    <DataTemplate.Triggers>
      <DataTrigger Binding="{Binding Selected}" Value="True">
        <Setter TargetName="b" Property="Background" Value="{StaticResource Accent}"/>
        <Setter TargetName="t" Property="FontWeight" Value="SemiBold"/>
      </DataTrigger>
    </DataTemplate.Triggers>
  </DataTemplate>

  <!-- Window tab: accent when selected. -->
  <DataTemplate x:Key="Tab">
    <Button Command="{Binding ApplyCmd}" Style="{StaticResource Plain}" Margin="10,0">
      <TextBlock x:Name="t" Text="{Binding Label}" FontWeight="SemiBold" FontSize="12" Foreground="#D9D9D9"/>
    </Button>
    <DataTemplate.Triggers>
      <DataTrigger Binding="{Binding Selected}" Value="True">
        <Setter TargetName="t" Property="Foreground" Value="{StaticResource Accent}"/>
      </DataTrigger>
    </DataTemplate.Triggers>
  </DataTemplate>

  <Style x:Key="TrayCard" TargetType="Border">
    <Setter Property="Background" Value="#262626"/>
    <Setter Property="BorderBrush" Value="#333333"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="10"/>
    <Setter Property="Padding" Value="12"/>
  </Style>
  <Style x:Key="TrayIcon" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="Width" Value="26"/>
    <Setter Property="Margin" Value="0,1,0,0"/>
    <Setter Property="VerticalAlignment" Value="Top"/>
    <Setter Property="Foreground" Value="{StaticResource Muted}"/>
  </Style>
  <Style x:Key="TrayLabel" TargetType="TextBlock">
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    <Setter Property="Margin" Value="0,0,0,6"/>
  </Style>
  <Style x:Key="TrayButton" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="#2A2A2A" BorderBrush="#3A3A3A" BorderThickness="1" CornerRadius="8" Padding="12,6">
            <ContentPresenter HorizontalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#333333"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
```

`A30Control/TrayIcon.cs`:
```csharp
using System.Drawing;
using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;

namespace A30Control;

/// Notification-area icon: Doug's artwork with status dots (green charging, red low battery,
/// orange mic muted), tooltip with name and battery, left click = panel, right click = menu.
sealed class TrayIcon : IDisposable
{
    readonly Forms.NotifyIcon icon = new();
    readonly HeadsetModel model;
    readonly Bitmap baseImage;
    string? badgeKey;

    public TrayIcon(HeadsetModel model, Action togglePanel, Action openWindow, Action quit)
    {
        this.model = model;
        using (var s = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/tray.png")).Stream)
        using (var tmp = new Bitmap(s))
            baseImage = new Bitmap(tmp);   // GDI+ needs the stream alive unless copied
        icon.MouseUp += (_, e) => { if (e.Button == Forms.MouseButtons.Left) togglePanel(); };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open window", null, (_, _) => openWindow());
        menu.Items.Add("Quit", null, (_, _) => quit());
        icon.ContextMenuStrip = menu;
        model.PropertyChanged += (_, _) => Refresh();
        Refresh();
        icon.Visible = true;
    }

    void Refresh()
    {
        var tip = model.TrayTooltip;
        icon.Text = tip.Length > 127 ? tip[..127] : tip;
        var (charging, low, mic) = model.Badges;
        var key = $"{charging}{low}{mic}";
        if (key == badgeKey) return;
        badgeKey = key;
        using var bmp = new Bitmap(baseImage);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            void Dot(Color c, int x, int y)
            {
                using var b = new SolidBrush(c);
                using var p = new Pen(Color.Black, 2);
                g.FillEllipse(b, x, y, 13, 13);
                g.DrawEllipse(p, x, y, 13, 13);
            }
            if (charging) Dot(Color.FromArgb(0x3C, 0xCF, 0x4E), 18, 18);
            else if (low) Dot(Color.FromArgb(0xFF, 0x3B, 0x30), 18, 18);
            if (mic) Dot(Color.FromArgb(0xFF, 0x9F, 0x0A), 18, 1);
        }
        var h = bmp.GetHicon();
        var old = icon.Icon;
        using (var tmp = Icon.FromHandle(h)) icon.Icon = (Icon)tmp.Clone();
        DestroyIcon(h);
        old?.Dispose();
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    public void Toast(string title, string body) => icon.ShowBalloonTip(5000, title, body, Forms.ToolTipIcon.None);

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}
```

`A30Control/TrayPanel.xaml` (card layout of the Mac tray panel):
```xml
<Window x:Class="A30Control.TrayPanel"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False"
        Topmost="True" ResizeMode="NoResize" SizeToContent="Height" Width="350"
        Foreground="{StaticResource Text}" FontFamily="Segoe UI" FontSize="13">
  <Border Background="#1E1E1E" BorderBrush="#383838" BorderThickness="1" CornerRadius="12" Padding="10">
    <StackPanel>
      <DockPanel Margin="4,2,4,10">
        <TextBlock DockPanel.Dock="Right" Text="{Binding BatteryText}"/>
        <TextBlock DockPanel.Dock="Right" Text="&#xE945;" FontFamily="Segoe MDL2 Assets" Margin="0,2,6,0" Visibility="{Binding ChargingVisibility}"/>
        <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="14"/>
      </DockPanel>

      <StackPanel Visibility="{Binding ConnectedVisibility}">
        <Border Style="{StaticResource TrayCard}">
          <StackPanel>
            <DockPanel>
              <TextBlock Text="&#xE767;" Style="{StaticResource TrayIcon}"/>
              <StackPanel>
                <TextBlock Text="Volume" Style="{StaticResource TrayLabel}"/>
                <DockPanel IsEnabled="{Binding HasVolume}">
                  <TextBlock DockPanel.Dock="Right" Text="{Binding VolumeText}" Width="40" TextAlignment="Right"/>
                  <Slider Minimum="0" Maximum="31" IsSnapToTickEnabled="True" TickFrequency="1" SmallChange="1" LargeChange="4" Value="{Binding VolumeValue}"/>
                </DockPanel>
              </StackPanel>
            </DockPanel>
            <DockPanel Margin="0,12,0,0">
              <TextBlock Text="&#xE9E9;" Style="{StaticResource TrayIcon}"/>
              <StackPanel>
                <TextBlock Text="Equalizer" Style="{StaticResource TrayLabel}"/>
                <ItemsControl ItemsSource="{Binding EqPills}" ItemTemplate="{StaticResource Pill}" Margin="-3,0">
                  <ItemsControl.ItemsPanel>
                    <ItemsPanelTemplate><UniformGrid Columns="3"/></ItemsPanelTemplate>
                  </ItemsControl.ItemsPanel>
                </ItemsControl>
              </StackPanel>
            </DockPanel>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource TrayCard}" Margin="0,10,0,0">
          <StackPanel>
            <DockPanel>
              <TextBlock Text="&#xE720;" Style="{StaticResource TrayIcon}"/>
              <StackPanel>
                <TextBlock Text="Sidetone" Style="{StaticResource TrayLabel}"/>
                <DockPanel IsEnabled="{Binding HasBoomSidetone}">
                  <TextBlock DockPanel.Dock="Right" Text="{Binding BoomSidetoneText}" Width="40" TextAlignment="Right"/>
                  <Slider Minimum="0" Maximum="100" IsSnapToTickEnabled="True" TickFrequency="1" SmallChange="1" LargeChange="10" Value="{Binding BoomSidetoneValue}"/>
                </DockPanel>
              </StackPanel>
            </DockPanel>
            <DockPanel Margin="0,12,0,0">
              <TextBlock Text="&#xE7FC;" Style="{StaticResource TrayIcon}"/>
              <StackPanel>
                <TextBlock Text="Game mix" Style="{StaticResource TrayLabel}"/>
                <DockPanel IsEnabled="{Binding CanBalance}">
                  <TextBlock DockPanel.Dock="Right" Text="{Binding BalanceText}" Width="40" TextAlignment="Right"/>
                  <Slider Minimum="0" Maximum="20" IsSnapToTickEnabled="True" TickFrequency="1" SmallChange="1" LargeChange="2" Value="{Binding BalanceValue}"/>
                </DockPanel>
                <TextBlock Text="Connect the 2.4 GHz dongle to mix game and chat." Style="{StaticResource Hint}" Margin="0,4,0,0" Visibility="{Binding NoDongleVisibility}"/>
              </StackPanel>
            </DockPanel>
            <Border Height="1" Background="#333333" Margin="0,12"/>
            <DockPanel Visibility="{Binding TurnOffRowVisibility}">
              <TextBlock Text="&#xE7E8;" Style="{StaticResource TrayIcon}"/>
              <Button DockPanel.Dock="Right" Content="Turn off" Style="{StaticResource TrayButton}" Click="TurnOff"/>
              <TextBlock Text="Turn off headset" VerticalAlignment="Center"/>
            </DockPanel>
          </StackPanel>
        </Border>
      </StackPanel>

      <Border Style="{StaticResource TrayCard}" Visibility="{Binding PowerOffVisibility}">
        <DockPanel>
          <TextBlock Text="&#xE7E8;" Style="{StaticResource TrayIcon}"/>
          <Button DockPanel.Dock="Right" Content="Cancel" Style="{StaticResource TrayButton}" Click="CancelTurnOff"/>
          <TextBlock Text="{Binding PowerOffText}" VerticalAlignment="Center"/>
        </DockPanel>
      </Border>

      <Border Style="{StaticResource TrayCard}" Visibility="{Binding DisconnectedVisibility}">
        <TextBlock Text="{Binding Status}" Foreground="{StaticResource Muted}" TextWrapping="Wrap" TextAlignment="Center"/>
      </Border>

      <TextBlock Text="{Binding Banner}" Foreground="#FFD54F" FontSize="11" Margin="4,8,4,0" TextWrapping="Wrap" Visibility="{Binding BannerVisibility}"/>

      <UniformGrid Columns="2" Margin="0,10,0,0">
        <Button Style="{StaticResource TrayButton}" Margin="0,0,5,0" Click="OpenWindow">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE8A7;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/>
            <TextBlock Text="Open window"/>
          </StackPanel>
        </Button>
        <Button Style="{StaticResource TrayButton}" Margin="5,0,0,0" Click="Quit">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/>
            <TextBlock Text="Quit"/>
          </StackPanel>
        </Button>
      </UniformGrid>
    </StackPanel>
  </Border>
</Window>
```

`A30Control/TrayPanel.xaml.cs`:
```csharp
using System.Windows;

namespace A30Control;

public partial class TrayPanel : Window
{
    readonly Action openWindow, quit;
    public DateTime HiddenAt { get; private set; }

    public TrayPanel(HeadsetModel model, Action openWindow, Action quit)
    {
        InitializeComponent();
        DataContext = model;
        this.openWindow = openWindow;
        this.quit = quit;
        // Clicking anywhere else closes the panel, like a flyout.
        Deactivated += (_, _) => { Hide(); HiddenAt = DateTime.Now; };
        SizeChanged += (_, _) => { if (IsVisible) PlaceNearTray(); };
    }

    public void ShowNearTray()
    {
        Show();
        UpdateLayout();
        PlaceNearTray();
        Activate();
    }

    /// Bottom-right corner of the work area (the desktop minus the taskbar), in WPF units.
    void PlaceNearTray()
    {
        var wa = SystemParameters.WorkArea;
        Left = wa.Right - ActualWidth - 12;
        Top = wa.Bottom - ActualHeight - 12;
    }

    HeadsetModel M => (HeadsetModel)DataContext;
    void TurnOff(object sender, RoutedEventArgs e) => M.TurnOff();
    void CancelTurnOff(object sender, RoutedEventArgs e) => M.CancelTurnOff();
    void OpenWindow(object sender, RoutedEventArgs e) { Hide(); openWindow(); }
    void Quit(object sender, RoutedEventArgs e) => quit();
}
```

`A30Control/App.xaml`:
```xml
<Application x:Class="A30Control.App"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             ShutdownMode="OnExplicitShutdown">
  <Application.Resources>
    <ResourceDictionary Source="Theme.xaml"/>
  </Application.Resources>
</Application>
```

`A30Control/App.xaml.cs` (`OpenWindow` gains the main window in Task 6):
```csharp
using System.Windows;

namespace A30Control;

public partial class App : Application
{
    public static bool Quitting { get; private set; }

    Mutex? single;
    HeadsetModel? model;
    TrayIcon? tray;
    TrayPanel? panel;
    ForegroundWatcher? foreground;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Only one client can hold the headset's control channel: a second copy exits at once.
        single = new Mutex(true, @"Local\A30Control", out bool first);
        if (!first) { Shutdown(); return; }
        DispatcherUnhandledException += (_, ex) => { Log.Write("unhandled: " + ex.Exception); ex.Handled = true; };
        Log.Write("A30 Control starting");
        model = new HeadsetModel();
        tray = new TrayIcon(model, TogglePanel, OpenWindow, Quit);
        model.Notify = tray.Toast;
        foreground = new ForegroundWatcher(model.AppActivated);
        model.Start();
    }

    void TogglePanel()
    {
        panel ??= new TrayPanel(model!, OpenWindow, Quit);
        if (panel.IsVisible) panel.Hide();
        // The click on the tray icon deactivates (hides) the panel first; don't reopen it right away.
        else if ((DateTime.Now - panel.HiddenAt).TotalMilliseconds > 300) panel.ShowNearTray();
    }

    void OpenWindow() => panel?.Hide();

    void Quit()
    {
        Quitting = true;
        model?.Shutdown();
        tray?.Dispose();
        Shutdown();
    }
}
```

- [ ] **Step 5: Build**

Run: `A30Control.Windows/build.sh`
Expected: `selftest: all passed`, then publish succeeds and `dist/A30Control.exe` is listed (~70 MB). If the WPF markup compiler refuses to run on macOS, stop and report: the fallback is `build.ps1` on Doug's PC.

---

### Task 6: Main window (Command Center) and tabs

**Files:**
- Create: `A30Control.Windows/A30Control/MainWindow.xaml`, `MainWindow.xaml.cs`, `AskWindow.cs`
- Create: `A30Control.Windows/A30Control/Views/EqView.xaml(.cs)`, `MicrophoneView.xaml(.cs)`, `MixView.xaml(.cs)`, `ExtrasView.xaml(.cs)`, `SettingsView.xaml(.cs)`
- Modify: `A30Control.Windows/A30Control/App.xaml.cs` (window field + `OpenWindow`)

**Interfaces:**
- Consumes: `HeadsetModel` bindings and methods (Task 5), `Theme.xaml` keys, `App.Quitting`, `Dark.TitleBar`.
- Produces: `AskWindow.Ask(Window? owner, string title, string initial = "", string? mustType = null) → string?`.

- [ ] **Step 1: `AskWindow.cs`** (name prompt and the typed-RESET confirmation)

```csharp
using System.Windows;
using System.Windows.Controls;

namespace A30Control;

static class AskWindow
{
    /// Text prompt. With `mustType`, the OK button stays disabled until exactly that text is typed.
    public static string? Ask(Window? owner, string title, string initial = "", string? mustType = null)
    {
        var box = new TextBox { Text = initial, Margin = new Thickness(0, 10, 0, 14), Padding = new Thickness(4) };
        var ok = new Button
        {
            Content = mustType == null ? "Save" : "Factory reset", IsDefault = true, Width = 110,
            Margin = new Thickness(0, 0, 8, 0), IsEnabled = mustType == null || initial == mustType,
        };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Width = 90 };
        if (mustType != null) box.TextChanged += (_, _) => ok.IsEnabled = box.Text == mustType;
        var w = new Window
        {
            Title = "A30 Control", Owner = owner, ShowInTaskbar = false,
            SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = owner == null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            Content = new StackPanel
            {
                Margin = new Thickness(18), Width = 340,
                Children =
                {
                    new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap },
                    box,
                    new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { ok, cancel } },
                },
            },
        };
        ok.Click += (_, _) => w.DialogResult = true;
        w.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        if (w.ShowDialog() != true) return null;
        var v = box.Text.Trim();
        return v.Length == 0 ? null : v;
    }
}
```

- [ ] **Step 2: `MainWindow.xaml` / `.cs`** — header (logo, "A30 / CONTROL", battery % and bolt; **no settings gear**, the SETTINGS tab covers it), device row with tabs, panel, overlays

```xml
<Window x:Class="A30Control.MainWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:v="clr-namespace:A30Control.Views"
        Title="A30 Control" Width="980" Height="660" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" Background="{StaticResource Bg}"
        Foreground="{StaticResource Text}" FontFamily="Segoe UI" FontSize="13">
  <Grid>
    <DockPanel>
      <DockPanel DockPanel.Dock="Top" Margin="20,14,20,12" LastChildFill="False">
        <Image Source="/Assets/logo.png" Height="26"/>
        <Border Width="1" Height="30" Background="#4D4D4D" Margin="12,0"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="A30" Style="{StaticResource Caps}" Foreground="{StaticResource Muted}"/>
          <TextBlock Text="CONTROL" Style="{StaticResource Caps}" Foreground="{StaticResource Muted}"/>
        </StackPanel>
        <TextBlock DockPanel.Dock="Right" Text="&#xE945;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Muted}"
                   VerticalAlignment="Center" Margin="6,0,0,0" Visibility="{Binding ChargingVisibility}"/>
        <TextBlock DockPanel.Dock="Right" Text="{Binding BatteryText}" Foreground="{StaticResource Muted}" VerticalAlignment="Center"/>
      </DockPanel>
      <Border DockPanel.Dock="Top" Height="1" Background="{StaticResource Line}"/>
      <DockPanel DockPanel.Dock="Top" Margin="20,16" LastChildFill="False">
        <TextBlock Text="&#xE7F6;" FontFamily="Segoe MDL2 Assets" FontSize="36" Foreground="#BFBFBF" Width="60" VerticalAlignment="Center"/>
        <StackPanel VerticalAlignment="Center" Margin="4,0,0,0">
          <TextBlock Text="{Binding NameUpper}" FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource Accent}"/>
          <TextBlock Text="{Binding DeviceLine}" FontSize="11" Foreground="#D9D9D9" Margin="0,4,0,0"/>
        </StackPanel>
        <ItemsControl DockPanel.Dock="Right" ItemsSource="{Binding Tabs}" ItemTemplate="{StaticResource Tab}" VerticalAlignment="Center">
          <ItemsControl.ItemsPanel>
            <ItemsPanelTemplate><StackPanel Orientation="Horizontal"/></ItemsPanelTemplate>
          </ItemsControl.ItemsPanel>
        </ItemsControl>
      </DockPanel>
      <Border Background="{StaticResource Panel}" Margin="14,0,14,14" Padding="18">
        <Grid>
          <v:EqView Visibility="{Binding EqualizerVisibility}"/>
          <v:MicrophoneView Visibility="{Binding MicrophoneVisibility}"/>
          <v:MixView Visibility="{Binding MixVisibility}"/>
          <v:ExtrasView Visibility="{Binding ExtrasVisibility}"/>
          <v:SettingsView Visibility="{Binding SettingsVisibility}"/>
          <Border VerticalAlignment="Bottom" HorizontalAlignment="Center" Background="#2B2B2B" Padding="14,8" CornerRadius="4"
                  Visibility="{Binding BannerVisibility}">
            <TextBlock Text="{Binding Banner}" Foreground="#FFD54F"/>
          </Border>
        </Grid>
      </Border>
    </DockPanel>

    <Border Background="#E60E0E0E" Visibility="{Binding DisconnectedVisibility}">
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
        <TextBlock Text="Looking for ASTRO A30…" FontSize="18" HorizontalAlignment="Center"/>
        <TextBlock Text="{Binding Status}" Foreground="{StaticResource Muted}" Margin="0,8,0,0" MaxWidth="520"
                   TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center"/>
      </StackPanel>
    </Border>
    <Border Background="#E60E0E0E" Visibility="{Binding PowerOffVisibility}">
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
        <TextBlock Text="{Binding PowerOffText}" FontSize="18" HorizontalAlignment="Center"/>
        <TextBlock Text="Keep audio paused so the headset can go idle." Foreground="{StaticResource Muted}" Margin="0,8,0,14" HorizontalAlignment="Center"/>
        <Button Content="CANCEL" Style="{StaticResource CCButton}" Click="CancelTurnOff" HorizontalAlignment="Center"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
```

```csharp
using System.ComponentModel;
using System.Windows;

namespace A30Control;

public partial class MainWindow : Window
{
    public MainWindow(HeadsetModel model)
    {
        InitializeComponent();
        DataContext = model;
        SourceInitialized += (_, _) => Dark.TitleBar(this);
    }

    void CancelTurnOff(object sender, RoutedEventArgs e) => ((HeadsetModel)DataContext).CancelTurnOff();

    /// Closing hides the window; the app stays in the tray (Quit is in the tray menu/panel).
    protected override void OnClosing(CancelEventArgs e)
    {
        if (!App.Quitting) { e.Cancel = true; Hide(); }
        base.OnClosing(e);
    }
}
```

- [ ] **Step 3: Tab views** (namespace `A30Control.Views`; each `.xaml.cs` is `public partial class X : UserControl { public X() => InitializeComponent(); … }` plus the handlers shown)

`Views/EqView.xaml`:
```xml
<UserControl x:Class="A30Control.Views.EqView"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="280"/><ColumnDefinition Width="24"/><ColumnDefinition/>
    </Grid.ColumnDefinitions>
    <DockPanel>
      <StackPanel DockPanel.Dock="Bottom" IsEnabled="{Binding IsCustom}" Margin="0,10,0,0">
        <UniformGrid Columns="2" Margin="0,0,0,8">
          <Button Content="REVERT" Style="{StaticResource CCButton}" Margin="0,0,5,0" Click="Revert"/>
          <Button Content="RESET FLAT" Style="{StaticResource CCButton}" Margin="5,0,0,0" Click="ResetFlat"/>
        </UniformGrid>
        <Button Content="SAVE CURVE AS" Style="{StaticResource CCButton}" Click="SaveCurve"/>
      </StackPanel>
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel>
          <TextBlock Text="PRESET LIBRARY" Style="{StaticResource Caps}" FontSize="14" Margin="0,0,0,12"/>
          <Border Height="1" Background="{StaticResource Line}"/>
          <ItemsControl ItemsSource="{Binding EqChoices}" ItemTemplate="{StaticResource ChoiceRow}"/>
          <StackPanel Visibility="{Binding SavedEqVisibility}">
            <TextBlock Text="SAVED CURVES" Style="{StaticResource Caps}" FontSize="11" Foreground="{StaticResource Dim}" Margin="0,14,0,6"/>
            <ItemsControl ItemsSource="{Binding SavedEqChoices}" ItemTemplate="{StaticResource ChoiceRow}"/>
          </StackPanel>
        </StackPanel>
      </ScrollViewer>
    </DockPanel>
    <Border Grid.Column="2" Background="#1C1C1C" Padding="16">
      <DockPanel>
        <TextBlock DockPanel.Dock="Bottom" Text="SELECT CUSTOM TO EDIT THE BANDS" Style="{StaticResource Caps}"
                   Foreground="{StaticResource Dim}" HorizontalAlignment="Center" Visibility="{Binding EditHintVisibility}"/>
        <UniformGrid Columns="5" IsEnabled="{Binding IsCustom}">
          <StackPanel>
            <TextBlock Text="{Binding Band0Text}" HorizontalAlignment="Center"/>
            <Slider Orientation="Vertical" Minimum="-12" Maximum="12" TickFrequency="1" IsSnapToTickEnabled="True"
                    SmallChange="1" LargeChange="3" Height="300" HorizontalAlignment="Center" Margin="0,8" Value="{Binding Band0}"/>
            <TextBlock Text="31 Hz" HorizontalAlignment="Center" FontSize="11" Foreground="{StaticResource Muted}"/>
          </StackPanel>
          <StackPanel>
            <TextBlock Text="{Binding Band1Text}" HorizontalAlignment="Center"/>
            <Slider Orientation="Vertical" Minimum="-12" Maximum="12" TickFrequency="1" IsSnapToTickEnabled="True"
                    SmallChange="1" LargeChange="3" Height="300" HorizontalAlignment="Center" Margin="0,8" Value="{Binding Band1}"/>
            <TextBlock Text="63 Hz" HorizontalAlignment="Center" FontSize="11" Foreground="{StaticResource Muted}"/>
          </StackPanel>
          <StackPanel>
            <TextBlock Text="{Binding Band2Text}" HorizontalAlignment="Center"/>
            <Slider Orientation="Vertical" Minimum="-12" Maximum="12" TickFrequency="1" IsSnapToTickEnabled="True"
                    SmallChange="1" LargeChange="3" Height="300" HorizontalAlignment="Center" Margin="0,8" Value="{Binding Band2}"/>
            <TextBlock Text="125 Hz" HorizontalAlignment="Center" FontSize="11" Foreground="{StaticResource Muted}"/>
          </StackPanel>
          <StackPanel>
            <TextBlock Text="{Binding Band3Text}" HorizontalAlignment="Center"/>
            <Slider Orientation="Vertical" Minimum="-12" Maximum="12" TickFrequency="1" IsSnapToTickEnabled="True"
                    SmallChange="1" LargeChange="3" Height="300" HorizontalAlignment="Center" Margin="0,8" Value="{Binding Band3}"/>
            <TextBlock Text="250 Hz" HorizontalAlignment="Center" FontSize="11" Foreground="{StaticResource Muted}"/>
          </StackPanel>
          <StackPanel>
            <TextBlock Text="{Binding Band4Text}" HorizontalAlignment="Center"/>
            <Slider Orientation="Vertical" Minimum="-12" Maximum="12" TickFrequency="1" IsSnapToTickEnabled="True"
                    SmallChange="1" LargeChange="3" Height="300" HorizontalAlignment="Center" Margin="0,8" Value="{Binding Band4}"/>
            <TextBlock Text="500 Hz" HorizontalAlignment="Center" FontSize="11" Foreground="{StaticResource Muted}"/>
          </StackPanel>
        </UniformGrid>
      </DockPanel>
    </Border>
  </Grid>
</UserControl>
```

`Views/EqView.xaml.cs`:
```csharp
using System.Windows;
using System.Windows.Controls;

namespace A30Control.Views;

public partial class EqView : UserControl
{
    public EqView() => InitializeComponent();
    HeadsetModel M => (HeadsetModel)DataContext;
    void Revert(object sender, RoutedEventArgs e) => M.RevertEq();
    void ResetFlat(object sender, RoutedEventArgs e) => M.ResetFlat();

    void SaveCurve(object sender, RoutedEventArgs e)
    {
        if (AskWindow.Ask(Window.GetWindow(this), "Save the Custom curve as") is string n) M.SaveCurrentEq(n);
    }
}
```

`Views/MicrophoneView.xaml`:
```xml
<UserControl x:Class="A30Control.Views.MicrophoneView"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="280"/><ColumnDefinition Width="24"/><ColumnDefinition/>
    </Grid.ColumnDefinitions>
    <StackPanel>
      <TextBlock Text="MICROPHONE" Style="{StaticResource Caps}" FontSize="14" Margin="0,0,0,12"/>
      <Border Height="1" Background="{StaticResource Line}"/>
      <ItemsControl ItemsSource="{Binding MicChoices}" ItemTemplate="{StaticResource ChoiceRow}"/>
    </StackPanel>
    <StackPanel Grid.Column="2">
      <TextBlock Text="SIDETONE" Style="{StaticResource Caps}"/>
      <DockPanel Margin="0,10" IsEnabled="{Binding HasSidetone}">
        <TextBlock DockPanel.Dock="Right" Text="{Binding SidetoneText}" Width="44" TextAlignment="Right"/>
        <Slider Minimum="0" Maximum="100" IsSnapToTickEnabled="True" TickFrequency="1" SmallChange="1" LargeChange="10" Value="{Binding SidetoneValue}"/>
      </DockPanel>
      <TextBlock Text="How much of your own voice you hear in the headset." Style="{StaticResource Hint}"/>
      <Border Height="1" Background="{StaticResource Line}" Margin="0,22"/>
      <TextBlock Text="NOISE GATE" Style="{StaticResource Caps}"/>
      <TextBlock Text="How loud you must speak before the microphone picks you up." Style="{StaticResource Hint}" Margin="0,4,0,8"/>
      <ItemsControl ItemsSource="{Binding NoiseGateChoices}" ItemTemplate="{StaticResource ChoiceRow}" IsEnabled="{Binding HasNoiseGate}"/>
    </StackPanel>
  </Grid>
</UserControl>
```
`Views/MicrophoneView.xaml.cs`: constructor only (`public MicrophoneView() => InitializeComponent();`).

`Views/MixView.xaml`:
```xml
<UserControl x:Class="A30Control.Views.MixView"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="280"/><ColumnDefinition Width="24"/><ColumnDefinition/>
    </Grid.ColumnDefinitions>
    <StackPanel>
      <TextBlock Text="MIX" Style="{StaticResource Caps}" FontSize="14" Margin="0,0,0,12"/>
      <Border Height="1" Background="{StaticResource Line}"/>
      <DockPanel Margin="8,11"><TextBlock Text="VOLUME" Style="{StaticResource Caps}"/><TextBlock Text="{Binding VolumeInfo}" HorizontalAlignment="Right"/></DockPanel>
      <Border Height="1" Background="{StaticResource Line}"/>
      <DockPanel Margin="8,11"><TextBlock Text="BALANCE" Style="{StaticResource Caps}"/><TextBlock Text="{Binding BalanceInfo}" HorizontalAlignment="Right"/></DockPanel>
      <Border Height="1" Background="{StaticResource Line}"/>
      <DockPanel Margin="8,11"><TextBlock Text="DONGLE" Style="{StaticResource Caps}"/><TextBlock Text="{Binding DongleText}" HorizontalAlignment="Right"/></DockPanel>
      <Border Height="1" Background="{StaticResource Line}"/>
    </StackPanel>
    <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <TextBlock Text="VOLUME" Style="{StaticResource Caps}"/>
        <DockPanel Margin="0,10" IsEnabled="{Binding HasVolume}">
          <TextBlock DockPanel.Dock="Right" Text="{Binding VolumeText}" Width="36" TextAlignment="Right"/>
          <Slider Minimum="0" Maximum="31" IsSnapToTickEnabled="True" TickFrequency="1" SmallChange="1" LargeChange="4" Value="{Binding VolumeValue}"/>
        </DockPanel>
        <CheckBox Content="Mute headset audio" IsChecked="{Binding AudioMutedValue}" IsEnabled="{Binding HasAudioMute}" Foreground="{StaticResource Text}"/>
        <TextBlock Text="Same 0–31 scale as the headset's volume wheel." Style="{StaticResource Hint}" Margin="0,6,0,0"/>
        <Border Height="1" Background="{StaticResource Line}" Margin="0,22"/>
        <TextBlock Text="GAME / CHAT BALANCE" Style="{StaticResource Caps}"/>
        <DockPanel Margin="0,10" IsEnabled="{Binding CanBalance}">
          <TextBlock DockPanel.Dock="Left" Text="Chat" Margin="0,0,8,0"/>
          <TextBlock DockPanel.Dock="Right" Text="Game" Margin="8,0,0,0"/>
          <Slider Minimum="0" Maximum="20" IsSnapToTickEnabled="True" TickFrequency="1" SmallChange="1" LargeChange="2" Value="{Binding BalanceValue}"/>
        </DockPanel>
        <TextBlock Text="Connect the 2.4 GHz dongle to mix game and chat." Style="{StaticResource Hint}" Visibility="{Binding NoDongleVisibility}"/>
        <Border Height="1" Background="{StaticResource Line}" Margin="0,22"/>
        <TextBlock Text="BASE STATION MODE" Style="{StaticResource Caps}" Margin="0,0,0,6"/>
        <ItemsControl ItemsSource="{Binding BaseModeChoices}" ItemTemplate="{StaticResource ChoiceRow}" IsEnabled="{Binding DongleConnected}"/>
        <TextBlock Text="Host type of the 2.4 GHz dongle. Switching makes the dongle reconnect for a few seconds." Style="{StaticResource Hint}" Margin="0,6,0,0"/>
      </StackPanel>
    </ScrollViewer>
  </Grid>
</UserControl>
```
`Views/MixView.xaml.cs`: constructor only.

`Views/ExtrasView.xaml`:
```xml
<UserControl x:Class="A30Control.Views.ExtrasView"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="280"/><ColumnDefinition Width="24"/><ColumnDefinition/>
    </Grid.ColumnDefinitions>
    <DockPanel>
      <TextBlock DockPanel.Dock="Bottom" Text="Mic mute changes and low battery (20%, 10%) show as Windows notifications." Style="{StaticResource Hint}"/>
      <StackPanel>
        <TextBlock Text="PROFILES" Style="{StaticResource Caps}" FontSize="14" Margin="0,0,0,12"/>
        <Border Height="1" Background="{StaticResource Line}"/>
        <ItemsControl ItemsSource="{Binding ProfileChoices}" ItemTemplate="{StaticResource ChoiceRow}"/>
        <TextBlock Text="Save EQ, sidetone, noise gate and balance together, then apply them in one click."
                   Style="{StaticResource Hint}" Margin="0,10" Visibility="{Binding NoProfilesVisibility}"/>
        <Button Content="SAVE CURRENT AS PROFILE" Style="{StaticResource CCButton}" Margin="0,12,0,0" Click="SaveProfile"/>
      </StackPanel>
    </DockPanel>
    <StackPanel Grid.Column="2">
      <TextBlock Text="EQ PER APP" Style="{StaticResource Caps}" Margin="0,0,0,4"/>
      <TextBlock Text="When one of these apps comes to the front, the EQ switches; leaving it restores the previous preset."
                 Style="{StaticResource Hint}" Margin="0,0,0,10"/>
      <TextBlock Text="NO APPS YET" Style="{StaticResource Caps}" Foreground="{StaticResource Dim}" Margin="0,8" Visibility="{Binding NoAppRulesVisibility}"/>
      <ItemsControl ItemsSource="{Binding AppRules}">
        <ItemsControl.ItemTemplate>
          <DataTemplate>
            <Border BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="8">
              <DockPanel>
                <Button DockPanel.Dock="Right" Style="{StaticResource Plain}" Command="{Binding RemoveCmd}" Margin="10,0,0,0" ToolTip="Remove">
                  <TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Muted}"/>
                </Button>
                <ComboBox DockPanel.Dock="Right" Width="150" ItemsSource="{Binding ModeLabels}" SelectedIndex="{Binding ModeIndex}"/>
                <TextBlock Text="{Binding Name}" VerticalAlignment="Center"/>
              </DockPanel>
            </Border>
          </DataTemplate>
        </ItemsControl.ItemTemplate>
      </ItemsControl>
      <Button Content="ADD APP" Style="{StaticResource CCButton}" HorizontalAlignment="Left" Width="180" Margin="0,12,0,0" Click="AddApp"/>
    </StackPanel>
  </Grid>
</UserControl>
```

`Views/ExtrasView.xaml.cs`:
```csharp
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace A30Control.Views;

public partial class ExtrasView : UserControl
{
    public ExtrasView() => InitializeComponent();
    HeadsetModel M => (HeadsetModel)DataContext;

    void SaveProfile(object sender, RoutedEventArgs e)
    {
        if (AskWindow.Ask(Window.GetWindow(this), "Profile name") is string n) M.SaveProfile(n);
    }

    void AddApp(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Title = "Choose a game or app",
            Filter = "Programs (*.exe)|*.exe",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        };
        if (dlg.ShowDialog(Window.GetWindow(this)) == true) M.AddAppRule(dlg.FileName);
    }
}
```

`Views/SettingsView.xaml`:
```xml
<UserControl x:Class="A30Control.Views.SettingsView"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="280"/><ColumnDefinition Width="24"/><ColumnDefinition/>
    </Grid.ColumnDefinitions>
    <DockPanel>
      <StackPanel DockPanel.Dock="Bottom">
        <Button Content="RENAME HEADSET" Style="{StaticResource CCButton}" Margin="0,0,0,8" Click="Rename"/>
        <Button Content="TURN OFF HEADSET" Style="{StaticResource CCButton}" Margin="0,0,0,8" Click="TurnOff"/>
        <Button Content="FACTORY RESET" Style="{StaticResource CCButton}" Click="FactoryReset"/>
      </StackPanel>
      <StackPanel>
        <TextBlock Text="DEVICE" Style="{StaticResource Caps}" FontSize="14" Margin="0,0,0,12"/>
        <Border Height="1" Background="{StaticResource Line}"/>
        <DockPanel Margin="8,11"><TextBlock Text="NAME" Style="{StaticResource Caps}"/><TextBlock Text="{Binding Name}" HorizontalAlignment="Right"/></DockPanel>
        <Border Height="1" Background="{StaticResource Line}"/>
        <DockPanel Margin="8,11"><TextBlock Text="FIRMWARE" Style="{StaticResource Caps}"/><TextBlock Text="{Binding Firmware}" HorizontalAlignment="Right"/></DockPanel>
        <Border Height="1" Background="{StaticResource Line}"/>
        <DockPanel Margin="8,11"><TextBlock Text="SERIAL" Style="{StaticResource Caps}"/><TextBlock Text="{Binding Serial}" HorizontalAlignment="Right"/></DockPanel>
        <Border Height="1" Background="{StaticResource Line}"/>
      </StackPanel>
    </DockPanel>
    <StackPanel Grid.Column="2">
      <TextBlock Text="SLEEP MODE" Style="{StaticResource Caps}" Margin="0,0,0,6"/>
      <ItemsControl ItemsSource="{Binding SleepChoices}" ItemTemplate="{StaticResource ChoiceRow}"/>
      <TextBlock Text="TONES" Style="{StaticResource Caps}" Margin="0,20,0,6"/>
      <ItemsControl ItemsSource="{Binding TonesChoices}" ItemTemplate="{StaticResource ChoiceRow}"/>
      <CheckBox Content="Start with Windows" IsChecked="{Binding LaunchAtLogin}" Foreground="{StaticResource Text}" Margin="0,20,0,0"/>
    </StackPanel>
  </Grid>
</UserControl>
```

`Views/SettingsView.xaml.cs`:
```csharp
using System.Windows;
using System.Windows.Controls;

namespace A30Control.Views;

public partial class SettingsView : UserControl
{
    public SettingsView() => InitializeComponent();
    HeadsetModel M => (HeadsetModel)DataContext;

    void Rename(object sender, RoutedEventArgs e)
    {
        if (AskWindow.Ask(Window.GetWindow(this), "Headset name (shown in Bluetooth)", M.Name) is string n) M.Rename(n);
    }

    void TurnOff(object sender, RoutedEventArgs e) => M.TurnOff();

    /// Two confirmations: a warning, then typing RESET.
    void FactoryReset(object sender, RoutedEventArgs e)
    {
        var w = Window.GetWindow(this);
        if (MessageBox.Show(w, "This erases all headset settings; you may need to re-pair it.", "Factory reset the headset?",
                            MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        if (AskWindow.Ask(w, "Type RESET to confirm", mustType: "RESET") == "RESET") M.FactoryReset();
    }
}
```

- [ ] **Step 4: Wire the window into `App.xaml.cs`**

Add the field `MainWindow? window;` next to `TrayPanel? panel;` and replace `void OpenWindow() => panel?.Hide();` with:
```csharp
    void OpenWindow()
    {
        panel?.Hide();
        window ??= new MainWindow(model!);
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }
```

- [ ] **Step 5: Build**

Run: `A30Control.Windows/build.sh`
Expected: `selftest: all passed` and `dist/A30Control.exe` listed, no XAML or C# errors.

---

### Task 7: Hand-over: checklist and docs

**Files:**
- Create: `docs/superpowers/a30-control-windows-checklist.md`
- Modify: `README.md` (Windows section), `CLAUDE.md` (Files + Windows notes)

**Interfaces:** none (documentation).

- [ ] **Step 1: `docs/superpowers/a30-control-windows-checklist.md`**

```markdown
# A30 Control for Windows — manual checklist

Copy `A30Control.Windows/dist/A30Control.exe` to the PC (any folder, e.g. `C:\Tools\A30Control\`).
Headset paired in Windows Bluetooth settings; 2.4 GHz dongle plugged in. If something fails, send
`%APPDATA%\A30Control\a30.log`.

## 1. First launch
- [ ] SmartScreen: "More info" → "Run anyway" (the exe is not signed).
- [ ] The A30 icon appears in the notification area (it may be under the ^ overflow; drag it out).
- [ ] Double-click the exe again: no second icon (one copy only).
- [ ] Hover the icon: "ASTRO A30 · NN%".

## 2. Connection
- [ ] Headset connected to the PC: within ~10 s the panel shows volume/EQ. Note in the log whether
      it says `connected (Raw)` or `connected (Iap2)`.
- [ ] Disconnect the headset in Windows Bluetooth settings: the panel shows "not connected to this PC"
      and the app does NOT reconnect it. Reconnect it in Windows: the app connects by itself.

## 3. Tray panel (left click on the icon)
- [ ] Volume slider changes the volume; turning the wheel moves the slider.
- [ ] EQ pills: Footstep → Immersive → Custom, the orange pill follows.
- [ ] Sidetone 40 → 60 → 40 %. Game mix slider moves (dongle connected).
- [ ] Clicking outside closes the panel; clicking the icon again opens it.

## 4. Window ("Open window")
- [ ] 980×660, cannot be maximized or resized; dark title bar; no gear in the header.
- [ ] EQUALIZER: Custom, drag 31 Hz to +6 dB, hear more bass; Reset flat; Save curve as "Test", apply it, remove it.
- [ ] MICROPHONE: Boom/Internal, sidetone, noise gate Night → Off.
- [ ] MIX: mute headset audio on/off; balance 0 % → 100 % → 50 %.
- [ ] MIX: base station mode Xbox, wait ~10 s (the dongle reconnects), then back to PC. Audio still works.
- [ ] EXTRAS: save a profile, change EQ, apply the profile; Add app (e.g. a game exe) with Footstep,
      focus the game → EQ switches; focus something else → it switches back.
- [ ] SETTINGS: Start with Windows on → listed in Task Manager → Startup apps; turn it off again.
- [ ] SETTINGS: Factory reset → Cancel at the warning. Again → OK → typing `RES` keeps the button disabled → Cancel. Do not reset.
- [ ] Closing the window keeps the tray icon; tray "Quit" exits.

## 5. Turn off
- [ ] Tray → Turn off, keep audio paused: countdown, the headset powers off within ~2 min.
- [ ] Turn it on again (USB-C or Bluetooth): the app reconnects and Settings shows Sleep mode "Never".

## 6. Leave it as you found it
Custom flat · sidetone 40 / 40 · noise gate Off / Off · sleep Never · tones Minimal · balance 50 % · base station PC.
```

- [ ] **Step 2: README.md** — add after the "Install" section:

```markdown
## Windows

`A30Control.Windows/` is a C#/.NET 8 WPF port with the same features (tray icon + panel instead of
the menu bar, "Start with Windows" instead of "Open at login"). Built on the Mac:

```bash
A30Control.Windows/selftest.sh   # protocol tests, no headset
A30Control.Windows/build.sh      # → A30Control.Windows/dist/A30Control.exe (self-contained, x64)
```

Copy the exe to the PC and run it (SmartScreen: "More info → Run anyway"). Logs and settings live in
`%APPDATA%\A30Control\`. On Windows the app detects whether the headset speaks iAP2 (as toward a Mac)
or plain SPP (as toward Android). Manual test list: `docs/superpowers/a30-control-windows-checklist.md`.
```

- [ ] **Step 3: CLAUDE.md** — in "Files", add:

```markdown
- `A30Control.Windows/` — Windows port (C#/.NET 8, WPF): `A30Kit/` protocol (port of the Swift A30Kit +
  `HeadsetLink` with iAP2/raw-SPP auto-detect), `A30Kit.SelfTest/`, `A30Control/` app. `selftest.sh`,
  `build.sh` (→ `dist/A30Control.exe`), `build.ps1` for building on Windows. .NET SDK in `~/.dotnet`;
  builds run from a snapshot in `~/Library/Caches/A30Control.Windows/` (iCloud evicts files).
```

- [ ] **Step 4: Final build and hand-over**

Run: `A30Control.Windows/build.sh`
Expected: `selftest: all passed`, `dist/A30Control.exe` listed. Send the exe and the checklist to Doug.
