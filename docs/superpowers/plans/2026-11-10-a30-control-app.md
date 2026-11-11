# A30 Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS app (menu bar + window) that controls the ASTRO A30 over its iAP2/CPP channel: EQ, microphone, game/chat balance, device settings, factory reset.

**Architecture:** `A30Control/Sources/A30Kit` holds the protocol: pure byte framing, a pure iAP2 state machine, typed codecs, then one IOBluetooth class (`HeadsetLink`) and a typed async API (`A30`). `A30Control/Sources/A30App` is SwiftUI. A single `@Observable` `HeadsetModel` is shared by the `MenuBarExtra` and the `Window`. Everything is compiled with `swiftc` by shell scripts and wrapped in an `.app` bundle.

**Tech Stack:** Swift 6.4 toolchain in Swift 5 language mode, SwiftUI + Observation (macOS 14+ APIs), IOBluetooth, shell scripts. No Xcode, no SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-10-a30-control-app-design.md`. Protocol background: `CLAUDE.md`. Reference implementation of every byte sequence: `a30b.swift` at the repo root.

## Global Constraints

- **Toolchain.** Only Command Line Tools are installed, and SwiftPM is broken (`Package.swift` fails to link `PackageDescription`).
  - Build with plain `swiftc -swift-version 5 -parse-as-library`.
  - Do not create a `Package.swift`.
- **Banned SwiftUI property wrappers.** In the macOS 27 SDK, SwiftUI's `@State` (and the other SwiftUI state wrappers) are macros whose plugin ships only with Xcode.
  - Never use `@State`, `@Binding`, `@StateObject`, `@ObservedObject` or `@Published`.
  - Allowed: `@Observable` (Observation), `@Environment`, `@ViewBuilder`.
  - Keep all view state in `HeadsetModel`.
  - Build bindings with `Binding(get:set:)`.
- **Launching.** Launch only as a bundle (`open "build/A30 Control.app"`, or Finder). A bare binary aborts with a TCC SIGABRT because the parent process lacks `NSBluetoothAlwaysUsageDescription`.
- **Safety.**
  - Never call any `iGenericDFU` (0x010A) function.
  - `FACTORY_RESET` (iDeviceInfo fn4) is reachable only through `A30.factoryReset(serial:)`, and only from the Settings confirmation flow.
  - `A30Kit` exposes no raw-command API.
- **Writes.** Every SET is followed by a GET of the same value, and the UI shows the value read back.
- **Platform.** macOS 14+ APIs only. Bundle id `local.a30control`. UI strings in English.
- **Address.** Headset address: first paired device whose name contains "A30", else `00-00-00-00-00-00`.
- **Version control.** The project is **not a git repository**. There are no commit steps; checkpoints run `./test.sh`. Do not run `git init` unless Doug asks.

## Review Focus

These need the real headset, so the owning task gets a manual hardware step rather than a unit test:

1. **Headset off or out of range at launch.** Expect the "Looking for ASTRO A30…" overlay, a retry every 5 s, no crash, and a connection within about 15 s of powering on. *(Task 8, step 2)*
2. **Headset powered off mid-session.** Pending requests fail with `.disconnected`, the UI shows the overlay (it does not freeze), and the app reconnects after power-on. *(Task 8, step 3)*
3. **Stale RFCOMM channel** after `./run.sh` (a30b) or a crash. The first open times out after 8 s, then the next attempt connects. *(Task 8, step 4)*
4. **iPhone Logitech G app connected at the same time.** Our open or handshake may fail. The app must keep retrying and show the error text, not hang. *(Task 8, step 5)*
5. **Binary started directly instead of via `open`.** It crashes with TCC. `build.sh` prints the correct launch command, and the README section in `CLAUDE.md` says so. *(Task 5, step 6)*

---

## File Structure

```
A30Control/
├─ Info.plist                         app bundle plist
├─ build.sh                           swiftc → build/A30 Control.app
├─ test.sh                            swiftc pure sources + Tests → build/selftest, runs it
├─ probe.sh                           swiftc A30Kit + Probe → build/A30Probe.app, runs it via open
├─ Sources/A30Kit/
│   ├─ Framing.swift                  pure: hex, CRC, SPP, CPL, CPPReply, iAP2 link/splitter/control msgs
│   ├─ IAP2Session.swift              pure: Apple-device iAP2 state machine (bytes in → events out)
│   ├─ Codecs.swift                   pure: FeatureID, errors, typed values and their byte codecs
│   ├─ HeadsetLink.swift              IOBluetooth RFCOMM + IAP2Session + one-in-flight request queue
│   └─ A30.swift                      typed async API over HeadsetLink
├─ Sources/A30App/
│   ├─ A30ControlApp.swift            @main: MenuBarExtra + Window
│   ├─ HeadsetModel.swift             @Observable state, connect loop, polling, writes
│   └─ Views/
│       ├─ Components.swift           Card, banner, connection overlay, shared controls
│       ├─ MenuBarPanel.swift
│       ├─ MainWindow.swift           sidebar + Home
│       ├─ EQView.swift
│       ├─ MicrophoneView.swift
│       └─ SettingsView.swift         incl. factory reset alert + sheet
├─ Probe/main.swift                   hardware smoke test (reads; --writes does change+restore)
└─ Tests/
    ├─ SelfTest.swift                 @main runner + check()/bytes() helpers
    ├─ FramingTests.swift
    ├─ IAP2Tests.swift
    └─ CodecTests.swift
```

Only `Framing.swift`, `IAP2Session.swift` and `Codecs.swift` are compiled into `selftest`. They must not import IOBluetooth or SwiftUI.

---

### Task 1: Byte framing

**Files:**
- Create: `A30Control/Sources/A30Kit/Framing.swift`
- Create: `A30Control/test.sh`
- Test: `A30Control/Tests/SelfTest.swift`, `A30Control/Tests/FramingTests.swift`

**Interfaces:**
- Produces:
  - `hex(_:) -> String`, `be16(_ v: Int) -> [UInt8]`, internal `rd16(_:_:) -> Int`
  - `crc16(_:) -> UInt16`, `sppWrap(_ payload: [UInt8]) -> [UInt8]`, `struct SPPParser { mutating func feed(_: [UInt8]) -> [[UInt8]] }`
  - `cppRequest(index:function:swID:args:) -> [UInt8]` (includes the CPL byte), `struct CPLReassembler { mutating func feed(_ payload: [UInt8]) -> [UInt8]? }` (returns the CPP message without the CPL byte)
  - `enum CPPReply: Equatable { case ok(index:function:swID:args:), error(index:function:swID:code:) }` with `init?(_ m: [UInt8])`
  - `iap2Detect: [UInt8]`, `iapChecksum(_:) -> UInt8`, `struct LinkPacket: Equatable` (`SYN`/`ACK`/`RST`, `encode()`), `enum IAP2Frame`, `struct IAP2Splitter`
  - `iapParam(_:_:)`, `controlMessage(_:_:)`, `struct IAPParam`, `parseParams(_:) -> [IAPParam]?`, `struct ControlMessage`, `struct ControlParser`, `iapText(_:) -> String?`

- [ ] **Step 1: Write the test runner and failing framing tests**

`A30Control/Tests/SelfTest.swift`:

```swift
// Minimal test runner: XCTest / swift-testing are unavailable without Xcode.
import Foundation

var failures = 0

func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if !cond() { failures += 1; print("FAIL line \(line): \(msg)") }
}

/// "13 a0 05" -> [0x13, 0xa0, 0x05]
func bytes(_ s: String) -> [UInt8] {
    s.split(separator: " ").map { UInt8($0, radix: 16)! }
}

@main
struct SelfTest {
    static func main() {
        testFraming()
        print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
```

`A30Control/Tests/FramingTests.swift`. The fixtures are real bytes from today's session; see the logs in `CLAUDE.md` and `a30b.swift`:

```swift
import Foundation

// Fragmented reply to FeatureSet.GET_FEATURE_ID[0], three SPP frames, CRC 00 00.
let featureListFrames = [
    bytes("13 a0 20 01 01 12 10 00 00 00 02 00 01 00 01 01 04 00 03 01 00 00 04 01 01 00 02 06 01 00 01 06 0b 00 01 00 00"),
    bytes("13 a0 20 03 02 00 00 03 06 04 00 01 06 08 00 01 06 09 00 01 06 0a 00 01 01 08 00 03 01 0a 00 04 02 01 00 00 00"),
    bytes("13 a0 06 04 03 00 04 00 03 00 00"),
]
let synFixture = bytes("ff 5a 00 1a 80 18 00 00 f5 01 05 00 84 05 dc 01 f4 1e 03 01 00 01 03 02 01 77")

func testFraming() {
    // CRC-16/MCRF4XX check value
    check(crc16(Array("123456789".utf8)) == 0x6F91, "crc check value")

    // CLAUDE.md worked example: GET_FEATURE(iEQSet) swId 1
    check(sppWrap(cppRequest(index: 0, function: 0, swID: 1, args: [0x02, 0x01]))
          == bytes("13 a0 05 00 00 01 02 01 d8 24"), "sppWrap worked example")

    // SPP parser across chunk boundaries, CRC 00 00 accepted
    var spp = SPPParser()
    check(spp.feed(bytes("13 a0 06 00")).isEmpty, "partial frame yields nothing")
    check(spp.feed(bytes("00 01 00 00 02 00 00")) == [bytes("00 00 01 00 00 02")], "frame completes")
    // bad CRC is dropped, correct CRC is accepted
    check(spp.feed(bytes("13 a0 01 00 12 34")).isEmpty, "bad crc dropped")
    check(spp.feed(sppWrap([0x00, 0x07])) == [[0x00, 0x07]], "good crc accepted")

    // CPL reassembly of the fragmented feature list
    var spp2 = SPPParser(), cpl = CPLReassembler()
    var messages: [[UInt8]] = []
    for f in featureListFrames {
        for p in spp2.feed(f) { if let m = cpl.feed(p) { messages.append(m) } }
    }
    check(messages.count == 1, "one reassembled message")
    check(messages.first?.count == 67, "reassembled length 2 + 65")
    if let m = messages.first, case let .ok(index, function, swID, args)? = CPPReply(m) {
        check(index == 1 && function == 1 && swID == 2, "reply header")
        check(args.first == 0x10, "feature count 16")
    } else { check(false, "feature list parses as ok reply") }

    // Error reply: FF featIdx fn|sw code (payload 00 ff 00 06 05)
    var cpl2 = CPLReassembler()
    check(cpl2.feed(bytes("00 ff 00 06 05")).flatMap(CPPReply.init)
          == .error(index: 0, function: 0, swID: 6, code: 5), "error reply")

    // iAP2 link packet: re-encoding the headset's own SYN reproduces it exactly
    let syn = LinkPacket(control: LinkPacket.SYN, seq: 0x18, ack: 0, session: 0,
                         payload: Array(synFixture[9..<25]))
    check(syn.encode() == synFixture, "SYN encode matches fixture")

    // Splitter: detect + SYN split mid-packet, then a corrupted packet is dropped
    var sp = IAP2Splitter()
    let stream = iap2Detect + synFixture
    let a = sp.feed(Array(stream[0..<10]))
    let b = sp.feed(Array(stream[10...]))
    check(a == [.detect], "detect first")
    check(b == [.packet(syn)], "SYN after second chunk")
    var bad = synFixture; bad[12] ^= 0xFF
    check(sp.feed(bad).isEmpty, "bad payload checksum dropped")
    check(sp.feed(Array(iap2Detect[0..<3])).isEmpty, "partial detect waits")
    check(sp.feed(Array(iap2Detect[3...])) == [.detect], "detect completes")

    // Control messages and params
    check(controlMessage(0xAA00) == bytes("40 40 00 06 aa 00"), "control message")
    let ps = iapParam(0, [1]) + iapParam(1, Array("x.y".utf8))
    check(parseParams(ps)?.map(\.id) == [0, 1], "params roundtrip")
    check(parseParams([0x00, 0x09, 0x00]) == nil, "malformed params rejected")
    var cp = ControlParser()
    let msg = controlMessage(0x1D02, iapParam(3, [7]))
    check(cp.feed(Array(msg[0..<4])).isEmpty, "partial control message")
    let done = cp.feed(Array(msg[4...]))
    check(done.count == 1 && done[0].id == 0x1D02 && done[0].params.first?.data == [7], "control message completes")
    check(iapText(Array("A30".utf8) + [0]) == "A30", "text with NUL")
    check(iapText([0x01, 0x02]) == nil, "binary is not text")
}
```

- [ ] **Step 2: Write `test.sh` and run it to verify it fails**

`A30Control/test.sh`:

```sh
#!/bin/sh
# Compiles the pure A30Kit sources with the tests and runs them. No headset needed.
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -parse-as-library -o build/selftest \
  $(ls Sources/A30Kit/Framing.swift Sources/A30Kit/IAP2Session.swift Sources/A30Kit/Codecs.swift 2>/dev/null) \
  Tests/*.swift
build/selftest
```

Run: `chmod +x A30Control/test.sh && A30Control/test.sh`
Expected: compile FAIL with `cannot find 'crc16' in scope`, and similar errors.

- [ ] **Step 3: Implement `Framing.swift`**

```swift
// Byte-level framing for the A30 control channel. Pure functions, no IOBluetooth,
// so Tests/ can exercise them without a headset. Layers (outside in):
// RFCOMM bytes → iAP2 link packets → EA session data → SPP frames → CPL → CPP.
import Foundation

public func hex<C: Collection>(_ d: C) -> String where C.Element == UInt8 {
    d.map { String(format: "%02x", $0) }.joined(separator: " ")
}

public func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

func rd16<C: Collection>(_ d: C, _ offset: Int) -> Int where C.Element == UInt8, C.Index == Int {
    Int(d[d.startIndex + offset]) << 8 | Int(d[d.startIndex + offset + 1])
}

// MARK: - SPP frame: 13 | A0+lenHi | lenLo | payload | crcLo crcHi

/// CRC-16/MCRF4XX (poly 0x8408 reflected, init 0xFFFF). Check value 0x6F91 for "123456789".
public func crc16<C: Collection>(_ d: C) -> UInt16 where C.Element == UInt8 {
    var c: UInt16 = 0xFFFF
    for b in d {
        c ^= UInt16(b)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
    }
    return c
}

public func sppWrap(_ payload: [UInt8]) -> [UInt8] {
    let n = payload.count
    var f: [UInt8] = [0x13, UInt8(0xA0 | ((n >> 8) & 0x0F)), UInt8(n & 0xFF)] + payload
    let c = crc16(f)
    f += [UInt8(c & 0xFF), UInt8(c >> 8)]
    return f
}

/// Reassembles SPP frames from a byte stream. Over the iAP2 EA session the A30
/// sends CRC 00 00, so that is accepted as well as a correct CRC.
public struct SPPParser {
    private var buf: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        buf += bytes
        var out: [[UInt8]] = []
        var i = 0
        while i + 5 <= buf.count {
            guard buf[i] == 0x13, buf[i + 1] & 0xF0 == 0xA0 else { i += 1; continue }
            let n = Int(buf[i + 1] & 0x0F) << 8 | Int(buf[i + 2])
            let end = i + 3 + n + 2
            if end > buf.count { break }
            let rx = UInt16(buf[end - 2]) | UInt16(buf[end - 1]) << 8
            if rx == 0 || rx == crc16(buf[i..<(i + 3 + n)]) { out.append(Array(buf[(i + 3)..<(i + 3 + n)])) }
            i = end
        }
        buf.removeFirst(i)
        return out
    }
}

// MARK: - CPL header + CPP message

/// CPL byte 0x00 (single fragment) + feature index + (fn << 4 | swId) + args.
public func cppRequest(index: UInt8, function: UInt8, swID: UInt8, args: [UInt8]) -> [UInt8] {
    [0x00, index, (function << 4) | (swID & 0x0F)] + args
}

/// Joins CPL fragments (CPL bit0 = more follow, bits1-7 = fragment seq).
/// Returns the CPP message (CPL byte stripped) once the last fragment arrives.
public struct CPLReassembler {
    private var frag: [UInt8] = []
    public init() {}

    public mutating func feed(_ payload: [UInt8]) -> [UInt8]? {
        guard let cpl = payload.first else { return nil }
        if cpl >> 1 == 0 { frag = [] }         // fragment 0 starts a new message
        frag += payload.dropFirst()
        if cpl & 1 != 0 { return nil }
        defer { frag = [] }
        return frag
    }
}

public enum CPPReply: Equatable {
    case ok(index: UInt8, function: UInt8, swID: UInt8, args: [UInt8])
    case error(index: UInt8, function: UInt8, swID: UInt8, code: UInt8)

    /// `m` is a CPP message without the CPL byte. Errors look like FF featIdx fn|sw code.
    public init?(_ m: [UInt8]) {
        if m.count >= 4, m[0] == 0xFF {
            self = .error(index: m[1], function: m[2] >> 4, swID: m[2] & 0x0F, code: m[3])
            return
        }
        guard m.count >= 2 else { return nil }
        self = .ok(index: m[0], function: m[1] >> 4, swID: m[1] & 0x0F, args: Array(m.dropFirst(2)))
    }
}

// MARK: - iAP2 link layer

public let iap2Detect: [UInt8] = [0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10]

/// iAP2 checksum: two's complement of the byte sum.
public func iapChecksum<C: Collection>(_ d: C) -> UInt8 where C.Element == UInt8 {
    0 &- d.reduce(0, &+)
}

/// FF 5A len(2) control seq ack session hdrCks [payload payloadCks]
public struct LinkPacket: Equatable {
    public static let SYN: UInt8 = 0x80
    public static let ACK: UInt8 = 0x40
    public static let RST: UInt8 = 0x10

    public var control: UInt8
    public var seq: UInt8
    public var ack: UInt8
    public var session: UInt8
    public var payload: [UInt8]

    public init(control: UInt8, seq: UInt8, ack: UInt8, session: UInt8, payload: [UInt8] = []) {
        self.control = control; self.seq = seq; self.ack = ack; self.session = session; self.payload = payload
    }

    public func encode() -> [UInt8] {
        let len = 9 + (payload.isEmpty ? 0 : payload.count + 1)
        var p: [UInt8] = [0xFF, 0x5A] + be16(len) + [control, seq, ack, session]
        p.append(iapChecksum(p))
        if !payload.isEmpty { p += payload; p.append(iapChecksum(payload)) }
        return p
    }
}

public enum IAP2Frame: Equatable {
    case detect
    case packet(LinkPacket)
    case junk(UInt8)
}

/// Splits the RFCOMM byte stream into iAP2 detect sequences and checksum-valid link packets.
public struct IAP2Splitter {
    private var buf: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [IAP2Frame] {
        buf += bytes
        var out: [IAP2Frame] = []
        while buf.count >= 2 {
            if buf.starts(with: iap2Detect) { buf.removeFirst(6); out.append(.detect); continue }
            if buf[0] == 0xFF && buf[1] == 0x5A {
                guard buf.count >= 4 else { break }
                let len = rd16(buf, 2)
                guard len >= 9 else { out.append(.junk(buf.removeFirst())); continue }
                guard buf.count >= len else { break }
                let p = Array(buf[0..<len])
                buf.removeFirst(len)
                let payload = len > 10 ? Array(p[9..<(len - 1)]) : []
                let ok = iapChecksum(p[0..<8]) == p[8] && (payload.isEmpty || iapChecksum(payload) == p[len - 1])
                if ok { out.append(.packet(LinkPacket(control: p[4], seq: p[5], ack: p[6], session: p[7], payload: payload))) }
                continue
            }
            if buf.count < 6 && iap2Detect.starts(with: buf) { break }   // partial detect
            out.append(.junk(buf.removeFirst()))
        }
        return out
    }
}

// MARK: - iAP2 control session messages: 40 40 len(2) msgId(2) params; param = len(2) id(2) data

public func iapParam(_ id: Int, _ data: [UInt8]) -> [UInt8] { be16(4 + data.count) + be16(id) + data }

public func controlMessage(_ id: Int, _ params: [UInt8] = []) -> [UInt8] {
    [0x40, 0x40] + be16(6 + params.count) + be16(id) + params
}

public struct IAPParam {
    public let id: Int
    public let data: [UInt8]
}

/// Parses a run of params; nil unless the bytes are exactly a well-formed run.
public func parseParams(_ d: [UInt8]) -> [IAPParam]? {
    var out: [IAPParam] = []
    var i = 0
    while i + 4 <= d.count {
        let n = rd16(d, i)
        guard n >= 4, i + n <= d.count else { return nil }
        out.append(IAPParam(id: rd16(d, i + 2), data: Array(d[(i + 4)..<(i + n)])))
        i += n
    }
    return i == d.count ? out : nil
}

public struct ControlMessage {
    public let id: Int
    public let params: [IAPParam]
}

/// Reassembles control messages that may span several link packets.
public struct ControlParser {
    private var buf: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [ControlMessage] {
        buf += bytes
        var out: [ControlMessage] = []
        while buf.count >= 6 {
            guard buf[0] == 0x40, buf[1] == 0x40 else { buf = []; break }   // desync: drop buffer
            let n = rd16(buf, 2)
            guard n >= 6 else { buf = []; break }
            guard buf.count >= n else { break }
            out.append(ControlMessage(id: rd16(buf, 4), params: parseParams(Array(buf[6..<n])) ?? []))
            buf.removeFirst(n)
        }
        return out
    }
}

/// Printable ASCII (one trailing NUL allowed), else nil.
public func iapText(_ d: [UInt8]) -> String? {
    let s = d.last == 0 ? Array(d.dropLast()) : d
    guard !s.isEmpty, s.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
    return String(decoding: s, as: UTF8.self)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `A30Control/test.sh`
Expected: `selftest: all passed`

---

### Task 2: iAP2 session state machine

**Files:**
- Create: `A30Control/Sources/A30Kit/IAP2Session.swift`
- Create: `A30Control/Tests/IAP2Tests.swift`
- Modify: `A30Control/Tests/SelfTest.swift` (call `testIAP2()`)

**Interfaces:**
- Consumes (Task 1): `LinkPacket`, `IAP2Splitter`, `ControlParser`, `controlMessage`, `iapParam`, `parseParams`, `iapText`, `be16`, `hex`, `iap2Detect`, `sppWrap`, `cppRequest`.
- Produces:
  - `enum IAP2Event: Equatable { case send([UInt8]), ready, eaData([UInt8]), reset, log(String) }`
  - `struct IAP2Session` with:
    - `static let protocolName = "com.logitech.ag.carbonite"`
    - `private(set) var linkUp: Bool`, `eaOpen: Bool`, `identity: [Int: String]`
    - internal `var random: () -> UInt8`
    - `init()`
    - `mutating func receive(_ bytes: [UInt8]) -> [IAP2Event]`
    - `mutating func eaPacket(_ data: [UInt8]) -> [UInt8]`

- [ ] **Step 1: Write the failing test**

Every expected byte string below is copied from the successful `./run.sh` log of 2026-11-10.

`A30Control/Tests/IAP2Tests.swift`:

```swift
import Foundation

func testIAP2() {
    var s = IAP2Session()
    s.random = { 0 }
    let A = LinkPacket.ACK

    check(s.receive(iap2Detect) == [.send(iap2Detect)], "detect is echoed")

    check(s.receive(synFixture) == [.send(bytes(
        "ff 5a 00 1a c0 2b 18 00 8a 01 05 00 84 05 dc 01 f4 1e 03 01 00 01 03 02 01 77"))], "SYN+ACK")

    check(s.receive(LinkPacket(control: A, seq: 0x18, ack: 0x2b, session: 0).encode())
          == [.send(bytes("ff 5a 00 10 40 2c 18 01 12 40 40 00 06 aa 00 d0"))], "link up → AA00")
    check(s.linkUp, "linkUp")

    // AuthenticationCertificate (609-byte cert) → ACK + 32-byte challenge
    let cert = LinkPacket(control: A, seq: 0x19, ack: 0x2c, session: 1,
                          payload: controlMessage(0xAA01, iapParam(0, [UInt8](repeating: 0x30, count: 609))))
    let e1 = s.receive(cert.encode())
    check(e1.first == .send(bytes("ff 5a 00 09 40 2c 19 00 19")), "ACK cert")
    let aa02 = LinkPacket(control: A, seq: 0x2d, ack: 0x19, session: 1,
                          payload: controlMessage(0xAA02, iapParam(0, [UInt8](repeating: 0, count: 32)))).encode()
    check(e1.count == 2 && e1[1] == .send(aa02), "AA02 challenge")
    check(Array(aa02[0..<9]) == bytes("ff 5a 00 34 40 2d 19 01 ec"), "AA02 header matches log")

    // AuthenticationResponse → ACK, AA05, 1D00
    let resp = LinkPacket(control: A, seq: 0x1a, ack: 0x2d, session: 1,
                          payload: controlMessage(0xAA03, iapParam(0, [UInt8](repeating: 1, count: 64))))
    check(s.receive(resp.encode()) == [
        .send(bytes("ff 5a 00 09 40 2d 1a 00 17")),
        .send(bytes("ff 5a 00 10 40 2e 1a 01 0e 40 40 00 06 aa 05 cb")),
        .send(bytes("ff 5a 00 10 40 2f 1a 01 0d 40 40 00 06 1d 00 5d")),
    ], "auth succeeded + start identification")

    // IdentificationInformation with the EA protocol group → ACK, 1D02, EA00, ready
    let ident = iapParam(0, Array("A30".utf8) + [0])
        + iapParam(3, Array("A30SERIAL001".utf8) + [0])
        + iapParam(10, iapParam(0, [1]) + iapParam(1, Array(IAP2Session.protocolName.utf8) + [0]) + iapParam(2, [1]))
    let idp = LinkPacket(control: A, seq: 0x1b, ack: 0x2f, session: 1, payload: controlMessage(0x1D01, ident))
    check(s.receive(idp.encode()) == [
        .send(bytes("ff 5a 00 09 40 2f 1b 00 14")),
        .send(bytes("ff 5a 00 10 40 30 1b 01 0b 40 40 00 06 1d 02 5b")),
        .send(bytes("ff 5a 00 1b 40 31 1b 01 ff 40 40 00 11 ea 00 00 05 00 00 01 00 06 00 01 00 01 77")),
        .ready,
    ], "identification accepted + EA session started")
    check(s.eaOpen, "eaOpen")
    check(s.identity[0] == "A30" && s.identity[3] == "A30SERIAL001", "identity strings")

    // First CPP request over EA, exactly as logged
    check(s.eaPacket(sppWrap(cppRequest(index: 0, function: 0, swID: 1, args: [0, 0])))
          == bytes("ff 5a 00 16 40 32 1b 03 01 00 01 13 a0 05 00 00 01 00 00 e1 06 5f"), "EA request packet")

    // EA reply → ACK + eaData (EA session id stripped); retransmission → ACK only
    let reply = LinkPacket(control: A, seq: 0x1c, ack: 0x32, session: 3,
                           payload: [0x00, 0x01] + bytes("13 a0 06 00 00 01 00 00 02 00 00")).encode()
    check(s.receive(reply) == [.send(bytes("ff 5a 00 09 40 32 1c 00 10")),
                               .eaData(bytes("13 a0 06 00 00 01 00 00 02 00 00"))], "EA reply")
    check(s.receive(reply) == [.send(bytes("ff 5a 00 09 40 32 1c 00 10"))], "duplicate only re-ACKed")

    // Accessory reset
    check(s.receive(LinkPacket(control: LinkPacket.RST, seq: 0, ack: 0, session: 0).encode()) == [.reset], "RST")
    check(!s.linkUp && !s.eaOpen, "state cleared on RST")

    // Identification without our protocol → accepted, but never ready
    var t = IAP2Session()
    _ = t.receive(synFixture)
    _ = t.receive(LinkPacket(control: A, seq: 0x18, ack: 0x2b, session: 0).encode())
    let other = LinkPacket(control: A, seq: 0x19, ack: 0x2c, session: 1,
                           payload: controlMessage(0x1D01, iapParam(0, Array("X".utf8)))).encode()
    let ev = t.receive(other)
    check(!ev.contains(.ready) && !t.eaOpen, "no ready without carbonite protocol")
}
```

In `A30Control/Tests/SelfTest.swift`, change `main()` to:

```swift
    static func main() {
        testFraming()
        testIAP2()
        print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `A30Control/test.sh`
Expected: compile FAIL, `cannot find 'IAP2Session' in scope`.

- [ ] **Step 3: Implement `IAP2Session.swift`**

```swift
// Apple-device side of iAP2 toward the A30: detect, link sync, authentication
// (the accessory certificate is accepted without verification: we are not Apple),
// identification, then one External Accessory session that carries CPP traffic.
// Pure state machine: bytes in, events out. HeadsetLink does the RFCOMM I/O.
import Foundation

public enum IAP2Event: Equatable {
    case send([UInt8])      // write these bytes to RFCOMM
    case ready              // EA session started; CPP traffic may flow
    case eaData([UInt8])    // bytes the accessory sent on the EA session (EA session id stripped)
    case reset              // accessory reset the link
    case log(String)
}

public struct IAP2Session {
    public static let protocolName = "com.logitech.ag.carbonite"

    public private(set) var linkUp = false
    public private(set) var eaOpen = false
    /// Top-level string params of IdentificationInformation (0 name, 2 maker, 3 serial, 4 fw…).
    public private(set) var identity: [Int: String] = [:]
    /// Challenge byte source; tests replace it for deterministic output.
    var random: () -> UInt8 = { UInt8.random(in: 0...255) }

    private var splitter = IAP2Splitter()
    private var control = ControlParser()
    private var txSeq: UInt8 = 0x2B
    private var rxSeq: UInt8 = 0
    private var lastRx: UInt8?
    private var ctrlSession: UInt8 = 1
    private var eaSession: UInt8 = 3
    private var eaProtocolID: UInt8?
    private let eaSessionID = 1

    public init() {}

    public mutating func receive(_ bytes: [UInt8]) -> [IAP2Event] {
        var out: [IAP2Event] = []
        for frame in splitter.feed(bytes) {
            switch frame {
            case .detect: if !linkUp { out.append(.send(iap2Detect)) }
            case .junk: break
            case .packet(let p): out += link(p)
            }
        }
        return out
    }

    /// Link packet carrying `data` on the EA session, prefixed with our EA session id.
    public mutating func eaPacket(_ data: [UInt8]) -> [UInt8] {
        txSeq &+= 1
        return LinkPacket(control: LinkPacket.ACK, seq: txSeq, ack: rxSeq, session: eaSession,
                          payload: be16(eaSessionID) + data).encode()
    }

    private mutating func link(_ p: LinkPacket) -> [IAP2Event] {
        if p.control & LinkPacket.RST != 0 {
            linkUp = false; eaOpen = false
            return [.reset]
        }
        if p.control & LinkPacket.SYN != 0 {
            // payload: ver maxOut maxLen(2) rtx(2) cumAck(2) maxRtx maxCum, then (id type ver)*
            var i = 10
            while i + 3 <= p.payload.count {
                if p.payload[i + 1] == 0 { ctrlSession = p.payload[i] }
                if p.payload[i + 1] == 2 { eaSession = p.payload[i] }
                i += 3
            }
            rxSeq = p.seq; lastRx = p.seq
            return [.send(LinkPacket(control: LinkPacket.SYN | LinkPacket.ACK, seq: txSeq, ack: rxSeq,
                                     session: 0, payload: p.payload).encode())]
        }
        var out: [IAP2Event] = []
        if !linkUp && p.control & LinkPacket.ACK != 0 && p.ack == txSeq {
            linkUp = true
            out.append(sendControl(0xAA00))   // RequestAuthenticationCertificate
        }
        guard !p.payload.isEmpty else { return out }
        rxSeq = p.seq
        out.append(.send(LinkPacket(control: LinkPacket.ACK, seq: txSeq, ack: rxSeq, session: 0).encode()))
        if p.seq == lastRx { return out }      // retransmission, already handled
        lastRx = p.seq
        if p.session == ctrlSession {
            for m in control.feed(p.payload) { out += handle(m) }
        } else if p.session == eaSession, p.payload.count >= 2 {
            out.append(.eaData(Array(p.payload.dropFirst(2))))
        } else {
            out.append(.log("data on unknown session \(p.session): \(hex(p.payload))"))
        }
        return out
    }

    private mutating func sendControl(_ id: Int, _ params: [UInt8] = []) -> IAP2Event {
        txSeq &+= 1
        return .send(LinkPacket(control: LinkPacket.ACK, seq: txSeq, ack: rxSeq, session: ctrlSession,
                                payload: controlMessage(id, params)).encode())
    }

    private mutating func handle(_ m: ControlMessage) -> [IAP2Event] {
        switch m.id {
        case 0xAA01:   // AuthenticationCertificate: auth 2.0 certs are ~900 B (20-byte challenge), 3.0 ~600 B
            let certLen = m.params.first?.data.count ?? 0
            let challenge = (0..<(certLen > 800 ? 20 : 32)).map { _ in random() }
            return [sendControl(0xAA02, iapParam(0, challenge))]
        case 0xAA03:   // AuthenticationResponse (not verified)
            return [sendControl(0xAA05), sendControl(0x1D00)]   // AuthenticationSucceeded, StartIdentification
        case 0x1D01:   // IdentificationInformation
            for p in m.params {
                if let s = iapText(p.data) { identity[p.id] = s; continue }
                guard let sub = parseParams(p.data),
                      let idp = sub.first(where: { $0.id == 0 }), idp.data.count == 1,
                      let namep = sub.first(where: { $0.id == 1 }), iapText(namep.data) == Self.protocolName
                else { continue }
                eaProtocolID = idp.data[0]
            }
            guard let proto = eaProtocolID else {
                return [sendControl(0x1D02), .log("accessory does not offer \(Self.protocolName)")]
            }
            eaOpen = true
            return [sendControl(0x1D02),   // IdentificationAccepted
                    sendControl(0xEA00, iapParam(0, [proto]) + iapParam(1, be16(eaSessionID))),
                    .ready]
        default:
            return [.log(String(format: "control message 0x%04X ignored", m.id))]
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `A30Control/test.sh`
Expected: `selftest: all passed`

---

### Task 3: Typed codecs

**Files:**
- Create: `A30Control/Sources/A30Kit/Codecs.swift`
- Create: `A30Control/Tests/CodecTests.swift`
- Modify: `A30Control/Tests/SelfTest.swift` (call `testCodecs()`)

**Interfaces:**
- Consumes (Task 1): `featureListFrames` fixture and the `SPPParser`/`CPLReassembler`/`CPPReply` pipeline, in the tests only.
- Produces:
  - `enum FeatureID: UInt16`
  - `enum CenturionError: UInt8, Error` (`message`)
  - `enum A30Error: Error, Equatable` (`notFound`, `openFailed(Int32)`, `timeout`, `disconnected`, `unsupported`, `badReply`, `device(CenturionError)`; `message`)
  - `parseFeatureList(_:) -> [UInt16]`
  - `enum ChargingState`, `struct Battery` (`real`, `percent`, `charging`, `isCharging`, `init?(_:)`)
  - `enum EQMode: UInt8, CaseIterable` (`label`)
  - `struct EQSetting: Equatable` (`bandLabels`, `gainRange`, `mode`, `bands`, `init(mode:bands:)`, `init?(_:)`, `wire`)
  - `enum Mic: UInt8, CaseIterable` (`internalMic = 0`, `boom = 1`, `label`)
  - `parseMicValues(_:) -> [Mic: Int]`
  - `enum NoiseGate`, `enum Tones`, `enum SleepTimer` (all `UInt8, CaseIterable`, `label`)
  - `struct DongleStatus` (`init(_ byte: UInt8)`)
  - `parseLengthString(_: ArraySlice<UInt8>) -> String?`, `parseName(_:) -> String?`, `parseFirmware(_:) -> String?`, `lengthPrefixed(_:) -> [UInt8]`

- [ ] **Step 1: Write the failing test**

`A30Control/Tests/CodecTests.swift`:

```swift
import Foundation

func testCodecs() {
    // Feature list: reassemble the real fragmented reply, then decode ids in index order
    var spp = SPPParser(), cpl = CPLReassembler()
    var args: [UInt8] = []
    for f in featureListFrames {
        for p in spp.feed(f) {
            if let m = cpl.feed(p), case let .ok(_, _, _, a)? = CPPReply(m) { args = a }
        }
    }
    check(parseFeatureList(args) == [0x0000, 0x0001, 0x0104, 0x0100, 0x0101, 0x0601, 0x060B, 0x0200,
                                     0x0604, 0x0608, 0x0609, 0x060A, 0x0108, 0x010A, 0x0201, 0x0004],
          "feature list order")

    let b = Battery(bytes("2a 28 00"))
    check(b?.percent == 40 && b?.real == 42 && b?.charging == .notCharging && b?.isCharging == false, "battery")
    check(Battery(bytes("2a 28 02"))?.isCharging == true, "fast charging")
    check(Battery([0x01]) == nil, "short battery reply")

    check(EQSetting(bytes("04 00 00 00 00 00")) == EQSetting(mode: 4, bands: [0, 0, 0, 0, 0]), "eq decode flat")
    let e = EQSetting(mode: 4, bands: [-12, -1, 0, 5, 12])
    check(e.wire == bytes("04 88 f6 00 32 78"), "eq encode dB×10 signed")
    check(EQSetting(e.wire) == e, "eq roundtrip")
    check(EQSetting(mode: 4, bands: [20, -20, 0, 0, 0]).wire == bytes("04 78 88 00 00 00"), "eq clamps ±12 dB")
    check(EQMode(rawValue: 0x80) == .immersive && EQMode(rawValue: 0x81) == .footstep, "eq modes")

    check(parseMicValues(bytes("02 00 28 01 28")) == [.internalMic: 40, .boom: 40], "sidetone list")
    check(parseMicValues(bytes("02 00 00 01 03")).compactMapValues { NoiseGate(rawValue: UInt8($0)) }
          == [.internalMic: .off, .boom: .tournament], "noise gate list")

    check(DongleStatus(0x00).connected == false, "dongle off")
    let d = DongleStatus(0x05)
    check(d.connected && !d.xboxMode && d.hostType, "dongle bits")

    check(parseName(bytes("30 09 41 53 54 52 4f 20 41 33 30")) == "ASTRO A30", "name")
    check(parseLengthString(bytes("03 32 32 34")[...]) == "224", "serial")
    check(lengthPrefixed("224") == bytes("03 32 32 34"), "serial re-encoded for factory reset")
    check(parseLengthString(bytes("05 41")[...]) == nil, "truncated string rejected")
    check(parseFirmware(bytes("01 00 00 3b 05 6c 6f 63 61 6c")) == "1.0.59", "firmware")

    check(CenturionError(rawValue: 8) == .notConnected && CenturionError(rawValue: 14) == .notAuthorized, "errors")
    check(SleepTimer(rawValue: 0) == .never && SleepTimer(rawValue: 30) == .thirty, "sleep timer")
    check(Tones(rawValue: 2) == .minimal && NoiseGate(rawValue: 3) == .tournament, "tones / noise gate")
}
```

In `A30Control/Tests/SelfTest.swift`, change `main()` to:

```swift
    static func main() {
        testFraming()
        testIAP2()
        testCodecs()
        print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `A30Control/test.sh`
Expected: compile FAIL, `cannot find 'parseFeatureList' in scope`.

- [ ] **Step 3: Implement `Codecs.swift`**

```swift
// Typed values for the A30's CPP features and their byte encodings. Encodings were
// read from the decompiled Logitech G app (jadx/, see the spec's "Value encodings").
import Foundation

public enum FeatureID: UInt16 {
    case root = 0x0000, featureSet = 0x0001, profile = 0x0004
    case deviceInfo = 0x0100, deviceName = 0x0101, battery = 0x0104, autoSleep = 0x0108
    case volume = 0x0200, eq = 0x0201
    case sidetone = 0x0604, noiseGate = 0x0608, mix = 0x0609, dongle = 0x060A, tones = 0x060B
    // iGenericDFU (0x010A) is intentionally absent: firmware updates are out of scope.
}

public enum CenturionError: UInt8, Error {
    case invalidFeature = 1, invalidFunction, invalidSize, invalidSwID, invalidParam, timeout,
         lowResource, notConnected, busy, notAvailable, failed, malformed
    case notAuthorized = 14

    public var message: String {
        switch self {
        case .notConnected: "Not connected (game/chat balance needs the 2.4 GHz dongle)"
        case .invalidFunction: "Not supported by this firmware"
        case .invalidParam: "Value out of range"
        case .busy: "Headset busy, try again"
        default: "Headset error \(rawValue) (\(self))"
        }
    }
}

public enum A30Error: Error, Equatable {
    case notFound, openFailed(Int32), timeout, disconnected, unsupported, badReply
    case device(CenturionError)

    public var message: String {
        switch self {
        case .notFound: "ASTRO A30 is not paired with this Mac"
        case .openFailed(let r): String(format: "Could not open the control channel (0x%08x)", r)
        case .timeout: "The headset did not answer"
        case .disconnected: "Headset disconnected"
        case .unsupported: "Not available on this headset"
        case .badReply: "Unexpected reply from the headset"
        case .device(let e): e.message
        }
    }
}

/// iFeatureSet GET_FEATURE_ID(0) on the A30: count, then count × (id(2) type ver).
/// Position in the list is the feature index.
public func parseFeatureList(_ a: [UInt8]) -> [UInt16] {
    var out: [UInt16] = []
    var i = 1
    while i + 4 <= a.count { out.append(UInt16(a[i]) << 8 | UInt16(a[i + 1])); i += 4 }
    return out
}

public enum ChargingState: UInt8 { case notCharging = 0, slow, fast, full, error }

/// GET_BATTERY_STATUS: [realSOC, userSOC, chargingState]; the official app shows userSOC.
public struct Battery: Equatable {
    public let real: Int
    public let percent: Int
    public let charging: ChargingState?

    public init?(_ a: [UInt8]) {
        guard a.count >= 3 else { return nil }
        real = Int(a[0]); percent = Int(a[1]); charging = ChargingState(rawValue: a[2])
    }

    public var isCharging: Bool { charging.map { [.slow, .fast, .full].contains($0) } ?? false }
}

public enum EQMode: UInt8, CaseIterable {
    case custom = 0x04, immersive = 0x80, footstep = 0x81
    public var label: String {
        switch self {
        case .custom: "Custom"
        case .immersive: "Immersive"
        case .footstep: "Footstep"
        }
    }
}

/// HeadsetEQSet GET/SET_USER_EQ: [mode, band0..band4], band byte = dB × 10 (signed).
public struct EQSetting: Equatable {
    public static let bandLabels = ["31 Hz", "63 Hz", "125 Hz", "250 Hz", "500 Hz"]
    public static let gainRange = -12...12

    public var mode: UInt8
    public var bands: [Int]    // dB

    public init(mode: UInt8, bands: [Int]) { self.mode = mode; self.bands = bands }

    public init?(_ a: [UInt8]) {
        guard a.count >= 6 else { return nil }
        mode = a[0]
        bands = a[1...5].map { Int((Double(Int8(bitPattern: $0)) / 10).rounded()) }
    }

    public var wire: [UInt8] {
        [mode] + bands.map { db in
            UInt8(bitPattern: Int8(Swift.min(Swift.max(db, Self.gainRange.lowerBound), Self.gainRange.upperBound) * 10))
        }
    }
}

public enum Mic: UInt8, CaseIterable {
    case internalMic = 0, boom = 1
    public var label: String { self == .boom ? "Boom mic" : "Internal mic" }
}

/// Sidetone / noise gate GET: [count, (mic, value)*].
public func parseMicValues(_ a: [UInt8]) -> [Mic: Int] {
    var out: [Mic: Int] = [:]
    var i = 1
    while i + 2 <= a.count {
        if let m = Mic(rawValue: a[i]) { out[m] = Int(a[i + 1]) }
        i += 2
    }
    return out
}

public enum NoiseGate: UInt8, CaseIterable {
    case off = 0, night, home, tournament
    public var label: String {
        switch self {
        case .off: "Off"
        case .night: "Night"
        case .home: "Home"
        case .tournament: "Tournament"
        }
    }
}

public enum Tones: UInt8, CaseIterable {
    case none = 0, all = 1, minimal = 2
    public var label: String {
        switch self {
        case .none: "None"
        case .all: "All"
        case .minimal: "Minimal"
        }
    }
}

public enum SleepTimer: UInt8, CaseIterable {
    case never = 0, fifteen = 15, thirty = 30, sixty = 60
    public var label: String { self == .never ? "Never" : "\(rawValue) minutes" }
}

/// iHeadsetDongle GET_CONFIG: bit0 connected, bit1 Xbox mode, bit2 host type.
public struct DongleStatus: Equatable {
    public let connected: Bool
    public let xboxMode: Bool
    public let hostType: Bool
    public init(_ b: UInt8) { connected = b & 1 != 0; xboxMode = b & 2 != 0; hostType = b & 4 != 0 }
}

/// [len][utf8] as read by CPPDataUnpacker.getString().
public func parseLengthString(_ a: ArraySlice<UInt8>) -> String? {
    guard let n = a.first, a.count >= 1 + Int(n) else { return nil }
    return String(decoding: a.dropFirst().prefix(Int(n)), as: UTF8.self)
}

/// iDeviceName GET_NAME: [maxLength, len, utf8].
public func parseName(_ a: [UInt8]) -> String? { parseLengthString(a.dropFirst()) }

/// GET_FIRMWARE_VERSION, e.g. 01 00 00 3b 05 "local" → "1.0.59".
// ponytail: major.minor.build(BE16) inferred from the official app showing "1.0.60"; the trailing
// length-prefixed tag ("local") is ignored. Decode properly from jadx if it ever looks wrong.
public func parseFirmware(_ a: [UInt8]) -> String? {
    guard a.count >= 4 else { return nil }
    return "\(a[0]).\(a[1]).\(Int(a[2]) << 8 | Int(a[3]))"
}

public func lengthPrefixed(_ s: String) -> [UInt8] {
    let b = Array(s.utf8)
    return [UInt8(b.count)] + b
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `A30Control/test.sh`
Expected: `selftest: all passed`

---

### Task 4: Headset link, typed API, hardware probe

**Files:**
- Create: `A30Control/Sources/A30Kit/HeadsetLink.swift`
- Create: `A30Control/Sources/A30Kit/A30.swift`
- Create: `A30Control/Probe/main.swift`
- Create: `A30Control/probe.sh`

**Interfaces:**
- Consumes: all of Tasks 1–3.
- Produces:
  - `@MainActor final class HeadsetLink` with:
    - `var onClose: (@MainActor () -> Void)?`, `var log: (String) -> Void`, `private(set) var isReady: Bool`
    - `func open(address: String, timeout: Duration = .seconds(8)) async throws`
    - `func request(_ index: UInt8, _ function: UInt8, _ args: [UInt8] = []) async throws -> [UInt8]`
    - `func close()`
  - `@MainActor final class A30` with:
    - `let link: HeadsetLink`
    - `static func pairedAddress() -> String`
    - `func connect() async throws`, `func supports(_: FeatureID) -> Bool`
    - Reads: `battery() -> Battery`, `name() -> String`, `firmware() -> String`, `serial() -> String`, `volume() -> Int`, `eq() -> EQSetting`, `eqModes() -> [UInt8]`, `sidetone() -> [Mic: Int]`, `noiseGate() -> [Mic: NoiseGate]`, `balance() -> Int`, `dongle() -> DongleStatus`, `sleepTimer() -> SleepTimer`, `tones() -> Tones`
    - Writes: `setEQ(_: EQSetting, switching: Bool)`, `setSidetone(_: Mic, _ percent: Int)`, `setNoiseGate(_: Mic, _: NoiseGate)`, `setBalance(_: Int)`, `setSleepTimer(_: SleepTimer)`, `setTones(_: Tones)`, `factoryReset(serial: String)`
    - All of these are `async throws`.

- [ ] **Step 1: Implement `HeadsetLink.swift`**

There is no unit test, because this is IOBluetooth glue. The byte logic it calls is already tested; Step 4 verifies it on hardware.

```swift
// RFCOMM channel 26 to the A30 + IAP2Session + a one-in-flight CPP request queue.
// IOBluetooth delivers delegate callbacks on the main thread's run loop, so the class is
// MainActor-isolated and the nonisolated delegate methods hop in with assumeIsolated.
import Foundation
import IOBluetooth

@MainActor
public final class HeadsetLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    public static let channelID: BluetoothRFCOMMChannelID = 26

    public var onClose: (@MainActor () -> Void)?
    public var log: (String) -> Void = { print("[A30]", $0) }
    public private(set) var isReady = false

    private var channel: IOBluetoothRFCOMMChannel?
    private var session = IAP2Session()
    private var spp = SPPParser()
    private var cpl = CPLReassembler()
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var openGen = 0

    private struct Pending {
        let id: Int
        let index: UInt8
        let function: UInt8
        let args: [UInt8]
        var swID: UInt8 = 0
        let cont: CheckedContinuation<[UInt8], Error>
    }
    private var queue: [Pending] = []
    private var current: Pending?
    private var nextID = 0
    private var sw: UInt8 = 0
    private var consecutiveTimeouts = 0

    public override init() { super.init() }

    /// Opens the channel and completes the iAP2 handshake. Returns once CPP requests may be sent.
    public func open(address: String, timeout: Duration = .seconds(8)) async throws {
        close()
        guard let dev = IOBluetoothDevice(addressString: address) else { throw A30Error.notFound }
        session = IAP2Session(); spp = SPPParser(); cpl = CPLReassembler()
        openGen += 1
        let gen = openGen
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            openWaiter = c
            var ch: IOBluetoothRFCOMMChannel?
            let r = dev.openRFCOMMChannelAsync(&ch, withChannelID: Self.channelID, delegate: self)
            channel = ch
            if r != kIOReturnSuccess { failOpen(A30Error.openFailed(r)); return }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, self.openGen == gen, self.openWaiter != nil else { return }
                self.log("open timed out (stale channel or another host holds it)")
                self.failOpen(A30Error.timeout)
            }
        }
    }

    public func close() {
        let ch = channel
        channel = nil
        _ = ch?.close()
        teardown(A30Error.disconnected, notify: false)
    }

    public func request(_ index: UInt8, _ function: UInt8, _ args: [UInt8] = []) async throws -> [UInt8] {
        guard isReady else { throw A30Error.disconnected }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], Error>) in
            nextID += 1
            queue.append(Pending(id: nextID, index: index, function: function, args: args, cont: c))
            pump()
        }
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    nonisolated public func rfcommChannelOpenComplete(_ c: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        MainActor.assumeIsolated {
            guard c === channel else { return }
            if status != kIOReturnSuccess { failOpen(A30Error.openFailed(status)) }
        }
    }

    nonisolated public func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length n: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: p, count: n))
        MainActor.assumeIsolated {
            guard c === channel else { return }
            handle(session.receive(bytes))
        }
    }

    nonisolated public func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated {
            guard c === channel else { return }
            channel = nil
            log("channel closed")
            teardown(A30Error.disconnected, notify: true)
        }
    }

    // MARK: internals

    private func handle(_ events: [IAP2Event]) {
        for e in events {
            switch e {
            case .send(let b):
                write(b)
            case .log(let s):
                log(s)
            case .reset:
                log("iAP2 reset by accessory")
                let ch = channel; channel = nil; _ = ch?.close()
                teardown(A30Error.disconnected, notify: true)
            case .ready:
                let gen = openGen
                Task { [weak self] in   // the accessory needs a moment after EA00 before CPP traffic
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, self.openGen == gen, self.channel != nil else { return }
                    self.isReady = true
                    if let w = self.openWaiter { self.openWaiter = nil; w.resume() }
                }
            case .eaData(let d):
                for payload in spp.feed(d) {
                    if let m = cpl.feed(payload), let r = CPPReply(m) { deliver(r) }
                }
            }
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let ch = channel else { return }
        var b = bytes
        // writeAsync copies the buffer (proven by a30b.swift), so a temporary pointer is fine.
        let r = b.withUnsafeMutableBytes { ch.writeAsync($0.baseAddress, length: UInt16($0.count), refcon: nil) }
        if r != kIOReturnSuccess { log(String(format: "write failed 0x%08x", r)) }
    }

    private func pump() {
        guard current == nil, isReady, !queue.isEmpty else { return }
        var p = queue.removeFirst()
        sw = sw % 15 + 1      // swId 1…15, never 0
        p.swID = sw
        current = p
        write(session.eaPacket(sppWrap(cppRequest(index: p.index, function: p.function, swID: p.swID, args: p.args))))
        let id = p.id
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.timeout(id)
        }
    }

    private func timeout(_ id: Int) {
        guard let p = current, p.id == id else { return }
        consecutiveTimeouts += 1
        log("timeout idx=\(p.index) fn=\(p.function)")
        if consecutiveTimeouts >= 3 {
            consecutiveTimeouts = 0
            let ch = channel; channel = nil; _ = ch?.close()
            teardown(A30Error.disconnected, notify: true)
            return
        }
        current = nil
        p.cont.resume(throwing: A30Error.timeout)
        pump()
    }

    private func deliver(_ r: CPPReply) {
        guard let p = current else { log("unsolicited \(r)"); return }
        switch r {
        case let .ok(index, _, swID, args) where index == p.index && swID == p.swID:
            finish(.success(args))
        case let .error(index, _, swID, code) where index == p.index && swID == p.swID:
            finish(.failure(A30Error.device(CenturionError(rawValue: code) ?? .failed)))
        default:
            log("unmatched reply \(r)")
        }
    }

    private func finish(_ r: Result<[UInt8], Error>) {
        guard let p = current else { return }
        current = nil
        consecutiveTimeouts = 0
        p.cont.resume(with: r)
        pump()
    }

    private func failOpen(_ e: Error) {
        let ch = channel; channel = nil; _ = ch?.close()
        teardown(e, notify: false)
    }

    /// Fails everything in flight. `notify` reports a drop of an established link to onClose.
    private func teardown(_ error: Error, notify: Bool) {
        let wasReady = isReady
        isReady = false
        if let w = openWaiter { openWaiter = nil; w.resume(throwing: error) }
        let pending = (current.map { [$0] } ?? []) + queue
        current = nil
        queue = []
        for p in pending { p.cont.resume(throwing: A30Error.disconnected) }
        if notify && wasReady { onClose?() }
    }
}
```

- [ ] **Step 2: Implement `A30.swift`**

```swift
// Typed async API for the A30. Feature indexes come from the headset's own feature list
// at connect, never from constants, so a firmware that reorders features still works.
import Foundation
import IOBluetooth

@MainActor
public final class A30 {
    public static let fallbackAddress = "00-00-00-00-00-00"
    public let link = HeadsetLink()
    private var index: [UInt16: UInt8] = [:]

    public init() {}

    /// First paired device whose name contains "A30", else Doug's unit.
    public static func pairedAddress() -> String {
        let devs = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devs.first { ($0.name ?? "").contains("A30") }?.addressString ?? fallbackAddress
    }

    public func connect() async throws {
        try await link.open(address: Self.pairedAddress())
        let list = try await link.request(1, 1, [0])   // iFeatureSet (always idx 1) GET_FEATURE_ID(0)
        index = [:]
        for (i, id) in parseFeatureList(list).enumerated() { index[id] = UInt8(i) }
    }

    public func supports(_ f: FeatureID) -> Bool { index[f.rawValue] != nil }

    private func call(_ f: FeatureID, _ fn: UInt8, _ args: [UInt8] = []) async throws -> [UInt8] {
        guard let i = index[f.rawValue] else { throw A30Error.unsupported }
        return try await link.request(i, fn, args)
    }

    private func decoded<T>(_ v: T?) throws -> T {
        guard let v else { throw A30Error.badReply }
        return v
    }

    // MARK: reads

    public func battery() async throws -> Battery { let a = try await call(.battery, 0); return try decoded(Battery(a)) }
    public func name() async throws -> String { let a = try await call(.deviceName, 0); return try decoded(parseName(a)) }
    public func firmware() async throws -> String { let a = try await call(.deviceInfo, 1); return try decoded(parseFirmware(a)) }
    public func serial() async throws -> String { let a = try await call(.deviceInfo, 2); return try decoded(parseLengthString(a[...])) }
    public func volume() async throws -> Int { let a = try await call(.volume, 0); return try decoded(a.first.map { Int($0) }) }
    public func eq() async throws -> EQSetting { let a = try await call(.eq, 0); return try decoded(EQSetting(a)) }
    public func eqModes() async throws -> [UInt8] { Array(try await call(.eq, 2).dropFirst()) }
    public func sidetone() async throws -> [Mic: Int] { parseMicValues(try await call(.sidetone, 0)) }
    public func noiseGate() async throws -> [Mic: NoiseGate] {
        parseMicValues(try await call(.noiseGate, 0)).compactMapValues { NoiseGate(rawValue: UInt8($0)) }
    }
    public func balance() async throws -> Int { let a = try await call(.mix, 0); return try decoded(a.first.map { Int($0) }) }
    public func dongle() async throws -> DongleStatus { DongleStatus(try await call(.dongle, 0).first ?? 0) }
    public func sleepTimer() async throws -> SleepTimer {
        let a = try await call(.autoSleep, 0); return try decoded(a.first.flatMap(SleepTimer.init(rawValue:)))
    }
    public func tones() async throws -> Tones {
        let a = try await call(.tones, 0); return try decoded(a.first.flatMap(Tones.init(rawValue:)))
    }

    // MARK: writes

    /// `switching`: the mode differs from the current one. Like the official app, a switch to
    /// any mode other than Immersive/Footstep first passes through Immersive.
    public func setEQ(_ s: EQSetting, switching: Bool) async throws {
        let direct = s.mode == EQMode.immersive.rawValue || s.mode == EQMode.footstep.rawValue
        if switching && !direct {
            _ = try await call(.eq, 1, EQSetting(mode: EQMode.immersive.rawValue, bands: [0, 0, 0, 0, 0]).wire)
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await call(.eq, 1, s.wire)
    }
    public func setSidetone(_ mic: Mic, _ percent: Int) async throws {
        _ = try await call(.sidetone, 1, [mic.rawValue, UInt8(min(max(percent, 0), 100))])
    }
    public func setNoiseGate(_ mic: Mic, _ g: NoiseGate) async throws { _ = try await call(.noiseGate, 1, [mic.rawValue, g.rawValue]) }
    public func setBalance(_ v: Int) async throws { _ = try await call(.mix, 1, [UInt8(min(max(v, 0), 20))]) }
    public func setSleepTimer(_ t: SleepTimer) async throws { _ = try await call(.autoSleep, 1, [t.rawValue, t.rawValue]) }
    public func setTones(_ t: Tones) async throws { _ = try await call(.tones, 1, [t.rawValue]) }

    /// Erases all headset settings (iDeviceInfo FACTORY_RESET with the serial GET_SERIAL_NUMBER
    /// returned). The official app sends the user through re-pairing afterwards.
    public func factoryReset(serial: String) async throws {
        _ = try await call(.deviceInfo, 4, lengthPrefixed(serial))
    }
}
```

- [ ] **Step 3: Write the probe and `probe.sh`**

`A30Control/Probe/main.swift`:

```swift
// Hardware smoke test for A30Kit. Default: read everything. --writes: change + read back +
// restore sidetone (boom) and EQ mode. Never touches factory reset or DFU.
import Foundation

@main
struct Probe {
    static func main() {
        Task { @MainActor in
            let a = A30()
            do {
                try await a.connect()
                print("battery", try await a.battery())
                print("name", try await a.name(), "fw", try await a.firmware(), "serial", try await a.serial())
                print("volume", try await a.volume(), "eq", try await a.eq(), "modes", hex(try await a.eqModes()))
                print("sidetone", try await a.sidetone(), "noiseGate", try await a.noiseGate())
                print("balance", try await a.balance(), "dongle", try await a.dongle())
                print("sleep", try await a.sleepTimer(), "tones", try await a.tones())
                if CommandLine.arguments.contains("--writes") {
                    let st = try await a.sidetone()[.boom] ?? 40
                    try await a.setSidetone(.boom, st == 40 ? 30 : 40)
                    print("sidetone after set", try await a.sidetone())
                    try await a.setSidetone(.boom, st)
                    print("sidetone restored", try await a.sidetone())
                    let eq = try await a.eq()
                    try await a.setEQ(EQSetting(mode: EQMode.footstep.rawValue, bands: [0, 0, 0, 0, 0]), switching: true)
                    print("eq after set", try await a.eq())
                    try await a.setEQ(eq, switching: true)
                    print("eq restored", try await a.eq())
                    do { try await a.setBalance(10) } catch { print("balance set ->", error) }
                }
                print("PROBE OK")
                exit(0)
            } catch {
                print("PROBE ERROR", error)
                exit(1)
            }
        }
        RunLoop.main.run()   // IOBluetooth callbacks need the main run loop
    }
}
```

`A30Control/probe.sh`:

```sh
#!/bin/sh
# Builds build/A30Probe.app (A30Kit + Probe) and runs it via `open` so TCC accepts Bluetooth.
# Usage: ./probe.sh [--writes]
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -parse-as-library -O -o build/A30Probe Sources/A30Kit/*.swift Probe/main.swift -framework IOBluetooth
APP=build/A30Probe.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp build/A30Probe "$APP/Contents/MacOS/A30Probe"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.a30control.probe</string>
<key>CFBundleExecutable</key><string>A30Probe</string>
<key>CFBundleName</key><string>A30Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Talk to the ASTRO A30 control channel.</string>
</dict></plist>
EOF
xattr -cr "$APP"
codesign -s - -f "$APP"
rm -f build/probe.log
open -W -n --stdout "$PWD/build/probe.log" --stderr "$PWD/build/probe.log" "$APP" --args "$@"
cat build/probe.log
```

- [ ] **Step 4: Run the probe on hardware**

Run: `chmod +x A30Control/probe.sh && A30Control/probe.sh`

Expected: a line for each value, then `PROBE OK`. Values on Doug's unit:
- battery `percent: 40` (± drain)
- name `ASTRO A30`, fw `1.0.59`, serial `224`, volume `30`
- eq mode `4` with flat bands, modes `04 80 81`
- sidetone 40 / 40, noise gate off / off
- balance `20`, dongle `connected: false`
- sleep `never`, tones `minimal`

If `openComplete` never arrives, the 8 s timeout prints the stale-channel message. Run the probe again.

- [ ] **Step 5: Run the write round-trip**

Run: `A30Control/probe.sh --writes`

Expected:
- sidetone boom changes, then is restored to its original value
- EQ mode changes to `129` (Footstep), then is restored to `4`
- the balance set prints `device(notConnected)` (no dongle)
- `PROBE OK`

- [ ] **Step 6: Checkpoint**

Run: `A30Control/test.sh`
Expected: `selftest: all passed` (the pure sources still compile without IOBluetooth).

---

### Task 5: Model, app shell, menu bar panel, `build.sh`

**Files:**
- Create: `A30Control/Sources/A30App/HeadsetModel.swift`
- Create: `A30Control/Sources/A30App/A30ControlApp.swift`
- Create: `A30Control/Sources/A30App/Views/Components.swift`
- Create: `A30Control/Sources/A30App/Views/MenuBarPanel.swift`
- Create: `A30Control/Sources/A30App/Views/MainWindow.swift` (placeholder detail until Task 6)
- Create: `A30Control/Info.plist`, `A30Control/build.sh`

**Interfaces:**
- Consumes (Task 4): `A30` and all of its methods, `HeadsetLink.onClose`.
- Produces:
  - `enum Pane: String, CaseIterable, Identifiable` (`home`, `eq`, `microphone`, `settings`; `icon`)
  - `@Observable @MainActor final class HeadsetModel` with:
    - `static let shared`
    - State: `connection`, `battery`, `name`, `firmware`, `serial`, `volume`, `eq`, `eqModes: [EQMode]`, `sidetone: [Mic: Int]`, `noiseGate: [Mic: NoiseGate]`, `balance`, `dongle`, `sleep`, `tones`, `banner`
    - View state: `pane`, `micTab`, `showResetAlert`, `showResetSheet`, `resetText`
    - `menuTitle`, `start()`, `refreshAll()`
    - Writes: `selectEQ(_:)`, `setBand(_:_:)`, `commitEQ()`, `resetFlat()`, `commitSidetone(_:)`, `setNoiseGate(_:_:)`, `commitBalance()`, `setSleep(_:)`, `setTones(_:)`, `factoryReset()`
  - Views: `Card`, `BannerView`, `ConnectionOverlay`, `View.headsetChrome(_:)`, `EQModePicker`, `SidetoneSlider`, `BalanceSlider`, `BatteryLabel`, `MenuBarPanel`, `MainWindow`

- [ ] **Step 1: Implement `HeadsetModel.swift`**

```swift
// Single source of truth for both the menu bar panel and the window.
// View-local state lives here too: the macOS 27 SDK's @State needs a macro plugin that only
// Xcode ships, so views bind to this model with Binding(get:set:).
import Foundation
import Observation

enum Pane: String, CaseIterable, Identifiable {
    case home = "Home", eq = "EQ", microphone = "Microphone", settings = "Settings"
    var id: Self { self }
    var icon: String {
        switch self {
        case .home: "headphones"
        case .eq: "slider.vertical.3"
        case .microphone: "mic"
        case .settings: "gearshape"
        }
    }
}

@Observable @MainActor
final class HeadsetModel {
    static let shared = HeadsetModel()

    enum Connection: Equatable { case searching, connected, failed(String) }

    var connection: Connection = .searching
    var battery: Battery?
    var name = "ASTRO A30"
    var firmware = "—"
    var serial = "—"
    var volume: Int?
    var eq: EQSetting?
    var eqModes: [EQMode] = EQMode.allCases
    var sidetone: [Mic: Int] = [:]
    var noiseGate: [Mic: NoiseGate] = [:]
    var balance: Int?
    var dongle = DongleStatus(0)
    var sleep: SleepTimer?
    var tones: Tones?
    var banner: String?

    // view state
    var pane: Pane = .home
    var micTab: Mic = .boom
    var showResetAlert = false
    var showResetSheet = false
    var resetText = ""

    var menuTitle: String { battery.map { "\($0.percent)%" } ?? "" }

    private let a30 = A30()
    private var started = false
    private var pollTask: Task<Void, Never>?

    func start() {
        guard !started else { return }
        started = true
        a30.link.onClose = { [weak self] in self?.disconnected() }
        Task { await connectLoop() }
    }

    private func connectLoop() async {
        while true {
            connection = .searching
            do {
                try await a30.connect()
                connection = .connected
                await refreshAll()
                startPolling()
                return
            } catch {
                connection = .failed(message(error))
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func disconnected() {
        pollTask?.cancel()
        Task { await connectLoop() }
    }

    /// Each read is independent, so one unsupported feature does not hide the rest.
    func refreshAll() async {
        if let v = try? await a30.battery() { battery = v }
        if let v = try? await a30.name() { name = v }
        if let v = try? await a30.firmware() { firmware = v }
        if let v = try? await a30.serial() { serial = v }
        volume = try? await a30.volume()
        eq = try? await a30.eq()
        if let m = try? await a30.eqModes() { eqModes = m.compactMap(EQMode.init(rawValue:)) }
        sidetone = (try? await a30.sidetone()) ?? [:]
        noiseGate = (try? await a30.noiseGate()) ?? [:]
        balance = try? await a30.balance()
        if let d = try? await a30.dongle() { dongle = d }
        sleep = try? await a30.sleepTimer()
        tones = try? await a30.tones()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.connection == .connected else { return }
                if let b = try? await self.a30.battery() { self.battery = b }
                if let d = try? await self.a30.dongle() { self.dongle = d }
            }
        }
    }

    // MARK: writes — every SET is followed by a GET; the UI shows what the headset reports

    private func write(_ op: () async throws -> Void, reread: () async -> Void) async {
        do { try await op() } catch { show(message(error)) }
        await reread()
    }

    func selectEQ(_ mode: EQMode) {
        let switching = eq?.mode != mode.rawValue
        let flat = [0, 0, 0, 0, 0]
        let bands = (mode == .custom && !switching) ? (eq?.bands ?? flat) : flat
        let target = EQSetting(mode: mode.rawValue, bands: bands)
        Task { await write({ try await a30.setEQ(target, switching: switching) }, reread: { eq = try? await a30.eq() }) }
    }

    /// Slider drag: local only. `commitEQ` sends it when the slider is released.
    func setBand(_ i: Int, _ db: Int) { eq?.bands[i] = db }

    func commitEQ() {
        guard let e = eq else { return }
        Task { await write({ try await a30.setEQ(e, switching: false) }, reread: { eq = try? await a30.eq() }) }
    }

    func resetFlat() {
        eq?.bands = [0, 0, 0, 0, 0]
        commitEQ()
    }

    func commitSidetone(_ mic: Mic) {
        guard let v = sidetone[mic] else { return }
        Task {
            await write({ try await a30.setSidetone(mic, v) },
                        reread: { if let s = try? await a30.sidetone() { sidetone = s } })
        }
    }

    func setNoiseGate(_ mic: Mic, _ g: NoiseGate) {
        noiseGate[mic] = g
        Task {
            await write({ try await a30.setNoiseGate(mic, g) },
                        reread: { if let n = try? await a30.noiseGate() { noiseGate = n } })
        }
    }

    func commitBalance() {
        guard let v = balance else { return }
        Task { await write({ try await a30.setBalance(v) }, reread: { balance = try? await a30.balance() }) }
    }

    func setSleep(_ t: SleepTimer) {
        sleep = t
        Task { await write({ try await a30.setSleepTimer(t) }, reread: { sleep = try? await a30.sleepTimer() }) }
    }

    func setTones(_ t: Tones) {
        tones = t
        Task { await write({ try await a30.setTones(t) }, reread: { tones = try? await a30.tones() }) }
    }

    /// Only reachable from the Settings alert → sheet with "RESET" typed.
    func factoryReset() {
        guard resetText == "RESET" else { return }
        showResetSheet = false
        resetText = ""
        Task {
            do {
                let s = try await a30.serial()
                try await a30.factoryReset(serial: s)
                show("Factory reset sent. Re-pair the headset if it disconnects.")
            } catch {
                show(message(error))
            }
            await refreshAll()
        }
    }

    // MARK: helpers

    func show(_ msg: String) {
        banner = msg
        Task {
            try? await Task.sleep(for: .seconds(4))
            if banner == msg { banner = nil }
        }
    }

    func message(_ e: Error) -> String { (e as? A30Error)?.message ?? e.localizedDescription }
}
```

- [ ] **Step 2: Implement `Components.swift`**

```swift
import SwiftUI

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThickMaterial))
        .padding(10)
    }
}

struct ConnectionOverlay: View {
    let connection: HeadsetModel.Connection

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Looking for ASTRO A30…").font(.headline)
            if case .failed(let why) = connection {
                Text(why).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text("Make sure the headset is on and connected to this Mac.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

extension View {
    /// Error banner on top, disconnected overlay while not connected.
    func headsetChrome(_ model: HeadsetModel) -> some View {
        overlay(alignment: .top) {
            if let b = model.banner { BannerView(text: b) { model.banner = nil } }
        }
        .overlay {
            if model.connection != .connected { ConnectionOverlay(connection: model.connection) }
        }
    }
}

struct BatteryLabel: View {
    let battery: Battery?

    var body: some View {
        if let b = battery {
            Label("\(b.percent)%", systemImage: b.isCharging ? "battery.100.bolt" : "battery.50")
                .monospacedDigit()
        } else {
            Label("—", systemImage: "battery.0")
        }
    }
}

struct EQModePicker: View {
    let model: HeadsetModel

    var body: some View {
        Picker("EQ", selection: Binding(
            get: { EQMode(rawValue: model.eq?.mode ?? EQMode.custom.rawValue) ?? .custom },
            set: { model.selectEQ($0) })
        ) {
            ForEach(model.eqModes, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(model.eq == nil)
    }
}

struct SidetoneSlider: View {
    let model: HeadsetModel
    let mic: Mic

    var body: some View {
        HStack {
            Text("Sidetone")
            Slider(value: Binding(get: { Double(model.sidetone[mic] ?? 0) },
                                  set: { model.sidetone[mic] = Int($0) }),
                   in: 0...100, step: 1,
                   onEditingChanged: { editing in if !editing { model.commitSidetone(mic) } })
            Text("\(model.sidetone[mic] ?? 0)%").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .disabled(model.sidetone[mic] == nil)
    }
}

/// 0…20 on the wire = game share (0 % … 100 %), like the official app.
struct BalanceSlider: View {
    let model: HeadsetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Chat")
                Slider(value: Binding(get: { Double(model.balance ?? 10) },
                                      set: { model.balance = Int($0) }),
                       in: 0...20, step: 1,
                       onEditingChanged: { editing in if !editing { model.commitBalance() } })
                Text("Game")
            }
            .disabled(!model.dongle.connected || model.balance == nil)
            if !model.dongle.connected {
                Text("Connect the 2.4 GHz dongle to mix game and chat.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 3: Implement `MenuBarPanel.swift`, `MainWindow.swift` (Home only for now), `A30ControlApp.swift`**

`MenuBarPanel.swift`:

```swift
import SwiftUI
import AppKit

struct MenuBarPanel: View {
    let model: HeadsetModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.name).font(.headline)
                Spacer()
                BatteryLabel(battery: model.battery)
            }
            if model.connection == .connected {
                EQModePicker(model: model)
                SidetoneSlider(model: model, mic: .boom)
                BalanceSlider(model: model)
            } else {
                Text("Looking for ASTRO A30…").foregroundStyle(.secondary)
            }
            if let b = model.banner { Text(b).font(.caption).foregroundStyle(.yellow) }
            Divider()
            HStack {
                Button("Open window…") {
                    NSApp.activate()
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .preferredColorScheme(.dark)
    }
}
```

`MainWindow.swift`:

```swift
import SwiftUI

struct MainWindow: View {
    let model: HeadsetModel

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { Optional(model.pane) },
                                                  set: { if let p = $0 { model.pane = p } })) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.pane {
                    case .home: HomeView(model: model)
                    case .eq: Text("EQ")          // Task 6
                    case .microphone: Text("Microphone")   // Task 6
                    case .settings: Text("Settings")       // Task 7
                    }
                }
                .padding(20)
            }
        }
        .headsetChrome(model)
        .frame(minWidth: 680, minHeight: 480)
        .preferredColorScheme(.dark)
    }
}

struct HomeView: View {
    let model: HeadsetModel

    var body: some View {
        Text(model.name).font(.largeTitle.bold())
        HStack(alignment: .top, spacing: 16) {
            Card(title: "Battery") {
                BatteryLabel(battery: model.battery).font(.title2)
                if model.battery?.isCharging == true { Text("Charging").foregroundStyle(.secondary) }
            }
            Card(title: "Connection") {
                Label("Bluetooth connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label(model.dongle.connected ? "Dongle connected" : "Dongle not connected",
                      systemImage: model.dongle.connected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.dongle.connected ? .green : .secondary)
            }
        }
        Card(title: "Volume") {
            ProgressView(value: Double(model.volume ?? 0), total: 31)
            Text("\(model.volume ?? 0) / 31 (set with the headset's volume wheel)").font(.caption).foregroundStyle(.secondary)
        }
        Card(title: "Game / chat balance") { BalanceSlider(model: model) }
    }
}
```

`A30ControlApp.swift`:

```swift
import SwiftUI

@main
struct A30ControlApp: App {
    private let model = HeadsetModel.shared

    init() { HeadsetModel.shared.start() }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            Image(systemName: "headphones")
            Text(model.menuTitle)
        }
        .menuBarExtraStyle(.window)

        Window("A30 Control", id: "main") {
            MainWindow(model: model)
        }
        .defaultSize(width: 780, height: 560)
    }
}
```

- [ ] **Step 4: Write `Info.plist` and `build.sh`**

`A30Control/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.a30control</string>
<key>CFBundleExecutable</key><string>A30Control</string>
<key>CFBundleName</key><string>A30 Control</string>
<key>CFBundleDisplayName</key><string>A30 Control</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>A30 Control talks to your ASTRO A30 over Bluetooth to change its settings.</string>
</dict></plist>
```

`A30Control/build.sh`:

```sh
#!/bin/sh
# Builds "build/A30 Control.app". Launch it with:  open "build/A30 Control.app"
# (Running the binary directly crashes: TCC needs the bundle's Bluetooth usage string.)
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -parse-as-library -O -o build/A30Control \
  Sources/A30Kit/*.swift Sources/A30App/*.swift Sources/A30App/Views/*.swift \
  -framework IOBluetooth
APP="build/A30 Control.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp build/A30Control "$APP/Contents/MacOS/A30Control"
cp Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign -s - -f "$APP"
echo "Built $APP — run: open \"$APP\""
```

- [ ] **Step 5: Build**

Run: `chmod +x A30Control/build.sh && A30Control/build.sh`
Expected: `Built build/A30 Control.app — run: open "build/A30 Control.app"`, with no `error:` lines. If the compiler reports `external macro implementation type 'SwiftUIMacros…' could not be found`, a SwiftUI state wrapper slipped in. Replace it with model state and `Binding(get:set:)`.

- [ ] **Step 6: Launch and check the menu bar (hardware)**

Run: `open "A30Control/build/A30 Control.app"`

Expected:
- The first launch shows the Bluetooth permission prompt; allow it.
- A headphones icon appears in the menu bar with `40%` (or the current battery level) next to it.
- Clicking it shows the EQ segmented control on Custom, boom sidetone at 40 %, and the balance slider greyed out with the dongle hint.
- The window opens with Home showing battery, "Dongle not connected" and volume 30 / 31.

Review Focus #5: run `"A30Control/build/A30 Control.app/Contents/MacOS/A30Control"` directly. Expected: it aborts (TCC). That is the known limitation, so `build.sh`'s message tells you to use `open`.

- [ ] **Step 7: Checkpoint**

Run: `A30Control/test.sh`
Expected: `selftest: all passed`.

---

### Task 6: EQ and Microphone panes

**Files:**
- Create: `A30Control/Sources/A30App/Views/EQView.swift`
- Create: `A30Control/Sources/A30App/Views/MicrophoneView.swift`
- Modify: `A30Control/Sources/A30App/Views/MainWindow.swift` (the `.eq` and `.microphone` cases)

**Interfaces:**
- Consumes (Task 5): `HeadsetModel.eq`, `eqModes`, `selectEQ`, `setBand`, `commitEQ`, `resetFlat`, `micTab`, `sidetone`, `commitSidetone`, `noiseGate`, `setNoiseGate`; the `Card`, `EQModePicker` and `SidetoneSlider` views.
- Produces: `EQView(model:)`, `MicrophoneView(model:)`.

- [ ] **Step 1: Implement `EQView.swift`**

```swift
import SwiftUI

struct EQView: View {
    let model: HeadsetModel

    private var isCustom: Bool { model.eq?.mode == EQMode.custom.rawValue }

    var body: some View {
        Text("EQ").font(.largeTitle.bold())
        Card(title: "Preset") { EQModePicker(model: model) }
        Card(title: isCustom ? "Custom bands" : "Custom bands (select Custom to edit)") {
            HStack(alignment: .bottom, spacing: 18) {
                ForEach(0..<5, id: \.self) { i in band(i) }
            }
            .frame(maxWidth: .infinity)
            .disabled(!isCustom)
            HStack {
                Spacer()
                Button("Reset flat") { model.resetFlat() }.disabled(!isCustom)
            }
        }
    }

    private func band(_ i: Int) -> some View {
        let db = model.eq?.bands[i] ?? 0
        return VStack(spacing: 8) {
            Text(db > 0 ? "+\(db) dB" : "\(db) dB").monospacedDigit().font(.caption)
            Slider(value: Binding(get: { Double(model.eq?.bands[i] ?? 0) },
                                  set: { model.setBand(i, Int($0.rounded())) }),
                   in: Double(EQSetting.gainRange.lowerBound)...Double(EQSetting.gainRange.upperBound),
                   step: 1,
                   onEditingChanged: { editing in if !editing { model.commitEQ() } })
                .frame(width: 180)
                .rotationEffect(.degrees(-90))
                .frame(width: 44, height: 180)
            Text(EQSetting.bandLabels[i]).font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Implement `MicrophoneView.swift`**

```swift
import SwiftUI

struct MicrophoneView: View {
    let model: HeadsetModel

    var body: some View {
        Text("Microphone").font(.largeTitle.bold())
        Picker("Mic", selection: Binding(get: { model.micTab }, set: { model.micTab = $0 })) {
            ForEach(Mic.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Card(title: "Sidetone") {
            SidetoneSlider(model: model, mic: model.micTab)
            Text("How much of your own voice you hear in the headset.").font(.caption).foregroundStyle(.secondary)
        }
        Card(title: "Noise gate") {
            Picker("Noise gate", selection: Binding(
                get: { model.noiseGate[model.micTab] ?? .off },
                set: { model.setNoiseGate(model.micTab, $0) })
            ) {
                ForEach(NoiseGate.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.noiseGate[model.micTab] == nil)
            Text("How loud you must speak before the microphone picks you up.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Wire them into `MainWindow.swift`**

Replace the two placeholder cases:

```swift
                    case .eq: EQView(model: model)
                    case .microphone: MicrophoneView(model: model)
```

- [ ] **Step 4: Build and verify on hardware**

Run: `A30Control/build.sh && open "A30Control/build/A30 Control.app"`

Expected, in the window:
- **EQ, mode switch:** Immersive, then Footstep, then Custom. Each time the segmented control lands on the chosen mode after the re-read, and you hear the change.
- **EQ, custom band:** in Custom, drag 31 Hz to +6 and release. The label shows `+6 dB` after the re-read.
- **EQ, reset:** "Reset flat" sets every band to 0.
- **Microphone, sidetone:** on the Boom tab, set sidetone to 60 % and release. You hear more of your own voice, and the value stays at 60 after the re-read. Set it back to 40.
- **Microphone, noise gate:** select Night, then Off. Both stay selected after the re-read.

Leave the headset as you found it: Custom flat, sidetone 40 / 40, noise gate Off / Off.

- [ ] **Step 5: Checkpoint**

Run: `A30Control/test.sh`
Expected: `selftest: all passed`.

---

### Task 7: Settings pane and factory-reset flow

**Files:**
- Create: `A30Control/Sources/A30App/Views/SettingsView.swift`
- Modify: `A30Control/Sources/A30App/Views/MainWindow.swift` (the `.settings` case)

**Interfaces:**
- Consumes (Task 5): `HeadsetModel.name`, `firmware`, `serial`, `sleep`, `setSleep`, `tones`, `setTones`, `showResetAlert`, `showResetSheet`, `resetText`, `factoryReset()`; the `Card` view.
- Produces: `SettingsView(model:)`.

- [ ] **Step 1: Implement `SettingsView.swift`**

```swift
import SwiftUI

struct SettingsView: View {
    let model: HeadsetModel

    var body: some View {
        Text("Settings").font(.largeTitle.bold())
        Card(title: "Device") {
            row("Name", model.name)
            row("Firmware", model.firmware)
            row("Serial", model.serial)
        }
        Card(title: "Sleep mode") {
            Picker("Turn off after", selection: Binding(get: { model.sleep ?? .never },
                                                        set: { model.setSleep($0) })) {
                ForEach(SleepTimer.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(model.sleep == nil)
        }
        Card(title: "Tones") {
            Picker("Tones", selection: Binding(get: { model.tones ?? .minimal },
                                               set: { model.setTones($0) })) {
                ForEach(Tones.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.tones == nil)
        }
        Card(title: "Factory reset") {
            Text("Erases every headset setting. You may need to re-pair the headset afterwards.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Factory reset…", role: .destructive) { model.showResetAlert = true }
        }
        .alert("Factory reset the headset?",
               isPresented: Binding(get: { model.showResetAlert }, set: { model.showResetAlert = $0 })) {
            Button("Continue", role: .destructive) { model.resetText = ""; model.showResetSheet = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases all headset settings; you may need to re-pair it.")
        }
        .sheet(isPresented: Binding(get: { model.showResetSheet }, set: { model.showResetSheet = $0 })) {
            ResetSheet(model: model)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).textSelection(.enabled) }
    }
}

private struct ResetSheet: View {
    let model: HeadsetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Type RESET to confirm").font(.headline)
            TextField("RESET", text: Binding(get: { model.resetText }, set: { model.resetText = $0 }))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { model.showResetSheet = false; model.resetText = "" }
                    .keyboardShortcut(.cancelAction)
                Button("Factory reset", role: .destructive) { model.factoryReset() }
                    .disabled(model.resetText != "RESET")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
```

- [ ] **Step 2: Wire it into `MainWindow.swift`**

```swift
                    case .settings: SettingsView(model: model)
```

- [ ] **Step 3: Build and verify on hardware (without resetting)**

Run: `A30Control/build.sh && open "A30Control/build/A30 Control.app"`

Expected in Settings:
- **Device:** Name `ASTRO A30`, Firmware `1.0.59`, Serial `224`.
- **Sleep mode:** set it to 15 minutes. It stays at 15 after the re-read. Set it back to **Never**, because Doug wants auto-sleep off.
- **Tones:** select All, then Minimal (the original). Each one stays selected after the re-read.
- **Factory reset gating:**
  1. Click "Factory reset…": the alert appears. Cancel.
  2. Open it again and Continue: the sheet appears.
  3. Type `RES`: the "Factory reset" button stays disabled.
  4. Click Cancel. **Do not run the reset** unless Doug explicitly asks for it.

- [ ] **Step 4: Checkpoint**

Run: `A30Control/test.sh`
Expected: `selftest: all passed`.

---

### Task 8: Robustness on hardware and docs

**Files:**
- Modify: `CLAUDE.md` (add an "A30 Control app" section and an entry under Files)

**Interfaces:**
- Consumes: the built app from Tasks 5–7.
- Produces: verified behaviour for every Review Focus item, plus documentation.

- [ ] **Step 1: Build the final app**

Run: `A30Control/test.sh && A30Control/build.sh`
Expected: `selftest: all passed`, then `Built build/A30 Control.app`.

- [ ] **Step 2: Headset off at launch (Review Focus #1)**

1. Power the headset off and quit the app.
2. Run `open "A30Control/build/A30 Control.app"`.

Expected: the window shows the "Looking for ASTRO A30…" overlay with the error text, and there is no crash. Power the headset on: the overlay disappears within about 15 s and values load.

- [ ] **Step 3: Power off mid-session (Review Focus #2)**

With the app connected, power the headset off.

Expected: the overlay appears within a few seconds (the channel closes, or 3 timeouts), and the menu and window stay responsive. Power it back on: the app reconnects by itself.

- [ ] **Step 4: Stale channel (Review Focus #3)**

Quit the app, run `./run.sh` at the repo root (a30b), then open the app right away.

Expected: it connects, possibly after one 8 s timeout and a retry.

- [ ] **Step 5: iPhone app competing (Review Focus #4)**

Open the Logitech G app on the iPhone, connected to the headset, then open A30 Control.

Expected: either it connects, or the overlay shows an error and keeps retrying (no hang). Close the iPhone app: A30 Control connects on its next retry.

- [ ] **Step 6: Document in `CLAUDE.md`**

Add this section above `## Reference: BLE GATT map`:

````markdown
## A30 Control app (`A30Control/`)

Native macOS app: menu bar (battery %, EQ preset, boom sidetone, balance) + window
(Home, EQ, Microphone, Settings incl. factory reset). Spec:
`docs/superpowers/specs/2026-11-10-a30-control-app-design.md`, plan:
`docs/superpowers/plans/2026-11-10-a30-control-app.md`.

```bash
A30Control/test.sh                       # pure protocol tests, no headset
A30Control/build.sh                      # → A30Control/build/A30 Control.app
open "A30Control/build/A30 Control.app"  # must be launched via open/Finder (TCC)
A30Control/probe.sh [--writes]           # hardware smoke test of A30Kit
```

Toolchain notes: SwiftPM is broken with these Command Line Tools and SwiftUI's
`@State`/`@Binding` are macros needing Xcode's plugin — so everything is built with
`swiftc` and all view state lives in the `@Observable` `HeadsetModel`.
````

Add this line under `## Files`:

```markdown
- `A30Control/` — the macOS app (A30Kit protocol + SwiftUI); see "A30 Control app"
```

- [ ] **Step 7: Final checkpoint**

Run: `A30Control/test.sh`
Expected: `selftest: all passed`.
