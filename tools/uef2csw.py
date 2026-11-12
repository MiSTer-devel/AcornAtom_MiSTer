#!/usr/bin/env python3
"""Write an Atom UEF (plain or gzipped) as a CSW, for testing the core's CSW
reader (rtl/csw_in.sv) against tapes whose bytes are known.

  uef2csw.py in.uef out.csw [--v1 | --rle] [--rate 44100]

The default is CSW 2.0 with Z-RLE (zlib), as the CSWs in circulation are;
--rle writes 2.0 uncompressed RLE, --v1 writes CSW 1.01 (RLE only).
Chunks: &0100 (8N1 at 300 baud: a 0 is four cycles of 1200 Hz, a 1 eight of
2400 Hz), &0104 (bits, parity, stop bits), &0110 (carrier, 2400 Hz cycles), &0111 (carrier, &AA, carrier),
&0112 (gap, n/600 s). Others are skipped.
"""
import argparse, gzip, struct, sys, zlib


def chunks(b):
    if b[:2] == b"\x1f\x8b":
        b = gzip.decompress(b)
    if b[:10] != b"UEF File!\x00":
        sys.exit("not a UEF")
    i = 12
    while i + 6 <= len(b):
        cid, n = struct.unpack("<HI", b[i:i + 6])
        yield cid, b[i + 6:i + 6 + n]
        i += 6 + n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--rate", type=int, default=44100)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--v1", action="store_true")
    g.add_argument("--rle", action="store_true")
    a = ap.parse_args()

    rate = a.rate
    pulses = []
    t = 0.0  # time in samples, kept fractional so the rate is exact on average

    def half(f):  # one half cycle of frequency f
        nonlocal t
        start = round(t)
        t += rate / (2.0 * f)
        pulses.append(max(1, round(t) - start))

    def bit(v):
        if v:
            for _ in range(16):
                half(2400)
        else:
            for _ in range(8):
                half(1200)

    def byte(v, nbits=8, parity="N", stop=1):
        bit(0)
        for k in range(nbits):
            bit((v >> k) & 1)
        if parity in "OE":
            bit((bin(v & ((1 << nbits) - 1)).count("1") + (parity == "O")) & 1)
        for _ in range(abs(stop)):
            bit(1)
        if stop < 0:  # the UEF spec: a negative count adds one short wave
            half(2400)
            half(2400)

    def tone(cycles):
        for _ in range(2 * cycles):
            half(2400)

    for cid, d in chunks(open(a.inp, "rb").read()):
        if cid == 0x0100:
            for v in d:
                byte(v)
        elif cid == 0x0104:
            nbits, parity, stop = d[0], chr(d[1]), struct.unpack("b", d[2:3])[0]
            for v in d[3:]:
                byte(v, nbits, parity, stop)
        elif cid == 0x0110:
            tone(struct.unpack("<H", d[:2])[0])
        elif cid == 0x0111:
            c1, c2 = struct.unpack("<HH", d[:4])
            tone(c1)
            byte(0xAA)
            tone(c2)
        elif cid == 0x0112:
            start = round(t)
            t += struct.unpack("<H", d[:2])[0] * rate / 600.0
            if round(t) > start:
                pulses.append(round(t) - start)

    rle = bytearray()
    for p in pulses:
        if p < 256:
            rle.append(p)
        else:
            rle += b"\x00" + struct.pack("<I", p)

    hdr = b"Compressed Square Wave\x1a"
    with open(a.out, "wb") as f:
        if a.v1:
            f.write(hdr + bytes([1, 1]) + struct.pack("<HBB", rate, 1, 0) + b"\x00" * 3 + rle)
        else:
            body = rle if a.rle else zlib.compress(bytes(rle), 9)
            f.write(hdr + bytes([2, 0]) + struct.pack("<IIBBB", rate, len(pulses), 1 if a.rle else 2, 0, 0)
                    + b"uef2csw.py".ljust(16, b"\x00") + body)


if __name__ == "__main__":
    main()
