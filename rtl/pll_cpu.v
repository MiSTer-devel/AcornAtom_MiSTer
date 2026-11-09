// The CPU-side clock: exactly 32 MHz from the 50 MHz board clock
// (VCO 800 MHz = 50 x 16, output /25), so the 6502 enable is 32 / 32 = 1 MHz
// as on the Atom (Technical Manual: 1 MHz from the 4 MHz crystal), the tape
// tones are 2400/1200 Hz, and the SID runs at 1 MHz.
//
// It is a PLL of its own because the 6847 clock (42.954545 MHz, rtl/pll) and
// 32 MHz cannot come from one integer VCO (945 MHz there; 945 and 704 are
// coprime). The two domains are asynchronous anyway (AcornAtom.sdc).
`timescale 1ns/10ps
module pll_cpu (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		.output_clock_frequency0("32.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst      (rst),
		.outclk   (outclk_0),
		.locked   (locked),
		.fboutclk (),
		.fbclk    (1'b0),
		.refclk   (refclk)
	);

endmodule
