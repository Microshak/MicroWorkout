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

cmd_wait() {
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

cmd_start() {
  ensure_avd
  if device_present; then
    echo "[emu] already running"
    cmd_wait
    return
  fi
  echo "[emu] starting $AVD_NAME ($WINDOW_FLAG, swiftshader) — log: ${LOG#$ROOT/}"
  nohup "$EMU" -avd "$AVD_NAME" \
    $WINDOW_FLAG -no-audio -no-boot-anim \
    -no-snapshot-load -no-snapshot-save \
    -gpu swiftshader_indirect \
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
  pkill -f "qemu-system-x86_64.*$AVD_NAME" >/dev/null 2>&1 || true
  pkill -f "emulator.*-avd $AVD_NAME" >/dev/null 2>&1 || true
  adb kill-server >/dev/null 2>&1 || true
  echo "[emu] killed"
}

case "${1:-status}" in
  start)  cmd_start ;;
  wait)   cmd_wait ;;
  status) cmd_status ;;
  stop)   cmd_stop ;;
  kill)   cmd_kill ;;
  *) echo "usage: $0 [start|wait|status|stop|kill]" >&2; exit 2 ;;
esac
