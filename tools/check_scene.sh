#!/usr/bin/env bash
# MicroWorkout — instantiate one or more scenes headless and report whether they survive a frame.
#
#   tools/check_scene.sh res://scenes/ui/workout_player.tscn
#
# Catches the `.tscn` failures the parser cannot: stale node paths in `@onready`, unresolvable
# ExtResources, and crashes on the first frame. See `tests/check_scene.gd`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-$HOME/Applications/godot}"

if [[ ! -x "$GODOT" ]]; then
  echo "ERROR: Godot binary not found at $GODOT (override with GODOT_BIN)" >&2
  exit 127
fi

if [[ $# -lt 1 ]]; then
  echo "usage: tools/check_scene.sh res://scenes/ui/foo.tscn […]" >&2
  exit 2
fi

cd "$ROOT"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" --script res://tests/check_scene.gd -- "$@"
