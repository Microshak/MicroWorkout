extends Control
## First-run onboarding wizard — PRD-06 R4.
##
## Six pages, one per question the app needs answered before it can be useful: units, theme,
## weekly goal, and how (or whether) to connect an AI provider. Every answer is written the
## moment it is touched (`App.set_setting()`), so a process kill halfway through the wizard
## loses nothing; only `onboarding_complete` is written at the end.
##
## Contract details that are easy to get wrong and are therefore explicit here:
##
## * **The wizard owns the back gesture** (`Nav.set_back_handling(false)`). `Nav`'s default is
##   "press back twice to exit", which must never fire on page 0 of a first run — so page 0
##   swallows back entirely and later pages walk one page back (R4).
## * **Motion never gates input.** The outgoing page is hidden and the incoming page is
##   positioned in the same frame; the 180 ms slide is decoration on top of an already-live page.
## * **No screen formats a weight.** The `lb`/`kg` example goes through `Units.display_weight()`
##   and is re-rendered from `App.units_changed` (R13).
## * **The LLM page writes nothing it cannot validate.** `ProviderConfigBlock` runs the R7 rules
##   before it writes, so an invalid key never reaches `settings.json`.

const PAGE_COUNT := 6
const PAGE_WELCOME := 0
const PAGE_UNITS := 1
const PAGE_THEME := 2
const PAGE_GOAL := 3
const PAGE_LLM := 4
const PAGE_DONE := 5
const GOAL_MIN := 1
const GOAL_MAX := 7

const PAGE_NAMES: PackedStringArray = [
	"Welcome", "Units", "Theme", "Goal", "LLM", "Done",
]

## R4's Continue label per page.
const CONTINUE_LABELS: PackedStringArray = [
	"Get started", "Continue", "Continue", "Continue", "Test & continue",
	"Take me to the app",
]

## The example weight on page 1. It is authored in pounds because that is the number a lifter
## recognises, and converted once through [Units] — the literal `135 lb` never appears in a
## screen, which is what keeps `scripts/ui/` free of formatting code (R13).
const EXAMPLE_LB := 135.0

## Progress-dot geometry: the current page is a wide pill so state is never colour-only.
const DOT_SIZE := Vector2(24.0, 24.0)
const DOT_CURRENT_SIZE := Vector2(56.0, 24.0)
const DOT_DONE := 0
const DOT_CURRENT := 1
const DOT_FUTURE := 2
const DOT_TOKENS: PackedStringArray = ["success", "primary", "outline"]

const SEGMENTED_SCENE := preload("res://scenes/components/segmented_control.tscn")
const RING_SCENE := preload("res://scenes/components/progress_ring.tscn")
const PROVIDER_SCENE := preload("res://scenes/components/provider_config_block.tscn")

const UNITS_OPTIONS: PackedStringArray = [Units.LB, Units.KG]
const THEME_OPTIONS: PackedStringArray = ["Dark", "Light"]
const THEME_VALUES: PackedStringArray = ["dark", "light"]

@onready var _bg: ColorRect = $Bg
@onready var _pages_host: Control = $Gutter/Layout/Pages
@onready var _dots_row: HBoxContainer = $Gutter/Layout/Header/ProgressDots
@onready var _back_button: Button = $Gutter/Layout/Header/BackButton
@onready var _skip_button: Button = $Gutter/Layout/Header/SkipButton
@onready var _continue_button: Button = $Gutter/Layout/Footer/ContinueButton

var _page: int = PAGE_WELCOME
var _pages: Array[Control] = []
var _dots: Array[Panel] = []

var _units_control: SegmentedControl = null
var _example_label: Label = null
var _theme_control: SegmentedControl = null
var _goal_value: Label = null
var _goal: int = 4
var _increase_button: Button = null
var _decrease_button: Button = null
var _ring: Control = null
var _provider_block: ProviderConfigBlock = null
var _summary_units: Label = null
var _summary_theme: Label = null
var _summary_goal: Label = null
var _summary_ai: Label = null


func _ready() -> void:
	_bg.color = DesignTokens.color(App.theme_mode, "bg")
	App.theme_changed.connect(_on_theme_changed)
	App.units_changed.connect(_on_units_changed)
	# R4: on page 0 back must not exit the app, so the wizard takes the gesture away from Nav.
	Nav.set_back_handling(false)

	_goal = int(App.get_setting("weekly_goal_days", 4))
	if _goal < GOAL_MIN or _goal > GOAL_MAX:
		_goal = 4

	_collect_pages()
	_build_welcome()
	_build_units()
	_build_theme()
	_build_goal()
	_build_llm()
	_build_done()
	_build_dots()

	_back_button.pressed.connect(_on_back_pressed)
	_skip_button.pressed.connect(_on_skip_pressed)
	_skip_button.text = Strings.SKIP_BUTTON
	_continue_button.pressed.connect(_on_continue_pressed)

	_go_to(PAGE_WELCOME, 1, true)
	print("[onboarding] ready pages=%d onboarding_complete=%s" % [
		PAGE_COUNT, str(bool(App.get_setting("onboarding_complete", false)))])


func _exit_tree() -> void:
	Nav.set_back_handling(true)


func _notification(what: int) -> void:
	# Android's back button (R4). Nav's own handler is disabled for the wizard's lifetime.
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_pressed()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_on_back_pressed()
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ page construction

func _collect_pages() -> void:
	for page_name in PAGE_NAMES:
		var page := _pages_host.get_node_or_null(NodePath(page_name)) as Control
		_pages.append(page)


## A page is a `ScrollContainer` so the long LLM page survives a small screen and a 1.5 × text
## scale without a redesign.
func _body(page: Control) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_child(scroll)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override(&"separation", DesignTokens.SPACE["lg"])
	scroll.add_child(body)
	return body


func _label(parent: Node, label_name: String, text: String, variation: StringName) -> Label:
	var label := Label.new()
	label.name = label_name
	label.text = text
	label.theme_type_variation = variation
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _build_welcome() -> void:
	var body := _body(_pages[PAGE_WELCOME])
	var wordmark := _label(body, "Wordmark", Strings.WELCOME_TITLE, &"DisplayLabel")
	wordmark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var promise := _label(body, "Promise", Strings.WELCOME_PROMISE, &"BodyLabel")
	promise.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var footnote := _label(body, "Footnote", Strings.WELCOME_FOOTNOTE, &"Caption")
	footnote.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _build_units() -> void:
	var body := _body(_pages[PAGE_UNITS])
	_label(body, "Question", Strings.UNITS_QUESTION, &"H3")

	_units_control = SEGMENTED_SCENE.instantiate()
	_units_control.name = "UnitsControl"
	body.add_child(_units_control)
	_units_control.set_values(UNITS_OPTIONS)
	_units_control.set_options(UNITS_OPTIONS)
	_units_control.select_value(App.units())
	_units_control.selected_changed.connect(_on_units_selected)

	_example_label = _label(body, "Example", "", &"BodyLabel")
	_refresh_example()


func _build_theme() -> void:
	var body := _body(_pages[PAGE_THEME])
	_label(body, "Question", Strings.THEME_QUESTION, &"H3")

	# Tapping applies immediately, so this page recolours itself — the clearest possible proof
	# that the theme switch needs no restart (R4/R13).
	_theme_control = SEGMENTED_SCENE.instantiate()
	_theme_control.name = "ThemeControl"
	body.add_child(_theme_control)
	_theme_control.set_values(THEME_VALUES)
	_theme_control.set_options(THEME_OPTIONS)
	_theme_control.select_value(App.theme_mode)
	_theme_control.selected_changed.connect(_on_theme_selected)


func _build_goal() -> void:
	var body := _body(_pages[PAGE_GOAL])
	_label(body, "Question", Strings.GOAL_QUESTION, &"H3")

	var stepper := HBoxContainer.new()
	stepper.name = "Stepper"
	stepper.alignment = BoxContainer.ALIGNMENT_CENTER
	stepper.add_theme_constant_override(&"separation", DesignTokens.SPACE["lg"])
	body.add_child(stepper)

	_decrease_button = _stepper_button(stepper, "DecreaseButton", "−")
	_decrease_button.pressed.connect(_on_goal_step.bind(-1))
	_goal_value = _label(stepper, "GoalValue", str(_goal), &"H2")
	_goal_value.custom_minimum_size.x = 96.0
	_goal_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_increase_button = _stepper_button(stepper, "IncreaseButton", "+")
	_increase_button.pressed.connect(_on_goal_step.bind(1))

	_ring = RING_SCENE.instantiate()
	_ring.name = "RingPreview"
	body.add_child(_ring)
	_ring.custom_minimum_size = Vector2(320.0, 320.0)
	_ring.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_refresh_goal()


func _build_llm() -> void:
	var body := _body(_pages[PAGE_LLM])
	_label(body, "Question", Strings.LLM_QUESTION, &"H3")

	_provider_block = PROVIDER_SCENE.instantiate()
	_provider_block.name = "ProviderBlock"
	body.add_child(_provider_block)
	# The footer button is this page's action (R4's "Test & continue"), so the block hides its
	# own action row, and the privacy note is open rather than behind the info button (R8).
	_provider_block.set_actions_visible(false, false)
	_provider_block.set_privacy_expanded(true)


func _build_done() -> void:
	var body := _body(_pages[PAGE_DONE])
	_label(body, "Title", Strings.DONE_TITLE, &"H1")
	_summary_units = _label(body, "SummaryUnits", "", &"BodyLabel")
	_summary_theme = _label(body, "SummaryTheme", "", &"BodyLabel")
	_summary_goal = _label(body, "SummaryGoal", "", &"BodyLabel")
	_summary_ai = _label(body, "SummaryAi", "", &"BodyLabel")
	_label(body, "Hint", Strings.DONE_HINT, &"Caption")


func _stepper_button(parent: Node, button_name: String, text: String) -> Button:
	var button := Button.new()
	button.name = button_name
	button.text = text
	button.theme_type_variation = &"SecondaryButton"
	TouchTargets.enforce(button)
	A11y.label(button, text)
	parent.add_child(button)
	return button


func _build_dots() -> void:
	for i in PAGE_COUNT:
		var dot := Panel.new()
		dot.name = "Dot%d" % i
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dots_row.add_child(dot)
		_dots.append(dot)
	_refresh_dots()


# ------------------------------------------------------------------ navigation

func _go_to(index: int, direction: int, immediate: bool = false) -> void:
	if index < 0 or index >= PAGE_COUNT:
		return
	var outgoing: Control = null
	if _page >= 0 and _page < _pages.size():
		outgoing = _pages[_page]
	if outgoing != null and outgoing != _pages[index]:
		# Hidden in the same frame the incoming page is shown: the animation decorates a page
		# that is already interactive rather than gating it.
		outgoing.visible = false
		if _page == PAGE_LLM and _provider_block != null:
			_provider_block.cancel_test()

	_page = index
	var incoming := _pages[index]
	if incoming == null:
		return
	incoming.visible = true
	incoming.position.x = 0.0

	var duration := _slide_seconds()
	if not immediate and duration > 0.0:
		incoming.position.x = float(direction) * maxf(incoming.size.x, 1.0)
		var tween := create_tween()
		tween.set_trans(Tween.TRANS_CUBIC)
		tween.set_ease(Tween.EASE_OUT)
		tween.tween_property(incoming, "position:x", 0.0, duration)

	_continue_button.text = CONTINUE_LABELS[index]
	_back_button.visible = index > 0
	_skip_button.visible = index == PAGE_LLM
	if index == PAGE_DONE:
		_refresh_summary()
	_refresh_dots()
	# One frame later, so the check measures a laid-out page and the rects the Android tooling
	# taps belong to the page that is actually on screen.
	_report_touch_targets.call_deferred()
	_publish_probe_rects.call_deferred()


## 180 ms ease-out per §9, shortened to `reduced_ms` under `ui.reduce_motion` — skipped, never
## stretched, when motion is reduced.
func _slide_seconds() -> float:
	var milliseconds := int(DesignTokens.MOTION["screen_ms"])
	if bool(App.get_setting("ui.reduce_motion", false)):
		milliseconds = int(DesignTokens.MOTION["reduced_ms"])
	return float(milliseconds) / 1000.0


func _on_continue_pressed() -> void:
	match _page:
		PAGE_LLM:
			await _test_and_continue()
		PAGE_DONE:
			_finish()
		_:
			_go_to(_page + 1, 1)


## R9's "Test & continue": the wizard advances only on a verified key. A failure keeps the user
## here with the provider's own (redacted) explanation, and `Skip` stays the documented exit.
func _test_and_continue() -> void:
	if _provider_block == null:
		_go_to(PAGE_DONE, 1)
		return
	_continue_button.disabled = true
	var result: Dictionary = await _provider_block.run_test_connection()
	_continue_button.disabled = false
	if result.is_empty():
		return
	if bool(result.get("ok", false)):
		var _marked := App.set_setting("llm.configured", true)
		_go_to(PAGE_DONE, 1)


func _on_back_pressed() -> void:
	# Page 0 swallows back: a first-run user must not be able to exit the setup by accident (R4).
	if _page > PAGE_WELCOME:
		_go_to(_page - 1, -1)


## R4's skip path — one tap from "no AI" to the built-in generator, with nothing left behind.
func _on_skip_pressed() -> void:
	var _cleared := App.set_setting("llm.api_key", "")
	var _unconfigured := App.set_setting("llm.configured", false)
	_finish()


func _finish() -> void:
	var _done := App.set_setting("onboarding_complete", true)
	# Forced flush, not the 400 ms debounce: the next thing that happens is a scene change.
	var _saved := Store.save_settings()
	Nav.set_back_handling(true)
	print("[onboarding] complete units=%s theme=%s goal=%d" % [
		App.units(), App.theme_mode, _goal])
	Nav.goto(Routes.SHELL)


func _report_touch_targets() -> void:
	var _count := TouchTargets.report(self)


## Publishes the wizard's tap targets for the Android tooling (debug builds only), so a scripted
## walk can tap Continue/Back/Skip and each page's controls without guessing a coordinate.
func _publish_probe_rects() -> void:
	UiProbe.log_rect("onboarding_continue", _continue_button)
	UiProbe.log_rect("onboarding_back", _back_button)
	UiProbe.log_rect("onboarding_skip", _skip_button)
	UiProbe.log_rect("onboarding_units", _units_control)
	UiProbe.log_rect("onboarding_theme", _theme_control)
	UiProbe.log_rect("onboarding_goal_increase", _increase_button)
	UiProbe.log_rect("onboarding_goal_decrease", _decrease_button)
	if _provider_block != null:
		UiProbe.log_rect("onboarding_provider_picker", _provider_block.get_node_or_null(
			^"ProviderRow/ProviderPicker") as Control)
		UiProbe.log_rect("onboarding_api_key", _provider_block.get_node_or_null(
			^"ApiKeyRow/ApiKeyField") as Control)


# ------------------------------------------------------------------ page state

func _on_units_selected(_index: int) -> void:
	var chosen := _units_control.selected_value()
	var _written := App.set_setting("units", chosen)
	_refresh_example()


func _on_theme_selected(_index: int) -> void:
	var _written := App.set_setting("theme", _theme_control.selected_value())


func _on_goal_step(delta: int) -> void:
	var wanted := clampi(_goal + delta, GOAL_MIN, GOAL_MAX)
	if wanted == _goal:
		return
	_goal = wanted
	var _written := App.set_setting("weekly_goal_days", _goal)
	_refresh_goal()


func _on_units_changed(_units: String) -> void:
	# R13: a screen that shows a weight re-renders from the signal, never by polling the store.
	if _units_control != null:
		_units_control.select_value(App.units())
	_refresh_example()


func _on_theme_changed(mode: String) -> void:
	_bg.color = DesignTokens.color(mode, "bg")
	if _theme_control != null:
		var index := THEME_VALUES.find(mode)
		if index >= 0:
			_theme_control.set_selected(index)
	_refresh_dots()


# ------------------------------------------------------------------ rendering

func _refresh_example() -> void:
	if _example_label == null:
		return
	var kg := Units.lb_to_kg(EXAMPLE_LB)
	_example_label.text = Strings.UNITS_EXAMPLE_PREFIX + Units.display_weight(kg, App.units())


func _refresh_goal() -> void:
	if _goal_value != null:
		_goal_value.text = str(_goal)
	if _decrease_button != null:
		_decrease_button.disabled = _goal <= GOAL_MIN
	if _increase_button != null:
		_increase_button.disabled = _goal >= GOAL_MAX
	if _ring != null:
		_ring.call(&"set_value", float(_goal) / float(GOAL_MAX))
		_ring.call(&"set_caption", "%d days/week" % _goal)
		# Appendix §6.4: the day bits come from `Streak.ring_segments()` and are drawn by
		# `progress_ring.set_segments()` — the only ring primitive. On a first run there are no
		# completed days yet, so the ticks show the week ahead of the user rather than a fake
		# progress arc; the same call PRD-09's `weekly_ring` makes.
		_ring.call(&"set_segments",
			Streak.ring_segments(Store.all_entries(), Store.current_week_id(), _goal))


func _refresh_summary() -> void:
	if _summary_units == null:
		return
	_summary_units.text = "Units: %s" % Units.unit_label(App.units())
	_summary_theme.text = "Theme: %s" % App.theme_mode
	_summary_goal.text = "Goal: %d days/week" % _goal
	_summary_ai.text = _ai_summary()


func _ai_summary() -> String:
	var key := String(App.get_setting("llm.api_key", ""))
	if key.is_empty():
		return "AI: built-in generator"
	var provider := String(App.get_setting("llm.provider", LLMProviders.DEFAULT_KEY))
	var state := Strings.STATUS_VERIFIED if bool(App.get_setting("llm.configured", false)) \
		else Strings.STATUS_UNVERIFIED
	return "AI: %s (%s)" % [LLMProviders.label_for(provider), state]


## `ProgressDots` is one `Panel` per page (R4). The theme has no `Panel`-based variation for a
## progress dot and its variation set is frozen by `test_design_tokens.gd`, so the dot boxes are
## built here from `DesignTokens` tokens only — re-applied on every theme change, and shaped
## differently per state so "which page am I on" is never colour-only (appendix §4.3 rule 6).
func _refresh_dots() -> void:
	for i in _dots.size():
		var state := DOT_FUTURE
		if i < _page:
			state = DOT_DONE
		elif i == _page:
			state = DOT_CURRENT
		var box := StyleBoxFlat.new()
		box.bg_color = DesignTokens.color(App.theme_mode, DOT_TOKENS[state])
		box.set_corner_radius_all(int(DesignTokens.RADIUS["bar"]))
		_dots[i].add_theme_stylebox_override(&"panel", box)
		_dots[i].custom_minimum_size = DOT_CURRENT_SIZE if state == DOT_CURRENT else DOT_SIZE
