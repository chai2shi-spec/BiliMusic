import zlib
import struct
import math

W = H = 216
PINK = (0xFB, 0x72, 0x99)
WHITE = (0xFF, 0xFF, 0xFF)
TRANS = (0, 0, 0, 0)

cx, cy = W / 2, H / 2
r_out = W * 0.46
r_in = W * 0.20


def color(x, y):
    dx = x - cx
    dy = y - cy
    d = math.sqrt(dx * dx + dy * dy)
    if d <= r_out:
        if d >= r_in:
            return PINK + (255,)
        return WHITE + (255,)
    return TRANS


raw = bytearray()
for y in range(H):
    raw.append(0)  # filter type 0
    for x in range(W):
        r, g, b, a = color(x + 0.5, y + 0.5)
        raw += bytes((r, g, b, a))

comp = zlib.compress(bytes(raw), 9)


def chunk(tag, data):
    out = struct.pack('>I', len(data)) + tag + data
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return out + struct.pack('>I', crc)


png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
png += chunk(b'IDAT', comp)
png += chunk(b'IEND', b'')

with open('AppScope/resources/base/media/app_icon.png', 'wb') as f:
    f.write(png)
print('app_icon.png written,', len(png), 'bytes')
