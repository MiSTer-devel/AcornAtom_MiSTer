# Acorn Atom Verilator simulation

```bash
cd verilator
make                                   # gen/atomcore.v (ghdl), then ./obj_dir/Vtop
./obj_dir/Vtop --help
```

The machine is VHDL (`rtl/AtomFpga_Core.vhd`: T65, 6847, 8255, 6522, the
AVR8 running the AtoMMC firmware, PL8). `tools/ghdl_synth.sh` turns it into one
Verilog netlist with `ghdl synth`; the keyboard, the SID and `sys/sd_card.sv`
go to Verilator from their own sources. `sim.v` stands in for `AcornAtom.sv`
(two clocks from C++, a `$readmemh` ROM/RAM, the HPS side of the SD card driven
by `sim_main.cpp`), so what runs is the same core the FPGA gets, AtoMMC
included.

Requires ghdl 5.x (Homebrew: synthesis built in), Verilator 5.x, python3,
perl, SDL2 for the window. Run `Vtop` from this directory: `atom192k.hex`
(made from `roms/ATOM192k.mif` by `tools/mif2hex.py`) is opened relative to
the working directory.

## Running

```bash
./obj_dir/Vtop                                                     # window (ImGui)
./obj_dir/Vtop --headless --screenshot 120 --stop-at-frame 121     # boot banner
./obj_dir/Vtop --headless --send-keys 90:'PRINT 1+1\n' --screenshot 200 --stop-at-frame 201
./obj_dir/Vtop --headless --vhd ../software/mister11/boot.vhd --send-keys 300:'*CAT\n' --screenshot 600 --stop-at-frame 601
```

| Option | |
|---|---|
| `--headless` | no window (still renders, so screenshots work) |
| `--vhd <file>`, `--vhd-at N` | mount a VHD on the AtoMMC SD card at start, or at frame N |
| `--screenshot N[,N...]`, `--screenshot-prefix`, `--screenshot-name` | PNGs of the 256x192 active area (60 frames = 1 s) |
| `--stop-at-frame N` | exit after frame N |
| `--send-keys N:text` | type at frame N: `\n` Return, `\xNN` raw PS/2 code, `\U\D\L\R` arrows, `\1`..`\4` F1-F4 (turbo), `\K` BREAK (F10), `\e` Escape |
| `--break N[,N...]` | tap BREAK at these frames |
| `--key-hold MS` | hold time per key edge (default 100 ms: the kernel waits for the release and debounces; at 40 ms every other key is lost) |
| `--layout uk\|us\|orig\|game`, `--charset original\|xtra`, `--dark`, `--bbc`, `--turbo 1\|2\|4\|8`, `--speaker on\|off`, `--sid on\|off`, `--tape-audio on\|off` | the OSD settings |
| `--osd-break N[,N...]`, `--trace-audio` | the OSD BREAK button (held nine frames, like a key press); per-frame AUDIO_L range and change count |
| `--joy 1\|2:FRAME:BUTTONS` | joystick, e.g. `1:300:UP+FIRE`; `1:400:` lets go |
| `--dump-mem ADDR:LEN@FRAME`, `--poke ADDR=BYTES@FRAME` | read or write the 192 KB image (hex; Atom addresses 0000-FFFF map 1:1) |
| `--watch-pc ADDR[,...]` | count CPU accesses to addresses |
| `--trace-cpu`, `--trace-cpu-from N`, `--trace-cpu-to N` | every CPU bus cycle |
| `--trace-sd`, `--trace-key` | SD chip select, PS/2 events |

Keys are sent as the PS/2 codes of a US PC keyboard; what the Atom makes of a
shifted key depends on the OSD layout, exactly as on the hardware.

## Regression (run_tests.sh, `make test`)

| scenario | checks |
|---|---|
| boot | the banner and prompt at frame 60 (golden image) |
| print | `PRINT 1+1` answers 2 (golden image) |
| cat | `*CAT` on `../software/mister11/boot.vhd` lists the directory (golden image; skipped without the VHD) |
| sid, sid4 | a voice gated from BASIC moves the audio output at 1 MHz and in 4 MHz turbo (`--trace-audio` log) |

Each scenario takes a few minutes; `./run_tests.sh boot` runs one.

## Clocks and timing

`clk_42` (42.954545 MHz, the 6847 side) and `clk_32` (31.5 MHz, the CPU side)
are scheduled independently in picoseconds, so their relationship is the
hardware's. The 6847 line is 456 half-dots (228 chroma clocks, 63.7 us) and
the frame 262 lines, 59.92 Hz, so frame numbers mean the same thing as on
the hardware and as in MAME.

## Netlist post-processing (tools/ghdl_synth.sh)

* `fix_port_aliases.py` restores `sig <= port` aliases ghdl's Verilog writer
  drops (`ram_dout <= ExternDout` in the core is one of them).
* `do`, `config` and `break` are SystemVerilog keywords and get a `_v` suffix.
* `'Z'` constants (the AVR8's slots for peripherals it does not implement)
  become zeros, which is what synthesis makes of them.

The work library is rebuilt from scratch every time: re-analysing a package
in a populated library marks its users obsolete.
