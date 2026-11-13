# Tape status

Measurements for the tape deck (`rtl/atom_tape.sv`, `rtl/tape_overlay.sv`),
as `~/dev2/tape-standard.md` asks each core to keep. Dates are 2026-11-08.

## What the deck does

| Rule | Here |
|---|---|
| Deck plays | No motor relay on the Atom: the deck plays while the CPU runs the kernel's tape-read code (FB8A-FC37, FCBD-FCD7; 64 accesses with no gap over 1 ms to start, 250 ms hold) |
| Timebase | The core's 2.4 kHz tone tick, 208 CPU cycles apart at every CPU speed, as on the real machine (4 MHz / 13 / 64 against 1 MHz); 16 ticks a bit |
| Turbo | 8x: the CPU at 8 MHz and the tick with it, only while the deck plays (the clock divider's fastest step; was 4x until 2026-11-09) |
| Quick start | None: the Atom has no boot path that runs before the tape |
| Next-step hint | Yes, from the block headers: each file's command in turn, RUN after a BASIC file (see README) |
| Formats | UEF, plain or gzipped (expanded as it downloads, `rtl/gunzip.sv`), chunks &0100 &0104 &0110 &0111 &0112 &0114 &0116 (the last two since 2026-11-12: MakeUEF's recordings of real tapes keep the bytes it could not read as &0114 waves, 262 of the 263 local ones). CSW 1.01 and 2.0, RLE or Z-RLE: demodulated as it downloads into a UEF of &0110 and &0100 chunks (`rtl/csw_in.sv`), so only 300-baud Atom recordings |

## Load times

| Tape | Kind | Tape length | Turbo, measured | Where |
|---|---|---|---|---|
| BBALL at 8x | BASIC, 1 block | 0:16 | 2.05 s (123 frames, deck start to stop) | simulator |
| BBALL at 4x (before) | | | 3.9 s (237 frames) | simulator |
| BBALL at 4x (before) | | | about 4 s | mister192 |
| BBALL at Normal | | | 14.7 s (883 frames, deck start to stop) | simulator |
| BBALL at Normal | | | under 30 s from the key at PLAY TAPE; the counter read 0:06 six seconds in (no x4 shown) | mister192 |
| ASTEROIDS at 8x | machine code, 11 blocks | 2:19 | about 16 s (the counter at 2:14 15 s after the key) | mister192 |
| ASTEROIDS at 4x (before) | | | about 35 s | mister192 |

8x cuts the BBALL load from 14.7 s to 2.05 s, 7.2 times (the deck's start and its 250 ms
run-on are not sped up). 8x on mister192: ASTEROIDS (its score table), HILO then BBALL
from one tape (both run), 3DMAZE (runs); in the simulator every tape scenario passes.

## Corpus

Atom Software Archive 13 as UEFs (`software/archive.org_atom-archive-13-uef`,
4,745 files; 4,740 with an Atom header):

| First file | Tapes | Hint |
|---|---|---|
| BASIC (exec #C2B2 or #CE86) | 985 | `LOAD"NAME"`, then `RUN` |
| BASIC text with exec = load (starts &0D and a line number; 9 here, 142 of the commercial tapes' files; since 2026-11-12, before that `*RUN`) | counted under machine code | `LOAD"NAME"`, then `RUN` |
| Machine code (exec inside the file, outside video RAM) | 1,212 | `*RUN"NAME"` |
| Exec in video RAM (#8000-#9FFF): loading screens (270 named SCREEN), AtoMMC menu pages (2,098 at #8200 in MNUA-MNUG) | 2,514 | `*LOAD"NAME"` |
| Exec outside the file (data for another program: adventure data, word lists) | 29 | `*LOAD"NAME"` |

Converter flag: 2,568 single-block files carry flag bit 7 set ("more blocks
follow") on their only block; 1 multi-block file ends that way too; 2,175
multi-block files end correctly. The deck repairs the flag and the block
checksum as it plays (README, Tape).

Other local collections (No-Intro and archive.org sets, local testing only):
263 of their 324 UEFs are gzipped, and 189 hold more than one file. The common
patterns are INSTRUCTIONS (BASIC) then the game, INDEX (a title screen at
#8000) then the game, and LOADER then data and code; the instruction programs
print what to type next (Defender: "NOW LOAD MAIN PROGRAM"; Labyrinth:
`*RUN"LABYRINTH"`).

## Tested

- Simulator (`verilator/run_tests.sh`): hints for a BASIC, a machine-code and a
  data tape; a whole BBALL load to the RUN hint.
- Simulator: Rewind tape after a load returns the tape to its start and the hint to the
  load step; Tape speed Normal loads BBALL in real time.
- mister192: BBALL (F11, `LOAD"BBALL"`, RUN: the game), ASTEROIDS (F11,
  `*RUN"ASTEROIDS"`: the game's score table).
- Inflater (`verilator/tests/gunzip`): all 324 local UEFs (263 gzipped)
  expand byte for byte as Python's gzip does, with and without download
  stalls; also stored, fixed-code, RLE, empty and over-64 KB streams and a gzip
  header with every optional field; truncated streams report an error.
- Simulator: a gzipped BBALL gives the same hint as the plain one.
- Simulator and mister192: a two-file tape (HILO then BBALL): `LOAD"HILO"`,
  `TYPE RUN`; after RUN the box shows `LOAD"BBALL"` over the running HILO;
  ESCAPE, `LOAD"BBALL"`, `TYPE RUN`, the game.
- mister192: a gzipped BBALL (the download paced by `ioctl_wait`): the hint,
  the load, the game.

- CSW reader (`verilator/tests/csw`): the 61 archive UEFs, each written as CSW
  2.0 Z-RLE, 2.0 RLE and 1.01 by `tools/uef2csw.py`, give back the UEF's bytes
  exactly, with and without download stalls. The 14 distinct CSWs of the local
  TOSEC set (all 2.0 Z-RLE at 44.1 kHz, Kees van Oss and Sloanysoft games, local
  testing only) give the same bytes as a Python decoder that cuts by time
  instead, and every block's checksum is right.
- Simulator: BBALL as a CSW: the same hint and the same whole load as the UEF.
- mister192: ASTEROIDS as a CSW (2.0 Z-RLE, from the archive UEF): the hint,
  F11, `*RUN"ASTEROIDS"`, the 4x load (before 8x), the game. A .csw downloads as index 65,
  not 1: with two extensions on one F entry Main puts the extension's number in
  `ioctl_index[7:6]`, so the deck matches `[5:0]`.

- mister192: Tape speed Normal (BBALL in real time, no x4 on the bar, then
  `TYPE RUN`); Rewind tape after the load (the hint back to `TYPE LOAD"BBALL"`,
  and a second LOAD from the start runs the game).

- mister192, 2026-11-12, MakeUEF recordings of real tapes (local testing only), at 8x:
  747 (`LOAD"747"`, RUN: "STARTING ALTITUDE IS?"; release 20261112 ended in SUM,
  ERROR 6: a byte of the last block is &0114 waves); Peeko-Computer (`*LOAD"INDEX"`,
  both blocks, then the hint `LOAD"PEEKO"`, RUN: the machine's panel; 20261112 gave
  SUM after INDEX's first block and the hint `*RUN"PEEKO"`); Galaxian (48 blocks,
  RUN: the title page); Pinball (INSTRUCTIONS, then PINBALL, RUN).

Not yet: SAVE (the tape output goes to the audio only), the hint over the whole
corpus by loading.
