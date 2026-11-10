# ROM sources for roms/ATOM192k.mif

`roms/make_rom_image.py` builds `roms/ATOM192k.mif` from these files. It checks
each file's sha1 and places it as in the map in `AcornAtom.sv` (MEMORY). Banks
that aren't listed are RAM, video RAM, I/O or unused, and are filled with #FF.
`--check` reports whether the mif in the repo matches the sources.

The files are unmodified copies from David Banks' (hoglet67) repositories:

- **AtomFpga** `roms/`, commit 7798c46709b1 (2026-07-17):
  https://github.com/hoglet67/AtomFpga
- **Ice40Atom** `roms/`, commit 28e4363ddff9 (2019-06-01):
  https://github.com/hoglet67/Ice40Atom. These are the images built for a ROM
  at #B010 (Ice40Atom `roms/build.sh`, image `boot_b000_17fff`).

| Image | CPU | File | From | Contents |
|---|---|---|---|---|
| 0x0B000 | #B010 | bran_b010.rom | Ice40Atom | Branquart ROM switcher (BRAN) at #B010, under the I/O page |
| 0x0C000 | #C000 | abasic.rom | AtomFpga | Atom BASIC |
| 0x0D000 | #D000 | afloat_patched_b010.rom | Ice40Atom | Floating point, patched to start BRAN at #B010 |
| 0x0E000 | #E000 | atommc3_avr.rom | AtomFpga | AtoMMC 3.02E |
| 0x0F000 | #F000 | akernel_patched.rom | AtomFpga | Atom kernel (OS), patched |
| 0x10000 | #A000 bank 0 | axr1.rom | AtomFpga | AXR1 |
| 0x11000 | #A000 bank 1 | pcharme_v1.73.rom | AtomFpga | P-Charme 1.73 |
| 0x12000 | #A000 bank 2 | atomic_windows_v1.1.rom | AtomFpga | Atomic Windows 1.1 |
| 0x13000 | #A000 bank 3 | gags_v2.3.rom | AtomFpga | GAGS 2.3 |
| 0x14000 | #A000 bank 4 | pp_toolkit.rom | AtomFpga | Program Power Programmers Toolkit |
| 0x15000 | #A000 bank 5 | we_rom.rom | AtomFpga | WE ROM |
| 0x16000 | #A000 bank 6 | fpgautil.rom | Ice40Atom | FPGA Utils 0.28 (VGA80, ...) |
| 0x26000 | BBC #6000 | atom_bbc_ext1.rom | AtomFpga | BBC BASIC mode extension ROM 1 |
| 0x27000 | BBC #7000 | atom_bbc_ext2_avr.rom | AtomFpga | Extension ROM 2 (BBCMMC, AVR) |
| 0x2A000 | BBC #A000 | bbc_a000.rom | AtomFpga | BBC BASIC 2, 1/4 |
| 0x2C000-0x2E000 | BBC #C000-#E000 | bbc_c000/d000/e000.rom | AtomFpga | BBC BASIC 2, 2/4 to 4/4 |
| 0x2F000 | BBC #F000 | bbc_f000.rom | AtomFpga | Atom MOS 3.0 (Hoglet) |

Before 2026-11-10 the mif was a hand-made srec_cat image. Its ROM banks are
byte-identical to the table above. It also held leftover RAM contents (bytes at
#0008-#000C and a BASIC program at #2000-#3FFF); the generated image fills RAM
with #FF instead.
