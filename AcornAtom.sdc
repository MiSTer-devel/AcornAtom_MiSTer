# Core-specific timing constraints for AcornAtom_MiSTer.
#
# The core has two clocks from two PLLs: clk_42 (42.954545 MHz, CLK_VIDEO,
# the 6847 side) from rtl/pll, and clk_32 (exactly 32 MHz, clk_sys /
# clk_main, the CPU side) from rtl/pll_cpu.v.
#
# The design treats the two domains as asynchronous: the 6847 reads video RAM
# through a true dual-port memory, the display mode bits from the 8255 are
# quasi-static, and the frame-sync line back into the 8255 is an asynchronous
# level, exactly as on the real machine. Any new crossing must be synchronised
# or go through the dual-port RAM.
#
# sys/sys_top.sdc puts rtl/pll's outputs in a group exclusive of the sys
# clocks, but its pattern (*|pll|pll_inst|...) does not match pll_cpu. A
# group of one makes clk_32 asynchronous to every other clock: clk_42 and the
# sys clocks (hps_io and the rest of the core-to-sys interface run on clk_sys,
# and sys already synchronises what it takes from the core).
set clk_system [get_clocks {emu|pll_cpu|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_clock_groups -asynchronous -group $clk_system
