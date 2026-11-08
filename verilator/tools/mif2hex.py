#!/usr/bin/env python3
"""Convert a Quartus .mif (as written by srec_cat) to a $readmemh file, one byte per line.

Usage: mif2hex.py roms/ATOM192k.mif verilator/atom192k.hex
"""
import re
import sys


def main(mif_path, hex_path):
    depth = None
    data = None
    with open(mif_path) as f:
        text = f.read()
    m = re.search(r'DEPTH\s*=\s*(\d+)', text)
    depth = int(m.group(1))
    data = bytearray([0xFF]) * depth
    body = text.split('CONTENT BEGIN', 1)[1].split('END', 1)[0]
    filled = 0
    for line in body.splitlines():
        line = line.split('--')[0].strip().rstrip(';')
        if not line or ':' not in line:
            continue
        addr_s, bytes_s = line.split(':', 1)
        addr_s = addr_s.strip()
        if '..' in addr_s:          # [lo..hi] : value
            lo, hi = addr_s.strip('[]').split('..')
            lo, hi = int(lo, 16), int(hi, 16)
            v = int(bytes_s.split()[0], 16)
            for a in range(lo, hi + 1):
                data[a] = v
            filled += hi - lo + 1
            continue
        a = int(addr_s, 16)
        for tok in bytes_s.split():
            data[a] = int(tok, 16)
            a += 1
            filled += 1
    with open(hex_path, 'w') as out:
        for b in data:
            out.write('%02X\n' % b)
    print('%s: depth %d, %d bytes written to %s' % (mif_path, depth, filled, hex_path))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
