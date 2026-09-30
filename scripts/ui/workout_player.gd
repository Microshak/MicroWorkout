extends Control
## PRD-10 R1–R17 — the workout player: the core experience of the app.
##
## The owner taps **Start workout** and is walked, exercise by exercise, through their session:
## an animated illustration, the name, sets × reps and rest, per-set check-off, a rest countdown,
## warm-up and cool-down sub-flows, a progress bar across the whole session, then the celebration.
##
## What owns what (the boundaries that keep this file honest):
##
## * **`SessionRun` owns the session.** Which step is showing, which sets are checked, how many
##   seconds are active — all of it lives in `scripts/core/session_run.gd` and this file only drives
##   it and renders it. There is exactly one session state model in the app (R3).
## * **`exercise_thumbnail` owns the flipbook.** The player calls `set_exercise()` and flips the
##   component's `animate` switch; it never touches `Frame.texture` (R4).
## * **`Store` owns persistence.** History goes through `Store.add_entry()` — which emits
##   `entry_added`, the signal Home listens to, so this screen adds no completion signal of its own
##   (R1) — and in-progress state through `Store.save_session_progress()` (R13).
## * **`Nav` owns navigation.** Every exit goes through `Nav`, and `set_back_handling(false)` is set
##   while the player owns back and restored on **every** exit path, including an early
##   `queue_free` — leaving it false would silently break back everywhere else in the app (R14).
## * **`Feedback` owns toasts and cues.** `_sfx()` maps PRD-10's fine-grained names onto
##   PRD-12's five cues, so every interaction lands on a sound and a haptic (R7, AC14).
##
## Three things about this screen are easy to get wrong and are therefore stated once, here:
##
## 1. **`Nav` is busy while a screen is being pushed.** `Nav._swap_screen()` calls `setup()` *inside*
##    its transition, and every `Nav` verb is dropped while `is_transitioning()` — so R1's
##    "that session is gone" exit cannot call `Nav.pop_to_root()` from `setup()`. [method
##    _leave_when_ready] waits for the router instead, which is also why every exit goes through it.
## 2. **`_process()` does nothing.** The active clock, the timed-step label, the progress save and the
##    flipbook all tick on timers or signals (R17), which is what keeps an idle player at 0 % CPU.
## 3. **R7's `BlockDoneChip` needed a row.** It appears *beside* `SetCounterLabel`, so `SetGroup`
##    starts with a `SetCounterRow` HBoxContainer holding both. R2's tree lists the label as a direct
##    child of `SetGroup`; the wrapper is the only way to honour R7's "beside".

# ===========================================================================
# Constants
# ===========================================================================

## R11's states. `REST` is an **overlay**: `SessionRun.state` stays `ACTIVE` while the rest sheet
## is up, and only `PAUSED`/`COMPLETING` move the model. The `ZOOMED` sub-state is gone — the
## illustration is the swipe surface and a tap on it does nothing (ADR-31).
const STATE_LOADING := "LOADING"
const STATE_ACTIVE := "ACTIVE"
const STATE_REST := "REST"
const STATE_PAUSED := "PAUSED"
const STATE_CONFIRM_QUIT := "CONFIRM_QUIT"
const STATE_COMPLETING := "COMPLETING"
const STATE_FINISHED := "FINISHED"
const STATE_EXITED := "EXITED"

## R11's transition table, verbatim. Anything not listed is rejected and logged.
const TRANSITIONS: Dictionary = {
	STATE_LOADING: [STATE_ACTIVE],
	STATE_ACTIVE: [STATE_REST, STATE_PAUSED, STATE_COMPLETING],
	STATE_REST: [STATE_ACTIVE, STATE_PAUSED],
	STATE_PAUSED: [STATE_ACTIVE, STATE_REST, STATE_COMPLETING, STATE_CONFIRM_QUIT],
	STATE_CONFIRM_QUIT: [STATE_PAUSED, STATE_EXITED],
	STATE_COMPLETING: [STATE_FINISHED],
	STATE_FINISHED: [],
	STATE_EXITED: [],
}

## R11's copy, verbatim.
const TOAST_SESSION_GONE := "That session is gone — pick one from your plan."
const TOAST_STALE_PROGRESS := "That workout isn't in this plan any more — starting fresh."
const TOAST_DISCARDED := "Session discarded."
const TOAST_SAVED_PARTIAL := "Saved — %d of %d exercises."
const TOAST_LOGGED_SETS := "Logged %d of %d sets."
const PAUSED_NOTE := "Been away a while — resume when you're ready."

## The footer hint that replaced the Previous/Next row (owner request, ADR-24).
const SWIPE_HINT := "Swipe left or right to change exercise"
const SWIPE_HINT_FINISH := "Swipe left to finish"
## Gesture thresholds in design px: far enough to be deliberate, and strongly horizontal.
const SWIPE_MIN_PX := 140.0
const SWIPE_DOMINANCE := 1.25

## R7's chip geometry.
const CHIP_SIZE := 88.0
const CHIP_CHECK_SIZE := 44.0

## R14: coming back after this long leaves the owner on the pause sheet instead of mid-set.
const BACKGROUND_PAUSE_SEC := 1800

## R2's `AutoSaveTimer`: the active clock, the timed-step label and the progress save all tick here,
## which is what keeps `_process()` empty (R17).
const AUTOSAVE_SEC := 2.0

## The partial-block toast is the only comment `Next` ever makes, and only when some sets are in.
const KIND_BLOCK := SessionRun.KIND_BLOCK
const KIND_WARMUP := SessionRun.KIND_WARMUP

const GLYPH_SCENE := preload("res://scenes/components/glyph.tscn")

# ===========================================================================
# Nodes (R2)
# ===========================================================================

@onready var _background: ColorRect = $Background
@onready var _pause_button: Button = $SafeArea/Layout/TopBar/PauseButton
@onready var _block_counter: Label = $SafeArea/Layout/TopBar/TopCenter/BlockCounterLabel
@onready var _session_title: Label = $SafeArea/Layout/TopBar/TopCenter/SessionTitleLabel
@onready var _elapsed_label: Label = $SafeArea/Layout/TopBar/ElapsedLabel
@onready var _progress: HBoxContainer = $SafeArea/Layout/SessionProgress
@onready var _illustration_host: Control = $SafeArea/Layout/IllustrationSlot/IllustrationHost
@onready var _illustration: Control = $SafeArea/Layout/IllustrationSlot/IllustrationHost/Illustration
@onready var _name_label: Label = $SafeArea/Layout/NameLabel
@onready var _sets_reps_label: Label = $SafeArea/Layout/SetsRepsLabel
@onready var _rest_label: Label = $SafeArea/Layout/RestLabel
@onready var _cues_box: VBoxContainer = $SafeArea/Layout/CuesBox
@onready var _cue_labels: Array[Label] = [
	$SafeArea/Layout/CuesBox/CueLabel_0,
	$SafeArea/Layout/CuesBox/CueLabel_1,
	$SafeArea/Layout/CuesBox/CueLabel_2,
]
@onready var _set_group: VBoxContainer = $SafeArea/Layout/SetGroup
@onready var _set_counter_label: Label = $SafeArea/Layout/SetGroup/SetCounterRow/SetCounterLabel
@onready var _block_done_chip: PanelContainer = $SafeArea/Layout/SetGroup/SetCounterRow/BlockDoneChip
@onready var _set_row: HBoxContainer = $SafeArea/Layout/SetGroup/SetRow
@onready var _timer_row: VBoxContainer = $SafeArea/Layout/TimerRow
@onready var _timer_ring: Control = $SafeArea/Layout/TimerRow/TimerCenter/TimerRing
@onready var _timer_label: Label = $SafeArea/Layout/TimerRow/TimerLabel
@onready var _swipe_hint: Label = $SafeArea/Layout/SwipeRow/SwipeHint
@onready var _rest_sheet: PanelContainer = $RestSheet
@onready var _pause_sheet: Control = $PauseSheet
@onready var _pause_dim: ColorRect = $PauseSheet/PauseDim
@onready var _pause_stats: Label = $PauseSheet/PauseCenter/PauseCard/PauseVBox/PauseStatsLabel
@onready var _paused_note: Label = $PauseSheet/PauseCenter/PauseCard/PauseVBox/PausedNote
@onready var _resume_button: Button = $PauseSheet/PauseCenter/PauseCard/PauseVBox/ResumeButton
@onready var _restart_button: Button = $PauseSheet/PauseCenter/PauseCard/PauseVBox/RestartExerciseButton
@onready var _end_button: Button = $PauseSheet/PauseCenter/PauseCard/PauseVBox/EndWorkoutButton
@onready var _quit_button: Button = $PauseSheet/PauseCenter/PauseCard/PauseVBox/QuitButton
@onready var _confirm_dialog: ConfirmationDialog = $ConfirmQuitDialog
@onready var _auto_save_timer: Timer = $AutoSaveTimer

# ===========================================================================
# State
# ===========================================================================

var _plan: Dictionary = {}
var _session: Dictionary = {}
var _plan_id: String = ""
var _session_id: String = ""
var _resume: bool = false
var _early: bool = false
var _run: SessionRun = null

var _state: String = STATE_LOADING
var _state_before_pause: String = STATE_ACTIVE
var _paused_by_background: bool = false

## Swipe tracking (ADR-24): where the current touch started, and whether this gesture already
## navigated — one drag fires once, and its release is swallowed instead of clicking through.
var _touch_origin: Vector2 = Vector2.ZERO
var _touch_active: bool = false
var _swipe_consumed: bool = false

## Active-clock bookkeeping (R9/R14): whole seconds are folded into `SessionRun.elapsed_sec` and the
## remainder waits here, so a 1.99 s tick never loses a second.
var _clock_ms: int = 0
var _clock_started_ms: int = 0

var _segments: Array[Control] = []
var _segment_styles: Dictionary = {}
var _chips: Array[Dictionary] = []

var _timer_tween: Tween = null
var _timer_done: bool = false

var _frame_cycles: int = 0
var _frame_off_start: bool = false
var _frame_log_started_ms: int = 0

var _backgrounded_at: int = 0

## R10's second vibration of the pair, counted down by a one-shot timer.
var _extra_vibrations: int = 0

## Set once an exit has begun, so a second tap (or a repeated back gesture) cannot exit twice.
var _exit_started: bool = false

# ===========================================================================
# Lifecycle
# ===========================================================================

func _ready() -> void:
	_background.color = DesignTokens.color(App.theme_mode, "bg")
	_pause_dim.color = _dim_colour()

	if not App.theme_changed.is_connected(_on_theme_changed):
		App.theme_changed.connect(_on_theme_changed)

	_pause_button.pressed.connect(_on_pause_pressed)
	# The illustration host ignores the mouse (`mouse_filter = IGNORE` in the scene): the artwork
	# is the swipe surface, a tap on it does nothing, and it can never eat the drag (ADR-31).
	_resume_button.pressed.connect(_on_resume_pressed)
	_restart_button.pressed.connect(_on_restart_pressed)
	_end_button.pressed.connect(_on_end_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)

	_confirm_dialog.confirmed.connect(_on_quit_confirmed)
	_confirm_dialog.canceled.connect(_on_quit_cancelled)
	_style_dialog(_confirm_dialog)

	_rest_sheet.connect(&"skipped", _on_rest_skipped)
	_rest_sheet.connect(&"finished", _on_rest_finished)
	_rest_sheet.connect(&"time_added", _on_rest_time_added)

	_illustration.connect(&"frame_changed", _on_frame_changed)

	_auto_save_timer.wait_time = AUTOSAVE_SEC
	_auto_save_timer.timeout.connect(_on_autosave_tick)

	# The screen owns back while it is up (R14); every exit path gives it back.
	Nav.set_back_handling(false)

	_set_group.visible = false
	_timer_row.visible = false
	_pause_sheet.visible = false
	_paused_note.visible = false


## `Nav` calls this right after `add_child` (PRD-02's push order).
func setup(args: Dictionary) -> void:
	_plan_id = String(args.get("plan_id", ""))
	_session_id = String(args.get("session_id", ""))
	_resume = bool(args.get("resume", false))
	_early = bool(args.get("early", false))

	if not _resolve():
		Feedback.toast(TOAST_SESSION_GONE, &"warning")
		_leave_when_ready()
		return
	_begin()


func _exit_tree() -> void:
	# An early `queue_free` (a plan deleted under the player, a test tearing the tree down) must not
	# leave back handling disabled or the screen pinned awake (R14).
	_release_screen_and_back()
	_stop_timer_tween()


# ===========================================================================
# Resolution and start (R1)
# ===========================================================================

## `plan = Store.get_plan(plan_id)` — falling back to the active plan when `plan_id` is `""` — and
## `session` = the one whose id matches. `false` when either is missing, so the caller toasts and
## leaves instead of showing an empty player.
func _resolve() -> bool:
	if _plan_id.is_empty():
		_plan = Store.active_plan()
	else:
		_plan = Store.get_plan(_plan_id)
	if _plan.is_empty():
		return false
	var wanted := _session_id
	var sessions: Array = _plan.get("sessions", [])
	for element in sessions:
		if not (element is Dictionary):
			continue
		var candidate: Dictionary = element
		if wanted.is_empty() or String(candidate.get("id", "")) == wanted:
			_session = candidate
			break
	if _session.is_empty():
		return false
	_plan_id = String(_plan.get("id", ""))
	_session_id = String(_session.get("id", ""))
	return true


func _begin() -> void:
	_run = SessionRun.build(_plan, _session)
	_run.started_at = int(Time.get_unix_time_from_system())
	_session_title.text = _run.session_title

	var restored := false
	if _resume:
		restored = _restore_progress()

	var flags := ""
	if restored:
		flags = " resume=1"
	elif _early:
		flags = " early=1"
	# The start line comes **before** the first step line, so a logcat reader sees the session and
	# then what it is showing — AC15's expected sequence is a direct grep of this order.
	print("[player] start plan=%s session=%s steps=%d blocks=%d sets=%d%s" % [
		_run.plan_id, _run.session_id, _run.total_steps(), _run.block_count(),
		_run.total_sets(), flags])

	_build_progress_segments()
	_set_state(STATE_ACTIVE)
	_apply_step()
	_clock_start()
	_keep_screen_on(true)
	_auto_save_timer.start()


## R13's resume path. Returns `true` when a stored cursor was adopted.
func _restore_progress() -> bool:
	var stored := Store.load_session_progress()
	if stored.is_empty():
		return false
	if String(stored.get("plan_id", "")) != _run.plan_id \
			or String(stored.get("session_id", "")) != _run.session_id:
		# The plan changed under the record: start fresh, loudly, rather than restoring a cursor that
		# points at exercises the owner is no longer being asked to do.
		Store.clear_session_progress()
		Feedback.toast(TOAST_STALE_PROGRESS, &"warning")
		return false

	_run = SessionRun.from_dict(stored, _plan, _session)
	var exercise_id := _run.current_exercise_id()
	print("[player] progress restored step=%d sets=%d/%d elapsed=%d" % [
		_run.step_index, _run.sets_checked(exercise_id), _run.block_sets(exercise_id),
		_run.elapsed_sec])
	return true


# ===========================================================================
# Step rendering (R5, R6, R8, R9)
# ===========================================================================

func _apply_step() -> void:
	var step := _run.current_step()
	if step.is_empty():
		return
	var exercise_id := _run.current_exercise_id()
	var kind := _run.step_kind()

	_name_label.text = Library.name_of(exercise_id)
	_update_identity(kind)
	_update_cues(exercise_id)
	_update_illustration(exercise_id)
	_warm_next_frames()
	_block_counter.text = _counter_text(step)
	_swipe_hint.text = SWIPE_HINT_FINISH if _run.is_last_step() else SWIPE_HINT
	_repaint_progress()

	if kind == KIND_BLOCK:
		_timer_done = false
		_stop_timer_tween()
		_timer_row.visible = false
		_build_set_chips(step)
	else:
		_start_timed_step(step)

	print("[player] step=%d kind=%s ex=%s%s" % [
		_run.step_index, kind, exercise_id, _step_log_tail(step)])
	# The strings that are on screen, so AC4's label matrix and AC14's "sets × reps and rest are
	# readable" are greppable facts rather than a claim about a picture nobody can read.
	print("[player] labels name=\"%s\" sets_reps=\"%s\" rest=\"%s\" cues=%d next=\"%s\"" % [
		_name_label.text, _sets_reps_label.text,
		_rest_label.text if _rest_label.visible else "", _visible_cues(),
		_run.next_label()])
	UiProbe.log_rects_settled(get_tree(), {
		# The central illustration area is the swipe surface (ADR-24/31): the device flows swipe
		# across it, and neither a Next button nor a tap-zoom sits under the finger.
		"player_swipe": _illustration_host,
		"player_pause": _pause_button,
		"player_illustration": _illustration_host,
	})


func _visible_cues() -> int:
	var shown := 0
	for label in _cue_labels:
		if label.visible and not label.text.is_empty():
			shown += 1
	return shown


func _step_log_tail(step: Dictionary) -> String:
	if _run.step_kind() == KIND_BLOCK:
		return " sets=%d rest=%d" % [
			int(step.get("sets", 0)), int(step.get("rest_seconds", 0))]
	return " duration=%d" % int(step.get("duration_sec", 0))


func _update_identity(kind: String) -> void:
	var step := _run.current_step()
	_set_group.visible = kind == KIND_BLOCK
	if kind != KIND_BLOCK:
		_sets_reps_label.text = "%ds" % int(step.get("duration_sec", 0))
		_rest_label.visible = false
		return
	_sets_reps_label.text = "%d × %s" % [int(step.get("sets", 0)), String(step.get("reps", ""))]
	var rest_seconds := int(step.get("rest_seconds", 0))
	_rest_label.visible = rest_seconds > 0
	_rest_label.text = "%ds rest" % rest_seconds


## R5: up to three `Library.get_cues()` lines under the `FORM TIPS` title; the whole box hides when
## the exercise has none, so a cue-less exercise shows no title over nothing.
func _update_cues(exercise_id: String) -> void:
	var cues := Library.get_cues(exercise_id)
	_cues_box.visible = not cues.is_empty()
	for index in _cue_labels.size():
		var label: Label = _cue_labels[index]
		if index < cues.size():
			label.text = String(cues[index])
			label.visible = true
		else:
			label.text = ""
			label.visible = false


func _update_illustration(exercise_id: String) -> void:
	_illustration.set(&"animate", true)
	_illustration.call(&"set_exercise", exercise_id, Library.get_frames(exercise_id))
	_illustration.modulate = DesignTokens.color(App.theme_mode, "text")
	_frame_off_start = false


## R4: warm the next step's frames so a step change never stalls on disk I/O on the emulator. The
## component owns the textures; this only asks the loader to have them ready.
func _warm_next_frames() -> void:
	var index := _run.step_index + 1
	if index >= _run.total_steps():
		return
	var next_step: Dictionary = _run.steps[index]
	for path in Library.get_frames(String(next_step.get("exercise_id", ""))):
		if ResourceLoader.exists(path):
			ResourceLoader.load_threaded_request(path)


func _counter_text(step: Dictionary) -> String:
	var kind := String(step.get("kind", ""))
	if kind == KIND_BLOCK:
		return "Exercise %d of %d" % [int(step.get("block_index", 0)) + 1, _run.block_count()]
	var index := int(step.get("group_index", 0)) + 1
	var total := _count_kind(kind)
	if kind == KIND_WARMUP:
		return "Warm-up %d of %d" % [index, total]
	return "Cool-down %d of %d" % [index, total]


func _count_kind(kind: String) -> int:
	var total := 0
	for step in _run.steps:
		if String(step.get("kind", "")) == kind:
			total += 1
	return total


# ===========================================================================
# Session progress (R6)
# ===========================================================================

## R6: exactly `total_steps` segments, built at runtime and never authored in the scene.
func _build_progress_segments() -> void:
	for child in _progress.get_children():
		child.queue_free()
	_segments.clear()
	for index in _run.total_steps():
		var step: Dictionary = _run.steps[index]
		var panel := Panel.new()
		panel.name = "Segment_%d" % index
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if String(step.get("kind", "")) == KIND_BLOCK:
			panel.custom_minimum_size = Vector2(0, 8)
		else:
			# Mobility work reads thinner and vertically centred, so working blocks stand out.
			panel.custom_minimum_size = Vector2(0, 4)
			panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_progress.add_child(panel)
		_segments.append(panel)


## R6: `current` beats `done`, and a block turns `success` the moment every set is checked —
## independent of where the cursor is, so the owner watches their work accumulate behind them.
func _repaint_progress() -> void:
	for index in _segments.size():
		var panel: Control = _segments[index]
		var step: Dictionary = _run.steps[index]
		var token := "outline"
		if String(step.get("kind", "")) == KIND_BLOCK \
				and _run.block_done(String(step.get("exercise_id", ""))):
			token = "success"
		if index == _run.step_index:
			token = "primary"
		panel.add_theme_stylebox_override(&"panel", _segment_style(token))


## One shared `StyleBoxFlat` per token: the segments are read-only and identical, so repainting a
## 7-step session does not allocate seven boxes (R17).
func _segment_style(token: String) -> StyleBoxFlat:
	if _segment_styles.has(token):
		return _segment_styles[token]
	var style := StyleBoxFlat.new()
	style.bg_color = DesignTokens.color(App.theme_mode, token)
	style.set_corner_radius_all(4)
	_segment_styles[token] = style
	return style


# ===========================================================================
# Set check-off (R7)
# ===========================================================================

func _build_set_chips(step: Dictionary) -> void:
	for child in _set_row.get_children():
		_set_row.remove_child(child)
		child.queue_free()
	_chips.clear()
	var sets := int(step.get("sets", 0))
	var exercise_id := _run.current_exercise_id()
	for index in sets:
		_set_row.add_child(_make_set_chip(index))
	_update_set_counter(exercise_id, sets)
	_update_block_done_chip(exercise_id)
	_sync_chip_states(exercise_id)
	_publish_chip_rects.call_deferred()


func _make_set_chip(index: int) -> Button:
	var chip := Button.new()
	chip.name = "SetChip_%d" % (index + 1)
	chip.custom_minimum_size = Vector2(CHIP_SIZE, CHIP_SIZE)
	chip.toggle_mode = true
	chip.focus_mode = Control.FOCUS_NONE
	chip.theme_type_variation = &"ChipToggle"
	chip.text = str(index + 1)
	A11y.label(chip, "Set %d" % (index + 1), "Check off this set")

	# Per-chip duplicated styleboxes, so the fill can be tweened between `surface_alt` and `success`
	# without touching the shared theme (R7's "fill tweens to success").
	var normal := _duplicate_style(chip.get_theme_stylebox(&"normal"))
	var pressed := _duplicate_style(chip.get_theme_stylebox(&"pressed"))
	if normal != null:
		normal.bg_color = DesignTokens.color(App.theme_mode, "surface_alt")
		chip.add_theme_stylebox_override(&"normal", normal)
	if pressed != null:
		pressed.bg_color = DesignTokens.color(App.theme_mode, "success")
		chip.add_theme_stylebox_override(&"pressed", pressed)

	var check: Control = GLYPH_SCENE.instantiate()
	check.name = "Check"
	check.set(&"kind", &"check")
	check.custom_minimum_size = Vector2(CHIP_CHECK_SIZE, CHIP_CHECK_SIZE)
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	check.set_anchors_preset(Control.PRESET_CENTER)
	check.offset_left = -CHIP_CHECK_SIZE * 0.5
	check.offset_top = -CHIP_CHECK_SIZE * 0.5
	check.offset_right = CHIP_CHECK_SIZE * 0.5
	check.offset_bottom = CHIP_CHECK_SIZE * 0.5
	check.modulate.a = 0.0
	chip.add_child(check)

	chip.toggled.connect(_on_set_toggled.bind(index))
	_chips.append({"button": chip, "check": check, "normal": normal, "pressed": pressed})
	return chip


static func _duplicate_style(style: StyleBox) -> StyleBoxFlat:
	if style is StyleBoxFlat:
		return (style as StyleBoxFlat).duplicate() as StyleBoxFlat
	return null


## The model is authoritative on step entry (and after a resume), so the chips are pushed to it
## without emitting `toggled` — a restored check must not start a rest timer.
func _sync_chip_states(exercise_id: String) -> void:
	for index in _chips.size():
		var chip: Dictionary = _chips[index]
		var button: Button = chip["button"]
		var checked := _run.is_set_checked(exercise_id, index)
		button.set_pressed_no_signal(checked)
		var check: Control = chip["check"]
		check.modulate.a = 1.0 if checked else 0.0


## R7's table. The Button flips its own `toggle_mode` state before this runs, so the model is
## reconciled against the UI rather than blindly toggled — the two can never drift.
func _on_set_toggled(pressed: bool, index: int) -> void:
	if _state != STATE_ACTIVE && _state != STATE_REST:
		_revert_chip(index, pressed)
		return
	var exercise_id := _run.current_exercise_id()
	if _run.is_set_checked(exercise_id, index) != pressed:
		if _run.set_toggle(exercise_id, index) != pressed:
			_revert_chip(index, pressed)
			return
	_cancel_rest(false)
	var sets := _run.block_sets(exercise_id)
	var checked := _run.sets_checked(exercise_id)
	_animate_chip(index, pressed)
	_update_set_counter(exercise_id, sets)
	var block_done := _run.block_done(exercise_id)
	if block_done:
		_show_block_done_chip()
	else:
		_block_done_chip.visible = false
	_repaint_progress()
	_save_progress(false)

	print("[player] set ex=%s n=%d checked=%d/%d" % [exercise_id, index + 1, checked, sets])

	if not pressed:
		_sfx(&"set_undo")
		return
	_sfx(&"set_ok")
	Input.vibrate_handheld(30)
	if block_done:
		_sfx(&"block_done")
		Input.vibrate_handheld(60)
	_maybe_start_rest(index, sets)


func _revert_chip(index: int, pressed: bool) -> void:
	if index < 0 or index >= _chips.size():
		return
	var button: Button = _chips[index]["button"]
	button.set_pressed_no_signal(not pressed)


## R7: checked pops 1.0 → 1.25 → 1.0 over 200 ms (PRD-00 §9's set-complete pop) and the check glyph
## fades in; unchecked is the smaller 120 ms acknowledge. State first, animation second (R16).
func _animate_chip(index: int, checked: bool) -> void:
	if index < 0 or index >= _chips.size():
		return
	var chip: Dictionary = _chips[index]
	var button: Button = chip["button"]
	var check: Control = chip["check"]
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	if checked:
		tween.tween_property(button, "scale", Vector2(1.25, 1.25), 0.1)
		tween.tween_property(button, "scale", Vector2.ONE, 0.1)
		tween.parallel().tween_property(check, "modulate:a", 1.0, 0.12)
	else:
		tween.tween_property(button, "scale", Vector2(0.94, 0.94), 0.06)
		tween.tween_property(button, "scale", Vector2.ONE, 0.06)
		tween.parallel().tween_property(check, "modulate:a", 0.0, 0.06)


func _update_set_counter(exercise_id: String, sets: int) -> void:
	_set_counter_label.text = "%d/%d sets" % [_run.sets_checked(exercise_id), sets]


## R7: the chip is a `Caption` on a `success` fill at 22 %, appearing over 160 ms. R7's 8 px rise is
## rendered as a 0.92 → 1.0 scale because the chip is a container child and a container re-sort
## would snap a tweened `position.y` back mid-animation — the same "it just appeared" affordance
## without the fight. No sound of its own: the block's own cue already fired.
func _show_block_done_chip() -> void:
	if _block_done_chip.visible:
		return
	_block_done_chip.modulate.a = 0.0
	_block_done_chip.visible = true
	_block_done_chip.scale = Vector2(0.92, 0.92)
	_block_done_chip.pivot_offset = _block_done_chip.size * 0.5
	var style := _duplicate_style(_block_done_chip.get_theme_stylebox(&"panel"))
	if style == null:
		style = StyleBoxFlat.new()
		style.set_corner_radius_all(12)
	var fill := DesignTokens.color(App.theme_mode, "success")
	fill.a = 0.22
	style.bg_color = fill
	_block_done_chip.add_theme_stylebox_override(&"panel", style)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(_block_done_chip, "modulate:a", 1.0, 0.16)
	tween.tween_property(_block_done_chip, "scale", Vector2.ONE, 0.16)


## The Android acceptance flow taps chips by name, and a chip is built at runtime — so its rect is
## published one frame after the row lays out, because a rect read before the container has sorted
## its children is a rect of zero size.
func _publish_chip_rects() -> void:
	var entries := {}
	for index in _chips.size():
		# Step-scoped names: a chip rect from a previous step would be a tap that lands on the wrong
		# block's padding the moment the set count changes (a 3-set row is centred differently from a
		# 4-set row).
		entries["player_%d_set_%d" % [_run.step_index, index + 1]] = _chips[index]["button"]
	UiProbe.log_rects_settled(get_tree(), entries)


func _update_block_done_chip(exercise_id: String) -> void:
	var done := _run.block_done(exercise_id)
	_block_done_chip.visible = done
	_block_done_chip.modulate.a = 1.0
	_block_done_chip.scale = Vector2.ONE


# ===========================================================================
# Rest timer (R10)
# ===========================================================================

## R10: rest appears after a set when it was not the block's last set, the block asked for rest, and
## the owner has rest timing on. It never gates anything — `Next`, `Previous`, `Pause` and another
## set check all stay live while it runs.
func _maybe_start_rest(index: int, sets: int) -> void:
	if index >= sets - 1:
		return
	var rest_seconds := int(_run.current_step().get("rest_seconds", 0))
	if rest_seconds <= 0:
		return
	if not bool(Store.get_setting("rest_timer.enabled", true)):
		return
	_anchor_rest_sheet()
	_set_state(STATE_REST)
	_rest_sheet.call(&"start_rest", rest_seconds)
	print("[player] rest start=%d" % rest_seconds)


## R10: "the rest timer never gates ... another set check". The sheet is anchored to end where the
## chip row starts, measured from the row itself rather than from a fixed offset, so the chips stay
## tappable on any screen size and the owner can check the next set without touching the timer.
func _anchor_rest_sheet() -> void:
	if not _set_row.is_visible_in_tree() or size.y <= 0.0:
		return
	var row_top := _set_row.get_global_rect().position.y
	if row_top <= 0.0:
		return
	var offset := row_top - size.y
	_rest_sheet.call(&"set_bottom_offset", maxf(offset, -size.y))


## Cancels the countdown and hides the sheet. `play_skip` is R10's `Skip rest` sound; every other
## cancellation (Next, Previous, Pause, another check, backgrounding) is silent.
func _cancel_rest(play_skip: bool) -> void:
	if _state == STATE_REST:
		_set_state(STATE_ACTIVE)
	var was_running := bool(_rest_sheet.call(&"is_running"))
	if play_skip and was_running:
		_sfx(&"rest_skip")
	_rest_sheet.call(&"stop_rest")


func _on_rest_skipped() -> void:
	_sfx(&"rest_skip")
	if _state == STATE_REST:
		_set_state(STATE_ACTIVE)


## R10: at zero the cue is one `rest_done` sound plus `vibrate_handheld(120)` twice, 160 ms apart.
func _on_rest_finished() -> void:
	_sfx(&"rest_done")
	Input.vibrate_handheld(120)
	_extra_vibrations = 1
	get_tree().create_timer(0.16).timeout.connect(_on_rest_vibration_tick)
	print("[player] rest done")
	if _state == STATE_REST:
		_set_state(STATE_ACTIVE)


func _on_rest_vibration_tick() -> void:
	if _extra_vibrations <= 0:
		return
	_extra_vibrations -= 1
	Input.vibrate_handheld(120)


func _on_rest_time_added(seconds: int) -> void:
	_sfx(&"rest_add")
	print("[player] rest add=%d" % seconds)


# ===========================================================================
# Timed steps (R9)
# ===========================================================================

## R9: the ring drains across `duration_sec` and the label counts down, both derived from the active
## clock — and the step does **not** auto-advance at zero, because stealing control during a stretch
## the owner is holding is worse than making them tap Next.
func _start_timed_step(step: Dictionary) -> void:
	_timer_row.visible = true
	_timer_done = _run.timed_seconds_remaining() <= 0
	_timer_label.text = Dates.format_clock(_run.timed_seconds_remaining())
	_timer_ring.call(&"clear_value_text")
	_timer_ring.set(&"thickness", 20.0)
	_set_timer_tint(_timer_done)
	_start_timer_tween(_run.timed_seconds_remaining(), int(step.get("duration_sec", 0)))


func _start_timer_tween(remaining: int, duration: int) -> void:
	_stop_timer_tween()
	var fraction := 1.0
	if duration > 0:
		fraction = clampf(float(remaining) / float(duration), 0.0, 1.0)
	_timer_ring.set(&"value", fraction)
	if remaining <= 0:
		_on_timed_step_zero()
		return
	_timer_tween = create_tween()
	_timer_tween.tween_property(_timer_ring, "value", 0.0, float(remaining))
	_timer_tween.finished.connect(_on_timed_step_zero)


func _stop_timer_tween() -> void:
	if _timer_tween != null and _timer_tween.is_valid():
		_timer_tween.kill()
	_timer_tween = null


## The cue at zero: `success` on the ring and the label, one sound and one 80 ms buzz, exactly once.
func _on_timed_step_zero() -> void:
	if _timer_done:
		return
	_timer_done = true
	_timer_label.text = Dates.format_clock(0)
	_set_timer_tint(true)
	_sfx(&"timer_done")
	Input.vibrate_handheld(80)
	print("[player] timer done step=%d" % _run.step_index)


func _set_timer_tint(done: bool) -> void:
	var token := "success" if done else "primary"
	_timer_ring.add_theme_color_override(&"fill_color", DesignTokens.color(App.theme_mode, token))


func _update_timed_label() -> void:
	if _run == null or _run.step_kind() == KIND_BLOCK:
		return
	var remaining := _run.timed_seconds_remaining()
	_timer_label.text = Dates.format_clock(remaining)
	if remaining <= 0:
		_on_timed_step_zero()


# ===========================================================================
# Navigation (R8)
# ===========================================================================

## R8: `Next` never blocks progress — enabled on every step, even with unchecked sets. The partial
## block toast is the only comment it ever makes, and zero checked sets says nothing at all.
func _on_next_pressed() -> void:
	if not _is_running_state():
		return
	_cancel_rest(false)
	if _run.is_last_step():
		_complete(false)
		return
	if _run.step_kind() == KIND_BLOCK:
		var exercise_id := _run.current_exercise_id()
		var sets := _run.block_sets(exercise_id)
		var checked := _run.sets_checked(exercise_id)
		if checked > 0 and checked < sets:
			Feedback.toast(TOAST_LOGGED_SETS % [checked, sets], &"info")
	if _run.next():
		_after_step_change()


## R8: on step 0 a right-swipe (or `ui_left`) does nothing at all — there is nothing before the
## first warm-up, and looking back never costs a check (R3).
func _on_previous_pressed() -> void:
	if not _is_running_state():
		return
	if not _run.can_prev():
		return
	_cancel_rest(false)
	if _run.prev():
		_after_step_change()


## R3: nothing here touches `set_states` — looking back never costs a check.
func _after_step_change() -> void:
	_stop_timer_tween()
	_timer_done = false
	_save_progress(false)
	_apply_step()


func _is_running_state() -> bool:
	return _state == STATE_ACTIVE or _state == STATE_REST


# ===========================================================================
# Pause / quit / exit (R11, R14)
# ===========================================================================

func _on_pause_pressed() -> void:
	_enter_pause(false)


## [param from_background] distinguishes an Android lifecycle pause — which cancels the rest
## countdown outright (R10) — from a deliberate one, which freezes it.
func _enter_pause(from_background: bool) -> void:
	if not _is_running_state():
		return
	_state_before_pause = _state
	_paused_by_background = from_background
	if not _set_state(STATE_PAUSED):
		return

	_clock_stop()
	_run.pause()
	_stop_timer_tween()
	_illustration.set(&"animate", false)
	if from_background:
		_cancel_rest(false)
	else:
		_rest_sheet.call(&"pause_countdown")
	_pause_stats.text = "%s · %d of %d exercises · %d sets" % [
		_run.elapsed_text(), _run.blocks_completed(), _run.block_count(), _run.sets_completed()]
	_pause_sheet.visible = true
	# The sheet is `visible = false` until now, so its rects only exist after this layout — published
	# twice (immediately and 2 s later with `settled=1`) for the same reason every other control is.
	UiProbe.log_rects_settled(get_tree(), {
		"player_resume": _resume_button,
		"player_restart": _restart_button,
		"player_end": _end_button,
		"player_quit": _quit_button,
	}, 2.0)
	_keep_screen_on(false)
	_save_progress(true)
	print("[player] pause elapsed=%d" % _run.elapsed_sec)


func _on_resume_pressed() -> void:
	_resume_session()


## R11/R14: back to the state the owner left — `ACTIVE` or `REST`.
func _resume_session() -> void:
	if _state != STATE_PAUSED:
		return
	var target := _state_before_pause if _state_before_pause == STATE_REST else STATE_ACTIVE
	if not _set_state(target):
		return
	_pause_sheet.visible = false
	_paused_note.visible = false
	_paused_by_background = false
	_run.resume()
	_clock_start()
	_keep_screen_on(true)
	_illustration.set(&"animate", true)
	if _state == STATE_REST:
		_rest_sheet.call(&"resume_countdown")
	elif _run.step_kind() != KIND_BLOCK and not _timer_done:
		_start_timer_tween(_run.timed_seconds_remaining(), _current_duration())
	print("[player] resume elapsed=%d" % _run.elapsed_sec)


func _current_duration() -> int:
	return int(_run.current_step().get("duration_sec", 0))


## R11: `Restart exercise` clears the current step's checks and its timer, leaving `elapsed_sec`
## untouched — the time already spent is still time spent.
func _on_restart_pressed() -> void:
	if _state != STATE_PAUSED:
		return
	var exercise_id := _run.current_exercise_id()
	var cleared := _run.restart_block(exercise_id)
	_resume_session()
	_apply_step()
	_save_progress(false)
	print("[player] restart ex=%s cleared=%d" % [exercise_id, cleared])


## R11: `End workout` writes an honest partial entry — no celebration screen, and the entry
## deliberately does not extend the streak or fill the ring (§10 N3).
func _on_end_pressed() -> void:
	if _state != STATE_PAUSED:
		return
	_complete(true)


func _on_quit_pressed() -> void:
	if _state != STATE_PAUSED:
		return
	if not _set_state(STATE_CONFIRM_QUIT):
		return
	_confirm_dialog.popup_centered()
	_log_dialog_rects.call_deferred()


## `ConfirmationDialog` is an embedded `Window`, so its buttons' global rects are in the *dialog's*
## space — the Android flow needs the viewport rect, which is the dialog's own position plus the
## button's. Logged in `UiProbe`'s exact format so `tools/tap_ui.sh quit_confirm` works unchanged.
func _log_dialog_rects() -> void:
	if not OS.is_debug_build():
		return
	var ok := _confirm_dialog.get_ok_button()
	if ok == null:
		return
	var rect := ok.get_global_rect()
	var origin := _confirm_dialog.position
	print("[ui] rect name=quit_confirm x=%d y=%d w=%d h=%d settled=1" % [
		int(rect.position.x + origin.x), int(rect.position.y + origin.y),
		int(rect.size.x), int(rect.size.y)])


func _on_quit_cancelled() -> void:
	if _state == STATE_CONFIRM_QUIT:
		_set_state(STATE_PAUSED)


func _on_quit_confirmed() -> void:
	if _state != STATE_CONFIRM_QUIT:
		return
	_exit_started = true
	_set_state(STATE_EXITED)
	Store.clear_session_progress()
	print("[player] progress cleared (discarded)")
	_leave_when_ready()
	Feedback.toast(TOAST_DISCARDED, &"info")


# ===========================================================================
# Completion (R11, R12)
# ===========================================================================

## Commits the history entry and routes. `partial_requested` is `End workout`; `I'm done for the day`
## with unchecked sets becomes partial on its own, because `exercises_completed == exercises_total`
## is what decides the celebration (R8/R12).
func _complete(partial_requested: bool) -> void:
	if _exit_started:
		return
	if not _set_state(STATE_COMPLETING):
		return
	_exit_started = true
	_auto_save_timer.stop()
	_clock_stop()
	_stop_timer_tween()
	_illustration.set(&"animate", false)
	_rest_sheet.call(&"stop_rest")

	var partial := partial_requested or not _run.fully_completed()
	var entry := _build_entry(partial)
	var entry_id := Store.add_entry(entry)
	if entry_id.is_empty():
		# The store refused the record (an invalid date, a full disk). The moment still happens: the
		# celebration runs on the in-memory entry and the log says exactly what was refused.
		print("[player] entry rejected plan=%s session=%s" % [_run.plan_id, _run.session_id])
	else:
		entry["id"] = entry_id

	Store.clear_session_progress()
	print("[player] progress cleared")
	_release_screen_and_back()

	if partial:
		print("[player] partial entry=%s duration=%d exercises=%d/%d sets=%d/%d" % [
			entry_id, _run.elapsed_sec, _run.blocks_completed(), _run.block_count(),
			_run.sets_completed(), _run.total_sets()])
		# R10 (P5): the flipbook window ends here too — an ended-early session measures the
		# same frames as a finished one.
		Perf.end_session()
		_leave_when_ready()
		Feedback.toast(TOAST_SAVED_PARTIAL % [
			int(entry.get("exercises_completed", 0)), int(entry.get("exercises_total", 0))], &"info")
		return

	print("[player] complete entry=%s duration=%d exercises=%d/%d sets=%d/%d" % [
		entry_id, _run.elapsed_sec, _run.blocks_completed(), _run.block_count(),
		_run.sets_completed(), _run.total_sets()])
	_set_state(STATE_FINISHED)
	# R10 (P5): the flipbook window ends with the session.
	Perf.end_session()
	# `replace` clears the stack, so the finished player is gone and the celebration cannot be
	# backed into (R12).
	Nav.replace(Routes.COMPLETION, {"entry": entry, "partial": false})


## §5.3's history shape, with §10 N2's additive set counters.
func _build_entry(partial: bool) -> Dictionary:
	var exercise_ids := PackedStringArray()
	for step in _run.steps:
		if String(step.get("kind", "")) == KIND_BLOCK:
			exercise_ids.append(String(step.get("exercise_id", "")))
	return {
		"plan_id": _run.plan_id,
		"session_id": _run.session_id,
		"session_title": _run.session_title,
		"date": Store.today_local_iso(),
		"started_at": _iso_from_unix(_run.started_at),
		"completed_at": Store.now_iso(),
		"duration_sec": _run.elapsed_sec,
		"exercises_completed": _run.blocks_completed(),
		"exercises_total": _run.block_count(),
		"sets_completed": _run.sets_completed(),
		"sets_total": _run.total_sets(),
		"completed": not partial,
		"focus": _session.get("focus", []),
		"exercise_ids": Array(exercise_ids),
	}


static func _iso_from_unix(unix: int) -> String:
	if unix <= 0:
		return Time.get_datetime_string_from_system(true, false) + "Z"
	return Time.get_datetime_string_from_unix_time(unix, false) + "Z"


## The one way out of this screen. `Nav` drops every verb while it is transitioning **and**
## `setup()` runs inside that transition, so an exit triggered during the push (R1's "that session is
## gone") has to wait for the router to be free; every later exit finds it free and leaves at once.
func _leave_when_ready() -> void:
	var guard := 0
	while Nav.is_transitioning() and guard < 120:
		guard += 1
		await get_tree().process_frame
	_release_screen_and_back()
	Nav.pop_to_root()


## Idempotent: called on every exit path **and** from `_exit_tree`, so a screen that leaves in a way
## nobody predicted still gives back handling and the screen back (R14).
func _release_screen_and_back() -> void:
	_auto_save_timer.stop()
	_keep_screen_on(false)
	if is_inside_tree():
		Nav.set_back_handling(true)


func _keep_screen_on(on: bool) -> void:
	DisplayServer.screen_set_keep_on(on)


# ===========================================================================
# Lifecycle and back (R14)
# ===========================================================================

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_on_app_paused()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_on_app_resumed()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back()


## R14: save + flush, freeze the illustration, drop the rest countdown, release the screen and move
## to `PAUSED` so coming back shows the pause sheet instead of a session that silently kept running.
func _on_app_paused() -> void:
	if _run == null or _exit_started:
		return
	_backgrounded_at = int(Time.get_unix_time_from_system())
	_clock_stop()
	_save_progress(true)
	_illustration.set(&"animate", false)
	_cancel_rest(false)
	_keep_screen_on(false)
	if _is_running_state():
		_enter_pause(true)


func _on_app_resumed() -> void:
	if _run == null or _exit_started:
		return
	_keep_screen_on(true)
	if _state != STATE_PAUSED:
		return
	var away := int(Time.get_unix_time_from_system()) - _backgrounded_at
	if _paused_by_background and away < BACKGROUND_PAUSE_SEC:
		_resume_session()
		return
	if away >= BACKGROUND_PAUSE_SEC:
		# Long enough that dropping straight back into a set would be wrong; the note says why.
		_paused_note.text = PAUSED_NOTE
		_paused_note.visible = true
		_paused_by_background = true
		print("[player] stayed paused away=%d" % away)


## R14: one handler for the Android back gesture and `ui_cancel`. Back never exits the workout from
## `ACTIVE` — it means "pause", not "lose my session".
func _on_back() -> void:
	if _run == null or _exit_started:
		return
	match _state:
		STATE_REST:
			print("[player] back -> REST")
			_cancel_rest(true)
		STATE_CONFIRM_QUIT:
			print("[player] back -> CONFIRM_QUIT")
			_confirm_dialog.hide()
			_on_quit_cancelled()
		STATE_PAUSED:
			print("[player] back -> PAUSED")
			_resume_session()
		STATE_ACTIVE:
			print("[player] back -> ACTIVE")
			_enter_pause(false)
		_:
			print("[player] back -> ignored (%s)" % _state)


## `ui_cancel` has to be caught in `_input`: `Nav` listens in `_unhandled_input`, and there the
## autoloads are visited after the main scene, so a player that only listened in `_unhandled_input`
## would never see the key while `Nav` swallowed it (R14: the screen owns back, the router is
## suppressed).
func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_back()
		return
	if _handle_swipe(event):
		return
	if not _is_running_state() or _run == null:
		return
	if event.is_action_pressed(&"ui_left"):
		get_viewport().set_input_as_handled()
		_on_previous_pressed()
	elif event.is_action_pressed(&"ui_right"):
		get_viewport().set_input_as_handled()
		_on_next_pressed()


## Swipe navigation — the owner's replacement for the Previous/Next row (ADR-24). Returns true
## when the event has been consumed and must not reach the GUI.
##
## Why `_input` and not `_unhandled_input`: the drag often starts on a Button (a set chip), and
## Godot's GUI consumes the press before the unhandled phase — so unhandled would never see a
## gesture that starts on one of the controls this screen is made of. The flip side is that
## *every* event passes through here, which is why every branch guards explicitly.
##
## One gesture navigates once: the threshold-crossing drag is consumed, and the release that
## follows is consumed too — otherwise the Button the finger started on would still register a
## click when it lifts (a swipe that grazes a set chip must not also tick it). The release is
## consumed *before* the state guard so the last-step swipe, which moves the session to
## `COMPLETING`, cannot leak its release into whatever comes next.
func _handle_swipe(event: InputEvent) -> bool:
	if event is InputEventScreenTouch and not (event as InputEventScreenTouch).pressed:
		_touch_active = false
		if _swipe_consumed:
			_swipe_consumed = false
			get_viewport().set_input_as_handled()
			return true
		return false
	if _run == null or (_state != STATE_ACTIVE and _state != STATE_REST):
		return false
	if event is InputEventScreenTouch:
		var touch: InputEventScreenTouch = event
		_touch_origin = touch.position
		_touch_active = true
		_swipe_consumed = false
		return false
	if event is InputEventScreenDrag and _touch_active:
		if _swipe_consumed:
			# The rest of the gesture keeps its events away from the GUI.
			get_viewport().set_input_as_handled()
			return true
		var drag: InputEventScreenDrag = event
		var offset := drag.position - _touch_origin
		if absf(offset.x) >= SWIPE_MIN_PX \
				and absf(offset.x) >= absf(offset.y) * SWIPE_DOMINANCE:
			_swipe_consumed = true
			get_viewport().set_input_as_handled()
			if offset.x < 0.0:
				_on_next_pressed()
			else:
				_on_previous_pressed()
			return true
	return false


# ===========================================================================
# Clock, autosave and progress (R13, R17)
# ===========================================================================

func _on_autosave_tick() -> void:
	if _run == null or _exit_started or not _is_running_state():
		return
	_clock_fold()
	_elapsed_label.text = _run.elapsed_text()
	_update_timed_label()
	_save_progress(false)


func _clock_start() -> void:
	if _clock_started_ms <= 0:
		_clock_started_ms = Time.get_ticks_msec()


## Folds whole active seconds into the model; the remainder waits, so a 1.99 s tick loses nothing.
func _clock_fold() -> void:
	if _clock_started_ms <= 0 or _run == null:
		return
	var now := Time.get_ticks_msec()
	_clock_ms += maxi(now - _clock_started_ms, 0)
	_clock_started_ms = now
	# `floori` of a float division: an int `/` would discard the remainder *and* warn (R17 keeps the
	# warning gate at zero).
	var whole := floori(float(_clock_ms) / 1000.0)
	if whole > 0:
		_clock_ms -= whole * 1000
		_run.tick(whole)


func _clock_stop() -> void:
	_clock_fold()
	_clock_started_ms = 0
	if _run != null:
		_elapsed_label.text = _run.elapsed_text()


## R13: every set toggle and every step change, plus the 2 s tick; [param force] flushes now, which is
## what the pause and backgrounding paths do so a debounced write cannot lose the last seconds.
func _save_progress(force: bool) -> void:
	if _run == null or _run.plan_id.is_empty() or _run.session_id.is_empty():
		return
	Store.save_session_progress(_run.to_dict(Store.now_iso()))
	if force:
		Store.flush()


# ===========================================================================
# Sound (R7)
# ===========================================================================

## PRD-12 R2: the cue set is five sounds owned by `Feedback`; PRD-10's finer-grained names are
## mapped onto it here, so every existing call site keeps reading as the intent it names
## (`set_ok`, `block_done`, `timer_done`) instead of as an index into a sound table.
func _sfx(sound_name: StringName) -> void:
	match String(sound_name):
		"set_ok":
			Feedback.select()
		"block_done", "rest_done", "timer_done":
			Feedback.success()
		_:
			Feedback.tap()


# ===========================================================================
# State machine (R11), theme (R16) and the flipbook cycle log (R4/AC3)
# ===========================================================================

## Applies [param next] when R11's table allows it and logs the rejection otherwise, so an illegal
## transition shows up in logcat instead of silently corrupting the flow.
func _set_state(next: String) -> bool:
	if next == _state:
		return true
	var allowed: Array = TRANSITIONS.get(_state, [])
	if not allowed.has(next):
		print("[player] rejected %s from %s" % [next, _state])
		return false
	_state = next
	return true


## Current R11 state — read by `tools/tap_ui.sh`-driven acceptance runs and by the scene checks.
func state() -> String:
	return _state


## The live session model — the test seam that lets a headless check assert what the screen shows.
func run() -> SessionRun:
	return _run


## R16: illustrations keep their `text` tint in both themes; every other runtime colour is re-read.
func _on_theme_changed(_mode: String) -> void:
	_background.color = DesignTokens.color(App.theme_mode, "bg")
	_pause_dim.color = _dim_colour()
	_segment_styles.clear()
	if _run == null:
		return
	_update_illustration(_run.current_exercise_id())
	_set_timer_tint(_timer_done)
	_repaint_progress()
	for chip in _chips:
		var normal: StyleBoxFlat = chip["normal"]
		var pressed: StyleBoxFlat = chip["pressed"]
		if normal != null:
			normal.bg_color = DesignTokens.color(App.theme_mode, "surface_alt")
		if pressed != null:
			pressed.bg_color = DesignTokens.color(App.theme_mode, "success")
	_update_block_done_chip(_run.current_exercise_id())


## R2's `PauseDim`: the background token darkened to 0.9, so the card reads as a sheet over the
## paused session rather than a new screen.
func _dim_colour() -> Color:
	var colour := DesignTokens.color(App.theme_mode, "bg")
	colour.a = 0.9
	return colour


## `ConfirmationDialog` is a `Window`: it lives outside the theme tree, so R11's two buttons take
## their look from the shared button variations explicitly, with `Keep going` focused by default —
## the destructive path is deliberately the second tap.
func _style_dialog(dialog: ConfirmationDialog) -> void:
	var ok := dialog.get_ok_button()
	if ok != null:
		ok.theme_type_variation = &"DangerButton"
		ok.custom_minimum_size = Vector2(0, 88)
	var cancel := dialog.get_cancel_button()
	if cancel != null:
		cancel.theme_type_variation = &"SecondaryButton"
		cancel.custom_minimum_size = Vector2(0, 88)
		cancel.grab_focus()


## Counts a full ping-pong: the component's `[0, 1, 2, 1]` sequence comes back to index 0 once per
## cycle, which is what makes the 1.818 s period measurable from logcat alone (AC3).
func _on_frame_changed(index: int) -> void:
	# R10 (P5): the frame that renders a flipbook advance is the one the budget cares about, so
	# the engine's own process-time monitor is sampled at every advance.
	Perf.note_frame_ms(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	if index != 0:
		_frame_off_start = true
		return
	if not _frame_off_start:
		return
	_frame_off_start = false
	_frame_cycles += 1
	if _frame_log_started_ms <= 0:
		_frame_log_started_ms = Time.get_ticks_msec()
	var elapsed := float(Time.get_ticks_msec() - _frame_log_started_ms) / 1000.0
	print("[player] frame_cycle=%d t=%.3f" % [_frame_cycles, elapsed])
