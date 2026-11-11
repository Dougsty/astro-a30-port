using A30Kit;
using Windows.Devices.Bluetooth;
using Windows.Devices.Enumeration;

namespace A30Control;

/// Finds the paired A30 and opens its control channel: BLE GATT first (how the Android app reaches
/// the A30; toward a non-Apple host the RFCOMM channel stays silent), then RFCOMM (iAP2/raw SPP).
static class Connector
{
    public static async Task<ITransport> OpenAsync(Action<string> log)
    {
        var infos = await DeviceInformation.FindAllAsync(BluetoothDevice.GetDeviceSelectorFromPairingState(true));
        var info = infos.FirstOrDefault(i => i.Name.Contains("A30", StringComparison.OrdinalIgnoreCase))
                   ?? throw new A30Exception(A30ErrorKind.NotFound);
        using var dev = await BluetoothDevice.FromIdAsync(info.Id) ?? throw new A30Exception(A30ErrorKind.NotFound);
        // Opening a control channel on a disconnected headset pages it and brings the link up, overriding
        // a manual disconnect. Only attach to a headset Windows already has connected.
        if (dev.ConnectionStatus != BluetoothConnectionStatus.Connected) throw new A30Exception(A30ErrorKind.NotConnectedToHost);
        try
        {
            return await BleTransport.OpenAsync(dev.BluetoothAddress, log);
        }
        catch (Exception e)
        {
            log("BLE route failed: " + e.Message + "; trying RFCOMM");
        }
        return await RfcommTransport.OpenAsync(dev, log);
    }
}
