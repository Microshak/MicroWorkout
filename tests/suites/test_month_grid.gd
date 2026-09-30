extends TestSuite
## PRD-11 R3/R13 — [MonthGrid]: the fixed 42-cell month page and [MonthGrid.DayStatus]'s
## day-kind sentence.
##
## The calendar is pure data before it is pixels: every fact the screen draws — which dates a
## page shows, what each date *is* — is asserted here with fixed dates, so a wrong month page or
## a wrong `missed` mark fails headless instead of in a screenshot.

## Monday 2026-09-14 — the plan's creation date and the fixture anchor. 2026-09-01 is a Tuesday,
## 2026-02-01 is a Sunday, and 2024-02 is a leap February; R13 pins all three.
const MONDAY := "2026-09-14"
const TUESDAY := "2026-09-15"
const WEDNESDAY := "2026-09-16"
const THURSDAY := "2026-09-17"
const FRIDAY := "2026-09-18"

const PLAN_ID := "plan-1757941200"


func _init() -> void:
	suite_name = "month_grid"


func run() -> void:
	_test_cells()
	_test_month_math()
	_test_day_status()
	_test_day_status_without_plan()


# ------------------------------------------------------------------ cells (AC4 / R13)

func _test_cells() -> void:
	begin("cells(2026, 9) is 42 dates starting Monday 2026-08-31")
	var september := MonthGrid.cells(2026, 9)
	assert_eq(september.size(), MonthGrid.CELLS, "42 cells")
	assert_eq(september[0], "2026-08-31",
		"2026-09-01 is a Tuesday, so the page opens on the Monday before it")
	assert_eq(september[41], "2026-10-11", "the last cell is five Sundays later")
	assert_true(september.has("2026-09-30"), "the month's last day is on the page")

	begin("cells(2026, 2) is six rows because 2026-02-01 is a Sunday")
	var february := MonthGrid.cells(2026, 2)
	assert_eq(february.size(), 42, "still 42 cells")
	assert_eq(february[0], "2026-01-26", "opens Monday 2026-01-26")
	assert_true(february.has("2026-02-28"), "28-day February's last day is present")
	assert_false(february.has("2026-02-29"), "2026 is not a leap year")

	begin("cells(2024, 2) contains the leap day")
	assert_true(MonthGrid.cells(2024, 2).has("2024-02-29"), "2024-02-29 exists")

	begin("every 2026 month is 42 unique, consecutive dates")
	for month in range(1, 13):
		var cells := MonthGrid.cells(2026, month)
		assert_eq(cells.size(), 42, "month %d has 42 cells" % month)
		var seen := {}
		for index in cells.size():
			var iso := cells[index]
			assert_false(seen.has(iso), "month %d repeats %s" % [month, iso])
			seen[iso] = true
			if index > 0:
				assert_eq(Dates.day_diff(iso, cells[index - 1]), 1,
					"month %d: %s follows %s" % [month, iso, cells[index - 1]])
	assert_eq(MonthGrid.cells(2026, 13).size(), 0, "month 13 has no page")
	assert_eq(MonthGrid.cells(2026, 0).size(), 0, "month 0 has no page")


# ------------------------------------------------------------------ month maths (R13)

func _test_month_math() -> void:
	begin("first_key / last_key / contains")
	assert_eq(MonthGrid.first_key(2026, 9), "2026-09-01", "first key")
	assert_eq(MonthGrid.last_key(2026, 9), "2026-09-30", "last key")
	assert_eq(MonthGrid.last_key(2026, 2), "2026-02-28", "February 2026")
	assert_eq(MonthGrid.last_key(2024, 2), "2024-02-29", "February 2024")
	assert_true(MonthGrid.contains(2026, 9, "2026-09-15"), "in September")
	assert_false(MonthGrid.contains(2026, 9, "2026-08-31"), "a padding day is not in the month")
	assert_false(MonthGrid.contains(2026, 9, "2026-02-30"), "an invalid date is not in any month")

	begin("days_in_month covers the leap boundary")
	assert_eq(MonthGrid.days_in_month(2024, 2), 29, "Feb 2024")
	assert_eq(MonthGrid.days_in_month(2026, 2), 28, "Feb 2026")
	assert_eq(MonthGrid.days_in_month(2026, 4), 30, "Apr")
	assert_eq(MonthGrid.days_in_month(2026, 1), 31, "Jan")
	assert_eq(MonthGrid.days_in_month(2026, 13), 0, "month 13")

	begin("add_months wraps across year boundaries")
	assert_eq(MonthGrid.add_months(2026, 12, 1), [2027, 1] as Array, "December + 1")
	assert_eq(MonthGrid.add_months(2026, 1, -1), [2025, 12] as Array, "January − 1")
	assert_eq(MonthGrid.add_months(2026, 9, 0), [2026, 9] as Array, "no shift")
	assert_eq(MonthGrid.add_months(2026, 4, -38), [2023, 2] as Array, "three years back")

	begin("label and month_of")
	assert_eq(MonthGrid.label(2026, 9), "September 2026", "R13's exact label")
	assert_eq(MonthGrid.label(2026, 1), "January 2026", "January")
	assert_eq(MonthGrid.label(2026, 12), "December 2026", "December")
	assert_eq(MonthGrid.month_of("2026-09-15"), [2026, 9] as Array, "month_of")
	assert_eq(MonthGrid.month_of("not-a-date"), [] as Array, "invalid input")
	assert_eq(MonthGrid.month_name(0), "", "month 0 has no name")
	assert_eq(MonthGrid.month_name(13), "", "month 13 has no name")


# ------------------------------------------------------------------ day kinds (R6)

func _test_day_status() -> void:
	var plan := _plan()
	var none := PackedStringArray()
	var done_days := PackedStringArray(["2026-09-10"])  # a Thursday, and before the plan existed

	begin("off-month cells are padding")
	assert_eq(MonthGrid.DayStatus.resolve("2026-08-31", WEDNESDAY, none, plan, [],
		false), MonthGrid.DayStatus.PADDING, "outside the displayed month")
	assert_eq(MonthGrid.DayStatus.resolve("not-a-date", WEDNESDAY, none, plan, [],
		true), MonthGrid.DayStatus.PADDING, "an invalid date is padding, never a crash")

	begin("a completed day is done even when the plan had no session")
	assert_eq(MonthGrid.DayStatus.resolve("2026-09-10", WEDNESDAY, done_days, plan, [],
		true), MonthGrid.DayStatus.DONE, "an extra workout is a win")

	begin("today is `today` when the plan trains, `rest` when it does not")
	assert_eq(MonthGrid.DayStatus.resolve(THURSDAY, THURSDAY, none, plan, [],
		true), MonthGrid.DayStatus.TODAY, "Thursday is planned on a 4-day plan")
	assert_eq(MonthGrid.DayStatus.resolve(WEDNESDAY, WEDNESDAY, none, plan, [],
		true), MonthGrid.DayStatus.REST, "Wednesday is a rest day")
	assert_eq(MonthGrid.DayStatus.resolve(WEDNESDAY, WEDNESDAY,
		PackedStringArray([WEDNESDAY]), plan, [], true), MonthGrid.DayStatus.DONE,
		"a completed today outranks the today kind")

	begin("planned future days are upcoming, planned past days are missed")
	assert_eq(MonthGrid.DayStatus.resolve(FRIDAY, WEDNESDAY, none, plan, [],
		true), MonthGrid.DayStatus.UPCOMING, "Friday is planned and in the future")
	assert_eq(MonthGrid.DayStatus.resolve(TUESDAY, WEDNESDAY, none, plan, [],
		true), MonthGrid.DayStatus.MISSED, "Tuesday was planned and passed")

	begin("rest days never become missed")
	assert_eq(MonthGrid.DayStatus.resolve("2026-09-16", THURSDAY, none, plan, [],
		true), MonthGrid.DayStatus.REST, "a past Wednesday is still a rest day")

	begin("days before the plan existed fall through to rest, not missed")
	# The plan was created 2026-09-14; 2026-09-10 was a planned weekday (Thursday) but the plan
	# does not project backwards past its cycle anchor (R8's risks table).
	assert_eq(MonthGrid.DayStatus.resolve("2026-09-10", WEDNESDAY, none, plan, [],
		true), MonthGrid.DayStatus.REST, "before the plan = rest")


func _test_day_status_without_plan() -> void:
	var none := PackedStringArray()
	begin("with no active plan only done days are marked")
	assert_eq(MonthGrid.DayStatus.resolve(TUESDAY, WEDNESDAY, none, {}, [],
		true), MonthGrid.DayStatus.REST, "no plan, no marking")
	assert_eq(MonthGrid.DayStatus.resolve(TUESDAY, WEDNESDAY, PackedStringArray([TUESDAY]),
		{}, [], true), MonthGrid.DayStatus.DONE, "history still shows")

	begin("an invalid `today` never marks a day")
	assert_eq(MonthGrid.DayStatus.resolve(TUESDAY, "", none, _plan(), [],
		true), MonthGrid.DayStatus.REST, "an unusable clock reads as rest")


# ------------------------------------------------------------------ fixtures

## A minimal 4-day plan anchored at Monday 2026-09-14 with real sessions — the same shape
## `PlanSchedule.session_for_date()` consumes.
func _plan() -> Dictionary:
	var sessions: Array = []
	var ids := ["s1", "s2", "s3", "s4"]
	for index in ids.size():
		sessions.append({
			"id": ids[index],
			"index": index,
			"title": "Session %d" % (index + 1),
			"focus": ["chest"],
			"est_minutes": 40,
			"warmup": [],
			"blocks": [],
			"cooldown": [],
		})
	return {
		"id": PLAN_ID,
		"created_at": "2026-09-14T10:00:00Z",
		"days_per_week": 4,
		"sessions": sessions,
	}
