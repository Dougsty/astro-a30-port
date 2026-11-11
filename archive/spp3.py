import struct, sys, objc
from Foundation import NSObject, NSRunLoop, NSDate
from IOBluetooth import IOBluetoothDevice

ADDR    = sys.argv[1] if len(sys.argv) > 1 else "00-00-00-00-00-00"
CHANNEL = int(sys.argv[2]) if len(sys.argv) > 2 else 26

FEATS = {0x0000:"iRoot", 0x0001:"iFeatureSet", 0x0100:"iDeviceInfo",
         0x0104:"iBatterySOC", 0x0201:"iEQSet", 0x020D:"iAdvancedParaEQ"}

STATE = {"open": None, "buf": bytearray(), "frames": [], "cbs": []}

def ioerr(s):
    if s == 0: return "kIOReturnSuccess"
    u = s & 0xFFFFFFFF
    k = {0x2BC:"kIOReturnError", 0x2C0:"kIOReturnNoDevice",
         0x2C1:"kIOReturnNotPrivileged", 0x2C2:"kIOReturnBadArgument",
         0x2C5:"kIOReturnExclusiveAccess", 0x2C7:"kIOReturnUnsupported",
         0x2CA:"kIOReturnIOError", 0x2CC:"kIOReturnCannotLock",
         0x2CD:"kIOReturnNotOpen", 0x2CF:"kIOReturnNotWritable",
         0x2D4:"kIOReturnTimeout", 0x2D5:"kIOReturnBusy"}
    return f"0x{u:08X} {k.get(u & 0xFFF,'')}".strip()

def crc16(d):
    c = 0xFFFF
    for b in d:
        c ^= b
        for _ in range(8): c = (c >> 1) ^ 0x8408 if c & 1 else c >> 1
    return c

def wrap(p):
    n = len(p); f = bytearray(n+5)
    f[0]=0x13; f[1]=((n & 0x0F00)>>8)+0xA0; f[2]=n & 0xFF; f[3:3+n]=p
    c = crc16(bytes(f[:n+3])); f[n+3]=c & 0xFF; f[n+4]=(c>>8) & 0xFF
    return bytes(f)

def cpp(i, fn, sw, a=b""):
    return b"\x00" + bytes([i & 0xFF, ((fn<<4)&0xF0)|(sw&0xF)]) + a

def unwrap(buf):
    out, i = [], 0
    while i+5 <= len(buf):
        if buf[i]!=0x13 or (buf[i+1]&0xF0)!=0xA0: i+=1; continue
        n=((buf[i+1]&0x0F)<<8)|buf[i+2]; end=i+3+n+2
        if end>len(buf): break
        rx=buf[i+3+n]|(buf[i+4+n]<<8)
        out.append((buf[i+3:i+3+n], rx==crc16(buf[i:i+3+n]))); i=end
    return out, i

class Delegate(NSObject):
    def rfcommChannelOpenComplete_status_(self, ch, status):
        STATE["open"]=status; STATE["cbs"].append("openComplete")
        print(f"[cb] openComplete {ioerr(status)}")
    def rfcommChannelData_data_length_(self, ch, data, length):
        STATE["cbs"].append("data")
        raw = bytes(data[:length]) if not isinstance(data, bytes) else data[:length]
        print("  <- raw", raw.hex(" "))
        STATE["buf"] += raw
        fr, used = unwrap(bytes(STATE["buf"]))
        if used: del STATE["buf"][:used]
        for p, ok in fr:
            STATE["frames"].append(p)
            t = "" if ok else " [CRC BAD]"
            if len(p)>=3:
                print(f"  <- CPP idx={p[1]:#04x} fn={p[2]>>4:#x} sw={p[2]&0xF:#x} args={p[3:].hex(' ') or '-'}{t}")
    def rfcommChannelClosed_(self, ch):
        STATE["cbs"].append("closed"); print("[cb] closed")
    def rfcommChannelControlSignalsChanged_(self, ch): STATE["cbs"].append("ctrl")
    def rfcommChannelFlowControlChanged_(self, ch): STATE["cbs"].append("flow")
    def rfcommChannelWriteComplete_refcon_status_(self, ch, refcon, status):
        STATE["cbs"].append("writeComplete"); print(f"[cb] writeComplete {ioerr(status)}")
    def rfcommChannelQueueSpaceAvailable_(self, ch): STATE["cbs"].append("space")

def pump(sec):
    NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(sec))

dev = IOBluetoothDevice.deviceWithAddressString_(ADDR)
print(f"[*] {dev.name()}  connected={dev.isConnected()}")
d = Delegate.alloc().init()
res = dev.openRFCOMMChannelAsync_withChannelID_delegate_(None, CHANNEL, d)
status, chan = res if isinstance(res, tuple) else (res, None)
print("[*] async open returned:", ioerr(status), " chan:", chan)
if chan is None: sys.exit("no channel object")

try: chan.setDelegate_(d); print("[*] delegate set on channel")
except Exception as e: print("[*] setDelegate failed:", e)

print("[*] waiting for channel to become open ...")
ok = False
for i in range(40):
    try:
        if chan.isOpen():
            ok = True; print(f"[+] isOpen() true after {i*0.25:.2f}s"); break
    except Exception as e:
        print("    isOpen() raised:", e); break
    pump(0.25)
if not ok:
    print("[!] channel never reported open. callbacks seen:", STATE["cbs"] or "NONE")
    print("    -> if NONE, PyObjC never delivered delegate callbacks.")
    sys.exit(1)

sw, found = 0, {}
for fid, label in FEATS.items():
    sw = sw % 15 + 1
    f = wrap(cpp(0, 0, sw, struct.pack(">H", fid)))
    print(f"  -> {f.hex(' ')}   ({label})")
    STATE["frames"].clear()
    r = chan.writeSync_length_(f, len(f))
    if r != 0: print("     write ->", ioerr(r))
    pump(1.2)
    if STATE["frames"]:
        p = STATE["frames"][-1]
        if len(p) > 3:
            found[fid] = p[3]; print(f"  [OK] 0x{fid:04X} {label} -> index {p[3]}\n")
        else: print(f"  [--] 0x{fid:04X} short reply\n")
    else: print(f"  [--] 0x{fid:04X} {label} no reply\n")

print("--- summary ---")
for fid, idx in found.items(): print(f"  0x{fid:04X} {FEATS[fid]:<18} index {idx}")
print("callbacks seen:", sorted(set(STATE["cbs"])) or "NONE")
try: chan.closeChannel()
except Exception: pass
