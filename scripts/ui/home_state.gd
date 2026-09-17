class_name HomeState
extends RefCounted
## The Home cover screen's state model — PRD-09 R3/R4.
##
## One pure function, [method build], turns the stored documents into a render-ready dictionary:
## which of the five states Home is in, today's session, the next session, the seven week-strip
## pills, the streak and ring numbers, and the greeting line. It is the **only** producer of the
## R4 greeting strings, so the 12 greeting cells and all five states are asserted verbatim in
## `tests/suites/test_home_state.gd` without a screen, a clock or an autoload.
##
## `build()` is a pure function of its five arguments: it never calls `Time.*`, never touches
## [Store], never `await`s, and never reads a file (the appendix's rule 3). Everything that needs
## the clock or the store is handed in:
##
## - [param plans_doc] — `Store.plans_doc()` (`{schema_version, active_plan_id, plans}`)
## - [param entries] — `Store.all_entries()`
## - [param settings] — `Store.settings()`
## - [param derived] — `{streak, week_id, week_completed, week_target, week_fraction, ring_bits}`,
##   pre-computed by the screen from PRD-03's `Store` accessors + [Streak]. **This class
##   implements no streak, week or ring math of its own** (appendix §10 N4): the numbers only
##   travel through it.
## - [param now] — `Time.get_datetime_dict_from_system()`
##
## ## Why this file is in `scripts/ui/`
##
## PRD-09 §5 names `scripts/core/home_state.gd`. The PRD-09 implementer's brief reserved
## `scripts/core/` for `plan_schedule.gd` alone (other PRDs own the rest of that directory while
## they are in flight), so this module ships at `scripts/ui/home_state.gd` with the same
## `class_name HomeState`, the same purity and the same tests. Moving it is a one-line change.

## The five states, in R3's precedence order. `state` is always exactly one of these.
const NO_PLAN := "NO_PLAN"
const TRAINING := "TRAINING"
const DONE_TODAY := "DONE_TODAY"
const REST := "REST"
const PLAN_FINISHED := "PLAN_FINISHED"

## The weekly ring's segment count (`Streak.RING_SEGMENTS`).
const STRIP_DAYS := 7

## R4: the cover's signature line never changes (PRD-00 §4.3).
const TITLE := "Hey Workout"

## R7: the streak tile's caption.
const STREAK_TITLE := "DAY STREAK"

## Strip pill kinds (appendix §6.4's "Day kinds").
const KIND_DONE := "done"
const KIND_TODAY := "today"
const KIND_UPCOMING := "upcoming"
const KIND_REST := "rest"
const KIND_MISSED := "missed"

## R11/R12: shown by the next-up card instead of a weekday name when the next session can be
## done today.
const TODAY_LABEL := "Today"

const _BAND_MORNING := "morning"
const _BAND_AFTERNOON := "afternoon"
const _BAND_EVENING := "evening"

const _MORNING_FROM_HOUR := 5
const _AFTERNOON_FROM_HOUR := 12
const _EVENING_FROM_HOUR := 18


## Builds the whole render-ready state. Every returned key is always present (R3):
##
## `state`, `plan`, `session`, `session_index`, `next_session`, `next_session_index`,
## `next_weekday_name`, `next_scheduled_weekday_name`, `next_days_ahead`, `week_strip`, `streak`,
## `week_completed`, `week_target`, `week_fraction`, `greeting`, `early_label`, `early_available`,
## `done_entry`, `done_minutes`, `cycles`, `total_sessions`, `total_duration_sec`, `today`,
## `days_per_week`, `strip_kinds`.
static func build(plans_doc: Dictionary, entries: Array, settings: Dictionary,
		derived: Dictionary, now: Dictionary) -> Dictionary:
	var today := PlanSchedule.today_iso(now)
	var plan := active_plan_of(plans_doc)
	var settings_goal := _int_of(settings.get("weekly_goal_days", 4), 4)
	var days_per_week := PlanSchedule.days_per_week_of(plan, settings_goal)
	var sessions := PlanSchedule.sessions_of(plan)
	var session_count := sessions.size()

	var streak := _int_of(derived.get("streak", 0), 0)
	var week_completed := _int_of(derived.get("week_completed", 0), 0)
	var week_target := _int_of(derived.get("week_target", 0), 0)
	var week_fraction := _float_of(derived.get("week_fraction", 0.0))
	var ring_bits := _bytes_of(derived.get("ring_bits", null))

	var state := resolve_state(plan, entries, today, days_per_week)
	var done_entry := first_completed_entry_on(entries, today)

	var session := {}
	var session_index := 0
	var next_session := {}
	var next_index := 0
	var next_name := ""
	var next_scheduled := ""
	var next_ahead := 0
	var early_available := false

	match state:
		TRAINING:
			session_index = PlanSchedule.session_index_for(plan, entries)
			session = _session_at(sessions, session_index)
			next_index = (session_index + 1) % maxi(session_count, 1)
			next_session = _session_at(sessions, next_index)
			var upcoming := PlanSchedule.next_training_day(today, days_per_week)
			next_name = String(upcoming.get("weekday_name", ""))
			next_scheduled = next_name
			next_ahead = _int_of(upcoming.get("days_ahead", 0), 0)
		DONE_TODAY:
			# Today's completion has already advanced the cycle counter.
			session_index = PlanSchedule.session_index_for(plan, entries)
			next_index = session_index
			next_session = _session_at(sessions, next_index)
			var following := PlanSchedule.next_training_day(today, days_per_week)
			next_scheduled = String(following.get("weekday_name", ""))
			early_available = not next_session.is_empty()
			if PlanSchedule.is_training_day(today, days_per_week):
				# Still a planned day: the next session can be brought forward to today.
				next_name = TODAY_LABEL
				next_ahead = 0
			else:
				next_name = next_scheduled
				next_ahead = _int_of(following.get("days_ahead", 0), 0)
		REST:
			session_index = PlanSchedule.session_index_for(plan, entries)
			next_index = session_index
			next_session = _session_at(sessions, next_index)
			var upcoming := PlanSchedule.next_training_day(today, days_per_week)
			next_name = String(upcoming.get("weekday_name", ""))
			next_scheduled = next_name
			next_ahead = _int_of(upcoming.get("days_ahead", 0), 0)
			early_available = not next_session.is_empty()
		_:
			# NO_PLAN and PLAN_FINISHED preview nothing (R10/R13).
			pass

	var strip := build_week_strip(state, plan, entries, today, days_per_week)
	var completed := 0
	var duration_sec := 0
	if not plan.is_empty():
		var plan_id := String(plan.get("id", ""))
		for entry in entries:
			if not (entry is Dictionary):
				continue
			var record: Dictionary = entry
			if String(record.get("plan_id", "")) != plan_id:
				continue
			if not bool(record.get("completed", false)):
				continue
			completed += 1
			duration_sec += _int_of(record.get("duration_sec", 0), 0)

	var early_label := ""
	if early_available and not next_scheduled.is_empty():
		early_label = "Do %s early" % next_scheduled

	return {
		"state": state,
		"plan": plan,
		"session": session,
		"session_index": session_index,
		"next_session": next_session,
		"next_session_index": next_index,
		"next_weekday_name": next_name,
		"next_scheduled_weekday_name": next_scheduled,
		"next_days_ahead": next_ahead,
		"week_strip": strip,
		"streak": streak,
		"week_completed": week_completed if state != NO_PLAN else 0,
		"week_target": week_target if state != NO_PLAN else 0,
		"week_fraction": week_fraction if state != NO_PLAN else 0.0,
		"ring_bits": ring_bits,
		"greeting": greeting_for(state, _band_of(now), streak),
		"early_label": early_label,
		"early_available": early_available,
		"done_entry": done_entry,
		"done_minutes": floori(float(_int_of(done_entry.get("duration_sec", 0), 0)) / 60.0),
		"cycles": PlanSchedule.finished_cycles(plan, entries),
		"total_sessions": completed,
		"total_duration_sec": duration_sec,
		"today": today,
		"days_per_week": days_per_week,
		"settings_goal": settings_goal,
		"strip_kinds": strip_kinds(strip),
	}


# ------------------------------------------------------------------ state resolution (R3)

## R3's precedence, first match wins:
## 1. every session has >= 4 completions → `PLAN_FINISHED`; 2. no active plan → `NO_PLAN`;
## 3. a completed entry exists for today → `DONE_TODAY`; 4. a planned weekday → `TRAINING`;
## 5. otherwise → `REST`.
static func resolve_state(plan: Dictionary, entries: Array, today: String,
		days_per_week: int) -> String:
	if not plan.is_empty() and PlanSchedule.is_plan_finished(plan, entries):
		return PLAN_FINISHED
	if plan.is_empty():
		return NO_PLAN
	if not first_completed_entry_on(entries, today).is_empty():
		return DONE_TODAY
	if PlanSchedule.is_training_day(today, days_per_week):
		return TRAINING
	return REST


static func is_no_plan(state: String) -> bool:
	return state == NO_PLAN


## The active plan out of a `plans.json` view, or `{}` when there is none / the pointer dangles.
static func active_plan_of(plans_doc: Dictionary) -> Dictionary:
	var plan_id := String(plans_doc.get("active_plan_id", ""))
	if plan_id.is_empty():
		return {}
	var raw: Variant = plans_doc.get("plans", [])
	if not (raw is Array):
		return {}
	for element in (raw as Array):
		if not (element is Dictionary):
			continue
		var plan: Dictionary = element
		if String(plan.get("id", "")) == plan_id:
			return plan
	return {}


## The first completed entry dated [param date_iso] (`{}` when there is none). History is stored
## in `date`, `started_at` order, so "first" is the day's earliest finished session.
static func first_completed_entry_on(entries: Array, date_iso: String) -> Dictionary:
	if not Dates.is_valid_iso_date(date_iso):
		return {}
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var record: Dictionary = entry
		if String(record.get("date", "")) != date_iso:
			continue
		if bool(record.get("completed", false)):
			return record
	return {}


static func has_completed_entry_on(entries: Array, date_iso: String) -> bool:
	return not first_completed_entry_on(entries, date_iso).is_empty()


# ------------------------------------------------------------------ week strip (R6)

## Seven pills, Monday → Sunday, each `{weekday_iso, letter, date, kind}` with
## `kind ∈ done|today|upcoming|rest|missed`.
##
## `NO_PLAN` renders seven `rest` pills and `PLAN_FINISHED` seven `done` pills (R10/R13) —
## neither state has a training pattern to apply.
static func build_week_strip(state: String, plan: Dictionary, entries: Array, today: String,
		days_per_week: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dates := PlanSchedule.week_dates(today)
	var cycle_start := PlanSchedule.cycle_start_date(plan, entries)
	for index in STRIP_DAYS:
		var date := dates[index] if index < dates.size() else ""
		var weekday := index + 1
		var kind := KIND_REST
		match state:
			NO_PLAN:
				kind = KIND_REST
			PLAN_FINISHED:
				kind = KIND_DONE
			_:
				kind = _strip_kind(date, today, entries, days_per_week, cycle_start)
		out.append({
			"weekday_iso": weekday,
			"letter": PlanSchedule.weekday_letter(weekday),
			"date": date,
			"kind": kind,
		})
	return out


static func _strip_kind(date: String, today: String, entries: Array, days_per_week: int,
		cycle_start: String) -> String:
	if has_completed_entry_on(entries, date):
		return KIND_DONE
	if date == today:
		return KIND_TODAY
	# A day the plan never trains on is a rest day whenever it falls — R6 states this for today
	# and the future; a *past* rest day has no other kind that fits, and calling it `upcoming`
	# would tint yesterday's Wednesday like tomorrow's session.
	if not PlanSchedule.is_training_day(date, days_per_week):
		return KIND_REST
	if date > today:
		return KIND_UPCOMING
	# A past planned day that was never trained, and not before the plan's own cycle started,
	# is a miss.
	if cycle_start.is_empty() or date >= cycle_start:
		return KIND_MISSED
	return KIND_UPCOMING


## The seven kinds in strip order, for the `[home] strip=…` log line and for tests.
static func strip_kinds(strip: Array[Dictionary]) -> PackedStringArray:
	var out := PackedStringArray()
	for day in strip:
		out.append(String(day.get("kind", "")))
	return out


# ------------------------------------------------------------------ greeting (R4)

## `"1 day"` / `"%d days"` (R4).
static func format_streak(count: int) -> String:
	if count == 1:
		return "1 day"
	return "%d days" % count


## `morning` 05:00–11:59, `afternoon` 12:00–17:59, `evening` 18:00–04:59 — 00:00–04:59 folds
## into evening so there is no fourth band and no "night" copy (R4).
static func band_of(now: Dictionary) -> String:
	return _band_of(now)


## The `SubGreetingLabel` line for a state, band and streak. R4's matrix verbatim; the three
## plan-independent states override it because they have no training/rest dimension.
static func greeting_for(state: String, band: String, streak: int) -> String:
	match state:
		NO_PLAN:
			return "%s. Let's build your first week." % _band_prefix(band)
		DONE_TODAY:
			return "Nice — today's session is done."
		PLAN_FINISHED:
			return "That plan is complete. Nice work."
	# TRAINING / REST are the only states left; `REST` is the "rest" column. `{n+1}` is computed,
	# never templated: a 3-day streak reads "one more makes it 4".
	if state == TRAINING:
		match band:
			_BAND_MORNING:
				if streak > 0:
					return "Morning. %d in a row — let's keep it going." % streak
				return "Morning. Here's what's on for today."
			_BAND_AFTERNOON:
				if streak > 0:
					return "Afternoon. %d on the line — today's session is ready." % streak
				return "Afternoon. Your session is ready when you are."
			_:
				if streak > 0:
					return "Evening. %d in a row — one more makes it %d." % [streak, streak + 1]
				return "Evening. Still time to get today's session in."
	match band:
		_BAND_MORNING:
			if streak > 0:
				return "Morning. Rest today — %d in a row so far." % streak
			return "Morning. Nothing planned today."
		_BAND_AFTERNOON:
			if streak > 0:
				return "Afternoon. Rest day — %d in a row so far." % streak
			return "Afternoon. Nothing planned today."
		_:
			if streak > 0:
				return "Evening. Rest today — %d in a row so far." % streak
			return "Evening. Nothing planned today."


# ------------------------------------------------------------------ internals

static func _band_of(now: Dictionary) -> String:
	var hour := _int_of(now.get("hour", -1), -1)
	if hour >= _MORNING_FROM_HOUR and hour < _AFTERNOON_FROM_HOUR:
		return _BAND_MORNING
	if hour >= _AFTERNOON_FROM_HOUR and hour < _EVENING_FROM_HOUR:
		return _BAND_AFTERNOON
	return _BAND_EVENING


static func _band_prefix(band: String) -> String:
	match band:
		_BAND_MORNING:
			return "Morning"
		_BAND_AFTERNOON:
			return "Afternoon"
	return "Evening"


static func _session_at(sessions: Array, index: int) -> Dictionary:
	if sessions.is_empty() or index < 0 or index >= sessions.size():
		return {}
	var value: Variant = sessions[index]
	return value if value is Dictionary else {}


static func _int_of(value: Variant, fallback: int) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String and String(value).is_valid_int():
		return int(value)
	return fallback


static func _float_of(value: Variant) -> float:
	if value is float:
		return value
	if value is int:
		return float(value)
	if value is String and String(value).is_valid_float():
		return float(value)
	return 0.0


static func _bytes_of(value: Variant) -> PackedByteArray:
	return value if value is PackedByteArray else PackedByteArray()
