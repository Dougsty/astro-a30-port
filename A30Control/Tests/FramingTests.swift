import Foundation

// Fragmented reply to FeatureSet.GET_FEATURE_ID[0], three SPP frames, CRC 00 00.
let featureListFrames = [
    bytes("13 a0 20 01 01 12 10 00 00 00 02 00 01 00 01 01 04 00 03 01 00 00 04 01 01 00 02 06 01 00 01 06 0b 00 01 00 00"),
    bytes("13 a0 20 03 02 00 00 03 06 04 00 01 06 08 00 01 06 09 00 01 06 0a 00 01 01 08 00 03 01 0a 00 04 02 01 00 00 00"),
    bytes("13 a0 06 04 03 00 04 00 03 00 00"),
]
let synFixture = bytes("ff 5a 00 1a 80 18 00 00 f5 01 05 00 84 05 dc 01 f4 1e 03 01 00 01 03 02 01 77")

func testFraming() {
    // CRC-16/MCRF4XX check value
    check(crc16(Array("123456789".utf8)) == 0x6F91, "crc check value")

    // CLAUDE.md worked example: GET_FEATURE(iEQSet) swId 1
    check(sppWrap(cppRequest(index: 0, function: 0, swID: 1, args: [0x02, 0x01]))
          == bytes("13 a0 05 00 00 01 02 01 d8 24"), "sppWrap worked example")

    // SPP parser across chunk boundaries, CRC 00 00 accepted
    var spp = SPPParser()
    check(spp.feed(bytes("13 a0 06 00")).isEmpty, "partial frame yields nothing")
    check(spp.feed(bytes("00 01 00 00 02 00 00")) == [bytes("00 00 01 00 00 02")], "frame completes")
    // bad CRC is dropped, correct CRC is accepted
    check(spp.feed(bytes("13 a0 01 00 12 34")).isEmpty, "bad crc dropped")
    check(spp.feed(sppWrap([0x00, 0x07])) == [[0x00, 0x07]], "good crc accepted")

    // CPL reassembly of the fragmented feature list
    var spp2 = SPPParser(), cpl = CPLReassembler()
    var messages: [[UInt8]] = []
    for f in featureListFrames {
        for p in spp2.feed(f) { if let m = cpl.feed(p) { messages.append(m) } }
    }
    check(messages.count == 1, "one reassembled message")
    check(messages.first?.count == 67, "reassembled length 2 + 65")
    if let m = messages.first, case let .ok(index, function, swID, args)? = CPPReply(m) {
        check(index == 1 && function == 1 && swID == 2, "reply header")
        check(args.first == 0x10, "feature count 16")
    } else { check(false, "feature list parses as ok reply") }

    // Error reply: FF featIdx fn|sw code (payload 00 ff 00 06 05)
    var cpl2 = CPLReassembler()
    check(cpl2.feed(bytes("00 ff 00 06 05")).flatMap(CPPReply.init)
          == .error(index: 0, function: 0, swID: 6, code: 5), "error reply")

    // CPL continuity: a final fragment with seq 2 and no seq 0/1 is discarded
    var cplGap = CPLReassembler()
    check(cplGap.feed(bytes("04 01 02 03")) == nil, "orphan fragment seq 2 dropped")
    // An aborted partial must not leak into the next single-fragment message
    var cplAbort = CPLReassembler()
    check(cplAbort.feed(bytes("01 aa bb")) == nil, "partial fragment buffered")
    check(cplAbort.feed(bytes("00 11 22")) == [0x11, 0x22], "single fragment after abort returns only its bytes")
    // A gap mid-message (seq 0, then seq 2) drops the partial and the stray fragment
    var cplMid = CPLReassembler()
    check(cplMid.feed(bytes("01 aa")) == nil, "seq 0 buffered")
    check(cplMid.feed(bytes("05 bb")) == nil, "seq 2 after seq 0 dropped")
    check(cplMid.feed(bytes("00 33")) == [0x33], "fresh message after gap")

    // iAP2 link packet: re-encoding the headset's own SYN reproduces it exactly
    let syn = LinkPacket(control: LinkPacket.SYN, seq: 0x18, ack: 0, session: 0,
                         payload: Array(synFixture[9..<25]))
    check(syn.encode() == synFixture, "SYN encode matches fixture")

    // Splitter: detect + SYN split mid-packet, then a corrupted packet is dropped
    var sp = IAP2Splitter()
    let stream = iap2Detect + synFixture
    let a = sp.feed(Array(stream[0..<10]))
    let b = sp.feed(Array(stream[10...]))
    check(a == [.detect], "detect first")
    check(b == [.packet(syn)], "SYN after second chunk")
    var bad = synFixture; bad[12] ^= 0xFF
    check(sp.feed(bad).isEmpty, "bad payload checksum dropped")
    check(sp.feed(Array(iap2Detect[0..<3])).isEmpty, "partial detect waits")
    check(sp.feed(Array(iap2Detect[3...])) == [.detect], "detect completes")

    // A bogus FF 5A header (bad header checksum) must not stall the valid SYN behind it
    var resync = IAP2Splitter()
    let rOut = resync.feed(bytes("ff 5a ff ff 00 00 00 00 00") + synFixture)
    check(rOut.last == .packet(syn), "valid SYN found after bogus header")
    check(rOut.count > 1 && rOut.dropLast().allSatisfy({ if case .junk = $0 { return true } else { return false } }),
          "bogus header bytes reported as junk")

    // Control messages and params
    check(controlMessage(0xAA00) == bytes("40 40 00 06 aa 00"), "control message")
    let ps = iapParam(0, [1]) + iapParam(1, Array("x.y".utf8))
    check(parseParams(ps)?.map(\.id) == [0, 1], "params roundtrip")
    check(parseParams([0x00, 0x09, 0x00]) == nil, "malformed params rejected")
    var cp = ControlParser()
    let msg = controlMessage(0x1D02, iapParam(3, [7]))
    check(cp.feed(Array(msg[0..<4])).isEmpty, "partial control message")
    let done = cp.feed(Array(msg[4...]))
    check(done.count == 1 && done[0].id == 0x1D02 && done[0].params.first?.data == [7], "control message completes")
    check(iapText(Array("A30".utf8) + [0]) == "A30", "text with NUL")
    check(iapText([0x01, 0x02]) == nil, "binary is not text")
}
