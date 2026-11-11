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
    /// BLE GATT carries CPL+CPP per write/notification without the SPP wrapper (the Android route
    /// for the A30); RFCOMM carries SPP frames, raw or inside iAP2.
    bool IsBle => false;
}
