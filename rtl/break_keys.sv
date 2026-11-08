// BREAK, Shift-BREAK and Ctrl-BREAK, from the OSD buttons and from the keyboard.
// OSD BREAK (P1, T[15]), Shift-BREAK (T[20]) and Ctrl-BREAK (T[21]): Main pulses
// the status bit; hold the machine's BREAK line for 150 ms, as long as a key
// press. BREAK also resets the AtoMMC's AVR, and a short reset lets the 6502 ask
// the AVR for its configuration byte before the AVR is back: it then reads a
// stale value and auto-runs *MENU. SHIFT or CTRL stays down 500 ms longer: the
// kernel and the AtoMMC ROM read them after BREAK ends (Shift-BREAK runs the
// AtoMMC menu, Ctrl-BREAK starts without the AtoMMC ROM, for the tape).
//
// The same from the keyboard: F9 = Shift-BREAK, F11 = Ctrl-BREAK (Main lets both
// through outside the OSD), and F10 = BREAK as before (rtl/keyboard.sv). When F10
// is released with Ctrl or Shift down, that key is held on for 500 ms here, so
// the kernel sees it however quickly the keys are let go.
module break_keys
(
	input             clk_sys,          // 31.5 MHz (the hold times are counted in it)
	input             btn_break,        // OSD buttons (status bits, levels)
	input             btn_shift_break,
	input             btn_ctrl_break,
	input      [10:0] ps2_key,
	output            osd_break,        // to the core: BREAK held
	output            osd_shift,        // SHIFT held
	output            osd_ctrl          // CTRL held
);
reg [22:0] break_cnt = 0;
reg [24:0] mod_cnt = 0;
reg        mod_shift = 0, mod_ctrl = 0;
reg  [2:0] old_btn = 0;
reg        old_ps2 = 0;
reg        kb_ctrl = 0, kb_shift = 0;
wire       ps2_new  = ps2_key[10] != old_ps2;
wire       ps2_down = ps2_new && ps2_key[9];
wire       key_f9   = ps2_down && ps2_key[8:0] == 9'h001;
wire       key_f11  = ps2_down && ps2_key[8:0] == 9'h078;
wire       f10_up   = ps2_new && !ps2_key[9] && ps2_key[8:0] == 9'h009;
always @(posedge clk_sys) begin
	old_btn <= {btn_ctrl_break, btn_shift_break, btn_break};
	old_ps2 <= ps2_key[10];
	if (ps2_new && (ps2_key[7:0] == 8'h14)) kb_ctrl <= ps2_key[9];                          // either Ctrl
	if (ps2_new && !ps2_key[8] && (ps2_key[7:0] == 8'h12 || ps2_key[7:0] == 8'h59)) kb_shift <= ps2_key[9];
	if ((btn_break && !old_btn[0]) || (btn_shift_break && !old_btn[1]) || (btn_ctrl_break && !old_btn[2]) || key_f9 || key_f11) begin
		break_cnt <= 23'd4725000;
		mod_cnt   <= 25'd20475000;          // 650 ms
		mod_shift <= (btn_shift_break && !old_btn[1]) || key_f9;
		mod_ctrl  <= (btn_ctrl_break && !old_btn[2]) || key_f11;
	end
	else if (f10_up && (kb_ctrl || kb_shift)) begin
		mod_cnt   <= 25'd15750000;          // 500 ms after F10 is let go
		mod_shift <= kb_shift;
		mod_ctrl  <= kb_ctrl;
	end
	else begin
		if (break_cnt) break_cnt <= break_cnt - 1'd1;
		if (mod_cnt) mod_cnt <= mod_cnt - 1'd1;
		else begin mod_shift <= 1'b0; mod_ctrl <= 1'b0; end
	end
end
assign osd_break = |break_cnt;
assign osd_shift = mod_shift;
assign osd_ctrl  = mod_ctrl;

endmodule
