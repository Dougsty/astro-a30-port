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
    check(b?.percent == 42 && b?.user == 40 && b?.charging == .notCharging && b?.isCharging == false, "battery: real SOC, user SOC")
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
