// Single source of truth for both the menu bar panel and the window.
// View-local state lives here too: the macOS 27 SDK's @State needs a macro plugin that only
// Xcode ships, so views bind to this model with Binding(get:set:).
import Foundation
import AppKit
import Observation
import ServiceManagement

/// Tabs of the Command Center–style window.
enum Pane: String, CaseIterable, Identifiable {
    case equalizer = "Equalizer", microphone = "Microphone", mix = "Mix", extras = "Extras", settings = "Settings"
    var id: Self { self }
    var icon: String {
        switch self {
        case .equalizer: "slider.vertical.3"
        case .microphone: "mic"
        case .mix: "arrow.left.arrow.right"
        case .extras: "sparkles"
        case .settings: "line.3.horizontal"
        }
    }
}

@Observable @MainActor
final class HeadsetModel {
    static let shared = HeadsetModel()

    enum Connection: Equatable { case searching, connected, failed(String) }

    var connection: Connection = .searching
    var battery: Battery? { didSet { checkBattery() } }
    /// Boom-mic mute pushed by the headset; nil until the first toggle (no GET exists).
    var micMuted: Bool?
    /// "EQ per app" rules, persisted.
    var appRules: [AppEQRule] = AppEQRule.load() { didSet { AppEQRule.save(appRules) } }
    var name = "ASTRO A30"
    var firmware = "—"
    var serial = "—"
    var volume: Int?
    /// Headset audio output muted (iVolumeSet byte 2).
    var audioMuted: Bool?
    var savedEQs: [SavedEQ] = Store.load("a30.savedEQs") { didSet { Store.save(savedEQs, "a30.savedEQs") } }
    var profiles: [Profile] = Store.load("a30.profiles") { didSet { Store.save(profiles, "a30.profiles") } }
    var eq: EQSetting?
    var eqModes: [EQMode] = EQMode.allCases
    var sidetone: [Mic: Int] = [:]
    var noiseGate: [Mic: NoiseGate] = [:]
    var balance: Int?
    var dongle = DongleStatus(0)
    var sleep: SleepTimer?
    var tones: Tones?
    var banner: String?
    var lastConnectError: String?
    /// Last Custom-mode bands, so switching back to Custom restores the curve.
    var lastCustomBands: [Int] = {
        let v = UserDefaults.standard.array(forKey: "a30.lastCustomBands") as? [Int]
        return v?.count == 5 ? v! : [0, 0, 0, 0, 0]
    }() {
        didSet { UserDefaults.standard.set(lastCustomBands, forKey: "a30.lastCustomBands") }
    }

    // view state
    var pane: Pane = .equalizer
    var micTab: Mic = .boom
    var showResetAlert = false
    var showResetSheet = false
    var resetText = ""
    /// Mirrors SMAppService.mainApp; only reliable when the app lives in /Applications (install.sh).
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Status badges drawn next to the menu bar glyph.
    var menuBadges: [MenuBarIcon.Badge] {
        var out: [MenuBarIcon.Badge] = []
        if micMuted == true { out.append(.micMuted) }
        if connection == .connected, let b = battery {
            // the headset pushes this ~2 s after USB-C is plugged/unplugged (idx 2, byte 3)
            if b.isCharging { out.append(.charging) } else if b.percent <= 20 { out.append(.lowBattery) }
        }
        return out
    }

    var menuTitle: String { connection == .connected ? (battery.map { "\($0.percent)%" } ?? "") : "" }

    private let a30 = A30()
    private var started = false
    private var pollTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private enum Control: Hashable { case sidetone(Mic), balance, eq, volume }
    private var debounce: [Control: Task<Void, Never>] = [:]

    func start() {
        guard !started else { return }
        started = true
        Notifier.requestPermission()
        Extras.watchFrontmostApp(self)
        a30.onClose = { [weak self] in self?.disconnected() }
        a30.onNotification = { [weak self] f, fn, args in self?.notified(f, fn, args) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [a30] _ in
            MainActor.assumeIsolated { a30.disconnect() }
        }
        reconnect()
    }

    /// At most one connect loop at a time.
    private func reconnect() {
        guard connectTask == nil else { return }
        connectTask = Task { await connectLoop(); connectTask = nil }
    }

    private func connectLoop() async {
        while true {
            // After "Turn off", leave the headset alone so it can go idle and power down.
            if let until = suspendReconnectUntil {
                let wait = until.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                suspendReconnectUntil = nil
            }
            connection = .searching
            do {
                try await a30.connect()
                connection = .connected
                lastConnectError = nil
                await finishTurnOffIfNeeded()
                await refreshAll()
                // A drop during refreshAll sets .searching via disconnected(): retry.
                guard connection == .connected else { continue }
                startPolling()
                return
            } catch {
                connection = .failed(message(error))
                lastConnectError = message(error)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func disconnected() {
        pollTask?.cancel()
        connection = .searching
        reconnect()
    }

    /// Each read is independent, so one unsupported feature does not hide the rest.
    func refreshAll() async {
        if let v = try? await a30.battery() { battery = v }
        if let v = try? await a30.name() { name = v }
        if let v = try? await a30.firmware() { firmware = v }
        if let v = try? await a30.serial() { serial = v }
        volume = try? await a30.volume()
        if let v = try? await a30.eq() { store(v) } else { eq = nil }
        if let m = try? await a30.eqModes() {
            // + the Astro Studio/Gaming/Pro modes the firmware accepts but doesn't list
            let listed = m.compactMap(EQMode.init(rawValue:))
            eqModes = listed + [.studio, .gaming, .pro].filter { !listed.contains($0) }
        }
        audioMuted = try? await a30.audioMuted()
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
                guard (try? await Task.sleep(for: .seconds(60))) != nil, !Task.isCancelled else { return }
                guard let self, self.connection == .connected else { return }
                do { self.battery = try await self.a30.battery() }
                catch A30Error.disconnected { self.disconnected(); return }
                catch {}
                if let d = try? await self.a30.dongle() { self.dongle = d }
                if let v = try? await self.a30.volume() { self.volume = v }
            }
        }
    }

    // MARK: writes — every SET is followed by a GET; the UI shows what the headset reports

    private func write(_ op: () async throws -> Void, reread: () async -> Void) async {
        do { try await op() } catch { show(message(error)) }
        await reread()
    }

    /// Live updates pushed by the headset (volume wheel, EQ changes). Ignored while the
    /// user is dragging that control, so a slider doesn't jump under the cursor.
    private func notified(_ f: FeatureID, _ fn: UInt8, _ args: [UInt8]) {
        guard fn == 0 else { return }
        switch f {
        case .volume where debounce[.volume] == nil:
            if let v = args.first { volume = Int(v) }
            if args.count > 1 { audioMuted = args[1] != 0 }
        case .micMute:
            if let s = args.first { setMicMuted(s != 0) }
        case .battery:
            if let b = Battery(args) { battery = b }
        case .eq where debounce[.eq] == nil && eqWrites == 0:
            if let e = EQSetting(args) { store(e) }
        default:
            break
        }
    }

    private func store(_ v: EQSetting) {
        eq = v
        if v.mode == EQMode.custom.rawValue { lastCustomBands = v.bands }
    }

    private func rereadEQ() async { if let v = try? await a30.eq() { store(v) } }

    /// Local update now, send after 150 ms without further changes (works for keyboard/VoiceOver too).
    private func schedule(_ c: Control, _ commit: @escaping @MainActor () -> Void) {
        debounce[c]?.cancel()
        debounce[c] = Task {
            guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
            debounce[c] = nil   // drag finished: live notifications for this control apply again
            commit()
        }
    }

    func selectEQ(_ mode: EQMode) {
        let switching = eq?.mode != mode.rawValue
        let bands = mode == .custom ? lastCustomBands : [0, 0, 0, 0, 0]
        let target = EQSetting(mode: mode.rawValue, bands: bands)
        writeEQ(target, switching: switching)
    }

    /// EQ writes pass through Immersive and the headset pushes a notification for each step;
    /// applying those mid-write made the preset list flash Custom → Immersive → Custom.
    /// So EQ notifications are ignored while a write is in flight and briefly after it.
    private var eqWrites = 0
    private func writeEQ(_ s: EQSetting, switching: Bool) {
        eqWrites += 1
        Task {
            await write({ try await a30.setEQ(s, switching: switching) }, reread: { await rereadEQ() })
            try? await Task.sleep(for: .milliseconds(400))   // trailing notifications
            eqWrites -= 1
        }
    }

    func setBand(_ i: Int, _ db: Int) {
        eq?.bands[i] = db
        schedule(.eq) { [self] in commitEQ() }
    }

    func commitEQ() {
        guard let e = eq else { return }
        if e.mode == EQMode.custom.rawValue { lastCustomBands = e.bands }
        // Official app's pass-through: Immersive flat, 100 ms, then the custom bands.
        writeEQ(e, switching: true)
    }

    /// Drop unsent band edits and show what the headset has.
    func revertEQ() { Task { await rereadEQ() } }

    func resetFlat() {
        eq?.bands = [0, 0, 0, 0, 0]
        commitEQ()
    }

    func setSidetone(_ mic: Mic, _ v: Int) {
        sidetone[mic] = v
        schedule(.sidetone(mic)) { [self] in commitSidetone(mic) }
    }

    func setVolume(_ v: Int) {
        volume = v
        schedule(.volume) { [self] in commitVolume() }
    }

    func commitVolume() {
        guard let v = volume else { return }
        Task { await write({ try await a30.setVolume(v) }, reread: { if let v = try? await a30.volume() { volume = v } }) }
    }

    func setBalance(_ v: Int) {
        balance = v
        schedule(.balance) { [self] in commitBalance() }
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
        Task { await write({ try await a30.setBalance(v) }, reread: { if let v = try? await a30.balance() { balance = v } }) }
    }

    func setSleep(_ t: SleepTimer) {
        sleep = t
        Task { await write({ try await a30.setSleepTimer(t) }, reread: { if let v = try? await a30.sleepTimer() { sleep = v } }) }
    }

    func setTones(_ t: Tones) {
        tones = t
        Task { await write({ try await a30.setTones(t) }, reread: { if let v = try? await a30.tones() { tones = v } }) }
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

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show("Open at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: helpers

    // MARK: extras: mic mute, battery alerts, shortcuts, EQ per app

    private var alerted20 = false
    private var alerted10 = false
    private var restoreMode: UInt8?   // mode to put back when leaving an app with an EQ rule

    private func setMicMuted(_ m: Bool) {
        guard micMuted != m else { return }
        micMuted = m
        Notifier.post(m ? "Mic muted" : "Mic unmuted", "ASTRO A30")
    }

    private func checkBattery() {
        guard let b = battery else { return }
        if b.isCharging || b.percent > 25 { alerted20 = false; alerted10 = false; return }
        if b.percent <= 10 && !alerted10 {
            alerted10 = true; alerted20 = true
            Notifier.post("A30 battery at \(b.percent)%", "Charge the headset soon.")
        } else if b.percent <= 20 && !alerted20 {
            alerted20 = true
            Notifier.post("A30 battery at \(b.percent)%", "Battery is getting low.")
        }
    }

    /// Frontmost app changed: apply its EQ rule, or restore the mode from before the last rule.
    // MARK: turn off (no power-off command on the A30: 1-minute auto-sleep, then back to never)

    /// Seconds left in the turn-off countdown (nil when not turning off).
    var powerOffRemaining: Int?
    private var powerOffTask: Task<Void, Never>?
    private var suspendReconnectUntil: Date?
    private var powerOffStartedAt: Date?
    /// Survives quitting the app: the sleep mode is put back to "never" on the next connect.
    private var restoreSleepPending: Bool {
        get { UserDefaults.standard.bool(forKey: "a30.restoreSleepNever") }
        set { UserDefaults.standard.set(newValue, forKey: "a30.restoreSleepNever") }
    }

    func turnOff() {
        guard connection == .connected, powerOffRemaining == nil else { return }
        Task {
            do { try await a30.setSleepMinutes(1) } catch { show(message(error)); return }
            restoreSleepPending = true
            powerOffStartedAt = Date()
            // Close the control channel and stay away, so our traffic doesn't keep it awake.
            suspendReconnectUntil = Date().addingTimeInterval(135)
            pollTask?.cancel()
            a30.disconnect()
            powerOffRemaining = 120   // measured: ~2 min from SET 1 min to power-off (2026-11-10)
            powerOffTask = Task {
                while let r = powerOffRemaining, r > 0 {
                    guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
                    powerOffRemaining = r - 1
                }
                powerOffRemaining = nil
                reconnect()   // waits out suspendReconnectUntil, then finds the headset off (or not)
            }
        }
    }

    func cancelTurnOff() {
        powerOffTask?.cancel()
        powerOffRemaining = nil
        powerOffStartedAt = nil
        suspendReconnectUntil = nil
        reconnect()   // reconnecting restores the sleep mode to never
    }

    private func finishTurnOffIfNeeded() async {
        guard restoreSleepPending else { return }
        if (try? await a30.setSleepTimer(.never)) != nil {
            restoreSleepPending = false
            sleep = .never
        }
        if let t = powerOffStartedAt, Date().timeIntervalSince(t) < 180 {
            show("The headset didn't turn off. Pause any audio and try again.")
        }
        powerOffStartedAt = nil
    }

    // MARK: rename, audio mute, base station mode

    func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task { await write({ try await a30.setName(n) }, reread: { if let v = try? await a30.name() { self.name = v } }) }
    }

    func setAudioMuted(_ m: Bool) {
        audioMuted = m
        Task { await write({ try await a30.setAudioMuted(m) }, reread: { if let v = try? await a30.audioMuted() { audioMuted = v } }) }
    }

    func setDongleXbox(_ x: Bool) {
        Task {
            await write({ try await a30.setDongleXbox(x) }, reread: {
                // the dongle drops and re-links after a mode change; read once it is back
                try? await Task.sleep(for: .seconds(6))
                if let d = try? await a30.dongle() { dongle = d }
            })
        }
    }

    // MARK: saved EQ curves and profiles (stored on this Mac, like the official app's local DB)

    func saveCurrentEQ(as name: String) {
        guard let e = eq, e.mode == EQMode.custom.rawValue else { return }
        savedEQs.append(SavedEQ(id: UUID(), name: name, bands: e.bands))
    }

    func applySavedEQ(_ s: SavedEQ) {
        lastCustomBands = s.bands
        if eq?.mode == EQMode.custom.rawValue { eq?.bands = s.bands; commitEQ() } else { selectEQ(.custom) }
    }

    func saveProfile(as name: String) {
        guard let e = eq else { return }
        profiles.append(Profile(id: UUID(), name: name, eqMode: e.mode, bands: e.mode == EQMode.custom.rawValue ? e.bands : lastCustomBands,
                                sidetone: Dictionary(uniqueKeysWithValues: sidetone.map { ($0.key.rawValue, $0.value) }),
                                noiseGate: Dictionary(uniqueKeysWithValues: noiseGate.map { ($0.key.rawValue, $0.value.rawValue) }),
                                balance: dongle.connected ? balance : nil))
    }

    func applyProfile(_ p: Profile) {
        if let mode = EQMode(rawValue: p.eqMode) {
            lastCustomBands = p.bands
            if mode == .custom && eq?.mode == EQMode.custom.rawValue { eq?.bands = p.bands; commitEQ() } else { selectEQ(mode) }
        }
        for (raw, v) in p.sidetone { if let m = Mic(rawValue: raw) { setSidetone(m, v) } }
        for (raw, g) in p.noiseGate { if let m = Mic(rawValue: raw), let ng = NoiseGate(rawValue: g) { setNoiseGate(m, ng) } }
        if let b = p.balance, dongle.connected { setBalance(b) }
        show("Profile \(p.name) applied")
    }

    func appActivated(_ bundleID: String?) {
        guard connection == .connected, let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        if let rule = appRules.first(where: { $0.bundleID == bundleID }), let mode = EQMode(rawValue: rule.mode) {
            if restoreMode == nil { restoreMode = eq?.mode }
            if eq?.mode != mode.rawValue { selectEQ(mode) }
        } else if let prev = restoreMode {
            restoreMode = nil
            if eq?.mode != prev, let m = EQMode(rawValue: prev) { selectEQ(m) }
        }
    }

    func addAppRule(bundleID: String, name: String) {
        guard !appRules.contains(where: { $0.bundleID == bundleID }) else { return }
        appRules.append(AppEQRule(bundleID: bundleID, name: name, mode: EQMode.footstep.rawValue))
    }

    func show(_ msg: String) {
        banner = msg
        Task {
            try? await Task.sleep(for: .seconds(4))
            if banner == msg { banner = nil }
        }
    }

    func message(_ e: Error) -> String { (e as? A30Error)?.message ?? e.localizedDescription }
}
