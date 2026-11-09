#!/bin/bash
# Unit test for rtl/csw_in.sv. Each argument is a .uef (or .uef.gz): it is
# written as a CSW three ways by tools/uef2csw.py (2.0 Z-RLE, 2.0 RLE, 1.01),
# each is read by the testbench, with and without input stalls, and the bytes
# of the UEF it writes must be the source's. A .csw argument is compared with
# a reference decode in Python instead (csw_ref.py).
cd "$(dirname "$0")" || exit 1
R=../../../rtl
B=obj/Vtb_csw
if [ ! -x $B ] || [ $R/csw_in.sv -nt $B ] || [ $R/gunzip.sv -nt $B ] || [ tb_csw.sv -nt $B ]; then
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -O2 --top-module tb_csw -Mdir obj tb_csw.sv $R/csw_in.sv $R/gunzip.sv > obj.log 2>&1 || { tail -20 obj.log; exit 1; }
fi
T=$(mktemp -d); pass=0; fail=0
check() {   # $1 the CSW, $2 the bytes it must give
	for s in "" +stall +fast; do
		r=$($B +in="$1" +out="$T/got.uef" $s | grep '^err=')
		python3 -I uef_bytes.py "$T/got.uef" > "$T/got" 2>/dev/null
		if [[ $r == "err=0"* ]] && cmp -s "$2" "$T/got"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $3 $s ($r)"; fi
	done
}
for f in "$@"; do
	case "$f" in
	*.csw|*.CSW)
		python3 -I csw_ref.py "$f" > "$T/want" || continue
		check "$f" "$T/want" "$f" ;;
	*)
		python3 -I uef_bytes.py "$f" > "$T/want" || continue
		for m in "" --rle --v1; do
			python3 -I ../../../tools/uef2csw.py "$f" "$T/in.csw" $m || continue
			check "$T/in.csw" "$T/want" "$f $m"
		done ;;
	esac
done
rm -rf "$T"
echo "csw: $pass passed, $fail failed"
[ $fail = 0 ]
