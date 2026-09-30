#!/usr/bin/env bash
# MicroWorkout — install the signed release APK on the owner's phone over wireless debugging.
#
#   tools/install_to_phone.sh [path/to/apk]      (default: build/MicroWorkout.apk)
#
# Before running: phone → Settings → Developer options → Wireless debugging → ON.
# The script waits for the phone's *pairing* service (visible only while the phone shows
# "Pair device with pairing code"), then `adb pair` prompts for the 6-digit code — type it
# at the prompt; it is never written anywhere. After that it discovers the *connect* service
# over mDNS, connects, installs, launches the app and waits for the boot health line.
#
# Retries exist because a fresh shell starts a fresh adb server and mDNS discovery takes a
# few seconds to populate — the same trap tools/adb_ready.sh exists for.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
APK="${1:-$ROOT/build/MicroWorkout.apk}"
PKG="com.microshak.microworkout"
PAIR_WAIT="${PAIR_WAIT:-180}"
CONNECT_WAIT="${CONNECT_WAIT:-30}"
BOOT_WAIT="${BOOT_WAIT:-60}"

[[ -x "$ADB" ]] || { echo "ERROR: adb not found at $ADB" >&2; exit 127; }
[[ -f "$APK" ]] || { echo "ERROR: APK not found: $APK (build it: tools/build_android.sh release)" >&2; exit 1; }
"$ADB" start-server >/dev/null 2>&1 || true

service_addr() { # $1 = mDNS service name, e.g. _adb-tls-pairing._tcp
  "$ADB" mdns services 2>/dev/null | awk -v svc="$1" '$2 == svc {print $3; exit}'
}

wait_for_service() { # $1 = service name, $2 = timeout in seconds
  local waited=0 addr
  while (( waited < $2 )); do
    addr="$(service_addr "$1")"
    [[ -n "$addr" ]] && { printf '%s' "$addr"; return 0; }
    sleep 1; waited=$((waited + 1))
  done
  return 1
}

echo "[phone] waiting for the pairing service (open 'Pair device with pairing code' on the phone)…"
pair_addr="$(wait_for_service _adb-tls-pairing._tcp "$PAIR_WAIT")" || {
  echo "ERROR: no pairing service after ${PAIR_WAIT}s — is Wireless debugging ON and the pairing dialog open?" >&2
  exit 1
}
echo "[phone] pairing with $pair_addr — enter the 6-digit code at the prompt"
"$ADB" pair "$pair_addr"

echo "[phone] looking for the connect service…"
conn_addr="$(wait_for_service _adb-tls-connect._tcp "$CONNECT_WAIT")" || {
  echo "ERROR: paired, but no connect service found after ${CONNECT_WAIT}s." >&2
  exit 1
}
"$ADB" connect "$conn_addr" >/dev/null
if ! "$ADB" devices | awk -v a="$conn_addr" '$1 == a && $2 == "device" {found=1} END {exit !found}'; then
  echo "ERROR: $conn_addr is not online — if it says 'unauthorized', tap Allow on the phone." >&2
  "$ADB" devices >&2
  exit 1
fi

echo "[phone] installing $(basename "$APK")"
if ! "$ADB" install -r "$APK"; then
  echo "HINT: for INSTALL_FAILED_UPDATE_INCOMPATIBLE (an older app signed with another key):" >&2
  echo "      $ADB uninstall $PKG   — then run this script again" >&2
  exit 1
fi

"$ADB" logcat -c >/dev/null 2>&1 || true
"$ADB" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
echo "[phone] launched; waiting for the boot health line…"
waited=0
while (( waited < BOOT_WAIT )); do
  if "$ADB" logcat -d 2>/dev/null | grep -q "\[data\] settings_keys="; then
    echo "[phone] installed and booted:"
    "$ADB" logcat -d | grep -E "\[library\] loaded|\[theme\] mode|\[data\] settings_keys=" | tail -4
    exit 0
  fi
  sleep 1; waited=$((waited + 1))
done
echo "WARNING: installed and launched, but no boot line within ${BOOT_WAIT}s — check the phone screen." >&2
exit 1
