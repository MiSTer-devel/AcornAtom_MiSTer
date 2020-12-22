This is a cut down version of the fabulous AtomFPGA by David Banks (Hoglet) and my 
thanks to him for his help.

The Acorn Atom was the predecessor of the BBC micro based on Acorn's System computers.
It was available as a kit or ready made. 2k ram expandable to 12k and 8k rom expandable to 16k.
It was monochrome 256x192 pixels, later a colour board was made.

This version of the Acorn Atom features 
32k ram
System Roms with mmc (to access the SD card)
Seven additional Roms and 1 slot of ram to download additional Rom.
Two character sets.
Tape in/out (not tested)
Selectable sound, Atom,SID,Tape,off
Black or Dark background
Atom or BBC Basic mode
Colour palette
SID sound
Turbo mode (f1,f2,f3,f4)
Four keyboards - UK(default),USA,original,game

UK + US - Shift lock is Caps, Repeat is right Alt, copy is tab - Left Alt is xtra shift key
The original keyboard had @ and up-arrow as separate keys these have moved to a PS2 config. 
Up-Arrow is shift 6 so to 'shift' this press left Alt, shift and 6.

The original keyboard is as originally written ie shift 8 is ( and shift 9 is )

The game keyboard just reverses the ctrl and shift as on the original keyboard, for games like Asteroids.

CANNOT DOWMNLOAD--In the release folder is a 100MB blank.vhd file this has been formatted in MSDOS.

You need a boot.vhd file around a 100MB FAT formatted 
Attach the boot.vhd and copy software onto it. Detach the VHD and place the file in the AcornAtom folder on your SD card.
To auto boot the software menu Shift-Break(f10), Ctrl-Break disables the MMC Rom
The best software source is the AtomSoftwareArchive V11 zip 11.9MB
There are several sites dedicated to the atom.

