`timescale 1ns / 1ps
//============================================================================
//  Simulation top (Verilator) for the Acorn Atom core.
//
//  Stands in for AcornAtom.sv: the same wiring around AtomFpga_Core, with
//  hps_io, the PLL and the Altera memories replaced by things sim_main.cpp
//  can drive. Keep it in sync with AcornAtom.sv when the real top changes.
//
//  Differences from AcornAtom.sv, all deliberate:
//    * clk_42 and clk_32 come from C++ (two independent schedulers, so their
//      relationship is the hardware's: 42.954545 and 31.5 MHz);
//    * the 192 KB ROM/RAM is a $readmemh array (atom192k.hex from the mif);
//    * the HPS side of sys/sd_card.sv is driven by sim_main.cpp's block device;
//    * no physical SD card: its MISO is tied high (no card present);
//    * the tape ADC is replaced by the cas_in input;
//    * video goes out raw (2-bit RGB widened to 8 bits), no video_mixer.
//============================================================================

module top (
	input         clk_42,
	input         clk_32,
	input         reset,

	input  [10:0] ps2_key,
	input  [15:0] joy1,
	input  [15:0] joy2,
	input   [1:0] layout,          // OSD Keyboard: UK, US, orig, game (status[7:6])
	input         charset,         // OSD character set: xtra (status[8])
	input         dark_background, // OSD Background: Dark (status[9])
	input         bbc_mode,        // OSD Mode: BBC (status[10])
	input         speaker_en,      // OSD Audio: Speaker (status[4] = 0)
	input         sid_en,          // OSD Audio: SID (status[5] = 0)
	input         tape_audio_en,   // OSD Audio: Tape audio (status[16])
	input   [1:0] turbo_default,   // OSD CPU speed (status[14:13]); F1-F4 change it live
	input         btn_break,       // OSD BREAK button (status[15], level)
	input         btn_shift_break, // OSD Shift-BREAK (status[20])
	input         btn_ctrl_break,  // OSD Ctrl-BREAK (status[21])
	input         tape_fast_sel,   // OSD Tape speed: 4x (status[17] = 0)
	input         tape_rewind,     // OSD Rewind tape (status[18])
	input         tape_overlay_en, // OSD Tape overlay: On (status[19] = 0)
	// HPS file transfer (the tape, index 1), driven by sim/sim_bus.cpp
	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,
	input   [7:0] ioctl_index,
	output        ioctl_wait,
	input         cas_in,
	output        cas_out,

	// HPS side of the SD card (sys/sd_card.sv); widths as sim_blkdevice expects
	output [31:0] sd_lba,
	output  [9:0] sd_rd,
	output  [9:0] sd_wr,
	input   [9:0] sd_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr,
	input   [9:0] img_mounted,
	input         img_readonly,
	input  [63:0] img_size,

	// Video, straight from the 6847
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_HB,
	output        VGA_VB,
	output        CE_PIXEL,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,

	// Debug taps: hierarchical reads out of the netlist, no RTL changes
	output [15:0] dbg_cpu_addr,
	output  [7:0] dbg_cpu_din,
	output  [7:0] dbg_cpu_dout,
	output        dbg_cpu_rw,      // 1 = read
	output        dbg_cpu_clken,   // one clk_32 per CPU cycle
	output  [7:0] dbg_pa,          // 8255 port A: keyboard row 3:0, A/G 4, GM 7:5
	output        dbg_irq_n,
	output  [1:0] dbg_turbo,
	output        dbg_sdss,
	output        dbg_vsd_sel,
	output        dbg_kb_shift,    // keyboard shift to the 8255 (active low)
	output        dbg_kb_ctrl,     // keyboard ctrl to the 8255 (active low)
	output        dbg_tape_loaded,
	output        dbg_tape_playing,
	output        dbg_tape_turbo,
	output        dbg_tape_level,
	output        dbg_tape_hooked,
	output        dbg_tape_file_end,
	output [31:0] dbg_tape_played,
	output [31:0] dbg_tape_total,
	output  [7:0] dbg_tape_info,
	output        dbg_tape_info_req
);

//////////////////////////////  CLOCKS  //////////////////////////////////////
// 14.318 MHz enable from clk_42, as AcornAtom.sv makes it.
reg       clk_14M318_ena;
reg [1:0] count;

always @(posedge clk_42) begin
	if (reset) begin
		count <= 0;
		clk_14M318_ena <= 0;
	end else begin
		clk_14M318_ena <= 0;
		if (count == 2'd2) begin
			clk_14M318_ena <= 1;
			count <= 0;
		end else
			count <= count + 1'd1;
	end
end

//////////////////////////////  MEMORY  //////////////////////////////////////
// AcornAtom.sv: spram #(8, 18, 196608, "roms/ATOM192k.mif"), single port on
// clk_main, address registered, data out unregistered, new data on a
// read-during-write. The hex file is tools/mif2hex.py's rendering of the mif.
wire        mem_we;
wire [17:0] mem_addr;
wire  [7:0] mem_din;
wire  [7:0] mem_dout;
wire        rom_cs;

reg [7:0] mem [0:196607] /*verilator public_flat_rw*/;
initial $readmemh("atom192k.hex", mem);

reg [17:0] mem_addr_r;
always @(posedge clk_32) begin
	if (mem_we) mem[mem_addr] <= mem_din;
	mem_addr_r <= mem_addr;
end
assign mem_dout = mem[mem_addr_r];

// BREAK, Shift-BREAK, Ctrl-BREAK from the OSD buttons and F10/F9/F11, as AcornAtom.sv.
wire osd_break, osd_shift, osd_ctrl;
break_keys break_keys (
	.clk_sys(clk_32), .btn_break(btn_break), .btn_shift_break(btn_shift_break),
	.btn_ctrl_break(btn_ctrl_break), .ps2_key(ps2_key),
	.osd_break(osd_break), .osd_shift(osd_shift), .osd_ctrl(osd_ctrl)
);

// tape deck signals the core uses (the deck is under TAPE below)
wire        cas_tick, cpu_clken;
wire [15:0] cpu_addr;
wire        tape_level, tape_loaded, tape_playing, tape_turbo;

//////////////////////////////  THE MACHINE  /////////////////////////////////
wire  [1:0] r, g, b;
wire        hs, vs, hblank, vblank;
wire        a_audio;
wire [17:0] sid_audio;
wire        sdclk, sdss, sdmosi, sdmiso;

AtomFpga_Core core (
	.clk_vid       (clk_42),
	.clk_vid_en    (clk_14M318_ena),
	.clk_main      (clk_32),
	.clk_dac       (clk_32),
	.clk_avr       (clk_32),
	.pixel_clock   (CE_PIXEL),

	.ps2_key       (ps2_key),
	.layout        (layout),
	.BLACK_BACKGND (~dark_background),
	.computer      (bbc_mode),
	.turbo_default (turbo_default),
	.osd_break     (osd_break),
	.osd_shift     (osd_shift),
	.osd_ctrl      (osd_ctrl),
	.tape_turbo    (tape_turbo),
	.cas_tick      (cas_tick),
	.cpu_addr_o    (cpu_addr),
	.cpu_clken_o   (cpu_clken),

	.ext_reset_n   (~reset),

	.red           (r),
	.green         (g),
	.blue          (b),
	.vsync         (vs),
	.hsync         (hs),
	.vblank        (vblank),
	.hblank        (hblank),

	.ExternWE      (mem_we),
	.ExternA       (mem_addr),
	.ExternDin     (mem_din),
	.ExternDout    (mem_dout),
	.ExternROM     (rom_cs),

	.sid_audio_d   (sid_audio),
	.sid_audio     (),
	.atom_audio    (a_audio),

	.SDMISO        (sdmiso),
	.SDSS          (sdss),
	.SDCLK         (sdclk),
	.SDMOSI        (sdmosi),

	.cas_in        (tape_loaded ? tape_level : cas_in),
	.cas_out       (cas_out),

	.LED1          (),
	.LED2          (),
	.charSet       (charset),
	.Joystick1     (~joy1),
	.Joystick2     (~joy2),

	.avr_TxD       (),
	.avr_RxD       (1'b0)
);

//////////////////////////////  TAPE  ////////////////////////////////////////
// As AcornAtom.sv (rtl/atom_tape.sv, rtl/tape_overlay.sv).
wire        tape_at_start, tape_file_end;
wire [31:0] tape_played, tape_total;
wire        tape_hdr_ok;
wire [103:0] tape_hdr_name;
wire  [3:0] tape_hdr_len;
wire [15:0] tape_hdr_exec, tape_hdr_load;
wire        tape_info_req;
wire  [7:0] tape_info;
assign ioctl_wait = 1'b0;

atom_tape #(.CLK_HZ(31_500_000)) atom_tape (
	.clk(clk_32), .reset(reset),
	.dl(ioctl_download && ioctl_index == 8'd1), .wr(ioctl_wr), .addr(ioctl_addr), .data(ioctl_dout),
	.tick(cas_tick), .cpu_addr(cpu_addr), .cpu_ce(cpu_clken),
	.rewind(tape_rewind), .fast_sel(tape_fast_sel),
	.level(tape_level), .loaded(tape_loaded), .playing(tape_playing), .turbo(tape_turbo),
	.played(tape_played), .total(tape_total),
	.hdr_ok(tape_hdr_ok), .hdr_name(tape_hdr_name), .hdr_len(tape_hdr_len),
	.hdr_exec(tape_hdr_exec), .hdr_load(tape_hdr_load),
	.file_end(tape_file_end), .at_start(tape_at_start),
	.info_req(tape_info_req), .info(tape_info)
);

reg [7:0] lodvec_hi = 8'hF9;
always @(posedge clk_32) if (mem_we && mem_addr == 18'h0020D) lodvec_hi <= mem_din;
wire tape_hooked = lodvec_hi[7:4] != 4'hF;

wire [26*16+48:0] tape_stat;
wire        tape_req, tape_ack;
tape_status #(.CHARS(26)) tape_status (
	.clk(clk_32), .loaded(tape_loaded), .playing(tape_playing), .fast(tape_turbo),
	.played(tape_played), .total(tape_total), .at_start(tape_at_start), .file_end(tape_file_end),
	.hdr_ok(tape_hdr_ok), .hdr_name(tape_hdr_name), .hdr_len(tape_hdr_len), .hdr_exec(tape_hdr_exec),
	.hooked(tape_hooked), .bbc(bbc_mode), .ps2_key(ps2_key),
	.status(tape_stat), .req(tape_req), .ack(tape_ack)
);

wire [23:0] ov_rgb;
tape_overlay #(.CHARS(26), .FACTOR(4'd4)) tape_overlay (
	.clk(clk_42), .ce_pix(CE_PIXEL), .hblank(hblank), .vblank(vblank), .enable(tape_overlay_en),
	.status(tape_stat), .req(tape_req), .ack(tape_ack),
	.rgb_in({r[1], r[1], r[1], r[0], r[0], r[0], r, g[1], g[1], g[1], g[0], g[0], g[0], g, b[1], b[1], b[1], b[0], b[0], b[0], b}),
	.rgb_out(ov_rgb)
);

assign dbg_tape_loaded = tape_loaded;
assign dbg_tape_playing = tape_playing;
assign dbg_tape_turbo = tape_turbo;
assign dbg_tape_level = tape_level;
assign dbg_tape_hooked = tape_hooked;
assign dbg_tape_file_end = tape_file_end;
assign dbg_tape_played = tape_played;
assign dbg_tape_total = tape_total;
assign dbg_tape_info = tape_info;
assign dbg_tape_info_req = tape_info_req;

//////////////////////////////  VIDEO  ///////////////////////////////////////
// AcornAtom.sv widens the 2-bit channels the same way and inverts the syncs
// for video_mixer (the 6847 outputs them active low).
// Through the tape overlay, as AcornAtom.sv.
assign VGA_R  = ov_rgb[23:16];
assign VGA_G  = ov_rgb[15:8];
assign VGA_B  = ov_rgb[7:0];
assign VGA_HS = ~hs;
assign VGA_VS = ~vs;
assign VGA_HB = hblank;
assign VGA_VB = vblank;

//////////////////////////////  AUDIO  ///////////////////////////////////////
// rtl/audio_mix.sv, as AcornAtom.sv (signed 16-bit).
audio_mix audio_mix (
	.clk        (clk_32),
	.beeper     (a_audio),
	.sid        (sid_audio),
	.tape       (tape_playing ? tape_level : cas_out),
	.speaker_en (speaker_en),
	.sid_en     (sid_en),
	.tape_en    (tape_audio_en),
	.audio      (AUDIO_L)
);
assign AUDIO_R = AUDIO_L;

//////////////////////////////  SD CARD  /////////////////////////////////////
// As AcornAtom.sv: the AVR's SPI goes to the framework's SD-card emulation
// while a VHD is mounted, otherwise to the physical card, which the sim does
// not have (MISO high = nothing answers).
reg vsd_sel = 0;
always @(posedge clk_32) if (img_mounted[0]) vsd_sel <= |img_size;

wire vsdmiso;
assign sdmiso = vsd_sel ? vsdmiso : 1'b1;

wire sd_rd0, sd_wr0;
sd_card #(0) sd_card (
	.clk_sys      (clk_32),
	.reset        (reset),
	.sdhc         (1'b1),
	.img_mounted  (img_mounted[0]),
	.img_size     (img_size),
	.sd_lba       (sd_lba),
	.sd_rd        (sd_rd0),
	.sd_wr        (sd_wr0),
	.sd_ack       (sd_ack[0]),
	.sd_buff_addr (sd_buff_addr),
	.sd_buff_dout (sd_buff_dout),
	.sd_buff_din  (sd_buff_din),
	.sd_buff_wr   (sd_buff_wr),
	.clk_spi      (clk_32),
	.ss           (sdss | ~vsd_sel),
	.sck          (sdclk),
	.mosi         (sdmosi),
	.miso         (vsdmiso)
);
assign sd_rd = {9'b0, sd_rd0};
assign sd_wr = {9'b0, sd_wr0};

//////////////////////////////  DEBUG  ///////////////////////////////////////
assign dbg_cpu_addr  = core.cpu_addr;
assign dbg_cpu_din   = core.cpu_din;
assign dbg_cpu_dout  = core.cpu_dout;
assign dbg_cpu_rw    = core.cpu_r_w_n;
assign dbg_cpu_clken = core.cpu_clken;
assign dbg_pa        = core.i8255_pa_data;
assign dbg_irq_n     = core.mc6522_irq;
assign dbg_turbo     = core.turbo_synced;
assign dbg_sdss      = sdss;
assign dbg_vsd_sel   = vsd_sel;
assign dbg_kb_shift  = core.key_shift;
assign dbg_kb_ctrl   = core.key_ctrl;

endmodule
