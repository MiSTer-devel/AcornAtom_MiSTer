//============================================================================
//  Cassette deck for the Acorn Atom core: a UEF image in block RAM, played
//  into the 8255's cassette input (PC5), per ~/dev2/tape-standard.md.
//
//  Format. UEF ("UEF File!"), uncompressed (the Atom Software Archive's UEFs
//  all are): chunks &0100 (8N1 data), &0104 (defined format: bits, parity,
//  stop bits; a negative stop count adds one short wave, as the UEF spec
//  says), &0110 (carrier: cycles of 2400 Hz), &0111 (carrier, &AA, carrier),
//  &0112 (gap, n/600 s). Others (&0000 origin, &0117 baud, which is always
//  300 on the Atom) are skipped. A gzipped UEF or anything else reports
//  "Tape format not supported"; more than 128 KB "Tape too large".
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
//  The tape's first file: its name, load and execution addresses come from
//  the first block header as the image downloads (Atom block: four '*', the
//  name, &0D, flag, block number, length-1, exec, load; flag bit 7 = more
//  blocks). `file_end` is set when the player has passed the first file's
//  last block, for the next-step hint.
//============================================================================

module atom_tape #(
	parameter integer CLK_HZ = 31_500_000,
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

	input             dl,                    // ioctl_download for the tape's index
	input             wr,
	input      [24:0] addr,
	input       [7:0] data,

	input             tick,                  // one per 2400 Hz half cycle (scales with turbo)
	input      [15:0] cpu_addr,              // the CPU's address bus ...
	input             cpu_ce,                // ... on its clock enable
	input             rewind,                // OSD Rewind tape (level, rising edge acts)
	input             fast_sel,              // OSD Tape speed: 4x (taken when the deck starts)

	output reg        level,                 // to the cassette input
	output            loaded,
	output            playing,
	output            turbo,

	// for the status bar
	output reg [31:0] played,                // ticks played since the start of the tape
	output reg [31:0] total,                 // ticks on the tape (counted at download)

	// the first file, for the hint
	output reg        hdr_ok,
	output reg [103:0] hdr_name,             // 13 characters, the first in [103:96], space padded
	output reg  [3:0] hdr_len,
	output reg [15:0] hdr_exec,
	output reg [15:0] hdr_load,
	output reg [15:0] file_lo,               // the first file's lowest load address ...
	output reg [16:0] file_hi,               // ... and the end of its highest block
	output reg        file_end,              // the first file has played to its end
	output            at_start,

	// OSD info message (hps_io info_req / info)
	output reg        info_req,
	output reg  [7:0] info
);

localparam integer HOLD = CLK_HZ / 4;        // the deck runs on 250 ms after the last read

//----------------------------------------------------------------------------
// The image
//----------------------------------------------------------------------------
reg  [7:0] mem [0:(1 << AW) - 1];
reg  [AW-1:0] rd_addr;
reg  [7:0] rd_data;
always @(posedge clk) begin
	if (dl && wr && addr < (25'd1 << AW)) mem[addr[AW-1:0]] <= data;
	rd_data <= mem[rd_addr];
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
reg [24:0] h_flag_off;                        // image offset of this block's flag byte
reg        h_first;                           // this block belongs to the tape's first file
reg [24:0] first_end;                         // image offset just past the first file
reg        first_end_ok;
// the previous block, until the next header says whether it was its file's last
reg        p_valid, p_more, p_first;
reg [103:0] p_name;
reg [15:0] p_blk;
reg [24:0] p_flag_off, p_ck_off;
// the repairs: flag and checksum offsets
localparam NFIX = 8;
reg [24:0] fix_flag [0:NFIX-1];
reg [24:0] fix_ck   [0:NFIX-1];
reg  [3:0] nfix;

// the previous block was its file's last: repair it if it says otherwise
task automatic prev_was_last;
	if (p_more && nfix != NFIX) begin
		fix_flag[nfix[2:0]] <= p_flag_off;
		fix_ck[nfix[2:0]]   <= p_ck_off;
		nfix <= nfix + 1'd1;
	end
	if (p_first) begin h_first <= 1'b0; first_end <= p_ck_off + 1'd1; first_end_ok <= 1'b1; end
endtask

task automatic scan(input [7:0] c);
	case (h_state)
	H_SEEK: begin
		if (c == 8'h2A) begin if (h_stars != 3'd7) h_stars <= h_stars + 1'd1; end
		else if (h_stars >= 3'd4) begin
			h_stars <= 0; h_i <= 0;
			h_name <= {c == 8'h0D ? 8'h20 : c, {12{8'h20}}};
			if (h_first && !hdr_ok) begin hdr_name <= {c, {12{8'h20}}}; hdr_len <= 4'd1; end
			if (c == 8'h0D) h_state <= H_HDR;
			else begin h_state <= H_NAME; h_i <= 4'd1; end
		end
		else h_stars <= 0;
	end
	H_NAME: begin
		if (c == 8'h0D || h_i == 4'd14) begin h_state <= H_HDR; h_i <= 0; end
		else begin
			for (int k = 1; k < 13; k++) if (h_i == k) h_name[103 - 8 * k -: 8] <= c;
			if (h_first && !hdr_ok && h_i < 4'd13) begin
				for (int k = 1; k < 13; k++) if (h_i == k) hdr_name[103 - 8 * k -: 8] <= c;
				hdr_len <= h_i + 1'd1;
			end
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
			// is this the previous block's continuation?
			if (p_valid && !(p_more && h_name == p_name && {h_blk_hi, c} == p_blk + 1'd1)) prev_was_last();
			p_valid <= 1'b0;
		end
		4'd3: h_lenm1 <= c;
		4'd4: if (h_first && !hdr_ok) hdr_exec[15:8] <= c;
		4'd5: if (h_first && !hdr_ok) hdr_exec[7:0] <= c;
		4'd6: begin h_load_hi <= c; if (h_first && !hdr_ok) hdr_load[15:8] <= c; end
		4'd7: begin
			if (h_first && !hdr_ok) begin hdr_load[7:0] <= c; hdr_ok <= 1'b1; end
			// the first file's address range, over all its blocks (for the hint)
			if (h_first && h_name == (hdr_ok ? hdr_name : h_name)) begin
				if (!hdr_ok || {h_load_hi, c} < file_lo) file_lo <= {h_load_hi, c};
				if (!hdr_ok || {1'b0, h_load_hi, c} + h_lenm1 + 1'd1 > file_hi) file_hi <= {1'b0, h_load_hi, c} + h_lenm1 + 1'd1;
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
			p_valid <= 1'b1; p_more <= h_flag[7]; p_first <= h_first;
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
		p_state <= P_SIG; hdr_ok <= 1'b0; hdr_len <= 0; hdr_name <= {13{8'h20}};
		h_state <= H_SEEK; h_stars <= 0; h_first <= 1'b1; first_end_ok <= 1'b0;
		p_valid <= 1'b0; nfix <= 0;
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
		valid <= p_state != 4'd15 && !too_big && len > 25'd12;
		info_req <= 1'b1;
		info <= too_big ? 8'd3 : (p_state == 4'd15 || len <= 25'd12) ? 8'd2 : 8'd1;
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
assign at_start = loaded && played == 0;

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
		played <= 0; file_end <= 1'b0; level <= 1'b0; tcnt <= 0;
	end
	else begin
		// Past the first file's last block (flag bit 7 clear), or the end of the
		// tape: BBALL's only block is flagged C0, so the flag alone is not enough.
		if ((first_end_ok && pos >= first_end) || at_end) file_end <= 1'b1;
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
