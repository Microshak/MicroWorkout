extends TestSuite
## PRD-09 R3/R4 / AC1 — the pure Home state builder.
##
## Two things this suite exists to pin down:
## 1. the greeting matrix, **verbatim** — all 12 time × today × streak cells plus the three
##    plan-independent overrides (a copy change must be a deliberate test change);
## 2. the five states by R3's precedence, the week-strip kinds, the cycle index wrap-around and
##    the `NO_PLAN` ring's `0/0` (never `NaN`).
##
## Every case is a fixed date, so the suite never depends on the wall clock.

## The fixture week: Monday 2026-09-14 … Sunday 2026-09-20.
const MONDAY := "2026-09-14"
const TUESDAY := "2026-09-15"
const WEDNESDAY := "2026-09-16"
const THURSDAY := "2026-09-17"
const FRIDAY := "2026-09-18"
const SATURDAY := "2026-09-19"
const SUNDAY := "2026-09-20"
const NEXT_MONDAY := "2026-09-21"

const PLAN_ID := "plan-1757941200"


func _init() -> void:
	suite_name = "home_state"


func run() -> void:
	_test_greeting_matrix()
	_test_greeting_overrides()
	_test_format_streak()
	_test_state_precedence()
	_test_no_plan_state()
	_test_training_state()
	_test_done_today_state()
	_test_rest_state()
	_test_plan_finished_state()
	_test_week_strip()
	_test_next_up_wrap_around()
	_test_derived_values_pass_through()
	_test_robustness()


# ------------------------------------------------------------------ R4 greeting matrix (AC1)

func _test_greeting_matrix() -> void:
	begin("morning · training (streak 0 / > 0)")
	assert_eq(HomeState.greeting_for(HomeState.TRAINING, "morning", 0),
		"Morning. Here's what's on for today.", "morning training, no streak")
	assert_eq(HomeState.greeting_for(HomeState.TRAINING, "morning", 3),
		"Morning. 3 in a row — let's keep it going.", "morning training, streak 3")

	begin("morning · rest (streak 0 / > 0)")
	assert_eq(HomeState.greeting_for(HomeState.REST, "morning", 0),
		"Morning. Nothing planned today.", "morning rest, no streak")
	assert_eq(HomeState.greeting_for(HomeState.REST, "morning", 1),
		"Morning. Rest today — 1 in a row so far.", "morning rest, streak 1")

	begin("afternoon · training (streak 0 / > 0)")
	assert_eq(HomeState.greeting_for(HomeState.TRAINING, "afternoon", 0),
		"Afternoon. Your session is ready when you are.", "afternoon training, no streak")
	assert_eq(HomeState.greeting_for(HomeState.TRAINING, "afternoon", 3),
		"Afternoon. 3 on the line — today's session is ready.", "afternoon training, streak 3")

	begin("afternoon · rest (streak 0 / > 0)")
	assert_eq(HomeState.greeting_for(HomeState.REST, "afternoon", 0),
		"Afternoon. Nothing planned today.", "afternoon rest, no streak")
	assert_eq(HomeState.greeting_for(HomeState.REST, "afternoon", 3),
		"Afternoon. Rest day — 3 in a row so far.", "afternoon rest, streak 3")

	begin("evening · training (streak 0 / > 0, {n+1} computed)")
	assert_eq(HomeState.greeting_for(HomeState.TRAINING, "evening", 0),
		"Evening. Still time to get today's session in.", "evening training, no streak")
	assert_eq(HomeState.greeting_for(HomeState.TRAINING, "evening", 3),
		"Evening. 3 in a row — one more makes it 4.", "evening training, streak 3 (R4's example)")
	assert_eq(HomeState.greeting_for(HomeState.TRAINING, "evening", 41),
		"Evening. 41 in a row — one more makes it 42.", "the +1 is computed, not templated")

	begin("evening · rest (streak 0 / > 0)")
	assert_eq(HomeState.greeting_for(HomeState.REST, "evening", 0),
		"Evening. Nothing planned today.", "evening rest, no streak")
	assert_eq(HomeState.greeting_for(HomeState.REST, "evening", 3),
		"Evening. Rest today — 3 in a row so far.", "evening rest, streak 3")

	begin("the time bands are 05:00–11:59 / 12:00–17:59 / 18:00–04:59")
	assert_eq(HomeState.band_of({"hour": 4}), "evening", "04:59 is evening")
	assert_eq(HomeState.band_of({"hour": 5}), "morning", "05:00 is morning")
	assert_eq(HomeState.band_of({"hour": 11}), "morning", "11:59 is morning")
	assert_eq(HomeState.band_of({"hour": 12}), "afternoon", "12:00 is afternoon")
	assert_eq(HomeState.band_of({"hour": 17}), "afternoon", "17:59 is afternoon")
	assert_eq(HomeState.band_of({"hour": 18}), "evening", "18:00 is evening")
	assert_eq(HomeState.band_of({"hour": 23}), "evening", "23:59 is evening")
	assert_eq(HomeState.band_of({"hour": 0}), "evening", "midnight folds into evening")


func _test_greeting_overrides() -> void:
	begin("NO_PLAN overrides the matrix per band")
	assert_eq(HomeState.greeting_for(HomeState.NO_PLAN, "morning", 0),
		"Morning. Let's build your first week.", "morning")
	assert_eq(HomeState.greeting_for(HomeState.NO_PLAN, "afternoon", 7),
		"Afternoon. Let's build your first week.", "afternoon, streak ignored")
	assert_eq(HomeState.greeting_for(HomeState.NO_PLAN, "evening", 0),
		"Evening. Let's build your first week.", "evening")

	begin("DONE_TODAY and PLAN_FINISHED are band-independent")
	assert_eq(HomeState.greeting_for(HomeState.DONE_TODAY, "morning", 0),
		"Nice — today's session is done.", "done today, morning")
	assert_eq(HomeState.greeting_for(HomeState.DONE_TODAY, "evening", 4),
		"Nice — today's session is done.", "done today, evening")
	assert_eq(HomeState.greeting_for(HomeState.PLAN_FINISHED, "afternoon", 9),
		"That plan is complete. Nice work.", "plan finished")


func _test_format_streak() -> void:
	begin("format_streak pluralises exactly once")
	assert_eq(HomeState.format_streak(0), "0 days", "zero")
	assert_eq(HomeState.format_streak(1), "1 day", "one")
	assert_eq(HomeState.format_streak(2), "2 days", "two")

	begin("the cover title never changes")
	assert_eq(HomeState.TITLE, "Hey Workout", "PRD-00 §4.3's signature line")


# ------------------------------------------------------------------ R3 states (AC1)

func _test_state_precedence() -> void:
	begin("no active plan is NO_PLAN")
	var state := _build(_empty_plans(), [], _now(WEDNESDAY, 9))
	assert_eq(state["state"], HomeState.NO_PLAN, "no plan")
	assert_eq(state["plan"], {} as Dictionary, "no plan dictionary")
	assert_eq(state["session"], {} as Dictionary, "no session")
	assert_eq(state["next_session"], {} as Dictionary, "no next session")
	assert_eq(state["early_label"], "", "no early action")
	assert_false(bool(state["early_available"]), "no early option")

	begin("a training weekday with nothing done is TRAINING")
	var plan := _plan(3, "2026-09-14T06:00:00Z")
	var training := _build(_plans(plan), [], _now(WEDNESDAY, 9))
	assert_eq(training["state"], HomeState.TRAINING, "Wednesday on a Mon/Wed/Fri plan")
	assert_eq(_session_id(training["session"]), "s1", "the first session is still waiting")
	assert_eq(int(training["session_index"]), 0, "index 0")

	begin("a completed entry today outranks a training day")
	var done_entries: Array = [_entry(WEDNESDAY, "s1")]
	var done := _build(_plans(plan), done_entries, _now(WEDNESDAY, 9))
	assert_eq(done["state"], HomeState.DONE_TODAY, "done today")

	begin("a rest weekday is REST")
	var four_day := _plan(4, "2026-09-14T06:00:00Z")
	var rest := _build(_plans(four_day), [], _now(WEDNESDAY, 9))
	assert_eq(rest["state"], HomeState.REST, "Wednesday on a Mon/Tue/Thu/Fri plan")

	begin("PLAN_FINISHED outranks everything else (R3 rule 1)")
	var finished := _build(_plans(plan), _four_cycles(), _now(WEDNESDAY, 9))
	assert_eq(finished["state"], HomeState.PLAN_FINISHED, "every session has four completions")
	assert_eq(int(finished["cycles"]), 4, "cycles is the smallest per-session count")
	assert_eq(int(finished["total_sessions"]), 12, "twelve completed sessions")
	assert_eq(int(finished["total_duration_sec"]), 12 * 2400, "total active seconds")

	begin("a finished plan is still finished when today was also trained")
	var finished_today := _build(_plans(plan), _four_cycles(true), _now(WEDNESDAY, 9))
	assert_eq(finished_today["state"], HomeState.PLAN_FINISHED, "rule 1 first")

	begin("three cycles are not finished")
	var short := _build(_plans(plan), _cycles(3), _now(WEDNESDAY, 9))
	assert_true(short["state"] != HomeState.PLAN_FINISHED, "not finished")
	assert_eq(int(short["cycles"]), 3, "three cycles")


func _test_no_plan_state() -> void:
	begin("NO_PLAN shows seven rest pills and a 0/0 ring (R10)")
	var state := _build(_empty_plans(), [], _now(WEDNESDAY, 9))
	assert_eq(state["strip_kinds"], _kinds(["rest", "rest", "rest", "rest", "rest", "rest", "rest"]),
		"all rest")
	assert_eq(int(state["week_completed"]), 0, "no completed days")
	assert_eq(int(state["week_target"]), 0, "0/0, never NaN")
	assert_eq(float(state["week_fraction"]), 0.0, "no fill")
	assert_eq(_session_id(state["session"]), "", "no session")

	begin("NO_PLAN's derived numbers are forced to zero even if Store reports a goal")
	var derived := {"streak": 4, "week_completed": 3, "week_target": 4, "week_fraction": 0.75,
		"ring_bits": PackedByteArray([1, 1, 1, 0, 0, 0, 0])}
	var state2 := _build(_empty_plans(), [], _now(WEDNESDAY, 9), derived)
	assert_eq(int(state2["week_completed"]), 0, "the ring reads 0/0")
	assert_eq(int(state2["week_target"]), 0, "0/0")
	assert_eq(float(state2["week_fraction"]), 0.0, "an empty arc")
	assert_eq(int(state2["streak"]), 4, "but the streak tile still shows the live streak")

	begin("a dangling active_plan_id is treated as no plan")
	var dangling := {"schema_version": 1, "active_plan_id": PLAN_ID, "plans": []}
	assert_eq(_build(dangling, [], _now(WEDNESDAY, 9))["state"], HomeState.NO_PLAN, "dangling")


func _test_training_state() -> void:
	begin("TRAINING shows today's session, index and next-up (R5/R9)")
	var plan := _plan(4, "2026-09-14T06:00:00Z")
	var entries: Array = [_entry(MONDAY, "s1"), _entry(TUESDAY, "s2")]
	var state := _build(_plans(plan), entries, _now(THURSDAY, 7))
	assert_eq(state["state"], HomeState.TRAINING, "Thursday is a planned day")
	assert_eq(int(state["session_index"]), 2, "two sessions consumed")
	assert_eq(_session_id(state["session"]), "s3", "today's session")
	assert_eq(int(state["next_session_index"]), 3, "the one after it")
	assert_eq(_session_id(state["next_session"]), "s4", "next up")
	assert_eq(String(state["next_weekday_name"]), "Friday", "tomorrow")
	assert_eq(int(state["next_days_ahead"]), 1, "one day ahead")
	assert_eq(String(state["early_label"]), "", "no early action while today is due")

	begin("TRAINING's greeting follows the band and the streak")
	var morning := _build(_plans(plan), entries, _now(THURSDAY, 7), _derived(2))
	assert_eq(String(morning["greeting"]), "Morning. 2 in a row — let's keep it going.",
		"morning, streak 2")
	var evening := _build(_plans(plan), entries, _now(THURSDAY, 20), _derived(2))
	assert_eq(String(evening["greeting"]), "Evening. 2 in a row — one more makes it 3.",
		"evening, streak 2")

	begin("TRAINING carries the plan and its days_per_week")
	assert_eq(_session_id(state["plan"]), PLAN_ID, "the active plan")
	assert_eq(int(state["days_per_week"]), 4, "the plan's cadence")
	assert_eq(int(state["session_index"]), 2, "index for the today card")


func _test_done_today_state() -> void:
	begin("DONE_TODAY carries the finished entry and offers the early session (R11)")
	var plan := _plan(3, "2026-09-14T06:00:00Z")
	var entries: Array = [_entry(MONDAY, "s1"), _entry(WEDNESDAY, "s2", true, PLAN_ID, 2700)]
	var state := _build(_plans(plan), entries, _now(WEDNESDAY, 20))
	assert_eq(state["state"], HomeState.DONE_TODAY, "trained today")
	assert_eq(String(state["done_entry"].get("session_id", "")), "s2", "the day's first entry")
	assert_eq(int(state["done_minutes"]), 45, "2700 s is 45 min")
	assert_true(bool(state["early_available"]), "the next session can be done early")
	assert_eq(_session_id(state["next_session"]), "s3", "the next session")
	assert_eq(String(state["next_weekday_name"]), "Today",
		"today is still a planned day, so the next session can happen today")
	assert_eq(int(state["next_days_ahead"]), 0, "zero days ahead")
	assert_eq(String(state["next_scheduled_weekday_name"]), "Friday",
		"…but it is normally Friday's session")
	assert_eq(String(state["early_label"]), "Do Friday early", "R11's button label")

	begin("DONE_TODAY on a rest day names the real next weekday")
	var four_day := _plan(4, "2026-09-14T06:00:00Z")
	var rest_done: Array = [_entry(WEDNESDAY, "s1")]
	var on_rest := _build(_plans(four_day), rest_done, _now(WEDNESDAY, 20))
	assert_eq(on_rest["state"], HomeState.DONE_TODAY, "training on a rest day still counts")
	assert_eq(String(on_rest["next_weekday_name"]), "Thursday", "the next planned day")
	assert_eq(int(on_rest["next_days_ahead"]), 1, "tomorrow")
	assert_eq(String(on_rest["early_label"]), "Do Thursday early", "R11's label")

	begin("the Done body reads the day's first session duration")
	assert_eq(String(state["greeting"]), "Nice — today's session is done.", "R4 override")

	begin("two sessions in one day keep the first entry's numbers (R11)")
	var twice: Array = [
		_entry(WEDNESDAY, "s1", true, PLAN_ID, 1800),
		_entry(WEDNESDAY, "s2", true, PLAN_ID, 2700),
	]
	var second := _build(_plans(plan), twice, _now(WEDNESDAY, 21))
	assert_eq(second["state"], HomeState.DONE_TODAY, "still DONE_TODAY")
	assert_eq(int(second["done_minutes"]), 30, "the first entry")
	assert_true(bool(second["early_available"]), "repetition is never blocked")


func _test_rest_state() -> void:
	begin("REST names the next session and its weekday (R12)")
	var plan := _plan(4, "2026-09-14T06:00:00Z")
	var entries: Array = [_entry(MONDAY, "s1"), _entry(TUESDAY, "s2")]
	var state := _build(_plans(plan), entries, _now(WEDNESDAY, 12))
	assert_eq(state["state"], HomeState.REST, "Wednesday is not a planned day")
	assert_eq(_session_id(state["next_session"]), "s3", "the next session")
	assert_eq(String(state["next_weekday_name"]), "Thursday", "tomorrow")
	assert_eq(int(state["next_days_ahead"]), 1, "one day ahead")
	assert_eq(String(state["early_label"]), "Do Thursday early", "the early button")
	assert_true(bool(state["early_available"]), "the early option is offered")

	begin("REST keeps the live streak (grace until end of day, PRD-00 §5.4)")
	var rested := _build(_plans(plan), entries, _now(WEDNESDAY, 12), _derived(2))
	assert_eq(int(rested["streak"]), 2, "the streak survives a rest day")
	assert_eq(String(rested["greeting"]), "Afternoon. Rest day — 2 in a row so far.",
		"R4's rest column")

	begin("REST with no streak")
	var fresh := _build(_plans(plan), [], _now(WEDNESDAY, 12))
	assert_eq(String(fresh["greeting"]), "Afternoon. Nothing planned today.", "no streak")

	begin("a rest day trained flips to DONE_TODAY with no special handling (R12)")
	var trained: Array = [_entry(WEDNESDAY, "s3")]
	assert_eq(_build(_plans(plan), trained, _now(WEDNESDAY, 18))["state"],
		HomeState.DONE_TODAY, "state flipped")


func _test_plan_finished_state() -> void:
	begin("PLAN_FINISHED hides the next-up card's content and counts the cycles (R13)")
	var plan := _plan(3, "2026-08-03T06:00:00Z")
	var state := _build(_plans(plan), _four_cycles(), _now(WEDNESDAY, 9))
	assert_eq(state["state"], HomeState.PLAN_FINISHED, "finished")
	assert_eq(_session_id(state["session"]), "", "no today session")
	assert_eq(_session_id(state["next_session"]), "", "nothing next")
	assert_eq(int(state["cycles"]), 4, "four weeks of it")
	assert_eq(int(state["total_sessions"]), 12, "twelve sessions")
	assert_eq(floori(float(int(state["total_duration_sec"])) / 60.0), 480, "480 min total")
	assert_eq(String(state["greeting"]), "That plan is complete. Nice work.", "R4 override")

	begin("PLAN_FINISHED shows every pill done and no early option")
	assert_eq(state["strip_kinds"], _kinds(["done", "done", "done", "done", "done", "done", "done"]),
		"all done")
	assert_eq(String(state["early_label"]), "", "no early button")
	assert_false(bool(state["early_available"]), "no early option")


# ------------------------------------------------------------------ R6 week strip

func _test_week_strip() -> void:
	begin("a 4-day plan mid-week: Monday done, Tuesday today, Thursday upcoming")
	var plan := _plan(4, "2026-09-14T06:00:00Z")
	var entries: Array = [_entry(MONDAY, "s1")]
	var state := _build(_plans(plan), entries, _now(TUESDAY, 9))
	assert_eq(state["strip_kinds"],
		_kinds(["done", "today", "rest", "upcoming", "upcoming", "rest", "rest"]),
		"the R6 rules in order")

	begin("the strip carries the weekday number, letter and date")
	var strip: Array = state["week_strip"]
	assert_eq(strip.size(), 7, "seven pills")
	assert_eq(int(strip[0]["weekday_iso"]), 1, "Monday first")
	assert_eq(String(strip[0]["letter"]), "M", "M")
	assert_eq(String(strip[0]["date"]), MONDAY, "Monday's date")
	assert_eq(int(strip[6]["weekday_iso"]), 7, "Sunday last")
	assert_eq(String(strip[6]["letter"]), "S", "S")
	assert_eq(String(strip[6]["date"]), SUNDAY, "Sunday's date")

	begin("a past planned day with no entry is missed")
	var thursday := _build(_plans(plan), [_entry(MONDAY, "s1"), _entry(TUESDAY, "s2")],
		_now(FRIDAY, 9))
	assert_eq(thursday["strip_kinds"],
		_kinds(["done", "done", "rest", "missed", "today", "rest", "rest"]),
		"Thursday was skipped")

	begin("days before the cycle started are never 'missed'")
	var later_plan := _plan(4, "2026-09-17T06:00:00Z")
	var fresh := _build(_plans(later_plan), [], _now(FRIDAY, 9))
	assert_eq(fresh["strip_kinds"],
		_kinds(["upcoming", "upcoming", "rest", "missed", "today", "rest", "rest"]),
		"the plan did not exist on Monday and Tuesday; Thursday was its first planned day")

	begin("a partial entry does not count as done (PRD-00 §6.4)")
	var partial: Array = [_entry(MONDAY, "s1", false)]
	assert_eq(_build(_plans(plan), partial, _now(TUESDAY, 9))["strip_kinds"],
		_kinds(["missed", "today", "rest", "upcoming", "upcoming", "rest", "rest"]),
		"a partial day is not a completed day")

	begin("the strip is a full week every time, even across a month boundary")
	var month_end := _build(_plans(plan), [], _now("2026-10-01", 9))
	var month_strip: Array = month_end["week_strip"]
	assert_eq(String(month_strip[0]["date"]), "2026-09-28", "Monday of that ISO week")
	assert_eq(String(month_strip[6]["date"]), "2026-10-04", "Sunday of that ISO week")


# ------------------------------------------------------------------ R9/R11 next-up

func _test_next_up_wrap_around() -> void:
	begin("the next session wraps past the last session (AC1)")
	var plan := _plan(3, "2026-09-14T06:00:00Z")
	# Mon s1 and Wed s2 done; today is Friday, where s3 is due.
	var state := _build(_plans(plan), [_entry(MONDAY, "s1"), _entry(WEDNESDAY, "s2")],
		_now(FRIDAY, 9))
	assert_eq(_session_id(state["session"]), "s3", "today's session")
	assert_eq(int(state["next_session_index"]), 0, "wrap to index 0")
	assert_eq(_session_id(state["next_session"]), "s1", "next Monday repeats session 1")
	assert_eq(String(state["next_weekday_name"]), "Monday", "Monday")
	assert_eq(int(state["next_days_ahead"]), 3, "three days ahead")

	begin("the last session's completion wraps the plan")
	var closed: Array = [
		_entry(MONDAY, "s1"), _entry(WEDNESDAY, "s2"), _entry(FRIDAY, "s3"),
	]
	var after := _build(_plans(plan), closed, _now(SUNDAY, 9))
	assert_eq(after["state"], HomeState.REST, "Sunday is a rest day")
	assert_eq(int(after["session_index"]), 0, "the cycle restarted")
	assert_eq(_session_id(after["next_session"]), "s1", "next Monday starts again")
	assert_eq(String(after["next_weekday_name"]), "Monday", "Monday")

	begin("a one-session plan always previews itself")
	var single := _plan(1, "2026-09-14T06:00:00Z")
	var only := _build(_plans(single), [], _now(WEDNESDAY, 9))
	assert_eq(_session_id(only["session"]), "s1", "today's session")
	assert_eq(_session_id(only["next_session"]), "s1", "and the next one")


# ------------------------------------------------------------------ derived pass-through

func _test_derived_values_pass_through() -> void:
	begin("streak, week and ring numbers come from the caller, not from here")
	var plan := _plan(4, "2026-09-14T06:00:00Z")
	var derived := {
		"streak": 3, "week_id": "2026-W38", "week_completed": 3, "week_target": 4,
		"week_fraction": 0.75, "ring_bits": PackedByteArray([1, 1, 0, 1, 0, 0, 0]),
	}
	var state := _build(_plans(plan), [_entry(MONDAY, "s1")], _now(TUESDAY, 9), derived)
	assert_eq(int(state["streak"]), 3, "streak")
	assert_eq(int(state["week_completed"]), 3, "the ring numerator")
	assert_eq(int(state["week_target"]), 4, "the ring denominator")
	assert_close(float(state["week_fraction"]), 0.75, 0.0001, "the arc")
	assert_eq(state["ring_bits"], PackedByteArray([1, 1, 0, 1, 0, 0, 0]), "the segments")

	begin("a five-day week keeps counting past the target (AC8's '5/4')")
	var over := _build(_plans(plan), [_entry(MONDAY, "s1")], _now(TUESDAY, 9),
		{"streak": 5, "week_completed": 5, "week_target": 4, "week_fraction": 1.0,
			"ring_bits": PackedByteArray([1, 1, 1, 1, 1, 0, 0])})
	assert_eq(int(over["week_completed"]), 5, "the numerator keeps counting")
	assert_eq(int(over["week_target"]), 4, "the denominator is the plan's cadence")
	assert_close(float(over["week_fraction"]), 1.0, 0.0001, "the arc caps at 100 %")

	begin("missing derived keys degrade to zero instead of failing")
	var bare := _build(_plans(plan), [], _now(TUESDAY, 9), {})
	assert_eq(int(bare["streak"]), 0, "streak")
	assert_eq(int(bare["week_target"]), 0, "target")
	assert_eq(bare["ring_bits"], PackedByteArray(), "no segments")


func _test_robustness() -> void:
	begin("an empty document set is NO_PLAN, never an error (PRD-00 rule 6)")
	var state := HomeState.build({}, [], {}, {}, {"year": 2026, "month": 9, "day": 16, "hour": 9})
	assert_eq(state["state"], HomeState.NO_PLAN, "no plan")
	assert_eq(state["week_strip"].size(), 7, "the strip still renders")
	assert_eq(String(state["greeting"]), "Morning. Let's build your first week.", "copy")

	begin("malformed plans/entries are skipped, not fatal")
	var plans := {"schema_version": 1, "active_plan_id": PLAN_ID,
		"plans": ["nonsense", 7, {"id": PLAN_ID, "days_per_week": 3, "sessions": []}]}
	var built := _build(plans, ["junk", null, 3], _now(WEDNESDAY, 9))
	assert_eq(built["state"], HomeState.TRAINING, "a plan with no sessions is still a plan")
	assert_eq(_session_id(built["session"]), "", "but has no session to show")

	begin("a plan without days_per_week falls back to the settings goal")
	var bare_plan := {"id": PLAN_ID, "created_at": "2026-09-14T06:00:00Z",
		"sessions": [{"id": "s1", "title": "Only", "focus": [], "est_minutes": 20,
			"warmup": [], "blocks": [], "cooldown": []}]}
	var fallback := HomeState.build(_plans(bare_plan), [], {"weekly_goal_days": 3}, {},
		_now(WEDNESDAY, 9))
	assert_eq(int(fallback["days_per_week"]), 3, "the settings goal was used")
	assert_eq(fallback["state"], HomeState.TRAINING, "Wednesday is planned by a 3-day goal")

	begin("every documented key is always present")
	var keys: PackedStringArray = ["state", "plan", "session", "session_index", "next_session",
		"next_session_index", "next_weekday_name", "next_days_ahead", "week_strip", "streak",
		"week_completed", "week_target", "greeting", "early_label"]
	for key in keys:
		assert_has_key(built, key, "key %s" % key)


# ------------------------------------------------------------------ helpers

func _build(plans_doc: Dictionary, entries: Array, now: Dictionary,
		derived: Dictionary = {}) -> Dictionary:
	return HomeState.build(plans_doc, entries, {"weekly_goal_days": 4}, derived, now)


func _empty_plans() -> Dictionary:
	return {"schema_version": 1, "active_plan_id": "", "plans": []}


func _plans(plan: Dictionary) -> Dictionary:
	return {"schema_version": 1, "active_plan_id": String(plan.get("id", "")), "plans": [plan]}


## A fixed local clock. `hour` selects the greeting band.
func _now(date_key: String, hour: int) -> Dictionary:
	var parts := Dates.parse_iso_date(date_key)
	return {
		"year": int(parts["y"]), "month": int(parts["m"]), "day": int(parts["d"]),
		"hour": hour, "minute": 0, "second": 0,
	}


func _derived(streak: int) -> Dictionary:
	return {"streak": streak, "week_id": "2026-W38", "week_completed": streak,
		"week_target": 4, "week_fraction": 0.5, "ring_bits": PackedByteArray([1, 1, 0, 0, 0, 0, 0])}


func _kinds(values: Array) -> PackedStringArray:
	return PackedStringArray(values)


## A `days_per_week`-session plan with sessions `s1 … sN` on Mon/Wed/Fri-style weekdays.
func _plan(days_per_week: int, created_at: String) -> Dictionary:
	var sessions: Array = []
	for index in days_per_week:
		sessions.append({
			"id": "s%d" % (index + 1),
			"index": index,
			"title": "Session %d" % (index + 1),
			"focus": ["chest", "back"],
			"est_minutes": 40,
			"warmup": [],
			"blocks": [
				{"exercise_id": "bench-press", "sets": 3, "reps": "8-10", "rest_seconds": 90},
				{"exercise_id": "bent-over-row", "sets": 3, "reps": "8-10", "rest_seconds": 90},
			],
			"cooldown": [],
		})
	return {
		"id": PLAN_ID,
		"name": "%d-Day Test" % days_per_week,
		"created_at": created_at,
		"source": "builtin",
		"provider": "",
		"goal": "hypertrophy",
		"days_per_week": days_per_week,
		"duration_min": 40,
		"areas": ["chest", "back"],
		"equipment": ["barbell"],
		"notes": "",
		"split_name": "Test",
		"sessions": sessions,
	}


func _entry(date: String, session_id: String, completed: bool = true,
		plan_id: String = PLAN_ID, duration_sec: int = 2400) -> Dictionary:
	return {
		"id": "h-%s-%s" % [date, session_id],
		"plan_id": plan_id,
		"session_id": session_id,
		"session_title": session_id.to_upper(),
		"date": date,
		"started_at": "%sT18:00:00Z" % date,
		"completed_at": "%sT18:40:00Z" % date,
		"duration_sec": duration_sec,
		"exercises_completed": 5,
		"exercises_total": 5,
		"completed": completed,
	}


## Complete Mon/Wed/Fri cycles starting 2026-08-03. With [param add_today] the last cycle also
## gets a completion on the fixture Wednesday, which is what the precedence test needs.
func _four_cycles(add_today: bool = false) -> Array:
	var entries := _cycles(4)
	if add_today:
		entries.append(_entry(WEDNESDAY, "s1"))
	return entries


## [param count] complete Mon/Wed/Fri cycles of the three-session plan.
func _cycles(count: int) -> Array:
	var entries: Array = []
	var starts: PackedStringArray = [
		"2026-08-03", "2026-08-10", "2026-08-17", "2026-08-24",
	]
	for index in mini(count, starts.size()):
		var start := starts[index]
		entries.append(_entry(start, "s1"))
		entries.append(_entry(Dates.add_days(start, 2), "s2"))
		entries.append(_entry(Dates.add_days(start, 4), "s3"))
	return entries


func _session_id(session: Dictionary) -> String:
	return String(session.get("id", ""))
