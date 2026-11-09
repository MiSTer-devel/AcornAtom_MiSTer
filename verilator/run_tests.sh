#!/bin/bash
# Regression: run the scenarios headless and compare each screenshot with
# tests/golden/<name>.png (tools/pngdiff.py, pixel for pixel).
#
#   ./run_tests.sh            # all scenarios
#   ./run_tests.sh boot       # one scenario (or every scenario whose name starts with it)
#
# A scenario without a golden image reports NEW and leaves its output in
# tests/out/<name>.png: copy it to tests/golden/ once it has been checked.
cd "$(dirname "$0")" || exit 1
VTOP=./obj_dir/Vtop
OUT=tests/out
mkdir -p "$OUT"
fail=0
only=$1

run() {
	local name=$1 frame=$2 golden=tests/golden/${GOLDEN:-$1}.png; shift 2
	[ -n "$only" ] && [[ $name != "$only"* ]] && return
	"$VTOP" --headless "$@" --screenshot "$frame" --screenshot-name "$OUT/$name.png" \
		--stop-at-frame $((frame + 1)) > "$OUT/$name.log" 2>&1
	if [ ! -f "$OUT/$name.png" ]; then
		echo "FAIL $name (no screenshot; see $OUT/$name.log)"; fail=1
	elif [ -f "$golden" ]; then
		if python3 tools/pngdiff.py "$golden" "$OUT/$name.png" > "$OUT/$name.diff" 2>&1; then
			echo "PASS $name"
		else
			echo "FAIL $name ($(head -1 "$OUT/$name.diff"))"; fail=1
		fi
	else
		echo "NEW  $name (no golden image; check $OUT/$name.png and copy it to tests/golden/)"
	fi
}

# Boot banner: ACORN ATOM + ATOMMC2 and the prompt (the AVR8 firmware is up).
run boot 60
# Keyboard and BASIC: PRINT 1+1 answers 2 in BASIC's right-justified field.
run print 200 --send-keys '60:PRINT 1+1\n'
# Undecoded #Bxxx reads #F1 (241) and ignores writes, as upstream; #B000 is the 8255.
run unmapped 640 --send-keys '60:P.?#BC00;?#B500=5;P.?#B500;P.?#B000\n'
# AtoMMC: *CAT lists the VHD's root directory through sys/sd_card.sv.
if [ -f ../software/mister11/boot.vhd ]; then
	run cat 300 --vhd ../software/mister11/boot.vhd --send-keys '120:*CAT\n'
else
	[ -z "$only" ] || [[ cat == "$only"* ]] && echo "SKIP cat (no ../software/mister11/boot.vhd)"
fi

# SID: one voice gated from BASIC must make the audio output move, at 1 MHz
# and in 4 MHz turbo (it used to stop dead in turbo: the SID clock came from
# the CPU divider). Judged on the --trace-audio log, not a screenshot: a frame
# after the gate with thousands of output changes.
SID_PROG='60:?#BDD8=15;?#BDC6=240;?#BDC1=40;?#BDC4=17\n'
run_sid() {
	local name=$1; shift
	[ -n "$only" ] && [[ $name != "$only"* ]] && return
	"$VTOP" --headless --sid on --speaker off --trace-audio "$@" --send-keys "$SID_PROG" \
		--stop-at-frame 640 > "$OUT/$name.log" 2>&1
	local changes
	changes=$(grep '^\[audio\] frame 63[0-9]:' "$OUT/$name.log" | sed -E 's/.*changes ([0-9]+)/\1/' | sort -n | tail -1)
	if [ -n "$changes" ] && [ "$changes" -gt 1000 ]; then
		echo "PASS $name (audio changes/frame: $changes)"
	else
		echo "FAIL $name (audio changes/frame: ${changes:-none}; see $OUT/$name.log)"; fail=1
	fi
}
run_sid sid
run_sid sid4 --turbo 4

# Tape (rtl/atom_tape.sv, rtl/tape_overlay.sv): the next-step hint for each kind
# of first file, read from the tape header (golden images at frame 50), and a
# whole BBALL load: F11 (Ctrl-BREAK), LOAD"BBALL", a key at PLAY TAPE, the 4x
# deck, the converter-flag repair, then the RUN hint at frame 580.
U=../software/archive.org_atom-archive-13-uef
if [ -f "$U/BBALL.uef" ] && [ -f "$U/ASTEROID.uef" ]; then
	run hint_basic 50 --layout us --tape "$U/BBALL.uef"
	run hint_code  50 --layout us --tape "$U/ASTEROID.uef"
	if [ -z "$only" ] || [[ hint_data == "$only"* ]]; then
		python3 -I -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); open(sys.argv[2],'wb').write(z.read('Atom Archive 13 - UEF/AGD/ADAGGER/DAGSCR.uef'))" \
			"$U/Atom Archive 13 - UEF.zip" "$OUT/DAGSCR.uef" && run hint_data 50 --layout us --tape "$OUT/DAGSCR.uef"
	fi
	run tape_bball 580 --layout us --tape "$U/BBALL.uef" --send-keys '60:\C' --send-keys '130:LOAD"BBALL"\n' --send-keys '260: '
	# A gzipped UEF (rtl/gunzip.sv expands it as it downloads): the same hint as
	# the plain one, so it is checked against hint_basic's golden image.
	if [ -z "$only" ] || [[ hint_gz == "$only"* ]]; then
		python3 -I -c "import gzip,sys; open(sys.argv[2],'wb').write(gzip.compress(open(sys.argv[1],'rb').read()))" \
			"$U/BBALL.uef" "$OUT/BBALL.uef.gz" && GOLDEN=hint_basic run hint_gz 50 --layout us --tape "$OUT/BBALL.uef.gz"
	fi
	# A CSW (rtl/csw_in.sv reads it back into bytes as it downloads), made from
	# BBALL.uef by tools/uef2csw.py: the same hint, and the same whole load.
	if [ -z "$only" ] || [[ hint_csw == "$only"* ]] || [[ tape_csw == "$only"* ]]; then
		python3 -I ../tools/uef2csw.py "$U/BBALL.uef" "$OUT/BBALL.csw"
		GOLDEN=hint_basic run hint_csw 50 --layout us --tape "$OUT/BBALL.csw"
		GOLDEN=tape_bball run tape_csw 580 --layout us --tape "$OUT/BBALL.csw" --send-keys '60:\C' --send-keys '130:LOAD"BBALL"\n' --send-keys '260: '
	fi
	# Two files on one tape (HILO, then BBALL; rule 26 of the tape standard):
	# LOAD"HILO", RUN; with HILO running the hint moves on to the next file
	# (frame 1000); ESCAPE, LOAD"BBALL"; the RUN hint for BBALL (frame 1600).
	if [ -z "$only" ] || [[ tape_multi == "$only"* ]]; then
		python3 -I -c "import sys; o=open(sys.argv[1],'wb'); [o.write(open(p,'rb').read()[0 if i == 0 else 12:]) for i, p in enumerate(sys.argv[2:])]" \
			"$OUT/HILO_BBALL.uef" "$U/HILO.uef" "$U/BBALL.uef"
		M=(--layout us --tape "$OUT/HILO_BBALL.uef" --send-keys '60:\C' --send-keys '130:LOAD"HILO"\n' --send-keys '260: '
		   --send-keys '900:RUN\n' --send-keys '1050:\e' --send-keys '1090:LOAD"BBALL"\n' --send-keys '1210: ')
		run tape_multi_next 1000 "${M[@]}"
		run tape_multi_run 1600 "${M[@]}"
	fi
else
	[ -z "$only" ] && echo "SKIP tape scenarios (no $U)"
fi
# The inflater on its own (tests/gunzip): every UEF under ../software, gzipped
# or not, expanded with and without input stalls and compared with Python's.
if [ -z "$only" ] || [[ gunzip == "$only"* ]]; then
	if [ -d ../software ]; then
		if r=$(find "$PWD/../software" -iname '*.uef' -print0 | xargs -0 tests/gunzip/run.sh); then
			echo "PASS gunzip (${r##*gunzip: })"
		else
			echo "FAIL gunzip"; echo "$r" | grep FAIL | head; fail=1
		fi
	else
		echo "SKIP gunzip (no ../software)"
	fi
fi
# The CSW reader on its own (tests/csw): every UEF under ../software written as
# a CSW three ways and read back, with and without input stalls.
if [ -z "$only" ] || [[ csw == "$only"* ]]; then
	if [ -d ../software ]; then
		if r=$(find "$PWD/../software" -iname '*.uef' -not -path '*commercial*' -print0 | xargs -0 tests/csw/run.sh); then
			echo "PASS csw (${r##*csw: })"
		else
			echo "FAIL csw"; echo "$r" | grep FAIL | head; fail=1
		fi
	else
		echo "SKIP csw (no ../software)"
	fi
fi
exit $fail
