from IOBluetooth import IOBluetoothDevice

devs = IOBluetoothDevice.pairedDevices() or []
print(f"paired devices: {len(devs)}\n")

for d in devs:
    try:
        name = d.name() or "(no name)"
        addr = d.addressString()
    except Exception as e:
        print("  !! device read failed:", e); continue
    conn = ""
    try:
        conn = " [CONNECTED]" if d.isConnected() else ""
    except Exception:
        pass
    print(f"=== {name}  {addr}{conn}")

    try:
        services = d.services() or []
    except Exception as e:
        print("   services() failed:", e); continue
    if not services:
        print("   no SDP records cached (try: disconnect+reconnect the device)")
    for s in services:
        try:
            sname = s.getServiceName() or "(unnamed)"
        except Exception:
            sname = "(unnamed)"
        chan = None
        try:
            res = s.getRFCOMMChannelID_(None)
            if isinstance(res, tuple):
                status, cid = res[0], res[1]
                if status == 0:
                    chan = cid
            elif isinstance(res, int):
                chan = res
        except Exception:
            pass
        uuidtxt = ""
        try:
            attrs = s.attributes() or {}
            for k, v in attrs.items():
                if "1101" in str(v).upper():
                    uuidtxt = "  <== SPP (0x1101)"
                    break
        except Exception:
            pass
        line = f"   - {sname}"
        if chan is not None:
            line += f"   RFCOMM channel {chan}"
        print(line + uuidtxt)
    print()
