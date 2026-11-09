"""Reference decode of an Atom CSW (any version or compression) to its bytes,
to stdout: a different method from rtl/csw_in.sv's, cutting the pulses into
1/300 s cells by time and voting short against long in each."""
import struct, sys, zlib
d = open(sys.argv[1], "rb").read()
assert d[:23] == b"Compressed Square Wave\x1a", "not a CSW"
if d[23] == 1:
    rate, comp = struct.unpack("<H", d[25:27])[0], d[27]
    body = d[32:]
else:
    rate, comp, ext = struct.unpack("<I", d[25:29])[0], d[33], d[35]
    body = d[52 + ext:]
if comp == 2:
    body = zlib.decompress(body)
pulses, i = [], 0
while i < len(body):
    b = body[i]; i += 1
    if b == 0:
        b = struct.unpack("<I", body[i:i + 4])[0]; i += 4
    pulses.append(b)
short = lambda p: p * 3200 < rate
long_ = lambda p: not short(p) and p * 1600 < rate
cell = rate / 300.0
out, idx, n = bytearray(), 0, len(pulses)
while idx < n:
    if long_(pulses[idx]):
        bits, j, ok = [], idx, True
        for _ in range(10):
            tt = s = l = 0
            while j < n and tt < cell * 0.95:
                p = pulses[j]; tt += p; j += 1
                if short(p): s += 1
                elif long_(p): l += 1
                else: ok = False
            bits.append(1 if s > l else 0)
        if ok and bits[0] == 0 and bits[9] == 1:
            out.append(sum(bits[1 + k] << k for k in range(8)))
            idx = j
            continue
    idx += 1
sys.stdout.buffer.write(out)
