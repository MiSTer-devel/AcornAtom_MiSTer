//============================================================================
//  CSW reader for the tape deck: a .csw (Compressed Square Wave, v1 or v2,
//  RLE or Z-RLE) is turned back into the Atom's bytes as it downloads and
//  written out as a small UEF, so the deck, the file table and the hint see
//  a UEF and need nothing else.
//
//  The pulses (half cycles) are sorted by length against the header's sample
//  rate: short (2400 Hz, under rate/3200), long (1200 Hz, under rate/1600),
//  or a gap. The Atom's bit is 1/300 s, 16 short halves for a 1 (eight 2400 Hz
//  cycles) or 8 long ones for a 0 (four 1200 Hz cycles); a byte is a 0 start
//  bit, eight bits LSB first, and a 1 stop bit. Counting in short halves (a
//  long one is two), a bit ends every 16, and it is a 1 if under half of it
//  was long.
//
//  Out: "UEF File!" and version 0.10, then for each run of bytes a &0110
//  carrier chunk (the tone before it, in 2400 Hz cycles) and a &0100 data
//  chunk. A run ends at 64 halves of carrier after a byte, at a gap, or at
//  BUFN bytes. The data waits in a buffer until its length is known.
//
//  Z-RLE is zlib: the two header bytes are taken off here and the DEFLATE
//  body goes to a second inflater (rtl/gunzip.sv, raw) with its own 32 KB
//  window; plain RLE goes through the same inflater as a copy.
//============================================================================

module csw_in
(
	input             clk,
	input             start,                 // a download begins
	input             in_wr,                 // the download's bytes (a CSW from the first)
	input       [7:0] in_data,
	input             in_end,                // the download is over (level)
	output            in_wait,

	output reg        out_wr,
	output reg [24:0] out_addr,
	output reg  [7:0] out_data,

	output            busy,
	output reg        err
);

localparam integer BUFN = 512;

// the header
reg  [6:0] hp;                               // header byte
reg  [7:0] major;
reg [31:0] rate;
reg  [7:0] comp, ext;
reg  [7:0] skip;                             // header extension, zlib header
reg        body, zhdr;
reg        run = 0;                          // a CSW so far
reg        bad;                              // not one, or one this cannot read

function automatic [7:0] magic(input [4:0] i);   // "Compressed Square Wave" 1A
	case (i)
	5'd0: magic = "C";  5'd1: magic = "o";  5'd2: magic = "m";  5'd3: magic = "p";
	5'd4: magic = "r";  5'd5: magic = "e";  5'd6: magic = "s";  5'd7: magic = "s";
	5'd8: magic = "e";  5'd9: magic = "d";  5'd10: magic = " "; 5'd11: magic = "S";
	5'd12: magic = "q"; 5'd13: magic = "u"; 5'd14: magic = "a"; 5'd15: magic = "r";
	5'd16: magic = "e"; 5'd17: magic = " "; 5'd18: magic = "W"; 5'd19: magic = "a";
	5'd20: magic = "v"; 5'd21: magic = "e"; default: magic = 8'h1A;
	endcase
endfunction

// the body goes to the inflater
reg        z_start, z_raw;
wire       z_wait, z_wr, z_busy, z_err;
wire [24:0] z_addr;
wire  [7:0] z_data;
wire [14:0] z_ra;
reg   [7:0] z_q;
reg   [7:0] win [0:32767];
always @(posedge clk) begin
	if (z_wr) win[z_addr[14:0]] <= z_data;
	z_q <= win[z_ra];
end

// the inflater's output, to the pulse reader
reg  [7:0] pf [0:7];
reg  [2:0] pf_wp = 0, pf_rp = 0;
reg  [3:0] pf_n = 0;
wire       z_stall = pf_n >= 4'd4;

gunzip #(.AW(15)) inflate (
	.clk(clk), .start(z_start), .raw(z_raw), .stall(z_stall),
	.in_wr(in_wr && body && !zhdr && skip == 0), .in_data(in_data), .in_end(in_end),
	.in_wait(z_wait),
	.out_wr(z_wr), .out_addr(z_addr), .out_data(z_data), .rd_addr(z_ra), .rd_data(z_q),
	.busy(z_busy), .gz(), .err(z_err)
);
assign in_wait = body && z_wait;

always @(posedge clk) begin
	z_start <= 1'b0;
	if (start) begin
		hp <= 0; body <= 1'b0; zhdr <= 1'b0; skip <= 0; run <= 1'b1; bad <= 1'b0;
	end
	else if (in_wr && !body) begin
		hp <= hp + 1'd1;
		if (hp < 7'd23 && in_data != magic(hp[4:0])) begin run <= 1'b0; bad <= 1'b1; end
		case (hp)
		7'd23: major <= in_data;
		7'd25: rate[7:0] <= in_data;
		7'd26: rate[15:8] <= in_data;
		default: ;
		endcase
		if (major == 8'd1) begin
			// v1: rate (16 bits), compression, flags, 3 reserved; the data at &20
			if (hp == 7'd25) rate[31:16] <= 0;
			if (hp == 7'd27) begin comp <= in_data; if (in_data != 8'd1) begin run <= 1'b0; bad <= 1'b1; end end
			// the inflater starts a byte early: bytes can come on every clock,
			// and a byte that arrives with its start is not taken
			if (hp == 7'd30 && run) begin z_start <= 1'b1; z_raw <= 1'b0; end
			if (hp == 7'd31 && run) body <= 1'b1;
		end
		else begin
			// v2: rate, pulses, compression, flags, extension length, encoder (16); the data at &34 + ext
			if (hp == 7'd27) rate[23:16] <= in_data;
			if (hp == 7'd28) rate[31:24] <= in_data;
			if (hp == 7'd33) begin
				comp <= in_data;
				if (in_data != 8'd1 && in_data != 8'd2) begin run <= 1'b0; bad <= 1'b1; end
			end
			if (hp == 7'd35) ext <= in_data;
			if (hp == 7'd50 && run && comp != 8'd2) begin z_start <= 1'b1; z_raw <= 1'b0; end
			if (hp == 7'd51 && run) begin
				body <= 1'b1; skip <= ext;
				zhdr <= comp == 8'd2;
			end
		end
	end
	else if (in_wr && skip != 0) skip <= skip - 1'd1;
	else if (in_wr && zhdr) begin
		// zlib: CMF (deflate, 32 KB window or less) then FLG; then the DEFLATE body
		if (hp == 7'd52) begin
			if (in_data[3:0] != 4'd8) begin run <= 1'b0; bad <= 1'b1; end
			else begin z_start <= 1'b1; z_raw <= 1'b1; end
		end
		hp <= hp + 1'd1;
		if (hp == 7'd53) zhdr <= 1'b0;
	end
end

//----------------------------------------------------------------------------
// Pulses, bits, bytes, and the UEF out
//----------------------------------------------------------------------------
reg  [7:0] buf_m [0:BUFN-1];
reg  [8:0] buf_ra;
reg  [7:0] buf_q;
always @(posedge clk) buf_q <= buf_m[buf_ra];

localparam W_HDR = 3'd0, W_RUN = 3'd1, W_TONE = 3'd2, W_DHDR = 3'd3, W_DAT = 3'd4, W_END = 3'd5;
reg  [2:0] w_st;
reg  [3:0] w_i;
reg  [9:0] w_j;
reg        w_ph;
reg        w_last;                           // the flush is the last thing

// RLE: a byte is a pulse, or 0 and four bytes of one
reg  [2:0] r_long;
reg [31:0] r_val;

// the demodulator
reg        d_frame;                          // inside a byte
reg  [4:0] d_u;                              // halves of this bit (short = 1, long = 2)
reg  [4:0] d_lu;                             // ... of them long
reg  [3:0] d_bit;
reg  [7:0] d_sh;
reg [16:0] d_tone;                           // short halves before the byte
reg  [6:0] d_quiet;                          // short halves since the last byte
reg        seg_open;
reg  [9:0] seg_n;
reg        flush, tone_req;                  // jobs for the writer
reg [15:0] tone_cyc;

wire       pf_any = pf_n != 0;
wire       idle_w = w_st == W_RUN && !flush && !tone_req;
wire       done_in = in_end && !z_busy && pf_n == 0 && r_long == 0;
assign busy = run && w_st != W_END;

function automatic [7:0] uef_hdr(input [3:0] i);   // "UEF File!" 00, version 0.10
	case (i)
	4'd0: uef_hdr = "U"; 4'd1: uef_hdr = "E"; 4'd2: uef_hdr = "F"; 4'd3: uef_hdr = " ";
	4'd4: uef_hdr = "F"; 4'd5: uef_hdr = "i"; 4'd6: uef_hdr = "l"; 4'd7: uef_hdr = "e";
	4'd8: uef_hdr = "!"; 4'd9: uef_hdr = 8'h00; 4'd10: uef_hdr = 8'h0A; default: uef_hdr = 8'h00;
	endcase
endfunction

reg [31:0] p;
reg        got, is_s, is_l, bit_v;
reg  [5:0] u;
reg  [5:0] lu;

always @(posedge clk) begin
	out_wr <= 1'b0;
	got = 1'b0; p = 0;

	if (start) begin
		w_st <= W_HDR; w_i <= 0; out_addr <= 0; err <= 1'b0;
		pf_wp <= 0; pf_rp <= 0; pf_n <= 0;
		r_long <= 0; d_frame <= 1'b0; d_tone <= 0; d_quiet <= 0;
		seg_open <= 1'b0; seg_n <= 0; flush <= 1'b0; tone_req <= 1'b0; w_last <= 1'b0;
	end
	else begin
		// the inflater's bytes into the FIFO
		if (z_wr) begin pf[pf_wp] <= z_data; pf_wp <= pf_wp + 1'd1; end

		case (w_st)
		W_HDR: if (!run) w_st <= W_END;
		else if (hp != 0) begin                // the first byte has said CSW
			out_wr <= 1'b1; out_data <= uef_hdr(w_i); out_addr <= {21'd0, w_i};
			w_i <= w_i + 1'd1;
			if (w_i == 4'd11) w_st <= W_RUN;
		end

		W_RUN: if (tone_req) begin w_st <= W_TONE; w_i <= 0; end
		else if (flush) begin w_st <= W_DHDR; w_i <= 0; end
		else if (pf_any) begin
			// a pulse
			pf_rp <= pf_rp + 1'd1;
			if (r_long != 0) begin
				r_val <= {pf[pf_rp], r_val[31:8]};
				r_long <= r_long - 1'd1;
				if (r_long == 3'd1) begin got = 1'b1; p = {pf[pf_rp], r_val[31:8]}; end
			end
			else if (pf[pf_rp] == 8'd0) r_long <= 3'd4;
			else begin got = 1'b1; p = {24'd0, pf[pf_rp]}; end
		end
		else if (done_in) begin
			if (seg_open) begin flush <= 1'b1; w_last <= 1'b1; end
			else w_st <= W_END;
		end

		// &0110: 2 bytes, the cycles
		W_TONE: begin
			out_wr <= 1'b1; out_addr <= out_addr + 1'd1;
			case (w_i)
			4'd0: out_data <= 8'h10; 4'd1: out_data <= 8'h01; 4'd2: out_data <= 8'h02;
			4'd6: out_data <= tone_cyc[7:0]; 4'd7: out_data <= tone_cyc[15:8];
			default: out_data <= 8'h00;
			endcase
			w_i <= w_i + 1'd1;
			if (w_i == 4'd7) begin tone_req <= 1'b0; w_st <= W_RUN; end
		end

		// &0100: the buffered bytes
		W_DHDR: begin
			out_wr <= 1'b1; out_addr <= out_addr + 1'd1;
			case (w_i)
			4'd0: out_data <= 8'h00; 4'd1: out_data <= 8'h01;
			4'd2: out_data <= seg_n[7:0]; 4'd3: out_data <= {6'd0, seg_n[9:8]};
			default: out_data <= 8'h00;
			endcase
			w_i <= w_i + 1'd1;
			if (w_i == 4'd5) begin w_st <= W_DAT; w_j <= 0; w_ph <= 1'b0; buf_ra <= 0; end
		end
		W_DAT: if (w_j == seg_n) begin
			flush <= 1'b0; seg_open <= 1'b0; seg_n <= 0;
			w_st <= w_last ? W_END : W_RUN;
		end
		else begin
			w_ph <= ~w_ph;
			if (w_ph) begin
				out_wr <= 1'b1; out_addr <= out_addr + 1'd1; out_data <= buf_q;
				w_j <= w_j + 1'd1; buf_ra <= w_j[8:0] + 1'd1;
			end
		end

		W_END: ;
		default: w_st <= W_END;
		endcase

		// the pulse's length: short, long or a gap (sample counts over 16 bits are gaps)
		is_s = p[31:16] == 0 && ({p[15:0], 11'd0} + {p[15:0], 10'd0} + {p[15:0], 7'd0}) < {5'd0, rate};   // p * 3200
		is_l = !is_s && p[31:16] == 0 && ({p[15:0], 10'd0} + {p[15:0], 9'd0} + {p[15:0], 6'd0}) < {6'd0, rate};   // p * 1600

		if (got) begin
			if (!is_s && !is_l) begin
				// a gap ends the run and any byte
				d_frame <= 1'b0; d_tone <= 0; d_quiet <= 0;
				if (seg_open) flush <= 1'b1;
			end
			else if (!d_frame) begin
				if (is_l) begin
					// a start bit
					d_frame <= 1'b1; d_u <= 5'd2; d_lu <= 5'd2; d_bit <= 0;
				end
				else begin
					if (d_tone != 17'h1FFFF) d_tone <= d_tone + 1'd1;
					if (d_quiet != 7'h7F) d_quiet <= d_quiet + 1'd1;
					if (seg_open && d_quiet == 7'd63) flush <= 1'b1;
				end
			end
			else begin
				u  = {1'b0, d_u} + (is_l ? 6'd2 : 6'd1);
				lu = {1'b0, d_lu} + (is_l ? 6'd2 : 6'd0);
				if (u >= 6'd16) begin
					bit_v = lu < 6'd8;
					// a long half across the edge: its second half starts the next bit
					d_u  <= 5'(u - 6'd16);
					d_lu <= (u == 6'd17) ? 5'd1 : 5'd0;
					d_bit <= d_bit + 1'd1;
					if (d_bit == 0 && bit_v) begin d_frame <= 1'b0; d_tone <= 0; d_quiet <= 0; end   // no start bit
					else if (d_bit >= 4'd1 && d_bit <= 4'd8) d_sh <= {bit_v, d_sh[7:1]};
					else if (d_bit == 4'd9) begin
						d_frame <= 1'b0; d_quiet <= 0; d_tone <= 0;
						if (bit_v) begin
							// a byte
							buf_m[seg_n[8:0]] <= d_sh;
							seg_n <= seg_n + 1'd1;
							if (!seg_open) begin
								seg_open <= 1'b1;
								tone_cyc <= d_tone[16:1] == 0 ? 16'd1 : d_tone[16:1];
								tone_req <= 1'b1;
							end
							if (seg_n == 10'(BUFN - 1)) flush <= 1'b1;
						end
					end
				end
				else begin d_u <= u[4:0]; d_lu <= lu[4:0]; end
			end
		end

		if (bad || z_err || (in_end && !body)) err <= 1'b1;
	end

	if (!start) pf_n <= pf_n + z_wr - (w_st == W_RUN && !flush && !tone_req && pf_any);
end

endmodule
