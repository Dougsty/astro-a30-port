using System.IO;
using A30Kit;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Devices.Enumeration;
using Windows.Networking.Sockets;

namespace A30Control;

/// The A30's control channel: the paired headset's Serial Port service (RFCOMM ch 26, UUID 0x1101).
sealed class RfcommTransport : ITransport
{
    public event Action<byte[]>? Received;
    public event Action? Closed;

    readonly StreamSocket socket;
    readonly Stream input, output;
    readonly Action<string> log;
    readonly CancellationTokenSource cts = new();

    RfcommTransport(StreamSocket s, Action<string> log)
    {
        socket = s;
        this.log = log;
        input = s.InputStream.AsStreamForRead();
        output = s.OutputStream.AsStreamForWrite();
    }

    public static async Task<RfcommTransport> OpenAsync(Action<string> log)
    {
        var infos = await DeviceInformation.FindAllAsync(BluetoothDevice.GetDeviceSelectorFromPairingState(true));
        var info = infos.FirstOrDefault(i => i.Name.Contains("A30", StringComparison.OrdinalIgnoreCase))
                   ?? throw new A30Exception(A30ErrorKind.NotFound);
        using var dev = await BluetoothDevice.FromIdAsync(info.Id) ?? throw new A30Exception(A30ErrorKind.NotFound);
        // Opening RFCOMM on a disconnected headset pages it and brings the link up, overriding a manual
        // disconnect. Only attach to a headset Windows already has connected.
        if (dev.ConnectionStatus != BluetoothConnectionStatus.Connected) throw new A30Exception(A30ErrorKind.NotConnectedToHost);
        var res = await dev.GetRfcommServicesForIdAsync(RfcommServiceId.SerialPort, BluetoothCacheMode.Uncached);
        log($"{info.Name}: {res.Services.Count} serial port service(s), status {res.Error}");
        // ponytail: first Serial Port service; the A30 lists one (ch 26). Pick by SDP channel if a unit lists more.
        var svc = res.Services.FirstOrDefault() ?? throw new A30Exception(A30ErrorKind.OpenFailed, detail: res.Error.ToString());
        var s = new StreamSocket();
        try
        {
            await s.ConnectAsync(svc.ConnectionHostName, svc.ConnectionServiceName,
                                 SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication);
        }
        catch (Exception e)
        {
            s.Dispose();
            throw new A30Exception(A30ErrorKind.OpenFailed, detail: e.Message);
        }
        log($"RFCOMM open: {svc.ConnectionServiceName}");
        return new RfcommTransport(s, log);
    }

    public void Start() => _ = Task.Run(ReadLoop);

    async Task ReadLoop()
    {
        var buf = new byte[1024];
        try
        {
            while (true)
            {
                int n = await input.ReadAsync(buf, cts.Token);
                if (n <= 0) break;
                // A failing handler must not end the read loop (it would look like a disconnect).
                try { Received?.Invoke(buf[..n]); }
                catch (Exception e) { log("receive handler failed: " + e); }
            }
        }
        catch (Exception e)
        {
            if (!cts.IsCancellationRequested) log("read loop ended: " + e.Message);
        }
        if (!cts.IsCancellationRequested) Closed?.Invoke();
    }

    public async Task SendAsync(byte[] bytes)
    {
        await output.WriteAsync(bytes);
        await output.FlushAsync();
    }

    public void Close()
    {
        cts.Cancel();
        socket.Dispose();
    }
}
