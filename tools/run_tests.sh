#!/usr/bin/env bash
# MicroWorkout — headless unit test runner (PRD-00 §10 layer 1).
# Exits 0 when every suite passes, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-$HOME/Applications/godot}"

if [[ ! -x "$GODOT" ]]; then
  echo "ERROR: Godot binary not found at $GODOT (override with GODOT_BIN)" >&2
  exit 127
fi

cd "$ROOT"
# --import keeps the global class cache fresh so `class_name` lookups resolve.
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" --script res://tests/run_tests.gd
