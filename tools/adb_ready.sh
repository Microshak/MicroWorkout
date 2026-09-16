#!/usr/bin/env bash
# MicroWorkout — ensure a usable adb connection to the emulator, reviving a stale one.
#
#   tools/adb_ready.sh [timeout_seconds]
#
# Why this exists: each command here runs in a fresh sandbox, so the adb server started by a
# previous command is gone. A long build (~60 s) is enough for the connection to go stale, and
# the next `adb install` then races the reconnect and fails with "device offline" — which looks
# exactly like a broken device or a broken APK. Rather than conclude either, force a clean
# connection and wait for it.
#
# Exit 0 when a device is online and `sys.boot_completed=1`, 1 otherwise.
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
TIMEOUT="${1:-90}"

[[ -x "$ADB" ]] || { echo "ERROR: adb not found at $ADB" >&2; exit 127; }

waited=0
"$ADB" start-server >/dev/null 2>&1 || true

while (( waited < TIMEOUT )); do
  state="$("$ADB" devices 2>/dev/null | grep -E "emulator-[0-9]+" | head -1 | awk '{print $2}' | tr -d '\r' || true)"
  case "$state" in
    device)
      booted="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
      if [[ "$booted" == "1" ]]; then
        echo "[adb] ready (device online, boot_completed=1)"
        exit 0
      fi
      ;;
    offline|unauthorized|"")
      # A stale server is the usual cause; restart it and retry.
      "$ADB" kill-server >/dev/null 2>&1 || true
      sleep 1
      "$ADB" start-server >/dev/null 2>&1 || true
      ;;
  esac
  sleep 2; waited=$((waited + 2))
done

echo "ERROR: no usable adb device after ${TIMEOUT}s (last state: '${state:-none}')" >&2
"$ADB" devices >&2 || true
exit 1
