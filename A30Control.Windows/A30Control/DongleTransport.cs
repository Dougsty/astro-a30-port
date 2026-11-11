using System.Runtime.InteropServices.WindowsRuntime;
using A30Kit;
using Windows.Devices.Enumeration;
using Windows.Devices.HumanInterfaceDevice;
using Windows.Storage;

namespace A30Control;

/// The A30's 2.4 GHz dongle (USB, VID 0x9886 PID 0x004F). Its vendor HID collection (usage page 0xFF03,
/// usage 1) carries report 0xF2 both ways; Wire.DongleWrap/Unwrap add and strip the header. The headset
/// applies writes and pushes notifications (plus a full status burst whenever it links to the dongle),
/// but never answers requests.
sealed class DongleTransport : ITransport
{
    const ushort Vid = 0x9886, Pid = 0x004F, UsagePage = 0xFF03, UsageId = 0x0001;

    public event Action<byte[]>? Received;
    public event Action? Closed;
    public bool IsDongle => true;

    readonly HidDevice device;
    readonly DeviceWatcher watcher;
    readonly Action<string> log;
    volatile bool started, closed;

    DongleTransport(HidDevice device, string id, Action<string> log)
    {
        this.device = device;
        this.log = log;
        device.InputReportReceived += (_, e) => OnReport(e.Report.Data.ToArray());
        // The dongle unplugged: the HID device goes away.
        watcher = DeviceInformation.CreateWatcher(HidDevice.GetDeviceSelector(UsagePage, UsageId, Vid, Pid));
        watcher.Removed += (_, u) =>
        {
            if (u.Id != id || closed) return;
            log("dongle removed");
            if (started) Closed?.Invoke();
        };
        watcher.Added += (_, _) => { };
        watcher.Start();
    }

    /// The dongle's control collection, or null when no dongle is plugged in.
    public static async Task<DongleTransport?> OpenAsync(Action<string> log)
    {
        var infos = await DeviceInformation.FindAllAsync(HidDevice.GetDeviceSelector(UsagePage, UsageId, Vid, Pid));
        if (infos.Count == 0) return null;
        var info = infos[0];
        var dev = await HidDevice.FromIdAsync(info.Id, FileAccessMode.ReadWrite)
                  ?? throw new A30Exception(A30ErrorKind.OpenFailed, detail: "the 2.4 GHz dongle is in use or access was denied");
        log($"dongle open: {info.Name}");
        return new DongleTransport(dev, info.Id, log);
    }

    void OnReport(byte[] r)
    {
        if (!started || closed) return;
        if (Wire.DongleUnwrap(r) is not byte[] cplCpp) { log("dongle rx (ignored) " + Wire.Hex(r.Take(16))); return; }
        try { Received?.Invoke(cplCpp); }
        catch (Exception e) { log("receive handler failed: " + e); }
    }

    public void Start() => started = true;

    public async Task SendAsync(byte[] cplCpp)
    {
        var bytes = Wire.DongleWrap(cplCpp);
        var report = device.CreateOutputReport(Wire.DongleReport);
        // Windows wants the report's exact size (id byte included); zero-pad our 47 bytes to it.
        var data = new byte[Math.Max((int)report.Data.Length, bytes.Length)];
        bytes.CopyTo(data, 0);
        if (data.Length != bytes.Length) log($"dongle output report is {data.Length} bytes, padded");
        report.Data = data.AsBuffer();
        await device.SendOutputReportAsync(report);
    }

    public void Close()
    {
        closed = true;
        if (watcher.Status is DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted) watcher.Stop();
        device.Dispose();
    }
}
