class_name PlanSchedule
extends RefCounted
## Deterministic weekday → session mapping, cycle index and session lookup — PRD-09 R3,
## appendix §6.3 (R48/R49).
##
## Why this file exists: nothing in the original model mapped a session to a weekday or defined
## a rest day (PRD-00 §5.3 gives sessions only an `index`), so "today's session" was undefined.
## PRD-09 owns the answer because it is the first screen that needs it; **PRD-10 and PRD-11
## import this file, they never re-derive it** (appendix R48/R52).
##
## Everything here is `static`, pure and scene-tree-free: no autoloads, no I/O, no `Time` clock
## read except [method today_iso]'s explicit fallback. That is what makes the whole schedule
## model unit-testable headless (`tests/suites/test_plan_schedule.gd`).
##
## ## The model (one paragraph)
##
## Sessions are consumed in `index` order, one per **planned weekday**, and the plan repeats
## weekly forever. `weekdays_for(4)` is `[1, 2, 4, 5]` (Mon, Tue, Thu, Fri — ISO weekday numbers,
## Monday = 1). A cycle is anchored at the most recent completion of the plan's **last** session
## ([method cycle_start_date]); when there is none, it is anchored at `plan.created_at`'s date.
## Because the closing completion *belongs to the cycle it closed*, the new cycle starts at the
## first training day **after** it — see [method session_index_for] for why the literal
## `date >= cycle_start_date` reading is off by one at every cycle boundary.
##
## ## Date arithmetic
##
## PRD-09 R3 asked for `Time.get_unix_time_from_datetime_dict({…, "hour": 12})` so a DST shift
## can never move a date by a day. This module instead routes every date operation through
## PRD-03's frozen [Dates] layer, which does pure civil-calendar arithmetic (Hinnant's
## `days_from_civil`) and never touches a timezone at all — strictly DST-proof, and the
## project's **single** date implementation (appendix §10 N4/R52 forbids a second one).

## A plan counts as finished once **every** session has this many completed entries
## (appendix §6.3, R49). Four full cycles ≈ four weeks at the plan's own cadence.
const FINISH_CYCLES := 4

## [method weekdays_for] clamps into this range (appendix §6.4: `days_per_week` is 1..6 for a
## plan, 7 is accepted for the settings/ring preview).
const MIN_DAYS_PER_WEEK := 1
const MAX_DAYS_PER_WEEK := 7

## The frozen ISO weekday table — Monday = 1 … Sunday = 7 (appendix §6.3, PRD-11 R8's identical
## numbers). Key is `days_per_week`, value is the weekday numbers in session order.
const WEEKDAY_PATTERNS: Dictionary = {
	1: [3],
	2: [1, 4],
	3: [1, 3, 5],
	4: [1, 2, 4, 5],
	5: [1, 2, 3, 5, 6],
	6: [1, 2, 3, 4, 5, 6],
	7: [1, 2, 3, 4, 5, 6, 7],
}

## Index 0 is Monday (ISO), so `WEEKDAY_NAMES[weekday_iso - 1]`.
const WEEKDAY_NAMES: PackedStringArray = [
	"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
]

## The seven strip letters, Monday → Sunday.
const WEEKDAY_LETTERS: PackedStringArray = ["M", "T", "W", "T", "F", "S", "S"]

## Returned by [method next_training_day] when the input date is unusable.
const NO_DAY := {"weekday_iso": 0, "days_ahead": 0, "weekday_name": ""}


# ------------------------------------------------------------------ weekdays

## The weekday numbers a `days_per_week`-day plan trains on, in session order (R3's table).
## Out-of-range input clamps into 1..7 and logs `[schedule] days_per_week=%d clamped`.
static func weekdays_for(days_per_week: int) -> Array[int]:
	var out: Array[int] = []
	var clamped := clampi(days_per_week, MIN_DAYS_PER_WEEK, MAX_DAYS_PER_WEEK)
	if clamped != days_per_week:
		print("[schedule] days_per_week=%d clamped" % days_per_week)
	var pattern: Array = WEEKDAY_PATTERNS[clamped]
	for value: int in pattern:
		out.append(value)
	return out


## `"Tuesday"` for ISO weekday 2; `""` outside 1..7.
static func weekday_name(iso: int) -> String:
	if iso < 1 or iso > 7:
		return ""
	return WEEKDAY_NAMES[iso - 1]


## `"T"` for ISO weekday 2; `""` outside 1..7. (Both Tuesday and Thursday are `"T"`, as on
## every paper calendar.)
static func weekday_letter(iso: int) -> String:
	if iso < 1 or iso > 7:
		return ""
	return WEEKDAY_LETTERS[iso - 1]


## ISO weekday of a local `"YYYY-MM-DD"` date: Monday = 1 … Sunday = 7, `0` when the date is
## not a real calendar date.
static func weekday_iso(date_key: String) -> int:
	if not Dates.is_valid_iso_date(date_key):
		return 0
	return Dates.weekday_index(date_key) + 1


## The local calendar day of a `Time.get_datetime_dict_from_system()`-shaped dictionary.
## Taking the clock as an argument is what keeps [method HomeState.build] pure.
static func today_iso(now: Dictionary) -> String:
	var year := _int_of(now.get("year", 0))
	var month := _int_of(now.get("month", 0))
	var day := _int_of(now.get("day", 0))
	var composed := "%04d-%02d-%02d" % [year, month, day]
	if Dates.is_valid_iso_date(composed):
		return composed
	# A malformed clock dictionary degrades to the system clock rather than to an empty date,
	# so Home can never render a blank day.
	return Dates.today_iso(false)


## True when [param date_key] is one of the plan's training weekdays (R3).
static func is_training_day(date_key: String, days_per_week: int) -> bool:
	return weekdays_for(days_per_week).has(weekday_iso(date_key))


## The next training day strictly after [param date_key] (R3): the smallest `d >= 1` whose
## weekday is in the pattern. Returns `{weekday_iso, days_ahead, weekday_name}`; a non-training
## input date is fine — the answer is simply the next planned weekday.
static func next_training_day(date_key: String, days_per_week: int) -> Dictionary:
	if not Dates.is_valid_iso_date(date_key):
		return NO_DAY.duplicate()
	var pattern := weekdays_for(days_per_week)
	# The pattern is never empty, so a hit is guaranteed inside seven days.
	for ahead in range(1, 8):
		var candidate := Dates.add_days(date_key, ahead)
		var iso := weekday_iso(candidate)
		if pattern.has(iso):
			return {
				"weekday_iso": iso,
				"days_ahead": ahead,
				"weekday_name": weekday_name(iso),
			}
	return NO_DAY.duplicate()


## The seven dates of [param date_key]'s ISO week, Monday → Sunday (`[]` for an invalid date).
static func week_dates(date_key: String) -> PackedStringArray:
	if not Dates.is_valid_iso_date(date_key):
		return PackedStringArray()
	return Dates.iso_week_days(date_key)


# ------------------------------------------------------------------ the plan

## A plan's `sessions` array, or `[]` when the field is missing or malformed.
static func sessions_of(plan: Dictionary) -> Array:
	var raw: Variant = plan.get("sessions", [])
	return raw if raw is Array else []


## A plan's `days_per_week`, clamped into 1..7, falling back to [param fallback] when the field
## is missing or not a positive integer.
static func days_per_week_of(plan: Dictionary, fallback: int = 4) -> int:
	var days := _int_of(plan.get("days_per_week", 0))
	if days < MIN_DAYS_PER_WEEK or days > MAX_DAYS_PER_WEEK:
		return clampi(fallback, MIN_DAYS_PER_WEEK, MAX_DAYS_PER_WEEK)
	return days


## The `date` of the most recent completed entry of the plan's **last** session — the anchor of
## the current cycle — or the date part of `plan.created_at` when the plan has never been
## completed once. `""` when neither is available (`R3`).
static func cycle_start_date(plan: Dictionary, entries: Array) -> String:
	var sessions := sessions_of(plan)
	if not sessions.is_empty():
		var plan_id := String(plan.get("id", ""))
		var last_id := _session_id(sessions[sessions.size() - 1])
		var best := ""
		for entry in entries:
			if not (entry is Dictionary):
				continue
			var record: Dictionary = entry
			if String(record.get("plan_id", "")) != plan_id:
				continue
			if not bool(record.get("completed", false)):
				continue
			if String(record.get("session_id", "")) != last_id:
				continue
			var date := String(record.get("date", ""))
			if Dates.is_valid_iso_date(date) and (best.is_empty() or date > best):
				best = date
		if not best.is_empty():
			return best
	return created_at_date(plan)


## The `YYYY-MM-DD` part of `plan.created_at` (`""` when it is missing or malformed).
static func created_at_date(plan: Dictionary) -> String:
	var stamp := String(plan.get("created_at", ""))
	var date := stamp.substr(0, 10)
	return date if Dates.is_valid_iso_date(date) else ""


## Index into `plan.sessions` of the session **waiting to be done**: `done_in_cycle` modulo the
## session count (R3). `0` for an empty/invalid plan.
##
## `done_in_cycle` counts this plan's completed entries since the cycle anchor. The anchor
## completion itself is a completion of the *previous* cycle, so it is not counted; without that
## correction a plan that has just finished a full cycle would resume one session late (a Monday
## would run session 2 instead of session 1). PRD-09 §7's illustrative line
## (`state=TRAINING session=s1 index=2 done_in_cycle=2`) still holds: mid-cycle the two readings
## are identical, and every extra completion of the closing session at/after the anchor is
## treated as part of the cycle it closed.
static func session_index_for(plan: Dictionary, entries: Array) -> int:
	var sessions := sessions_of(plan)
	if sessions.is_empty():
		return 0
	var plan_id := String(plan.get("id", ""))
	var anchor := _cycle_anchor(plan, entries)
	var done := _completed_since(plan_id, entries, String(anchor["date"]))
	if bool(anchor["closes_cycle"]):
		var last_id := _session_id(sessions[sessions.size() - 1])
		done -= _completed_since_of_session(plan_id, last_id, entries, String(anchor["date"]))
	return maxi(done, 0) % sessions.size()


## The session planned for [param date_key] — the exact signature PRD-11 R9 consumes for its
## calendar and day-detail screens. `{}` when the date is not one of the plan's training days.
##
## This is the **calendar projection**: the weekly template, anchored at the cycle start, so a
## date's session depends only on `plan` + `entries` (never on "now"). It agrees with
## [method session_index_for] on every week without a skipped session; they differ only where the
## owner skipped a planned day (the calendar keeps the weekday cadence, the progress index
## advances on completion) or trained out of sequence, which is deliberate.
static func session_for_date(plan: Dictionary, entries: Array, date_key: String) -> Dictionary:
	var sessions := sessions_of(plan)
	if sessions.is_empty():
		return {}
	var days := days_per_week_of(plan)
	if not is_training_day(date_key, days):
		return {}
	var anchor := _cycle_anchor(plan, entries)
	var anchor_date := String(anchor["date"])
	var count := sessions.size()
	if anchor_date.is_empty():
		# No usable anchor: a training day can only be answered with the first session.
		return _session_at(sessions, 0)
	if bool(anchor["closes_cycle"]):
		# The closing completion belongs to the cycle it closed: on and before its day the
		# calendar counts backwards from the last session, after it the new cycle starts at
		# session 1 on the very next training day.
		if date_key <= anchor_date:
			var back := _training_day_count(Dates.add_days(date_key, 1), anchor_date, days)
			return _session_at(sessions, ((count - 1 - back) % count + count) % count)
		var after := _training_day_count(Dates.add_days(anchor_date, 1), date_key, days) - 1
		return _session_at(sessions, maxi(after, 0) % count)
	if date_key < anchor_date:
		# Before the plan existed there is nothing to project.
		return {}
	# No cycle has closed yet: the weekly template starts at the creation date, so the first
	# training day at or after it is session 1.
	var steps := _training_day_count(anchor_date, date_key, days) - 1
	return _session_at(sessions, maxi(steps, 0) % count)


# ------------------------------------------------------------------ plan finished (R49)

## Completed-entry counts per session id, for the plan's own sessions only.
static func completion_counts(plan: Dictionary, entries: Array) -> Dictionary:
	var counts := {}
	for session in sessions_of(plan):
		counts[_session_id(session)] = 0
	var plan_id := String(plan.get("id", ""))
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var record: Dictionary = entry
		if String(record.get("plan_id", "")) != plan_id:
			continue
		if not bool(record.get("completed", false)):
			continue
		var session_id := String(record.get("session_id", ""))
		if counts.has(session_id):
			counts[session_id] = int(counts[session_id]) + 1
	return counts


## The number of **complete** cycles: the smallest per-session completion count (R13's `cycles`).
static func finished_cycles(plan: Dictionary, entries: Array) -> int:
	var counts := completion_counts(plan, entries)
	if counts.is_empty():
		return 0
	var fewest := -1
	for session_id in counts:
		var value := int(counts[session_id])
		fewest = value if fewest < 0 else mini(fewest, value)
	return maxi(fewest, 0)


## Appendix §6.3's "plan finished": every session of the plan has >= [constant FINISH_CYCLES]
## completed entries with `plan_id == plan.id`.
static func is_plan_finished(plan: Dictionary, entries: Array) -> bool:
	var counts := completion_counts(plan, entries)
	if counts.is_empty():
		return false
	for session_id in counts:
		if int(counts[session_id]) < FINISH_CYCLES:
			return false
	return true


# ------------------------------------------------------------------ internals

## The anchor of the current cycle: `{"date": String, "closes_cycle": bool}`.
##
## `closes_cycle == true` means the anchor is the completion of the plan's last session, so the
## anchor day belongs to the cycle that just ended and the new cycle starts the day after it.
static func _cycle_anchor(plan: Dictionary, entries: Array) -> Dictionary:
	var sessions := sessions_of(plan)
	if not sessions.is_empty():
		var plan_id := String(plan.get("id", ""))
		var last_id := _session_id(sessions[sessions.size() - 1])
		var best := ""
		for entry in entries:
			if not (entry is Dictionary):
				continue
			var record: Dictionary = entry
			if String(record.get("plan_id", "")) != plan_id:
				continue
			if not bool(record.get("completed", false)):
				continue
			if String(record.get("session_id", "")) != last_id:
				continue
			var date := String(record.get("date", ""))
			if Dates.is_valid_iso_date(date) and (best.is_empty() or date > best):
				best = date
		if not best.is_empty():
			return {"date": best, "closes_cycle": true}
	return {"date": created_at_date(plan), "closes_cycle": false}


## Completed entries of [param plan_id] dated [param since] or later.
static func _completed_since(plan_id: String, entries: Array, since: String) -> int:
	var total := 0
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var record: Dictionary = entry
		if String(record.get("plan_id", "")) != plan_id:
			continue
		if not bool(record.get("completed", false)):
			continue
		var date := String(record.get("date", ""))
		if not Dates.is_valid_iso_date(date):
			continue
		if since.is_empty() or date >= since:
			total += 1
	return total


## The same, restricted to one session id.
static func _completed_since_of_session(plan_id: String, session_id: String, entries: Array,
		since: String) -> int:
	var total := 0
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var record: Dictionary = entry
		if String(record.get("plan_id", "")) != plan_id:
			continue
		if String(record.get("session_id", "")) != session_id:
			continue
		if not bool(record.get("completed", false)):
			continue
		var date := String(record.get("date", ""))
		if not Dates.is_valid_iso_date(date):
			continue
		if since.is_empty() or date >= since:
			total += 1
	return total


## How many training days of a `days_per_week` plan fall inside `[from_iso, to_iso]`
## (inclusive on both ends). `0` when either end is invalid or the range is empty.
static func _training_day_count(from_iso: String, to_iso: String, days_per_week: int) -> int:
	if not Dates.is_valid_iso_date(from_iso) or not Dates.is_valid_iso_date(to_iso):
		return 0
	var span := Dates.day_diff(to_iso, from_iso) + 1
	if span <= 0:
		return 0
	var pattern := weekdays_for(days_per_week)
	# Any whole seven-day block contains exactly one of each planned weekday, so only the
	# remainder needs a day-by-day walk (at most six days).
	var weeks := floori(float(span) / 7.0)
	var remainder := span - weeks * 7
	var count := weeks * pattern.size()
	var cursor := from_iso
	for _day in remainder:
		if pattern.has(weekday_iso(cursor)):
			count += 1
		cursor = Dates.add_days(cursor, 1)
	return count


static func _session_at(sessions: Array, index: int) -> Dictionary:
	if sessions.is_empty() or index < 0 or index >= sessions.size():
		return {}
	var value: Variant = sessions[index]
	return value if value is Dictionary else {}


static func _session_id(session: Variant) -> String:
	if not (session is Dictionary):
		return ""
	return String((session as Dictionary).get("id", ""))


static func _int_of(value: Variant) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String and String(value).is_valid_int():
		return int(value)
	return 0
