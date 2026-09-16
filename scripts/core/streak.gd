class_name Streak
extends RefCounted
## Streak, week and ring arithmetic — PRD-03 R13 / R14 / R15.
##
## Pure functions over an array of history entries: no scene tree, no autoloads, no I/O.
## Every consumer (Home, Tracker, the weekly ring, the data probe) calls these instead of
## re-implementing "what is a streak", so two screens can never disagree about it
## (appendix R52).
##
## Canonical semantics (appendix §6.4):
## - only entries with `completed == true` and a valid, non-future `date` count;
## - several completed sessions on one local calendar day collapse to **one** day;
## - a streak runs backwards from today, or from yesterday when today is not done yet
##   (so an unfinished today never breaks a streak);
## - the ring numerator is *unique completed days* in the ISO week, the denominator is
##   `Store.weekly_goal_days_effective()`.

## The seven-byte ring shape drawn by PRD-11: one byte per Monday→Sunday slot.
const RING_SEGMENTS := 7


## Unique completed local dates at or before [param through_iso], **descending**.
## An empty [param through_iso] means "no upper bound".
static func completed_dates(entries: Array[Dictionary], through_iso: String) -> PackedStringArray:
	var seen := {}
	for entry in entries:
		if not bool(entry.get("completed", false)):
			continue
		var date := String(entry.get("date", ""))
		if not Dates.is_valid_iso_date(date):
			continue
		if not through_iso.is_empty() and date > through_iso:
			continue
		seen[date] = true
	var ascending := PackedStringArray(seen.keys())
	ascending.sort()
	var descending := PackedStringArray()
	for i in range(ascending.size() - 1, -1, -1):
		descending.append(ascending[i])
	return descending


## Consecutive completed days ending today, or yesterday when today is still open.
static func current_streak(entries: Array[Dictionary], today: String) -> int:
	var dates := completed_dates(entries, today)
	if dates.is_empty():
		return 0
	var cursor := today
	if dates[0] != today:
		# Grace: today has not been trained (yet) — the run may still end yesterday.
		cursor = Dates.add_days(today, -1)
	var count := 0
	while dates.has(cursor):
		count += 1
		cursor = Dates.add_days(cursor, -1)
	return count


## The longest maximal run of completed days anywhere in the history.
static func longest_streak(entries: Array[Dictionary]) -> int:
	var descending := completed_dates(entries, "")
	var previous := ""
	var run := 0
	var best := 0
	for i in range(descending.size() - 1, -1, -1):
		var date := descending[i]
		if not previous.is_empty() and Dates.day_diff(date, previous) == 1:
			run += 1
		else:
			run = 1
		best = maxi(best, run)
		previous = date
	return best


## Unique completed days inside ISO week [param week_id] (e.g. `"2026-W38"`).
static func completed_days_in_week(entries: Array[Dictionary], week_id: String) -> int:
	if week_id.is_empty():
		return 0
	var seen := {}
	for entry in entries:
		if not bool(entry.get("completed", false)):
			continue
		var date := String(entry.get("date", ""))
		if not Dates.is_valid_iso_date(date):
			continue
		if Dates.iso_week_id(date) == week_id:
			seen[date] = true
	return seen.size()


## `completed_days_in_week(today's week) / goal_days`, clamped to 0.0 … 1.0.
static func week_goal_progress(entries: Array[Dictionary], today: String, goal_days: int) -> float:
	var week_id := Dates.iso_week_id(today)
	if week_id.is_empty():
		return 0.0
	var done := completed_days_in_week(entries, week_id)
	return clampf(float(done) / float(maxi(goal_days, 1)), 0.0, 1.0)


## Seven bytes, Monday → Sunday: `1` when that day has a completed entry **and** its
## Monday-based index is below [param goal_days] (PRD-11 draws these as ring ticks).
static func ring_segments(entries: Array[Dictionary], week_id: String, goal_days: int) -> PackedByteArray:
	var segments := PackedByteArray()
	segments.resize(RING_SEGMENTS)
	var monday := Dates.week_id_start(week_id)
	if monday.is_empty():
		return segments
	var done := {}
	for entry in entries:
		if not bool(entry.get("completed", false)):
			continue
		var date := String(entry.get("date", ""))
		if Dates.is_valid_iso_date(date):
			done[date] = true
	var limit := maxi(goal_days, 0)
	for i in RING_SEGMENTS:
		var date := Dates.add_days(monday, i)
		segments[i] = 1 if (done.has(date) and i < limit) else 0
	return segments
