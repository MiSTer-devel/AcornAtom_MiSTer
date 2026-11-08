# Core-specific timing constraints for AcornAtom_MiSTer.
#
# sys/sys_top.sdc creates the clocks (derive_pll_clocks) and puts every output
# of the core PLL into one clock group, so TimeQuest timed paths between the
# 42.954545 MHz video clock (clk_42, CLK_VIDEO, the 6847 side) and the
# 31.5 MHz system clock (clk_sys / clk_main, the CPU side) as related clocks.
# Both come from one 945 MHz VCO, which gives a 2.1 ns setup relationship,
# and every negative-slack path in the baseline build (2026-11-07) was one of
# those crossings; nothing inside either domain was failing.
#
# The design treats the two domains as asynchronous: the 6847 reads video RAM
# through a true dual-port memory, the display mode bits from the 8255 are
# quasi-static, and the frame-sync line back into the 8255 is an asynchronous
# level, exactly as on the real machine. Any new crossing must be synchronised
# or go through the dual-port RAM.
set clk_video  [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set clk_system [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_clock_groups -asynchronous -group $clk_video -group $clk_system
