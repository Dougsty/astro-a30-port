// Byte-level framing for the A30 control channel. Pure functions, no IOBluetooth,
// so Tests/ can exercise them without a headset. Layers (outside in):
// RFCOMM bytes → iAP2 link packets → EA session data → SPP frames → CPL → CPP.
import Foundation

public func hex<C: Collection>(_ d: C) -> String where C.Element == UInt8 {
    d.map { String(format: "%02x", $0) }.joined(separator: " ")
}

public func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

func rd16<C: Collection>(_ d: C, _ offset: Int) -> Int where C.Element == UInt8, C.Index == Int {
    Int(d[d.startIndex + offset]) << 8 | Int(d[d.startIndex + offset + 1])
}

// MARK: - SPP frame: 13 | A0+lenHi | lenLo | payload | crcLo crcHi

/// CRC-16/MCRF4XX (poly 0x8408 reflected, init 0xFFFF). Check value 0x6F91 for "123456789".
public func crc16<C: Collection>(_ d: C) -> UInt16 where C.Element == UInt8 {
    var c: UInt16 = 0xFFFF
    for b in d {
        c ^= UInt16(b)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
    }
    return c
}

public func sppWrap(_ payload: [UInt8]) -> [UInt8] {
    let n = payload.count
    var f: [UInt8] = [0x13, UInt8(0xA0 | ((n >> 8) & 0x0F)), UInt8(n & 0xFF)] + payload
    let c = crc16(f)
    f += [UInt8(c & 0xFF), UInt8(c >> 8)]
    return f
}

/// Reassembles SPP frames from a byte stream. Over the iAP2 EA session the A30
/// sends CRC 00 00, so that is accepted as well as a correct CRC.
public struct SPPParser {
    private var buf: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        buf += bytes
        var out: [[UInt8]] = []
        var i = 0
        while i + 5 <= buf.count {
            guard buf[i] == 0x13, buf[i + 1] & 0xF0 == 0xA0 else { i += 1; continue }
            let n = Int(buf[i + 1] & 0x0F) << 8 | Int(buf[i + 2])
            let end = i + 3 + n + 2
            if end > buf.count { break }
            let rx = UInt16(buf[end - 2]) | UInt16(buf[end - 1]) << 8
            if rx == 0 || rx == crc16(buf[i..<(i + 3 + n)]) { out.append(Array(buf[(i + 3)..<(i + 3 + n)])) }
            i = end
        }
        buf.removeFirst(i)
        return out
    }
}

// MARK: - CPL header + CPP message

/// CPL byte 0x00 (single fragment) + feature index + (fn << 4 | swId) + args.
public func cppRequest(index: UInt8, function: UInt8, swID: UInt8, args: [UInt8]) -> [UInt8] {
    [0x00, index, (function << 4) | (swID & 0x0F)] + args
}

/// Joins CPL fragments (CPL bit0 = more follow, bits1-7 = fragment seq).
/// Returns the CPP message (CPL byte stripped) once the last fragment arrives.
public struct CPLReassembler {
    private var frag: [UInt8] = []
    private var nextSeq: UInt8 = 0
    private var inProgress = false
    public init() {}

    /// Fragments must arrive in order 0, 1, 2 ... Any gap or stray continuation drops the
    /// partial message. A fragment 0 always starts fresh.
    public mutating func feed(_ payload: [UInt8]) -> [UInt8]? {
        guard let cpl = payload.first else { return nil }
        let seq = cpl >> 1
        if seq == 0 {
            frag = []                           // fragment 0 starts a new message
        } else if !inProgress || seq != nextSeq {
            frag = []; inProgress = false       // gap: abort the partial, discard this fragment
            return nil
        }
        frag += payload.dropFirst()
        if frag.count > 4096 { frag = []; inProgress = false; return nil }   // runaway guard
        if cpl & 1 != 0 { inProgress = true; nextSeq = (seq &+ 1) & 0x7F; return nil }
        let msg = frag
        frag = []; inProgress = false
        return msg
    }
}

public enum CPPReply: Equatable {
    case ok(index: UInt8, function: UInt8, swID: UInt8, args: [UInt8])
    case error(index: UInt8, function: UInt8, swID: UInt8, code: UInt8)

    /// `m` is a CPP message without the CPL byte. Errors look like FF featIdx fn|sw code.
    public init?(_ m: [UInt8]) {
        if m.count >= 4, m[0] == 0xFF {
            self = .error(index: m[1], function: m[2] >> 4, swID: m[2] & 0x0F, code: m[3])
            return
        }
        guard m.count >= 2 else { return nil }
        self = .ok(index: m[0], function: m[1] >> 4, swID: m[1] & 0x0F, args: Array(m.dropFirst(2)))
    }
}

// MARK: - iAP2 link layer

public let iap2Detect: [UInt8] = [0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10]

/// iAP2 checksum: two's complement of the byte sum.
public func iapChecksum<C: Collection>(_ d: C) -> UInt8 where C.Element == UInt8 {
    0 &- d.reduce(0, &+)
}

/// FF 5A len(2) control seq ack session hdrCks [payload payloadCks]
public struct LinkPacket: Equatable {
    public static let SYN: UInt8 = 0x80
    public static let ACK: UInt8 = 0x40
    public static let RST: UInt8 = 0x10

    public var control: UInt8
    public var seq: UInt8
    public var ack: UInt8
    public var session: UInt8
    public var payload: [UInt8]

    public init(control: UInt8, seq: UInt8, ack: UInt8, session: UInt8, payload: [UInt8] = []) {
        self.control = control; self.seq = seq; self.ack = ack; self.session = session; self.payload = payload
    }

    public func encode() -> [UInt8] {
        let len = 9 + (payload.isEmpty ? 0 : payload.count + 1)
        var p: [UInt8] = [0xFF, 0x5A] + be16(len) + [control, seq, ack, session]
        p.append(iapChecksum(p))
        if !payload.isEmpty { p += payload; p.append(iapChecksum(payload)) }
        return p
    }
}

public enum IAP2Frame: Equatable {
    case detect
    case packet(LinkPacket)
    case junk(UInt8)
}

/// Splits the RFCOMM byte stream into iAP2 detect sequences and checksum-valid link packets.
public struct IAP2Splitter {
    private var buf: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [IAP2Frame] {
        buf += bytes
        var out: [IAP2Frame] = []
        while buf.count >= 2 {
            if buf.starts(with: iap2Detect) { buf.removeFirst(6); out.append(.detect); continue }
            if buf[0] == 0xFF && buf[1] == 0x5A {
                guard buf.count >= 9 else { break }
                // Check the header checksum before trusting len: a false FF 5A or a corrupt
                // length must not make us wait for up to 64 KiB and swallow valid packets.
                guard iapChecksum(buf[0..<8]) == buf[8] else { out.append(.junk(buf.removeFirst())); continue }
                let len = rd16(buf, 2)
                guard len >= 9 else { out.append(.junk(buf.removeFirst())); continue }
                guard buf.count >= len else { break }
                let p = Array(buf[0..<len])
                buf.removeFirst(len)
                let payload = len > 10 ? Array(p[9..<(len - 1)]) : []
                let ok = iapChecksum(p[0..<8]) == p[8] && (payload.isEmpty || iapChecksum(payload) == p[len - 1])
                if ok { out.append(.packet(LinkPacket(control: p[4], seq: p[5], ack: p[6], session: p[7], payload: payload))) }
                continue
            }
            if buf.count < 6 && iap2Detect.starts(with: buf) { break }   // partial detect
            out.append(.junk(buf.removeFirst()))
        }
        return out
    }
}

// MARK: - iAP2 control session messages: 40 40 len(2) msgId(2) params; param = len(2) id(2) data

public func iapParam(_ id: Int, _ data: [UInt8]) -> [UInt8] { be16(4 + data.count) + be16(id) + data }

public func controlMessage(_ id: Int, _ params: [UInt8] = []) -> [UInt8] {
    [0x40, 0x40] + be16(6 + params.count) + be16(id) + params
}

public struct IAPParam {
    public let id: Int
    public let data: [UInt8]
}

/// Parses a run of params; nil unless the bytes are exactly a well-formed run.
public func parseParams(_ d: [UInt8]) -> [IAPParam]? {
    var out: [IAPParam] = []
    var i = 0
    while i + 4 <= d.count {
        let n = rd16(d, i)
        guard n >= 4, i + n <= d.count else { return nil }
        out.append(IAPParam(id: rd16(d, i + 2), data: Array(d[(i + 4)..<(i + n)])))
        i += n
    }
    return i == d.count ? out : nil
}

public struct ControlMessage {
    public let id: Int
    public let params: [IAPParam]
}

/// Reassembles control messages that may span several link packets.
public struct ControlParser {
    private var buf: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [ControlMessage] {
        buf += bytes
        var out: [ControlMessage] = []
        while buf.count >= 6 {
            guard buf[0] == 0x40, buf[1] == 0x40 else { buf = []; break }   // desync: drop buffer
            let n = rd16(buf, 2)
            guard n >= 6 else { buf = []; break }
            guard buf.count >= n else { break }
            out.append(ControlMessage(id: rd16(buf, 4), params: parseParams(Array(buf[6..<n])) ?? []))
            buf.removeFirst(n)
        }
        return out
    }
}

/// Printable ASCII (one trailing NUL allowed), else nil.
public func iapText(_ d: [UInt8]) -> String? {
    let s = d.last == 0 ? Array(d.dropLast()) : d
    guard !s.isEmpty, s.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
    return String(decoding: s, as: UTF8.self)
}
