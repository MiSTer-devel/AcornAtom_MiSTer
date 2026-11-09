#!/bin/bash
# Unit test for rtl/gunzip.sv: every argument (a .uef or .gz) is expanded by the
# testbench, with and without input stalls, and compared with Python's gzip.
cd "$(dirname "$0")" || exit 1
B=obj/Vtb_gunzip
if [ ! -x $B ] || [ ../../../rtl/gunzip.sv -nt $B ] || [ tb_gunzip.sv -nt $B ]; then
	verilator --binary --timing -Wno-fatal -Wno-WIDTH -O2 --top-module tb_gunzip -Mdir obj tb_gunzip.sv ../../../rtl/gunzip.sv > obj.log 2>&1 || { tail -20 obj.log; exit 1; }
fi
T=$(mktemp -d); pass=0; fail=0
for f in "$@"; do
	python3 -I -c "import gzip,sys; b=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(gzip.decompress(b) if b[:2]==b'\x1f\x8b' else b)" "$f" "$T/want" || continue
	for s in "" +stall; do
		r=$($B +in="$f" +out="$T/got" $s | grep '^gz=')
		if cmp -s "$T/want" "$T/got" && [[ $r == *"err=0"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $f $s ($r)"; fi
	done
done
rm -rf "$T"
echo "gunzip: $pass passed, $fail failed"
[ $fail = 0 ]
