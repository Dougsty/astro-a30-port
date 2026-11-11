# Packs PNG files into one .ico (PNG-compressed entries, Windows Vista+). Usage: mkico.py out.ico a.png b.png ...
import struct, sys

out, pngs = sys.argv[1], sys.argv[2:]
datas = [open(p, 'rb').read() for p in pngs]
offset = 6 + 16 * len(datas)
entries = b''
for d in datas:
    w, h = struct.unpack('>II', d[16:24])   # IHDR width/height
    entries += struct.pack('<BBBBHHII', w % 256, h % 256, 0, 0, 1, 32, len(d), offset)
    offset += len(d)
open(out, 'wb').write(struct.pack('<HHH', 0, 1, len(datas)) + entries + b''.join(datas))
