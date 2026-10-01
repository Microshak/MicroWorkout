extends TestSuite
## The Plan screen instantiated headless into a 1080×1920 `SubViewport`.
##
## Four contracts this suite makes facts rather than promises:
##
## * **It is a real screen, not a placeholder.** The plan's identity, this week's seven pills and
##   one day card per session are all rendered from the store.
## * **The pool is fixed.** Seven day cards are built once in `_ready()`; a refresh instantiates
##   **zero** nodes — the same invariant the Tracker suite asserts.
## * **Reset clears the pointer, never the history.** `reset_plan()` writes `""` to
##   `active_plan_id` and leaves every logged entry in place.
## * **Empty is a state, not an error.** With no active plan the cards hide and the one useful
##   action (start the wizard) shows.
##
## Seeding is PRD-03's pattern: point `Store` at a fresh directory under `res://.test_tmp/`
## (ADR-04), load it, and re-seed between groups — the screen reads the store on every refresh.

const TMP_ROOT := "res://.test_tmp/"
const TMP_DIR := "res://.test_tmp/plan_screen/"
const PLAN_ID := "plan-1757941200"

const SCREEN_PATH := "res://scenes/ui/plan_tab.tscn"

const COLUMN := "Gutter/Layout/Scroll/Column/"
const PLAN_CARD := COLUMN + "PlanCard/CardBody/"
const WEEK_CARD := COLUMN + "WeekCard/CardBody/"
const SESSIONS_CARD := COLUMN + "SessionsCard/CardBody/"

var _tree: SceneTree = null
var _viewport: SubViewport = null
var _screen: Control = null


func _init() -> void:
	suite_name = "plan_screen"


func run() -> void:
	_tree = Engine.get_main_loop() as SceneTree
	if _tree == null:
		_fail("no SceneTree — the suite cannot run")
		return

	_seed_plan(PLAN_ID)
	_open_screen()
	_test_structure()
	_test_current_plan()
	_test_week_card()
	_test_node_count_stable()
	_test_empty_state()
	_test_reset()
	_teardown()


# ------------------------------------------------------------------ structure

func _test_structure() -> void:
	begin("seven day cards are pooled, built once")
	assert_eq(_screen.call(&"day_card_count"), 7, "seven cards")
	var list := _screen.get_node(COLUMN + "SessionsCard/CardBody/DayList") as VBoxContainer
	assert_eq(list.get_child_count(), 7, "seven children in the list")
	for child in list.get_children():
		assert_eq(child.scene_file_path, "res://scenes/components/day_card.tscn",
			"each slot is a day_card")

	begin("the week card is PRD-09's week_strip")
	var strip := _screen.get_node(WEEK_CARD + "WeekStrip") as Control
	assert_eq(strip.scene_file_path, "res://scenes/components/week_strip.tscn",
		"WeekStrip instances week_strip.tscn")
	assert_eq(int(strip.call(&"pill_count")), 7, "seven pills")

	begin("the three cards are theme Cards with their own CardBody (ADR-26)")
	for card_name in ["PlanCard", "WeekCard", "SessionsCard"]:
		var card := _screen.get_node(COLUMN + str(card_name)) as PanelContainer
		assert_eq(card.theme_type_variation, &"Card", "%s is a Card" % card_name)
		assert_true(card.get_node_or_null(^"CardBody") is VBoxContainer,
			"%s owns a CardBody" % card_name)


# ------------------------------------------------------------------ the current plan

func _test_current_plan() -> void:
	begin("the plan card says what the plan is")
	var state := _screen.call(&"debug_state") as Dictionary
	assert_eq(String(state.get("empty_case", "x")), "", "not the empty state")
	assert_eq(String(state.get("name", "")), "Chest & Back ×2 / Legs & Arms / Shoulders & Core",
		"the plan's own name")
	assert_eq(int(state.get("days", 0)), 4, "four days a week")
	assert_eq((_screen.get_node(PLAN_CARD + "MetaLabel") as Label).text,
		"4 days a week · 40 min · Hypertrophy", "the meta row")
	assert_eq((_screen.get_node(PLAN_CARD + "SplitLabel") as Label).text,
		"Chest & Back ×2 / Legs & Arms / Shoulders & Core", "the split")
	assert_eq((_screen.get_node(PLAN_CARD + "AreasLabel") as Label).text,
		"Chest · Back · Shoulders · Arms", "the body areas in plan order")
	assert_true((_screen.get_node(COLUMN + "PlanCard") as Control).visible, "the card shows")

	begin("one day card per session, in order, with the weekday from the plan's pattern")
	var list := _screen.get_node(COLUMN + "SessionsCard/CardBody/DayList") as VBoxContainer
	var visible := 0
	var titles := PackedStringArray()
	for child in list.get_children():
		if not (child as Control).visible:
			continue
		visible += 1
		titles.append(String(child.call(&"session_title")))
	assert_eq(visible, 4, "four visible cards")
	assert_eq(titles, PackedStringArray(["Chest & Back A", "Legs & Arms", "Shoulders & Core",
		"Chest & Back B"]), "the plan's session order")

	var first := list.get_child(0) as Control
	var weekdays := PlanSchedule.weekdays_for(4)
	assert_eq((first.call(&"number_label") as Label).text,
		"Day 1 · %s" % PlanSchedule.weekday_name(int(weekdays[0])), "day number and weekday")
	assert_eq((first.call(&"focus_label") as Label).text, "Chest · Back", "the focus line")
	assert_eq((first.call(&"meta_label") as Label).text, "2 exercises · 40 min",
		"blocks and minutes")

	begin("every visible card reports the tap that opens its preview")
	for child in list.get_children():
		if (child as Control).visible:
			assert_true(child.get_signal_connection_list(&"pressed").size() > 0,
				"the card's pressed signal is wired")


# ------------------------------------------------------------------ this week

func _test_week_card() -> void:
	begin("the strip shows this week's kinds and the shared caption")
	var state := _screen.call(&"debug_state") as Dictionary
	var kinds: Array = state.get("strip", [])
	assert_eq(kinds.size(), 7, "seven pills' worth of kinds")
	assert_eq(_screen.call(&"kind_for", Dates.today_iso()), "done", "today is done")
	assert_eq(String(state.get("caption", "")), "1 of 4 done this week", "the caption")
	assert_eq((_screen.get_node(WEEK_CARD + "WeekCaption") as Label).text,
		HomeState.week_caption(String(state.get("state", "")), _strip_of(state), 4),
		"the label carries HomeState's sentence")

	begin("session kinds come from the same builder the pills use")
	var plan := Store.active_plan()
	var entries := Store.all_entries()
	var today := Dates.today_iso()
	var kinds_by_id := PlanTab.session_kinds(plan, entries, today)
	for session in PlanSchedule.sessions_of(plan):
		var id := String((session as Dictionary).get("id", ""))
		assert_true(["done", "today", "upcoming"].has(String(kinds_by_id.get(id, ""))),
			"session %s has a rendered kind" % id)
		assert_eq(String(_screen.call(&"session_kind", id)), String(kinds_by_id.get(id, "")),
			"the screen agrees with the builder for %s" % id)
	var done_sessions := 0
	for value in kinds_by_id.values():
		if String(value) == "done":
			done_sessions += 1
	assert_eq(done_sessions, 1 if PlanSchedule.is_training_day(today, 4) else 0,
		"the completed session is done when today is one of the plan's days")


# ------------------------------------------------------------------ zero churn

func _test_node_count_stable() -> void:
	begin("a refresh instantiates zero nodes")
	var before := _count_nodes(_screen)
	_screen.call(&"_refresh")
	assert_eq(_count_nodes(_screen), before, "refresh adds no nodes")


# ------------------------------------------------------------------ empty + reset

func _test_empty_state() -> void:
	begin("with no active plan the cards hide and the wizard is offered")
	_seed_plan("")
	_screen.call(&"_refresh")
	var state := _screen.call(&"debug_state") as Dictionary
	assert_eq(String(state.get("empty_case", "")), "no_plan", "the empty case")
	var empty := _screen.get_node(^"Gutter/Layout/EmptyState") as Control
	assert_true(empty.visible, "the empty state shows")
	assert_eq((empty.get_node(^"Title") as Label).text, "No plan yet", "title")
	assert_eq((empty.get_node(^"Body") as Label).text, PlanTab.EMPTY_BODY, "body")
	assert_eq((empty.get_node(^"Action") as Button).text, "Create a plan", "the one action")
	assert_false((_screen.get_node(^"Gutter/Layout/Scroll") as Control).visible,
		"the scroll region hides")
	for child in (_screen.get_node(COLUMN + "SessionsCard/CardBody/DayList") as VBoxContainer).get_children():
		assert_false((child as Control).visible, "no day card is left showing")


func _test_reset() -> void:
	begin("reset clears the pointer and keeps every logged session")
	_seed_plan(PLAN_ID)
	_screen.call(&"_refresh")
	var entries_before := Store.all_entries().size()
	assert_eq(entries_before, 1, "one seeded entry")
	assert_eq(Store.active_plan_id(), PLAN_ID, "the plan is active")
	assert_true(bool(_screen.call(&"reset_plan")), "reset reports success")
	assert_eq(Store.active_plan_id(), "", "the pointer is cleared")
	assert_eq(Store.all_entries().size(), entries_before, "history is untouched")
	assert_false(bool(_screen.call(&"reset_plan")), "a second reset is a no-op")

	begin("the screen follows the store into the empty state")
	_screen.call(&"_refresh")
	assert_eq(String((_screen.call(&"debug_state") as Dictionary).get("empty_case", "")),
		"no_plan", "the view emptied itself")


# ------------------------------------------------------------------ harness

## Points the Store autoload at a fresh temp dir, seeds the plan and — when it is real — the one
## completed session that makes this week "1 of 4". `plan_id == ""` seeds history only.
func _seed_plan(plan_id: String) -> void:
	var dir := _fresh(TMP_DIR)
	Store.set_io_root_for_tests(dir)
	Store.load_all()
	Store.add_entry(_entry(Dates.today_iso()))
	if not plan_id.is_empty():
		Store.upsert_plan(_plan_fixture(plan_id))
		Store.set_active_plan(plan_id)


func _open_screen() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1080, 1920)
	_viewport.disable_3d = true
	_tree.root.add_child(_viewport)
	_screen = (load(SCREEN_PATH) as PackedScene).instantiate() as Control
	_viewport.add_child(_screen)


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


## The strip the screen is showing, rebuilt from its own debug state — the suite never re-derives
## the kinds itself.
func _strip_of(state: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var kinds: Array = state.get("strip", [])
	var dates := PlanSchedule.week_dates(Dates.today_iso())
	for index in kinds.size():
		out.append({
			"weekday_iso": index + 1,
			"letter": PlanSchedule.weekday_letter(index + 1),
			"date": dates[index] if index < dates.size() else "",
			"kind": String(kinds[index]),
		})
	return out


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

## The plan the wizard would produce today: four days, body-part split, real library ids.
func _plan_fixture(plan_id: String) -> Dictionary:
	return {
		"id": plan_id,
		"name": "Chest & Back ×2 / Legs & Arms / Shoulders & Core",
		"created_at": Dates.add_days(Dates.today_iso(), -14) + "T10:00:00Z",
		"source": "builtin",
		"provider": "",
		"goal": "hypertrophy",
		"days_per_week": 4,
		"duration_min": 40,
		"areas": ["chest", "back", "shoulders", "arms"],
		"equipment": ["barbell", "dumbbell", "bodyweight"],
		"notes": "",
		"split_name": "Chest & Back ×2 / Legs & Arms / Shoulders & Core",
		"sessions": [
			_session("s1", 0, "Chest & Back A", ["chest", "back"], [
				{"exercise_id": "bench-press", "sets": 3, "reps": "8-10", "rest_seconds": 90},
				{"exercise_id": "barbell-row", "sets": 3, "reps": "8-10", "rest_seconds": 90},
			]),
			_session("s2", 1, "Legs & Arms", ["legs", "arms"], [
				{"exercise_id": "squat", "sets": 3, "reps": "8-10", "rest_seconds": 120},
			]),
			_session("s3", 2, "Shoulders & Core", ["shoulders", "core"], [
				{"exercise_id": "overhead-press", "sets": 3, "reps": "8-10",
					"rest_seconds": 90},
			]),
			_session("s4", 3, "Chest & Back B", ["chest", "back"], [
				{"exercise_id": "bench-press", "sets": 3, "reps": "8-10", "rest_seconds": 90},
			]),
		],
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


func _entry(date: String) -> Dictionary:
	return {
		"id": "h-%s" % date.replace("-", ""),
		"plan_id": PLAN_ID,
		"session_id": "s1",
		"session_title": "Chest & Back A",
		"date": date,
		"started_at": date + "T18:00:00Z",
		"completed_at": date + "T19:00:00Z",
		"completed": true,
		"duration_sec": 2400,
		"focus": ["chest", "back"],
		"partial": false,
	}
