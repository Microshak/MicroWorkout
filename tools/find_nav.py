#!/usr/bin/env python3
"""Locate the bottom navigation bar in a screenshot and report which tab is active.

Why this exists: the tab strip's screen position depends on the Android status bar,
the safe-area insets and the device's own navigation bar, so a hard-coded tap
coordinate drifts and silently taps empty padding — which looks exactly like a passing
test that captured the same screen four times. This script measures the nav bar from
the rendered pixels instead, and by reporting the active tab it also lets the caller
*verify* that a tap actually changed tabs.

The active tab's icon is tinted with the `primary` token while the others use
`text_muted`, so clustering primary-coloured pixels in the lower part of the frame
locates both the bar's vertical centre and the active tab's horizontal centre.

Usage:
    tools/find_nav.py build/screenshots/x.png
    # -> "nav_y=2223 active_x=135 active_index=0 tab_pitch=270 tabs=4"

    tools/find_nav.py build/screenshots/x.png --expect-index 2   # exit 1 if not tab 2
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    print("FATAL: Pillow required", file=sys.stderr)
    sys.exit(2)

TAB_COUNT = 4
DEFAULT_ACCENT = "FF6B35"      # DesignTokens primary
DEFAULT_MUTED = "9AA5B6"       # DesignTokens text_muted
TOLERANCE = 26


def rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def close(a, b, tol=TOLERANCE) -> bool:
    return all(abs(int(a[i]) - int(b[i])) <= tol for i in range(3))


def cluster_xs(xs: list[int], gap: int = 40) -> list[tuple[int, int]]:
    """Group sorted x positions into contiguous clusters; returns (start, end) pairs."""
    if not xs:
        return []
    xs = sorted(xs)
    out = [(xs[0], xs[0])]
    for x in xs[1:]:
        if x - out[-1][1] > gap:
            out.append((x, x))
        else:
            out[-1] = (out[-1][0], x)
    return out


def nav_band(image: Image.Image, bg: tuple[int, int, int],
             min_height: int = 106, max_height: int = 160) -> tuple[int, int] | None:
    """The navigation bar's (top, bottom) rows, measured from pixels.

    A row belongs to the bar when most of its sampled pixels are *not* the background token: the
    bar is a surface fill spanning the full width, the Android system bar below it is only ~63 px
    tall (so the height window rejects it) and the content above it is not a 132 px band.
    """
    width, height = image.size
    xs = list(range(6, width - 6, 12))
    rows: list[int] = []
    for y in range(int(height * 0.75), height):
        # Tolerance 6, not 14: the bar's `surface` token (#171A21) is only 8–11 per channel away
        # from the `bg` token (#0F1116), so a 14-wide tolerance calls the bar "background".
        filled = sum(1 for x in xs if not close(image.getpixel((x, y)), bg, tol=6))
        if filled >= len(xs) * 0.6:
            rows.append(y)

    bands: list[tuple[int, int]] = []
    start = prev = None
    for y in rows:
        if start is None:
            start = prev = y
            continue
        if y == prev + 1:
            prev = y
            continue
        bands.append((start, prev))
        start = prev = y
    if start is not None:
        bands.append((start, prev))

    candidates = [b for b in bands if min_height <= b[1] - b[0] + 1 <= max_height]
    if not candidates:
        return None
    # Highest of the candidates: the system navigation bar sits below the app's own bar.
    return min(candidates, key=lambda b: b[0])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("png")
    ap.add_argument("--accent", default=DEFAULT_ACCENT)
    ap.add_argument("--muted", default=DEFAULT_MUTED)
    ap.add_argument("--expect-index", type=int, default=None,
                    help="exit non-zero unless this tab index is the active one")
    # PRD-10 addition. The accent-cluster heuristic below locates the *active tab* by looking for
    # primary-tinted pixels — which Home breaks, because a full-width primary `Start workout`
    # button is also a big cluster of primary pixels and sits in the bottom third. That produced a
    # calibration offset 254 px off and made every tap in the player flow land on the wrong rows.
    # `--nav-band` measures the bar itself instead: a full-width band of non-background pixels
    # whose height is the nav bar's (132 ± 26), below the content and above the system bar.
    ap.add_argument("--nav-band", action="store_true",
                    help="measure the navigation bar as a band instead of clustering the accent")
    ap.add_argument("--from-viewport-y", type=int, default=None,
                    help="with --nav-band, also print offset_y = measured_nav_top - this value")
    ap.add_argument("--bg", default="0F1116", help="app background token, for --nav-band")
    args = ap.parse_args()

    path = Path(args.png)
    if not path.exists():
        print(f"FATAL: {path} not found", file=sys.stderr)
        return 1

    image = Image.open(path).convert("RGB")
    width, height = image.size
    accent = rgb(args.accent)
    muted = rgb(args.muted)

    if args.nav_band:
        band = nav_band(image, rgb(args.bg))
        if band is None:
            print("FATAL: no navigation-bar band found in the bottom quarter", file=sys.stderr)
            return 1
        line = f"nav_top={band[0]} nav_bottom={band[1]} nav_height={band[1] - band[0] + 1}"
        if args.from_viewport_y is not None:
            line += f" offset_y={band[0] - args.from_viewport_y}"
        print(line)
        return 0

    # Search only the bottom third: that is the only place the tab strip can be.
    top = int(height * 0.66)
    accent_pts: list[tuple[int, int]] = []
    muted_pts: list[tuple[int, int]] = []
    for y in range(top, height, 2):
        for x in range(0, width, 2):
            pixel = image.getpixel((x, y))
            if close(pixel, accent):
                accent_pts.append((x, y))
            elif close(pixel, muted):
                muted_pts.append((x, y))

    if not accent_pts:
        print("FATAL: no primary-tinted pixels found in the bottom third — "
              "is the bottom nav rendered?", file=sys.stderr)
        return 1

    clusters = cluster_xs([x for x, _ in accent_pts], gap=int(width / (TAB_COUNT * 2)))
    # The icon and the caption are separate vertical clusters at the same x; merge by x.
    best = max(clusters, key=lambda c: c[1] - c[0])
    active_x = (best[0] + best[1]) // 2

    ys = [y for x, y in accent_pts if best[0] - 8 <= x <= best[1] + 8]
    nav_y = sum(ys) // len(ys)

    pitch = width // TAB_COUNT
    active_index = int(round((active_x - pitch // 2) / pitch))
    active_index = max(0, min(TAB_COUNT - 1, active_index))

    print(f"nav_y={nav_y} active_x={active_x} active_index={active_index} "
          f"tab_pitch={pitch} tabs={TAB_COUNT} "
          f"accent_px={len(accent_pts)} muted_px={len(muted_pts)}")

    if args.expect_index is not None and active_index != args.expect_index:
        print(f"MISMATCH: expected tab {args.expect_index} to be active, "
              f"but tab {active_index} is tinted", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
