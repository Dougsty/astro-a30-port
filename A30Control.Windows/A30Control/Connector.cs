using A30Kit;
using Windows.Devices.Bluetooth;
using Windows.Devices.Enumeration;

namespace A30Control;

/// Opens the A30's control channel: the 2.4 GHz dongle when it is plugged in (the route that works on
/// Windows), else Bluetooth RFCOMM (works toward a Mac; on Windows the headset stays silent there).
/// BLE was tried in 1.0.2: the A30 sends no advertisements while connected, so it is gone.
static class Connector
{
    public static async Task<ITransport> OpenAsync(Action<string> log)
    {
        if (await DongleTransport.OpenAsync(log) is DongleTransport d) return d;
        var infos = await DeviceInformation.FindAllAsync(BluetoothDevice.GetDeviceSelectorFromPairingState(true));
        var info = infos.FirstOrDefault(i => i.Name.Contains("A30", StringComparison.OrdinalIgnoreCase))
                   ?? throw new A30Exception(A30ErrorKind.NotFound);
        using var dev = await BluetoothDevice.FromIdAsync(info.Id) ?? throw new A30Exception(A30ErrorKind.NotFound);
        // Opening a control channel on a disconnected headset pages it and brings the link up, overriding
        // a manual disconnect. Only attach to a headset Windows already has connected.
        if (dev.ConnectionStatus != BluetoothConnectionStatus.Connected) throw new A30Exception(A30ErrorKind.NotConnectedToHost);
        return await RfcommTransport.OpenAsync(dev, log);
    }
}
