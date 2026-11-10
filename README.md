# Acorn_Atom_MiSTer

Acorn Atom for MiSTer FPGA

## Introduction
This is a cut down version of the fabulous [AtomFPGA by David Banks (Hoglet)](https://github.com/hoglet67/AtomFpga) and my thanks to him for his help.

The [Acorn Atom](https://en.wikipedia.org/wiki/Acorn_Atom) was the predecessor of the BBC micro based on Acorn's System computers. It was available as a kit or ready made. The Acorn had 2KB of RAM that was expandable to 12KB and 8KB of ROM that was expandable to 16KB. It could display graphics in monochrome at a resolution of 256x192 pixels, although later a colour board was made.

## Features
* 32KB ram
* System Roms with mmc (to access the SD card): AtoMMC 3.02
* Seven additional Roms and 1 slot of ram to download additional Rom.
* Two character sets.
* Tape: UEF images (plain or gzipped) from the OSD (Tape), played at 8x with a status bar and a hint that says what to type; tape input through the MiSTer's ADC too
* Sound is mixed: the speaker, the SID and the tape tone, each with an on/off switch
* Black or Dark background
* MC6847 video with the datasheet's 15 kHz timing (455 pixel clocks a line, 262 lines,
  59.94 Hz) and its border: green or buff around graphics modes, black around text
  (Video, Border: On/Off; Off shows only the 256x192 picture)
* GODIL extensions (from AtomGodilVideo): two 8 KB video RAM banks (#BDE0 bits 4 and 5,
  as Bad Apple uses), the mouse and pointer (#BDE8-#BDEA, for Atomic Windows; MiSTer's
  mouse moves it), the version register (#BDEF)
* Atom or BBC Basic mode
* Colour palette
* SID sound
* The 6502 at 1 MHz from an exact 32 MHz clock, as on the Atom
* Turbo mode (F1-F4), or a CPU speed chosen in the OSD and applied at reset
* BREAK on F10, Shift-BREAK (AtoMMC menu) on F9, Ctrl-BREAK (no AtoMMC, for tapes) on F11; also OSD buttons
* Four keyboards: PC (US, the default), PC (UK), Atom (original), Atom (game)
* Load ROM: a 192 KB image in the layout of roms/ATOM192k.mif replaces every ROM and RAM bank

## OSD
The top page holds the media (the SD card image and Load ROM) and the pages
Machine, Video, Input and Audio. Keyboard layout (Input) applies at once; every
other setting is applied by **Apply and reset** (or any other reset), and
"Changes pending" shows while an OSD value differs from what the machine runs.
Machine also has BREAK, Shift-BREAK and Ctrl-BREAK buttons, and the tape rows
(Tape speed, Rewind tape); Tape overlay is on Video, Tape audio on Audio.

A `games/AcornAtom/boot0.rom` is loaded at start if present (192 KB, same
layout as the mif); Load ROM picks another image for the session.

## Tape
Choose a `.uef` or `.csw` in the OSD's **Tape** row. A UEF can be plain or gzipped
(the Atom Software Archive's UEFs are plain; most other collections gzip theirs), up
to 128 KB expanded. A CSW (a recording of the tape's wave, 1.01 or 2.0, RLE or
Z-RLE) is read back into the Atom's bytes as it downloads, so it behaves as a UEF;
only standard Atom 300-baud recordings can be read that way.
The AtoMMC ROM takes over LOAD and SAVE, so the tape needs the Atom without it:
the box in the bottom-left corner says what to do, read from the tape itself:

1. `PRESS F11 (CTRL-BREAK)`: the Atom restarts without the AtoMMC ROM.
2. `TYPE LOAD"NAME"` for a BASIC program, `*RUN"NAME"` for machine code, or
   `*LOAD"NAME"` for a data file (a loading screen, a menu page); then press any
   key at PLAY TAPE.
3. The deck plays (the Atom has no motor relay: it plays while the kernel reads
   the tape) at 8x with a status bar, then stops. A BASIC program ends with
   `TYPE RUN`.
4. On a tape with more files (instructions, then the game; a title screen, then
   the game), the box then shows the next file's command, once RUN has been
   typed for a BASIC file. Stop the program first if it is still running
   (ESCAPE). A file straight after another of the same name is taken for a
   backup copy and skipped.

The command is chosen from the file's header: execution address #C2B2 or #CE86
is BASIC; an execution address inside the file's own memory (outside video RAM)
is machine code; anything else is data. That rule matched every tape of the
archive's 4,745 by kind, but it is a rule, not something the tape states.

The archive's single-block files (2,568 of them) were converted with the "more
blocks follow" flag set on their only block, so a real Atom's LOAD would wait for
a block that never comes. The deck corrects that flag, and the block checksum,
as it plays such a block, and only when the tape has no next block of that file.

Tape speed Normal plays at the real 300 baud.

## Controls
The PC layouts type what is printed on the PC key (US or UK keyboard). The Atom
layouts follow the Atom's own key positions.

UK/US Keyboards - Shift lock is Caps, Repeat is right Alt, copy is tab - Left Alt is xtra shift key. 

Input > Swap Alt/Win keys puts these two Alt functions on the Win keys (Cmd on a Mac
keyboard), and the Alt keys then do nothing.

The original keyboard had @ and up-arrow as separate keys these have moved to a PS2 config. 

Up-Arrow is shift+6 so to "shift" this press left Alt+shift+6. 

The original keyboard is as originally written ie shift+8 = ( and shift+9 = )

The game keyboard just reverses the ctrl and shift as on the original keyboard, for games like Asteroids. 

## Instructions
You need a boot.vhd file formatted as FAT and around 100MB. There is a blank.zip in releases. Unzip and rename to boot.vhd

Attach the boot.vhd and copy software onto it.

Detach the VHD and place the file in the games/AcornAtom folder on your SD card, and mount it
on the OSD's "Pri. disk (SD)" row; the mount is remembered across core starts.

To auto boot the software menu press Shift-BREAK (F9, or Shift+F10); Ctrl-BREAK (F11, or Ctrl+F10) starts without the MMC ROM

The best software source is the AtomSoftwareArchive V11 zip 11.9MB

There are several sites dedicated to the atom.

## Simulation
`verilator/` holds a Verilator simulation of the whole core (the AtoMMC's AVR
included) with screenshots, typed input, VHD mounting and a regression suite:
see `verilator/README.md`.
