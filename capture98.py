import sys, zlib, struct, os
sys.path.insert(0, os.path.expanduser('~/hpp-pont'))
os.environ.setdefault('HPP_DISPLAY', ':98')
import clavier_hpp as C
from Xlib import display, X
d = display.Display(os.environ['HPP_DISPLAY']); r = d.screen().root
W, H = 1920, 886; f = int(sys.argv[2]) if len(sys.argv) > 2 else 2
raw = r.get_image(0, 0, W, H, X.ZPixmap, 0xffffffff).data
w2, h2 = W // f, H // f
rows = bytearray()
for y in range(h2):
    rows.append(0); base = y * f * W * 4
    for x in range(w2):
        i = base + x * f * 4
        rows.append((raw[i] * 29 + raw[i+1] * 150 + raw[i+2] * 77) >> 8)
def ch(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w2, h2, 8, 0, 0, 0, 0)) + ch(b'IDAT', zlib.compress(bytes(rows), 9)) + ch(b'IEND', b'')
open(sys.argv[1], 'wb').write(png); print(len(png))
