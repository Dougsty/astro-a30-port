# A30 Control

Native macOS app to control the **ASTRO A30** headset without the Logitech G app, built by
reverse-engineering the headset's control protocol. It lives in the menu bar, opens a window in the
style of the ASTRO Command Center, and adds a few things the official app doesn't have.

> Personal interoperability project. Not affiliated with or endorsed by Logitech/ASTRO.

---

## Features

### Menu bar
- Custom icon (the "a" with the star) with the **battery %** next to it.
- Icon badges: **⚡ charging**, **🔋 low battery** (≤ 20 %), **🎙️ mic muted on the headset**.
- Quick panel: volume, EQ preset, boom mic sidetone, game/chat balance, **turn off the headset**,
  open the window, quit.
- No Dock icon while the window is closed; the Dock icon only shows with the window open.
  "Quit" from the Dock or ⌘Q only closes the window — the app stays in the menu bar.
- **Open at login** (Settings), via `SMAppService`.

### Window (Command Center style, fixed size)
- **EQUALIZER** — preset library (Custom, Immersive, Footstep, plus Astro Studio / Gaming / Pro) and
  5 vertical bands (31/63/125/250/500 Hz, −12…+12 dB). Drag, ↑/↓ on the keyboard, or VoiceOver.
  REVERT and RESET FLAT. The Custom curve is remembered and comes back when you return to Custom.
  **Save curve as…** stores named Custom curves; they show under "Saved curves" and apply in one click.
- **MICROPHONE** — internal / boom mic, sidetone 0–100 %, noise gate (Off/Night/Home/Tournament).
- **MIX** — headset volume (0–31, same scale as the wheel), **mute headset audio**, game/chat
  balance, and **base station mode PC / Xbox** (the last two need the 2.4 GHz dongle).
- **EXTRAS** — **profiles** (save EQ + sidetone + noise gate + balance under a name and apply them all
  at once), EQ per app (switches the preset when an app comes to the front and back when it leaves),
  and notifications.
- **SETTINGS** — name (**rename headset…**, shown in Bluetooth), firmware, serial, sleep mode, tones,
  open at login, **turn off headset**, and factory reset (double confirmation: alert + type `RESET`).

### Things the official app doesn't do
- **Turn the headset off from the app.** The A30 has no power-off command; the app sets auto-sleep to
  1 minute (the firmware accepts values outside the official 15/30/60), closes the connection, and the
  headset goes off ~2 min later. On the next connection sleep goes back to "never".
  Useful because my headset's physical button died.
- **Live updates**: volume (wheel), EQ, battery and charging arrive through notifications the headset
  pushes itself — no waiting for polling.
- **Battery in 1 % steps**: the official app shows the headset's "user" value, which moves in 10 %
  steps and looks stuck while charging; A30 Control shows the real value.
- **Extra EQ presets** (Astro Studio, Gaming, Pro) from other ASTRO products — the A30 firmware
  accepts them even though the official app doesn't offer them.
- **Saved EQ curves and profiles.**
- **macOS notifications**: battery at 20 % and 10 %, mic muted/unmuted.
- **EQ per app**.
- **Doesn't force the Bluetooth connection**: the app only connects if the headset is already
  connected to the Mac, so you can disconnect from the Bluetooth menu as usual.

---

## Install

Requirements: macOS 15+, Command Line Tools (`xcode-select --install`). Xcode is not needed.

```bash
A30Control/install.sh
```

Builds, copies to `/Applications/A30 Control.app` and opens it. The first time, macOS asks for
**Bluetooth** and **notifications** permission.

Other commands:

```bash
A30Control/test.sh              # protocol tests (no headset)
A30Control/build.sh             # build only → A30Control/build/A30 Control.app
A30Control/probe.sh [--writes]  # smoke test on the real headset
```

The app must be opened as a bundle (`open` / Finder). Running the binary directly aborts because of
TCC (the Bluetooth permission belongs to the bundle).

---

## Windows

`A30Control.Windows/` is a C#/.NET 8 WPF port with the same features: tray icon + panel instead of the
menu bar, "Start with Windows" instead of "Open at login". Built on the Mac (needs the .NET 8 SDK in
`~/.dotnet` and `brew install makensis`):

```bash
A30Control.Windows/selftest.sh   # protocol tests, no headset
A30Control.Windows/build.sh      # → dist/A30Control-Setup-<version>.exe and the portable dist/A30Control.exe
```

On the PC run the setup (per-user, no admin rights; SmartScreen: "More info → Run anyway"). It adds a
Start menu entry, optional "Start with Windows" and an entry in Settings → Apps to uninstall. Logs and
settings live in `%APPDATA%\A30Control\`. Manual test list: `docs/superpowers/a30-control-windows-checklist.md`.

On Windows the app controls the headset **through the 2.4 GHz dongle** (USB): toward a Windows PC the
headset never answers on its Bluetooth control channel. Over the dongle the headset accepts every
setting but can't be queried, so the app shows what the headset pushes (a full status when it links to
the dongle, then volume, battery and mic changes) and remembers the last known state. Firmware, serial,
sleep mode and tones aren't shown there.

---

## How it works

The A30 exposes a control channel on **RFCOMM channel 26** (classic Bluetooth). When the host is a
Mac, the headset speaks **iAP2** (Apple's accessory protocol) on that channel, not plain SPP. The app
plays the "iPhone" role:

1. answers the iAP2 detect, does link sync and authentication (the accessory's certificate is
   accepted without verification — we're not Apple);
2. identification → the headset announces the External Accessory protocol
   **`com.logitech.ag.carbonite`**;
3. opens the External Accessory session and, inside it, talks **CPP** — Logitech's protocol,
   structurally HID++ 2.0: `[feature index, function<<4 | swId, args…]`, wrapped in an SPP frame
   (`13 A0 len … CRC-16/MCRF4XX`).

The feature map, command formats and error codes come from the decompiled official Android app
(JADX) and were confirmed on the headset. Full details in [`CLAUDE.md`](CLAUDE.md).

### Headset features (what the firmware answers)

| idx | feature | used for |
|---|---|---|
| 2 | iBatterySOC | battery, charging state |
| 3 | iDeviceInfo | firmware, serial, factory reset |
| 4 | iDeviceName | name, rename |
| 5 | iheadsetMicMute | mute notification |
| 6 | iHeadsetTones | tones |
| 7 | iVolumeSet | volume, audio mute |
| 8 | iHeadsetAudioSidetone | sidetone |
| 9 | iHeadsetNoiseGate | noise gate |
| 10 | iHeadsetMix | game/chat balance (2.4 GHz dongle only) |
| 11 | iHeadsetDongle | dongle status, base station mode PC/Xbox |
| 12 | iAutoSleep | sleep mode, "turn off" |
| 14 | iEQSet | EQ |
| 15 | iProfile | — |

### What the investigation found
- A sweep of **4,352 ids** (`0x0000–0x0FFF`, `0x9000–0x90FF`) found **only the 16 official
  features** — nothing hidden, not even "connected devices".
- The firmware **accepts** EQ modes from other products (Studio, Gaming, Pro, Standard, Bass Boost,
  Voice).
- **Renaming the headset** (`SET_NAME`) and **muting audio** (`SET_MUTE_STATUS`) work.
- Real limits: volume 31, noise gate 3, tones 2; sidetone accepts **101**.
- **Game/chat balance only works with the dongle connected** (firmware rule, `NOT_CONNECTED`).
- **No command to power off, remap buttons, mute the mic in software, or read the firmware.**
- Firmware: the update (OTA + DFU) was mapped but not implemented — use the Logitech G app on an
  iPhone (Device Settings → Firmware Update).

---

## Layout

```
A30Control/            the app
  Sources/A30Kit/      protocol: framing, iAP2, codecs, Bluetooth link, typed API
  Sources/A30App/      SwiftUI: model, window, menu bar, extras
  Tests/               protocol tests (real bytes captured from the headset)
  Tools/prepicon.swift makes the app icon, menu bar glyph and logo from Assets/icon.png
  build.sh install.sh test.sh probe.sh
A30Control.Windows/    Windows port (C#/.NET 8, WPF) + NSIS installer
tools/a30b/            diagnostic tool: raw commands (--seq), SDP dump (--sdp)
docs/superpowers/      spec, implementation plan and manual checklist
archive/               old attempts (plain SPP, Python)
CLAUDE.md              full protocol notes
```

### Diagnostic tool

```bash
tools/a30b/build.sh
tools/a30b/run.sh --seq "7:0,14:0"     # GET volume and EQ
tools/a30b/run.sh --sdp                # headset SDP records
```

`--seq` format: `index:function:hexArgs`, comma-separated; `p` = 4 s pause.
Quit A30 Control first — channel 26 only accepts one client at a time.

---

## Known limitations
- Tested with a single unit only (firmware 1.0.59, hw rev 1).
- Toolchain without Xcode: SwiftPM doesn't work in this environment and SwiftUI's state property
  wrappers (`@State`, `@Binding`…) need Xcode's macro plugin; all state lives in the `@Observable`
  `HeadsetModel`.
- The mic mute state only shows after the first toggle (there's no GET for it).
- Switching base station mode makes the dongle drop and re-link for a few seconds.
