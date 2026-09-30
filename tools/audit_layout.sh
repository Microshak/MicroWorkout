#!/usr/bin/env bash
# PRD-12 R3/R5/R6 — the layout audit: touch targets (≥ 88 px), accessible names, clipped
# labels, horizontal scrolling and absolute-position lint, swept at text scale 1.0 *and* 1.5.
#
#   tools/audit_layout.sh                        # both scales, every shipping screen (AC1)
#   tools/audit_layout.sh --text-scale 1.5       # one scale
#   tools/audit_layout.sh res://scenes/ui/home_tab.tscn   # one scene, both scales
#
# Runs `tests/run_layout_audit.gd` once per scale; exits non-zero if any scale reports a
# finding. `boot_screen` is skipped (its anti-flash timer navigates the tree inside a
# SubViewport) and the debug gallery is skipped because it does not ship.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-$HOME/Applications/godot}"

if [[ ! -x "$GODOT" ]]; then
	echo "ERROR: Godot binary not found at $GODOT (override with GODOT_BIN)" >&2
	exit 127
fi

SCALES=("1.0" "1.5")
SCENES=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--text-scale) SCALES=("${2:-1.0}"); shift 2 ;;
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

STATUS=0
for scale in "${SCALES[@]}"; do
	echo "audit_layout: text-scale=$scale scenes=${#SCENES[@]}"
	if ! "$GODOT" --headless --path "$ROOT" --script res://tests/run_layout_audit.gd \
			-- --text-scale "$scale" "${SCENES[@]}"; then
		STATUS=1
	fi
done

if [[ $STATUS -eq 0 ]]; then
	echo "audit_layout: PASS (${#SCALES[@]} scale(s), ${#SCENES[@]} scene(s))"
else
	echo "audit_layout: FAIL — see the [layout] FAIL lines above" >&2
fi
exit $STATUS
