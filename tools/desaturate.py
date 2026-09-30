#!/usr/bin/env python3
"""PRD-12 R7 — screenshot to grayscale, for the colourblind-safe audit.

    python3 tools/desaturate.py build/screenshots/tracker-full.png \
        -o build/screenshots/12-grayscale-tracker.png

Uses Pillow (PRD-00 §3 allows it for tools) and ITU-R BT.601 luma weights, the same
sensation-preserving conversion Android's "Simulate colour space: Monochromacy" uses. The point
of the exercise is not the file: it is that done / missed / rest must still be distinguishable,
which works only because every status carries a shape cue as well as a colour (PRD-12 R7 ①).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover - environment guard with a clear message
    sys.exit("desaturate: FAIL — Pillow is required (python3 -m pip install Pillow)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", help="screenshot to convert")
    parser.add_argument("-o", "--out", required=True, help="grayscale PNG to write")
    args = parser.parse_args()

    source = Path(args.source)
    if not source.exists():
        sys.exit(f"desaturate: FAIL — {source} does not exist")
    with Image.open(source) as image:
        # `convert("L")` is the BT.601 luma conversion; the round trip through RGB keeps the
        # file viewable by every tool in the audit chain with no alpha surprises.
        grayscale = image.convert("L").convert("RGB")
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        grayscale.save(out, format="PNG")

    print(f"desaturate: wrote {out} ({out.stat().st_size} bytes) from {source.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
