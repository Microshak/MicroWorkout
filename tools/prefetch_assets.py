#!/usr/bin/env python3
"""Cache-warmer for the MicroWorkout illustration source.

Downloads the upstream metadata manifest plus every animation frame into a local
cache under `assets_src/workout-guide/` (gitignored), so that PRD-04's build
pipeline can run entirely offline and re-run cheaply.

This is deliberately NOT the pipeline itself — `tools/build_library.py` turns the
cache into res:// assets and metadata. This script only fills the cache, is
resumable, and never deletes anything.

Usage:
    python3 tools/prefetch_assets.py            # fill the cache
    python3 tools/prefetch_assets.py --check    # report cache status only
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = "bryllim/workout-guide"
BRANCH = "main"
PKG = "packages/workout-guide"
RAW = f"https://raw.githubusercontent.com/{REPO}/{BRANCH}/{PKG}"

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "assets_src" / "workout-guide"
MANIFEST = CACHE / "manifest.json"

WORKERS = 16
TIMEOUT = 30


def fetch(url: str, dest: Path) -> str:
    """Download url -> dest. Returns 'cached' | 'ok' | an error string."""
    if dest.exists() and dest.stat().st_size > 0:
        return "cached"
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "MicroWorkout-build"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            data = response.read()
        if not data:
            return f"EMPTY {url}"
        tmp.write_bytes(data)
        os.replace(tmp, dest)
        return "ok"
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        tmp.unlink(missing_ok=True)
        return f"FAIL {url}: {exc}"


def load_manifest() -> list[dict]:
    if not MANIFEST.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        status = fetch(f"{RAW}/manifest.json", MANIFEST)
        if status not in ("ok", "cached"):
            print(f"FATAL: cannot download manifest: {status}", file=sys.stderr)
            sys.exit(1)
    return json.loads(MANIFEST.read_text())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="report cache status without downloading")
    args = parser.parse_args()

    exercises = load_manifest()
    print(f"manifest: {len(exercises)} exercises")

    jobs: list[tuple[str, Path]] = []
    for exercise in exercises:
        slug = exercise["slug"]
        for frame in exercise["frames"]:
            rel = frame["path"]                      # assets/<slug>/frame-N.svg
            name = Path(rel).name
            jobs.append((f"{RAW}/{rel[:-4]}.png", CACHE / "assets" / slug / f"{Path(name).stem}.png"))

    total = len(jobs)
    have = sum(1 for _, dest in jobs if dest.exists() and dest.stat().st_size > 0)
    print(f"frames: {total} ({have} already cached, {total - have} to fetch)")

    if args.check:
        print("cache dir:", CACHE)
        return 0

    fetched = failed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = [pool.submit(fetch, url, dest) for url, dest in jobs]
        for index, future in enumerate(concurrent.futures.as_completed(futures), 1):
            result = future.result()
            if result == "ok":
                fetched += 1
            elif result != "cached":
                failed += 1
                print("  ", result, file=sys.stderr)
            if index % 100 == 0:
                print(f"  … {index}/{total}")

    have = sum(1 for _, dest in jobs if dest.exists() and dest.stat().st_size > 0)
    bytes_total = sum(dest.stat().st_size for _, dest in jobs if dest.exists())
    print(f"done: {fetched} downloaded, {have}/{total} present, "
          f"{bytes_total / 1048576:.1f} MiB in cache")
    if failed:
        print(f"WARNING: {failed} download(s) failed — re-run to retry", file=sys.stderr)
        return 1
    if have != total:
        print(f"WARNING: cache incomplete ({have}/{total})", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
