"""The data bytes of a UEF (chunks &0100 and &0104, in order) to stdout."""
import gzip, struct, sys
b = open(sys.argv[1], "rb").read()
if b[:2] == b"\x1f\x8b":
    b = gzip.decompress(b)
assert b[:10] == b"UEF File!\x00", "not a UEF"
out = bytearray()
i = 12
while i + 6 <= len(b):
    cid, n = struct.unpack("<HI", b[i:i + 6])
    d = b[i + 6:i + 6 + n]
    if cid == 0x0100:
        out += d
    elif cid == 0x0104:
        out += d[3:]
    i += 6 + n
sys.stdout.buffer.write(out)
