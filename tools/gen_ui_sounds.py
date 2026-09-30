#!/usr/bin/env python3
"""PRD-12 R2 — regenerate the five UI cue sounds, byte-identically.

    python3 tools/gen_ui_sounds.py [--out assets/audio/ui] [--check]

Every cue is mono 22050 Hz 16-bit PCM (PRD-00 §3), ≤ 12 KB (six seconds of 16-bit
mono would be 264 KB — a cue is 30–260 ms), synthesised from fixed sine tables with a 5 ms
fade in and fade out so nothing clicks, and written with the stdlib `wave` module only.
No randomness and no floating-point accumulation across runs means two invocations produce
byte-identical files, which `tests/suites/test_feedback.gd` and the PRD-12 AC9 evidence
(before/after `sha256sum`) both rely on.

    --check   write nothing; exit 1 if a file on disk differs from what would be written
"""

from __future__ import annotations

import argparse
import math
import sys
import wave
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

SAMPLE_RATE = 22050
FADE_SEC = 0.005  # 5 ms attack and decay on every note
MAX_BYTES = 12 * 1024


def note_samples(freq: float, duration: float, loudness: float = 0.6) -> list[int]:
    """One sine note with the 5 ms fades, as 16-bit samples."""
    total = max(int(round(duration * SAMPLE_RATE)), 1)
    fade = max(int(round(FADE_SEC * SAMPLE_RATE)), 1)
    fade = min(fade, total // 2) if total > 2 else 1
    out: list[int] = []
    for i in range(total):
        value = math.sin(2.0 * math.pi * freq * i / SAMPLE_RATE)
        envelope = 1.0
        if i < fade:
            envelope = i / fade
        elif i >= total - fade:
            envelope = (total - i) / fade
        out.append(int(round(value * envelope * loudness * 32767.0)))
    return out


def silence(duration: float) -> list[int]:
    return [0] * max(int(round(duration * SAMPLE_RATE)), 0)


#: name -> the notes that make the cue. Deliberately short: a UI sound is an acknowledgement,
#: not a jingle (the risk table's fallback is even shorter).
CUES: dict[str, list[tuple[float, float]]] = {
    # a short mid click, the sound of a button
    "ui_tap": [(880.0, 0.030)],
    # two quick rising notes: "this option is now selected"
    "ui_select": [(660.0, 0.030), (990.0, 0.030)],
    # a rising major triad: an achievement without a fanfare
    "ui_success": [(523.25, 0.050), (659.25, 0.050), (783.99, 0.050)],
    # two falling low notes: something did not work
    "ui_error": [(330.0, 0.075), (220.0, 0.075)],
    # a rising four-note arpeggio, the longest cue at 260 ms (11.5 KB)
    "ui_celebrate": [
        (523.25, 0.065), (659.25, 0.065), (783.99, 0.065), (1046.50, 0.065),
    ],
}


def build_cue(name: str) -> bytes:
    samples: list[int] = []
    for freq, duration in CUES[name]:
        samples.extend(note_samples(freq, duration))
        samples.extend(silence(0.0))
    payload = bytearray()
    for sample in samples:
        # little-endian signed 16-bit, wrapping-safe by construction (|sample| < 32767)
        payload += int(sample).to_bytes(2, "little", signed=True)
    return bytes(payload)


def write_wav(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(payload)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=str(REPO_ROOT / "assets" / "audio" / "ui"),
                        help="output directory (default: assets/audio/ui)")
    parser.add_argument("--check", action="store_true",
                        help="write nothing; fail if a file on disk differs")
    args = parser.parse_args()

    out_dir = Path(args.out)
    failures = 0
    for name in sorted(CUES):
        payload = build_cue(name)
        path = out_dir / f"{name}.wav"
        size = 44 + len(payload)  # canonical WAV header
        if size > MAX_BYTES:
            print(f"gen_ui_sounds: FAIL — {name}.wav is {size} bytes (limit {MAX_BYTES})")
            failures += 1
            continue
        if args.check:
            if not path.exists() or path.read_bytes() != _wav_bytes(payload):
                print(f"gen_ui_sounds: FAIL — {path.name} differs from the generator output")
                failures += 1
            else:
                print(f"gen_ui_sounds: OK {path.name} ({size} bytes)")
            continue
        write_wav(path, payload)
        print(f"gen_ui_sounds: wrote {path} ({size} bytes)")

    if failures:
        return 1
    if not args.check:
        print(f"gen_ui_sounds: {len(CUES)} cue(s) written to {out_dir}")
    return 0


def _wav_bytes(payload: bytes) -> bytes:
    """The exact bytes `write_wav` produces, without touching the disk."""
    import io

    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(payload)
    return buffer.getvalue()


if __name__ == "__main__":
    sys.exit(main())
