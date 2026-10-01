class_name PlanTab
extends Control
## Plan tab — "what am I doing this week?" answered from the stored plan and the history.
##
## Three cards: the active plan's identity (name, days, goal, split, body areas) with the two
## actions that change it, this week's strip — the same seven pills Home shows, with the same
## kinds, so "which days did I train" reads identically in both places — and the plan's sessions
## as day cards that open the session preview.
##
## **It owns no domain maths.** The strip kinds come from [HomeState], the weekday pattern and
## the session-for-date mapping from [PlanSchedule], the labels from [Taxonomy] and
## [WizardState.title_for_goal]. This file renders, walks routes and asks [Store] for data.
##
## **Refresh.** `_refresh()` pushes values into nodes that were all created in `_ready()` — seven
## day cards, the strip's own seven pills — so a refresh adds no nodes to the tab. It runs when
## the data changes, when the tab becomes visible, on theme changes, and from
## [method on_route_entered].
##
## **Remove plan never touches history.** The button clears the *active-plan pointer* through
## `Store.set_active_plan("")`; every logged session stays in `history.json` and in the Tracker.
##
## **Empty state.** With no active plan the three cards hide and one state card offers the only
## useful action: start the wizard. That is the reset path the owner asked for, and it is also
## the "make a new plan" path — a plan is replaced, never edited, so there is exactly one button
## for both jobs.

## Empty-state copy (asserted by the screen suite).
const EMPTY_ICON := &"plan"
const EMPTY_TITLE := "No plan yet"
const EMPTY_BODY := "Answer a few questions and MicroWorkout builds a week for you — " \
	+ "different muscle groups each day."
const EMPTY_ACTION := "Create a plan"

## This-week caption and empty-state copy live in [HomeState] / here respectively; the strip
## itself comes from [HomeState.build_week_strip], so Home, Plan and Tracker can never disagree.
const REMOVED_TOAST := "Plan removed. Your history is still in the Tracker."

## A plan can hold one session per day, and Sunday is the seventh.
const SESSION_SLOTS := 7

## Every session kind the strip can carry, i.e. the vocabulary `kind_for()` returns.
const KIND_DONE := "done"
const KIND_TODAY := "today"
const KIND_UPCOMING := "upcoming"

const DAY_CARD_SCENE := preload("res://scenes/components/day_card.tscn")

@onready var _empty_state: Control = $Gutter/Layout/EmptyState
@onready var _scroll: ScrollContainer = $Gutter/Layout/Scroll
@onready var _name_label: Label = $Gutter/Layout/Scroll/Column/PlanCard/CardBody/NameLabel
@onready var _meta_label: Label = $Gutter/Layout/Scroll/Column/PlanCard/CardBody/MetaLabel
@onready var _split_label: Label = $Gutter/Layout/Scroll/Column/PlanCard/CardBody/SplitLabel
@onready var _areas_label: Label = $Gutter/Layout/Scroll/Column/PlanCard/CardBody/AreasLabel
@onready var _new_button: Button = $Gutter/Layout/Scroll/Column/PlanCard/CardBody/Actions/NewPlanButton
@onready var _remove_button: Button = $Gutter/Layout/Scroll/Column/PlanCard/CardBody/Actions/RemovePlanButton
@onready var _strip: Control = $Gutter/Layout/Scroll/Column/WeekCard/CardBody/WeekStrip
@onready var _week_caption: Label = $Gutter/Layout/Scroll/Column/WeekCard/CardBody/WeekCaption
@onready var _day_list: VBoxContainer = $Gutter/Layout/Scroll/Column/SessionsCard/CardBody/DayList
@onready var _remove_dialog: ConfirmationDialog = $RemoveDialog

var _cards: Array[Control] = []
var _today: String = ""
var _strip_kinds_by_date: Dictionary = {}
var _session_kinds: Dictionary = {}
var _empty_case: String = ""
var _debug_state: Dictionary = {}


func _ready() -> void:
	_today = Dates.today_iso()
	_build_header()
	_build_day_cards()
	_apply_static_copy()
	_connect_signals()
	_refresh()
	print("[plan] ready cards=%d" % _cards.size())


# ------------------------------------------------------------------ construction

func _build_header() -> void:
	var header := $Gutter/Layout/SectionHeader
	if header.has_method(&"set_header"):
		header.call(&"set_header", "Plan", "")


## Seven pooled day cards, created once. `_refresh()` only calls `set_day()` on them.
func _build_day_cards() -> void:
	for _index in SESSION_SLOTS:
		var card: Control = DAY_CARD_SCENE.instantiate()
		card.connect(&"pressed", _on_day_pressed)
		_day_list.add_child(card)
		_cards.append(card)


func _apply_static_copy() -> void:
	_empty_state.call(&"set_state", EMPTY_ICON, EMPTY_TITLE, EMPTY_BODY, EMPTY_ACTION)


func _connect_signals() -> void:
	App.data_changed.connect(_on_data_changed)
	Store.plans_changed.connect(_on_data_changed)
	Store.history_changed.connect(_on_data_changed)
	App.settings_changed.connect(_on_settings_changed)
	App.theme_changed.connect(_on_theme_changed)
	Nav.tab_changed.connect(_on_tab_changed)
	visibility_changed.connect(_on_visibility_changed)
	_new_button.pressed.connect(_on_new_plan_pressed)
	_remove_button.pressed.connect(_on_remove_pressed)
	_remove_dialog.confirmed.connect(_on_remove_confirmed)
	_empty_state.connect(&"action_pressed", _on_empty_action)
	_strip.connect(&"pressed", _on_strip_day_pressed)
	_style_dialog(_remove_dialog)


# ------------------------------------------------------------------ refresh

func _refresh() -> void:
	if not is_inside_tree() or _cards.is_empty():
		return
	var plan := Store.active_plan()
	var entries := Store.all_entries()
	var has_plan := not plan.is_empty()

	_empty_case = "" if has_plan else "no_plan"
	_empty_state.visible = not has_plan
	_scroll.visible = has_plan
	if not has_plan:
		_strip_kinds_by_date.clear()
		_session_kinds.clear()
		for card in _cards:
			card.visible = false
		_debug_state = {
			"empty_case": _empty_case,
			"name": "",
			"days": 0,
			"done_this_week": 0,
			"kinds": [],
		}
		print("[plan] empty=%s" % _empty_case)
		return

	var days := PlanSchedule.days_per_week_of(plan)
	var state := HomeState.resolve_state(plan, entries, _today, days)
	var strip := HomeState.build_week_strip(state, plan, entries, _today, days)
	_strip.call(&"set_week", strip)

	_strip_kinds_by_date.clear()
	var done := 0
	for day in strip:
		var date := String(day.get("date", ""))
		var kind := String(day.get("kind", ""))
		_strip_kinds_by_date[date] = kind
		if kind == HomeState.KIND_DONE:
			done += 1

	_name_label.text = _plan_name(plan, days)
	_meta_label.text = _meta_text(plan, days)
	_split_label.text = PlanModel.as_text(plan.get("split_name"), "")
	_areas_label.text = _areas_text(plan)
	_week_caption.text = HomeState.week_caption(state, strip, days)
	_render_sessions(plan, entries, days)

	_debug_state = {
		"empty_case": _empty_case,
		"name": _name_label.text,
		"split": _split_label.text,
		"days": days,
		"state": state,
		"done_this_week": done,
		"caption": _week_caption.text,
		"strip": Array(HomeState.strip_kinds(strip)),
		"sessions": Array(_session_kinds.values()),
		"plan_id": PlanModel.as_text(plan.get("id"), ""),
	}
	print("[plan] name=%s days=%d state=%s done=%d cards=%d" % [
		_name_label.text, days, state, done, _visible_card_count()])
	_publish_probe_rects.call_deferred()


## The day cards are a *view* of the plan's sessions: one per session, `Day N · weekday` from
## the plan's own pattern, and the kind of the session's next appearance this week.
func _render_sessions(plan: Dictionary, entries: Array[Dictionary], days: int) -> void:
	var sessions := PlanSchedule.sessions_of(plan)
	var weekdays := PlanSchedule.weekdays_for(days)
	_session_kinds = session_kinds(plan, entries, _today)
	for index in _cards.size():
		var card := _cards[index]
		if index >= sessions.size():
			card.visible = false
			continue
		var session: Dictionary = sessions[index]
		var iso := int(weekdays[index % weekdays.size()]) if not weekdays.is_empty() else 0
		var kind := String(_session_kinds.get(_session_id(session), KIND_UPCOMING))
		card.call(&"set_day", session, StringName(kind), PlanSchedule.weekday_name(iso))
		card.visible = true


## Each session's kind for *this* week: `done` when a completed entry already covers it, `today`
## when it is today's session, `upcoming` otherwise. A finished plan is `done` throughout — the
## same rule `HomeState.build_week_strip()` applies to the pills, so the card and the pill can
## never disagree.
static func session_kinds(plan: Dictionary, entries: Array[Dictionary], today: String) -> Dictionary:
	var out := {}
	var sessions := PlanSchedule.sessions_of(plan)
	if sessions.is_empty():
		return out
	if PlanSchedule.is_plan_finished(plan, entries):
		for session in sessions:
			out[_session_id(session)] = KIND_DONE
		return out
	for date in PlanSchedule.week_dates(today):
		var session := PlanSchedule.session_for_date(plan, entries, date)
		if session.is_empty():
			continue
		var id := _session_id(session)
		if String(out.get(id, "")) == KIND_DONE:
			continue
		if HomeState.has_completed_entry_on(entries, date):
			out[id] = KIND_DONE
		elif date == today:
			out[id] = KIND_TODAY
		elif not out.has(id):
			out[id] = KIND_UPCOMING
	return out


# ------------------------------------------------------------------ actions

func _on_new_plan_pressed() -> void:
	Feedback.tap()
	Nav.push(Routes.NEW_WORKOUT_WIZARD, {"entry": "plan_tab"})


func _on_empty_action() -> void:
	_on_new_plan_pressed()


func _on_remove_pressed() -> void:
	if Store.active_plan_id().is_empty():
		return
	Feedback.tap()
	_remove_dialog.popup_centered()


func _on_remove_confirmed() -> void:
	reset_plan()


## Clears the active-plan pointer. Exposed so the screen suite can drive the reset without
## popping the dialog; a plan is never edited in place, so this is the whole "reset" contract.
func reset_plan() -> bool:
	if Store.active_plan_id().is_empty():
		return false
	var cleared := Store.set_active_plan("")
	if cleared:
		Feedback.toast(REMOVED_TOAST, &"success")
	return cleared


## A strip tap is never a dead end: a day with a logged session opens its detail, a training day
## opens that session's preview, and a rest day just acknowledges the tap.
func _on_strip_day_pressed(date: String) -> void:
	var entries := Store.entries_on(date)
	if not entries.is_empty():
		Nav.push(Routes.TRACKER_DAY_DETAIL, {
			"date": date,
			"entry_id": String((entries[0] as Dictionary).get("id", "")),
		})
		return
	var plan := Store.active_plan()
	var session := PlanSchedule.session_for_date(plan, Store.all_entries(), date)
	if not session.is_empty():
		Nav.push(Routes.SESSION_PREVIEW, {
			"plan_id": PlanModel.as_text(plan.get("id"), ""),
			"session_id": _session_id(session),
		})
		return
	Feedback.tap()


func _on_day_pressed(session_id: String) -> void:
	var plan := Store.active_plan()
	Nav.push(Routes.SESSION_PREVIEW, {
		"plan_id": PlanModel.as_text(plan.get("id"), ""),
		"session_id": session_id,
	})


# ------------------------------------------------------------------ signal slots

func _on_data_changed() -> void:
	_refresh()


func _on_settings_changed(_key: String) -> void:
	_refresh()


func _on_theme_changed(_mode: String) -> void:
	_refresh()


func _on_tab_changed(index: int) -> void:
	if index == Routes.TAB_ROUTES.find(Routes.PLAN):
		_refresh()


func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		return
	# A tab entry always re-reads the clock: a session finished on the Home tab is visible here
	# the moment the owner switches over.
	var system_today := Dates.today_iso()
	if system_today != _today:
		_today = system_today
	_refresh()


## Nav calls this when the Plan tab becomes the active tab.
func on_route_entered(_args: Dictionary) -> void:
	_refresh()


# ------------------------------------------------------------------ helpers

func _plan_name(plan: Dictionary, days: int) -> String:
	var stored := PlanModel.as_text(plan.get("name"), "").strip_edges()
	if not stored.is_empty():
		return stored
	var split := PlanModel.as_text(plan.get("split_name"), "")
	return "%d-Day %s" % [days, split] if not split.is_empty() else "%d-Day plan" % days


func _meta_text(plan: Dictionary, days: int) -> String:
	var parts := PackedStringArray(["%d days a week" % days])
	var duration := PlanModel.as_int(plan.get("duration_min"), 0)
	if duration > 0:
		parts.append("%d min" % duration)
	var goal := WizardState.title_for_goal(PlanModel.as_text(plan.get("goal"), ""))
	if not goal.is_empty():
		parts.append(goal)
	return " · ".join(parts)


func _areas_text(plan: Dictionary) -> String:
	var labels := PackedStringArray()
	var raw: Variant = plan.get("areas", [])
	if raw is Array:
		for value in raw:
			var area := String(value)
			if Taxonomy.is_user_area(area):
				labels.append(Taxonomy.label(area))
	return " · ".join(labels)


static func _session_id(session: Dictionary) -> String:
	return PlanModel.as_text(session.get("id"), "")


func _visible_card_count() -> int:
	var count := 0
	for card in _cards:
		if card.visible:
			count += 1
	return count


func _style_dialog(dialog: ConfirmationDialog) -> void:
	var ok := dialog.get_ok_button()
	if ok != null:
		ok.theme_type_variation = &"DangerButton"
	var cancel := dialog.get_cancel_button()
	if cancel != null:
		cancel.theme_type_variation = &"SecondaryButton"


## The rects the acceptance tooling drives (debug builds only).
func _probe_rects() -> Dictionary:
	var entries := {}
	if _new_button.is_visible_in_tree():
		entries["plan_new_button"] = _new_button
	if _remove_button.is_visible_in_tree():
		entries["plan_remove_button"] = _remove_button
	for card in _cards:
		if card.is_visible_in_tree():
			entries["plan_first_day_card"] = card
			break
	return entries


func _publish_probe_rects() -> void:
	UiProbe.log_rects_settled(get_tree(), _probe_rects())


# ------------------------------------------------------------------ test/debug surface

func debug_state() -> Dictionary:
	return _debug_state


## The strip kind for [param date] (`done | today | upcoming | rest | missed`), as rendered.
func kind_for(date: String) -> String:
	return String(_strip_kinds_by_date.get(date, ""))


func session_kind(session_id: String) -> String:
	return String(_session_kinds.get(session_id, ""))


func day_card_count() -> int:
	return _cards.size()

