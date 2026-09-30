#!/usr/bin/env python3
"""PRD-12 R4/R7 — measured WCAG 2.1 contrast audit for the design tokens.

    python3 tools/check_contrast.py --theme dark --theme light   # AC2
    python3 tools/check_contrast.py --grayscale                  # AC2 (R7)

The palettes are read from `resources/themes/tokens.json`, which
`scripts/dev/build_themes.gd` generates from `scripts/core/design_tokens.gd` beside the two
theme resources — so this script measures exactly what the app renders, and it can never
drift from the constants without `tools/build_themes.sh` failing its `git diff --exit-code`
gate first. Nothing here is hard-coded from the spec: every ratio is computed from the
token hex values.

Exit status
    0  every walked pair passes, or fails only where `EXEMPT` carries a written reason,
       and (with --grayscale) every in-component near-collision is shape-mitigated
    1  an unexempted pair fails, or two states of one component are greyscale-identical
       and differ by colour alone
    2  usage error (unknown theme, missing/garbled tokens.json)

Token naming
    The spec calls the on-fill foreground `on_primary`; this repository's token (PRD-00
    appendix §4) is `on_accent`, and the light-theme text colours are `*_text_light`.
    Both are used here so the audit and the theme share one vocabulary.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
TOKENS_JSON = REPO_ROOT / "resources" / "themes" / "tokens.json"

AA_TEXT = 4.5  # WCAG 2.1 SC 1.4.3 — body text
AA_LARGE = 3.0  # WCAG 2.1 SC 1.4.11 — large text, icons, focus rings, boundaries
COLLISION = 1.15  # R7 — below this, two greyscale values are the same patch of grey

# --- the pairs the app actually renders -------------------------------------------------
# (foreground, background, need, label, modes). `label` says where the pair lives, so a
# failure names the component instead of just two token names.
PAIRS = [
    ("text", "bg", AA_TEXT, "body text on the page", ("dark", "light")),
    ("text", "surface", AA_TEXT, "body text on a card", ("dark", "light")),
    ("text", "surface_alt", AA_TEXT, "body text on an alt card", ("dark", "light")),
    ("text_muted", "bg", AA_TEXT, "secondary text on the page", ("dark", "light")),
    ("text_muted", "surface", AA_TEXT, "secondary text on a card", ("dark", "light")),
    ("text_muted", "surface_alt", AA_TEXT, "secondary text on an alt card", ("dark", "light")),
    ("on_accent", "primary", AA_TEXT, "primary button label on its fill", ("dark", "light")),
    ("primary", "surface", AA_TEXT, "links, icons and the focus ring", ("dark",)),
    ("secondary", "surface", AA_TEXT, "cardio / info colour as an icon", ("dark",)),
    ("success", "surface", AA_TEXT, "done colour as an icon", ("dark",)),
    ("warning", "surface", AA_TEXT, "warning colour as an icon", ("dark",)),
    ("danger", "surface", AA_TEXT, "danger text on a card", ("dark",)),
    ("danger", "surface_alt", AA_TEXT, "danger text on an alt card", ("dark",)),
    ("danger_text_light", "surface", AA_TEXT, "danger text on a card", ("light",)),
    ("primary_text_light", "surface", AA_TEXT, "link / accent text", ("light",)),
    ("secondary_text_light", "surface", AA_TEXT, "info text", ("light",)),
    ("success_text_light", "surface", AA_TEXT, "success text", ("light",)),
    ("warning_text_light", "surface", AA_TEXT, "warning text", ("light",)),
    ("primary_dim", "surface", AA_LARGE, "ring track against the card", ("dark", "light")),
    ("outline_strong", "surface", AA_LARGE, "input border and the planned-day ring", ("dark", "light")),
    # Low-contrast by design — every one carries a written reason below.
    ("text_disabled", "surface", AA_TEXT, "disabled control label", ("dark",)),
    ("outline", "surface", AA_LARGE, "decorative card edge / divider", ("dark", "light")),
]

#: pair key -> why the failure is allowed to ship. WCAG has explicit exclusions for both.
EXEMPT = {
    ("text_disabled", "surface"): (
        "SC 1.4.3 exempts inactive controls; disabled text is deliberately low-contrast"
    ),
    ("outline", "surface"): (
        "decorative card edges, dividers and the toast grabber only; SC 1.4.11 exempts "
        "purely decorative boundaries — every functional border uses outline_strong"
    ),
}

# --- combinations that must never be walked ---------------------------------------------
# Measured failures that the design avoids by construction. Each entry names the modes it is
# banned in (a raw accent is fine as dark-theme text but is banned in light mode), and
# `audit_banned()` proves no walked pair contains one of them for the same mode — so the ban
# cannot silently rot into a "passing" audit.
BANNED = [
    # Dark-mode `text` is #F4F6FA (2.62:1); in light mode it is #12151C, which is exactly
    # `on_accent`, so only the dark pair is a ban.
    ("text", "primary", ("dark",),
     "2.62:1 — body text never sits on a primary fill; use on_accent"),
    ("#FFFFFF", "primary", ("dark", "light"),
     "2.84:1 — white is never used on a primary fill; use on_accent"),
    ("on_accent", "primary_dim", ("dark", "light"),
     "4.02:1 — press feedback scales + scrims, it never swaps the fill"),
    ("primary", "surface", ("light",),
     "2.84:1 — raw accent as light-theme text; use primary_text_light"),
    ("secondary", "surface", ("light",),
     "1.99:1 — raw accent as light-theme text; use secondary_text_light"),
    ("success", "surface", ("light",),
     "1.99:1 — raw accent as light-theme text; use success_text_light"),
    ("warning", "surface", ("light",),
     "1.83:1 — raw accent as light-theme text; use warning_text_light"),
    ("danger", "surface", ("light",),
     "3.03:1 — raw accent as light-theme text; use danger_text_light"),
]

# --- R7 ②: one component, several states, and the shape cue that separates them ---------
# If two states of the same component are greyscale-identical, the pair must not be the only
# difference between them: each state declares its non-colour cue, and the audit fails when a
# colliding pair has none. This mirrors the components named in PRD-12 R7.
COMPONENT_STATES = {
    "calendar day cell": {
        "done": ("success", "filled circle + check mark"),
        "missed": ("danger", "arc + 45° slash"),
        "planned": ("outline_strong", "hollow ring"),
        "today": ("primary", "3 px border"),
        "rest": ("outline", "no mark (the absence is the cue)"),
    },
    "area balance bar": {
        "trained": ("primary", "partial fill width"),
        "neglected": ("warning", "alert glyph + the word 'Neglected'"),
    },
    "session row": {
        "complete": ("success", "no badge"),
        "partial": ("warning", "alert glyph"),
    },
    "toast": {
        "info": ("secondary", "info glyph"),
        "success": ("success", "check glyph"),
        "warning": ("warning", "alert glyph"),
        "danger": ("danger", "cross glyph"),
    },
    "status chip": {
        "completed": ("success", "the word 'Completed'"),
        "partial": ("warning", "the words 'Partial — n of m'"),
    },
    "streak tile": {
        "today done": ("success", "check glyph"),
        "today not done": ("text_muted", "no glyph"),
    },
}


def load_palettes() -> dict:
    try:
        data = json.loads(TOKENS_JSON.read_text(encoding="utf-8"))
    except FileNotFoundError:
        sys.exit(f"check_contrast: FAIL — {TOKENS_JSON} is missing; run tools/build_themes.sh")
    except json.JSONDecodeError as exc:
        sys.exit(f"check_contrast: FAIL — {TOKENS_JSON} is not valid JSON: {exc}")
    palettes = data.get("palettes")
    if not isinstance(palettes, dict) or not palettes:
        sys.exit(f"check_contrast: FAIL — {TOKENS_JSON} has no 'palettes' object")
    return palettes


def hex_to_rgb(value: str) -> tuple[float, float, float]:
    text = value.removeprefix("#")
    if len(text) != 6:
        sys.exit(f"check_contrast: FAIL — '{value}' is not a #RRGGBB colour")
    return tuple(int(text[i : i + 2], 16) / 255.0 for i in (0, 2, 4))  # type: ignore[return-value]


def luminance(rgb: tuple[float, float, float]) -> float:
    """WCAG 2.1 relative luminance."""
    linear = []
    for channel in rgb:
        linear.append(channel / 12.92 if channel <= 0.03928 else ((channel + 0.055) / 1.055) ** 2.4)
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def ratio(fg: str, bg: str, palette: dict) -> float:
    """Contrast between two tokens (or literal `#RRGGBB` values) in [param palette]."""
    la = luminance(hex_to_rgb(resolve(fg, palette)))
    lb = luminance(hex_to_rgb(resolve(bg, palette)))
    lighter, darker = max(la, lb), min(la, lb)
    return (lighter + 0.05) / (darker + 0.05)


def resolve(token: str, palette: dict) -> str:
    """`#RRGGBB` passes through; a token name resolves through the palette."""
    if token.startswith("#"):
        return token
    value = palette.get(token)
    if value is None:
        sys.exit(f"check_contrast: FAIL — palette has no token '{token}'")
    return value


def audit_theme(mode: str, palette: dict, failures: list[str]) -> int:
    walked = 0
    for fg, bg, need, label, modes in PAIRS:
        if mode not in modes:
            continue
        walked += 1
        value = ratio(fg, bg, palette)
        passed = value >= need
        verdict = "PASS" if passed else "FAIL"
        print(f"PAIR {mode:<5} {fg} on {bg} = {value:.2f} (need {need:.1f}) {verdict}")
        if passed:
            continue
        reason = EXEMPT.get((fg, bg))
        if reason:
            print(f"PAIR {mode:<5} {fg} on {bg} — exempt: {reason}")
        else:
            failures.append(f"{mode}: {fg} on {bg} = {value:.2f} (need {need:.1f}) — {label}")
    return walked


def audit_banned(palettes: dict, failures: list[str]) -> None:
    """Print the banned combinations with their measured ratio and prove none is walked."""
    print("\nBANNED (measured, never walked)")
    for fg, bg, modes, reason in BANNED:
        for mode in modes:
            value = ratio(fg, bg, palettes[mode])
            print(f"BANNED {mode:<5} {fg} on {bg} = {value:.2f} — {reason}")
    for banned_fg, banned_bg, banned_modes, _reason in BANNED:
        for fg, bg, _need, _label, modes in PAIRS:
            if fg != banned_fg or bg != banned_bg:
                continue
            if set(modes) & set(banned_modes):
                failures.append(
                    f"pair {fg}/{bg} is banned for {'/'.join(banned_modes)} but was walked"
                )


def grayscale(palettes: dict, failures: list[str]) -> None:
    """R7 ③ — luminance table and every pairwise greyscale contrast, then the state maps."""
    for mode in ("dark", "light"):
        palette = palettes.get(mode, {})
        print(f"\nLUMINANCE ({mode})")
        rows = sorted(
            ((luminance(hex_to_rgb(value)), name) for name, value in palette.items()),
            reverse=True,
        )
        for value, name in rows:
            print(f"GRAY {mode:<5} {name:<22} L={value:.4f} {palette[name]}")

        names = sorted(palette)
        collisions: list[tuple[str, str, float]] = []
        for i, a in enumerate(names):
            for b in names[i + 1 :]:
                value = ratio(a, b, palette)
                if value < COLLISION:
                    collisions.append((a, b, value))
        print(f"\nGRAY {mode} — pairwise greyscale contrasts below {COLLISION:.2f}")
        if not collisions:
            print(f"GRAY {mode} — none")
        for a, b, value in sorted(collisions, key=lambda row: row[2]):
            print(f"GRAY {mode:<5} {a}/{b} = {value:.2f}")

        # AC2 pins this exact line: R7's example collision, and the reason the calendar adds
        # a check mark / slash instead of relying on green-vs-red.
        pinned = ratio("success", "secondary", palette)
        mark = "collision" if pinned < COLLISION else "distinct"
        print(f"GRAY {mode:<5} success/secondary = {pinned:.2f} ({mark})")

        colliding = {(a, b): v for a, b, v in collisions}
        print(f"\nCOMPONENTS ({mode})")
        for component, states in COMPONENT_STATES.items():
            state_names = sorted(states)
            for i, a in enumerate(state_names):
                for b in state_names[i + 1 :]:
                    colour_a, cue_a = states[a]
                    colour_b, cue_b = states[b]
                    pair = tuple(sorted((colour_a, colour_b)))
                    value = colliding.get(pair)  # type: ignore[arg-type]
                    if value is None:
                        continue
                    mitigated = bool(cue_a) and bool(cue_b) and cue_a != cue_b
                    verdict = "MITIGATED" if mitigated else "FAIL"
                    print(
                        f"STATE {mode:<5} {component}: {a} vs {b} = "
                        f"{value:.2f} grey — {verdict} ({cue_a} / {cue_b})"
                    )
                    if not mitigated:
                        failures.append(
                            f"{mode}: {component} states '{a}'/'{b}' are greyscale-identical "
                            f"({value:.2f}) and differ by colour alone"
                        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--theme",
        action="append",
        choices=["dark", "light"],
        help="theme to audit (repeatable; default: both)",
    )
    parser.add_argument(
        "--grayscale",
        action="store_true",
        help="also print the R7 luminance table, pairwise greyscale contrasts and state maps",
    )
    args = parser.parse_args()

    palettes = load_palettes()
    for mode in ("dark", "light"):
        if mode not in palettes:
            sys.exit(f"check_contrast: FAIL — tokens.json has no '{mode}' palette")
    themes = args.theme or ["dark", "light"]

    failures: list[str] = []
    walked = 0
    for mode in themes:
        print(f"--- theme: {mode} ({len(palettes[mode])} tokens) ---")
        walked += audit_theme(mode, palettes[mode], failures)

    if args.grayscale:
        grayscale(palettes, failures)

    audit_banned(palettes, failures)

    print(
        f"\ncheck_contrast: {walked} pair(s) walked across {len(themes)} theme(s), "
        f"{len(failures)} unexempted failure(s)"
    )
    if failures:
        for failure in failures:
            print(f"check_contrast: FAIL — {failure}")
        return 1
    print("check_contrast: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
