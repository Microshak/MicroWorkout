#!/usr/bin/env bash
# MicroWorkout — Android end-to-end smoke test (PRD-00 §10 layer 4, the acceptance gate).
#
#   tools/test_android.sh [debug|release]
#
# Builds, installs, launches, screenshots, and checks the built APK's manifest.
# Evidence lands in build/screenshots/ so a human (or the agent's vision) can look
# at what actually rendered. Fails loudly — a PRD may not be signed off on
# desktop evidence alone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB="$SDK/platform-tools/adb"
BUILD_DIR="$ROOT/build"
SHOTS="$BUILD_DIR/screenshots"
MODE="${1:-debug}"

mkdir -p "$SHOTS"

case "$MODE" in
  debug)   PKG="com.microshak.microworkout.debug"; APK="$BUILD_DIR/MicroWorkout-debug.apk" ;;
  release) PKG="com.microshak.microworkout";       APK="$BUILD_DIR/MicroWorkout.apk" ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

FAILURES=0
pass() { echo "  ✔ $1"; }
fail() { echo "  ✘ $1"; FAILURES=$((FAILURES + 1)); }

echo "══════════════════════════════════════════════════════════════"
echo "  MicroWorkout — Android E2E ($MODE)"
echo "══════════════════════════════════════════════════════════════"

# ---------------------------------------------------------------- 1. build
echo "[1/6] build"
"$ROOT/tools/build_android.sh" "$MODE" | tail -3
[[ -f "$APK" ]] && pass "APK exists: $(basename "$APK")" || { fail "APK missing"; exit 1; }

# ------------------------------------------------- 2. manifest permissions
echo "[2/6] manifest permissions"
AAPT2="$(ls -d "$SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1)aapt2"
PERMS=""
if [[ -x "$AAPT2" ]]; then
  PERMS="$("$AAPT2" dump permissions "$APK" 2>/dev/null || true)"
fi
if [[ -z "$PERMS" ]]; then
  # Fallback: the binary manifest still contains the permission string.
  PERMS="$(unzip -p "$APK" AndroidManifest.xml 2>/dev/null | strings | tr -d '\0' || true)"
fi
if grep -q "android.permission.INTERNET" <<<"$PERMS"; then
  pass "android.permission.INTERNET declared (required for LLM calls, PRD-07)"
else
  fail "android.permission.INTERNET NOT declared — LLM calls will fail on device"
fi
# Haptics fail *silently* without this (Input.vibrate_handheld just does nothing), so it is
# asserted here rather than discovered later on a phone.
if grep -q "android.permission.VIBRATE" <<<"$PERMS"; then
  pass "android.permission.VIBRATE declared (required for haptics, PRD-12)"
else
  fail "android.permission.VIBRATE NOT declared — haptics will silently do nothing"
fi

# --------------------------------------------------------------- 3. device
echo "[3/6] emulator"
"$ROOT/tools/emu.sh" start | tail -2

# ---------------------------------------------------------------- 4. install
echo "[4/6] install"
adb() { "$ADB" "$@"; }
adb logcat -c >/dev/null 2>&1 || true
if adb install -r -t "$APK" 2>&1 | tail -2 | grep -q "Success"; then
  pass "installed $PKG"
else
  fail "install failed"
fi

# ----------------------------------------------------------------- 5. launch
echo "[5/6] launch"
LAUNCH_OK=0
for attempt in 1 2 3; do
  if adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    LAUNCH_OK=1; break
  fi
  sleep 3
done
[[ "$LAUNCH_OK" == "1" ]] && pass "launched via launcher intent" || fail "could not launch"

# wait for the process to actually come up
for _ in $(seq 1 20); do
  if adb shell pidof "$PKG" >/dev/null 2>&1; then break; fi
  sleep 1
done
PID="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' || true)"
[[ -n "$PID" ]] && pass "process alive (pid $PID)" || fail "process is not running"

sleep 6  # let the splash finish and the first screen render

# ------------------------------------------------------------- 6. evidence
echo "[6/6] evidence"
STAMP="$(date +%Y%m%d-%H%M%S)"
SHOT="$SHOTS/${MODE}-${STAMP}.png"
adb exec-out screencap -p > "$SHOT" 2>/dev/null || true
if [[ -s "$SHOT" ]]; then
  pass "screenshot: ${SHOT#$ROOT/} ($(stat -c%s "$SHOT") bytes)"
else
  fail "screenshot capture failed"
fi

LOGFILE="$BUILD_DIR/logcat-${MODE}-${STAMP}.txt"
adb logcat -d > "$LOGFILE" 2>&1 || true
grep -E "\[(boot|App|Store|Library|LLM|Nav|nav|Feedback|home|theme|ui|toast)\]" "$LOGFILE" | tail -24 || true
if grep -q "\[boot\] MicroWorkout" "$LOGFILE"; then
  pass "app boot log found in logcat"
  grep -m1 "\[boot\] MicroWorkout" "$LOGFILE" | sed 's/^/      /'
else
  fail "no [boot] log line in logcat — did the app actually reach main scene?"
fi

# Godot engine errors are fatal for sign-off.
# NOTE: logcat lines are timestamp-prefixed ("09-15 19:04:48.778  4178  4211 E godot : ..."),
# so an anchored ^ERROR grep never matches and silently yields a FALSE PASS. Match the
# godot tag/level columns and "ERROR:" appearing anywhere in the message instead.
#
# Godot routes *warnings* to stderr too, so logcat shows them at level E. Those are
# reported separately and are not fatal — e.g. "Failed to load cached shader, recompiling"
# is expected on a cold first launch and resolves itself.
BENIGN="editor_settings|Cannot save file|app_userdata|user://logs"

GODOT_WARNINGS="$(grep -E "E godot *: *WARNING:|WARNING:" "$LOGFILE" \
  | grep -viE "$BENIGN" || true)"
# Godot prints a warning as a two-line block ("WARNING: …" then "at: …"). Drop the block as
# a unit, otherwise the location line survives the WARNING filter and fails the build.
GODOT_ERRORS="$(grep -E "E godot *:|ERROR:|SCRIPT ERROR:" "$LOGFILE" \
  | grep -viE "$BENIGN" \
  | awk '/WARNING:/ { warn = 1; next } warn && /at: / { warn = 0; next } { warn = 0; print }' \
  || true)"

if [[ -n "$GODOT_ERRORS" ]]; then
  fail "engine errors present in logcat:"
  head -8 <<<"$GODOT_ERRORS" | sed 's/^/      /'
else
  pass "no engine errors in logcat"
fi

if [[ -n "$GODOT_WARNINGS" ]]; then
  echo "  • engine warnings (non-fatal, reported for review):"
  head -4 <<<"$GODOT_WARNINGS" | sed 's/^/      /'
else
  pass "no engine warnings in logcat"
fi

# Shader compilation/linking failures produce a blank window while the process still
# reports healthy, so they get their own explicit check (see ADR-06/ADR-07).
SHADER_ERRORS="$(grep -E "Program linking failed|exceed GL_MAX|Shader compilation failed|Cannot compile" "$LOGFILE" || true)"
if [[ -n "$SHADER_ERRORS" ]]; then
  fail "SHADER failure — the window will be blank even though the process is alive:"
  head -4 <<<"$SHADER_ERRORS" | sed 's/^/      /'
else
  pass "no shader compilation/linking failures"
fi

echo "──────────────────────────────────────────────────────────────"
if (( FAILURES == 0 )); then
  echo "  RESULT: PASS — evidence in ${SHOTS#$ROOT/} and ${LOGFILE#$ROOT/}"
  echo "══════════════════════════════════════════════════════════════"
  exit 0
else
  echo "  RESULT: FAIL — $FAILURES check(s) failed"
  echo "══════════════════════════════════════════════════════════════"
  exit 1
fi
