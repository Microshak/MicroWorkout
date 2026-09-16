extends TestSuite
## PRD-05 R2/R3 — the typed plan model and the one validator every plan passes.
##
## The suite reads `res://data/exercise_library.json` through `PlanModel.load_catalog()`
## (never the `Library` autoload: suites run under `--script`, where autoloads do not
## exist yet — see tests/framework.gd). Nothing here writes to disk.
##
## Style note that matters for every later PRD: `JSON.parse_string("3")` yields `3.0`,
## so the "valid plan" helpers below are deliberately written with **floats** in a few
## places — a plan that came back from `plans.json` must validate exactly like one built
## in memory.

const FIXTURE_DIR := "res://tests/fixtures/"

## R19 — the six hand-written malformed plans and the error substring each must produce.
const BAD_FIXTURES: Array = [
	["bad_plan_unknown_exercise.json", "unknown exercise_id"],
	["bad_plan_sets_zero.json", "sets out of range"],
	["bad_plan_reps_garbage.json", "unparseable reps"],
	["bad_plan_rest_too_long.json", "rest out of range"],
	["bad_plan_duplicate_exercise.json", "duplicate exercise"],
	["bad_plan_session_count_mismatch.json", "sessions"],
]

const STRETCH_IDS: PackedStringArray = [
	"arm-circles", "cat-cow-stretch", "childs-pose",
	"butterfly-stretch", "hamstring-stretch", "seated-forward-fold-stretch",
]

## `reps` forms accepted by V16 and the ones it must reject (PRD-00 §7.3).
const VALID_REPS: PackedStringArray = [
	"1", "8", "12", "30", "8-10", "1-30", "10-30", "45s", "10s", "100s", "300s",
]
const INVALID_REPS: PackedStringArray = [
	"", "0", "31", "45", "8-8", "10-5", "5-40", "40-5", "as many as you can",
	"45ss", "5s", "s", "-5", "8-", "1e2", "AMRAP",
]


func _init() -> void:
	suite_name = "plan_model"


func run() -> void:
	_test_catalog_available()
	_test_typed_round_trip()
	_test_extra_keys_survive()
	_test_validator_accepts_a_good_plan()
	_test_malformed_fixtures()
	_test_rule_coverage()
	_test_reps_forms()
	_test_accessors()
	_test_number_type_leniency()
	_test_never_throws()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _errors(plan: Dictionary) -> Array[String]:
	var model := PlanModel.plan_from_dict(plan)
	return model.validate()


func _contains(errors: Array[String], needle: String) -> bool:
	for error in errors:
		if error.contains(needle):
			return true
	return false


## Whole floats → ints, recursively: what Godot's JSON parser needs before a parsed
## document can be compared with one built in memory.
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


func _mobility(exercise_id: String) -> Dictionary:
	return {"exercise_id": exercise_id, "duration_sec": 60}


func _block(exercise_id: String, sets: int, reps: String, rest: int) -> Dictionary:
	return {"exercise_id": exercise_id, "sets": sets, "reps": reps, "rest_seconds": rest}


## A complete, valid §5.3 plan; every rule test below mutates exactly one field of it.
func _valid_plan() -> Dictionary:
	return {
		"id": "plan-1758000000",
		"name": "2-Day Full Body A / B",
		"created_at": "2026-09-15T12:00:00Z",
		"source": "builtin",
		"provider": "",
		"goal": "hypertrophy",
		"days_per_week": 2,
		"duration_min": 30,
		"areas": ["chest", "back"],
		"equipment": ["barbell", "dumbbell", "bodyweight"],
		"notes": "",
		"split_name": "Full Body A / B",
		"sessions": [
			{
				"id": "s1", "index": 0, "title": "Full Body A",
				"focus": ["chest", "back"], "est_minutes": 30,
				"warmup": [_mobility("arm-circles"), _mobility("cat-cow-stretch"),
					_mobility("childs-pose")],
				"blocks": [_block("bench-press", 3, "8-12", 90),
					_block("barbell-row", 3, "8-12", 90)],
				"cooldown": [_mobility("butterfly-stretch"), _mobility("hamstring-stretch"),
					_mobility("seated-forward-fold-stretch")],
			},
			{
				"id": "s2", "index": 1, "title": "Full Body B",
				"focus": ["back", "chest"], "est_minutes": 30,
				"warmup": [_mobility("leg-swings-stretch"),
					_mobility("worlds-greatest-stretch"), _mobility("torso-twist-stretch")],
				"blocks": [_block("lat-pulldown", 3, "10-12", 75),
					_block("dumbbell-bench-press", 3, "8-12", 90)],
				"cooldown": [_mobility("cross-body-shoulder-stretch"),
					_mobility("kneeling-hip-flexor-stretch"), _mobility("wall-calf-stretch")],
			},
		],
	}


func _session(plan: Dictionary, index: int) -> Dictionary:
	return (plan["sessions"] as Array)[index]


# ---------------------------------------------------------------------------
# 1 · catalog
# ---------------------------------------------------------------------------

func _test_catalog_available() -> void:
	begin("the shipped catalog resolves without the Library autoload")
	PlanModel.reset_catalog_cache()
	var catalog := PlanModel.load_catalog()
	assert_eq(catalog.size(), 204, "the catalog map holds every library record")
	var record: Dictionary = catalog.get("bench-press", {})
	assert_eq(record.get("primary_muscle", ""), "Chest", "bench-press resolves")
	assert_eq(PlanModel.is_plan_id("plan-1757941200"), true, "the golden id shape is legal")
	assert_eq(PlanModel.is_plan_id("plan-17579412"), false, "a short id is rejected")
	assert_eq(PlanModel.is_plan_id("175794120a"), false, "a non-numeric id is rejected")


# ---------------------------------------------------------------------------
# 2 · typed model round-trip
# ---------------------------------------------------------------------------

func _test_typed_round_trip() -> void:
	begin("plan_from_dict/to_dict round-trips the §5.3 document byte for byte")
	var source := _valid_plan()
	var model := PlanModel.plan_from_dict(source)
	assert_eq(model.session_count(), 2, "two sessions")
	assert_eq(model.source, "builtin", "source is typed")
	assert_eq(model.goal, "hypertrophy", "goal is typed")
	assert_eq(model.sessions[0].blocks.size(), 2, "blocks are typed")
	assert_eq(model.sessions[0].warmup.size(), 3, "warm-up items are typed")
	assert_eq(model.sessions[0].blocks[0].exercise_id, "bench-press", "block id")
	assert_eq(model.sessions[0].blocks[0].sets, 3, "block sets are ints, not floats")
	assert_eq(model.sessions[0].warmup[0].duration_sec, 60, "mobility duration is an int")
	assert_eq(JSON.stringify(model.to_dict(), "", true), JSON.stringify(source, "", true),
		"to_dict() reproduces the input exactly")

	begin("to_dict() emits exactly the documented key sets (no _meta, no debug keys)")
	var plan_dict: Dictionary = model.to_dict()
	var plan_keys: Array = plan_dict.keys()
	plan_keys.sort()
	var expected_keys: Array = ["areas", "created_at", "days_per_week", "duration_min",
		"equipment", "goal", "id", "name", "notes", "provider", "sessions", "source",
		"split_name"]
	assert_eq(plan_keys, expected_keys, "13 plan keys")
	var session_dict: Dictionary = (plan_dict["sessions"] as Array)[0]
	var session_keys: Array = session_dict.keys()
	session_keys.sort()
	assert_eq(session_keys, ["blocks", "cooldown", "est_minutes", "focus", "id", "index",
		"title", "warmup"], "8 session keys")
	var block_keys: Array = ((session_dict["blocks"] as Array)[0] as Dictionary).keys()
	block_keys.sort()
	assert_eq(block_keys, ["exercise_id", "reps", "rest_seconds", "sets"], "4 block keys")
	var item_keys: Array = ((session_dict["warmup"] as Array)[0] as Dictionary).keys()
	item_keys.sort()
	assert_eq(item_keys, ["duration_sec", "exercise_id"], "2 mobility keys")

	begin("a plan parsed straight from a JSON string round-trips too")
	# Godot parses every JSON number as a float, so `to_dict()` must be compared against a
	# normalised copy of the parsed document, not against the raw parse.
	var text := FileAccess.get_file_as_string(FIXTURE_DIR + "bad_plan_sets_zero.json")
	var parsed: Variant = JSON.parse_string(text)
	assert_true(parsed is Dictionary, "the fixture parses")
	if parsed is Dictionary:
		var reparsed := PlanModel.plan_from_dict(parsed)
		assert_eq(reparsed.days_per_week, 2, "a JSON int became an int again")
		assert_eq(reparsed.sessions[0].blocks[0].sets, 3, "sets survived the JSON float type")
		assert_eq(JSON.stringify(reparsed.to_dict(), "", true),
			JSON.stringify(_normalised(parsed), "", true),
			"to_dict() is byte-identical to the normalised document")


# ---------------------------------------------------------------------------
# 3 · forward compatibility
# ---------------------------------------------------------------------------

func _test_extra_keys_survive() -> void:
	begin("unknown keys at every level survive the round trip")
	var source := _valid_plan()
	source["x_future"] = 1
	source["generation"] = {"attempts": 2, "model": "deepseek-chat"}
	_session(source, 0)["future_session_key"] = "keep"
	(_session(source, 0)["blocks"] as Array)[0]["future_block_key"] = "keep"
	(_session(source, 0)["warmup"] as Array)[0]["future_warmup_key"] = "keep"

	var model := PlanModel.plan_from_dict(source)
	var out: Dictionary = model.to_dict()
	assert_eq(out.get("x_future", 0), 1, "an unknown plan key survives")
	assert_eq((out.get("generation", {}) as Dictionary).get("attempts", 0), 2,
		"the additive PRD-07 `generation` block survives")
	assert_eq((out["sessions"] as Array)[0].get("future_session_key", ""), "keep", "session key")
	assert_eq(((out["sessions"] as Array)[0]["blocks"] as Array)[0].get("future_block_key", ""),
		"keep", "block key")
	assert_eq(((out["sessions"] as Array)[0]["warmup"] as Array)[0].get("future_warmup_key", ""),
		"keep", "warm-up key")
	assert_eq(JSON.stringify(out, "", true), JSON.stringify(source, "", true),
		"the whole document round-trips byte for byte")

	begin("V1 only fires when schema_version is present and wrong")
	var versioned := _valid_plan()
	versioned["schema_version"] = 1
	assert_empty(_errors(versioned), "schema_version 1 is accepted")
	versioned["schema_version"] = 2
	assert_true(_contains(_errors(versioned), "schema_version"), "schema_version 2 is rejected")


# ---------------------------------------------------------------------------
# 4 · the validator accepts what the generator produces
# ---------------------------------------------------------------------------

func _test_validator_accepts_a_good_plan() -> void:
	begin("the hand-written valid plan and a real generated plan both validate clean")
	assert_empty(_errors(_valid_plan()), "the base plan is valid: %s"
		% str(_errors(_valid_plan())))
	var generated := Generator.build_plan({
		"goal": "hypertrophy", "days_per_week": 4, "duration_min": 40,
		"areas": ["chest", "back", "shoulders", "arms", "core"],
		"equipment": ["barbell", "machine", "cable", "dumbbell", "bodyweight"],
		"notes": "", "id": "plan-1757941200", "created_at": "2026-09-15T12:00:00Z",
	}, 20260915)
	assert_false(generated.has("error"), "the generator produced a plan")
	assert_empty(_errors(generated), "a generated plan validates clean: %s"
		% str(_errors(generated)))

	begin("PlanModel.validate_dict is the same contract for an untyped plan")
	assert_empty(PlanModel.validate_dict(_valid_plan()), "a raw dict validates")
	var broken := _valid_plan()
	broken["id"] = "nope"
	assert_true(_contains(PlanModel.validate_dict(broken), "id: must match"),
		"the static helper reports the same defect")


# ---------------------------------------------------------------------------
# 5 · R19 — the six malformed-plan fixtures
# ---------------------------------------------------------------------------

func _test_malformed_fixtures() -> void:
	for entry in BAD_FIXTURES:
		var file_name := String(entry[0])
		var needle := String(entry[1])
		var path := FIXTURE_DIR + file_name
		begin("%s is rejected with '%s'" % [file_name, needle])
		var parsed: Variant = _read_json(path)
		assert_true(parsed is Dictionary, "%s parses as JSON" % file_name)
		if not (parsed is Dictionary):
			continue
		var errors := _errors(parsed)
		assert_eq(errors.size(), 1, "exactly one defect: %s" % str(errors))
		assert_true(_contains(errors, needle), "the error names the defect: %s" % str(errors))
		print("      %s rejected: %s" % [file_name, errors[0] if not errors.is_empty() else ""])


# ---------------------------------------------------------------------------
# 6 · rule coverage beyond the fixtures (V1…V22)
# ---------------------------------------------------------------------------

func _test_rule_coverage() -> void:
	begin("V3/V6 — days_per_week and duration_min ranges")
	for value in [0, 7, 9, -1]:
		var plan := _valid_plan()
		plan["days_per_week"] = value
		assert_true(_contains(_errors(plan), "days_per_week"), "days_per_week %d rejected" % value)
	for value in [5, 9, 121, 240]:
		var plan := _valid_plan()
		plan["duration_min"] = value
		assert_true(_contains(_errors(plan), "duration_min"), "duration_min %d rejected" % value)

	begin("V7/V8 — goal and source enums")
	for value in ["general", "fitness", "", "General"]:
		var plan := _valid_plan()
		plan["goal"] = value
		assert_true(_contains(_errors(plan), "goal:"), "goal '%s' rejected" % value)
	for value in ["strength", "hypertrophy", "general_fitness", "conditioning"]:
		var plan := _valid_plan()
		plan["goal"] = value
		assert_empty(_errors(plan), "goal '%s' accepted" % value)
	for value in ["generator", "llm ", "builtin2", ""]:
		var plan := _valid_plan()
		plan["source"] = value
		assert_true(_contains(_errors(plan), "source:"), "source '%s' rejected" % value)

	begin("V9/V10 — areas and equipment")
	var no_areas := _valid_plan()
	no_areas["areas"] = []
	assert_true(_contains(_errors(no_areas), "areas:"), "an empty area list is rejected")
	var bad_area := _valid_plan()
	bad_area["areas"] = ["chest", "mobility"]
	assert_true(_contains(_errors(bad_area), "unknown area 'mobility'"),
		"the reserved area is not user-selectable")
	var no_equipment := _valid_plan()
	no_equipment["equipment"] = []
	assert_true(_contains(_errors(no_equipment), "equipment:"), "empty equipment is rejected")

	begin("V4/V5 — session count")
	var mismatch := _valid_plan()
	mismatch["days_per_week"] = 3
	assert_true(_contains(_errors(mismatch), "sessions: count must equal"), "count mismatch")
	var none := _valid_plan()
	none["sessions"] = []
	assert_true(_contains(_errors(none), "at least 1 session"), "no sessions at all")

	begin("V11/V13 — block count bounds")
	var empty_session := _valid_plan()
	_session(empty_session, 0)["blocks"] = []
	assert_true(_contains(_errors(empty_session), "at least 1 block"), "a block-less session")
	var too_many := _valid_plan()
	var blocks: Array = []
	for index in 13:
		blocks.append(_block("bench-press", 3, "8-12", 90) if index % 2 == 0
			else _block("barbell-row", 3, "8-12", 90))
	_session(too_many, 0)["blocks"] = blocks
	assert_true(_contains(_errors(too_many), "at most 12 blocks"), "13 blocks rejected")

	begin("V12/V20 — warm-up presence and mobility durations")
	var no_warmup := _valid_plan()
	_session(no_warmup, 0)["warmup"] = []
	assert_true(_contains(_errors(no_warmup), "warmup:"), "a session without a warm-up")
	for value in [0, 5, 19, 181, 300]:
		var plan := _valid_plan()
		(_session(plan, 0)["cooldown"] as Array)[0]["duration_sec"] = value
		assert_true(_contains(_errors(plan), "duration_sec out of range"),
			"duration_sec %d rejected" % value)

	begin("V14 — unknown ids are reported, never crashed on")
	for value in ["nope", "Bench-Press", "", "bench press"]:
		var plan := _valid_plan()
		(_session(plan, 0)["blocks"] as Array)[0]["exercise_id"] = value
		assert_true(_contains(_errors(plan), "unknown exercise_id"),
			"'%s' is an unknown exercise_id" % value)
	var bad_cooldown := _valid_plan()
	(_session(bad_cooldown, 0)["cooldown"] as Array)[0]["exercise_id"] = "not-real"
	assert_true(_contains(_errors(bad_cooldown), "unknown exercise_id"),
		"a cooldown id is checked as well")

	begin("V15/V17 — sets and rest ranges")
	for value in [0, -1, 9, 40]:
		var plan := _valid_plan()
		(_session(plan, 0)["blocks"] as Array)[0]["sets"] = value
		assert_true(_contains(_errors(plan), "sets out of range"), "sets %d rejected" % value)
	for value in [0, 14, 301, 600]:
		var plan := _valid_plan()
		(_session(plan, 0)["blocks"] as Array)[0]["rest_seconds"] = value
		assert_true(_contains(_errors(plan), "rest out of range"), "rest %d rejected" % value)

	begin("V18 — no exercise twice in one session (blocks ∪ warm-up ∪ cooldown)")
	var duplicated := _valid_plan()
	(_session(duplicated, 1)["cooldown"] as Array)[0] = _mobility("lat-pulldown")
	assert_true(_contains(_errors(duplicated), "duplicate exercise 'lat-pulldown'"),
		"a block id repeated in the cooldown")
	var repeated_in_blocks := _valid_plan()
	_session(repeated_in_blocks, 0)["blocks"] = [
		_block("bench-press", 3, "8-12", 90), _block("bench-press", 3, "8-12", 90)]
	var repeated_errors := _errors(repeated_in_blocks)
	assert_true(_contains(repeated_errors, "duplicate exercise 'bench-press'"),
		"a block repeated inside one session is a duplicate: %s" % str(repeated_errors))
	assert_true(_contains(repeated_errors, "adjacent blocks share primary muscle"),
		"and the same pair also breaks the anti-adjacency rail")

	begin("V19 — est_minutes range")
	for value in [0, -5, 181, 400]:
		var plan := _valid_plan()
		_session(plan, 0)["est_minutes"] = value
		assert_true(_contains(_errors(plan), "est_minutes out of range"),
			"est_minutes %d rejected" % value)

	begin("V21 — anti-adjacency at primary_muscle granularity, not body-area granularity")
	var adjacent := _valid_plan()
	_session(adjacent, 0)["blocks"] = [
		_block("dumbbell-bench-press", 3, "8-12", 90), _block("bench-press", 3, "8-12", 90)]
	var adjacent_errors := _errors(adjacent)
	assert_true(_contains(adjacent_errors, "adjacent blocks share primary muscle 'Chest'"),
		"two chest exercises back to back: %s" % str(adjacent_errors))
	# Same *area* (back) but different primary muscles is legal — appendix R40.
	var same_area := _valid_plan()
	_session(same_area, 0)["blocks"] = [
		_block("lat-pulldown", 3, "10-12", 75), _block("barbell-row", 3, "8-12", 90)]
	assert_empty(_errors(same_area),
		"Lats then Back are both `back` but not the same primary_muscle")

	begin("V22 — a stretch is never a working block")
	var stretch_block := _valid_plan()
	(_session(stretch_block, 0)["blocks"] as Array)[0] = _block("arm-circles", 3, "8-12", 90)
	assert_true(_contains(_errors(stretch_block), "stretch used as a working block"),
		"an is_stretch record as a block")

	begin("duplicate session ids are reported")
	var duplicate_sessions := _valid_plan()
	_session(duplicate_sessions, 1)["id"] = "s1"
	assert_true(_contains(_errors(duplicate_sessions), "duplicate session id 's1'"),
		"two sessions sharing an id")


# ---------------------------------------------------------------------------
# 7 · reps forms (V16)
# ---------------------------------------------------------------------------

func _test_reps_forms() -> void:
	begin("V16 accepts exactly the three documented `reps` forms")
	for value in VALID_REPS:
		assert_true(PlanModel.is_valid_reps(value), "'%s' is a valid reps value" % value)
	for value in INVALID_REPS:
		assert_false(PlanModel.is_valid_reps(value), "'%s' is not a valid reps value" % value)

	begin("V16 in situ: the block message carries the offending value")
	var plan := _valid_plan()
	(_session(plan, 0)["blocks"] as Array)[0]["reps"] = "as many as you can"
	var errors := _errors(plan)
	assert_true(_contains(errors, "unparseable reps 'as many as you can'"),
		"the message quotes the value: %s" % str(errors))


# ---------------------------------------------------------------------------
# 8 · accessors
# ---------------------------------------------------------------------------

func _test_accessors() -> void:
	begin("session_count() and exercise_ids_in_session()")
	var model := PlanModel.plan_from_dict(_valid_plan())
	assert_eq(model.session_count(), 2, "session_count()")
	assert_eq(model.session_count(), model.sessions.size(), "session_count() matches the array")
	var ids := model.exercise_ids_in_session(0)
	assert_eq(ids.size(), 8, "3 warm-up + 2 blocks + 3 cooldown")
	assert_eq(ids[0], "arm-circles", "the warm-up comes first")
	assert_eq(ids[3], "bench-press", "then the working blocks, in order")
	assert_eq(ids[7], "seated-forward-fold-stretch", "then the cooldown")
	assert_true(model.exercise_ids_in_session(9).is_empty(), "an out-of-range index is empty")
	assert_true(model.exercise_ids_in_session(-1).is_empty(), "a negative index is empty")
	assert_true(model.session_by_id("s2") != null, "session_by_id finds a session")
	assert_true(model.session_by_id("s9") == null, "session_by_id returns null when absent")


# ---------------------------------------------------------------------------
# 9 · JSON number leniency
# ---------------------------------------------------------------------------

func _test_number_type_leniency() -> void:
	begin("whole floats from JSON count as ints (a plan off disk validates)")
	var plan := _valid_plan()
	plan["days_per_week"] = 2.0
	plan["duration_min"] = 30.0
	_session(plan, 0)["est_minutes"] = 30.0
	(_session(plan, 0)["blocks"] as Array)[0]["sets"] = 3.0
	(_session(plan, 0)["blocks"] as Array)[0]["rest_seconds"] = 90.0
	(_session(plan, 0)["warmup"] as Array)[0]["duration_sec"] = 60.0
	assert_empty(_errors(plan), "2.0 / 30.0 / 3.0 are accepted as ints")

	begin("a fractional number is not an int")
	var fractional := _valid_plan()
	(_session(fractional, 0)["blocks"] as Array)[0]["sets"] = 3.5
	assert_true(_contains(_errors(fractional), "sets out of range"), "3.5 sets is rejected")
	var fractional_days := _valid_plan()
	fractional_days["days_per_week"] = 2.5
	assert_true(_contains(_errors(fractional_days), "days_per_week"),
		"2.5 days_per_week is rejected")
	assert_eq(PlanModel.as_int(7.0, -1), 7, "as_int converts a whole float")
	assert_eq(PlanModel.as_int(7.5, -1), -1, "as_int refuses a fraction")
	assert_eq(PlanModel.as_int("7", -1), -1, "as_int refuses a string")
	assert_eq(PlanModel.as_int(true, -1), -1, "as_int refuses a bool")


# ---------------------------------------------------------------------------
# 10 · robustness
# ---------------------------------------------------------------------------

func _test_never_throws() -> void:
	begin("validate() never throws on hostile input")
	var hostile: Array = [
		{}, {"sessions": "nope"}, {"sessions": [1, 2]}, {"sessions": [{}]},
		{"blocks": []}, {"id": 17, "areas": 3, "equipment": true},
		{"sessions": [{"blocks": [{"exercise_id": "x", "sets": "three"}],
			"warmup": [null], "cooldown": [3]}]},
		{"days_per_week": "four", "duration_min": null, "goal": 9, "source": []},
	]
	for index in hostile.size():
		var errors := _errors(hostile[index])
		assert_true(errors.size() > 0, "hostile plan %d is reported, not crashed on" % index)
	var only_sessions := _errors({"sessions": [{}]})
	assert_gt(float(only_sessions.size()), 0.0, "a session with nothing in it is reported")
	assert_true(_contains(_errors({"sessions": [{}]}), "unknown exercise_id") == false,
		"a block-less session reports block problems, not id problems")
