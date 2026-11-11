using System.Runtime.InteropServices.WindowsRuntime;
using A30Kit;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;

namespace A30Control;

/// The A30's control channel toward non-Apple hosts: Logitech's BLE GATT service (what the Android
/// app uses). Each write and each notification carries one CPL fragment (CPL byte + CPP), no SPP
/// wrapper. Long replies are announced on the long-response characteristic ([size lo, size hi]) and
/// read from it.
sealed class BleTransport : ITransport
{
    static readonly Guid ServiceId = new("7FD36E38-4680-4A77-BEA3-BEEAEECBF592");
    static readonly Guid WriteId = new("748E2216-8B9A-4598-A0C6-2DEE1AF454DB");
    static readonly Guid LongResponseId = new("8F83DD07-E637-5CEA-A223-F1F3B64B73EE");
    /// 16-bit service UUID 0xFE61 in Logitech's advertisements.
    static readonly Guid AdvertisedId = new("0000FE61-0000-1000-8000-00805F9B34FB");

    public event Action<byte[]>? Received;
    public event Action? Closed;
    public bool IsBle => true;

    readonly BluetoothLEDevice device;
    readonly GattSession session;
    readonly GattDeviceService service;
    readonly GattCharacteristic write;
    readonly GattCharacteristic? longResponse;
    readonly GattWriteOption writeOption;
    readonly Action<string> log;
    volatile bool started, closed;

    BleTransport(BluetoothLEDevice device, GattSession session, GattDeviceService service, GattCharacteristic write,
                 GattCharacteristic? longResponse, Action<string> log)
    {
        this.device = device;
        this.session = session;
        this.service = service;
        this.write = write;
        this.longResponse = longResponse;
        this.log = log;
        writeOption = write.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Write)
            ? GattWriteOption.WriteWithResponse : GattWriteOption.WriteWithoutResponse;
        write.ValueChanged += (_, e) => Deliver(e.CharacteristicValue.ToArray());
        if (longResponse != null) longResponse.ValueChanged += (sender, e) => _ = ReadLongResponse(e.CharacteristicValue.ToArray());
        device.ConnectionStatusChanged += (d, _) =>
        {
            log($"BLE: connection {d.ConnectionStatus}");
            if (d.ConnectionStatus == BluetoothConnectionStatus.Disconnected && started && !closed) Closed?.Invoke();
        };
    }

    /// The LE side of the already-connected classic headset. Dual-mode headsets usually use the same
    /// address for LE; otherwise scan for the Logitech advertisement.
    public static async Task<BleTransport> OpenAsync(ulong classicAddress, Action<string> log)
    {
        var device = await BluetoothLEDevice.FromBluetoothAddressAsync(classicAddress);
        if (device == null)
        {
            log("BLE: no LE device at the classic address; scanning for the Logitech advertisement (0xFE61)");
            if (await ScanAsync(log) is ulong scanned) device = await BluetoothLEDevice.FromBluetoothAddressAsync(scanned);
        }
        if (device == null) throw new A30Exception(A30ErrorKind.OpenFailed, detail: "headset not found over Bluetooth LE");
        log($"BLE: {device.Name} {device.BluetoothAddress:X12} {device.ConnectionStatus}");
        try
        {
            var session = await GattSession.FromDeviceIdAsync(device.BluetoothDeviceId);
            session.MaintainConnection = true;
            var sr = await device.GetGattServicesForUuidAsync(ServiceId, BluetoothCacheMode.Uncached);
            log($"BLE: control service {sr.Status}, {sr.Services.Count} found");
            var service = sr.Services.FirstOrDefault()
                ?? throw new A30Exception(A30ErrorKind.OpenFailed, detail: $"BLE control service not found ({sr.Status})");
            var cr = await service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
            log("BLE: characteristics " + string.Join(", ", cr.Characteristics.Select(c => $"{c.Uuid} [{c.CharacteristicProperties}]")));
            var write = cr.Characteristics.FirstOrDefault(c => c.Uuid == WriteId)
                ?? throw new A30Exception(A30ErrorKind.OpenFailed, detail: "BLE write characteristic not found");
            var longResponse = cr.Characteristics.FirstOrDefault(c => c.Uuid == LongResponseId);
            var t = new BleTransport(device, session, service, write, longResponse, log);
            await t.Subscribe(write);
            if (longResponse != null) await t.Subscribe(longResponse);
            log($"BLE: ready, max PDU {session.MaxPduSize}");
            return t;
        }
        catch
        {
            device.Dispose();
            throw;
        }
    }

    static async Task<ulong?> ScanAsync(Action<string> log)
    {
        var found = new TaskCompletionSource<ulong>(TaskCreationOptions.RunContinuationsAsynchronously);
        var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(AdvertisedId);
        var seen = new HashSet<ulong>();
        watcher.Received += (_, e) =>
        {
            var name = e.Advertisement.LocalName ?? "";
            if (seen.Add(e.BluetoothAddress)) log($"BLE scan: {e.BluetoothAddress:X12} \"{name}\" RSSI {e.RawSignalStrengthInDBm}");
            if (name.Contains("A30", StringComparison.OrdinalIgnoreCase)) found.TrySetResult(e.BluetoothAddress);
        };
        watcher.Start();
        var done = await Task.WhenAny(found.Task, Task.Delay(8000));
        watcher.Stop();
        if (done == found.Task) return found.Task.Result;
        // ponytail: an unnamed Logitech advertiser is used only when it is the only one; match PID 801 in
        // the vendor data if several appear.
        return seen.Count == 1 ? seen.First() : null;
    }

    async Task Subscribe(GattCharacteristic c)
    {
        var status = await c.WriteClientCharacteristicConfigurationDescriptorAsync(
            GattClientCharacteristicConfigurationDescriptorValue.Notify);
        log($"BLE: notifications on {c.Uuid}: {status}");
        if (status != GattCommunicationStatus.Success)
            throw new A30Exception(A30ErrorKind.OpenFailed, detail: $"BLE notifications refused ({status})");
    }

    void Deliver(byte[] data)
    {
        if (!started || closed) return;
        try { Received?.Invoke(data); }
        catch (Exception e) { log("receive handler failed: " + e); }
    }

    async Task ReadLongResponse(byte[] announce)
    {
        if (longResponse == null || announce.Length < 2) return;
        int size = announce[0] | announce[1] << 8;
        var r = await longResponse.ReadValueAsync(BluetoothCacheMode.Uncached);
        if (r.Status != GattCommunicationStatus.Success) { log($"BLE: long response read {r.Status}"); return; }
        var data = r.Value.ToArray();
        Deliver(data.Length > size ? data[..size] : data);
    }

    public void Start() => started = true;

    public async Task SendAsync(byte[] bytes)
    {
        var r = await write.WriteValueWithResultAsync(bytes.AsBuffer(), writeOption);
        if (r.Status != GattCommunicationStatus.Success) log($"BLE: write {r.Status} (protocol error {r.ProtocolError})");
    }

    public void Close()
    {
        closed = true;
        service.Dispose();
        session.Dispose();
        device.Dispose();
    }
}
