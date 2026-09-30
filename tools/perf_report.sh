#!/usr/bin/env bash
# PRD-12 R10 — collect the P1…P8 evidence from the running emulator/device and print the
# verdict table.
#
#   tools/perf_report.sh                 # two cold starts + one measurement pass
#   tools/perf_report.sh --runs 3
#
# Writes everything it measured to build/perf/<timestamp>.txt and then feeds that file to
# `tests/run_perf_verdict.gd`, which owns the verdicts (AC10). The device must already have
# the **debug** APK installed (`tools/build_android.sh debug && tools/test_android.sh`) and
# the emulator running (`tools/emu.sh start`): debug builds log `[perf]` lines, release
# builds do not.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-$HOME/Applications/godot}"
PKG="${MW_PACKAGE:-com.microshak.microworkout.debug}"
ACTIVITY="${MW_ACTIVITY:-com.godot.game.GodotApp}"
APK="${MW_APK:-$ROOT/build/MicroWorkout.apk}"

RUNS=2
while [[ $# -gt 0 ]]; do
	case "$1" in
		--runs) RUNS="${2:-2}"; shift 2 ;;
		*) echo "perf_report: unknown argument '$1'" >&2; exit 2 ;;
	esac
done

cd "$ROOT"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT/build/perf"
OUT="$OUT_DIR/$STAMP.txt"
mkdir -p "$OUT_DIR"

# Every shell gets its own adb server in this environment (see docs/SESSION.md §4).
"$ROOT/tools/adb_ready.sh" >/dev/null 2>&1 || true
ADB="${ADB:-$HOME/Android/Sdk/platform-tools/adb}"

{
	echo "# perf report $STAMP"
	echo "# device: $("$ADB" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
	echo "# build:  $("$ADB" shell dumpsys package "$PKG" 2>/dev/null | grep -m1 versionName | tr -d '\r')"
	echo
	echo "## cold starts (P1)"
	for i in $(seq 1 "$RUNS"); do
		"$ADB" shell am force-stop "$PKG" >/dev/null 2>&1
		sleep 1
		"$ADB" logcat -c >/dev/null 2>&1
		echo "# run $i"
		# Android 15 refuses `am start` of a non-exported activity, which is what the Godot
		# template installs; the launcher intent is the sanctioned way in and the app's own
		# `[perf] cold_start_ms=` line is the measurement (PRD-12 R10 P1's second half).
		"$ADB" shell am start -W -n "$PKG/$ACTIVITY" 2>&1 \
			| grep -E "TotalTime|Status" | tr -d '\r'
		"$ADB" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
		sleep 8
		"$ADB" logcat -d 2>/dev/null | grep -E "\[perf\]|\[nav\] transition|\[feedback\]" | tail -40
	done
	echo
	echo "## memory (P6) and jank (P7)"
	"$ADB" shell dumpsys meminfo "$PKG" 2>/dev/null | grep -E "TOTAL PSS|TOTAL RSS"
	"$ADB" shell dumpsys gfxinfo "$PKG" 2>/dev/null | grep -A2 "Janky frames"
	echo
	echo "## APK size (P8)"
	if [[ -f "$APK" ]]; then
		SIZE="$(stat -c %s "$APK")"
		awk -v size="$SIZE" -v file="$APK" \
			'BEGIN { printf "APK size: %.1f MB (%s)\n", size / 1048576.0, file }'
	else
		echo "# no APK at $APK (run tools/build_android.sh release)"
	fi
} | tee "$OUT"

echo
if [[ ! -x "$GODOT" ]]; then
	echo "perf_report: cannot compute verdicts — no Godot at $GODOT" >&2
	exit 127
fi
"$GODOT" --headless --path "$ROOT" --script res://tests/run_perf_verdict.gd -- "$OUT"
STATUS=$?

echo "perf_report: evidence in $OUT"
exit $STATUS
