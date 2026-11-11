// Dave Wood 2020
//
// PS/2 keyboard (MiSTer's ps2_key) to the Atom's 10x6 key matrix, plus the
// SHIFT, CTRL, REPEAT and BREAK lines, the turbo keys F1-F4 and the joysticks.
// After https://github.com/hoglet67/AtomFpga/blob/e72d68a968c0833ed34a4582b6c9f1b58265f5fc/src/ps2kybrd/keyboard.vhd
//
// layout: 0 PC (UK), 1 PC (US), 2 Atom (original), 3 Atom (game: Shift and
// Ctrl swapped). The PC layouts type what is printed on the PC key, so a key
// can sit at a different matrix position, and need the other Shift state on
// the Atom, depending on whether Shift is held. The Atom layouts put each Atom
// key at one PC key whatever Shift does.

module keyboard
(
	input			 	clk,
	input				clk_en,
	input			 	reset,
	input		[1:0]	layout,
	input		[1:0]	turbo_default,  // CPU speed at reset (OSD); F1-F4 change it live
	input  		[10:0]	ps2_key,
	input	 	[3:0]	row,
	input		[15:0]	joy1,
	input		[15:0]	joy2,
	output reg 	[5:0]	keyout,
	output reg			shift_out,
	output reg			ctrl_out,
	output reg			repeat_out,
	output reg			break_out,
	output reg	[1:0]	turbo = 2'b00
);

localparam UK = 2'b00, US = 2'b01, ORIG = 2'b10, GAME = 2'b11;
wire pc_layout = ~layout[1];

reg  [8:0]	code;			// {extended, scan code}
reg			key_press;
reg			key_strobe = 1'b0;
reg  [5:0]	keys [0:9];		// the matrix, active low
reg			shift_press = 1'b1;	// the PC's Shift keys, active low
reg			left_alt;		// PC layouts: Left Alt is an extra Shift for ^ @ and 0

always @(posedge clk) if (clk_en) begin
	reg old_state;

	key_strobe 	<= 1'b0;
	old_state 	<= ps2_key[10];
	if (old_state != ps2_key[10]) begin
		key_press 	<= ps2_key[9];
		code 		<= ps2_key[8:0];
		key_strobe 	<= 1'b1;
	end
end

// Each layout has two tables, Shift up and Shift down. A key is released
// through the table it was pressed through: choosing by Shift's state at the
// release left a key down in the other table when Shift was let go first
// (Shift, ' down, Shift up, ' up left " held: everything typed after it came
// out wrong, ERROR 94).
reg  [511:0]	press_shifted = 512'd0;
wire			unshifted = key_press ? shift_press : ~press_shifted[code];
always @(posedge clk) if (key_strobe && clk_en && key_press) press_shifted[code] <= ~shift_press;

// ---------------------------------------------------------------------------
// The tables. Each entry gives the key's matrix position and, for some PC
// keys, the Atom's SHIFT line while the key is down (SH = shifted, NS = not
// shifted; without one the line follows the Shift keys).
//
//   row  col 0          1        2      3      4  5
//    9   SPACE          -        4 $    . >    H  R
//    8   [              -        5 %    / ?    I  S
//    7   backslash      -        6 &    @      J  T
//    6   ]              RETURN   7 '    A      K  U
//    5   ^              COPY     8 (    B      L  V
//    4   LOCK           DELETE   9 )    C      M  W
//    3   RIGHT/LEFT     0        : *    D      N  X
//    2   UP/DOWN        1 !      ; +    E      O  Y
//    1   -              2 "      , <    F      P  Z
//    0   -              3 #      - =    G      Q  ESC
// The two cursor keys give RIGHT and UP, and LEFT and DOWN with SHIFT.
// ---------------------------------------------------------------------------

localparam [1:0] FOLLOW = 2'b00, NS = 2'b11, SH = 2'b10;

// {hit, shift override (enable, SHIFT line value), row, column}
function automatic [9:0] K(input [3:0] r, input [2:0] c, input [1:0] sh);
	K = {1'b1, sh, r, c};
endfunction

// The same in every layout and Shift state.
function automatic [9:0] common_key(input [8:0] c);
	casex (c)
	'h029: common_key = K(9,0,FOLLOW);  // space
	'h054: common_key = K(8,0,FOLLOW);  // [
	'h05B: common_key = K(6,0,FOLLOW);  // ]
	'h058: common_key = K(4,0,FOLLOW);  // LOCK (Caps Lock)
	'hx74: common_key = K(3,0,FOLLOW);  // RIGHT
	'hx75: common_key = K(2,0,FOLLOW);  // UP
	'h05A: common_key = K(6,1,FOLLOW);  // RETURN
	'h066: common_key = K(4,1,FOLLOW);  // DELETE (Backspace)
	'h016: common_key = K(2,1,FOLLOW);  // 1
	'h025: common_key = K(9,2,FOLLOW);  // 4
	'h02E: common_key = K(8,2,FOLLOW);  // 5
	'h041: common_key = K(1,2,FOLLOW);  // ,
	'h049: common_key = K(9,3,FOLLOW);  // .
	'h04A: common_key = K(8,3,FOLLOW);  // /
	'h01C: common_key = K(6,3,FOLLOW);  // A
	'h032: common_key = K(5,3,FOLLOW);  // B
	'h021: common_key = K(4,3,FOLLOW);  // C
	'h023: common_key = K(3,3,FOLLOW);  // D
	'h024: common_key = K(2,3,FOLLOW);  // E
	'h02B: common_key = K(1,3,FOLLOW);  // F
	'h034: common_key = K(0,3,FOLLOW);  // G
	'h033: common_key = K(9,4,FOLLOW);  // H
	'h043: common_key = K(8,4,FOLLOW);  // I
	'h03B: common_key = K(7,4,FOLLOW);  // J
	'h042: common_key = K(6,4,FOLLOW);  // K
	'h04B: common_key = K(5,4,FOLLOW);  // L
	'h03A: common_key = K(4,4,FOLLOW);  // M
	'h031: common_key = K(3,4,FOLLOW);  // N
	'h044: common_key = K(2,4,FOLLOW);  // O
	'h04D: common_key = K(1,4,FOLLOW);  // P
	'h015: common_key = K(0,4,FOLLOW);  // Q
	'h02D: common_key = K(9,5,FOLLOW);  // R
	'h01B: common_key = K(8,5,FOLLOW);  // S
	'h02C: common_key = K(7,5,FOLLOW);  // T
	'h03C: common_key = K(6,5,FOLLOW);  // U
	'h02A: common_key = K(5,5,FOLLOW);  // V
	'h01D: common_key = K(4,5,FOLLOW);  // W
	'h022: common_key = K(3,5,FOLLOW);  // X
	'h035: common_key = K(2,5,FOLLOW);  // Y
	'h01A: common_key = K(1,5,FOLLOW);  // Z
	'h076: common_key = K(0,5,FOLLOW);  // ESCAPE
	default: common_key = 10'd0;
	endcase
endfunction

// Atom layouts (original and game), either Shift state: the Atom's keys by
// position, Shift passed through.
function automatic [9:0] atom_key(input [8:0] c);
	casex (c)
	'h00D: atom_key = K(5,0,FOLLOW);  // ^ (Tab)
	'h05D: atom_key = K(7,0,FOLLOW);  // backslash
	'hx69: atom_key = K(5,1,FOLLOW);  // COPY (End)
	'h045: atom_key = K(3,1,FOLLOW);  // 0
	'h01E: atom_key = K(1,1,FOLLOW);  // 2
	'h026: atom_key = K(0,1,FOLLOW);  // 3
	'h036: atom_key = K(7,2,FOLLOW);  // 6
	'h03D: atom_key = K(6,2,FOLLOW);  // 7
	'h03E: atom_key = K(5,2,FOLLOW);  // 8
	'h046: atom_key = K(4,2,FOLLOW);  // 9
	'h052: atom_key = K(3,2,FOLLOW);  // : (')
	'h04C: atom_key = K(2,2,FOLLOW);  // ;
	'h04E: atom_key = K(0,2,FOLLOW);  // -
	'h055: atom_key = K(7,3,FOLLOW);  // @ (=)
	default: atom_key = common_key(c);
	endcase
endfunction

// PC layouts, Shift up. The Atom's unshifted key where the PC's is the same,
// else the shifted Atom key that prints the same thing.
function automatic [9:0] pc_key_unshifted(input uk, input [8:0] c);
	casex (c)
	'h05D: pc_key_unshifted = uk ? K(0,1,SH)       // UK #  = Atom Shift 3
	                             : K(7,0,FOLLOW);  // US backslash
	'h056,
	'h061: pc_key_unshifted = uk ? K(7,0,FOLLOW)   // UK backslash (two scan codes)
	                             : 10'd0;
	'hx6B: pc_key_unshifted = K(3,0,SH);  // LEFT  = Atom Shift LEFT/RIGHT
	'hx72: pc_key_unshifted = K(2,0,SH);  // DOWN  = Atom Shift UP/DOWN
	'h00D: pc_key_unshifted = K(5,1,FOLLOW);  // COPY (Tab)
	'h045: pc_key_unshifted = K(3,1,FOLLOW);  // 0
	'h00E: pc_key_unshifted = uk ? K(2,1,FOLLOW)   // ` types 1 (UK) or 2 (US): which layout is on
	                             : K(1,1,FOLLOW);
	'h01E: pc_key_unshifted = K(1,1,FOLLOW);  // 2
	'h026: pc_key_unshifted = K(0,1,FOLLOW);  // 3
	'h036: pc_key_unshifted = K(7,2,FOLLOW);  // 6
	'h03D: pc_key_unshifted = K(6,2,FOLLOW);  // 7
	'h052: pc_key_unshifted = K(6,2,SH);      // '  = Atom Shift 7
	'h03E: pc_key_unshifted = K(5,2,FOLLOW);  // 8
	'h046: pc_key_unshifted = K(4,2,FOLLOW);  // 9
	'h04C: pc_key_unshifted = K(2,2,FOLLOW);  // ;
	'h04E: pc_key_unshifted = K(0,2,FOLLOW);  // -
	'h055: pc_key_unshifted = K(0,2,SH);      // =  = Atom Shift -
	default: pc_key_unshifted = common_key(c);
	endcase
endfunction

// PC layouts, Shift down. alt is Left Alt, which shifts ^ @ and 0 again.
function automatic [9:0] pc_key_shifted(input uk, input alt, input [8:0] c);
	casex (c)
	'h05D: pc_key_shifted = uk ? 10'd0            // UK ~ : none
	                           : K(7,0,FOLLOW);   // US | (Shift backslash)
	'h056,
	'h061: pc_key_shifted = uk ? K(7,0,FOLLOW)    // UK |
	                           : 10'd0;
	'h036: pc_key_shifted = K(5,0,alt ? SH : NS); // ^ (Shift 6)
	'hx74: pc_key_shifted = K(3,0,NS);  // Shift RIGHT = Atom RIGHT
	'hx6B: pc_key_shifted = K(3,0,FOLLOW);  // Shift LEFT
	'hx75: pc_key_shifted = K(2,0,NS);  // Shift UP = Atom UP/DOWN unshifted
	'hx72: pc_key_shifted = K(2,0,FOLLOW);  // Shift DOWN
	'h00D: pc_key_shifted = K(5,1,FOLLOW);  // COPY (Tab)
	'h052: pc_key_shifted = uk ? K(7,3,alt ? SH : NS)   // UK @ (Shift ')
	                           : K(1,1,FOLLOW);       // US " (Shift ')
	'h01E: pc_key_shifted = uk ? K(1,1,FOLLOW)        // UK " (Shift 2)
	                           : K(7,3,alt ? SH : NS); // US @ (Shift 2)
	'h026: pc_key_shifted = uk ? 10'd0                // UK pound: none
	                           : K(0,1,FOLLOW);       // US # (Shift 3)
	'h03D: pc_key_shifted = K(7,2,FOLLOW);  // & (Shift 7) = Atom Shift 6
	'h046: pc_key_shifted = K(5,2,FOLLOW);  // ( (Shift 9) = Atom Shift 8
	'h045: pc_key_shifted = alt ? K(3,1,FOLLOW)       // Alt Shift 0: Atom Shift 0
	                            : K(4,2,FOLLOW);      // ) (Shift 0) = Atom Shift 9
	'h03E: pc_key_shifted = K(3,2,FOLLOW);  // * (Shift 8) = Atom Shift :
	'h04C: pc_key_shifted = K(3,2,NS);      // : (Shift ;) = Atom :
	'h055: pc_key_shifted = K(2,2,FOLLOW);  // + (Shift =) = Atom Shift ;
	'h04E,
	'h00E: pc_key_shifted = 10'd0;          // _ and ~: none
	default: pc_key_shifted = common_key(c);
	endcase
endfunction

wire [9:0] key = !pc_layout ? atom_key(code)
               : unshifted  ? pc_key_unshifted(layout == UK, code)
               :              pc_key_shifted(layout == UK, left_alt, code);
wire       key_hit    = key[9];
wire [1:0] key_shift  = key[8:7];
wire [3:0] key_row    = key[6:3];
wire [2:0] key_col    = key[2:0];

// Modifier keys. The game layout swaps Left Shift and Left Ctrl; the original
// layout has REPEAT on Left Alt, the others on Right Alt.
wire is_shift  = code == 'h059 || code == (layout == GAME ? 9'h014 : 9'h012);
wire is_ctrl   = code == 'h114 || code == (layout == GAME ? 9'h012 : 9'h014);
wire is_repeat = code == (layout == ORIG ? 9'h011 : 9'h111);

always @(posedge clk) begin
	if (reset) begin
		break_out  	<= 1'b1;
		shift_out  	<= 1'b1;
		shift_press <= 1'b1;
		ctrl_out   	<= 1'b1;
		repeat_out 	<= 1'b1;
		left_alt 	<= 1'b0;
		for (int i = 0; i < 10; i++) keys[i] <= 6'b111111;
		turbo      	<= turbo_default;
	end

	if (key_strobe && clk_en) begin
		case (code)
		'h005: turbo <= 2'b00;  // F1
		'h006: turbo <= 2'b01;  // F2
		'h004: turbo <= 2'b10;  // F3
		'h00C: turbo <= 2'b11;  // F4
		'h009: break_out <= ~key_press;  // F10 BREAK
		default: ;
		endcase
		if (is_repeat) repeat_out  <= ~key_press;
		if (is_shift)  shift_press <= ~key_press;
		if (is_ctrl)   ctrl_out    <= ~key_press;
		if (pc_layout && code == 'h011) left_alt <= key_press;

		if (key_hit) keys[key_row][key_col] <= ~key_press;

		// The Atom's SHIFT line. A Shift key drives it at once (the AtoMMC
		// menu's "down" and Centipede's fire are Shift alone). A key that needs
		// the other Shift state on the Atom (the cursor keys, PC " ' ^ ...)
		// forces it while down; any release gives it back to the Shift keys
		// (Down used to leave it held, and the AtoMMC menu kept scrolling).
		if (is_shift)
			shift_out <= ~key_press;
		else if (key_press && key_shift[1])
			shift_out <= key_shift[0];
		else
			shift_out <= shift_press;
	end
end

// The matrix as the 8255 reads it. joy1 and joy2 (active low) are ANDed into
// rows 0 and 1, bits 4..0: up, right, down, left, fire.
always @(*) begin
	if (row == 4'd0)
		keyout = keys[row] & {1'b1, joy1[3], joy1[0], joy1[2], joy1[1], joy1[4]};
	else if (row == 4'd1)
		keyout = keys[row] & {1'b1, joy2[3], joy2[0], joy2[2], joy2[1], joy2[4]};
	else
		keyout = keys[row];
end

endmodule
