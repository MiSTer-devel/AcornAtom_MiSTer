// GODIL VGA80x40 text mode (#BDE0 bit 7) at 15 kHz.
//
// The registers and the screen follow AtomGodilVideo's VGA80x40 (the GODIL
// wiki, refs/video/AtomGodilVideo.wiki/GODIL-memory-map-and-register-
// description.md, and the controller src/VGA80x40/vga80x40.vhd by Javier
// Valcarce Garcia, LGPL): 80x40 characters of 8x12 pixels, the characters at
// #8000-#8C7F and their attributes at #8C80-#98FF of the 6847's video RAM,
// the glyphs from the 6847's character ROM (bit 7 inverts), a hardware
// cursor (#BDE2 column, #BDE3 row) and the two control registers #BDE4/#BDE5.
//
// Upstream draws it as 640x480 VGA (31 kHz, 25 MHz). This core keeps the
// 6847's 15 kHz line instead: 640x480 interlaced, 910 clocks a line at
// 14.318 MHz (the 6847's 455 at 7.16 MHz), 525 lines in two fields of
// 262.5. Every CRT the 6847 picture runs on shows it, and MiSTer's scaler
// weaves the two fields (field, VGA_F1) into one 640x480 frame.
//
// Fetch: character k is read during the 8 pixels before it is shown.
// The video RAM and the character ROM answer within one pixel (3 clk).

module godil_vga80
(
	input             clk,        // clk_vid, 42.954545 MHz
	input             ce,         // 14.318 MHz: one pixel
	input             reset,

	input       [7:0] ocrx,       // #BDE2 cursor column
	input       [7:0] ocry,       // #BDE3 cursor row
	input       [7:0] octl,       // #BDE4 control 1
	input       [7:0] octl2,      // #BDE5 control 2

	output reg [12:0] ram_addr,   // video RAM (6847 side), data one ce later
	input       [7:0] ram_data,
	output reg [11:0] font_addr,  // character ROM, data one ce later
	input       [7:0] font_data,

	output reg        r, g, b,
	output reg        hsync,      // active low, as the 6847's
	output reg        vsync,      // active low
	output reg        hblank,
	output reg        vblank,
	output reg        field       // 1 = the top field (even picture lines)
);

localparam H_LINE   = 910;
localparam H_SYNC   = 67;         // 4.7 us
localparam H_ACT    = 194;        // centred on the 6847's picture (clock 258 of 910)
localparam H_END    = H_ACT + 640;
localparam H_FETCH  = H_ACT - 8;  // character 0's fetch starts here
localparam V_ACT    = 240;        // picture lines a field
localparam V_VS     = 245;        // vsync line (bottom field: at the line start,
                                  // top field: half a line later)

reg  [9:0] hc;
reg  [8:0] vc;
reg        top;                   // this field is the top one (263 lines)

// Picture position: row and line within the character for this line.
reg  [3:0] chry;                  // 0..11
reg [12:0] row_base;              // row * 80
reg  [5:0] row;                   // 0..39

// Fetch pipeline
reg  [9:0] fx;                    // pixel within the fetch window
wire [2:0] sub = fx[2:0];
wire [6:0] col = fx[9:3];
reg        fetching;
reg  [7:0] chr, attr_t;
reg  [7:0] font_l;

// Shifter for the character on screen
reg  [7:0] sh;
reg  [7:0] attr, data;
reg  [6:0] col_s;
reg  [2:0] px;                    // pixel within the shown character
reg        shown;                 // a character is in the shifter

// Cursor blink: about 3 Hz (10 fields on, 10 off), as upstream's 2.98 Hz.
reg  [4:0] blink_cnt;
reg        blink;

wire vga_en    = octl[7];
wire cur_en    = octl[6];
wire cur_blink = octl[5];
wire cur_large = octl[4];         // the wiki says bit 4 = 1 large; upstream's
                                  // code draws the block when it is 0: follow it
wire ctl_attr  = octl[3];

wire h_vis = hc >= H_ACT && hc < H_END;
wire v_vis = vc < V_ACT;

always @(posedge clk) begin
	if (reset) begin
		hc <= 0; vc <= 0; top <= 1;
		chry <= 0; row <= 0; row_base <= 0;
		fetching <= 0; shown <= 0;
		blink_cnt <= 0; blink <= 0;
		hsync <= 1; vsync <= 1; hblank <= 1; vblank <= 1; field <= 1;
		{r, g, b} <= 0;
	end
	else if (ce) begin
		// counters
		if (hc == H_LINE - 1) begin
			hc <= 0;
			if (vc == (top ? 9'd262 : 9'd261)) begin
				vc <= 0;
				top <= ~top;
				// the top field shows picture lines 0, 2, 4 ...; the bottom 1, 3, 5 ...
				chry <= top ? 4'd1 : 4'd0;
				row <= 0;
				row_base <= 0;
				if (blink_cnt == 9) begin blink_cnt <= 0; blink <= ~blink; end
				else blink_cnt <= blink_cnt + 1'd1;
			end
			else begin
				vc <= vc + 1'd1;
				if (v_vis) begin
					// next picture line of this field: two down
					if (chry >= 10) begin
						chry <= chry - 4'd10;
						row <= row + 1'd1;
						row_base <= row_base + 13'd80;
					end
					else chry <= chry + 4'd2;
				end
			end
		end
		else hc <= hc + 1'd1;

		// fetch: sub 0 the character, 1 its attribute, 2 the glyph line
		if (hc == H_FETCH - 1) begin fetching <= v_vis; fx <= 0; end
		else if (fetching) begin
			if (fx == 639) fetching <= 0;
			fx <= fx + 1'd1;
		end

		if (fetching) begin
			case (sub)
				0: ram_addr <= row_base + col;
				1: begin
					chr <= ram_data;
					ram_addr <= row_base + col + 13'd3200;
					font_addr <= {1'b0, ram_data[6:0], chry};
				end
				2: attr_t <= ram_data;
				3: font_l <= font_data;
				default: ;
			endcase
		end

		// the shifter: load at the end of each fetch, shift while shown
		if (fetching && sub == 7) begin
			sh <= font_l ^ {8{chr[7]}};
			data <= chr;
			attr <= attr_t;
			col_s <= col;
			px <= 0;
			shown <= 1;
		end
		else begin
			sh <= {sh[6:0], 1'b0};
			px <= px + 1'd1;
			if (px == 7) shown <= 0;
		end

		// the pixel (registered, with its syncs)
		begin : pixel
			reg y, ys, yu, ya, cur;
			cur = cur_en && (blink || !cur_blink) && col_s == ocrx[6:0] && row == ocry[5:0]
			      && (!cur_large || chry > 8);
			y  = sh[7] ^ cur;
			yu = (attr[3] && chry == 10) ? ~y : y;
			case ({chry >= 8, chry >= 4})
				2'b11:   ys = px >= 4 ? data[0] : data[1];
				2'b01:   ys = px >= 4 ? data[2] : data[3];
				default: ys = px >= 4 ? data[4] : data[5];
			endcase
			ya = attr[7] ? ys : yu;
			if (h_vis && v_vis && shown && vga_en) begin
				if (ctl_attr) {r, g, b} <= ya ? attr[2:0] : attr[6:4];
				else          {r, g, b} <= y ? octl[2:0] : octl2[2:0];
			end
			else {r, g, b} <= 0;
		end

		hsync  <= ~(hc < H_SYNC);
		hblank <= ~h_vis;
		vblank <= ~v_vis;
		field  <= top;
		// vsync: 3 lines; the bottom field's starts with a line, the top
		// field's half a line later, so the fields sit 262.5 lines apart
		if (top) begin
			if (vc == V_VS && hc == H_LINE/2 - 1) vsync <= 0;
			else if (vc == V_VS + 3 && hc == H_LINE/2 - 1) vsync <= 1;
		end
		else begin
			if (vc == V_VS - 1 && hc == H_LINE - 1) vsync <= 0;
			else if (vc == V_VS + 2 && hc == H_LINE - 1) vsync <= 1;
		end
	end
end

endmodule
