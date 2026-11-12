#!/usr/bin/env python3
"""Compare two PNG screenshots pixel for pixel (no dependencies beyond the standard library).

    pngdiff.py A.png B.png            exit 0 if identical, 1 if not; prints the differing area
    pngdiff.py --double-a A.png B.png  each line of A twice first (core 640x200 vs CSP 640x400)

Handles 8-bit greyscale, RGB and RGBA, non-interlaced: what stb_image_write and CSP write.
"""
import struct
import sys
import zlib


def read_png(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit(f'{path}: not a PNG')
    pos, idat, w = 8, b'', 0
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
            if depth != 8 or interlace or ctype not in (0, 2, 6):
                raise SystemExit(f'{path}: unsupported PNG (depth {depth}, type {ctype}, interlace {interlace})')
            bpp = {0: 1, 2: 3, 6: 4}[ctype]
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        cur = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = cur[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: cur[x] = (cur[x] + a) & 255
            elif f == 2: cur[x] = (cur[x] + b) & 255
            elif f == 3: cur[x] = (cur[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                cur[x] = (cur[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = cur
        rgb = [tuple(cur[i:i + 3]) if bpp >= 3 else (cur[i],) * 3 for i in range(0, stride, bpp)]
        rows.append(rgb)
    return w, h, rows


def main():
    args = sys.argv[1:]
    double = '--double-a' in args
    args = [a for a in args if a != '--double-a']
    if len(args) != 2:
        raise SystemExit(__doc__)
    wa, ha, a = read_png(args[0])
    wb, hb, b = read_png(args[1])
    if double:
        a = [r for r in a for _ in (0, 1)]
        ha *= 2
    if (wa, ha) != (wb, hb):
        print(f'size differs: {wa}x{ha} vs {wb}x{hb}')
        return 1
    diff = [(x, y) for y in range(ha) for x in range(wa) if a[y][x] != b[y][x]]
    if not diff:
        print(f'identical ({wa}x{ha})')
        return 0
    xs, ys = [d[0] for d in diff], [d[1] for d in diff]
    print(f'{len(diff)} pixels differ, area x {min(xs)}-{max(xs)} y {min(ys)}-{max(ys)}; '
          f'first at ({xs[0]},{ys[0]}): {a[ys[0]][xs[0]]} vs {b[ys[0]][xs[0]]}')
    return 1


if __name__ == '__main__':
    sys.exit(main())
