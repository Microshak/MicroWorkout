#!/usr/bin/env python3
"""Find nodes attached under an *instanced scene's internals* in hand-authored .tscn files.

Godot's text scene format allows `parent="<instance path>/<internal node>"` — the editor writes
it whenever "Editable Children" is used. On desktop it loads fine, but the .tscn -> .scn
conversion used by the Android export **drops those nodes** (measured 2026-09-30: the packed
weekly_ring.scn has no Ring, and the packed tracker_tab.scn had no calendar/list children).
This script lists every occurrence so the pattern can be replaced with a self-owned container.

    python3 tools/find_instance_children.py [scenes/…]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

NODE_RE = re.compile(r'^\[node name="([^"]+)"(?: type="([^"]+)")?(?: parent="([^"]+)")?(?:[^\]]*)?\]')


def scan(path: Path) -> list[str]:
    instances: dict[str, str] = {}   # full node path -> scene resource
    nodes: list[tuple[str, str, str]] = []  # (name, parent, line)
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = NODE_RE.match(line)
        if not match:
            continue
        name, _type, parent = match.group(1), match.group(2), match.group(3) or ""
        if parent == ".":
            parent = ""
        full = f"{parent}/{name}" if parent else name
        if "instance=" in line:
            instances[full] = line.split("instance=", 1)[1].split()[0]
        nodes.append((name, parent, f"{lineno}:{full}"))

    findings: list[str] = []
    for name, parent, where in nodes:
        for inst_path in instances:
            if parent == inst_path or parent.startswith(inst_path + "/"):
                findings.append(
                    f"  {where}  (parent '{parent}' is inside instance '{inst_path}' "
                    f"= {instances[inst_path]})"
                )
                break
    return findings


def main() -> int:
    roots = [Path(arg) for arg in sys.argv[1:]] or [Path("scenes")]
    total = 0
    for root in roots:
        files = sorted(root.rglob("*.tscn")) if root.is_dir() else [root]
        for path in files:
            findings = scan(path)
            if findings:
                total += len(findings)
                print(f"{path}:")
                print("\n".join(findings))
    print(f"total instance-internal children: {total}")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
