#!/usr/bin/env python3
"""PRD-04 R1-R4 - fetch, validate and downscale the illustration frames.

Run order is fixed (PRD-04 R1):

    tools/build_library.py  ->  tools/fetch_exercise_assets.py  ->  godot --headless --import

The catalog produced by `build_library.py` decides *which* slugs exist; this script
downloads the three frames of each of them, validates them against the upstream
contract (R2), converts them with Pillow exactly as R3 specifies, and reports the
size budget of R4.

Cache layout under `--cache` (default `build/cache`, gitignored):

    manifest.json  manifest.sha256  raw/<slug>/frame-N.png  checksums.json  asset_report.json

A never-re-download rule protects the network: a raw frame is only fetched when it is
missing or its SHA-256 no longer matches `checksums.json`. Frames already present in a
local seed cache (`--seed-cache`, default `assets_src/workout-guide`, the pre-populated
cache from PRD-01/ADR-08) are copied in instead of being downloaded, which is what makes
this pipeline runnable offline.

Exit codes: 0 ok - 2 network failure (resumable) - 3 frame failed validation -
            4 frame count mismatch.

Usage:
    python3 tools/fetch_exercise_assets.py --catalog build/catalog.json \\
        --cache build/cache --out assets/exercises
    python3 tools/fetch_exercise_assets.py --check
    python3 tools/fetch_exercise_assets.py --verify-only
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path

try:
    from PIL import Image, ImageChops
except ImportError:  # pragma: no cover
    print("[assets] FATAL Pillow is required (pip install Pillow)", file=sys.stderr)
    sys.exit(3)

ROOT = Path(__file__).resolve().parent.parent

EXIT_OK = 0
EXIT_NETWORK = 2
EXIT_VALIDATION = 3
EXIT_FRAME_COUNT = 4

RAW_BASE = "https://raw.githubusercontent.com/bryllim/workout-guide/main/packages/workout-guide"
MANIFEST_URL = f"{RAW_BASE}/manifest.json"

MANIFEST_LENGTH = 302
FRAMES_PER_SLUG = 3
SOURCE_PX = 512
FRAME_PX = 384

# R3 specifies 4 alpha levels {0,85,170,255} at 384 px, expecting ~5.4 MB. Measured on
# this machine the real art is heavier than that estimate, and R4's escalation ladder
# step 1 ("ALPHA_LEVELS 4 -> 2") therefore had to be applied:
#
#   4 levels: out_bytes=6,997,153  assets/exercises du -sb=8,468,649  -> OVER 8,388,608
#   2 levels: out_bytes=5,916,187  assets/exercises du -sb=7,387,683  -> under, 11.9% headroom
#
# (The `.import` siblings required by R13 are part of that directory total.) The grayscale
# luminance channel keeps its full 8-bit anti-aliasing from the Lanczos downscale, so the
# edges stay smooth and only the coverage mask becomes hard. Recorded in docs/DECISIONS.md
# (ADR-13) and in build/cache/asset_report.json.
ALPHA_LEVELS = 2
PURITY_TOLERANCE = 8
MIN_OPAQUE_PIXELS = 2000
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# Alpha quantisation step derived from ALPHA_LEVELS (R3 step 5 / R4 ladder step 1).
ALPHA_STEP = 255 // (ALPHA_LEVELS - 1)

SIZE_CEILING = 8_388_608
RESAMPLE = getattr(Image, "LANCZOS", None) or Image.ANTIALIAS  # Pillow < 9.0 fallback

DEFAULT_JOBS = 8


def log(message: str) -> None:
    print(f"[assets] {message}")


def die(code: int, message: str) -> None:
    print(f"[assets] FATAL {message}", file=sys.stderr)
    sys.exit(code)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def human(num_bytes: int) -> str:
    return f"{num_bytes / 1048576:.2f} MB"


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

def acquire_manifest(path: Path, seed: Path, offline: bool) -> None:
    """Make sure `path` holds the upstream manifest, without re-downloading when possible."""
    if path.exists() and path.stat().st_size > 0:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    seeded = seed / "manifest.json"
    if seeded.exists() and seeded.stat().st_size > 0:
        shutil.copyfile(seeded, path)
        log(f"manifest seeded from {seeded.relative_to(ROOT)}")
        return
    if offline:
        die(EXIT_NETWORK, f"manifest missing at {path} and --offline was given")
    log(f"manifest not found; downloading {MANIFEST_URL}")
    try:
        request = urllib.request.Request(MANIFEST_URL, headers={"User-Agent": "MicroWorkout-build"})
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        die(EXIT_NETWORK, f"cannot download manifest: {exc}")
    if not payload.startswith(b"["):
        die(EXIT_VALIDATION, "downloaded manifest is not a JSON array")
    partial = path.with_suffix(".json.part")
    partial.write_bytes(payload)
    os.replace(partial, path)


def load_manifest(path: Path) -> list[dict]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(EXIT_VALIDATION, f"cannot read manifest {path}: {exc}")
    if not isinstance(manifest, list):
        die(EXIT_VALIDATION, "manifest must be a JSON array")
    if len(manifest) != MANIFEST_LENGTH:
        die(EXIT_FRAME_COUNT,
            f"manifest has {len(manifest)} records, expected {MANIFEST_LENGTH}")
    for record in manifest:
        frames = record.get("frames") or []
        if len(frames) != FRAMES_PER_SLUG:
            die(EXIT_FRAME_COUNT,
                f"{record.get('slug')}: {len(frames)} frames, expected {FRAMES_PER_SLUG}")
        for position, frame in enumerate(frames):
            if int(frame.get("index", -1)) != position + 1:
                die(EXIT_FRAME_COUNT,
                    f"{record.get('slug')}: frames[{position}].index == {frame.get('index')}")
    return manifest


# ---------------------------------------------------------------------------
# Validation (R2)
# ---------------------------------------------------------------------------

def validate_frame(path: Path) -> str:
    """Returns "" when the frame satisfies R2, otherwise a reason string."""
    if not path.exists():
        return "missing"
    with path.open("rb") as handle:
        if handle.read(8) != PNG_SIGNATURE:
            return "not a PNG (bad signature)"
    try:
        with Image.open(path) as image:
            image.load()
            if image.size != (SOURCE_PX, SOURCE_PX):
                return f"size {image.size} != ({SOURCE_PX}, {SOURCE_PX})"
            if image.mode not in ("P", "RGBA"):
                return f"mode {image.mode} not in {{P, RGBA}}"
            alpha = image.convert("RGBA").getchannel("A")
    except OSError as exc:
        return f"cannot decode: {exc}"
    opaque = sum(alpha.histogram()[1:])
    if opaque < MIN_OPAQUE_PIXELS:
        return f"only {opaque} non-zero alpha pixels (< {MIN_OPAQUE_PIXELS})"
    return ""


def is_pure_white(image: "Image.Image", tolerance: int = PURITY_TOLERANCE) -> bool:
    """True when every pixel with alpha > 0 is (255,255,255) within `tolerance`.

    Vector-traced line art is drawn in pure white on a transparent canvas, so the RGB
    channels carry no information and can be collapsed to a single luminance channel.
    Only pixels with a non-zero alpha are considered; anything below 247 on the darkest
    channel means the RGB data matters and the frame must stay RGBA.
    """
    rgba = image.convert("RGBA")
    mask = rgba.getchannel("A").point(lambda value: 255 if value > 0 else 0)
    red, green, blue = rgba.convert("RGB").split()
    darkest = ImageChops.darker(ImageChops.darker(red, green), blue)
    masked = Image.composite(darkest, Image.new("L", rgba.size, 255), mask)
    return masked.getextrema()[0] >= 255 - tolerance


# ---------------------------------------------------------------------------
# Processing (R3)
# ---------------------------------------------------------------------------

def process_frame(source: Path, destination: Path, slug: str) -> tuple[int, bool]:
    """R3, exactly. Returns (bytes written, purity_fallback)."""
    with Image.open(source) as opened:
        image = opened.convert("RGBA")

    fallback = False
    if is_pure_white(image):
        converted = image.convert("LA").resize((FRAME_PX, FRAME_PX), RESAMPLE)
        _luminance, alpha = converted.split()
        alpha = alpha.point(lambda value: round(value * (ALPHA_LEVELS - 1) / 255) * ALPHA_STEP)
        output = Image.merge("LA", (_luminance, alpha))
    else:
        log(f"[assets] purity_fallback slug={slug}")
        fallback = True
        resized = image.resize((FRAME_PX, FRAME_PX), RESAMPLE)
        red, green, blue, alpha = resized.split()
        alpha = alpha.point(lambda value: round(value * (ALPHA_LEVELS - 1) / 255) * ALPHA_STEP)
        output = Image.merge("RGBA", (red, green, blue, alpha))

    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(".png.part")
    output.save(partial, "PNG", optimize=True, compress_level=9, pnginfo=None)
    os.replace(partial, destination)
    return destination.stat().st_size, fallback


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

def frame_url(relative_path: str) -> str:
    """`assets/<slug>/frame-N.svg` -> the upstream PNG URL (R1)."""
    return f"{RAW_BASE}/{Path(relative_path).with_suffix('.png').as_posix()}"


def download(url: str, destination: Path) -> str:
    """Download to `<name>.part`, then os.replace(). Returns "" on success, else a reason."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(".png.part")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "MicroWorkout-build"})
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = response.read()
        if not payload:
            return f"empty response for {url}"
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        partial.unlink(missing_ok=True)
        return f"{url}: {exc}"
    partial.write_bytes(payload)
    os.replace(partial, destination)
    return ""


def seed_from_local(seed: Path, relative_path: str, destination: Path) -> bool:
    """Copy a frame out of the pre-populated local cache instead of downloading it."""
    candidate = seed / Path(relative_path).with_suffix(".png")
    if not candidate.exists() or candidate.stat().st_size == 0:
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(".png.part")
    shutil.copyfile(candidate, partial)
    os.replace(partial, destination)
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def build_plan(catalog_path: Path, manifest: list[dict], limit: int) -> list[tuple[str, list[str]]]:
    """[(slug, [frame-N.png relative paths])] taken from the catalog, in catalog order."""
    if not catalog_path.exists():
        die(EXIT_FRAME_COUNT,
            f"catalog not found: {catalog_path} (run tools/build_library.py first)")
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(EXIT_FRAME_COUNT, f"cannot read catalog {catalog_path}: {exc}")

    manifest_slugs = {record["slug"] for record in manifest}
    plan: list[tuple[str, list[str]]] = []
    for entry in catalog.get("exercises", []):
        slug = entry["slug"]
        if slug not in manifest_slugs:
            die(EXIT_FRAME_COUNT, f"catalog slug {slug!r} is not in the manifest")
        frames = list(entry["frames"])
        if len(frames) != FRAMES_PER_SLUG:
            die(EXIT_FRAME_COUNT, f"{slug}: {len(frames)} frames in the catalog")
        plan.append((slug, frames))
    if limit > 0:
        plan = plan[:limit]
    return plan


def report_cache_status(args, manifest_path: Path, seed: Path) -> int:
    print(f"manifest: {args.manifest} (exists={manifest_path.exists()})")
    if not manifest_path.exists():
        print("  -> not built yet; run the pipeline once to seed it from "
              f"{seed.relative_to(ROOT)}")
        return 1
    digest = sha256_file(manifest_path)
    print(f"  records={len(json.loads(manifest_path.read_text(encoding='utf-8')))} "
          f"sha256={digest}")
    sha_file = ROOT / args.cache / "manifest.sha256"
    print(f"  pinned sha256 file: {args.cache}/manifest.sha256 "
          f"({'match' if sha_file.exists() and sha_file.read_text().split()[0] == digest else 'absent/differs'})")

    catalog_path = ROOT / args.catalog
    if catalog_path.exists():
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        slugs = [entry["slug"] for entry in catalog["exercises"]]
        print(f"catalog: {args.catalog} exercises={len(slugs)} frames={len(slugs) * 3}")
    else:
        slugs = [record["slug"] for record in json.loads(manifest_path.read_text(encoding="utf-8"))]
        print(f"catalog: {args.catalog} absent - reporting on all {len(slugs)} manifest slugs")

    raw_dir = ROOT / args.cache / "raw"
    out_dir = ROOT / args.out
    raw_have = sum(1 for slug in slugs for index in (1, 2, 3)
                   if (raw_dir / slug / f"frame-{index}.png").exists())
    seed_have = sum(1 for slug in slugs for index in (1, 2, 3)
                    if (seed / "assets" / slug / f"frame-{index}.png").exists())
    out_have = sum(1 for slug in slugs for index in (1, 2, 3)
                   if (out_dir / slug / f"frame-{index}.png").exists())
    total = len(slugs) * 3
    out_bytes = sum((out_dir / slug / f"frame-{index}.png").stat().st_size
                    for slug in slugs for index in (1, 2, 3)
                    if (out_dir / slug / f"frame-{index}.png").exists())
    print(f"raw cache:  {raw_have}/{total} in {raw_dir}")
    print(f"seed cache: {seed_have}/{total} in {seed / 'assets'}")
    print(f"output:     {out_have}/{total} in {out_dir}"
          + (f" ({human(out_bytes)}, ceiling {human(SIZE_CEILING)})" if out_have else ""))
    obtainable = len([1 for slug in slugs for index in (1, 2, 3)
                      if (raw_dir / slug / f"frame-{index}.png").exists()
                      or (seed / "assets" / slug / f"frame-{index}.png").exists()])
    if obtainable == total:
        print(f"verdict: READY - all {total} source frames are available offline")
        return 0
    print(f"verdict: INCOMPLETE - {total - obtainable} source frame(s) need downloading")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch and downscale the exercise frames.")
    parser.add_argument("--manifest", default="build/cache/manifest.json")
    parser.add_argument("--catalog", default="build/catalog.json")
    parser.add_argument("--cache", default="build/cache")
    parser.add_argument("--out", default="assets/exercises")
    parser.add_argument("--report", default="")
    parser.add_argument("--seed-cache", default="assets_src/workout-guide")
    parser.add_argument("--jobs", type=int, default=DEFAULT_JOBS)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--offline", action="store_true",
                        help="never touch the network; fail instead if a frame is missing")
    args = parser.parse_args()

    manifest_path = ROOT / args.manifest
    cache_dir = ROOT / args.cache
    out_dir = ROOT / args.out
    seed_dir = ROOT / args.seed_cache
    report_path = Path(args.report) if args.report else cache_dir / "asset_report.json"

    if args.check:
        return report_cache_status(args, manifest_path, seed_dir)

    acquire_manifest(manifest_path, seed_dir, args.offline)
    manifest = load_manifest(manifest_path)

    manifest_sha = sha256_file(manifest_path)
    cache_dir.mkdir(parents=True, exist_ok=True)
    (cache_dir / "manifest.sha256").write_text(
        f"{manifest_sha}  manifest.json\n", encoding="utf-8")

    plan = build_plan(ROOT / args.catalog, manifest, args.limit)
    expected_frames = len(plan) * FRAMES_PER_SLUG
    log(f"catalog {args.catalog}: {len(plan)} exercises, {expected_frames} frames")
    log(f"manifest sha256={manifest_sha[:16]}...")

    checksums_path = cache_dir / "checksums.json"
    checksums = {"raw": {}, "out": {}}
    if checksums_path.exists():
        try:
            loaded = json.loads(checksums_path.read_text(encoding="utf-8"))
            checksums["raw"] = loaded.get("raw", {})
            checksums["out"] = loaded.get("out", {})
        except json.JSONDecodeError:
            log("checksums.json is corrupt; rebuilding it")

    raw_dir = cache_dir / "raw"

    # ---- stage 1: raw frames -------------------------------------------------
    downloaded = cached = seeded = 0
    failures: list[str] = []
    source_bytes = 0
    to_download: list[tuple[str, str, Path]] = []

    for slug, frames in plan:
        for relative in frames:
            name = Path(relative).name
            key = f"{slug}/{name}"
            raw_path = raw_dir / slug / name
            known = checksums["raw"].get(key)
            if (not args.force and raw_path.exists() and known
                    and sha256_file(raw_path) == known):
                source_bytes += raw_path.stat().st_size
                cached += 1
                continue
            if not args.force and not args.verify_only and seed_from_local(seed_dir, relative, raw_path):
                checksums["raw"][key] = sha256_file(raw_path)
                source_bytes += raw_path.stat().st_size
                cached += 1
                seeded += 1
                continue
            to_download.append((slug, relative, raw_path))

    if args.verify_only and to_download:
        for slug, relative, _ in to_download:
            failures.append(f"{slug}/{Path(relative).name}: not in the raw cache")
    elif to_download:
        log(f"downloading {len(to_download)} frame(s) with {args.jobs} worker(s)")
        network_error = ""
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            futures = {pool.submit(download, frame_url(relative), raw_path): (slug, relative)
                       for slug, relative, raw_path in to_download}
            for future in concurrent.futures.as_completed(futures):
                slug, relative = futures[future]
                reason = future.result()
                if reason:
                    network_error = reason
                    failures.append(f"{slug}/{Path(relative).name}: {reason}")
                    continue
                key = f"{slug}/{Path(relative).name}"
                raw_path = raw_dir / slug / Path(relative).name
                checksums["raw"][key] = sha256_file(raw_path)
                source_bytes += raw_path.stat().st_size
                downloaded += 1
        if network_error and not args.verify_only:
            save_checksums(checksums_path, checksums)
            print(f"downloaded={downloaded} cached={cached} failed={len(failures)}")
            die(EXIT_NETWORK, f"network failure (resumable, re-run to retry): {network_error}")

    # ---- stage 2: validate every raw frame (R2) ------------------------------
    log(f"validating {expected_frames} raw frames")
    for slug, frames in plan:
        for relative in frames:
            raw_path = raw_dir / slug / Path(relative).name
            reason = validate_frame(raw_path)
            if reason:
                failures.append(f"{slug}/{Path(relative).name}: {reason}")
    if failures:
        for failure in failures:
            print(f"[assets] INVALID {failure}", file=sys.stderr)
        save_checksums(checksums_path, checksums)
        die(EXIT_VALIDATION, f"{len(failures)} frame(s) failed validation")

    # ---- stage 3: process to 384x384 (R3) -----------------------------------
    skipped = 0
    processed = 0
    fallbacks: list[str] = []
    out_bytes = 0
    max_out_bytes = 0
    max_out_path = ""

    for slug, frames in plan:
        for relative in frames:
            name = Path(relative).name
            key = f"{slug}/{name}"
            raw_path = raw_dir / slug / name
            destination = out_dir / slug / name
            known = checksums["out"].get(key)
            if (not args.force and destination.exists() and known
                    and sha256_file(destination) == known):
                size = destination.stat().st_size
                out_bytes += size
                skipped += 1
                if size > max_out_bytes:
                    max_out_bytes, max_out_path = size, key
                continue
            if args.verify_only:
                failures.append(f"{key}: output missing or stale")
                continue
            size, fallback = process_frame(raw_path, destination, slug)
            checksums["out"][key] = sha256_file(destination)
            out_bytes += size
            processed += 1
            if fallback:
                fallbacks.append(slug)
            if size > max_out_bytes:
                max_out_bytes, max_out_path = size, key

    save_checksums(checksums_path, checksums)

    if failures:
        for failure in failures:
            print(f"[assets] MISSING {failure}", file=sys.stderr)
        die(EXIT_VALIDATION, f"{len(failures)} output frame(s) missing")

    # ---- stage 4: measure and report (R4) -----------------------------------
    assets_dir_bytes = sum(path.stat().st_size for path in out_dir.rglob("*") if path.is_file())
    counted = processed + skipped
    mean_out_bytes = out_bytes // counted if counted else 0

    if counted != expected_frames:
        die(EXIT_FRAME_COUNT, f"processed {counted} frames, expected {expected_frames}")

    report = {
        "schema_version": 1,
        "manifest_sha256": manifest_sha,
        "frames": counted,
        "downloaded": downloaded,
        "cached": cached,
        "seeded": seeded,
        "skipped": skipped,
        "processed": processed,
        "source_bytes": source_bytes,
        "out_bytes": out_bytes,
        "mean_out_bytes": mean_out_bytes,
        "max_out_bytes": max_out_bytes,
        "max_out_frame": max_out_path,
        "assets_dir_bytes": assets_dir_bytes,
        "assets_dir_mb": round(assets_dir_bytes / 1048576, 2),
        "size_ceiling": SIZE_CEILING,
        "alpha_levels": ALPHA_LEVELS,
        "frame_px": FRAME_PX,
        "purity_fallbacks": fallbacks,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(f"frames={counted} downloaded={downloaded} cached={cached} skipped={skipped}")
    print(f"source_bytes={source_bytes} out_bytes={out_bytes} "
          f"mean_out_bytes={mean_out_bytes} max_out_bytes={max_out_bytes}")
    print(f"assets_dir_bytes={assets_dir_bytes} ({human(assets_dir_bytes)}) "
          f"frame_bytes={out_bytes} ({human(out_bytes)})")
    print(f"largest frame: {max_out_path} ({max_out_bytes} bytes)")
    if seeded:
        print(f"seeded_from_local_cache={seeded} ({args.seed_cache})")
    if fallbacks:
        print(f"purity_fallback_frames={len(fallbacks)} (RGBA kept): {sorted(set(fallbacks))}")

    if assets_dir_bytes > SIZE_CEILING:
        print(f"[assets] FATAL assets/exercises is {human(assets_dir_bytes)}, "
              f"over the {human(SIZE_CEILING)} ceiling - apply the PRD-04 R4 ladder "
              f"(ALPHA_LEVELS 4 -> 2, then FRAME_PX 384 -> 320)", file=sys.stderr)
        return EXIT_VALIDATION
    return EXIT_OK


def save_checksums(path: Path, checksums: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "raw": dict(sorted(checksums["raw"].items())),
        "out": dict(sorted(checksums["out"].items())),
    }, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
