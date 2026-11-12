#include <iostream>
#include <queue>
#include <string>

#include "sim_blkdevice.h"
#include "sim_console.h"
#include "verilated.h"
#include "a2_nib_codec.h"
#include <cstring>
#include <iterator>

#ifndef _MSC_VER
#else
#define WIN32
#endif


static DebugConsole console;

IData* sd_lba[kVDNUM]= {NULL,NULL,NULL,NULL,NULL,
                   NULL,NULL,NULL,NULL,NULL};
SData* sd_rd=NULL;
SData* sd_wr=NULL;
SData* sd_ack=NULL;
SData* sd_buff_addr=NULL;
CData* sd_buff_dout=NULL;
CData* sd_buff_din[kVDNUM]= {NULL,NULL,NULL,NULL,NULL,
                   NULL,NULL,NULL,NULL,NULL};
CData* sd_buff_wr=NULL;
SData* img_mounted=NULL;
CData* img_readonly=NULL;
QData* img_size=NULL;


#define bitset(byte,nbit)   ((byte) |=  (1<<(nbit)))
#define bitclear(byte,nbit) ((byte) &= ~(1<<(nbit)))
#define bitflip(byte,nbit)  ((byte) ^=  (1<<(nbit)))
#define bitcheck(byte,nbit) ((byte) &   (1<<(nbit)))


static std::string lower_ext(const std::string &f) {
	size_t dot = f.find_last_of('.');
	if (dot == std::string::npos) return "";
	std::string e = f.substr(dot + 1);
	for (auto &c : e) c = tolower(c);
	return e;
}

bool SimBlockDevice::MountDisk(std::string file, int index) {
	std::ifstream in(file.c_str(), std::ios::in | std::ios::binary);
	if (!in) {
		fprintf(stderr, "BLKDEV ERROR: failed to open %s\n", file.c_str());
		return false;
	}
	bool was_mounted = mounted[index];
	image[index].assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
	disk_path[index] = file;
	size_t slash = file.find_last_of("/\\");
	disk_name[index] = (slash == std::string::npos) ? file : file.substr(slash + 1);

	// Same classification as Main_MiSTer for the TK2000 core: .dsk/.do/.po are
	// 16-sector images nibblized on the fly; everything else is raw (.nib).
	std::string ext = lower_ext(file);
	long sz = (long)image[index].size();
	format[index] = BLK_RAW;
	if (ext == "dsk" || ext == "do") format[index] = BLK_A2_DOS;
	if (ext == "po") format[index] = BLK_A2_PRODOS;
	if (format[index] != BLK_RAW && sz == A2NIB_IMAGE_SIZE) {
		printf("BLKDEV: %s is NIB-sized (%ld) despite .%s extension; passing through raw\n",
		       disk_name[index].c_str(), sz, ext.c_str());
		format[index] = BLK_RAW;
	}
	if (format[index] != BLK_RAW && sz < A2NIB_DSK_IMAGE_SIZE) {
		printf("BLKDEV: WARNING %s is %ld bytes (< %d); missing sectors read as zero\n",
		       disk_name[index].c_str(), sz, A2NIB_DSK_IMAGE_SIZE);
	}
	if (format[index] == BLK_RAW && sz != A2NIB_IMAGE_SIZE) {
		printf("BLKDEV: WARNING %s is %ld bytes, not a 35-track NIB (%d)\n",
		       disk_name[index].c_str(), sz, A2NIB_IMAGE_SIZE);
	}

	disk_size[index] = sz;
	mounted[index] = true;
	mountQueue[index] = 1;
	wb_track[index] = -1;
	wb_mask[index] = 0;
	printf("BLKDEV: drive %d %s %s (%ld bytes, %s)\n", index, was_mounted ? "swapped to" : "inserted",
	       disk_name[index].c_str(), sz,
	       format[index] == BLK_RAW ? "raw" : format[index] == BLK_A2_DOS ? "DOS-order nibblized" : "ProDOS-order nibblized");
	return true;
}

void SimBlockDevice::EjectDisk(int index) {
	image[index].clear();
	mounted[index] = false;
	disk_size[index] = 0;
	disk_name[index].clear();
	mountQueue[index] = 1;   // mount pulse with size 0 -> core sees unmount
	printf("BLKDEV: drive %d ejected\n", index);
}

bool SimBlockDevice::IsMounted(int index) {
	return mounted[index];
}

void SimBlockDevice::FlushRange(int i, long off, long len) {
	if (!writeback || disk_path[i].empty()) return;
	std::fstream f(disk_path[i].c_str(), std::ios::in | std::ios::out | std::ios::binary);
	if (!f) { fprintf(stderr, "BLKDEV ERROR: cannot write back to %s\n", disk_path[i].c_str()); return; }
	f.seekp(off);
	f.write((const char *)&image[i][off], len);
}

void SimBlockDevice::ReadBlock(int i, int lba, uint8_t *buf) {
	memset(buf, 0, kBLKSZ);
	if (!mounted[i]) return;
	blocks_read[i]++;
	if (format[i] == BLK_RAW) {
		long off = (long)lba * kBLKSZ;
		for (int k = 0; k < kBLKSZ; k++)
			if (off + k < (long)image[i].size()) buf[k] = image[i][off + k];
		return;
	}
	// On-the-fly nibblizer (matches Main_MiSTer a2_readDsk2Nib)
	long off = (long)lba * kBLKSZ;
	int track = off / A2NIB_TRACK_SIZE;
	int toff = off % A2NIB_TRACK_SIZE;
	if (track >= A2NIB_TRACKS) return;
	uint8_t dsk[A2NIB_DSK_TRACK_SIZE] = {0};
	long doff = (long)track * A2NIB_DSK_TRACK_SIZE;
	for (int k = 0; k < A2NIB_DSK_TRACK_SIZE; k++)
		if (doff + k < (long)image[i].size()) dsk[k] = image[i][doff + k];
	uint8_t nib[A2NIB_TRACK_SIZE];
	a2_nibblize_track(dsk, track, A2NIB_DEFAULT_VOLUME, format[i] == BLK_A2_PRODOS ? A2NIB_ORDER_PRODOS : A2NIB_ORDER_DOS, nib);
	if (legacy_interleave) {
		// Reproduce the pre-fix Main_MiSTer layout: physical slot k carried
		// address-field sector legacy[k] (a second interleave on top of DOS skew).
		static const int legacy[16] = { 0x0,0x7,0xE,0x6,0xD,0x5,0xC,0x4,0xB,0x3,0xA,0x2,0x9,0x1,0x8,0xF };
		uint8_t tmp[A2NIB_TRACK_SIZE];
		for (int k = 0; k < 16; k++) memcpy(tmp + k * 416, nib + legacy[k] * 416, 416);
		memcpy(nib, tmp, sizeof(tmp));
	}
	int n = A2NIB_TRACK_SIZE - toff;
	if (n > kBLKSZ) n = kBLKSZ;
	memcpy(buf, nib + toff, n);
}

void SimBlockDevice::WriteBlock(int i, int lba, const uint8_t *buf) {
	if (!mounted[i]) return;
	blocks_written[i]++;
	long off = (long)lba * kBLKSZ;
	if (format[i] == BLK_RAW) {
		if (off + kBLKSZ > (long)image[i].size()) image[i].resize(off + kBLKSZ, 0);
		memcpy(&image[i][off], buf, kBLKSZ);
		FlushRange(i, off, kBLKSZ);
		return;
	}
	// NIB -> DSK write-back. floppy_track.sv always saves a whole track as 13
	// consecutive blocks; accumulate them and decode once the track is complete.
	int track = off / A2NIB_TRACK_SIZE;
	int blk = (off % A2NIB_TRACK_SIZE) / kBLKSZ;
	if (track >= A2NIB_TRACKS) return;
	int order = format[i] == BLK_A2_PRODOS ? A2NIB_ORDER_PRODOS : A2NIB_ORDER_DOS;
	if (wb_track[i] != track) {
		// Seed with the current contents so a partial save still decodes.
		uint8_t dsk[A2NIB_DSK_TRACK_SIZE] = {0};
		long doff = (long)track * A2NIB_DSK_TRACK_SIZE;
		for (int k = 0; k < A2NIB_DSK_TRACK_SIZE; k++)
			if (doff + k < (long)image[i].size()) dsk[k] = image[i][doff + k];
		a2_nibblize_track(dsk, track, A2NIB_DEFAULT_VOLUME, order, wb_nib[i]);
		wb_track[i] = track;
		wb_mask[i] = 0;
	}
	int n = A2NIB_TRACK_SIZE - blk * kBLKSZ;
	if (n > kBLKSZ) n = kBLKSZ;
	memcpy(wb_nib[i] + blk * kBLKSZ, buf, n);
	wb_mask[i] |= 1u << blk;
	if (wb_mask[i] == (1u << A2NIB_BLOCKS) - 1) {
		long doff = (long)track * A2NIB_DSK_TRACK_SIZE;
		if (doff + A2NIB_DSK_TRACK_SIZE > (long)image[i].size()) image[i].resize(doff + A2NIB_DSK_TRACK_SIZE, 0);
		uint8_t *dsk = &image[i][doff];
		uint32_t got = a2_denibblize_track(wb_nib[i], track, order, dsk);
		int cnt = 0;
		for (int s = 0; s < 16; s++) if (got & (1u << s)) cnt++;
		sectors_written_back[i] += cnt;
		printf("BLKDEV: drive %d track %d written back, %d/16 sectors decoded%s\n", i, track, cnt,
		       cnt < 16 ? " (WARNING: undecodable sectors kept old data)" : "");
		FlushRange(i, doff, A2NIB_DSK_TRACK_SIZE);
		wb_mask[i] = 0;
	}
}

void SimBlockDevice::BeforeEval(int cycles)
{
//
// switch to a new disk if current_disk is -1
// check to see if we need a read or a write or a mount
//

// wait until the computer boots to start mounting, etc
 if (cycles<2000) return;

 for (int i=0; i<kVDNUM;i++)
 {

//fprintf(stderr,"current_disk = %d *sd_rd %x ack_delay %x reading %d writing %d\n",current_disk,*sd_rd,ack_delay,reading,writing);

    if (current_disk == i) {
    // send data
    if (ack_delay==1) {
      if (reading && (*sd_buff_wr==0) &&  (bytecnt<kBLKSZ)) {
         *sd_buff_dout = blkbuf[bytecnt];
         *sd_buff_addr = bytecnt++;
         *sd_buff_wr= 1;
         //printf("cycles %x reading %X : %X ack %x\n",cycles,*sd_buff_addr,*sd_buff_dout,*sd_ack );
      } else if(writing && *sd_buff_addr != bytecnt && (*sd_buff_addr< kBLKSZ)) {
      //} else if(writing && (bytecnt < kBLKSZ)) {
  	//printf("writing disk %i at sd_buff_addr %x data %x ack %x\n",i,*sd_buff_addr,*sd_buff_din[i],*sd_ack);
        blkbuf[*sd_buff_addr & (kBLKSZ-1)] = *(sd_buff_din[i]);
        *sd_buff_addr = bytecnt;
      } else {
	  *sd_buff_wr=0;

	  if (writing) {
		  if (bytecnt>=kBLKSZ) {
			  writing=0;
			  WriteBlock(i, cur_lba, blkbuf);
			  //printf("writing stopped: bytecnt %x sd_buff_addr %x \n",bytecnt,*sd_buff_addr);
		  }
		  if (bytecnt<kBLKSZ)
		  	bytecnt++;
	  }
	  else if (reading) {
        	if(bytecnt == kBLKSZ) {
         	 	reading = 0;
        	} 
        }
      }
    } else {
	  *sd_buff_wr=0;
    } 
    }

    // issue a mount if we aren't doing anything, and the img_mounted has no bits set
    if (!reading && !writing && mountQueue[i] && !*img_mounted) {
           mountQueue[i]=0;
           printf("BLKDEV: mount pulse drive %d size %ld\n", i, disk_size[i]);
           *img_size = disk_size[i];
	   *img_readonly=0;
           bitset(*img_mounted,i);
           ack_delay=sd_ack_delay;
    } else if (ack_delay==1 && bitcheck(*img_mounted,i) ) {
        bitclear(*img_mounted,i) ;
        //*img_size = 0;
    } else { if (!reading && !writing && ack_delay>0) ack_delay--; }

    // start reading when sd_rd pulses high
    if ((current_disk==-1 || current_disk==i) && (bitcheck(*sd_rd,i) || bitcheck(*sd_wr,i) )) {
       // set current disk here..
//fprintf(stderr,"setting current disk %d %x ack_delay %x\n",i,*sd_rd,ack_delay);
       current_disk=i;
      if (!ack_delay) {
        int lba = *(sd_lba[i]);
        if (bitcheck(*sd_rd,i)) {
        	reading = true;
	} 
        if (bitcheck(*sd_wr,i)) {
        	writing = true;
	} 

        cur_lba = lba;
        if (reading) ReadBlock(i, lba, blkbuf);
        if (verbose) printf("BLKDEV: drive %d %s lba %d (track %d blk %d)\n", i, reading ? "read" : "write",
                            lba, (lba * kBLKSZ) / 6656, ((lba * kBLKSZ) % 6656) / kBLKSZ);
        bytecnt = 0;
        *sd_buff_addr = 0;
        ack_delay = sd_ack_delay;
      }
    }

    if (current_disk == i) {
      if (ack_delay==1) {
           bitset(*sd_ack,i);
	   //printf("setting sd_ack: %x\n",*sd_ack);
      } else {
           bitclear(*sd_ack,i);
	   //printf("clearing sd_ack: %x\n",*sd_ack);
      }
      if((ack_delay > 1) || ((ack_delay == 1) && !reading && !writing))
        ack_delay--;
      if (ack_delay==0 && !reading && !writing) 
	current_disk=-1;
    }
  }
}

void SimBlockDevice::AfterEval()
{
}


SimBlockDevice::SimBlockDevice(DebugConsole c) {
	console = c;
        current_disk=-1;
        sd_ack_delay=1200;
        writeback=false;
        verbose=false;
        legacy_interleave=false;
        reading=writing=false;
        ack_delay=0;
        bytecnt=0;
        cur_lba=0;

        sd_rd = NULL;
        sd_wr = NULL;
        sd_ack = NULL;
        sd_buff_addr = NULL;
        sd_buff_dout = NULL;
	for (int i=0;i<kVDNUM;i++) {
           sd_lba[i] = NULL;
	   sd_buff_din[i] = NULL;
           mountQueue[i]=0;
           mounted[i]=false;
           disk_size[i]=0;
           format[i]=BLK_RAW;
           wb_track[i]=-1;
           wb_mask[i]=0;
           blocks_read[i]=blocks_written[i]=sectors_written_back[i]=0;
        }
        sd_buff_wr=NULL;
        img_mounted=NULL;
        img_readonly=NULL;
        img_size=NULL;
}

SimBlockDevice::~SimBlockDevice() {

}
