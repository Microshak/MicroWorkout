extends Control
## Home / cover screen — PRD-09.
##
## "Hey Workout" answers *what am I doing today, and how do I do it?* in one glance: the greeting
## line (R4), exactly one of five state cards (R10–R13), the week strip (R6), the streak tile and
## the weekly ring (R7/R8) and a preview of the next session (R9).
##
## **This screen owns no domain math.** Which weekday a session belongs to is
## [PlanSchedule]'s; what today's state is, which session is due, what the strip looks like and
## what the greeting says is [HomeState]'s; streak, ISO-week and ring numbers come straight from
## PRD-03's `Store` accessors and [Streak]. Both are pure and unit-tested headless, which is why
## this file is only rendering, wiring and motion.
##
## **Refresh (R14).** [method refresh] is idempotent and safe from any trigger: `App.data_changed`
## (plan saved/removed) and `Store.entry_added` (a workout just finished — PRD-10 must write
## through `Store.add_entry()`), the tab becoming visible, settings changes, Android's
## `APPLICATION_RESUMED`, the 60 s rollover timer and PRD-10's return from the player. A refresh
## that produces an identical state dictionary does nothing beyond the comparison.
##
## **It does no I/O.** Every read goes through [Store]; no `user://` path is ever opened here.

## The tab indices Home navigates to (appendix §2: `TAB_ROUTES` order).
const HOME_TAB := 0
const PLAN_TAB := 1

## R14 #6: the day-rollover poll. The timer pauses with the app, so `APPLICATION_RESUMED` is the
## real overnight path; this only covers an app left open across midnight.
const ROLLOVER_SEC := 60.0

## R15: the entrance animation is once per app session, not once per tab switch.
const ENTRANCE_MS := 180
const ENTRANCE_RISE := 12.0

## R13's `Repeat this plan` name suffix: the first repeat is the plan's second run.
const REPEAT_MARKER := "(repeat "

## R5: at most three focus chips, then a muted `+N`.
const MAX_FOCUS_CHIPS := 3

## R15: the flame only breathes from a three-day streak.
const FLAME_MIN_STREAK := 3

const ROUTES_PATH := "res://scripts/core/routes.gd"

## Route constants that land with PRD-08/PRD-10. Their **values** are the frozen appendix §2
## route names, so Home compiles and behaves identically before and after those PRDs add the
## constants to `routes.gd` — [method route_named] prefers whatever the real table declares.
const ROUTE_FALLBACKS := {
	"NEW_WORKOUT_WIZARD": &"new_workout_wizard",
	"SESSION_PREVIEW": &"session_preview",
	"WORKOUT_PLAYER": &"workout_player",
}

@onready var _background: ColorRect = $Background
@onready var _body: VBoxContainer = $Scroller/Gutter/Body
@onready var _sub_greeting: Label = $Scroller/Gutter/Body/GreetingBlock/SubGreetingLabel

@onready var _state_host: VBoxContainer = $Scroller/Gutter/Body/StateHost
@onready var _no_plan_card: PanelContainer = $Scroller/Gutter/Body/StateHost/NoPlanCard
@onready var _today_card: PanelContainer = $Scroller/Gutter/Body/StateHost/TodayCard
@onready var _done_card: PanelContainer = $Scroller/Gutter/Body/StateHost/DoneTodayCard
@onready var _rest_card: PanelContainer = $Scroller/Gutter/Body/StateHost/RestDayCard
@onready var _finished_card: PanelContainer = $Scroller/Gutter/Body/StateHost/PlanFinishedCard

@onready var _day_badge: Label = $Scroller/Gutter/Body/StateHost/TodayCard/CardBody/CardTopRow/DayBadge/BadgeLabel
@onready var _source_badge: Control = $Scroller/Gutter/Body/StateHost/TodayCard/CardBody/CardTopRow/BadgeHost/BadgeRow/SourceBadge
@onready var _session_title: Label = $Scroller/Gutter/Body/StateHost/TodayCard/CardBody/SessionTitle
@onready var _focus_row: HBoxContainer = $Scroller/Gutter/Body/StateHost/TodayCard/CardBody/FocusRow
@onready var _meta_row: Label = $Scroller/Gutter/Body/StateHost/TodayCard/CardBody/MetaRow
@onready var _start_button: Button = $Scroller/Gutter/Body/StateHost/TodayCard/CardBody/StartButton
@onready var _preview_button: Button = $Scroller/Gutter/Body/StateHost/TodayCard/CardBody/CardActions/PreviewButton
@onready var _change_plan_button: Button = $Scroller/Gutter/Body/StateHost/TodayCard/CardBody/CardActions/ChangePlanButton

@onready var _no_plan_button: Button = $Scroller/Gutter/Body/StateHost/NoPlanCard/CardBody/NoPlanButton

@onready var _done_body: Label = $Scroller/Gutter/Body/StateHost/DoneTodayCard/CardBody/DoneBody
@onready var _done_early_button: Button = $Scroller/Gutter/Body/StateHost/DoneTodayCard/CardBody/DoneActions/EarlyButton
@onready var _done_week_button: Button = $Scroller/Gutter/Body/StateHost/DoneTodayCard/CardBody/DoneActions/WeekButton

@onready var _rest_body: Label = $Scroller/Gutter/Body/StateHost/RestDayCard/CardBody/RestBody
@onready var _rest_early_button: Button = $Scroller/Gutter/Body/StateHost/RestDayCard/CardBody/RestActions/EarlyButton
@onready var _rest_week_button: Button = $Scroller/Gutter/Body/StateHost/RestDayCard/CardBody/RestActions/WeekButton

@onready var _finished_body: Label = $Scroller/Gutter/Body/StateHost/PlanFinishedCard/CardBody/FinishedBody
@onready var _finished_stats: Label = $Scroller/Gutter/Body/StateHost/PlanFinishedCard/CardBody/FinishedStats
@onready var _new_plan_button: Button = $Scroller/Gutter/Body/StateHost/PlanFinishedCard/CardBody/FinishedActions/NewPlanButton
@onready var _repeat_button: Button = $Scroller/Gutter/Body/StateHost/PlanFinishedCard/CardBody/FinishedActions/RepeatButton

@onready var _week_strip: PanelContainer = $Scroller/Gutter/Body/WeekStrip
@onready var _streak_tile: PanelContainer = $Scroller/Gutter/Body/StatsRow/StreakTile
@onready var _flame_node: Control = $Scroller/Gutter/Body/StatsRow/StreakTile/Stack/Icon
@onready var _ring_tile: Control = $Scroller/Gutter/Body/StatsRow/RingTile
@onready var _next_up_card: PanelContainer = $Scroller/Gutter/Body/NextUpCard
@onready var _next_title: Label = $Scroller/Gutter/Body/NextUpCard/CardBody/NextTitleLabel
@onready var _next_meta: Label = $Scroller/Gutter/Body/NextUpCard/CardBody/NextMetaLabel

@onready var _rollover_timer: Timer = $DayRolloverTimer

var _state: Dictionary = {}
var _today: String = ""
var _entrance_played: bool = false

var _route_wizard: StringName = &""
var _route_player: StringName = &""
var _route_preview: StringName = &""

var _breathe: Tween = null
var _flame: Tween = null

## Guards `NOTIFICATION_THEME_CHANGED`: setting a theme override from inside that notification
## re-enters it (the override propagates a theme change to the subtree), which recursion-checks
## out at 1024 frames.
var _repainting: bool = false


func _ready() -> void:
	_route_wizard = route_named("NEW_WORKOUT_WIZARD")
	_route_player = route_named("WORKOUT_PLAYER")
	_route_preview = route_named("SESSION_PREVIEW")
	_apply_rollover_override()
	_connect_signals()
	_apply_palette()
	_flame_node.resized.connect(_on_flame_resized)
	refresh()
	_play_entrance.call_deferred()
	print("[home] ready states=5 strip=7")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		# The commonest "the phone was in a pocket overnight" path (R14 #5): re-read the clock
		# and then re-render, because the day may have changed while the app was asleep.
		var _changed := _check_rollover("resumed")
		refresh_from("resumed")
	elif what == NOTIFICATION_THEME_CHANGED:
		# A theme swap can arrive before this scene's `_ready` has resolved its nodes, and it
		# arrives again for every override this subtree sets — hence the re-entrancy guard.
		if _repainting or not is_node_ready():
			return
		_repainting = true
		_apply_palette()
		_render(_state, {}, false)
		_repainting = false


# ------------------------------------------------------------------ refresh triggers (R14)

## Recomputes and re-renders. Idempotent, cheap, and callable at any time (R14).
func refresh(play_update_animations: bool = false) -> void:
	_refresh("manual", play_update_animations)


## [method refresh] with the trigger named, so the log says *why* Home re-rendered. Every signal
## slot uses this; `reason` is one of `data_changed`, `entry_added`, `plan_changed`,
## `history_changed`, `settings_changed`, `theme_changed`, `tab_changed`, `visibility`,
## `route_entered`, `returned_from_player`, `resumed`, `rollover`, `timer`, `manual`.
func refresh_from(reason: String, play_update_animations: bool = false) -> void:
	_refresh(reason, play_update_animations)


func _refresh(reason: String, play_update_animations: bool) -> void:
	if not is_inside_tree():
		return
	var built := HomeState.build(Store.plans_doc(), Store.all_entries(), Store.settings(),
		_derived(), Time.get_datetime_dict_from_system())
	_today = String(built.get("today", ""))

	# R14: "A refresh() that produces an identical state dictionary does no work beyond the
	# comparison, so the 60 s timer is free."
	var changed := built != _state
	if changed or reason != "timer":
		print("[home] refresh trigger=%s changed=%s state=%s" % [
			reason, "yes" if changed else "no", String(built.get("state", ""))])
	if not changed:
		return

	var previous := _state
	_state = built
	_render(built, previous, play_update_animations)
	_log_state(built)


## Everything [method HomeState.build] is not allowed to know: the streak, the ISO week, the
## ring's numerator/denominator and its segments — all from PRD-03 (R3/appendix §10 N4).
func _derived() -> Dictionary:
	var entries := Store.all_entries()
	var week_id := Store.current_week_id()
	var target := Store.weekly_goal_days_effective()
	return {
		"streak": Store.streak_days(),
		"week_id": week_id,
		"week_completed": Store.completed_days_in_week(week_id),
		"week_target": target,
		"week_fraction": Store.weekly_goal_progress(),
		"ring_bits": Streak.ring_segments(entries, week_id, target),
	}


func _connect_signals() -> void:
	# 1. plan/history mutations (App fans Store's signals out; connecting to both is harmless
	#    because the second refresh is a no-op comparison).
	App.data_changed.connect(_on_data_changed)
	Store.plans_changed.connect(_on_plans_changed)
	Store.history_changed.connect(_on_history_changed)
	# 2. a workout just finished — the signal PRD-10 relies on (R14 #2).
	Store.entry_added.connect(_on_entry_added)
	# 3. tab shown.
	Nav.tab_changed.connect(_on_tab_changed)
	visibility_changed.connect(_on_visibility_changed)
	# 4. settings (units, theme, weekly goal).
	App.settings_changed.connect(_on_settings_changed)
	App.theme_changed.connect(_on_theme_changed)
	# 5/6. lifecycle + day rollover.
	_rollover_timer.timeout.connect(_on_rollover_tick)
	# Buttons.
	_start_button.pressed.connect(_on_start_pressed)
	_start_button.button_down.connect(_stop_breathe)
	_preview_button.pressed.connect(_on_preview_pressed)
	_change_plan_button.pressed.connect(_on_change_plan_pressed)
	_no_plan_button.pressed.connect(_on_new_plan_pressed)
	_done_early_button.pressed.connect(_on_early_pressed)
	_done_week_button.pressed.connect(_on_week_pressed)
	_rest_early_button.pressed.connect(_on_early_pressed)
	_rest_week_button.pressed.connect(_on_week_pressed)
	_new_plan_button.pressed.connect(_on_new_plan_pressed)
	_repeat_button.pressed.connect(_on_repeat_pressed)
	_week_strip.connect(&"pressed", _on_week_strip_pressed)
	_focus_row.mouse_filter = Control.MOUSE_FILTER_IGNORE


# ------------------------------------------------------------------ Nav contract

## Nav calls this when Home becomes the active tab (R14 #3); PRD-10 returns here with
## `Nav.replace(Routes.HOME, {})`, which lands in this same hook.
func on_route_entered(args: Dictionary) -> void:
	if bool(args.get("returned_from_player", false)):
		_on_returned_from_player()
	refresh_from("route_entered")


## PRD-10's defensive refresh (R14 #7): the completion screen may hand back before the debounced
## store flush lands, so Home re-reads rather than trusting the `entry_added` it may have missed.
func _on_returned_from_player() -> void:
	refresh_from("returned_from_player", true)


# ------------------------------------------------------------------ signal slots

func _on_data_changed() -> void:
	refresh_from("data_changed")


func _on_plans_changed() -> void:
	# A plan was created/replaced/deleted: size and content of the screen can both change.
	refresh_from("plan_changed")


func _on_history_changed() -> void:
	refresh_from("history_changed")


func _on_entry_added(_entry: Dictionary) -> void:
	# R14 #2: emitted *before* the debounce timer fires, so Home is correct even if the app dies
	# a moment later — and the owner sees the streak, the ring and the pill update right away.
	refresh_from("entry_added", true)


func _on_tab_changed(index: int) -> void:
	if index != HOME_TAB:
		_stop_breathe()
		return
	refresh_from("tab_changed")
	_play_entrance.call_deferred()


func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		_stop_breathe()
		return
	refresh_from("visibility")
	_play_entrance.call_deferred()


func _on_settings_changed(_key: String) -> void:
	refresh_from("settings_changed")


func _on_theme_changed(_mode: String) -> void:
	# `App.set_theme_mode()` swaps the theme resource and *then* emits this, which is the only
	# trigger that reliably reaches a live screen: replacing `Window.theme` does not deliver
	# `NOTIFICATION_THEME_CHANGED` to descendants in 4.7.2 (measured; see day_pill.gd). The
	# background, the streak flame's accent and every chip are re-tokenised here, and the state
	# is re-rendered directly rather than through [method refresh], whose unchanged-state
	# short-circuit would skip the repaint entirely.
	_apply_palette()
	# The repaint runs under the same re-entrancy guard as the notification branch: the
	# `add_theme_*_override()` calls below notify this node's subtree synchronously, and without
	# the guard that cascade re-enters `_render` (measured: it recursion-checks out at 1024
	# frames).
	if not _state.is_empty() and not _repainting:
		_repainting = true
		_render(_state, {}, false)
		_repainting = false
	refresh_from("theme_changed")


func _on_rollover_tick() -> void:
	var _changed := _check_rollover("timer")


## R14 #6/#5: the local date changed under us, so re-render for the new day. Returns true when
## it did.
func _check_rollover(trigger: String) -> bool:
	var system_today := Time.get_date_string_from_system()
	if _today.is_empty():
		_today = system_today
		return false
	if system_today == _today:
		return false
	print("[home] rollover trigger=%s from=%s to=%s" % [trigger, _today, system_today])
	_today = system_today
	refresh_from("rollover")
	return true


# ------------------------------------------------------------------ rendering

func _render(built: Dictionary, previous: Dictionary, play: bool) -> void:
	if built.is_empty() or not is_node_ready():
		return
	_render_greeting(built)
	_render_state(built)
	_render_today(built)
	_render_done(built)
	_render_rest(built)
	_render_finished(built)
	_render_week_strip(built, previous, play)
	_render_stats(built, previous, play)
	_render_next_up(built)


func _render_greeting(built: Dictionary) -> void:
	# PRD-00 §4.3's signature line: always, exactly, "Hey Workout".
	_sub_greeting.text = String(built.get("greeting", ""))


## Exactly one StateHost child is visible (R10–R13).
func _render_state(built: Dictionary) -> void:
	var state := String(built.get("state", HomeState.NO_PLAN))
	_no_plan_card.visible = state == HomeState.NO_PLAN
	_today_card.visible = state == HomeState.TRAINING
	_done_card.visible = state == HomeState.DONE_TODAY
	_rest_card.visible = state == HomeState.REST
	_finished_card.visible = state == HomeState.PLAN_FINISHED


func _render_today(built: Dictionary) -> void:
	if String(built.get("state", "")) != HomeState.TRAINING:
		_stop_breathe()
		return
	var plan: Dictionary = built.get("plan", {})
	var session: Dictionary = built.get("session", {})
	if session.is_empty():
		return

	var weekday := PlanSchedule.weekday_name(PlanSchedule.weekday_iso(String(built.get("today", ""))))
	_day_badge.text = weekday.to_upper()
	_render_source_badge(plan)

	_session_title.text = String(session.get("title", ""))
	_render_focus(session)

	var session_id := String(session.get("id", ""))
	var progress := _progress_for(session_id)
	var meta := "%d exercises · %d min" % [_blocks_of(session).size(),
		_int_of(session.get("est_minutes", 0))]
	if not progress.is_empty():
		var counts := _progress_counts(progress)
		meta += " · %d of %d done" % [counts.x, counts.y]
		_start_button.text = "Resume workout"
	else:
		_start_button.text = "Start workout"
	_meta_row.text = meta
	_start_breathe()


## R5: a fallback plan is labelled honestly on the cover too, with PRD-08's component.
func _render_source_badge(plan: Dictionary) -> void:
	if _source_badge == null or not _source_badge.has_method(&"set_source"):
		return
	var source := String(plan.get("source", ""))
	var provider := ""
	if source == "llm":
		var key := String(plan.get("provider", ""))
		if not key.is_empty() and LLMProviders.has(key):
			provider = LLMProviders.label_for(key)
	_source_badge.call(&"set_source", source, provider)


## R5: one chip per focus area; more than three collapses into a muted `+N`.
func _render_focus(session: Dictionary) -> void:
	for child in _focus_row.get_children():
		_focus_row.remove_child(child)
		child.queue_free()
	var focus := _string_array_of(session.get("focus", []))
	var shown := mini(focus.size(), MAX_FOCUS_CHIPS)
	for index in shown:
		_focus_row.add_child(_make_chip(Taxonomy.label(focus[index])))
	if focus.size() > shown:
		_focus_row.add_child(_make_chip("+%d" % (focus.size() - shown)))


func _render_done(built: Dictionary) -> void:
	if String(built.get("state", "")) != HomeState.DONE_TODAY:
		return
	var entry: Dictionary = built.get("done_entry", {})
	var title := String(entry.get("session_title", ""))
	if title.is_empty():
		title = "today's session"
	_done_body.text = "You finished %s in %d min." % [title, int(built.get("done_minutes", 0))]
	var label := String(built.get("early_label", ""))
	_done_early_button.text = label
	_done_early_button.visible = bool(built.get("early_available", false)) and not label.is_empty()


func _render_rest(built: Dictionary) -> void:
	if String(built.get("state", "")) != HomeState.REST:
		return
	_rest_body.text = "Nothing planned today. Recovery is part of the plan — your next session is %s." % String(
		built.get("next_weekday_name", ""))
	var label := String(built.get("early_label", ""))
	_rest_early_button.text = label
	_rest_early_button.visible = bool(built.get("early_available", false)) and not label.is_empty()


func _render_finished(built: Dictionary) -> void:
	if String(built.get("state", "")) != HomeState.PLAN_FINISHED:
		return
	var plan: Dictionary = built.get("plan", {})
	_finished_body.text = "You finished every session in %s — %d weeks of it." % [
		String(plan.get("name", "this plan")), int(built.get("cycles", 0))]
	_finished_stats.text = "%d sessions · %d min total" % [
		int(built.get("total_sessions", 0)),
		floori(float(int(built.get("total_duration_sec", 0))) / 60.0)]


func _render_week_strip(built: Dictionary, previous: Dictionary, play: bool) -> void:
	var strip := _strip_of(built)
	if strip.is_empty():
		return
	_week_strip.call(&"set_week", strip)
	if not play or previous.is_empty():
		return
	# R15: pulse the pill that just became done.
	var before := _strip_of(previous)
	for index in strip.size():
		var kind := String(strip[index].get("kind", ""))
		var was := "" if index >= before.size() else String(before[index].get("kind", ""))
		if kind == HomeState.KIND_DONE and was != HomeState.KIND_DONE:
			_week_strip.call(&"pulse_date", String(strip[index].get("date", "")))


## R7/R8: the streak tile and the weekly ring, both fed from PRD-03's numbers.
func _render_stats(built: Dictionary, previous: Dictionary, play: bool) -> void:
	var streak := int(built.get("streak", 0))
	var was := streak if previous.is_empty() else int(previous.get("streak", 0))
	_streak_tile.call(&"set_stat", HomeState.STREAK_TITLE, str(streak), &"flame")
	_style_flame(streak)
	if play and not previous.is_empty() and streak > was:
		_count_up_streak(was, streak)

	_ring_tile.call(&"set_week", int(built.get("week_completed", 0)),
		int(built.get("week_target", 0)), float(built.get("week_fraction", 0.0)),
		_bits_of(built))


## R7: the flame is `warning` while a streak is alive and `text_disabled` at zero, "so a zero
## streak never looks like an error"; from three days on it breathes (R15).
func _style_flame(streak: int) -> void:
	var mode := App.theme_mode
	var token := "warning" if streak > 0 else "text_disabled"
	_flame_node.add_theme_color_override(&"color", DesignTokens.accent_text(mode, token))
	if streak >= FLAME_MIN_STREAK and _motion_enabled() and is_visible_in_tree():
		if _flame == null or not _flame.is_valid():
			_flame = create_tween().set_loops()
			_flame.tween_property(_flame_node, "scale", Vector2(1.04, 1.04), 0.9) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			_flame.tween_property(_flame_node, "scale", Vector2.ONE, 0.9) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	elif _flame != null and _flame.is_valid():
		_flame.kill()
		_flame_node.scale = Vector2.ONE


## R7's icon is 32×32; the scale animation must grow from its centre, and the first layout pass
## is the only moment its size becomes real.
func _on_flame_resized() -> void:
	_flame_node.pivot_offset = _flame_node.size * 0.5


func _count_up_streak(from: float, to: float) -> void:
	if not _motion_enabled():
		return
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_method(_set_streak_value, from, to, 0.5)


func _set_streak_value(value: float) -> void:
	_streak_tile.call(&"set_stat", HomeState.STREAK_TITLE, str(roundi(value)), &"flame")


## R9's next-up card; hidden entirely in `NO_PLAN` and `PLAN_FINISHED`.
func _render_next_up(built: Dictionary) -> void:
	var state := String(built.get("state", ""))
	var session: Dictionary = built.get("next_session", {})
	var show_card := state != HomeState.NO_PLAN and state != HomeState.PLAN_FINISHED \
		and not session.is_empty()
	_next_up_card.visible = show_card
	if not show_card:
		return
	_next_title.text = String(session.get("title", ""))
	_next_meta.text = "%s · %d exercises · %d min" % [
		String(built.get("next_weekday_name", "")), _blocks_of(session).size(),
		_int_of(session.get("est_minutes", 0))]


# ------------------------------------------------------------------ buttons

func _on_start_pressed() -> void:
	var plan: Dictionary = _state.get("plan", {})
	var session: Dictionary = _state.get("session", {})
	if plan.is_empty() or session.is_empty():
		return
	var session_id := String(session.get("id", ""))
	var args := {
		"plan_id": String(plan.get("id", "")),
		"session_id": session_id,
	}
	# R5: an in-flight session is resumed, and the two screens can never disagree about whether
	# one exists because both ask `Store.load_session_progress()`.
	if not _progress_for(session_id).is_empty():
		args["resume"] = true
	Nav.push(_route_player, args)


## R11/R12's "do the next session early": PRD-10 records it with **today's** date, and the cycle
## index advances by itself because `done_in_cycle` grew.
func _on_early_pressed() -> void:
	var plan: Dictionary = _state.get("plan", {})
	var session: Dictionary = _state.get("next_session", {})
	if plan.is_empty() or session.is_empty():
		return
	Nav.push(_route_player, {
		"plan_id": String(plan.get("id", "")),
		"session_id": String(session.get("id", "")),
		"early": true,
	})


func _on_preview_pressed() -> void:
	var plan: Dictionary = _state.get("plan", {})
	var session: Dictionary = _state.get("session", {})
	if plan.is_empty() or session.is_empty():
		return
	Nav.push(_route_preview, {
		"plan_id": String(plan.get("id", "")),
		"session_id": String(session.get("id", "")),
	})


func _on_change_plan_pressed() -> void:
	Nav.push(_route_wizard, {"restart": false, "entry": "home"})


func _on_new_plan_pressed() -> void:
	var entry := "home" if String(_state.get("state", "")) == HomeState.NO_PLAN else "plan_finished"
	Nav.push(_route_wizard, {"restart": true, "entry": entry})


func _on_week_pressed() -> void:
	Nav.goto_tab(PLAN_TAB)


## The frozen `week_strip` API reports the tapped date (appendix §3.2); v1's behaviour is that
## any tap opens the Plan tab (R6), where the week lives in detail.
func _on_week_strip_pressed(_date: String) -> void:
	Nav.goto_tab(PLAN_TAB)


## R13's "Repeat this plan": a copy under a fresh id, made active, so `done_in_cycle` restarts at
## 0 and every completed entry stays exactly where it is.
func _on_repeat_pressed() -> void:
	var plan: Dictionary = _state.get("plan", {})
	if plan.is_empty():
		return
	var plan_name := String(plan.get("name", ""))
	var copy := Store.duplicate_plan(plan,
		"%s (repeat %d)" % [plan_name, _repeat_count(plan_name) + 2])
	if copy.is_empty():
		Feedback.toast("Could not repeat this plan", &"danger")
		return
	var activated := Store.set_active_plan(String(copy.get("id", "")))
	if activated:
		Feedback.toast("Plan repeated", &"success")
	else:
		Feedback.toast("Could not repeat this plan", &"danger")
	refresh_from("repeat_plan")


# ------------------------------------------------------------------ motion (R15)

## The five `Body` blocks, in stagger order.
func _animated_blocks() -> Array[Control]:
	var out: Array[Control] = []
	for child in _body.get_children():
		if child is Control:
			out.append(child as Control)
	return out


## R15: the first open of the tab this session fades and rises each block, staggered 40 ms.
## Skipped entirely under `ui.reduce_motion` (decorative motion is skipped, not shortened).
func _play_entrance() -> void:
	if _entrance_played or not is_visible_in_tree() or not is_inside_tree():
		return
	_entrance_played = true
	var blocks := _animated_blocks()
	if not _motion_enabled():
		for block in blocks:
			block.modulate.a = 1.0
		return
	var stagger := float(DesignTokens.MOTION["stagger_ms"]) / 1000.0
	var duration := float(ENTRANCE_MS) / 1000.0
	for index in blocks.size():
		var block := blocks[index]
		var base_y := block.position.y
		block.modulate.a = 0.0
		block.position.y = base_y + ENTRANCE_RISE
		var tween := create_tween()
		tween.set_trans(Tween.TRANS_CUBIC)
		tween.set_ease(Tween.EASE_OUT)
		tween.tween_interval(stagger * float(index))
		tween.tween_property(block, "modulate:a", 1.0, duration)
		tween.parallel().tween_property(block, "position:y", base_y, duration)


## R15's Start-button breathe, only while `TRAINING` and only before the session starts. Tappable
## from the first frame either way — motion never gates input.
func _start_breathe() -> void:
	if not _motion_enabled() or not is_visible_in_tree():
		return
	if _breathe != null and _breathe.is_valid():
		return
	_breathe = create_tween().set_loops()
	_breathe.tween_property(_start_button, "scale", Vector2(1.012, 1.012), 1.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_breathe.tween_property(_start_button, "scale", Vector2.ONE, 1.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## Stopped on press and whenever Home leaves `TRAINING`, so it can never fight the press-scale
## affordance `tappable_button.gd` owns (appendix §4.3 rule 3).
func _stop_breathe() -> void:
	if _breathe != null and _breathe.is_valid():
		_breathe.kill()
	_breathe = null
	_start_button.scale = Vector2.ONE


## `Motion.decorative_enabled()` (appendix §4.4) lives with PRD-12's accessibility work; until
## then the setting it reads is the same one.
func _motion_enabled() -> bool:
	return not bool(App.get_setting("ui.reduce_motion", false))


# ------------------------------------------------------------------ logging (AC4–AC10)

## The greppable state lines the PRD's acceptance criteria read (AC4–AC8, AC10).
func _log_state(built: Dictionary) -> void:
	var plan: Dictionary = built.get("plan", {})
	var session: Dictionary = built.get("session", {})
	print("[home] state=%s session=%s index=%d streak=%d ring=%d/%d today=%s plan=%s" % [
		String(built.get("state", "")),
		_session_id(session),
		int(built.get("session_index", 0)),
		int(built.get("streak", 0)),
		int(built.get("week_completed", 0)),
		int(built.get("week_target", 0)),
		String(built.get("today", "")),
		_session_id(plan)])
	print("[home] greeting=\"%s\"" % String(built.get("greeting", "")))
	var kinds := PackedStringArray()
	for day in _strip_of(built):
		kinds.append(_kind_of(day))
	print("[home] strip=%s" % ",".join(kinds))
	print("[home] ring=%d/%d fraction=%.2f target=%d" % [
		int(built.get("week_completed", 0)), int(built.get("week_target", 0)),
		float(built.get("week_fraction", 0.0)), int(built.get("week_target", 0))])
	var next: Dictionary = built.get("next_session", {})
	if not next.is_empty():
		print("[home] next=%s ahead=%d weekday=%s" % [_session_id(next),
			int(built.get("next_days_ahead", 0)), String(built.get("next_weekday_name", ""))])


# ------------------------------------------------------------------ helpers

## The one visible `StateHost` card, or `null`. AC5's "exactly one state card is visible" check
## and the desktop probe read this rather than guessing from screenshots.
func visible_state_card() -> PanelContainer:
	for child in _state_host.get_children():
		if child is PanelContainer and (child as PanelContainer).visible:
			return child as PanelContainer
	return null


## The visible state card's node name (`TodayCard`, `RestDayCard`, …), or `""`.
func state_card_name() -> String:
	var card := visible_state_card()
	return "" if card == null else String(card.name)


## The state dictionary Home last rendered — the probe compares the screen against it.
func current_state() -> Dictionary:
	return _state


## Resolves a route constant out of the frozen route table, falling back to the appendix §2 route
## name. Binding through the table (rather than hard-coding a `StringName`) means Home picks up
## the real value the moment PRD-08/PRD-10 add the constant — with no edit here and no dependency
## on a file another PRD is still writing.
static func route_named(constant_name: String) -> StringName:
	var script: Script = load(ROUTES_PATH)
	if script != null:
		var constants: Dictionary = script.get_script_constant_map()
		var value: Variant = constants.get(constant_name, null)
		if value is StringName:
			return value
		if value is String:
			return StringName(value)
	return StringName(ROUTE_FALLBACKS.get(constant_name, ""))


func _apply_palette() -> void:
	if not is_node_ready():
		return
	_background.color = DesignTokens.color(App.theme_mode, "bg")


## A small read-only chip for the focus row (radius 12, `surface_alt`, `Caption` text). Built
## from the theme's chip surface rather than a new stylebox, and never interactive — a chip in a
## summary row must not eat the touch target of the card's buttons.
func _make_chip(text: String) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.theme_type_variation = &"Toast"
	chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.theme_type_variation = &"Caption"
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(label)
	return chip


## The in-flight session record for [param session_id], or `{}`. `Store` already discards a
## record older than `STALE_PROGRESS_HOURS` (12 h, appendix R28 — not R5's prose "24 h") or one
## whose ids no longer resolve, so the two screens cannot disagree.
func _progress_for(session_id: String) -> Dictionary:
	if session_id.is_empty():
		return {}
	var progress := Store.load_session_progress()
	if progress.is_empty():
		return {}
	if String(progress.get("session_id", "")) != session_id:
		return {}
	return progress


## `Vector2i(done, total)` set counts out of a progress record's `set_states`.
func _progress_counts(progress: Dictionary) -> Vector2i:
	var done := 0
	var total := 0
	var raw: Variant = progress.get("set_states", null)
	if raw is Dictionary:
		for key in (raw as Dictionary):
			var value: Variant = (raw as Dictionary)[key]
			if not (value is Array):
				continue
			var flags: Array = value
			total += flags.size()
			for flag in flags:
				if bool(flag):
					done += 1
	return Vector2i(done, total)


## How many times this plan has already been repeated, from R13's own name suffix.
func _repeat_count(plan_name: String) -> int:
	var count := 0
	var cursor := plan_name.find(REPEAT_MARKER)
	while cursor >= 0:
		count += 1
		cursor = plan_name.find(REPEAT_MARKER, cursor + REPEAT_MARKER.length())
	return count


## PRD-09's `--rollover-timer=<sec>` debug flag (AC10). Honoured only in a debug build, and only
## over a sane range, so a release build can never be talked out of its 60 s poll.
func _apply_rollover_override() -> void:
	if not OS.is_debug_build():
		return
	var seconds := _cmdline_value("--rollover-timer=")
	if seconds <= 0:
		return
	_rollover_timer.wait_time = float(clampi(seconds, 1, 3600))
	print("[home] rollover_timer=%.1fs" % _rollover_timer.wait_time)


static func _cmdline_value(prefix: String) -> int:
	var sources: Array[PackedStringArray] = [OS.get_cmdline_args(), OS.get_cmdline_user_args()]
	for source in sources:
		for argument in source:
			if argument.begins_with(prefix):
				var raw := argument.substr(prefix.length())
				if raw.is_valid_int():
					return int(raw)
	return 0


static func _blocks_of(session: Dictionary) -> Array:
	var raw: Variant = session.get("blocks", [])
	return raw if raw is Array else []


static func _string_array_of(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array:
		for element in (value as Array):
			out.append(String(element))
	elif value is PackedStringArray:
		out.append_array(value)
	return out


static func _strip_of(built: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = built.get("week_strip", null)
	if raw is Array:
		for element in (raw as Array):
			if element is Dictionary:
				out.append(element)
	return out


static func _bits_of(built: Dictionary) -> PackedByteArray:
	var raw: Variant = built.get("ring_bits", null)
	return raw if raw is PackedByteArray else PackedByteArray()


static func _session_id(record: Dictionary) -> String:
	return String(record.get("id", ""))


static func _kind_of(day: Dictionary) -> String:
	return String(day.get("kind", ""))


static func _int_of(value: Variant) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	return 0
