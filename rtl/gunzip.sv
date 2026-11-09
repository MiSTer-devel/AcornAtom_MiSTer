//============================================================================
//  gzip inflater for the tape deck: a .uef that is gzipped (as the UEF spec
//  allows and most UEF collections are) is expanded as it downloads, into the
//  deck's own RAM. Anything that does not start with the gzip magic passes
//  through unchanged.
//
//  Input: the download's bytes, paced with `in_wait` (hps_io's ioctl_wait).
//  Output: the expanded bytes in order (out_wr/out_addr/out_data), and a read
//  port into the same RAM (rd_addr, rd_data one clock after) for DEFLATE's
//  back references: the RAM is the 32 KB window. busy stays high until the
//  stream has ended; err says it was not a stream this can expand.
//
//  DEFLATE (RFC 1951) as zlib's puff.c does it: canonical Huffman codes
//  decoded a bit a clock against per-length counts, stored, fixed and
//  dynamic blocks. gzip (RFC 1952): the header with its optional fields is
//  skipped; the trailer (CRC-32, size) is not checked.
//============================================================================

module gunzip #(
	parameter integer AW = 17
)(
	input             clk,
	input             start,                 // a download begins
	input             in_wr,
	input       [7:0] in_data,
	input             in_end,                // the download is over (level)
	output            in_wait,

	output reg        out_wr,
	output reg [24:0] out_addr,
	output reg  [7:0] out_data,
	output reg [AW-1:0] rd_addr,
	input       [7:0] rd_data,

	output            busy,
	output reg        gz,                    // the input is gzipped
	output reg        err
);

// input FIFO: the HPS sees in_wait a byte late, so there is room for two more
reg  [7:0] fifo [0:3];
reg  [1:0] f_wp = 0, f_rp = 0;
reg  [2:0] f_n = 0;
assign in_wait = f_n >= 3'd2;

localparam M_IDLE = 5'd0,  M_PASS = 5'd1,  M_DONE = 5'd2,  G_HDR = 5'd3,  G_XLEN = 5'd4,
           G_SKIP = 5'd5,  G_STR = 5'd6,   BLK = 5'd7,     ST_LEN = 5'd8, ST_CP = 5'd9,
           F_INIT = 5'd10, B_CLR = 5'd11,  B_CNT = 5'd12,  B_OFF = 5'd13, B_PL = 5'd14,
           D_HDR = 5'd15,  D_CLZ = 5'd16,  D_CLL = 5'd17,  D_LENS = 5'd18, D_REP = 5'd19,
           D_XB = 5'd20,   H_DEC = 5'd21,  H_SYM = 5'd22,  L_EXT = 5'd23, X_EXT = 5'd24,
           CP_RD = 5'd25,  CP_W1 = 5'd26,  CP_W2 = 5'd27,  DATA = 5'd28,  F_T1 = 5'd29;
reg  [4:0] st = M_DONE, bret, hret;
reg        run = 0;
assign busy = run && st != M_DONE;

// bit buffer, LSB first
reg [31:0] bb;
reg  [5:0] bc;

// code lengths (litlen 0-287, dist 288-319, code-length codes 320-338) and
// symbol tables (litlen at 0, dist at 320, code-length codes at 384)
reg  [3:0] lens [0:511];
reg  [8:0] lens_ra;
reg  [3:0] lens_q;
reg  [8:0] symtab [0:511];
reg  [8:0] sym_ra;
reg  [8:0] sym_q;
always @(posedge clk) begin lens_q <= lens[lens_ra]; sym_q <= symtab[sym_ra]; end

// per table (0 litlen, 1 dist, 2 code lengths) and length: how many codes
reg  [8:0] cnt [0:47];
reg  [8:0] offs [0:15];

// table build: which table, its lengths' base, size, symbols' base
reg  [1:0] bt;
reg  [8:0] lb, bn, sb, bs;
reg  [1:0] bph;                              // read phase

// decode
reg  [1:0] ht;                               // table
reg [15:0] hcode, hfirst, hindex;
reg  [4:0] hlen;

reg        bfinal;
reg  [8:0] hlit, i_cnt, lim;
reg  [5:0] hdist;
reg  [4:0] hclen;
reg  [3:0] prev, rep_val;
reg  [7:0] rep;
reg  [3:0] gi;                               // gzip header byte
reg  [7:0] flg;
reg [15:0] slen, xcnt;
reg  [8:0] clen;
reg [15:0] cdist;
reg  [3:0] xn;                               // extra bits wanted
reg  [2:0] xk;                               // what they are for
reg [24:0] opos;

function automatic [4:0] cl_order(input [4:0] i);   // 16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1 15
	case (i)
	5'd0: cl_order = 16; 5'd1: cl_order = 17; 5'd2: cl_order = 18; 5'd3: cl_order = 0;
	5'd4: cl_order = 8;  5'd5: cl_order = 7;  5'd6: cl_order = 9;  5'd7: cl_order = 6;
	5'd8: cl_order = 10; 5'd9: cl_order = 5;  5'd10: cl_order = 11; 5'd11: cl_order = 4;
	5'd12: cl_order = 12; 5'd13: cl_order = 3; 5'd14: cl_order = 13; 5'd15: cl_order = 2;
	5'd16: cl_order = 14; 5'd17: cl_order = 1; default: cl_order = 15;
	endcase
endfunction

// where code length i of the dynamic header goes
wire [8:0] dl_addr = i_cnt < hlit ? i_cnt : 9'd288 + (i_cnt - hlit);

integer k;
reg [31:0] nbb;
reg  [5:0] nbc;
reg        tk;
reg  [5:0] tn;
reg        pop, push, starve;
reg [15:0] c, cn;
reg  [8:0] l;
reg  [3:0] e;

always @(posedge clk) begin
	out_wr <= 1'b0;
	tk = 1'b0; tn = 0; pop = 1'b0; starve = 1'b0;
	push = in_wr;

	if (start) begin
		run <= 1'b1; st <= M_IDLE; gz <= 1'b0; err <= 1'b0;
		f_wp <= 0; f_rp <= 0; f_n <= 0; push = 1'b0;
		bb <= 0; bc <= 0; opos <= 0;
	end
	else begin
		case (st)
		M_IDLE: if (f_n != 0) begin
			if (fifo[f_rp] == 8'h1F) begin gz <= 1'b1; gi <= 0; st <= G_HDR; end
			else st <= M_PASS;
		end
		else if (in_end) st <= M_DONE;

		M_PASS: if (f_n != 0) begin
			pop = 1'b1;
			out_wr <= 1'b1; out_addr <= opos; out_data <= fifo[f_rp]; opos <= opos + 1'd1;
		end
		else if (in_end) st <= M_DONE;

		M_DONE: if (f_n != 0) pop = 1'b1;    // the trailer, or what follows an error

		// gzip header: ID1 ID2 CM FLG MTIME(4) XFL OS, then FEXTRA, FNAME, FCOMMENT, FHCRC
		G_HDR: if (bc >= 8) begin
			tk = 1'b1; tn = 8;
			gi <= gi + 1'd1;
			if ((gi == 0 && bb[7:0] != 8'h1F) || (gi == 1 && bb[7:0] != 8'h8B) || (gi == 2 && bb[7:0] != 8'h08)) begin
				err <= 1'b1; st <= M_DONE;
			end
			if (gi == 3) flg <= bb[7:0];
			if (gi == 9) begin
				if (flg[2]) st <= G_XLEN;
				else begin gi <= 0; st <= G_STR; end
			end
		end
		else starve = 1'b1;
		G_XLEN: if (bc >= 16) begin tk = 1'b1; tn = 16; xcnt <= bb[15:0]; st <= G_SKIP; end
		else starve = 1'b1;
		G_SKIP: if (xcnt == 0) begin gi <= 0; st <= G_STR; end
		else if (bc >= 8) begin tk = 1'b1; tn = 8; xcnt <= xcnt - 1'd1; end
		else starve = 1'b1;
		// gi 0: FNAME, 1: FCOMMENT, 2: FHCRC, 3: done
		G_STR: begin
			if (gi == 0 && !flg[3]) gi <= 1;
			else if (gi == 1 && !flg[4]) gi <= 2;
			else if (gi == 2 && !flg[1]) gi <= 3;
			else if (gi == 3) st <= BLK;
			else if (gi == 2) begin
				if (bc >= 16) begin tk = 1'b1; tn = 16; gi <= 3; end else starve = 1'b1;
			end
			else if (bc >= 8) begin tk = 1'b1; tn = 8; if (bb[7:0] == 0) gi <= gi + 1'd1; end
			else starve = 1'b1;
		end

		// a block
		BLK: if (bc >= 3) begin
			tk = 1'b1; tn = 3;
			bfinal <= bb[0];
			case (bb[2:1])
			2'd0: st <= ST_LEN;
			2'd1: begin i_cnt <= 0; st <= F_INIT; end
			2'd2: st <= D_HDR;
			default: begin err <= 1'b1; st <= M_DONE; end
			endcase
		end
		else starve = 1'b1;

		// stored: to a byte boundary, LEN, NLEN, the bytes
		ST_LEN: if (bc[2:0] != 0) begin tk = 1'b1; tn = {3'd0, bc[2:0]}; end
		else if (bc >= 32) begin
			tk = 1'b1; tn = 32; slen <= bb[15:0];
			if (bb[15:0] != ~bb[31:16]) begin err <= 1'b1; st <= M_DONE; end
			else st <= ST_CP;
		end
		else starve = 1'b1;
		ST_CP: if (slen == 0) st <= bfinal ? M_DONE : BLK;
		else if (bc >= 8) begin
			tk = 1'b1; tn = 8; slen <= slen - 1'd1;
			out_wr <= 1'b1; out_addr <= opos; out_data <= bb[7:0]; opos <= opos + 1'd1;
		end
		else starve = 1'b1;

		// fixed codes: lengths 8 (0-143), 9 (144-255), 7 (256-279), 8 (280-287), cdist 5
		F_INIT: if (i_cnt == 9'd318) begin
			bt <= 0; lb <= 0; bn <= 288; sb <= 0; bret <= F_T1; st <= B_CLR;
		end
		else begin
			lens[i_cnt] <= i_cnt < 144 ? 4'd8 : i_cnt < 256 ? 4'd9 : i_cnt < 280 ? 4'd7 : i_cnt < 288 ? 4'd8 : 4'd5;
			i_cnt <= i_cnt + 1'd1;
		end
		F_T1: begin bt <= 1; lb <= 288; bn <= 30; sb <= 320; bret <= DATA; st <= B_CLR; end

		// build table bt from bn lengths at lb into symbols at sb
		B_CLR: begin
			for (k = 0; k < 16; k++) cnt[{bt, 4'd0} + k] <= 0;
			bs <= 0; bph <= 0; st <= B_CNT;
		end
		B_CNT: begin
			bph <= bph + 1'd1;
			if (bph == 0) begin
				if (bs == bn) st <= B_OFF;
				else lens_ra <= lb + bs;
			end
			else if (bph == 2) begin
				if (lens_q != 0) cnt[{bt, lens_q}] <= cnt[{bt, lens_q}] + 1'd1;
				bs <= bs + 1'd1; bph <= 0;
			end
		end
		B_OFF: begin
			offs[1] <= 0;
			for (k = 1; k < 15; k++) offs[k + 1] <= offs_sum(k);
			bs <= 0; bph <= 0; st <= B_PL;
		end
		B_PL: begin
			bph <= bph + 1'd1;
			if (bph == 0) begin
				if (bs == bn) st <= bret;
				else lens_ra <= lb + bs;
			end
			else if (bph == 2) begin
				if (lens_q != 0) begin
					symtab[sb + offs[lens_q]] <= bs;
					offs[lens_q] <= offs[lens_q] + 1'd1;
				end
				bs <= bs + 1'd1; bph <= 0;
			end
		end

		// dynamic: HLIT, HDIST, HCLEN, the code-length code, the code lengths
		D_HDR: if (bc >= 14) begin
			tk = 1'b1; tn = 14;
			hlit <= {4'd0, bb[4:0]} + 9'd257; hdist <= {1'b0, bb[9:5]} + 6'd1; hclen <= {1'b0, bb[13:10]} + 5'd4;
			i_cnt <= 0; st <= D_CLZ;
		end
		else starve = 1'b1;
		D_CLZ: if (i_cnt == 19) begin i_cnt <= 0; st <= D_CLL; end
		else begin lens[9'd320 + i_cnt] <= 0; i_cnt <= i_cnt + 1'd1; end
		D_CLL: if (i_cnt == {4'd0, hclen}) begin
			bt <= 2; lb <= 320; bn <= 19; sb <= 384; bret <= D_LENS; st <= B_CLR;
			i_cnt <= 0; lim <= hlit + hdist;
		end
		else if (bc >= 3) begin
			tk = 1'b1; tn = 3;
			lens[9'd320 + cl_order(i_cnt[4:0])] <= bb[2:0];
			i_cnt <= i_cnt + 1'd1;
		end
		else starve = 1'b1;
		D_LENS: if (i_cnt == lim) begin
			bt <= 0; lb <= 0; bn <= hlit; sb <= 0; bret <= D_XB; st <= B_CLR;
		end
		else begin ht <= 2; hret <= D_LENS; st <= H_DEC; hcode <= 0; hfirst <= 0; hindex <= 0; hlen <= 1; end
		D_XB: begin bt <= 1; lb <= 288; bn <= {3'd0, hdist}; sb <= 320; bret <= DATA; st <= B_CLR; end
		D_REP: if (rep == 0) st <= D_LENS;
		else if (i_cnt == lim) begin err <= 1'b1; st <= M_DONE; end
		else begin lens[dl_addr] <= rep_val; i_cnt <= i_cnt + 1'd1; rep <= rep - 1'd1; end

		// the data: literal/length codes, distance codes
		DATA: begin ht <= 0; hret <= DATA; st <= H_DEC; hcode <= 0; hfirst <= 0; hindex <= 0; hlen <= 1; end

		// decode one symbol of table ht (puff.c's decode())
		H_DEC: if (bc >= 1) begin
			tk = 1'b1; tn = 1;
			c = hcode | {15'd0, bb[0]};
			cn = {7'd0, cnt[{ht, hlen[3:0]}]};
			if (c < hfirst + cn) begin
				sym_ra <= (ht == 0 ? 9'd0 : ht == 1 ? 9'd320 : 9'd384) + hindex[8:0] + (c[8:0] - hfirst[8:0]);
				bph <= 0; st <= H_SYM;
			end
			else if (hlen == 15) begin err <= 1'b1; st <= M_DONE; end
			else begin
				hindex <= hindex + cn; hfirst <= (hfirst + cn) << 1; hcode <= c << 1; hlen <= hlen + 1'd1;
			end
		end
		else starve = 1'b1;
		H_SYM: begin
			bph <= bph + 1'd1;
			if (bph == 1) begin
				if (hret == D_LENS) begin
					// a code length: 0-15 itself, 16 repeat the previous 3-6, 17 zeros 3-10, 18 zeros 11-138
					if (sym_q < 16) begin
						lens[dl_addr] <= sym_q[3:0]; prev <= sym_q[3:0]; i_cnt <= i_cnt + 1'd1; st <= D_LENS;
					end
					else begin
						xk <= sym_q[2:0];        // 0 (16), 1 (17), 2 (18)
						xn <= sym_q == 16 ? 4'd2 : sym_q == 17 ? 4'd3 : 4'd7;
						st <= X_EXT;
						if (sym_q == 16 && i_cnt == 0) begin err <= 1'b1; st <= M_DONE; end
					end
				end
				else if (ht == 0) begin
					if (sym_q < 256) begin
						out_wr <= 1'b1; out_addr <= opos; out_data <= sym_q[7:0]; opos <= opos + 1'd1;
						st <= DATA;
					end
					else if (sym_q == 256) st <= bfinal ? M_DONE : BLK;
					else begin
						// length: 257-264 3-10, 285 258, else a base and extra bits
						l = sym_q - 9'd257;
						if (l > 28) begin err <= 1'b1; st <= M_DONE; end
						else if (l < 8) begin clen <= l + 9'd3; ht <= 1; hret <= DATA; st <= L_EXT; xn <= 0; end
						else if (l == 28) begin clen <= 9'd258; ht <= 1; st <= L_EXT; xn <= 0; end
						else begin
							e = l[5:2] - 4'd1;
							clen <= ({5'd0, 2'b01, l[1:0]} << e) + 9'd3;
							xn <= e; ht <= 1; st <= L_EXT;
						end
						xk <= 3'd3;
					end
				end
				else begin
					// distance: 0-3 1-4, else a base and extra bits
					if (sym_q > 29) begin err <= 1'b1; st <= M_DONE; end
					else if (sym_q < 4) begin cdist <= sym_q + 16'd1; xn <= 0; xk <= 3'd4; st <= X_EXT; end
					else begin
						e = sym_q[4:1] - 4'd1;
						cdist <= ({14'd0, 1'b1, sym_q[0]} << e) + 16'd1;
						xn <= e; xk <= 3'd4; st <= X_EXT;
					end
				end
			end
		end
		// a length's extra bits, then its distance code
		L_EXT: if (bc >= xn) begin
			tk = 1'b1; tn = {2'd0, xn};
			clen <= clen + (bb[8:0] & ((9'd1 << xn) - 1'd1));
			hret <= DATA; st <= H_DEC; hcode <= 0; hfirst <= 0; hindex <= 0; hlen <= 1;
		end
		else starve = 1'b1;
		// extra bits: xk 0-2 code-length repeats, 4 a distance
		X_EXT: if (bc >= xn) begin
			tk = 1'b1; tn = {2'd0, xn};
			case (xk)
			3'd0: begin rep <= 8'd3 + bb[1:0]; rep_val <= prev; st <= D_REP; end
			3'd1: begin rep <= 8'd3 + bb[2:0]; rep_val <= 0; st <= D_REP; end
			3'd2: begin rep <= 8'd11 + bb[6:0]; rep_val <= 0; st <= D_REP; end
			default: begin
				cdist <= cdist + (bb[15:0] & ((16'd1 << xn) - 1'd1));
				st <= CP_RD;
			end
			endcase
		end
		else starve = 1'b1;
		// the copy: three clocks a byte (address, RAM, write), so a byte just
		// written is in the RAM before it is read back (a distance of 1)
		CP_RD: if (clen == 0) st <= DATA;
		else if ({9'd0, cdist} > opos) begin err <= 1'b1; st <= M_DONE; end
		else begin rd_addr <= AW'(opos - {9'd0, cdist}); st <= CP_W1; end
		CP_W1: st <= CP_W2;
		CP_W2: begin
			out_wr <= 1'b1; out_addr <= opos; out_data <= rd_data; opos <= opos + 1'd1;
			clen <= clen - 1'd1; st <= CP_RD;
		end
		default: st <= M_DONE;
		endcase

		// a stream that ends early
		if (starve && in_end && f_n == 0) begin err <= 1'b1; st <= M_DONE; end
	end

	// the bit buffer: take, then refill a byte from the FIFO
	nbb = bb; nbc = bc;
	if (tk) begin nbb = nbb >> tn; nbc = nbc - tn; end
	if (gz && !start && st != M_DONE && f_n != 0 && nbc <= 6'd24 && !pop) begin
		nbb = nbb | ({24'd0, fifo[f_rp]} << nbc); nbc = nbc + 6'd8; pop = 1'b1;
	end
	if (!start) begin bb <= nbb; bc <= nbc; end

	// the FIFO
	if (push) begin fifo[f_wp] <= in_data; f_wp <= f_wp + 1'd1; end
	if (pop) f_rp <= f_rp + 1'd1;
	if (!start) f_n <= f_n + push - pop;
end

// offs[k + 1] = offs[k] + cnt[k], from offs[1] = 0
function automatic [8:0] offs_sum(input integer n);
	reg [8:0] s;
	s = 0;
	for (int j = 1; j <= n; j++) s = s + cnt[{bt, 4'(j)}];
	offs_sum = s;
endfunction

endmodule
