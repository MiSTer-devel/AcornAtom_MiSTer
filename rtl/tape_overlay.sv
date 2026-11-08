//============================================================================
//  Tape status bar and next-step hint for the Acorn Atom core
//  (~/dev2/tape-standard.md rules 19-28; ported from the Basic Master Jr and
//  Sharp X1 cores' overlays, drawn here with the 6847's own characters).
//
//  While the deck plays, the bottom-left corner of the picture shows
//
//      TAPE > 0:09/ 1:42 x4
//      [=========----------]
//
//  elapsed/total tape time (the tape's own 300 baud timebase: 4808 ticks of
//  the 2.4 kHz tone a second), the turbo factor while turbo is on, and a
//  64-step bar. While the deck is stopped, the same box says what to type,
//  read from the first block header on the tape (atom_tape.sv):
//
//  - at the start of the tape, the load command. A header whose execution
//    address is #C2B2 is a BASIC program saved with SAVE (Atomic Theory and
//    Practice 19.3): LOAD"NAME". Anything else runs from its execution
//    address: *RUN"NAME". With the AtoMMC ROM's vectors in place (it hooks
//    LOAD, SAVE and the byte routines, so the tape is out of reach), the
//    first line says to press F11 (Ctrl-BREAK; also an OSD button) first:
//    Ctrl-BREAK starts the Atom without the AtoMMC ROM. The second line, with the vectors back on the tape,
//    says to press a key at PLAY TAPE, which the COS waits for.
//  - once the first file has played to its end, for a BASIC program: RUN,
//    until Return is pressed.
//  - nothing in the middle of a load, in BBC BASIC mode, or for a tape whose
//    first block has no Atom header.
//
//  tape_status (clk_sys) packs everything into one word and hands it to
//  tape_overlay (the video clock) with a toggle handshake. The overlay is
//  mixed in after the machine and before video_mixer; it never changes the
//  machine.
//============================================================================

`define TH_RETURN 8'h01
`define TH_PLAY   8'h03

module tape_status #(
	parameter integer CHARS = 26
)(
	input              clk,
	input              loaded,
	input              playing,
	input              fast,
	input       [31:0] played,               // ticks
	input       [31:0] total,                // ticks
	input              at_start,
	input              file_end,
	input              hdr_ok,
	input      [103:0] hdr_name,
	input        [3:0] hdr_len,
	input       [15:0] hdr_exec,
	input              hooked,               // the AtoMMC ROM has the LOAD vector
	input              bbc,                  // BBC BASIC mode: no hint
	input       [10:0] ps2_key,

	output reg [CHARS*16+48:0] status,      // held while req != ack
	output reg         req,
	input              ack
);
localparam integer TPS = 4808;              // ticks per tape second

function automatic [15:0] bcd_tick(input [15:0] t);
	reg [15:0] n;
	n = t;
	if (t == 16'h9959) bcd_tick = t;
	else begin
		if (t[3:0] != 4'd9) n[3:0] = t[3:0] + 4'd1;
		else begin
			n[3:0] = 0;
			if (t[7:4] != 4'd5) n[7:4] = t[7:4] + 4'd1;
			else begin
				n[7:4] = 0;
				if (t[11:8] != 4'd9) n[11:8] = t[11:8] + 4'd1;
				else begin n[11:8] = 0; n[15:12] = t[15:12] + 4'd1; end
			end
		end
		bcd_tick = n;
	end
endfunction

reg [15:0] elapsed = 0, tot = 0;
reg [12:0] frac = 0;
reg [31:0] last_played = 0, last_total = 0, rem = 0, cellc = 0;
reg  [6:0] fill = 0;
reg        computing = 0;
reg  [1:0] ack_s = 0;
wire [31:0] cell_ticks = total[31:6] == 0 ? 32'd1 : {6'd0, total[31:6]};

always @(posedge clk) begin
	last_played <= played;
	if (played == 0 || played < last_played) begin
		elapsed <= 0; frac <= 0; fill <= 0; cellc <= 0;
	end
	else if (played != last_played) begin
		if (frac == TPS - 1) begin frac <= 0; elapsed <= bcd_tick(elapsed); end
		else frac <= frac + 1'd1;
		if (cellc + 1'd1 >= cell_ticks) begin cellc <= 0; if (fill != 7'd64) fill <= fill + 1'd1; end
		else cellc <= cellc + 1'd1;
	end
	last_total <= total;
	if (total != last_total) begin rem <= total; tot <= 0; computing <= 1'b1; end
	else if (computing) begin
		if (rem >= TPS) begin rem <= rem - TPS; tot <= bcd_tick(tot); end
		else computing <= 1'b0;
	end
end

//----------------------------------------------------------------------------
// The hint
//----------------------------------------------------------------------------
wire basic = hdr_exec == 16'hC2B2;
reg  run_done = 0;                           // RUN was typed (Return) after the load
reg  old_key = 0;
always @(posedge clk) begin
	old_key <= ps2_key[10];
	if (at_start) run_done <= 1'b0;
	else if (ps2_key[10] != old_key && ps2_key[9] && ps2_key[8:0] == 9'h05A && file_end) run_done <= 1'b1;
end

wire load_hint = loaded && hdr_ok && !bbc && at_start && !playing;
wire run_hint  = loaded && hdr_ok && !bbc && basic && file_end && !playing && !run_done;
wire hint_show = load_hint || run_hint;
wire hint_two  = load_hint;

// "TYPE LOAD"NAME" <ret>" / "TYPE *RUN"NAME" <ret>": 13 + name characters
function automatic [7:0] cmd_char(input [4:0] i);
	reg [7:0] c;
	c = " ";
	if (i < 5'd5) c = "TYPE "  >> (8 * (4 - i));
	else if (i < 5'd10) c = (basic ? "LOAD\"" : "*RUN\"") >> (8 * (9 - i));
	else if (i < 5'd10 + hdr_len) c = (hdr_name << (8 * (i - 5'd10))) >> 96;   // a shift: Quartus checks part-select ranges even where the guard excludes them
	else if (i == 5'd10 + hdr_len) c = "\"";
	else if (i == 5'd12 + hdr_len) c = `TH_RETURN;
	cmd_char = c;
endfunction
localparam [8*22-1:0] L_CTRL = "PRESS F11 (CTRL-BREAK)";
localparam [8*21-1:0] L_KEY  = "AT PLAY TAPE: ANY KEY";
localparam [8*10-1:0] L_RUN  = {"TYPE RUN ", `TH_RETURN};   // 10 (no "\001" escape: Quartus reads it as four characters)

reg [8*CHARS-1:0] line1, line2;
reg [4:0] hint_len;
integer i;
always @(*) begin
	line1 = {CHARS{8'h20}};
	line2 = {CHARS{8'h20}};
	for (i = 0; i < CHARS; i = i + 1) begin
		if (load_hint && hooked) begin
			if (i < 22) line1[8*(CHARS-1-i) +: 8] = L_CTRL[8*(21-i) +: 8];
			line2[8*(CHARS-1-i) +: 8] = cmd_char(i[4:0]);
		end
		else if (load_hint) begin
			line1[8*(CHARS-1-i) +: 8] = cmd_char(i[4:0]);
			if (i < 21) line2[8*(CHARS-1-i) +: 8] = L_KEY[8*(20-i) +: 8];
		end
		else if (i < 10) line1[8*(CHARS-1-i) +: 8] = L_RUN[8*(9-i) +: 8];
	end
	hint_len = !load_hint ? 5'd10 : (5'd13 + hdr_len > 5'd22) ? 5'd13 + hdr_len : 5'd22;
end

wire [CHARS*16+48:0] pack = {hint_two, hint_show, hint_len, line1, line2, loaded, playing, fast, fill, elapsed, tot};

always @(posedge clk) begin
	ack_s <= {ack_s[0], ack};
	if (req == ack_s[1] && pack != status) begin
		status <= pack;
		req <= !req;
	end
end
initial begin status = 0; req = 0; end

endmodule

module tape_overlay #(
	parameter integer CHARS = 26,
	parameter [3:0]   FACTOR = 4'd4          // shown as "x4" while turbo is on
)(
	input                      clk,          // video clock
	input                      ce_pix,
	input                      hblank, vblank,
	input                      enable,       // OSD Tape overlay: On
	input      [CHARS*16+48:0] status,
	input                      req,
	output reg                 ack,
	input               [23:0] rgb_in,
	output reg          [23:0] rgb_out
);
`include "tape_font.vh"

reg  [1:0] req_s = 0;
reg  [CHARS*16+48:0] shown = 0;
reg [10:0] x = 0, width = 0;
reg  [9:0] y = 0, height = 0;
reg        line_active = 0, old_hb = 0, old_vb = 0;
initial ack = 0;

always @(posedge clk) begin
	req_s <= {req_s[0], req};
	if (req_s[1] != ack) begin shown <= status; ack <= req_s[1]; end
	if (ce_pix) begin
		old_hb <= hblank; old_vb <= vblank;
		if (!hblank && !vblank) begin x <= x + 1'd1; line_active <= 1'b1; end
		if (hblank && !old_hb) begin
			if (line_active) begin width <= x; y <= y + 1'd1; end
			x <= 0; line_active <= 0;
		end
		if (vblank && !old_vb) begin height <= y; y <= 0; end
	end
end

localparam integer W = CHARS * 8;
// {hint_two, hint_show, hint_len[4:0], line1, line2, loaded, playing, fast, fill[6:0], elapsed, total}
wire            hint_two  = shown[CHARS*16+48];
wire            hint_show = shown[CHARS*16+47];
wire      [4:0] hint_len  = shown[CHARS*16+46 -: 5];
wire [W-1:0]    line1     = shown[CHARS*16+41 -: W];
wire [W-1:0]    line2     = shown[CHARS*8+41 -: W];
wire            tape_bar  = enable && shown[41] && shown[40];
wire            hint      = enable && hint_show && !tape_bar;
wire            visible   = tape_bar || hint;
wire            fast      = shown[39];
wire      [6:0] fill      = shown[38:32];
wire     [15:0] el        = shown[31:16];
wire     [15:0] total     = shown[15:0];

// Double on wide or tall pictures (never at the Atom's 256x192).
wire        sx = width >= 11'd512, sy = height >= 10'd300;
wire  [4:0] chars = tape_bar ? 5'd21 : hint_len;
wire [10:0] box_w = {3'd0, chars, 3'd0} + 11'd4;
wire  [9:0] box_h = tape_bar ? 10'd18 : hint_two ? 10'd22 : 10'd12;
wire [10:0] x0 = 11'd4;
wire  [9:0] y0 = height - (sy ? {box_h[8:0], 1'b0} : box_h) - 10'd4;
wire [10:0] dx = x - x0;
wire  [9:0] dy = y - y0;
wire [10:0] lx = sx ? {1'b0, dx[10:1]} : dx;
wire  [9:0] ly = sy ? {1'b0, dy[9:1]} : dy;
wire        in_box = x >= x0 && y >= y0 && lx < box_w && ly < box_h;

wire [10:0] tx = lx - 11'd2;
wire        second = hint && hint_two && ly >= 10'd12;
wire  [9:0] ty = ly - (second ? 10'd12 : 10'd2);
wire  [4:0] col = tx[7:3];

function automatic [7:0] digit(input [3:0] d, input blank_zero);
	digit = (blank_zero && d == 0) ? 8'h20 : 8'h30 + d;
endfunction

reg [7:0] ch;
always @(*) begin
	ch = " ";
	if (!tape_bar) ch = second ? line2[W-1 - 8*col -: 8] : line1[W-1 - 8*col -: 8];
	else case (col)
		5'd0: ch = "T"; 5'd1: ch = "A"; 5'd2: ch = "P"; 5'd3: ch = "E";
		5'd5: ch = `TH_PLAY;
		5'd7: ch = digit(el[15:12], 1'b1);   5'd8: ch = digit(el[11:8], 1'b0);
		5'd9: ch = ":";
		5'd10: ch = digit(el[7:4], 1'b0);    5'd11: ch = digit(el[3:0], 1'b0);
		5'd12: ch = "/";
		5'd13: ch = digit(total[15:12], 1'b1); 5'd14: ch = digit(total[11:8], 1'b0);
		5'd15: ch = ":";
		5'd16: ch = digit(total[7:4], 1'b0); 5'd17: ch = digit(total[3:0], 1'b0);
		5'd19: ch = fast ? "X" : " ";
		5'd20: ch = fast ? digit(FACTOR, 1'b0) : " ";
		default: ch = " ";
	endcase
end

// ASCII to the 6847's codes (@ A-Z [ \ ] ^ <- at 00-1F, space to ? at 20-3F);
// the Return and play signs are drawn here.
function automatic [7:0] glyph(input [7:0] c, input [2:0] r);
	reg [63:0] g;
	if (c == `TH_RETURN) begin g = 64'h0002022262FE6020; glyph = g[63 - 8*r -: 8]; end
	else if (c == `TH_PLAY) begin g = 64'h4060707870604000; glyph = g[63 - 8*r -: 8]; end
	else if (c >= 8'h40 && c < 8'h60) glyph = tape_font({1'b0, c[4:0]}, r);
	else if (c >= 8'h20 && c < 8'h40) glyph = tape_font({1'b1, c[4:0]}, r);
	else glyph = 8'h00;
endfunction

wire [7:0] grow = glyph(ch, ty[2:0]);
wire text_on  = ty < 10'd8 && tx < {3'd0, chars, 3'd0} && grow[3'd7 - tx[2:0]];
wire bar_area = tape_bar && ly >= 10'd12 && ly < 10'd16 && lx >= 11'd2 && lx < 11'd130;
wire bar_on   = bar_area && (lx - 11'd2) < {3'd0, fill, 1'b0};

always @(*) begin
	rgb_out = rgb_in;
	if (visible && in_box)
		rgb_out = text_on ? 24'hFFFFFF : bar_on ? 24'h44CC44 : bar_area ? 24'h333333 : 24'h000000;
end

endmodule
