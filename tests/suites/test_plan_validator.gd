extends TestSuite
## PRD-07 R5 — the validator, field by field.
##
## Every test works on a **copy of the shipped mock fixture** (`tools/fixtures/mock_plan_valid.json`)
## mutated in exactly one way, so a failure says which rule broke rather than which fixture drifted.
## The fixture is the same file `tools/mock_llm_server.py` serves in `valid` mode, which is what
## makes the emulator path and this suite test the same bytes.
##
## Two things this suite deliberately proves beyond R5's check-list:
##   * the validated plan passes `PlanModel.validate()` — it is *storable*, not merely accepted;
##   * every code the validator can emit is inside the closed R5 vocabularies, checked by
##     collecting the codes from every scenario in this file.

## R9's `sample_input()` — the request every scenario is validated against.
const SAMPLE_INPUT: Dictionary = {
	"goal": "hypertrophy",
	"days_per_week": 4,
	"duration_min": 40,
	"areas": ["chest", "back", "shoulders", "core"],
	"equipment": ["barbell", "machine", "cable", "dumbbell", "bodyweight"],
	"notes": "",
	"id": "plan-1758000000",
	"created_at": "2026-09-15T00:00:00Z",
	"provider": "custom",
}

const FIXTURE_PATH := "res://tools/fixtures/mock_plan_valid.json"


func _init() -> void:
	suite_name = "plan_validator"


func run() -> void:
	_test_valid_fixture()
	_test_storable()
	_test_parse_tolerance()
	_test_root_shape()
	_test_session_count_and_index()
	_test_missing_fields()
	_test_wrong_types()
	_test_unknown_and_fuzzy_ids()
	_test_numeric_clamps()
	_test_duplicates_and_stretches()
	_test_block_counts()
	_test_adjacency()
	_test_identity()
	_test_stats()
	_test_normalisation_helpers()
	_test_estimate_helpers()
	_test_split_names()
	_test_closed_vocabularies()


# ------------------------------------------------------------------ the happy path

func _test_valid_fixture() -> void:
	begin("the shipped mock fixture validates with zero errors")
	var result := _validate(_plan())
	assert_true(bool(result["ok"]), "ok: %s" % _codes(result))
	assert_empty(result["errors"], "no errors")
	assert_empty(result["dropped"], "no block was dropped")
	assert_empty(result["repaired"], "nothing needed repairing")
	assert_eq((result["plan"] as Dictionary).get("sessions", []).size(), 4, "four sessions")

	begin("the plan it produces is exactly the §5.2 key set (and nothing else)")
	var plan: Dictionary = result["plan"]
	var expected: PackedStringArray = [
		"id", "name", "created_at", "source", "provider", "goal", "days_per_week",
		"duration_min", "areas", "equipment", "notes", "split_name", "sessions",
	]
	assert_eq(plan.size(), expected.size(), "thirteen keys")
	assert_eq(", ".join(PackedStringArray(plan.keys())), ", ".join(expected), "R5's key order")
	assert_eq(String(plan["source"]), "llm", "a validated reply is an llm plan")
	assert_eq(String(plan["split_name"]), "Upper / Lower", "the model's split name survives")
	assert_eq(String(plan["name"]), "4-Day Upper / Lower", "and its plan name")

	begin("warnings are advisory, and every one of them is in the closed set")
	var warnings: Array = result["warnings"]
	assert_true(warnings.is_empty() or warnings.size() > 0, "warnings are a list")
	for warning in warnings:
		assert_true(_warning_code(String(warning)) in PlanValidator.WARNING_CODES,
			"warning '%s' names a closed code" % warning)

	begin("a session keeps its identity and its warm-up/blocks/cooldown shape")
	var session: Dictionary = (plan["sessions"] as Array)[0]
	assert_eq(String(session["id"]), "s1", "id is re-derived from the position")
	assert_eq(int(session["index"]), 0, "index")
	assert_eq(String(session["title"]), "Upper A — Push Focus", "title kept verbatim")
	assert_eq((session["focus"] as Array).size(), 3, "focus kept")
	assert_eq((session["warmup"] as Array).size(), 2, "two warm-up items")
	assert_eq((session["blocks"] as Array).size(), 5, "five blocks")
	assert_eq((session["cooldown"] as Array).size(), 2, "two cooldown items")
	assert_eq(int(session["est_minutes"]), 45, "est_minutes inside the tolerance is kept")

	begin("a block keeps its four §5.2 fields and nothing else")
	var block: Dictionary = (session["blocks"] as Array)[0]
	assert_eq(block.size(), 4, "four fields")
	assert_eq(String(block["exercise_id"]), "bench-press", "exercise_id")
	assert_eq(int(block["sets"]), 4, "sets")
	assert_eq(String(block["reps"]), "8-10", "reps")
	assert_eq(int(block["rest_seconds"]), 90, "rest_seconds")

	begin("the validator is a pure function of its arguments")
	var again := _validate(_plan())
	assert_eq(JSON.stringify(again["plan"]), JSON.stringify(plan), "same input, same plan")
	assert_eq(JSON.stringify(again["errors"]), JSON.stringify(result["errors"]), "same errors")


func _test_storable() -> void:
	begin("the validated plan passes PlanModel.validate(): it can be stored")
	var plan: Dictionary = _validate(_plan())["plan"]
	var errors := PlanModel.validate_dict(plan, _catalog_map())
	assert_empty(errors, "PlanModel accepts it: %s" % ", ".join(errors))

	begin("the same holds for a plan with dropped blocks")
	var mutated := _plan()
	_block(mutated, 0, 2)["exercise_id"] = "incline-fly-machine"
	var dropped_plan: Dictionary = _validate(mutated)["plan"]
	assert_empty(PlanModel.validate_dict(dropped_plan, _catalog_map()),
		"a dropped block still leaves a storable plan")


# ------------------------------------------------------------------ parsing

func _test_parse_tolerance() -> void:
	begin("a fenced reply is parsed (R5 slices first { to last })")
	var text := "```json\n%s\n```\n" % _fixture_text()
	var result := PlanValidator.validate(text, _catalog(), SAMPLE_INPUT)
	assert_true(bool(result["ok"]), "ok: %s" % _codes(result))

	begin("a reply with prose before and after is parsed")
	var chatty := "Sure! Here is your plan:\n%s\nLet me know if you want changes." % _fixture_text()
	assert_true(bool(PlanValidator.validate(chatty, _catalog(), SAMPLE_INPUT)["ok"]),
		"prose around the object is tolerated")

	begin("a truncated reply is E_NOT_JSON")
	var truncated := "{\"name\": \"X\", \"sessions\": [{\"id\": \"s1\","
	var result_truncated := PlanValidator.validate(truncated, _catalog(), SAMPLE_INPUT)
	assert_false(bool(result_truncated["ok"]), "not ok")
	assert_true(_has_code(result_truncated, "E_NOT_JSON"), "E_NOT_JSON")
	assert_empty(result_truncated["plan"], "no plan is produced")

	begin("prose with no object at all is E_NOT_JSON")
	var prose := PlanValidator.validate("I can't help with that.", _catalog(), SAMPLE_INPUT)
	assert_true(_has_code(prose, "E_NOT_JSON"), "E_NOT_JSON")
	assert_eq(String((prose["errors"] as Array)[0]["path"]), "root", "the path is root")
	assert_eq(String((prose["errors"] as Array)[0]["severity"]), "error", "severity error")

	begin("an empty reply is E_NOT_JSON, not a crash")
	assert_true(_has_code(PlanValidator.validate("", _catalog(), SAMPLE_INPUT), "E_NOT_JSON"),
		"an empty string")
	assert_true(_has_code(PlanValidator.validate("   ", _catalog(), SAMPLE_INPUT), "E_NOT_JSON"),
		"whitespace only")

	begin("the error object has R5's six fields")
	var error: Dictionary = (truncated and PlanValidator.validate("nope", _catalog(),
		SAMPLE_INPUT)["errors"] as Array)[0]
	assert_eq(error.size(), 6, "six fields")
	for field in PackedStringArray(["code", "path", "message", "got", "expected", "severity"]):
		assert_has_key(error, field, "missing %s" % field)

	begin("messages are clipped to 200 characters")
	var hostile := PlanValidator.validate("{" + "x".repeat(5000), _catalog(), SAMPLE_INPUT)
	for error_entry in hostile["errors"]:
		assert_le(float(String((error_entry as Dictionary)["got"]).length()), 200.0, "got clipped")
		assert_le(float(String((error_entry as Dictionary)["message"]).length()), 200.0,
			"message clipped")

	begin("slice_object() unit behaviour")
	assert_eq(PlanValidator.slice_object("a{b}c"), "{b}", "first { to last }")
	assert_eq(PlanValidator.slice_object("{}"), "{}", "an empty object")
	assert_eq(PlanValidator.slice_object("no braces"), "", "none")
	assert_eq(PlanValidator.slice_object("{"), "", "an unterminated object")
	assert_eq(PlanValidator.slice_object("}{"), "", "reversed braces")


func _test_root_shape() -> void:
	begin("a JSON array is E_ROOT_TYPE")
	var array_reply := PlanValidator.validate("[1, 2, 3]", _catalog(), SAMPLE_INPUT)
	assert_true(_has_code(array_reply, "E_ROOT_TYPE"), "E_ROOT_TYPE: %s" % _codes(array_reply))
	assert_eq(String((array_reply["errors"] as Array)[0]["expected"]), "one JSON object",
		"the expected value is spelled out")

	begin("a JSON string is E_ROOT_TYPE rather than a silent success")
	assert_true(_has_code(PlanValidator.validate("\"hello\"", _catalog(), SAMPLE_INPUT),
		"E_ROOT_TYPE"), "a quoted string is not a plan")

	begin("a missing sessions key is E_MISSING_FIELD")
	var no_sessions := PlanValidator.validate("{\"name\": \"X\"}", _catalog(), SAMPLE_INPUT)
	assert_true(_has_code(no_sessions, "E_MISSING_FIELD"), "E_MISSING_FIELD")
	assert_eq(String((no_sessions["errors"] as Array)[0]["path"]), "sessions", "the path")
	assert_empty(no_sessions["plan"], "and no plan")

	begin("sessions that are not an array is E_WRONG_TYPE")
	assert_true(_has_code(PlanValidator.validate("{\"sessions\": {}}", _catalog(), SAMPLE_INPUT),
		"E_WRONG_TYPE"), "an object is not an array")
	assert_true(_has_code(PlanValidator.validate("{\"sessions\": \"x\"}", _catalog(), SAMPLE_INPUT),
		"E_WRONG_TYPE"), "nor is a string")


func _test_session_count_and_index() -> void:
	begin("three sessions for four days is E_SESSION_COUNT")
	var mutated := _plan()
	(mutated["sessions"] as Array).remove_at(3)
	var result := _validate(mutated)
	assert_false(bool(result["ok"]), "not ok")
	assert_true(_has_code(result, "E_SESSION_COUNT"), "E_SESSION_COUNT")
	var error := _error_with(result, "E_SESSION_COUNT")
	assert_eq(String(error["got"]), "3", "the count it saw")
	assert_eq(String(error["expected"]), "4", "the count it wanted")

	begin("five sessions for four days is E_SESSION_COUNT too")
	var extra := _plan()
	var sessions: Array = extra["sessions"]
	sessions.append(_copy(sessions[3]))
	extra["sessions"] = sessions
	assert_true(_has_code(_validate(extra), "E_SESSION_COUNT"), "too many is also a mismatch")

	begin("a shuffled index is E_SESSION_INDEX")
	var swapped := _plan()
	_session(swapped, 1)["index"] = 2
	var result_swapped := _validate(swapped)
	assert_true(_has_code(result_swapped, "E_SESSION_INDEX"), "E_SESSION_INDEX")
	assert_eq(String(_error_with(result_swapped, "E_SESSION_INDEX")["path"]), "sessions[1].index",
		"the path names the position, not the model's value")

	begin("a missing index is E_MISSING_FIELD")
	var missing := _plan()
	(_session(missing, 2) as Dictionary).erase("index")
	assert_true(_has_code(_validate(missing), "E_MISSING_FIELD"), "E_MISSING_FIELD")

	begin("index values are written back as 0..n-1 even when the reply disagrees")
	var fixed: Dictionary = _validate(swapped)["plan"]
	var indexes: Array = []
	for session in fixed["sessions"]:
		indexes.append(int((session as Dictionary)["index"]))
	assert_eq(", ".join(PackedStringArray(indexes.map(func(value: Variant) -> String:
		return str(value)))), "0, 1, 2, 3", "the plan's indexes are positional")


func _test_missing_fields() -> void:
	begin("a missing warmup is E_NO_WARMUP (R11)")
	var no_warmup := _plan()
	(_session(no_warmup, 0) as Dictionary).erase("warmup")
	var result := _validate(no_warmup)
	assert_false(bool(result["ok"]), "not ok")
	assert_true(_has_code(result, "E_NO_WARMUP"), "E_NO_WARMUP")
	assert_eq(String(_error_with(result, "E_NO_WARMUP")["path"]), "sessions[0].warmup", "the path")

	begin("an empty warmup and an empty cooldown are both E_NO_WARMUP")
	var empty := _plan()
	_session(empty, 1)["warmup"] = []
	assert_true(_has_code(_validate(empty), "E_NO_WARMUP"), "an empty list is missing too")
	var empty_cooldown := _plan()
	_session(empty_cooldown, 0)["cooldown"] = []
	assert_true(_has_code(_validate(empty_cooldown), "E_NO_WARMUP"), "the cooldown uses the same code")

	begin("a warm-up item that is not a stretch is E_BAD_STRETCH")
	var wrong_stretch := _plan()
	_mobility(wrong_stretch, 0, "warmup", 0)["exercise_id"] = "bench-press"
	var result_stretch := _validate(wrong_stretch)
	assert_true(_has_code(result_stretch, "E_BAD_STRETCH"), "E_BAD_STRETCH")
	assert_eq(String(_error_with(result_stretch, "E_BAD_STRETCH")["got"]), "bench-press", "the id")

	begin("a missing title, focus, blocks and est_minutes are all E_MISSING_FIELD")
	for field in PackedStringArray(["title", "focus", "blocks", "est_minutes"]):
		var mutated := _plan()
		(_session(mutated, 0) as Dictionary).erase(field)
		var missing := _validate(mutated)
		assert_true(_has_code(missing, "E_MISSING_FIELD"), "missing %s" % field)
		assert_eq(String(_error_with(missing, "E_MISSING_FIELD")["path"]), "sessions[0].%s" % field,
			"the path for %s" % field)

	begin("an exercise_id-less block is E_MISSING_FIELD")
	var no_id := _plan()
	(_block(no_id, 0, 0) as Dictionary).erase("exercise_id")
	assert_true(_has_code(_validate(no_id), "E_MISSING_FIELD"), "E_MISSING_FIELD")

	begin("a block missing sets/reps/rest_seconds is reported once per field")
	var bare := _plan()
	var block := _block(bare, 0, 0)
	block.erase("sets")
	block.erase("reps")
	block.erase("rest_seconds")
	var result_bare := _validate(bare)
	assert_eq(_count_code(result_bare, "E_MISSING_FIELD") >= 3, true, "three missing fields reported")

	begin("an item with no duration_sec is E_MISSING_FIELD")
	var no_duration := _plan()
	(_mobility(no_duration, 0, "warmup", 0) as Dictionary).erase("duration_sec")
	assert_true(_has_code(_validate(no_duration), "E_MISSING_FIELD"), "E_MISSING_FIELD")

	begin("a title longer than 60 characters is truncated with a warning, not rejected")
	var long_title := _plan()
	_session(long_title, 0)["title"] = "T".repeat(80)
	var result_long := _validate(long_title)
	assert_true(bool(result_long["ok"]), "still valid")
	assert_eq(String((((result_long["plan"] as Dictionary)["sessions"] as Array)[0] as Dictionary)
		["title"]).length(), 60, "truncated to 60")
	assert_true(_has_warning(result_long, "W_CLAMPED"), "W_CLAMPED recorded")


func _test_wrong_types() -> void:
	begin("a session that is not an object is E_WRONG_TYPE")
	var scalar_session := _plan()
	(scalar_session["sessions"] as Array)[1] = 5
	assert_true(_has_code(_validate(scalar_session), "E_WRONG_TYPE"), "E_WRONG_TYPE")

	begin("a focus that is not an array is E_WRONG_TYPE")
	var bad_focus := _plan()
	_session(bad_focus, 0)["focus"] = "chest"
	assert_true(_has_code(_validate(bad_focus), "E_WRONG_TYPE"), "E_WRONG_TYPE")

	begin("a focus entry outside the seven areas is E_BAD_AREA")
	var bad_area := _plan()
	_session(bad_area, 0)["focus"] = ["chest", "quads"]
	var result_area := _validate(bad_area)
	assert_true(_has_code(result_area, "E_BAD_AREA"), "E_BAD_AREA")
	assert_eq(String(_error_with(result_area, "E_BAD_AREA")["got"]), "quads", "the offending key")
	assert_eq(_focus_of(result_area, 0), "chest", "the valid entry survives")

	begin("an empty focus is E_BAD_AREA")
	var empty_focus := _plan()
	_session(empty_focus, 0)["focus"] = []
	assert_true(_has_code(_validate(empty_focus), "E_BAD_AREA"), "E_BAD_AREA")

	begin("blocks that are not an array is E_WRONG_TYPE")
	var bad_blocks := _plan()
	_session(bad_blocks, 0)["blocks"] = "nope"
	assert_true(_has_code(_validate(bad_blocks), "E_WRONG_TYPE"), "E_WRONG_TYPE")

	begin("a block that is not an object is E_WRONG_TYPE")
	var scalar_block := _plan()
	(_session(scalar_block, 0)["blocks"] as Array)[1] = "nope"
	assert_true(_has_code(_validate(scalar_block), "E_WRONG_TYPE"), "E_WRONG_TYPE")

	begin("a non-numeric sets/rest/duration/est is the field's own error")
	var bad_sets := _plan()
	_block(bad_sets, 0, 0)["sets"] = "four"
	var result_sets := _validate(bad_sets)
	assert_true(_has_code(result_sets, "E_BAD_SETS"), "E_BAD_SETS")

	var bad_rest := _plan()
	_block(bad_rest, 0, 0)["rest_seconds"] = "ninety"
	assert_true(_has_code(_validate(bad_rest), "E_BAD_REST"), "E_BAD_REST")

	var bad_duration := _plan()
	_mobility(bad_duration, 0, "warmup", 0)["duration_sec"] = "sixty"
	assert_true(_has_code(_validate(bad_duration), "E_BAD_DURATION"), "E_BAD_DURATION")

	var bad_est := _plan()
	_session(bad_est, 0)["est_minutes"] = "forty"
	assert_true(_has_code(_validate(bad_est), "E_WRONG_TYPE"), "est_minutes is E_WRONG_TYPE")

	begin("reps must be R7.3's three forms")
	for bad_reps in PackedStringArray(["eight to ten", "10-8", "0", "400s", "8-", "-10", "8.5"]):
		var mutated := _plan()
		_block(mutated, 0, 0)["reps"] = bad_reps
		var result := _validate(mutated)
		assert_true(_has_code(result, "E_BAD_REPS"), "reps '%s' is rejected" % bad_reps)
	for good_reps in PackedStringArray(["8", "8-10", "45s"]):
		var mutated_ok := _plan()
		_block(mutated_ok, 0, 0)["reps"] = good_reps
		assert_false(_has_code(_validate(mutated_ok), "E_BAD_REPS"),
			"reps '%s' is accepted" % good_reps)

	begin("a typographic dash and stray spaces in reps are normalised, not rejected")
	var spaced := _plan()
	_block(spaced, 0, 0)["reps"] = "8 - 10"
	var result_spaced := _validate(spaced)
	assert_false(_has_code(result_spaced, "E_BAD_REPS"), "'8 - 10' is accepted")
	assert_eq(_reps_of(result_spaced, 0, 0), "8-10", "and written back canonical")
	var endash := _plan()
	_block(endash, 0, 0)["reps"] = "8–10"
	assert_false(_has_code(_validate(endash), "E_BAD_REPS"), "an en dash is accepted")


# ------------------------------------------------------------------ id resolution (R5)

func _test_unknown_and_fuzzy_ids() -> void:
	begin("an unknown id drops the block and is reported in `dropped`, not as an error")
	var mutated := _plan()
	_block(mutated, 0, 2)["exercise_id"] = "incline-fly-machine"
	var result := _validate(mutated)
	assert_false(_has_code(result, "E_UNKNOWN_EXERCISE") or _has_code(result, "E_NO_BLOCKS"),
		"dropping is not an error")
	assert_true((result["dropped"] as PackedStringArray).has("incline-fly-machine"),
		"reported in dropped")
	assert_true(_has_warning(result, "W_DROPPED_EXERCISE"), "W_DROPPED_EXERCISE recorded")
	assert_eq((_blocks_of(result, 0)).size(), 4, "four blocks survive of five")
	assert_empty(result["errors"], "and no rule was broken")

	begin("`Bench  Press` is fuzzy-resolved to bench-press (R11)")
	var fuzzy := _plan()
	_block(fuzzy, 1, 3)["exercise_id"] = "Bench  Press"
	var result_fuzzy := _validate(fuzzy)
	assert_true(bool(result_fuzzy["ok"]), "still valid: %s" % _codes(result_fuzzy))
	assert_true((result_fuzzy["repaired"] as PackedStringArray).has("bench-press"),
		"recorded in repaired")
	assert_true(_has_warning(result_fuzzy, "W_FUZZY_RESOLVED"), "W_FUZZY_RESOLVED recorded")
	assert_eq(_id_of(result_fuzzy, 1, 3), "bench-press", "the block now names the real id")
	assert_empty(result_fuzzy["dropped"], "nothing was dropped")

	begin("a name-shaped id resolves for a stretch too (warm-up items)")
	var stretch_name := _plan()
	_mobility(stretch_name, 0, "warmup", 0)["exercise_id"] = "Arm Circles"
	var result_stretch := _validate(stretch_name)
	assert_true(bool(result_stretch["ok"]), "still valid: %s" % _codes(result_stretch))
	assert_eq(_mobility_id_of(result_stretch, 0, "warmup", 0), "arm-circles", "resolved")
	assert_true((result_stretch["repaired"] as PackedStringArray).has("arm-circles"),
		"reported in repaired")

	begin("a pluralised, spaced id resolves through the fuzzy step")
	var plural := _plan()
	_block(plural, 0, 3)["exercise_id"] = "Lat Pulldowns"
	var result_plural := _validate(plural)
	assert_true(bool(result_plural["ok"]), "still valid: %s" % _codes(result_plural))
	assert_eq(_id_of(result_plural, 0, 3), "lat-pulldown", "lat-pulldown")

	begin("an exact id match is accepted with no warning at all (step 1)")
	var exact := _plan()
	var result_exact := _validate(exact)
	assert_empty(result_exact["repaired"], "nothing was repaired")
	for warning in result_exact["warnings"]:
		assert_false(_warning_code(String(warning)) == "W_FUZZY_RESOLVED", "no fuzzy warning")

	begin("an ambiguous match is dropped rather than guessed (R5 step 3)")
	var ambiguous := PlanValidator.validate(
		"{\"sessions\": [{\"id\": \"s1\", \"index\": 0, \"title\": \"T\", \"focus\": [\"chest\"],"
		+ " \"est_minutes\": 40, \"warmup\": [], \"cooldown\": [], \"blocks\": ["
		+ "{\"exercise_id\": \"Bench Press\", \"sets\": 3, \"reps\": \"8-10\","
		+ " \"rest_seconds\": 90}]}]}",
		_twin_catalog(), {"goal": "hypertrophy", "days_per_week": 1, "duration_min": 40,
			"areas": ["chest"], "equipment": ["barbell"], "notes": "",
			"id": "plan-1758000000"})
	assert_true(_has_code(ambiguous, "E_NO_WARMUP"), "the empty warm-up is still an error")
	assert_true((ambiguous["dropped"] as PackedStringArray).has("Bench Press"),
		"the ambiguous id is dropped")
	assert_false((ambiguous["repaired"] as PackedStringArray).has("bench-press"),
		"and nothing is repaired")
	assert_true(_has_code(ambiguous, "E_NO_BLOCKS"), "which empties the session")
	assert_false(bool(ambiguous["ok"]), "so the plan is not ok")

	begin("the last block dropped is E_NO_BLOCKS and ok == false (R11)")
	var lonely := _plan()
	var blocks := _blocks_of_dict(lonely, 0)
	blocks.resize(1)
	(lonely["sessions"] as Array)[0]["blocks"] = blocks
	_block(lonely, 0, 0)["exercise_id"] = "not-a-real-exercise"
	var result_lonely := _validate(lonely)
	assert_true(_has_code(result_lonely, "E_NO_BLOCKS"), "E_NO_BLOCKS")
	assert_false(bool(result_lonely["ok"]), "ok == false")
	assert_true((result_lonely["dropped"] as PackedStringArray).has("not-a-real-exercise"),
		"the dropped id is still reported")

	begin("every session emptied by drops is reported")
	var all_gone := _plan()
	for session_index in 4:
		var session_blocks := _blocks_of_dict(all_gone, session_index)
		for block in session_blocks:
			(block as Dictionary)["exercise_id"] = "ghost-%d" % session_index
	assert_eq(_count_code(_validate(all_gone), "E_NO_BLOCKS"), 4, "four empty sessions")


func _test_numeric_clamps() -> void:
	begin("sets: 99 is clamped to 8 with W_CLAMPED (R11)")
	var mutated := _plan()
	_block(mutated, 0, 0)["sets"] = 99
	var result := _validate(mutated)
	assert_true(bool(result["ok"]), "still valid")
	assert_eq(int(_block_of(result, 0, 0)["sets"]), 8, "clamped to 8")
	assert_true(_has_warning(result, "W_CLAMPED"), "W_CLAMPED recorded")
	assert_false(_has_code(result, "E_BAD_SETS"), "not an error")

	begin("sets below the floor clamp up to 1")
	var low := _plan()
	_block(low, 0, 0)["sets"] = 0
	assert_eq(int(_block_of(_validate(low), 0, 0)["sets"]), 1, "clamped to 1")

	begin("rest_seconds outside 15..300 is clamped")
	var fast := _plan()
	_block(fast, 0, 0)["rest_seconds"] = 5
	assert_eq(int(_block_of(_validate(fast), 0, 0)["rest_seconds"]), 15, "clamped up to 15")
	var slow := _plan()
	_block(slow, 0, 0)["rest_seconds"] = 999
	assert_eq(int(_block_of(_validate(slow), 0, 0)["rest_seconds"]), 300, "clamped down to 300")

	begin("duration_sec outside 20..180 is clamped")
	var short_item := _plan()
	_mobility(short_item, 0, "warmup", 0)["duration_sec"] = 5
	assert_eq(int(_mobility_of(_validate(short_item), 0, "warmup", 0)["duration_sec"]), 20,
		"clamped up to 20")
	var long_item := _plan()
	_mobility(long_item, 0, "cooldown", 0)["duration_sec"] = 600
	assert_eq(int(_mobility_of(_validate(long_item), 0, "cooldown", 0)["duration_sec"]), 180,
		"clamped down to 180")

	begin("est_minutes outside ±15 % is recomputed from the set math")
	var wrong_est := _plan()
	_session(wrong_est, 0)["est_minutes"] = 90
	var result_est := _validate(wrong_est)
	assert_true(bool(result_est["ok"]), "a wrong estimate is not fatal")
	var recomputed := int((_sessions_of(result_est)[0] as Dictionary)["est_minutes"])
	assert_eq(recomputed, 45, "recomputed to the §7.1 arithmetic (45 minutes)")
	assert_true(_has_warning(result_est, "W_CLAMPED"), "W_CLAMPED recorded")
	assert_eq(PlanValidator.EST_MINUTES_TOL, 0.15, "appendix R39's single tolerance")

	begin("an estimate just inside the tolerance is kept")
	var inside := _plan()
	_session(inside, 0)["est_minutes"] = 46
	assert_eq(int((_sessions_of(_validate(inside))[0] as Dictionary)["est_minutes"]), 46, "kept")
	_session(inside, 0)["est_minutes"] = 34
	assert_eq(int((_sessions_of(_validate(inside))[0] as Dictionary)["est_minutes"]), 34, "kept")

	begin("an estimate just outside the tolerance is recomputed")
	_session(inside, 0)["est_minutes"] = 47
	assert_eq(int((_sessions_of(_validate(inside))[0] as Dictionary)["est_minutes"]), 45,
		"recomputed at 47")
	_session(inside, 0)["est_minutes"] = 33
	assert_eq(int((_sessions_of(_validate(inside))[0] as Dictionary)["est_minutes"]), 45,
		"recomputed at 33")


func _test_duplicates_and_stretches() -> void:
	begin("the same exercise twice in one session is E_DUPLICATE_EXERCISE")
	var mutated := _plan()
	(_blocks_of_dict(mutated, 1) as Array)[3]["exercise_id"] = "plank"
	var result := _validate(mutated)
	assert_false(bool(result["ok"]), "not ok")
	assert_true(_has_code(result, "E_DUPLICATE_EXERCISE"), "E_DUPLICATE_EXERCISE")
	assert_eq(String(_error_with(result, "E_DUPLICATE_EXERCISE")["got"]), "plank", "the id")

	begin("the check spans warm-up, blocks and cooldown (appendix V18)")
	var cross := _plan()
	_block(cross, 0, 0)["exercise_id"] = "arm-circles"
	var result_cross := _validate(cross)
	assert_true(_has_code(result_cross, "E_DUPLICATE_EXERCISE")
		or _has_code(result_cross, "E_BAD_STRETCH"),
		"reusing a warm-up id as a block is caught")

	begin("a stretch used as a working block is E_BAD_STRETCH")
	var stretch_block := _plan()
	_block(stretch_block, 0, 0)["exercise_id"] = "childs-pose"
	var result_stretch := _validate(stretch_block)
	assert_true(_has_code(result_stretch, "E_BAD_STRETCH"), "E_BAD_STRETCH")
	assert_false(_has_code(result_stretch, "E_UNKNOWN_EXERCISE"), "the id is known, just wrong")

	begin("a block whose id matches no record is dropped, not mis-resolved")
	var ghost := _plan()
	_block(ghost, 0, 4)["exercise_id"] = "zzz-qqq-xyz"
	var result_ghost := _validate(ghost)
	assert_true((result_ghost["dropped"] as PackedStringArray).has("zzz-qqq-xyz"), "dropped")
	assert_false((result_ghost["repaired"] as PackedStringArray).has("zzz-qqq-xyz"), "not repaired")


func _test_block_counts() -> void:
	begin("a session with 13 blocks is E_TOO_MANY_BLOCKS")
	var mutated := _plan()
	var blocks := _blocks_of_dict(mutated, 0)
	while blocks.size() < 13:
		var clone := _copy(blocks[blocks.size() - 1]) as Dictionary
		clone["exercise_id"] = "spare-%d" % blocks.size()
		blocks.append(clone)
	var result := _validate(mutated)
	assert_true(_has_code(result, "E_TOO_MANY_BLOCKS"), "E_TOO_MANY_BLOCKS")
	assert_eq(String(_error_with(result, "E_TOO_MANY_BLOCKS")["got"]), "13", "the count")

	begin("an empty blocks array is E_NO_BLOCKS")
	var empty := _plan()
	_session(empty, 0)["blocks"] = []
	var result_empty := _validate(empty)
	assert_true(_has_code(result_empty, "E_NO_BLOCKS"), "E_NO_BLOCKS")
	assert_false(bool(result_empty["ok"]), "not ok")

	begin("exactly 12 blocks is accepted")
	var twelve := _plan()
	var twelve_blocks := _blocks_of_dict(twelve, 3)
	while twelve_blocks.size() < 12:
		var clone: Dictionary = _copy(twelve_blocks[twelve_blocks.size() - 1])
		clone["exercise_id"] = "spare-%d" % twelve_blocks.size()
		twelve_blocks.append(clone)
	assert_false(_has_code(_validate(twelve), "E_TOO_MANY_BLOCKS"), "12 is the cap, not 11")


func _test_adjacency() -> void:
	begin("two adjacent blocks that share primary_muscle are reordered (R11)")
	var mutated := _plan()
	var blocks := _blocks_of_dict(mutated, 0)
	blocks.insert(1, {"exercise_id": "incline-bench-press", "sets": 3, "reps": "8-10",
		"rest_seconds": 90})
	(mutated["sessions"] as Array)[0]["blocks"] = blocks
	var result := _validate(mutated)
	assert_false(_has_code(result, "E_ADJACENT_MUSCLE"), "the conflict was repaired")
	assert_true(bool(result["ok"]), "and the plan is valid: %s" % _codes(result))
	assert_true(_has_warning(result, "W_CLAMPED"), "the reorder is recorded as W_CLAMPED")
	var order := _ids_of_session(result, 0)
	assert_eq(", ".join(order), "bench-press, overhead-press, barbell-row, lat-pulldown, plank, "
		+ "incline-bench-press", "the offender moved to the end")
	assert_eq(order.size(), 6, "no block was lost")

	begin("a session that cannot be reordered reports E_ADJACENT_MUSCLE")
	var impossible := PlanValidator.validate(
		"{\"sessions\": [{\"id\": \"s1\", \"index\": 0, \"title\": \"T\", \"focus\": [\"chest\"],"
		+ " \"est_minutes\": 40, \"warmup\": [{\"exercise_id\": \"arm-circles\","
		+ " \"duration_sec\": 60}], \"cooldown\": [{\"exercise_id\": \"childs-pose\","
		+ " \"duration_sec\": 60}], \"blocks\": ["
		+ "{\"exercise_id\": \"bench-press\", \"sets\": 3, \"reps\": \"8-10\","
		+ " \"rest_seconds\": 90},"
		+ "{\"exercise_id\": \"incline-bench-press\", \"sets\": 3, \"reps\": \"8-10\","
		+ " \"rest_seconds\": 90}]}]}",
		_catalog(), {"goal": "hypertrophy", "days_per_week": 1, "duration_min": 40,
			"areas": ["chest"], "equipment": ["barbell"], "notes": "",
			"id": "plan-1758000000"})
	assert_true(_has_code(impossible, "E_ADJACENT_MUSCLE"), "E_ADJACENT_MUSCLE")
	assert_false(bool(impossible["ok"]), "not ok")
	assert_eq(String(_error_with(impossible, "E_ADJACENT_MUSCLE")["got"]), "Chest",
		"the shared muscle is named")


# ------------------------------------------------------------------ identity

func _test_identity() -> void:
	begin("the request's identity fields win over the reply's")
	var result := _validate(_plan())
	var plan: Dictionary = result["plan"]
	assert_eq(String(plan["goal"]), "hypertrophy", "goal from the request")
	assert_eq(int(plan["days_per_week"]), 4, "days from the request")
	assert_eq(int(plan["duration_min"]), 40, "duration from the request")
	assert_eq(JSON.stringify(plan["areas"]),
		JSON.stringify(["chest", "back", "shoulders", "core"]), "areas from the request")
	assert_eq(JSON.stringify(plan["equipment"]),
		JSON.stringify(["barbell", "machine", "cable", "dumbbell", "bodyweight"]),
		"equipment from the request")
	assert_eq(String(plan["notes"]), "", "notes from the request")
	assert_eq(String(plan["id"]), "plan-1758000000", "the caller's id")
	assert_eq(String(plan["created_at"]), "2026-09-15T00:00:00Z", "the caller's timestamp")
	assert_eq(String(plan["provider"]), "custom", "the provider the ladder will use")

	begin("a reply that disagrees about the request fields is warned about, not believed")
	var disagreeing := _plan()
	disagreeing["goal"] = "strength"
	disagreeing["days_per_week"] = 2
	disagreeing["duration_min"] = 20
	disagreeing["areas"] = ["legs"]
	var result_disagreeing := _validate(disagreeing)
	assert_eq(String((result_disagreeing["plan"] as Dictionary)["goal"]), "hypertrophy",
		"the request still wins")
	assert_eq(int((result_disagreeing["plan"] as Dictionary)["days_per_week"]), 4, "days too")
	assert_true(_has_warning(result_disagreeing, "W_NAME_MISMATCH"), "W_NAME_MISMATCH recorded")

	begin("a missing name is derived and warned about")
	var unnamed := _plan()
	unnamed.erase("name")
	var result_unnamed := _validate(unnamed)
	assert_eq(String((result_unnamed["plan"] as Dictionary)["name"]), "4-Day Upper / Lower",
		"derived from days + split")
	assert_true(_has_warning(result_unnamed, "W_NAME_MISMATCH"), "W_NAME_MISMATCH recorded")

	begin("a missing split_name falls back to the canonical §6.3 name")
	var no_split := _plan()
	no_split.erase("split_name")
	var result_split := _validate(no_split)
	assert_eq(String((result_split["plan"] as Dictionary)["split_name"]), "Upper / Lower",
		"days 4 -> Upper / Lower")

	begin("id and created_at default to the generator's own pattern when the caller omits them")
	var bare_input: Dictionary = SAMPLE_INPUT.duplicate()
	bare_input.erase("id")
	bare_input.erase("created_at")
	bare_input.erase("provider")
	var result_bare := PlanValidator.validate(_fixture_text(), _catalog(), bare_input)
	var bare_plan: Dictionary = result_bare["plan"]
	assert_true(PlanModel.is_plan_id(String(bare_plan["id"])),
		"'%s' matches ^plan-\\d{10}$" % bare_plan["id"])
	assert_false(String(bare_plan["created_at"]).is_empty(), "created_at is set")
	assert_eq(String(bare_plan["provider"]), "", "and the provider is empty until the ladder sets it")

	begin("unknown keys the model invented are never echoed (R5)")
	var noisy := _plan()
	noisy["confidence"] = 0.9
	noisy["model_notes"] = "I guessed"
	_session(noisy, 0)["why"] = "because"
	_block(noisy, 0, 0)["tempo"] = "3-1-1"
	var noisy_plan: Dictionary = _validate(noisy)["plan"]
	assert_false(noisy_plan.has("confidence"), "no root extra")
	assert_false(noisy_plan.has("model_notes"), "no root extra")
	assert_false((_sessions_of_dict(noisy_plan)[0] as Dictionary).has("why"), "no session extra")
	assert_false(((_sessions_of_dict(noisy_plan)[0] as Dictionary)["blocks"] as Array)[0]
		is Dictionary and (((_sessions_of_dict(noisy_plan)[0] as Dictionary)["blocks"] as Array)[0]
			as Dictionary).has("tempo"), "no block extra")


func _test_stats() -> void:
	begin("stats.blocks counts every surviving working block")
	var result := _validate(_plan())
	var stats: Dictionary = result["stats"]
	assert_eq(int(stats["blocks"]), 18, "5 + 4 + 5 + 4 blocks")
	assert_has_key(stats, "sets_per_area", "sets_per_area present")

	begin("stats.sets_per_area tallies direct sets by the record's primary area")
	var sets: Dictionary = stats["sets_per_area"]
	assert_eq(int(sets.get("chest", 0)), 7, "chest: bench-press 4 + 3")
	assert_eq(int(sets.get("back", 0)), 18, "back: rows 4 + 4 + lat pulldown 3 + 4 + face-pull 3")
	assert_eq(int(sets.get("shoulders", 0)), 6, "shoulders: overhead press 3 + 3")
	assert_eq(int(sets.get("core", 0)), 9, "core: plank 3 + 3 + hanging leg raise 3")
	assert_eq(int(sets.get("legs", 0)), 20, "legs: squat 7 + RDL 7 + goblet 3 + bulgarian 3")
	var total := 0
	for area in sets.keys():
		total += int(sets[area])
	assert_eq(total, 60, "every set is attributed exactly once")

	begin("a dropped block is not counted")
	var mutated := _plan()
	_block(mutated, 0, 0)["exercise_id"] = "ghost"
	var dropped_stats: Dictionary = _validate(mutated)["stats"]
	assert_eq(int(dropped_stats["blocks"]), 17, "one fewer block")
	assert_eq(int((dropped_stats["sets_per_area"] as Dictionary).get("chest", 0)), 3,
		"and its four chest sets are gone")

	begin("W_LOW_VOLUME warns when an area is under the appendix §6.4 floor")
	var result_warn := _validate(_plan())
	assert_true(_has_warning(result_warn, "W_LOW_VOLUME"),
		"the fixture's 6 shoulder sets are under a 10-set floor")
	assert_true(bool(result_warn["ok"]), "but it is a warning, not an error")


# ------------------------------------------------------------------ pure helpers

func _test_normalisation_helpers() -> void:
	begin("normalize_id keeps hyphens, so an id-shaped string matches at step 2")
	assert_eq(PlanValidator.normalize_id("bench-press"), "bench-press", "an id")
	assert_eq(PlanValidator.normalize_id("BENCH-PRESS"), "bench-press", "case-insensitive")
	assert_eq(PlanValidator.normalize_id("bench_press"), "bench press", "underscores become spaces")
	assert_eq(PlanValidator.normalize_id("  bench   press  "), "bench press", "collapsed and trimmed")
	assert_eq(PlanValidator.normalize_id("LAT PULLDOWNS"), "lat pulldown", "a trailing plural")

	begin("normalize_text is the name-side twin")
	assert_eq(PlanValidator.normalize_text("Bench  Press"), "bench pres",
		"punctuation and runs of spaces collapse")
	assert_eq(PlanValidator.normalize_text("Press"), "press", "a doubled s is never singularised")
	assert_eq(PlanValidator.normalize_text("abs"), "abs", "short words are left alone")
	assert_eq(PlanValidator.normalize_text("Arm Circles"), "arm circle", "a real plural")
	assert_eq(PlanValidator.normalize_text(""), "", "empty stays empty")

	begin("a name-shaped candidate deliberately misses step 2 and lands on step 3")
	assert_ne(PlanValidator.normalize_id("Bench  Press"), PlanValidator.normalize_id("bench-press"),
		"so the resolution is reported as fuzzy rather than silently exact")
	assert_eq(PlanValidator.normalize_text("Bench  Press"), PlanValidator.normalize_text(
		"Bench Press"), "and it still finds the right name")

	begin("reps normalisation")
	assert_eq(PlanValidator.normalize_reps(" 8 - 10 "), "8-10", "spaces removed")
	assert_eq(PlanValidator.normalize_reps("8–10"), "8-10", "en dash")
	assert_eq(PlanValidator.normalize_reps("45s"), "45s", "seconds untouched")

	begin("R5's fuzzy threshold is exactly 0.82")
	assert_close(PlanValidator.FUZZY_THRESHOLD, 0.82, 0.0001, "threshold")
	assert_eq(PlanValidator.MAX_BLOCKS_PER_SESSION, 12, "twelve blocks")


func _test_estimate_helpers() -> void:
	begin("reps_used() reads a range, a single count and a seconds block")
	assert_eq(PlanValidator.reps_used("8-10"), 10, "top of the range")
	assert_eq(PlanValidator.reps_used("8"), 8, "a single count")
	assert_eq(PlanValidator.reps_used("45s"), 45, "seconds")
	assert_eq(PlanValidator.reps_used(""), 1, "an empty string still yields the minimum")

	begin("estimate_minutes() is PRD-05 R8's arithmetic")
	assert_eq(PlanValidator.estimate_minutes([], [], []), 1, "an empty session is still a minute")
	var blocks: Array = [{"sets": 3, "reps": "10", "rest_seconds": 90}]
	assert_eq(PlanValidator.estimate_minutes(blocks, [], []), 7, "3 x (10x3 + 12 + 90) = 396 s")
	var warmup: Array = [{"exercise_id": "arm-circles", "duration_sec": 60}]
	assert_eq(PlanValidator.estimate_minutes(blocks, warmup, warmup), 9,
		"two mobility items add 120 s")
	assert_eq(PlanValidator.estimate_minutes([{"sets": 3, "reps": "45s", "rest_seconds": 60}], [], []),
		9, "a seconds block uses its own value")

	begin("the generator's constants are the ones being used")
	assert_eq(Generator.REP_SEC, 3, "3 s per rep")
	assert_eq(Generator.TRANSITION_SEC, 12, "12 s per transition")
	assert_eq(Generator.MOBILITY_ITEM_SEC, 60, "60 s per mobility item")


func _test_split_names() -> void:
	begin("canonical_split_name() follows appendix §6.3")
	assert_eq(PlanValidator.canonical_split_name(1, 4), "Full Body", "1 day")
	assert_eq(PlanValidator.canonical_split_name(2, 4), "Full Body A / B", "2 days")
	assert_eq(PlanValidator.canonical_split_name(3, 4), "Push / Pull / Legs", "3 days, 4 areas")
	assert_eq(PlanValidator.canonical_split_name(3, 3), "Full Body ×3", "3 days, 3 areas")
	assert_eq(PlanValidator.canonical_split_name(4, 4), "Upper / Lower", "4 days")
	assert_eq(PlanValidator.canonical_split_name(5, 4), "Push / Pull / Legs + Upper / Lower", "5 days")
	assert_eq(PlanValidator.canonical_split_name(6, 4), "Push / Pull / Legs ×2", "6 days")
	assert_eq(PlanValidator.canonical_split_name(7, 4), "Full Body", "out of range degrades")


# ------------------------------------------------------------------ the closed vocabularies

func _test_closed_vocabularies() -> void:
	begin("the error and warning vocabularies are R5's closed sets")
	assert_eq(PlanValidator.ERROR_CODES.size(), 18, "eighteen error codes")
	assert_eq(PlanValidator.WARNING_CODES.size(), 5, "five warning codes")
	var expected_errors: PackedStringArray = [
		"E_NOT_JSON", "E_ROOT_TYPE", "E_MISSING_FIELD", "E_WRONG_TYPE", "E_UNKNOWN_EXERCISE",
		"E_DUPLICATE_EXERCISE", "E_BAD_SETS", "E_BAD_REPS", "E_BAD_REST", "E_BAD_DURATION",
		"E_BAD_AREA", "E_SESSION_COUNT", "E_SESSION_INDEX", "E_NO_BLOCKS", "E_TOO_MANY_BLOCKS",
		"E_ADJACENT_MUSCLE", "E_NO_WARMUP", "E_BAD_STRETCH",
	]
	assert_eq(", ".join(PlanValidator.ERROR_CODES), ", ".join(expected_errors), "R5's list")
	assert_eq(", ".join(PlanValidator.WARNING_CODES),
		"W_DROPPED_EXERCISE, W_FUZZY_RESOLVED, W_CLAMPED, W_LOW_VOLUME, W_NAME_MISMATCH",
		"R5's warning list")

	begin("every code this suite can provoke is inside those sets")
	var scenarios: Array = _scenarios()
	var seen: Dictionary = {}
	for scenario in scenarios:
		var plan: Dictionary = scenario
		var result := _validate(plan)
		for error in result["errors"]:
			var code := String((error as Dictionary)["code"])
			seen[code] = true
			assert_true(PlanValidator.ERROR_CODES.has(code), "'%s' is a closed code" % code)
		for warning in result["warnings"]:
			var warning_code := _warning_code(String(warning))
			seen[warning_code] = true
			assert_true(PlanValidator.WARNING_CODES.has(warning_code),
				"'%s' is a closed warning" % warning_code)

	begin("the scenarios really exercised most of the vocabulary")
	var expected_seen: PackedStringArray = [
		"E_MISSING_FIELD", "E_WRONG_TYPE", "E_BAD_SETS", "E_BAD_REST", "E_BAD_DURATION",
		"E_BAD_REPS", "E_BAD_AREA", "E_SESSION_COUNT", "E_SESSION_INDEX", "E_NO_BLOCKS",
		"E_TOO_MANY_BLOCKS", "E_ADJACENT_MUSCLE", "E_NO_WARMUP", "E_BAD_STRETCH",
		"E_DUPLICATE_EXERCISE", "W_DROPPED_EXERCISE", "W_FUZZY_RESOLVED", "W_CLAMPED",
		"W_LOW_VOLUME", "W_NAME_MISMATCH",
	]
	for code in expected_seen:
		assert_true(seen.has(code), "'%s' was provoked somewhere" % code)

	begin("E_UNKNOWN_EXERCISE and E_NOT_JSON come from the parse path")
	assert_true(_has_code(PlanValidator.validate("not a plan", _catalog(), SAMPLE_INPUT),
		"E_NOT_JSON"), "E_NOT_JSON")
	var empty_id := _plan()
	_block(empty_id, 0, 0)["exercise_id"] = ""
	assert_true(_has_code(_validate(empty_id), "E_UNKNOWN_EXERCISE"), "an empty id")
	assert_true(_has_code(PlanValidator.validate("[1]", _catalog(), SAMPLE_INPUT), "E_ROOT_TYPE"),
		"E_ROOT_TYPE")


## One plan per scenario, mutated in exactly one way, so the vocabulary scan above is exhaustive
## by construction rather than by inspection.
func _scenarios() -> Array:
	var out: Array = []
	var no_warmup := _plan()
	(_session(no_warmup, 0) as Dictionary).erase("warmup")
	out.append(no_warmup)
	var bad_sets := _plan()
	_block(bad_sets, 0, 2)["sets"] = 99
	out.append(bad_sets)
	var bad_rest := _plan()
	_block(bad_rest, 0, 0)["rest_seconds"] = 999
	out.append(bad_rest)
	var bad_duration := _plan()
	_mobility(bad_duration, 0, "warmup", 0)["duration_sec"] = 5
	out.append(bad_duration)
	var bad_reps := _plan()
	_block(bad_reps, 0, 0)["reps"] = "lots"
	out.append(bad_reps)
	var bad_area := _plan()
	_session(bad_area, 0)["focus"] = ["quadz"]
	out.append(bad_area)
	var short := _plan()
	(short["sessions"] as Array).remove_at(0)
	out.append(short)
	var indexed := _plan()
	_session(indexed, 0)["index"] = 9
	out.append(indexed)
	var dropped := _plan()
	_block(dropped, 0, 2)["exercise_id"] = "ghost"
	out.append(dropped)
	var fuzzy := _plan()
	_block(fuzzy, 1, 3)["exercise_id"] = "Bench  Press"
	out.append(fuzzy)
	var stretchy := _plan()
	_mobility(stretchy, 0, "warmup", 1)["exercise_id"] = "bench-press"
	out.append(stretchy)
	var duplicated := _plan()
	(_blocks_of_dict(duplicated, 1) as Array)[3]["exercise_id"] = "plank"
	out.append(duplicated)
	var wrong_type := _plan()
	_session(wrong_type, 0)["focus"] = "chest"
	out.append(wrong_type)
	var unnamed := _plan()
	unnamed.erase("name")
	out.append(unnamed)
	return out


# ------------------------------------------------------------------ fixtures

func _fixture_text() -> String:
	return FileAccess.get_file_as_string(FIXTURE_PATH)


## A fresh, mutable copy of the fixture, parsed from its own text so a mutation cannot leak into
## another test through a shared Dictionary.
func _plan() -> Dictionary:
	var parsed: Variant = JSON.parse_string(_fixture_text())
	return (parsed as Dictionary).duplicate(true)


func _copy(value: Variant) -> Variant:
	if value is Dictionary or value is Array:
		return JSON.parse_string(JSON.stringify(value))
	return value


func _validate(plan: Dictionary) -> Dictionary:
	return PlanValidator.validate(JSON.stringify(plan), _catalog(), SAMPLE_INPUT)


## The ALLOWED EXERCISES list the ladder would embed for SAMPLE_INPUT.
func _catalog() -> Array[Dictionary]:
	var records: Array = []
	var catalog := PlanModel.load_catalog()
	for id in catalog.keys():
		records.append(catalog[id])
	return PlanPrompt.filter_records(records,
		PackedStringArray(SAMPLE_INPUT["areas"]), PackedStringArray(SAMPLE_INPUT["equipment"]))


func _catalog_map() -> Dictionary:
	return PlanModel.load_catalog()


## Two records with the same name, for R5 step 3's tie rule.
func _twin_catalog() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in PackedStringArray(["bench-press", "bench-press-machine"]):
		out.append({
			"id": id,
			"name": "Bench Press",
			"areas": ["chest"],
			"equipment": "Barbell",
			"primary_muscle": "Chest",
			"is_stretch": false,
			"compound": true,
			"default_sets": 3,
			"rep_min": 8,
			"rep_max": 12,
			"rest_seconds": 90,
		})
	return out


# ------------------------------------------------------------------ accessors

func _sessions_of(result: Dictionary) -> Array:
	return (result["plan"] as Dictionary).get("sessions", [])


func _sessions_of_dict(plan: Dictionary) -> Array:
	return plan.get("sessions", [])


func _blocks_of(result: Dictionary, session_index: int) -> Array:
	return (_sessions_of(result)[session_index] as Dictionary)["blocks"]


func _blocks_of_dict(plan: Dictionary, session_index: int) -> Array:
	return (_sessions_of_dict(plan)[session_index] as Dictionary)["blocks"]


func _session(plan: Dictionary, index: int) -> Dictionary:
	return _sessions_of_dict(plan)[index]


func _block(plan: Dictionary, session_index: int, block_index: int) -> Dictionary:
	return _blocks_of_dict(plan, session_index)[block_index]


func _mobility(plan: Dictionary, session_index: int, field: String, item_index: int) -> Dictionary:
	return (_sessions_of_dict(plan)[session_index] as Dictionary)[field][item_index]


func _block_of(result: Dictionary, session_index: int, block_index: int) -> Dictionary:
	return _blocks_of(result, session_index)[block_index]


func _mobility_of(result: Dictionary, session_index: int, field: String,
		item_index: int) -> Dictionary:
	return (_sessions_of(result)[session_index] as Dictionary)[field][item_index]


func _id_of(result: Dictionary, session_index: int, block_index: int) -> String:
	return String(_block_of(result, session_index, block_index)["exercise_id"])


func _reps_of(result: Dictionary, session_index: int, block_index: int) -> String:
	return String(_block_of(result, session_index, block_index)["reps"])


func _mobility_id_of(result: Dictionary, session_index: int, field: String,
		item_index: int) -> String:
	return String(_mobility_of(result, session_index, field, item_index)["exercise_id"])


func _ids_of_session(result: Dictionary, session_index: int) -> PackedStringArray:
	var out := PackedStringArray()
	for block in _blocks_of(result, session_index):
		out.append(String((block as Dictionary)["exercise_id"]))
	return out


func _focus_of(result: Dictionary, session_index: int) -> String:
	return String(((_sessions_of(result)[session_index] as Dictionary)["focus"] as Array)[0])


func _codes(result: Dictionary) -> String:
	var out := PackedStringArray()
	for error in result["errors"]:
		out.append(String((error as Dictionary)["code"]))
	return ", ".join(out)


func _has_code(result: Dictionary, code: String) -> bool:
	for error in result["errors"]:
		if String((error as Dictionary)["code"]) == code:
			return true
	return false


func _count_code(result: Dictionary, code: String) -> int:
	var total := 0
	for error in result["errors"]:
		if String((error as Dictionary)["code"]) == code:
			total += 1
	return total


func _error_with(result: Dictionary, code: String) -> Dictionary:
	for error in result["errors"]:
		if String((error as Dictionary)["code"]) == code:
			return error
	return {}


func _has_warning(result: Dictionary, code: String) -> bool:
	for warning in result["warnings"]:
		if _warning_code(String(warning)) == code:
			return true
	return false


## Warnings are rendered as `CODE: message`, so the code is the part before the first colon.
func _warning_code(warning: String) -> String:
	var separator := warning.find(":")
	if separator < 0:
		return warning
	return warning.substr(0, separator)
