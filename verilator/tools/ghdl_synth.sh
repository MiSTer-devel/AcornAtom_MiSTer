#!/bin/bash
# Turn the core's VHDL into one Verilog netlist for Verilator.
#
#   tools/ghdl_synth.sh <repo root> <ghdl work dir> <output .v>
#
# Analyses every VHDL file named in files.qip (repeating the pass until the
# dependency order sorts itself out), then runs "ghdl synth" on AtomFpga_Core.
# The Verilog keyboard (rtl/keyboard.sv) and SID (rtl/SID) are components in
# the VHDL, so they come out of the netlist as plain module instances and are
# compiled from their own sources.
#
# Post-processing:
#  * fix_port_aliases.py restores "sig <= port" aliases that ghdl's Verilog
#    writer drops (it reads them back from the VHDL netlist of the same run).
#  * "do" (the T65's data-out port and others), "config" and "break" are SystemVerilog
#    keywords; they are renamed with a _v suffix throughout the netlist.
#  * 'Z' constants (unused AVR8 peripheral slots) become zeros.
#
# Requires ghdl 5.x (synthesis built in: the Homebrew bottle has it).
set -e
ROOT=$1
WORK=$2
OUT=$3
GHDL=${GHDL:-ghdl}
TOOLS=$(cd "$(dirname "$0")" && pwd)
FLAGS=(--std=08 -fsynopsys -fexplicit -frelaxed -Wno-hide -Wno-shared -Wno-binding --workdir="$WORK")

# Always start clean: re-analysing a package in a populated work library marks
# everything that used it obsolete, and the whole set takes seconds anyway.
rm -rf "$WORK"
mkdir -p "$WORK" "$(dirname "$OUT")"
cd "$ROOT"

files=()
while read -r f; do files+=("$f"); done < <(grep -o '[^" ]*\.vhd' files.qip)
remaining=("${files[@]}")
for pass in 1 2 3 4 5 6 7 8; do
	next=()
	for f in "${remaining[@]}"; do
		if ! "$GHDL" -a "${FLAGS[@]}" "$f" > "$WORK/$(basename "$f").log" 2>&1; then
			next+=("$f")
		fi
	done
	echo "ghdl -a pass $pass: ${#remaining[@]} tried, ${#next[@]} failed"
	[ "${#next[@]}" -eq 0 ] && break
	if [ "${#next[@]}" -eq "${#remaining[@]}" ]; then
		for f in "${next[@]}"; do
			echo "--- $f"
			grep -v -e warning -e '^[[:space:]]' "$WORK/$(basename "$f").log" | head -5
		done
		exit 1
	fi
	remaining=("${next[@]}")
done

"$GHDL" synth "${FLAGS[@]}" --out=verilog AtomFpga_Core > "$OUT.tmp"
"$GHDL" synth "${FLAGS[@]}" --out=vhdl    AtomFpga_Core > "${OUT%.v}_netlist.vhd"
python3 "$TOOLS/fix_port_aliases.py" "$OUT.tmp" "${OUT%.v}_netlist.vhd"
perl -pi -e 's/\b(do|config|break)\b/$1_v/g' "$OUT.tmp"
# The AVR8 fills the I/O mux slots of peripherals it does not implement with
# 'Z'; synthesis treats those as no driver, Verilator cannot. Make them zeros.
perl -pi -e "s/(\d+)'bZ+/\$1'b0/g" "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "netlist: $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
