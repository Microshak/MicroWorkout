extends TestSuite
## PRD-04 R9/R10/R15/R18 — validates the GENERATED exercise-library data.
##
## This suite deliberately tests the *artifacts*, not the loader: it reads
## `res://data/exercise_library.json`, `res://data/cue_overrides.json`,
## `res://tests/fixtures/pattern_table.json` and the 612 PNG frames straight off
## disk with `FileAccess`, so it proves what the pipeline actually produced rather
## than what `Library` makes of it (PRD-03 owns `Library`'s own suite).
##
## It must therefore not depend on autoload singletons — the runner is
## `godot --headless --script`, where autoloads are not reachable (ADR-04).

const LIBRARY_PATH := "res://data/exercise_library.json"
const OVERRIDES_PATH := "res://data/cue_overrides.json"
const PATTERNS_PATH := "res://tests/fixtures/pattern_table.json"
const REFS_PATH := "res://tests/fixtures/plan_refs.json"
const ATTRIBUTION_JSON := "res://assets/exercises/ATTRIBUTION.json"
const ATTRIBUTION_MD := "res://docs/ATTRIBUTION.md"
const LICENSE_ASSETS := "res://assets/exercises/LICENSE-ASSETS"

const EXPECTED_COUNT := 204
const FRAMES_PER_EXERCISE := 3
const FRAME_PX := 384
const USER_AREA_MINIMUM := 12
const MOBILITY_MINIMUM := 10
const CUE_MAX_CHARS := 90
const SIZE_CEILING := 8388608

## Appendix §7.1 — exactly these keys, no extras, no missing.
const RECORD_KEYS: PackedStringArray = [
	"id", "name", "exercise_type", "equipment", "primary_muscle",
	"secondary_muscles", "areas", "is_stretch", "compound", "difficulty",
	"frames", "cues", "default_sets", "rep_min", "rep_max", "rest_seconds",
]

const USER_AREAS: PackedStringArray = [
	"chest", "back", "shoulders", "arms", "core", "legs", "cardio",
]

## PRD-04 R5 stage B, written out literally on purpose: `scripts/core/taxonomy.gd`
## does not exist yet, so the test must not borrow the pipeline's own table.
const MUSCLE_AREA := {
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

## PRD-04 R10 / appendix §7.2 — the asserted per-area distribution.
const AREA_DISTRIBUTION := {
	"legs": 101, "core": 82, "shoulders": 78, "arms": 68,
	"back": 58, "chest": 28, "cardio": 14, "mobility": 13,
}

const DIFFICULTIES: PackedStringArray = ["beginner", "intermediate", "advanced"]
const COMPOUND_PATTERNS: PackedStringArray = [
	"squat", "hinge", "lunge", "horizontal_push",
	"vertical_push", "horizontal_pull", "vertical_pull", "cardio",
]

## R8 lists 60 priority ids; one of them (`farmer-carry`) is `distance_duration`
## upstream and is dropped by stage A because it cannot be expressed as sets x reps.
const STAGE_A_EXCLUDED_PRIORITY: PackedStringArray = ["farmer-carry"]

var _library: Dictionary = {}
var _ids: PackedStringArray = PackedStringArray()
var _by_id: Dictionary = {}
var _total_frame_bytes: int = 0
var _total_import_bytes: int = 0


func _init() -> void:
	suite_name = "library_data"


func run() -> void:
	_test_root_schema()
	_test_record_schema()
	_test_counts_and_ids()
	_test_frames_on_disk()
	_test_areas()
	_test_area_distribution()
	_test_stretches()
	_test_defaults_ranges()
	_test_cues()
	_test_cue_overrides()
	_test_pattern_table()
	_test_plan_fixture_refs()
	_test_import_presets()
	_test_size_budget()
	_test_attribution_files()
	_report_distribution()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return null
	return JSON.parse_string(text)


func _is_int(value: Variant) -> bool:
	if value is int:
		return true
	if value is float:
		return is_equal_approx(float(value), floorf(float(value)))
	return false


func _is_string_array(value: Variant) -> bool:
	if not (value is Array):
		return false
	for entry in value:
		if not (entry is String):
			return false
	return true


func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var size := file.get_length()
	file.close()
	return size


func _load_library_once() -> void:
	if not _library.is_empty():
		return
	var parsed: Variant = _read_json(LIBRARY_PATH)
	if parsed is Dictionary:
		_library = parsed
		for record in _library.get("exercises", []):
			_by_id[record.get("id", "")] = record
			_ids.append(record.get("id", ""))


# ---------------------------------------------------------------------------
# 1-2 · root document and the frozen record schema
# ---------------------------------------------------------------------------

func _test_root_schema() -> void:
	begin("root document schema")
	_load_library_once()
	assert_not_empty(_library, "%s parses to a Dictionary" % LIBRARY_PATH)
	assert_eq(int(_library.get("schema_version", -1)), 1, "schema_version is 1")
	var source: Variant = _library.get("source")
	assert_true(source is Dictionary, "source is an object")
	if source is Dictionary:
		assert_eq(source.get("repo", ""), "bryllim/workout-guide", "source.repo")
		assert_eq(source.get("license", ""), "CC BY-SA 4.0", "source.license")
		assert_eq(source.get("creator", ""), "Bryl Lim", "source.creator")
	assert_eq(_library.keys().size(), 3, "root has exactly schema_version + source + exercises")
	assert_true(_library.get("exercises") is Array, "exercises is an array")


func _test_record_schema() -> void:
	begin("every record has exactly the %d appendix §7.1 keys" % RECORD_KEYS.size())
	_load_library_once()
	var exercises: Array = _library.get("exercises", [])
	assert_eq(exercises.size(), EXPECTED_COUNT,
		"the library is the asserted %d records" % EXPECTED_COUNT)
	for record in exercises:
		var id: String = record.get("id", "<no id>")
		assert_eq(record.keys().size(), RECORD_KEYS.size(), "%s: key count" % id)
		for key in RECORD_KEYS:
			assert_has_key(record, key, "%s" % id)
		assert_true(record.get("id") is String and not (record.get("id") as String).is_empty(),
			"%s: id is a non-empty String" % id)
		assert_true(record.get("name") is String and not (record.get("name") as String).is_empty(),
			"%s: name" % id)
		assert_true(record.get("exercise_type") is String, "%s: exercise_type" % id)
		assert_true(record.get("equipment") is String, "%s: equipment" % id)
		assert_true(record.get("primary_muscle") is String, "%s: primary_muscle" % id)
		assert_true(_is_string_array(record.get("secondary_muscles", null)),
			"%s: secondary_muscles is Array[String]" % id)
		assert_true(_is_string_array(record.get("areas", null)), "%s: areas is Array[String]" % id)
		assert_true(record.get("is_stretch") is bool, "%s: is_stretch is bool" % id)
		assert_true(record.get("compound") is bool, "%s: compound is bool" % id)
		assert_true(record.get("difficulty") is String
			and DIFFICULTIES.has(record.get("difficulty", "")), "%s: difficulty" % id)
		assert_true(_is_string_array(record.get("frames", null)), "%s: frames is Array[String]" % id)
		assert_true(_is_string_array(record.get("cues", null)), "%s: cues is Array[String]" % id)
		assert_true(_is_int(record.get("default_sets", null)), "%s: default_sets is an int" % id)
		assert_true(_is_int(record.get("rep_min", null)), "%s: rep_min is an int" % id)
		assert_true(_is_int(record.get("rep_max", null)), "%s: rep_max is an int" % id)
		assert_true(_is_int(record.get("rest_seconds", null)), "%s: rest_seconds is an int" % id)


# ---------------------------------------------------------------------------
# 3 · count, uniqueness, ordering
# ---------------------------------------------------------------------------

func _test_counts_and_ids() -> void:
	begin("count, unique ids, sorted by id")
	_load_library_once()
	var exercises: Array = _library.get("exercises", [])
	assert_eq(exercises.size(), EXPECTED_COUNT, "count() == %d" % EXPECTED_COUNT)

	var seen: Dictionary = {}
	var duplicates: PackedStringArray = PackedStringArray()
	for record in exercises:
		var id: String = record.get("id", "")
		if seen.has(id):
			duplicates.append(id)
		seen[id] = int(seen.get(id, 0)) + 1
	assert_empty(duplicates, "no duplicate ids: %s" % str(duplicates))
	assert_eq(seen.size(), EXPECTED_COUNT, "every id is distinct")

	var sorted_ids: PackedStringArray = _ids.duplicate()
	sorted_ids.sort()
	assert_eq(_ids, sorted_ids, "exercises are sorted by id")

	var repeated: PackedStringArray = PackedStringArray()
	for id in seen:
		if int(seen[id]) != 1:
			repeated.append("%s x%d" % [id, int(seen[id])])
	assert_empty(repeated, "each id appears exactly once: %s" % str(repeated))


# ---------------------------------------------------------------------------
# 4 · the 612 frames really exist, and really are 384x384 LA PNGs
# ---------------------------------------------------------------------------

func _test_frames_on_disk() -> void:
	begin("all %d frame paths exist on disk" % (EXPECTED_COUNT * FRAMES_PER_EXERCISE))
	_load_library_once()
	var exercises: Array = _library.get("exercises", [])
	var checked := 0
	var missing: PackedStringArray = PackedStringArray()
	var wrong_format: PackedStringArray = PackedStringArray()
	for record in exercises:
		var id: String = record.get("id", "")
		var frames: Array = record.get("frames", [])
		assert_eq(frames.size(), FRAMES_PER_EXERCISE, "%s: exactly 3 frames" % id)
		for index in range(frames.size()):
			var path: String = frames[index]
			checked += 1
			assert_eq(path, "res://assets/exercises/%s/frame-%d.png" % [id, index + 1],
				"%s frame %d path form" % [id, index + 1])
			if not FileAccess.file_exists(path):
				missing.append(path)
				continue
			_total_frame_bytes += _file_size(path)
			var image := Image.new()
			var error := image.load_png_from_buffer(FileAccess.get_file_as_bytes(path))
			if error != OK:
				wrong_format.append("%s (decode error %d)" % [path, error])
				continue
			if image.get_width() != FRAME_PX or image.get_height() != FRAME_PX:
				wrong_format.append("%s (%dx%d)" % [path, image.get_width(), image.get_height()])
			elif image.get_format() != Image.FORMAT_LA8:
				wrong_format.append("%s (format %d, expected FORMAT_LA8)" % [path, image.get_format()])
	assert_eq(checked, EXPECTED_COUNT * FRAMES_PER_EXERCISE, "checked all 612 frame paths")
	assert_empty(missing, "no missing frame files: %s" % str(missing.slice(0, 5)))
	assert_empty(wrong_format, "every frame decodes as 384x384 LA: %s" % str(wrong_format.slice(0, 5)))


# ---------------------------------------------------------------------------
# 5 · areas, invariant I1
# ---------------------------------------------------------------------------

func _test_areas() -> void:
	begin("every exercise maps to >= 1 area and areas[0] is the primary area (I1)")
	_load_library_once()
	var exercises: Array = _library.get("exercises", [])
	var no_user_area: PackedStringArray = PackedStringArray()
	var broken_invariant: PackedStringArray = PackedStringArray()
	var unknown_muscle: PackedStringArray = PackedStringArray()
	var single_area := 0

	for record in exercises:
		var id: String = record.get("id", "")
		var areas: Array = record.get("areas", [])
		assert_not_empty(areas, "%s: at least one area" % id)

		var has_user_area := false
		for area in areas:
			if USER_AREAS.has(area):
				has_user_area = true
		if not has_user_area:
			no_user_area.append(id)

		var unique := {}
		for area in areas:
			unique[area] = true
		assert_eq(unique.size(), areas.size(), "%s: areas are de-duplicated" % id)
		if areas.size() == 1:
			single_area += 1

		var primary: String = record.get("primary_muscle", "")
		if not MUSCLE_AREA.has(primary):
			unknown_muscle.append("%s:%s" % [id, primary])
			continue
		if areas[0] != MUSCLE_AREA[primary]:
			broken_invariant.append("%s: %s != %s" % [id, areas[0], MUSCLE_AREA[primary]])

		# The full mapping must be reproducible from primary + secondary muscles.
		var expected: Array = []
		for muscle in ([primary] as Array) + (record.get("secondary_muscles", []) as Array):
			if not MUSCLE_AREA.has(muscle):
				unknown_muscle.append("%s:%s" % [id, muscle])
				continue
			var area: String = MUSCLE_AREA[muscle]
			if not expected.has(area):
				expected.append(area)
		assert_eq(areas, expected, "%s: areas == dedupe(primary + secondary)" % id)

	assert_empty(no_user_area, "every exercise has >= 1 user area: %s" % str(no_user_area))
	assert_empty(broken_invariant, "areas[0] == primary area: %s" % str(broken_invariant))
	assert_empty(unknown_muscle, "no unmapped muscle names: %s" % str(unknown_muscle))
	assert_eq(single_area, 37, "37 single-area exercises (PRD-04 R10)")


func _test_area_distribution() -> void:
	begin("per-area distribution matches PRD-04 R10 and the minimums hold")
	_load_library_once()
	var exercises: Array = _library.get("exercises", [])
	var counts: Dictionary = {}
	for area in USER_AREAS:
		counts[area] = 0
	counts["mobility"] = 0
	for record in exercises:
		for area in record.get("areas", []):
			counts[area] = int(counts.get(area, 0)) + 1

	for area in AREA_DISTRIBUTION:
		assert_eq(counts.get(area, -1), AREA_DISTRIBUTION[area],
			"areas.%s == %d" % [area, AREA_DISTRIBUTION[area]])
	for area in USER_AREAS:
		assert_ge(int(counts[area]), USER_AREA_MINIMUM,
			"user area %s has >= %d exercises" % [area, USER_AREA_MINIMUM])
	assert_ge(int(counts["mobility"]), MOBILITY_MINIMUM, "mobility >= %d" % MOBILITY_MINIMUM)

	var total_area_links := 0
	for area in counts:
		total_area_links += int(counts[area])
	assert_eq(total_area_links, 442, "442 area links across 204 exercises")


# ---------------------------------------------------------------------------
# 8 · stretches
# ---------------------------------------------------------------------------

func _test_stretches() -> void:
	begin("exactly 13 stretches, all in mobility, sets 1 / rest 0")
	_load_library_once()
	var stretches: Array = []
	for record in _library.get("exercises", []):
		if record.get("is_stretch", false):
			stretches.append(record)
	assert_eq(stretches.size(), 13, "13 records have is_stretch == true")
	for record in stretches:
		var id: String = record.get("id", "")
		assert_true((record.get("areas", []) as Array).has("mobility"),
			"%s is in the mobility area" % id)
		assert_eq(int(record.get("default_sets", -1)), 1, "%s: default_sets == 1" % id)
		assert_eq(int(record.get("rest_seconds", -1)), 0, "%s: rest_seconds == 0" % id)
		assert_eq(int(record.get("rep_min", -1)), 30, "%s: rep_min == 30" % id)
		assert_eq(int(record.get("rep_max", -1)), 60, "%s: rep_max == 60" % id)
		assert_eq(record.get("exercise_type", ""), "duration", "%s: duration type" % id)


# ---------------------------------------------------------------------------
# 6 · defaults, reps, compound flags
# ---------------------------------------------------------------------------

func _test_defaults_ranges() -> void:
	begin("defaults are inside the documented ranges and compound matches the pattern table")
	_load_library_once()
	var patterns: Variant = _read_json(PATTERNS_PATH)
	var table: Dictionary = patterns.get("patterns", {}) if patterns is Dictionary else {}
	var duration_count := 0
	var mismatched_compound: PackedStringArray = PackedStringArray()

	for record in _library.get("exercises", []):
		var id: String = record.get("id", "")
		var sets := int(record.get("default_sets", 0))
		var rep_min := int(record.get("rep_min", 0))
		var rep_max := int(record.get("rep_max", 0))
		var rest := int(record.get("rest_seconds", 0))
		assert_true(sets >= 1 and sets <= 8, "%s: default_sets %d in 1..8" % [id, sets])
		assert_true(rep_max >= rep_min, "%s: rep_max >= rep_min" % id)
		assert_true(rest >= 0 and rest <= 300, "%s: rest_seconds %d in 0..300" % [id, rest])
		if record.get("exercise_type", "") == "duration":
			duration_count += 1
			assert_true(rep_min >= 10 and rep_max <= 300, "%s: seconds in 10..300" % id)
		else:
			assert_true(rep_min >= 1 and rep_max <= 30, "%s: reps in 1..30" % id)
		var expected_compound: bool = COMPOUND_PATTERNS.has(table.get(id, "other"))
		if bool(record.get("compound", false)) != expected_compound:
			mismatched_compound.append("%s (pattern=%s)" % [id, table.get(id, "<missing>")])

	assert_eq(duration_count, 34, "34 duration records (reps are SECONDS for these)")
	assert_empty(mismatched_compound,
		"compound == pattern in {8 lifting patterns}: %s" % str(mismatched_compound))
	assert_true(bool(_by_id.get("bench-press", {}).get("compound", false)),
		"bench-press is compound")
	assert_eq(_by_id.get("bench-press", {}).get("difficulty", ""), "intermediate",
		"bench-press is intermediate (PRD-00 §5.2)")


# ---------------------------------------------------------------------------
# 10 · cues
# ---------------------------------------------------------------------------

func _test_cues() -> void:
	begin("every record has exactly 3 non-empty cues of <= 90 chars with no placeholders")
	_load_library_once()
	var template_only := 0
	for record in _library.get("exercises", []):
		var id: String = record.get("id", "")
		var cues: Array = record.get("cues", [])
		assert_eq(cues.size(), 3, "%s: exactly 3 cues" % id)
		for cue in cues:
			assert_true(cue is String and not (cue as String).strip_edges().is_empty(),
				"%s: cue is a non-empty String" % id)
			assert_le(float((cue as String).length()), float(CUE_MAX_CHARS),
				"%s: cue <= %d chars" % [id, CUE_MAX_CHARS])
			assert_false((cue as String).contains("{"), "%s: no placeholder" % id)
		template_only += 1
	assert_eq(template_only, EXPECTED_COUNT, "every record was inspected")


func _test_cue_overrides() -> void:
	begin("data/cue_overrides.json parses with 60 priority ids that all resolve")
	var overrides_doc: Variant = _read_json(OVERRIDES_PATH)
	assert_true(overrides_doc is Dictionary, "%s parses" % OVERRIDES_PATH)
	if not (overrides_doc is Dictionary):
		return
	assert_eq(int(overrides_doc.get("schema_version", -1)), 1, "schema_version is 1")
	var overrides: Dictionary = overrides_doc.get("overrides", {})
	assert_eq(overrides.size(), 60, "exactly 60 priority overrides")
	_load_library_once()
	var unresolved: PackedStringArray = PackedStringArray()
	for id in overrides:
		var cues: Variant = overrides[id]
		assert_true(cues is Array and (cues as Array).size() == 3,
			"%s: exactly 3 override cues" % id)
		for cue in cues:
			assert_true(cue is String and not (cue as String).strip_edges().is_empty(),
				"%s: override cue non-empty" % id)
			assert_le(float((cue as String).length()), float(CUE_MAX_CHARS),
				"%s: override cue <= %d chars" % [id, CUE_MAX_CHARS])
		if not _by_id.has(id):
			unresolved.append(id)
	assert_eq(unresolved.size(), STAGE_A_EXCLUDED_PRIORITY.size(),
		"only the documented stage-A exclusion is outside the catalog: %s" % str(unresolved))
	assert_eq(unresolved, STAGE_A_EXCLUDED_PRIORITY,
		"the excluded priority id is exactly farmer-carry")

	# The override text must actually be the text in the library.
	for id in ["bench-press", "deadlift", "squat", "plank", "childs-pose"]:
		assert_eq(_by_id.get(id, {}).get("cues", []), overrides.get(id, []),
			"%s uses its hand-written override verbatim" % id)


# ---------------------------------------------------------------------------
# 10 · pattern table (PRD-05 consumes this)
# ---------------------------------------------------------------------------

func _test_pattern_table() -> void:
	begin("pattern_table.json has one entry per catalog id")
	var patterns: Variant = _read_json(PATTERNS_PATH)
	assert_true(patterns is Dictionary, "%s parses" % PATTERNS_PATH)
	if not (patterns is Dictionary):
		return
	assert_eq(int(patterns.get("schema_version", -1)), 1, "schema_version is 1")
	var table: Dictionary = patterns.get("patterns", {})
	assert_eq(table.size(), EXPECTED_COUNT, "204 pattern entries")
	_load_library_once()
	var keys: PackedStringArray = PackedStringArray()
	for key in table:
		keys.append(key)
	keys.sort()
	assert_eq(keys, _ids, "pattern_table keys == the library's ids")
	for id in table:
		assert_true((table[id] as String).length() > 0, "%s has a pattern" % id)


func _test_plan_fixture_refs() -> void:
	begin("every exercise id referenced by tests/fixtures resolves in the library")
	_load_library_once()
	if not FileAccess.file_exists(REFS_PATH):
		assert_true(true, "%s is not present yet — skipped" % REFS_PATH)
		return
	var refs: Variant = _read_json(REFS_PATH)
	assert_true(refs is Dictionary, "%s parses" % REFS_PATH)
	if not (refs is Dictionary):
		return
	var listed: Array = refs.get("exercise_ids", [])
	assert_not_empty(listed, "the fixture lists exercise ids")
	for id in listed:
		assert_true(_by_id.has(id), "%s resolves in the generated library" % id)


# ---------------------------------------------------------------------------
# R4 · the size budget
# ---------------------------------------------------------------------------

func _test_size_budget() -> void:
	begin("612 frames exist and the art payload is under the 8 MB ceiling")
	_load_library_once()
	var png_count := 0
	var total_bytes := 0
	var dir := DirAccess.open("res://assets/exercises")
	assert_true(dir != null, "assets/exercises exists")
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			var sub := DirAccess.open("res://assets/exercises/%s" % entry)
			if sub != null:
				sub.list_dir_begin()
				var file := sub.get_next()
				while file != "":
					if not sub.current_is_dir() and file.begins_with("frame-") and file.ends_with(".png"):
						png_count += 1
						total_bytes += _file_size("res://assets/exercises/%s/%s" % [entry, file])
					file = sub.get_next()
				sub.list_dir_end()
		entry = dir.get_next()
	dir.list_dir_end()

	assert_eq(png_count, EXPECTED_COUNT * FRAMES_PER_EXERCISE,
		"the frame file count is 3 x the exercise count")
	assert_eq(total_bytes, _total_frame_bytes,
		"the on-disk byte total agrees with the per-record sum")
	assert_le(float(total_bytes), float(SIZE_CEILING),
		"frame bytes %d <= %d" % [total_bytes, SIZE_CEILING])

	# The whole asset directory, `.import` siblings and notices included, is what
	# PRD-04 R4 puts the ceiling on.
	var payload := total_bytes
	payload += _file_size("res://assets/exercises/ATTRIBUTION.json")
	payload += _file_size("res://assets/exercises/LICENSE-ASSETS")
	payload += _total_import_bytes
	assert_le(float(payload), float(SIZE_CEILING),
		"assets/exercises payload %d <= %d" % [payload, SIZE_CEILING])
	print("      assets payload=%d bytes (%.2f MB) = frames %d + .import %d + notices %d"
		% [payload, float(payload) / 1048576.0, total_bytes, _total_import_bytes,
			payload - total_bytes - _total_import_bytes])


func _test_import_presets() -> void:
	begin("R13 — every frame has a sibling .import with detect_3d/compress_to=0")
	_load_library_once()
	var required: PackedStringArray = PackedStringArray([
		"detect_3d/compress_to=0",
		"mipmaps/generate=false",
		"compress/mode=0",
	])
	var imports := 0
	var problems: PackedStringArray = PackedStringArray()
	_total_import_bytes = 0
	for id in _ids:
		for index in range(1, FRAMES_PER_EXERCISE + 1):
			var path := "res://assets/exercises/%s/frame-%d.png.import" % [id, index]
			if not FileAccess.file_exists(path):
				problems.append("%s: missing" % path)
				continue
			imports += 1
			_total_import_bytes += _file_size(path)
			var text := FileAccess.get_file_as_string(path)
			for line in required:
				if not text.contains(line):
					problems.append("%s: no %s" % [path, line])
	assert_eq(imports, EXPECTED_COUNT * FRAMES_PER_EXERCISE, "612 .import files")
	assert_empty(problems, "every .import carries the R13 parameters: %s"
		% str(problems.slice(0, 5)))


# ---------------------------------------------------------------------------
# R15 · attribution
# ---------------------------------------------------------------------------

func _test_attribution_files() -> void:
	begin("attribution artifacts exist and list 68 upstream-derived frames")
	assert_true(FileAccess.file_exists(ATTRIBUTION_MD), "docs/ATTRIBUTION.md exists")
	assert_true(FileAccess.file_exists(LICENSE_ASSETS), "assets/exercises/LICENSE-ASSETS exists")
	var notice := FileAccess.get_file_as_string(ATTRIBUTION_MD)
	assert_true(notice.contains("CC BY-SA 4.0"), "ATTRIBUTION.md names the license")
	assert_true(notice.contains("bryllim.com"), "ATTRIBUTION.md names the creator")
	assert_true(notice.contains("everkinetic/data"), "ATTRIBUTION.md names the upstream")
	assert_true(notice.contains("ShareAlike"), "ATTRIBUTION.md states the ShareAlike obligation")
	var license_file := FileAccess.get_file_as_string(LICENSE_ASSETS)
	assert_true(license_file.contains("CC BY-SA 4.0"), "LICENSE-ASSETS names the license")
	assert_true(license_file.contains("Bryl Lim"), "LICENSE-ASSETS names Bryl Lim")

	var attribution: Variant = _read_json(ATTRIBUTION_JSON)
	assert_true(attribution is Dictionary, "%s parses" % ATTRIBUTION_JSON)
	if not (attribution is Dictionary):
		return
	assert_eq(int(attribution.get("schema_version", -1)), 1, "schema_version is 1")
	assert_eq(attribution.get("license", ""), "CC BY-SA 4.0", "license")
	assert_true(str(attribution.get("license_url", "")).contains("by-sa/4.0"),
		"license_url points at the CC BY-SA 4.0 deed")
	var assets: Array = attribution.get("assets", [])
	assert_eq(assets.size(), 68, "68 Everkinetic-derived frames")
	_load_library_once()
	for entry in assets:
		assert_true(_by_id.has(entry.get("id", "")), "%s is a catalog id" % entry.get("id", ""))
		assert_eq(int(entry.get("frame", 0)), 1, "%s: attribution is recorded on frame 1" % entry.get("id", ""))
		assert_eq(entry.get("upstream_name", ""), "Everkinetic", "upstream_name")
		assert_true(str(entry.get("upstream_url", "")).contains("everkinetic/data"),
			"upstream_url points at Everkinetic")
		assert_true(str(entry.get("changes", "")).contains("384"),
			"the changes note records the 384x384 downscale")


func _report_distribution() -> void:
	begin("distribution report")
	_load_library_once()
	var counts: Dictionary = {}
	for record in _library.get("exercises", []):
		for area in record.get("areas", []):
			counts[area] = int(counts.get(area, 0)) + 1
	var parts: PackedStringArray = PackedStringArray()
	for area in USER_AREAS:
		parts.append("%s=%d" % [area, int(counts.get(area, 0))])
	parts.append("mobility=%d" % int(counts.get("mobility", 0)))
	print("      count=%d frames=%d areas: %s"
		% [_ids.size(), EXPECTED_COUNT * FRAMES_PER_EXERCISE, " ".join(parts)])
	print("      frame_bytes=%d (%.2f MB, ceiling 8.00 MB)"
		% [_total_frame_bytes, float(_total_frame_bytes) / 1048576.0])
	assert_true(_total_frame_bytes > 0, "the frame byte total was measured")
	assert_le(float(_total_frame_bytes), float(SIZE_CEILING), "the measured art payload fits")
