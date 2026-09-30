extends TestSuite
## PRD-11 R13 — the Tracker screen instantiated headless into a 1080×1920 `SubViewport`.
##
## This is the suite that makes "42 cells, forever" a fact rather than a promise: it counts the
## nodes, checks the cell minimums, drives the ring from a seeded store, walks all three empty
## states, exercises the month-bounds and swipe rules, and — the R12 invariant — asserts that a
## refresh instantiates **zero** nodes.
##
## Seeding works the way PRD-03's own suite does: point the `Store` autoload at a fresh
## directory under `res://.test_tmp/` (ADR-04) and load it, so nothing here touches the
## developer's real data. Because the screen reads `Store` on every `_refresh()`, one instance
## can be re-seeded between test groups.

const TMP_ROOT := "res://.test_tmp/"
const TMP_DIR := "res://.test_tmp/tracker_screen/"
const PLAN_ID := "plan-1757941200"

const SCREEN_PATH := "res://scenes/ui/tracker_tab.tscn"
const DETAIL_PATH := "res://scenes/ui/tracker_day_detail.tscn"

var _tree: SceneTree = null
var _viewport: SubViewport = null
var _screen: Control = null


func _init() -> void:
	suite_name = "tracker_screen"


func run() -> void:
	_tree = Engine.get_main_loop() as SceneTree
	if _tree == null:
		_fail("no SceneTree — the suite cannot run")
		return

	_seed_structure()
	_open_screen()
	_test_structure()
	_test_ring_one_of_four()
	_test_calendar_kinds()
	_test_rich_seed()
	_test_node_count_stable()
	_test_month_navigation()
	_test_empty_states()
	_test_risk_rule()
	_test_day_detail()
	_teardown()


# ------------------------------------------------------------------ R2/R13: structure

func _test_structure() -> void:
	begin("the calendar holds exactly 42 cells, each 128×128")
	var grid := _screen.get_node(^"Gutter/Layout/Scroll/Column/CalendarCard/CardBody/CalendarGrid") as GridContainer
	assert_eq(_screen.call(&"cell_count"), 42, "42 cells")
	assert_eq(grid.get_child_count(), 42, "42 children in the grid")
	for child in grid.get_children():
		var cell := child as Control
		assert_eq(cell.custom_minimum_size, Vector2(128, 128), "cell minimum size")
		assert_eq(cell.mouse_filter, Control.MOUSE_FILTER_STOP, "cells take taps")

	begin("the recent list and the area list are pooled, not rebuilt")
	var recent := _screen.get_node(^"Gutter/Layout/Scroll/Column/RecentCard/CardBody/RecentList") as VBoxContainer
	var areas := _screen.get_node(^"Gutter/Layout/Scroll/Column/AreaCard/CardBody/AreaList") as VBoxContainer
	assert_eq(_screen.call(&"recent_row_count"), 10, "10 pooled rows")
	assert_eq(recent.get_child_count(), 10, "10 children")
	assert_eq(_screen.call(&"area_row_count"), 7, "7 area bars")
	assert_eq(areas.get_child_count(), 7, "7 children")
	var order := PackedStringArray()
	for child in areas.get_children():
		order.append(String(child.get_meta(&"area")))
	assert_eq(order, Taxonomy.USER_AREAS, "areas are in §6.1 order")

	begin("the ring is PRD-09's weekly_ring component (AC5)")
	var ring := _screen.get_node(^"Gutter/Layout/Scroll/Column/RingTile") as Control
	assert_eq(ring.scene_file_path, "res://scenes/components/weekly_ring.tscn",
		"RingTile instances weekly_ring.tscn")


# ------------------------------------------------------------------ AC6: 1 of 4

func _test_ring_one_of_four() -> void:
	begin("a one-of-four week reads 1/4 and logs completed=1 goal=4")
	var state := _screen.call(&"debug_state") as Dictionary
	assert_eq(int(state.get("completed", -1)), 1, "one completed day this week")
	assert_eq(int(state.get("target", -1)), 4, "the plan's four days are the goal")
	assert_eq(int(state.get("streak", -1)), 1, "a session today is a streak of one")
	assert_eq(int(state.get("best", -1)), 1, "and the best is one")
	var ring := _screen.get_node(^"Gutter/Layout/Scroll/Column/RingTile") as Control
	assert_eq(String(ring.call(&"value_text")), "1/4", "the ring's value text (AC6)")
	assert_eq(int(ring.call(&"completed_days")), 1, "ring numerator")
	assert_eq(int(ring.call(&"target_days")), 4, "ring denominator")

	begin("the streak tile shows the same number as the ring's week")
	var value := _screen.get_node(^"Gutter/Layout/Scroll/Column/StatsRow/StreakTile/Stack/ValueLabel") as Label
	var title := _screen.get_node(^"Gutter/Layout/Scroll/Column/StatsRow/StreakTile/Stack/TitleLabel") as Label
	assert_eq(value.text, "1", "DAY STREAK value")
	assert_eq(title.text, "DAY STREAK", "DAY STREAK title")

	begin("today's calendar cell is marked done (AC6/PRD-14 step 28)")
	assert_eq(_screen.call(&"kind_for", Dates.today_iso()), "done", "today is done")

	begin("the recent list shows the one session and hides the rest")
	var recent := _screen.get_node(^"Gutter/Layout/Scroll/Column/RecentCard/CardBody/RecentList") as VBoxContainer
	var visible_rows := 0
	for child in recent.get_children():
		if (child as Control).visible:
			visible_rows += 1
	assert_eq(visible_rows, 1, "one visible row")
	var row_title := recent.get_child(0).get_node(^"Row/Texts/TitleLabel") as Label
	assert_eq(row_title.text, "Upper A", "the row names the session")


# ------------------------------------------------------------------ R6: kinds

func _test_calendar_kinds() -> void:
	begin("every in-month date resolves to a kind, and today is done")
	var month := _screen.call(&"calendar_month") as Array
	var year := int(month[0])
	var to_month := int(month[1])
	var today := Dates.today_iso()
	var counts := {"done": 0, "missed": 0, "upcoming": 0, "rest": 0, "today": 0}
	for iso in MonthGrid.cells(year, to_month):
		if not MonthGrid.contains(year, to_month, iso):
			continue
		var kind := String(_screen.call(&"kind_for", iso))
		assert_true(kind != "", "%s has a kind" % iso)
		counts[kind] = int(counts.get(kind, 0)) + 1
		if iso == today:
			assert_eq(kind, "done", "today is done because the seed completed it")

	# Which kinds must exist is a function of the calendar, not of the clock: a planned weekday
	# before today must be missed, one after it upcoming, and a 28+ day month always has rest days.
	var today_day := int(today.substr(8, 2))
	var expect_missed := false
	var expect_upcoming := false
	for day in range(1, today_day):
		if PlanSchedule.is_training_day("%04d-%02d-%02d" % [year, to_month, day], 4):
			expect_missed = true
			break
	for day in range(today_day + 1, MonthGrid.days_in_month(year, to_month) + 1):
		if PlanSchedule.is_training_day("%04d-%02d-%02d" % [year, to_month, day], 4):
			expect_upcoming = true
			break
	if expect_missed:
		assert_gt(float(counts["missed"]), 0.0, "earlier planned days this month are missed")
	if expect_upcoming:
		assert_gt(float(counts["upcoming"]), 0.0, "later planned days are upcoming")
	assert_gt(float(counts["rest"]), 0.0, "rest days exist in every month")

	begin("a completed day is never missed, even off-plan")
	var off_day := _off_plan_day(today)
	if not off_day.is_empty():
		_seed_plan(PLAN_ID, {"entries": [_entry(off_day, "s1", ["chest"], true, PLAN_ID, "Extra")]})
		_screen.call(&"_refresh")
		assert_eq(String(_screen.call(&"kind_for", off_day)), "done",
			"a rest day with a completed session is a win, not a miss")
	else:
		assert_true(true, "no off-plan day before today in this month — boundary not reachable")


# ------------------------------------------------------------------ R9: rich data

func _test_rich_seed() -> void:
	begin("a chest/back week makes shoulders and core Neglected (AC9)")
	var today := Dates.today_iso()
	_seed_plan(PLAN_ID, {
		"entries": [
			_entry(today, "s1", ["chest", "back"], true, PLAN_ID, "Upper A"),
			_entry(Dates.add_days(today, -3), "s3", ["chest"], true, PLAN_ID, "Full Body"),
			_entry(Dates.add_days(today, -20), "s4", ["back"], true, PLAN_ID, "Upper B"),
			_entry(Dates.add_days(today, -70), "s1", [], true, "plan-gone", "Old session"),
		],
	})
	_screen.call(&"_refresh")
	var state := _screen.call(&"debug_state") as Dictionary
	var neglected := state.get("neglected", []) as Array
	assert_true(neglected.has("shoulders"), "shoulders never trained in the plan")
	assert_true(neglected.has("core"), "core never trained in the plan")
	assert_false(neglected.has("chest"), "chest was trained")
	assert_false(neglected.has("back"), "back was trained")
	assert_false(neglected.has("legs"), "legs is not in the plan, so never reported")

	begin("the area rows carry the Neglected marker and the count")
	var areas := _screen.get_node(^"Gutter/Layout/Scroll/Column/AreaCard/CardBody/AreaList") as VBoxContainer
	var shoulders := areas.get_child(Taxonomy.USER_AREAS.find("shoulders"))
	assert_true(bool(shoulders.call(&"is_neglected")), "shoulders row is neglected")
	var recency := shoulders.get_node(^"RecencyLabel") as Label
	assert_true(recency.text.ends_with(" · Neglected"), "the literal marker: %s" % recency.text)
	var chest := areas.get_child(Taxonomy.USER_AREAS.find("chest"))
	assert_false(bool(chest.call(&"is_neglected")), "chest is not neglected")

	begin("the unattributed footnote counts the deleted-plan session (AC9)")
	var footnote := _screen.get_node(^"Gutter/Layout/Scroll/Column/AreaCard/CardBody/AreaFootnote") as Label
	assert_true(footnote.visible, "the footnote is visible")
	assert_true(footnote.text.contains("1 older sessions"), footnote.text)

	begin("a partial entry is listed with the partial mark (R8)")
	_seed_plan(PLAN_ID, {
		"entries": [
			_entry(Dates.today_iso(), "s1", ["chest"], true, PLAN_ID, "Upper A"),
			_entry(Dates.add_days(Dates.today_iso(), -2), "s2", ["back"], false, PLAN_ID, "Lower A"),
		],
	})
	_screen.call(&"_refresh")
	var recent := _screen.get_node(^"Gutter/Layout/Scroll/Column/RecentCard/CardBody/RecentList") as VBoxContainer
	assert_false(bool(recent.get_child(0).call(&"is_partial")), "newest row is the complete session")
	assert_true(bool(recent.get_child(1).call(&"is_partial")), "the older row is the partial session")


# ------------------------------------------------------------------ R12: zero churn

func _test_node_count_stable() -> void:
	begin("a refresh instantiates zero nodes and a month change none either")
	var before := _count_nodes(_screen)
	_screen.call(&"_refresh")
	assert_eq(_count_nodes(_screen), before, "refresh adds no nodes")
	before = _count_nodes(_screen)
	_screen.call(&"apply_swipe", -80.0, 4.0)
	assert_eq(_count_nodes(_screen), before, "a month swipe adds no nodes")
	_park_current_month()


# ------------------------------------------------------------------ R11: navigation

func _test_month_navigation() -> void:
	begin("month bounds follow the earliest entry")
	# The rich seed above was replaced; seed one old entry so Prev has somewhere to go.
	var today := Dates.today_iso()
	_seed_plan(PLAN_ID, {
		"entries": [
			_entry(today, "s1", ["chest"], true, PLAN_ID, "Upper A"),
			_entry(Dates.add_days(today, -70), "s1", ["chest"], true, PLAN_ID, "Old"),
		],
	})
	_screen.call(&"_refresh")
	_park_current_month()
	var prev := _screen.get_node(^"Gutter/Layout/MonthRow/PrevMonthButton") as Button
	var next := _screen.get_node(^"Gutter/Layout/MonthRow/NextMonthButton") as Button
	assert_false(prev.disabled, "history exists in an earlier month, so Prev is live")
	assert_true(next.disabled, "never past the current month")
	assert_eq(next.focus_mode, Control.FOCUS_NONE, "a disabled button leaves the focus ring")

	begin("a swipe turns the page, a weak or diagonal drag does not")
	var before := _month_index(_screen.call(&"calendar_month") as Array)
	assert_false(bool(_screen.call(&"apply_swipe", 30.0, 4.0)), "30 px is not a swipe")
	assert_false(bool(_screen.call(&"apply_swipe", 80.0, 60.0)), "a diagonal drag is not a swipe")
	assert_eq(_month_index(_screen.call(&"calendar_month") as Array), before,
		"neither attempt changed the month")
	assert_true(bool(_screen.call(&"apply_swipe", 80.0, 4.0)), "80 px is a swipe")
	assert_eq(_month_index(_screen.call(&"calendar_month") as Array), before - 1,
		"swiping right goes back a month")

	begin("the earliest history month is the floor and the current month the ceiling")
	var earliest := MonthGrid.month_of(Dates.add_days(today, -70))
	var expected_back := _current_month_index() - _month_index(earliest)
	var back_steps := 1  # the successful swipe above already stepped back one month
	var guard := 0
	while bool(_screen.call(&"apply_swipe", 80.0, 4.0)) and guard < 8:
		back_steps += 1
		guard += 1
	assert_eq(back_steps, expected_back, "the floor is the month of the oldest entry")
	assert_true(prev.disabled, "Prev is disabled at the floor")
	assert_false(bool(_screen.call(&"apply_swipe", 80.0, 4.0)), "and the swipe refuses to pass it")
	var forward_steps := 0
	guard = 0
	while bool(_screen.call(&"apply_swipe", -80.0, 4.0)) and guard < 8:
		forward_steps += 1
		guard += 1
	assert_eq(forward_steps, back_steps, "the same distance back to today")
	assert_true(next.disabled, "Next is disabled at the current month")
	assert_false(bool(_screen.call(&"apply_swipe", -80.0, 4.0)), "and refuses to pass it")


# ------------------------------------------------------------------ R10: empty states

func _test_empty_states() -> void:
	begin("case 1 — no plan, no history: exact copy, cards hidden")
	_seed_plan("", {})
	_screen.call(&"_refresh")
	var empty := _screen.get_node(^"Gutter/Layout/EmptyState")
	var title := empty.get_node(^"Title") as Label
	var body := empty.get_node(^"Body") as Label
	var action := empty.get_node(^"Action") as Button
	assert_true(empty.visible, "the empty state shows")
	assert_eq(title.text, "No workouts yet", "title")
	assert_eq(body.text, "Generate a plan and MicroWorkout will walk you through it, exercise by exercise.",
		"body")
	assert_eq(action.text, "Create a plan", "action")
	assert_false(_screen.get_node(^"Gutter/Layout/MonthRow").visible, "the calendar hides")
	assert_false(_screen.get_node(^"Gutter/Layout/Scroll/Column/CalendarCard").visible, "cards hide")

	begin("case 2 — plan, no history: exact copy, calendar hidden")
	_seed_plan(PLAN_ID, {})
	_screen.call(&"_refresh")
	title = empty.get_node(^"Title") as Label
	body = empty.get_node(^"Body") as Label
	action = empty.get_node(^"Action") as Button
	assert_true(empty.visible, "the empty state shows")
	assert_eq(title.text, "Your plan is ready", "title")
	assert_eq(body.text, "Nothing logged yet. Today's session is waiting on the Home tab.", "body")
	assert_eq(action.text, "Go to Home", "action")
	assert_false(_screen.get_node(^"Gutter/Layout/MonthRow").visible, "still no calendar")

	begin("case 3 — history, no plan: additive, banner inside the calendar")
	_seed_plan("", {
		"entries": [_entry(Dates.today_iso(), "s1", ["chest"], true, "plan-gone", "Old session")],
	})
	_screen.call(&"_refresh")
	title = empty.get_node(^"Title") as Label
	body = empty.get_node(^"Body") as Label
	action = empty.get_node(^"Action") as Button
	assert_true(empty.visible, "the empty state shows")
	assert_eq(title.text, "No active plan", "title")
	assert_eq(body.text, "Your past workouts are still here. Generate a new plan to start a fresh week.",
		"body")
	assert_eq(action.text, "New plan", "action")
	assert_true(_screen.get_node(^"Gutter/Layout/Scroll/Column/CalendarCard").visible,
		"the history stays visible")
	assert_true(_screen.get_node(^"Gutter/Layout/Scroll/Column/AreaCard").visible, "area card stays")
	var banner := _screen.get_node(^"Gutter/Layout/Scroll/Column/CalendarCard/CardBody/NoPlanBanner") as PanelContainer
	assert_true(banner.visible, "the banner shows")
	var banner_label := banner.get_node(^"NoPlanLabel") as Label
	assert_eq(banner_label.text, "No active plan — missed days can't be shown.", "banner copy")
	var state := _screen.call(&"debug_state") as Dictionary
	assert_eq(int(state.get("target", -1)), 4, "the settings goal is the fallback denominator")


# ------------------------------------------------------------------ R5: at-risk chip

func _test_risk_rule() -> void:
	begin("the at-risk chip needs a streak, no session today and 20:00")
	assert_true(bool(_screen.call(&"_risk_should_show", 3, false, 20)), "all three conditions")
	assert_true(bool(_screen.call(&"_risk_should_show", 3, false, 23)), "late evening")
	assert_false(bool(_screen.call(&"_risk_should_show", 0, false, 21)), "no streak, no warning")
	assert_false(bool(_screen.call(&"_risk_should_show", 3, true, 21)), "today is logged")
	assert_false(bool(_screen.call(&"_risk_should_show", 3, false, 19)), "before 20:00")

	begin("the grace rule survives on screen: yesterday done, today open")
	var today := Dates.today_iso()
	_seed_plan(PLAN_ID, {
		"entries": [
			_entry(Dates.add_days(today, -1), "s1", ["chest"], true, PLAN_ID, "Upper A"),
			_entry(Dates.add_days(today, -2), "s2", ["back"], true, PLAN_ID, "Lower A"),
		],
	})
	_screen.call(&"_refresh")
	var streak := int((_screen.call(&"debug_state") as Dictionary).get("streak", 0))
	assert_eq(streak, 2, "today not being logged yet does not break yesterday's streak")


# ------------------------------------------------------------------ R7: day detail

func _test_day_detail() -> void:
	var today := Dates.today_iso()
	begin("the day detail shows the summary, the counts and the prescribed blocks")
	var entry := _entry(today, "s1", ["chest", "back"], true, PLAN_ID, "Upper A")
	_seed_plan(PLAN_ID, {"entries": [entry]})
	_screen.call(&"_refresh")

	var detail := _open_detail({"date": today, "entry_id": String(entry.get("id", ""))})
	if detail == null:
		return
	var column := "SafeArea/Layout/Scroller/Column/"
	assert_eq((detail.get_node(column + "TitleLabel") as Label).text, "Upper A", "title")
	var meta := (detail.get_node(column + "MetaLabel") as Label).text
	assert_true(meta.contains("6 of 6 exercises"), meta)
	assert_true(meta.contains("11 of 11 sets"), meta)
	assert_eq((detail.get_node(column + "StatusChip") as Button).text, "Completed", "chip")
	var list := detail.get_node(column + "ExerciseList") as VBoxContainer
	assert_eq(list.get_child_count(), 6, "one row per prescribed block")
	var first_name := list.get_child(0).get_child(0) as Label
	assert_eq(first_name.text, Library.name_of("bench-press"), "the block's exercise name")
	assert_false((detail.get_node(column + "MissingLabel") as Label).visible, "nothing missing")
	_free_detail(detail)

	begin("a deleted plan still lists the entry's exercises by id (R29/R7)")
	var gone := _entry(today, "s99", [], true, "plan-gone", "Lost plan")
	gone["exercise_ids"] = ["bench-press", "barbell-row"]
	gone["completed_at"] = Dates.now_iso8601()
	_seed_plan(PLAN_ID, {"entries": [gone]})
	_screen.call(&"_refresh")
	detail = _open_detail({"date": today, "entry_id": String(gone.get("id", ""))})
	if detail == null:
		return
	list = detail.get_node(column + "ExerciseList") as VBoxContainer
	assert_eq(list.get_child_count(), 2, "the ids still name the exercises")
	var missing := detail.get_node(column + "MissingLabel") as Label
	assert_true(missing.visible, "the copy explains what is gone")
	assert_true(missing.text.contains("session log"), missing.text)
	_free_detail(detail)

	begin("an entry with neither plan nor exercise_ids says so instead of inventing one")
	var bare := _entry(today, "s99", [], true, "plan-gone", "Lost plan")
	_seed_plan(PLAN_ID, {"entries": [bare]})
	_screen.call(&"_refresh")
	detail = _open_detail({"date": today, "entry_id": String(bare.get("id", ""))})
	if detail == null:
		return
	assert_false((detail.get_node(column + "ExerciseList") as VBoxContainer).visible,
		"the list hides")
	assert_eq((detail.get_node(column + "MissingLabel") as Label).text,
		"The plan this session came from is no longer on this device. Only the summary is available.",
		"R7's exact copy")
	_free_detail(detail)


# ------------------------------------------------------------------ harness

## Points the Store autoload at a fresh temp dir and seeds [param plan] — plus entries when the
## plan is real. `plan_id == ""` seeds history only (the "no active plan" state).
func _seed_plan(plan_id: String, data: Dictionary) -> void:
	var dir := _fresh(TMP_DIR)
	Store.set_io_root_for_tests(dir)
	Store.load_all()
	if not plan_id.is_empty():
		var plan := _plan_fixture(plan_id)
		Store.upsert_plan(plan)
		Store.set_active_plan(plan_id)
	var entries: Array = data.get("entries", [])
	for entry in entries:
		Store.add_entry(entry)


func _seed_structure() -> void:
	# One completed session today: the AC6 shape (1 of 4).
	_seed_plan(PLAN_ID, {
		"entries": [_entry(Dates.today_iso(), "s1", ["chest", "back"], true, PLAN_ID, "Upper A")],
	})


func _open_screen() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1080, 1920)
	_viewport.disable_3d = true
	_tree.root.add_child(_viewport)
	_screen = (load(SCREEN_PATH) as PackedScene).instantiate() as Control
	_viewport.add_child(_screen)


func _open_detail(args: Dictionary) -> Control:
	var packed := load(DETAIL_PATH) as PackedScene
	if packed == null:
		_fail("the day detail scene did not load")
		return null
	var detail := packed.instantiate() as Control
	_viewport.add_child(detail)
	detail.call(&"setup", args)
	return detail


func _free_detail(detail: Control) -> void:
	_viewport.remove_child(detail)
	detail.free()


func _teardown() -> void:
	if _viewport != null:
		_tree.root.remove_child(_viewport)
		_viewport.free()
		_viewport = null
		_screen = null


func _count_nodes(node: Node) -> int:
	var total := 0
	for child in node.get_children():
		total += 1 + _count_nodes(child)
	return total


func _current_month_index() -> int:
	var parts := MonthGrid.month_of(Dates.today_iso())
	return int(parts[0]) * 12 + int(parts[1])


func _month_index(month: Array) -> int:
	if month.size() < 2:
		return 0
	return int(month[0]) * 12 + int(month[1])


## Sets the displayed page back to the current month, whatever earlier tests left behind.
func _park_current_month() -> void:
	var month := _screen.call(&"calendar_month") as Array
	while int(month[0]) * 12 + int(month[1]) < _current_month_index():
		_screen.call(&"_on_next_month")
		month = _screen.call(&"calendar_month") as Array


## The most recent date before [param today] that this 4-day plan does not train, or `""` when
## this month has no such day (a month that just started).
func _off_plan_day(today: String) -> String:
	var month := today.substr(0, 7)
	for back in range(1, 32):
		var candidate := Dates.add_days(today, -back)
		if candidate.substr(0, 7) != month:
			return ""
		if not PlanSchedule.is_training_day(candidate, 4):
			return candidate
	return ""


## Wipes [param dir_path] and recreates it with the `.gdignore` that keeps the importer out.
func _fresh(dir_path: String) -> String:
	_remove_tree(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)
	var ignore := FileAccess.open(TMP_ROOT + ".gdignore", FileAccess.WRITE)
	if ignore != null:
		ignore.close()
	return dir_path


func _remove_tree(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			_remove_tree(dir_path + name + "/")
		else:
			DirAccess.remove_absolute(dir_path + name)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(dir_path)


# ------------------------------------------------------------------ fixtures

## A complete 4-day plan anchored eight weeks back, so every day of the current month projects.
## Sessions carry real library ids so the day detail (and later PRD-14 runs) show real names.
func _plan_fixture(plan_id: String) -> Dictionary:
	var created := Dates.add_days(Dates.today_iso(), -56)
	var blocks_a := [
		{"exercise_id": "bench-press", "sets": 3, "reps": "8-10", "rest_seconds": 90},
		{"exercise_id": "barbell-row", "sets": 3, "reps": "8-10", "rest_seconds": 90},
		{"exercise_id": "overhead-press", "sets": 2, "reps": "8-10", "rest_seconds": 75},
		{"exercise_id": "plank", "sets": 1, "reps": "45s", "rest_seconds": 30},
		{"exercise_id": "squat", "sets": 1, "reps": "8-10", "rest_seconds": 120},
		{"exercise_id": "romanian-deadlift", "sets": 1, "reps": "8-10", "rest_seconds": 120},
	]
	var sessions: Array = [
		_session("s1", 0, "Upper A", ["chest", "back"], blocks_a),
		_session("s2", 1, "Lower A", ["legs"], [
			{"exercise_id": "squat", "sets": 3, "reps": "8-10", "rest_seconds": 120},
			{"exercise_id": "romanian-deadlift", "sets": 3, "reps": "8-10", "rest_seconds": 120},
		]),
		_session("s3", 2, "Upper B", ["chest", "shoulders"], [
			{"exercise_id": "overhead-press", "sets": 3, "reps": "8-10", "rest_seconds": 90},
		]),
		_session("s4", 3, "Lower B", ["back", "core"], [
			{"exercise_id": "barbell-row", "sets": 3, "reps": "8-10", "rest_seconds": 90},
		]),
	]
	return {
		"id": plan_id,
		"name": "Upper / Lower",
		"created_at": created + "T10:00:00Z",
		"source": "builtin",
		"provider": "",
		"goal": "hypertrophy",
		"days_per_week": 4,
		"duration_min": 40,
		"areas": ["chest", "back", "shoulders", "core"],
		"equipment": ["barbell", "dumbbell", "bodyweight"],
		"notes": "",
		"split_name": "Upper / Lower",
		"sessions": sessions,
	}


func _session(session_id: String, index: int, title: String, focus: Array,
		blocks: Array) -> Dictionary:
	return {
		"id": session_id,
		"index": index,
		"title": title,
		"focus": focus,
		"est_minutes": 40,
		"warmup": [],
		"blocks": blocks,
		"cooldown": [],
	}


## A history entry. `focus` stays absent for "older" entries that predate the additive field.
func _entry(date: String, session_id: String, focus: Array, completed: bool,
		plan_id: String, title: String) -> Dictionary:
	var record := {
		"id": "h-%s-%s" % [date.replace("-", ""), session_id],
		"plan_id": plan_id,
		"session_id": session_id,
		"session_title": title,
		"date": date,
		"started_at": date + "T18:00:00Z",
		"completed_at": date + "T19:00:00Z",
		"duration_sec": 1830,
		"exercises_completed": 6 if completed else 3,
		"exercises_total": 6,
		"sets_completed": 11 if completed else 5,
		"sets_total": 11,
		"completed": completed,
	}
	if not focus.is_empty():
		record["focus"] = focus
	return record
