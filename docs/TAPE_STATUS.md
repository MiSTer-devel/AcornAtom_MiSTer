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
| Next-step hint | Yes, from the first block header (see README) |
| Formats | UEF (uncompressed), chunks &0100 &0104 &0110 &0111 &0112. Not CSW, not gzipped UEF |

## Load times

| Tape | Kind | Tape length | 4x, measured | Where |
|---|---|---|---|---|
| BBALL | BASIC, 1 block | 0:16 | 3.9 s (237 frames, deck start to stop) | simulator |
| BBALL | | | about 4 s | mister192 |
| BBALL at Normal | | | 14.7 s (883 frames, deck start to stop) | simulator |
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

## Tested

- Simulator (`verilator/run_tests.sh`): hints for a BASIC, a machine-code and a
  data tape; a whole BBALL load to the RUN hint.
- Simulator: Rewind tape after a load returns the tape to its start and the hint to the
  load step; Tape speed Normal loads BBALL in real time.
- mister192: BBALL (F11, `LOAD"BBALL"`, RUN: the game), ASTEROIDS (F11,
  `*RUN"ASTEROIDS"`: the game's score table).

Not yet: a multi-file tape's second file, Normal speed and Rewind on hardware, SAVE (the
tape output goes to the audio only), the hint over the whole corpus by loading.
