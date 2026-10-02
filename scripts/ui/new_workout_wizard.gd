extends Control
## PRD-08 R1–R10, R16–R17 — the New Workout wizard.
##
## Six steps collect the owner's own words and four checkboxes, then hand the request to
## `LLM.generate_plan()` and push the generated week onto the preview screen. The training goal
## is asked **every time** (PRD-00 D4): `WizardState` never persists it and `setup()` clears it on
## every entry — that is the whole mechanism, and it is the reason this screen exists.
##
## Things that are easy to get wrong and are therefore deliberate here:
##
## * **The wizard owns no plan logic.** It builds R9's request dictionary and awaits PRD-07. It
##   never branches on success/failure and never renders an error dialog: every provider failure
##   has already been resolved into a `builtin` result with a `reason_code` and a `user_message`
##   by the time the await returns. Only `cancelled` and `busy` are handled separately, because
##   they are the two outcomes that are *not* fallbacks.
## * **The generating overlay is PRD-07's component, not a second implementation.** PRD-07 R9
##   ships `generating_overlay.tscn` explicitly so that "PRD-08 embeds it". Its API is
##   `start(message)`, `set_message()`, `set_sub_text()`, `stop()` — so R10's per-phase copy is
##   driven through those, and the elapsed clock rides along in the sub-label (`0:12`) because the
##   shared component has no third label. See `docs/DECISIONS.md` for that adaptation.
## * **The draft is written through `Store`, never to a file** (PRD-00 rule 3). Every step change
##   and every field mutation writes `ui.wizard_draft`; `Store` debounces the flush. A failed
##   draft write is logged and ignored — it must never block navigation or generation.
## * **Input is gated for exactly one thing**: the await that must not be duplicated. The footer
##   is frozen and the close path is disabled while `_busy`; nothing else in the app is gated.
## * **The API key is never read by this screen.** It stays in `settings.json` and inside
##   `LLMClient`; `LLM.generate_plan()` reads it itself.

const STEP_SLIDE := 16.0
const STEP_OUT_MS := 120
const STEP_IN_MS := 180
const OVERLAY_FADE_MS := 180
## R10: a fast local generation must not flash the overlay.
const OVERLAY_MIN_MS := 600
const DISABLED_ALPHA := 0.45
const NOTES_MIN_HEIGHT := 240.0
const SEGMENT_HEIGHT := 96.0
const GOAL_CARD_HEIGHT := 132.0
const REVIEW_ROW_HEIGHT := 88.0
const RADIO_SIZE := 44.0

## R3's placeholder, verbatim.
const NOTES_PLACEHOLDER := "Tell the AI what matters to you.\n\nBad shoulder on the left? " \
	+ "Training for a holiday? Hate burpees? Say it here — it gets read."
## R4's helper copy, verbatim.
const AREAS_HELPER := "Pick everything you want covered. The generator targets at least " \
	+ "10 hard sets a week for each area you pick."
## R6's helper copy, verbatim.
const DURATION_HELPER := "Warm-up and cool-down take about 8 minutes of this."
## R7's helper copy, verbatim.
const GOAL_HELPER := "Asked every time, because it changes the whole plan."

## R10's phase copy, verbatim (thresholds in seconds).
const PHASE_WAITING_SEC := 1
const PHASE_VALIDATING_SEC := 25
const PHASE_FALLBACK_SEC := 45

## R10's toasts, verbatim.
const CANCELLED_TOAST := "Cancelled — nothing was saved."
const BUSY_TOAST := "Still working on the last one — give it a second."
## PRD-12 R8's exact no-key copy, shown as the generating overlay's sub-text.
const NO_KEY_NOTE := "No API key saved. The built-in generator will make your plan."
## Only reached when the built-in generator itself cannot run (no library, no areas) — a state
## PRD-07 has no copy for, because it means the app is broken rather than unconfigured.
const BUILTIN_FAILED_TOAST := "Couldn't build a plan on this device just now."

## Owner request (2026-10-02): pressing Generate with nothing saved must offer the door to the
## API fields instead of silently building offline. `Add API key` switches to Settings → AI
## provider; `Build on-device` is the explicit offline path; `Not now` just closes the dialog.
const NO_AI_TITLE := "No AI set up yet"
const NO_AI_BODY := "Your API key isn't saved on this phone. Add it and AI writes your plan — " \
	+ "or build one on this device right now."
const NO_AI_ADD := "Add API key"
const NO_AI_OFFLINE := "Build on-device"
const NO_AI_CANCEL := "Not now"

## The seven day segments, in order (R5: "1"…"6") and R6's five duration segments.
const DAY_LABELS: PackedStringArray = ["1", "2", "3", "4", "5", "6"]
const DURATION_LABELS: PackedStringArray = ["20 min", "30 min", "40 min", "50 min", "60 min"]

## The review rows, in R8's order: name, value getter index, and the step `Edit` jumps to.
const REVIEW_LABELS: PackedStringArray = [
	"Goal", "Areas", "Days a week", "Session length", "Your notes",
]
const REVIEW_TARGETS: PackedInt32Array = [
	WizardState.STEP_GOAL,
	WizardState.STEP_AREAS,
	WizardState.STEP_DAYS,
	WizardState.STEP_DURATION,
	WizardState.STEP_NOTES,
]

const CHIP_SCENE := preload("res://scenes/components/area_chip.tscn")
const SEGMENTED_SCENE := preload("res://scenes/components/segmented_control.tscn")
const GLYPH_SCENE := preload("res://scenes/components/glyph.tscn")
const GeneratingOverlayScript := preload("res://scripts/ui/generating_overlay.gd")

@onready var _bg: ColorRect = $Background
@onready var _scroller: ScrollContainer = $SafeArea/Layout/StepScroller
@onready var _step_host: MarginContainer = $SafeArea/Layout/StepScroller/StepHost
@onready var _close_button: Button = $SafeArea/Layout/Header/CloseButton
@onready var _title_label: Label = $SafeArea/Layout/Header/HeaderCenter/TitleLabel
@onready var _step_indicator: Label = $SafeArea/Layout/Header/HeaderCenter/StepIndicator
@onready var _validation_label: Label = $SafeArea/Layout/Footer/ValidationLabel
@onready var _back_button: Button = $SafeArea/Layout/Footer/FooterRow/BackButton
@onready var _next_button: Button = $SafeArea/Layout/Footer/FooterRow/NextButton
@onready var _overlay: GeneratingOverlayScript = $GenerationOverlay
@onready var _gen_timer: Timer = $GenTimer
@onready var _discard_dialog: ConfirmationDialog = $DiscardDialog
@onready var _start_over_dialog: ConfirmationDialog = $StartOverDialog
@onready var _no_ai_dialog: ConfirmationDialog = $NoAiDialog

var _state: WizardState = WizardState.new()
var _step: int = WizardState.STEP_NOTES
var _entry: String = "home"

var _step_nodes: Array[Control] = []
var _area_chips: Dictionary = {}
var _goal_cards: Dictionary = {}
var _review_values: Array[Label] = []
var _days_control: SegmentedControl = null
var _duration_control: SegmentedControl = null
var _notes_edit: TextEdit = null
var _char_counter: Label = null
var _goal_group: ButtonGroup = null

var _busy: bool = false
var _saving_notes: bool = false
var _accept_draft_writes: bool = false
var _elapsed_base_ms: int = 0


# ===========================================================================
# Lifecycle
# ===========================================================================

func _ready() -> void:
	_bg.color = DesignTokens.color(App.theme_mode, "bg")
	if not App.theme_changed.is_connected(_on_theme_changed):
		App.theme_changed.connect(_on_theme_changed)

	_collect_steps()
	_build_notes_step()
	_build_areas_step()
	_build_days_step()
	_build_duration_step()
	_build_goal_step()
	_build_review_step()
	_wire_footer()
	_wire_dialogs()
	_wire_no_ai_dialog()

	_gen_timer.timeout.connect(_on_generation_tick)
	_gen_timer.stop()

	# Nav hands the back gesture to this screen for as long as it is alive: the default
	# "press back twice to exit" must never fire while the owner is mid-setup (R2.3), and the
	# prompt's own copy is what Android's back button produces instead.
	Nav.set_back_handling(false)

	_go_to(WizardState.STEP_NOTES, true)


func _exit_tree() -> void:
	# Hand the gesture back to Nav unless another screen of this flow is still on the stack —
	# the preview sets the same flag, and the two must not undo each other.
	var current := Nav.current_route()
	if current != Routes.NEW_WORKOUT_WIZARD and current != Routes.PLAN_PREVIEW:
		Nav.set_back_handling(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_pressed()


func _input(event: InputEvent) -> void:
	# R3: tapping outside the notes field unfocuses it (so the soft keyboard closes) without
	# touching any answer.
	if _notes_edit == null or not _notes_edit.has_focus():
		return
	var inside := _notes_edit.get_global_rect()
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if not inside.has_point((event as InputEventMouseButton).position):
			_notes_edit.release_focus()
	elif event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		if not inside.has_point((event as InputEventScreenTouch).position):
			_notes_edit.release_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		# R3: while the notes field is focused, Escape/back only drops focus.
		get_viewport().set_input_as_handled()
		_on_back_pressed()


# ===========================================================================
# R1 — entry point and arguments
# ===========================================================================

## Nav calls this after `add_child` (appendix §1.5). [param args]:
##   `restart: bool = true`  — true clears every answer and deletes the draft;
##                             false prefills from the saved draft.
##   `entry: String = "home"` — log tag: home | plan_tab | settings | plan_finished.
##   `state: Dictionary`     — additive: the preview hands the full state back on
##                             `Edit answers`, which is the only way the goal can survive a trip
##                             through the preview (a draft never carries it, by design).
##   `step: int`             — additive: which step to land on.
func setup(args: Dictionary) -> void:
	_entry = PlanModel.as_text(args.get("entry"), "home")
	var restart := bool(args.get("restart", true))
	var handed: Variant = args.get("state")
	var resumed: bool = handed is Dictionary and not (handed as Dictionary).is_empty()

	_accept_draft_writes = false
	_state.reset()
	if resumed:
		_state.apply_full_dict(handed)
	else:
		# R7 / PRD-00 D4: the goal is unanswered on every entry, including one that prefilled
		# every other field from the draft.
		_state.goal = ""
		if restart:
			_clear_draft()
		else:
			_load_draft()
	_accept_draft_writes = true

	_refresh_all()
	print("[wizard] open restart=%s entry=%s resumed=%s" % [
		"true" if restart else "false", _entry, "true" if resumed else "false"])

	var step := PlanModel.as_int(args.get("step"), WizardState.STEP_NOTES)
	_go_to(clampi(step, 0, WizardState.STEP_REVIEW), true)


# ===========================================================================
# Step construction
# ===========================================================================

func _collect_steps() -> void:
	_step_nodes.clear()
	for step in WizardState.STEP_COUNT:
		var node := _step_host.get_node_or_null(NodePath(_step_name(step))) as Control
		_step_nodes.append(node)


static func _step_name(step: int) -> String:
	match step:
		WizardState.STEP_NOTES:
			return "StepNotes"
		WizardState.STEP_AREAS:
			return "StepAreas"
		WizardState.STEP_DAYS:
			return "StepDays"
		WizardState.STEP_DURATION:
			return "StepDuration"
		WizardState.STEP_GOAL:
			return "StepGoal"
	return "StepReview"


## A label with the theme's word-wrap default, so no screen has to remember to set it.
func _label(parent: Node, label_name: String, text: String, variation: StringName) -> Label:
	var label := Label.new()
	label.name = label_name
	label.text = text
	label.theme_type_variation = variation
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


# ------------------------------------------------------------------ R3

func _build_notes_step() -> void:
	var body := _step_nodes[WizardState.STEP_NOTES]

	_notes_edit = TextEdit.new()
	_notes_edit.name = "NotesEdit"
	_notes_edit.theme_type_variation = &"InputMulti"
	_notes_edit.custom_minimum_size = Vector2(0.0, NOTES_MIN_HEIGHT)
	_notes_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_notes_edit.placeholder_text = NOTES_PLACEHOLDER
	_notes_edit.virtual_keyboard_show_on_focus = true
	A11y.label(_notes_edit, "Notes for this plan", NOTES_PLACEHOLDER)
	body.add_child(_notes_edit)
	_notes_edit.text_changed.connect(_on_notes_changed)

	# `TextEdit` has neither `max_length` nor `virtual_keyboard_type` in Godot 4.7.2 (both are
	# `LineEdit`-only), so the 500-character cap is enforced in `_on_notes_changed()` — which is
	# also where R3's paste rule has to live, because the caret must move to the end. See
	# docs/DECISIONS.md.
	_char_counter = _label(body, "CharCounterLabel", _state.notes_counter(), &"Caption")
	_char_counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


# ------------------------------------------------------------------ R4

func _build_areas_step() -> void:
	var body := _step_nodes[WizardState.STEP_AREAS]

	var grid := GridContainer.new()
	grid.name = "AreaGrid"
	grid.columns = 2
	grid.add_theme_constant_override(&"h_separation", int(DesignTokens.SPACE["lg"]))
	grid.add_theme_constant_override(&"v_separation", int(DesignTokens.SPACE["lg"]))
	body.add_child(grid)

	# `Taxonomy.USER_AREAS` is the source of truth (PRD-05) *and* exactly R4's seven keys in
	# R4's order, so the grid cannot drift from the taxonomy and `mobility` can never appear.
	for area in Taxonomy.USER_AREAS:
		var chip: Button = CHIP_SCENE.instantiate()
		chip.name = "AreaChip_%s" % area
		grid.add_child(chip)
		chip.call(&"set_area", area, false)
		chip.toggled.connect(_on_area_toggled.bind(area))
		_area_chips[area] = chip

	_label(body, "AreasHelper", AREAS_HELPER, &"MutedLabel")


# ------------------------------------------------------------------ R5

func _build_days_step() -> void:
	var body := _step_nodes[WizardState.STEP_DAYS]

	_days_control = SEGMENTED_SCENE.instantiate()
	_days_control.name = "DaysSegmented"
	body.add_child(_days_control)
	_days_control.set_options(DAY_LABELS)
	_size_segments(_days_control)
	_days_control.selected_changed.connect(_on_days_selected)

	# R5's `DaysHelperLabel` is deliberately absent: it must read the split from
	# `Generator.split_name_for(days)`, PRD-05 exposes no such helper, and R5 forbids
	# re-implementing the appendix §6.3 table here. Recorded in docs/DECISIONS.md.


# ------------------------------------------------------------------ R6

func _build_duration_step() -> void:
	var body := _step_nodes[WizardState.STEP_DURATION]

	_duration_control = SEGMENTED_SCENE.instantiate()
	_duration_control.name = "DurationSegmented"
	body.add_child(_duration_control)
	_duration_control.set_options(DURATION_LABELS)
	_size_segments(_duration_control)
	_duration_control.selected_changed.connect(_on_duration_selected)

	_label(body, "DurationHelper", DURATION_HELPER, &"MutedLabel")


# ------------------------------------------------------------------ R7

func _build_goal_step() -> void:
	var body := _step_nodes[WizardState.STEP_GOAL]
	_goal_group = ButtonGroup.new()

	for i in WizardState.GOAL_KEYS.size():
		var key := WizardState.GOAL_KEYS[i]
		var card := _build_goal_card(key, i)
		body.add_child(card)
		_goal_cards[key] = card

	_label(body, "GoalHelper", GOAL_HELPER, &"MutedLabel")


## One goal option: a `Button` styled as R7's card (surface fill, 2 px border, radius 18), a
## drawn radio indicator, the title and the description. The `ButtonGroup` makes "exactly one
## goal" a property of the control rather than a rule the screen has to remember.
func _build_goal_card(key: String, index: int) -> Button:
	var card := Button.new()
	card.name = "GoalCard_%s" % key
	card.theme_type_variation = &"ChipToggle"
	card.toggle_mode = true
	card.button_group = _goal_group
	card.custom_minimum_size = Vector2(0.0, GOAL_CARD_HEIGHT)
	card.pressed.connect(_on_goal_pressed.bind(key))

	var row := HBoxContainer.new()
	row.name = "Row"
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 24.0
	row.offset_top = 8.0
	row.offset_right = -24.0
	row.offset_bottom = -8.0
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override(&"separation", int(DesignTokens.SPACE["lg"]))
	card.add_child(row)

	var radio := Panel.new()
	radio.name = "Radio"
	radio.custom_minimum_size = Vector2(RADIO_SIZE, RADIO_SIZE)
	radio.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	radio.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(radio)

	var texts := VBoxContainer.new()
	texts.name = "Texts"
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_theme_constant_override(&"separation", int(DesignTokens.SPACE["xs"]))
	row.add_child(texts)

	var title := Label.new()
	title.name = "GoalTitleLabel"
	title.theme_type_variation = &"H3"
	title.text = WizardState.GOAL_TITLES[index]
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(title)

	var description := Label.new()
	description.name = "GoalDescLabel"
	description.theme_type_variation = &"MutedLabel"
	description.text = WizardState.GOAL_DESCRIPTIONS[index]
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(description)

	_refresh_goal_card(card, false)
	return card


# ------------------------------------------------------------------ R8

func _build_review_step() -> void:
	var body := _step_nodes[WizardState.STEP_REVIEW]
	_review_values.clear()

	for i in REVIEW_LABELS.size():
		if i > 0:
			var divider := HSeparator.new()
			divider.name = "ReviewDivider%d" % i
			body.add_child(divider)
		body.add_child(_build_review_row(i))

	var reset := Button.new()
	reset.name = "ResetButton"
	reset.theme_type_variation = &"DangerButton"
	reset.text = "Start over"
	reset.custom_minimum_size = Vector2(0.0, REVIEW_ROW_HEIGHT)
	reset.pressed.connect(_on_reset_pressed)
	A11y.label(reset, "Start over")
	body.add_child(reset)


func _build_review_row(index: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "ReviewRow%d" % (index + 1)
	row.custom_minimum_size = Vector2(0.0, REVIEW_ROW_HEIGHT)
	row.add_theme_constant_override(&"separation", int(DesignTokens.SPACE["md"]))

	# R8 asks for a body-22 `text_muted` label; the theme has no 22 px muted variation and its
	# variation set is frozen, so the muted colour rides on `MutedLabel` (19 px) instead. The
	# value keeps body 22 / `text`, which is what the row is read for.
	var label := Label.new()
	label.name = "RowLabel"
	label.theme_type_variation = &"MutedLabel"
	label.text = REVIEW_LABELS[index]
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.custom_minimum_size.x = 220.0
	row.add_child(label)

	var value := Label.new()
	value.name = "RowValue"
	value.theme_type_variation = &"BodyLabel"
	value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(value)
	_review_values.append(value)

	var edit := Button.new()
	edit.name = "EditButton"
	edit.theme_type_variation = &"GhostButton"
	edit.text = "Edit"
	edit.custom_minimum_size = Vector2(REVIEW_ROW_HEIGHT, REVIEW_ROW_HEIGHT)
	edit.pressed.connect(_on_review_edit.bind(REVIEW_TARGETS[index]))
	A11y.label(edit, "Edit %s" % REVIEW_LABELS[index])
	row.add_child(edit)
	return row


# ===========================================================================
# Wiring
# ===========================================================================

func _wire_footer() -> void:
	_close_button.pressed.connect(_request_close)
	_back_button.pressed.connect(_on_back_pressed)
	_next_button.pressed.connect(_on_next_pressed)


func _wire_dialogs() -> void:
	_style_dialog(_discard_dialog)
	_style_dialog(_start_over_dialog)
	_discard_dialog.confirmed.connect(_on_discard_confirmed)
	_start_over_dialog.confirmed.connect(_on_start_over_confirmed)


## R2.3/R8: the destructive button carries the danger variation and the safe one keeps focus.
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


## The no-AI dialog's own wiring (owner request, 2026-10-02). Unlike the two discard dialogs
## this one is not destructive: OK is the primary route to the API fields and keeps focus, and
## `Build on-device` is a third button that runs the unchanged offline path.
func _wire_no_ai_dialog() -> void:
	_no_ai_dialog.title = NO_AI_TITLE
	_no_ai_dialog.dialog_text = NO_AI_BODY
	_no_ai_dialog.ok_button_text = NO_AI_ADD
	_no_ai_dialog.cancel_button_text = NO_AI_CANCEL
	var ok := _no_ai_dialog.get_ok_button()
	if ok != null:
		ok.theme_type_variation = &"PrimaryButton"
		ok.custom_minimum_size = Vector2(0, 88)
		ok.grab_focus()
	var cancel := _no_ai_dialog.get_cancel_button()
	if cancel != null:
		cancel.theme_type_variation = &"GhostButton"
		cancel.custom_minimum_size = Vector2(0, 88)
	var offline := _no_ai_dialog.add_button(NO_AI_OFFLINE, false)
	if offline != null:
		offline.theme_type_variation = &"SecondaryButton"
		offline.custom_minimum_size = Vector2(0, 88)
		offline.pressed.connect(_on_no_ai_offline_pressed)
	_no_ai_dialog.confirmed.connect(_on_no_ai_add_pressed)


## `Add API key`: the Settings tab's AI provider card is the one place keys are entered. The
## tab receives `{"focus": "ai"}`, which scrolls the fields into view instead of landing at
## the top of the page. The log line deliberately avoids the word the redaction gate watches
## for — a log is never the place to prove a credential exists (R14).
func _on_no_ai_add_pressed() -> void:
	print("[wizard] no-ai -> settings focus=ai")
	Nav.push(Routes.SETTINGS, {"focus": "ai"})


## `Build on-device`: exactly the path Generate used to take silently — the offline promise is
## kept, it is just an explicit choice now. The custom button does not auto-hide the dialog, so
## it is hidden here before the (idempotent) generation starts.
func _on_no_ai_offline_pressed() -> void:
	print("[wizard] no-ai build on-device")
	_no_ai_dialog.hide()
	_run_generation()


## One tap per segment, sized to R5/R6's 96 px and to the touch floor.
func _size_segments(control: SegmentedControl) -> void:
	for i in control.option_count():
		var chip := control.option_control(i)
		if chip != null:
			chip.custom_minimum_size = Vector2(0.0, SEGMENT_HEIGHT)
			TouchTargets.enforce(chip)


# ===========================================================================
# Step display
# ===========================================================================

func _go_to(step: int, immediate: bool = false) -> void:
	if step < 0 or step >= WizardState.STEP_COUNT:
		return
	var outgoing := _current_step_node()

	for i in _step_nodes.size():
		var node := _step_nodes[i]
		if node == null or node == outgoing:
			continue
		node.visible = i == step
		node.modulate.a = 1.0
		node.position.y = 0.0

	_step = step
	var incoming := _step_nodes[step]
	if incoming == null:
		return
	incoming.visible = true
	if _scroller != null:
		_scroller.scroll_vertical = 0
	_title_label.text = WizardState.STEP_TITLES[step]
	_step_indicator.text = WizardState.STEP_INDICATORS[step]
	if step == WizardState.STEP_REVIEW:
		_refresh_review()
	_animate_step(incoming, outgoing, immediate)
	_apply_footer()
	_save_draft()

	print("[wizard] step=%d valid=%s msg=\"%s\"" % [
		step, "true" if _state.is_step_valid(step) else "false",
		_state.validation_message(step)])
	_report_touch_targets.call_deferred()


## R17: outgoing fades and slides to y −16 in 120 ms, incoming arrives from y +16 in 180 ms.
## Both are skipped (never shortened) under `ui.reduce_motion`, and neither gates input — the
## incoming step is visible and interactive in the same frame it is shown.
func _animate_step(incoming: Control, outgoing: Control, immediate: bool) -> void:
	if not _motion_enabled():
		incoming.modulate.a = 1.0
		incoming.position.y = 0.0
		if outgoing != null and outgoing != incoming:
			outgoing.visible = false
		return

	if outgoing != null and outgoing != incoming:
		outgoing.visible = true
		outgoing.modulate.a = 1.0
		outgoing.position.y = 0.0
		if immediate:
			outgoing.visible = false
		else:
			var out_tween := create_tween()
			out_tween.set_parallel(true)
			out_tween.set_trans(Tween.TRANS_CUBIC)
			out_tween.set_ease(Tween.EASE_IN)
			out_tween.tween_property(outgoing, "modulate:a", 0.0, float(STEP_OUT_MS) / 1000.0)
			out_tween.tween_property(outgoing, "position:y", -STEP_SLIDE, float(STEP_OUT_MS) / 1000.0)
			out_tween.chain().tween_callback(_hide_step.bind(outgoing))

	incoming.modulate.a = 0.0
	incoming.position.y = STEP_SLIDE
	if immediate:
		incoming.modulate.a = 1.0
		incoming.position.y = 0.0
		return
	var in_tween := create_tween()
	in_tween.set_parallel(true)
	in_tween.set_trans(Tween.TRANS_CUBIC)
	in_tween.set_ease(Tween.EASE_OUT)
	in_tween.tween_property(incoming, "modulate:a", 1.0, float(STEP_IN_MS) / 1000.0)
	in_tween.tween_property(incoming, "position:y", 0.0, float(STEP_IN_MS) / 1000.0)


func _hide_step(node: Control) -> void:
	if node == null or not is_instance_valid(node):
		return
	node.visible = false
	node.modulate.a = 1.0
	node.position.y = 0.0


func _current_step_node() -> Control:
	if _step < 0 or _step >= _step_nodes.size():
		return null
	return _step_nodes[_step]


## R2.2's footer table. A disabled `Next` keeps its size and only dims (`modulate.a`), so the
## layout never jumps.
func _apply_footer() -> void:
	var back_text := "Back"
	var next_text := "Next"
	if _step == WizardState.STEP_NOTES:
		back_text = "Cancel"
	elif _step == WizardState.STEP_REVIEW:
		next_text = "Generate my plan"
	_back_button.text = back_text
	_next_button.text = next_text

	var enabled := _state.is_step_valid(_step) and not _busy
	_next_button.disabled = not enabled
	_next_button.modulate.a = 1.0 if enabled else DISABLED_ALPHA

	var message := _state.validation_message(_step)
	_validation_label.text = message
	_validation_label.visible = not message.is_empty()


func _refresh_all() -> void:
	if _notes_edit != null:
		_saving_notes = true
		_notes_edit.text = _state.notes
		_saving_notes = false
	_refresh_counter()
	for area in _area_chips:
		var chip: Button = _area_chips[area]
		chip.call(&"set_area", area, _state.areas.has(area))
	if _days_control != null:
		_days_control.set_selected(_state.days_per_week - 1)
	if _duration_control != null:
		_duration_control.set_selected(WizardState.DURATION_OPTIONS.find(_state.duration_min))
	_refresh_goal_cards()
	_refresh_review()


func _refresh_counter() -> void:
	if _char_counter != null:
		_char_counter.text = _state.notes_counter()


func _refresh_review() -> void:
	var values := PackedStringArray([
		_state.goal_label(),
		", ".join(_state.area_labels()),
		str(_state.days_per_week),
		_state.duration_label(),
		_state.notes_preview(),
	])
	for i in _review_values.size():
		if i < values.size():
			_review_values[i].text = values[i]


func _refresh_goal_card(card: Button, selected: bool) -> void:
	card.set_pressed_no_signal(selected)
	var radio := card.get_node_or_null(^"Row/Radio") as Panel
	if radio != null:
		radio.add_theme_stylebox_override(&"panel", _radio_style(selected))
	# R7's card look: `surface` fill with a 2 px `outline` border, and 2 px `primary` once
	# chosen — the same `add_theme_stylebox_override` route the area chips use, because the
	# theme's variation set is frozen and colour overrides are banned.
	card.add_theme_stylebox_override(&"normal", _card_style("outline", false))
	card.add_theme_stylebox_override(&"disabled", _card_style("outline", false))
	card.add_theme_stylebox_override(&"hover", _card_style("outline_strong", false))
	card.add_theme_stylebox_override(&"pressed", _card_style("primary", true))
	card.add_theme_stylebox_override(&"hover_pressed", _card_style("primary", true))


func _refresh_goal_cards() -> void:
	for key in _goal_cards:
		var card: Button = _goal_cards[key]
		_refresh_goal_card(card, _state.goal == key)


func _on_theme_changed(mode: String) -> void:
	_bg.color = DesignTokens.color(mode, "bg")
	_refresh_goal_cards()


## R7: radius 18, 2 px border, `surface` fill. [param filled] tints the fill slightly so the
## selected card reads as raised as well as outlined.
func _card_style(border_token: String, filled: bool) -> StyleBoxFlat:
	var mode := App.theme_mode
	var box := StyleBoxFlat.new()
	box.bg_color = DesignTokens.color(mode, "surface")
	var accent := DesignTokens.color(mode, border_token)
	box.border_color = accent
	box.set_border_width_all(2)
	box.set_corner_radius_all(int(DesignTokens.RADIUS["card"]))
	if filled:
		box.bg_color = Color(accent.r, accent.g, accent.b, 0.10)
	box.content_margin_left = 24.0
	box.content_margin_right = 24.0
	box.content_margin_top = 16.0
	box.content_margin_bottom = 16.0
	return box


## R16's drawn radio: a ring when unselected, a filled disc when chosen — the difference is
## shape as well as colour, which is what keeps the state legible in greyscale.
func _radio_style(selected: bool) -> StyleBoxFlat:
	var mode := App.theme_mode
	var box := StyleBoxFlat.new()
	box.set_corner_radius_all(int(RADIO_SIZE * 0.5))
	if selected:
		box.bg_color = DesignTokens.color(mode, "primary")
		box.border_color = DesignTokens.color(mode, "primary")
	else:
		box.draw_center = false
		box.border_color = DesignTokens.color(mode, "outline_strong")
	box.set_border_width_all(2)
	return box


# ===========================================================================
# Interaction
# ===========================================================================

func _on_area_toggled(pressed: bool, area: String) -> void:
	_state.set_area(area, pressed)
	_save_draft()
	_apply_footer()


func _on_days_selected(index: int) -> void:
	_state.set_days_per_week(index + 1)
	_save_draft()
	_apply_footer()


func _on_duration_selected(index: int) -> void:
	var _accepted := _state.set_duration_min(WizardState.DURATION_OPTIONS[index])
	_save_draft()
	_apply_footer()


func _on_goal_pressed(key: String) -> void:
	var _accepted := _state.set_goal(key)
	_refresh_goal_cards()
	_save_draft()
	_apply_footer()


## R3: the cap and the paste rule. `TextEdit` has no `max_length` in Godot 4.7.2, so this is
## the only place the 500-character limit exists — and it also owns moving the caret to the end
## after a truncation, which is what makes a long paste feel like it landed rather than vanished.
func _on_notes_changed() -> void:
	if _saving_notes:
		return
	var text := _notes_edit.text
	if text.length() > WizardState.NOTES_MAX:
		text = text.substr(0, WizardState.NOTES_MAX)
		_saving_notes = true
		_notes_edit.text = text
		_saving_notes = false
		var last_line := maxi(_notes_edit.get_line_count() - 1, 0)
		_notes_edit.set_caret_line(last_line)
		_notes_edit.set_caret_column(_notes_edit.get_line(last_line).length())
	_state.set_notes(text)
	_refresh_counter()
	_save_draft()
	_apply_footer()


func _on_review_edit(step: int) -> void:
	_go_to(step)


func _on_next_pressed() -> void:
	if _busy:
		return
	if _step == WizardState.STEP_REVIEW:
		# `_generate()` is now synchronous — it either opens the no-AI dialog or starts
		# `_run_generation()`, whose awaits continue on their own.
		_generate()
		return
	if not _state.is_step_valid(_step):
		return
	_go_to(_step + 1)


## One path for every "go back" affordance: the footer `Back`/`Cancel`, `ui_cancel`, and
## Android's back button (R2.3). Mid-flow it steps back; on step 0 it leaves.
func _on_back_pressed() -> void:
	if _dialogs_open():
		_close_dialogs()
		return
	if _busy:
		return
	if _notes_edit != null and _notes_edit.has_focus():
		_notes_edit.release_focus()
		return
	if _step == WizardState.STEP_NOTES:
		_request_close()
		return
	_go_to(_step - 1)


## R2.3: a pristine setup pops immediately; anything the owner typed gets the confirmation.
func _request_close() -> void:
	if _busy or _dialogs_open():
		return
	if _state.is_pristine():
		Nav.pop()
		return
	_discard_dialog.popup_centered()


func _on_discard_confirmed() -> void:
	_clear_draft()
	Nav.pop()


func _on_reset_pressed() -> void:
	_start_over_dialog.popup_centered()


func _on_start_over_confirmed() -> void:
	_state.reset()
	_clear_draft()
	_refresh_all()
	_go_to(WizardState.STEP_NOTES)


func _dialogs_open() -> bool:
	return (_discard_dialog != null and _discard_dialog.visible) \
			or (_start_over_dialog != null and _start_over_dialog.visible) \
			or (_no_ai_dialog != null and _no_ai_dialog.visible)


func _close_dialogs() -> void:
	if _discard_dialog != null and _discard_dialog.visible:
		_discard_dialog.hide()
	if _start_over_dialog != null and _start_over_dialog.visible:
		_start_over_dialog.hide()
	if _no_ai_dialog != null and _no_ai_dialog.visible:
		_no_ai_dialog.hide()
# ===========================================================================
# R9 — the draft
# ===========================================================================

func _save_draft() -> void:
	if not _accept_draft_writes:
		return
	if not Store.set_setting("ui.wizard_draft", _state.to_dict()):
		# Best effort (PRD-08 §8): a draft that cannot be written must never block navigation
		# or generation.
		print("[wizard] draft save failed")


func _clear_draft() -> void:
	var _cleared := Store.set_setting("ui.wizard_draft", {})


func _load_draft() -> void:
	var raw: Variant = Store.get_setting("ui.wizard_draft", {})
	if not (raw is Dictionary):
		return
	var draft: Dictionary = raw
	if draft.is_empty():
		return
	if not WizardState.is_fresh(draft):
		print("[wizard] draft stale ignored")
		_clear_draft()
		return
	_state.apply_dict(draft)
	print("[wizard] draft restored areas=%d days=%d duration=%d" % [
		_state.areas.size(), _state.days_per_week, _state.duration_min])


# ===========================================================================
# R10 — generation
# ===========================================================================

func _generate() -> void:
	if _busy or not _state.is_complete():
		return
	if LLM.is_generating:
		Feedback.toast(BUSY_TOAST)
		return

	# Owner request (2026-10-02): with nothing saved, Generate silently built an offline plan;
	# the owner asked to be taken to the API fields instead. The dialog keeps the offline path
	# one tap away, so a phone without a key can still build its week.
	if not LLM.is_configured():
		print("[wizard] no-ai dialog opened")
		_no_ai_dialog.popup_centered()
		return
	_run_generation()


## The generation await — the old `_generate()` body, unchanged. Reached when a provider is
## configured, or when the owner chose `Build on-device` in the no-AI dialog. The guard makes a
## double-tap on either path a no-op instead of a second concurrent generation.
func _run_generation() -> void:
	if _busy or LLM.is_generating:
		return
	# R9/R13: the wizard owns the seed. The first generation takes the clock; a regeneration
	# takes `seed + 1` (the preview's job), so identical inputs plus a seed stay reproducible.
	_state.seed = int(Time.get_unix_time_from_system())
	var request := _state.to_request(_equipment())
	_begin_generation()

	var started := Time.get_ticks_msec()
	var result: Dictionary = await LLM.generate_plan(request, {"seed": _state.seed})
	await _hold_overlay_open(started)
	await _end_generation()

	var elapsed := Time.get_ticks_msec() - started
	var source := PlanModel.as_text(result.get("source"), "")
	var reason := PlanModel.as_text(result.get("reason_code"), "")
	print("[wizard] generate source=%s reason_code=%s attempts=%d elapsed_ms=%d" % [
		source, reason, PlanModel.as_int(result.get("attempts"), 0), elapsed])

	# R10: the two outcomes that are not fallbacks. Neither one writes anything.
	if reason == "cancelled":
		print("[wizard] generate cancelled")
		Feedback.toast(CANCELLED_TOAST)
		return
	if reason == "busy":
		Feedback.toast(BUSY_TOAST)
		return

	var plan: Variant = result.get("plan", {})
	if not bool(result.get("ok", false)) or source.is_empty() \
			or not (plan is Dictionary) or (plan as Dictionary).is_empty():
		# The built-in generator could not run either. PRD-07 has no user copy for this state
		# (it means the library is missing, not that the provider failed), so the result's own
		# message is preferred and this screen's single fallback sentence is the last resort.
		var message := PlanModel.as_text(result.get("user_message"), "")
		Feedback.toast(message if not message.is_empty() else BUILTIN_FAILED_TOAST, &"warning")
		return

	# PRD-12 R8: a fallback still saves a plan, and the owner is told which one and why. The
	# wording is PRD-07's `user_message` — R8 forbids inventing copy here.
	if source == "builtin" and not reason.is_empty():
		var fallback_message := PlanModel.as_text(result.get("user_message"), "")
		if not fallback_message.is_empty():
			Feedback.toast(fallback_message, &"warning")

	var sessions := WizardState.plain_list((plan as Dictionary).get("sessions", []))
	print("[wizard] preview sessions=%d" % sessions.size())
	Nav.push(Routes.PLAN_PREVIEW, {
		"plan": plan,
		"state": _state.to_dict(),
		"state_full": _state.to_full_dict(),
		"result": result,
		"entry": _entry,
	})


func _begin_generation() -> void:
	_busy = true
	_elapsed_base_ms = Time.get_ticks_msec()
	_apply_footer()
	_back_button.disabled = true
	_close_button.disabled = true
	var root := _overlay_root()
	if root != null:
		root.modulate.a = 0.0
	_overlay.start(_phase_title(0))
	_overlay.set_sub_text(_phase_sub(0))
	# PRD-12 R8's no-key row: the wizard still generates (the built-in generator needs nothing),
	# and the owner is told what is about to happen instead of wondering why it is instant.
	# Reached only via the dialog's `Build on-device` (a configured provider gets no note).
	if not LLM.is_configured():
		_overlay.set_sub_text(NO_KEY_NOTE)
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
	_back_button.disabled = false
	_close_button.disabled = false
	_apply_footer()
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


## R10: the overlay is held for at least 600 ms so a fast local generation does not flash.
func _hold_overlay_open(started_ms: int) -> void:
	var remaining := OVERLAY_MIN_MS - (Time.get_ticks_msec() - started_ms)
	if remaining > 0:
		await get_tree().create_timer(float(remaining) / 1000.0).timeout


## R10's phase table, driven **only** by elapsed time: PRD-07 exposes no progress signal for the
## ladder, and this screen must not invent one.
func _on_generation_tick() -> void:
	if not _busy:
		return
	var seconds := int(floorf(float(Time.get_ticks_msec() - _elapsed_base_ms) / 1000.0))
	_overlay.set_message(_phase_title(seconds))
	_overlay.set_sub_text("%s · %s" % [_phase_sub(seconds), _mmss(seconds)])


func _phase_title(seconds: int) -> String:
	if seconds > PHASE_FALLBACK_SEC:
		return "Building your week on-device…"
	if seconds > PHASE_VALIDATING_SEC:
		return "Double-checking the plan…"
	if seconds > PHASE_WAITING_SEC:
		return "Writing your week…"
	return "Talking to %s…" % _provider_label()


func _phase_sub(seconds: int) -> String:
	if seconds > PHASE_FALLBACK_SEC:
		return "No AI needed — this always works."
	if seconds > PHASE_VALIDATING_SEC:
		return "Making sure every exercise is one you can actually do."
	if seconds > PHASE_WAITING_SEC:
		return "Personalizing from your notes and your picks."
	return "This usually takes 5–20 seconds."


## `"M:SS"` — R10's elapsed clock. Integer seconds, so it ticks with `GenTimer`'s 1 s period.
func _mmss(seconds: int) -> String:
	var minutes := int(floorf(float(seconds) / 60.0))
	return "%d:%02d" % [minutes, seconds % 60]


## R10's `{Provider}`. PRD-07's preset table is the source of every label except `custom`, where
## the owner's own name for their server wins (and "Custom" is the documented fallback).
func _provider_label() -> String:
	var provider := PlanModel.as_text(
		Store.get_setting("llm.provider", LLMProviders.DEFAULT_KEY), LLMProviders.DEFAULT_KEY)
	if provider == "custom":
		var named := PlanModel.as_text(Store.get_setting("llm.custom_name", ""), "").strip_edges()
		return named if not named.is_empty() else "Custom"
	if not LLMProviders.has(provider):
		return LLMProviders.label_for(LLMProviders.DEFAULT_KEY)
	return LLMProviders.label_for(provider)


## R9: the equipment list comes from `Store`, and PRD-00 D3's full-gym list is the default. No
## PRD has shipped an `equipment` settings key yet, so `get_setting` returns the default — which
## is exactly the documented behaviour and keeps this correct the day one appears.
func _equipment() -> Array[String]:
	var out: Array[String] = []
	var configured: Variant = Store.get_setting("equipment", Generator.DEFAULT_EQUIPMENT)
	for entry in WizardState.plain_list(configured):
		var key := PlanModel.as_text(entry, "")
		if not key.is_empty() and not out.has(key):
			out.append(key)
	if out.is_empty():
		for entry in Generator.DEFAULT_EQUIPMENT:
			out.append(entry)
	return out


## The overlay's own root `Control`. PRD-07's component is a `CanvasLayer` (which has no
## `modulate`), so R10's 180 ms fade is applied one level in.
func _overlay_root() -> Control:
	if _overlay == null:
		return null
	return _overlay.get_node_or_null(^"Root") as Control


func _motion_enabled() -> bool:
	if not is_inside_tree():
		return false
	return not bool(App.get_setting("ui.reduce_motion", false))


# ===========================================================================
# Diagnostics
# ===========================================================================

## The greppable line PRD-02 R6 requires of every screen that owns controls.
func _report_touch_targets() -> void:
	var _violations := TouchTargets.report(self)
