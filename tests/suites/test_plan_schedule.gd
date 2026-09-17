extends TestSuite
## PRD-09 R3 / AC2 — the deterministic weekday → session model.
##
## `PlanSchedule` is the module PRD-10 and PRD-11 import (appendix R48/R52), so every fact the
## other two PRDs will bind to is asserted here with fixed dates: the R3 weekday table, ISO
## weekday indexing, `next_training_day`, `cycle_start_date`, `session_index_for` (including the
## cycle boundary), `session_for_date` and the `FINISH_CYCLES` rule.

## Monday 2026-09-14 … Sunday 2026-09-20 — the fixture week every case below uses.
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
	suite_name = "plan_schedule"


func run() -> void:
	_test_weekday_table()
	_test_weekday_indexing()
	_test_today_iso()
	_test_next_training_day()
	_test_cycle_start()
	_test_session_index()
	_test_session_for_date()
	_test_plan_finished()
	_test_invalid_input_is_safe()


# ------------------------------------------------------------------ R3 table (AC2)

func _test_weekday_table() -> void:
	begin("weekdays_for matches the frozen R3 table")
	var expected := {
		1: [3],
		2: [1, 4],
		3: [1, 3, 5],
		4: [1, 2, 4, 5],
		5: [1, 2, 3, 5, 6],
		6: [1, 2, 3, 4, 5, 6],
		7: [1, 2, 3, 4, 5, 6, 7],
	}
	for days in range(1, 8):
		assert_eq(PlanSchedule.weekdays_for(days), expected[days] as Array,
			"weekdays_for(%d)" % days)

	begin("weekdays_for(4) is [1, 2, 4, 5] — the assertion PRD-11 R8 also makes")
	assert_eq(PlanSchedule.weekdays_for(4), [1, 2, 4, 5] as Array[int], "four-day pattern")

	begin("weekdays_for clamps out-of-range input into 1..7")
	assert_eq(PlanSchedule.weekdays_for(0), [3] as Array[int], "0 clamps to 1")
	assert_eq(PlanSchedule.weekdays_for(-5), [3] as Array[int], "negative clamps to 1")
	assert_eq(PlanSchedule.weekdays_for(9), [1, 2, 3, 4, 5, 6, 7] as Array[int],
		"9 clamps to 7")
	assert_eq(PlanSchedule.weekdays_for(1000), [1, 2, 3, 4, 5, 6, 7] as Array[int],
		"a huge value clamps to 7")

	begin("weekday_name and weekday_letter are 1-based ISO")
	assert_eq(PlanSchedule.weekday_name(1), "Monday", "Monday")
	assert_eq(PlanSchedule.weekday_name(7), "Sunday", "Sunday")
	assert_eq(PlanSchedule.weekday_name(0), "", "0 has no name")
	assert_eq(PlanSchedule.weekday_name(8), "", "8 has no name")
	assert_eq(PlanSchedule.weekday_letter(1), "M", "Monday is M")
	assert_eq(PlanSchedule.weekday_letter(7), "S", "Sunday is S")
	assert_eq(PlanSchedule.weekday_letter(0), "", "0 has no letter")


func _test_weekday_indexing() -> void:
	begin("weekday_iso is Monday 1 … Sunday 7")
	assert_eq(PlanSchedule.weekday_iso(MONDAY), 1, "2026-09-14 is a Monday")
	assert_eq(PlanSchedule.weekday_iso(TUESDAY), 2, "2026-09-15 is a Tuesday")
	assert_eq(PlanSchedule.weekday_iso(WEDNESDAY), 3, "2026-09-16 is a Wednesday")
	assert_eq(PlanSchedule.weekday_iso(THURSDAY), 4, "2026-09-17 is a Thursday")
	assert_eq(PlanSchedule.weekday_iso(FRIDAY), 5, "2026-09-18 is a Friday")
	assert_eq(PlanSchedule.weekday_iso(SATURDAY), 6, "2026-09-19 is a Saturday")
	assert_eq(PlanSchedule.weekday_iso(SUNDAY), 7, "2026-09-20 is a Sunday")
	assert_eq(PlanSchedule.weekday_iso(NEXT_MONDAY), 1, "the week wraps back to Monday")

	begin("a known Monday and a known Sunday (AC2)")
	assert_eq(PlanSchedule.weekday_iso("2024-01-01"), 1, "2024-01-01 is a Monday")
	assert_eq(PlanSchedule.weekday_iso("2026-01-04"), 7, "2026-01-04 is a Sunday")

	begin("weekday_iso rejects a non-date")
	assert_eq(PlanSchedule.weekday_iso(""), 0, "empty")
	assert_eq(PlanSchedule.weekday_iso("2026-02-30"), 0, "February 30th is not a date")
	assert_eq(PlanSchedule.weekday_iso("not-a-date"), 0, "garbage")

	begin("is_training_day follows the pattern")
	assert_true(PlanSchedule.is_training_day(MONDAY, 4), "Monday is planned on a 4-day plan")
	assert_true(PlanSchedule.is_training_day(TUESDAY, 4), "Tuesday is planned")
	assert_false(PlanSchedule.is_training_day(WEDNESDAY, 4), "Wednesday is a rest day")
	assert_true(PlanSchedule.is_training_day(THURSDAY, 4), "Thursday is planned")
	assert_true(PlanSchedule.is_training_day(FRIDAY, 4), "Friday is planned")
	assert_false(PlanSchedule.is_training_day(SATURDAY, 4), "Saturday is a rest day")
	assert_false(PlanSchedule.is_training_day(SUNDAY, 4), "Sunday is a rest day")
	assert_true(PlanSchedule.is_training_day(WEDNESDAY, 1), "a 1-day plan trains Wednesday")
	assert_false(PlanSchedule.is_training_day(MONDAY, 1), "…and only Wednesday")
	assert_false(PlanSchedule.is_training_day("", 4), "an invalid date is never a training day")

	begin("week_dates returns the ISO week Monday → Sunday")
	var week := PlanSchedule.week_dates(WEDNESDAY)
	assert_eq(week.size(), 7, "seven days")
	assert_eq(week[0], MONDAY, "starts on Monday")
	assert_eq(week[6], SUNDAY, "ends on Sunday")


func _test_today_iso() -> void:
	begin("today_iso renders the clock dictionary it was handed")
	var now := {"year": 2026, "month": 9, "day": 16, "hour": 7, "minute": 30, "second": 5}
	assert_eq(PlanSchedule.today_iso(now), "2026-09-16", "the local calendar day")

	begin("today_iso pads single-digit months and days")
	var padded := {"year": 2027, "month": 1, "day": 4, "hour": 23}
	assert_eq(PlanSchedule.today_iso(padded), "2027-01-04", "padded")

	begin("a malformed clock dictionary degrades to the system date, never to an empty day")
	var broken := PlanSchedule.today_iso({"hour": 9})
	assert_true(Dates.is_valid_iso_date(broken), "still a real date: %s" % broken)


func _test_next_training_day() -> void:
	begin("next_training_day finds the next planned weekday (R3)")
	var from_tuesday := PlanSchedule.next_training_day(TUESDAY, 4)
	assert_eq(from_tuesday["weekday_iso"], 4, "Tuesday → Thursday on a 4-day plan")
	assert_eq(from_tuesday["days_ahead"], 2, "two days ahead")
	assert_eq(from_tuesday["weekday_name"], "Thursday", "named")

	var from_sunday := PlanSchedule.next_training_day(SUNDAY, 4)
	assert_eq(from_sunday["weekday_name"], "Monday", "Sunday wraps to Monday")
	assert_eq(from_sunday["days_ahead"], 1, "one day ahead")

	var from_friday := PlanSchedule.next_training_day(FRIDAY, 4)
	assert_eq(from_friday["weekday_name"], "Monday", "Friday → next Monday")
	assert_eq(from_friday["days_ahead"], 3, "three days ahead")

	begin("a rest day looks forward to the next planned day")
	var from_wednesday := PlanSchedule.next_training_day(WEDNESDAY, 4)
	assert_eq(from_wednesday["weekday_name"], "Thursday", "Wednesday wants Thursday")
	assert_eq(from_wednesday["days_ahead"], 1, "tomorrow")

	begin("a one-day plan answers seven days out, at most")
	var one_day := PlanSchedule.next_training_day(WEDNESDAY, 1)
	assert_eq(one_day["weekday_name"], "Wednesday", "same weekday next week")
	assert_eq(one_day["days_ahead"], 7, "a full week")

	begin("an invalid date has no next training day")
	var none := PlanSchedule.next_training_day("", 4)
	assert_eq(none["weekday_name"], "", "no name")
	assert_eq(none["days_ahead"], 0, "no distance")


# ------------------------------------------------------------------ cycle + index (R3)

func _test_cycle_start() -> void:
	begin("cycle_start_date falls back to plan.created_at's date")
	var plan := _plan(3, "2026-09-14T06:00:00Z")
	assert_eq(PlanSchedule.cycle_start_date(plan, []), MONDAY, "the creation date")

	begin("cycle_start_date is the most recent completion of the last session")
	var entries: Array = [
		_entry(MONDAY, "s1"), _entry(WEDNESDAY, "s2"), _entry(FRIDAY, "s3"),
		_entry("2026-09-11", "s3"), _entry("2026-09-04", "s3"),
	]
	assert_eq(PlanSchedule.cycle_start_date(plan, entries), FRIDAY,
		"the newest last-session completion wins")

	begin("only completed entries of this plan's last session anchor the cycle")
	var partial: Array = [_entry(FRIDAY, "s3", false)]
	assert_eq(PlanSchedule.cycle_start_date(plan, partial), MONDAY,
		"a partial entry is not a completion")
	var other_plan: Array = [_entry(FRIDAY, "s3", true, "plan-9999999999")]
	assert_eq(PlanSchedule.cycle_start_date(plan, other_plan), MONDAY,
		"another plan's entry is ignored")
	var mid_session: Array = [_entry(FRIDAY, "s1")]
	assert_eq(PlanSchedule.cycle_start_date(plan, mid_session), MONDAY,
		"only the last session closes a cycle")

	begin("created_at_date reads the date part of an ISO-8601 stamp")
	assert_eq(PlanSchedule.created_at_date(_plan(3, "2026-09-14T06:00:00Z")), MONDAY, "stamp")
	assert_eq(PlanSchedule.created_at_date(_plan(3, "")), "", "missing stamp")
	assert_eq(PlanSchedule.created_at_date(_plan(3, "nonsense")), "", "malformed stamp")


func _test_session_index() -> void:
	begin("a fresh plan starts at session 0")
	var plan := _plan(4, "2026-09-14T06:00:00Z")
	assert_eq(PlanSchedule.session_index_for(plan, []), 0, "nothing done yet")

	begin("the index advances one per completed session")
	var one: Array = [_entry(MONDAY, "s1")]
	assert_eq(PlanSchedule.session_index_for(plan, one), 1, "after s1")
	var two: Array = [_entry(MONDAY, "s1"), _entry(TUESDAY, "s2")]
	assert_eq(PlanSchedule.session_index_for(plan, two), 2, "after s2")
	var three: Array = [_entry(MONDAY, "s1"), _entry(TUESDAY, "s2"), _entry(THURSDAY, "s3")]
	assert_eq(PlanSchedule.session_index_for(plan, three), 3, "after s3")

	begin("a partial entry does not advance the cycle")
	var partial: Array = [_entry(MONDAY, "s1"), _entry(TUESDAY, "s2", false)]
	assert_eq(PlanSchedule.session_index_for(plan, partial), 1, "still waiting for s2")

	begin("a finished cycle wraps back to session 0 (not one session late)")
	var cycle: Array = [
		_entry(MONDAY, "s1"), _entry(TUESDAY, "s2"),
		_entry(THURSDAY, "s3"), _entry(FRIDAY, "s4"),
	]
	assert_eq(PlanSchedule.cycle_start_date(plan, cycle), FRIDAY, "the closing completion")
	assert_eq(PlanSchedule.session_index_for(plan, cycle), 0,
		"the next training day repeats the plan from session 1")

	begin("mid-cycle wrap-around: three done in a three-session plan")
	var three_day := _plan(3, "2026-09-14T06:00:00Z")
	var round_one: Array = [
		_entry(MONDAY, "s1"), _entry(WEDNESDAY, "s2"), _entry(FRIDAY, "s3"),
	]
	assert_eq(PlanSchedule.finished_cycles(three_day, round_one), 1, "one full cycle")
	assert_eq(PlanSchedule.session_index_for(three_day, round_one), 0, "back to s1")

	begin("entries from another plan never move this plan's index")
	var mixed: Array = [
		_entry(MONDAY, "s1"), _entry(TUESDAY, "s2"), _entry(THURSDAY, "s3"),
		_entry(FRIDAY, "s4", true, "plan-9999999999"),
	]
	assert_eq(PlanSchedule.session_index_for(plan, mixed), 3, "still three")

	begin("an empty plan has index 0")
	assert_eq(PlanSchedule.session_index_for({}, []), 0, "no sessions")

	begin("days_per_week_of falls back for a malformed value")
	assert_eq(PlanSchedule.days_per_week_of(_plan(4, "")), 4, "the plan's own value")
	assert_eq(PlanSchedule.days_per_week_of({}, 6), 6, "the caller's fallback")
	assert_eq(PlanSchedule.days_per_week_of({"days_per_week": 0}, 5), 5, "zero is not a plan")
	assert_eq(PlanSchedule.days_per_week_of({"days_per_week": 99}, 4), 4, "99 is clamped away")


func _test_session_for_date() -> void:
	begin("session_for_date returns {} on a rest weekday (AC2)")
	var plan := _plan(4, "2026-09-14T06:00:00Z")
	assert_eq(PlanSchedule.session_for_date(plan, [], WEDNESDAY), {}, "Wednesday is a rest day")
	assert_eq(PlanSchedule.session_for_date(plan, [], SATURDAY), {}, "Saturday is a rest day")
	assert_eq(PlanSchedule.session_for_date(plan, [], SUNDAY), {}, "Sunday is a rest day")

	begin("a fresh Monday plan maps its own week to the session order")
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, [], MONDAY)), "s1", "Monday → s1")
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, [], TUESDAY)), "s2", "Tuesday → s2")
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, [], THURSDAY)), "s3", "Thursday → s3")
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, [], FRIDAY)), "s4", "Friday → s4")

	begin("the template repeats weekly")
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, [], NEXT_MONDAY)), "s1",
		"next Monday → s1")
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, [], "2026-09-24")), "s3",
		"the following Thursday → s3")

	begin("after a closed cycle the calendar restarts at session 1")
	var closed: Array = [
		_entry(MONDAY, "s1"), _entry(TUESDAY, "s2"),
		_entry(THURSDAY, "s3"), _entry(FRIDAY, "s4"),
	]
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, closed, NEXT_MONDAY)), "s1",
		"the cycle wrapped")
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, closed, "2026-09-22")), "s2",
		"…and keeps counting")

	begin("a closed cycle can also be projected backwards")
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, closed, THURSDAY)), "s3",
		"the day before the anchor")
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, closed, MONDAY)), "s1",
		"the start of the closing cycle")
	assert_eq(_session_id(PlanSchedule.session_for_date(plan, closed, "2026-09-07")), "s1",
		"a week earlier is the same weekday template")

	begin("before the plan existed there is nothing to project")
	assert_eq(PlanSchedule.session_for_date(plan, [], "2026-09-07"), {},
		"a week before creation")

	begin("a plan with no sessions answers nothing")
	assert_eq(PlanSchedule.session_for_date({"id": PLAN_ID, "sessions": []}, [], MONDAY), {},
		"empty sessions")


func _test_plan_finished() -> void:
	begin("finished_cycles counts complete round trips")
	var plan := _plan(3, "2026-08-01T06:00:00Z")
	# Four full cycles: Mon/Wed/Fri for four consecutive weeks.
	var entries: Array = [
		_entry("2026-08-03", "s1"), _entry("2026-08-05", "s2"), _entry("2026-08-07", "s3"),
		_entry("2026-08-10", "s1"), _entry("2026-08-12", "s2"), _entry("2026-08-14", "s3"),
		_entry("2026-08-17", "s1"), _entry("2026-08-19", "s2"), _entry("2026-08-21", "s3"),
		_entry("2026-08-24", "s1"), _entry("2026-08-26", "s2"), _entry("2026-08-28", "s3"),
	]
	assert_eq(PlanSchedule.finished_cycles(plan, entries), 4, "four cycles")
	assert_true(PlanSchedule.is_plan_finished(plan, entries), "every session has four")

	begin("one session short of four cycles is not finished")
	var short: Array = entries.slice(0, 11)
	assert_eq(PlanSchedule.finished_cycles(plan, short), 3, "the smallest count")
	assert_false(PlanSchedule.is_plan_finished(plan, short), "s3 has only three")

	begin("completion_counts only counts the plan's own sessions")
	var counts := PlanSchedule.completion_counts(plan, entries)
	assert_eq(counts.size(), 3, "one entry per session")
	assert_eq(int(counts["s1"]), 4, "s1 count")
	assert_eq(int(counts["s3"]), 4, "s3 count")
	var foreign: Array = [_entry("2026-08-03", "s9")]
	assert_eq(int(PlanSchedule.completion_counts(plan, foreign)["s1"]), 0,
		"an unknown session id counts nowhere")

	begin("a plan with no sessions is never finished")
	assert_false(PlanSchedule.is_plan_finished({"id": PLAN_ID, "sessions": []}, entries),
		"no sessions")
	assert_false(PlanSchedule.is_plan_finished({}, []), "no plan")


func _test_invalid_input_is_safe() -> void:
	begin("every entry point tolerates empty and malformed input")
	assert_eq(PlanSchedule.sessions_of({}), [] as Array, "no sessions key")
	assert_eq(PlanSchedule.sessions_of({"sessions": "nope"}), [] as Array, "wrong type")
	assert_eq(PlanSchedule.cycle_start_date({}, []), "", "no plan")
	assert_eq(PlanSchedule.session_index_for({}, []), 0, "no plan")
	assert_eq(PlanSchedule.session_for_date({}, [], MONDAY), {}, "no plan")
	assert_eq(PlanSchedule.finished_cycles({}, []), 0, "no plan")
	assert_eq(PlanSchedule.week_dates(""), PackedStringArray(), "no date")
	assert_eq(PlanSchedule.weekday_iso("2026-13-01"), 0, "month 13")

	begin("non-dictionary entries in the history are skipped, not fatal")
	var plan := _plan(3, "2026-09-14T06:00:00Z")
	var mixed: Array = ["nonsense", 42, null, _entry(MONDAY, "s1")]
	assert_eq(PlanSchedule.session_index_for(plan, mixed), 1, "the real entry still counts")
	assert_eq(PlanSchedule.cycle_start_date(plan, mixed), MONDAY, "the creation date")


# ------------------------------------------------------------------ fixtures

## A `days_per_week`-session plan whose sessions are `s1 … sN`.
func _plan(days_per_week: int, created_at: String) -> Dictionary:
	var sessions: Array = []
	for index in days_per_week:
		sessions.append({
			"id": "s%d" % (index + 1),
			"index": index,
			"title": "Session %d" % (index + 1),
			"focus": ["chest"],
			"est_minutes": 40,
			"warmup": [],
			"blocks": [{"exercise_id": "bench-press", "sets": 3, "reps": "8-10",
				"rest_seconds": 90}],
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
		"areas": ["chest"],
		"equipment": ["barbell"],
		"notes": "",
		"split_name": "Test",
		"sessions": sessions,
	}


func _entry(date: String, session_id: String, completed: bool = true,
		plan_id: String = PLAN_ID) -> Dictionary:
	return {
		"id": "h-%s-%s" % [date, session_id],
		"plan_id": plan_id,
		"session_id": session_id,
		"session_title": session_id.to_upper(),
		"date": date,
		"started_at": "%sT18:00:00Z" % date,
		"completed_at": "%sT18:40:00Z" % date,
		"duration_sec": 2400,
		"exercises_completed": 5,
		"exercises_total": 5,
		"completed": completed,
	}


func _session_id(session: Dictionary) -> String:
	return String(session.get("id", ""))
