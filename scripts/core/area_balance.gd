class_name AreaBalance
extends RefCounted
## Body-area tally and neglect detection — PRD-11 R9 (appendix §6.4, R29/R30).
##
## Pure and `static`: it reads history *records* and plan *documents* and returns one row per
## user area. No autoloads, no scene tree, no clock read, so the whole tally is unit-tested
## headless (`tests/suites/test_area_balance.gd`).
##
## **Attribution order (R30):** `entry.focus` first — PRD-10 copies the session's focus into the
## entry at write time, which is what keeps the tally correct after a plan is replaced or
## deleted — then the plan/session lookup, then `_unattributed`. A session is never silently
## dropped; an entry that cannot be attributed *anywhere* increments `_unattributed`.
##
## **Window:** [constant WINDOW_DAYS] = 84 (12 weeks), inclusive of the boundary day: an entry
## exactly 84 days old counts, one 85 days old does not (R13's boundary test). Future-dated
## entries are ignored, exactly as in [Streak].
##
## **Neglect:** `sessions == 0` or `days_since > 14` (`days_since == 14` is *not* neglected — R9).
## Only areas the active plan actually trains are ever reported, so the owner is never nagged
## about a body area they deliberately left out.

## History entries that resolve to no area at all are counted here instead of vanishing.
const UNATTRIBUTED := "_unattributed"

## 12 weeks, boundary day included.
const WINDOW_DAYS := 84

## A trained area is neglected when its last session is older than this (`== 14` is not, `15` is).
const THRESHOLD_DAYS := 14


## One slot per user area (§6.1 order) plus [constant UNATTRIBUTED]:
## `{sessions: int, last_date: String, days_since: int}`. Empty totals are `0 / "" / -1` — never
## `NaN`, so the screen can render "never" without a special case.
##
## [param plans_by_id] is the caller's `{plan_id: plan}` view (the screen builds it from
## `Store.plans_doc()`); a missing plan is what `_unattributed` exists for.
static func tally(entries: Array[Dictionary], plans_by_id: Dictionary, today_iso: String,
		window_days: int = WINDOW_DAYS) -> Dictionary:
	var out := {}
	for area in Taxonomy.USER_AREAS:
		out[area] = {"sessions": 0, "last_date": "", "days_since": -1}
	out[UNATTRIBUTED] = {"sessions": 0, "last_date": "", "days_since": -1}
	if not Dates.is_valid_iso_date(today_iso):
		return out
	var window := maxi(window_days, 0)
	for entry in entries:
		if not bool(entry.get("completed", false)):
			continue
		var date := String(entry.get("date", ""))
		if not Dates.is_valid_iso_date(date):
			continue
		var age := Dates.day_diff(today_iso, date)
		if age < 0 or age > window:
			continue
		var areas := _areas_for(entry, plans_by_id)
		if areas.is_empty():
			_bump(out[UNATTRIBUTED], date)
			continue
		for area in areas:
			_bump(out[area], date)
	for key in out:
		var slot: Dictionary = out[key]
		var last := String(slot.get("last_date", ""))
		slot["days_since"] = Dates.day_diff(today_iso, last) if not last.is_empty() else -1
	return out


## The area keys that are due for attention: `sessions == 0` or `days_since > threshold_days`,
## restricted to [param plan_areas] (pass all seven when there is no active plan). Returned in
## §6.1 order. `today_iso` re-derives `days_since` from `last_date` so a stale tally dictionary
## cannot make the verdict disagree with the calendar day it is shown on.
static func neglected(tally_data: Dictionary, plan_areas: PackedStringArray, today_iso: String,
		threshold_days: int = THRESHOLD_DAYS) -> PackedStringArray:
	var out := PackedStringArray()
	for area in Taxonomy.USER_AREAS:
		if not plan_areas.has(area):
			continue
		var slot_variant: Variant = tally_data.get(area, {})
		if not (slot_variant is Dictionary):
			out.append(area)
			continue
		var slot: Dictionary = slot_variant
		if int(slot.get("sessions", 0)) <= 0:
			out.append(area)
			continue
		var last := String(slot.get("last_date", ""))
		if not Dates.is_valid_iso_date(last) or not Dates.is_valid_iso_date(today_iso):
			out.append(area)
			continue
		if Dates.day_diff(today_iso, last) > threshold_days:
			out.append(area)
	return out


# ------------------------------------------------------------------ internals

## `entry.focus` when it carries user areas, else the plan/session lookup, else `[]`.
static func _areas_for(entry: Dictionary, plans_by_id: Dictionary) -> PackedStringArray:
	var direct := _user_areas(entry.get("focus", []))
	if not direct.is_empty():
		return direct
	var plan_variant: Variant = plans_by_id.get(String(entry.get("plan_id", "")), {})
	if not (plan_variant is Dictionary):
		return PackedStringArray()
	var session := _session_by_id(plan_variant, String(entry.get("session_id", "")))
	if session.is_empty():
		return PackedStringArray()
	return _user_areas(session.get("focus", []))


## The session with [param session_id] inside a raw plan document (`{}` when absent). PRD-09's
## `PlanSchedule` has no raw-dict session lookup — `PlanModel.session_by_id()` works on a parsed
## `Plan` — so the two-line scan lives here rather than inventing a second schedule model.
static func _session_by_id(plan: Dictionary, session_id: String) -> Dictionary:
	if session_id.is_empty():
		return {}
	var raw: Variant = plan.get("sessions", [])
	if not (raw is Array):
		return {}
	for value in raw:
		if value is Dictionary and String(value.get("id", "")) == session_id:
			return value
	return {}


## User-area keys in [param raw], de-duplicated and in first-seen order; `mobility` and anything
## unknown are not user areas and are ignored (§6.1).
static func _user_areas(raw: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	var values: Array = raw if raw is Array else []
	for value in values:
		var area := String(value)
		if Taxonomy.is_user_area(area) and not out.has(area):
			out.append(area)
	return out


## One session for one area, with the newest date winning. The dictionaries inside the tally are
## shared by reference, which is what makes this in-place update visible to the caller.
static func _bump(slot: Dictionary, date: String) -> void:
	slot["sessions"] = int(slot.get("sessions", 0)) + 1
	if date > String(slot.get("last_date", "")):
		slot["last_date"] = date
