import asyncio, struct, sys
from bleak import BleakClient, BleakScanner

PRIMARY = "7fd36e38-4680-4a77-bea3-beeaeecbf592"
POWER   = "1b7e8251-2877-41c3-b46e-cf057c562023"
WRITE   = "748e2216-8b9a-4598-a0c6-2dee1af454db"
LONG    = "8f83dd07-e637-5cea-a223-f1f3b64b73ee"
AUTHCH  = ["5e9bf2a8-f93f-4481-a67e-3b2f4a07891a",
           "0b848765-751d-4972-903f-651d8b2e80ad"]
AUID    = bytes([2]*6)
FEATS   = {0x0000:"iRoot",0x0001:"iFeatureSet",0x0004:"iProfile",
           0x0100:"iDeviceInfo",0x0101:"iDeviceName",0x0104:"iBatterySOC",
           0x0107:"iPowerState",0x0201:"iEQSet",0x020D:"iAdvancedParaEQ"}

inbox = asyncio.Queue()

def frame(idx, fn, sw, pl=b""):
    return b"\x00" + bytes([idx & 0xFF, ((fn << 4) & 0xF0) | (sw & 0xF)]) + pl

async def notify(_s, d):
    d = bytes(d)
    print("  <-", d.hex(" "))
    if len(d) >= 3:
        await inbox.put(d)

async def main():
    print("[*] scanning 10s ...")
    devs = await BleakScanner.discover(timeout=10, return_adv=True)
    cands = []
    for dev, adv in devs.values():
        u = [x.lower() for x in (adv.service_uuids or [])]
        name = (dev.name or "").strip()
        hit = PRIMARY in u or POWER in u
        if hit or any(k in name.upper() for k in ("A30", "ASTRO", "LOGI")):
            print(f"  [{'CPP' if hit else 'name'}] {name or '(no name)'} {dev.address} rssi={adv.rssi}")
            cands.append((dev, adv.rssi, hit))
    if not cands:
        print("  nothing found. headset ON and disconnected from the phone app?")
        return
    cands.sort(key=lambda c: (not c[2], -c[1]))
    target = cands[0][0]
    print(f"\n[*] connecting {target.name or target.address}")

    async with BleakClient(target.address) as c:
        print("[+] connected, mtu =", getattr(c, "mtu_size", "?"))
        print("\n--- services ---")
        for s in c.services:
            mark = "  <== CPP" if s.uuid.lower() in (PRIMARY, POWER) else ""
            print(" ", s.uuid, mark)
            for ch in s.characteristics:
                print("    ", ch.uuid, ",".join(ch.properties))

        for ch in (WRITE, LONG):
            try:
                await c.start_notify(ch, notify); print("[+] subscribed", ch)
            except Exception as e:
                print("[!] notify", ch, "->", e)

        print("\n--- authorize ---")
        for ch in AUTHCH:
            try:
                await c.write_gatt_char(ch, AUID + b"\x42", response=True)
                print("[+] auth ok via", ch); break
            except Exception as e:
                print("[!] auth", ch, "->", e)
        await asyncio.sleep(0.5)

        print("\n--- enumerate ---")
        sw = 0
        for fid, label in FEATS.items():
            sw = sw % 15 + 1
            f = frame(0, 0, sw, struct.pack(">H", fid))
            print(f"  -> {f.hex(' ')}  ({label})")
            try:
                await c.write_gatt_char(WRITE, f, response=True)
                r = await asyncio.wait_for(inbox.get(), 2.0)
                print(f"  [OK] 0x{fid:04X} {label} -> index {r[3] if len(r) > 3 else '?'}")
            except asyncio.TimeoutError:
                print(f"  [--] 0x{fid:04X} {label} no reply")
            except Exception as e:
                print(f"  [!!] 0x{fid:04X} {label} {e}")

asyncio.run(main())
