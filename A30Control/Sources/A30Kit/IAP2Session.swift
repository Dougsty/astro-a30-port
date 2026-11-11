// Apple-device side of iAP2 toward the A30: detect, link sync, authentication
// (the accessory certificate is accepted without verification: we are not Apple),
// identification, then one External Accessory session that carries CPP traffic.
// Pure state machine: bytes in, events out. HeadsetLink does the RFCOMM I/O.
import Foundation

public enum IAP2Event: Equatable {
    case send([UInt8])      // write these bytes to RFCOMM
    case ready              // EA session started; CPP traffic may flow
    case eaData([UInt8])    // bytes the accessory sent on the EA session (EA session id stripped)
    case reset              // accessory reset the link
    case log(String)
}

public struct IAP2Session {
    public static let protocolName = "com.logitech.ag.carbonite"

    public private(set) var linkUp = false
    public private(set) var eaOpen = false
    /// Top-level string params of IdentificationInformation (0 name, 2 maker, 3 serial, 4 fw…).
    public private(set) var identity: [Int: String] = [:]
    /// Challenge byte source; tests replace it for deterministic output.
    var random: () -> UInt8 = { UInt8.random(in: 0...255) }

    private var splitter = IAP2Splitter()
    private var control = ControlParser()
    private var txSeq: UInt8 = 0x2B
    private var rxSeq: UInt8 = 0
    private var lastRx: UInt8?
    private var ctrlSession: UInt8 = 1
    private var eaSession: UInt8 = 3
    private var eaProtocolID: UInt8?
    private let eaSessionID = 1

    public init() {}

    public mutating func receive(_ bytes: [UInt8]) -> [IAP2Event] {
        var out: [IAP2Event] = []
        for frame in splitter.feed(bytes) {
            switch frame {
            case .detect: if !linkUp { out.append(.send(iap2Detect)) }
            case .junk: break
            case .packet(let p): out += link(p)
            }
        }
        return out
    }

    /// Link packet carrying `data` on the EA session, prefixed with our EA session id.
    public mutating func eaPacket(_ data: [UInt8]) -> [UInt8] {
        txSeq &+= 1
        return LinkPacket(control: LinkPacket.ACK, seq: txSeq, ack: rxSeq, session: eaSession,
                          payload: be16(eaSessionID) + data).encode()
    }

    private mutating func link(_ p: LinkPacket) -> [IAP2Event] {
        if p.control & LinkPacket.RST != 0 {
            resetHandshake()
            return [.reset]
        }
        if p.control & LinkPacket.SYN != 0 {
            // A SYN always starts a fresh link: forget everything from any earlier one.
            resetHandshake()
            // payload: ver maxOut maxLen(2) rtx(2) cumAck(2) maxRtx maxCum, then (id type ver)*
            var i = 10
            while i + 3 <= p.payload.count {
                if p.payload[i + 1] == 0 { ctrlSession = p.payload[i] }
                if p.payload[i + 1] == 2 { eaSession = p.payload[i] }
                i += 3
            }
            rxSeq = p.seq; lastRx = p.seq
            return [.send(LinkPacket(control: LinkPacket.SYN | LinkPacket.ACK, seq: txSeq, ack: rxSeq,
                                     session: 0, payload: p.payload).encode())]
        }
        var out: [IAP2Event] = []
        if !linkUp && p.control & LinkPacket.ACK != 0 && p.ack == txSeq {
            linkUp = true
            out.append(sendControl(0xAA00))   // RequestAuthenticationCertificate
        }
        guard !p.payload.isEmpty else { return out }
        if p.seq == lastRx {                   // retransmission: re-ACK with the current rxSeq only
            out.append(.send(LinkPacket(control: LinkPacket.ACK, seq: txSeq, ack: rxSeq, session: 0).encode()))
            return out
        }
        rxSeq = p.seq; lastRx = p.seq
        out.append(.send(LinkPacket(control: LinkPacket.ACK, seq: txSeq, ack: rxSeq, session: 0).encode()))
        if p.session == ctrlSession {
            for m in control.feed(p.payload) { out += handle(m) }
        } else if p.session == eaSession, p.payload.count >= 2 {
            out.append(.eaData(Array(p.payload.dropFirst(2))))
        } else {
            out.append(.log("data on unknown session \(p.session): \(hex(p.payload))"))
        }
        return out
    }

    /// Forgets all handshake and session state. Keeps txSeq (it keeps counting), random, and the splitter.
    private mutating func resetHandshake() {
        linkUp = false; eaOpen = false; eaProtocolID = nil; identity = [:]
        control = ControlParser(); lastRx = nil
        ctrlSession = 1; eaSession = 3
    }

    private mutating func sendControl(_ id: Int, _ params: [UInt8] = []) -> IAP2Event {
        txSeq &+= 1
        return .send(LinkPacket(control: LinkPacket.ACK, seq: txSeq, ack: rxSeq, session: ctrlSession,
                                payload: controlMessage(id, params)).encode())
    }

    private mutating func handle(_ m: ControlMessage) -> [IAP2Event] {
        switch m.id {
        case 0xAA01:   // AuthenticationCertificate: auth 2.0 certs are ~900 B (20-byte challenge), 3.0 ~600 B
            let certLen = m.params.first?.data.count ?? 0
            let challenge = (0..<(certLen > 800 ? 20 : 32)).map { _ in random() }
            return [sendControl(0xAA02, iapParam(0, challenge))]
        case 0xAA03:   // AuthenticationResponse (not verified)
            return [sendControl(0xAA05), sendControl(0x1D00)]   // AuthenticationSucceeded, StartIdentification
        case 0x1D01:   // IdentificationInformation
            for p in m.params {
                if let s = iapText(p.data) { identity[p.id] = s; continue }
                guard let sub = parseParams(p.data),
                      let idp = sub.first(where: { $0.id == 0 }), idp.data.count == 1,
                      let namep = sub.first(where: { $0.id == 1 }), iapText(namep.data) == Self.protocolName
                else { continue }
                eaProtocolID = idp.data[0]
            }
            guard let proto = eaProtocolID else {
                return [sendControl(0x1D02), .log("accessory does not offer \(Self.protocolName)")]
            }
            eaOpen = true
            return [sendControl(0x1D02),   // IdentificationAccepted
                    sendControl(0xEA00, iapParam(0, [proto]) + iapParam(1, be16(eaSessionID))),
                    .ready]
        default:
            return [.log(String(format: "control message 0x%04X ignored", m.id))]
        }
    }
}
