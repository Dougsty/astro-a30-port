import struct, sys, objc
from Foundation import NSObject, NSRunLoop, NSDate
from IOBluetooth import IOBluetoothDevice

ADDR    = sys.argv[1] if len(sys.argv) > 1 else "00-00-00-00-00-00"
CHANNEL = int(sys.argv[2]) if len(sys.argv) > 2 else 26

FEATS = {0x0000:"iRoot", 0x0001:"iFeatureSet", 0x0004:"iProfile",
         0x0100:"iDeviceInfo", 0x0101:"iDeviceName", 0x0104:"iBatterySOC",
         0x0107:"iPowerState", 0x0201:"iEQSet", 0x020D:"iAdvancedParaEQ"}

STATE = {"open": None, "buf": bytearray(), "frames": []}

def ioerr(s):
    if s == 0: return "kIOReturnSuccess"
    u = s & 0xFFFFFFFF
    known = {0x2BC:"kIOReturnError (generic)", 0x2C0:"kIOReturnNoDevice",
             0x2C1:"kIOReturnNotPrivileged (permission)", 0x2C2:"kIOReturnBadArgument",
             0x2C5:"kIOReturnExclusiveAccess (channel in use)",
             0x2CE:"kIOReturnNotOpen", 0x2D5:"kIOReturnBusy",
             0x2D4:"kIOReturnTimeout", 0x2E8:"kIOReturnNotAttached"}
    return f"0x{u:08X} {known.get(u & 0xFFF, '')}".strip()

def crc16_mcrf4xx(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc

def spp_wrap(p):
    n = len(p); f = bytearray(n + 5)
    f[0] = 0x13; f[1] = ((n & 0x0F00) >> 8) + 0xA0; f[2] = n & 0xFF
    f[3:3+n] = p
    c = crc16_mcrf4xx(bytes(f[:n+3])); f[n+3] = c & 0xFF; f[n+4] = (c >> 8) & 0xFF
    return bytes(f)

def cpp(idx, fn, sw, args=b""):
    return b"\x00" + bytes([idx & 0xFF, ((fn << 4) & 0xF0) | (sw & 0xF)]) + args

def unwrap(buf):
    out, i = [], 0
    while i + 5 <= len(buf):
        if buf[i] != 0x13 or (buf[i+1] & 0xF0) != 0xA0:
            i += 1; continue
        n = ((buf[i+1] & 0x0F) << 8) | buf[i+2]
        end = i + 3 + n + 2
        if end > len(buf): break
        body = buf[i:i+3+n]
        rx = buf[i+3+n] | (buf[i+4+n] << 8)
        out.append((buf[i+3:i+3+n], rx == crc16_mcrf4xx(body)))
        i = end
    return out, i

class Delegate(NSObject):
    def rfcommChannelOpenComplete_status_(self, ch, status):
        STATE["open"] = status
        print(f"[cb] openComplete status={ioerr(status)}")

    def rfcommChannelData_data_length_(self, ch, data, length):
        raw = bytes(data[:length]) if not isinstance(data, bytes) else data[:length]
        print("  <- raw", raw.hex(" "))
        STATE["buf"] += raw
        frames, used = unwrap(bytes(STATE["buf"]))
        if used: del STATE["buf"][:used]
        for payload, ok in frames:
            STATE["frames"].append(payload)
            tag = "" if ok else "  [CRC BAD]"
            if len(payload) >= 3:
                print(f"  <- CPP idx={payload[1]:#04x} fn={payload[2]>>4:#x} "
                      f"sw={payload[2]&0xF:#x} args={payload[3:].hex(' ') or '-'}{tag}")
            else:
                print(f"  <- short {payload.hex(' ')}{tag}")

    def rfcommChannelClosed_(self, ch):
        print("[cb] channel closed")

def pump(sec):
    NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(sec))

def main():
    dev = IOBluetoothDevice.deviceWithAddressString_(ADDR)
    if dev is None: sys.exit(f"no device for {ADDR}")
    print(f"[*] {dev.name()}  {ADDR}")
    print(f"[*] connected={dev.isConnected()}  paired={dev.isPaired()}")
    if not dev.isConnected():
        print("[*] opening baseband connection ..."); print("    ->", ioerr(dev.openConnection()))
    delegate = Delegate.alloc().init()
    print(f"[*] async open RFCOMM channel {CHANNEL} ...")
    res = dev.openRFCOMMChannelAsync_withChannelID_delegate_(None, CHANNEL, delegate)
    status, chan = res if isinstance(res, tuple) else (res, None)
    print("    call returned:", ioerr(status))
    if status != 0:
        print("\nchannel did not open. likely causes, in order:")
        print("  1. Terminal lacks Bluetooth permission")
        print("     -> System Settings > Privacy & Security > Bluetooth")
        print("  2. another process owns channel 26 (Logitech G HUB / LogiTune)")
        print("  3. ACL link dropped; play audio to the headset and retry")
        return
    for _ in range(20):
        if STATE["open"] is not None: break
        pump(0.25)
    if STATE["open"] not in (0, None):
        print("[!] open completed with error:", ioerr(STATE["open"])); return
    print("[+] RFCOMM open\n")
    sw, found = 0, {}
    for fid, label in FEATS.items():
        sw = sw % 15 + 1
        frame = spp_wrap(cpp(0, 0, sw, struct.pack(">H", fid)))
        print(f"  -> {frame.hex(' ')}   ({label})")
        STATE["frames"].clear()
        r = chan.writeSync_length_(frame, len(frame))
        if r != 0: print("     write ->", ioerr(r))
        pump(1.2)
        if STATE["frames"]:
            p = STATE["frames"][-1]
            idx = p[3] if len(p) > 3 else None
            if idx:
                found[fid] = idx; print(f"  [OK] 0x{fid:04X} {label} -> index {idx}\n")
            else:
                print(f"  [--] 0x{fid:04X} {label} empty reply\n")
        else:
            print(f"  [--] 0x{fid:04X} {label} no reply\n")
    print("--- summary ---")
    for fid, idx in found.items():
        print(f"  0x{fid:04X} {FEATS[fid]:<20} index {idx}")
    if not found: print("  channel open but no frames came back.")
    try: chan.closeChannel()
    except Exception: pass

main()
