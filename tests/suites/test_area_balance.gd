extends TestSuite
## PRD-11 R9/R13 — [AreaBalance]: which areas a completed session counts for, when an entry
## cannot be attributed, and which planned areas read `Neglected`.
##
## The screen renders this dictionary; it never recomputes it. So the boundaries that matter —
## the 84-day window edge, the 14-day neglect edge, the plan-area filter — are pinned here.

## A Tuesday; the suite's "today". 84 days earlier is 2026-07-07, 85 days earlier is 2026-07-06.
const TODAY := "2026-09-29"

const PLAN_ID := "plan-1757941200"


func _init() -> void:
	suite_name = "area_balance"


func run() -> void:
	_test_tally_attribution()
	_test_tally_window_and_filters()
	_test_unattributed()
	_test_neglected()
	_test_empty_input()


# ------------------------------------------------------------------ attribution (R9/R30)

func _test_tally_attribution() -> void:
	begin("a two-area session increments both areas once")
	var entries: Array[Dictionary] = [
		_entry(TODAY, PLAN_ID, "s1"),
	]
	var tally := AreaBalance.tally(entries, _plans(), TODAY)
	assert_eq(int((tally["chest"] as Dictionary)["sessions"]), 1, "chest counted")
	assert_eq(int((tally["arms"] as Dictionary)["sessions"]), 1, "arms counted")
	assert_eq(int((tally["legs"] as Dictionary)["sessions"]), 0, "legs untouched")
	assert_eq(String((tally["chest"] as Dictionary)["last_date"]), TODAY, "last date recorded")
	assert_eq(int((tally["chest"] as Dictionary)["days_since"]), 0, "today is zero days ago")

	begin("entry.focus wins over the plan lookup (R30)")
	var direct: Array[Dictionary] = [
		_entry(TODAY, PLAN_ID, "s1", ["legs"]),
	]
	var direct_tally := AreaBalance.tally(direct, _plans(), TODAY)
	assert_eq(int((direct_tally["legs"] as Dictionary)["sessions"]), 1,
		"the copied focus is authoritative")
	assert_eq(int((direct_tally["chest"] as Dictionary)["sessions"]), 0,
		"the plan's focus is not consulted when the entry carries one")

	begin("two sessions on different days collapse into one area count of two")
	var two: Array[Dictionary] = [
		_entry("2026-09-22", PLAN_ID, "s1"),
		_entry(TODAY, PLAN_ID, "s1"),
	]
	var two_tally := AreaBalance.tally(two, _plans(), TODAY)
	assert_eq(int((two_tally["chest"] as Dictionary)["sessions"]), 2, "two chest sessions")
	assert_eq(String((two_tally["chest"] as Dictionary)["last_date"]), TODAY, "newest date wins")
	assert_eq(int((two_tally["chest"] as Dictionary)["days_since"]), 0,
		"the newest session was today, whatever the older one was")

	begin("an unknown focus area is ignored, not invented as a key")
	var unknown: Array[Dictionary] = [
		_entry(TODAY, PLAN_ID, "s1", ["mobility", "cardio"]),
	]
	var unknown_tally := AreaBalance.tally(unknown, _plans(), TODAY)
	assert_eq(int((unknown_tally["cardio"] as Dictionary)["sessions"]), 1,
		"cardio is a user area and counts")
	assert_false(unknown_tally.has("mobility"), "mobility is reserved, never a tally key")
	assert_eq(unknown_tally.size(), 8, "seven areas + _unattributed, never more")


func _test_tally_window_and_filters() -> void:
	begin("the 84-day window includes its boundary day and excludes the 85th")
	var entries: Array[Dictionary] = [
		_entry("2026-07-07", PLAN_ID, "s1"),   # exactly 84 days old
		_entry("2026-07-06", PLAN_ID, "s2"),   # 85 days old
	]
	assert_eq(Dates.day_diff(TODAY, "2026-07-07"), 84, "fixture sanity: the boundary day")
	assert_eq(Dates.day_diff(TODAY, "2026-07-06"), 85, "fixture sanity: one day past it")
	var tally := AreaBalance.tally(entries, _plans(), TODAY)
	assert_eq(int((tally["chest"] as Dictionary)["sessions"]), 1, "84 days old counts")
	assert_eq(int((tally["legs"] as Dictionary)["sessions"]), 0, "85 days old does not")

	begin("partial entries and future entries are ignored")
	var ignored: Array[Dictionary] = [
		_entry(TODAY, PLAN_ID, "s1", [], false),
		_entry("2026-10-05", PLAN_ID, "s1"),
	]
	var ignored_tally := AreaBalance.tally(ignored, _plans(), TODAY)
	assert_eq(int((ignored_tally["chest"] as Dictionary)["sessions"]), 0,
		"a partial session is not a trained area")
	assert_eq(int((ignored_tally[AreaBalance.UNATTRIBUTED] as Dictionary)["sessions"]), 0,
		"and it is not unattributed either")

	begin("a malformed date is skipped without breaking the rest")
	var malformed: Array[Dictionary] = [
		_entry("2026-02-30", PLAN_ID, "s1"),
		_entry(TODAY, PLAN_ID, "s1"),
	]
	var malformed_tally := AreaBalance.tally(malformed, _plans(), TODAY)
	assert_eq(int((malformed_tally["chest"] as Dictionary)["sessions"]), 1,
		"only the real date counted")


func _test_unattributed() -> void:
	begin("a deleted plan lands in _unattributed, never silently dropped")
	var entries: Array[Dictionary] = [
		_entry(TODAY, "plan-gone", "s1", []),
	]
	var tally := AreaBalance.tally(entries, _plans(), TODAY)
	var unattributed: Dictionary = tally[AreaBalance.UNATTRIBUTED]
	assert_eq(int(unattributed["sessions"]), 1, "counted")
	assert_eq(String(unattributed["last_date"]), TODAY, "its date is kept")
	assert_eq(int(unattributed["days_since"]), 0, "so is its recency")
	assert_eq(int((tally["chest"] as Dictionary)["sessions"]), 0, "no invented attribution")

	begin("a session id missing from an existing plan is unattributed")
	var missing_session: Array[Dictionary] = [
		_entry(TODAY, PLAN_ID, "s99", []),
	]
	var missing_tally := AreaBalance.tally(missing_session, _plans(), TODAY)
	assert_eq(int((missing_tally[AreaBalance.UNATTRIBUTED] as Dictionary)["sessions"]), 1,
		"unattributed")

	begin("a plan that resolves but has no user areas is unattributed")
	var empty_focus: Array[Dictionary] = [
		_entry(TODAY, PLAN_ID, "s4", []),
	]
	var empty_tally := AreaBalance.tally(empty_focus, _plans(), TODAY)
	assert_eq(int((empty_tally[AreaBalance.UNATTRIBUTED] as Dictionary)["sessions"]), 1,
		"no area resolved anywhere")


# ------------------------------------------------------------------ neglected (R9)

func _test_neglected() -> void:
	var all_areas := Taxonomy.USER_AREAS

	begin("days_since == 14 is not neglected; 15 is")
	var fresh: Array[Dictionary] = [_entry("2026-09-15", PLAN_ID, "s1")]  # 14 days before TODAY
	var stale: Array[Dictionary] = [_entry("2026-09-14", PLAN_ID, "s1")]  # 15 days before TODAY
	assert_eq(Dates.day_diff(TODAY, "2026-09-15"), 14, "fixture sanity: the boundary")
	var fresh_tally := AreaBalance.tally(fresh, _plans(), TODAY)
	var stale_tally := AreaBalance.tally(stale, _plans(), TODAY)
	assert_false(AreaBalance.neglected(fresh_tally, all_areas, TODAY).has("chest"),
		"14 days ago is still fresh")
	assert_false(AreaBalance.neglected(fresh_tally, all_areas, TODAY).has("arms"),
		"arms was trained 14 days ago too")
	assert_true(AreaBalance.neglected(stale_tally, all_areas, TODAY).has("chest"),
		"15 days ago is neglected")
	assert_true(AreaBalance.neglected(stale_tally, all_areas, TODAY).has("arms"),
		"both areas of the session are neglected")

	begin("an area that was never trained is neglected")
	var one := AreaBalance.tally(fresh, _plans(), TODAY)
	var neglected := AreaBalance.neglected(one, all_areas, TODAY)
	assert_true(neglected.has("legs"), "legs never trained")
	assert_true(neglected.has("back"), "back never trained")
	assert_false(neglected.has("chest"), "chest trained")

	begin("only areas the plan trains are ever reported")
	var plan_areas := PackedStringArray(["chest", "legs"])
	var filtered := AreaBalance.neglected(one, plan_areas, TODAY)
	assert_true(filtered.has("legs"), "legs is in the plan and untrained")
	assert_false(filtered.has("cardio"), "cardio is not in the plan — never nagged about")
	assert_false(filtered.has("chest"), "chest is trained")

	begin("an all-zero tally with all seven plan areas returns all seven, in §6.1 order")
	var zero := AreaBalance.tally([] as Array[Dictionary], {}, TODAY)
	var everything := AreaBalance.neglected(zero, all_areas, TODAY)
	assert_eq(everything.size(), 7, "all seven")
	for index in all_areas.size():
		assert_eq(everything[index], all_areas[index], "order follows USER_AREAS")

	begin("an unlisted area in the tally is not returned")
	var stray := {"chest": {"sessions": 0, "last_date": "", "days_since": -1}, "nonsense":
		{"sessions": 0, "last_date": "", "days_since": -1}}
	var stray_result := AreaBalance.neglected(stray, PackedStringArray(["chest", "nonsense"]), TODAY)
	assert_eq(stray_result, PackedStringArray(["chest"]), "only real user areas")


# ------------------------------------------------------------------ empty input (R13)

func _test_empty_input() -> void:
	begin("empty input yields seven zeroed areas plus _unattributed, never NaN")
	var empty: Array[Dictionary] = []
	var tally := AreaBalance.tally(empty, {}, TODAY)
	assert_eq(tally.size(), 8, "seven + unattributed")
	for area in Taxonomy.USER_AREAS:
		var slot: Dictionary = tally[area]
		assert_eq(int(slot["sessions"]), 0, "%s has no sessions" % area)
		assert_eq(String(slot["last_date"]), "", "%s has no last date" % area)
		assert_eq(int(slot["days_since"]), -1, "%s has no days_since" % area)
	assert_eq(int((tally[AreaBalance.UNATTRIBUTED] as Dictionary)["sessions"]), 0,
		"unattributed is zeroed too")

	begin("an invalid today returns the zeroed shape instead of misdating everything")
	var solo: Array[Dictionary] = [_entry(TODAY, PLAN_ID, "s1")]
	var broken := AreaBalance.tally(solo, _plans(), "not-a-date")
	assert_eq(int((broken["chest"] as Dictionary)["sessions"]), 0, "nothing tallied")

# ------------------------------------------------------------------ fixtures

## A completed entry. [param focus] stays empty for "older" entries that predate the additive
## field, which forces the plan/session lookup.
func _entry(date: String, plan_id: String, session_id: String, focus: Array = [],
		completed: bool = true) -> Dictionary:
	var record := {
		"id": "h-%s-%s" % [date, session_id],
		"plan_id": plan_id,
		"session_id": session_id,
		"session_title": "Session",
		"date": date,
		"completed": completed,
	}
	if not focus.is_empty():
		record["focus"] = focus
	return record


## `{plan_id: plan}`: four sessions — s1 chest+arms, s2 back, s3 shoulders, s4 focus left empty
## on purpose (the "resolves but contributes nothing" case).
func _plans() -> Dictionary:
	var focus := {
		"s1": ["chest", "arms"],
		"s2": ["back"],
		"s3": ["shoulders"],
		"s4": [],
	}
	var sessions: Array = []
	var ids := ["s1", "s2", "s3", "s4"]
	for index in ids.size():
		sessions.append({
			"id": ids[index],
			"index": index,
			"title": "Session %d" % (index + 1),
			"focus": focus[ids[index]],
			"est_minutes": 40,
			"warmup": [],
			"blocks": [],
			"cooldown": [],
		})
	return {
		PLAN_ID: {
			"id": PLAN_ID,
			"created_at": "2026-09-14T10:00:00Z",
			"days_per_week": 4,
			"sessions": sessions,
		},
	}
