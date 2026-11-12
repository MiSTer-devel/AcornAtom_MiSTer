#!/usr/bin/env python3
"""Build an AtoMMC boot.vhd from an Atom Software Archive release zip.

The image is a fixed VHD holding an MBR and one FAT16 partition, like the
releases/blank.zip VHD. The zip is unpacked into its root (MENU, LIB,
MANPAGES, ASA/...). Needs mtools (mformat, mcopy); nothing is mounted.

usage: tools/make_boot_vhd.py AtomSoftwareArchive_..._V13.01.zip boot.vhd [size_MiB]

The plain AtoMMC zip is the one to use (not _SDDOS2/_SDDOS3/_ECONET/...):
https://github.com/hoglet67/AtomSoftwareArchive/releases
"""
import os, shutil, struct, subprocess, sys, tempfile, time, uuid, zipfile

zip_path, out = sys.argv[1], sys.argv[2]
size_mib = int(sys.argv[3]) if len(sys.argv) > 3 else 128

SECT = 512
total = size_mib * 1024 * 1024 // SECT
heads, spt = 16, 63                  # same CHS as the VHD geometry below
start = 63                            # first partition at LBA 63, as the old boot.vhd
part = total - start

def chs(lba):
    c, r = divmod(lba, heads * spt)
    h, s = divmod(r, spt)
    c = min(c, 1023)
    return bytes([h, ((c >> 2) & 0xC0) | (s + 1), c & 0xFF])

with open(out, 'wb') as f:
    f.truncate(total * SECT)
    mbr = bytearray(SECT)
    mbr[446:462] = (bytes([0x80]) + chs(start) + bytes([0x06]) + chs(total - 1)
                    + struct.pack('<II', start, part))
    mbr[510:512] = b'\x55\xaa'
    f.write(mbr)

img = f'{out}@@{start * SECT}'
env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
subprocess.run(['mformat', '-i', img, '-v', 'ATOMARCHIVE',
                '-T', str(part), '-h', str(heads), '-s', str(spt), '-H', str(start), '::'],
               check=True, env=env)

tmp = tempfile.mkdtemp()
try:
    with zipfile.ZipFile(zip_path) as z:
        for n in z.namelist():
            if os.path.basename(n.rstrip('/')) == '.DS_Store':
                continue
            if '..' in n.split('/') or n.startswith('/'):
                raise SystemExit(f'bad path in zip: {n}')
            z.extract(n, tmp)
    entries = sorted(os.listdir(tmp))
    subprocess.run(['mcopy', '-s', '-Q', '-m', '-i', img] + [os.path.join(tmp, e) for e in entries] + ['::'],
                   check=True, env=env)
finally:
    shutil.rmtree(tmp)

# Fixed-disk VHD footer
size = total * SECT
cyl = size // (heads * spt * SECT)
footer = bytearray(struct.pack('>8sIIQI4sI4sQQHBBII16sB',
    b'conectix', 2, 0x00010000, 0xFFFFFFFFFFFFFFFF,
    int(time.time()) - 946684800, b'mstr', 0x00010000, b'Wi2k',
    size, size, min(cyl, 65535), heads, spt, 2, 0, uuid.uuid4().bytes, 0))
footer += bytes(SECT - len(footer))
footer[64:68] = struct.pack('>I', ~sum(footer) & 0xFFFFFFFF)
with open(out, 'ab') as f:
    f.write(footer)
print(out, size_mib, 'MiB')
