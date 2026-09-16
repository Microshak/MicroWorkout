#!/usr/bin/env bash
# MicroWorkout — Android emulator lifecycle (PRD-00 §10 layer 4).
#
#   tools/emu.sh start    provision (if needed), boot, and wait until usable
#   tools/emu.sh wait     wait for an already-running emulator to finish booting
#   tools/emu.sh status   print device + boot state
#   tools/emu.sh stop     shut the emulator down
#   tools/emu.sh kill     hard-kill emulator processes
#
# ── Why the AVD lives in build/ ────────────────────────────────────────────────
# On this machine ~/.android is mounted read-only for the agent, so the emulator
# cannot write snapshots/locks/userdata into the default AVD home — it dies with
# "A snapshot operation is pending and timeout has expired".
# We therefore keep a project-local AVD home under build/ (gitignored), defined by
# the checked-in tools/avd-config.ini. That makes the test device self-provisioning
# and reproducible on any machine, instead of depending on whatever AVDs happen to
# exist in the user's home directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="$SDK"
export ANDROID_HOME="$SDK"
export JAVA_HOME="${JAVA_HOME:-$HOME/dev/jdk-17}"
export PATH="$JAVA_HOME/bin:$SDK/platform-tools:$SDK/emulator:$PATH"

# Project-local Android state (all writable, all gitignored).
export ANDROID_AVD_HOME="$ROOT/build/avd"
export ANDROID_USER_HOME="$ROOT/build/android-user"
export ANDROID_EMULATOR_HOME="$ROOT/build/android-user"
export ANDROID_PREFS_ROOT="$ROOT/build/android-user"

EMU="$SDK/emulator/emulator"
ADB="$SDK/platform-tools/adb"
AVD_NAME="${MW_AVD:-mw_api35}"
AVD_INI="$ANDROID_AVD_HOME/$AVD_NAME.ini"
AVD_DIR="$ANDROID_AVD_HOME/$AVD_NAME.avd"
AVD_CONFIG_SRC="$ROOT/tools/avd-config.ini"
LOG_DIR="$ROOT/build"
LOG="$LOG_DIR/emulator.log"
BOOT_TIMEOUT_SEC="${MW_BOOT_TIMEOUT:-420}"
WINDOW_FLAG="${MW_WINDOW:--no-window}"
# GPU mode matters: Godot's gl_compatibility renderer needs a GLES3 driver whose
# GL_MAX_FRAGMENT_UNIFORM_VECTORS is high enough for its scene shader. The emulator's
# plain "swiftshader_indirect" reports only 261, which fails to link the scene shader
# and renders a blank window (ADR-07). Override with MW_GPU if needed.
GPU_MODE="${MW_GPU:-swangle_indirect}"

mkdir -p "$LOG_DIR" "$ANDROID_AVD_HOME" "$ANDROID_USER_HOME"

for tool in "$EMU" "$ADB"; do
  [[ -x "$tool" ]] || { echo "ERROR: missing $tool" >&2; exit 127; }
done

adb() { "$ADB" "$@"; }

# --------------------------------------------------------------- provisioning
ensure_avd() {
  if [[ -f "$AVD_INI" && -f "$AVD_DIR/config.ini" ]]; then
    return
  fi
  echo "[emu] provisioning AVD '$AVD_NAME' in build/avd (one time)"
  [[ -f "$AVD_CONFIG_SRC" ]] || { echo "ERROR: missing $AVD_CONFIG_SRC" >&2; exit 1; }
  mkdir -p "$AVD_DIR"
  cp "$AVD_CONFIG_SRC" "$AVD_DIR/config.ini"
  cat >"$AVD_INI" <<EOF
avd.ini.encoding=UTF-8
path=$AVD_DIR
path.rel=avd/$AVD_NAME.avd
target=android-35
EOF
  echo "[emu] AVD created"
}

is_booted() {
  [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]
}

device_present() {
  adb devices | grep -qE "emulator-[0-9]+\s+device"
}

## A running emulator can report as "offline" purely because the adb server's connection went
## stale — this happens when the shell that started the adb server exits. Restarting the adb
## server revives the connection without touching the emulator, so never conclude "the device
## died" (and never restart it, which needs /dev/kvm and an approval) before trying this.
revive_adb_if_stale() {
  if adb devices | grep -qE "emulator-[0-9]+\s+offline"; then
    echo "[emu] adb reports 'offline' — restarting the adb server to revive the connection"
    adb kill-server >/dev/null 2>&1 || true
    sleep 1
    adb start-server >/dev/null 2>&1 || true
    sleep 2
    adb devices | sed 's/^/      /'
  fi
}

cmd_wait() {
  revive_adb_if_stale
  local waited=0
  echo "[emu] waiting for device (timeout ${BOOT_TIMEOUT_SEC}s)…"
  until device_present; do
    sleep 3; waited=$((waited + 3))
    if (( waited >= BOOT_TIMEOUT_SEC )); then
      echo "[emu] TIMEOUT waiting for device — see $LOG" >&2
      tail -20 "$LOG" >&2 || true
      exit 1
    fi
  done
  echo "[emu] device present after ${waited}s; waiting for boot_completed…"
  while ! is_booted; do
    sleep 3; waited=$((waited + 3))
    if (( waited >= BOOT_TIMEOUT_SEC )); then
      echo "[emu] TIMEOUT waiting for boot_completed — see $LOG" >&2
      tail -20 "$LOG" >&2
      exit 1
    fi
  done
  sleep 6   # let the launcher settle so screenshots aren't taken mid-boot
  adb shell input keyevent 82 >/dev/null 2>&1 || true
  local api release
  api="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
  release="$(adb shell getprop ro.build.version.release | tr -d '\r')"
  echo "[emu] BOOTED in ${waited}s (Android $release / API $api)"
}

## Count running emulator instances for our AVD.
##
## Two traps this avoids:
## 1. The pattern is bracketed ("[q]emu-…") on purpose: `pkill -f` / `pgrep -f` match the full
##    command line, and an unbracketed pattern also matches the very shell running the check —
##    so pkill would kill its own caller. That bit us once already.
## 2. `pgrep` exits 1 when nothing matches, and under `set -o pipefail` that failure propagates
##    through the pipeline and `set -e` aborts the caller *during a variable assignment* —
##    silently, before any output. `|| true` keeps this function's status 0 in the empty case,
##    which is the common case (no emulator running, about to start one).
emulator_process_count() {
  local count=0
  count="$(pgrep -f "[q]emu-system-x86_64.*$AVD_NAME" 2>/dev/null | wc -l || true)"
  printf '%s' "${count//[[:space:]]/}"
}

## Remove lock artifacts left behind when an emulator was killed rather than shut down.
##
## A killed emulator (pkill / crash) leaves `multiinstance.lock` behind, and the next start
## then refuses with "Running multiple emulators with the same AVD is an experimental feature"
## even though nothing is running. Only call this once we have confirmed no emulator for this
## AVD is alive — otherwise it would break a genuinely concurrent instance.
clear_stale_locks() {
  local removed=0
  for lock in "$AVD_DIR/multiinstance.lock" "$AVD_DIR/hardware-qemu.ini.lock"; do
    if [[ -e "$lock" ]]; then
      rm -rf "$lock" && removed=$((removed + 1))
    fi
  done
  if (( removed > 0 )); then
    echo "[emu] cleared $removed stale lock artifact(s) from a previous killed instance"
  fi
}

cmd_start() {
  ensure_avd

  # Duplicate instances of the same AVD fight over ports 5554/5555 and make adb flap between
  # "device" and "offline", which looks like a flaky device but is really two emulators.
  local running
  running="$(emulator_process_count)"
  if (( running > 1 )); then
    echo "[emu] found $running emulator processes for '$AVD_NAME' — cleaning up duplicates first"
    pkill -f "[q]emu-system-x86_64.*$AVD_NAME" >/dev/null 2>&1 || true
    sleep 4
    running="$(emulator_process_count)"
  fi

  if device_present; then
    echo "[emu] already running"
    cmd_wait
    return
  fi

  # No live process for our AVD => any lock file is stale and must go, or the start fails.
  if (( running == 0 )); then
    clear_stale_locks
  fi
  echo "[emu] starting $AVD_NAME ($WINDOW_FLAG, gpu=$GPU_MODE) — log: ${LOG#$ROOT/}"
  nohup "$EMU" -avd "$AVD_NAME" \
    $WINDOW_FLAG -no-audio -no-boot-anim \
    -no-snapshot-load -no-snapshot-save \
    -gpu "$GPU_MODE" \
    -netdelay none -netspeed full \
    -no-metrics \
    >"$LOG" 2>&1 &
  echo "[emu] pid $!"
  cmd_wait
}

cmd_status() {
  echo "--- avd home: $ANDROID_AVD_HOME"
  echo "--- avds: $(ls "$ANDROID_AVD_HOME" 2>/dev/null | tr '\n' ' ')"
  echo "--- devices ---"
  adb devices
  echo "--- boot_completed: $(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || echo '<none>')"
}

cmd_stop() {
  adb emu kill >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do
    device_present || break
    sleep 1
  done
  echo "[emu] stopped"
}

cmd_kill() {
  # Bracketed patterns: see emulator_process_count() — an unbracketed -f pattern matches the
  # shell running this command and kills the caller.
  pkill -f "[q]emu-system-x86_64.*$AVD_NAME" >/dev/null 2>&1 || true
  pkill -f "[e]mulator.*-avd $AVD_NAME" >/dev/null 2>&1 || true
  sleep 3
  adb kill-server >/dev/null 2>&1 || true
  echo "[emu] killed (remaining processes: $(emulator_process_count))"
}

case "${1:-status}" in
  start)  cmd_start ;;
  wait)   cmd_wait ;;
  status) cmd_status ;;
  stop)   cmd_stop ;;
  kill)   cmd_kill ;;
  *) echo "usage: $0 [start|wait|status|stop|kill]" >&2; exit 2 ;;
esac
