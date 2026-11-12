# rtl/godil

Parts of AtomGodilVideo (https://github.com/hoglet67/AtomGodilVideo, Apache-2.0,
David Banks), copied unchanged from commit 52ded1f (2025-06-14):

- `Pointer.vhd`, `PointerRamBlack.vhd`, `PointerRamWhite.vhd`: the mouse pointer
  overlay (32 pointer images, 8x8, drawn into the 6847's data in the 32 bytes per
  row graphics modes).

The register block (#BDE0-#BDFF) lives in `rtl/AtomFpga_Core.vhd`; the mouse
position comes from MiSTer's `ps2_mouse` through `rtl/godil_mouse.sv` instead of
AtomGodilVideo's own PS/2 mouse controller.
