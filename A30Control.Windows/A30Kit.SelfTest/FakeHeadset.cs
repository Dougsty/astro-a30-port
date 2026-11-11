using A30Kit;

/// Scripted headset speaking raw SPP. OnRequest(index, function, swId, args) returns the chunks to
/// send back (delivered in order on a worker thread), or null to stay silent.
sealed class FakeHeadset : ITransport
{
    public event Action<byte[]>? Received;
    public event Action? Closed;
    public readonly List<byte[]> Sent = new();
    public bool IsClosed;
    /// Speaks like the A30 behind the 2.4 GHz dongle: CPL+CPP per message, never answers requests.
    public bool Dongle { get; init; }
    bool ITransport.IsDongle => Dongle;
    public Func<byte, byte, byte, byte[], byte[][]?>? OnRequest;
    /// Called with every chunk the link sends (before OnRequest).
    public Action<byte[]>? OnSent;

    public void Start() { }

    public Task SendAsync(byte[] b)
    {
        lock (Sent) Sent.Add(b);
        OnSent?.Invoke(b);
        // raw request frame: 13 A0 len | CPL idx fn|sw args | crc crc
        byte[][]? chunks = null;
        if (!Dongle && b.Length >= 8 && b[0] == 0x13)
            chunks = OnRequest?.Invoke(b[4], (byte)(b[5] >> 4), (byte)(b[5] & 0x0F), b[6..^2]);
        if (chunks != null)
            _ = Task.Run(() => { foreach (var c in chunks) Received?.Invoke(c); });
        return Task.CompletedTask;
    }

    public void Push(byte[] b) => Received?.Invoke(b);
    public void Close() => IsClosed = true;
    public void Drop() => Closed?.Invoke();

    public static byte[] Reply(byte idx, byte fn, byte sw, params byte[] args) => Wire.SppWrap([0x00, idx, (byte)(fn << 4 | sw), .. args]);
    public static byte[] Error(byte idx, byte fn, byte sw, byte code) => Wire.SppWrap([0x00, 0xFF, idx, (byte)(fn << 4 | sw), code]);
}
