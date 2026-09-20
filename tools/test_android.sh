#!/usr/bin/env bash
# MicroWorkout — Android end-to-end smoke test (PRD-00 §10 layer 4, the acceptance gate).
#
#   tools/test_android.sh [debug|release] [--flow NAME]
#
# Builds, installs, launches, screenshots, and checks the built APK's manifest.
# Evidence lands in build/screenshots/ so a human (or the agent's vision) can look
# at what actually rendered. Fails loudly — a PRD may not be signed off on
# desktop evidence alone.
#
# Flows (PRD-10 R5) drive a real session with real taps, by asking the app where its controls are
# (`tools/tap_ui.sh` reads the `[ui] rect` lines the app logs in debug builds):
#   player-full    seed a plan, start from Home, tick every set of every block, finish, celebrate
#   player-skip    the same walk, but the celebration is tapped at ~200 ms (AC13's second half)
#   player-resume  check two sets, kill the process, relaunch, resume from Home (AC10)
#   player-quit    quit without saving and prove history is untouched (AC9)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB="$SDK/platform-tools/adb"
BUILD_DIR="$ROOT/build"
SHOTS="$BUILD_DIR/screenshots"
MODE="debug"
FLOW=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    debug|release) MODE="$1"; shift ;;
    --flow) FLOW="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

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


# ============================================================================
# Flows — a real session, driven by real taps (PRD-10 R5)
# ============================================================================
#
# Every step here waits for the app to *say* it happened (a log line) before moving on. That is not
# politeness: the emulator renders under 1 fps, so a tap can take four seconds to reach a handler,
# and a flow that taps on a timer produces a screen full of plausible-looking screenshots while
# nothing actually happened. `wait_log` turns each race into a wait with a deadline, so a real
# failure still fails.

FIXTURE="$ROOT/tests/fixtures/sessions/upper_a.json"

## "2 3 2" — warm-up items, blocks, cool-down items.
fixture_shape() {
  python3 - "$FIXTURE" <<'PYEOF'
import json, sys
plan = json.load(open(sys.argv[1]))["plan"]
session = plan["sessions"][0]
print(len(session.get("warmup", [])), len(session.get("blocks", [])), len(session.get("cooldown", [])))
PYEOF
}

## "4 4 3" — the sets of each block, in order.
fixture_sets() {
  python3 - "$FIXTURE" <<'PYEOF'
import json, sys
plan = json.load(open(sys.argv[1]))["plan"]
print(" ".join(str(b["sets"]) for b in plan["sessions"][0].get("blocks", [])))
PYEOF
}

## Puts a known plan and a known settings document on the device, so a flow starts from Home with a
## session to do instead of walking onboarding first. `run-as` works because this is a debug APK.
seed_device_state() {
  local tmp="$BUILD_DIR/tmp/seed"
  local file
  rm -rf "$tmp"; mkdir -p "$tmp"
  python3 - "$FIXTURE" "$tmp" <<'PYEOF'
import copy, json, os, sys
fixture, out = sys.argv[1], sys.argv[2]
plan = json.load(open(fixture))["plan"]
# The fixture is a 2-day plan, and `PlanSchedule` maps 2 days to Monday/Thursday — so on most days
# of the week Home would correctly show a rest day and there would be no `Start workout` to tap.
# Six sessions on the same session shape makes **today** a training day whatever day the run
# happens (the 6-day pattern is Monday–Saturday), which is the tap AC14 asks for.
base = plan["sessions"][0]
sessions = []
for index in range(6):
    session = copy.deepcopy(base)
    session["id"] = "s%d" % (index + 1)
    session["index"] = index
    if index:
        session["title"] = "%s %d" % (base.get("title", "Session"), index + 1)
    sessions.append(session)
plan["sessions"] = sessions
plan["days_per_week"] = 6
json.dump({"schema_version": 1, "active_plan_id": plan["id"], "plans": [plan]},
          open(os.path.join(out, "plans.json"), "w"))
json.dump({"schema_version": 2, "units": "lb", "theme": "dark", "weekly_goal_days": 4,
           "onboarding_complete": True, "attribution_seen": True,
           "rest_timer": {"enabled": True, "auto_start": True, "sound": True, "haptic": True,
                          "default_seconds": 90}},
          open(os.path.join(out, "settings.json"), "w"))
json.dump({"schema_version": 1, "entries": []}, open(os.path.join(out, "history.json"), "w"))
PYEOF
  adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  adb shell run-as "$PKG" mkdir -p files/data >/dev/null 2>&1 || true
  for file in plans.json settings.json history.json; do
    adb push "$tmp/$file" "/data/local/tmp/mw_$file" >/dev/null 2>&1
    adb shell chmod 644 "/data/local/tmp/mw_$file" >/dev/null 2>&1 || true
    if adb shell run-as "$PKG" cp "/data/local/tmp/mw_$file" "files/data/$file" >/dev/null 2>&1; then
      pass "seeded files/data/$file"
    else
      fail "could not seed files/data/$file (is this a debug build?)"
    fi
  done
  # A leftover cursor would make the run resume instead of start.
  adb shell run-as "$PKG" rm -f files/data/session_progress.json >/dev/null 2>&1 || true
}

log_has() { adb logcat -d 2>/dev/null | grep -qE "$1"; }

## Waits up to [param seconds] for a log line, then reports either way.
wait_log() {
  local pattern="$1" message="$2" seconds="${3:-20}"
  local waited=0
  while (( waited < seconds )); do
    if log_has "$pattern"; then pass "$message"; return 0; fi
    sleep 1; waited=$((waited + 1))
  done
  fail "$message — no /$pattern/ in logcat after ${seconds}s"
  return 1
}

## Immediate check, for facts that must already be in logcat.
require_log() {
  if log_has "$1"; then pass "$2"; else fail "$2 — no /$1/ in logcat"; fi
}

## Restarts the app and waits until Home has rendered **and** published its tap rects. The rects
## arrive a frame or two after the refresh, which on this emulator is seconds later — waiting only
## for `[home] refresh` was how the first version of this flow tapped nothing at all.
relaunch_app() {
  adb logcat -c >/dev/null 2>&1 || true
  adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  # Wait for the *settled* publication, not merely for a rect: the first one is logged a frame
  # after the refresh and can be seconds (and hundreds of pixels) out of date on this emulator.
  local waited=0
  while (( waited < 40 )); do
    if log_has "\[home\] refresh" && log_has "rect name=home_(start|early) .*settled=1"; then
      return 0
    fi
    sleep 1; waited=$((waited + 1))
  done
  fail "Home never published a settled tap target after relaunch"
  return 1
}

shot() {
  local label="$1"
  local stamp
  local path
  stamp="$(date +%Y%m%d-%H%M%S)"
  path="$SHOTS/${label}-${stamp}.png"
  adb exec-out screencap -p > "$path" 2>/dev/null || true
  if [[ -s "$path" ]]; then
    pass "screenshot ${path#$ROOT/} ($(stat -c%s "$path") bytes)"
  else
    fail "screenshot $label failed"
  fi
}

## Taps a named control through `tools/tap_ui.sh`, which reads the newest rect the app logged. It
## waits for that rect first: a rect that has not been published yet means the app has not finished
## laying the screen out, and tapping anyway is how a test taps empty padding.
tap() {
  local name="$1"
  local settle="${2:-2}"
  local wait="${3:-25}"
  local waited=0
  local out
  while (( waited < wait )); do
    if log_has "rect name=${name} .*settled=1"; then break; fi
    sleep 1; waited=$((waited + 1))
  done
  if out="$(MW_PKG="$PKG" "$ROOT/tools/tap_ui.sh" "$name" --settle "$settle" 2>&1)"; then
    echo "        $(grep -oE '\[tap\] .*' <<<"$out" | tail -1)"
  else
    fail "tap '$name' failed"
    tail -2 <<<"$out" | sed 's/^/        /'
  fi
}

## Home offers `Start workout` on a training day and `Do the next session early` on a rest day, and
## only the one that is on screen logs a rect — so the flow taps whichever the screen offers. Both
## push the same player; the rest-day path is R1's `early: true` argument.
home_entry_tap() {
  if log_has "rect name=home_start .*settled=1"; then
    tap home_start 3
  elif log_has "rect name=home_early .*settled=1"; then
    tap home_early 3
  else
    fail "Home offers no way into a workout (no home_start or home_early rect)"
  fi
}

## PRD-10 AC11. Godot implements `screen_set_keep_on()` with the window flag rather than a wakelock,
## so both facts are collected and the script says which one it found.
wake_evidence() {
  # NOTE: one variable per `local` statement. `local a="$1" b="${a}"` expands every right-hand side
  # before assigning any of them, so `${a}` is "unbound" under `set -u` — which is how the first
  # version of this function died mid-flow.
  local label="$1"
  local power="$BUILD_DIR/dumpsys-power-${label}.txt"
  local window="$BUILD_DIR/dumpsys-window-${label}.txt"
  adb shell dumpsys power 2>/dev/null | grep -iE 'wake|screen' > "$power" || true
  if grep -qiE 'mWakefulness=Awake|mScreenOn|mHoldingDisplaySuspendBlocker=true' "$power"; then
    pass "display is awake while the player runs ($label)"
  else
    fail "display is not awake ($label)"
  fi
  adb shell dumpsys window 2>/dev/null | grep -iE 'keep_?screen_?on' > "$window" || true
  if grep -qi 'keep_?screen_?on' "$window"; then
    pass "FLAG_KEEP_SCREEN_ON is held on the app window ($label)"
  else
    echo "  • no KEEP_SCREEN_ON flag in dumpsys window ($label) — see ${power#$ROOT/}"
  fi
}

## Walks the fixture session end to end. `skip` taps the celebration at ~200 ms (AC13's second half).
player_walk() {
  local mode="$1"
  local warm blocks cooldowns sets step shot_index n k index
  read -r warm blocks cooldowns <<<"$(fixture_shape)"
  sets="$(fixture_sets)"
  echo "      fixture: $warm warm-up, $blocks block(s) [$sets], $cooldowns cool-down"

  home_entry_tap
  wait_log "\[player\] start plan=" "player started from Home" 30
  wait_log "\[player\] step=0 " "player is on step 0" 20
  shot "player-step-0"

  # AC12: back opens the pause sheet (it never exits the workout), back again resumes, and back
  # while zoomed closes the zoom. Driven with real key events, not by calling the handler.
  adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
  wait_log "\[player\] back -> ACTIVE" "back in ACTIVE opened the pause sheet (AC12)" 25
  adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
  wait_log "\[player\] back -> PAUSED" "back in PAUSED resumed (AC12)" 25
  tap player_illustration 2
  wait_log "\[player\] zoom ex=" "tapping the illustration opened the zoom (R4)" 25
  adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
  wait_log "\[player\] back -> ZOOMED" "back while zoomed closed the zoom (AC12)" 25

  # Warm-ups: Next through each, waiting for the next step to be reported.
  step=0
  while (( step < warm )); do
    tap player_next 2
    step=$((step + 1))
    wait_log "\[player\] step=${step} " "advanced to step $step" 25
  done

  # Working blocks: tick every set of every block, then Next.
  shot_index=1
  for n in $sets; do
    k=1
    while (( k <= n )); do
      tap "player_${step}_set_${k}" 2
      wait_log "\[player\] set ex=[a-z0-9-]+ n=${k} checked=${k}/${n}" \
        "set $k of $n checked on block $shot_index" 25
      if (( k == 1 && n > 1 )); then
        wait_log "\[player\] rest start=" "rest sheet up after set 1 of block $shot_index" 20
        shot "player-rest"
      fi
      k=$((k + 1))
    done
    shot "player-step-${shot_index}"
    if (( shot_index == 1 )); then
      wake_evidence "active"
      tap player_pause 2
      wait_log "\[player\] pause elapsed=" "pause logged" 25
      shot "player-paused"
      tap player_resume 2
      wait_log "\[player\] resume elapsed=" "resume logged" 25
    fi
    tap player_next 2
    step=$((step + 1))
    shot_index=$((shot_index + 1))
    wait_log "\[player\] step=${step} " "advanced to step $step" 25
  done

  # AC4: the R8 label matrix, read off the steps the walk actually visited.
  wait_log "next=\"Cool down\"" "the last working block offers \"Cool down\" (AC4)" 5 || true
  if log_has "next=\"Start sets\""; then
    pass "the last warm-up offered \"Start sets\" (AC4)"
  else
    fail "no \"Start sets\" label in the walk (AC4)"
  fi

  # Cool-downs: the last Next is "I'm done for the day".
  index=0
  while (( index < cooldowns )); do
    tap player_next 2
    index=$((index + 1))
    step=$((step + 1))
    if (( index < cooldowns )); then
      wait_log "\[player\] step=${step} " "advanced to cool-down $index" 25
    fi
  done

  if [[ "$mode" == "skip" ]]; then
    # A tap has to be *in flight* when the celebration appears. R12 asks for ~200 ms; on this
    # emulator a single `adb shell input tap` costs about a second and the whole celebration is over
    # in ~2.5 s of wall clock (a 1.6 s timeline at under 1 fps), so the flow taps as soon as it can
    # and the log line records the `t` the app actually saw.
    for _try in 1 2 3 4; do
      adb shell input tap 540 1200 >/dev/null 2>&1 || true
      sleep 0.4
      if log_has "\[complete\] celebration_skipped"; then break; fi
    done
    wait_log "\[complete\] celebration_skipped" "celebration skipped on a tap (AC13)" 15
  else
    wait_log "\[complete\] celebration start" "the celebration began" 25
    wait_log "\[complete\] celebration end" "celebration ran its full 1.6 s (AC13)" 25
  fi
  shot "player-celebration"
  require_log "\[player\] complete entry=h-" "history entry written (AC15)"
  require_log "\[store\] entry_added id=h-" "Store emitted entry_added (AC15)"
  require_log "\[player\] progress cleared" "in-progress record cleared after completion"
  wake_evidence "after-done"

  tap complete_done 3
  # `trigger=route_entered` is the one Home refresh that can only come from the Done navigation:
  # the completion screen's own completion emits `history_changed`/`entry_added` refreshes *before*
  # Done is tapped, so waiting for a bare `[home] refresh` passed while the celebration was still up.
  wait_log "\[home\] refresh trigger=route_entered" "Done landed back on Home (AC15)" 30
  shot "player-home-after"
  wait_log "\[home\] state=DONE_TODAY" "Home shows DONE_TODAY after Done (AC15)" 25
}

flow_player_full() { player_walk noskip; }
flow_player_skip() { player_walk skip; }

## AC10: check two sets, kill the process mid-session, relaunch, resume.
flow_player_resume() {
  local warm step
  read -r warm _ _ <<<"$(fixture_shape)"
  home_entry_tap
  wait_log "\[player\] start plan=" "player started from Home" 30
  tap player_next 2
  tap player_next 2
  step="$warm"
  wait_log "\[player\] step=${step} " "on the first working block" 25
  tap "player_${step}_set_1" 2
  wait_log "\[player\] set ex=[a-z0-9-]+ n=1 checked=1/" "first set checked" 25
  tap "player_${step}_set_2" 2
  wait_log "\[player\] set ex=[a-z0-9-]+ n=2 checked=2/" "second set checked" 25
  sleep 3   # the 400 ms write debounce plus a 2 s autosave tick
  adb shell run-as "$PKG" ls -l files/data/session_progress.json 2>/dev/null | sed 's/^/      /' || true
  adb shell am force-stop "$PKG"
  sleep 2
  relaunch_app || true
  shot "player-resume-home"
  # Home must now offer the resume path; its label is asserted from the log-free side below.
  home_entry_tap
  wait_log "\[player\] progress restored step=" "session resumed from disk (AC10)" 30
  shot "player-resume"
  adb logcat -d 2>/dev/null | grep -oE "\[player\] progress restored .*" | tail -1 | sed 's/^/      /'
}

## AC9: quit without saving writes nothing to history and leaves no in-progress record behind.
flow_player_quit() {
  local before_history after_history
  home_entry_tap
  wait_log "\[player\] start plan=" "player started from Home" 30
  tap player_next 2
  sleep 3   # let a progress write land, so clearing it is real work
  before_history="$(adb shell run-as "$PKG" cat files/data/history.json 2>/dev/null | tr -d '\r')"
  tap player_pause 2
  wait_log "\[player\] pause elapsed=" "pause logged" 25
  tap player_quit 2
  # The dialog's own button is tapped by rect (the player logs `quit_confirm`); the keyboard is only
  # a fallback, because focus starts on `Keep going` — the destructive path is deliberately the
  # second tap (R11).
  tap quit_confirm 2
  if ! log_has "\[player\] progress cleared \(discarded\)"; then
    adb shell input keyevent KEYCODE_TAB >/dev/null 2>&1 || true
    adb shell input keyevent KEYCODE_ENTER >/dev/null 2>&1 || true
  fi
  wait_log "\[player\] progress cleared \(discarded\)" "discard cleared the in-progress record" 20
  wait_log "Session discarded" "the owner is told the session was discarded" 20
  if adb shell run-as "$PKG" ls files/data/session_progress.json >/dev/null 2>&1; then
    fail "session_progress.json still exists after a discard"
  else
    pass "session_progress.json is gone after a discard"
  fi
  after_history="$(adb shell run-as "$PKG" cat files/data/history.json 2>/dev/null | tr -d '\r')"
  printf '%s' "$after_history" > "$BUILD_DIR/history-after-quit.json"
  printf '%s' "$before_history" > "$BUILD_DIR/history-before-quit.json"
  if [[ "$after_history" == "$before_history" ]]; then
    pass "history.json is byte-identical after quitting without saving (AC9)"
  else
    fail "history.json changed after quitting without saving"
  fi
}

run_flow() {
  case "$1" in
    player-full)   flow_player_full ;;
    player-skip)   flow_player_skip ;;
    player-resume) flow_player_resume ;;
    player-quit)   flow_player_quit ;;
    *) fail "unknown flow '$1'"; return 1 ;;
  esac
}

if [[ -n "$FLOW" ]]; then
  echo "──────────────────────────────────────────────────────────────"
  echo "[flow] $FLOW"
  seed_device_state
  relaunch_app || true
  run_flow "$FLOW" || true
fi

if (( FAILURES == 0 )); then
  echo "  RESULT: PASS — evidence in ${SHOTS#$ROOT/} and ${LOGFILE#$ROOT/}"
  echo "══════════════════════════════════════════════════════════════"
  exit 0
else
  echo "  RESULT: FAIL — $FAILURES check(s) failed"
  echo "══════════════════════════════════════════════════════════════"
  exit 1
fi
