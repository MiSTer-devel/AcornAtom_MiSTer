//============================================================================
//  Cassette deck for the Acorn Atom core: a UEF image in block RAM, played
//  into the 8255's cassette input (PC5), per ~/dev2/tape-standard.md.
//
//  Format. UEF ("UEF File!"), plain or gzipped: chunks &0100 (8N1 data), &0104 (defined format: bits, parity,
//  stop bits; a negative stop count adds one short wave, as the UEF spec
//  says), &0110 (carrier: cycles of 2400 Hz), &0111 (carrier, &AA, carrier),
//  &0112 (gap, n/600 s). Others (&0000 origin, &0117 baud, which is always
//  300 on the Atom) are skipped. A gzipped UEF (most UEF collections are) is
//  expanded as it downloads (rtl/gunzip.sv). A CSW (v1/v2, RLE or Z-RLE) is
//  read back into bytes as it downloads and stored as a UEF (rtl/csw_in.sv).
//  Anything else reports "Tape format not supported"; more than 128 KB
//  expanded "Tape too large".
//
//  Timebase. The Atom's cassette is CUTS at 300 baud: a 1 is eight cycles of
//  2400 Hz, a 0 four cycles of 1200 Hz. Both are made from `tick`, the core's
//  2.4 kHz tone tick (one per half cycle of 2400 Hz, 208 CPU cycles apart as
//  on the real machine), so the tape keeps its place against the CPU's timing
//  loops at every CPU speed: 16 ticks are one bit. The kernel reads the tape
//  with CPU timing loops, so turbo is the CPU enable and this tick sped up
//  together (the core does both when `turbo` is high).
//
//  The deck plays. The Atom has no motor relay: its COS prints PLAY TAPE and
//  waits for a key. Here the deck plays while the CPU executes the kernel's
//  tape-read routine (`cpu_tape`, from the core) and for HOLD after it last
//  did, and stops otherwise, so the tape waits at a prompt and between loads
//  like a real deck under a patient user. Turbo follows the deck.
//
//  The files, for the next-step hint. As the image downloads, the block
//  headers (Atom block: four '*', the name, &0D, flag, block number,
//  length-1, exec, load; flag bit 7 = more blocks) are grouped into files: a
//  block that is not the previous one's next (same name, number + 1) starts a
//  file. Up to NF files are kept (name, exec, load, address range, where the
//  file starts and ends in the image); a file straight after another of the
//  same name is a backup copy and is left out. As the tape plays, `hdr_*`
//  describe the next file the deck has not entered yet, `between` says the
//  deck is not inside a file (at the start, between files or past the last),
//  and `prev_basic` says the file before it was BASIC.
//============================================================================

module atom_tape #(
	parameter integer CLK_HZ = 32_000_000,
	parameter integer AW     = 17,           // 128 KB of tape
	// The kernel's tape-read code, where the deck plays: the header search and
	// byte reader FB8A-FC37 (Splitting the Atom: OSBGET at FBEE-FC2A) and the
	// bit detector FCBD-FCD7, measured in the simulator. Not FC38-FC7B (the
	// PLAY TAPE prompt and its key wait) nor FC7C-FCBC and FCD8 on (SAVE).
	parameter [15:0]  PC_LO  = 16'hFB8A,
	parameter [15:0]  PC_HI  = 16'hFC37,
	parameter [15:0]  PC2_LO = 16'hFCBD,
	parameter [15:0]  PC2_HI = 16'hFCD7
)(
	input             clk,
	input             reset,                 // power-on / core reset: rewinds nothing

	input             dl_in,                 // ioctl_download for the tape's index
	input             wr_in,
	input      [24:0] addr_in,
	input       [7:0] data_in,
	output            dl_wait,               // ioctl_wait: a gzipped tape is expanded as it comes

	input             tick,                  // one per 2400 Hz half cycle (scales with turbo)
	input      [15:0] cpu_addr,              // the CPU's address bus ...
	input             cpu_ce,                // ... on its clock enable
	input             rewind,                // OSD Rewind tape (level, rising edge acts)
	input             fast_sel,              // OSD Tape speed: 8x (taken when the deck starts)

	output reg        level,                 // to the cassette input
	output            loaded,
	output            playing,
	output            turbo,

	// for the status bar
	output reg [31:0] played,                // ticks played since the start of the tape
	output reg [31:0] total,                 // ticks on the tape (counted at download)

	// the next file, for the hint
	output            hdr_ok,                // there is a next file
	output    [103:0] hdr_name,              // 13 characters, the first in [103:96], space padded
	output      [3:0] hdr_len,
	output     [15:0] hdr_exec,
	output     [15:0] hdr_load,
	output     [15:0] file_lo,               // its lowest load address ...
	output     [16:0] file_hi,               // ... and the end of its highest block
	output            between,               // the deck is not inside a file
	output reg        prev_basic,            // the file before the next was BASIC
	output reg  [4:0] file_idx,              // the next file's number (0 = the first)

	// OSD info message (hps_io info_req / info)
	output reg        info_req,
	output reg  [7:0] info
);

localparam integer HOLD = CLK_HZ / 4;        // the deck runs on 250 ms after the last read
localparam integer NF   = 16;                // files kept for the hint

//----------------------------------------------------------------------------
// The image
//----------------------------------------------------------------------------
// The download goes through the inflater: a gzipped UEF is expanded into the
// RAM, anything else is copied. From here on `dl`, `wr`, `addr` and `data`
// are the expanded image, and the download lasts until it is all in.
wire        gz_wr, gz_busy, gz_gz, gz_err;
wire [24:0] gz_addr;
wire  [7:0] gz_data;
wire [AW-1:0] gz_ra;
reg         dl_d;
always @(posedge clk) dl_d <= dl_in;

reg  [7:0] mem [0:(1 << AW) - 1];
reg  [AW-1:0] rd_addr;
reg  [7:0] rd_data;

// A CSW (its first byte is the "C" of "Compressed Square Wave") goes to the
// CSW reader instead, which writes the bytes it finds on it as a UEF.
reg         csw_r;
wire        first = dl_in && wr_in && addr_in == 25'd0;
wire        csw = first ? data_in == 8'h43 : csw_r;
always @(posedge clk) if (dl_in && !dl_d) csw_r <= 1'b0; else if (first) csw_r <= data_in == 8'h43;

wire        gz_wait, cs_wait, cs_wr, cs_busy, cs_err;
wire [24:0] cs_addr;
wire  [7:0] cs_data;

gunzip #(.AW(AW)) gunzip (
	.clk(clk), .start(dl_in && !dl_d), .raw(1'b0), .stall(1'b0),
	.in_wr(dl_in && wr_in && !csw), .in_data(data_in), .in_end(!dl_in),
	.in_wait(gz_wait),
	.out_wr(gz_wr), .out_addr(gz_addr), .out_data(gz_data), .rd_addr(gz_ra), .rd_data(rd_data),
	.busy(gz_busy), .gz(gz_gz), .err(gz_err)
);
csw_in csw_in (
	.clk(clk), .start(dl_in && !dl_d), .in_wr(dl_in && wr_in && csw), .in_data(data_in), .in_end(!dl_in),
	.in_wait(cs_wait),
	.out_wr(cs_wr), .out_addr(cs_addr), .out_data(cs_data),
	.busy(cs_busy), .err(cs_err)
);
assign      dl_wait = csw ? cs_wait : gz_wait;
wire        dl   = dl_in || gz_busy || (csw_r && cs_busy);
wire        wr   = csw_r ? cs_wr : gz_wr;
wire [24:0] addr = csw_r ? cs_addr : gz_addr;
wire  [7:0] data = csw_r ? cs_data : gz_data;
wire        bad_image = gz_err || (csw_r && cs_err);

always @(posedge clk) begin
	if (wr && addr < (25'd1 << AW)) mem[addr[AW-1:0]] <= data;
	rd_data <= mem[gz_busy ? gz_ra : rd_addr];
end

reg [24:0] len;
reg        valid, too_big;
assign loaded = valid && !dl;

//----------------------------------------------------------------------------
// Parsing as it downloads: the UEF signature, the total time, the first file
//----------------------------------------------------------------------------
reg  [3:0] p_state;
localparam P_SIG = 4'd0, P_ID0 = 4'd1, P_ID1 = 4'd2, P_LEN = 4'd3, P_BODY = 4'd4;
reg [15:0] p_id;
reg [31:0] p_len, p_cnt;
reg [1:0]  p_lb;                              // length byte index
reg [7:0]  p_b0, p_b1, p_b2;                  // first body bytes (format, counts)
reg [7:0]  p_bits;                            // ticks per byte of the current data chunk / 16
reg        p_extra;                           // a short wave after each byte

// Atom block header scanner over the data bytes.
//
// It also repairs the block flag of a file's last block. A real Atom's SAVE
// (kernel FB0D-FB29) sets flag bit 7 on every block but the last, and LOAD
// (FA05, F983) reads blocks until one has it clear. The Atom Software
// Archive's UEFs were converted from ATM files, which carry no flag, and the
// converter (ATM2UEF) wrote C0 on every single-block file: 2568 of the
// archive's 4745 tapes. LOAD then takes the program and waits for a block that
// never comes. So: a block with bit 7 set that the tape does not follow with
// the same file's next block (same name, block number + 1) is its file's last;
// the player flips bit 7 of its flag byte and of its checksum byte (the
// checksum is the sum of every byte of the block, the flag included) as it
// plays them. Nothing else on the tape is changed, and a tape with correct
// flags is played as it is.
reg  [2:0] h_state;
localparam H_SEEK = 3'd0, H_NAME = 3'd1, H_HDR = 3'd2, H_DATA = 3'd3;
reg  [2:0] h_stars;
reg  [3:0] h_i;
reg  [7:0] h_flag, h_lenm1, h_blk_hi, h_load_hi;
reg [15:0] h_blk;
reg [8:0]  h_skip;
reg [103:0] h_name;                           // this block's name, space padded
reg  [3:0] h_len;                             // its length
reg [15:0] h_exec;
reg [24:0] h_off;                             // image offset of this block's first '*'
reg [24:0] h_star;                            // ... of the current run of '*'
reg [24:0] h_flag_off;                        // image offset of this block's flag byte
reg        h_new;                             // this block starts a file
// the previous block, until the next header says whether it was its file's last
reg        p_valid, p_more;
reg [103:0] p_name;
reg [15:0] p_blk;
reg [24:0] p_flag_off, p_ck_off;
// the repairs: flag and checksum offsets
localparam NFIX = 8;
reg [24:0] fix_flag [0:NFIX-1];
reg [24:0] fix_ck   [0:NFIX-1];
reg  [3:0] nfix;
// the file being scanned, and the table of files
reg        f_open, f_skip, f_valid;
reg [103:0] f_name;
reg  [3:0] f_len;
reg [15:0] f_exec, f_load, f_lo;
reg [16:0] f_hi;
reg [24:0] f_off;
reg  [4:0] nfiles;
// {start, end, name, length, exec, load, lowest address, end address}
localparam FW = 25 + 25 + 104 + 4 + 16 + 16 + 16 + 17;
reg [FW-1:0] ftab [0:NF-1];

// the previous block was its file's last: repair it if it says otherwise
task automatic prev_was_last;
	if (p_more && nfix != NFIX) begin
		fix_flag[nfix[2:0]] <= p_flag_off;
		fix_ck[nfix[2:0]]   <= p_ck_off;
		nfix <= nfix + 1'd1;
	end
	// the file it ends goes in the table
	if (f_open && !f_skip && nfiles != NF) begin
		ftab[nfiles[3:0]] <= {f_off, p_ck_off + 1'd1, f_name, f_len, f_exec, f_load, f_lo, f_hi};
		nfiles <= nfiles + 1'd1;
	end
	f_open <= 1'b0;
endtask

task automatic scan(input [7:0] c);
	case (h_state)
	H_SEEK: begin
		if (c == 8'h2A) begin
			if (h_stars == 0) h_star <= addr;
			if (h_stars != 3'd7) h_stars <= h_stars + 1'd1;
		end
		else if (h_stars >= 3'd4) begin
			h_stars <= 0; h_i <= 0; h_off <= h_star;
			h_name <= {c == 8'h0D ? 8'h20 : c, {12{8'h20}}};
			h_len <= c == 8'h0D ? 4'd0 : 4'd1;
			if (c == 8'h0D) h_state <= H_HDR;
			else begin h_state <= H_NAME; h_i <= 4'd1; end
		end
		else h_stars <= 0;
	end
	H_NAME: begin
		if (c == 8'h0D || h_i == 4'd14) begin h_state <= H_HDR; h_i <= 0; end
		else begin
			for (int k = 1; k < 13; k++) if (h_i == k) h_name[103 - 8 * k -: 8] <= c;
			if (h_i < 4'd13) h_len <= h_i + 1'd1;
			h_i <= h_i + 1'd1;
		end
	end
	H_HDR: begin
		h_i <= h_i + 1'd1;
		case (h_i)
		4'd0: begin h_flag <= c; h_flag_off <= addr; end
		4'd1: h_blk_hi <= c;
		4'd2: begin
			h_blk <= {h_blk_hi, c};
			// is this the previous block's continuation? If not, it starts a file
			h_new <= 1'b1;
			if (p_valid) begin
				if (p_more && h_name == p_name && {h_blk_hi, c} == p_blk + 1'd1) h_new <= 1'b0;
				else prev_was_last();
			end
			p_valid <= 1'b0;
		end
		4'd3: h_lenm1 <= c;
		4'd4: h_exec[15:8] <= c;
		4'd5: h_exec[7:0] <= c;
		4'd6: h_load_hi <= c;
		4'd7: begin
			if (h_new) begin
				// a file starts; one of the previous file's name is its backup copy
				f_open <= 1'b1;
				f_skip <= f_valid && h_name == f_name;
				if (!(f_valid && h_name == f_name)) begin
					f_valid <= 1'b1;
					f_name <= h_name; f_len <= h_len; f_exec <= h_exec; f_load <= {h_load_hi, c};
					f_off <= h_off;
					f_lo <= {h_load_hi, c};
					f_hi <= {1'b0, h_load_hi, c} + h_lenm1 + 1'd1;
				end
			end
			else if (!f_skip) begin
				// the file's address range, over all its blocks
				if ({h_load_hi, c} < f_lo) f_lo <= {h_load_hi, c};
				if ({1'b0, h_load_hi, c} + h_lenm1 + 1'd1 > f_hi) f_hi <= {1'b0, h_load_hi, c} + h_lenm1 + 1'd1;
			end
			// data: length-1 + 1 bytes, then the checksum
			h_skip <= {1'b0, h_lenm1} + 9'd2;
			h_state <= H_DATA;
		end
		default: ;
		endcase
	end
	H_DATA: begin
		if (h_skip == 9'd1) begin
			h_state <= H_SEEK; h_stars <= 0;
			p_valid <= 1'b1; p_more <= h_flag[7];
			p_name <= h_name; p_blk <= h_blk; p_flag_off <= h_flag_off; p_ck_off <= addr;
		end
		h_skip <= h_skip - 1'd1;
	end
	default: h_state <= H_SEEK;
	endcase
endtask

function automatic [7:0] sig(input [3:0] i);   // "UEF File!" and a zero
	case (i)
	4'd0: sig = "U"; 4'd1: sig = "E"; 4'd2: sig = "F"; 4'd3: sig = " "; 4'd4: sig = "F";
	4'd5: sig = "i"; 4'd6: sig = "l"; 4'd7: sig = "e"; 4'd8: sig = "!"; default: sig = 8'h00;
	endcase
endfunction

reg old_dl;
always @(posedge clk) begin
	old_dl <= dl;
	info_req <= 1'b0;
	if (dl && !old_dl) begin
		valid <= 1'b0; too_big <= 1'b0; total <= 0; len <= 0;
		p_state <= P_SIG;
		h_state <= H_SEEK; h_stars <= 0;
		p_valid <= 1'b0; nfix <= 0;
		f_open <= 1'b0; f_skip <= 1'b0; f_valid <= 1'b0; nfiles <= 0;
	end
	if (dl && wr) begin
		len <= addr + 1'd1;
		if (addr >= (25'd1 << AW)) too_big <= 1'b1;
		case (p_state)
		P_SIG: begin
			// "UEF File!" 00, then a two-byte version
			if (addr < 25'd10 && data != sig(addr[3:0])) p_state <= 4'd15;
			if (addr == 25'd11) p_state <= P_ID0;
		end
		P_ID0: begin p_id[7:0] <= data; p_state <= P_ID1; end
		P_ID1: begin p_id[15:8] <= data; p_lb <= 0; p_state <= P_LEN; end
		P_LEN: begin
			p_len[8 * p_lb +: 8] <= data;
			p_lb <= p_lb + 1'd1;
			if (p_lb == 2'd3) begin
				p_cnt <= 0;
				p_state <= ({data, p_len[23:0]} == 0) ? P_ID0 : P_BODY;
				p_bits <= 8'd10; p_extra <= 1'b0;   // &0100: 8N1
			end
		end
		P_BODY: begin
			p_cnt <= p_cnt + 1'd1;
			if (p_cnt == 0) p_b0 <= data;
			if (p_cnt == 1) p_b1 <= data;
			if (p_cnt == 2) p_b2 <= data;
			case (p_id)
			16'h0100: begin total <= total + 32'd160; scan(data); end
			16'h0104: begin
				if (p_cnt == 2) begin
					// bits + start + parity + |stop|
					p_bits <= p_b0 + 8'd1 + (p_b1 != "N") + (data[7] ? 8'(-data) : data);
					p_extra <= data[7];
				end
				else if (p_cnt > 2) begin
					total <= total + {20'd0, p_bits, 4'd0} + (p_extra ? 32'd2 : 32'd0);
					scan(data);
				end
			end
			16'h0110: if (p_cnt == 1) total <= total + {15'd0, data, p_b0, 1'b0};
			16'h0111: begin
				if (p_cnt == 1) total <= total + {15'd0, data, p_b0, 1'b0} + 32'd160;
				if (p_cnt == 3) total <= total + {15'd0, data, p_b2, 1'b0};
			end
			16'h0112: if (p_cnt == 1) total <= total + {13'd0, data, p_b0, 3'd0};
			default: ;
			endcase
			if (p_cnt + 1'd1 == p_len) p_state <= P_ID0;
		end
		default: ;
		endcase
	end
	if (!dl && old_dl) begin
		if (p_valid) begin prev_was_last(); p_valid <= 1'b0; end   // the tape's last block
		valid <= p_state != 4'd15 && !too_big && len > 25'd12 && !bad_image;
		info_req <= 1'b1;
		info <= too_big ? 8'd3 : (p_state == 4'd15 || len <= 25'd12 || bad_image) ? 8'd2 : 8'd1;
	end
end

//----------------------------------------------------------------------------
// The deck
//----------------------------------------------------------------------------
reg [31:0] hold;
wire       cpu_tape = cpu_ce && ((cpu_addr >= PC_LO && cpu_addr <= PC_HI) || (cpu_addr >= PC2_LO && cpu_addr <= PC2_HI));
reg        fast;
reg        at_end;
reg        old_rewind;
wire       running = loaded && !at_end && hold != 0;
assign playing = running;
assign turbo   = running && fast;

// A stray access in the range (the kernel's reset path reads FC0B once) must not
// start the deck: it starts after 64 accesses with no gap over 1 ms between
// them; reading the tape makes thousands per bit. Once running, any access
// keeps it going.
localparam integer GAP = CLK_HZ / 1000;
reg [6:0]  hits;
reg [15:0] gap;
always @(posedge clk) begin
	if (cpu_tape && loaded && !at_end) begin
		gap <= 0;
		if (hold != 0 || hits == 7'd63) begin
			if (hold == 0) fast <= fast_sel;  // the deck starts: take the OSD speed
			hold <= HOLD;
		end
		else hits <= hits + 1'd1;
	end
	else begin
		if (hold != 0) hold <= hold - 1'd1;
		if (gap != GAP) gap <= gap + 1'd1;
		else hits <= 0;
	end
end

//----------------------------------------------------------------------------
// The player
//----------------------------------------------------------------------------
// Fetches take three clocks (address, RAM, register); the wave states wait for
// ticks, which are thousands of clocks apart, so the fetches never stretch a pulse.
localparam S_IDLE = 4'd0, S_CHUNK = 4'd1, S_HDRB = 4'd2, S_BODY = 4'd3, S_BYTE = 4'd4,
           S_BIT = 4'd5, S_TONE = 4'd6, S_GAP = 4'd7, S_FETCH = 4'd8, S_END = 4'd9;
reg  [3:0] st, ret;
reg [24:0] pos;                               // next image byte
reg  [1:0] fw;
reg  [7:0] fb;                                // fetched byte
reg  [2:0] ci;                                // chunk header byte index
reg [15:0] c_id;
reg [31:0] c_len, c_cnt;
reg  [7:0] c_bits, c_par, c_stop;             // &0104 format
reg [15:0] c_n;
reg [11:0] shift;                             // the bits of a byte, LSB out first
reg  [3:0] nbits;
reg        extra;                             // a short wave after the byte
reg  [3:0] tcnt;                              // ticks into the current bit
reg [16:0] tone;                              // ticks of carrier / gap left
reg  [1:0] sub;                               // &0111: 1 the &AA byte, 2 the second carrier
// The next file: the first the deck has not entered (fetched its first '*').
// The table is a RAM: after file_idx moves, its entry takes two clocks.
reg [FW-1:0] fq;
reg  [1:0] settle;
reg [24:0] prev_end;
always @(posedge clk) fq <= ftab[file_idx[3:0]];
wire [24:0] q_off = fq[FW-1 -: 25];
wire [24:0] q_end = fq[FW-26 -: 25];
wire        q_exec_basic = hdr_exec == 16'hC2B2 || hdr_exec == 16'hCE86;   // BASIC, or BASIC's RUN
assign {hdr_name, hdr_len, hdr_exec, hdr_load, file_lo, file_hi} = fq[FW-51:0];
assign hdr_ok  = loaded && settle == 0 && file_idx < nfiles;
assign between = loaded && settle == 0 && (file_idx == 0 || pos >= prev_end);

// the byte being played gets bit 7 flipped if it is a repaired flag or checksum
reg fixit;
always @(*) begin
	fixit = 1'b0;
	for (int k = 0; k < NFIX; k++)
		if (k < nfix && (pos - 1'd1 == fix_flag[k] || pos - 1'd1 == fix_ck[k])) fixit = 1'b1;
end
wire [7:0] fbx = fb ^ {fixit, 7'd0};

always @(posedge clk) begin
	old_rewind <= rewind;
	if ((dl && !old_dl) || (rewind && !old_rewind) || !loaded) begin
		st <= S_IDLE; pos <= 25'd12; ci <= 0; at_end <= 1'b0;
		played <= 0; level <= 1'b0; tcnt <= 0;
		file_idx <= 0; prev_basic <= 1'b0; prev_end <= 0; settle <= 2'd2;
	end
	else begin
		if (settle != 0) settle <= settle - 1'd1;
		else if (file_idx < nfiles && pos > q_off) begin
			// the deck has entered the next file
			prev_basic <= q_exec_basic;
			prev_end <= q_end;
			file_idx <= file_idx + 1'd1;
			settle <= 2'd2;
		end
		case (st)
		S_IDLE: begin st <= S_CHUNK; pos <= 25'd12; ci <= 0; end
		S_FETCH: begin
			fw <= fw + 1'd1;
			if (fw == 2'd2) begin fb <= rd_data; pos <= pos + 1'd1; st <= ret; end
		end
		S_CHUNK: begin
			if (ci == 3'd6) begin
				ci <= 0; c_cnt <= 0;
				c_bits <= 8'd8; c_par <= "N"; c_stop <= 8'd1;
				st <= S_BODY;
			end
			else if (pos >= len) begin st <= S_END; at_end <= 1'b1; end
			else begin rd_addr <= pos[AW-1:0]; fw <= 0; ret <= S_HDRB; st <= S_FETCH; end
		end
		S_HDRB: begin
			case (ci)
			3'd0: c_id[7:0]    <= fb;
			3'd1: c_id[15:8]   <= fb;
			3'd2: c_len[7:0]   <= fb;
			3'd3: c_len[15:8]  <= fb;
			3'd4: c_len[23:16] <= fb;
			default: c_len[31:24] <= fb;
			endcase
			ci <= ci + 1'd1;
			st <= S_CHUNK;
		end
		S_BODY: begin
			if (c_cnt == c_len) st <= S_CHUNK;
			else if (pos >= len) begin st <= S_END; at_end <= 1'b1; end
			else begin rd_addr <= pos[AW-1:0]; fw <= 0; ret <= S_BYTE; st <= S_FETCH; end
		end
		S_BYTE: begin
			c_cnt <= c_cnt + 1'd1;
			st <= S_BODY;
			tcnt <= 0;
			case (c_id)
			16'h0100: begin shift <= {3'b111, fbx, 1'b0}; nbits <= 4'd10; extra <= 1'b0; st <= S_BIT; end
			16'h0104: begin
				if (c_cnt == 0) c_bits <= fb;
				else if (c_cnt == 1) c_par <= fb;
				else if (c_cnt == 2) c_stop <= fb;
				else begin
					// start bit, data LSB first, parity, stop bits
					if (c_bits == 8'd7)
						shift <= {3'b111, (c_par == "N") ? 1'b1 : (c_par == "E") ? ^fbx[6:0] : ~^fbx[6:0], fbx[6:0], 1'b0};
					else
						shift <= {2'b11, (c_par == "N") ? 1'b1 : (c_par == "E") ? ^fbx : ~^fbx, fbx, 1'b0};
					nbits <= 4'd1 + c_bits[3:0] + ((c_par != "N") ? 4'd1 : 4'd0) +
					         (c_stop[7] ? 4'(8'(-c_stop)) : c_stop[3:0]);
					extra <= c_stop[7];
					st <= S_BIT;
				end
			end
			16'h0110: begin
				if (c_cnt == 0) c_n[7:0] <= fb;
				else if (c_cnt == 1) begin tone <= {fb, c_n[7:0], 1'b0}; st <= S_TONE; end
			end
			16'h0111: begin
				if (c_cnt == 0) c_n[7:0] <= fb;
				else if (c_cnt == 1) begin tone <= {fb, c_n[7:0], 1'b0}; sub <= 2'd0; st <= S_TONE; end
				else if (c_cnt == 2) c_n[7:0] <= fb;
				else if (c_cnt == 3) begin
					c_n[15:8] <= fb;
					shift <= {3'b111, 8'hAA, 1'b0}; nbits <= 4'd10; extra <= 1'b0; sub <= 2'd1; st <= S_BIT;
				end
			end
			16'h0112: begin
				if (c_cnt == 0) c_n[7:0] <= fb;
				else if (c_cnt == 1) begin tone <= {fb, c_n[7:0], 3'd0}; level <= 1'b0; st <= S_GAP; end
			end
			default: ;   // skipped
			endcase
		end
		S_BIT: if (tick && running) begin
			// 16 ticks a bit: a 1 toggles every tick (2400 Hz), a 0 every second tick (1200 Hz)
			played <= played + 1'd1;
			if (shift[0] || tcnt[0]) level <= ~level;
			tcnt <= tcnt + 1'd1;
			if (tcnt == 4'd15) begin
				shift <= {1'b1, shift[11:1]};
				nbits <= nbits - 1'd1;
				if (nbits == 4'd1) begin
					if (extra) begin tone <= 17'd2; extra <= 1'b0; st <= S_TONE; end
					else if (c_id == 16'h0111 && sub == 2'd1) begin tone <= {c_n, 1'b0}; sub <= 2'd2; st <= S_TONE; end
					else st <= S_BODY;
				end
			end
		end
		S_TONE: if (tone == 0) st <= S_BODY;
		else if (tick && running) begin
			played <= played + 1'd1;
			level <= ~level;
			tone <= tone - 1'd1;
			if (tone == 17'd1) st <= S_BODY;
		end
		S_GAP: if (tone == 0) st <= S_BODY;
		else if (tick && running) begin
			played <= played + 1'd1;
			tone <= tone - 1'd1;
			if (tone == 17'd1) st <= S_BODY;
		end
		default: ;   // S_END
		endcase
	end
end

endmodule
