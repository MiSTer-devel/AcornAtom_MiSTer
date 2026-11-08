#pragma once
#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <stdint.h>
#include "verilated.h"
#include "sim_console.h"


#ifndef _MSC_VER
#else
#define WIN32
#endif

#define kVDNUM 10
#define kBLKSZ 512

// How an image is presented to the core. This mirrors Main_MiSTer:
// .nib (and anything that is not a 16-sector image) is passed through raw;
// .dsk/.do/.po are nibblized on the fly into 6656-byte tracks
// (Main_MiSTer user_io.cpp SD_TYPE_A2 -> support/a2/dsk2nib_lib.cpp).
enum SimBlkFormat { BLK_RAW = 0, BLK_A2_DOS = 1, BLK_A2_PRODOS = 2 };

struct SimBlockDevice {
public:

	IData* sd_lba[kVDNUM];
	SData* sd_rd;
	SData* sd_wr;
	SData* sd_ack;
	SData* sd_buff_addr;
	CData* sd_buff_dout;
	CData* sd_buff_din[kVDNUM];
	CData* sd_buff_wr;
	SData* img_mounted;
	CData* img_readonly;
	QData* img_size;

	int bytecnt;
	long int disk_size[kVDNUM];
	bool reading;
	bool writing;
	int ack_delay;
	int current_disk;
	bool mountQueue[kVDNUM];

	// Options
	int  sd_ack_delay;     // cycles from sd_rd/sd_wr to sd_ack (models HPS latency)
	bool writeback;        // persist writes to the image file (false = in-memory only)
	bool verbose;          // log every block transfer
	bool legacy_interleave; // reproduce old Main_MiSTer dsk2nib sector layout (A/B testing)

	// Statistics
	long blocks_read[kVDNUM];
	long blocks_written[kVDNUM];
	long sectors_written_back[kVDNUM];

	std::string disk_name[kVDNUM];
	std::string disk_path[kVDNUM];
	SimBlkFormat format[kVDNUM];

	void BeforeEval(int cycles);
	void AfterEval(void);
	bool MountDisk(std::string file, int index);
	void EjectDisk(int index);
	bool IsMounted(int index);

	SimBlockDevice(DebugConsole c);
	~SimBlockDevice();

private:
	std::vector<uint8_t> image[kVDNUM];   // whole image file, in memory
	bool mounted[kVDNUM];
	uint8_t blkbuf[kBLKSZ];
	int cur_lba;

	// NIB write-back accumulation (one NIB track per drive)
	int      wb_track[kVDNUM];
	uint32_t wb_mask[kVDNUM];
	uint8_t  wb_nib[kVDNUM][6656];

	void ReadBlock(int i, int lba, uint8_t *buf);
	void WriteBlock(int i, int lba, const uint8_t *buf);
	void FlushRange(int i, long off, long len);
};
