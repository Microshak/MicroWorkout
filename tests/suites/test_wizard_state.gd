extends TestSuite
## PRD-08 R9 (and AC1) — the wizard's pure input model.
##
## Everything here is a function of the fields, so the suite needs no autoloads, no scene tree
## and no clock. The one time-dependent rule (`saved_at` freshness) takes an injected "now",
## which is why `WizardState.is_fresh()` accepts one.
##
## The assertions the acceptance criteria name explicitly are at the top of their sections:
## default `days_per_week == 4`, default `duration_min == 40`, `goal == ""` on a fresh state,
## `is_step_valid(STEP_AREAS) == false` with no areas, `is_step_valid(STEP_GOAL) == false` with
## no goal, and a `to_dict()` with no `goal` key.

const NOW := 1789000000        # 2026-09-09T…Z-ish; only the deltas matter
const DAY := 86400


func _init() -> void:
	suite_name = "wizard_state"


func run() -> void:
	_test_routes()
	_test_defaults()
	_test_step_order_and_copy()
	_test_step_validity()
	_test_validation_messages()
	_test_area_selection()
	_test_days_and_duration()
	_test_goal_every_time()
	_test_notes_rules()
	_test_pristine_and_reset()
	_test_request_shape()
	_test_draft_round_trip()
	_test_draft_never_carries_the_goal()
	_test_draft_freshness()
	_test_full_dict_round_trip()
	_test_invalid_input_is_safe()


# ------------------------------------------------------------------ R1 routes

func _test_routes() -> void:
	begin("R1: the two wizard routes exist and point at the two screens")
	assert_eq(str(Routes.NEW_WORKOUT_WIZARD), "new_workout_wizard", "the wizard name")
	assert_eq(str(Routes.PLAN_PREVIEW), "plan_preview", "the preview name")
	assert_true(Routes.TABLE.has(Routes.NEW_WORKOUT_WIZARD), "the wizard is in Routes.TABLE")
	assert_true(Routes.TABLE.has(Routes.PLAN_PREVIEW), "the preview is in Routes.TABLE")
	assert_eq(str(Routes.TABLE[Routes.NEW_WORKOUT_WIZARD]),
		"res://scenes/ui/new_workout_wizard.tscn", "the wizard scene path")
	assert_eq(str(Routes.TABLE[Routes.PLAN_PREVIEW]),
		"res://scenes/ui/plan_preview.tscn", "the preview scene path")
	assert_false(Routes.is_main_scene(Routes.NEW_WORKOUT_WIZARD),
		"the wizard is a pushed screen, not a main-scene replacement")
	assert_false(Routes.is_main_scene(Routes.PLAN_PREVIEW), "so is the preview")
	assert_true(ResourceLoader.exists(str(Routes.TABLE[Routes.NEW_WORKOUT_WIZARD])),
		"the wizard scene is on disk")
	assert_true(ResourceLoader.exists(str(Routes.TABLE[Routes.PLAN_PREVIEW])),
		"the preview scene is on disk")

	begin("R1: neither route disturbs the tab or main-scene tables")
	assert_false(Routes.TAB_ROUTES.has(Routes.NEW_WORKOUT_WIZARD), "the wizard is not a tab")
	assert_false(Routes.TAB_ROUTES.has(Routes.PLAN_PREVIEW), "neither is the preview")
	assert_eq(Routes.TAB_ROUTES.size(), 4, "the four tabs are untouched")


# ------------------------------------------------------------------ R9 defaults

func _test_defaults() -> void:
	begin("a fresh WizardState is at its defaults")
	var state := WizardState.new()
	assert_eq(state.days_per_week, 4, "default days_per_week is 4 (PRD-00 D5)")
	assert_eq(state.duration_min, 40, "default duration_min is 40 (PRD-00 D5)")
	assert_eq(state.goal, "", "the goal starts unanswered, every entry (PRD-00 D4)")
	assert_empty(state.areas, "no area is selected by default")
	assert_eq(state.notes, "", "notes start empty")
	assert_eq(state.seed, 0, "the seed is unassigned until the wizard generates")

	begin("the step enum is the R2 order")
	assert_eq(WizardState.STEP_NOTES, 0, "notes is step 0")
	assert_eq(WizardState.STEP_AREAS, 1, "areas is step 1")
	assert_eq(WizardState.STEP_DAYS, 2, "days is step 2")
	assert_eq(WizardState.STEP_DURATION, 3, "duration is step 3")
	assert_eq(WizardState.STEP_GOAL, 4, "goal is step 4")
	assert_eq(WizardState.STEP_REVIEW, 5, "review is step 5")
	assert_eq(WizardState.STEP_COUNT, 6, "there are six steps")
	assert_eq(WizardState.ANSWER_STEPS, 5, "and five of them are answers")


func _test_step_order_and_copy() -> void:
	begin("R2's titles and step indicators are verbatim")
	assert_eq(WizardState.STEP_TITLES.size(), WizardState.STEP_COUNT, "one title per step")
	assert_eq(WizardState.STEP_INDICATORS.size(), WizardState.STEP_COUNT,
		"one indicator per step")
	assert_eq(WizardState.STEP_TITLES[WizardState.STEP_NOTES], "What matters to you?", "step 1")
	assert_eq(WizardState.STEP_TITLES[WizardState.STEP_AREAS], "Which areas?", "step 2")
	assert_eq(WizardState.STEP_TITLES[WizardState.STEP_DAYS], "How many days a week?", "step 3")
	assert_eq(WizardState.STEP_TITLES[WizardState.STEP_DURATION], "How long per session?",
		"step 4")
	assert_eq(WizardState.STEP_TITLES[WizardState.STEP_GOAL], "What are you training for?",
		"step 5")
	assert_eq(WizardState.STEP_TITLES[WizardState.STEP_REVIEW], "Ready to build your week",
		"review")
	assert_eq(WizardState.STEP_INDICATORS[WizardState.STEP_NOTES], "STEP 1/5", "indicator 1")
	assert_eq(WizardState.STEP_INDICATORS[WizardState.STEP_GOAL], "STEP 5/5", "indicator 5")
	assert_eq(WizardState.STEP_INDICATORS[WizardState.STEP_REVIEW], "REVIEW", "review indicator")

	begin("R7's four goals match the appendix §6.2 keys and copy")
	assert_eq(WizardState.GOAL_KEYS.size(), 4, "four goals")
	assert_eq(", ".join(WizardState.GOAL_KEYS),
		"strength, hypertrophy, general_fitness, conditioning", "canonical stored keys")
	assert_eq(WizardState.GOAL_TITLES[2], "General fitness", "the display title, not the key")
	assert_eq(WizardState.GOAL_DESCRIPTIONS[0],
		"Heavy and low reps. 3–6 reps, 4–5 sets, long rests.", "strength copy")
	assert_eq(WizardState.GOAL_DESCRIPTIONS[1],
		"Build muscle. 8–12 reps, 3–4 sets, 75–90s rests.", "hypertrophy copy")
	assert_eq(WizardState.GOAL_DESCRIPTIONS[2],
		"Feel better all round. 8–15 reps, 2–3 sets, 60–75s rests.", "general fitness copy")
	assert_eq(WizardState.GOAL_DESCRIPTIONS[3],
		"Get your heart rate up. 12–20 reps, 2–3 sets, short rests.", "conditioning copy")
	assert_false(WizardState.GOAL_KEYS.has("general"),
		"`general` is banned (appendix R32) — only `general_fitness` is stored")

	begin("R6's duration segments are the five the appendix allows")
	assert_eq(WizardState.DURATION_OPTIONS.size(), 5, "five segments")
	assert_eq(WizardState.DURATION_OPTIONS[0], 20, "starts at 20 min")
	assert_eq(WizardState.DURATION_OPTIONS[4], 60, "ends at 60 min")
	assert_eq(WizardState.DEFAULT_DURATION_MIN, 40, "the default segment is 40 min")


# ------------------------------------------------------------------ R2.2 validity

func _test_step_validity() -> void:
	begin("only the notes step is valid on a fresh state")
	var state := WizardState.new()
	assert_true(state.is_step_valid(WizardState.STEP_NOTES),
		"empty notes are valid — they mean `no constraints` (R3)")
	assert_false(state.is_step_valid(WizardState.STEP_AREAS),
		"is_step_valid(STEP_AREAS) == false with zero areas")
	assert_true(state.is_step_valid(WizardState.STEP_DAYS), "the day default is in range")
	assert_true(state.is_step_valid(WizardState.STEP_DURATION), "the duration default is a segment")
	assert_false(state.is_step_valid(WizardState.STEP_GOAL),
		"is_step_valid(STEP_GOAL) == false with goal == \"\"")
	assert_false(state.is_step_valid(WizardState.STEP_REVIEW), "review needs every answer")
	assert_false(state.is_complete(), "and so the wizard is not complete")
	assert_eq(state.next_invalid_step(), WizardState.STEP_AREAS,
		"the first invalid step is the area step")

	begin("a fully answered state is valid at every step")
	var full := _answered()
	for step in range(WizardState.STEP_COUNT):
		assert_true(full.is_step_valid(step), "step %d valid" % step)
	assert_true(full.is_complete(), "every answer present")
	assert_eq(full.next_invalid_step(), -1, "nothing left to fix")

	begin("an out-of-range step index is never valid")
	assert_false(state.is_step_valid(-1), "negative index")
	assert_false(state.is_step_valid(WizardState.STEP_COUNT), "past the review step")


func _test_validation_messages() -> void:
	begin("R4's validation copy is exact, and only the area step has one")
	var state := WizardState.new()
	assert_eq(state.validation_message(WizardState.STEP_AREAS), "Pick at least one area to train.",
		"the area message is verbatim")
	assert_eq(state.validation_message(WizardState.STEP_GOAL), "",
		"the goal step disables Next without a sentence")
	assert_eq(state.validation_message(WizardState.STEP_NOTES), "", "notes never validate")
	assert_eq(state.validation_message(WizardState.STEP_DAYS), "",
		"the day step is always valid, so it says nothing")

	begin("a valid step has no message")
	var full := _answered()
	for step in range(WizardState.STEP_COUNT):
		assert_eq(full.validation_message(step), "", "step %d is silent when valid" % step)


# ------------------------------------------------------------------ R4 areas

func _test_area_selection() -> void:
	begin("areas keep insertion order and stay a user-area subset")
	var state := WizardState.new()
	state.toggle_area("core")
	state.toggle_area("chest")
	state.toggle_area("back")
	assert_eq(", ".join(state.areas), "core, chest, back", "insertion order is preserved")
	assert_eq(", ".join(state.area_labels()), "Core / Abs, Chest, Back",
		"labels come from Taxonomy, in the selected order")
	assert_true(state.is_step_valid(WizardState.STEP_AREAS), "one area is enough")

	begin("toggling the same area twice removes it")
	state.toggle_area("chest")
	assert_eq(", ".join(state.areas), "core, back", "chest was deselected")
	assert_eq(state.areas.size(), 2, "two areas remain")
	state.toggle_area("core")
	state.toggle_area("back")
	assert_empty(state.areas, "and now there are none")
	assert_false(state.is_step_valid(WizardState.STEP_AREAS), "zero areas is invalid again")

	begin("`mobility` is never selectable and unknown keys are refused")
	state.toggle_area("mobility")
	state.toggle_area("")
	state.toggle_area("quads")
	assert_empty(state.areas, "the reserved area and unknown keys never enter the model")
	assert_false(Taxonomy.is_user_area("mobility"), "the taxonomy agrees")

	begin("the seven canonical areas are all offerable, in the appendix order")
	for area in Taxonomy.USER_AREAS:
		var probe := WizardState.new()
		probe.set_area(area, true)
		assert_true(probe.areas.has(area), "%s is selectable" % area)
	assert_eq(", ".join(Taxonomy.USER_AREAS),
		"chest, back, shoulders, arms, core, legs, cardio", "the R4 grid order is the taxonomy's")

	begin("set_area is idempotent")
	var fixed := WizardState.new()
	fixed.set_area("legs", true)
	fixed.set_area("legs", true)
	assert_eq(fixed.areas.size(), 1, "selecting twice adds one entry")
	fixed.set_area("legs", false)
	fixed.set_area("legs", false)
	assert_empty(fixed.areas, "deselecting twice removes it once")


# ------------------------------------------------------------------ R5 / R6

func _test_days_and_duration() -> void:
	begin("days_per_week is clamped into 1..6 (appendix §6.4)")
	var state := WizardState.new()
	state.set_days_per_week(0)
	assert_eq(state.days_per_week, 1, "0 clamps up to 1")
	state.set_days_per_week(9)
	assert_eq(state.days_per_week, 6, "9 clamps down to 6 — 7 is settings-only")
	state.set_days_per_week(3)
	assert_eq(state.days_per_week, 3, "an in-range value is kept")
	assert_true(state.is_step_valid(WizardState.STEP_DAYS), "and the step stays valid")

	begin("duration accepts exactly R6's five segments")
	var duration := WizardState.new()
	for option in WizardState.DURATION_OPTIONS:
		assert_true(duration.set_duration_min(option), "%d min accepted" % option)
		assert_eq(duration.duration_min, option, "and stored")
	assert_false(duration.set_duration_min(45), "45 min is not a segment")
	assert_eq(duration.duration_min, 60, "a refused value leaves the previous one alone")
	assert_false(duration.set_duration_min(0), "0 min is not a segment")
	assert_eq(duration.duration_label(), "60 min", "the review row value")


# ------------------------------------------------------------------ R7 / D4

func _test_goal_every_time() -> void:
	begin("a fresh state, and a reset state, have no goal")
	var state := _answered()
	assert_eq(state.goal, "hypertrophy", "the answered state has one")
	state.reset()
	assert_eq(state.goal, "", "reset clears it")
	assert_eq(state.goal_label(), "", "and the label is empty rather than a default")

	begin("goal_label returns the R7 title, never the stored key")
	for key in WizardState.GOAL_KEYS:
		var probe := WizardState.new()
		assert_true(probe.set_goal(key), "%s is accepted" % key)
		assert_eq(probe.goal, key, "stored verbatim")
		assert_eq(probe.goal_label(), WizardState.GOAL_TITLES[WizardState.GOAL_KEYS.find(key)],
			"displayed as its title")

	begin("an unknown goal key is refused")
	var probe := WizardState.new()
	assert_false(probe.set_goal("general"), "`general` is banned (appendix R32)")
	assert_false(probe.set_goal(""), "the empty key is not a goal")
	assert_false(probe.set_goal("Strength"), "the display title is not the stored key")
	assert_eq(probe.goal, "", "and nothing was stored")
	assert_false(probe.is_step_valid(WizardState.STEP_GOAL), "the goal step stays blocked")


# ------------------------------------------------------------------ R3 notes

func _test_notes_rules() -> void:
	begin("notes are capped at 500 characters")
	var state := WizardState.new()
	state.set_notes("a".repeat(WizardState.NOTES_MAX))
	assert_eq(state.notes.length(), 500, "exactly the cap is allowed")
	assert_eq(state.notes_counter(), "500/500", "the counter shows it")
	state.set_notes("b".repeat(700))
	assert_eq(state.notes.length(), 500, "a paste longer than the cap is truncated")
	assert_eq(state.notes.substr(0, 3), "bbb", "from the front, so the caret can go to the end")
	assert_false(state.notes.ends_with("a"), "and it is not the old value")

	begin("the counter tracks every length, including zero")
	assert_eq(WizardState.new().notes_counter(), "0/500", "empty notes read 0/500")
	var counted := WizardState.new()
	counted.set_notes("Bench only")
	assert_eq(counted.notes_counter(), "10/500", "the live counter value")

	begin("R8's review preview trims, truncates at 60 and has a no-notes sentence")
	var blank := WizardState.new()
	assert_eq(blank.notes_preview(), "None — that's fine.", "the exact empty-state copy")
	var short := WizardState.new()
	short.set_notes("  No overhead pressing  ")
	assert_eq(short.notes_preview(), "No overhead pressing", "trimmed")
	var long := WizardState.new()
	long.set_notes("x".repeat(80))
	assert_eq(long.notes_preview().length(), 61, "60 characters plus the ellipsis")
	assert_true(long.notes_preview().ends_with("…"), "and it ends with an ellipsis")
	assert_eq(WizardState.new().notes.strip_edges(), "", "empty notes are valid (R3)")


# ------------------------------------------------------------------ R2.3 / R8

func _test_pristine_and_reset() -> void:
	begin("a fresh state is pristine")
	var state := WizardState.new()
	assert_true(state.is_pristine(), "all defaults and no notes")

	begin("any answer makes it no longer pristine")
	var touched := WizardState.new()
	touched.toggle_area("chest")
	assert_false(touched.is_pristine(), "an area was picked")
	var noted := WizardState.new()
	noted.set_notes("hello")
	assert_false(noted.is_pristine(), "notes were typed")
	var dayed := WizardState.new()
	dayed.set_days_per_week(5)
	assert_false(dayed.is_pristine(), "the day count moved")
	var timed := WizardState.new()
	timed.set_duration_min(60)
	assert_false(timed.is_pristine(), "the duration moved")
	var goaled := WizardState.new()
	goaled.set_goal("strength")
	assert_false(goaled.is_pristine(), "a goal was tapped")

	begin("whitespace-only notes still count as pristine")
	var spaces := WizardState.new()
	spaces.set_notes("   ")
	assert_true(spaces.is_pristine(), "a stray space is not an answer")
	spaces.set_notes("  squat  ")
	assert_false(spaces.is_pristine(), "real text is")

	begin("reset returns every field to its default and unsets the goal")
	var full := _answered()
	full.seed = 12345
	full.reset()
	assert_eq(full.goal, "", "goal cleared (R8: Start over)")
	assert_empty(full.areas, "areas cleared")
	assert_eq(full.days_per_week, 4, "days back to the default")
	assert_eq(full.duration_min, 40, "duration back to the default")
	assert_eq(full.notes, "", "notes cleared")
	assert_eq(full.seed, 0, "seed unassigned again")
	assert_true(full.is_pristine(), "and the state is pristine again")


# ------------------------------------------------------------------ R9 to_request

func _test_request_shape() -> void:
	begin("to_request has exactly R9's keys, always present")
	var state := _answered()
	var equipment: Array[String] = ["barbell", "dumbbell"]
	var request := state.to_request(equipment)
	var expected: PackedStringArray = [
		"goal", "areas", "days_per_week", "duration_min", "notes", "equipment", "seed",
	]
	assert_eq(request.size(), expected.size(), "seven keys, no more")
	for key in expected:
		assert_has_key(request, key, "R9 requires `%s`" % key)
		assert_ne(request[key], null, "`%s` is never null (R9)" % key)
	assert_eq(request["goal"], "hypertrophy", "the goal rides along")
	assert_eq(request["days_per_week"], 4, "days")
	assert_eq(request["duration_min"], 40, "duration")
	assert_eq(", ".join(request["areas"]), "chest, back, core", "areas in pick order")
	assert_eq(", ".join(request["equipment"]), "barbell, dumbbell", "equipment verbatim")
	assert_eq(request["seed"], 777, "the seed the wizard assigned")

	begin("notes reach the request with only the edges trimmed (R3)")
	var noted := WizardState.new()
	noted.set_notes("  Bad shoulder on the left.  ")
	assert_eq(noted.to_request(equipment)["notes"], "Bad shoulder on the left.",
		"the primary personalisation channel arrives unchanged")
	var blank := WizardState.new()
	assert_eq(blank.to_request(equipment)["notes"], "", "empty stays empty, never null")

	begin("the request copies the equipment array rather than aliasing it")
	var aliased := WizardState.new()
	var source: Array[String] = ["barbell"]
	var built := aliased.to_request(source)
	source.append("cable")
	assert_eq(", ".join(built["equipment"]), "barbell", "the request is a snapshot")

	begin("the built-in generator accepts the request unchanged")
	var plan := Generator.build_plan(state.to_request(equipment), 777)
	assert_false(plan.has("error"), "the generator takes R9's shape as-is")
	assert_eq(int(plan["days_per_week"]), 4, "and honours the day count")
	assert_eq(String(plan["goal"]), "hypertrophy", "and the goal")


# ------------------------------------------------------------------ R9 drafts

func _test_draft_round_trip() -> void:
	begin("to_dict has R9's draft shape")
	var state := _answered()
	var draft := state.to_dict("2026-09-15T12:00:00Z")
	var expected: PackedStringArray = [
		"areas", "days_per_week", "duration_min", "notes", "saved_at",
	]
	assert_eq(draft.size(), expected.size(), "five keys, no more")
	for key in expected:
		assert_has_key(draft, key, "R9 requires `%s`" % key)
	assert_eq(draft["saved_at"], "2026-09-15T12:00:00Z", "the stamp is injectable")
	assert_eq(", ".join(draft["areas"]), "chest, back, core", "areas survive")
	assert_eq(draft["days_per_week"], 4, "days survive")
	assert_eq(draft["duration_min"], 40, "duration survives")
	assert_eq(draft["notes"], "Bad shoulder on the left.", "notes survive")

	begin("apply_dict restores every persisted field")
	var restored := WizardState.new()
	restored.apply_dict(draft)
	assert_eq(", ".join(restored.areas), "chest, back, core", "areas restored in order")
	assert_eq(restored.days_per_week, 4, "days restored")
	assert_eq(restored.duration_min, 40, "duration restored")
	assert_eq(restored.notes, "Bad shoulder on the left.", "notes restored")
	assert_false(restored.is_complete(),
		"but the state is still incomplete: the goal is missing (D4)")
	assert_eq(restored.next_invalid_step(), WizardState.STEP_GOAL,
		"and the goal step is exactly what is missing")

	begin("apply_dict ignores junk instead of trusting it")
	var guarded := WizardState.new()
	guarded.apply_dict({
		"areas": ["chest", "mobility", "quads", "chest", 7, ""],
		"days_per_week": 99,
		"duration_min": 45,
		"notes": "ok",
	})
	assert_eq(", ".join(guarded.areas), "chest", "only real, unique user areas survive")
	assert_eq(guarded.days_per_week, 6, "an out-of-range day count clamps into 1..6")
	assert_eq(guarded.duration_min, 40, "a duration that is not a segment falls back to 40")
	assert_eq(guarded.notes, "ok", "the notes are kept")

	begin("an empty dictionary changes nothing")
	var untouched := _answered()
	untouched.apply_dict({})
	assert_eq(untouched.goal, "hypertrophy", "the goal is untouched")
	assert_eq(untouched.days_per_week, 4, "the days are untouched")
	assert_eq(untouched.notes, "Bad shoulder on the left.", "the notes are untouched")


func _test_draft_never_carries_the_goal() -> void:
	begin("to_dict() contains no `goal` key (AC1 / PRD-00 D4)")
	var state := _answered()
	var draft := state.to_dict()
	assert_false(draft.has("goal"), "to_dict() containing no `goal` key")
	assert_false(draft.has("seed"), "and no seed either")

	begin("a hand-written `goal` in the draft cannot pre-answer the step")
	var smuggled := state.to_dict()
	smuggled["goal"] = "strength"
	smuggled["seed"] = 99
	var restored := WizardState.new()
	restored.apply_dict(smuggled)
	assert_eq(restored.goal, "", "the goal is cleared on load, whatever the file says")
	assert_eq(restored.seed, 0, "and so is the seed")
	assert_false(restored.is_step_valid(WizardState.STEP_GOAL), "the step is still blocked")

	begin("a round trip through to_dict never resurrects the goal")
	var cycled := _answered()
	cycled.apply_dict(cycled.to_dict())
	assert_eq(cycled.goal, "", "goal lost, by design")


func _test_draft_freshness() -> void:
	begin("a draft stamped now is fresh")
	var draft := WizardState.new().to_dict("2026-09-15T12:00:00Z")
	var stamp := WizardState.unix_from_iso("2026-09-15T12:00:00Z")
	assert_gt(float(stamp), 0.0, "the ISO stamp parses to a Unix time")
	assert_true(WizardState.is_fresh(draft, stamp), "same instant is fresh")

	begin("29 days is fresh, 31 days is not (R9)")
	assert_true(WizardState.is_fresh(draft, stamp + 29 * DAY), "inside the window")
	assert_true(WizardState.is_fresh(draft, stamp + 30 * DAY), "exactly 30 days still counts")
	assert_false(WizardState.is_fresh(draft, stamp + 31 * DAY), "outside the window")
	assert_false(WizardState.is_fresh(draft, stamp + 400 * DAY), "long stale")

	begin("a draft with no usable stamp is not fresh")
	assert_false(WizardState.is_fresh({}, NOW), "an empty draft is never fresh")
	assert_false(WizardState.is_fresh({"areas": ["chest"]}, NOW), "no saved_at at all")
	assert_false(WizardState.is_fresh({"saved_at": "not a date"}, NOW), "an unparseable stamp")
	assert_false(WizardState.is_fresh({"saved_at": ""}, NOW), "an empty stamp")
	assert_false(WizardState.is_fresh({"saved_at": "2026-09-15"}, stamp + 400 * DAY),
		"a date-only stamp parses as midnight — and 400 days later it is stale")

	begin("a stamp in the future is kept rather than deleted")
	var future := (NOW + 10 * DAY)
	var future_iso := Time.get_datetime_string_from_unix_time(future, true) + "Z"
	assert_true(WizardState.is_fresh({"saved_at": future_iso}, NOW),
		"a clock that moved backwards must not cost the owner their answers")


func _test_full_dict_round_trip() -> void:
	begin("to_full_dict carries the goal and seed for the in-process hand-off")
	var state := _answered()
	state.seed = 4242
	var full := state.to_full_dict()
	assert_eq(full.size(), 6, "six fields")
	assert_eq(full["goal"], "hypertrophy", "including the goal")
	assert_eq(full["seed"], 4242, "and the seed")
	assert_false(full.has("saved_at"), "but it is not a draft: no stamp")

	begin("apply_full_dict restores the goal the preview handed back")
	var back := WizardState.new()
	back.apply_full_dict(full)
	assert_eq(back.goal, "hypertrophy", "goal restored")
	assert_eq(back.seed, 4242, "seed restored")
	assert_eq(", ".join(back.areas), "chest, back, core", "areas restored")
	assert_eq(back.notes, "Bad shoulder on the left.", "notes restored")
	assert_true(back.is_complete(), "the state comes back complete")

	begin("apply_full_dict still refuses a junk goal")
	var guarded := WizardState.new()
	guarded.apply_full_dict({"goal": "general", "areas": ["legs"], "days_per_week": 2})
	assert_eq(guarded.goal, "", "`general` is not restored")
	assert_eq(guarded.days_per_week, 2, "the valid fields are")
	assert_eq(guarded.seed, 0, "a missing seed is 0")


func _test_invalid_input_is_safe() -> void:
	begin("the model never throws on nonsense input")
	var state := WizardState.new()
	state.apply_dict({"areas": "chest", "days_per_week": "four", "notes": 12})
	assert_empty(state.areas, "a string is not an area list")
	assert_eq(state.days_per_week, 4, "a non-numeric day count falls back to the default")
	assert_eq(state.notes, "12", "a non-string note becomes its text form")
	assert_false(state.is_complete(), "and the state is still incomplete")

	begin("unix_from_iso rejects everything that is not a timestamp")
	assert_eq(WizardState.unix_from_iso(""), 0, "empty")
	assert_eq(WizardState.unix_from_iso("2026-13-45T99:99:99Z"), 0, "an impossible date")
	assert_eq(WizardState.unix_from_iso("1758000000"), 0, "a bare epoch number")
	assert_gt(float(WizardState.unix_from_iso("2026-09-15")), 0.0,
		"a date-only stamp parses as midnight (Dates' documented behaviour)")


# ------------------------------------------------------------------ helpers

## A complete, valid state: four areas, four days, 40 minutes, hypertrophy, notes.
func _answered() -> WizardState:
	var state := WizardState.new()
	state.set_goal("hypertrophy")
	state.toggle_area("chest")
	state.toggle_area("back")
	state.toggle_area("core")
	state.set_days_per_week(4)
	state.set_duration_min(40)
	state.set_notes("Bad shoulder on the left.")
	state.seed = 777
	return state
