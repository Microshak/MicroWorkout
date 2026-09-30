extends Control
## Tracker tab — PRD-11.
##
## "Am I actually doing this?" answered from stored history: the weekly goal ring, day-streak
## and best-streak tiles, a month calendar with every past day marked, per-area balance, and the
## ten most recent sessions.
##
## **It owns no domain maths.** The ring numbers are PRD-03's `Store` accessors plus
## `Streak.ring_segments()`; the day kinds are [MonthGrid.DayStatus] over
## `PlanSchedule.session_for_date()`; the area tally is [AreaBalance]. This file renders, wires
## and navigates (R3 — PRD-03 §10 and PRD-09 §10 both forbid a second streak/schedule
## implementation, and AC3 greps for one).
##
## **It never writes.** No `FileAccess`, no `Store` mutation, no `Store.flush()` (AC14, R1).
##
## **Refresh (R1/R12).** `_refresh()` re-reads the store and pushes values into nodes that were
## all created in `_ready()` — 42 cells, 10 pooled rows, 7 area bars — so a refresh allocates no
## nodes and cannot leak them. It runs on data/plan/history changes, on `entry_added` (PRD-10's
## completion signal), when the tab becomes visible, and on theme/settings changes.

## Tab indices (appendix §2 order: Home 0, Plan 1, Tracker 2, Settings 3).
const HOME_TAB := 0

## R2/R8: pooled recent rows. More than this and the list stops being "recent".
const RECENT_ROWS := 10

## R6's cell width. The day_cell component owns the same 128 px minimum (ADR-25); the weekday
## header labels repeat it here so the letters sit exactly over the columns.
const CELL_WIDTH := 128.0

## R5's copy. The titles are the exact strings the acceptance run reads.
const TITLE_STREAK := "DAY STREAK"
const TITLE_BEST := "BEST STREAK"
const RISK_TEXT := "!  Streak at risk — today isn't logged yet"
const RISK_HOUR := 20

## R10's three sets of copy — asserted verbatim by the screen suite.
const EMPTY_1_TITLE := "No workouts yet"
const EMPTY_1_BODY := "Generate a plan and MicroWorkout will walk you through it, exercise by exercise."
const EMPTY_1_ACTION := "Create a plan"
const EMPTY_2_TITLE := "Your plan is ready"
const EMPTY_2_BODY := "Nothing logged yet. Today's session is waiting on the Home tab."
const EMPTY_2_ACTION := "Go to Home"
const EMPTY_3_TITLE := "No active plan"
const EMPTY_3_BODY := "Your past workouts are still here. Generate a new plan to start a fresh week."
const EMPTY_3_ACTION := "New plan"
const NO_PLAN_BANNER := "No active plan — missed days can't be shown."
const AREA_SUBTITLE := "Completed sessions, last 12 weeks"
const RECENT_EMPTY := "No completed sessions yet."
const UNATTRIBUTED_TEXT := "%d older sessions could not be attributed to an area."

const CELL_SCENE := preload("res://scenes/components/day_cell.tscn")
const ROW_SCENE := preload("res://scenes/components/session_row.tscn")
const BAR_SCENE := preload("res://scenes/components/area_bar.tscn")

@onready var _month_row: HBoxContainer = $Gutter/Layout/MonthRow
@onready var _prev_button: Button = $Gutter/Layout/MonthRow/PrevMonthButton
@onready var _next_button: Button = $Gutter/Layout/MonthRow/NextMonthButton
@onready var _month_label: Label = $Gutter/Layout/MonthRow/MonthLabel
@onready var _empty_state: Control = $Gutter/Layout/EmptyState
@onready var _ring_tile: Control = $Gutter/Layout/Scroll/Column/RingTile
@onready var _streak_tile: Control = $Gutter/Layout/Scroll/Column/StatsRow/StreakTile
@onready var _best_tile: Control = $Gutter/Layout/Scroll/Column/StatsRow/BestTile
@onready var _progress_over: Button = $Gutter/Layout/Scroll/Column/ProgressOver
@onready var _risk_chip: Button = $Gutter/Layout/Scroll/Column/RiskChip
@onready var _calendar_card: PanelContainer = $Gutter/Layout/Scroll/Column/CalendarCard
@onready var _grid: GridContainer = $Gutter/Layout/Scroll/Column/CalendarCard/CardBody/CalendarGrid
@onready var _weekday_header: GridContainer = $Gutter/Layout/Scroll/Column/CalendarCard/CardBody/WeekdayHeader
@onready var _legend_done: Control = $Gutter/Layout/Scroll/Column/CalendarCard/CardBody/CalendarLegend/LegendDoneGlyph
@onready var _legend_missed: Control = $Gutter/Layout/Scroll/Column/CalendarCard/CardBody/CalendarLegend/LegendMissedGlyph
@onready var _legend_planned: Control = $Gutter/Layout/Scroll/Column/CalendarCard/CardBody/CalendarLegend/LegendPlannedGlyph
@onready var _no_plan_banner: PanelContainer = $Gutter/Layout/Scroll/Column/CalendarCard/CardBody/NoPlanBanner
@onready var _no_plan_label: Label = $Gutter/Layout/Scroll/Column/CalendarCard/CardBody/NoPlanBanner/NoPlanLabel
@onready var _area_card: PanelContainer = $Gutter/Layout/Scroll/Column/AreaCard
@onready var _area_list: VBoxContainer = $Gutter/Layout/Scroll/Column/AreaCard/CardBody/AreaList
@onready var _area_footnote: Label = $Gutter/Layout/Scroll/Column/AreaCard/CardBody/AreaFootnote
@onready var _recent_card: PanelContainer = $Gutter/Layout/Scroll/Column/RecentCard
@onready var _recent_list: VBoxContainer = $Gutter/Layout/Scroll/Column/RecentCard/CardBody/RecentList
@onready var _recent_empty: Label = $Gutter/Layout/Scroll/Column/RecentCard/CardBody/RecentEmpty

var _cells: Array[Control] = []
var _cell_by_date: Dictionary = {}
var _rows: Array[Button] = []
var _bars: Array[Control] = []

var _year: int = 0
var _month: int = 0
var _today: String = ""
var _kinds: Dictionary = {}
var _empty_case: String = ""
var _debug_state: Dictionary = {}
var _route_detail: StringName = &""
var _neglected_this_refresh := PackedStringArray()


func _ready() -> void:
	_route_detail = Routes.TRACKER_DAY_DETAIL
	_today = Dates.today_iso()
	var month := MonthGrid.month_of(_today)
	_year = int(month[0]) if not month.is_empty() else 2026
	_month = int(month[1]) if not month.is_empty() else 1

	_build_header()
	_build_calendar()
	_build_area_list()
	_build_recent_list()
	_connect_signals()
	_apply_static_copy()
	_apply_legend_colours()
	_refresh()
	set_process(false)
	print("[tracker] ready cells=%d rows=%d bars=%d" % [_cells.size(), _rows.size(), _bars.size()])


# ------------------------------------------------------------------ construction (R2)

func _build_header() -> void:
	var header := $Gutter/Layout/SectionHeader
	if header.has_method(&"set_header"):
		header.call(&"set_header", "Tracker", "")


## R2/R6: exactly 42 childless day cells, created once. `_refresh()` only calls `set_day()`.
func _build_calendar() -> void:
	for column in MonthGrid.COLUMNS:
		var header := Label.new()
		header.text = PlanSchedule.WEEKDAY_LETTERS[column]
		header.custom_minimum_size.x = CELL_WIDTH
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		header.theme_type_variation = &"Caption"
		_weekday_header.add_child(header)
	for index in MonthGrid.CELLS:
		var cell: Control = CELL_SCENE.instantiate()
		cell.connect(&"pressed", _on_day_pressed)
		cell.connect(&"swiped", _on_day_swiped)
		_grid.add_child(cell)
		_cells.append(cell)


func _build_area_list() -> void:
	for area in Taxonomy.USER_AREAS:
		var bar: Control = BAR_SCENE.instantiate()
		bar.set_meta("area", area)
		_area_list.add_child(bar)
		_bars.append(bar)


func _build_recent_list() -> void:
	for index in RECENT_ROWS:
		var row: Button = ROW_SCENE.instantiate()
		row.set_meta("stagger_index", index)
		row.connect(&"row_pressed", _on_row_pressed)
		_recent_list.add_child(row)
		_rows.append(row)


func _connect_signals() -> void:
	App.data_changed.connect(_on_data_changed)
	Store.plans_changed.connect(_on_data_changed)
	Store.history_changed.connect(_on_data_changed)
	Store.entry_added.connect(_on_entry_added)
	App.settings_changed.connect(_on_settings_changed)
	App.theme_changed.connect(_on_theme_changed)
	Nav.tab_changed.connect(_on_tab_changed)
	visibility_changed.connect(_on_visibility_changed)
	_prev_button.pressed.connect(_on_prev_month)
	_next_button.pressed.connect(_on_next_month)
	_streak_tile.gui_input.connect(_on_stat_input)
	_best_tile.gui_input.connect(_on_stat_input)
	_empty_state.connect(&"action_pressed", _on_empty_action)


func _apply_static_copy() -> void:
	_no_plan_label.text = NO_PLAN_BANNER
	_recent_empty.text = RECENT_EMPTY
	var subtitle := $Gutter/Layout/Scroll/Column/AreaCard/CardBody/AreaSubtitle as Label
	subtitle.text = AREA_SUBTITLE
	var title := $Gutter/Layout/Scroll/Column/AreaCard/CardBody/AreaTitle as Label
	title.text = "Body-area balance"
	var recent_title := $Gutter/Layout/Scroll/Column/RecentCard/CardBody/RecentTitle as Label
	recent_title.text = "Recent sessions"


## R6's legend: four drawn cues, so the legend itself never depends on colour. "Rest" is the
## absence of a mark, shown as blank space rather than a fabricated glyph.
func _apply_legend_colours() -> void:
	var mode := App.theme_mode
	_legend_done.add_theme_color_override(&"color", DesignTokens.accent_text(mode, "success"))
	_legend_missed.add_theme_color_override(&"color", DesignTokens.accent_text(mode, "danger"))
	_legend_planned.add_theme_color_override(&"color", DesignTokens.color(mode, "outline_strong"))


# ------------------------------------------------------------------ refresh (R1/R12)

func _refresh() -> void:
	if not is_inside_tree() or _cells.is_empty():
		return
	var entries := Store.all_entries()
	var plans_doc := Store.plans_doc()
	var plan := Store.active_plan()

	var week_id := Store.current_week_id()
	var completed := Store.completed_days_in_week(week_id)
	var target := Store.weekly_goal_days_effective()
	var fraction := Store.weekly_goal_progress()
	var streak := Store.streak_days(_today)
	var longest := Store.longest_streak()

	_render_empty_state(plan, entries)
	_render_ring(completed, target, fraction, entries, week_id)
	_render_streak(streak, longest, entries)
	_render_overload(completed, target)
	_refresh_calendar(plan, entries)
	_render_areas(plan, entries, plans_doc)
	_render_recent(entries)

	_debug_state = {
		"week_id": week_id,
		"completed": completed,
		"target": target,
		"streak": streak,
		"best": longest,
		"month": "%04d-%02d" % [_year, _month],
		"neglected": Array(_neglected_this_refresh),
	}
	print("[tracker] week=%s completed=%d goal=%d streak=%d longest=%d neglected=[%s]" % [
		week_id, completed, target, streak, longest, ",".join(_neglected_this_refresh)])
	_publish_probe_rects.call_deferred()


## R10. Cases 1 and 2 hide every card and show only the empty state; case 3 is additive — the
## history IS the point, so the cards stay and a banner explains why missed days are missing.
func _render_empty_state(plan: Dictionary, entries: Array[Dictionary]) -> void:
	var has_plan := not plan.is_empty()
	var has_history := not entries.is_empty()
	var has_completed := _completed_count(entries) > 0
	_empty_case = ""
	if not has_plan and not has_history:
		_empty_case = "no_data"
		_empty_state.call(&"set_state", &"dumbbell", EMPTY_1_TITLE, EMPTY_1_BODY, EMPTY_1_ACTION)
	elif has_plan and not has_completed:
		_empty_case = "no_history"
		_empty_state.call(&"set_state", &"calendar", EMPTY_2_TITLE, EMPTY_2_BODY, EMPTY_2_ACTION)
	elif has_history and not has_plan:
		_empty_case = "no_plan"
		_empty_state.call(&"set_state", &"alert", EMPTY_3_TITLE, EMPTY_3_BODY, EMPTY_3_ACTION)

	var show_only_empty := _empty_case == "no_data" or _empty_case == "no_history"
	_empty_state.visible = not _empty_case.is_empty()
	_month_row.visible = not show_only_empty
	_ring_tile.visible = not show_only_empty
	_streak_tile.get_parent().visible = not show_only_empty
	_calendar_card.visible = not show_only_empty
	_area_card.visible = not show_only_empty
	_recent_card.visible = not show_only_empty
	_no_plan_banner.visible = _empty_case == "no_plan"


func _render_ring(completed: int, target: int, fraction: float, entries: Array[Dictionary],
		week_id: String) -> void:
	var bits := Streak.ring_segments(entries, week_id, target)
	_ring_tile.call(&"set_week", completed, target, fraction, bits)


func _render_streak(streak: int, longest: int, entries: Array[Dictionary]) -> void:
	_streak_tile.call(&"set_stat", TITLE_STREAK, str(streak), &"flame")
	_best_tile.call(&"set_stat", TITLE_BEST, str(longest), &"trophy")
	var mode := App.theme_mode
	var streak_icon := _streak_tile.get_node_or_null(^"Stack/Icon") as Control
	if streak_icon != null:
		streak_icon.add_theme_color_override(&"color", DesignTokens.accent_text(mode,
			"warning" if streak > 0 else "text_disabled"))
	var best_icon := _best_tile.get_node_or_null(^"Stack/Icon") as Control
	if best_icon != null:
		best_icon.add_theme_color_override(&"color", DesignTokens.accent_text(mode,
			"success" if longest > 0 else "text_disabled"))

	var today_done := _has_completed_on(entries, _today)
	var hour := int(Time.get_datetime_dict_from_system().get("hour", 0))
	_risk_chip.visible = _risk_should_show(streak, today_done, hour)
	_risk_chip.text = RISK_TEXT
	_risk_chip.add_theme_color_override(&"font_disabled_color",
		DesignTokens.accent_text(mode, "warning"))


## R4's overload affordance: the label keeps counting past the goal while the arc caps at 100 %.
func _render_overload(completed: int, target: int) -> void:
	var over := target > 0 and completed > target
	_progress_over.visible = over
	if not over:
		return
	_progress_over.text = "+%d over goal" % (completed - target)
	_progress_over.add_theme_color_override(&"font_disabled_color",
		DesignTokens.accent_text(App.theme_mode, "success"))


## R6: the 42 cells for the displayed month. Every kind comes from [MonthGrid.DayStatus]; this
## file asserts nothing about what a day is.
func _refresh_calendar(plan: Dictionary, entries: Array[Dictionary]) -> void:
	_month_label.text = MonthGrid.label(_year, _month)
	var cells := MonthGrid.cells(_year, _month)
	var completed_dates := Streak.completed_dates(entries, "")
	_cell_by_date.clear()
	_kinds.clear()
	for index in _cells.size():
		var cell := _cells[index]
		var iso := cells[index] if index < cells.size() else ""
		var in_month := MonthGrid.contains(_year, _month, iso)
		var kind := MonthGrid.DayStatus.resolve(iso, _today, completed_dates, plan, entries,
			in_month)
		cell.call(&"set_day", iso, kind, in_month, iso == _today)
		if in_month:
			_cell_by_date[iso] = cell
			_kinds[iso] = kind
	_update_month_bounds(entries)


## R11: no page past the current month, none before the earliest entry's month.
func _update_month_bounds(entries: Array[Dictionary]) -> void:
	var current := MonthGrid.month_of(_today)
	var current_index := 0
	if not current.is_empty():
		current_index = int(current[0]) * 12 + int(current[1])
	var earliest := _earliest_month_index(entries)
	var shown := _year * 12 + _month
	_prev_button.disabled = shown <= earliest
	_next_button.disabled = shown >= current_index
	_prev_button.focus_mode = Control.FOCUS_NONE if _prev_button.disabled else Control.FOCUS_ALL
	_next_button.focus_mode = Control.FOCUS_NONE if _next_button.disabled else Control.FOCUS_ALL


func _earliest_month_index(entries: Array[Dictionary]) -> int:
	var best := ""
	for entry in entries:
		var date := String(entry.get("date", ""))
		if Dates.is_valid_iso_date(date) and (best.is_empty() or date < best):
			best = date
	if best.is_empty():
		var current := MonthGrid.month_of(_today)
		if current.is_empty():
			return _year * 12 + _month
		return int(current[0]) * 12 + int(current[1])
	var parts := MonthGrid.month_of(best)
	return int(parts[0]) * 12 + int(parts[1])


## R9: seven rows in §6.1 order. `Neglected` is computed only over the active plan's areas.
func _render_areas(plan: Dictionary, entries: Array[Dictionary], plans_doc: Dictionary) -> void:
	var plans_by_id := _plans_by_id(plans_doc)
	var tally := AreaBalance.tally(entries, plans_by_id, _today)
	var plan_areas := _plan_areas(plan)
	_neglected_this_refresh = AreaBalance.neglected(tally, plan_areas, _today)
	var highest := 1
	for area in Taxonomy.USER_AREAS:
		highest = maxi(highest, int((tally[area] as Dictionary).get("sessions", 0)))
	for index in _bars.size():
		var area := Taxonomy.USER_AREAS[index]
		var slot: Dictionary = tally[area]
		_bars[index].call(&"set_area", Taxonomy.label(area), int(slot.get("sessions", 0)),
			int(slot.get("days_since", -1)), highest, _neglected_this_refresh.has(area))
	var unattributed := int((tally[AreaBalance.UNATTRIBUTED] as Dictionary).get("sessions", 0))
	_area_footnote.visible = unattributed > 0
	if unattributed > 0:
		_area_footnote.text = UNATTRIBUTED_TEXT % unattributed


## R8: up to ten rows, newest first, pooled — unused rows hide.
func _render_recent(entries: Array[Dictionary]) -> void:
	var sorted := _sorted_entries(entries)
	_recent_empty.visible = sorted.is_empty()
	_recent_list.visible = not sorted.is_empty()
	for index in _rows.size():
		var row := _rows[index]
		if index < sorted.size():
			row.call(&"set_entry", sorted[index], _today)
			row.visible = true
		else:
			row.visible = false


# ------------------------------------------------------------------ month navigation (R11)

func _on_prev_month() -> void:
	if _prev_button.disabled:
		return
	var shifted := MonthGrid.add_months(_year, _month, -1)
	_year = int(shifted[0])
	_month = int(shifted[1])
	_refresh_calendar(Store.active_plan(), Store.all_entries())


func _on_next_month() -> void:
	if _next_button.disabled:
		return
	var shifted := MonthGrid.add_months(_year, _month, 1)
	_year = int(shifted[0])
	_month = int(shifted[1])
	_refresh_calendar(Store.active_plan(), Store.all_entries())


func _on_day_swiped(dx: float, dy: float) -> void:
	apply_swipe(dx, dy)


## R11's swipe rule, exposed so the screen suite can drive it without synthesising touches:
## a ≥ 64 px horizontal drag with `|dx| > |dy| × 1.5` turns the page; nothing else does.
func apply_swipe(dx: float, dy: float) -> bool:
	if absf(dx) < 64.0 or absf(dx) <= absf(dy) * 1.5:
		return false
	if dx < 0.0:
		if _next_button.disabled:
			return false
		_on_next_month()
	else:
		if _prev_button.disabled:
			return false
		_on_prev_month()
	return true


# ------------------------------------------------------------------ day detail (R6/R7)

func _on_day_pressed(date: String) -> void:
	var kind := String(_kinds.get(date, MonthGrid.DayStatus.REST))
	if kind == MonthGrid.DayStatus.DONE:
		_open_day(date)
	else:
		Feedback.tap()


## R6: a done day opens its most recent entry; several sessions in one day must not be a dead
## end. The detail screen resolves `""` to the day's first entry.
func _open_day(date: String) -> void:
	var entries := Store.entries_on(date)
	if entries.is_empty():
		Feedback.tap()
		return
	var sorted := _sorted_entries(entries)
	var entry := sorted[0]
	Nav.push(_route_detail, {
		"date": date,
		"entry_id": String(entry.get("id", "")),
	})


func _on_row_pressed(entry_id: String) -> void:
	var entry := _entry_by_id(entry_id)
	if entry.is_empty():
		return
	Nav.push(_route_detail, {
		"date": String(entry.get("date", "")),
		"entry_id": entry_id,
	})


# ------------------------------------------------------------------ stats tap (R5)

## R5: a dead tap on a stat tile is a bug — both tiles open the most recent completed session,
## and do nothing at all when there is none.
func _on_stat_input(event: InputEvent) -> void:
	var released := false
	if event is InputEventScreenTouch:
		released = not (event as InputEventScreenTouch).pressed
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		released = button.button_index == MOUSE_BUTTON_LEFT and not button.pressed
	if not released:
		return
	var sorted := _sorted_entries(Store.all_entries())
	for entry in sorted:
		if bool(entry.get("completed", false)):
			_on_row_pressed(String(entry.get("id", "")))
			return


# ------------------------------------------------------------------ empty-state action (R10)

func _on_empty_action() -> void:
	match _empty_case:
		"no_history":
			Nav.goto_tab(HOME_TAB)
		_:
			Nav.push(Routes.NEW_WORKOUT_WIZARD, {"entry": "tracker"})


# ------------------------------------------------------------------ signal slots

func _on_data_changed() -> void:
	_refresh()


func _on_entry_added(_entry: Dictionary) -> void:
	_refresh()


func _on_settings_changed(_key: String) -> void:
	_refresh()


func _on_theme_changed(_mode: String) -> void:
	_apply_legend_colours()
	_refresh()


func _on_tab_changed(index: int) -> void:
	if index == 2:
		_refresh()


func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		# A tab entry always re-reads the clock and the store (R1), so a session finished on the
		# Home tab is visible here the moment the owner switches over.
		var system_today := Dates.today_iso()
		if system_today != _today:
			_today = system_today
		_refresh()


# ------------------------------------------------------------------ helpers

func _plans_by_id(plans_doc: Dictionary) -> Dictionary:
	var out := {}
	var raw: Variant = plans_doc.get("plans", [])
	if raw is Array:
		for value in raw:
			if value is Dictionary:
				out[String(value.get("id", ""))] = value
	return out


func _plan_areas(plan: Dictionary) -> PackedStringArray:
	if plan.is_empty():
		return Taxonomy.USER_AREAS
	var out := PackedStringArray()
	var raw: Variant = plan.get("areas", [])
	if raw is Array:
		for value in raw:
			var area := String(value)
			if Taxonomy.is_user_area(area) and not out.has(area):
				out.append(area)
	return out if not out.is_empty() else Taxonomy.USER_AREAS


func _sorted_entries(entries: Array[Dictionary]) -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for entry in entries:
		copy.append(entry)
	copy.sort_custom(_entry_is_newer)
	return copy


static func _entry_is_newer(a: Dictionary, b: Dictionary) -> bool:
	return _sort_key(a) > _sort_key(b)


static func _sort_key(entry: Dictionary) -> String:
	var stamp := String(entry.get("completed_at", ""))
	if not stamp.is_empty():
		return stamp
	return String(entry.get("date", ""))


func _entry_by_id(entry_id: String) -> Dictionary:
	for entry in Store.all_entries():
		if String(entry.get("id", "")) == entry_id:
			return entry
	return {}


func _completed_count(entries: Array[Dictionary]) -> int:
	var count := 0
	for entry in entries:
		if bool(entry.get("completed", false)):
			count += 1
	return count


func _has_completed_on(entries: Array[Dictionary], date: String) -> bool:
	for entry in entries:
		if bool(entry.get("completed", false)) and String(entry.get("date", "")) == date:
			return true
	return false


## R5's at-risk rule, kept separate so the screen suite can test all three conditions without
## controlling the wall clock.
func _risk_should_show(streak: int, today_done: bool, hour: int) -> bool:
	return streak > 0 and not today_done and hour >= RISK_HOUR


## The rects the acceptance tooling drives (debug builds only). Only on-screen controls are
## published — today's cell is published only while the displayed month actually contains it.
## `tracker_done_cell` is the newest completed day on the page, which is how a seeded demo can
## open the day detail without tapping through the recent list.
func _probe_rects() -> Dictionary:
	var entries := {}
	if _prev_button.is_visible_in_tree():
		entries["tracker_prev_month"] = _prev_button
	if _next_button.is_visible_in_tree():
		entries["tracker_next_month"] = _next_button
	if _ring_tile.is_visible_in_tree():
		entries["tracker_ring"] = _ring_tile
	var cell: Control = _cell_by_date.get(_today, null)
	if cell != null and cell.is_visible_in_tree() and bool(cell.call(&"in_month")):
		entries["tracker_today_cell"] = cell
	var done_date := ""
	for date in _kinds:
		if String(_kinds[date]) == MonthGrid.DayStatus.DONE and String(date) > done_date:
			done_date = String(date)
	if not done_date.is_empty():
		var done_cell: Control = _cell_by_date.get(done_date, null)
		if done_cell != null and done_cell.is_visible_in_tree():
			entries["tracker_done_cell"] = done_cell
	return entries


func _publish_probe_rects() -> void:
	UiProbe.log_rects_settled(get_tree(), _probe_rects())


# ------------------------------------------------------------------ test/debug surface (R12)

## R12's machine-readable state — what the acceptance run reads through the logs, not by eye.
func debug_state() -> Dictionary:
	return _debug_state


func calendar_month() -> Array:
	return [_year, _month]


func kind_for(date: String) -> String:
	return String(_kinds.get(date, ""))


func cell_count() -> int:
	return _cells.size()


func recent_row_count() -> int:
	return _rows.size()


func area_row_count() -> int:
	return _bars.size()


## Nav calls this when the Tracker tab becomes the active tab (R1).
func on_route_entered(_args: Dictionary) -> void:
	_refresh()
