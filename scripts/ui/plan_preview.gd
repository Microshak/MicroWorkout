extends Control
## PRD-08 R11–R15 — the generated-week preview.
##
## Distinct from PRD-09's `SessionPreview` (`Routes.SESSION_PREVIEW`), which shows **one**
## session and belongs to Home. This screen shows the whole generated week, says who wrote it,
## and is the only place a plan is written to the device.
##
## Decisions worth knowing before editing:
##
## * **Nothing is saved until `Save plan`.** There is deliberately no "Discard" button because
##   nothing has been written; leaving discards the in-memory plan and nothing else.
## * **`Edit answers` re-enters the wizard with the full state as route arguments.** The frozen
##   `Nav` frees the screen below on every push (appendix §1.5), so R12's "the wizard stays on the
##   stack below" is not how this engine behaves; the state therefore travels as an additive
##   `state`/`step` argument pair, which is also the only way the goal — never persisted — survives
##   the round trip.
## * **The id is assigned here, not by the generator.** R14 requires uniqueness across `plans[]`
##   including archived plans, so the preview picks `plan-<unix>` (with a `-2`/`-3` suffix on a
##   same-second collision) immediately before writing.
## * **Regeneration never falls back to a second request shape**: it resends the very dictionary
##   the wizard sent, with `seed + 1` (R13).
## * **History is never touched.** The preview only calls `Store.upsert_plan()` and
##   `Store.set_active_plan()`; no delete, no migration, no rewrite.

const FIXABLE_REASONS: PackedStringArray = ["auth", "forbidden", "no_key", "bad_path"]

## R11's copy.
const REASON_LLM := "Built from what you told the AI."
const REASON_UNMAPPED := "This came from the built-in generator. It always works."
const FIX_BUTTON := "Fix in Settings"
const FALLBACK_PROVIDER := "your AI provider"

## R13's toasts and hint, verbatim.
const TOAST_NEW_VERSION := "New version ready."
const TOAST_AI_BACK := "The AI is back — this one is AI-personalized."
const TOAST_FELL_BACK := "Falling back to the built-in generator."
const REGENERATE_HINT := "Regenerating only changes the exercise order and picks. " \
	+ "Use Edit answers to change the goal, days, or length."
const REGENERATE_HINT_FROM := 4

## R14's toast for a replacement (R15's save message is used when there is no plan to replace).
const TOAST_REPLACED := "Plan replaced."

## R15's copy, verbatim.
const SAVE_LABEL := "Save plan"
const SAVING_LABEL := "Saving…"
const SAVE_TOAST := "Plan saved — %d days a week, %d min"
const SAVE_FAILED_TOAST := "Couldn't save to this device. Your plan is still here — try again."

## R10's two non-fallback toasts, reused from the wizard's table so both screens say the same
## thing about the same outcome.
const CANCELLED_TOAST := "Cancelled — nothing was saved."
const BUSY_TOAST := "Still working on the last one — give it a second."

## R17's day-card entrance: 40 ms per card, capped at `MOTION.stagger_max`, 220 ms each.
const CARD_ENTER_SEC := 0.22
const CARD_RISE := 16.0

const OVERLAY_FADE_MS := 180
const OVERLAY_MIN_MS := 600

const GeneratingOverlayScript := preload("res://scripts/ui/generating_overlay.gd")
const DAY_CARD_SCENE := preload("res://scenes/components/day_card.tscn")

@onready var _bg: ColorRect = $Background
@onready var _back_button: Button = $SafeArea/Layout/Header/BackButton
@onready var _name_label: Label = $SafeArea/Layout/Header/PlanNameLabel
@onready var _badge: PanelContainer = $SafeArea/Layout/Header/BadgeHost/SourceBadge
@onready var _badge_host: Control = $SafeArea/Layout/Header/BadgeHost
@onready var _meta_label: Label = $SafeArea/Layout/MetaRow/MetaLabel
@onready var _reason_label: Label = $SafeArea/Layout/ReasonLabel
@onready var _reason_action: Button = $SafeArea/Layout/ReasonAction
@onready var _regen_hint: Label = $SafeArea/Layout/RegenerateHintLabel
@onready var _scroller: ScrollContainer = $SafeArea/Layout/WeekScroller
@onready var _day_list: VBoxContainer = $SafeArea/Layout/WeekScroller/DayList
@onready var _save_button: Button = $SafeArea/Layout/Actions/SaveButton
@onready var _regenerate_button: Button = $SafeArea/Layout/Actions/RegenerateButton
@onready var _keep_previous_button: Button = $SafeArea/Layout/Actions/KeepPreviousButton
@onready var _edit_answers_button: Button = $SafeArea/Layout/Actions/EditAnswersButton
@onready var _replace_dialog: ConfirmationDialog = $ReplaceDialog
@onready var _overlay: GeneratingOverlayScript = $GeneratingOverlay
@onready var _gen_timer: Timer = $GenTimer

var _plan: Dictionary = {}
var _previous_plan: Dictionary = {}
var _result: Dictionary = {}
var _previous_result: Dictionary = {}
var _request: Dictionary = {}
var _state_full: Dictionary = {}
var _entry: String = "home"

var _day_cards: Array[Control] = []
var _regen_count: int = 0
var _busy: bool = false
var _saving: bool = false
var _replacing: bool = false
var _elapsed_base_ms: int = 0


# ===========================================================================
# Lifecycle
# ===========================================================================

func _ready() -> void:
	_bg.color = DesignTokens.color(App.theme_mode, "bg")
	if not App.theme_changed.is_connected(_on_theme_changed):
		App.theme_changed.connect(_on_theme_changed)

	_back_button.pressed.connect(_on_back_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_regenerate_button.pressed.connect(_on_regenerate_pressed)
	_keep_previous_button.pressed.connect(_on_keep_previous_pressed)
	_edit_answers_button.pressed.connect(_on_edit_answers_pressed)
	_reason_action.pressed.connect(_on_fix_in_settings_pressed)

	_style_dialog(_replace_dialog)
	_replace_dialog.confirmed.connect(_perform_save)
	_gen_timer.timeout.connect(_on_generation_tick)
	_gen_timer.stop()

	_reason_action.text = FIX_BUTTON
	_regen_hint.text = REGENERATE_HINT

	Nav.set_back_handling(false)
	_refresh()


func _exit_tree() -> void:
	# Same hand-back rule as the wizard: never re-arm Nav while another wizard-flow screen is
	# still on the stack, because that screen owns the gesture.
	var current := Nav.current_route()
	if current != Routes.NEW_WORKOUT_WIZARD and current != Routes.PLAN_PREVIEW:
		Nav.set_back_handling(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_pressed()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_back_pressed()


# ===========================================================================
# R12 — entry
# ===========================================================================

## Nav calls this after `add_child`. [param args]:
##   `plan: Dictionary`       — the generated plan (required).
##   `state: Dictionary`      — the wizard's draft-shaped answers, for the meta row.
##   `state_full: Dictionary` — additive: every answer including the goal, so `Edit answers`
##                              can hand the wizard back a complete state.
##   `request: Dictionary`    — additive: the exact request that produced this plan, which is
##                              what R13's regeneration resends with `seed + 1`.
##   `result: Dictionary`     — PRD-07's result, for the badge and the reason line.
##   `entry: String`          — the wizard's log tag, carried through unchanged.
func setup(args: Dictionary) -> void:
	_plan = _as_dictionary(args.get("plan"))
	_result = _as_dictionary(args.get("result"))
	_state_full = _as_dictionary(args.get("state_full"))
	if _state_full.is_empty():
		_state_full = _as_dictionary(args.get("state"))
	_request = _as_dictionary(args.get("request"))
	_entry = PlanModel.as_text(args.get("entry"), "home")
	_previous_plan = {}
	_previous_result = {}
	_regen_count = 0
	_busy = false
	_saving = false
	_keep_previous_button.visible = false
	_replace_dialog.visible = false
	_refresh()
	# One frame later, so the check measures a laid-out screen.
	_report_touch_targets.call_deferred()
	print("[preview] open sessions=%d source=%s days=%d" % [
		WizardState.plain_list(_plan.get("sessions", [])).size(),
		PlanModel.as_text(_result.get("source"), ""),
		PlanModel.as_int(_plan.get("days_per_week"), 0)])


# ===========================================================================
# Rendering
# ===========================================================================

func _refresh() -> void:
	_name_label.text = _plan_name()
	_meta_label.text = _meta_text()
	_refresh_source()
	_regen_hint.visible = _regen_count >= REGENERATE_HINT_FROM
	_save_button.text = SAVING_LABEL if _saving else SAVE_LABEL
	_rebuild_days()


## R11: the plan's own name, and when it has none, the same `"<N>-Day <split>"` shape
## `Generator` builds — never a blank card, never a rename of a name the model chose.
func _plan_name() -> String:
	var plan_name := PlanModel.as_text(_plan.get("name"), "")
	if not plan_name.is_empty():
		return plan_name
	var days := PlanModel.as_int(_plan.get("days_per_week"), 0)
	var split := PlanModel.as_text(_plan.get("split_name"), "")
	if split.is_empty():
		return "%d-Day plan" % days
	return "%d-Day %s" % [days, split]


## R12's meta row: `"4 days · 40 min · Hypertrophy"`. The goal title comes from the plan, so a
## plan restored from history shows the goal it was actually built for.
func _meta_text() -> String:
	var goal := WizardState.title_for_goal(PlanModel.as_text(_plan.get("goal"), ""))
	if goal.is_empty():
		goal = WizardState.title_for_goal(PlanModel.as_text(_state_full.get("goal"), ""))
	if goal.is_empty():
		return "%d days · %d min" % [
			PlanModel.as_int(_plan.get("days_per_week"), 0),
			PlanModel.as_int(_plan.get("duration_min"), 0),
		]
	return "%d days · %d min · %s" % [
		PlanModel.as_int(_plan.get("days_per_week"), 0),
		PlanModel.as_int(_plan.get("duration_min"), 0),
		goal,
	]


## R11: the badge reuses PRD-07's own strings, and the reason line is PRD-07's own
## `user_message` on the fallback path — this screen adds no copy of its own and never
## re-diagnoses the cause.
func _refresh_source() -> void:
	var source := PlanModel.as_text(_result.get("source"), "")
	var reason := PlanModel.as_text(_result.get("reason_code"), "")
	_badge.call(&"set_source", source, _provider_name())
	_badge_host.visible = _badge.visible

	var line := ""
	if source == "llm":
		line = REASON_LLM
	elif source == "builtin":
		line = PlanModel.as_text(_result.get("user_message"), "")
		if line.is_empty():
			line = REASON_UNMAPPED
			print("[wizard] unmapped reason_code=%s" % reason)
	_reason_label.text = line
	_reason_label.visible = not line.is_empty()
	_reason_action.visible = source == "builtin" and FIXABLE_REASONS.has(reason)


## PRD-07's provider display name for a plan.
func _provider_name() -> String:
	var provider := PlanModel.as_text(_plan.get("provider"), "")
	if provider.is_empty():
		return FALLBACK_PROVIDER
	if provider == "custom":
		var named := PlanModel.as_text(Store.get_setting("llm.custom_name", ""), "").strip_edges()
		if not named.is_empty():
			return named
	return LLMProviders.label_for(provider)


## One `day_card` per session, in plan order (R12). Day *numbers*, not weekday names: the
## weekday mapping is PRD-09's decision (PRD-08 §10 note N3).
func _rebuild_days() -> void:
	for child in _day_list.get_children():
		_day_list.remove_child(child)
		child.queue_free()
	_day_cards.clear()

	var sessions := WizardState.plain_list(_plan.get("sessions", []))
	for i in sessions.size():
		var session: Dictionary = sessions[i] if sessions[i] is Dictionary else {}
		var card: Control = DAY_CARD_SCENE.instantiate()
		card.name = "DayCard%d" % (i + 1)
		_day_list.add_child(card)
		card.call(&"set_day", session, &"upcoming", "")
		card.connect(&"pressed", _on_day_pressed)
		_day_cards.append(card)
		_enter_card(card, i)
	if _scroller != null:
		_scroller.scroll_vertical = 0


## R17's entrance: 40 ms of stagger per card (capped, appendix §4.4), 220 ms each, skipped
## entirely under `ui.reduce_motion`.
func _enter_card(card: Control, index: int) -> void:
	if not _motion_enabled():
		card.modulate.a = 1.0
		card.position.y = 0.0
		return
	card.modulate.a = 0.0
	card.position.y = CARD_RISE
	var stagger_ms := int(DesignTokens.MOTION["stagger_ms"])
	var stagger_max := int(DesignTokens.MOTION["stagger_max"])
	var delay := float(mini(index, stagger_max) * stagger_ms) / 1000.0
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	if delay > 0.0:
		tween.tween_interval(delay)
	tween.tween_property(card, "modulate:a", 1.0, CARD_ENTER_SEC)
	tween.parallel().tween_property(card, "position:y", 0.0, CARD_ENTER_SEC)


## R12: one accordion open at a time. The card has already opened itself by the time this runs,
## so every *other* card is closed.
func _on_day_pressed(session_id: String) -> void:
	for card in _day_cards:
		if not is_instance_valid(card):
			continue
		if PlanModel.as_text(card.call(&"session_id"), "") != session_id:
			card.call(&"set_expanded", false)


func _on_theme_changed(mode: String) -> void:
	_bg.color = DesignTokens.color(mode, "bg")


# ===========================================================================
# R13 — regenerate / edit-and-retry
# ===========================================================================

func _on_regenerate_pressed() -> void:
	if _busy or _saving or _plan.is_empty():
		return
	if LLM.is_generating:
		Feedback.toast(BUSY_TOAST)
		return

	var previous_source := PlanModel.as_text(_result.get("source"), "")
	var request := _next_request()
	_begin_generation()

	var started := Time.get_ticks_msec()
	var result: Dictionary = await LLM.generate_plan(request, {
		"seed": PlanModel.as_int(request.get("seed"), 0),
	})
	await _hold_overlay_open(started)
	await _end_generation()

	var source := PlanModel.as_text(result.get("source"), "")
	var reason := PlanModel.as_text(result.get("reason_code"), "")
	print("[wizard] regenerate source=%s reason_code=%s attempts=%d elapsed_ms=%d" % [
		source, reason, PlanModel.as_int(result.get("attempts"), 0),
		Time.get_ticks_msec() - started])

	if reason == "cancelled":
		print("[wizard] regenerate cancelled")
		Feedback.toast(CANCELLED_TOAST)
		return
	if reason == "busy":
		Feedback.toast(BUSY_TOAST)
		return

	var plan: Variant = result.get("plan", {})
	if not bool(result.get("ok", false)) or source.is_empty() \
			or not (plan is Dictionary) or (plan as Dictionary).is_empty():
		var message := PlanModel.as_text(result.get("user_message"), "")
		Feedback.toast(message if not message.is_empty() else REASON_UNMAPPED, &"warning")
		return

	# One level of undo: a second regeneration overwrites the previous version (R13).
	_previous_plan = _plan
	_previous_result = _result
	_plan = plan as Dictionary
	_result = result
	_request = request
	_regen_count += 1
	_keep_previous_button.visible = true
	_refresh()

	if previous_source != "llm" and source == "llm":
		Feedback.toast(TOAST_AI_BACK)
	elif previous_source == "llm" and source == "builtin":
		Feedback.toast(TOAST_FELL_BACK)
	else:
		Feedback.toast(TOAST_NEW_VERSION)


func _on_keep_previous_pressed() -> void:
	if _previous_plan.is_empty() or _busy:
		return
	var swapped := _plan
	_plan = _previous_plan
	_previous_plan = swapped
	var swapped_result := _result
	_result = _previous_result
	_previous_result = swapped_result
	_keep_previous_button.visible = false
	_refresh()


func _on_edit_answers_pressed() -> void:
	_return_to_wizard(WizardState.STEP_REVIEW)


## R12: back returns to the wizard with every answer intact and never discards the plan — the
## plan was never saved, so there is nothing to discard.
func _on_back_pressed() -> void:
	if _replace_dialog.visible:
		_replace_dialog.hide()
		return
	_return_to_wizard(WizardState.STEP_REVIEW)


## The frozen `Nav` frees the screen below on push (appendix §1.5), so the wizard cannot simply
## be popped back to with its memory intact. `replace` keeps the stack at one entry and the full
## state — including the goal, which is never persisted — travels as arguments.
func _return_to_wizard(step: int) -> void:
	if _busy or _saving:
		return
	Nav.replace(Routes.NEW_WORKOUT_WIZARD, {
		"restart": false,
		"entry": _entry,
		"state": _state_full,
		"step": step,
	})


## R13: the same request, `seed + 1`. When the wizard did not pass its request along, the shape
## is rebuilt from the plan itself, which carries every field the request had.
func _next_request() -> Dictionary:
	var request := _request.duplicate(true)
	if request.is_empty():
		request = _request_from_plan()
	request["seed"] = PlanModel.as_int(request.get("seed"), 0) + 1
	return request


func _request_from_plan() -> Dictionary:
	var state := WizardState.new()
	state.apply_full_dict({
		"goal": PlanModel.as_text(_plan.get("goal"), ""),
		"areas": _plan.get("areas", []),
		"days_per_week": PlanModel.as_int(_plan.get("days_per_week"), 4),
		"duration_min": PlanModel.as_int(_plan.get("duration_min"), 40),
		"notes": PlanModel.as_text(_plan.get("notes"), ""),
		"seed": 0,
	})
	var equipment: Array[String] = []
	for entry in WizardState.plain_list(_plan.get("equipment", [])):
		equipment.append(PlanModel.as_text(entry, ""))
	return state.to_request(equipment)


func _on_fix_in_settings_pressed() -> void:
	# R11: a nudge, never a blocker. Returning keeps the generated plan on screen because this
	# screen stays on the stack.
	Nav.push(Routes.SETTINGS, {"section": "llm"})


# ===========================================================================
# R14 / R15 — save
# ===========================================================================

func _on_save_pressed() -> void:
	if _saving or _busy or _plan.is_empty():
		return
	_replacing = not Store.active_plan_id().is_empty()
	if _replacing and _active_plan_has_completed_history():
		_replace_dialog.popup_centered()
		return
	_perform_save()


## R14: the dialog appears only when data is genuinely at risk — an active plan that already has
## a finished workout behind it.
func _active_plan_has_completed_history() -> bool:
	var active := Store.active_plan_id()
	if active.is_empty():
		return false
	for entry in Store.all_entries():
		if PlanModel.as_text(entry.get("plan_id"), "") == active \
				and bool(entry.get("completed", false)):
			return true
	return false


## R15(2): write the plan, then make it active. A failure leaves the plan in memory, the draft
## untouched and the button restored, so the owner can simply try again.
func _perform_save() -> void:
	if _saving or _plan.is_empty():
		return
	_saving = true
	_save_button.disabled = true
	_save_button.text = SAVING_LABEL

	var plan := _plan.duplicate(true)
	plan["id"] = _unique_plan_id()
	var stored := Store.upsert_plan(plan)
	if stored:
		stored = Store.set_active_plan(PlanModel.as_text(plan.get("id"), ""))

	if not stored:
		_saving = false
		_save_button.disabled = false
		_save_button.text = SAVE_LABEL
		print("[wizard] save failed error=%s" % Store.last_error())
		Feedback.toast(SAVE_FAILED_TOAST, &"danger")
		return

	_plan = plan
	var _cleared := Store.set_setting("ui.wizard_draft", {})
	var _flushed := Store.flush()
	print("[wizard] saved %s days=%d duration=%d areas=%d source=%s" % [
		PlanModel.as_text(plan.get("id"), ""),
		PlanModel.as_int(plan.get("days_per_week"), 0),
		PlanModel.as_int(plan.get("duration_min"), 0),
		WizardState.plain_list(plan.get("areas", [])).size(),
		PlanModel.as_text(plan.get("source"), "")])

	if _replacing:
		Feedback.toast(TOAST_REPLACED, &"success")
	else:
		Feedback.toast(SAVE_TOAST % [
			PlanModel.as_int(plan.get("days_per_week"), 0),
			PlanModel.as_int(plan.get("duration_min"), 0),
		], &"success")
	# R14: one fan-out so Home, PlanTab and Tracker all recompute. `App.data_changed` is declared
	# for exactly this and nothing emits it yet (PRD-03 fans out `Store.plans_changed` instead),
	# so the screen that mutates the data emits it — recorded in docs/DECISIONS.md.
	App.data_changed.emit()
	Nav.replace(Routes.HOME, {})


## R14: `plan-<unix>`, with `-2`/`-3`… on a same-second collision, unique across `plans[]`
## including archived ones. This is the *only* place a saved plan's id is chosen; the generator
## and the model choose theirs, and `Store.upsert_plan()` replaces in place on a matching id,
## which would silently overwrite a plan the owner still has.
func _unique_plan_id() -> String:
	var base := "plan-%d" % int(Time.get_unix_time_from_system())
	var taken := PackedStringArray()
	for plan in Store.all_plans():
		taken.append(PlanModel.as_text(plan.get("id"), ""))
	if not taken.has(base):
		return base
	var suffix := 2
	while suffix < 100:
		var candidate := "%s-%d" % [base, suffix]
		if not taken.has(candidate):
			return candidate
		suffix += 1
	# Unreachable in practice: 98 plans saved inside one second. Still unique, which is the
	# property that matters more than the shape.
	return "%s-%d" % [base, int(Time.get_ticks_msec())]


# ===========================================================================
# R10 (reused) — the generation overlay
# ===========================================================================

func _begin_generation() -> void:
	_busy = true
	_elapsed_base_ms = Time.get_ticks_msec()
	_save_button.disabled = true
	_regenerate_button.disabled = true
	_back_button.disabled = true
	_edit_answers_button.disabled = true
	_keep_previous_button.disabled = true
	var root := _overlay_root()
	if root != null:
		root.modulate.a = 0.0
	_overlay.start(_phase_title(0))
	_overlay.set_sub_text(_phase_sub(0))
	_gen_timer.start()
	if root == null:
		return
	if not _motion_enabled():
		root.modulate.a = 1.0
		return
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(root, "modulate:a", 1.0, float(OVERLAY_FADE_MS) / 1000.0)


func _end_generation() -> void:
	_gen_timer.stop()
	_busy = false
	_save_button.disabled = false
	_regenerate_button.disabled = false
	_back_button.disabled = false
	_edit_answers_button.disabled = false
	_keep_previous_button.disabled = false
	var root := _overlay_root()
	if root != null and _motion_enabled():
		var tween := create_tween()
		tween.set_trans(Tween.TRANS_CUBIC)
		tween.set_ease(Tween.EASE_OUT)
		tween.tween_property(root, "modulate:a", 0.0, float(OVERLAY_FADE_MS) / 1000.0)
		await tween.finished
	if _overlay != null:
		_overlay.stop()
	if root != null:
		root.modulate.a = 1.0


func _hold_overlay_open(started_ms: int) -> void:
	var remaining := OVERLAY_MIN_MS - (Time.get_ticks_msec() - started_ms)
	if remaining > 0:
		await get_tree().create_timer(float(remaining) / 1000.0).timeout


func _on_generation_tick() -> void:
	if not _busy:
		return
	var seconds := int(floorf(float(Time.get_ticks_msec() - _elapsed_base_ms) / 1000.0))
	_overlay.set_message(_phase_title(seconds))
	_overlay.set_sub_text("%s · %s" % [_phase_sub(seconds), _mmss(seconds)])


func _phase_title(seconds: int) -> String:
	if seconds > 45:
		return "Building your week on-device…"
	if seconds > 25:
		return "Double-checking the plan…"
	if seconds > 1:
		return "Writing your week…"
	return "Talking to %s…" % _configured_provider_label()


func _phase_sub(seconds: int) -> String:
	if seconds > 45:
		return "No AI needed — this always works."
	if seconds > 25:
		return "Making sure every exercise is one you can actually do."
	if seconds > 1:
		return "Personalizing from your notes and your picks."
	return "This usually takes 5–20 seconds."


func _mmss(seconds: int) -> String:
	var minutes := int(floorf(float(seconds) / 60.0))
	return "%d:%02d" % [minutes, seconds % 60]


func _configured_provider_label() -> String:
	var provider := PlanModel.as_text(
		Store.get_setting("llm.provider", LLMProviders.DEFAULT_KEY), LLMProviders.DEFAULT_KEY)
	if provider == "custom":
		var named := PlanModel.as_text(Store.get_setting("llm.custom_name", ""), "").strip_edges()
		return named if not named.is_empty() else "Custom"
	if not LLMProviders.has(provider):
		return LLMProviders.label_for(LLMProviders.DEFAULT_KEY)
	return LLMProviders.label_for(provider)


func _overlay_root() -> Control:
	if _overlay == null:
		return null
	return _overlay.get_node_or_null(^"Root") as Control


# ===========================================================================
# Internals
# ===========================================================================

func _style_dialog(dialog: ConfirmationDialog) -> void:
	var ok := dialog.get_ok_button()
	if ok != null:
		ok.theme_type_variation = &"DangerButton"
	var cancel := dialog.get_cancel_button()
	if cancel != null:
		cancel.theme_type_variation = &"SecondaryButton"
	if not dialog.about_to_popup.is_connected(_focus_dialog_cancel.bind(dialog)):
		dialog.about_to_popup.connect(_focus_dialog_cancel.bind(dialog))


func _focus_dialog_cancel(dialog: ConfirmationDialog) -> void:
	var cancel := dialog.get_cancel_button()
	if cancel != null:
		cancel.grab_focus()


static func _as_dictionary(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	return {}


func _motion_enabled() -> bool:
	if not is_inside_tree():
		return false
	return not bool(App.get_setting("ui.reduce_motion", false))


## The greppable line PRD-02 R6 requires of every screen that owns controls.
func _report_touch_targets() -> void:
	var _violations := TouchTargets.report(self)
