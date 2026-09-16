#!/usr/bin/env python3
"""PRD-04 R5-R10, R15 - turn the upstream manifest into the app's exercise catalog.

Stages, exactly as specified in PRD-04 R5:

    A  gym-eligibility  302 -> 261   (exercise type + equipment allow-lists)
    B  areas            muscle name -> one of the 7 app areas (+ reserved `mobility`)
    C  pattern + cap    261 -> 204   (movement pattern, equipment rank, PATTERN_CAP)

Outputs:

    data/exercise_library.json          the shipped catalog (PRD-00 appendix sec.7.1)
    build/catalog.json                  slug + upstream frame paths, for the asset fetcher
    build/cache/library_report.json     the asserted numbers in R10
    tests/fixtures/pattern_table.json   id -> movement pattern (PRD-05 drift test)
    assets/exercises/ATTRIBUTION.json   per-frame CC BY-SA upstream credit (R15)

Exit codes: 0 ok - 2 manifest missing/unreadable - 3 manifest shape error -
            4 assertion drift - 5 unknown muscle name - 6 cue-override key fatal.

Usage:
    python3 tools/build_library.py --manifest build/cache/manifest.json \\
        --out data/exercise_library.json --catalog build/catalog.json \\
        --report build/cache/library_report.json \\
        --patterns tests/fixtures/pattern_table.json
"""

from __future__ import annotations

import argparse
import collections
import datetime
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

EXIT_OK = 0
EXIT_MANIFEST = 2
EXIT_SHAPE = 3
EXIT_DRIFT = 4
EXIT_UNKNOWN_MUSCLE = 5
EXIT_OVERRIDE = 6

MANIFEST_LENGTH = 302
FRAMES_PER_EXERCISE = 3

# --- Stage A ---------------------------------------------------------------

GYM_TYPES = ("weight_reps", "bodyweight_reps", "assisted_bodyweight", "duration")
GYM_EQUIPMENT = (
    "Barbell", "Dumbbell", "Machine", "Cable", "Bodyweight",
    "Pull-up Bar", "Bench", "Box", "Plate", "Cardio",
)
EXCLUDED_EQUIPMENT = (
    "Resistance Band", "Kettlebell", "Stability Ball",
    "Wall", "Towel", "Doorway", "Chair",
)

# --- Stage B ---------------------------------------------------------------

USER_AREAS = ("chest", "back", "shoulders", "arms", "core", "legs", "cardio")
RESERVED_AREA = "mobility"

MUSCLE_AREA = {
    "Chest": "chest",
    "Lats": "back",
    "Upper Back": "back",
    "Back": "back",
    "Lower Back": "back",
    "Posterior Chain": "back",       # PRD-04 sec.10 note 1 (absent from PRD-00 sec.5.1)
    "Shoulders": "shoulders",
    "Rear Delts": "shoulders",
    "Biceps": "arms",
    "Triceps": "arms",
    "Forearms": "arms",
    "Grip": "arms",
    "Core": "core",
    "Quads": "legs",
    "Hamstrings": "legs",
    "Glutes": "legs",
    "Calves": "legs",
    "Legs": "legs",
    "Hips": "legs",
    "Adductors": "legs",             # PRD-04 sec.10 note 1
    "Groin": "legs",                 # PRD-04 sec.10 note 1
    "Cardio": "cardio",
    "Mobility": RESERVED_AREA,
}

# --- Stage C ---------------------------------------------------------------

# First-match-wins scan of the lowercased slug; is_stretch short-circuits first.
PATTERN_KEYWORDS = (
    ("vertical_pull", ("pulldown", "pull-up", "pullup", "chin-up", "chinup")),
    ("vertical_push", ("overhead-press", "shoulder-press", "arnold", "military-press",
                       "push-press", "z-press", "pike-push-up", "handstand", "wall-walk",
                       "dumbbell-press", "landmine-press")),
    ("horizontal_pull", ("row",)),
    ("hinge", ("deadlift", "romanian", "good-morning", "swing", "hip-thrust", "glute-bridge",
               "back-extension", "hyperextension", "pull-through", "kickback", "nordic",
               "leg-curl", "hamstring-curl", "walkout", "reverse-hyper")),
    ("lunge", ("lunge", "split-squat", "step-up", "step-down", "cossack", "skater", "curtsy")),
    ("squat", ("squat", "leg-press", "hack", "sissy", "wall-sit")),
    ("horizontal_push", ("bench-press", "chest-press", "push-up", "pushup", "fly",
                         "pec-deck", "pec", "svend", "dip", "floor-press")),
    ("calf", ("calf",)),
    ("shoulder_iso", ("lateral-raise", "front-raise", "rear-delt", "face-pull", "reverse-fly",
                      "y-raise", "t-raise", "snow-angel", "cuban", "scapular", "shrug")),
    ("arm_iso", ("curl", "pushdown", "skullcrusher", "skull-crusher", "triceps-extension",
                 "tricep-extension", "wrist", "farmer", "grip", "hang", "crab-walk")),
    ("core_anti", ("plank", "dead-bug", "bird-dog", "hollow", "ab-wheel", "rollout", "bear",
                   "crawl", "copenhagen", "l-sit", "knee-tuck", "dragon-flag", "inchworm")),
    ("core_rotation", ("twist", "chop", "pallof", "windmill", "russian", "side-bend")),
    ("core_flexion", ("crunch", "sit-up", "v-up", "leg-raise", "toe-touch", "heel-tap",
                      "flutter", "rock", "captains-chair")),
    ("cardio", ("burpee", "jumping-jack", "high-knees", "jack", "rope", "shuffle", "fast-feet",
                "sprawl", "mountain-climber", "thrust", "climber", "jump-rope")),
)
PATTERN_ORDER = ("mobility",) + tuple(key for key, _ in PATTERN_KEYWORDS) + ("other",)

PATTERN_CAP = {
    "horizontal_push": 17, "hinge": 19, "arm_iso": 15, "squat": 13, "lunge": 13,
    "vertical_pull": 14, "core_anti": 13, "core_flexion": 12, "core_rotation": 8,
    "cardio": 14, "shoulder_iso": 12, "vertical_push": 13, "horizontal_pull": 13,
    "calf": 8, "mobility": 14, "other": 99,
}

EQUIPMENT_RANK = {
    "Barbell": 0, "Machine": 1, "Cable": 2, "Dumbbell": 3, "Plate": 4,
    "Pull-up Bar": 5, "Box": 6, "Bench": 7, "Bodyweight": 8, "Cardio": 9,
}

# --- R6 --------------------------------------------------------------------

COMPOUND_PATTERNS = ("squat", "hinge", "lunge", "horizontal_push",
                     "vertical_push", "horizontal_pull", "vertical_pull", "cardio")

ADVANCED_KEYWORDS = (
    "pistol", "shrimp", "handstand", "dragon-flag", "l-sit", "nordic", "copenhagen",
    "ab-wheel", "sissy", "one-arm", "commando", "muscle-up", "planche", "typewriter",
    "archer", "hindu", "explosive", "deficit", "feet-elevated", "walkout",
    "weighted-", "hip-airplane", "reverse-hyper",
)
BEGINNER_KEYWORDS = (
    "assisted", "machine-", "cable-", "wall-sit", "plank", "glute-bridge", "dead-bug",
    "bird-dog", "incline-push-up", "knee-push-up", "crunch", "calf-raise", "goblet",
    "leg-press", "stretch", "circles", "swings", "pushdown", "face-pull", "pallof",
)

DEFAULT_TABLE = {
    (True, "beginner"): (3, 8, 12, 75),
    (True, "intermediate"): (4, 6, 10, 90),
    (True, "advanced"): (4, 4, 8, 120),
    (False, "beginner"): (2, 12, 15, 60),
    (False, "intermediate"): (3, 10, 15, 60),
    (False, "advanced"): (3, 8, 12, 75),
}

# --- R7 --------------------------------------------------------------------

CUE_TEMPLATES = {
    "squat": (
        "Brace your core and keep your chest tall before you descend.",
        "Sit down and back until your thighs reach at least parallel.",
        "Drive through mid-foot and keep your knees tracking over your toes.",
    ),
    "hinge": (
        "Set your shoulders down and pull the weight into your body.",
        "Push your hips back with a flat back — do not round your lower back.",
        "Finish by squeezing your glutes; stop before your back arches.",
    ),
    "lunge": (
        "Take a long enough step that your front shin stays near vertical.",
        "Lower until the back knee is just above the floor.",
        "Push through the front heel to stand; keep your torso upright.",
    ),
    "horizontal_push": (
        "Set your shoulder blades back and down, then keep them pinned.",
        "Lower under control until your hands are level with your mid-chest.",
        "Press away without letting your shoulders roll forward.",
    ),
    "vertical_push": (
        "Start with the weight at collarbone height and your ribs down.",
        "Press straight overhead, moving your head slightly back and through.",
        "Lock out with your biceps next to your ears; do not arch your lower back.",
    ),
    "horizontal_pull": (
        "Hinge to about 45 degrees with a flat back and let the weight hang.",
        "Pull with your elbows, not your hands, and touch your lower ribs.",
        "Lower slowly and let your shoulder blades travel; do not shrug.",
    ),
    "vertical_pull": (
        "Start from a dead hang with your shoulders active, not slack.",
        "Drive your elbows down toward your ribs and lead with your chest.",
        "Lower all the way under control; no swinging or kipping.",
    ),
    "core_flexion": (
        "Exhale and draw your ribs toward your hips.",
        "Move slowly — no momentum from your arms or hips.",
        "Stop when your lower back starts to arch away from the floor.",
    ),
    "core_anti": (
        "Brace as if you were about to be punched in the stomach.",
        "Keep a straight line from shoulders to hips; do not let your hips sag.",
        "Breathe normally and hold the position without shifting.",
    ),
    "core_rotation": (
        "Rotate from your ribcage, not from your arms.",
        "Keep your hips square and your core braced throughout.",
        "Move slowly and stop the rotation rather than letting it swing.",
    ),
    "shoulder_iso": (
        "Lead with your elbows and keep a slight bend in them.",
        "Raise only to shoulder height; stop before your traps take over.",
        "Lower slowly — the lowering half is where the work happens.",
    ),
    "arm_iso": (
        "Keep your elbows tucked and pinned to your sides.",
        "Move only at the elbow — no swinging from your shoulders or hips.",
        "Squeeze at the top, then lower over two seconds.",
    ),
    "calf": (
        "Stand tall with your knees straight but not locked.",
        "Rise as high as you can onto the balls of your feet.",
        "Lower until you feel a stretch in your calf; pause, then repeat.",
    ),
    "cardio": (
        "Start at a pace you could hold a short conversation at.",
        "Keep your breathing rhythmic and your core braced.",
        "Slow down rather than stopping abruptly when the interval ends.",
    ),
    "mobility": (
        "Move into the position slowly and stop before it hurts.",
        "Breathe out as you settle deeper; never bounce.",
        "Hold for the full duration — aim for a gentle pull, not pain.",
    ),
    "other": (
        "Use a load you can control for every rep.",
        "Keep your core braced and your spine neutral.",
        "Stop the set when your form starts to break down.",
    ),
}

CUE_MAX_CHARS = 90
SOURCE = {
    "repo": "bryllim/workout-guide",
    "license": "CC BY-SA 4.0",
    "creator": "Bryl Lim",
}
LICENSE_URL = "https://creativecommons.org/licenses/by-sa/4.0/"
CREATOR_URL = "https://bryllim.com"
CHANGES_SUFFIX = "then downscaled to 384 x 384, alpha quantized to 4 levels, metadata stripped."

# R10 - the pipeline fails the build if any of these differ.
EXPECTED = {
    "manifest_records": 302,
    "after_stage_a": 261,
    "after_stage_c": 204,
    "frames": 612,
    "areas": {"legs": 101, "core": 82, "shoulders": 78, "arms": 68,
              "back": 58, "chest": 28, "cardio": 14, "mobility": 13},
    "types": {"weight_reps": 119, "bodyweight_reps": 48,
              "duration": 34, "assisted_bodyweight": 3},
    "equipment": {"Bodyweight": 69, "Machine": 35, "Dumbbell": 32, "Barbell": 29,
                  "Cable": 26, "Cardio": 4, "Pull-up Bar": 4, "Plate": 2,
                  "Box": 2, "Bench": 1},
    "primary_muscle": {"Core": 34, "Quads": 24, "Shoulders": 20, "Glutes": 19,
                       "Chest": 14, "Back": 13, "Lats": 12, "Biceps": 10,
                       "Hamstrings": 10, "Calves": 9, "Triceps": 7, "Legs": 7,
                       "Upper Back": 5, "Rear Delts": 4, "Mobility": 4,
                       "Lower Back": 3, "Posterior Chain": 3, "Hips": 2,
                       "Adductors": 2, "Forearms": 2},
    "patterns": {"hinge": 19, "horizontal_push": 17, "arm_iso": 15, "vertical_pull": 14,
                 "squat": 13, "lunge": 13, "core_anti": 13, "mobility": 13,
                 "vertical_push": 12, "horizontal_pull": 12, "cardio": 12,
                 "shoulder_iso": 12, "core_flexion": 12, "core_rotation": 7,
                 "calf": 5, "other": 15},
    "priority_overrides": 60,
    "stretches": 13,
}

USER_AREA_MINIMUM = 12
MOBILITY_MINIMUM = 10


def die(code: int, message: str) -> None:
    print(f"[library] FATAL {message}", file=sys.stderr)
    sys.exit(code)


def log(message: str) -> None:
    print(f"[library] {message}")


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

def load_manifest(path: Path) -> list[dict]:
    if not path.exists():
        die(EXIT_MANIFEST, f"manifest not found: {path} (run tools/fetch_exercise_assets.py first)")
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(EXIT_MANIFEST, f"cannot read manifest {path}: {exc}")
    if not isinstance(manifest, list):
        die(EXIT_SHAPE, f"manifest must be a JSON array, got {type(manifest).__name__}")
    for index, record in enumerate(manifest):
        missing = [key for key in ("slug", "name", "exerciseType", "equipment",
                                   "primaryMuscle", "secondaryMuscles", "isStretch", "frames")
                   if key not in record]
        if missing:
            die(EXIT_SHAPE, f"manifest record {index} is missing {missing}")
        if len(record["frames"]) != FRAMES_PER_EXERCISE:
            die(EXIT_SHAPE,
                f"manifest record {index} ({record['slug']}) has {len(record['frames'])} frames")
    return manifest


def load_overrides(path: Path) -> dict[str, list[str]]:
    if not path.exists():
        die(EXIT_MANIFEST, f"cue overrides not found: {path}")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(EXIT_OVERRIDE, f"cannot read {path}: {exc}")
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        die(EXIT_OVERRIDE, f"{path} must be an object with schema_version == 1")
    overrides = document.get("overrides")
    if not isinstance(overrides, dict) or not overrides:
        die(EXIT_OVERRIDE, f"{path} has no 'overrides' object")
    for key, value in overrides.items():
        if not isinstance(value, list) or len(value) != 3:
            die(EXIT_OVERRIDE, f"override {key!r} must have exactly 3 cues")
        for cue in value:
            if not isinstance(cue, str) or not cue.strip():
                die(EXIT_OVERRIDE, f"override {key!r} has an empty cue")
            if len(cue) > CUE_MAX_CHARS:
                die(EXIT_OVERRIDE, f"override {key!r} cue is {len(cue)} chars (max {CUE_MAX_CHARS})")
            if "{" in cue:
                die(EXIT_OVERRIDE, f"override {key!r} contains a placeholder")
    return overrides


# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

def stage_a(manifest: list[dict]) -> list[tuple[int, dict]]:
    """Gym eligibility: exercise type and equipment allow-lists."""
    return [(index, record) for index, record in enumerate(manifest)
            if record["exerciseType"] in GYM_TYPES
            and record["equipment"] in GYM_EQUIPMENT]


def areas_for(record: dict) -> list[str]:
    """Stage B. Invariant I1: areas[0] is always the primary muscle's area."""
    ordered: list[str] = []
    for muscle in [record["primaryMuscle"]] + list(record["secondaryMuscles"]):
        area = MUSCLE_AREA.get(muscle)
        if area is None:
            die(EXIT_UNKNOWN_MUSCLE,
                f"muscle {muscle!r} on {record['slug']!r} is not in the area mapping; "
                f"add it to MUSCLE_AREA before shipping")
        if area not in ordered:
            ordered.append(area)
    return ordered


def pattern_for(record: dict) -> str:
    if record["isStretch"]:
        return "mobility"
    slug = record["slug"].lower()
    for key, keywords in PATTERN_KEYWORDS:
        for keyword in keywords:
            if keyword in slug:
                return key
    return "other"


def stage_c(eligible: list[tuple[int, dict]], priority: set[str]) -> tuple[list[tuple[int, dict]], dict]:
    """Rank inside each pattern group, apply PATTERN_CAP, force-keep priority ids.

    A priority id outside the cap displaces the lowest-ranked *non-priority* member of
    its own group, so the group still contributes exactly PATTERN_CAP entries; the
    catalog therefore lands on exactly 204 records with all 59 in-catalog priority
    lifts present (see docs/DECISIONS.md ADR-12).
    """
    groups: dict[str, list[tuple[int, dict]]] = collections.OrderedDict(
        (key, []) for key in PATTERN_ORDER)
    for index, record in eligible:
        groups[pattern_for(record)].append((index, record))

    kept: list[tuple[int, dict]] = []
    displaced: list[str] = []
    for key in PATTERN_ORDER:
        items = groups[key]
        items.sort(key=lambda item: (EQUIPMENT_RANK.get(item[1]["equipment"], 99), item[0]))
        cap = PATTERN_CAP[key]
        forced = [item for item in items if item[1]["slug"] in priority]
        rest = [item for item in items if item[1]["slug"] not in priority]
        keep = forced + rest[:max(0, cap - len(forced))]
        keep_slugs = {item[1]["slug"] for item in keep}
        for item in rest:
            if item[1]["slug"] not in keep_slugs:
                displaced.append(item[1]["slug"])
        keep.sort(key=lambda item: item[0])
        kept.extend(keep)

    kept.sort(key=lambda item: item[1]["slug"])
    stats = {
        "groups": {key: len(groups[key]) for key in PATTERN_ORDER},
        "caps": dict(PATTERN_CAP),
        "displaced": sorted(displaced),
    }
    return kept, stats


# ---------------------------------------------------------------------------
# R6 - compound / difficulty / defaults
# ---------------------------------------------------------------------------

def compound_for(pattern: str) -> bool:
    return pattern in COMPOUND_PATTERNS


def difficulty_for(record: dict) -> str:
    slug = record["slug"].lower()
    for keyword in ADVANCED_KEYWORDS:
        if keyword in slug:
            return "advanced"
    if record["exerciseType"] == "assisted_bodyweight":
        return "beginner"
    for keyword in BEGINNER_KEYWORDS:
        if keyword in slug:
            return "beginner"
    return "intermediate"


def defaults_for(record: dict, compound: bool, difficulty: str) -> tuple[int, int, int, int]:
    sets, rep_min, rep_max, rest = DEFAULT_TABLE[(compound, difficulty)]
    if record["exerciseType"] == "duration":
        sets, rep_min, rep_max = 3, 30, 60
        rest = 45 if compound else 30
    if record["isStretch"]:
        sets, rep_min, rep_max, rest = 1, 30, 60, 0
    if record["exerciseType"] == "assisted_bodyweight":
        rep_min = max(rep_min, 8)
        rep_max = max(rep_max, 12)
    return sets, rep_min, rep_max, rest


def build_records(kept: list[tuple[int, dict]],
                  overrides: dict[str, list[str]]) -> list[dict]:
    records: list[dict] = []
    for _, source in kept:
        slug = source["slug"]
        pattern = pattern_for(source)
        compound = compound_for(pattern)
        difficulty = difficulty_for(source)
        sets, rep_min, rep_max, rest = defaults_for(source, compound, difficulty)
        cues = overrides.get(slug) or list(CUE_TEMPLATES[pattern])
        records.append({
            "id": slug,
            "name": source["name"],
            "exercise_type": source["exerciseType"],
            "equipment": source["equipment"],
            "primary_muscle": source["primaryMuscle"],
            "secondary_muscles": list(source["secondaryMuscles"]),
            "areas": areas_for(source),
            "is_stretch": bool(source["isStretch"]),
            "compound": compound,
            "difficulty": difficulty,
            "frames": [f"res://assets/exercises/{slug}/frame-{index}.png"
                       for index in (1, 2, 3)],
            "cues": list(cues),
            "default_sets": sets,
            "rep_min": rep_min,
            "rep_max": rep_max,
            "rest_seconds": rest,
        })
    return records


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def tally(records: list[dict], key) -> collections.Counter:
    counter: collections.Counter = collections.Counter()
    for record in records:
        value = key(record)
        if isinstance(value, list):
            counter.update(value)
        else:
            counter[value] += 1
    return counter


def ordered(counter: collections.Counter, pin_last: tuple[str, ...] = ()) -> list[tuple[str, int]]:
    """Highest count first; ties keep the order in which the id first appeared."""
    pinned = [(key, counter[key]) for key in pin_last if key in counter]
    body = [(key, value) for key, value in counter.items() if key not in pin_last]
    body.sort(key=lambda item: -item[1])
    return body + pinned


def render(label: str, pairs: list[tuple[str, int]]) -> str:
    return f"{label}: " + " ".join(f"{key}={value}" for key, value in pairs)


def compute_report(manifest: list[dict], eligible: list[tuple[int, dict]],
                   records: list[dict], pattern_by_id: dict[str, str],
                   stage_stats: dict, overrides: dict[str, list[str]]) -> dict:
    pattern_counter: collections.Counter = collections.Counter(pattern_by_id.values())
    return {
        "manifest_records": len(manifest),
        "after_stage_a": len(eligible),
        "after_stage_c": len(records),
        "frames": len(records) * FRAMES_PER_EXERCISE,
        "areas": dict(ordered(tally(records, lambda r: r["areas"]))),
        "types": dict(ordered(tally(records, lambda r: r["exercise_type"]))),
        "equipment": dict(ordered(tally(records, lambda r: r["equipment"]))),
        "primary_muscle": dict(ordered(tally(records, lambda r: r["primary_muscle"]))),
        "patterns": dict(ordered(pattern_counter, pin_last=("other",))),
        "priority_overrides": len(overrides),
        "stretches": sum(1 for record in records if record["is_stretch"]),
        "single_area": sorted(record["id"] for record in records if len(record["areas"]) == 1),
        "excluded_equipment": list(EXCLUDED_EQUIPMENT),
        "pattern_group_sizes": stage_stats["groups"],
        "pattern_caps": stage_stats["caps"],
        "stage_c_displaced": stage_stats["displaced"],
        "priority_ids": sorted(overrides),
    }


def diff_report(actual: dict, expected: dict) -> list[str]:
    lines: list[str] = []
    for key, want in expected.items():
        got = actual.get(key)
        if got != want:
            if isinstance(want, dict) and isinstance(got, dict):
                for sub in sorted(set(want) | set(got)):
                    if want.get(sub) != got.get(sub):
                        lines.append(f"  {key}.{sub}: expected {want.get(sub)} got {got.get(sub)}")
            else:
                lines.append(f"  {key}: expected {want} got {got}")
    return lines


def assert_invariants(records: list[dict], overrides: dict[str, list[str]],
                      manifest_slugs: set[str], eligible_slugs: set[str]) -> list[str]:
    problems: list[str] = []

    ids = [record["id"] for record in records]
    if len(ids) != len(set(ids)):
        problems.append("duplicate ids in the catalog")
    if ids != sorted(ids):
        problems.append("catalog is not sorted by id")
    if len(records) != EXPECTED["after_stage_c"]:
        problems.append(f"after_stage_c != {EXPECTED['after_stage_c']}")
    if len(records) * FRAMES_PER_EXERCISE != EXPECTED["frames"]:
        problems.append(f"frames != {EXPECTED['frames']}")

    for record in records:
        areas = record["areas"]
        if not areas:
            problems.append(f"{record['id']}: no areas")
            continue
        if not any(area in USER_AREAS for area in areas):
            problems.append(f"{record['id']}: no user-selectable area")
        primary_area = MUSCLE_AREA[record["primary_muscle"]]
        if areas[0] != primary_area:
            problems.append(f"{record['id']}: areas[0]={areas[0]} != primary area {primary_area}")
        if len(areas) != len(set(areas)):
            problems.append(f"{record['id']}: areas contain duplicates")
        if len(record["cues"]) != 3:
            problems.append(f"{record['id']}: {len(record['cues'])} cues")
        for cue in record["cues"]:
            if not cue.strip() or len(cue) > CUE_MAX_CHARS or "{" in cue:
                problems.append(f"{record['id']}: bad cue {cue!r}")
        if len(record["frames"]) != FRAMES_PER_EXERCISE:
            problems.append(f"{record['id']}: {len(record['frames'])} frames")
        if not (record["difficulty"] in ("beginner", "intermediate", "advanced")):
            problems.append(f"{record['id']}: bad difficulty {record['difficulty']}")
        if record["is_stretch"] and RESERVED_AREA not in areas:
            problems.append(f"{record['id']}: stretch without the mobility area")
        if record["rep_max"] < record["rep_min"]:
            problems.append(f"{record['id']}: rep_max < rep_min")

    area_counts = tally(records, lambda r: r["areas"])
    for area in USER_AREAS:
        if area_counts[area] < USER_AREA_MINIMUM:
            problems.append(f"area {area} has {area_counts[area]} < {USER_AREA_MINIMUM}")
    if area_counts[RESERVED_AREA] < MOBILITY_MINIMUM:
        problems.append(f"mobility has {area_counts[RESERVED_AREA]} < {MOBILITY_MINIMUM}")

    stretches = [record for record in records if record["is_stretch"]]
    if len(stretches) != EXPECTED["stretches"]:
        problems.append(f"stretches != {EXPECTED['stretches']}")
    for record in stretches:
        if record["default_sets"] != 1 or record["rest_seconds"] != 0:
            problems.append(f"{record['id']}: stretch defaults sets={record['default_sets']} "
                            f"rest={record['rest_seconds']}")

    catalog_ids = set(ids)
    for key in overrides:
        if key not in manifest_slugs:
            problems.append(f"cue override {key!r} is not a manifest slug (typo?)")
        elif key not in catalog_ids:
            if key in eligible_slugs:
                problems.append(f"priority id {key!r} was pruned by stage C")
            else:
                log(f"NOTE priority id {key!r} is excluded by stage A "
                    f"(not a sets x reps lift); kept in cue_overrides.json for the record")
    return problems


# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------

def write_json(path: Path, document, indent: int = 2) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(document, indent=indent, sort_keys=False, ensure_ascii=False)
    path.write_text(text + "\n", encoding="utf-8")


def attribution_document(kept: list[tuple[int, dict]]) -> dict:
    assets: list[dict] = []
    for _, source in kept:
        for frame in source["frames"]:
            upstream = (frame.get("attribution") or {}).get("source")
            if not upstream:
                continue
            changes = (upstream.get("changes") or "").strip().rstrip(".")
            assets.append({
                "id": source["slug"],
                "frame": int(frame["index"]),
                "upstream_name": upstream.get("name", ""),
                "upstream_url": upstream.get("url", ""),
                "upstream_license": upstream.get("license", ""),
                "upstream_license_url": upstream.get("licenseUrl", ""),
                "changes": f"{changes}; {CHANGES_SUFFIX}",
            })
    return {
        "schema_version": 1,
        "license": "CC BY-SA 4.0",
        "license_url": LICENSE_URL,
        "creator": {"name": SOURCE["creator"], "url": CREATOR_URL},
        "source_repo": SOURCE["repo"],
        "note": ("Derived from the upstream workout-guide manifest. Redistributed under "
                 "CC BY-SA 4.0; the ShareAlike obligation travels with these files."),
        "assets": assets,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the MicroWorkout exercise catalog.")
    parser.add_argument("--manifest", default="build/cache/manifest.json")
    parser.add_argument("--out", default="data/exercise_library.json")
    parser.add_argument("--catalog", default="build/catalog.json")
    parser.add_argument("--report", default="build/cache/library_report.json")
    parser.add_argument("--patterns", default="tests/fixtures/pattern_table.json")
    parser.add_argument("--attribution", default="assets/exercises/ATTRIBUTION.json")
    parser.add_argument("--cue-overrides", default="data/cue_overrides.json")
    parser.add_argument("--allow-drift", action="store_true",
                        help="regenerate after an upstream change; prints the diff and does not fail")
    args = parser.parse_args()

    manifest_path = ROOT / args.manifest
    manifest = load_manifest(manifest_path)
    if len(manifest) != MANIFEST_LENGTH:
        log(f"WARNING manifest has {len(manifest)} records, expected {MANIFEST_LENGTH}")
    log(f"manifest {args.manifest} records={len(manifest)}")

    overrides = load_overrides(ROOT / args.cue_overrides)
    priority = set(overrides)
    manifest_slugs = {record["slug"] for record in manifest}

    eligible = stage_a(manifest)
    eligible_slugs = {record["slug"] for _, record in eligible}
    kept, stage_stats = stage_c(eligible, priority)
    records = build_records(kept, overrides)
    pattern_by_id = {source["slug"]: pattern_for(source) for _, source in kept}

    report = compute_report(manifest, eligible, records, pattern_by_id, stage_stats, overrides)
    problems = assert_invariants(records, overrides, manifest_slugs, eligible_slugs)

    # ---- the catalog -------------------------------------------------------
    library = {
        "schema_version": 1,
        "source": dict(SOURCE),
        "exercises": records,
    }
    catalog = {
        "schema_version": 1,
        "count": len(records),
        "frame_count": len(records) * FRAMES_PER_EXERCISE,
        "exercises": [
            {
                "slug": source["slug"],
                "frames": [frame["path"][:-4] + ".png" for frame in source["frames"]],
            }
            for _, source in kept
        ],
    }
    patterns = {
        "schema_version": 1,
        "patterns": pattern_by_id,
    }
    attribution = attribution_document(kept)
    report["attribution_entries"] = len(attribution["assets"])

    if problems:
        for problem in problems:
            print(f"[library] ASSERTION FAILED {problem}", file=sys.stderr)
        return EXIT_DRIFT

    drift = diff_report(report, EXPECTED)
    if drift:
        if not args.allow_drift:
            print("[library] FATAL report drift vs PRD-04 R10:", file=sys.stderr)
            for line in drift:
                print(line, file=sys.stderr)
            print("[library] re-run with --allow-drift to regenerate and record the change",
                  file=sys.stderr)
            return EXIT_DRIFT
        log("--allow-drift: the following numbers changed")
        for line in drift:
            log(line)

    write_json(ROOT / args.out, library)
    write_json(ROOT / args.catalog, catalog)
    write_json(ROOT / args.patterns, patterns)
    write_json(ROOT / args.attribution, attribution)
    write_json(ROOT / args.report, report)

    # ---- the asserted R10 report ------------------------------------------
    print(f"manifest_records={report['manifest_records']} "
          f"after_stage_a={report['after_stage_a']} "
          f"after_stage_c={report['after_stage_c']} frames={report['frames']}")
    print(render("areas", ordered(tally(records, lambda r: r["areas"]))))
    print(render("types", ordered(tally(records, lambda r: r["exercise_type"]))))
    print(render("equipment", ordered(tally(records, lambda r: r["equipment"]))))
    print(render("primary_muscle", ordered(tally(records, lambda r: r["primary_muscle"]))))
    print(render("patterns", ordered(collections.Counter(pattern_by_id.values()),
                                     pin_last=("other",))))
    print(f"priority_overrides={report['priority_overrides']} stretches={report['stretches']}")
    print(f"attribution_entries={report['attribution_entries']} "
          f"single_area={len(report['single_area'])}")
    print("single_area_ids: " + " ".join(report["single_area"]))
    print(f"wrote {args.out} ({len(records)} exercises), {args.catalog}, "
          f"{args.patterns}, {args.attribution}, {args.report}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
