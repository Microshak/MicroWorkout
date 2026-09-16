class_name Taxonomy
extends RefCounted
## PRD-05 R1 — the canonical PRD-00 §6.1 body-area taxonomy.
##
## Static-only, node-free and scene-tree-free (PRD-TEMPLATE rule 4): everything the
## plan model and the generator need in order to turn a library record's muscles into
## one of the seven user areas lives here and nowhere else. `tests/suites/test_generator.gd`
## (section 2) re-derives the mapping from `data/exercise_library.json` for all 204
## records, so this table cannot drift away from the shipped catalog.
##
## Appendix §6.1 + R33: `Posterior Chain` → `back`, `Adductors`/`Groin` → `legs`. An
## unknown muscle is a build failure upstream (`tools/build_library.py` exits 5), so
## `area_for_muscle()` returning "" is a programming-error signal, never a silent skip.

## The seven user-selectable areas, in the canonical table order.
const USER_AREAS: PackedStringArray = [
	"chest", "back", "shoulders", "arms", "core", "legs", "cardio",
]

## Display labels (PRD-05 R1 / appendix §6.1). `mobility` is never user-selectable.
const AREA_LABELS: Dictionary = {
	"chest": "Chest",
	"back": "Back",
	"shoulders": "Shoulders",
	"arms": "Arms",
	"core": "Core / Abs",
	"legs": "Glutes & Legs",
	"cardio": "Cardio & Conditioning",
	"mobility": "Mobility",
}

## Reserved area: only `is_stretch == true` records live here (PRD-04 R10).
const RESERVED_AREA: String = "mobility"

## Muscle name → area key. Every muscle that appears in the shipped library is listed.
const MUSCLE_TO_AREA: Dictionary = {
	"Chest": "chest",
	"Lats": "back", "Upper Back": "back", "Back": "back",
	"Lower Back": "back", "Posterior Chain": "back",
	"Shoulders": "shoulders", "Rear Delts": "shoulders",
	"Biceps": "arms", "Triceps": "arms", "Forearms": "arms", "Grip": "arms",
	"Core": "core",
	"Quads": "legs", "Hamstrings": "legs", "Glutes": "legs", "Calves": "legs",
	"Legs": "legs", "Hips": "legs", "Adductors": "legs", "Groin": "legs",
	"Cardio": "cardio",
	"Mobility": "mobility",
}


## Area key for a muscle name, or "" when the muscle is unknown.
static func area_for_muscle(muscle: String) -> String:
	return String(MUSCLE_TO_AREA.get(muscle, ""))


## The deduplicated, ordered area list for a library record — the same order the
## library builder used (PRD-04 R5): primary muscle first, then secondaries.
static func areas_for_record(record: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var muscles: Array = [String(record.get("primary_muscle", ""))]
	for muscle in record.get("secondary_muscles", []):
		muscles.append(String(muscle))
	for muscle in muscles:
		var area := area_for_muscle(muscle)
		if area.is_empty() or out.has(area):
			continue
		out.append(area)
	return out


## `record.areas[0]` — never re-derived from `primary_muscle` (PRD-05 R1). The library
## invariant I1 (`areas[0]` is the primary muscle's area) is asserted here, so a
## catalog that violates it fails loudly during development instead of mis-attributing
## weekly volume.
static func primary_area(record: Dictionary) -> String:
	var areas: Array = record.get("areas", [])
	if areas.is_empty():
		return ""
	var first := String(areas[0])
	assert(area_for_muscle(String(record.get("primary_muscle", ""))) == first,
		"library invariant I1 violated for '%s'" % String(record.get("id", "")))
	return first


## `record.areas[1..]` — the areas that count at SECONDARY_WEIGHT in `effective`.
static func secondary_areas(record: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var areas: Array = record.get("areas", [])
	for index in range(1, areas.size()):
		out.append(String(areas[index]))
	return out


## True for the seven selectable areas (never `mobility`).
static func is_user_area(area: String) -> bool:
	return USER_AREAS.has(area)


## Display label; an unknown area returns the key itself so a UI never renders "".
static func label(area: String) -> String:
	return String(AREA_LABELS.get(area, area))
