// Typed async API for the A30. Feature indexes come from the headset's own feature list
// at connect, never from constants, so a firmware that reorders features still works.
import Foundation
import IOBluetooth

@MainActor
public final class A30 {
    private let link = HeadsetLink()
    public var onClose: (@MainActor () -> Void)? { get { link.onClose } set { link.onClose = newValue } }
    private var index: [UInt16: UInt8] = [:]

    /// Device-pushed report decoded to its feature: (feature, function, args).
    public var onNotification: (@MainActor (FeatureID, UInt8, [UInt8]) -> Void)? {
        didSet {
            link.onNotification = { [weak self] i, fn, args in
                guard let self, let id = self.index.first(where: { $0.value == i })?.key,
                      let f = FeatureID(rawValue: id) else { return }
                self.onNotification?(f, fn, args)
            }
        }
    }

    public init() {}

    /// First paired device whose name contains "A30".
    public static func pairedAddress() -> String? {
        let devs = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devs.first { ($0.name ?? "").contains("A30") }?.addressString
    }

    public func connect() async throws {
        index = [:]
        guard let address = Self.pairedAddress() else { throw A30Error.notFound }
        try await link.open(address: address)
        let list: [UInt8]
        do { list = try await link.request(1, 1, [0]) }   // iFeatureSet (always idx 1) GET_FEATURE_ID(0)
        catch { link.close(); throw error }
        for (i, id) in parseFeatureList(list).enumerated() { index[id] = UInt8(i) }
    }

    public func disconnect() { link.close() }

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
    /// iVolumeSet GET: [level, muted].
    public func audioMuted() async throws -> Bool { let a = try await call(.volume, 0); return try decoded(a.count > 1 ? a[1] != 0 : nil) }
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
    /// iVolumeSet SET_VOLUME_LEVEL: one byte, 0–31 (AppConstants.HEADSET_MAX_DEVICE_VOLUME).
    /// iVolumeSet SET_MUTE_STATUS (fn 2): mutes the headset's audio output. Tested 2026-11-10.
    public func setAudioMuted(_ m: Bool) async throws { _ = try await call(.volume, 2, [m ? 1 : 0]) }
    /// iDeviceName SET_NAME (fn 1): [len][utf8], max 48 bytes — the name shown in Bluetooth.
    public func setName(_ n: String) async throws { _ = try await call(.deviceName, 1, lengthPrefixed(String(n.utf8.prefix(48))!)) }
    /// iHeadsetDongle SET_CONFIG (fn 1): base station host type, 0 = PC, 1 = Xbox (official "Base station mode", read back as bit 2).
    public func setDongleXbox(_ xbox: Bool) async throws { _ = try await call(.dongle, 1, [xbox ? 1 : 0]) }
    public func setVolume(_ v: Int) async throws { _ = try await call(.volume, 1, [UInt8(min(max(v, 0), 31))]) }
    public func setBalance(_ v: Int) async throws { _ = try await call(.mix, 1, [UInt8(min(max(v, 0), 20))]) }
    /// Raw auto-sleep minutes (the app's presets are 0/15/30/60; the firmware accepts 1…255).
    public func setSleepMinutes(_ m: UInt8) async throws { _ = try await call(.autoSleep, 1, [m, m]) }
    public func setSleepTimer(_ t: SleepTimer) async throws { _ = try await call(.autoSleep, 1, [t.rawValue, t.rawValue]) }
    public func setTones(_ t: Tones) async throws { _ = try await call(.tones, 1, [t.rawValue]) }

    /// Erases all headset settings (iDeviceInfo FACTORY_RESET with the serial GET_SERIAL_NUMBER
    /// returned). The official app sends the user through re-pairing afterwards.
    public func factoryReset(serial: String) async throws {
        _ = try await call(.deviceInfo, 4, lengthPrefixed(serial))
    }
}
