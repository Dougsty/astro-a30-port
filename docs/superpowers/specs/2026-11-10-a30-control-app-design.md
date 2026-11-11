# A30 Control — macOS app design

Date: 2026-11-10
Status: approved in chat (sections 1–3), awaiting spec review

## Goal

A native macOS app that controls Doug's ASTRO A30 headset without the Logitech G
app, with the controls the official iPhone app offers on this headset. Success =
open the app, see the headset connected, change EQ / mic / settings with no
terminal, and every value shown is what the headset actually reports.

Protocol, transport and every command used here are already proven against the
real headset — see `CLAUDE.md` (iAP2 over RFCOMM ch 26, EA protocol
`com.logitech.ag.carbonite`, CPP feature map, error codes). The decompiled app in
`jadx/` is the reference for value encodings.

## Scope

In v1:

- Menu bar extra (quick controls) **and** a full window (detailed settings).
- EQ: preset Custom / Astro Immersive / Astro Footstep; 5 custom band gains.
- Microphone: sidetone and noise gate, per mic (internal = 0, boom = 1).
- Game/chat balance (disabled unless the 2.4 GHz dongle is connected).
- Device settings: battery, name (read-only), firmware, serial, sleep mode, tones.
- Factory reset behind a double confirmation.

Out of v1: advanced parametric EQ (A50 X only), profiles (A30 has one active),
firmware update / anything in `iGenericDFU`, renaming, spontaneous device
notifications (logged, not acted on).

Constraint: no Xcode on this Mac (Command Line Tools only, Swift 6.4, macOS 27).

## Architecture

```
A30Control/
├─ Sources/A30Kit/               protocol, no UI
│   ├─ Framing.swift             CRC-16/MCRF4XX, SPP wrap/parse, CPL fragment reassembly,
│   │                            iAP2 link packets + checksums, control messages/params
│   ├─ IAP2Session.swift         pure state machine: detect → SYN/SYN+ACK → auth (cert not
│   │                            verified) → identification → StartExternalAccessoryProtocolSession
│   ├─ Codecs.swift              feature ids, error codes, typed values and their byte codecs
│   ├─ HeadsetLink.swift         IOBluetooth RFCOMM ch 26 + one-in-flight request queue
│   │                            (match by feature index + swId, 1.5 s timeout), async API
│   └─ A30.swift                 typed API over feature *ids* (indexes resolved at connect)
├─ Sources/A30App/
│   ├─ A30ControlApp.swift       MenuBarExtra + Window sharing one HeadsetModel
│   ├─ HeadsetModel.swift        @Observable state, connect / reconnect / polling
│   └─ Views/                    MenuBarPanel, MainWindow (+Home), EQ, Microphone, Settings
├─ Probe/main.swift              hardware smoke test of A30Kit
├─ Tests/                        selftest runner + framing / iAP2 / codec tests
└─ build.sh, test.sh, probe.sh   swiftc → "A30 Control.app" / selftest / A30Probe.app
                                 (Info.plist with NSBluetoothAlwaysUsageDescription,
                                 ad-hoc codesign, xattr -cr)
```

Toolchain findings (2026-11-10): SwiftPM cannot link `Package.swift` with these
Command Line Tools, and the macOS 27 SDK's SwiftUI `@State`/`@Binding` are macros
whose plugin ships only with Xcode. So everything is compiled with plain `swiftc`,
and all view state lives in the `@Observable` `HeadsetModel` with explicit
`Binding(get:set:)` (`@Observable` and `@Environment` compile fine).

- `A30Kit` is `a30b.swift` split into units with one job each. `Framing.swift`,
  `IAP2Session.swift` and `Codecs.swift` have no IOBluetooth dependency so they are testable.
- `a30b.swift` / `build.sh` / `run.sh` at the repo root stay as the diagnostic
  tool (`--seq`, `--sdp`). Nothing is deleted.
- The app must be launched as a bundle (Finder / `open`) so it is its own TCC
  responsible process (see "TCC gotcha" in `CLAUDE.md`).

### A30Kit API (v1)

All `async throws`; errors are `A30Error` (`.timeout`, `.disconnected`,
`.device(CenturionError)`, `.unsupported`).

| Call | Feature (id) | Wire |
|---|---|---|
| `battery()` | iBatterySOC 0x0104 fn0 | → `[realSOC, userSOC, charging]`; show userSOC |
| `deviceInfo()` | iDeviceInfo 0x0100 fn0–2, iDeviceName 0x0101 fn0 | name `[max, len, text]` |
| `volume()` | iVolumeSet 0x0200 fn0 | → `[level, 0]`, 0–31 |
| `eq()` / `setEQ(mode:bands:)` | iEQSet (HeadsetEQSet) 0x0201 fn0 / fn1 | `[mode, b0..b4]`, modes 0x04 / 0x80 / 0x81, band byte = dB × 10 (signed) |
| `eqModes()` | 0x0201 fn2 | → `[count, modes…]` |
| `sidetone()` / `setSidetone(mic:level:)` | iHeadsetAudioSidetone 0x0604 fn0 / fn1 | GET `[count,(mic,level)*]`, SET `[mic, level]`, level 0–100 % (feature v2 would be `[mic, 0xFF, level]`; A30 is v1) |
| `noiseGate()` / `setNoiseGate(mic:value:)` | iHeadsetNoiseGate 0x0608 fn0 / fn1 | GET `[count,(mic,value)*]`, SET `[mic, value]`, 0 Off / 1 Night / 2 Home / 3 Tournament |
| `balance()` / `setBalance(_:)` | iHeadsetMix 0x0609 fn0 / fn1 | `[n]`, 0–20, needs dongle |
| `dongle()` | iHeadsetDongle 0x060A fn0 | bit0 connected, bit1 Xbox, bit2 host type |
| `sleepTimer()` / `setSleepTimer(minutes:)` | iAutoSleep 0x0108 fn0 / fn1 | `[m, m]`, m ∈ {0, 15, 30, 60} |
| `tones()` / `setTones(_:)` | iHeadsetTones 0x060B fn0 / fn1 | `[state]`, 0 None / 1 All / 2 Minimal |
| `factoryReset(serial:)` | iDeviceInfo 0x0100 fn4 | `[len, utf8]` = the exact string GET_SERIAL_NUMBER returned |

No raw-command entry point is exported from `A30Kit`. `factoryReset` is the only
destructive call and is used only by the confirmation flow. No `iGenericDFU`
(0x010A) call exists anywhere.

## Screens

Dark theme inspired by the Logitech G app.

**Menu bar** — headphones icon + battery %. Panel: EQ segmented control,
boom-mic sidetone slider, game/chat balance slider (greyed with hint when no
dongle), "Open window…", "Quit".

**Window** — sidebar with four sections:

1. **Home** — name, battery, connection state (Bluetooth connected; dongle
   connected/not), volume (read-only, 0–31), balance slider.
2. **EQ** — preset picker; 5 vertical sliders (enabled only in Custom), band
   labelled 31 / 63 / 125 / 250 / 500 Hz, −12…+12 dB in 1 dB steps; "Reset flat"
  (all bands 0).
3. **Microphone** — Internal / Boom tabs; sidetone slider 0–100 %; noise
   gate radio Off / Night / Home / Tournament.
4. **Settings** — name (read-only), firmware, serial, sleep mode
   (Never / 15 / 30 / 60 min), tones (All / Minimal / None), **Factory
   reset**: red button → alert "This erases all headset settings; you may need to re-pair it" → sheet that
   requires typing `RESET` → `factoryReset(serial:)`.

Global states: *Disconnected* overlay "Looking for ASTRO A30…" with automatic
retry; *write error* banner naming the error (e.g. NOT_CONNECTED → "Connect the
dongle to adjust the balance").

## Data flow

1. Launch → find paired `00-00-00-00-00-00` (first paired device named "ASTRO A30"
   if the address differs) → open RFCOMM 26. No `openComplete` within 5 s → close
   and retry (stale channel from a previous session is a known cause).
2. iAP2 handshake → EA session → `GET_FEATURE_ID[0]` → map feature id → index.
3. Initial read of every value above.
4. Poll battery + dongle every 60 s. Unsolicited CPP frames: log only.
5. Channel closed, or 3 consecutive timeouts → state *Disconnected*, reconnect
   with 5 s backoff.

Writes: sliders send on release (or 150 ms debounce), one request in flight.
Every SET is followed by a GET of the same value and the UI shows the value read
back. On error: revert to the previous value and show the banner. Controls the
firmware rejects up front are disabled: balance while dongle bit0 = 0; any
function that answered INVALID_FUNCTION.

## Testing

- `A30KitTests` (no headset): CRC check value, SPP wrap/parse, iAP2 link packet
  build + checksum (headset's own SYN as fixture), control message params, CPL
  fragment reassembly (the fragmented feature list captured today), error reply
  parsing, response parsers (EQ `04 00 00 00 00 00`, sidetone `02 00 28 01 28`,
  dongle `00`, balance `14`). XCTest / swift-testing are unavailable without Xcode,
  so the cases run in an executable `selftest` (`test.sh`) with a small `check()` helper.
- Hardware checklist (manual, in the plan): for each control, change → read back
  → restore the original value. Factory reset is **not** exercised unless Doug
  asks for it explicitly.

## Value encodings (resolved from `jadx/`, 2026-11-10)

Paths relative to `jadx/sources/com/`.

1. **EQ bands** — UI −12…+12 dB, 1 dB steps (`SingleLineGraphView.java:128`,
   `HeadsetHeadphonesFragment.java:621`). Wire byte = dB × 10, signed, so −120…+120
   in steps of 10 (`CPPCarboniteManager.java:134`). Labels 31 / 63 / 125 / 250 /
   500 Hz (`SingleLineGraphView.java:137`). Reading back: divide by 10.
   **Quirk to copy:** when switching to a mode other than Immersive/Footstep, the
   app first sends `SET_USER_EQ [0x80, 0,0,0,0,0]`, waits 100 ms, then the real
   mode (`CPPCarboniteManager.java:186`). Do the same for Custom.
2. **Sidetone** — device value is already a percentage 0–100, no step scaling for
   carbonite (`BottomSheetQuickControlFragment.java:100`, `:556`). 0x28 = 40 %.
3. **Noise gate** — Off 0, Night 1, Home 2, Tournament 3
   (`HeadsetHomeViewModel.java:3511`). Current: both mics Off.
4. **Tones** — None 0, All 1, Minimal 2 (`HeadsetToneViewModel.java:81`). Current:
   Minimal.
5. **Factory reset** — serial read with no-arg GET_SERIAL_NUMBER, parsed as
   `[len][utf8]` → "224" is the whole string; reset sends those same bytes
   (`CPPDevice.java:759`, `HeadsetResetDeviceViewModel.java:176`). The app sends no
   unpair/reboot command for carbonite but afterwards deletes its own data and
   sends the user through **re-pairing** — assume the Mac may need to re-pair
   the headset after a reset, and say so in the confirmation alert.
6. **Battery** — `[realSOC, userSOC, chargingState]` (`CPPDevice.java:909`);
   the app shows userSOC. Charging: 0 not charging, 1 slow, 2 fast, 3 full,
   4 error. `2a 28 00` = 40 % shown, not charging.
