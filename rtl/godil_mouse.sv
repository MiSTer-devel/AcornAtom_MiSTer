// The GODIL mouse position (AtomGodilVideo's MouseRefComp, 256x192 setting) from
// MiSTer's ps2_mouse: x 0 (left) .. 255, y 0 (top) .. 191, centred at reset,
// moved by each packet's deltas and clamped at the edges. PS/2 Y is positive
// upwards, the pointer's y grows downwards.
//
// ps2_mouse (sys/hps_io.sv): [24] toggles per packet, [23:16] Y delta,
// [15:8] X delta, [7:0] status (bit 0 left, 1 right, 2 middle, 4 X sign,
// 5 Y sign).
module godil_mouse (
	input             clk,
	input             reset,
	input      [24:0] ps2_mouse,
	output reg  [7:0] x,
	output reg  [7:0] y,
	output      [2:0] buttons    // {middle, right, left}, 1 = pressed
);

assign buttons = {ps2_mouse[2], ps2_mouse[1], ps2_mouse[0]};

wire signed [9:0] dx = {ps2_mouse[4], ps2_mouse[4], ps2_mouse[15:8]};
wire signed [9:0] dy = {ps2_mouse[5], ps2_mouse[5], ps2_mouse[23:16]};
wire signed [10:0] nx = $signed({3'b000, x}) + dx;
wire signed [10:0] ny = $signed({3'b000, y}) - dy;

reg toggle;
always @(posedge clk) begin
	toggle <= ps2_mouse[24];
	if (reset) begin
		x <= 8'd128;
		y <= 8'd96;
	end else if (toggle != ps2_mouse[24]) begin
		x <= nx < 0 ? 8'd0 : nx > 255 ? 8'd255 : nx[7:0];
		y <= ny < 0 ? 8'd0 : ny > 191 ? 8'd191 : ny[7:0];
	end
end

endmodule
