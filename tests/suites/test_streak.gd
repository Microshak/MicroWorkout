extends TestSuite
## PRD-03 R12–R14 — civil dates, ISO weeks, streaks and the weekly ring.
##
## Pure logic, no filesystem and no scene tree: every fact here is a fixed date, so the
## suite proves the boundary behaviour (leap years, month and year ends, ISO week-year
## rollover, the "today not done yet" grace day) without depending on the wall clock.

const TODAY := "2026-09-15"


func _init() -> void:
	suite_name = "streak"


func run() -> void:
	_test_civil_math()
	_test_date_shape_helpers()
	_test_iso_weeks()
	_test_streak_table()
	_test_longest_streak()
	_test_week_buckets()
	_test_ring_segments()
	_test_invalid_input_is_safe()


# ------------------------------------------------------------------ R12: dates

func _test_civil_math() -> void:
	begin("days_from_civil is anchored at the epoch")
	assert_eq(Dates.days_from_civil(1970, 1, 1), 0, "1970-01-01 is day 0")
	assert_eq(Dates.days_from_civil(1970, 1, 2), 1, "the next day is day 1")
	assert_eq(Dates.days_from_civil(1969, 12, 31), -1, "the day before the epoch is -1")
	assert_eq(Dates.days_from_civil(1970, 3, 1), 59, "1970-03-01 is day 59")
	assert_eq(Dates.days_from_civil(2000, 1, 1), 10957, "2000-01-01 is day 10957")

	begin("civil_from_days round-trips days_from_civil")
	var samples: PackedStringArray = [
		"1969-12-31", "1970-01-01", "1972-02-29", "1999-12-31",
		"2000-02-29", "2024-02-29", "2026-09-15", "2100-03-01",
	]
	for iso in samples:
		var parts := Dates.parse_iso_date(iso)
		var back := Dates.civil_from_days(
			Dates.days_from_civil(int(parts["y"]), int(parts["m"]), int(parts["d"])))
		assert_eq("%04d-%02d-%02d" % [int(back["y"]), int(back["m"]), int(back["d"])], iso,
			"round trip for %s" % iso)

	begin("is_leap_year follows the 4/100/400 rule")
	assert_true(Dates.is_leap_year(2024), "2024 is a leap year")
	assert_false(Dates.is_leap_year(2023), "2023 is not")
	assert_false(Dates.is_leap_year(2100), "2100 is not (century)")
	assert_true(Dates.is_leap_year(2000), "2000 is (400-year rule)")
	assert_eq(Dates.days_in_month(2024, 2), 29, "February 2024 has 29 days")
	assert_eq(Dates.days_in_month(2026, 2), 28, "February 2026 has 28 days")
	assert_eq(Dates.days_in_month(2026, 12), 31, "December has 31 days")

	begin("add_days crosses month, year and leap boundaries")
	assert_eq(Dates.add_days("2026-09-15", 1), "2026-09-16", "next day")
	assert_eq(Dates.add_days("2026-09-15", -1), "2026-09-14", "previous day")
	assert_eq(Dates.add_days("2026-01-31", 1), "2026-02-01", "month end")
	assert_eq(Dates.add_days("2026-03-01", -1), "2026-02-28", "month start backwards")
	assert_eq(Dates.add_days("2024-02-28", 1), "2024-02-29", "leap day")
	assert_eq(Dates.add_days("2023-02-28", 1), "2023-03-01", "no leap day in 2023")
	assert_eq(Dates.add_days("2026-12-31", 1), "2027-01-01", "year end")
	assert_eq(Dates.add_days("2027-01-01", -1), "2026-12-31", "year start backwards")
	assert_eq(Dates.add_days("2026-09-15", 0), "2026-09-15", "a zero shift is identity")
	assert_eq(Dates.add_days("2026-09-15", 365), "2027-09-15", "a full year")

	begin("day_diff is signed whole days")
	assert_eq(Dates.day_diff("2026-09-15", "2026-09-14"), 1, "one day apart")
	assert_eq(Dates.day_diff("2026-09-14", "2026-09-15"), -1, "signed")
	assert_eq(Dates.day_diff("2026-03-01", "2026-02-28"), 1, "across a month end")
	assert_eq(Dates.day_diff("2027-01-01", "2026-01-01"), 365, "a non-leap year")
	assert_eq(Dates.day_diff("2025-01-01", "2024-01-01"), 366, "2024 is a leap year")
	assert_eq(Dates.day_diff("2026-09-15", "2026-09-15"), 0, "same day")

	begin("weekday_index is Monday-based")
	assert_eq(Dates.weekday_index("2026-09-14"), 0, "2026-09-14 is a Monday")
	assert_eq(Dates.weekday_index("2026-09-15"), 1, "2026-09-15 is a Tuesday")
	assert_eq(Dates.weekday_index("2026-09-20"), 6, "2026-09-20 is a Sunday")
	assert_eq(Dates.weekday_index("1970-01-01"), 3, "the epoch was a Thursday")


func _test_date_shape_helpers() -> void:
	begin("parse_iso_date accepts only real dates")
	assert_true(Dates.is_valid_iso_date("2026-09-15"), "a normal date is valid")
	assert_true(Dates.is_valid_iso_date("2024-02-29"), "a real leap day is valid")
	assert_false(Dates.is_valid_iso_date("2026-02-29"), "a fake leap day is rejected")
	assert_false(Dates.is_valid_iso_date("2026-02-30"), "February never has 30 days")
	assert_false(Dates.is_valid_iso_date("2026-13-01"), "month 13 is rejected")
	assert_false(Dates.is_valid_iso_date("2026-00-10"), "month 0 is rejected")
	assert_false(Dates.is_valid_iso_date("2026-09-00"), "day 0 is rejected")
	assert_false(Dates.is_valid_iso_date("2026-9-15"), "a single-digit month is rejected")
	assert_false(Dates.is_valid_iso_date("20260915"), "the separators are required")
	assert_false(Dates.is_valid_iso_date(""), "an empty string is rejected")
	var parsed := Dates.parse_iso_date("2026-09-15")
	assert_eq(int(parsed.get("y", 0)), 2026, "parsed year")
	assert_eq(int(parsed.get("m", 0)), 9, "parsed month")
	assert_eq(int(parsed.get("d", 0)), 15, "parsed day")
	assert_true(Dates.parse_iso_date("nope").is_empty(), "invalid input parses to {}")

	begin("ISO-8601 timestamps parse with and without a time part")
	assert_true(Dates.is_valid_iso_datetime("2026-09-15T12:00:00Z"), "a Z timestamp is valid")
	assert_true(Dates.is_valid_iso_datetime("2026-09-15T12:00:00"), "no Z is still valid")
	assert_true(Dates.is_valid_iso_datetime("2026-09-15"), "a bare date is midnight")
	assert_false(Dates.is_valid_iso_datetime("2026-09-15T25:00:00Z"), "hour 25 is rejected")
	assert_false(Dates.is_valid_iso_datetime("2026-09-15T12:60:00Z"), "minute 60 is rejected")
	assert_false(Dates.is_valid_iso_datetime("2026-09-15 12:00"), "a partial time is rejected")
	var stamp := Dates.parse_iso_datetime("2026-09-15T12:34:56Z")
	assert_eq(int(stamp.get("h", -1)), 12, "parsed hour")
	assert_eq(int(stamp.get("mi", -1)), 34, "parsed minute")
	assert_eq(int(stamp.get("s", -1)), 56, "parsed second")
	assert_eq(int(Dates.parse_iso_datetime("2026-09-15").get("h", -1)), 0, "midnight default")

	begin("epoch seconds are timezone-free civil math")
	assert_eq(Dates.epoch_seconds("1970-01-01T00:00:00Z"), 0, "the epoch is 0")
	assert_eq(Dates.epoch_seconds("1970-01-02T00:00:00Z"), 86400, "one day is 86400 s")
	assert_eq(Dates.epoch_seconds("1970-01-01T01:00:00Z"), 3600, "one hour is 3600 s")
	assert_eq(Dates.epoch_seconds("2026-09-15"),
		Dates.days_from_civil(2026, 9, 15) * 86400, "a bare date is midnight UTC")
	assert_eq(Dates.seconds_between_iso("2026-09-15T13:00:00Z", "2026-09-15T00:00:00Z"),
		46800, "thirteen hours")
	assert_eq(Dates.seconds_between_iso("2026-09-16", "2026-09-15"), 86400, "across midnight")

	begin("format_clock renders mm:ss and h:mm:ss")
	assert_eq(Dates.format_clock(2430), "40:30", "40 minutes 30 seconds")
	assert_eq(Dates.format_clock(3900), "1:05:00", "one hour five minutes")
	assert_eq(Dates.format_clock(0), "0:00", "zero")
	assert_eq(Dates.format_clock(59), "0:59", "under a minute")
	assert_eq(Dates.format_clock(3600), "1:00:00", "exactly one hour")
	assert_eq(Dates.format_clock(-5), "0:00", "a negative duration clamps to zero")

	begin("format_long and relative_day_label")
	assert_eq(Dates.format_long("2026-09-15"), "Tue, Sep 15", "long format")
	assert_eq(Dates.format_long("2026-01-01"), "Thu, Jan 1", "January first")
	assert_eq(Dates.relative_day_label(TODAY, TODAY), "Today", "today")
	assert_eq(Dates.relative_day_label("2026-09-14", TODAY), "Yesterday", "yesterday")
	assert_eq(Dates.relative_day_label("2026-09-13", TODAY), "Sun, Sep 13", "older")
	assert_eq(Dates.relative_day_label("2026-09-16", TODAY), "Wed, Sep 16", "future dates too")


# ------------------------------------------------------------------ R14: ISO weeks

func _test_iso_weeks() -> void:
	begin("the five mandatory ISO-week facts (R14)")
	assert_eq(Dates.iso_week_id("2026-09-15"), "2026-W38", "2026-09-15 is in W38")
	assert_eq(Dates.iso_week_start("2026-09-15"), "2026-09-14", "that week starts on Monday")
	assert_eq(Dates.iso_week_id("2026-09-20"), "2026-W38", "Sunday 09-20 is still W38")
	assert_eq(Dates.iso_week_id("2026-09-21"), "2026-W39", "Monday 09-21 starts W39")
	assert_eq(Dates.iso_week_id("2027-01-01"), "2026-W53", "the ISO week-year rolls over")

	begin("week buckets around the boundaries")
	assert_eq(Dates.iso_week_id("2026-09-14"), "2026-W38", "the Monday belongs to W38")
	assert_eq(Dates.iso_week_id("2026-01-01"), "2026-W01", "the first days of 2026 are W01")
	assert_eq(Dates.iso_week_id("2026-12-31"), "2026-W53", "the last days of 2026 are W53")
	assert_eq(Dates.iso_week_id("2027-01-04"), "2027-W01", "the first Monday of 2027 is W01")

	begin("week_id_start maps a week back to its Monday")
	assert_eq(Dates.week_id_start("2026-W38"), "2026-09-14", "W38 starts 2026-09-14")
	assert_eq(Dates.week_id_start("2026-W01"), "2025-12-29", "W01 starts in the previous year")
	assert_eq(Dates.week_id_start("2026-W53"), "2026-12-28", "W53 starts 2026-12-28")
	assert_eq(Dates.iso_week_id(Dates.week_id_start("2026-W53")), "2026-W53", "round trip")
	assert_true(Dates.is_valid_iso_week_id("2026-W38"), "a well-formed week id is valid")
	assert_false(Dates.is_valid_iso_week_id("2026-38"), "a missing W is invalid")
	assert_false(Dates.is_valid_iso_week_id(""), "an empty week id is invalid")

	begin("iso_week_days returns seven consecutive days, Monday first")
	var days := Dates.iso_week_days("2026-09-15")
	assert_eq(days.size(), 7, "seven days")
	assert_eq(days[0], "2026-09-14", "Monday first")
	assert_eq(days[6], "2026-09-20", "Sunday last")
	assert_eq(Dates.iso_week_days("2026-09-15")[3], "2026-09-17", "Thursday in the middle")


# ------------------------------------------------------------------ R13: the streak table

func _test_streak_table() -> void:
	begin("today done, yesterday done -> 2")
	assert_eq(Streak.current_streak(_dates(["2026-09-15", "2026-09-14"]), TODAY), 2, "R13 case 1")

	begin("today not done yet (grace) -> 2")
	assert_eq(Streak.current_streak(_dates(["2026-09-14", "2026-09-13"]), TODAY), 2, "R13 case 2")

	begin("a gap of one day -> 0")
	assert_eq(Streak.current_streak(_dates(["2026-09-13", "2026-09-12"]), TODAY), 0, "R13 case 3")

	begin("a gap of two or more days -> 0")
	assert_eq(Streak.current_streak(_dates(["2026-09-10", "2026-09-09"]), TODAY), 0, "R13 case 4")

	begin("two sessions on one day collapse to one -> 2")
	assert_eq(Streak.current_streak(_dates(["2026-09-15", "2026-09-15", "2026-09-14"]), TODAY),
		2, "R13 case 5")

	begin("today only -> 1")
	assert_eq(Streak.current_streak(_dates(["2026-09-15"]), TODAY), 1, "R13 case 6")

	begin("an abandoned entry does not count -> 1")
	var abandoned: Array[Dictionary] = [
		_entry("2026-09-15", false),
		_entry("2026-09-14", true),
	]
	assert_eq(Streak.current_streak(abandoned, TODAY), 1, "R13 case 7")

	begin("a future-dated entry is ignored -> 1")
	assert_eq(Streak.current_streak(_dates(["2026-09-16", "2026-09-15"]), TODAY), 1, "R13 case 8")

	begin("empty history -> 0, and a full week -> 7")
	var empty: Array[Dictionary] = []
	assert_eq(Streak.current_streak(empty, TODAY), 0, "no entries, no streak")
	assert_eq(Streak.current_streak(_dates([
		"2026-09-15", "2026-09-14", "2026-09-13", "2026-09-12", "2026-09-11", "2026-09-10",
		"2026-09-09"]), TODAY), 7, "seven consecutive days")

	begin("completed_dates is unique, descending and bounded by through_iso")
	var dates := Streak.completed_dates(_dates(["2026-09-14", "2026-09-15", "2026-09-15"]), TODAY)
	assert_eq(dates.size(), 2, "duplicates collapse")
	assert_eq(dates[0], "2026-09-15", "descending order")
	assert_eq(dates[1], "2026-09-14", "second entry")
	var bounded := Streak.completed_dates(_dates(["2026-09-16", "2026-09-15"]), TODAY)
	assert_eq(bounded.size(), 1, "entries after through_iso are ignored")
	assert_eq(Streak.completed_dates(_dates(["2026-09-14"]), "").size(), 1,
		"an empty through_iso means no upper bound")


func _test_longest_streak() -> void:
	begin("longest_streak finds the longest run anywhere in the history")
	var separated := _dates([
		"2026-09-01", "2026-09-02", "2026-09-03",
		"2026-09-10", "2026-09-11", "2026-09-12", "2026-09-13",
	])
	assert_eq(Streak.longest_streak(separated), 4, "the later run of four wins")
	assert_eq(Streak.longest_streak(_dates(["2026-09-15"])), 1, "a single day is one")
	var empty: Array[Dictionary] = []
	assert_eq(Streak.longest_streak(empty), 0, "empty history")

	begin("longest_streak ignores today and partial entries")
	assert_eq(Streak.longest_streak(_dates([
		"2026-08-01", "2026-08-02", "2026-08-03", "2026-08-04", "2026-08-05"])), 5,
		"a run that ended long ago still counts")
	var partial: Array[Dictionary] = [_entry("2026-09-15", false), _entry("2026-09-14", false)]
	assert_eq(Streak.longest_streak(partial), 0, "partial entries never extend a streak")
	assert_eq(Streak.longest_streak(_dates([
		"2026-09-13", "2026-09-14", "2026-09-15", "2026-09-17", "2026-09-18"])), 3,
		"a gap breaks the run")


# ------------------------------------------------------------------ R14: week + ring

func _test_week_buckets() -> void:
	begin("09-20 and 09-21 land in different ISO weeks")
	assert_ne(Dates.iso_week_id("2026-09-20"), Dates.iso_week_id("2026-09-21"),
		"Sunday and Monday are different weeks")

	begin("completed_days_in_week counts unique completed days")
	var entries := _dates(["2026-09-21", "2026-09-20"])
	assert_eq(Streak.completed_days_in_week(entries, "2026-W39"), 1, "one day in W39")
	assert_eq(Streak.completed_days_in_week(entries, "2026-W38"), 1, "one day in W38")
	assert_eq(Streak.completed_days_in_week(entries, "2026-W37"), 0, "nothing in W37")
	assert_eq(Streak.completed_days_in_week(_dates(["2026-09-21", "2026-09-21"]), "2026-W39"), 1,
		"two workouts on one day count once")
	var partial: Array[Dictionary] = [_entry("2026-09-21", false)]
	assert_eq(Streak.completed_days_in_week(partial, "2026-W39"), 0,
		"a partial entry never fills the ring")
	assert_eq(Streak.completed_days_in_week(entries, ""), 0, "an empty week id matches nothing")

	begin("week_goal_progress is completed days over the goal")
	assert_close(Streak.week_goal_progress(entries, "2026-09-21", 4), 0.25, 0.0001,
		"one of four days")
	assert_close(Streak.week_goal_progress(entries, "2026-09-21", 1), 1.0, 0.0001,
		"capped at 100%")
	assert_close(Streak.week_goal_progress(entries, "2026-09-21", 0), 1.0, 0.0001,
		"a zero goal cannot divide by zero")
	assert_close(Streak.week_goal_progress(entries, "2026-09-21", 7), 1.0 / 7.0, 0.0001,
		"a seven day goal")
	var empty: Array[Dictionary] = []
	assert_close(Streak.week_goal_progress(empty, "2026-09-21", 4), 0.0, 0.0001,
		"an empty history is 0%")


func _test_ring_segments() -> void:
	begin("ring_segments returns seven Monday-to-Sunday bytes")
	var entries := _dates(["2026-09-14", "2026-09-16", "2026-09-20"])
	var segments := Streak.ring_segments(entries, "2026-W38", 4)
	assert_eq(segments.size(), 7, "seven segments, one per weekday")
	assert_eq(segments, PackedByteArray([1, 0, 1, 0, 0, 0, 0]),
		"Monday and Wednesday are lit; Sunday is outside the goal")
	var wide := Streak.ring_segments(entries, "2026-W38", 7)
	assert_eq(wide, PackedByteArray([1, 0, 1, 0, 0, 0, 1]),
		"a seven day goal lights Sunday too")
	var narrow := Streak.ring_segments(entries, "2026-W38", 1)
	assert_eq(narrow, PackedByteArray([1, 0, 0, 0, 0, 0, 0]),
		"a one day goal lights only Monday")

	begin("ring_segments is empty-safe and malformed-safe")
	var empty: Array[Dictionary] = []
	assert_eq(Streak.ring_segments(empty, "2026-W38", 4), PackedByteArray([0, 0, 0, 0, 0, 0, 0]),
		"an empty history lights nothing")
	assert_eq(Streak.ring_segments(entries, "not-a-week", 4).size(), 7,
		"a malformed week id still yields seven zero bytes")

	begin("ring_segments ignores partial and future entries")
	var partial: Array[Dictionary] = [_entry("2026-09-15", false)]
	assert_eq(Streak.ring_segments(partial, "2026-W38", 7), PackedByteArray([0, 0, 0, 0, 0, 0, 0]),
		"a partial entry lights nothing")
	assert_eq(Streak.ring_segments(_dates(["2026-09-19"]), "2026-W38", 7),
		PackedByteArray([0, 0, 0, 0, 0, 1, 0]), "Saturday is the sixth segment")


func _test_invalid_input_is_safe() -> void:
	begin("invalid input returns the neutral value instead of erroring")
	assert_eq(Dates.add_days("nope", 1), "", "add_days on garbage")
	assert_eq(Dates.add_days("", 1), "", "add_days on an empty string")
	assert_eq(Dates.day_diff("nope", TODAY), 0, "day_diff on garbage")
	assert_eq(Dates.weekday_index(""), 0, "weekday_index on an empty string")
	assert_eq(Dates.iso_week_id("2026-9-15"), "", "iso_week_id on a bad date")
	assert_eq(Dates.iso_week_start("nope"), "", "iso_week_start on garbage")
	assert_eq(Dates.week_id_start("garbage"), "", "week_id_start on garbage")
	assert_eq(Dates.format_long(""), "", "format_long on an empty string")
	assert_eq(Dates.relative_day_label("nope", TODAY), "", "relative_day_label on garbage")
	assert_eq(Dates.epoch_seconds("nope"), 0, "epoch_seconds on garbage")
	assert_eq(Dates.seconds_between_iso("nope", TODAY), 0, "seconds_between_iso on garbage")
	assert_true(Dates.iso_week_days("nope").is_empty(), "iso_week_days on garbage")
	assert_eq(Dates.days_in_month(2026, 0), 0, "month 0 has no days")
	assert_eq(Dates.days_in_month(2026, 13), 0, "month 13 has no days")
	assert_eq(Dates.add_days("2026-09-15", 0).length(), 10, "a valid shift always has a shape")

	begin("helpers default the clock reads instead of inventing a date")
	assert_true(Dates.is_valid_iso_date(Dates.today_iso()), "today_iso() is a real date")
	assert_true(Dates.is_valid_iso_date(Dates.today_iso(true)), "today_iso(true) is a real date")
	assert_true(Dates.is_valid_iso_datetime(Dates.now_iso8601()), "now_iso8601() is a timestamp")
	assert_true(Dates.now_iso8601(true).ends_with("Z"), "the default is UTC")
	assert_false(Dates.now_iso8601(true).ends_with("ZZ"), "exactly one Z suffix")

	begin("streak helpers tolerate entries that are missing fields")
	var malformed: Array[Dictionary] = [
		{"completed": true},
		{"date": "not-a-date", "completed": true},
		{"date": "2026-09-15"},
		{"date": "2026-09-15", "completed": true},
	]
	assert_eq(Streak.current_streak(malformed, TODAY), 1, "only the well-formed entry counts")
	assert_eq(Streak.completed_dates(malformed, TODAY).size(), 1, "one usable date")
	assert_eq(Streak.completed_days_in_week(malformed, "2026-W38"), 1, "the week bucket agrees")
	assert_eq(Streak.longest_streak(malformed), 1, "the longest run is one day")


# ------------------------------------------------------------------ helpers

func _dates(dates: PackedStringArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for date in dates:
		out.append(_entry(date, true))
	return out


func _entry(date_iso: String, completed: bool) -> Dictionary:
	return {
		"id": "h-%s" % date_iso,
		"plan_id": "plan-1758000000",
		"session_id": "s1",
		"session_title": "Full Body A",
		"date": date_iso,
		"started_at": "%sT12:00:00Z" % date_iso,
		"completed_at": "%sT12:40:00Z" % date_iso if completed else "",
		"duration_sec": 2400,
		"exercises_completed": 1 if completed else 0,
		"exercises_total": 1,
		"completed": completed,
	}
