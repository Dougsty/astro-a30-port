namespace A30Kit;

/// A byte pipe to the headset's control channel (RFCOMM on Windows, a fake in the selftest).
public interface ITransport
{
    event Action<byte[]>? Received;
    /// The channel dropped by itself (not raised after Close()).
    event Action? Closed;
    /// Begin delivering Received; called after the link has subscribed.
    void Start();
    Task SendAsync(byte[] bytes);
    void Close();
}
