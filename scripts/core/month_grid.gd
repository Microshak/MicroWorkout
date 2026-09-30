class_name MonthGrid
extends RefCounted
## Month-grid maths and calendar day-kind resolution — PRD-11 R3/R6 (appendix §6.4).
##
## Everything here is `static` and pure: no autoloads, no scene tree, no I/O, and no clock read.
## That is what lets the whole calendar be unit-tested headless (`tests/suites/test_month_grid.gd`).
##
## **PRD-11 owns exactly two things here, and nothing else.** The civil-date arithmetic is
## PRD-03's [Dates] (`days_from_civil`, `weekday_index`, `days_in_month`, `add_days`); the
## weekday → session mapping and the day-kind vocabulary are PRD-09's [PlanSchedule]. This file
## only computes *which 42 dates a month page shows* and *what kind each of them is* — it never
## re-derives a streak, an ISO week or a schedule ([method DayStatus.resolve] calls
## `PlanSchedule.session_for_date()` verbatim).
##
## The 42-cell shape is constant on purpose: February 2026 starts on a Sunday, so six rows are
## needed, and keeping every month 42 cells means the screen's node count never changes when the
## month does (R2/R12 — `_refresh()` must not instantiate nodes).

## Columns per calendar row (Monday-first, ISO).
const COLUMNS := 7
## Cells per month page — always six rows, so the grid never resizes.
const CELLS := 42

## Month names for [method label]. The app ships no locale data, so this is a constant, not a
## locale API (R11).
const MONTH_NAMES: PackedStringArray = [
	"January", "February", "March", "April", "May", "June",
	"July", "August", "September", "October", "November", "December",
]


## The 42 ISO dates of [param year]/[param month]'s page, starting at the Monday on or before the
## 1st and running Monday-first. Dates outside the month are still returned — the screen marks
## them `padding` (R6). Empty for an invalid month.
static func cells(year: int, month: int) -> PackedStringArray:
	var out := PackedStringArray()
	if month < 1 or month > 12:
		return out
	var first := first_key(year, month)
	# `weekday_index` is 0 = Monday, so subtracting it lands on the Monday of the 1st's week.
	var start := Dates.add_days(first, -Dates.weekday_index(first))
	for index in CELLS:
		out.append(Dates.add_days(start, index))
	return out


## `"2026-09-01"`.
static func first_key(year: int, month: int) -> String:
	return "%04d-%02d-01" % [year, month]


## `"2026-09-30"`.
static func last_key(year: int, month: int) -> String:
	return "%04d-%02d-%02d" % [year, month, days_in_month(year, month)]


## True when [param iso] is a real date inside [param year]/[param month].
static func contains(year: int, month: int, iso: String) -> bool:
	var parts := month_of(iso)
	return not parts.is_empty() and int(parts[0]) == year and int(parts[1]) == month


## `[year, month]` shifted by [param delta] months, wrapped across years. Invalid input returns
## the unshifted month rather than a wild value.
static func add_months(year: int, month: int, delta: int) -> Array:
	if month < 1 or month > 12:
		return [year, clampi(month, 1, 12)]
	var total := year * 12 + (month - 1) + delta
	var y := int(floor(float(total) / 12.0))
	return [y, total - y * 12 + 1]


## `"September"`; `""` outside 1..12.
static func month_name(month: int) -> String:
	if month < 1 or month > 12:
		return ""
	return MONTH_NAMES[month - 1]


## `"September 2026"` — what `MonthLabel.text` shows (R11). Never a locale API.
static func label(year: int, month: int) -> String:
	return "%s %d" % [month_name(month), year]


## `[year, month]` of a local `YYYY-MM-DD` date; `[]` when it is not a real date.
static func month_of(iso: String) -> Array:
	var parts := Dates.parse_iso_date(iso)
	if parts.is_empty():
		return []
	return [int(parts["y"]), int(parts["m"])]


## Days in [param month]; delegates to [method Dates.days_in_month] so leap years live in one
## place.
static func days_in_month(year: int, month: int) -> int:
	return Dates.days_in_month(year, month)


## Calendar day kinds — the PRD-09 vocabulary plus PRD-11's `padding` (R6). The string values are
## what `day_cell.gd` draws and what tests assert.
class DayStatus extends RefCounted:
	const PADDING := "padding"
	const DONE := "done"
	const TODAY := "today"
	const UPCOMING := "upcoming"
	const REST := "rest"
	const MISSED := "missed"

	## The kind of [param iso] on a page showing [param in_month], first match wins (R6):
	## ① off-month → `padding`; ② a completed day → `done` (an extra workout is a win, never
	## `missed`); ③ today → `today` when the plan trains today, else `rest` (the cell still gets
	## its today border from its own flag); ④ planned future → `upcoming`; ⑤ planned past →
	## `missed`; ⑥ anything else → `rest`.
	##
	## [param completed_dates] is `Streak.completed_dates(entries, "")`; [param entries] is the
	## history array `PlanSchedule.session_for_date()` needs for its cycle anchor. `missed` is
	## only ever returned where `session_for_date()` resolves — days before the plan existed fall
	## through to `rest` (R8's risks table).
	static func resolve(iso: String, today: String, completed_dates: PackedStringArray,
			plan: Dictionary, entries: Array, in_month: bool = true) -> String:
		if not in_month or not Dates.is_valid_iso_date(iso):
			return PADDING
		if completed_dates.has(iso):
			return DONE
		if iso == today:
			return TODAY if _planned(plan, entries, iso) else REST
		var planned := _planned(plan, entries, iso)
		if not planned:
			return REST
		if Dates.is_valid_iso_date(today) and iso > today:
			return UPCOMING
		if Dates.is_valid_iso_date(today) and iso < today:
			return MISSED
		return REST

	## True when the plan has a session for [param iso] — the whole of R6's planned-day test, and
	## deliberately the *only* place this file asks the schedule anything.
	static func _planned(plan: Dictionary, entries: Array, iso: String) -> bool:
		if plan.is_empty():
			return false
		return not PlanSchedule.session_for_date(plan, entries, iso).is_empty()
