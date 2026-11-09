#============================================================================
#  Acorn Atom Verilator simulation
#
#    make                 # builds ./obj_dir/Vtop (GUI and headless in one binary)
#    make netlist         # only the ghdl step: gen/atomcore.v
#    make test            # run_tests.sh: scenarios against tests/golden/*.png
#    make clean
#
#  The machine (rtl/AtomFpga_Core.vhd and everything under it: T65, 6847,
#  8255, 6522, AVR8/AtoMMC, PL8) is VHDL, turned into one Verilog netlist by
#  "ghdl synth" (tools/ghdl_synth.sh). The keyboard and the SID are Verilog
#  and go to Verilator as they are, as does sys/sd_card.sv; sim.v stands in
#  for AcornAtom.sv (clocks from C++, a $readmemh ROM/RAM, the HPS side of the
#  SD card driven by sim_main.cpp).
#
#  Requires: ghdl 5.x, verilator 5.x, python3, perl, SDL2 (for the window).
#  Run the result from this directory: atom192k.hex is opened relative to cwd.
#============================================================================

V        = verilator
GHDL    ?= ghdl
ROOT     = ..
RTL      = $(ROOT)/rtl
SYS      = $(ROOT)/sys
GEN      = gen
WORK     = ghdl_work
NETLIST  = $(GEN)/atomcore.v
TOP      = --top-module top

VHDL_SRC = $(addprefix $(ROOT)/,$(shell grep -o '[^" ]*\.vhd' $(ROOT)/files.qip))

V_SRC = \
	sim.v \
	rtl/altsyncram.v \
	$(NETLIST) \
	$(RTL)/keyboard.sv $(RTL)/audio_mix.sv $(RTL)/gunzip.sv $(RTL)/csw_in.sv $(RTL)/atom_tape.sv $(RTL)/tape_overlay.sv $(RTL)/break_keys.sv \
	$(RTL)/SID/sid_6581.v $(RTL)/SID/sid_coeffs.v $(RTL)/SID/sid_components.v \
	$(RTL)/SID/sid_filters.v $(RTL)/SID/sid_voice.v \
	$(SYS)/sd_card.sv

C_SRC = \
	sim_main.cpp \
	sim/sim_bus.cpp sim/sim_clock.cpp sim/sim_console.cpp sim/sim_video.cpp \
	sim/sim_input.cpp sim/sim_audio.cpp sim/sim_blkdevice.cpp sim/a2_nib_codec.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp \
	sim/imgui/imgui_draw.cpp sim/imgui/imgui_widgets.cpp sim/imgui/imgui_tables.cpp \
	sim/imgui/imgui.cpp sim/imgui/ImGuiFileDialog.cpp \
	sim/imgui/implot.cpp sim/imgui/implot_items.cpp

# The netlist is plain Verilog from a synthesiser: wide, flat, and full of
# things a lint pass dislikes (unused nets, mixed blocking assignments). None
# of those warnings is actionable here.
V_DEFINE = -I$(RTL) \
	-CFLAGS "-I../sim/imgui -I../sim -g" \
	--timescale-override 1ps/1ps \
	-Wno-fatal -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-WIDTH -Wno-UNOPTFLAT \
	-Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-LATCH \
	-Wno-DECLFILENAME -Wno-CASEX -Wno-BLKANDNBLK -Wno-COMBDLY -Wno-INITIALDLY \
	-Wno-SYNCASYNCNET -Wno-UNUSED -Wno-CMPCONST -Wno-LITENDIAN -Wno-ASCRANGE

ifeq ($(TRACE),1)
V_DEFINE += --trace
CXX_DEFINE += -DVM_TRACE_VCD=1
else
CXX_DEFINE += -DVM_TRACE_VCD=0
endif

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S), Darwin)
	LIBS += -framework OpenGL -framework Cocoa -framework IOKit -framework CoreVideo `sdl2-config --libs`
	LIBS += -L/usr/local/lib -L/opt/local/lib -L/opt/homebrew/lib
	CXXFLAGS += `sdl2-config --cflags`
	CXXFLAGS += `sdl2-config --cflags | sed 's|include/SDL2|include/|'`
	CXXFLAGS += -I/usr/local/include -I/opt/local/include -I/opt/homebrew/include
endif

ifeq ($(UNAME_S), Linux)
	LIBS += -lGL -ldl `sdl2-config --libs`
	CXXFLAGS += `sdl2-config --cflags`
endif

CC_OPT    = -O2
V_OPT     = -O3 --x-assign fast --x-initial fast --noassert
CXXFLAGS += $(CC_OPT) $(CXX_DEFINE) -Isim/imgui -std=c++17
LDFLAGS   = $(LIBS)
EXE       = ./obj_dir/Vtop
VOUT      = obj_dir/Vtop.cpp

all: atom192k.hex $(EXE)

# The ROM/RAM image the core boots from, in $readmemh form.
atom192k.hex: $(ROOT)/roms/ATOM192k.mif tools/mif2hex.py
	python3 tools/mif2hex.py $< $@

$(NETLIST): $(VHDL_SRC) tools/ghdl_synth.sh tools/fix_port_aliases.py
	GHDL=$(GHDL) tools/ghdl_synth.sh $(abspath $(ROOT)) $(abspath $(WORK)) $(abspath $(NETLIST))

netlist: $(NETLIST)

$(VOUT): $(V_SRC) $(RTL)/tape_font.vh Makefile
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS)" -exe --Mdir ./obj_dir \
		$(V_DEFINE) $(TOP) -CFLAGS "$(CXXFLAGS)" $(V_SRC) $(C_SRC)

$(EXE): $(VOUT) $(C_SRC)
	(cd obj_dir; $(MAKE) -f Vtop.mk OBJCACHE= OPT_FAST="-O2" OPT_SLOW="-O0" OPT_GLOBAL="-O2")

test: all
	./run_tests.sh

clean:
	rm -rf obj_dir $(GEN) $(WORK) tests/out

.PHONY: all netlist test clean
