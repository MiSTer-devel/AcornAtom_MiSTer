# Tape status

Measurements for the tape deck (`rtl/atom_tape.sv`, `rtl/tape_overlay.sv`),
as `~/dev2/tape-standard.md` asks each core to keep. Dates are 2026-11-08.

## What the deck does

| Rule | Here |
|---|---|
| Deck plays | No motor relay on the Atom: the deck plays while the CPU runs the kernel's tape-read code (FB8A-FC37, FCBD-FCD7; 64 accesses with no gap over 1 ms to start, 250 ms hold) |
| Timebase | The core's 2.4 kHz tone tick, 208 CPU cycles apart at every CPU speed, as on the real machine (4 MHz / 13 / 64 against 1 MHz); 16 ticks a bit |
| Turbo | 4x: the CPU at 4 MHz and the tick with it, only while the deck plays. 8x is available in the clock divider but not used: 4x is what was tested |
| Quick start | None: the Atom has no boot path that runs before the tape |
| Next-step hint | Yes, from the block headers: each file's command in turn, RUN after a BASIC file (see README) |
| Formats | UEF, plain or gzipped (expanded as it downloads, `rtl/gunzip.sv`), chunks &0100 &0104 &0110 &0111 &0112. CSW 1.01 and 2.0, RLE or Z-RLE: demodulated as it downloads into a UEF of &0110 and &0100 chunks (`rtl/csw_in.sv`), so only 300-baud Atom recordings |

## Load times

| Tape | Kind | Tape length | 4x, measured | Where |
|---|---|---|---|---|
| BBALL | BASIC, 1 block | 0:16 | 3.9 s (237 frames, deck start to stop) | simulator |
| BBALL | | | about 4 s | mister192 |
| BBALL at Normal | | | 14.7 s (883 frames, deck start to stop) | simulator |
| BBALL at Normal | | | under 30 s from the key at PLAY TAPE; the counter read 0:06 six seconds in (no x4 shown) | mister192 |
| ASTEROIDS | machine code, 11 blocks | 2:19 | about 35 s | mister192 |

Turbo cuts the BBALL load from 14.7 s to 3.9 s, 3.7 times (the deck's start and its 250 ms
run-on are not sped up).

## Corpus

Atom Software Archive 13 as UEFs (`software/archive.org_atom-archive-13-uef`,
4,745 files; 4,740 with an Atom header):

| First file | Tapes | Hint |
|---|---|---|
| BASIC (exec #C2B2 or #CE86) | 985 | `LOAD"NAME"`, then `RUN` |
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
  F11, `*RUN"ASTEROIDS"`, the 4x load, the game. A .csw downloads as index 65,
  not 1: with two extensions on one F entry Main puts the extension's number in
  `ioctl_index[7:6]`, so the deck matches `[5:0]`.

- mister192: Tape speed Normal (BBALL in real time, no x4 on the bar, then
  `TYPE RUN`); Rewind tape after the load (the hint back to `TYPE LOAD"BBALL"`,
  and a second LOAD from the start runs the game).

Not yet: SAVE (the tape output goes to the audio only), the hint over the whole
corpus by loading.
