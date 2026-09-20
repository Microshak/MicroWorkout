extends TestSuite
## PRD-05 R15 / PRD-10 R15 — the next-session advice.
##
## The completion screen shows exactly one line of this, so the suite pins the four goal strings,
## the unknown-goal fallback, the third-session consistency sentence, the plan filter that stops a
## second plan's entries from counting, and the two display helpers (`first_line`, `clip`) that the
## card relies on.

const STRENGTH := "Next session: if you hit the top of every rep range, add 2.5–5 lb to the bar. " \
	+ "If you missed reps, keep the weight the same."
const HYPERTROPHY := "Next session: add one rep per set until you reach the top of the range, then " \
	+ "add the smallest weight jump you have and drop back to the bottom of the range."
const GENERAL := "Next session: aim for one more rep than last time on your first set of each exercise."
const CONDITIONING := "Next session: shorten your rest by 5 seconds or add one round — not both."


func _init() -> void:
	suite_name = "progression"


func run() -> void:
	_test_goal_strings()
	_test_consistency()
	_test_plan_filter()
	_test_line_helpers()


func _plan(goal: String, id: String = "plan-1") -> Dictionary:
	return {"id": id, "goal": goal, "sessions": [{"id": "s1", "title": "Upper A"}]}


func _session() -> Dictionary:
	return {"id": "s1", "title": "Upper A"}


# ------------------------------------------------------------------ goal strings

func _test_goal_strings() -> void:
	begin("R15 each goal returns its own fixed sentence")
	assert_eq(Progression.advise(_plan("strength"), _session(), []), STRENGTH)
	assert_eq(Progression.advise(_plan("hypertrophy"), _session(), []), HYPERTROPHY)
	assert_eq(Progression.advise(_plan("general_fitness"), _session(), []), GENERAL)
	assert_eq(Progression.advise(_plan("conditioning"), _session(), []), CONDITIONING)

	begin("R15 PRD-05's `general` spelling is accepted as well as the schema's `general_fitness`")
	assert_eq(Progression.advise(_plan("general"), _session(), []), GENERAL)

	begin("R15 an unknown or missing goal falls back to the general sentence")
	assert_eq(Progression.advise(_plan("mobility"), _session(), []), GENERAL)
	assert_eq(Progression.advise({"id": "plan-1", "sessions": []}, _session(), []), GENERAL)
	assert_eq(Progression.advise(_plan("STRENGTH"), _session(), []), STRENGTH,
		"the goal is compared case-insensitively")

	begin("R15 no goal string is empty and none is longer than the card can show without clipping")
	for goal in PlanModel.GOALS:
		var line: String = Progression.advise(_plan(goal), _session(), [])
		assert_not_empty(line, goal)
		assert_true(line.begins_with("Next session:"), goal)

	begin("R15 an unresolvable session returns an empty string, the fallback trigger")
	assert_eq(Progression.advise(_plan("strength"), {}, []), "",
		"the player lost its session under itself: the screen shows its own fallback copy")


# ------------------------------------------------------------------ completed_sessions

func _test_consistency() -> void:
	var plan := _plan("strength")

	begin("R15 the consistency sentence appears from the third completed session")
	assert_eq(Progression.completed_sessions(plan, []), 0)
	var one := Progression.advise(plan, _session(), [_entry("plan-1", true)])
	assert_eq(one, STRENGTH, "two sessions is not yet a streak")
	var two := Progression.advise(plan, _session(), [
		_entry("plan-1", true), _entry("plan-1", true),
	])
	assert_eq(two, STRENGTH)
	var three := Progression.advise(plan, _session(), [
		_entry("plan-1", true), _entry("plan-1", true), _entry("plan-1", true),
	])
	assert_true(three.begins_with(STRENGTH), "the goal line is still first")
	assert_true(three.contains("consistency is doing the work"))
	assert_true(three.contains("3 sessions on this plan"), "the count is real: %s" % three)
	assert_eq(Progression.first_line(three), STRENGTH, "the card shows only the goal line")

	begin("N3 a partial entry is history but is not a finished session")
	var partial := Progression.advise(plan, _session(), [
		_entry("plan-1", true), _entry("plan-1", true), _entry("plan-1", false),
	])
	assert_eq(partial, STRENGTH, "2 completed + 1 partial is not three sessions")
	assert_eq(Progression.completed_sessions(plan, [
		_entry("plan-1", true), _entry("plan-1", false),
	]), 1)


func _test_plan_filter() -> void:
	begin("R15 only this plan's completed entries count")
	var plan := _plan("hypertrophy", "plan-2")
	var history: Array = [
		_entry("plan-1", true), _entry("plan-1", true), _entry("plan-1", true),
		_entry("plan-2", true),
	]
	assert_eq(Progression.completed_sessions(plan, history), 1)
	var advice := Progression.advise(plan, _session(), history)
	assert_false(advice.contains("consistency"), "another plan's sessions do not count: %s" % advice)

	begin("R15 a plan with no id never claims a history")
	assert_eq(Progression.completed_sessions({"goal": "strength"}, [
		_entry("", true), _entry("plan-1", true),
	]), 0)

	begin("R15 junk in the history array is skipped, not trusted")
	var junk: Array = [null, "nope", 42, _entry("plan-2", true)]
	assert_eq(Progression.completed_sessions(plan, junk), 1)


func _entry(plan_id: String, completed: bool) -> Dictionary:
	return {"id": "h-1", "plan_id": plan_id, "date": "2026-09-15", "completed": completed}


# ------------------------------------------------------------------ display helpers

func _test_line_helpers() -> void:
	begin("R12 first_line takes line 0 of a multi-line advice")
	assert_eq(Progression.first_line("one\ntwo"), "one")
	assert_eq(Progression.first_line("  one  \n two"), "one")
	assert_eq(Progression.first_line("one"), "one")
	assert_eq(Progression.first_line(""), "")

	begin("R12 clip shortens long advice at a word boundary inside the limit")
	var long := Progression.advise(_plan("hypertrophy"), _session(), [])
	var clipped := Progression.clip(long)
	assert_true(clipped.length() <= Progression.DISPLAY_LIMIT + 1, "clipped to the limit: %d" % clipped.length())
	assert_true(clipped.ends_with(Progression.ELLIPSIS))
	assert_true(long.begins_with(clipped.substr(0, clipped.length() - 1).strip_edges()))

	begin("R12 clip leaves short text exactly as it is")
	assert_eq(Progression.clip("short line"), "short line")
	assert_eq(Progression.clip("  padded  "), "padded")
	assert_eq(Progression.clip(""), "")
	assert_eq(Progression.clip("abcdef", 3), "abc…", "an unbroken word is cut at the limit")
	assert_eq(Progression.clip("abcdef", 0), "abcdef", "a non-positive limit disables clipping")

	begin("R12 every goal's advice is presentable on the card after clipping")
	for goal in PlanModel.GOALS:
		var line := Progression.clip(Progression.first_line(
			Progression.advise(_plan(goal), _session(), [])))
		assert_not_empty(line, goal)
		assert_true(line.length() <= Progression.DISPLAY_LIMIT + 1, goal)
