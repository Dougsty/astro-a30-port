import Foundation
import IOBluetooth

let ADDR = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "00-00-00-00-00-00"
let CHAN: BluetoothRFCOMMChannelID = 26

let FEATS: [(UInt16, String)] = [
    (0x0000, "iRoot"), (0x0001, "iFeatureSet"), (0x0100, "iDeviceInfo"),
    (0x0104, "iBatterySOC"), (0x0201, "iEQSet"), (0x020D, "iAdvancedParaEQ"),
]

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
    var f = [UInt8](repeating: 0, count: n + 5)
    f[0] = 0x13
    f[1] = UInt8(((n & 0x0F00) >> 8) + 0xA0)
    f[2] = UInt8(n & 0xFF)
    for i in 0..<n { f[3 + i] = p[i] }
    let c = crc16(f[0..<(n + 3)])
    f[n + 3] = UInt8(c & 0xFF)
    f[n + 4] = UInt8((c >> 8) & 0xFF)
    return f
}

func cppMsg(_ idx: UInt8, _ fn: UInt8, _ sw: UInt8, _ args: [UInt8]) -> [UInt8] {
    return [0x00, idx, ((fn << 4) & 0xF0) | (sw & 0x0F)] + args
}

func hex(_ d: [UInt8]) -> String {
    d.map { String(format: "%02x", $0) }.joined(separator: " ")
}

final class Chan: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var opened = false
    var openStatus: IOReturn = 0
    var buf = [UInt8]()
    var frames = [[UInt8]]()

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        openStatus = status
        opened = (status == kIOReturnSuccess)
        print("[cb] openComplete status=\(status) \(opened ? "OK" : "FAIL")")
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!,
                           data p: UnsafeMutableRawPointer!, length n: Int) {
        let raw = Array(UnsafeBufferPointer(
            start: p.assumingMemoryBound(to: UInt8.self), count: n))
        print("  <- raw \(hex(raw))")
        buf += raw
        parse()
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) { print("[cb] closed") }

    func parse() {
        var i = 0
        while i + 5 <= buf.count {
            if buf[i] != 0x13 || (buf[i + 1] & 0xF0) != 0xA0 { i += 1; continue }
            let n = (Int(buf[i + 1] & 0x0F) << 8) | Int(buf[i + 2])
            let end = i + 3 + n + 2
            if end > buf.count { break }
            let payload = Array(buf[(i + 3)..<(i + 3 + n)])
            let rx = UInt16(buf[i + 3 + n]) | (UInt16(buf[i + 4 + n]) << 8)
            let ok = rx == crc16(buf[i..<(i + 3 + n)])
            frames.append(payload)
            if payload.count >= 3 {
                let fn = payload[2] >> 4, sw = payload[2] & 0x0F
                let args = Array(payload.dropFirst(3))
                print(String(format: "  <- CPP idx=0x%02x fn=0x%x sw=0x%x args=%@%@",
                             payload[1], fn, sw,
                             args.isEmpty ? "-" : hex(args), ok ? "" : "  [CRC BAD]"))
            }
            i = end
        }
        if i > 0 { buf.removeFirst(min(i, buf.count)) }
    }
}

func pump(_ sec: Double) {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(sec))
}

guard let dev = IOBluetoothDevice(addressString: ADDR) else {
    print("no device for \(ADDR)"); exit(1)
}
print("[*] \(dev.name ?? "?")  connected=\(dev.isConnected())")

let del = Chan()
var channel: IOBluetoothRFCOMMChannel?
let st = dev.openRFCOMMChannelAsync(&channel, withChannelID: CHAN, delegate: del)
print("[*] openRFCOMMChannelAsync -> \(st)")
guard st == kIOReturnSuccess, let ch = channel else {
    print("open failed"); exit(1)
}

print("[*] waiting for openComplete ...")
let deadline = Date().addingTimeInterval(10)
while !del.opened && Date() < deadline { pump(0.2) }
if !del.opened {
    print("[!] never opened (status=\(del.openStatus)). isOpen=\(ch.isOpen())")
    exit(1)
}
print("[+] channel open\n")

var sw: UInt8 = 0
var found = [(UInt16, String, UInt8)]()
for (fid, label) in FEATS {
    sw = sw % 15 + 1
    var f = wrap(cppMsg(0, 0, sw, [UInt8(fid >> 8), UInt8(fid & 0xFF)]))
    print("  -> \(hex(f))   (\(label))")
    del.frames.removeAll()
    let flen = f.count
    let r = f.withUnsafeMutableBytes { p -> IOReturn in
        ch.writeSync(p.baseAddress, length: UInt16(flen))
    }
    if r != kIOReturnSuccess { print("     write -> \(r)") }
    pump(1.2)
    if let p = del.frames.last, p.count > 3 {
        found.append((fid, label, p[3]))
        print(String(format: "  [OK] 0x%04X %@ -> index %d\n", fid, label, p[3]))
    } else {
        print(String(format: "  [--] 0x%04X %@ no reply\n", fid, label))
    }
}

print("--- summary ---")
for (fid, label, idx) in found {
    print(String(format: "  0x%04X %-18@ index %d", fid, label, idx))
}
if found.isEmpty { print("  channel open, no frames back") }
_ = ch.close()
