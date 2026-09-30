#!/usr/bin/env bash
# PRD-12 R6 — dynamic-type audit. Instantiates every shipping `scenes/ui/*.tscn` in a 1080×1920
# SubViewport under a scaled theme and fails on clipped Labels, horizontally scrolling content,
# or anything laid out beyond the design viewport.
#
#   tools/audit_text_scale.sh                 # default: XXL (1.5)
#   tools/audit_text_scale.sh --text-scale 1.0
#   tools/audit_text_scale.sh --text-scale 1.5 res://scenes/ui/workout_player.tscn
#
# boot_screen is skipped: its 900 ms anti-flash timer navigates the tree, which a SubViewport
# audit cannot meaningfully measure. The debug gallery is skipped because it does not ship.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-$HOME/Applications/godot}"

if [[ ! -x "$GODOT" ]]; then
  echo "ERROR: Godot binary not found at $GODOT (override with GODOT_BIN)" >&2
  exit 127
fi

SCALE="1.5"
RECTS=""
SCENES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --text-scale) SCALE="${2:-1.5}"; shift 2 ;;
    --rects) RECTS="${2:-}"; shift 2 ;;
    *) SCENES+=("$1"); shift ;;
  esac
done

if [[ ${#SCENES[@]} -eq 0 ]]; then
  for file in "$ROOT"/scenes/ui/*.tscn; do
    base="$(basename "$file")"
    case "$base" in
      boot_screen.tscn|dev_component_gallery.tscn) continue ;;
    esac
    SCENES+=("res://scenes/ui/$base")
  done
fi

cd "$ROOT"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" --script res://tests/run_text_scale_audit.gd \
  -- --text-scale "$SCALE" ${RECTS:+--rects "$RECTS"} "${SCENES[@]}"
