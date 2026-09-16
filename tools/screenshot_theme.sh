#!/usr/bin/env bash
# MicroWorkout — prove the theme switches live on the device (PRD-02 AC8/AC9).
#
#   tools/screenshot_theme.sh
#
# Captures the same screen in dark and light mode, proves the switch happened *without a
# restart* (no `[boot]` line between the two captures), and asserts the background pixels
# numerically rather than by eye.
#
# NOTE on the pixel probe: PRD-02's AC9 names pixel (24,24). On a device with a visible
# status bar, (24,24) is the *system* status bar, not the app, so the check is performed at
# a point inside the app window and both values are printed for transparency. Recorded in
# DECISIONS.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB="$SDK/platform-tools/adb"
SHOTS="$ROOT/build/screenshots"
PKG="${MW_PKG:-com.microshak.microworkout.debug}"

mkdir -p "$SHOTS"
adb() { "$ADB" "$@"; }

# Land on the Settings tab (which owns the temporary theme toggle) without clearing logcat,
# because tap_ui.sh reads the control rects out of logcat.
"$ROOT/tools/tap_ui.sh" nav_tab_3 --settle 1 >/dev/null
# Tapping the tab re-publishes the settings controls on entry.
"$ROOT/tools/tap_ui.sh" nav_tab_3 --settle 1 >/dev/null

CURRENT="$(adb logcat -d 2>/dev/null | grep -oE "\[theme\] mode=[a-z]+" | tail -1 | sed 's/.*mode=//')"
echo "[theme-shots] currently: ${CURRENT:-unknown}"

ensure_mode() {
  local want="$1" out="$2"
  local mode
  mode="$(adb logcat -d 2>/dev/null | grep -oE "\[theme\] mode=[a-z]+" | tail -1 | sed 's/.*mode=//')"
  if [[ "$mode" != "$want" ]]; then
    "$ROOT/tools/tap_ui.sh" theme_button --settle 2 >/dev/null
  fi
  adb exec-out screencap -p > "$SHOTS/$out"
  echo "[theme-shots] captured $out (mode now: $(adb logcat -d 2>/dev/null | grep -oE "\[theme\] mode=[a-z]+" | tail -1 | sed 's/.*mode=//'))"
}

ensure_mode dark  theme-dark.png
BOOT_BEFORE="$(adb logcat -d 2>/dev/null | grep -c "\[boot\] MicroWorkout" || true)"
ensure_mode light theme-light.png
BOOT_AFTER="$(adb logcat -d 2>/dev/null | grep -c "\[boot\] MicroWorkout" || true)"

echo "[theme-shots] [boot] lines before=$BOOT_BEFORE after=$BOOT_AFTER"
if [[ "$BOOT_BEFORE" != "$BOOT_AFTER" ]]; then
  echo "  ✘ the app restarted between captures — that is not a live theme switch"
  exit 1
fi
echo "  ✔ no restart between the two captures (no new [boot] line)"

python3 - "$SHOTS/theme-dark.png" "$SHOTS/theme-light.png" <<'PY'
import sys
from PIL import Image

dark = Image.open(sys.argv[1]).convert("RGB")
light = Image.open(sys.argv[2]).convert("RGB")
fail = 0

def report(label, ok, detail):
    global fail
    print(f"  {'✔' if ok else '✘'} {label}: {detail}")
    if not ok:
        fail += 1

for name, img, want in (("dark", dark, (0x0F, 0x11, 0x16)), ("light", light, (0xF6, 0xF7, 0xFB))):
    w, h = img.size
    # Sample a grid inside the app window (skip the status bar and the nav bar).
    pts = [(x, y) for y in range(300, h - 400, 60) for x in range(20, w - 20, 60)]
    hits = sum(1 for (x, y) in pts if all(abs(img.getpixel((x, y))[i] - want[i]) <= 10 for i in range(3)))
    ratio = hits / len(pts)
    report(f"{name} mode background",
           ratio >= 0.55,
           f"#{want[0]:02X}{want[1]:02X}{want[2]:02X} covers {ratio:.1%} of the app region "
           f"({hits}/{len(pts)} samples)")

report("raw pixel (24,24)",
       True,
       f"dark=#%02X%02X%02X light=#%02X%02X%02X — this is the system status bar, "
       "so it is reported, not asserted" % (dark.getpixel((24, 24)) + light.getpixel((24, 24))))

# The two frames must actually differ.
diff = sum(1 for (x, y) in [(x, y) for y in range(300, dark.size[1] - 400, 40)
                            for x in range(20, dark.size[0] - 20, 40)]
           if dark.getpixel((x, y)) != light.getpixel((x, y)))
report("frames differ", diff > 0, f"{diff} sampled pixels changed between dark and light")

sys.exit(1 if fail else 0)
PY
