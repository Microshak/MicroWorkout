#!/usr/bin/env python3
"""Programmatic screenshot verification for MicroWorkout.

Why this exists (ADR-06): the acceptance gate requires *looking at* what actually
rendered on the emulator, but the agent's model has no image input. Rather than
weaken the gate, rendering is asserted numerically — device geometry, background
token colour, content presence, and per-region colour probes — plus an ASCII
luminance preview that makes layout mistakes (empty screen, unstyled default
theme, content off-centre, missing nav bar) visible in plain text.

Usage:
    tools/verify_screenshot.py build/screenshots/foo.png
    tools/verify_screenshot.py build/screenshots/foo.png --expect-bg 0F1116 \
        --profile boot --ascii

Exit code 0 = all assertions passed, 1 = at least one failed.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    print("FATAL: Pillow is required (pip install pillow)", file=sys.stderr)
    sys.exit(2)

# Design tokens (master plan §9) used as colour probes.
TOKEN_BG_DARK = (0x0F, 0x11, 0x16)
TOKEN_TEXT_DARK = (0xF4, 0xF6, 0xFA)
TOKEN_PRIMARY = (0xFF, 0x6B, 0x35)

RAMP = " .:-=+*#%@"


def hex_to_rgb(value: str) -> tuple[int, int, int]:
    value = value.strip().lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def luminance(pixel: tuple[int, int, int]) -> float:
    r, g, b = pixel[:3]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def close(a: tuple[int, int, int], b: tuple[int, int, int], tol: int = 12) -> bool:
    return all(abs(int(x) - int(y)) <= tol for x, y in zip(a, b))


def ascii_preview(image: Image.Image, cols: int = 64) -> str:
    """Downscale to a luminance map so layout is legible as text."""
    aspect = image.height / image.width
    rows = max(1, int(cols * aspect * 0.5))
    small = image.convert("L").resize((cols, rows), Image.BOX)
    pixels = small.load()
    lines = []
    for y in range(rows):
        line = "".join(RAMP[min(len(RAMP) - 1, pixels[x, y] * len(RAMP) // 256)] for x in range(cols))
        lines.append(line)
    return "\n".join(lines)


def colour_histogram(image: Image.Image, top: int = 8) -> list[tuple[tuple[int, int, int], int]]:
    rgb = image.convert("RGB")
    counts: dict[tuple[int, int, int], int] = {}
    for pixel in rgb.getdata():
        counts[pixel] = counts.get(pixel, 0) + 1
    return sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:top]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("png")
    parser.add_argument("--expect-bg", default=None, help="required background hex, e.g. 0F1116")
    parser.add_argument("--expect-width", type=int, default=None)
    parser.add_argument("--expect-height", type=int, default=None)
    parser.add_argument("--min-distinct-colours", type=int, default=24)
    parser.add_argument("--min-bright-fraction", type=float, default=0.0005,
                        help="fraction of pixels that must be bright (i.e. text is present)")
    parser.add_argument("--inset-top", type=int, default=200,
                        help="pixels to skip at the top (Android status bar)")
    parser.add_argument("--inset-bottom", type=int, default=150,
                        help="pixels to skip at the bottom (Android navigation bar)")
    parser.add_argument("--inset-x", type=int, default=6, help="pixels to skip at the sides")
    parser.add_argument("--min-bg-coverage", type=float, default=0.10,
                        help="fraction of the sampled app region that must be the background token")
    parser.add_argument("--ascii", action="store_true", help="print a text-mode layout preview")
    # PRD-10 additions: the player's acceptance run has to prove *what* rendered, not just that
    # something did. These three assert colour and brightness inside a named region of the screen.
    parser.add_argument("--region", action="append", default=[],
                        metavar="NAME=FX0,FY0,FX1,FY1",
                        help="a relative screen box to probe, e.g. illustration=0.1,0.2,0.9,0.6 "
                             "(fractions of width/height; repeatable)")
    parser.add_argument("--region-min-bright", action="append", default=[],
                        metavar="NAME=FRACTION",
                        help="fraction of the region's pixels that must be bright, e.g. "
                             "illustration=0.01 (repeatable)")
    parser.add_argument("--region-min-colour", action="append", default=[],
                        metavar="NAME=HEX:COUNT",
                        help="the region must contain at least COUNT pixels of HEX within "
                             "tolerance 14, e.g. progress=35D08A:200 (repeatable)")
    args = parser.parse_args()

    path = Path(args.png)
    failures: list[str] = []

    def check(condition: bool, ok: str, bad: str) -> None:
        if condition:
            print(f"  ✔ {ok}")
        else:
            print(f"  ✘ {bad}")
            failures.append(bad)

    if not path.exists() or path.stat().st_size == 0:
        print(f"FATAL: {path} missing or empty", file=sys.stderr)
        return 1

    image = Image.open(path).convert("RGB")
    width, height = image.size
    print(f"── {path.name}  {width}x{height}  {path.stat().st_size / 1024:.1f} KiB")

    # 1. geometry
    if args.expect_width:
        check(width == args.expect_width, f"width {width}",
              f"width {width} != expected {args.expect_width}")
    if args.expect_height:
        check(abs(height - args.expect_height) <= 8, f"height {height}",
              f"height {height} != expected {args.expect_height} (±8)")

    # 2. not blank
    histogram = colour_histogram(image)
    distinct = len(set(image.getdata()))
    check(distinct >= args.min_distinct_colours,
          f"{distinct} distinct colours (content is present)",
          f"only {distinct} distinct colours — screen may be blank/unstyled")

    # 3. text / foreground presence
    pixels = list(image.getdata())
    bright = sum(1 for p in pixels if luminance(p) > 140)
    fraction = bright / len(pixels)
    check(fraction >= args.min_bright_fraction,
          f"{bright} bright pixels ({fraction:.4%}) — text/foreground present",
          f"only {bright} bright pixels ({fraction:.4%}) — expected visible text")

    # 4. dominant colour matches the app background token
    if args.expect_bg:
        bg = hex_to_rgb(args.expect_bg)
        dominant, count = histogram[0]
        share = count / len(pixels)
        check(close(dominant, bg, tol=6),
              f"dominant colour #{dominant[0]:02X}{dominant[1]:02X}{dominant[2]:02X} "
              f"({share:.1%}) matches background #{args.expect_bg.upper()}",
              f"dominant colour #{dominant[0]:02X}{dominant[1]:02X}{dominant[2]:02X} ({share:.1%}) "
              f"does not match expected background #{args.expect_bg.upper()}")
        # A raw screen corner is the Android status bar, not our app, so sample a grid
        # *inside* the app window (insets exclude the status and navigation bars).
        xs = list(range(args.inset_x, width - args.inset_x, max(1, (width - 2 * args.inset_x) // 24)))
        ys = list(range(args.inset_top, height - args.inset_bottom,
                        max(1, (height - args.inset_top - args.inset_bottom) // 30)))
        samples = [image.getpixel((x, y)) for y in ys for x in xs]
        matching = sum(1 for p in samples if close(p, bg, tol=10))
        ratio = matching / len(samples) if samples else 0.0
        check(ratio >= args.min_bg_coverage,
              f"app region is {ratio:.1%} background #{args.expect_bg.upper()} "
              f"({len(samples)} samples inside the app window)",
              f"app region is only {ratio:.1%} background #{args.expect_bg.upper()} "
              f"(need >= {args.min_bg_coverage:.0%}) — UI may be unstyled or failing to draw")
        corner = image.getpixel((2, 2))
        print("  ·  info: raw corner #%02X%02X%02X is the system status bar, not the app"
              % corner)

    print("  ── top colours ──")
    for colour, count in histogram[:5]:
        print(f"     #{colour[0]:02X}{colour[1]:02X}{colour[2]:02X}  {count / len(pixels):6.2%}")

    # 5. region probes (PRD-10 AC14): the numbers that stand in for looking at the picture.
    if args.region:
        regions: dict[str, tuple[int, int, int, int]] = {}
        for spec in args.region:
            name, _, box = spec.partition("=")
            parts = [float(v) for v in box.split(",")]
            if len(parts) != 4:
                print(f"FATAL: --region {spec} needs four fractions", file=sys.stderr)
                return 2
            regions[name] = (
                int(parts[0] * width), int(parts[1] * height),
                int(parts[2] * width), int(parts[3] * height),
            )

        def crop(name: str):
            box = regions.get(name)
            if box is None:
                return None
            return image.crop(box)

        for spec in args.region_min_bright:
            name, _, value = spec.partition("=")
            patch = crop(name)
            if patch is None:
                print(f"FATAL: --region-min-bright {spec} names no --region", file=sys.stderr)
                return 2
            wanted = float(value)
            total = patch.width * patch.height
            lit = sum(1 for p in patch.getdata() if luminance(p) > 140)
            ratio = lit / total if total else 0.0
            check(ratio >= wanted,
                  f"region {name}: {lit} bright pixels ({ratio:.3%}) — content is drawn",
                  f"region {name}: only {lit} bright pixels ({ratio:.3%}) — nothing drew there")

        for spec in args.region_min_colour:
            name, _, value = spec.partition("=")
            patch = crop(name)
            if patch is None:
                print(f"FATAL: --region-min-colour {spec} names no --region", file=sys.stderr)
                return 2
            hex_value, _, count_text = value.partition(":")
            wanted_rgb = hex_to_rgb(hex_value)
            wanted_count = int(count_text)
            total = patch.width * patch.height
            hits = sum(1 for p in patch.getdata() if close(p, wanted_rgb, tol=14))
            check(hits >= wanted_count,
                  f"region {name}: {hits} px of #{hex_value.upper()} (need {wanted_count})",
                  f"region {name}: only {hits} px of #{hex_value.upper()} (need {wanted_count} "
                  f"of {total})")

    if args.ascii:
        print("  ── layout preview (dark = space, bright = @) ──")
        for line in ascii_preview(image).splitlines():
            print("     " + line)

    print("──────────────────────────────────────────────────────────────")
    if failures:
        print(f"  SCREENSHOT RESULT: FAIL ({len(failures)} check(s))")
        return 1
    print("  SCREENSHOT RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
