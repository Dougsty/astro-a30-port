// Byte-level framing for the A30 control channel. Pure functions, no Bluetooth, so the selftest
// can exercise them without a headset. Layers (outside in):
// RFCOMM bytes → [iAP2 link packets → EA session data] → SPP frames → CPL → CPP.
using System.Text;

namespace A30Kit;

public static class Wire
{
    public static string Hex(IEnumerable<byte> d) => string.Join(" ", d.Select(b => b.ToString("x2")));

    public static byte[] Be16(int v) => [(byte)(v >> 8), (byte)v];

    internal static int Rd16(IReadOnlyList<byte> d, int o) => d[o] << 8 | d[o + 1];

    /// CRC-16/MCRF4XX (poly 0x8408 reflected, init 0xFFFF). Check value 0x6F91 for "123456789".
    public static ushort Crc16(IEnumerable<byte> d)
    {
        ushort c = 0xFFFF;
        foreach (var b in d)
        {
            c ^= b;
            for (int i = 0; i < 8; i++) c = (c & 1) != 0 ? (ushort)((c >> 1) ^ 0x8408) : (ushort)(c >> 1);
        }
        return c;
    }

    /// SPP frame: 13 | A0+lenHi | lenLo | payload | crcLo crcHi
    public static byte[] SppWrap(byte[] payload)
    {
        int n = payload.Length;
        var f = new List<byte>(n + 5) { 0x13, (byte)(0xA0 | ((n >> 8) & 0x0F)), (byte)n };
        f.AddRange(payload);
        var c = Crc16(f);
        f.Add((byte)c);
        f.Add((byte)(c >> 8));
        return f.ToArray();
    }

    /// CPL byte 0x00 (single fragment) + feature index + (fn << 4 | swId) + args.
    public static byte[] CppRequest(byte index, byte function, byte swId, byte[] args) =>
        [0x00, index, (byte)((function << 4) | (swId & 0x0F)), .. args];

    // ---- iAP2

    public static readonly byte[] Iap2Detect = [0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10];

    /// iAP2 checksum: two's complement of the byte sum.
    public static byte IapChecksum(IEnumerable<byte> d) => unchecked((byte)-d.Sum(b => (int)b));

    /// Control-message param: len(2) id(2) data.
    public static byte[] IapParam(int id, byte[] data) => [.. Be16(4 + data.Length), .. Be16(id), .. data];

    /// Control message: 40 40 len(2) msgId(2) params.
    public static byte[] ControlMsg(int id, byte[]? prm = null)
    {
        prm ??= [];
        return [0x40, 0x40, .. Be16(6 + prm.Length), .. Be16(id), .. prm];
    }

    /// Parses a run of params; null unless the bytes are exactly a well-formed run.
    public static List<IapParam>? ParseParams(byte[] d)
    {
        var o = new List<IapParam>();
        int i = 0;
        while (i + 4 <= d.Length)
        {
            int n = Rd16(d, i);
            if (n < 4 || i + n > d.Length) return null;
            o.Add(new IapParam(Rd16(d, i + 2), d[(i + 4)..(i + n)]));
            i += n;
        }
        return i == d.Length ? o : null;
    }

    /// Printable ASCII (one trailing NUL allowed), else null.
    public static string? IapText(byte[] d)
    {
        var s = d.Length > 0 && d[^1] == 0 ? d[..^1] : d;
        if (s.Length == 0 || s.Any(b => b < 0x20 || b >= 0x7F)) return null;
        return Encoding.ASCII.GetString(s);
    }
}

/// Reassembles SPP frames from a byte stream. Over the iAP2 EA session the A30 sends CRC 00 00,
/// so that is accepted as well as a correct CRC.
public sealed class SppParser
{
    readonly List<byte> buf = new();

    public List<byte[]> Feed(byte[] bytes)
    {
        buf.AddRange(bytes);
        var o = new List<byte[]>();
        int i = 0;
        while (i + 5 <= buf.Count)
        {
            if (buf[i] != 0x13 || (buf[i + 1] & 0xF0) != 0xA0) { i++; continue; }
            int n = (buf[i + 1] & 0x0F) << 8 | buf[i + 2];
            int end = i + 3 + n + 2;
            if (end > buf.Count) break;
            int rx = buf[end - 2] | buf[end - 1] << 8;
            if (rx == 0 || rx == Wire.Crc16(buf.GetRange(i, 3 + n))) o.Add(buf.GetRange(i + 3, n).ToArray());
            i = end;
        }
        buf.RemoveRange(0, i);
        return o;
    }
}

/// Joins CPL fragments (CPL bit0 = more follow, bits1-7 = fragment seq). Returns the CPP message
/// (CPL byte stripped) once the last fragment arrives. Fragments must arrive in order 0, 1, 2 …;
/// a gap or stray continuation drops the partial message; fragment 0 always starts fresh.
public sealed class CplReassembler
{
    List<byte> frag = new();
    int nextSeq;
    bool inProgress;

    public byte[]? Feed(byte[] payload)
    {
        if (payload.Length == 0) return null;
        byte cpl = payload[0];
        int seq = cpl >> 1;
        if (seq == 0) frag = new();
        else if (!inProgress || seq != nextSeq) { frag = new(); inProgress = false; return null; }
        frag.AddRange(payload.Skip(1));
        if (frag.Count > 4096) { frag = new(); inProgress = false; return null; }   // runaway guard
        if ((cpl & 1) != 0) { inProgress = true; nextSeq = (seq + 1) & 0x7F; return null; }
        var msg = frag.ToArray();
        frag = new();
        inProgress = false;
        return msg;
    }
}

/// CPP reply (CPL byte already stripped). Errors look like FF featIdx fn|sw code.
public sealed record CppReply(bool IsError, byte Index, byte Function, byte SwId, byte[] Args, byte Code)
{
    public static CppReply? Parse(byte[] m)
    {
        if (m.Length >= 4 && m[0] == 0xFF) return new(true, m[1], (byte)(m[2] >> 4), (byte)(m[2] & 0x0F), [], m[3]);
        if (m.Length < 2) return null;
        return new(false, m[0], (byte)(m[1] >> 4), (byte)(m[1] & 0x0F), m[2..], 0);
    }

    public override string ToString() => IsError
        ? $"error idx={Index} fn={Function} sw={SwId} code={Code}"
        : $"ok idx={Index} fn={Function} sw={SwId} args={Wire.Hex(Args)}";
}

/// iAP2 link packet: FF 5A len(2) control seq ack session hdrCks [payload payloadCks]
public sealed record LinkPacket(byte Control, byte Seq, byte Ack, byte Session, byte[] Payload)
{
    public const byte SYN = 0x80, ACK = 0x40, RST = 0x10;

    public LinkPacket(byte control, byte seq, byte ack, byte session) : this(control, seq, ack, session, []) { }

    public byte[] Encode()
    {
        int len = 9 + (Payload.Length == 0 ? 0 : Payload.Length + 1);
        var p = new List<byte> { 0xFF, 0x5A, (byte)(len >> 8), (byte)len, Control, Seq, Ack, Session };
        p.Add(Wire.IapChecksum(p));
        if (Payload.Length > 0) { p.AddRange(Payload); p.Add(Wire.IapChecksum(Payload)); }
        return p.ToArray();
    }

    public override string ToString() => "packet " + Wire.Hex(Encode());
}

public abstract record Iap2Frame
{
    public sealed record Detect : Iap2Frame { public override string ToString() => "detect"; }
    public sealed record Packet(LinkPacket P) : Iap2Frame { public override string ToString() => P.ToString(); }
    public sealed record Junk(byte B) : Iap2Frame { public override string ToString() => $"junk {B:x2}"; }
}

/// Splits the RFCOMM byte stream into iAP2 detect sequences and checksum-valid link packets.
public sealed class Iap2Splitter
{
    readonly List<byte> buf = new();

    public List<Iap2Frame> Feed(byte[] bytes)
    {
        buf.AddRange(bytes);
        var o = new List<Iap2Frame>();
        while (buf.Count >= 2)
        {
            if (buf.Count >= 6 && buf.Take(6).SequenceEqual(Wire.Iap2Detect))
            {
                buf.RemoveRange(0, 6);
                o.Add(new Iap2Frame.Detect());
                continue;
            }
            if (buf[0] == 0xFF && buf[1] == 0x5A)
            {
                if (buf.Count < 9) break;
                // Check the header checksum before trusting len: a false FF 5A or a corrupt length
                // must not make us wait for up to 64 KiB and swallow valid packets.
                if (Wire.IapChecksum(buf.Take(8)) != buf[8]) { o.Add(TakeJunk()); continue; }
                int len = Wire.Rd16(buf, 2);
                if (len < 9) { o.Add(TakeJunk()); continue; }
                if (buf.Count < len) break;
                var p = buf.GetRange(0, len).ToArray();
                buf.RemoveRange(0, len);
                byte[] payload = len > 10 ? p[9..(len - 1)] : [];
                if (payload.Length == 0 || Wire.IapChecksum(payload) == p[len - 1])
                    o.Add(new Iap2Frame.Packet(new LinkPacket(p[4], p[5], p[6], p[7], payload)));
                continue;
            }
            if (buf.Count < 6 && Wire.Iap2Detect.Take(buf.Count).SequenceEqual(buf)) break;   // partial detect
            o.Add(TakeJunk());
        }
        return o;
    }

    Iap2Frame TakeJunk()
    {
        var b = buf[0];
        buf.RemoveAt(0);
        return new Iap2Frame.Junk(b);
    }
}

public sealed record IapParam(int Id, byte[] Data);

public sealed record ControlMessage(int Id, List<IapParam> Params);

/// Reassembles iAP2 control messages that may span several link packets.
public sealed class ControlParser
{
    readonly List<byte> buf = new();

    public List<ControlMessage> Feed(byte[] bytes)
    {
        buf.AddRange(bytes);
        var o = new List<ControlMessage>();
        while (buf.Count >= 6)
        {
            if (buf[0] != 0x40 || buf[1] != 0x40) { buf.Clear(); break; }   // desync: drop buffer
            int n = Wire.Rd16(buf, 2);
            if (n < 6) { buf.Clear(); break; }
            if (buf.Count < n) break;
            o.Add(new ControlMessage(Wire.Rd16(buf, 4), Wire.ParseParams(buf.GetRange(6, n - 6).ToArray()) ?? []));
            buf.RemoveRange(0, n);
        }
        return o;
    }
}
