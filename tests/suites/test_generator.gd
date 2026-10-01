extends TestSuite
## PRD-05 R4–R19 — the built-in deterministic generator, its goldens and its safety rails.
##
## Ten sections, mirroring R18: (1) pattern drift, (2) taxonomy drift, (3) golden files,
## (4) determinism, (5) weekly volume, (6) duration, (7) the 200-input safety sweep,
## (8) the notes filter, (9) the malformed-plan fixtures, (10) the reports/error paths.
##
## Everything runs against `res://data/exercise_library.json` through
## `Generator`/`PlanModel` only — no autoload, no scene tree, no `user://`. Golden files
## are regenerated **only** when `MW_REGEN_GOLDENS=1` (see `tools/run_tests.sh`):
##
##     MW_REGEN_GOLDENS=1 ~/Applications/godot --headless --path . \
##         --script res://tests/run_tests.gd

const FIXTURE_DIR := "res://tests/fixtures/"
const GOLDEN_SEED := 20260915
const GOLDEN_ID := "plan-1757941200"
const GOLDEN_CREATED_AT := "2026-09-15T12:00:00Z"
const FULL_GYM: PackedStringArray = ["barbell", "machine", "cable", "dumbbell", "bodyweight"]
const FUZZ_SEED := 4242
const FUZZ_INPUTS := 200
const LIBRARY_PATH := "res://data/exercise_library.json"
const PATTERN_TABLE := "res://tests/fixtures/pattern_table.json"

## R16 — the five committed golden scenarios, in file order.
const SCENARIOS: Array = [
	["2day_full_body", "general_fitness", 2, 30, ["chest", "back", "legs", "core"], FULL_GYM, ""],
	["4day_chest_back_legs_arms", "hypertrophy", 4, 40,
		["chest", "back", "shoulders", "arms", "core"], FULL_GYM, ""],
	["5day_chest_back_legs_arms_x2", "hypertrophy", 5, 45,
		["chest", "back", "shoulders", "arms", "legs", "core"], FULL_GYM, ""],
	["strength_goal", "strength", 3, 60, ["chest", "back", "legs", "core"], FULL_GYM, ""],
	["conditioning_goal", "conditioning", 4, 30, ["cardio", "legs", "core", "arms"],
		["dumbbell", "bodyweight", "cable", "machine"], "bad left shoulder, avoid overhead pressing"],
]

## R19 — the same six malformed plans the plan-model suite checks, asserted here too so
## the generator suite owns its own copy of the contract (R18 section 9).
const BAD_FIXTURES: Array = [
	["bad_plan_unknown_exercise.json", "unknown exercise_id"],
	["bad_plan_sets_zero.json", "sets out of range"],
	["bad_plan_reps_garbage.json", "unparseable reps"],
	["bad_plan_rest_too_long.json", "rest out of range"],
	["bad_plan_duplicate_exercise.json", "duplicate exercise"],
	["bad_plan_session_count_mismatch.json", "sessions"],
]

## R12 — one canned note string per removal rule (`no_barbell`/`machines_only` act on the
## equipment set rather than on a record list).
const NOTES_RULES: Array = [
	["shoulder_overhead", "bad shoulder"],
	["shoulder_rear", "sore rear delt"],
	["knee_loaded", "bad knee"],
	["knee_impact", "knee pain"],
	["lowback_spinal_load", "lower back pain"],
	["hip_groin", "tight hip"],
	["wrist_elbow", "wrist pain"],
	["neck", "stiff neck"],
	["prenatal", "prenatal"],
	["no_impact", "low impact"],
	["no_deadlift", "no deadlift"],
	["no_bench", "no bench"],
	["no_barbell", "dumbbells only"],
	["machines_only", "machines only"],
]

const FUZZ_NOTES: PackedStringArray = [
	"", "bad left shoulder", "sore lower back", "bad knee, no squats", "prenatal",
	"low impact", "wrist pain", "no barbell", "machines only", "stiff neck",
	"tight hips", "no bench", "no deadlift", "abs please", "glutes and posture",
	"arms and abs", "bad shoulder, bad knee, no barbell", "apartment, quiet",
	"rotator cuff impingement", "six pack and upper back",
]

const USER_AREAS: PackedStringArray = [
	"chest", "back", "shoulders", "arms", "core", "legs", "cardio",
]

var _catalog: Dictionary = {}
var _ids: PackedStringArray = PackedStringArray()
var _regenerate: bool = false


func _init() -> void:
	suite_name = "generator"


func run() -> void:
	_regenerate = OS.get_environment("MW_REGEN_GOLDENS") == "1"
	_load_catalog()
	_test_pattern_drift()
	_test_taxonomy_drift()
	_test_goldens()
	_test_determinism()
	_test_split_selection()
	_test_volume_targets()
	_test_duration()
	_test_safety_rails()
	_test_notes_filter()
	_test_malformed_fixtures()
	_test_reports_and_error_paths()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _load_catalog() -> void:
	if not _catalog.is_empty():
		return
	_catalog = PlanModel.load_catalog()
	_ids = PackedStringArray()
	for exercise_id in _catalog.keys():
		_ids.append(String(exercise_id))
	_ids.sort()


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _normalised(value: Variant) -> Variant:
	if value is float:
		var number := float(value)
		if is_finite(number) and number == floorf(number):
			return int(number)
		return number
	if value is Array:
		var out: Array = []
		for entry in value:
			out.append(_normalised(entry))
		return out
	if value is Dictionary:
		var mapped: Dictionary = {}
		for key in (value as Dictionary).keys():
			mapped[key] = _normalised((value as Dictionary)[key])
		return mapped
	return value


func _scenario_input(entry: Array) -> Dictionary:
	return {
		"goal": String(entry[1]),
		"days_per_week": int(entry[2]),
		"duration_min": int(entry[3]),
		"areas": entry[4],
		"equipment": entry[5],
		"notes": String(entry[6]),
		"id": GOLDEN_ID,
		"created_at": GOLDEN_CREATED_AT,
	}


func _golden_path(scenario: String) -> String:
	return "%sgolden_plan_%s.json" % [FIXTURE_DIR, scenario]


func _build(input: Dictionary, seed: int, catalog: Dictionary = {}) -> Dictionary:
	return Generator.build_plan(input, seed, catalog)


func _errors(plan: Dictionary) -> Array[String]:
	return PlanModel.plan_from_dict(plan).validate(_catalog)


func _fingerprint(value: Variant) -> String:
	return JSON.stringify(value, "", true)


func _contains(errors: Array[String], needle: String) -> bool:
	for error in errors:
		if error.contains(needle):
			return true
	return false


## A record clone for the synthetic catalogs used by the notes-filter never-rails.
func _record(source_id: String, id: String, areas: Array, muscle: String,
		equipment: String, sets: int) -> Dictionary:
	var record: Dictionary = (_catalog[source_id] as Dictionary).duplicate(true)
	record["id"] = id
	record["areas"] = areas
	record["primary_muscle"] = muscle
	record["secondary_muscles"] = []
	record["equipment"] = equipment
	record["is_stretch"] = false
	record["default_sets"] = sets
	record["exercise_type"] = "weight_reps"
	record["rep_min"] = 8
	record["rep_max"] = 12
	record["rest_seconds"] = 60
	return record


## R18(5)/(6) — 24 fixed inputs: six day-counts × four goals, rotating through four area
## sets (5, 4, 6 and all 7 areas) and three durations. Deterministic, not hand-picked.
func _fixed_inputs() -> Array:
	var goals: PackedStringArray = [
		"strength", "hypertrophy", "general_fitness", "conditioning"]
	var area_sets: Array = [
		["chest", "back", "shoulders", "arms", "core"],
		["chest", "back", "legs", "core"],
		["chest", "back", "shoulders", "arms", "legs", "core"],
		["chest", "back", "shoulders", "arms", "legs", "core", "cardio"],
	]
	var durations: PackedInt32Array = [30, 40, 45]
	var out: Array = []
	for days in range(1, 7):
		for goal_index in goals.size():
			out.append({
				"goal": goals[goal_index],
				"days_per_week": days,
				"duration_min": int(durations[(days + goal_index) % durations.size()]),
				"areas": area_sets[(days + goal_index) % area_sets.size()],
				"equipment": FULL_GYM,
				"notes": "",
				"id": "plan-1758000000",
				"created_at": GOLDEN_CREATED_AT,
			})
	return out


# ---------------------------------------------------------------------------
# 1 · pattern drift (R4)
# ---------------------------------------------------------------------------

func _test_pattern_drift() -> void:
	begin("classify() agrees with pattern_table.json on all 204 ids")
	var parsed: Variant = _read_json(PATTERN_TABLE)
	assert_true(parsed is Dictionary, "%s parses" % PATTERN_TABLE)
	if not (parsed is Dictionary):
		return
	var table: Dictionary = (parsed as Dictionary).get("patterns", {})
	assert_eq(table.size(), 204, "the fixture holds one pattern per catalog id")
	var mismatches: PackedStringArray = PackedStringArray()
	for exercise_id in _ids:
		var record: Dictionary = _catalog[exercise_id]
		var expected := String(table.get(exercise_id, "<missing>"))
		var actual := Generator.classify(exercise_id, bool(record.get("is_stretch", false)))
		if actual != expected:
			mismatches.append("%s: %s != %s" % [exercise_id, actual, expected])
	assert_empty(mismatches, "no classifier drift: %s" % str(mismatches.slice(0, 5)))
	assert_eq(Generator.classify("arm-circles", true), "mobility", "is_stretch wins")
	assert_eq(Generator.classify("not-a-real-id", false), "other", "an unknown id is `other`")

	begin("is_compound()/rank_for_ordering()")
	var bench: Dictionary = _catalog["bench-press"]
	assert_true(Generator.is_compound("bench-press", bench), "bench-press is compound")
	assert_eq(Generator.rank_for_ordering("squat"), 0, "squat sorts first")
	assert_eq(Generator.rank_for_ordering("lunge"), 1, "lunge is second")
	assert_eq(Generator.rank_for_ordering("core_anti"), 2, "core_anti is third")
	assert_eq(Generator.rank_for_ordering("arm_iso"), 3, "arm_iso is fourth")
	assert_eq(Generator.rank_for_ordering("core_flexion"), 4, "core_flexion is fifth")
	assert_eq(Generator.rank_for_ordering("cardio"), 5, "cardio is sixth")
	assert_eq(Generator.rank_for_ordering("other"), 6, "other is last")
	for exercise_id in _ids:
		var record: Dictionary = _catalog[exercise_id]
		var pattern := Generator.classify(exercise_id, bool(record.get("is_stretch", false)))
		assert_eq(bool(record.get("compound", false)),
			Generator.COMPOUND_PATTERNS.has(pattern),
			"%s: compound flag matches its pattern" % exercise_id)


# ---------------------------------------------------------------------------
# 2 · taxonomy drift (R1)
# ---------------------------------------------------------------------------

func _test_taxonomy_drift() -> void:
	begin("Taxonomy reproduces every library record's area list")
	var problems: PackedStringArray = PackedStringArray()
	var counts: Dictionary = {}
	for exercise_id in _ids:
		var record: Dictionary = _catalog[exercise_id]
		var derived := Taxonomy.areas_for_record(record)
		if derived != PackedStringArray(record.get("areas", [])):
			problems.append("%s: %s != %s" % [exercise_id, str(derived), str(record.get("areas", []))])
		if Taxonomy.primary_area(record) != String((record.get("areas", []) as Array)[0]):
			problems.append("%s: primary_area != areas[0]" % exercise_id)
		if Taxonomy.area_for_muscle(String(record.get("primary_muscle", ""))) \
				!= String((record.get("areas", []) as Array)[0]):
			problems.append("%s: primary_muscle maps elsewhere" % exercise_id)
		var expected_secondary: Array = []
		var areas: Array = record.get("areas", [])
		for index in range(1, areas.size()):
			expected_secondary.append(String(areas[index]))
		if Taxonomy.secondary_areas(record) != PackedStringArray(expected_secondary):
			problems.append("%s: secondary_areas != areas[1..]" % exercise_id)
		for area in areas:
			counts[String(area)] = int(counts.get(String(area), 0)) + 1
	assert_empty(problems, "no taxonomy drift: %s" % str(problems.slice(0, 5)))

	begin("all 7 user areas have >= 12 records and mobility stays reserved")
	for area in USER_AREAS:
		assert_ge(float(counts.get(area, 0)), 12.0, "area %s has >= 12 records" % area)
		assert_true(Taxonomy.is_user_area(area), "%s is a user area" % area)
	assert_false(Taxonomy.is_user_area(Taxonomy.RESERVED_AREA), "mobility is not selectable")
	assert_eq(counts.get("mobility", 0), 13, "13 mobility (stretch) records")
	assert_eq(Taxonomy.label("core"), "Core / Abs", "labels come from §6.1")
	assert_eq(Taxonomy.label("mobility"), "Mobility", "the reserved label exists")
	assert_eq(Taxonomy.label("nope"), "nope", "an unknown area falls back to its key")
	assert_eq(Taxonomy.area_for_muscle("Posterior Chain"), "back", "R33 mapping")
	assert_eq(Taxonomy.area_for_muscle("Adductors"), "legs", "R33 mapping")
	assert_eq(Taxonomy.area_for_muscle("Groin"), "legs", "R33 mapping")
	assert_eq(Taxonomy.area_for_muscle("Nope"), "", "an unknown muscle is empty")


# ---------------------------------------------------------------------------
# 3 · golden files (R16)
# ---------------------------------------------------------------------------

func _test_goldens() -> void:
	var changed: PackedStringArray = PackedStringArray()
	for entry in SCENARIOS:
		var scenario := String(entry[0])
		var input := _scenario_input(entry)
		var path := _golden_path(scenario)
		var plan := _build(input, GOLDEN_SEED)
		var volume := Generator.volume_table(plan, _catalog)
		var digest := _fingerprint(plan).sha256_text()

		if _regenerate:
			var document: Dictionary = {
				"schema_version": 1,
				"scenario": scenario,
				"seed": GOLDEN_SEED,
				"expected_plan_sha256": digest,
				"input": input,
				"expected_plan": _normalised(plan),
				"expected_volume": _normalised(volume),
			}
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_string(JSON.stringify(document, "  ", true) + "\n")
				file.close()
				changed.append(scenario)
			else:
				print("      REGEN FAILED for %s" % path)
			continue

		begin("%s reproduces its golden bytes" % scenario)
		var parsed: Variant = _read_json(path)
		assert_true(parsed is Dictionary, "%s exists and parses" % path)
		if not (parsed is Dictionary):
			continue
		var golden: Dictionary = parsed
		assert_eq(int(golden.get("seed", 0)), GOLDEN_SEED, "the golden records its seed")
		assert_eq(golden.get("scenario", ""), scenario, "the golden names its scenario")
		var expected_plan: Dictionary = _normalised(golden.get("expected_plan", {}))
		assert_eq(_fingerprint(plan), _fingerprint(expected_plan),
			"build_plan(input, seed) is byte-identical to expected_plan")
		assert_eq(String(golden.get("expected_plan_sha256", "")), digest,
			"the recorded sha256 matches")
		var errors := _errors(plan)
		assert_empty(errors, "the golden plan validates: %s" % str(errors))
		var expected_volume: Dictionary = _normalised(golden.get("expected_volume", {}))
		assert_eq(_fingerprint(volume), _fingerprint(expected_volume),
			"volume_table(plan) equals expected_volume")
		var round_trip := PlanModel.plan_from_dict(expected_plan).to_dict()
		assert_eq(_fingerprint(round_trip), _fingerprint(expected_plan),
			"plan_from_dict/to_dict round-trips the golden")

	if _regenerate:
		print("      REGEN wrote %d golden files: %s"
			% [changed.size(), ", ".join(changed)])
		assert_gt(float(changed.size()), 0.0, "regeneration wrote the golden files")


# ---------------------------------------------------------------------------
# 4 · determinism (R14)
# ---------------------------------------------------------------------------

func _test_determinism() -> void:
	begin("same input + seed is byte-identical, a different seed differs")
	for entry in SCENARIOS:
		var scenario := String(entry[0])
		var input := _scenario_input(entry)
		var first := _fingerprint(_build(input, GOLDEN_SEED))
		var second := _fingerprint(_build(input, GOLDEN_SEED))
		assert_eq(first, second, "%s: two in-process builds are identical" % scenario)
		var other := _fingerprint(_build(input, GOLDEN_SEED + 1))
		assert_ne(first, other, "%s: the seed actually matters" % scenario)
		var reordered := _scenario_input(entry)
		reordered["areas"] = (reordered["areas"] as Array).duplicate()
		reordered["areas"].reverse()
		assert_ne(_fingerprint(_build(reordered, GOLDEN_SEED)), first,
			"%s: a different area order is a different plan" % scenario)

	begin("build_plan never mutates its input")
	var input := _scenario_input(SCENARIOS[1])
	var before := _fingerprint(input)
	_build(input, GOLDEN_SEED)
	assert_eq(_fingerprint(input), before, "the input dictionary is untouched")

	begin("injected catalogs are deterministic too")
	var injected := _build(_scenario_input(SCENARIOS[0]), GOLDEN_SEED, _catalog)
	assert_eq(_fingerprint(injected), _fingerprint(_build(_scenario_input(SCENARIOS[0]), GOLDEN_SEED)),
		"a raw {id: record} catalog behaves like the shipped one")
	var raw: Dictionary = {"exercises": []}
	for exercise_id in _ids:
		raw["exercises"].append(_catalog[exercise_id])
	assert_eq(_fingerprint(_build(_scenario_input(SCENARIOS[0]), GOLDEN_SEED, raw)),
		_fingerprint(injected), "a raw library document behaves like the id map")


# ---------------------------------------------------------------------------
# 5 · split selection (R6/R7)
# ---------------------------------------------------------------------------

func _test_split_selection() -> void:
	begin("the split table of R6 is followed for 1–6 days")
	var expectations: Array = [
		[1, "Full Body", ["Full Body A"]],
		[2, "Full Body A / B", ["Full Body A", "Full Body B"]],
		[3, "Chest & Back / Legs & Arms / Shoulders & Core",
			["Chest & Back", "Legs & Arms", "Shoulders & Core"]],
		[4, "Chest & Back ×2 / Legs & Arms / Shoulders & Core",
			["Chest & Back A", "Legs & Arms", "Shoulders & Core", "Chest & Back B"]],
		[5, "Chest & Back ×2 / Legs & Arms ×2 / Shoulders & Core",
			["Chest & Back A", "Legs & Arms A", "Shoulders & Core",
				"Chest & Back B", "Legs & Arms B"]],
		[6, "Chest & Back ×2 / Legs & Arms ×2 / Shoulders & Core ×2",
			["Chest & Back A", "Legs & Arms A", "Shoulders & Core A",
				"Chest & Back B", "Legs & Arms B", "Shoulders & Core B"]],
	]
	for row in expectations:
		var days := int(row[0])
		var plan := _build({
			"goal": "hypertrophy", "days_per_week": days, "duration_min": 40,
			"areas": ["chest", "back", "shoulders", "arms", "core"], "equipment": FULL_GYM,
			"notes": "", "id": GOLDEN_ID, "created_at": GOLDEN_CREATED_AT,
		}, GOLDEN_SEED)
		assert_eq(plan.get("split_name", ""), String(row[1]), "days=%d split_name" % days)
		var titles: Array = []
		for session in plan.get("sessions", []):
			titles.append(String((session as Dictionary).get("title", "")))
		assert_eq(titles, row[2], "days=%d session titles" % days)
		assert_eq((plan.get("sessions", []) as Array).size(), days, "days=%d session count" % days)

	begin("no area is trained on two consecutive sessions (owner request)")
	for days in [3, 4, 5, 6]:
		var plan := _build({
			"goal": "hypertrophy", "days_per_week": days, "duration_min": 40,
			"areas": ["chest", "back", "shoulders", "arms", "core", "legs", "cardio"],
			"equipment": FULL_GYM, "notes": "",
			"id": GOLDEN_ID, "created_at": GOLDEN_CREATED_AT,
		}, GOLDEN_SEED)
		var sessions: Array = plan.get("sessions", [])
		var clean := true
		for index in range(sessions.size() - 1):
			var left := PackedStringArray()
			var right := PackedStringArray()
			for area in (sessions[index] as Dictionary).get("focus", []):
				if String(area) != "cardio":
					left.append(String(area))
			for area in (sessions[index + 1] as Dictionary).get("focus", []):
				if String(area) != "cardio":
					right.append(String(area))
			for area in left:
				if right.has(area):
					clean = false
		assert_true(clean, "days=%d: consecutive sessions share no area" % days)

	begin("the 3-day conditional is evaluated on the selected-area count")
	var three_areas := _build({"goal": "hypertrophy", "days_per_week": 3, "duration_min": 40,
		"areas": ["chest", "back", "legs"], "equipment": FULL_GYM, "notes": "",
		"id": GOLDEN_ID, "created_at": GOLDEN_CREATED_AT}, GOLDEN_SEED)
	assert_eq(three_areas.get("split_name", ""), "Full Body ×3",
		"3 areas => Full Body ×3")
	var four_areas := _build({"goal": "hypertrophy", "days_per_week": 3, "duration_min": 40,
		"areas": ["chest", "back", "legs", "core"], "equipment": FULL_GYM, "notes": "",
		"id": GOLDEN_ID, "created_at": GOLDEN_CREATED_AT}, GOLDEN_SEED)
	assert_eq(four_areas.get("split_name", ""),
		"Chest & Back / Legs & Arms / Shoulders & Core",
		"4 areas => the three body-part days")

	begin("focus is the pool ∩ the user's areas, cardio always last")
	var plan := _build({"goal": "hypertrophy", "days_per_week": 4, "duration_min": 40,
		"areas": ["chest", "back", "legs", "cardio"], "equipment": FULL_GYM, "notes": "",
		"id": GOLDEN_ID, "created_at": GOLDEN_CREATED_AT}, GOLDEN_SEED)
	for session in plan.get("sessions", []):
		var focus: Array = (session as Dictionary).get("focus", [])
		assert_gt(float(focus.size()), 0.0, "every focus names at least one area")
		assert_eq(String(focus[focus.size() - 1]), "cardio", "cardio is the last focus entry")
		assert_eq(focus.count("cardio"), 1, "cardio appears exactly once per session")
	for area in plan.get("areas", []):
		var covered := false
		for session in plan.get("sessions", []):
			if ((session as Dictionary).get("focus", []) as Array).has(String(area)):
				covered = true
		assert_true(covered, "selected area %s is covered by a session" % area)

	begin("a split that cannot host a selected area is relaxed to Full Body")
	var relaxed := _build({"goal": "hypertrophy", "days_per_week": 4, "duration_min": 40,
		"areas": ["chest", "shoulders"], "equipment": FULL_GYM, "notes": "",
		"id": GOLDEN_ID, "created_at": GOLDEN_CREATED_AT}, GOLDEN_SEED)
	assert_eq(relaxed.get("split_name", ""), "Full Body ×4", "the relaxed split name")
	assert_empty(_errors(relaxed), "the relaxed plan still validates")


# ---------------------------------------------------------------------------
# 6 · weekly volume and the corrected floor (R9)
# ---------------------------------------------------------------------------

func _test_volume_targets() -> void:
	begin("weekly_floor is the corrected formula and the table reports it")
	var shortfall_areas := 0
	var area_rows := 0
	var inputs := _fixed_inputs()
	for index in inputs.size():
		var input: Dictionary = inputs[index]
		var plan := _build(input, 700 + index)
		var days := int(input["days_per_week"])
		var areas: Array = input["areas"]
		var available := int(input["duration_min"]) * 60 - 480
		var set_target := clampi(roundi(float(available) / 150.0), 8, 40)
		var expected_floor := mini(10, floori(float(days * set_target) / float(areas.size())))
		var floors := Generator.weekly_floor(plan)
		var table := Generator.volume_table(plan, _catalog)
		var short := Generator.volume_shortfalls(plan, _catalog)
		assert_eq(floors.size(), areas.size(), "one floor per selected area")
		for area in areas:
			var key := String(area)
			assert_eq(int(floors[key]), expected_floor,
				"floor(%s) for days=%d areas=%d" % [key, days, areas.size()])
			assert_has_key(table, key, "the volume table has a row for %s" % key)
			var row: Dictionary = table[key]
			assert_has_key(row, "direct", "%s.direct" % key)
			assert_has_key(row, "effective", "%s.effective" % key)
			assert_has_key(row, "target", "%s.target" % key)
			assert_has_key(row, "cap", "%s.cap" % key)
			assert_has_key(row, "coverage", "%s.coverage" % key)
			assert_eq(int(row["cap"]), 22, "%s.cap is WEEKLY_MAX_SETS" % key)
			assert_ge(float(row["coverage"]), 1.0, "%s is covered by a session" % key)
			assert_le(float(row["effective"]), 22.0, "%s.effective <= 22" % key)
			assert_le(float(row["direct"]), 22.0, "%s.direct <= 22" % key)
			assert_ge(float(row["target"]), 10.0, "%s.target >= WEEKLY_MIN_SETS" % key)
			# A shortfall is reported exactly when an R9 invariant is missed.
			var missed := float(row["effective"]) < float(floors[key]) \
				or int(row["direct"]) < Generator.DIRECT_FLOOR
			assert_eq(short.has(key), missed,
				"%s: a shortfall is reported iff the floor is missed (%s)" % [key, str(row)])
			if missed:
				shortfall_areas += 1
			area_rows += 1
	print("      volume: %d selected-area rows, %d below the corrected floor or DIRECT_FLOOR"
		% [area_rows, shortfall_areas])

	begin("secondary involvement counts at 0.5 in effective")
	var plan := _build(_scenario_input(SCENARIOS[1]), GOLDEN_SEED)
	var table := Generator.volume_table(plan, _catalog)
	var direct: Dictionary = {}
	var secondary: Dictionary = {}
	for session in plan.get("sessions", []):
		for block in (session as Dictionary).get("blocks", []):
			var record: Dictionary = _catalog[String((block as Dictionary)["exercise_id"])]
			var sets := int((block as Dictionary)["sets"])
			var primary := Taxonomy.primary_area(record)
			direct[primary] = int(direct.get(primary, 0)) + sets
			for area in Taxonomy.secondary_areas(record):
				secondary[area] = int(secondary.get(area, 0)) + sets
	for area in table.keys():
		var expected := float(int(direct.get(area, 0))) + 0.5 * float(int(secondary.get(area, 0)))
		assert_close(float((table[area] as Dictionary)["effective"]), expected, 0.0001,
			"%s.effective == direct + 0.5 x secondary" % area)


# ---------------------------------------------------------------------------
# 7 · duration (R8)
# ---------------------------------------------------------------------------

func _test_duration() -> void:
	begin("duration lands in the ±15 % window unless the weekly volume cap binds")
	var inputs := _fixed_inputs()
	var compliant := 0
	var cap_bound_misses := 0
	for index in inputs.size():
		var input: Dictionary = inputs[index]
		var plan := _build(input, 700 + index)
		var requested := int(input["duration_min"])
		var misses := Generator.duration_misses(plan)
		var table := Generator.volume_table(plan, _catalog)
		var cap_bound := false
		for area in input["areas"]:
			if int((table.get(String(area), {}) as Dictionary).get("effective", 0)) >= 22:
				cap_bound = true
		for session in plan.get("sessions", []):
			var entry: Dictionary = session
			var est := int(entry["est_minutes"])
			var session_id := String(entry["id"])
			var inside := float(est) >= 0.85 * float(requested) \
				and float(est) <= 1.05 * float(requested)
			if inside:
				assert_false(misses.has(session_id),
					"an in-window session is not reported as a miss")
				continue
			assert_true(misses.has(session_id),
				"%s est=%d is reported by duration_misses()" % [session_id, est])
			assert_close(float(misses[session_id]),
				100.0 * (float(est) - float(requested)) / float(requested), 0.05,
				"%s: the reported delta matches" % session_id)
			if cap_bound:
				cap_bound_misses += 1
			else:
				assert_true(false,
					"%s est=%d is outside the window for %s days=%d areas=%d without the cap binding"
					% [session_id, est, input["goal"], int(input["days_per_week"]),
						(input["areas"] as Array).size()])
		if misses.is_empty():
			compliant += 1
	print("      duration: %d/%d fixed inputs fully inside the window; %d cap-bound misses logged"
		% [compliant, inputs.size(), cap_bound_misses])
	assert_gt(float(compliant), 0.0, "at least some fixed inputs are fully compliant")
	assert_gt(float(cap_bound_misses), 0.0,
		"the cap-bound cases exist and are logged, not silently missed")

	begin("the upper bound can never be violated by the session budget")
	for index in inputs.size():
		var input: Dictionary = inputs[index]
		var plan := _build(input, 800 + index)
		for session in plan.get("sessions", []):
			var est := int((session as Dictionary)["est_minutes"])
			assert_le(float(est), 1.05 * float(input["duration_min"]),
				"est %d <= 1.05 x %d" % [est, int(input["duration_min"])])


# ---------------------------------------------------------------------------
# 8 · safety rails over 200 randomized inputs (R18 section 7)
# ---------------------------------------------------------------------------

func _test_safety_rails() -> void:
	begin("200 randomized inputs: every safety rail holds")
	var rng := RandomNumberGenerator.new()
	rng.seed = FUZZ_SEED
	var durations: PackedInt32Array = [15, 20, 30, 40, 60, 90]
	var equipment_keys: PackedStringArray = FULL_GYM
	var verbose := OS.get_environment("MW_GEN_VERBOSE") == "1"
	var failures: PackedStringArray = PackedStringArray()
	var ok := 0
	var rebuilt := 0
	for round_index in FUZZ_INPUTS:
		var areas: Array = []
		for area in USER_AREAS:
			if rng.randf() < 0.45:
				areas.append(String(area))
		if areas.is_empty():
			areas.append(String(USER_AREAS[rng.randi_range(0, USER_AREAS.size() - 1)]))
		var equipment: Array = []
		for key in equipment_keys:
			if rng.randf() < 0.7:
				equipment.append(String(key))
		if equipment.is_empty():
			equipment.append("bodyweight")
		var input: Dictionary = {
			"goal": PlanModel.GOALS[rng.randi_range(0, PlanModel.GOALS.size() - 1)],
			"days_per_week": rng.randi_range(1, 6),
			"duration_min": int(durations[rng.randi_range(0, durations.size() - 1)]),
			"areas": areas,
			"equipment": equipment,
			"notes": String(FUZZ_NOTES[rng.randi_range(0, FUZZ_NOTES.size() - 1)]),
			"id": GOLDEN_ID,
			"created_at": GOLDEN_CREATED_AT,
		}
		var seed := 900000 + round_index
		var plan := _build(input, seed)
		if plan.has("error"):
			failures.append("input %d returned %s" % [round_index, str(plan)])
			continue
		var errors := _errors(plan)
		if not errors.is_empty():
			failures.append("input %d failed validation: %s" % [round_index, str(errors)])
		if (plan.get("sessions", []) as Array).size() != int(input["days_per_week"]):
			failures.append("input %d has the wrong session count" % round_index)
		for session in plan.get("sessions", []):
			var entry: Dictionary = session
			var blocks: Array = entry.get("blocks", [])
			var warmup: Array = entry.get("warmup", [])
			if blocks.is_empty():
				failures.append("input %d: a session has 0 blocks" % round_index)
			if blocks.size() > Generator.MAX_BLOCKS:
				failures.append("input %d: a session has %d blocks" % [round_index, blocks.size()])
			if warmup.is_empty():
				failures.append("input %d: a session has no warm-up" % round_index)
			var seen: Dictionary = {}
			var previous := ""
			for block in blocks:
				var block_dict: Dictionary = block
				var exercise_id := String(block_dict["exercise_id"])
				if seen.has(exercise_id):
					failures.append("input %d: %s is used twice" % [round_index, exercise_id])
				seen[exercise_id] = true
				var record: Dictionary = _catalog.get(exercise_id, {})
				if record.is_empty():
					failures.append("input %d: %s is not in the library" % [round_index, exercise_id])
					continue
				var muscle := String(record["primary_muscle"])
				if muscle == previous:
					failures.append("input %d: V21 adjacent %s" % [round_index, muscle])
				previous = muscle
		var rebuild := _fingerprint(_build(input, seed))
		if rebuild != _fingerprint(plan):
			failures.append("input %d is not reproducible" % round_index)
		else:
			rebuilt += 1
		ok += 1
		if verbose:
			print("      fuzz ok %d" % round_index)
	assert_empty(failures, "the 200-input sweep found no rail violation: %s"
		% str(failures.slice(0, 5)))
	assert_eq(ok, FUZZ_INPUTS, "every randomized input produced a plan")
	assert_eq(rebuilt, FUZZ_INPUTS, "every plan was byte-reproducible")
	print("      fuzz: %d inputs, 0 rail violations, %d byte-identical rebuilds"
		% [ok, rebuilt])


# ---------------------------------------------------------------------------
# 9 · the notes keyword filter (R12)
# ---------------------------------------------------------------------------

func _test_notes_filter() -> void:
	begin("each of the 14 rules removes candidates and leaves a valid plan")
	var vacuous: PackedStringArray = PackedStringArray()
	for entry in NOTES_RULES:
		var rule_id := String(entry[0])
		var note := String(entry[1])
		var report := Generator.notes_filter_report({
			"notes": note, "areas": USER_AREAS, "equipment": FULL_GYM,
		}, _catalog)
		assert_true((report["matched_rules"] as Array).has(rule_id),
			"'%s' matches rule %s (got %s)" % [note, rule_id, str(report["matched_rules"])])
		# How many catalog records this rule can even target. `_rule_removes()` is called
		# directly on purpose: it is the single source of the R12 table, and a rule whose
		# predicate matches nothing in the shipped 204 records is a data fact worth
		# reporting (today: `hip_groin`, because no lunge record uses a Barbell).
		# The two equipment rules act on the wizard's equipment set, not on records.
		if rule_id == "no_barbell" or rule_id == "machines_only":
			assert_true((report["equipment"] as Array).size() < FULL_GYM.size(),
				"%s narrows the equipment set (got %s)" % [rule_id, str(report["equipment"])])
			assert_false((report["equipment"] as Array).has("barbell"),
				"%s drops barbell" % rule_id)
			continue
		var targets := 0
		for exercise_id in _ids:
			if Generator._rule_removes(rule_id, _catalog[exercise_id]):
				targets += 1
		if targets == 0:
			# Cannot fire against the shipped catalog at all — a data fact, reported.
			vacuous.append(rule_id)
			continue
		assert_true(int(report["removed_count"]) > 0,
			"%s changed the candidate pool (%d targets)" % [rule_id, targets])
		assert_false(bool(report["disabled"]), "%s did not disable the filter" % rule_id)
		var plan := _build({
			"goal": "hypertrophy", "days_per_week": 4, "duration_min": 40,
			"areas": ["chest", "back", "shoulders", "arms", "core", "legs", "cardio"],
			"equipment": FULL_GYM, "notes": note, "id": GOLDEN_ID,
			"created_at": GOLDEN_CREATED_AT,
		}, GOLDEN_SEED)
		var errors := _errors(plan)
		assert_empty(errors, "'%s' still yields a valid plan: %s" % [note, str(errors)])

	print("      notes filter: %d removal rules matched; no target in this catalog: %s"
		% [NOTES_RULES.size(), ("none" if vacuous.is_empty() else ", ".join(vacuous))])

	begin("the notes filter is a no-op when notes are empty")
	var empty_report := Generator.notes_filter_report({
		"notes": "", "areas": USER_AREAS, "equipment": FULL_GYM}, _catalog)
	assert_eq(int(empty_report["removed_count"]), 0, "nothing was removed")
	assert_empty(empty_report["matched_rules"], "no rule matched")
	assert_eq((empty_report["equipment"] as Array).size(), FULL_GYM.size(),
		"the equipment set is untouched")

	begin("the boost rules raise a target but never guarantee it")
	var boosted := Generator.notes_filter_report({"notes": "big glutes and a six pack",
		"areas": USER_AREAS, "equipment": FULL_GYM}, _catalog)
	assert_close(float((boosted["boosts"] as Dictionary).get("legs", 1.0)), 1.5, 0.0001,
		"glutes boosts legs x1.5")
	assert_close(float((boosted["boosts"] as Dictionary).get("core", 1.0)), 1.5, 0.0001,
		"six pack boosts core x1.5")
	var boosted_plan := _build({"goal": "hypertrophy", "days_per_week": 4, "duration_min": 40,
		"areas": ["legs", "core"], "equipment": FULL_GYM, "notes": "big glutes, six pack",
		"id": GOLDEN_ID, "created_at": GOLDEN_CREATED_AT}, GOLDEN_SEED)
	assert_empty(_errors(boosted_plan), "a boosted plan still validates")

	begin("never-rail: a rule that would leave an area with < 3 candidates is rolled back")
	var tiny: Dictionary = {
		"squat-a": _record("goblet-squat", "squat-a", ["legs"], "Quads", "Barbell", 3),
		"squat-b": _record("goblet-squat", "squat-b", ["legs"], "Quads", "Barbell", 3),
		"squat-c": _record("goblet-squat", "squat-c", ["legs"], "Quads", "Machine", 3),
		"squat-d": _record("goblet-squat", "squat-d", ["legs"], "Quads", "Barbell", 3),
		"bodyweight-squat": _record("goblet-squat", "bodyweight-squat", ["legs"], "Quads",
			"Bodyweight", 3),
	}
	var rolled := Generator.notes_filter_report({"notes": "bad knee", "areas": ["legs"],
		"equipment": FULL_GYM}, tiny)
	assert_eq((rolled["rollbacks"] as Array).size(), 1,
		"one rollback recorded: %s" % str(rolled["rollbacks"]))
	assert_eq(String((rolled["rollbacks"] as Array)[0]["area"]), "legs", "the rolled-back area")
	assert_eq(String((rolled["rollbacks"] as Array)[0]["rule"]), "knee_loaded", "the rule")
	assert_eq(int(rolled["removed_count"]), 0, "nothing stayed removed")

	begin("never-rail: a rule set that still empties an area is dropped entirely")
	var barbell_only: Dictionary = {
		"bench-a": _record("bench-press", "bench-a", ["chest"], "Chest", "Barbell", 3),
	}
	var dropped := Generator.notes_filter_report({"notes": "dumbbells only",
		"areas": ["chest"], "equipment": FULL_GYM}, barbell_only)
	assert_true(bool(dropped["disabled"]), "the filter was disabled")
	assert_eq(int(dropped["removed_count"]), 0, "no removal survives")
	assert_eq((dropped["equipment"] as Array).size(), FULL_GYM.size(),
		"the equipment restriction was rolled back too")

	begin("the rollback case from R18 still validates")
	var knee_plan := _build({"goal": "hypertrophy", "days_per_week": 4, "duration_min": 40,
		"areas": ["legs", "core"], "equipment": FULL_GYM,
		"notes": "bad left knee, no squats, no lunges, no legs", "id": GOLDEN_ID,
		"created_at": GOLDEN_CREATED_AT}, GOLDEN_SEED)
	var knee_errors := _errors(knee_plan)
	assert_empty(knee_errors, "the legacy-sounding note still produces a valid plan: %s"
		% str(knee_errors))
	assert_gt(float((knee_plan["sessions"] as Array).size()), 0.0, "sessions were built")


# ---------------------------------------------------------------------------
# 10 · malformed fixtures and the report surface
# ---------------------------------------------------------------------------

func _test_malformed_fixtures() -> void:
	for entry in BAD_FIXTURES:
		var file_name := String(entry[0])
		var needle := String(entry[1])
		begin("%s is rejected with '%s'" % [file_name, needle])
		var parsed: Variant = _read_json(FIXTURE_DIR + file_name)
		assert_true(parsed is Dictionary, "%s parses" % file_name)
		if not (parsed is Dictionary):
			continue
		var errors := PlanModel.plan_from_dict(parsed).validate(_catalog)
		assert_gt(float(errors.size()), 0.0, "%s is rejected" % file_name)
		assert_true(_contains(errors, needle), "the error mentions '%s': %s"
			% [needle, str(errors)])
		print("      %s rejected: %s" % [file_name, errors[0]])


func _test_reports_and_error_paths() -> void:
	begin("build_plan clamps out-of-range scalars instead of rejecting them")
	var clamped := _build({"goal": "general", "days_per_week": 9, "duration_min": 200,
		"areas": ["chest", "nope"], "equipment": [], "notes": "",
		"id": GOLDEN_ID, "created_at": GOLDEN_CREATED_AT}, GOLDEN_SEED)
	assert_eq(clamped.get("goal", ""), "general_fitness", "goal 'general' is canonicalised")
	assert_eq(clamped.get("days_per_week", 0), 6, "days_per_week clamps to 6")
	assert_eq(clamped.get("duration_min", 0), 90, "duration_min clamps to 90")
	assert_eq(clamped.get("areas", []), ["chest"], "an unknown area is dropped")
	assert_eq((clamped.get("equipment", []) as Array).size(), 5, "empty equipment becomes all 5")
	var too_few := _build({"goal": "strength", "days_per_week": 0, "duration_min": 3,
		"areas": ["back"], "equipment": FULL_GYM, "notes": "", "id": GOLDEN_ID,
		"created_at": GOLDEN_CREATED_AT}, GOLDEN_SEED)
	assert_eq(too_few.get("days_per_week", 0), 1, "days_per_week clamps up to 1")
	assert_eq(too_few.get("duration_min", 0), 15, "duration_min clamps up to 15")

	begin("the documented error results")
	assert_eq(_build({"areas": []}, 1), {"error": "no areas"}, "an empty area list is an error")
	assert_eq(_build({"areas": ["mobility"]}, 1), {"error": "no areas"},
		"the reserved area is not a user area")
	assert_eq(_build({"areas": ["chest"]}, 1, {"x": 1}), {"error": "library_not_loaded"},
		"an unusable catalog is an error, not a crash")

	begin("volume_table is a pure function of the plan document")
	var plan := _build(_scenario_input(SCENARIOS[2]), GOLDEN_SEED)
	var first := _fingerprint(Generator.volume_table(plan))
	var copy := PlanModel.plan_from_dict(plan).to_dict()
	assert_eq(_fingerprint(Generator.volume_table(copy)), first,
		"a round-tripped plan yields the same table")
	assert_eq(_fingerprint(Generator.weekly_floor(plan)), _fingerprint(Generator.weekly_floor(copy)),
		"and the same floor table")
	assert_eq(Generator.volume_table({"areas": []}), {},
		"a plan without areas has no table")

	begin("equipment_key maps the library spellings")
	var expected := {
		"Barbell": "barbell", "Dumbbell": "dumbbell", "Cable": "cable",
		"Machine": "machine", "Bodyweight": "bodyweight", "Pull-up Bar": "bodyweight",
		"Box": "bodyweight", "Bench": "barbell", "Plate": "barbell", "Cardio": "machine",
	}
	for clothing in expected.keys():
		assert_eq(Generator.equipment_key({"equipment": String(clothing)}),
			String(expected[clothing]), "%s maps to %s" % [clothing, expected[clothing]])

	begin("warm-up and cooldown are 3 + 3 distinct stretches of 60 s")
	var stretches: PackedStringArray = PackedStringArray()
	for exercise_id in _ids:
		if bool((_catalog[exercise_id] as Dictionary).get("is_stretch", false)):
			stretches.append(exercise_id)
	assert_eq(stretches.size(), 13, "13 stretch records in the catalog")
	var warm_sets: Array = []
	for entry in SCENARIOS:
		var scenario_plan := _build(_scenario_input(entry), GOLDEN_SEED)
		for session in scenario_plan.get("sessions", []):
			var payload: Dictionary = session
			var warmup: Array = payload["warmup"]
			var cooldown: Array = payload["cooldown"]
			assert_eq(warmup.size(), Generator.WARMUP_ITEMS, "3 warm-up items")
			assert_eq(cooldown.size(), Generator.COOLDOWN_ITEMS, "3 cooldown items")
			var seen: Dictionary = {}
			for item in warmup + cooldown:
				var item_dict: Dictionary = item
				var exercise_id := String(item_dict["exercise_id"])
				assert_true(stretches.has(exercise_id),
					"%s is one of the 13 stretches" % exercise_id)
				assert_false(seen.has(exercise_id), "%s appears once per session" % exercise_id)
				seen[exercise_id] = true
				assert_eq(int(item_dict["duration_sec"]), 60, "60 s per mobility item")
			warm_sets.append(_fingerprint(warmup))
	# Sessions of one plan must differ; the first session of two plans may repeat.
	assert_gt(float(warm_sets.size()), 6.0, "mobility picks were collected")
	var unique: Dictionary = {}
	for signature in warm_sets:
		unique[signature] = true
	assert_gt(float(unique.size()), 1.0, "the warm-up rotation produces variety")

	begin("notes_filter_report has a stable shape")
	var report := Generator.notes_filter_report({"notes": "bad knee", "areas": ["legs"],
		"equipment": FULL_GYM}, _catalog)
	for key in ["notes", "matched_rules", "removed", "removed_count", "equipment", "boosts",
			"rollbacks", "disabled"]:
		assert_has_key(report, key, "notes_filter_report.%s" % key)
	assert_eq(report.get("notes", ""), "bad knee", "the note is echoed verbatim")
	assert_true((report["matched_rules"] as Array).has("knee_loaded"), "knee_loaded matched")

	begin("V21 holds independently of validate() over the golden scenarios")
	for entry in SCENARIOS:
		var scenario_plan := _build(_scenario_input(entry), GOLDEN_SEED)
		for session in scenario_plan.get("sessions", []):
			var previous := ""
			for block in (session as Dictionary).get("blocks", []):
				var record: Dictionary = _catalog[String((block as Dictionary)["exercise_id"])]
				var muscle := String(record["primary_muscle"])
				assert_ne(muscle, previous, "no two adjacent blocks share a primary muscle")
				previous = muscle
