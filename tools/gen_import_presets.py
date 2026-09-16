#!/usr/bin/env python3
"""PRD-04 R13 - pin the Godot texture import parameters for every exercise frame.

Godot writes a `.import` sibling the first time it sees a PNG. Those auto-generated
files are correct except for `detect_3d/compress_to`, which defaults to `2`; a texture
that a 3D renderer ever touches would then be silently swapped for a VRAM-compressed
copy, which breaks the alpha channel this art depends on. This script rewrites the
`[params]` block of every `.import` under `--root` with the exact PRD-04 R13 list and
leaves Godot's own `[remap]`/`[deps]` bookkeeping untouched.

Run it, then let Godot re-import:

    python3 tools/gen_import_presets.py --root assets/exercises
    ~/Applications/godot --headless --path . --import
    python3 tools/gen_import_presets.py --root assets/exercises --verify

Exit codes: 0 ok - 3 a PNG has no sibling .import - 4 verification failed.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

EXIT_OK = 0
EXIT_MISSING = 3
EXIT_VERIFY = 4

# PRD-04 R13, verbatim and in order.
IMPORT_PARAMS: tuple[str, ...] = (
    "compress/mode=0",
    "compress/high_quality=false",
    "compress/lossy_quality=0.7",
    "compress/normal_map=0",
    "compress/channel_pack=0",
    "mipmaps/generate=false",
    "mipmaps/limit=-1",
    "process/fix_alpha_border=true",
    "process/premult_alpha=false",
    "process/normal_map_invert_y=false",
    "process/hdr_as_srgb=false",
    "process/hdr_clamp_exposure=false",
    "process/size_limit=0",
    "detect_3d/compress_to=0",
)

EXPECTED_IMPORTS = 612
REQUIRED_LINES = ("detect_3d/compress_to=0", "mipmaps/generate=false", "compress/mode=0")


def log(message: str) -> None:
    print(f"[import] {message}")


def split_sections(text: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current = ""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            current = stripped
            sections[current] = []
        elif current:
            sections[current].append(line)
    return sections


def rewrite(path: Path) -> bool:
    """Rewrite the [params] block; returns True when the file changed."""
    original = path.read_text(encoding="utf-8")
    sections = split_sections(original)
    if not sections:
        return False

    out: list[str] = []
    for header, body in sections.items():
        cleaned = list(body)
        while cleaned and not cleaned[0].strip():
            cleaned.pop(0)
        while cleaned and not cleaned[-1].strip():
            cleaned.pop()
        out.append(header)
        out.append("")
        if header == "[params]":
            out.extend(list(IMPORT_PARAMS))
        else:
            out.extend(cleaned)
        out.append("")

    updated = "\n".join(out).rstrip("\n") + "\n"
    if updated == original:
        return False
    path.write_text(updated, encoding="utf-8")
    return True


def stub(source: Path) -> str:
    """A minimal .import for a PNG Godot has never seen; `--import` completes it."""
    relative = source.relative_to(ROOT).as_posix() if source.is_relative_to(ROOT) else source.name
    lines = [
        "[remap]", "",
        'importer="texture"',
        'type="CompressedTexture2D"',
        'uid=""',
        "",
        "[deps]", "",
        f'source_file="res://{relative}"',
        "",
        "[params]", "",
    ]
    lines.extend(IMPORT_PARAMS)
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Pin the R13 texture import presets.")
    parser.add_argument("--root", default="assets/exercises")
    parser.add_argument("--verify", action="store_true",
                        help="only check the existing .import files")
    args = parser.parse_args()

    root = ROOT / args.root
    if not root.is_dir():
        print(f"[import] FATAL {args.root} is not a directory", file=sys.stderr)
        return EXIT_MISSING

    pngs = sorted(path for path in root.rglob("*.png") if path.is_file())
    if not pngs:
        print(f"[import] FATAL no PNGs under {args.root}", file=sys.stderr)
        return EXIT_MISSING

    if args.verify:
        return verify(pngs)

    missing: list[Path] = []
    changed = 0
    for source in pngs:
        target = source.with_suffix(source.suffix + ".import")
        if not target.exists():
            target.write_text(stub(source), encoding="utf-8")
            missing.append(source)
            changed += 1
            continue
        if rewrite(target):
            changed += 1

    log(f"scanned {len(pngs)} PNGs, rewrote {changed} .import file(s)")
    if missing:
        log(f"{len(missing)} PNG(s) had no .import yet; a stub was written - "
            f"now run: ~/Applications/godot --headless --path . --import")
    return verify(pngs)


def verify(pngs: list[Path]) -> int:
    problems: list[str] = []
    imports = sorted(path for path in (ROOT / "assets" / "exercises").rglob("*.import"))
    for source in pngs:
        target = source.with_suffix(source.suffix + ".import")
        name = source.relative_to(ROOT).as_posix()
        if not target.exists():
            problems.append(f"{name}: no sibling .import")
            continue
        text = target.read_text(encoding="utf-8")
        for required in REQUIRED_LINES:
            if required not in text:
                problems.append(f"{name}: .import is missing {required}")

    print(f"imports={len(imports)} pngs={len(pngs)} expected={EXPECTED_IMPORTS}")
    if len(imports) != EXPECTED_IMPORTS:
        problems.append(f".import count {len(imports)} != {EXPECTED_IMPORTS}")
    if len(pngs) != EXPECTED_IMPORTS:
        problems.append(f"PNG count {len(pngs)} != {EXPECTED_IMPORTS}")

    if problems:
        for problem in problems[:20]:
            print(f"[import] FAIL {problem}", file=sys.stderr)
        if len(problems) > 20:
            print(f"[import] ... and {len(problems) - 20} more", file=sys.stderr)
        return EXIT_VERIFY
    print("verify: OK - every frame has an .import with the R13 parameters")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
