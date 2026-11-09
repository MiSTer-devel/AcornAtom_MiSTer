//============================================================================
//  Acorn Atom port to MiSTer
//  2020 Dave Wood
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================


module emu
(
	`include "sys/emu_ports.vh"
);


assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign UART_RTS = UART_CTS;
assign UART_DTR = UART_DSR;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
assign UART_TXD = 0;
//assign LED_USER  = 0;
assign LED_DISK  = {1'b1,~vsd_sel & sd_act};
assign LED_POWER = 0;
assign BUTTONS   = 0;

assign VGA_DISABLE = 0;
assign VGA_SCALER = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire [1:0] ar = cfg[12:11];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;


`include "build_id.v" 
// Laid out per ~/dev2/osd-standard.md: media on the top page, settings on
// pages P1 Machine / P2 Video / P3 Input / P4 Audio, every setting except
// Input latched at reset (cfg below), "Changes pending" + "Apply and reset".
// Status bits 1-12 keep their old meaning; 4/5 changed from an audio source
// select to Speaker/SID enables (v,1), and Keyboard layout's values were
// reordered to put PC (US) first (v,2).
parameter CONF_STR = {
	"AcornAtom;;",
	"-;",
	"SC0,VHD,Pri. disk (SD);",
	"F1,UEFCSW,Tape;",
	"F0,ROM,Load ROM;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"P4,Audio;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P1O[10],Model,Atom,Atom (BBC BASIC);",
	"P1O[14:13],CPU speed,1 MHz,2 MHz,4 MHz,8 MHz;",
	"P1O[17],Tape speed,8x,Normal;",
	"P1-;",
	"P1T[15],BREAK;",
	"P1T[20],Shift-BREAK (menu);",
	"P1T[21],Ctrl-BREAK (no MMC);",
	"P1T[18],Rewind tape;",

	"P2O[12:11],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[3:1],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P2O[8],Character set,Original,Xtra;",
	"P2O[9],Background,Black,Dark;",
	"P2O[19],Tape overlay,On,Off;",

	"P3O[7:6],Keyboard layout,PC (US),PC (UK),Atom (original),Atom (game);",
	"P3O[22],Swap Alt/Win keys,No,Yes;",

	"P4O[4],Speaker,On,Off;",
	"P4O[5],SID,On,Off;",
	"P4O[16],Tape audio,Off,On;",

	"I,Tape ready (rewound),Tape format not supported,Tape too large;",
	"JA,Fire;",
	"v,2;",
	"V,v",`BUILD_DATE
};

/////////////////  CLOCKS  ////////////////////////
// clk_42 (42.954545 MHz) runs the 6847; clk_32 (exactly 32 MHz) runs the
// CPU side, divided by 32 for the Atom's 1 MHz. They come from two PLLs:
// one integer VCO cannot make both (rtl/pll_cpu.v). rtl/pll's other two
// outputs (31.5 and 16 MHz, the old CPU clock and an unused one) are left
// unconnected.
wire clk_main = clk_sys;
wire clk_sys = clk_32;
wire clk_32;
wire clk_42;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_42)
);

pll_cpu pll_cpu
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_32)
);

reg clk_14M318_ena ;
reg [1:0] count;


always @(posedge clk_42)
begin
	if (reset)
		count<=0;
	else
	begin
		clk_14M318_ena <= 0;
		if (count == 'd2)
		begin
		  clk_14M318_ena <= 1;
        count <= 0;
		end
		else
		begin
			count<=count+1;
		end
	end
end



/////////////////  HPS  ///////////////////////////

wire [127:0] status;

// Tape deck signals used by hps_io and the core (the deck is under TAPE below)
wire        cas_tick, cpu_clken;
wire [15:0] cpu_addr;
wire        tape_level, tape_loaded, tape_playing, tape_turbo;
wire        tape_info_req;
wire  [7:0] tape_info;

// The settings the machine runs with, taken from the OSD at every reset
// (Apply and reset, the board's reset, a core reload, a ROM load). Input
// settings (keyboard layout, 7:6), the triggers (BREAK 15, Rewind tape 18)
// and the tape rows (Tape audio 16, Tape speed 17, Tape overlay 19: they act
// at once or when the deck next starts, per the tape standard) read status
// directly and stay out of the pending compare.
reg  [127:0] cfg = 0;
always @(posedge clk_sys) if (reset) cfg <= status;
wire pending = {status[14:13], status[12:8], status[5:1]}
            != {cfg[14:13],    cfg[12:8],    cfg[5:1]};
wire  [1:0] buttons;

wire [15:0] joy1, joy2;

wire [10:0] ps2_key;

// Swap Alt/Win (OSD): Left Alt (#011) <-> Left Win (#11F), Right Alt (#111,
// REPEAT) <-> Right Win (#127), for keyboards whose Alt key is out of reach
// (a Mac keyboard's Cmd sends Win).
wire [8:0] ps2_code = ps2_key[8:0];
wire [8:0] ps2_code_sw =
	!status[22]           ? ps2_code :
	ps2_code == 9'h011    ? 9'h11F :
	ps2_code == 9'h11F    ? 9'h011 :
	ps2_code == 9'h111    ? 9'h127 :
	ps2_code == 9'h127    ? 9'h111 : ps2_code;
wire [10:0] ps2_key_core = {ps2_key[10:9], ps2_code_sw};
wire [24:0] ps2_mouse;

wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire [7:0]  ioctl_dout;
wire        tape_wait;                   // the tape deck expands a gzipped tape as it downloads
wire        forced_scandoubler;
wire [21:0] gamma_bus;
wire        direct_video;

wire [31:0] sd_lba[1];
wire        sd_rd;
wire        sd_wr;
wire        sd_ack;
wire  [8:0] sd_buff_addr;
wire [7:0]  sd_buff_dout;
wire [7:0]  sd_buff_din[1];
wire        sd_buff_wr;
wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;


wire ps2_clk,ps2_data;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),


	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, pending}),
	.info_req(tape_info_req),
	.info(tape_info),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.ps2_kbd_clk_out(ps2_clk),
	.ps2_kbd_data_out(ps2_data),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(tape_wait),
	
	//.uart_mode(16'b000_11111_000_11111),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),

	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.joystick_0(joy1),
	.joystick_1(joy2)
);

/////////////////  RESET  /////////////////////////

// A ROM load (index 0) holds the machine in reset; a tape (index 1) does not.
wire reset = RESET | status[0] | buttons[1] | (ioctl_download && ioctl_index == 8'd0);

////////////////  MEMORY  /////////////////////////

/* MAP

64k Atom memory map
00000 ram 
01000 ram
02000 ram
03000 ram
04000 ram
05000 ram
06000 ram
07000 ram

08000 ram video
09000 ram video
0A000 ram/rom used for paging 8 additional roms
0B000 bran_b010.rom + I/O
0C000 abasic.rom
0D000 afloat_patched_b010.rom
0E000 atommc3_avr.rom
0F000 akernel_patched.rom

 additional roms - slot 7 is ram and can be filled with utility rom download
10000 axr1.rom
11000 pcharme_v1.73.rom
12000 atomic_windows_v1.1.rom
13000 gags_v2.3.rom
14000 pp_toolkit.rom
15000 we_rom.rom
16000 fpgautil.rom
17000 ram

18000-1f000 space - filler

64k Atom memory map with BBC basic and mmc roms
20000 ram
21000 ram
22000 ram
23000 ram
24000 ram
25000 ram
26000 atom_bbc_ext1.rom
27000 atom_bbc_ext2_avr.rom

28000 ram video
29000 ram video
2A000 bbc_a000.rom
2B000 I/O
2C000 bbc_c000.rom
2D000 bbc_d000.rom
2E000 bbc_e000.rom
2F000 bbc_f000.rom
*/

wire        mem_we,rom_cs;
wire [17:0] mem_addr;
wire  [7:0] mem_din,mem_dout;


// Load ROM (F0, and games/AcornAtom/boot0.rom at start): a whole 192 KB image
// in the layout of roms/ATOM192k.mif, written over the mif contents while the
// machine is held in reset (reset includes that download).
// Only the ROM download (index 0) takes the RAM: a tape download must not
// change what the running CPU reads.
wire        rom_dl   = ioctl_download && ioctl_index == 8'd0;
wire [17:0] ram_addr = rom_dl ? ioctl_addr[17:0] : mem_addr;
wire  [7:0] ram_din  = rom_dl ? ioctl_dout       : mem_din;
wire        ram_we   = rom_dl ? (ioctl_wr && ioctl_addr < 25'd196608) : mem_we;

spram #(8, 18, 196608, "roms/ATOM192k.mif") rom
(
	.clock(clk_main),
	.address(ram_addr),
	.data(ram_din),
	.wren(ram_we),
	.q(mem_dout)
);

// BREAK, Shift-BREAK, Ctrl-BREAK: OSD buttons T[15], T[20], T[21] and the keys
// F10, F9, F11 (rtl/break_keys.sv).
wire osd_break, osd_shift, osd_ctrl;
break_keys break_keys
(
	.clk_sys(clk_sys),
	.btn_break(status[15]),
	.btn_shift_break(status[20]),
	.btn_ctrl_break(status[21]),
	.ps2_key(ps2_key),
	.osd_break(osd_break),
	.osd_shift(osd_shift),
	.osd_ctrl(osd_ctrl)
);


///////////////////////////////////////////////////

wire charset = cfg[8];

wire tape_out;
wire pixel_clock;
AtomFpga_Core AcornAtom
(
			// clocks
			
	.clk_vid(clk_42),
	.clk_vid_en(clk_14M318_ena),
	.clk_main(clk_main),
	.clk_dac(clk_sys),  // -2.202 setup slack
	.clk_avr(clk_main), // this helps timing
	
	.pixel_clock(pixel_clock),
	
        // Keyboard
	.ps2_key(ps2_key_core),
	// OSD order PC (US), PC (UK), Atom (original), Atom (game); rtl/keyboard.sv's
	// encoding is 0 UK, 1 US, 2 original, 3 game.
	.layout(status[7:6] == 2'd0 ? 2'd1 : status[7:6] == 2'd1 ? 2'd0 : status[7:6]),
	.BLACK_BACKGND(~cfg[9]),
	.computer(cfg[10]),
	.turbo_default(cfg[14:13]),
	.osd_break(osd_break),
	.osd_shift(osd_shift),
	.osd_ctrl(osd_ctrl),
	.tape_turbo(tape_turbo),
	.cas_tick(cas_tick),
	.cpu_addr_o(cpu_addr),
	.cpu_clken_o(cpu_clken),

        // Mouse
//   .ps2_mouse_clk(mse_clk),	//  : inout std_logic;
//   .ps2_mouse_data(mse_clk),	// : inout std_logic;
	
		//resets
//	.powerup_reset_n(~RESET),
	.ext_reset_n(~reset),
//	.int_reset_n(),

    // VGA
	.red(r),
        .green(g),
	.blue(b),
	.hsync(hs),
	.vsync(vs),
	.hblank(hblank),
	.vblank(vblank),
	
		// External 6502 bus interface
//	.phi2(),
//	.sync(),
//	.rnw(),
//	.blk_b(),
//	.addr(),
//	.rdy(1'b1),
//	.so(1'b1),
//	.irq_n(1'b1),
//	.nmi_n(1'b1),
	
		// External Bus/Ram/Rom interface
//	.ExternBus(),
//	.ExternCE(),
	.ExternROM(rom_cs),
	.ExternWE(mem_we),
	.ExternDout(mem_dout),
	.ExternDin(mem_din),
	.ExternA(mem_addr),


        // Audio
	.atom_audio(a_audio),	//          : out   std_logic;
	.sid_audio(),
	.sid_audio_d(sid_audio),
	
        // SD Card
	.SDCLK(sdclk),	//        : out   std_logic;
	.SDSS(sdss),	//         : out   std_logic;
	.SDMOSI(sdmosi),	//       : out   std_logic;
	.SDMISO(sdmiso),	//       : in    std_logic;

        // Serial
//   .uart_TxD(),	//      : out   std_logic;
//   .uart_RxD(1'B0),	//      : in    std_logic;
	
        // Cassette
	.cas_in(tape_loaded ? tape_level : tape_adc),
	.cas_out(tape_out),	//        : out   std_logic;
	
		// Misc
	.LED1(LED_USER),
	.LED2(),
	.charset(charset),
	.Joystick1(~joy1),
	.Joystick2(~joy2),


        // USB Uart on FPGA Module
   .avr_TxD(),     //       : out   std_logic;
   .avr_RxD(1'b0)  //       : in    std_logic

);

wire [17:0] sid_audio;
wire a_audio;

// Mixed, not selected (rtl/audio_mix.sv): beeper + SID + tape tone, each with
// its OSD enable, signed 16-bit.
wire [15:0] audio_mixed;
audio_mix audio_mix
(
	.clk(clk_sys),
	.beeper(a_audio),
	.sid(sid_audio),
	.tape(tape_playing ? tape_level : tape_out),
	.speaker_en(~cfg[4]),
	.sid_en(~cfg[5]),
	.tape_en(status[16]),
	.audio(audio_mixed)
);
assign AUDIO_L = audio_mixed;
assign AUDIO_R = audio_mixed;
assign AUDIO_MIX = 0;
assign AUDIO_S = 1'b1;

wire hs, vs, hblank, vblank,  clk_sel;
wire [1:0] r,g,b;

assign CLK_VIDEO = clk_42;// clk_25;
wire freeze_sync;



/////////////////  TAPE  ///////////////////////////
// rtl/atom_tape.sv: a UEF in block RAM played into the cassette input; the deck
// plays while the CPU runs the kernel's tape-read routine (no motor relay on the
// Atom) and turbo (8x) follows it. rtl/tape_overlay.sv: status bar and hint.
wire        tape_between, tape_prev_basic;
wire  [4:0] tape_file_idx;
wire [31:0] tape_played, tape_total;
wire        tape_hdr_ok;
wire [103:0] tape_hdr_name;
wire  [3:0] tape_hdr_len;
wire [15:0] tape_hdr_exec, tape_hdr_load, tape_file_lo;
wire [16:0] tape_file_hi;
atom_tape #(.CLK_HZ(32_000_000)) atom_tape
(
	.clk(clk_sys),
	.reset(reset),
	// [7:6] is which extension of "UEFCSW" the file matched (Main does that
	// when an F entry lists several)
	.dl_in(ioctl_download && ioctl_index[5:0] == 6'd1),
	.wr_in(ioctl_wr),
	.addr_in(ioctl_addr),
	.data_in(ioctl_dout),
	.dl_wait(tape_wait),
	.tick(cas_tick),
	.cpu_addr(cpu_addr),
	.cpu_ce(cpu_clken),
	.rewind(status[18]),
	.fast_sel(~status[17]),
	.level(tape_level),
	.loaded(tape_loaded),
	.playing(tape_playing),
	.turbo(tape_turbo),
	.played(tape_played),
	.total(tape_total),
	.hdr_ok(tape_hdr_ok),
	.hdr_name(tape_hdr_name),
	.hdr_len(tape_hdr_len),
	.hdr_exec(tape_hdr_exec),
	.hdr_load(tape_hdr_load),
	.file_lo(tape_file_lo),
	.file_hi(tape_file_hi),
	.between(tape_between),
	.prev_basic(tape_prev_basic),
	.file_idx(tape_file_idx),
	.info_req(tape_info_req),
	.info(tape_info)
);

// Is the AtoMMC ROM in the way? It points LODVEC (#020C) into its own ROM at
// #E000; Ctrl-BREAK leaves the kernel's (#F...). Watched on RAM writes.
reg [7:0] lodvec_hi = 8'hF9;
always @(posedge clk_sys) if (mem_we && mem_addr == 18'h0020D) lodvec_hi <= mem_din;
wire tape_hooked = lodvec_hi[7:4] != 4'hF;

wire [28*16+48:0] tape_stat;
wire        tape_req, tape_ack;
tape_status #(.CHARS(28)) tape_status
(
	.clk(clk_sys),
	.loaded(tape_loaded),
	.playing(tape_playing),
	.fast(tape_turbo),
	.played(tape_played),
	.total(tape_total),
	.between(tape_between),
	.prev_basic(tape_prev_basic),
	.file_idx(tape_file_idx),
	.hdr_ok(tape_hdr_ok),
	.hdr_name(tape_hdr_name),
	.hdr_len(tape_hdr_len),
	.hdr_exec(tape_hdr_exec),
	.file_lo(tape_file_lo),
	.file_hi(tape_file_hi),
	.hooked(tape_hooked),
	.bbc(cfg[10]),
	.ps2_key(ps2_key),
	.status(tape_stat),
	.req(tape_req),
	.ack(tape_ack)
);

wire [23:0] ov_rgb;
tape_overlay #(.CHARS(28), .FACTOR(4'd8)) tape_overlay
(
	.clk(clk_42),
	.ce_pix(pixel_clock),
	.hblank(hblank),
	.vblank(vblank),
	.enable(~status[19]),
	.status(tape_stat),
	.req(tape_req),
	.ack(tape_ack),
	.rgb_in({r[1],r[1],r[1],r[0],r[0],r[0],r, g[1],g[1],g[1],g[0],g[0],g[0],g, b[1],b[1],b[1],b[0],b[0],b[0],b}),
	.rgb_out(ov_rgb)
);

video_mixer #(.GAMMA(1)) video_mixer
(
   .*,

   .CLK_VIDEO(CLK_VIDEO),
   .ce_pix(pixel_clock),

	.hq2x(scale==1),


	.R(ov_rgb[23:16]),
	.G(ov_rgb[15:8]),
	.B(ov_rgb[7:0]),

   .HSync(~hs),
   .VSync(~vs),
   .HBlank(hblank),
   .VBlank(vblank)
);



assign VGA_F1 = 0;
reg [2:0] scale;
always @(posedge clk_42) scale = cfg[3:1];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;
wire       scandoubler = (scale || forced_scandoubler);
assign VGA_SL = sl[1:0];

//////////////////   SD   ///////////////////

wire sdclk;
wire sdmosi;
wire sdmiso = vsd_sel ? vsdmiso : SD_MISO;
wire sdss;

reg vsd_sel = 0;
always @(posedge clk_sys) if(img_mounted) vsd_sel <= |img_size;

wire vsdmiso;
sd_card #(0) sd_card
(
	.*,

	.sd_lba(sd_lba[0]),
	.sd_buff_din(sd_buff_din[0]),

	.clk_spi(clk_sys),
	.sdhc(1),
	.sck(sdclk),
	.ss(sdss | ~vsd_sel),
	.mosi(sdmosi),
	.miso(vsdmiso)
);

assign SD_CS   = sdss   |  vsd_sel;
assign SD_SCK  = sdclk  & ~vsd_sel;
assign SD_MOSI = sdmosi & ~vsd_sel;

reg sd_act;

always @(posedge clk_sys) begin
	reg old_mosi, old_miso;
	integer timeout = 0;

	old_mosi <= sdmosi;
	old_miso <= sdmiso;

	sd_act <= 0;
	if(timeout < 2000000) begin
		timeout <= timeout + 1;
		sd_act <= 1;
	end

	if((old_mosi ^ sdmosi) || (old_miso ^ sdmiso)) timeout <= 0;
end

wire tape_adc, tape_adc_act;
ltc2308_tape ltc2308_tape
(
	.clk(CLK_50M),
	.ADC_BUS(ADC_BUS),
	.dout(tape_adc),
	.active(tape_adc_act)
);


endmodule

//////////////////////////////////////////////

module spram #(parameter DATAWIDTH=8, ADDRWIDTH=8, NUMWORDS=1<<ADDRWIDTH, MEM_INIT_FILE="")
(
	input	                 clock,
	input	 [ADDRWIDTH-1:0] address,
	input	 [DATAWIDTH-1:0] data,
	input	                 wren,
	output [DATAWIDTH-1:0] q
);

altsyncram altsyncram_component
(
	.address_a (address),
	.clock0 (clock),
	.data_a (data),
	.wren_a (wren),
	.q_a (q),
	.aclr0 (1'b0),
	.aclr1 (1'b0),
	.address_b (1'b1),
	.addressstall_a (1'b0),
	.addressstall_b (1'b0),
	.byteena_a (1'b1),
	.byteena_b (1'b1),
	.clock1 (1'b1),
	.clocken0 (1'b1),
	.clocken1 (1'b1),
	.clocken2 (1'b1),
	.clocken3 (1'b1),
	.data_b (1'b1),
	.eccstatus (),
	.q_b (),
	.rden_a (1'b1),
	.rden_b (1'b1),
	.wren_b (1'b0)
);

defparam
	altsyncram_component.clock_enable_input_a = "BYPASS",
	altsyncram_component.clock_enable_output_a = "BYPASS",
	altsyncram_component.init_file = MEM_INIT_FILE,
	altsyncram_component.intended_device_family = "Cyclone V",
	altsyncram_component.lpm_type = "altsyncram",
	altsyncram_component.numwords_a = NUMWORDS,
	altsyncram_component.operation_mode = "SINGLE_PORT",
	altsyncram_component.outdata_aclr_a = "NONE",
	altsyncram_component.outdata_reg_a = "UNREGISTERED",
	altsyncram_component.power_up_uninitialized = "FALSE",
	altsyncram_component.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
	altsyncram_component.widthad_a = ADDRWIDTH,
	altsyncram_component.width_a = DATAWIDTH,
	altsyncram_component.width_byteena_a = 1;


endmodule
