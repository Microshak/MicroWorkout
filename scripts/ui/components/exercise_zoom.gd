extends Control
## Full-screen exercise detail overlay — PRD-10 R4, motion per R16.
##
## The player instantiates this as `ExerciseZoom` and owns the `ZOOMED` sub-state: it calls
## [method open] / [method close] and listens to [signal closed]. This component never calls `Nav`,
## never plays audio, never touches the session, and never drives the flipbook itself — the
## illustration is a second instance of PRD-02's `exercise_thumbnail` (R4: the flipbook is **not**
## forked), so the animation keeps running seamlessly at 900×900.
##
## Dismissal is a tap anywhere or `ui_cancel` (R4/R11), both of which emit [signal closed] so the
## player can leave `ZOOMED` without polling. [method close] — the player's own dismissal, e.g. when
## it enters `PAUSED` — deliberately does **not** emit, or the player would re-enter its own handler.

## Emitted when the overlay dismisses *itself* (tap anywhere, or `ui_cancel`).
signal closed

## R16: the overlay enters from this scale factor.
const ZOOM_FROM := 0.92

## R4: `ZoomDim` is the `bg` token at 92 %.
const DIM_ALPHA := 0.92

## R4/R5: at most three form tips, matching the cues the exercise library ships.
const MAX_CUES := 3

## Node references.
##
## Cached on first use instead of with `@onready`: `NOTIFICATION_THEME_CHANGED` can reach a Control
## *before* `_ready()` runs, and [method _apply_theme] has to survive that. After the first resolve
## nothing here calls `get_node()` again.
var _dim: ColorRect = null
var _illustration: Control = null
var _name_label: Label = null
var _meta_label: Label = null
var _cues: VBoxContainer = null

var _tween: Tween = null
var _showing: bool = false


func _ready() -> void:
	# Authored as `visible = false` too: an instantiated overlay must be inert. An invisible
	# Control is never hit-tested, so it cannot steal the IllustrationButton's taps either.
	visible = false
	_cache_nodes()
	_apply_theme()
	_pivot_to_center()
	if not resized.is_connected(_pivot_to_center):
		resized.connect(_pivot_to_center)
	# A root-`Window.theme` swap does NOT notify descendants in Godot 4.7.2 (measured; the same
	# note is in `loading_overlay`), so the app's own signal is what re-tints the scrim and the
	# line art after a dark↔light switch.
	if is_instance_valid(App) and not App.theme_changed.is_connected(_on_theme_changed):
		App.theme_changed.connect(_on_theme_changed)
	# `ZoomDim` is the topmost full-rect control and the only tap target that is not inside the
	# card, so a tap that misses the card stops there (`STOP` is exactly what keeps the tap away
	# from the screen underneath). Wire it to the same dismissal as the root, which receives every
	# tap that bubbles out of the card.
	var dim := _dim
	if dim != null and not dim.gui_input.is_connected(_on_gui_input):
		dim.gui_input.connect(_on_gui_input)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()


## R16's motion: 180 ms ease-out scale 0.92 → 1.0 with a simultaneous alpha 0 → 1.
##
## [param display_name] is R5's identity line and [param meta] its `"4 × 8-10 · 90s rest"` subtitle;
## [param cues] fills up to [constant MAX_CUES] form tips. The parameter is not named `name` as the
## PRD writes it — inside a `Control` that shadows `Node.name`, which this project treats as a build
## failure. Callers are unaffected: GDScript has no named arguments.
func open(exercise_id: String, display_name: String, meta: String, cues: PackedStringArray) -> void:
	_fill(exercise_id, display_name, meta, cues)
	_showing = true
	visible = true
	_pivot_to_center()
	_kill_tween()
	if _reduce_motion():
		# Appendix §4.4: decorative motion is skipped, never shortened.
		scale = Vector2.ONE
		modulate.a = 1.0
		return
	var seconds := float(DesignTokens.MOTION["screen_ms"]) / 1000.0
	scale = Vector2(ZOOM_FROM, ZOOM_FROM)
	modulate.a = 0.0
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2.ONE, seconds)
	tween.tween_property(self, "modulate:a", 1.0, seconds)
	_tween = tween


## Reverses the entry motion and hides the overlay. Emits nothing (see [signal closed]) and is safe
## to call when the overlay is already closed.
func close() -> void:
	if not _showing:
		return
	_showing = false
	_kill_tween()
	if _reduce_motion() or not is_inside_tree():
		_finish_close()
		return
	var seconds := float(DesignTokens.MOTION["screen_ms"]) / 1000.0
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN)
	tween.tween_property(self, "scale", Vector2(ZOOM_FROM, ZOOM_FROM), seconds)
	tween.tween_property(self, "modulate:a", 0.0, seconds)
	# `chain()` closes the parallel block, so the hide waits for both properties to settle.
	tween.chain().tween_callback(_finish_close)
	_tween = tween


## Whether the overlay is currently up. The player owns the session state; this only reports the
## overlay's own visibility toggled by [method open] / [method close].
func is_showing() -> bool:
	return _showing


## The flipbook slot, so the player can assert the same exercise is on screen at both sizes (R4).
func illustration() -> Control:
	if _illustration == null:
		_illustration = get_node_or_null(^"ZoomCard/ZoomVBox/ZoomIllustration") as Control
	return _illustration


## The `"4 × 8-10 · 90s rest"` line, for the player's assertions (R5).
func meta_label() -> Label:
	if _meta_label == null:
		_meta_label = get_node_or_null(^"ZoomCard/ZoomVBox/ZoomMetaLabel") as Label
	return _meta_label


# ------------------------------------------------------------------ input

## Tap anywhere (R4).
##
## `_gui_input` alone cannot promise "anywhere": the illustration is PRD-02's `exercise_thumbnail`,
## whose internal `Stack` is a `STOP` control, and a `STOP` control marks a press handled *inside*
## the GUI pass — so a tap in the middle of the artwork never reaches the overlay. Handling the press
## in `_input` (which Godot dispatches before the GUI) makes the dismissal true for every pixel, and
## marking it handled is what stops the press from reaching the illustration button underneath.
func _input(event: InputEvent) -> void:
	if not _showing or not _is_press(event):
		return
	get_viewport().set_input_as_handled()
	_dismiss()


## Root tap handler — the full-rect `gui_input` path R4 describes.
func _gui_input(event: InputEvent) -> void:
	_handle_tap(event)


## `ZoomDim`'s tap handler: the scrim is the only `STOP` control outside the card (see `_ready`), so
## this is where a tap that misses the card lands when the GUI pass gets it.
func _on_gui_input(event: InputEvent) -> void:
	_handle_tap(event)


## The Android back gesture and the desktop Esc. The player catches `ui_cancel` in `_input` while
## the screen is up, so this is the standalone path; it exists because R4 requires the overlay to
## answer the back gesture itself rather than depend on its owner.
func _unhandled_input(event: InputEvent) -> void:
	if not _showing or not event.is_action_pressed(&"ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	_dismiss()


func _handle_tap(event: InputEvent) -> void:
	if not _showing or not _is_press(event):
		return
	# Consume it: nothing underneath (the illustration button included) may see this tap.
	accept_event()
	_dismiss()


## A press, not a release: the overlay closes on finger-down, and acting on the release instead
## would also close it a second time on the way out.
func _is_press(event: InputEvent) -> bool:
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).pressed
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		return button.pressed and button.button_index == MOUSE_BUTTON_LEFT
	return false


## Dismissed by the user: close, then tell the player it may leave `ZOOMED` (R11).
func _dismiss() -> void:
	if not _showing:
		return
	close()
	closed.emit()


# ------------------------------------------------------------------ rendering (R4/R16)

## Fills the overlay for one exercise. Never touches `Frame.texture` — the thumbnail component owns
## its frames, its own `FrameTimer` and its no-art placeholder.
func _fill(exercise_id: String, display_name: String, meta: String, cues: PackedStringArray) -> void:
	_cache_nodes()
	var thumb := _illustration
	if thumb != null:
		# `animate` is set *first*: `set_exercise()` re-applies playback from the current flag, so
		# setting it afterwards would leave the flipbook stopped on its first frame.
		thumb.set(&"animate", true)
		thumb.call(&"set_exercise", exercise_id, Library.get_frames(exercise_id))
		thumb.modulate = DesignTokens.color(App.theme_mode, "text")
	var title := _name_label
	if title != null:
		title.text = display_name
	var subtitle := _meta_label
	if subtitle != null:
		subtitle.text = meta
	_fill_cues(cues)


## Up to [constant MAX_CUES] form tips; the box hides entirely when the exercise has none (R5).
func _fill_cues(cues: PackedStringArray) -> void:
	var box := _cues
	if box == null:
		return
	var shown := mini(cues.size(), MAX_CUES)
	for index in box.get_child_count():
		var label := box.get_child(index) as Label
		if label == null:
			continue
		label.text = cues[index] if index < shown else ""
		label.visible = index < shown
	box.visible = shown > 0


## The scrim and the line-art tint are the two runtime colours of R4 — both read from the tokens,
## never hard-coded, and both re-applied on a live theme switch.
func _apply_theme() -> void:
	_cache_nodes()
	var mode: String = App.theme_mode
	var dim := _dim
	if dim != null:
		var scrim := DesignTokens.color(mode, "bg")
		scrim.a = DIM_ALPHA
		dim.color = scrim
	var thumb := _illustration
	if thumb != null:
		thumb.modulate = DesignTokens.color(mode, "text")


func _on_theme_changed(_mode: String) -> void:
	_apply_theme()


## Scales from the middle of the screen, and keeps doing so across rotation/resize.
func _pivot_to_center() -> void:
	pivot_offset = size * 0.5


## R16's snap path. `Nav` exposes only a setter, so the setting is read the way every other
## component reads it (`weekly_ring`, `day_pill`, `day_card`).
func _reduce_motion() -> bool:
	return bool(App.get_setting("ui.reduce_motion", false))


func _cache_nodes() -> void:
	if _dim == null:
		_dim = get_node_or_null(^"ZoomDim") as ColorRect
	if _cues == null:
		_cues = get_node_or_null(^"ZoomCard/ZoomVBox/ZoomCues") as VBoxContainer
	if _name_label == null:
		_name_label = get_node_or_null(^"ZoomCard/ZoomVBox/ZoomNameLabel") as Label
	if _meta_label == null:
		_meta_label = get_node_or_null(^"ZoomCard/ZoomVBox/ZoomMetaLabel") as Label
	if _illustration == null:
		_illustration = get_node_or_null(^"ZoomCard/ZoomVBox/ZoomIllustration") as Control


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


## Restores the neutral transform *after* hiding, so the next [method open] always starts from a
## known scale/alpha even if the close tween was interrupted.
func _finish_close() -> void:
	_tween = null
	visible = false
	scale = Vector2.ONE
	modulate.a = 1.0
