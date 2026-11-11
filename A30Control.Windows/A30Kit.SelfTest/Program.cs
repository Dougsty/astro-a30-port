using System.Runtime.CompilerServices;

FramingTests.Run();
Iap2Tests.Run();
CodecTests.Run();
await LinkTests.Run();
UpdateTests.Run();
Console.WriteLine(T.Failures == 0 ? "selftest: all passed" : $"selftest: {T.Failures} failed");
return T.Failures == 0 ? 0 : 1;

/// Minimal runner, mirrors A30Control/Tests/SelfTest.swift.
static class T
{
    public static int Failures;

    public static void Check(bool cond, string msg, [CallerLineNumber] int line = 0)
    {
        if (cond) return;
        Failures++;
        Console.WriteLine($"FAIL line {line}: {msg}");
    }

    /// "13 a0 05" → [0x13, 0xa0, 0x05]
    public static byte[] Bytes(string s) =>
        s.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(x => Convert.ToByte(x, 16)).ToArray();

    public static bool Same(byte[]? a, byte[] b) => a != null && a.SequenceEqual(b);

    /// Compares event/frame lists by their ToString() forms ("send ff 5a …", "ready", …).
    public static void Events(IEnumerable<object> got, string msg, params string[] want)
    {
        var g = got.Select(x => x.ToString()!).ToArray();
        Check(g.SequenceEqual(want), $"{msg}\n  got:  {string.Join(" | ", g)}\n  want: {string.Join(" | ", want)}");
    }

    public static string Send(string hex) => "send " + hex;
}
