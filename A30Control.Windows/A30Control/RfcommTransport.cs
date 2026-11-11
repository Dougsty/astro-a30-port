using A30Kit;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Networking.Sockets;
using Windows.Storage.Streams;

namespace A30Control;

/// The A30's control channel: the paired headset's Serial Port service (RFCOMM ch 26, UUID 0x1101).
sealed class RfcommTransport : ITransport
{
    public event Action<byte[]>? Received;
    public event Action? Closed;

    readonly StreamSocket socket;
    // DataReader in Partial mode returns as soon as any bytes arrive (the headset sends 6-byte frames);
    // DataWriter.StoreAsync pushes each write to the socket immediately.
    readonly DataReader reader;
    readonly DataWriter writer;
    readonly Action<string> log;
    readonly CancellationTokenSource cts = new();

    RfcommTransport(StreamSocket s, Action<string> log)
    {
        socket = s;
        this.log = log;
        reader = new DataReader(s.InputStream) { InputStreamOptions = InputStreamOptions.Partial };
        writer = new DataWriter(s.OutputStream);
    }

    /// `dev` is the paired, connected classic headset (see Connector).
    public static async Task<RfcommTransport> OpenAsync(BluetoothDevice dev, Action<string> log)
    {
        var res = await dev.GetRfcommServicesForIdAsync(RfcommServiceId.SerialPort, BluetoothCacheMode.Uncached);
        log($"{dev.Name}: {res.Services.Count} serial port service(s), status {res.Error}");
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
        log("read loop started");
        try
        {
            while (!cts.IsCancellationRequested)
            {
                uint n = await reader.LoadAsync(1024).AsTask(cts.Token);
                if (n == 0) { log("read loop: stream closed by the headset"); break; }
                var chunk = new byte[n];
                reader.ReadBytes(chunk);
                // A failing handler must not end the read loop (it would look like a disconnect).
                try { Received?.Invoke(chunk); }
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
        writer.WriteBytes(bytes);
        uint stored = await writer.StoreAsync();
        if (stored != bytes.Length) log($"write: only {stored} of {bytes.Length} bytes sent");
    }

    public void Close()
    {
        cts.Cancel();
        socket.Dispose();
    }
}
