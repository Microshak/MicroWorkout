extends TestSuite
## PRD-10 R3 / AC1 — the pure session model.
##
## `SessionRun` is the only session state model in the app (PRD-10 R3), so every fact the player,
## the completion screen and the resume path bind to is asserted here: the flat step order, the full
## R8 label matrix, the direction rules (`can_prev`/`prev` landing on blocks), the set check-off
## counters, `fully_completed()` at 19 of 20 sets, and the R13 `to_dict()` → `from_dict()`
## round-trip.
##
## The fixture is `tests/fixtures/sessions/upper_a.json` — 2 warm-up + 3 block + 2 cool-down = 7
## steps and 11 sets, chosen so it exercises every boundary R8 can name (a first/last warm-up, a
## middle/last block, a first/last cool-down).

const FIXTURE := "res://tests/fixtures/sessions/upper_a.json"

## The frozen R8 labels, spelled out here so a copy change in the model cannot pass silently.
const L_NEXT := "Next"
const L_START_SETS := "Start sets"
const L_COOL_DOWN := "Cool down"
const L_DONE := "I'm done for the day"


func _init() -> void:
	suite_name = "session_run"


func run() -> void:
	var doc := _fixture()
	if doc.is_empty():
		begin("fixture loads")
		assert_true(false, "could not read %s" % FIXTURE)
		return
	var plan: Dictionary = doc["plan"]
	var session: Dictionary = plan["sessions"][0]

	_test_build(plan, session)
	_test_step_order_labels(plan, session)
	_test_prev_rules(plan, session)
	_test_set_check_off(plan, session)
	_test_nineteen_of_twenty()
	_test_round_trip(plan, session)
	_test_edge_cases()
	_test_timers(plan, session)


# ------------------------------------------------------------------ R3 build

func _test_build(plan: Dictionary, session: Dictionary) -> void:
	begin("R3 flattens the session into one ordered step list")
	var run := SessionRun.build(plan, session)
	assert_eq(run.total_steps(), 7, "2 warm-up + 3 block + 2 cool-down")
	assert_eq(run.block_count(), 3)
	assert_eq(run.total_sets(), 11, "4 + 4 + 3")
	assert_eq(run.plan_id, "fix-1")
	assert_eq(run.session_id, "s1")
	assert_eq(run.session_title, "Upper A")
	assert_eq(run.step_index, 0, "a fresh run starts on step 0")
	assert_eq(run.state, SessionRun.ACTIVE)
	assert_eq(run.elapsed_sec, 0)

	begin("R3 step order is warm-up → block → cool-down")
	assert_eq(run.steps[0]["kind"], SessionRun.KIND_WARMUP)
	assert_eq(run.steps[1]["kind"], SessionRun.KIND_WARMUP)
	assert_eq(run.steps[2]["kind"], SessionRun.KIND_BLOCK)
	assert_eq(run.steps[3]["kind"], SessionRun.KIND_BLOCK)
	assert_eq(run.steps[4]["kind"], SessionRun.KIND_BLOCK)
	assert_eq(run.steps[5]["kind"], SessionRun.KIND_COOLDOWN)
	assert_eq(run.steps[6]["kind"], SessionRun.KIND_COOLDOWN)

	begin("R3 carries each kind's own payload keys")
	assert_eq(run.steps[0]["exercise_id"], "arm-circles")
	assert_eq(run.steps[0]["duration_sec"], 60)
	assert_eq(run.steps[0]["group_index"], 0)
	assert_eq(run.steps[1]["group_index"], 1)
	assert_eq(run.steps[2]["exercise_id"], "incline-bench-press")
	assert_eq(run.steps[2]["sets"], 4)
	assert_eq(run.steps[2]["reps"], "8-10")
	assert_eq(run.steps[2]["rest_seconds"], 90)
	assert_eq(run.steps[2]["block_index"], 0)
	assert_eq(run.steps[4]["sets"], 3, "the last block has 3 sets")
	assert_eq(run.steps[4]["block_index"], 2)
	assert_eq(run.steps[5]["group_index"], 0, "cool-down indexes from 0 again")
	assert_eq(run.steps[6]["group_index"], 1)

	begin("R3 seeds every block with its sets unchecked")
	assert_eq(run.set_states.size(), 3, "one key per block")
	assert_eq(run.sets_checked("incline-bench-press"), 0)
	assert_eq(run.sets_completed(), 0)
	assert_eq(run.blocks_completed(), 0)
	assert_false(run.fully_completed(), "nothing is done at step 0")


# ------------------------------------------------------------------ R8 labels + progress

func _test_step_order_labels(plan: Dictionary, session: Dictionary) -> void:
	begin("R8 next_label() — the full 7-row matrix")
	var run := SessionRun.build(plan, session)
	# Step 0: warm-up, not the last one.
	assert_eq(run.next_label(), L_NEXT, "warm-up item, not the last one")
	run.next()
	# Step 1: the last warm-up item — blocks follow.
	assert_eq(run.next_label(), L_START_SETS, "last warm-up item")
	run.next()
	# Step 2: first block, more blocks follow.
	assert_eq(run.next_label(), L_NEXT, "block, not the last block")
	run.next()
	# Step 3: middle block.
	assert_eq(run.next_label(), L_NEXT, "middle block")
	run.next()
	# Step 4: the last block, with a cool-down after it.
	assert_eq(run.next_label(), L_COOL_DOWN, "last block, cooldown items follow")
	run.next()
	# Step 5: first cool-down item.
	assert_eq(run.next_label(), L_NEXT, "cool-down item, not the last one")
	run.next()
	# Step 6: the last cool-down item.
	assert_eq(run.next_label(), L_DONE, "last cool-down item")
	assert_true(run.is_last_step())
	assert_false(run.next(), "next() refuses past the last step")

	begin("R8 'I'm done for the day' also ends a session with no cool-down")
	var no_cooldown := {
		"id": "sx", "title": "No cool-down",
		"warmup": [{"exercise_id": "arm-circles", "duration_sec": 60}],
		"blocks": [{"exercise_id": "barbell-row", "sets": 3, "reps": "8-10", "rest_seconds": 90}],
		"cooldown": [],
	}
	var run2 := SessionRun.build(plan, no_cooldown)
	assert_eq(run2.total_steps(), 2)
	assert_eq(run2.next_label(), L_START_SETS, "last warm-up with a block after it")
	run2.next()
	assert_eq(run2.next_label(), L_DONE, "last block when the session has no cooldown")

	begin("R8 the counter labels track block/step position")
	var run3 := SessionRun.build(plan, session)
	assert_eq(run3.step_kind(), SessionRun.KIND_WARMUP)
	assert_eq(run3.current_exercise_id(), "arm-circles")
	run3.goto_step(3)
	assert_eq(run3.step_kind(), SessionRun.KIND_BLOCK)
	assert_eq(run3.current_step()["block_index"], 1)
	assert_eq(run3.current_exercise_id(), "barbell-row")
	assert_eq(run3.step_kind(), "block")


# ------------------------------------------------------------------ R3/R8 direction rules

func _test_prev_rules(plan: Dictionary, session: Dictionary) -> void:
	begin("R8 can_prev() is false only on step 0")
	var run := SessionRun.build(plan, session)
	assert_false(run.can_prev(), "step 0 has nothing before it")
	assert_false(run.prev(), "prev() on step 0 is a no-op")
	assert_eq(run.step_index, 0)
	for index in range(1, run.total_steps()):
		run.goto_step(index)
		assert_true(run.can_prev(), "step %d can go back" % index)

	begin("R3 prev() from a block lands on the previous block (not the warm-up)")
	run.goto_step(3)
	assert_true(run.prev())
	assert_eq(run.step_index, 2, "second block → first block")

	begin("R3 prev() from the first cooldown item lands on the last block")
	run.goto_step(5)
	assert_true(run.prev())
	assert_eq(run.step_index, 4, "first cool-down → the last block")
	assert_eq(run.step_kind(), SessionRun.KIND_BLOCK)

	begin("R3 prev() from the last cooldown item lands on the last block too")
	run.goto_step(6)
	assert_true(run.prev())
	assert_eq(run.step_index, 4, "mobility items are not individually steppable backwards")

	begin("R3 prev() from the first block falls back to step 0 when no block precedes it")
	run.goto_step(2)
	assert_true(run.prev())
	assert_eq(run.step_index, 0, "no block before step 2, so step 0")
	run.goto_step(1)
	assert_true(run.prev())
	assert_eq(run.step_index, 0)


# ------------------------------------------------------------------ R7 check-off

func _test_set_check_off(plan: Dictionary, session: Dictionary) -> void:
	begin("R7 set_toggle() returns the new state and counts correctly")
	var run := SessionRun.build(plan, session)
	assert_true(run.set_toggle("incline-bench-press", 0), "unchecked → checked")
	assert_eq(run.sets_checked("incline-bench-press"), 1)
	assert_false(run.set_toggle("incline-bench-press", 0), "checked → unchecked")
	assert_eq(run.sets_checked("incline-bench-press"), 0)

	begin("R7 block_done() needs every set; sets_completed and blocks_completed agree")
	assert_true(run.set_toggle("incline-bench-press", 0))
	assert_true(run.set_toggle("incline-bench-press", 1))
	assert_true(run.set_toggle("incline-bench-press", 2))
	assert_false(run.block_done("incline-bench-press"), "3 of 4 is not done")
	assert_eq(run.sets_completed(), 3)
	assert_eq(run.blocks_completed(), 0)
	assert_true(run.set_toggle("incline-bench-press", 3))
	assert_true(run.block_done("incline-bench-press"), "4 of 4 is done")
	assert_eq(run.blocks_completed(), 1)
	assert_eq(run.sets_completed(), 4)
	assert_false(run.fully_completed(), "one of three blocks")

	begin("R7 an out-of-range set index is refused without mutating")
	assert_false(run.set_toggle("incline-bench-press", 9), "index past the block")
	assert_false(run.set_toggle("incline-bench-press", -1), "negative index")
	assert_false(run.set_toggle("no-such-exercise", 0), "unknown exercise")
	assert_eq(run.sets_checked("incline-bench-press"), 4, "refusals changed nothing")

	begin("R3 navigating never loses a check")
	run.goto_step(2)
	assert_eq(run.sets_checked("incline-bench-press"), 4)
	assert_true(run.next())
	assert_true(run.prev())
	assert_eq(run.step_index, 2)
	assert_eq(run.sets_checked("incline-bench-press"), 4, "back-and-forward preserved")

	begin("R7 fully_completed() is true only when every block is done")
	assert_false(run.fully_completed())
	for index in 4:
		run.set_checked("barbell-row", index)
	for index in 3:
		run.set_checked("seated-dumbbell-press", index)
	assert_eq(run.blocks_completed(), 3)
	assert_eq(run.sets_completed(), 11)
	assert_true(run.fully_completed())

	begin("R3 set_checked() marks a set and reports an unknown target")
	assert_eq(run.sets_checked("barbell-row"), 4)
	assert_true(run.set_checked("barbell-row", 3), "already checked stays checked")
	assert_false(run.set_checked("barbell-row", 7), "out of range")

	begin("R13 completed_block_ids() lists finished blocks in step order")
	var ids := run.completed_block_ids()
	assert_eq(ids.size(), 3)
	assert_eq(ids[0], "incline-bench-press")
	assert_eq(ids[2], "seated-dumbbell-press")

	begin("R11 restart_block() clears one block and leaves the others alone")
	assert_eq(run.restart_block("barbell-row"), 4, "four sets were cleared")
	assert_eq(run.sets_checked("barbell-row"), 0)
	assert_eq(run.blocks_completed(), 2)
	assert_eq(run.sets_completed(), 7)
	assert_eq(run.restart_block("barbell-row"), 0, "already clear")
	assert_eq(run.restart_block("nope"), 0, "unknown block")


# ------------------------------------------------------------------ AC1's 19-of-20 case

func _test_nineteen_of_twenty() -> void:
	begin("AC1 fully_completed() is false at 19 of 20 sets")
	var plan := {"id": "p-20", "name": "Twenty"}
	var blocks: Array = []
	for index in 5:
		blocks.append({
			"exercise_id": "exercise-%d" % index, "sets": 4, "reps": "8-10", "rest_seconds": 90,
		})
	var session := {"id": "s20", "title": "Twenty sets", "warmup": [], "blocks": blocks,
		"cooldown": []}
	var run := SessionRun.build(plan, session)
	assert_eq(run.total_sets(), 20)
	assert_eq(run.block_count(), 5)
	# 19 of 20: four complete blocks plus three of the last block's four sets.
	for index in 4:
		for set_i in 4:
			run.set_checked("exercise-%d" % index, set_i)
	for set_i in 3:
		run.set_checked("exercise-4", set_i)
	assert_eq(run.sets_completed(), 19)
	assert_eq(run.blocks_completed(), 4)
	assert_false(run.fully_completed(), "19 of 20 sets is not a completed session")
	# R11's `Restart exercise` clears the block's checks; the owner then re-checks all four sets,
	# which is the only way back to 20 of 20 (a cleared block restarts at zero, not at three).
	assert_eq(run.restart_block("exercise-4"), 3)
	assert_eq(run.sets_completed(), 16)
	for set_i in 4:
		run.set_checked("exercise-4", set_i)
	assert_eq(run.sets_completed(), 20)
	assert_eq(run.blocks_completed(), 5)
	assert_true(run.fully_completed(), "20 of 20 sets is")


# ------------------------------------------------------------------ R13 round trip

func _test_round_trip(plan: Dictionary, session: Dictionary) -> void:
	begin("R13 to_dict() carries R13's exact shape")
	var run := SessionRun.build(plan, session)
	run.started_at = 1789495331
	run.elapsed_sec = 412
	run.paused_total_sec = 37
	assert_true(run.set_checked("incline-bench-press", 0))
	assert_true(run.set_checked("incline-bench-press", 1))
	run.goto_step(3)
	var doc := run.to_dict("2026-09-15T18:19:40Z")
	for key in ["plan_id", "session_id", "started_at", "updated_at", "step_index", "elapsed_sec",
			"paused_total_sec", "set_states", "completed_blocks", "rest_remaining_sec"]:
		assert_has_key(doc, key)
	assert_eq(doc["plan_id"], "fix-1")
	assert_eq(doc["session_id"], "s1")
	assert_eq(doc["updated_at"], "2026-09-15T18:19:40Z")
	assert_eq(doc["step_index"], 3)
	assert_eq(doc["elapsed_sec"], 412)
	assert_eq(doc["paused_total_sec"], 37)
	assert_eq(doc["rest_remaining_sec"], 0, "a rest timer never resumes")
	assert_eq(doc["completed_blocks"], [], "two of four sets is not a completed block")

	begin("R13 the timestamps are the ISO-8601 shape the store validates")
	assert_true(Dates.is_valid_iso_datetime(String(doc["started_at"])),
		"started_at=%s" % str(doc["started_at"]))
	assert_true(Dates.is_valid_iso_datetime(String(doc["updated_at"])))
	assert_eq(String(doc["started_at"]), "2026-09-15T18:02:11Z", "unix 1789495331 rendered as UTC")

	begin("R13 set_states is a JSON-safe exercise_id → bool-list map")
	var states: Dictionary = doc["set_states"]
	assert_eq(states.size(), 3)
	assert_eq(states["incline-bench-press"], [true, true, false, false])
	assert_eq(states["seated-dumbbell-press"], [false, false, false])
	var encoded := JSON.stringify(doc)
	assert_true(encoded.contains("\"incline-bench-press\":[true,true,false,false]"),
		"round-trips through JSON as R13's example shows")

	begin("R13 from_dict() restores every field")
	var restored := SessionRun.from_dict(doc, plan, session)
	assert_eq(restored.plan_id, run.plan_id)
	assert_eq(restored.session_id, run.session_id)
	assert_eq(restored.step_index, run.step_index)
	assert_eq(restored.elapsed_sec, run.elapsed_sec)
	assert_eq(restored.paused_total_sec, run.paused_total_sec)
	assert_eq(restored.started_at, run.started_at)
	assert_eq(restored.total_steps(), run.total_steps())
	assert_eq(restored.sets_checked("incline-bench-press"), 2)
	assert_eq(restored.sets_completed(), 2)
	assert_eq(restored.to_dict("2026-09-15T18:19:40Z"), doc, "round-trip equality")

	begin("R13 a completed block survives the round trip as a completed block")
	for index in range(2, 4):
		run.set_checked("incline-bench-press", index)
	var doc2 := run.to_dict("2026-09-15T18:19:40Z")
	assert_eq(doc2["completed_blocks"], ["incline-bench-press"])
	var restored2 := SessionRun.from_dict(doc2, plan, session)
	assert_true(restored2.block_done("incline-bench-press"))
	assert_eq(restored2.completed_block_ids(), run.completed_block_ids())

	begin("R13 resume logs the step and set counts (AC10's log line reads these)")
	assert_eq(restored2.step_index, 3)
	assert_eq(restored2.sets_checked("incline-bench-press"), 4)
	assert_eq(restored2.elapsed_sec, 412)


# ------------------------------------------------------------------ defensive edges

func _test_edge_cases() -> void:
	begin("R3 a session with no warm-up or cool-down still builds")
	var plan := {"id": "p1"}
	var session := {
		"id": "s1", "title": "Blocks only",
		"blocks": [{"exercise_id": "plank", "sets": 3, "reps": "30-45", "rest_seconds": 60}],
	}
	var run := SessionRun.build(plan, session)
	assert_eq(run.total_steps(), 1)
	assert_eq(run.total_sets(), 3)
	assert_eq(run.next_label(), L_DONE, "a lone block is the end of the session")
	assert_false(run.can_prev())

	begin("R3 an empty session cannot crash the model")
	var empty := SessionRun.build({}, {})
	assert_eq(empty.total_steps(), 0)
	assert_eq(empty.total_sets(), 0)
	assert_eq(empty.block_count(), 0)
	assert_true(empty.current_step().is_empty())
	assert_eq(empty.step_kind(), "")
	assert_eq(empty.current_exercise_id(), "")
	assert_eq(empty.next_label(), L_DONE)
	assert_false(empty.next())
	assert_false(empty.prev())
	assert_false(empty.fully_completed(), "an empty session is never 'complete'")
	assert_eq(empty.sets_completed(), 0)
	assert_eq(empty.blocks_completed(), 0)
	assert_eq(empty.sets_checked("plank"), 0)
	assert_false(empty.block_done("plank"))

	begin("R3 malformed block entries are tolerated rather than trusted")
	var messy := SessionRun.build({"id": "p"}, {
		"id": "s", "warmup": ["not-a-dict", 42],
		"blocks": [
			"nope",
			{"exercise_id": "plank"},
			{"exercise_id": "row", "sets": -4, "reps": 10, "rest_seconds": "90"},
		],
		"cooldown": [{"duration_sec": 30}],
	})
	assert_eq(messy.block_count(), 2, "the two dictionary blocks survive")
	assert_eq(messy.total_sets(), 0, "a missing sets field is 0, a negative one clamps to 0")
	assert_eq(messy.steps[1]["reps"], "10", "a numeric reps is coerced, never silently dropped")
	assert_eq(messy.steps[1]["rest_seconds"], 0, "a non-int rest is 0")
	assert_eq(messy.total_steps(), 3, "two blocks plus the one usable cool-down")
	assert_eq(messy.steps[2]["kind"], SessionRun.KIND_COOLDOWN)
	assert_eq(messy.current_exercise_id(), "plank", "the first block is the current step")
	assert_false(messy.set_toggle("plank", 0), "a zero-set block has no chip to toggle")

	begin("R3 a reps value that is not text or a number is dropped, not stringified")
	var odd := SessionRun.build({"id": "p"}, {
		"id": "s",
		"blocks": [{"exercise_id": "curl", "sets": 2, "reps": {"bad": true}, "rest_seconds": 30}],
	})
	assert_eq(odd.steps[0]["reps"], "", "an object is not a rep scheme")
	assert_eq(odd.total_sets(), 2)

	begin("R3 goto_step() refuses an out-of-range index")
	var run2 := SessionRun.build({"id": "p"}, {
		"id": "s", "blocks": [{"exercise_id": "plank", "sets": 1, "reps": "5", "rest_seconds": 30}],
	})
	assert_false(run2.goto_step(5))
	assert_false(run2.goto_step(-1))
	assert_eq(run2.step_index, 0)

	begin("R3 from_dict() tolerates a truncated or hostile document")
	var plan3 := {"id": "p3"}
	var session3 := {
		"id": "s3", "blocks": [{"exercise_id": "plank", "sets": 2, "reps": "5", "rest_seconds": 30}],
	}
	var fresh := SessionRun.from_dict({}, plan3, session3)
	assert_eq(fresh.step_index, 0)
	assert_eq(fresh.sets_completed(), 0)
	assert_eq(fresh.state, SessionRun.ACTIVE)

	var hostile := SessionRun.from_dict({
		"step_index": 99, "elapsed_sec": -5, "paused_total_sec": "x",
		"started_at": "not-a-date",
		"set_states": {"plank": [true, true, true, true], "ghost-block": [true]},
	}, plan3, session3)
	assert_eq(hostile.step_index, 0, "an out-of-range cursor falls back to step 0")
	assert_eq(hostile.elapsed_sec, 0, "a negative clock is refused")
	assert_eq(hostile.paused_total_sec, 0)
	assert_eq(hostile.started_at, 0, "an unparseable stamp is 0, not a warning")
	assert_eq(hostile.sets_checked("plank"), 2, "extra stored sets are ignored")
	assert_false(hostile.set_states.has("ghost-block"), "a block the plan lost is dropped")
	assert_true(hostile.block_done("plank"))

	begin("R11 the model states are PAUSED/COMPLETING only")
	var run3 := SessionRun.build(plan3, session3)
	assert_eq(run3.state, SessionRun.ACTIVE)
	assert_true(run3.pause())
	assert_eq(run3.state, SessionRun.PAUSED)
	assert_false(run3.pause(), "pausing twice is refused")
	assert_true(run3.resume())
	assert_eq(run3.state, SessionRun.ACTIVE)
	assert_false(run3.resume(), "resuming a running session is refused")

	begin("R14 tick() only moves the clock forward by a positive delta")
	var run4 := SessionRun.build(plan3, session3)
	run4.tick(0)
	run4.tick(-10)
	assert_eq(run4.elapsed_sec, 0)
	run4.tick(30)
	assert_eq(run4.elapsed_sec, 30)
	assert_eq(run4.elapsed_text(), "0:30")


# ------------------------------------------------------------------ R9 timers

func _test_timers(plan: Dictionary, session: Dictionary) -> void:
	begin("R9 a timed step counts down from elapsed_sec, not from a decrementing float")
	var run := SessionRun.build(plan, session)
	run.goto_step(0)
	assert_eq(run.timed_seconds_remaining(), 60, "a warm-up starts at its duration")
	run.elapsed_sec = 25
	assert_eq(run.timed_seconds_remaining(), 35)
	run.elapsed_sec = 60
	assert_eq(run.timed_seconds_remaining(), 0, "never below zero")
	run.elapsed_sec = 600
	assert_eq(run.timed_seconds_remaining(), 0)

	begin("R9 the countdown survives a pause because the active clock stops")
	run.elapsed_sec = 20
	var before := run.timed_seconds_remaining()
	assert_true(run.pause())
	# Nothing ticks while paused, so the remaining time is frozen.
	assert_eq(run.timed_seconds_remaining(), before, "paused keeps the same remaining time")
	assert_true(run.resume())

	begin("R9 a block step has no timer")
	run.goto_step(2)
	assert_eq(run.timed_seconds_remaining(), 0)
	assert_eq(run.step_kind(), SessionRun.KIND_BLOCK)

	begin("R9 re-entering a timed step restarts its ring")
	run.goto_step(0)
	assert_eq(run.timed_seconds_remaining(), 60, "entering a step always starts a full ring")
	run.elapsed_sec = 45
	assert_eq(run.timed_seconds_remaining(), 35, "45 active seconds after a full ring at 20")
	run.goto_step(5)
	run.goto_step(0)
	assert_eq(run.timed_seconds_remaining(), 60, "Previous re-enters with a full ring")
	assert_eq(run.step_entered_at_elapsed, 45, "the ring is anchored to the clock at entry")


# ------------------------------------------------------------------ fixture loading

func _fixture() -> Dictionary:
	if not FileAccess.file_exists(FIXTURE):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if not (parsed is Dictionary):
		return {}
	var doc: Dictionary = parsed
	var plan: Variant = doc.get("plan", null)
	if not (plan is Dictionary):
		return {}
	return doc
