// a30b — ASTRO A30 control client over RFCOMM channel 26.
//
// On a Mac the A30 speaks iAP2 on this channel (it treats the host as an Apple
// device), not raw SPP. So we play the Apple-device role:
//   detect FF55 -> link SYN/SYN+ACK/ACK -> auth (cert accepted blindly)
//   -> identification (learns the EA protocol) -> StartExternalAccessoryProtocolSession
//   -> CPP frames tunneled inside the External Accessory session.
//
// All work runs in IOBluetooth delegate callbacks / timers on the main run loop.
// Build: ./build.sh   Run: ./run.sh [--sdp] [--plain] [addr]
// (Must be launched via `open` so a30b.app is the TCC responsible process.)
import Foundation
import IOBluetooth

let ARGS = CommandLine.arguments
// Address argument (aa-bb-cc-dd-ee-ff), else the first paired device named "…A30…".
let ADDR = ARGS.dropFirst().first { $0.count == 17 && $0.contains("-") }
    ?? ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).first { ($0.name ?? "").contains("A30") }?.addressString ?? ""
let CHAN: BluetoothRFCOMMChannelID = 26
let PLAIN = ARGS.contains("--plain")
// --seq "idx:fn:hexargs,idx:fn,p,...": run raw CPP requests instead of readouts (p = 4s pause)
let SEQ = ARGS.firstIndex(of: "--seq").map { ARGS[$0 + 1] }   // send CPL+CPP inside EA without the 13 A0 SPP wrapper
let IAP2_DETECT: [UInt8] = [0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10]

// Feature names known so far (full table: see CLAUDE.md artifact link).
let NAMES: [UInt16: String] = [
    0x0000: "iRoot", 0x0001: "iFeatureSet", 0x0004: "iProfile", 0x0100: "iDeviceInfo",
    0x0101: "iDeviceName", 0x0104: "iBatterySOC", 0x0108: "iAutoSleep", 0x010A: "iGenericDFU",
    0x0200: "iVolumeSet", 0x0201: "iEQSet", 0x0601: "iheadsetMicMute", 0x0604: "iHeadsetAudioSidetone",
    0x0608: "iHeadsetNoiseGate", 0x0609: "iHeadsetMix", 0x060A: "iHeadsetDongle", 0x060B: "iHeadsetTones",
]
// MARK: - SPP / CPP layer

func crc16(_ d: ArraySlice<UInt8>) -> UInt16 {
    var c: UInt16 = 0xFFFF
    for b in d {
        c ^= UInt16(b)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
    }
    return c
}

func wrap(_ p: [UInt8]) -> [UInt8] {
    let n = p.count
    var f: [UInt8] = [0x13, UInt8(0xA0 | ((n >> 8) & 0x0F)), UInt8(n & 0xFF)] + p
    let c = crc16(f[...])
    f += [UInt8(c & 0xFF), UInt8(c >> 8)]
    return f
}

// CPL header (0x00 = single fragment) + CPP (index, fn<<4|sw, args)
func cppMsg(_ idx: UInt8, _ fn: UInt8, _ sw: UInt8, _ args: [UInt8]) -> [UInt8] {
    [0x00, idx, ((fn << 4) & 0xF0) | (sw & 0x0F)] + args
}

// MARK: - iAP2 layer

func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
func rd16(_ d: ArraySlice<UInt8>, _ i: Int) -> Int { Int(d[d.startIndex + i]) << 8 | Int(d[d.startIndex + i + 1]) }
func cks(_ d: ArraySlice<UInt8>) -> UInt8 { UInt8((0x100 - d.reduce(0) { ($0 + Int($1)) & 0xFF }) & 0xFF) }

// Link packet: FF 5A len(2) ctrl seq ack session hdrCks [payload payloadCks]
let SYN: UInt8 = 0x80, ACK: UInt8 = 0x40, RST: UInt8 = 0x10
func linkPkt(_ ctrl: UInt8, _ seq: UInt8, _ ack: UInt8, _ sess: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
    let len = 9 + (payload.isEmpty ? 0 : payload.count + 1)
    var p: [UInt8] = [0xFF, 0x5A] + be16(len) + [ctrl, seq, ack, sess]
    p.append(cks(p[...]))
    if !payload.isEmpty { p += payload; p.append(cks(payload[...])) }
    return p
}

// Control message: 40 40 len(2) msgId(2) params; param: len(2) id(2) data
func param(_ id: Int, _ data: [UInt8]) -> [UInt8] { be16(4 + data.count) + be16(id) + data }
func ctrlMsg(_ id: Int, _ params: [UInt8] = []) -> [UInt8] { [0x40, 0x40] + be16(6 + params.count) + be16(id) + params }
func params(_ d: ArraySlice<UInt8>) -> [(Int, ArraySlice<UInt8>)]? {
    var out = [(Int, ArraySlice<UInt8>)](), i = d.startIndex
    while i + 4 <= d.endIndex {
        let n = rd16(d, i - d.startIndex)
        guard n >= 4, i + n <= d.endIndex else { return nil }
        out.append((rd16(d, i - d.startIndex + 2), d[(i + 4)..<(i + n)]))
        i += n
    }
    return i == d.endIndex ? out : nil
}

func hex<C: Collection>(_ d: C) -> String where C.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined(separator: " ") }
func text(_ d: ArraySlice<UInt8>) -> String? {
    let s = d.last == 0 ? d.dropLast() : d
    guard !s.isEmpty, s.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
    return String(decoding: s, as: UTF8.self)
}

let T0 = Date()
func log(_ s: String) { print(String(format: "[%7.3f] ", Date().timeIntervalSince(T0)) + s); fflush(stdout) }

// Self-checks: CLAUDE.md worked example, CRC check value, and the A30's own SYN packet.
assert(wrap(cppMsg(0, 0, 1, [0x02, 0x01])) == [0x13, 0xa0, 0x05, 0x00, 0x00, 0x01, 0x02, 0x01, 0xd8, 0x24])
assert(crc16(Array("123456789".utf8)[...]) == 0x6F91)
assert(linkPkt(SYN, 0x18, 0, 0, [0x01, 0x05, 0x00, 0x84, 0x05, 0xdc, 0x01, 0xf4, 0x1e, 0x03, 0x01, 0x00, 0x01, 0x03, 0x02, 0x01])
       == [0xff, 0x5a, 0x00, 0x1a, 0x80, 0x18, 0x00, 0x00, 0xf5, 0x01, 0x05, 0x00, 0x84, 0x05, 0xdc, 0x01, 0xf4, 0x1e, 0x03, 0x01, 0x00, 0x01, 0x03, 0x02, 0x01, 0x77])

final class Client: NSObject, IOBluetoothRFCOMMChannelDelegate {
    let dev: IOBluetoothDevice
    var ch: IOBluetoothRFCOMMChannel?
    var rx = [UInt8]()                 // raw RFCOMM bytes
    var sess = [UInt8: [UInt8]]()      // per-session reassembly
    var ctrlSess: UInt8 = 1, eaSess: UInt8 = 3
    var txSeq: UInt8 = 0x2B, rxSeq: UInt8 = 0
    var lastRx: UInt8? = nil
    var linkUp = false
    var eaProto: UInt8? = nil
    let eaSID = 1
    var eaOpen = false
    var spp = [UInt8]()                // SPP-frame reassembly inside EA
    var sw: UInt8 = 0
    var stepTimer: Timer?

    init(_ d: IOBluetoothDevice) { dev = d }

    func start() {
        log("device \(dev.name ?? "?") connected=\(dev.isConnected()) paired=\(dev.isPaired())")
        if !dev.isConnected() { log("openConnection -> \(String(format: "0x%08x", dev.openConnection()))") }
        var c: IOBluetoothRFCOMMChannel?
        let st = dev.openRFCOMMChannelAsync(&c, withChannelID: CHAN, delegate: self)
        ch = c
        log("openRFCOMMChannelAsync -> \(String(format: "0x%08x", st))")
        if st != kIOReturnSuccess { finish(1) }
    }

    func write(_ bytes: [UInt8], _ what: String) {
        guard let c = ch else { return }
        var b = bytes
        let n = b.count
        let r = b.withUnsafeMutableBytes { c.writeAsync($0.baseAddress, length: UInt16(n), refcon: nil) }
        log("-> \(what): \(hex(bytes))" + (r == kIOReturnSuccess ? "" : String(format: "  r=0x%08x", r)))
    }

    // MARK: RFCOMM delegate
    func rfcommChannelOpenComplete(_ c: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        log("openComplete status=\(String(format: "0x%08x", status)) mtu=\(c.getMTU())")
        if status != kIOReturnSuccess { finish(1) }
    }

    func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length n: Int) {
        rx += UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: n)
        while rx.count >= 2 {
            if rx.starts(with: IAP2_DETECT) {
                rx.removeFirst(6)
                log("<- iAP2 detect")
                if !linkUp { write(IAP2_DETECT, "detect") }
            } else if rx[0] == 0xFF && rx[1] == 0x5A {
                guard rx.count >= 4 else { return }
                let len = rd16(rx[...], 2)
                guard len >= 9 else { rx.removeFirst(2); continue }
                guard rx.count >= len else { return }
                let pkt = Array(rx[0..<len]); rx.removeFirst(len)
                link(pkt)
            } else if rx.count >= 6 || rx[0] != 0xFF {
                log("<- junk \(String(format: "%02x", rx[0]))"); rx.removeFirst()
            } else { return }
        }
    }

    func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) { log("closed"); finish(1) }

    // MARK: iAP2 link
    func link(_ p: [UInt8]) {
        let ctrl = p[4], seq = p[5], ack = p[6], sid = p[7]
        let payload = p.count > 9 ? Array(p[9..<(p.count - 1)]) : []
        let ok = cks(p[0..<8]) == p[8] && (payload.isEmpty || cks(payload[...]) == p[p.count - 1])
        log(String(format: "<- link ctrl=%02x seq=%02x ack=%02x sess=%d len=%d%@", ctrl, seq, ack, sid, payload.count, ok ? "" : " [CKS BAD]"))

        if ctrl & RST != 0 { log("   RST from accessory"); linkUp = false; return }
        if ctrl & SYN != 0 {
            // payload: ver maxOut maxLen(2) rtx(2) cumAck(2) maxRtx maxCum, then (id type ver)*
            var i = 10
            while i + 3 <= payload.count {
                log("   session id=\(payload[i]) type=\(payload[i + 1]) ver=\(payload[i + 2])")
                if payload[i + 1] == 0 { ctrlSess = payload[i] }
                if payload[i + 1] == 2 { eaSess = payload[i] }
                i += 3
            }
            rxSeq = seq; lastRx = seq
            write(linkPkt(SYN | ACK, txSeq, rxSeq, 0, payload), "SYN+ACK")
            return
        }
        if !linkUp && ctrl & ACK != 0 && ack == txSeq {
            linkUp = true
            log("[+] iAP2 link up (ctrl=\(ctrlSess) ea=\(eaSess))")
            sendCtrl(0xAA00, name: "RequestAuthenticationCertificate")
        }
        guard !payload.isEmpty else { return }
        rxSeq = seq
        write(linkPkt(ACK, txSeq, rxSeq, 0), "ACK")
        if seq == lastRx { log("   dup, ignored"); return }
        lastRx = seq
        sess[sid, default: []] += payload
        if sid == ctrlSess { control() } else if sid == eaSess { ea() } else { log("   data on unknown session \(sid): \(hex(payload))") }
    }

    func sendLink(_ sid: UInt8, _ payload: [UInt8], _ what: String) {
        txSeq &+= 1
        write(linkPkt(ACK, txSeq, rxSeq, sid, payload), what)
    }
    func sendCtrl(_ id: Int, _ ps: [UInt8] = [], name: String) {
        sendLink(ctrlSess, ctrlMsg(id, ps), String(format: "ctrl 0x%04X %@", id, name))
    }

    // MARK: iAP2 control session
    func control() {
        while var b = sess[ctrlSess], b.count >= 6 {
            guard b[0] == 0x40 && b[1] == 0x40 else { log("   ctrl desync: \(hex(b))"); sess[ctrlSess] = []; return }
            let n = rd16(b[...], 2)
            guard b.count >= n else { return }
            let id = rd16(b[...], 4)
            let ps = params(b[6..<n]) ?? []
            b.removeFirst(n); sess[ctrlSess] = b
            log(String(format: "<- ctrl 0x%04X (%d params, %d bytes)", id, ps.count, n))
            handleCtrl(id, ps)
        }
    }

    func handleCtrl(_ id: Int, _ ps: [(Int, ArraySlice<UInt8>)]) {
        switch id {
        case 0xAA01:  // AuthenticationCertificate — not verified, we are not Apple.
            let cert = ps.first?.1 ?? []
            log("   cert \(cert.count) bytes")
            var ch = [UInt8](repeating: 0, count: cert.count > 800 ? 20 : 32)
            for i in ch.indices { ch[i] = UInt8.random(in: 0...255) }
            sendCtrl(0xAA02, param(0, ch), name: "RequestAuthenticationChallengeResponse")
        case 0xAA03:  // AuthenticationResponse
            log("   challenge response \(ps.first?.1.count ?? 0) bytes (not checked)")
            sendCtrl(0xAA05, name: "AuthenticationSucceeded")
            sendCtrl(0x1D00, name: "StartIdentification")
        case 0x1D01:  // IdentificationInformation
            for (pid, d) in ps { dump(pid, d, "   ") }
            sendCtrl(0x1D02, name: "IdentificationAccepted")
            if let proto = eaProto {
                sendCtrl(0xEA00, param(0, [proto]) + param(1, be16(eaSID)), name: "StartExternalAccessoryProtocolSession")
                eaOpen = true
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.plan() }
            } else { log("[!] no EA protocol in identification") }
        default:
            for (pid, d) in ps { dump(pid, d, "   ") }
        }
    }

    // Print a param, recursing into nested param groups; remember the EA protocol id.
    func dump(_ pid: Int, _ d: ArraySlice<UInt8>, _ ind: String) {
        if let s = text(d) { log("\(ind)[\(pid)] \"\(s)\""); return }
        if d.count >= 4, let sub = params(d) {
            log("\(ind)[\(pid)] group")
            for (sid, sd) in sub { dump(sid, sd, ind + "   ") }
            // EA protocol group: [0] uint8 id, [1] string name
            if let a = sub.first(where: { $0.0 == 0 }), a.1.count == 1,
               let b = sub.first(where: { $0.0 == 1 }), let name = text(b.1), name.contains(".") {
                if eaProto == nil { eaProto = a.1.first }
                log("\(ind)   => EA protocol id=\(a.1.first!) \"\(name)\"")
            }
            return
        }
        log("\(ind)[\(pid)] \(hex(d))")
    }

    // MARK: External Accessory session (carries CPP)
    func ea() {
        guard let b = sess[eaSess], b.count >= 2 else { return }
        sess[eaSess] = []
        let data = Array(b.dropFirst(2))
        log("<- EA sid=\(rd16(b[...], 0)) \(hex(data))")
        // An SPP frame can span several link packets: keep appending while one is pending.
        if data.first == 0x13 || !spp.isEmpty { spp += data; parseSPP() } else { cpp(data[...], crcOK: true) }
    }

    func parseSPP() {
        var i = 0
        while i + 5 <= spp.count {
            if spp[i] != 0x13 || (spp[i + 1] & 0xF0) != 0xA0 { i += 1; continue }
            let n = (Int(spp[i + 1] & 0x0F) << 8) | Int(spp[i + 2])
            let end = i + 3 + n + 2
            if end > spp.count { break }
            let rxc = UInt16(spp[i + 3 + n]) | (UInt16(spp[i + 4 + n]) << 8)
            // Over EA the A30 sends CRC 00 00 (iAP2 already checksums), so accept that too.
            cpp(spp[(i + 3)..<(i + 3 + n)], crcOK: rxc == 0 || rxc == crc16(spp[i..<(i + 3 + n)]))
            i = end
        }
        if i > 0 { spp.removeFirst(min(i, spp.count)) }
    }

    // MARK: CPP request queue — one request in flight, matched by (index, swId).
    struct Req { let label: String; let idx: UInt8; let fn: UInt8; let args: [UInt8]; let done: ([UInt8]) -> Void }
    var queue = [Req]()
    let PAUSE: UInt8 = 0xFE             // pseudo-index: wait instead of sending
    var cur: Req?
    var frag = [UInt8]()                  // CPL fragment reassembly
    var feats = [(UInt16, UInt8, UInt8)]() // (featureId, type, version), position = index

    func req(_ label: String, _ idx: UInt8, _ fn: UInt8, _ args: [UInt8] = [], _ done: @escaping ([UInt8]) -> Void = { _ in }) {
        queue.append(Req(label: label, idx: idx, fn: fn, args: args, done: done))
    }

    func cpp(_ p: ArraySlice<UInt8>, crcOK: Bool) {
        let p = Array(p)
        guard let cpl = p.first else { return }
        if cpl >> 1 == 0 { frag = [] }  // fragment seq 0 starts a new message
        frag += p.dropFirst()
        if cpl & 1 != 0 { log("   CPL fragment \(cpl >> 1), more follows"); return }
        let m = frag
        frag = []
        guard m.count >= 2 else { log("   short CPP \(hex(p))"); return }
        if m[0] == 0xFF, m.count >= 4 {  // HID++-style error: FF featIdx fn|sw err
            log(String(format: "   CPP ERROR idx=%d fn=%d sw=%d err=%d", m[1], m[2] >> 4, m[2] & 0x0F, m[3]))
            if let r = cur, m[1] == r.idx, m[2] & 0x0F == sw { log("   [ERR] \(r.label)"); sendNext() }
            return
        }
        let idx = m[0], fn = m[1] >> 4, rsw = m[1] & 0x0F
        let args = Array(m.dropFirst(2))
        log(String(format: "   CPP idx=%d fn=%d sw=%d args=%@%@",
                   idx, fn, rsw, args.isEmpty ? "-" : hex(args), crcOK ? "" : "  [CRC BAD]"))
        if let r = cur, idx == r.idx, rsw == sw {
            log("   [OK] \(r.label): \(hex(args))" + (text(args[...]).map { "  \"\($0)\"" } ?? ""))
            r.done(args)
            sendNext()
        }
    }

    func sendNext() {
        stepTimer?.invalidate()
        guard !queue.isEmpty else { cur = nil; summary(); return }
        let r = queue.removeFirst()
        cur = r
        if r.idx == PAUSE {
            log("   \(r.label)")
            stepTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.sendNext() }
            return
        }
        sw = sw % 15 + 1
        let m = cppMsg(r.idx, r.fn, sw, r.args)
        sendLink(eaSess, be16(eaSID) + (PLAIN ? m : wrap(m)), "EA \(r.label)")
        stepTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            log("   [--] \(r.label) no reply"); self?.sendNext()
        }
    }

    func index(of fid: UInt16) -> UInt8? { feats.firstIndex { $0.0 == fid }.map { UInt8($0) } }

    // Read-only probe plan: enumerate features, then read battery / device info / EQ.
    func plan() {
        // On the A30, GET_FEATURE_ID(start) returns the whole list from `start`:
        // count, then 4-byte entries featureId(2) type ver. One call with start=0.
        req("FeatureSet.GET_FEATURE_ID[0]", 1, 1, [0]) { [self] a in
            var i = 1
            while i + 4 <= a.count {
                feats.append((UInt16(a[i]) << 8 | UInt16(a[i + 1]), a[i + 2], a[i + 3])); i += 4
            }
            if feats.count != Int(a.first ?? 0) { log("[!] count \(a.first ?? 0) but parsed \(feats.count)") }
            if let q = SEQ { seq(q) } else { readouts() }
        }
        sendNext()
    }

    // GETs only. Never add iDeviceInfo fn4 (FACTORY_RESET) or iGenericDFU here.
    func readouts() {
        let reads: [(UInt16, [(UInt8, String)])] = [
            (0x0104, [(0, "GET_BATTERY_STATUS")]),
            (0x0100, [(0, "GET_HARDWARE_INFO"), (1, "GET_FIRMWARE_VERSION"), (2, "GET_SERIAL_NUMBER")]),
            (0x0101, [(0, "GET_NAME"), (2, "GET_DEFAULT_NAME"), (3, "GET_NAME_MAX_LENGTH")]),
            (0x0108, [(0, "GET_SLEEP_TIMER")]),
            (0x0200, [(0, "GET_VOLUME_LEVEL"), (3, "GET_INFO")]),
            (0x0601, [(3, "GET_MIC_MUTE_LED_SUPPORT")]),
            (0x0604, [(0, "GET_SIDE_TONE_LEVEL"), (2, "GET_SIDE_TONE_LEVEL_SETTINGS")]),
            (0x0608, [(0, "GET_CONFIG"), (2, "GET_CONNECTION_STATUS")]),
            (0x0609, [(0, "GET_BALANCE"), (2, "GET_INFO")]),
            (0x060A, [(0, "GET_CONFIG")]),
            (0x060B, [(0, "GET_HEADSET_TONE_ENABLED_STATE")]),
            (0x0004, [(0, "GET_INFO"), (1, "GET_ACTIVE_PROFILE")]),
                    ]
        for (fid, fns) in reads {
            guard let i = index(of: fid) else { continue }
            for (fn, name) in fns { req("\(NAMES[fid] ?? "?").\(name)", i, fn) }
        }
        if let i = index(of: 0x0201) {
            // GET_EQ / list / active / data all answer err 2 without an argument; try each EQ mode.
            req("iEQSet.GET_EQ_MODES", i, 2) { [self] a in
                for m in a.dropFirst() {
                    for (fn, name) in [(0, "GET_EQ"), (6, "GET_EQUALIZER_LIST"), (7, "GET_ACTIVE_EQ"), (8, "GET_EQUALIZER_DATA")] as [(UInt8, String)] {
                        req(String(format: "iEQSet.%@[0x%02x]", name, m), i, fn, [m])
                    }
                }
            }
        }
        if let i = index(of: 0x0004) {
            req("iProfile.GET_PROFILE_NAME[0]", i, 7, [0])
        }
    }

    func seq(_ spec: String) {
        for item in spec.split(separator: ",") {
            if item == "p" { req("pause 4s", PAUSE, 0); continue }
            let f = item.split(separator: ":")
            guard f.count >= 2, let idx = UInt8(f[0]), let fn = UInt8(f[1]) else { log("[!] bad seq item \(item)"); continue }
            let h = f.count > 2 ? Array(f[2].filter { $0 != " " }) : []
            let args = stride(from: 0, to: h.count - 1, by: 2).compactMap { UInt8(String(h[$0...$0 + 1]), radix: 16) }
            let name = feats.indices.contains(Int(idx)) ? NAMES[feats[Int(idx)].0] ?? "?" : "?"
            req("\(name)[\(idx)] fn\(fn) \(hex(args))", idx, fn, args)
        }
    }

    func summary() {
        log("--- features ---")
        for (i, f) in feats.enumerated() {
            print(String(format: "  idx %2d  0x%04X  type=0x%02x ver=%d  %@", i, f.0, f.1, f.2, NAMES[f.0] ?? ""))
        }
        finish(feats.isEmpty ? 1 : 0)
    }

    func finish(_ code: Int32) { _ = ch?.close(); exit(code) }
}

guard let dev = IOBluetoothDevice(addressString: ADDR) else { print("no device for \(ADDR)"); exit(1) }

if ARGS.contains("--sdp") {
    // Dump every SDP record: name, RFCOMM channel, raw attributes.
    for case let r as IOBluetoothSDPServiceRecord in dev.services ?? [] {
        var cid: BluetoothRFCOMMChannelID = 0
        let hasChan = r.getRFCOMMChannelID(&cid) == kIOReturnSuccess
        print("=== \(r.getServiceName() ?? "(unnamed)")  rfcomm=\(hasChan ? "\(cid)" : "-")")
        for (k, v) in (r.attributes as? [NSNumber: IOBluetoothSDPDataElement]) ?? [:] {
            print(String(format: "   0x%04x: %@", k.intValue, v.description))
        }
    }
    exit(0)
}

let client = Client(dev)
DispatchQueue.main.async { client.start() }
Timer.scheduledTimer(withTimeInterval: 45 + (SEQ?.split(separator: ",").reduce(0.0) { $0 + ($1 == "p" ? 4.5 : 0.2) } ?? 0), repeats: false) { _ in
    log("[!] watchdog 45s. linkUp=\(client.linkUp) eaProto=\(client.eaProto.map { "\($0)" } ?? "nil")")
    client.finish(2)
}
RunLoop.main.run()
