#!/usr/bin/env bash
# MicroWorkout — run ONE headless suite (the fast loop while implementing).
#
#   tools/run_suite.sh test_session_run [test_progression …]
#
# `tools/run_tests.sh` is the gate; this is the iteration tool. Same `TestSuite` base, same
# assertions, ~seconds instead of minutes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-$HOME/Applications/godot}"

if [[ ! -x "$GODOT" ]]; then
  echo "ERROR: Godot binary not found at $GODOT (override with GODOT_BIN)" >&2
  exit 127
fi

if [[ $# -lt 1 ]]; then
  echo "usage: tools/run_suite.sh <suite> [more…]" >&2
  exit 2
fi

cd "$ROOT"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" --script res://tests/run_suite.gd -- "$@"
