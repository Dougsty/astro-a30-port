// One CPP request in flight over an ITransport. The A30 greets an Apple host with the iAP2 detect
// (it does toward a Mac); without it we send raw SPP frames, as the Android app does. Either way a
// late detect switches to iAP2. Every frame is logged in hex for remote debugging.
namespace A30Kit;

public sealed class HeadsetLink
{
    public enum LinkMode { Unknown, Raw, Iap2, Ble }

    public TimeSpan ProbeTime { get; init; } = TimeSpan.FromMilliseconds(1500);
    public TimeSpan RequestTimeout { get; init; } = TimeSpan.FromMilliseconds(1500);
    public TimeSpan OpenTimeout { get; init; } = TimeSpan.FromSeconds(8);
    /// After a silent probe the link offers the iAP2 detect itself and waits this long for an answer.
    public TimeSpan DetectWait { get; init; } = TimeSpan.FromMilliseconds(1500);
    public Action<string> Log { get; set; } = _ => { };
    /// An established link dropped (not raised for Close()).
    public event Action? Closed;
    /// Device-initiated reports (swID 0): (feature index, function, args).
    public event Action<byte, byte, byte[]>? Notification;
    public LinkMode Mode { get; private set; }
    public bool IsReady { get; private set; }

    sealed class Pending(byte index, byte function, byte[] args)
    {
        public readonly byte Index = index, Function = function;
        public readonly byte[] Args = args;
        public byte SwId;
        public readonly TaskCompletionSource<byte[]> Tcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    readonly object gate = new();
    ITransport? transport;
    int generation;
    Iap2Session session = new();
    SppParser spp = new();
    CplReassembler cpl = new();
    TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    Task sendChain = Task.CompletedTask;
    readonly Queue<Pending> queue = new();
    Pending? current;
    int consecutiveTimeouts;
    long rxBytes;   // everything received on this transport, for the silent-probe check
    byte sw;

    public async Task OpenAsync(ITransport t)
    {
        Close();
        int gen;
        Task readyTask;
        lock (gate)
        {
            gen = ++generation;
            transport = t;
            session = new();
            spp = new();
            cpl = new();
            consecutiveTimeouts = 0;
            rxBytes = 0;
            Mode = LinkMode.Unknown;
            IsReady = false;
            ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
            readyTask = ready.Task;
        }
        t.Received += b => { if (IsCurrent(gen)) OnReceived(b); };
        t.Closed += () =>
        {
            if (!IsCurrent(gen)) return;
            Log("transport closed");
            Teardown(new A30Exception(A30ErrorKind.Disconnected), notify: true);
        };
        t.Start();

        if (t.IsBle)
        {
            lock (gate)
            {
                if (gen != generation || transport == null) throw new A30Exception(A30ErrorKind.Disconnected);
                Mode = LinkMode.Ble;
                IsReady = true;
                ready.TrySetResult();
                Log("BLE GATT: CPL frames without the SPP wrapper");
            }
            return;
        }

        await Task.Delay(ProbeTime);
        bool offerDetect;
        lock (gate)
        {
            offerDetect = gen == generation && transport != null && Mode == LinkMode.Unknown && rxBytes == 0;
            if (offerDetect)
            {
                // Toward a Mac the headset sends the detect first; toward other hosts it may wait for
                // the host to offer it. Nothing came: offer it, and fall back to raw SPP if still silent.
                Log("nothing received during the probe: sending the iAP2 detect");
                Write(Wire.Iap2Detect);
            }
        }
        if (offerDetect) await Task.Delay(DetectWait);
        lock (gate)
        {
            if (gen == generation && transport != null && Mode == LinkMode.Unknown)
            {
                Mode = LinkMode.Raw;
                IsReady = true;
                ready.TrySetResult();
                Log("no iAP2 detect: using raw SPP frames");
            }
        }
        if (await Task.WhenAny(readyTask, Task.Delay(OpenTimeout)) != readyTask)
        {
            Log("open timed out (iAP2 handshake did not finish)");
            Close();
            throw new A30Exception(A30ErrorKind.Timeout);
        }
        await readyTask;   // rethrows a teardown failure
    }

    public Task<byte[]> RequestAsync(byte index, byte function, byte[]? args = null)
    {
        lock (gate)
        {
            if (transport == null) return Task.FromException<byte[]>(new A30Exception(A30ErrorKind.Disconnected));
            var p = new Pending(index, function, args ?? []);
            queue.Enqueue(p);
            Pump();
            return p.Tcs.Task;
        }
    }

    public void Close()
    {
        ITransport? t;
        lock (gate) t = transport;
        t?.Close();
        Teardown(new A30Exception(A30ErrorKind.Disconnected), notify: false);
    }

    bool IsCurrent(int gen)
    {
        lock (gate) return gen == generation && transport != null;
    }

    void OnReceived(byte[] bytes)
    {
        var notes = new List<(byte Index, byte Function, byte[] Args)>();
        bool reset = false;
        lock (gate)
        {
            rxBytes += bytes.Length;
            Log("rx " + Wire.Hex(bytes));
            if (Mode == LinkMode.Ble)
            {
                HandleCpl(bytes, notes);   // one notification = one CPL fragment
                goto done;
            }
            var events = session.Receive(bytes);
            bool detect = events.Any(e => e is Iap2Event.Send s && s.Bytes.SequenceEqual(Wire.Iap2Detect));
            if (detect && Mode != LinkMode.Iap2)
            {
                Log(Mode == LinkMode.Raw ? "iAP2 detect after raw start: switching to iAP2" : "iAP2 detect: using iAP2");
                Mode = LinkMode.Iap2;
                IsReady = false;
            }
            if (Mode == LinkMode.Iap2)
            {
                foreach (var e in events)
                {
                    switch (e)
                    {
                        case Iap2Event.Send s: Write(s.Bytes); break;
                        case Iap2Event.Log l: Log(l.Text); break;
                        case Iap2Event.Ready: _ = BecomeReady(generation); break;
                        case Iap2Event.EaData d: Parse(d.Bytes, notes); break;
                        case Iap2Event.Reset: Log("iAP2 reset by accessory"); reset = true; break;
                    }
                }
            }
            else Parse(bytes, notes);   // raw SPP frames, and anything sent before the mode is known
            done:;
        }
        foreach (var n in notes) Notification?.Invoke(n.Index, n.Function, n.Args);
        if (reset) Drop();
    }

    async Task BecomeReady(int gen)
    {
        await Task.Delay(300);   // the accessory needs a moment after EA00 before CPP traffic
        lock (gate)
        {
            if (gen != generation || transport == null) return;
            IsReady = true;
            ready.TrySetResult();
            Pump();
        }
    }

    /// Under gate. SPP frames → CPL → CPP replies: notifications out, the matching reply to `current`.
    void Parse(byte[] bytes, List<(byte, byte, byte[])> notes)
    {
        foreach (var payload in spp.Feed(bytes)) HandleCpl(payload, notes);
    }

    /// Under gate. One CPL fragment → (once complete) a CPP reply or notification.
    void HandleCpl(byte[] payload, List<(byte, byte, byte[])> notes)
    {
        {
            if (cpl.Feed(payload) is not byte[] m || CppReply.Parse(m) is not CppReply r) return;
            // swID 0 is never used for requests, so these are always device-initiated notifications.
            if (!r.IsError && r.SwId == 0) { notes.Add((r.Index, r.Function, r.Args)); return; }
            if (current is not Pending p) { Log($"unsolicited {r}"); return; }
            if (r.Index != p.Index || r.SwId != p.SwId) { Log($"unmatched {r}"); return; }
            current = null;
            consecutiveTimeouts = 0;
            if (r.IsError)
            {
                var code = Enum.IsDefined((CenturionError)r.Code) ? (CenturionError)r.Code : CenturionError.Failed;
                p.Tcs.TrySetException(new A30Exception(A30ErrorKind.Device, code));
            }
            else p.Tcs.TrySetResult(r.Args);
            Pump();
        }
    }

    /// Under gate. Sends stay in order.
    void Write(byte[] b)
    {
        var t = transport;
        if (t == null) return;
        Log("tx " + Wire.Hex(b));
        sendChain = sendChain.ContinueWith(_ => t.SendAsync(b)).Unwrap()
            .ContinueWith(x => { if (x.IsFaulted) Log("write failed: " + x.Exception?.GetBaseException().Message); });
    }

    /// Under gate. One request in flight; swId 1…15 (0 marks device notifications).
    void Pump()
    {
        if (current != null || !IsReady || queue.Count == 0) return;
        var p = queue.Dequeue();
        sw = (byte)(sw % 15 + 1);
        p.SwId = sw;
        current = p;
        var cplCpp = Wire.CppRequest(p.Index, p.Function, p.SwId, p.Args);
        Write(Mode switch
        {
            LinkMode.Ble => cplCpp,
            LinkMode.Iap2 => session.EaPacket(Wire.SppWrap(cplCpp)),
            _ => Wire.SppWrap(cplCpp),
        });
        _ = Task.Delay(RequestTimeout).ContinueWith(_ => OnTimeout(p));
    }

    void OnTimeout(Pending p)
    {
        bool drop = false;
        lock (gate)
        {
            if (current != p) return;
            consecutiveTimeouts++;
            Log($"timeout idx={p.Index} fn={p.Function}");
            if (consecutiveTimeouts >= 3) drop = true;
            else
            {
                current = null;
                p.Tcs.TrySetException(new A30Exception(A30ErrorKind.Timeout));
                Pump();
            }
        }
        if (drop) Drop();
    }

    /// The link is unusable: close the transport and report the drop.
    void Drop()
    {
        ITransport? t;
        lock (gate) t = transport;
        t?.Close();
        Teardown(new A30Exception(A30ErrorKind.Disconnected), notify: true);
    }

    /// Fails everything in flight. `notify` reports a drop of an established link to Closed.
    void Teardown(Exception e, bool notify)
    {
        bool wasReady;
        lock (gate)
        {
            wasReady = IsReady && transport != null;
            IsReady = false;
            transport = null;
            ready.TrySetException(e);
            current?.Tcs.TrySetException(e);
            current = null;
            while (queue.Count > 0) queue.Dequeue().Tcs.TrySetException(e);
        }
        if (notify && wasReady) Closed?.Invoke();
    }
}
