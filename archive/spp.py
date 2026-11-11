import struct, sys, time, objc
from Foundation import NSObject, NSRunLoop, NSDate
from IOBluetooth import IOBluetoothDevice

ADDR    = sys.argv[1] if len(sys.argv) > 1 else "00-00-00-00-00-00"
CHANNEL = int(sys.argv[2]) if len(sys.argv) > 2 else 26

FEATS = {0x0000:"iRoot", 0x0001:"iFeatureSet", 0x0004:"iProfile",
         0x0100:"iDeviceInfo", 0x0101:"iDeviceName", 0x0104:"iBatterySOC",
         0x0107:"iPowerState", 0x0201:"iEQSet", 0x020D:"iAdvancedParaEQ",
         0x0005:"iMultiHostControl", 0x0109:"iEarcons"}

def crc16_mcrf4xx(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc

def spp_wrap(payload):
    n = len(payload)
    f = bytearray(n + 5)
    f[0] = 0x13
    f[1] = ((n & 0x0F00) >> 8) + 0xA0
    f[2] = n & 0xFF
    f[3:3 + n] = payload
    c = crc16_mcrf4xx(bytes(f[:n + 3]))
    f[n + 3] = c & 0xFF
    f[n + 4] = (c >> 8) & 0xFF
    return bytes(f)

def cpp(idx, fn, sw, args=b""):
    return b"\x00" + bytes([idx & 0xFF, ((fn << 4) & 0xF0) | (sw & 0xF)]) + args

def unwrap(buf):
    out, i = [], 0
    while i + 5 <= len(buf):
        if buf[i] != 0x13 or (buf[i + 1] & 0xF0) != 0xA0:
            i += 1
            continue
        n = ((buf[i + 1] & 0x0F) << 8) | buf[i + 2]
        end = i + 3 + n + 2
        if end > len(buf):
            break
        body = buf[i:i + 3 + n]
        crc_rx = buf[i + 3 + n] | (buf[i + 4 + n] << 8)
        out.append((buf[i + 3:i + 3 + n], crc_rx == crc16_mcrf4xx(body)))
        i = end
    return out, i

class Delegate(NSObject):
    def init(self):
        self = objc.super(Delegate, self).init()
        self.buf = bytearray()
        self.frames = []
        return self

    def rfcommChannelData_data_length_(self, ch, data, length):
        raw = bytes(data[:length]) if not isinstance(data, bytes) else data[:length]
        print("  <- raw", raw.hex(" "))
        self.buf += raw
        frames, used = unwrap(bytes(self.buf))
        if used:
            del self.buf[:used]
        for payload, ok in frames:
            self.frames.append(payload)
            tag = "" if ok else "  [CRC BAD]"
            if len(payload) >= 3:
                print(f"  <- CPP idx={payload[1]:#04x} fn={payload[2] >> 4:#x} "
                      f"sw={payload[2] & 0xF:#x} args={payload[3:].hex(' ') or '-'}{tag}")
            else:
                print(f"  <- short {payload.hex(' ')}{tag}")

    def rfcommChannelClosed_(self, ch):
        print("[!] channel closed")

def pump(seconds):
    NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(seconds))

def main():
    dev = IOBluetoothDevice.deviceWithAddressString_(ADDR)
    if dev is None:
        sys.exit(f"no device for {ADDR}")
    print(f"[*] {dev.name()}  {ADDR}  channel {CHANNEL}")
    delegate = Delegate.alloc().init()
    res = dev.openRFCOMMChannelSync_withChannelID_delegate_(None, CHANNEL, delegate)
    status, chan = (res if isinstance(res, tuple) else (res, None))
    if status != 0 or chan is None:
        sys.exit(f"[!] openRFCOMMChannel failed, status={status}")
    print("[+] RFCOMM open\n")
    sw = 0
    found = {}
    for fid, label in FEATS.items():
        sw = sw % 15 + 1
        frame = spp_wrap(cpp(0, 0, sw, struct.pack(">H", fid)))
        print(f"  -> {frame.hex(' ')}   ({label})")
        chan.writeSync_length_(frame, len(frame))
        delegate.frames.clear()
        pump(1.2)
        if delegate.frames:
            p = delegate.frames[-1]
            idx = p[3] if len(p) > 3 else None
            if idx:
                found[fid] = idx
                print(f"  [OK] 0x{fid:04X} {label} -> index {idx}\n")
            else:
                print(f"  [--] 0x{fid:04X} {label} empty reply\n")
        else:
            print(f"  [--] 0x{fid:04X} {label} no reply\n")
    print("--- summary ---")
    if found:
        for fid, idx in found.items():
            print(f"  0x{fid:04X} {FEATS[fid]:<20} index {idx}")
        print(f"\n  {len(found)} features live.")
    else:
        print("  no replies. channel opened but device ignored every frame.")
    chan.closeChannel()

main()
