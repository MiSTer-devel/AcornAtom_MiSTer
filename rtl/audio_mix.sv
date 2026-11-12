// Audio mixer for the Acorn Atom core.
//
// The three sources are mixed, not selected, as upstream AtomFpga does:
// the beeper (a single bit) at +/-0x1000, the SID's 18-bit unsigned output
// re-centred, and the cassette output tone at +/-0x800 so SAVE can be heard.
// Each source has an OSD enable. The sum is clamped to a signed 16-bit value
// (AUDIO_S = 1 at the top).
module audio_mix
(
	input             clk,
	input             beeper,
	input      [17:0] sid,
	input             tape,
	input             speaker_en,
	input             sid_en,
	input             tape_en,
	output reg [15:0] audio      // signed
);

wire signed [17:0] b = speaker_en ? (beeper ? 18'sd4096 : -18'sd4096) : 18'sd0;
wire signed [17:0] s = sid_en     ? ($signed({2'b00, sid[17:2]}) - 18'sd32768) : 18'sd0;
wire signed [17:0] t = tape_en    ? (tape ? 18'sd2048 : -18'sd2048) : 18'sd0;
wire signed [17:0] sum = b + s + t;

always @(posedge clk)
	audio <= (sum > 18'sd32767) ? 16'h7FFF : (sum < -18'sd32768) ? 16'h8000 : sum[15:0];

endmodule
