// Typed values for the A30's CPP features and their byte encodings. Encodings were
// read from the decompiled Logitech G app (jadx/, see the spec's "Value encodings").
import Foundation

public enum FeatureID: UInt16 {
    case root = 0x0000, featureSet = 0x0001, profile = 0x0004
    case deviceInfo = 0x0100, deviceName = 0x0101, battery = 0x0104, autoSleep = 0x0108
    case volume = 0x0200, eq = 0x0201
    case micMute = 0x0601   // no GET for the mute state; the headset pushes it (swID 0)
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
    case notFound, notConnectedToMac, openFailed(Int32), timeout, disconnected, unsupported, badReply
    case device(CenturionError)

    public var message: String {
        switch self {
        case .notFound: "ASTRO A30 is not paired with this Mac"
        case .notConnectedToMac: "ASTRO A30 is not connected to this Mac (connect it from the Bluetooth menu)"
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

/// GET_BATTERY_STATUS: [realSOC, userSOC, chargingState]. The official app shows userSOC, but
/// that moves in 10 % steps (10, 30, 40…) and looks frozen while charging; realSOC moves 1 % at
/// a time (measured 33→34→35 % while userSOC stayed 30 %), so `percent` is realSOC.
public struct Battery: Equatable {
    public let percent: Int   // realSOC, 1 % steps
    public let user: Int      // userSOC, 10 % steps (what the official app shows)
    public let charging: ChargingState?

    public init?(_ a: [UInt8]) {
        guard a.count >= 3 else { return nil }
        percent = Int(a[0]); user = Int(a[1]); charging = ChargingState(rawValue: a[2])
    }

    public var isCharging: Bool { charging.map { [.slow, .fast, .full].contains($0) } ?? false }
}

public enum EQMode: UInt8, CaseIterable {
    case custom = 0x04, immersive = 0x80, footstep = 0x81
    // Named in the official app (UtilsKt.getCode) but not offered for the A30; its firmware accepts them.
    case studio = 0x82, gaming = 0x83, pro = 0x84
    public var label: String {
        switch self {
        case .custom: "Custom"
        case .immersive: "Immersive"
        case .footstep: "Footstep"
        case .studio: "Astro Studio"
        case .gaming: "Astro Gaming"
        case .pro: "Astro Pro"
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
/// For the A30 the official "Base station mode" is the host type: SET_CONFIG [0 PC, 1 Xbox] sets bit 2
/// (tested 2026-11-10: 01 → 05 after SET 1); the dongle drops and reconnects for a few seconds.
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
