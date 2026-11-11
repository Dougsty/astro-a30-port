# A30 Control — manual checklist

Everything below needs eyes, ears or hands; the protocol layer is already
unit-tested and hardware-verified with the probe. Headset on and connected to the
Mac. Quit A30 Control before running `probe.sh` or `tools/a30b/run.sh` (one client per channel).

## 0. Menu-bar app, login item, icon

- [ ] No Dock icon; only the headphones in the menu bar. The window does not open on launch.
- [ ] "Open window…" opens it **and a Dock icon appears**; closing the window removes the Dock icon, menu bar stays.
- [ ] With the window open, Dock → right-click → Quit (or ⌘Q): window closes, menu bar app keeps running.
- [ ] Panel "Quit" really quits.
- [ ] Volume slider (panel and Home) changes the headset volume; turning the wheel updates it within ~60 s.
- [ ] Finder → /Applications shows the A30 Control icon (graphite, headset, red star).
- [ ] Toggle "Open at login" on → listed in System Settings → General → Login Items; log out/in → app starts.

## 1. Build and first launch

```bash
A30Control/install.sh
```

- [ ] macOS asks for Bluetooth access for **A30 Control** → Allow. (The app may look
      frozen until you answer — expected on first launch only.)
- [ ] Menu bar shows a headphones icon with the battery % next to it.

## 2. Menu bar panel

- [ ] EQ segmented control shows the current preset (Custom).
- [ ] Boom sidetone slider shows 40 %.
- [ ] Game/chat balance is greyed out with "Connect the 2.4 GHz dongle…".
- [ ] "Open window…" brings up the window.

## 3. Home

- [ ] Battery %, "Bluetooth connected", "Dongle not connected", volume 30 / 31.
- [ ] Change volume on the headset wheel; within ~60 s the Home volume updates.

## 4. EQ

- [ ] Switch Immersive → Footstep → Custom: the sound changes each time and the
      control stays on what you picked.
- [ ] In Custom, drag **31 Hz** to +6 dB: you **hear** more bass (a short dip to
      Immersive while it applies is expected) and the label stays at `+6 dB`.
- [ ] Switch to Footstep, then back to Custom: the +6 dB curve comes back.
- [ ] Quit and relaunch, select Custom: the curve is still there.
- [ ] Keyboard: Tab to a band slider, press → a few times, switch pane and back:
      the new value stuck.
- [ ] Drag a band and click Footstep immediately (< ¼ s): Footstep should win.
      If the app jumps back to Custom, report it (known narrow race, one-line fix).
- [ ] "Reset flat" sets every band to 0 dB.

## 5. Microphone

- [ ] Boom tab: sidetone to 60 % → you hear more of your own voice. Back to 40 %.
- [ ] Noise gate Night, then Off: each stays selected.
- [ ] Internal tab shows its own values (40 % / Off).

## 6. Settings

- [ ] Name `ASTRO A30`, firmware `1.0.59`, serial `224`.
- [ ] Sleep mode 15 minutes → stays; set back to **Never**.
- [ ] Tones All → stays; set back to **Minimal**.
- [ ] Factory reset… → alert → Cancel. Again → Continue → sheet; type `RES`: the
      button stays disabled. Cancel. **Do not reset.**

## 7. Robustness

- [ ] Headset off, launch the app: "Looking for ASTRO A30…" with the error text,
      no crash. Power on: connects within ~15 s.
- [ ] While connected, power the headset off: overlay appears, app stays
      responsive; power on: reconnects by itself.
- [ ] Quit the app, relaunch: note how long until connected (should be a few
      seconds, no 8 s stall).
- [ ] Logitech G app open on the iPhone, then launch A30 Control: it connects or
      keeps retrying with an error shown — never hangs. Close the iPhone app: it
      connects on the next retry.

## 8. Leave it as you found it

Custom flat · sidetone 40 / 40 · noise gate Off / Off · sleep Never · tones Minimal.
