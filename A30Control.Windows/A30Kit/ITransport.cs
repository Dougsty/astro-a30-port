namespace A30Kit;

/// A byte pipe to the headset's control channel (dongle HID or RFCOMM on Windows, a fake in the selftest).
public interface ITransport
{
    event Action<byte[]>? Received;
    /// The channel dropped by itself (not raised after Close()).
    event Action? Closed;
    /// Begin delivering Received; called after the link has subscribed.
    void Start();
    Task SendAsync(byte[] bytes);
    void Close();
    /// The 2.4 GHz dongle: each send/receive is one CPL+CPP message (the transport adds and strips the
    /// HID report header), and the headset never answers requests. RFCOMM carries SPP frames.
    bool IsDongle => false;
}
