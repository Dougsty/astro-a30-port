using A30Kit;
using static T;

static class LinkTests
{
    static HeadsetLink NewLink() => new()
    {
        ProbeTime = TimeSpan.FromMilliseconds(50),
        RequestTimeout = TimeSpan.FromMilliseconds(200),
        OpenTimeout = TimeSpan.FromMilliseconds(300),
        DetectWait = TimeSpan.FromMilliseconds(50),
    };

    static async Task<Exception?> Throws(Task t)
    {
        try { await t; return null; } catch (Exception e) { return e; }
    }

    static async Task<string> Wait(Task<string> t) => await Task.WhenAny(t, Task.Delay(2000)) == t ? t.Result : "timeout";

    public static async Task Run()
    {
        // Raw SPP (no iAP2 detect within the probe time), as the Android app talks to the headset
        var h = new FakeHeadset { OnRequest = (i, fn, sw, a) => i == 7 && fn == 0 ? [FakeHeadset.Reply(7, 0, sw, 0x1e, 0x00)] : null };
        var link = NewLink();
        await link.OpenAsync(h);
        Check(link.Mode == HeadsetLink.LinkMode.Raw && link.IsReady, "no detect → raw mode");
        Check(Same(await link.RequestAsync(7, 0), [0x1e, 0x00]), "raw request answered");

        // Review focus 3: a swID-0 report arriving first must not answer the pending request
        var note = new TaskCompletionSource<string>();
        link.Notification += (i, fn, a) => note.TrySetResult($"{i} {fn} {Wire.Hex(a)}");
        h.OnRequest = (i, fn, sw, a) => [FakeHeadset.Reply(7, 0, 0, 0x10, 0x00), FakeHeadset.Reply(i, fn, sw, 0x2a, 0x28, 0x00)];
        Check(Same(await link.RequestAsync(2, 0), [0x2a, 0x28, 0x00]), "notification does not answer the pending request");
        Check(await Wait(note.Task) == "7 0 10 00", "swID-0 report raised as notification");

        // Review focus 4: reply split into single bytes
        h.OnRequest = (i, fn, sw, a) => FakeHeadset.Reply(i, fn, sw, 1, 2, 3).Select(b => new[] { b }).ToArray();
        Check(Same(await link.RequestAsync(4, 0), [1, 2, 3]), "reply split into single bytes");

        // Error reply
        h.OnRequest = (i, fn, sw, a) => [FakeHeadset.Error(i, fn, sw, 8)];
        var err = await Throws(link.RequestAsync(10, 1, [5])) as A30Exception;
        Check(err is { Kind: A30ErrorKind.Device, DeviceError: CenturionError.NotConnected }, "error reply → NOT_CONNECTED");

        // Link drop fails the pending request and raises Closed
        h.OnRequest = (i, fn, sw, a) => null;
        var closed = new TaskCompletionSource<string>();
        link.Closed += () => closed.TrySetResult("closed");
        var pending = link.RequestAsync(7, 0);
        h.Drop();
        Check((await Throws(pending) as A30Exception)?.Kind == A30ErrorKind.Disconnected, "drop fails the pending request");
        Check(await Wait(closed.Task) == "closed", "drop raises Closed");

        // iAP2 detect → iAP2 mode, detect echoed; an unfinished handshake times out and closes
        var h2 = new FakeHeadset();
        var link2 = NewLink();
        var open2 = link2.OpenAsync(h2);
        h2.Push(Wire.Iap2Detect);
        var e2 = await Throws(open2) as A30Exception;
        Check(link2.Mode == HeadsetLink.LinkMode.Iap2, "detect → iAP2 mode");
        Check(h2.Sent.Any(b => b.SequenceEqual(Wire.Iap2Detect)), "detect echoed");
        Check(e2?.Kind == A30ErrorKind.Timeout && h2.IsClosed, "unfinished iAP2 handshake times out and closes");

        // Windows: the headset stays silent until the host offers the iAP2 detect itself
        var h5 = new FakeHeadset();
        h5.OnSent = b => { if (b.SequenceEqual(Wire.Iap2Detect)) h5.Push(Wire.Iap2Detect); };
        var link5 = NewLink();
        var open5 = link5.OpenAsync(h5);
        await Throws(open5);   // the fake can't finish the handshake; only the mode switch matters here
        Check(h5.Sent.FirstOrDefault()?.SequenceEqual(Wire.Iap2Detect) == true, "silent probe: the host sends the iAP2 detect first");
        Check(link5.Mode == HeadsetLink.LinkMode.Iap2, "headset answering the host's detect → iAP2 mode");

        // Review focus 2: silent headset → connect fails with Timeout and closes the channel
        var h3 = new FakeHeadset();
        var e3 = await Throws(new A30Client(NewLink()).ConnectAsync(h3)) as A30Exception;
        Check(e3?.Kind == A30ErrorKind.Timeout && h3.IsClosed, "silent headset: connect times out, channel closed");

        // A30Client over the real feature map
        var args = Fixtures.FeatureListArgs();
        var h4 = new FakeHeadset
        {
            OnRequest = (i, fn, sw, a) => (i, fn) switch
            {
                (1, 1) => [FakeHeadset.Reply(1, 1, sw, args)],
                (2, 0) => [FakeHeadset.Reply(2, 0, sw, 0x2a, 0x28, 0x02)],
                (7, 1) => [FakeHeadset.Reply(7, 1, sw)],
                (11, 1) => [FakeHeadset.Reply(11, 1, sw)],
                _ => null,
            },
        };
        var c = new A30Client(NewLink());
        await c.ConnectAsync(h4);
        Check(c.Supports(FeatureId.Mix) && c.Supports(FeatureId.Eq), "feature map from the headset");
        var bat = await c.BatteryAsync();
        Check(bat is { Percent: 42, IsCharging: true }, "battery via feature index 2");
        await c.SetVolumeAsync(40);
        var vol = h4.Sent.Last();
        Check(vol[4] == 7 && vol[5] >> 4 == 1 && vol[6] == 31, "volume clamped to 31 on idx 7 fn 1");
        await c.SetBaseStationXboxAsync(true);
        var dongle = h4.Sent.Last();
        Check(dongle[4] == 11 && dongle[5] >> 4 == 1 && dongle[6] == 1, "base station Xbox = SET_CONFIG [1] on idx 11");
        var nf = new TaskCompletionSource<string>();
        c.Notification += (f, fn, a) => nf.TrySetResult($"{f} {Wire.Hex(a)}");
        h4.Push(FakeHeadset.Reply(7, 0, 0, 0x05, 0x01));
        Check(await Wait(nf.Task) == "Volume 05 01", "notification mapped to FeatureId");
        Check(DongleStatus.From(0x05).HostType && !DongleStatus.From(0x01).HostType, "base station mode reads bit 2 (host type)");

        // Review fix: notifications pushed while ConnectAsync builds the feature map must not throw
        // (the reader thread used to loop over the map while the UI thread filled it).
        for (int round = 0; round < 50; round++)
        {
            var hs = new FakeHeadset { OnRequest = (i, fn, sw, a) => (i, fn) == (1, 1) ? [FakeHeadset.Reply(1, 1, sw, args)] : null };
            var cl = new A30Client(NewLink());
            cl.Notification += (_, _, _) => { };
            using var stop = new CancellationTokenSource();
            var flood = Task.Run(() =>
            {
                while (!stop.IsCancellationRequested)
                {
                    try { hs.Push(FakeHeadset.Reply(7, 0, 0, 0x01, 0x00)); }
                    catch { Interlocked.Increment(ref floodErrors); }
                }
            });
            await cl.ConnectAsync(hs);
            stop.Cancel();
            await flood;
        }
        Check(floodErrors == 0, $"notifications during connect never throw ({floodErrors} threw)");
    }

    static int floodErrors;
}
