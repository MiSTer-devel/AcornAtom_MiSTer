// Verilator harness for the Acorn Atom MiSTer core.
//
// Modelled on the Basic Master Jr. and TK2000 harnesses: a PS/2 keyboard, a
// VHD on the (emulated) SD card, video to a framebuffer, screenshots and typed
// input at given frame numbers.
//
//   make && ./obj_dir/Vtop                                   # windowed
//   ./obj_dir/Vtop --headless --screenshot 120 --stop-at-frame 130
//   ./obj_dir/Vtop --headless --send-keys 90:'PRINT 1+1\n' --screenshot 200 --stop-at-frame 201
//   ./obj_dir/Vtop --headless --vhd ../software/mister11/boot.vhd --send-keys 200:'*CAT\n' --screenshot 400
//
// Run it from the verilator/ directory: atom192k.hex is opened by $readmemh
// relative to the working directory.

#include <verilated.h>
#include "Vtop.h"

#if defined(__has_include)
# if __has_include("Vtop___024root.h")
#  include "Vtop___024root.h"
#  define VTOP_SPLIT_ROOT 1
# endif
#endif

#ifndef _MSC_VER
#include <SDL.h>
#include <SDL_opengl.h>
#endif

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>

#include "sim_console.h"
#include "sim_video.h"
#include "sim_input.h"
#include "sim_blkdevice.h"
#include "sim_bus.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "sim/stb_image_write.h"

// Active picture of the 6847: 256 x 192 inside a 456 x 262 frame.
// With the border (--border on): the 6847's whole visible area, 371 x 243
// (rtl/MC6847/mc6847.vhd: C_BLANK - C_BORDER_L by 26 + 192 + 25 lines).
#define VGA_WIDTH  256
#define VGA_HEIGHT 192
#define VGA_WIDTH_BORDER  371
#define VGA_HEIGHT_BORDER 243
static int vga_w = VGA_WIDTH, vga_h = VGA_HEIGHT;

// GODIL VGA80x40 (rtl/godil_vga80.sv) is 640x480 interlaced: its two fields
// are woven here by VGA_F1 (1 = the top field, picture lines 0, 2, 4 ...),
// as MiSTer's scaler does, and screenshots taken while it is on are 640x480.
#define V80_W 640
#define V80_H 480
static std::vector<uint32_t> v80_frame(V80_W * V80_H, 0xFF000000u);

// The two PLL clocks of the hardware, in picoseconds per half period.
//   clk_42: 42.954545 MHz (3 x the NTSC colour burst; the 6847 runs on an
//           enable at 14.318 MHz, its half-dots at 7.159 MHz)
//   clk_32: 32 MHz (rtl/pll_cpu.v: the CPU enable from it is 1 MHz).
// They are scheduled independently, so their relationship is the hardware's.
static const uint64_t HALF_42 = 11640;   // 23280 ps
static const uint64_t HALF_32 = 15625;   // 31250 ps
static const double   CLK32_HZ = 1e12 / (2.0 * HALF_32);

// Power-on reset: 300 us. The AVR8's reset generator and the 6502 reset
// sequence both want a few hundred cycles.
static const uint64_t RESET_PS = 300ull * 1000 * 1000;

vluint64_t main_time = 0;          // picoseconds
double sc_time_stamp() { return main_time; }

DebugConsole   console;
SimInput       input(1, console);
SimVideo       video(VGA_WIDTH, VGA_HEIGHT, 0);
SimBlockDevice blockdevice(console);
SimBus         bus(console);

Vtop* top = nullptr;

bool headless  = false;
bool trace_cpu = false;
int  trace_cpu_from = 0, trace_cpu_to = 0x7fffffff;   // frames
bool trace_sd  = false;
bool trace_key = false;
// 100 ms per key edge: the kernel's key routine waits for the release and
// debounces, and at 40 ms every other key was lost.
unsigned key_hold_cycles = (unsigned)(CLK32_HZ * 100 / 1000);
int  stop_at_frame = -1;
std::vector<int> screenshot_frames;
std::string screenshot_prefix = "screenshot_frame";
std::string screenshot_name;
std::string vhd_image;
int  vhd_at_frame = 0;

// OSD settings, as AcornAtom.sv reads them out of status
int  opt_layout   = 0;      // Keyboard: UK, US, orig, game
bool opt_charset  = false;  // character set: xtra
bool opt_border   = false;  // OSD Border: On (the sim defaults to Off: 256x192 goldens)
bool opt_dark     = false;  // Background: Dark
bool opt_bbc      = false;  // Mode: BBC
bool opt_speaker  = true;   // Audio: Speaker On
bool opt_sid      = true;   // Audio: SID On
bool opt_tape_au  = false;  // Audio: Tape audio Off
int  opt_turbo    = 0;      // CPU speed: 1 MHz (0), 2 (1), 4 (2), 8 (3)
bool trace_audio  = false;
std::vector<int> osd_break_frames;  // --osd-break N: the OSD BREAK button
std::vector<int> osd_shift_break_frames, osd_ctrl_break_frames;  // the OSD Shift-/Ctrl-BREAK buttons
std::string tape_image;             // --tape: loaded over ioctl index 1 (OSD Tape)
int  tape_at_frame = 0;
bool opt_tape_fast = true;          // OSD Tape speed: 8x
bool opt_tape_overlay = true;
bool trace_tape = false;
// --trace-video F: one line per scan line of frame F, every position in pixel
// clocks (CE_PIXEL) from the leading edge of horizontal sync (VGA_HS rises):
// the end of sync, HBLANK low (visible) and high again, the first and last
// lit pixel, the line length, and VS/VBLANK at the start of the line. Line 0
// is the first line of vertical sync.
int  trace_video_frame = -1;
int  trace_video_line  = -1;   // --trace-video F,L: also line L's lit/unlit runs
bool sloppy_shift = false;          // --sloppy-shift: let go of Shift before the key it shifts
std::vector<int> rewind_frames;

struct MemDump { int frame; unsigned addr; unsigned len; };
std::vector<MemDump> mem_dumps;
struct MemPoke { int frame; unsigned addr; std::vector<uint8_t> bytes; };
std::vector<MemPoke> mem_pokes;
std::vector<unsigned> watch_pcs;
std::vector<unsigned long long> watch_hits;
struct KeyInjection { int frame; std::string keys; };
std::vector<KeyInjection> key_injections;
struct JoyEvent { int frame; int port; unsigned buttons; };
std::vector<JoyEvent> joy_events;
static const char* const joy_names[6] = { "RIGHT", "LEFT", "DOWN", "UP", "FIRE", "B" };
std::vector<int> break_frames;      // --break N: tap F10 (BREAK)

// The 192 KB ROM/RAM image lives in sim.v (public_flat_rw), so --dump-mem and
// --poke read and write it directly. Atom addresses map 1:1 for 0000-FFFF;
// the utility-ROM banks and BBC ROMs sit above (see the map in AcornAtom.sv).
#ifdef VTOP_SPLIT_ROOT
# define ATOM_MEM top->rootp->top__DOT__mem
#else
# define ATOM_MEM top->top__DOT__mem
#endif

// ---------------------------------------------------------------------------
// Screenshots
// ---------------------------------------------------------------------------
static void save_screenshot(int frame_number, const char* name = nullptr)
{
	if (!output_ptr) { printf("screenshot: no framebuffer\n"); return; }
	char filename[512];
	if (name)                          snprintf(filename, sizeof(filename), "%s", name);
	else if (!screenshot_name.empty()) snprintf(filename, sizeof(filename), "%s", screenshot_name.c_str());
	else                               snprintf(filename, sizeof(filename), "%s_%04d.png", screenshot_prefix.c_str(), frame_number);

	const bool v80 = top->VGA80_ON;
	const int w = v80 ? V80_W : video.output_width, h = v80 ? V80_H : video.output_height;
	const uint32_t* fb = v80 ? v80_frame.data() : output_ptr;
	std::vector<uint8_t> rgb((size_t)w * h * 3);
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++) {
			uint32_t p = fb[y * w + x];             // 0xFF000000 | B<<16 | G<<8 | R
			size_t d = ((size_t)y * w + x) * 3;
			rgb[d + 0] = p & 0xFF; rgb[d + 1] = (p >> 8) & 0xFF; rgb[d + 2] = (p >> 16) & 0xFF;
		}
	if (stbi_write_png(filename, w, h, 3, rgb.data(), w * 3))
		printf("Screenshot saved: %s (frame %d, %.1f ms of machine time)\n", filename, frame_number, main_time / 1e9);
	else printf("Error: failed to write %s\n", filename);
	fflush(stdout);
}

// ---------------------------------------------------------------------------
// Keyboard injection. rtl/keyboard.sv decodes raw PS/2 set-2 codes, so we
// speak scancodes: the codes of a US PC keyboard, shift wrapped round the
// shifted ones. What the Atom makes of them depends on the OSD layout.
// ---------------------------------------------------------------------------
struct Ps2Map { unsigned code; bool shift; bool ext; };
enum { ARROW_UP = 0x11, ARROW_DOWN, ARROW_LEFT, ARROW_RIGHT, KEY_F1 = 0x01, KEY_F2, KEY_F3, KEY_F4, KEY_BREAK = 0x05, KEY_CTRL_BREAK = 0x06, KEY_F9 = 0x07, KEY_F11 = 0x0E, KEY_ESC = 0x1b };

static Ps2Map ascii_to_ps2(char c)
{
	Ps2Map m = { 0xFF, false, false };
	// rtl/keyboard.sv's UK layout expects a UK PS/2 keyboard: # on its own key
	// (0x5D; shift+3 is deliberately unmapped), @ on shift+', " on shift+2,
	// backslash on 0x61. The other layouts take the US codes below.
	if (opt_layout == 0) {
		switch (c) {
			case '#':  m.code = 0x5d; return m;
			case '@':  m.code = 0x52; m.shift = true; return m;
			case '"': m.code = 0x1e; m.shift = true; return m;
			case '\\': m.code = 0x61; return m;
		}
	}
	switch (c) {
		case ARROW_UP:    m.code = 0x75; m.ext = true; return m;
		case ARROW_DOWN:  m.code = 0x72; m.ext = true; return m;
		case ARROW_LEFT:  m.code = 0x6b; m.ext = true; return m;
		case ARROW_RIGHT: m.code = 0x74; m.ext = true; return m;
		case KEY_F1:      m.code = 0x05; return m;
		case KEY_F2:      m.code = 0x06; return m;
		case KEY_F3:      m.code = 0x04; return m;
		case KEY_F4:      m.code = 0x0c; return m;
		case KEY_BREAK:   m.code = 0x09; return m;     // F10
		case KEY_F9:      m.code = 0x01; return m;     // Shift-BREAK
		case KEY_F11:     m.code = 0x78; return m;     // Ctrl-BREAK
		case KEY_ESC:     m.code = 0x76; return m;
	}
	if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
	static const struct { char ch; unsigned sc; } letters[] = {
		{'A',0x1c},{'B',0x32},{'C',0x21},{'D',0x23},{'E',0x24},{'F',0x2b},{'G',0x34},
		{'H',0x33},{'I',0x43},{'J',0x3b},{'K',0x42},{'L',0x4b},{'M',0x3a},{'N',0x31},
		{'O',0x44},{'P',0x4d},{'Q',0x15},{'R',0x2d},{'S',0x1b},{'T',0x2c},{'U',0x3c},
		{'V',0x2a},{'W',0x1d},{'X',0x22},{'Y',0x35},{'Z',0x1a},
	};
	for (auto& l : letters) if (l.ch == c) { m.code = l.sc; return m; }
	static const unsigned digits[] = { 0x45,0x16,0x1e,0x26,0x25,0x2e,0x36,0x3d,0x3e,0x46 };
	if (c >= '0' && c <= '9') { m.code = digits[c - '0']; return m; }
	switch (c) {
		case ' ':  m.code = 0x29; break;
		case '\n': case '\r': m.code = 0x5a; break;
		case '\b': m.code = 0x66; break;
		case '\t': m.code = 0x0d; break;
		case '`':  m.code = 0x0e; break;
		case '-':  m.code = 0x4e; break;
		case '=':  m.code = 0x55; break;
		case '[':  m.code = 0x54; break;
		case ']':  m.code = 0x5b; break;
		case '\\': m.code = 0x5d; break;
		case ';':  m.code = 0x4c; break;
		case '\'': m.code = 0x52; break;
		case ',':  m.code = 0x41; break;
		case '.':  m.code = 0x49; break;
		case '/':  m.code = 0x4a; break;
		case '~':  m.code = 0x0e; m.shift = true; break;
		case '!':  m.code = 0x16; m.shift = true; break;
		case '@':  m.code = 0x1e; m.shift = true; break;
		case '#':  m.code = 0x26; m.shift = true; break;
		case '$':  m.code = 0x25; m.shift = true; break;
		case '%':  m.code = 0x2e; m.shift = true; break;
		case '^':  m.code = 0x36; m.shift = true; break;
		case '&':  m.code = 0x3d; m.shift = true; break;
		case '*':  m.code = 0x3e; m.shift = true; break;
		case '(':  m.code = 0x46; m.shift = true; break;
		case ')':  m.code = 0x45; m.shift = true; break;
		case '_':  m.code = 0x4e; m.shift = true; break;
		case '+':  m.code = 0x55; m.shift = true; break;
		case '{':  m.code = 0x54; m.shift = true; break;
		case '}':  m.code = 0x5b; m.shift = true; break;
		case '|':  m.code = 0x5d; m.shift = true; break;
		case ':':  m.code = 0x4c; m.shift = true; break;
		case '"':  m.code = 0x52; m.shift = true; break;
		case '<':  m.code = 0x41; m.shift = true; break;
		case '>':  m.code = 0x49; m.shift = true; break;
		case '?':  m.code = 0x4a; m.shift = true; break;
		default: break;
	}
	return m;
}

static void queue_key_string(const std::string& keys)
{
	const unsigned SHIFT = 0x12;
	for (char c : keys) {
		if (c == (char)KEY_CTRL_BREAK) {   // Ctrl held around F10
			input.keyEvents.push(SimInput_PS2KeyEvent(0x14, true, false, 0x14));
			input.keyEvents.push(SimInput_PS2KeyEvent(0x09, true, false, 0x09));
			input.keyEvents.push(SimInput_PS2KeyEvent(0x09, false, false, 0x09));
			input.keyEvents.push(SimInput_PS2KeyEvent(0x14, false, false, 0x14));
			continue;
		}
		Ps2Map m = ascii_to_ps2(c);
		if (m.code == 0xFF) { printf("send-keys: no mapping for '%c' (0x%02x) -- skipped\n", c, (unsigned char)c); continue; }
		if (m.shift) input.keyEvents.push(SimInput_PS2KeyEvent(SHIFT, true, false, SHIFT));
		input.keyEvents.push(SimInput_PS2KeyEvent(m.code, true,  m.ext, m.code));
		if (m.shift && sloppy_shift) input.keyEvents.push(SimInput_PS2KeyEvent(SHIFT, false, false, SHIFT));
		input.keyEvents.push(SimInput_PS2KeyEvent(m.code, false, m.ext, m.code));
		if (m.shift && !sloppy_shift) input.keyEvents.push(SimInput_PS2KeyEvent(SHIFT, false, false, SHIFT));
	}
}

// Backslash escapes accepted by --send-keys: \n \r \t \b \\ \xNN, \U \D \L \R
// arrows, \1..\4 = F1..F4 (turbo), \K = BREAK (F10), \e = Escape.
static std::string unescape(const std::string& in)
{
	std::string out;
	for (size_t i = 0; i < in.size(); i++) {
		if (in[i] != '\\' || i + 1 >= in.size()) { out += in[i]; continue; }
		char n = in[++i];
		switch (n) {
			case 'n': out += '\n'; break;
			case 'r': out += '\r'; break;
			case 't': out += '\t'; break;
			case 'b': out += '\b'; break;
			case 'e': out += (char)KEY_ESC; break;
			case '\\': out += '\\'; break;
			case 'U': out += (char)ARROW_UP; break;
			case 'D': out += (char)ARROW_DOWN; break;
			case 'L': out += (char)ARROW_LEFT; break;
			case 'R': out += (char)ARROW_RIGHT; break;
			case 'K': out += (char)KEY_BREAK; break;
			case 'k': out += (char)KEY_CTRL_BREAK; break;
			case 'S': out += (char)KEY_F9; break;
			case 'C': out += (char)KEY_F11; break;
			case '1': out += (char)KEY_F1; break;
			case '2': out += (char)KEY_F2; break;
			case '3': out += (char)KEY_F3; break;
			case '4': out += (char)KEY_F4; break;
			case 'x':
				if (i + 2 < in.size()) { out += (char)strtol(in.substr(i + 1, 2).c_str(), nullptr, 16); i += 2; }
				break;
			default: out += n; break;
		}
	}
	return out;
}

static void save_mem_dump(const MemDump& d)
{
	char filename[256];
	snprintf(filename, sizeof(filename), "memdump_%05X_%05X_f%04d.bin", d.addr, d.addr + d.len - 1, d.frame);
	FILE* f = fopen(filename, "wb");
	if (!f) { printf("dump-mem: cannot write %s\n", filename); return; }
	for (unsigned a = d.addr; a < d.addr + d.len && a < 0x30000; a++) fputc(ATOM_MEM[a], f);
	fclose(f);
	printf("Memory dump saved: %s\n", filename);
	fflush(stdout);
}

static void apply_poke(const MemPoke& q)
{
	for (size_t i = 0; i < q.bytes.size(); i++) {
		unsigned a = q.addr + (unsigned)i;
		if (a < 0x30000) ATOM_MEM[a] = q.bytes[i];
	}
	printf("Poked %zu byte(s) at $%05X\n", q.bytes.size(), q.addr);
	fflush(stdout);
}

// ---------------------------------------------------------------------------
// Simulation step: advance to the next clock edge of either clock.
// ---------------------------------------------------------------------------
static uint64_t next42 = HALF_42, next32 = HALF_32;
static uint64_t cyc32 = 0;          // clk_32 rising edges so far
static uint8_t  prev_ce = 0;
static bool     reset_done = false;

static void step()
{
	uint64_t t = std::min(next42, next32);
	main_time = t;
	bool rise42 = false, rise32 = false;
	if (next42 == t) { top->clk_42 ^= 1; rise42 = top->clk_42; next42 += HALF_42; }
	if (next32 == t) { top->clk_32 ^= 1; rise32 = top->clk_32; next32 += HALF_32; }

	if (rise32) {
		cyc32++;
		bus.BeforeEval();
		// sim_bus.cpp starts a download at address -1 (all 32 bits set) with wr high for one
		// clock; Main never writes there. Drop that write, and keep the address to 25 bits.
		if (top->ioctl_addr == 0xFFFFFFFFu) top->ioctl_wr = 0;
		top->ioctl_addr &= 0x1FFFFFF;
		if (!reset_done && main_time >= RESET_PS) { top->reset = 0; reset_done = true; }
		input.BeforeEval();
		blockdevice.BeforeEval(cyc32 > 100000000 ? 100000000 : (int)cyc32);
	}

	top->eval();

	if (rise32) {
		blockdevice.AfterEval();
		bus.AfterEval();
		if (top->dbg_tape_info_req) printf("[tape] info %d (1 ready, 2 not supported, 3 too large) total %u ticks\n", top->dbg_tape_info, top->dbg_tape_total);
		if (trace_tape) {
			static int lp = -1, lt = -1, lh = -1, le = -1, lb = -1;
			if (top->dbg_tape_playing != lp || top->dbg_tape_turbo != lt || top->dbg_tape_hooked != lh || top->dbg_tape_file != le || top->dbg_tape_between != lb) {
				lp = top->dbg_tape_playing; lt = top->dbg_tape_turbo; lh = top->dbg_tape_hooked; le = top->dbg_tape_file; lb = top->dbg_tape_between;
				printf("[tape] playing=%d turbo=%d hooked=%d file=%d between=%d played=%u/%u frame=%d\n", lp, lt, lh, le, lb,
				       top->dbg_tape_played, top->dbg_tape_total, video.count_frame);
			}
		}

		if (top->dbg_cpu_clken) {
			// One CPU cycle: the T65 samples its data bus on this enable.
			static uint64_t cpu_cycles = 0;
			cpu_cycles++;
			if (trace_cpu && video.count_frame >= trace_cpu_from && video.count_frame <= trace_cpu_to)
				printf("[cpu] %c %04X %02X\n", top->dbg_cpu_rw ? 'R' : 'W', top->dbg_cpu_addr,
				       top->dbg_cpu_rw ? top->dbg_cpu_din : top->dbg_cpu_dout);
			if (!watch_pcs.empty())
				for (size_t i = 0; i < watch_pcs.size(); i++)
					if (watch_pcs[i] == top->dbg_cpu_addr) watch_hits[i]++;
			// Report the measured CPU clock once, a second in.
			static bool reported = false;
			if (!reported && main_time >= 1000000000000ull) {
				reported = true;
				printf("[clk] CPU cycles in the first second: %llu (turbo %d)\n",
				       (unsigned long long)cpu_cycles, top->dbg_turbo);
			}
		}
		if (trace_sd) {
			static uint8_t last_ss = 0xFF, last_vsd = 0xFF;
			if (top->dbg_sdss != last_ss || top->dbg_vsd_sel != last_vsd) {
				last_ss = top->dbg_sdss; last_vsd = top->dbg_vsd_sel;
				printf("[sd] ss=%d vsd_sel=%d frame=%d\n", last_ss, last_vsd, video.count_frame);
			}
		}
		if (trace_key) {
			static uint16_t last_ps2 = 0xFFFF;
			if (top->ps2_key != last_ps2) {
				last_ps2 = top->ps2_key;
				printf("[key] ps2_key=%03X code=%02X pressed=%d frame=%d\n", top->ps2_key,
				       top->ps2_key & 0xFF, (top->ps2_key >> 9) & 1, video.count_frame);
			}
			static uint8_t last_sh = 0xFF, last_ct = 0xFF;
			if (top->dbg_kb_shift != last_sh || top->dbg_kb_ctrl != last_ct) {
				last_sh = top->dbg_kb_shift; last_ct = top->dbg_kb_ctrl;
				printf("[key] shift_n=%d ctrl_n=%d frame=%d\n", last_sh, last_ct, video.count_frame);
			}
		}
	}

	if (rise32 && trace_audio) {
		// Per frame: the range AUDIO_L covered and how often it changed.
		static int16_t amin = 32767, amax = -32768, last = 0; static unsigned changes = 0; static int frame = -1;
		int16_t a = (int16_t)top->AUDIO_L;
		if (video.count_frame != frame) {
			if (frame >= 0 && changes) printf("[audio] frame %d: min %d max %d changes %u\n", frame, amin, amax, changes);
			frame = video.count_frame; amin = 32767; amax = -32768; changes = 0;
		}
		if (a < amin) amin = a;
		if (a > amax) amax = a;
		if (a != last) { changes++; last = a; }
	}

	if (rise42) {
		// The 6847 registers a pixel on the clk_42 edge where its enable
		// (CE_PIXEL) was high, so the 1->0 edge of CE_PIXEL marks a settled pixel.
		uint8_t ce = top->CE_PIXEL;
		if (prev_ce && !ce) {
			uint32_t colour = 0xFF000000u | ((uint32_t)top->VGA_B << 16) | ((uint32_t)top->VGA_G << 8) | (uint32_t)top->VGA_R;
			video.Clock(top->VGA_HB, top->VGA_VB, top->VGA_HS, top->VGA_VS, colour);
			if (top->VGA80_ON) {
				static int vx = 0, vy = 0; static uint8_t hb0 = 1, vb0 = 1;
				if (top->VGA_VB && !vb0) vy = 0;                  // end of a field's picture
				if (top->VGA_HB && !hb0 && !top->VGA_VB) vy++;    // end of a picture line
				if (!top->VGA_HB && hb0) vx = 0;
				if (!top->VGA_HB && !top->VGA_VB) {
					int y = 2 * vy + (top->VGA_F1 ? 0 : 1);
					if (vx < V80_W && y < V80_H) v80_frame[y * V80_W + vx] = colour;
					vx++;
				}
				hb0 = top->VGA_HB; vb0 = top->VGA_VB;
			}
			if (trace_video_frame >= 0) {
				static int pos = -1, line = 0, hs_up, hb_on, hb_off, lit0, lit1, vs0, vb0;
				static uint8_t prev_hs = 0;
				static std::string runs; static int run_lit = -1, run_len = 0;
				uint8_t hs = top->VGA_HS;
				bool lit = (colour & 0x00FFFFFFu) != 0;
				if (!prev_hs && hs) {   // HS rises (sync starts): report the line that just ended
					if (pos >= 0 && video.count_frame == trace_video_frame) {
						printf("[video] line %3d len %3d hs_end %3d vis %3d..%3d lit %3d..%3d vs %d vb %d\n",
							line, pos, hs_up, hb_on, hb_off, lit0, lit1, vs0, vb0);
						if (line == trace_video_line) {
							runs += (run_lit ? "L" : "d") + std::to_string(run_len);
							printf("[video] line %3d runs from HS start: %s\n", line, runs.c_str());
						}
					}
					runs.clear(); run_lit = -1; run_len = 0;
					line = (!vs0 && top->VGA_VS) ? 0 : line + 1;
					pos = 0; hs_up = hb_on = hb_off = lit0 = lit1 = -1;
					vs0 = top->VGA_VS; vb0 = top->VGA_VB;
				}
				if (pos >= 0) {
					if (!hs && hs_up < 0) hs_up = pos;
					if (!top->VGA_HB && hb_on < 0) hb_on = pos;
					if (top->VGA_HB && hb_on >= 0 && hb_off < 0) hb_off = pos;
					if (lit) { if (lit0 < 0) lit0 = pos; lit1 = pos; }
					if ((int)lit != run_lit) {
						if (run_lit >= 0) runs += (run_lit ? "L" : "d") + std::to_string(run_len) + " ";
						run_lit = lit; run_len = 0;
					}
					run_len++;
					pos++;
				}
				prev_hs = hs;
			}
		}
		prev_ce = ce;
	}
}

static void RunBatch(int steps) { for (int i = 0; i < steps; i++) step(); }

static void mount_vhd()
{
	printf("Mounting VHD: %s\n", vhd_image.c_str());
	if (!blockdevice.MountDisk(vhd_image, 0)) printf("VHD mount failed\n");
}

static void queue_tape()
{
	// As Main does for "F1,UEFCSW": the matched extension's number in [7:6]
	std::string ext = tape_image.size() > 4 ? tape_image.substr(tape_image.size() - 4) : "";
	for (auto &c : ext) c = tolower(c);
	int index = 1 | (ext == ".csw" ? 1 << 6 : 0);
	printf("Loading tape: %s (ioctl index %d)\n", tape_image.c_str(), index);
	bus.QueueDownload(tape_image, index, true);
}

static bool frame_actions(int frame)
{
	if (!tape_image.empty() && tape_at_frame && frame == tape_at_frame) queue_tape();
	top->tape_rewind = std::find(rewind_frames.begin(), rewind_frames.end(), frame) != rewind_frames.end();
	if (!vhd_image.empty() && vhd_at_frame && frame == vhd_at_frame) mount_vhd();
	for (auto it = key_injections.begin(); it != key_injections.end(); )
		if (it->frame == frame) { printf("Injecting keys at frame %d: \"%s\"\n", frame, it->keys.c_str()); queue_key_string(it->keys); it = key_injections.erase(it); }
		else ++it;
	if (std::find(break_frames.begin(), break_frames.end(), frame) != break_frames.end()) {
		printf("BREAK at frame %d\n", frame);
		queue_key_string(std::string(1, (char)KEY_BREAK));
	}
	// The OSD BREAK button: AcornAtom.sv holds the line 150 ms, like a key press;
	// here nine frames. (BREAK resets the AtoMMC's AVR too; a shorter reset let
	// the 6502 read a stale configuration byte and auto-run *MENU.)
	{
		bool held = false;
		// Main pulses a T[n] status bit; rtl/break_keys.sv times the rest.
		top->btn_break       = std::find(osd_break_frames.begin(), osd_break_frames.end(), frame) != osd_break_frames.end();
		top->btn_shift_break = std::find(osd_shift_break_frames.begin(), osd_shift_break_frames.end(), frame) != osd_shift_break_frames.end();
		top->btn_ctrl_break  = std::find(osd_ctrl_break_frames.begin(), osd_ctrl_break_frames.end(), frame) != osd_ctrl_break_frames.end();
		(void)held;
	}
	for (const JoyEvent& e : joy_events)
		if (e.frame == frame) { if (e.port == 1) top->joy1 = e.buttons; else top->joy2 = e.buttons; }
	for (auto it = mem_pokes.begin(); it != mem_pokes.end(); )
		if (it->frame == frame) { apply_poke(*it); it = mem_pokes.erase(it); } else ++it;
	for (auto it = mem_dumps.begin(); it != mem_dumps.end(); )
		if (it->frame == frame) { save_mem_dump(*it); it = mem_dumps.erase(it); } else ++it;
	auto it = std::find(screenshot_frames.begin(), screenshot_frames.end(), frame);
	if (it != screenshot_frames.end()) { save_screenshot(frame); screenshot_frames.erase(it); }
	if (stop_at_frame >= 0 && frame >= stop_at_frame) {
		printf("Reached stop frame %d at %.1f ms of machine time, exiting\n", frame, main_time / 1e9);
		for (size_t i = 0; i < watch_pcs.size(); i++)
			printf("[watch] $%04X hit %llu times\n", watch_pcs[i], (unsigned long long)watch_hits[i]);
		return true;
	}
	return false;
}

static std::vector<int> int_list(const std::string& list)
{
	std::vector<int> out;
	for (size_t pos = 0; pos <= list.size();) {
		size_t comma = list.find(',', pos);
		std::string tok = list.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
		if (!tok.empty()) out.push_back(atoi(tok.c_str()));
		if (comma == std::string::npos) break;
		pos = comma + 1;
	}
	return out;
}

static void usage(const char* argv0)
{
	printf(
	"Acorn Atom core simulator\n"
	"\n"
	"Usage: %s [options]\n"
	"\n"
	"  --headless                 run without a window (still renders for screenshots)\n"
	"  --vhd <file>               mount a VHD on the AtoMMC SD card at start\n"
	"  --vhd-at N                 mount the --vhd image at frame N instead\n"
	"  --sd-ack-delay <cycles>    SD block latency (default 1200)\n"
	"  --screenshot N[,N,...]     write screenshot_frame_NNNN.png at these frames (60 = 1 s)\n"
	"  --screenshot-prefix <p>    file name prefix (default screenshot_frame)\n"
	"  --screenshot-name <path>   exact output path for a single --screenshot frame\n"
	"  --stop-at-frame N          exit once frame N has been reached\n"
	"  --send-keys N:string       type `string` at frame N; \\n Return, \\xNN raw code,\n"
	"                             \\U\\D\\L\\R arrows, \\1..\\4 F1-F4 (turbo), \\K BREAK (F10), \\k Ctrl+BREAK, \\S F9, \\C F11,\n"
	"                             \\e Escape. Repeatable\n"
	"  --break N[,N,...]          tap BREAK (F10) at these frames\n"
	"  --key-hold MS              how long to hold each injected key edge (default 100 ms)\n"
	"  --layout uk|us|orig|game   OSD Keyboard layout (default uk)\n"
	"  --charset original|xtra    OSD character set (default original)\n"
	"  --dark                     OSD Background: Dark\n"
	"  --border on|off            OSD Border (default off here: the goldens are 256x192;\n"
	"                             on gives 371x243 with the 6847's border)\n"
	"  --bbc                      OSD Mode: BBC (BBC BASIC ROMs)\n"
	"  --speaker on|off, --sid on|off, --tape-audio on|off   OSD Audio (defaults on, on, off)\n"
	"  --turbo 1|2|4|8            OSD CPU speed in MHz at reset (default 1; F1-F4 change it)\n"
	"  --osd-break N[,N,...]      press the OSD BREAK button at these frames\n"
	"  --osd-shift-break N[,...]  press the OSD Shift-BREAK button (AtoMMC menu)\n"
	"  --osd-ctrl-break N[,...]   press the OSD Ctrl-BREAK button (no AtoMMC ROM: the tape)\n"
	"  --trace-audio              per frame: range and change count of AUDIO_L\n"
	"  --trace-video F[,L]        frame F's line timing (sync, blank, lit pixels) in pixel\n"
	"                             clocks from the start of HS; with L, line L's lit/unlit runs\n"
	"  --tape <file.uef>          load a tape (OSD Tape, ioctl index 1) at start\n"
	"  --tape-at N                load the --tape image at frame N instead\n"
	"  --tape-speed 8x|normal     OSD Tape speed (default 8x)\n"
	"  --tape-overlay on|off      OSD Tape overlay (default on)\n"
	"  --rewind-at N[,N,...]      press OSD Rewind tape at these frames\n"
	"  --trace-tape               print deck state changes\n"
	"  --sloppy-shift             release Shift before the key it shifts (as fast typists do)\n"
	"  --joy 1|2:N:BUTTONS        joystick N from frame N, e.g. 1:300:UP+FIRE; 1:400: lets go\n"
	"  --dump-mem ADDR:LEN@FRAME  snapshot the 192K image to memdump_*.bin (hex)\n"
	"  --poke ADDR=BYTES@FRAME    write the image directly; BYTES is hex, FFx256 repeats\n"
	"  --watch-pc ADDR[,ADDR...]  count CPU accesses to these addresses (hex)\n"
	"  --trace-cpu                print every CPU bus cycle (very verbose)\n"
	"  --trace-cpu-from N / --trace-cpu-to N   limit --trace-cpu to frames N..M\n"
	"  --trace-sd                 print SD chip-select changes\n"
	"  --trace-key                print PS/2 events\n"
	"  -h, --help                 this text\n"
	"\n"
	"Run from the verilator/ directory: atom192k.hex is opened relative to cwd.\n",
	argv0);
}

int main(int argc, char** argv, char** env)
{
	Verilated::commandArgs(argc, argv);

	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&](const char* what) -> std::string {
			if (i + 1 >= argc) { printf("%s needs an argument\n", what); exit(1); }
			return argv[++i];
		};
		if      (a == "-h" || a == "--help") { usage(argv[0]); return 0; }
		else if (a == "--headless")          headless = true;
		else if (a == "--trace-cpu")         trace_cpu = true;
		else if (a == "--trace-cpu-from")    trace_cpu_from = atoi(next("--trace-cpu-from").c_str());
		else if (a == "--trace-cpu-to")      trace_cpu_to = atoi(next("--trace-cpu-to").c_str());
		else if (a == "--trace-sd")          trace_sd = true;
		else if (a == "--trace-key")         trace_key = true;
		else if (a == "--key-hold")          key_hold_cycles = (unsigned)(atof(next("--key-hold").c_str()) * CLK32_HZ / 1000.0);
		else if (a == "--vhd")               vhd_image = next("--vhd");
		else if (a == "--vhd-at")            vhd_at_frame = atoi(next("--vhd-at").c_str());
		else if (a == "--sd-ack-delay")      blockdevice.sd_ack_delay = atoi(next("--sd-ack-delay").c_str());
		else if (a == "--verbose-disk")      blockdevice.verbose = true;
		else if (a == "--screenshot-prefix") screenshot_prefix = next("--screenshot-prefix");
		else if (a == "--screenshot-name")   screenshot_name = next("--screenshot-name");
		else if (a == "--stop-at-frame")     stop_at_frame = atoi(next("--stop-at-frame").c_str());
		else if (a == "--screenshot")        screenshot_frames = int_list(next("--screenshot"));
		else if (a == "--break")             break_frames = int_list(next("--break"));
		else if (a == "--dark")              opt_dark = true;
		else if (a == "--border") {
			std::string v = next("--border");
			if (v == "on") opt_border = true; else if (v == "off") opt_border = false;
			else { printf("--border wants on or off\n"); return 1; }
		}
		else if (a == "--bbc")               opt_bbc = true;
		else if (a == "--layout") {
			std::string v = next("--layout");
			opt_layout = v == "uk" ? 0 : v == "us" ? 1 : v == "orig" ? 2 : v == "game" ? 3 : -1;
			if (opt_layout < 0) { printf("--layout wants uk, us, orig or game\n"); return 1; }
		}
		else if (a == "--charset") {
			std::string v = next("--charset");
			if (v == "original") opt_charset = false; else if (v == "xtra") opt_charset = true;
			else { printf("--charset wants original or xtra\n"); return 1; }
		}
		else if (a == "--speaker" || a == "--sid" || a == "--tape-audio") {
			std::string v = next(a.c_str());
			if (v != "on" && v != "off") { printf("%s wants on or off\n", a.c_str()); return 1; }
			bool on = v == "on";
			if (a == "--speaker") opt_speaker = on; else if (a == "--sid") opt_sid = on; else opt_tape_au = on;
		}
		else if (a == "--turbo") {
			int mhz = atoi(next("--turbo").c_str());
			opt_turbo = mhz == 1 ? 0 : mhz == 2 ? 1 : mhz == 4 ? 2 : mhz == 8 ? 3 : -1;
			if (opt_turbo < 0) { printf("--turbo wants 1, 2, 4 or 8\n"); return 1; }
		}
		else if (a == "--osd-break")        osd_break_frames = int_list(next("--osd-break"));
		else if (a == "--osd-shift-break")  osd_shift_break_frames = int_list(next("--osd-shift-break"));
		else if (a == "--osd-ctrl-break")   osd_ctrl_break_frames = int_list(next("--osd-ctrl-break"));
		else if (a == "--trace-audio")      trace_audio = true;
		else if (a == "--tape")             tape_image = next("--tape");
		else if (a == "--tape-at")          tape_at_frame = atoi(next("--tape-at").c_str());
		else if (a == "--rewind-at")        rewind_frames = int_list(next("--rewind-at"));
		else if (a == "--trace-tape")       trace_tape = true;
		else if (a == "--trace-video") {
			std::string v = next("--trace-video");
			trace_video_frame = atoi(v.c_str());
			size_t c = v.find(',');
			if (c != std::string::npos) trace_video_line = atoi(v.c_str() + c + 1);
		}
		else if (a == "--sloppy-shift")     sloppy_shift = true;
		else if (a == "--tape-speed") { std::string v = next("--tape-speed"); opt_tape_fast = v != "normal"; }
		else if (a == "--tape-overlay") { std::string v = next("--tape-overlay"); opt_tape_overlay = v != "off"; }
		else if (a == "--dump-mem") {
			std::string spec = next("--dump-mem");
			unsigned addr = 0, len = 0; int frame = 0;
			if (sscanf(spec.c_str(), "%x:%x@%d", &addr, &len, &frame) != 3) { printf("--dump-mem wants ADDR:LEN@FRAME (hex), e.g. 8000:1800@300\n"); return 1; }
			mem_dumps.push_back({ frame, addr, len });
		}
		else if (a == "--poke") {
			std::string spec = next("--poke");
			size_t eq = spec.find('='), at = spec.rfind('@');
			if (eq == std::string::npos || at == std::string::npos || at < eq) { printf("--poke wants ADDR=BYTE[,BYTE...]@FRAME\n"); return 1; }
			MemPoke q;
			q.addr  = strtoul(spec.substr(0, eq).c_str(), nullptr, 16);
			q.frame = atoi(spec.substr(at + 1).c_str());
			std::string list = spec.substr(eq + 1, at - eq - 1);
			for (size_t pos = 0; pos <= list.size();) {
				size_t comma = list.find(',', pos);
				std::string tok = list.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
				if (!tok.empty()) {
					size_t x = tok.find('x');
					uint8_t v = (uint8_t)strtoul(tok.substr(0, x).c_str(), nullptr, 16);
					unsigned rep = (x == std::string::npos) ? 1 : strtoul(tok.substr(x + 1).c_str(), nullptr, 10);
					for (unsigned r = 0; r < rep; r++) q.bytes.push_back(v);
				}
				if (comma == std::string::npos) break;
				pos = comma + 1;
			}
			mem_pokes.push_back(q);
		}
		else if (a == "--watch-pc") {
			std::string list = next("--watch-pc");
			for (size_t pos = 0; pos <= list.size();) {
				size_t comma = list.find(',', pos);
				std::string tok = list.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
				if (!tok.empty()) { watch_pcs.push_back(strtoul(tok.c_str(), nullptr, 16)); watch_hits.push_back(0); }
				if (comma == std::string::npos) break;
				pos = comma + 1;
			}
		}
		else if (a == "--send-keys") {
			std::string spec = next("--send-keys");
			size_t colon = spec.find(':');
			if (colon == std::string::npos) { printf("--send-keys wants FRAME:string\n"); return 1; }
			key_injections.push_back({ atoi(spec.substr(0, colon).c_str()), unescape(spec.substr(colon + 1)) });
		}
		else if (a == "--joy") {
			std::string spec = next("--joy");
			int port = 0, frame = 0; char buttons[64] = "";
			if (sscanf(spec.c_str(), "%d:%d:%63s", &port, &frame, buttons) < 2 || (port != 1 && port != 2)) { printf("--joy wants 1|2:FRAME:BUTTONS\n"); return 1; }
			JoyEvent e = { frame, port, 0 };
			std::string list = buttons;
			for (size_t pos = 0; pos < list.size();) {
				size_t plus = list.find('+', pos);
				std::string tok = list.substr(pos, plus == std::string::npos ? std::string::npos : plus - pos);
				int b = 0;
				while (b < 6 && tok != joy_names[b]) b++;
				if (b == 6) { printf("--joy: unknown button '%s'\n", tok.c_str()); return 1; }
				e.buttons |= 1u << b;
				if (plus == std::string::npos) break;
				pos = plus + 1;
			}
			joy_events.push_back(e);
		}
		else { printf("Unknown option: %s (try --help)\n", a.c_str()); return 1; }
	}
	if (!screenshot_name.empty() && screenshot_frames.size() != 1) { printf("--screenshot-name needs exactly one --screenshot frame\n"); return 1; }

	top = new Vtop();

	input.ps2_key      = &top->ps2_key;
	input.keyEventWait = key_hold_cycles;

	blockdevice.sd_lba[0]      = &top->sd_lba;
	blockdevice.sd_rd          = &top->sd_rd;
	blockdevice.sd_wr          = &top->sd_wr;
	blockdevice.sd_ack         = &top->sd_ack;
	blockdevice.sd_buff_addr   = &top->sd_buff_addr;
	blockdevice.sd_buff_dout   = &top->sd_buff_dout;
	blockdevice.sd_buff_din[0] = &top->sd_buff_din;
	blockdevice.sd_buff_wr     = &top->sd_buff_wr;
	blockdevice.img_mounted    = &top->img_mounted;
	blockdevice.img_readonly   = &top->img_readonly;
	blockdevice.img_size       = &top->img_size;

	top->clk_42 = 0; top->clk_32 = 0;
	top->reset = 1;
	top->ps2_key = 0;
	top->joy1 = 0; top->joy2 = 0;
	top->layout = opt_layout;
	top->charset = opt_charset;
	top->dark_background = opt_dark;
	top->border_en = opt_border;
	if (opt_border) { vga_w = VGA_WIDTH_BORDER; vga_h = VGA_HEIGHT_BORDER; video = SimVideo(vga_w, vga_h, 0); }
	top->bbc_mode = opt_bbc;
	top->speaker_en = opt_speaker;
	top->sid_en = opt_sid;
	top->tape_audio_en = opt_tape_au;
	top->turbo_default = opt_turbo;
	top->btn_break = 0;
	top->btn_shift_break = 0;
	top->btn_ctrl_break = 0;
	top->tape_fast_sel = opt_tape_fast;
	top->tape_rewind = 0;
	top->tape_overlay_en = opt_tape_overlay;
	bus.ioctl_addr = &top->ioctl_addr;
	bus.ioctl_index = &top->ioctl_index;
	bus.ioctl_wait = &top->ioctl_wait;
	bus.ioctl_download = &top->ioctl_download;
	bus.ioctl_wr = &top->ioctl_wr;
	bus.ioctl_dout = &top->ioctl_dout;
	if (!tape_image.empty() && tape_at_frame == 0) queue_tape();
	top->cas_in = 0;

	if (!vhd_image.empty() && vhd_at_frame == 0) mount_vhd();

	if (!headless) {
		input.Initialise();
		if (video.Initialise("Acorn Atom") == 1) return 1;
	} else if (!output_ptr) {
		output_width  = vga_w;
		output_height = vga_h;
		output_ptr = (uint32_t*)calloc((size_t)output_width * output_height, 4);
		if (!output_ptr) { fprintf(stderr, "framebuffer alloc failed\n"); return 2; }
	}

	if (headless) {
		printf("Headless mode.\n");
		int last_frame = -1;
		while (true) {
			RunBatch(4096);
			if (video.count_frame != last_frame) {
				last_frame = video.count_frame;
				if (frame_actions(last_frame)) return 0;
			}
		}
	}

#ifndef _MSC_VER
	bool done = false, run_enable = true;
	int last_frame = -1;
	while (!done) {
		SDL_Event event;
		while (SDL_PollEvent(&event)) {
			ImGui_ImplSDL2_ProcessEvent(&event);
			if (event.type == SDL_QUIT) done = true;
		}
		video.StartFrame();
		ImGui::NewFrame();
		input.Read();
		if (run_enable) RunBatch(200000);
		if (video.count_frame != last_frame) {
			last_frame = video.count_frame;
			if (frame_actions(last_frame)) done = true;
		}
		ImGui::Begin("Machine");
		ImGui::Text("Frame %d   %.1f fps", video.count_frame, video.stats_fps);
		ImGui::Text("CPU  A=%04X  D=%02X  %s  turbo=%d", top->dbg_cpu_addr,
		            top->dbg_cpu_rw ? top->dbg_cpu_din : top->dbg_cpu_dout, top->dbg_cpu_rw ? "R" : "W", top->dbg_turbo);
		ImGui::Text("8255 PA=%02X (row %d, mode %d%s)  IRQ=%d  SD ss=%d vhd=%d", top->dbg_pa, top->dbg_pa & 15,
		            (top->dbg_pa >> 5) & 7, (top->dbg_pa & 0x10) ? " graphics" : " text", !top->dbg_irq_n, top->dbg_sdss, top->dbg_vsd_sel);
		ImGui::Checkbox("Run", &run_enable);
		if (ImGui::Button("Reset")) { top->reset = 1; reset_done = false; next42 = main_time + HALF_42; next32 = main_time + HALF_32; main_time = 0; next42 = HALF_42; next32 = HALF_32; }
		ImGui::SameLine();
		if (ImGui::Button("Screenshot")) save_screenshot(video.count_frame);
		ImGui::End();
		ImGui::Begin("Video");
		ImGui::Image(video.texture_id, ImVec2(vga_w * 3, vga_h * 3));
		ImGui::End();
		console.Draw("Log", nullptr, ImVec2(500, 400));
		video.UpdateTexture();
	}
	video.CleanUp();
	input.CleanUp();
#endif
	return 0;
}
