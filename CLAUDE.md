# ASTRO A30 — third-party macOS controller

Goal: control the ASTRO A30 headset (EQ, game/chat mix, sidetone, profiles) from
macOS without the Logitech G app. Doug's own headset; interoperability work.

Protocol was recovered by statically decompiling the Logitech G Android app
v2.2.21 (`com.astrogaming.scorpius`) with JADX. The app is **unobfuscated and has
no native libraries** — the control stack is readable Kotlin in
`com.logitech.ue.centurion`.

## Device identity

| | |
|---|---|
| Marketing name | ASTRO A30 |
| Internal codename | **Carbonite** (`DeviceType.Carbonite`, id 20) |
| Model string | `A30 CB PA1` |
| BLE PID | 801 / 0x321 |
| Protocol family | `DeviceGroupType.CPP` |

## Transport: RFCOMM channel 26 (confirmed)

The A30 exposes **`iSPP Port` on RFCOMM channel 26**, SDP UUID `0x1101`.
Confirmed live via `IOBluetoothDevice.pairedDevices()` SDP dump while the headset
was connected as an audio device. The `i` prefix matches Centurion's naming
convention (iRoot, iEQSet, iMixAmp), so this is Logitech's own control channel.

The Android app opens it with `createInsecureRfcommSocketToServiceRecord(
UUID 00001101-0000-1000-8000-00805F9B34FB)` — insecure RFCOMM, no PIN.

A BLE/GATT path also exists in the app but is **not the route for this unit on
macOS**: CoreBluetooth only sees BLE, and the A30's control channel is classic
Bluetooth. (BLE GATT map kept at the bottom for reference.)

### On macOS channel 26 speaks iAP2, not raw SPP (confirmed 2026-11-10)

The SDP record on ch 26 carries two UUIDs: `0x1101` and Apple's iAP2 UUID
`00000000-DECA-FADE-DECA-DEAFDECACAFF`. Chip is Avnera. Toward a Mac the A30
never accepts raw SPP frames — it just repeats the iAP2 detect `FF 55 02 00 EE 10`
every ~1.5s forever. We play the Apple-device role (all working in `tools/a30b/a30b.swift`):

1. Echo detect `FF 55 02 00 EE 10`.
2. Accessory sends link SYN (`FF 5A`, ctrl 0x80). Params: maxOutstanding 5,
   maxPacket 132, sessions **1 = control (type 0)**, **3 = External Accessory (type 2)**.
   Reply SYN+ACK (0xC0) echoing params; accessory ACKs → link up.
3. Control session: send `AA00` RequestAuthenticationCertificate → accessory
   `AA01` (609-byte cert) → send `AA02` with 32 random challenge bytes →
   `AA03` (64-byte response, **not verified**) → send `AA05` AuthenticationSucceeded.
4. Send `1D00` StartIdentification → accessory `1D01`: name "A30", maker "Astro",
   serial `A30SERIAL001`, fw 0.1.0, EA protocol **id 1 = `com.logitech.ag.carbonite`**.
   Send `1D02` IdentificationAccepted.
5. Send `EA00` StartExternalAccessoryProtocolSession (param0 = proto 1, param1 = EA sid 1).
6. CPP traffic: link packet on session 3, payload = EA sid (2 bytes BE) + SPP frame
   (`13 A0 len ... crc`). Replies use the same framing but **CRC is `00 00`**.

Link packet: `FF 5A len(2) ctrl seq ack session hdrCks [payload payloadCks]`,
checksums = two's complement of byte sum. Every data packet must be ACKed
(`ctrl 0x40`, no payload). Control msg: `40 40 len(2) msgId(2)` + params
`len(2) id(2) data`.

### TCC gotcha

A plain CLI binary aborts (SIGABRT, namespace TCC, "missing
NSBluetoothAlwaysUsageDescription") when its *responsible process* lacks the key
— e.g. launched from Claude/an IDE. Fix: bundle as `a30b.app` (Info.plist with
the key) and start it with `open` (`run.sh`), so the app is its own responsible
process. Works from Terminal.app without this, which is why earlier runs didn't crash.

## Wire format

Three nested layers. All verified against the decompiled encoder/decoder.

### 1. SPP frame — `CLPSPPWrapperConnection.wrapPayload()`

```
byte 0        0x13                        (SOF low)
byte 1        0xA0 | ((len >> 8) & 0x0F)  (SOF high + length high nibble)
byte 2        len & 0xFF                  (length low byte)
byte 3..      payload (len bytes)
byte len+3    CRC low
byte len+4    CRC high
```

`len` = payload length. CRC is **CRC-16/MCRF4XX** over the first `len+3` bytes
(poly 0x1021 reflected = 0x8408, init 0xFFFF, refin/refout true, xorout 0x0000;
check value `0x6F91` for `"123456789"`). Stored little-endian.

Receiver validation, mirroring the app:
- `data[0] == 0x13 && (data[1] & 0xF0) == 0xA0`
- `size = ((data[1] & 0x0F) << 8) | data[2]`
- CRC over `data[start .. start+size+3)`

### 2. CPL transport header

One byte prefixed to the CPP message:

```
bit 0     more-fragments flag
bits 1-7  message sequence number
```

`0x00` for any single-fragment message. Fragmentation above 506 bytes
(512 buffer − 6 header). Reassembly concatenates until the flag clears.

### 3. CPP message — `CPPMessage.buildCommandData()`

```
byte 0    feature INDEX   <-- NOT the 16-bit feature id
byte 1    (functionId << 4) & 0xF0 | (swId & 0x0F)
byte 2+   payload
```

This is structurally **HID++ 2.0**. The first byte is the feature's index *on
this specific device*, discovered at runtime:

- `iRoot` (feature 0x0000) is **always index 0**
- `iRoot.GET_FEATURE` (fn 0x0), payload = featureId big-endian → returns index
- or walk `iFeatureSet` (0x0001): `GET_FEATURE_COUNT` (fn 0), `GET_FEATURE_ID` (fn 1)

`swId` is a 4-bit tag you pick per request; the device echoes it so replies can
be matched. Use 1–15, never 0.

### Worked example

Ask for the index of `iEQSet` (0x0201), swId=1:

```
CPP   :  00 01 02 01            (index 0, fn 0, sw 1, args = featureId)
CPL   :  00 00 01 02 01
SPP   :  13 a0 05 00 00 01 02 01 d8 24
```

Verified: SOF, length and CRC all round-trip through the app's own validator.

## Feature / opcode map

83 features, 418 functions extracted from `Features.java` (in the local, untracked `jadx/`).

Most relevant here:

| Feature | id | Functions |
|---|---|---|
| `iRoot` | 0x0000 | 0 GET_FEATURE, 1 GET_PROTOCOL_VERSION |
| `iFeatureSet` | 0x0001 | 0 GET_FEATURE_COUNT, 1 GET_FEATURE_ID |
| `iProfile` | 0x0004 | 0 GET_INFO, 1 GET_ACTIVE_PROFILE, 2 SET_ACTIVE_PROFILE, 7 GET_PROFILE_NAME, 8 SET_PROFILE_NAME |
| `iMixAmp` | 0x0000* | 0 GET_NUMBER_OF_AUDIO_MIXES, 2 GET_AUDIO_MIX_DATA, 4 SET_AUDIO_MIX_VALUE, 5 SET_ACTIVE_AUDIO_MIX_INDEX |
| `iDeviceInfo` | 0x0100 | 4 fns |
| `iDeviceName` | 0x0101 | 4 fns |
| `iBatterySOC` | 0x0104 | 1 fn |
| `iPowerState` | 0x0107 | 1 fn |
| `iEQSet` | 0x0201 | 0 GET_EQ, 1 SET_EQ, 4 SET_ACTIVE_EQ, 6 GET_EQUALIZER_LIST, 7 GET_ACTIVE_EQ |
| `iAdvancedParaEQ` | 0x020D | 1 GET_CUSTOM_EQ, 2 SET_CUSTOM_EQ, 4 SET_ACTIVE_EQ, 6/7 EQ_FRIENDLY_NAME |

\* `iMixAmp` and `iRoot` both report id 0x0000 in the decompiled table — resolve
by enumerating what the device actually answers rather than trusting this row.

## Current state

**Connected, all features enumerated, read-only GETs working (2026-11-10).**
`tools/a30b/build.sh && tools/a30b/run.sh` does link/auth/identification, opens the EA session,
lists features, then runs GETs only (`readouts()` in `a30b.swift`).

### Feature map on Doug's A30 (from iFeatureSet)

`iFeatureSet.GET_FEATURE_ID` (idx 1, fn 1) with arg `start` returns the **whole
list** from `start`: `count` then 4-byte entries `featureId(2) type ver` — not one
id per call as in HID++. Replies > ~32 bytes arrive as CPL fragments
(`01`, `03`, … `04` = seq 2 final); reassemble the bytes after the CPL byte.

| idx | id | name | ver | GET results (raw args) |
|---|---|---|---|---|
| 0 | 0x0000 | iRoot | 2 | |
| 1 | 0x0001 | iFeatureSet | 1 | count = 0x10 (16, incl. root) |
| 2 | 0x0104 | iBatterySOC | 3 | fn0 → `[realSOC, userSOC, charging]`, e.g. `2a 28 00` = 42 % real, 40 % user, not charging. userSOC (what the official app shows) moves in 10 % steps; realSOC in 1 % steps — A30 Control shows realSOC. charging: 0 no, 1 slow, 2 fast, 3 full |
| 3 | 0x0100 | iDeviceInfo | 4 | fn0 `14 01 00..`; fn1 `01 00 00 3b 05 "local"`; fn2 `03 "224"` (serial looks paged). **fn4 = FACTORY_RESET — never call** |
| 4 | 0x0101 | iDeviceName | 2 | fn0 `30 09 "ASTRO A30"` (max 48, len, text); fn2 default "Astro A30 Gaming Headset" |
| 5 | 0x0601 | iheadsetMicMute | 1 | fn3 err 2 |
| 6 | 0x060B | iHeadsetTones | 1 | fn0 → `02` |
| 7 | 0x0200 | iVolumeSet | 3 | fn0 → `1e 00` (30); fn3 err 2 |
| 8 | 0x0604 | iHeadsetAudioSidetone | 1 | fn0 → `02 00 28 01 28` (2 entries, both 0x28 = 40); fn2 err 2 |
| 9 | 0x0608 | iHeadsetNoiseGate | 1 | fn0 / fn2 → `02 00 00 01 00` |
| 10 | 0x0609 | iHeadsetMix | 1 | fn0 GET_BALANCE → `14` (20, likely centre of game/chat); fn2 err 2 |
| 11 | 0x060A | iHeadsetDongle | 1 | fn0 → `00` |
| 12 | 0x0108 | iAutoSleep | 3 | fn0 → `00 00` |
| 13 | 0x010A | iGenericDFU | 4 | firmware update — don't touch |
| 14 | 0x0201 | iEQSet | 3 | fn2 GET_EQ_MODES → `03 04 80 81`; fn0 GET_EQ → `04 00 00 00 00 00` with any arg; fn 5/6/7/8 err 2 |
| 15 | 0x0004 | iProfile | 3 | fn0 → `01 ca c3 00 00`; fn1 active = 0; fn7[0] err 2 |

Not present: iAdvancedParaEQ (0x020D), iMixAmp. Game/chat mix is **iHeadsetMix
0x0609**, sidetone is **0x0604**. Error reply: `FF featIdx fn|sw err`; err 2 seen
for unsupported/bad-arg calls, err 5 for unknown feature.

Root cause of the old "never opens" block: TCC abort (see TCC gotcha), plus the
channel being iAP2. Run-loop theory was not the issue. If `openComplete` doesn't
fire, the previous run's channel may still be held — just rerun.

### Writes (tested 2026-11-10)

Run raw requests with `tools/a30b/run.sh --seq "idx:fn:hexargs,idx:fn,p,..."` (`p` = 4s pause).

- **Sidetone works.** `iHeadsetAudioSidetone` idx 8: SET fn1 args `[channel, level]`;
  GET fn0 returns `[count, (channel, level)*]`. Tested ch0 `0x28 → 0x20 → 0x28`,
  read back each time. Original state: both channels 0x28.
  `tools/a30b/run.sh --seq "8:1:0020,8:0"` sets ch0 to 0x20.
- **Game/chat balance needs the 2.4 GHz dongle.** `iHeadsetMix` idx 10 SET fn1 `[n]`
  is the app's exact format (`CPPDevice.setHeadsetMixBalance`: one byte), range
  **0–20** (`AppConstants.HEADSET_MAXIMUM_MIX_VALUE = 20`; app sends
  `round(20 * percent / 100)`). Without the dongle: n=0..20 → err 8 **NOT_CONNECTED**,
  n=30 → err 5 INVALID_PARAM. The app itself only restores balance on profile load
  when `isDongleConnected()` and product == "carbonite". Mix = dongle (game) vs BT (chat).
  `GET_INFO` (fn2) returns 3 bytes `level, leftSource, rightSource` on newer fw; err 2 here.
- **Dongle status = `iHeadsetDongle` idx 11 GET_CONFIG fn0**, one byte of bits:
  bit0 connected, bit1 Xbox mode, bit2 host type (`QuickControlTransmitterInfo`).
  Reads `00` (not connected) on Doug's unit with BT only. The app sets
  `isDongleConnected` from this bit and, for carbonite, greys out the balance slider
  (alpha 0.25, not clickable) and skips SET_BALANCE whenever it is 0 — every UI path
  (`BottomSheetQuickControlBalance`, `HeadsetModuleAdapter` pos 2, `HeadsetHomeActivity`).
  Confirmed 2026-11-10: the iOS app also greys the slider out with BT only.
  **Balance needs the dongle connected — firmware rule, not something to work around.**

- **EQ works.** On the A30, 0x0201 is the `HeadsetEQSet` variant: fn0 GET_USER_EQ /
  fn1 SET_USER_EQ, both `[mode, band0..band4]` (bands = signed gain bytes,
  `HeadsetEQProfile.getBands()`). fn2 GET_EQ_MODES → `03 04 80 81` = supported modes.
  Mode codes (`UtilsKt.getCode(HeadsetEQSetting)`): CUSTOM 4, ASTRO_IMMERSIVE 0x80,
  ASTRO_FOOTSTEP 0x81 (others exist for other products: STANDARD 3, BASS_BOOST 5,
  ASTRO_STUDIO 0x82, ASTRO_GAMING 0x83, ASTRO_PRO 0x84…). Tested 04 → 80 → 81 → 04,
  read back each time. Original: `04 00 00 00 00 00` (Custom, flat).
  `tools/a30b/run.sh --seq "14:1:800000000000,14:0"` → Immersive. Custom band gain: −12…+12 dB in 1 dB steps, sent as dB×10 (signed).
- **Volume works.** `iVolumeSet` idx 7 SET fn1 `[level]`, 0–31 (`AppConstants.HEADSET_MAX_DEVICE_VOLUME`),
  same scale as the wheel; GET fn0 `[level, 0]`. Tested 31 → 26 → 31 (2026-11-10).
- **Notifications.** The headset pushes unsolicited CPP replies with **swID 0**, same
  layout as the GET: volume wheel → `idx 7 fn 0 [level, 0]` (every step, ~0.5 s apart);
  EQ change → `idx 14 fn 0 [mode, bands…]`; mic mute toggle → `idx 5 fn 0 [state]`.
  Battery → `idx 2 fn 0 [real, user, charging]` pushed ~2 s after plugging USB-C (charging 02 = fast).
  A30 Control applies volume and EQ live (`HeadsetLink.onNotification`).
- **Auto-sleep.** `iAutoSleep` idx 12 (v3): SET fn1 `[sleepMin, idleMin]` — the app
  sends the same value twice for carbonite; options 0 = never, 15, 30, 60.
  Doug's unit reads `00 00` = **never**. (v4+ adds a third deep-sleep byte.)
- **Turn off via auto-sleep.** The firmware accepts any minute value (1…255), not just the app's
  0/15/30/60. SET `[1, 1]` with the control channel closed and no audio → the headset powered off
  ~2 min later (tested 2026-11-10). A30 Control's "Turn off headset" does this (120 s countdown) and
  writes the sleep mode back to never on the next connect (`a30.restoreSleepNever` default).
  Doug's headset wakes with USB-C or by clicking it in the macOS Bluetooth menu.
- **No remote power-off / button remap on the A30.** `iRemotePowerSet` (SHUTDOWN)
  isn't in its feature list and there's no button-mapping feature. BLE power
  commands are only AUTHENTICATE_ONLY 0x42 / POWER_ON 0xFF.

### Firmware update (OTA + DFU) — researched, not implemented

- **OTA check:** the official app asks Logitech's OTA web service (device model `Carbonite`, hw
  revision, current firmware) with an API key embedded in the app; not used here. The answer points to a
  zip with `*params*`, `*data*`, `*tabor*` files, no checksum.
- **DFU = iGenericDFU 0x010A (v4 on this unit), big-endian, 3 modules (1 params, 2 data, 3 tabor):**
  ABORT(fn5) → per module: PREPARE(fn0 `[module]` → `[expectedTime, partition, chunkSize]`) → wait
  event 0 PREPARE_COMPLETE `[status, partition]` → WRITE(fn1, raw chunks of chunkSize, last one
  zero-padded, one in flight) → VERIFY(fn2) → wait event 1 VERIFY_COMPLETE `[status]` → next module;
  after module 3: INSTALL(fn3) → headset reboots → on reconnect CONFIRM(fn4). No battery check in the app.
  Source: `jadx/.../headset/common/ota/` (HeadsetOTAStepsFragment, HeadsetOTALandingViewModel).
- Recommended path: update from the official Logitech G app on the iPhone (Device Settings →
  Firmware Update); firmware updates don't require warranty.

### Error codes (`CenturionError`)

Reply `FF featIdx fn|sw code`:
1 INVALID_FEATURE, 2 INVALID_FUNCTION, 3 INVALID_SIZE, 4 INVALID_SWID,
5 INVALID_PARAM, 6 TIMEOUT, 7 LOW_RESOURCE, 8 NOT_CONNECTED, 9 BUSY,
10 NOT_AVAILABLE, 11 FAILED, 12 MALFORMED, 14 NOT_AUTHORIZED.
So the err 2 replies above (EQ fn 5–8, several GET_INFO) mean the function isn't
implemented in this firmware, not a bad argument.

### Next steps

1. Run the A30 Control manual checklist (see the plan's Task 8 / final review).
2. Done: the app handles swID-0 notifications for volume and EQ.

## Files

- `A30Control/` — the macOS app (A30Kit protocol + SwiftUI); see "A30 Control app"
- `tools/a30b/` — diagnostic CLI: `a30b.swift` (iAP2 + CPP client; `--sdp` dumps SDP,
  `--seq` runs raw requests, `--plain` sends CPP without SPP wrapper), `build.sh` / `run.sh`
  (build `a30b.app`, launch via `open`, output in `tools/a30b/a30b.log`), `Info.plist`
- `archive/` — obsolete attempts: `a30.swift` (raw SPP), `spp*.py` (PyObjC RFCOMM),
  `sdp.py` (SDP dump, superseded by `run.sh --sdp`), `probe.py` (BLE/bleak, wrong transport).
  The Python ones need a venv with `bleak` and `pyobjc-framework-IOBluetooth` (deleted; recreate if needed)
- `docs/superpowers/` — app spec, plan and manual checklist
- `A30Control.Windows/` — Windows port (C#/.NET 8, WPF): `A30Kit/` protocol (port of the Swift A30Kit +
  `HeadsetLink` with iAP2/raw-SPP auto-detect), `A30Kit.SelfTest/`, `A30Control/` app, `installer/`
  (NSIS, per-user). `selftest.sh`, `build.sh` (→ `dist/A30Control-Setup-<ver>.exe` + portable exe),
  `build.ps1` for building on Windows. .NET SDK in `~/.dotnet`, `makensis` from Homebrew; builds run
  from a snapshot in `~/Library/Caches/A30Control.Windows/` (iCloud evicts files). Not yet tested on
  real Windows hardware.
- `jadx/` — `jadx 1.5.6 --no-res` output of the base APK from `~/Downloads/Logitech+G_2.2.21_APKPure.xapk`.
  Protocol: `jadx/sources/com/logitech/ue/centurion/` (`cpp/device/CPPDevice.java` = every request encoder).
  App logic: `jadx/sources/com/astrogaming/scorpius/headset/` (`carbonite/` = A30).

## A30 Control app (`A30Control/`)

Native macOS menu-bar app (LSUIElement; Dock icon only while the window is open, Dock Quit/⌘Q just hides it, panel Quit exits): menu bar (battery %, EQ preset, boom sidetone, balance, Open at login) + window opened from the panel
(Home, EQ, Microphone, Settings incl. factory reset; sidebar collapses to an icon rail). A phone-style redesign was tried and rejected (2026-11-10); `reference/original-app/` keeps the extracted Logitech assets. Spec:
`docs/superpowers/specs/2026-11-10-a30-control-app-design.md`, plan:
`docs/superpowers/plans/2026-11-10-a30-control-app.md`.

```bash
A30Control/test.sh                       # pure protocol tests, no headset
A30Control/build.sh                      # → A30Control/build/A30 Control.app
open "A30Control/build/A30 Control.app"  # must be launched via open/Finder (TCC)
A30Control/install.sh                    # build + copy to /Applications + launch (needed for "Open at login")
A30Control/probe.sh [--writes]           # hardware smoke test of A30Kit
```

Only one client can hold RFCOMM ch 26: quit A30 Control before running `probe.sh` or `tools/a30b/run.sh`.
`probe.sh --writes` briefly switches EQ to Footstep and boom sidetone to 30, then restores both.

Window: Command Center style, fixed 980×640 (no resize/full screen): header + headset row + tabs
EQUALIZER / MICROPHONE / MIX / EXTRAS / SETTINGS.
Extras (not in the official app): mic-mute indicator + notification (idx 5 push; the A30 has no
software mute command), low-battery notifications at 20/10 %, EQ per frontmost app (`Extras.swift`).
Also (2026-11-10): EQ presets Astro Studio/Gaming/Pro (0x82–0x84, accepted by the firmware, not offered
by the official app for the A30); saved named Custom curves and profiles (EQ + sidetone + noise gate +
balance), both JSON in UserDefaults (`a30.savedEQs`, `a30.profiles`); rename (iDeviceName SET fn1
`[len][utf8]`, max 48); headset audio mute (iVolumeSet SET_MUTE_STATUS fn2 `[0/1]`, GET byte 1);
base station mode (iHeadsetDongle SET_CONFIG fn1 `[0 PC, 1 Xbox]`).
With the dongle on the Mac (2026-11-10): GET_CONFIG `01` (connected, PC). Balance SET `0e` → GET `0e` →
back to `0a` (centre) works. Base station mode = **host type, bit 2** (`QuickControlTransmitterInfo`,
`setQuickControlTransmitterData(hostType)`): SET `[1]` → `05`; the dongle then drops (`00`) and
re-links after a few seconds; SET `[0]` while it re-links → err 8. Restored to PC (`01`).
Repo language: everything in English (README, docs, comments, UI).
A full `iRoot.GET_FEATURE` sweep of 0x0000–0x0FFF and 0x9000–0x90FF found only the 16 listed
features — nothing hidden (no HeadsetBtConnInfo / connected-devices feature).

Icons: `A30Control/Assets/icon.png` (Doug's artwork) → `Tools/prepicon.swift` (run by `build.sh`)
makes the app icon (clipped to the macOS shape) and the menu bar template glyph (`menubar(@2x).png`).

Toolchain notes: SwiftPM is broken with these Command Line Tools and SwiftUI's
`@State`/`@Binding` are macros needing Xcode's plugin — so everything is built with
`swiftc` and all view state lives in the `@Observable` `HeadsetModel`.

## Reference: BLE GATT map (not the active route)

| Role | UUID |
|---|---|
| Primary service | `7FD36E38-4680-4A77-BEA3-BEEAEECBF592` |
| Power service | `1b7e8251-2877-41c3-b46e-cf057c562023` |
| Write + notify | `748E2216-8B9A-4598-A0C6-2DEE1AF454DB` |
| Authorize & remote power | `5E9BF2A8-F93F-4481-A67E-3B2F4A07891A` |
| MixAmp authorize | `0B848765-751D-4972-903F-651D8B2E80AD` |
| Long response | `8F83DD07-E637-5CEA-A223-F1F3B64B73EE` |

BLE authorize: write 7 bytes to an authorize characteristic — 6-byte AUID
(app default `02 02 02 02 02 02`) + power byte (`0x42` AUTHENTICATE_ONLY,
`0xFF` POWER_ON). MTU 512.
