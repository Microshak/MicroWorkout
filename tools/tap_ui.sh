#!/usr/bin/env bash
# MicroWorkout — tap a named UI control on the device, by asking the app where it is.
#
#   tools/tap_ui.sh theme_button
#   tools/tap_ui.sh gallery_button --settle 2
#   tools/tap_ui.sh player_swipe --swipe left
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
SWIPE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --settle) SETTLE="${2:-1}"; shift 2 ;;
    --swipe) SWIPE="${2:-left}"; shift 2 ;;
    *) echo "usage: $0 NAME [--settle SECONDS] [--swipe left|right]" >&2; exit 2 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "usage: $0 NAME [--settle SECONDS] [--swipe left|right]" >&2
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
#
# The viewport→screen offset is learned by comparing a *measured* pixel position with the
# rect the app reported for the same control. The bottom nav is the best anchor because it is
# always present in the shell and is easy to find in pixels. But screens that replace the shell
# entirely — onboarding, a pushed full-screen flow — have no bottom nav, so an offset measured
# on a previous screen is cached and reused. It only depends on the device geometry and the
# safe-area insets, which do not change between screens on one device.
OFFSET_CACHE="$TMP/viewport_offset_y"

calibrate() {
  local shot="$TMP/calib.png"
  adb exec-out screencap -p > "$shot"

  local nav_rect
  nav_rect="$(latest_rect bottom_nav)"
  if [[ -n "$nav_rect" ]]; then
    local ny nh offset band band_h
    ny="$(sed -E 's/.* y=([0-9]+).*/\1/' <<<"$nav_rect")"
    nh="$(sed -E 's/.* h=([0-9]+).*/\1/' <<<"$nav_rect")"

    # Measure the bar *band* itself (find_nav.py --nav-band) and accept it only when it is
    # consistent with the rect the app reported: a pushed screen has no bottom nav at all, and a
    # band found there (the illustration card's edge, the Next button) would silently recalibrate
    # the offset. That is exactly how a 132 px offset became 125 and moved a tap from the middle of
    # `Next` to one pixel above it.
    band="$(python3 "$ROOT/tools/find_nav.py" "$shot" --nav-band --from-viewport-y "$ny" 2>/dev/null || true)"
    offset="$(sed -n 's/.*offset_y=\(-*[0-9]*\).*/\1/p' <<<"$band")"
    band_h="$(sed -n 's/.*nav_height=\([0-9]*\).*/\1/p' <<<"$band")"
    if [[ "$offset" =~ ^-?[0-9]+$ && "$band_h" =~ ^[0-9]+$ ]] \
        && (( band_h > nh - 20 && band_h < nh + 20 )); then
      printf '%s' "$offset" > "$OFFSET_CACHE"
      echo "$offset"
      return
    fi
  fi

  # A cached offset is device geometry, which does not change between screens — prefer it over a
  # heuristic measured on a screen that may not even have a tab strip.
  if [[ -s "$OFFSET_CACHE" ]]; then
    cat "$OFFSET_CACHE"
    return
  fi

  # Last resort: the tab-strip heuristic, for a first calibration on a screen with no measurable bar.
  if [[ -n "$nav_rect" ]]; then
    local nav_out nav_y nh2
    nav_out="$(python3 "$ROOT/tools/find_nav.py" "$shot" 2>/dev/null || true)"
    nav_y="${nav_out#nav_y=}"; nav_y="${nav_y%% *}"
    if [[ "$nav_y" =~ ^[0-9]+$ ]]; then
      nh2="$(sed -E 's/.* h=([0-9]+).*/\1/' <<<"$nav_rect")"
      local offset2=$(( nav_y - (ny + nh2 / 2) ))
      printf '%s' "$offset2" > "$OFFSET_CACHE"
      echo "$offset2"
      return
    fi
  fi

  if [[ -s "$OFFSET_CACHE" ]]; then
    echo "[tap] no bottom nav on this screen — reusing cached offset from a previous screen" >&2
    cat "$OFFSET_CACHE"
    return
  fi

  echo "ERROR: cannot calibrate: no bottom_nav rect logged and no cached offset in $OFFSET_CACHE" >&2
  exit 1
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

Y_MID=$(( Y + H / 2 + OFFSET_Y ))

if [[ -n "$SWIPE" ]]; then
  # ADR-24: the player's step change is a horizontal swipe, not a button tap. Swipe inside the
  # control's own rect (an eighth in from each edge) at its vertical centre, so the gesture runs
  # across the surface the app actually listens to, whatever the device geometry is.
  INSET=$(( W / 8 ))
  if [[ "$SWIPE" == "right" ]]; then
    X_FROM=$(( X + INSET )); X_TO=$(( X + W - INSET ))
  else
    X_FROM=$(( X + W - INSET )); X_TO=$(( X + INSET ))
  fi
  echo "[tap] swipe-$SWIPE $NAME viewport=($X,$Y ${W}x${H}) -> screen=($X_FROM,$Y_MID)->($X_TO,$Y_MID)"
  adb shell input swipe "$X_FROM" "$Y_MID" "$X_TO" "$Y_MID" 140
  sleep "$SETTLE"
  exit 0
fi

TAP_X=$(( X + W / 2 ))
echo "[tap] $NAME viewport=($X,$Y ${W}x${H}) -> screen=($TAP_X,$Y_MID)"
adb shell input tap "$TAP_X" "$Y_MID"
sleep "$SETTLE"
