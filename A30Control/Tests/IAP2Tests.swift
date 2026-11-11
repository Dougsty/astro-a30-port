import Foundation

func testIAP2() {
    var s = IAP2Session()
    s.random = { 0 }
    let A = LinkPacket.ACK

    check(s.receive(iap2Detect) == [.send(iap2Detect)], "detect is echoed")

    check(s.receive(synFixture) == [.send(bytes(
        "ff 5a 00 1a c0 2b 18 00 8a 01 05 00 84 05 dc 01 f4 1e 03 01 00 01 03 02 01 77"))], "SYN+ACK")

    check(s.receive(LinkPacket(control: A, seq: 0x18, ack: 0x2b, session: 0).encode())
          == [.send(bytes("ff 5a 00 10 40 2c 18 01 12 40 40 00 06 aa 00 d0"))], "link up → AA00")
    check(s.linkUp, "linkUp")

    // AuthenticationCertificate (609-byte cert) → ACK + 32-byte challenge
    let cert = LinkPacket(control: A, seq: 0x19, ack: 0x2c, session: 1,
                          payload: controlMessage(0xAA01, iapParam(0, [UInt8](repeating: 0x30, count: 609))))
    let e1 = s.receive(cert.encode())
    check(e1.first == .send(bytes("ff 5a 00 09 40 2c 19 00 19")), "ACK cert")
    let aa02 = LinkPacket(control: A, seq: 0x2d, ack: 0x19, session: 1,
                          payload: controlMessage(0xAA02, iapParam(0, [UInt8](repeating: 0, count: 32)))).encode()
    check(e1.count == 2 && e1[1] == .send(aa02), "AA02 challenge")
    check(Array(aa02[0..<9]) == bytes("ff 5a 00 34 40 2d 19 01 ec"), "AA02 header matches log")

    // AuthenticationResponse → ACK, AA05, 1D00
    let resp = LinkPacket(control: A, seq: 0x1a, ack: 0x2d, session: 1,
                          payload: controlMessage(0xAA03, iapParam(0, [UInt8](repeating: 1, count: 64))))
    check(s.receive(resp.encode()) == [
        .send(bytes("ff 5a 00 09 40 2d 1a 00 17")),
        .send(bytes("ff 5a 00 10 40 2e 1a 01 0e 40 40 00 06 aa 05 cb")),
        .send(bytes("ff 5a 00 10 40 2f 1a 01 0d 40 40 00 06 1d 00 5d")),
    ], "auth succeeded + start identification")

    // IdentificationInformation with the EA protocol group → ACK, 1D02, EA00, ready
    let ident = iapParam(0, Array("A30".utf8) + [0])
        + iapParam(3, Array("A30SERIAL001".utf8) + [0])
        + iapParam(10, iapParam(0, [1]) + iapParam(1, Array(IAP2Session.protocolName.utf8) + [0]) + iapParam(2, [1]))
    let idp = LinkPacket(control: A, seq: 0x1b, ack: 0x2f, session: 1, payload: controlMessage(0x1D01, ident))
    check(s.receive(idp.encode()) == [
        .send(bytes("ff 5a 00 09 40 2f 1b 00 14")),
        .send(bytes("ff 5a 00 10 40 30 1b 01 0b 40 40 00 06 1d 02 5b")),
        .send(bytes("ff 5a 00 1b 40 31 1b 01 ff 40 40 00 11 ea 00 00 05 00 00 01 00 06 00 01 00 01 77")),
        .ready,
    ], "identification accepted + EA session started")
    check(s.eaOpen, "eaOpen")
    check(s.identity[0] == "A30" && s.identity[3] == "A30SERIAL001", "identity strings")

    // First CPP request over EA, exactly as logged
    check(s.eaPacket(sppWrap(cppRequest(index: 0, function: 0, swID: 1, args: [0, 0])))
          == bytes("ff 5a 00 16 40 32 1b 03 01 00 01 13 a0 05 00 00 01 00 00 e1 06 5f"), "EA request packet")

    // EA reply → ACK + eaData (EA session id stripped); retransmission → ACK only
    let reply = LinkPacket(control: A, seq: 0x1c, ack: 0x32, session: 3,
                           payload: [0x00, 0x01] + bytes("13 a0 06 00 00 01 00 00 02 00 00")).encode()
    check(s.receive(reply) == [.send(bytes("ff 5a 00 09 40 32 1c 00 10")),
                               .eaData(bytes("13 a0 06 00 00 01 00 00 02 00 00"))], "EA reply")
    check(s.receive(reply) == [.send(bytes("ff 5a 00 09 40 32 1c 00 10"))], "duplicate only re-ACKed")

    // Accessory reset
    check(s.receive(LinkPacket(control: LinkPacket.RST, seq: 0, ack: 0, session: 0).encode()) == [.reset], "RST")
    check(!s.linkUp && !s.eaOpen, "state cleared on RST")

    // Stale eaProtocolID from before the RST must not make a non-carbonite identification ready
    let noProto = LinkPacket(control: A, seq: 0x1d, ack: 0x33, session: 1,
                             payload: controlMessage(0x1D01, iapParam(0, Array("X".utf8)))).encode()
    let afterRST = s.receive(noProto)
    check(!afterRST.contains(.ready) && !s.eaOpen, "RST clears eaProtocolID: no ready without carbonite")
    check(sentPayloads(afterRST).contains(bytes("40 40 00 06 1d 02")), "1D02 sent after RST re-identification")

    // Identification without our protocol → accepted, but never ready
    var t = IAP2Session()
    _ = t.receive(synFixture)
    _ = t.receive(LinkPacket(control: A, seq: 0x18, ack: 0x2b, session: 0).encode())
    let other = LinkPacket(control: A, seq: 0x19, ack: 0x2c, session: 1,
                           payload: controlMessage(0x1D01, iapParam(0, Array("X".utf8)))).encode()
    let ev = t.receive(other)
    check(!ev.contains(.ready) && !t.eaOpen, "no ready without carbonite protocol")
    check(sentPayloads(ev).contains(bytes("40 40 00 06 1d 02")), "1D02 still sent without carbonite protocol")

    testIAP2Resync()
}

/// Payloads (control messages) of every .send in `ev`; plain ACKs have none and are skipped.
func sentPayloads(_ ev: [IAP2Event]) -> [[UInt8]] {
    ev.compactMap { e in
        guard case .send(let b) = e, b.count > 10 else { return nil }
        return Array(b[9..<(b.count - 1)])
    }
}

/// A mid-session SYN restarts the link: SYN+ACK, a fresh AA00 after link-up, and EA stays
/// closed until a new identification (a stale carbonite protocol id must not carry over).
func testIAP2Resync() {
    let A = LinkPacket.ACK
    var s = IAP2Session()
    s.random = { 0 }
    let carbonite = iapParam(0, Array("A30".utf8) + [0])
        + iapParam(10, iapParam(0, [1]) + iapParam(1, Array(IAP2Session.protocolName.utf8) + [0]) + iapParam(2, [1]))

    // First link up to ready
    _ = s.receive(synFixture)
    _ = s.receive(LinkPacket(control: A, seq: 0x18, ack: 0x2b, session: 0).encode())
    _ = s.receive(LinkPacket(control: A, seq: 0x19, ack: 0x2c, session: 1, payload: controlMessage(0x1D01, carbonite)).encode())
    check(s.eaOpen, "first session reaches eaOpen")

    // Accessory re-syncs mid-session
    let synAgain = s.receive(synFixture)
    guard case .send(let sa)? = synAgain.first, Array(sa[0..<5]) == bytes("ff 5a 00 1a c0") else {
        check(false, "SYN+ACK sent on re-sync"); return
    }
    check(!s.linkUp && !s.eaOpen, "SYN clears link and EA state")

    // Link-up ACK for our new SYN+ACK (ack = its seq) → AA00 again
    let cur = sa[5]
    let linkUp = s.receive(LinkPacket(control: A, seq: 0x18, ack: cur, session: 0).encode())
    check(sentPayloads(linkUp).contains(where: { $0.starts(with: bytes("40 40 00 06 aa 00")) }), "re-sync re-sends AA00")
    check(!s.eaOpen, "eaOpen false until re-identification")

    // Identification without carbonite must not reuse the old protocol id
    let plain = s.receive(LinkPacket(control: A, seq: 0x1a, ack: 0x33, session: 1,
                                     payload: controlMessage(0x1D01, iapParam(0, Array("X".utf8)))).encode())
    check(!plain.contains(.ready), "re-sync clears eaProtocolID")

    // Identification with carbonite → ready again
    let again = s.receive(LinkPacket(control: A, seq: 0x1b, ack: 0x34, session: 1,
                                     payload: controlMessage(0x1D01, carbonite)).encode())
    check(again.contains(.ready) && s.eaOpen, "re-identification reopens EA")
}
