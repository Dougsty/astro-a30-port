# A30 Control for Windows — design

Date: 2026-11-10. Status: approved in chat, awaiting spec review.

## Goal

Port A30 Control (the macOS menu-bar app in `A30Control/`) to Windows 10/11 with feature parity, so
Doug can control his ASTRO A30 from his Windows PC. On that PC the headset is paired over Bluetooth
**and** the 2.4 GHz dongle is plugged in, so game/chat balance and base station mode (PC/Xbox), which
were untestable on the Mac, become usable.

Success: on Doug's PC, `A30Control.exe` connects to the paired A30, shows battery/volume/EQ live,
and every write that works on the Mac also works there, plus balance and base station mode with the
dongle.

Constraints:
- Built on the Mac (no Windows build machine). Nothing can be run on Windows by Claude; the first
  hardware test is Doug's, helped by a log file.
- Never call iGenericDFU (0x010A). Factory reset only after typing `RESET`. No raw-command path in
  the UI.
- Repo content in English.

## Stack

C# / .NET 8, WPF, single self-contained `win-x64` executable. Built on macOS with
`EnableWindowsTargeting=true`. .NET 8 SDK installed per-user into `~/.dotnet` via Microsoft's
`dotnet-install.sh` (no sudo).

## Layout

```
A30Control.Windows/
  A30Control.Windows.sln
  Directory.Build.props   BaseOutputPath/BaseIntermediateOutputPath → ~/Library/Caches/A30Control.Windows
                          (keeps bin/obj out of iCloud Drive)
  A30Kit/                 net8.0 class library, no Windows APIs
    Framing.cs            SPP frame wrap/parse, CRC-16/MCRF4XX, CPL fragment reassembly
    Iap2Session.cs        iAP2 host role: link packets, SYN/ACK, control messages, auth/ident/EA flow
    Codecs.cs             Feature ids, Battery, EQSetting, EQMode, DongleStatus, ChargingState, errors
    A30Client.cs          typed API over a transport (see below)
    ITransport.cs         byte pipe abstraction
  A30Kit.SelfTest/        net8.0 console; ports A30Control/Tests (real captured bytes); runs on the Mac
  A30Control/             net8.0-windows10.0.19041.0 WPF app (UseWPF + UseWindowsForms for NotifyIcon)
    RfcommTransport.cs    WinRT Bluetooth RFCOMM → ITransport
    HeadsetModel.cs       app state + logic (port of HeadsetModel.swift)
    Store.cs              settings.json persistence
    WindowsIntegration.cs Run-key autostart, foreground-app hook, toasts
    TrayIcon.cs           NotifyIcon, badge-composited icon, tooltip, context menu
    Views/                TrayPanel, MainWindow and one view per tab, shared styles
  build.ps1 / build.sh    publish → A30Control.Windows/dist/A30Control.exe
```

## Protocol core (A30Kit)

A direct port of `A30Control/Sources/A30Kit` (Swift). Same wire formats as `CLAUDE.md`:
- SPP frame `13 A0|lenHi len payload crcLo crcHi`, CRC-16/MCRF4XX over `len+3` bytes; replies may
  carry CRC `00 00` (iAP2 path) — accept a valid CRC or `00 00`.
- CPL byte (bit0 more, bits1-7 seq) with reassembly.
- CPP `[featureIndex, fn<<4 | swId, args]`; error reply `FF idx fn|sw code`.
- iAP2: detect `FF 55 02 00 EE 10`, link `FF 5A`, SYN/SYN+ACK/ACK, ACK every data packet,
  AA00→AA01, AA02→AA03 (not verified), AA05, 1D00→1D01, 1D02, EA00 (proto 1, EA sid 1), CPP on
  session 3 prefixed by the EA sid.

`A30Client`:
- `ConnectAsync(ITransport)`: transport detection (below), then iFeatureSet enumeration into an
  index map. Features are addressed by id, never by hard-coded index.
- Request/response matching by rotating swId 1–15; per-request timeout; errors surface as
  `A30Exception(code)`.
- `Notification` event for swID-0 replies: volume `[level, muted]`, EQ `[mode, bands]`,
  mic mute `[state]`, battery `[real, user, charging]`.
- Typed calls mirroring `A30.swift`: battery, device info (fw, serial), name/rename, volume/set,
  audio mute get/set, sidetone get/set per mic, noise gate get/set, balance get/set, dongle status,
  dongle PC/Xbox, auto-sleep get/set (incl. arbitrary minutes for turn-off), tones get/set,
  EQ get/set/modes, factory reset.

### Transport detection

After the RFCOMM socket opens, listen for 1.5 s:
- `FF 55 02 00 EE 10` received → iAP2 path (exactly the Mac flow).
- Anything else / nothing → raw path: CPP inside SPP frames written directly to the socket, as the
  Android app does. If the first raw request times out and an iAP2 detect arrives later, switch to
  the iAP2 path.

Every step and every frame (hex) is logged to `%APPDATA%\A30Control\a30.log` (rotated at 1 MB).

## Bluetooth transport (RfcommTransport)

- Find paired devices (`BluetoothDevice.GetDeviceSelectorFromPairingState(true)`) whose name
  contains "A30".
- Connect only if `ConnectionStatus == Connected` — the app never forces a Bluetooth connection
  (same rule as the Mac).
- `GetRfcommServicesForIdAsync(RfcommServiceId.SerialPort, BluetoothCacheMode.Uncached)`;
  `StreamSocket.ConnectAsync(host, serviceName)`; a reader loop raises `Received`.
- Disconnect → `Closed`; the model's connect loop retries (same back-off as the Mac).

## App (HeadsetModel and views)

`HeadsetModel` ports `HeadsetModel.swift` behaviour: connect loop with reconnect suspension,
60 s polling (battery, dongle, volume), 150 ms debounced writes, EQ-notification suppression while
writing, Custom curve memory, turn-off flow (sleep 1 min, close channel, 120 s countdown, restore
sleep to never on the next connect), saved EQ curves, profiles (EQ + sidetone + noise gate +
balance when the dongle is connected), rename, audio mute, base station mode, EQ per app,
low-battery (20/10 %) and mic-mute notifications. Implements `INotifyPropertyChanged`; UI work is
marshalled to the dispatcher.

Tray:
- Icon generated from `A30Control/Assets/icon.png` (16/20/24/32 px), with badges composited
  (charging bolt, low battery, mic muted). The tooltip shows name, battery % and charging.
- Left click: borderless panel above the tray with the Mac's card layout (volume + 3×2 EQ presets;
  sidetone, game mix, turn off) and Open window / Quit.
- Right click: Open window, Quit. Closing the main window hides it; Quit exits.

Main window: 980×660 fixed, no maximize, dark Command Center style (accent `#ff4b1f`), tabs
EQUALIZER, MICROPHONE, MIX, EXTRAS, SETTINGS with the Mac content.

Windows equivalents:
- Open at login: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\A30Control`.
- EQ per app: `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` → process exe name; rules hold the exe
  name; "Add app" opens an `.exe` file picker.
- Notifications: Windows toasts via `NotifyIcon.ShowBalloonTip` (rendered as toasts on 10/11).
- Persistence: `%APPDATA%\A30Control\settings.json` (saved curves, profiles, app rules, last Custom
  bands, restore-sleep flag).

## Error handling

- Connection errors show in the tray panel ("Looking for ASTRO A30…" + reason) and the log; never
  modal dialogs.
- Write failures show a short banner (e.g. balance `NOT_CONNECTED` → "Connect the dongle").
- An unknown transport behaviour (no reply on either path) ends with a log hint telling Doug to
  send `a30.log`.

## Testing and delivery

- `A30Kit.SelfTest` runs on the Mac (`dotnet run`): framing/CRC (incl. check value `0x6F91`), CPL
  reassembly, iAP2 packet build/parse, codecs — using the byte fixtures from `A30Control/Tests`.
- `A30Control` is compiled on the Mac to catch build errors; UI and Bluetooth are verified by Doug.
- `build.sh` publishes `dist/A30Control.exe` (self-contained, single file, ~70 MB). Unsigned:
  SmartScreen → "More info → Run anyway".
- `docs/superpowers/a30-control-windows-checklist.md`: manual checklist for Doug's PC, including
  balance and PC/Xbox mode with the dongle, restoring original state afterwards.

## Out of scope

Firmware update, code signing, an installer (MSI), ARM64 builds, BLE transport.
