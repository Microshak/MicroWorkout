#!/usr/bin/env bash
# MicroWorkout — capture and VERIFY one screenshot per tab (PRD-02 AC7).
#
#   tools/screenshot_tabs.sh                     # all four tabs
#   tools/screenshot_tabs.sh --only settings
#   tools/screenshot_tabs.sh --suffix layout-short
#
# Taps come from tools/tap_ui.sh, which asks the app where its nav buttons actually are
# and calibrates viewport→screen coordinates against the rendered pixels. After each
# capture the screenshot is checked with tools/find_nav.py: the tab tinted `primary` must
# be the one we just tapped. Without that check a failed tap produces four identical
# screenshots that all "pass" — which is exactly what happened the first time this ran.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB="$SDK/platform-tools/adb"
SHOTS="$ROOT/build/screenshots"
PKG="${MW_PKG:-com.microshak.microworkout.debug}"

ONLY=""
SUFFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)   ONLY="${2:-}"; shift 2 ;;
    --suffix) SUFFIX="${2:-}"; shift 2 ;;
    *) echo "usage: $0 [--only home|plan|tracker|settings] [--suffix NAME]" >&2; exit 2 ;;
  esac
done

mkdir -p "$SHOTS"
adb() { "$ADB" "$@"; }

if ! adb devices | grep -qE "emulator-[0-9]+\s+device"; then
  echo "ERROR: no emulator/device attached" >&2
  exit 1
fi

NAMES=(home plan tracker settings)
FAILURES=0

# Make sure the app is in the foreground and has re-logged its rects.
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 3

capture_and_verify() {
  local index="$1" name="$2"
  local path="$SHOTS/tab-$index-$name${SUFFIX:+-$SUFFIX}.png"

  if ! "$ROOT/tools/tap_ui.sh" "nav_tab_$index" --settle 1 >/dev/null 2>&1; then
    echo "  ✘ tab $index ($name): could not tap nav_tab_$index"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # Give the emulator time to render the new tab before capturing. Under software GL it can run
  # well below 1 fps, and a screencap taken immediately after the tap can still be the previous
  # tab's frame — which the tint check below then (correctly) rejects as a wrong tab. Measured
  # 2026-09-30: settings failed once without this wait and passed consistently with it.
  sleep 2
  adb exec-out screencap -p > "$path"

  # `--in-nav-band`: look for the tinted tab only inside the measured nav bar. Without it the
  # Settings screen's own primary controls out-number the nav tint and the check fails a good
  # screenshot (measured 2026-09-30).
  if python3 "$ROOT/tools/find_nav.py" "$path" --expect-index "$index" --in-nav-band >/dev/null 2>&1; then
    local info
    info="$(python3 "$ROOT/tools/find_nav.py" "$path" --in-nav-band)"
    echo "  ✔ tab $index ($name)  $(stat -c%s "$path") bytes  [$info]"
  else
    echo "  ✘ tab $index ($name): the screenshot does not show tab $index as active"
    python3 "$ROOT/tools/find_nav.py" "$path" --in-nav-band 2>&1 | sed 's/^/      /' || true
    FAILURES=$((FAILURES + 1))
  fi
}

for i in 0 1 2 3; do
  NAME="${NAMES[$i]}"
  if [[ -n "$ONLY" && "$ONLY" != "$NAME" ]]; then
    continue
  fi
  capture_and_verify "$i" "$NAME"
done

echo "──────────────────────────────────────────────────────────────"
if (( FAILURES == 0 )); then
  echo "[shots] PASS — evidence in ${SHOTS#$ROOT/}"
  exit 0
else
  echo "[shots] FAIL — $FAILURES tab(s) did not verify"
  exit 1
fi
