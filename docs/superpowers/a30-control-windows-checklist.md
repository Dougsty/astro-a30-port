# A30 Control for Windows — manual checklist

Run `A30Control-Setup-<version>.exe` on the PC (per-user install, no admin rights), or copy the portable
`A30Control.exe` to any folder.
Headset paired in Windows Bluetooth settings; 2.4 GHz dongle plugged in. If something fails, send
`%APPDATA%\A30Control\a30.log`.

## 1. Install and first launch
- [ ] SmartScreen: "More info" → "Run anyway" (setup and exe are not signed).
- [ ] Setup: components "Start with Windows" (on) and "Desktop shortcut" (off); "Start A30 Control now" on the last page.
- [ ] Start menu has "A30 Control"; Settings → Apps lists "A30 Control" (Dougsty) with Uninstall.
- [ ] The A30 icon appears in the notification area (it may be under the ^ overflow; drag it out).
- [ ] Starting from the Start menu (or the setup's last page) opens the window; after a Windows sign-in with
      "Start with Windows" on, only the tray icon appears.
- [ ] Start it again while it runs: no second icon; the running copy's window comes to the front.
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

## 6. Uninstall
- [ ] Settings → Apps → A30 Control → Uninstall: the app closes, the Start menu entry and the Startup entry are gone.
      `%APPDATA%\A30Control` (settings, log) stays, so a reinstall keeps profiles.

## 7. Leave it as you found it
Custom flat · sidetone 40 / 40 · noise gate Off / Off · sleep Never · tones Minimal · balance 50 % · base station PC.
