extends Control
## Settings tab — PRD-06 R10/R11/R12, mounted as shell tab 3 (appendix §2).
##
## Every row here writes through `App.set_setting()`, which validates against `StoreSchema` and
## then against `Store`, and every row re-reads from `App.get_setting()` — so this screen holds
## no settings state of its own and can never disagree with `settings.json`. The two rows whose
## whole point is live application (units, theme) additionally re-render from
## `App.units_changed` / `App.theme_changed`, which means the running UI repaints with no
## restart (R13).
##
## Section order and node names are fixed by R10: `Units`, `Theme`, `WeeklyGoal`, `RestTimer`,
## `AIProvider`, `Plan`, `Storage`, `Attribution`, `About`, `Danger` — all children of
## `Scroll/Gutter/Sections`, each a `card` instance (radius 18, `surface`).

const SECTIONS_PATH := "Scroll/Gutter/Sections"
const PROVIDER_SCENE := preload("res://scenes/components/provider_config_block.tscn")
const SEGMENTED_SCENE := preload("res://scenes/components/segmented_control.tscn")
const RING_SCENE := preload("res://scenes/components/progress_ring.tscn")

const GOAL_MIN := 1
const GOAL_MAX := 7
## `Plan.days_per_week` is 1..6 (appendix §6.4) while the settings goal is 1..7 (R60).
const PLAN_DAYS_MAX := 6
const REST_MIN := 15
const REST_MAX := 300
const REST_STEP := 15
const DEFAULT_DURATION_MIN := 40
## `plan-<unix>` is the appendix §5.2 id shape; the store fills in the id when it is empty, and
## the generator wants a deterministic seed, so the settings row passes the clock explicitly.
const DEFAULT_PLAN_NAME := "Built-in default plan"

const EXAMPLE_LB := 135.0
const UNITS_OPTIONS: PackedStringArray = [Units.LB, Units.KG]
const THEME_OPTIONS: PackedStringArray = ["Dark", "Light"]
const THEME_VALUES: PackedStringArray = ["dark", "light"]

@onready var _sections: VBoxContainer = $Scroll/Gutter/Sections

var _units_control: SegmentedControl = null
var _units_example: Label = null
var _theme_control: SegmentedControl = null
var _goal_value: Label = null
var _goal_hint: Label = null
var _goal_decrease: Button = null
var _goal_increase: Button = null
var _goal_ring: Control = null
var _rest_slider: HSlider = null
var _rest_value_label: Label = null
var _rest_vibrate: CheckButton = null
var _rest_sound: CheckButton = null
var _provider_block: ProviderConfigBlock = null
var _plan_button: Button = null
var _plan_status: Label = null
var _storage_label: Label = null
var _attribution_button: Button = null
var _gallery_button: Button = null
var _reset_button: Button = null
var _reset_dialog: ConfirmationDialog = null
var _reset_field: LineEdit = null
var _plan_dialog: ConfirmationDialog = null
var _goal: int = 4
var _generating: bool = false
## PRD-07 R9's debug-only `Test plan generation` row (debug builds only).
var _test_generation_button: Button = null
var _test_generation_status: Label = null
var _test_generation_dialog: AcceptDialog = null
var _test_generating: bool = false


func _ready() -> void:
	_build_units()
	_build_theme()
	_build_weekly_goal()
	_build_rest_timer()
	_build_ai_provider()
	_build_plan()
	_build_storage()
	_build_attribution()
	_build_about()
	_build_danger()

	App.units_changed.connect(_on_units_changed)
	App.theme_changed.connect(_on_theme_changed)
	App.settings_changed.connect(_on_settings_changed)
	visibility_changed.connect(_on_visibility_changed)
	if is_instance_valid(Store):
		Store.plans_changed.connect(_refresh_state)
		Store.history_changed.connect(_refresh_state)
	_refresh_state()
	# Measures the rows that are visible when this scene is loaded on its own; inside the shell
	# the tab is hidden here, so the authoritative check runs from `on_route_entered()`.
	_report_touch_targets.call_deferred()
	_publish_probe_rects.call_deferred()
	print("[settings] ready sections=%d" % _sections.get_child_count())


## Nav calls this when the tab becomes visible; the shell's touch-target check only ever sees
## the *visible* tab, so this is where this screen's controls are really measured (R6).
func on_route_entered(_args: Dictionary) -> void:
	_refresh_state()
	_report_touch_targets.call_deferred()
	_publish_probe_rects.call_deferred()


func on_route_exited() -> void:
	if _provider_block != null:
		_provider_block.cancel_test()


func _report_touch_targets() -> void:
	var _count := TouchTargets.report(self)


# ------------------------------------------------------------------ 1. units (R10/R13)

func _build_units() -> void:
	var items := _items("Units")
	_card_title(items, Strings.UNITS_SECTION)

	_units_control = SEGMENTED_SCENE.instantiate()
	_units_control.name = "UnitsControl"
	items.add_child(_units_control)
	_units_control.set_values(UNITS_OPTIONS)
	_units_control.set_options(UNITS_OPTIONS)
	_units_control.select_value(App.units())
	_units_control.selected_changed.connect(_on_units_selected)

	_units_example = _caption(items, "")
	_units_example.name = "ExampleLabel"
	_refresh_units_example()


## Instant and live: the write goes through `App.set_setting`, which updates the stored document
## and then emits `units_changed` so every screen showing a weight re-renders (R2/R13).
func _on_units_selected(_index: int) -> void:
	var chosen := _units_control.selected_value()
	var message := StoreSchema.validate_units(chosen)
	if not message.is_empty():
		_reject("units", message)
		return
	var _written := App.set_setting("units", chosen)


func _on_units_changed(units: String) -> void:
	if _units_control != null:
		_units_control.select_value(units)
	_refresh_units_example()
	if _provider_block != null:
		_provider_block.load_from_settings()


func _refresh_units_example() -> void:
	if _units_example == null:
		return
	# No screen formats a weight itself — R13's hard rule, enforced by a literal scan.
	_units_example.text = Strings.UNITS_EXAMPLE_PREFIX \
		+ Units.display_weight(Units.lb_to_kg(EXAMPLE_LB), App.units())


# ------------------------------------------------------------------ 2. theme (R10/R13)

func _build_theme() -> void:
	var items := _items("Theme")
	_card_title(items, Strings.THEME_SECTION)

	_theme_control = SEGMENTED_SCENE.instantiate()
	_theme_control.name = "ThemeControl"
	items.add_child(_theme_control)
	_theme_control.set_values(THEME_VALUES)
	_theme_control.set_options(THEME_OPTIONS)
	_theme_control.select_value(App.theme_mode)
	_theme_control.selected_changed.connect(_on_theme_selected)


func _on_theme_selected(_index: int) -> void:
	var chosen := _theme_control.selected_value()
	var message := StoreSchema.validate_theme(chosen)
	if not message.is_empty():
		_reject("theme", message)
		return
	var _written := App.set_setting("theme", chosen)


func _on_theme_changed(mode: String) -> void:
	if _theme_control != null:
		_theme_control.select_value(mode)


# ------------------------------------------------------------------ 3. weekly goal (R10)

func _build_weekly_goal() -> void:
	var items := _items("WeeklyGoal")
	_card_title(items, Strings.WEEKLY_GOAL_SECTION)

	var stepper := HBoxContainer.new()
	stepper.name = "GoalStepper"
	stepper.alignment = BoxContainer.ALIGNMENT_CENTER
	stepper.add_theme_constant_override(&"separation", DesignTokens.SPACE["lg"])
	items.add_child(stepper)

	_goal_decrease = _button(stepper, "DecreaseButton", "−", &"SecondaryButton")
	_goal_decrease.pressed.connect(_on_goal_step.bind(-1))
	_goal_value = _body_label(stepper, "")
	_goal_value.name = "GoalValue"
	_goal_value.theme_type_variation = &"H2"
	_goal_value.custom_minimum_size.x = 96.0
	_goal_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_goal_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_goal_increase = _button(stepper, "IncreaseButton", "+", &"SecondaryButton")
	_goal_increase.pressed.connect(_on_goal_step.bind(1))

	_goal_ring = RING_SCENE.instantiate()
	_goal_ring.name = "RingPreview"
	items.add_child(_goal_ring)
	_goal_ring.custom_minimum_size = Vector2(280.0, 280.0)
	_goal_ring.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	_goal_hint = _caption(items, "")
	_refresh_goal()


## Appendix §6.4/R50: with an active plan the ring denominator is the plan's own
## `days_per_week`, so the settings row shows that value **read-only** instead of pretending the
## stored goal is in charge.
func _plan_owns_goal() -> bool:
	if not is_instance_valid(Store):
		return false
	return not Store.active_plan().is_empty()


func _refresh_goal() -> void:
	_goal = clampi(int(App.get_setting("weekly_goal_days", 4)), GOAL_MIN, GOAL_MAX)
	var effective := Store.weekly_goal_days_effective() if is_instance_valid(Store) else _goal
	var locked := _plan_owns_goal()
	if _goal_value != null:
		_goal_value.text = "%d days/week" % (effective if locked else _goal)
	if _goal_decrease != null:
		_goal_decrease.disabled = locked or _goal <= GOAL_MIN
	if _goal_increase != null:
		_goal_increase.disabled = locked or _goal >= GOAL_MAX
	if _goal_ring != null:
		var denominator := maxi(effective, 1)
		var completed := Store.completed_days_in_week()
		_goal_ring.call(&"set_value", clampf(float(completed) / float(denominator), 0.0, 1.0))
		_goal_ring.call(&"set_caption", "%d/%d this week" % [completed, denominator])
		# Appendix §6.4: the week's day bits come from `Streak.ring_segments()` and are drawn by
		# `progress_ring.set_segments()` — the one ring primitive, no second ring scene. Using the
		# same call PRD-09's `weekly_ring` uses keeps Settings, Home and the Tracker identical.
		_goal_ring.call(&"set_segments",
			Streak.ring_segments(Store.all_entries(), Store.current_week_id(), denominator))
	if _goal_hint != null:
		_goal_hint.text = Strings.GOAL_FROM_PLAN_HINT if locked else ""


func _on_goal_step(delta: int) -> void:
	var wanted := clampi(_goal + delta, GOAL_MIN, GOAL_MAX)
	if wanted == _goal:
		return
	var message := StoreSchema.validate_weekly_goal_days(wanted)
	if not message.is_empty():
		_reject("weekly_goal_days", message)
		return
	if App.set_setting("weekly_goal_days", wanted):
		_goal = wanted
	_refresh_goal()


# ------------------------------------------------------------------ 4. rest timer (R10)

func _build_rest_timer() -> void:
	var items := _items("RestTimer")
	_card_title(items, Strings.REST_TIMER_SECTION)

	var seconds := clampi(int(App.get_setting("rest_timer.default_seconds", 90)),
		REST_MIN, REST_MAX)
	if seconds % REST_STEP != 0:
		seconds = 90

	_rest_slider = HSlider.new()
	_rest_slider.name = "RestSlider"
	_rest_slider.theme_type_variation = &"Input"
	_rest_slider.min_value = float(REST_MIN)
	_rest_slider.max_value = float(REST_MAX)
	_rest_slider.step = float(REST_STEP)
	_rest_slider.value = float(seconds)
	_rest_slider.custom_minimum_size.y = float(DesignTokens.TOUCH_MIN)
	_rest_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rest_slider.value_changed.connect(_on_rest_changed)
	items.add_child(_rest_slider)

	_rest_value_label = _caption(items, "")
	_rest_value_label.name = "RestValueLabel"

	_rest_vibrate = _check(items, "VibrateCheck", Strings.REST_VIBRATE_LABEL,
		"rest_timer.haptic")
	_rest_sound = _check(items, "SoundCheck", Strings.REST_SOUND_LABEL, "rest_timer.sound")

	_caption(items, Strings.REST_STEP_HINT)
	_refresh_rest_label()


func _on_rest_changed(value: float) -> void:
	var seconds := int(round(value))
	var message := StoreSchema.validate_rest_seconds(seconds)
	if not message.is_empty():
		_reject("rest_timer.default_seconds", message)
		return
	var _written := App.set_setting("rest_timer.default_seconds", seconds)
	_refresh_rest_label()


func _refresh_rest_label() -> void:
	if _rest_value_label == null:
		return
	_rest_value_label.text = "Rest %d s between sets" % int(round(_rest_slider.value))


# ------------------------------------------------------------------ 5. AI provider (R10)

func _build_ai_provider() -> void:
	var items := _items("AIProvider")
	_card_title(items, Strings.AI_SECTION)

	_provider_block = PROVIDER_SCENE.instantiate()
	_provider_block.name = "ProviderBlock"
	items.add_child(_provider_block)
	# Settings shows both actions and keeps the R8 note behind its InfoButton.
	_provider_block.set_actions_visible(true, true)
	_provider_block.set_privacy_expanded(false)
	_provider_block.dirty_changed.connect(_on_ai_dirty_changed)
	_build_test_generation(items)


## PRD-07 R9: a **debug-only** row that runs `LLM.generate_plan(sample_input())` end to end and
## reports `source`, `reason_code`, `attempts` and the session count. It is what makes the
## emulator acceptance criterion reachable before PRD-08's wizard exists.
##
## It never touches `Store`: the ladder does not save, and the caller (PRD-08) is the only thing
## that ever writes a generated plan.
func _build_test_generation(parent: Node) -> void:
	if not OS.is_debug_build():
		return
	_test_generation_button = _button(parent, "TestPlanGenerationButton", "Test plan generation",
		&"SecondaryButton")
	_test_generation_button.pressed.connect(_on_test_generation_pressed)
	_test_generation_status = _caption(parent, "")
	_test_generation_status.name = "TestPlanGenerationStatus"
	_test_generation_dialog = AcceptDialog.new()
	_test_generation_dialog.name = "TestPlanGenerationDialog"
	_test_generation_dialog.title = "Test plan generation"
	_test_generation_dialog.ok_button_text = "Close"
	add_child(_test_generation_dialog)


## R9's fixed sample request — the same four areas and all five equipment types, so the debug row
## exercises the real catalog filter, the real prompt and the real validator.
func sample_input() -> Dictionary:
	return {
		"goal": "hypertrophy",
		"days_per_week": 4,
		"duration_min": 40,
		"areas": ["chest", "back", "shoulders", "core"],
		"equipment": ["barbell", "machine", "cable", "dumbbell", "bodyweight"],
		"notes": "",
	}


func _on_test_generation_pressed() -> void:
	if _test_generating or not is_instance_valid(LLM):
		return
	_test_generating = true
	_test_generation_button.disabled = true
	_test_generation_status.text = "Generating…"
	# One frame so the disabled button and the status line are painted before the request.
	await get_tree().process_frame

	var result: Dictionary = await LLM.generate_plan(sample_input())
	var plan: Dictionary = result.get("plan", {})
	var summary := "source: %s\nreason_code: %s\nattempts: %d\nrepaired: %s\nsessions: %d" % [
		String(result.get("source", "")),
		String(result.get("reason_code", "")) if not String(result.get("reason_code", "")).is_empty() 			else "(none)",
		int(result.get("attempts", 0)),
		str(bool(result.get("repaired", false))),
		(plan.get("sessions", []) as Array).size(),
	]
	if not plan.is_empty():
		summary += "\nname: %s\nsplit: %s" % [
			String(plan.get("name", "")), String(plan.get("split_name", ""))]
	summary += "\n\n%s" % String(result.get("user_message", ""))
	_test_generation_dialog.dialog_text = summary
	_test_generation_dialog.popup_centered()
	_test_generation_status.text = "source=%s reason=%s attempts=%d sessions=%d" % [
		String(result.get("source", "")), String(result.get("reason_code", "")),
		int(result.get("attempts", 0)), (plan.get("sessions", []) as Array).size()]
	_test_generating = false
	_test_generation_button.disabled = false


func _on_ai_dirty_changed(_is_dirty: bool) -> void:
	_refresh_state()


# ------------------------------------------------------------------ 6. default plan (R10)

func _build_plan() -> void:
	var items := _items("Plan")
	_card_title(items, Strings.PLAN_SECTION)

	_plan_button = _button(items, "RegenerateDefaultPlanButton", Strings.PLAN_REGENERATE_BUTTON,
		&"SecondaryButton")
	_plan_button.pressed.connect(_on_regenerate_pressed)
	_plan_status = _caption(items, "")
	_plan_status.name = "PlanStatus"

	_plan_dialog = ConfirmationDialog.new()
	_plan_dialog.name = "PlanConfirm"
	_plan_dialog.title = Strings.PLAN_REGENERATE_BUTTON
	_plan_dialog.dialog_text = Strings.PLAN_REGENERATE_CONFIRM
	_plan_dialog.ok_button_text = "Generate"
	_plan_dialog.cancel_button_text = "Cancel"
	add_child(_plan_dialog)
	_plan_dialog.confirmed.connect(_on_regenerate_confirmed)
	_refresh_plan_status()


## R10 order 6: the input the built-in generator is asked for. `weekly_goal_days` may legally be
## 7 while a plan may only hold 1..6, so the value is clamped here and the clamp is logged.
func default_input() -> Dictionary:
	var days := clampi(int(App.get_setting("weekly_goal_days", 4)), 1, PLAN_DAYS_MAX)
	if days != int(App.get_setting("weekly_goal_days", 4)):
		print("[settings] days_per_week clamped to %d for the plan input" % days)
	return {
		"goal": "general_fitness",
		"days_per_week": days,
		"duration_min": DEFAULT_DURATION_MIN,
		"areas": Taxonomy.USER_AREAS,
		"equipment": Generator.DEFAULT_EQUIPMENT,
		"notes": "",
	}


func _on_regenerate_pressed() -> void:
	if _generating:
		return
	_plan_dialog.popup_centered()


func _on_regenerate_confirmed() -> void:
	if _generating:
		return
	_generating = true
	_plan_button.disabled = true
	_plan_status.text = "Generating…"
	# One frame so the disabled button and the status line are actually painted before the
	# generator blocks the main thread.
	await get_tree().process_frame

	var seed_value := int(Time.get_unix_time_from_system())
	var plan := Generator.build_plan(default_input(), seed_value)
	if plan.has("error"):
		_plan_status.text = "Could not build a plan: %s" % String(plan["error"])
		Feedback.toast(Strings.TOAST_SAVE_FAILED, &"danger")
	else:
		plan["name"] = DEFAULT_PLAN_NAME
		plan["source"] = "builtin"
		plan["provider"] = ""
		var stored := Store.upsert_plan(plan)
		# A first-run user has no active plan; activating this one is what makes the Home tab
		# show something. An existing choice is never overridden, and the id is read back from
		# the store because the generator leaves `id` empty for the store to assign (appendix
		# §5.2).
		if stored and Store.active_plan_id().is_empty():
			var plans := Store.all_plans()
			if not plans.is_empty():
				var _activated := Store.set_active_plan(String(plans[0].get("id", "")))
		# History is deliberately untouched: regenerating a plan is not a workout (AC10).
		var _flushed := Store.flush()
		Feedback.toast(Strings.TOAST_PLAN_REGENERATED, &"success")
	_generating = false
	_plan_button.disabled = false
	_refresh_plan_status()


func _refresh_plan_status() -> void:
	if _plan_status == null or not is_instance_valid(Store):
		return
	var plan := Store.active_plan()
	if plan.is_empty():
		_plan_status.text = "No plan yet. Generate one, or build one from the Home tab."
		return
	_plan_status.text = "Active: %s (%d days/week) · %s" % [
		String(plan.get("name", "")), int(plan.get("days_per_week", 0)),
		String(plan.get("source", ""))]


# ------------------------------------------------------------------ 7. storage (R10/R11)

func _build_storage() -> void:
	var items := _items("Storage")
	_card_title(items, Strings.STORAGE_SECTION)
	_storage_label = _body_label(items, "")
	_storage_label.name = "StorageUsage"
	var hint := _caption(items, Strings.STORAGE_HINT)
	hint.name = "OpenFolderHint"


func _refresh_storage() -> void:
	if _storage_label == null or not is_instance_valid(Store):
		return
	_storage_label.text = Format.storage_line(Store.data_dir_usage_bytes(),
		Store.data_dir_breakdown())


# ------------------------------------------------------------------ 8. attribution (R10)

func _build_attribution() -> void:
	var items := _items("Attribution")
	_card_title(items, Strings.ATTRIBUTION_SECTION)
	_attribution_button = _button(items, "AttributionButton", Strings.ATTRIBUTION_BUTTON,
		&"SecondaryButton")
	_attribution_button.pressed.connect(_on_attribution_pressed)


func _on_attribution_pressed() -> void:
	Nav.push(Routes.ATTRIBUTION)


## PRD-02's gallery, kept reachable while it is still useful (debug builds only).
func _on_gallery_pressed() -> void:
	Nav.push(Routes.GALLERY)


# ------------------------------------------------------------------ 9. about (R10)

func _build_about() -> void:
	var items := _items("About")
	_card_title(items, Strings.ABOUT_SECTION)

	var version := _body_label(items, "")
	version.name = "VersionLine"
	version.text = "%s %s" % [AppInfo.NAME, AppInfo.VERSION]

	var engine := _caption(items, "")
	engine.name = "EngineLine"
	engine.text = "Godot %s" % String(Engine.get_version_info()["string"])

	var package := _caption(items, "")
	package.name = "PackageLine"
	package.text = "Package: %s" % Strings.package_id()

	var medical := _caption(items, "")
	medical.name = "MedicalLine"
	medical.text = Strings.MEDICAL_DISCLAIMER

	var evidence := _caption(items, "")
	evidence.name = "EvidenceLine"
	evidence.text = Strings.EVIDENCE_SOURCES

	# PRD-02's component gallery keeps its entry point (AC12) but only in debug builds, which
	# PRD-12 makes permanent.
	if OS.is_debug_build():
		_gallery_button = _button(items, "GalleryButton", "Component gallery (debug)",
			&"SecondaryButton")
		_gallery_button.pressed.connect(_on_gallery_pressed)


# ------------------------------------------------------------------ 10. danger (R12)

func _build_danger() -> void:
	var items := _items("Danger")
	_card_title(items, Strings.DANGER_SECTION)
	_caption(items, Strings.RESET_BODY)

	_reset_button = _button(items, "ResetAllDataButton", Strings.RESET_BUTTON, &"DangerButton")
	_reset_button.pressed.connect(_on_reset_pressed)

	_reset_dialog = ConfirmationDialog.new()
	_reset_dialog.name = "ResetConfirm"
	_reset_dialog.title = Strings.RESET_TITLE
	_reset_dialog.dialog_text = Strings.RESET_BODY
	_reset_dialog.ok_button_text = Strings.RESET_OK
	_reset_dialog.cancel_button_text = Strings.RESET_CANCEL
	# R12: tapping outside a destructive dialog must not dismiss it.
	_reset_dialog.exclusive = true
	add_child(_reset_dialog)

	var warning := Label.new()
	warning.name = "ResetWarning"
	warning.text = Strings.RESET_WARNING
	warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_reset_dialog.add_child(warning)

	_reset_field = LineEdit.new()
	_reset_field.name = "TypeReset"
	_reset_field.placeholder_text = Strings.RESET_PLACEHOLDER
	_reset_field.theme_type_variation = &"Input"
	TouchTargets.enforce(_reset_field)
	_reset_field.text_changed.connect(_on_reset_text_changed)
	_reset_dialog.add_child(_reset_field)

	_reset_dialog.about_to_popup.connect(_on_reset_about_to_popup)
	_reset_dialog.confirmed.connect(_on_reset_confirmed)
	_update_reset_guard()


## The typed confirmation (R12): exactly `RESET`, case-sensitive, with trailing whitespace
## ignored and nothing else tolerated. Static and pure so the headless suite can prove the guard
## without a scene tree.
static func is_reset_confirmation(text: String) -> bool:
	return text.rstrip(" \t\r\n") == Strings.RESET_WORD


func _on_reset_pressed() -> void:
	_reset_field.text = ""
	_update_reset_guard()
	_reset_dialog.popup_centered()


func _on_reset_about_to_popup() -> void:
	# A re-opened dialog must not remember the previous confirmation.
	_update_reset_guard()


func _on_reset_text_changed(_text: String) -> void:
	_update_reset_guard()


func _update_reset_guard() -> void:
	if _reset_dialog == null or _reset_field == null:
		return
	_reset_dialog.get_ok_button().disabled = not is_reset_confirmation(_reset_field.text)


func _on_reset_confirmed() -> void:
	# Belt and braces: the OK button is disabled until the word is typed, and the handler
	# re-checks so a programmatic `confirmed` can never wipe the device.
	if not is_reset_confirmation(_reset_field.text):
		return
	var _reset: bool = Store.reset_all()
	var _dark := App.set_theme_mode(DesignTokens.MODE_DARK)
	var _units := App.set_units(Units.LB)
	_refresh_state()
	Feedback.toast(Strings.TOAST_ALL_DATA_ERASED, &"success")
	print("[settings] reset_all done onboarding_complete=%s" % str(
		bool(App.get_setting("onboarding_complete", true))))
	# R12: back through boot so the wizard runs again. Boot is a main-scene route (appendix §2),
	# so this is a scene replacement rather than a push into the shell's ScreenHost.
	var _err := get_tree().change_scene_to_file(Routes.scene_for(Routes.BOOT))


# ------------------------------------------------------------------ shared rows

func _items(section: String) -> VBoxContainer:
	var path := "%s/%s/Body/Items" % [SECTIONS_PATH, section]
	var node := get_node_or_null(NodePath(path)) as VBoxContainer
	if node == null:
		push_error("[settings] missing section %s" % path)
		return VBoxContainer.new()
	return node


func _card_title(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.name = "Title"
	label.text = text
	label.theme_type_variation = &"H3"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _body_label(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"BodyLabel"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _caption(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"Caption"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _button(parent: Node, button_name: String, text: String, variation: StringName) -> Button:
	var button := Button.new()
	button.name = button_name
	button.text = text
	button.theme_type_variation = variation
	TouchTargets.enforce(button)
	parent.add_child(button)
	return button


func _check(parent: Node, check_name: String, text: String, path: String) -> CheckButton:
	var check := CheckButton.new()
	check.name = check_name
	check.text = text
	check.theme_type_variation = &"SettingToggle"
	check.button_pressed = bool(App.get_setting(path, true))
	TouchTargets.enforce(check)
	check.toggled.connect(_on_check_toggled.bind(path))
	parent.add_child(check)
	return check


func _on_check_toggled(pressed: bool, path: String) -> void:
	var message := StoreSchema.validate_setting(path, pressed)
	if not message.is_empty():
		_reject(path, message)
		return
	var _written := App.set_setting(path, pressed)


func _reject(path: String, message: String) -> void:
	# The message never contains the value, so a rejected key or URL is never echoed back (R7).
	Feedback.toast(message, &"warning")
	print("[settings] rejected %s: %s" % [path, message])


# ------------------------------------------------------------------ state

func _on_visibility_changed() -> void:
	if visible:
		_refresh_state()


func _on_settings_changed(key: String) -> void:
	if key == "units":
		_refresh_units_example()
	elif key == "weekly_goal_days":
		_refresh_goal()


## Everything that depends on the store rather than on a single control.
func _refresh_state() -> void:
	_refresh_storage()
	_refresh_goal()
	_refresh_plan_status()
	_refresh_units_example()


# ------------------------------------------------------------------ probe hooks

## Publishes tap targets for the Android tooling (debug builds only). `theme_button` is kept
## from PRD-02 — it is now "the theme chip that is not selected", which is the same tap the old
## single toggle button offered, so `tools/screenshot_theme.sh` still drives the app.
func _publish_probe_rects() -> void:
	if _theme_control != null:
		UiProbe.log_rect("theme_button", _theme_control.other_option_control())
		UiProbe.log_rect("theme_dark", _theme_control.option_control(0))
		UiProbe.log_rect("theme_light", _theme_control.option_control(1))
	if _units_control != null:
		UiProbe.log_rect("units_lb", _units_control.option_control(0))
		UiProbe.log_rect("units_kg", _units_control.option_control(1))
	UiProbe.log_rect("regenerate_default_plan_button", _plan_button)
	UiProbe.log_rect("attribution_button", _attribution_button)
	UiProbe.log_rect("reset_all_data_button", _reset_button)
	UiProbe.log_rect("gallery_button", _gallery_button)
	UiProbe.log_rect("rest_slider", _rest_slider)
	UiProbe.log_rect("test_plan_generation_button", _test_generation_button)
