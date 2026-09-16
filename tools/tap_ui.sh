#!/usr/bin/env bash
# MicroWorkout — tap a named UI control on the device, by asking the app where it is.
#
#   tools/tap_ui.sh theme_button
#   tools/tap_ui.sh gallery_button --settle 2
#
# How it works:
#   1. Read the control's viewport rect from logcat (the app logs it in debug builds).
#   2. Calibrate the viewport→screen offset using the bottom nav as an anchor: its centre
#      is measured from the actual screenshot (tools/find_nav.py) and compared with the
#      rect the app reported.
#   3. Tap the translated centre.
#
# This exists because a hard-coded tap coordinate drifts with status-bar and safe-area
# inset differences and fails silently.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB="$SDK/platform-tools/adb"
PKG="${MW_PKG:-com.microshak.microworkout.debug}"
SHOTS="$ROOT/build/screenshots"
TMP="$ROOT/build/tmp"

NAME="${1:-}"
shift || true
SETTLE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --settle) SETTLE="${2:-1}"; shift 2 ;;
    *) echo "usage: $0 NAME [--settle SECONDS]" >&2; exit 2 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "usage: $0 NAME [--settle SECONDS]" >&2
  exit 2
fi

mkdir -p "$SHOTS" "$TMP"
adb() { "$ADB" "$@"; }

latest_rect() {
  # Most recent rect line for this name. The app logs on layout, so we may need to
  # nudge it: a tab switch re-lays-out and re-logs.
  adb logcat -d 2>/dev/null | grep -oE "\[ui\] rect name=$1 x=[0-9]+ y=[0-9]+ w=[0-9]+ h=[0-9]+" | tail -1
}

# ------------------------------------------------------------------ calibration
calibrate() {
  local shot="$TMP/calib.png"
  adb exec-out screencap -p > "$shot"
  local nav_out
  nav_out="$(python3 "$ROOT/tools/find_nav.py" "$shot")"
  local nav_y="${nav_out#nav_y=}"; nav_y="${nav_y%% *}"

  local nav_rect
  nav_rect="$(latest_rect bottom_nav)"
  if [[ -z "$nav_rect" ]]; then
    echo "ERROR: the app has not logged 'bottom_nav' — is the debug build running?" >&2
    exit 1
  fi
  local ny nh
  ny="$(sed -E 's/.* y=([0-9]+).*/\1/' <<<"$nav_rect")"
  nh="$(sed -E 's/.* h=([0-9]+).*/\1/' <<<"$nav_rect")"
  local anchor=$(( ny + nh / 2 ))
  echo $(( nav_y - anchor ))
}

OFFSET_Y="$(calibrate)"
echo "[tap] viewport→screen offset_y=$OFFSET_Y"

RECT="$(latest_rect "$NAME")"
if [[ -z "$RECT" ]]; then
  echo "ERROR: no rect logged for '$name'." >&2
  echo "       Available rect names:" >&2
  adb logcat -d 2>/dev/null | grep -oE "rect name=[a-z_0-9]+" | sort -u | sed 's/^/         /' >&2
  exit 1
fi

X="$(sed -E 's/.* x=([0-9]+).*/\1/' <<<"$RECT")"
Y="$(sed -E 's/.* y=([0-9]+).*/\1/' <<<"$RECT")"
W="$(sed -E 's/.* w=([0-9]+).*/\1/' <<<"$RECT")"
H="$(sed -E 's/.* h=([0-9]+).*/\1/' <<<"$RECT")"

TAP_X=$(( X + W / 2 ))
TAP_Y=$(( Y + H / 2 + OFFSET_Y ))

echo "[tap] $NAME viewport=($X,$Y ${W}x${H}) -> screen=($TAP_X,$TAP_Y)"
adb shell input tap "$TAP_X" "$TAP_Y"
sleep "$SETTLE"
