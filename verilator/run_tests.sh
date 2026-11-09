#!/bin/bash
# Regression: run the scenarios headless and compare each screenshot with
# tests/golden/<name>.png (tools/pngdiff.py, pixel for pixel).
#
#   ./run_tests.sh            # all scenarios
#   ./run_tests.sh boot       # one scenario
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
	local name=$1 frame=$2; shift 2
	[ -n "$only" ] && [ "$only" != "$name" ] && return
	"$VTOP" --headless "$@" --screenshot "$frame" --screenshot-name "$OUT/$name.png" \
		--stop-at-frame $((frame + 1)) > "$OUT/$name.log" 2>&1
	if [ ! -f "$OUT/$name.png" ]; then
		echo "FAIL $name (no screenshot; see $OUT/$name.log)"; fail=1
	elif [ -f "tests/golden/$name.png" ]; then
		if python3 tools/pngdiff.py "tests/golden/$name.png" "$OUT/$name.png" > "$OUT/$name.diff" 2>&1; then
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
# AtoMMC: *CAT lists the VHD's root directory through sys/sd_card.sv.
if [ -f ../software/mister11/boot.vhd ]; then
	run cat 300 --vhd ../software/mister11/boot.vhd --send-keys '120:*CAT\n'
else
	[ -z "$only" ] || [ "$only" = cat ] && echo "SKIP cat (no ../software/mister11/boot.vhd)"
fi

# SID: one voice gated from BASIC must make the audio output move, at 1 MHz
# and in 4 MHz turbo (it used to stop dead in turbo: the SID clock came from
# the CPU divider). Judged on the --trace-audio log, not a screenshot: a frame
# after the gate with thousands of output changes.
SID_PROG='60:?#BDD8=15;?#BDC6=240;?#BDC1=40;?#BDC4=17\n'
run_sid() {
	local name=$1; shift
	[ -n "$only" ] && [ "$only" != "$name" ] && return
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
	if [ -z "$only" ] || [ "$only" = hint_data ]; then
		python3 -I -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); open(sys.argv[2],'wb').write(z.read('Atom Archive 13 - UEF/AGD/ADAGGER/DAGSCR.uef'))" \
			"$U/Atom Archive 13 - UEF.zip" "$OUT/DAGSCR.uef" && run hint_data 50 --layout us --tape "$OUT/DAGSCR.uef"
	fi
	run tape_bball 580 --layout us --tape "$U/BBALL.uef" --send-keys '60:\C' --send-keys '130:LOAD"BBALL"\n' --send-keys '260: '
else
	[ -z "$only" ] && echo "SKIP tape scenarios (no $U)"
fi
exit $fail
