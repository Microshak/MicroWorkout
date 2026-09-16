#!/usr/bin/env bash
# PRD-02 R1 / AC3 — regenerate both theme resources from DesignTokens (the single source of
# truth) and prove the committed pair is byte-for-byte in sync with the tokens.
#
#   tools/build_themes.sh
#
# Exits 0 when the regeneration is a no-op, non-zero when the generated themes drifted — in
# which case the regenerated files are already on disk and must be committed together with the
# token change that caused the drift. Override the engine with GODOT=/path/to/godot.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/Applications/godot}"
GENERATOR="res://scripts/dev/build_themes.gd"
THEMES_DIR="resources/themes"
THEME_FILES=("theme_dark.tres" "theme_light.tres")

cd "$REPO_ROOT"

if [[ ! -x "$GODOT" ]]; then
	echo "build_themes: FAIL — no Godot binary at $GODOT (set GODOT=/path/to/godot)" >&2
	exit 1
fi

echo "build_themes: generating from res://scripts/core/design_tokens.gd"
# The generator prints exactly "[themes] wrote <file> (N items)" per theme and exits non-zero
# on a save error, so a failed run stops the script here.
"$GODOT" --headless --path "$REPO_ROOT" --script "$GENERATOR"

for name in "${THEME_FILES[@]}"; do
	if [[ ! -s "$THEMES_DIR/$name" ]]; then
		echo "build_themes: FAIL — $THEMES_DIR/$name was not written" >&2
		exit 1
	fi
	echo "build_themes: wrote $THEMES_DIR/$name ($(wc -c < "$THEMES_DIR/$name") bytes)"
done

# AC3 — regeneration must leave the tree clean. `git diff --exit-code` can only see tracked
# files, so brand-new (never committed) themes are called out instead of passing silently.
UNTRACKED="$(git ls-files --others --exclude-standard -- "$THEMES_DIR")"
if [[ -n "$UNTRACKED" ]]; then
	echo "build_themes: NOTE — these theme files are untracked, so git diff cannot see them yet:"
	while IFS= read -r file; do
		echo "build_themes:   $file"
	done <<< "$UNTRACKED"
	echo "build_themes:   → 'git add $THEMES_DIR' to put them under drift control"
fi

set +e
DIFF_OUTPUT="$(git diff --exit-code -- "$THEMES_DIR" 2>&1)"
DIFF_STATUS=$?
set -e

if [[ $DIFF_STATUS -ne 0 ]]; then
	echo "build_themes: FAIL — the regenerated themes differ from the committed ones:" >&2
	echo "$DIFF_OUTPUT" >&2
	echo "build_themes: the .tres files are generated; commit them with the token change" >&2
	exit "$DIFF_STATUS"
fi

if [[ -n "$UNTRACKED" ]]; then
	echo "build_themes: PASS (untracked) — generation succeeded; drift check is live after 'git add'"
else
	echo "build_themes: PASS — git diff --exit-code $THEMES_DIR is clean"
fi
