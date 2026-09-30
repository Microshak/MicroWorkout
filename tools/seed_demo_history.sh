#!/usr/bin/env bash
# MicroWorkout — seed the debug build's history with the demo fixture (PRD-11 R14).
#
#   tools/seed_demo_history.sh
#
# What it does, in order: force-stops the app, reads the DEVICE's local date, shifts
# `tests/fixtures/history_demo.json` so its newest session is *yesterday on that device*, and
# copies the result over `files/data/history.json` through `run-as`. The shift is the whole
# point: the fixture is authored with fixed dates, and the Tracker must never disagree with
# `Dates.today_iso()` just because the emulator's clock says something else.
#
# Fixture shape (see the file): three consecutive completed days ending yesterday, a two-day
# gap, two sessions in the previous ISO week, and a six-week-old chest/arms session — so
# `shoulders` and `core` render as `Neglected` while the calendar shows done, missed and rest
# days.
#
# It refuses to run against the **release** package: that build is not debuggable, `run-as`
# does not exist, and the point of this script is a truthful demo state on a debug install.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB="$SDK/platform-tools/adb"
PKG="${MW_PKG:-com.microshak.microworkout.debug}"
RELEASE_PKG="com.microshak.microworkout"
FIXTURE="$ROOT/tests/fixtures/history_demo.json"
REMOTE_TMP="/data/local/tmp/mw_history_demo.json"

if [[ "$PKG" == "$RELEASE_PKG" ]]; then
  echo "ERROR: refusing to seed the release package '$PKG' (no run-as; unsigned for debugging)" >&2
  exit 2
fi

if [[ ! -f "$FIXTURE" ]]; then
  echo "ERROR: fixture not found: $FIXTURE" >&2
  exit 2
fi

adb() { "$ADB" "$@"; }

if ! adb devices | grep -qE "[[:space:]]device$"; then
  echo "ERROR: no emulator/device attached — run tools/adb_ready.sh first" >&2
  exit 1
fi

DEVICE_TODAY="$(adb shell date +%F | tr -d '\r')"
if [[ ! "$DEVICE_TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: could not read the device date (got '$DEVICE_TODAY')" >&2
  exit 1
fi
DEVICE_YESTERDAY="$(date -d "$DEVICE_TODAY -1 day" +%F)"

STAGED="$(mktemp /tmp/mw-history-demo.XXXXXX.json)"
python3 - "$FIXTURE" "$DEVICE_YESTERDAY" "$STAGED" <<'PY'
import datetime as dt
import json
import sys

fixture_path, yesterday, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(fixture_path, encoding="utf-8") as handle:
    doc = json.load(handle)

dates = [dt.date.fromisoformat(e["date"]) for e in doc["entries"]]
delta = dt.date.fromisoformat(yesterday) - max(dates)


def shift_stamp(value: str) -> str:
    if not value:
        return value
    return (dt.datetime.fromisoformat(value.replace("Z", "")) + delta).isoformat() + "Z"


for entry in doc["entries"]:
    entry["date"] = (dt.date.fromisoformat(entry["date"]) + delta).isoformat()
    entry["started_at"] = shift_stamp(entry.get("started_at", ""))
    entry["completed_at"] = shift_stamp(entry.get("completed_at", ""))

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")

print("[seed] shifted by %+d day(s): newest session -> %s" % (delta.days, yesterday))
PY

trap 'rm -f "$STAGED"' EXIT

echo "[seed] device date=$DEVICE_TODAY target yesterday=$DEVICE_YESTERDAY package=$PKG"
adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
adb push "$STAGED" "$REMOTE_TMP" >/dev/null
adb shell run-as "$PKG" cp "$REMOTE_TMP" files/data/history.json
# `run-as <pkg> cat <file>` — not `sh -c "cat <file>"`: adb joins `sh -c cat <file>` into
# `sh -c cat file`, which runs a bare `cat` that reads stdin and hangs forever (learned here).
adb shell run-as "$PKG" cat files/data/history.json | python3 -c \
  'import json,sys; doc=json.load(sys.stdin); entries=doc["entries"]; newest=max(e["date"] for e in entries); print("[seed] on-device entries=%d newest=%s" % (len(entries), newest))'
adb shell run-as "$PKG" rm -f files/data/history.json.bak >/dev/null 2>&1 || true
adb shell rm -f "$REMOTE_TMP" >/dev/null 2>&1 || true
# Android 15 refuses `am start` for a non-exported activity from the shell ("not exported from
# uid"), and the Godot debug activity is not exported. The launcher intent is the supported way
# in — the same route `tools/screenshot_tabs.sh` uses.
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
echo "[seed] done — open the Tracker tab (nav_tab_2); expect the ring, a marked calendar and a Neglected row"
