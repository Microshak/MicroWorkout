extends Control
## Circular progress / activity ring — PRD-02 R9, appendix §3.
##
## This is the **only** ring drawing code in the app: `weekly_ring` (PRD-09) composes it with
## [method set_segments] instead of re-implementing arcs. Drawing order is fixed by R9:
## track → fill → segment ticks → labels.
##
## All colours come from the theme's `ProgressRing` type variation, so the ring repaints on a
## runtime theme switch and on resize.

signal value_changed(v: float)

## Arc width, design px.
@export var thickness: float = 14.0:
	set(value):
		if is_equal_approx(thickness, value):
			return
		thickness = value
		queue_redraw()

## Degrees to start the fill sweep at; -90 = 12 o'clock.
@export var start_angle_deg: float = -90.0:
	set(value):
		if is_equal_approx(start_angle_deg, value):
			return
		start_angle_deg = value
		queue_redraw()

## Spins a 96° sweep instead of drawing [member value]. Redraws every frame by design (R9).
@export var indeterminate: bool = false:
	set(value):
		if indeterminate == value:
			return
		indeterminate = value
		queue_redraw()

## Shows [member caption] under the value label when it is non-empty.
@export var show_caption: bool = true:
	set(value):
		if show_caption == value:
			return
		show_caption = value
		_sync_labels()
		queue_redraw()

## Fill fraction, clamped to [0, 1].
@export var value: float = 0.0:
	set(v):
		var clamped := clampf(v, 0.0, 1.0)
		if is_equal_approx(clamped, value):
			return
		value = clamped
		_sync_labels()
		queue_redraw()

## Hidden below this width, where the value text no longer fits (R9 step 5).
const VALUE_LABEL_MIN_WIDTH := 160.0

## Length of a `set_segments()` tick, design px.
const TICK_LENGTH := 6.0

## Indeterminate sweep, degrees.
const INDETERMINATE_SWEEP_DEG := 96.0

var _caption: String = ""
var _segments: PackedByteArray = PackedByteArray()
var _value_text_override: String = ""
var _has_value_text_override: bool = false


## Sets the fill fraction and emits [signal value_changed] (R9).
func set_value(v: float) -> void:
	value = v
	value_changed.emit(value)


## Caption under the value label; empty hides it.
func set_caption(t: String) -> void:
	if _caption == t:
		return
	_caption = t
	_sync_labels()
	queue_redraw()


## Writes the value label verbatim and disables the automatic `%d%%` text (appendix §3.1).
## Passing "" blanks the label — used by `loading_overlay` so an indeterminate ring shows no
## meaningless "0%".
func set_caption_value(t: String) -> void:
	_has_value_text_override = true
	_value_text_override = t
	_sync_labels()


## Weekly bits for PRD-09: one tick per bit, `fill_color` for 1 and `track_color` for 0.
## Empty (the default) draws no ticks.
func set_segments(bits: PackedByteArray) -> void:
	if bits == _segments:
		return
	_segments = bits
	queue_redraw()


## The bits last handed to [method set_segments].
func segments() -> PackedByteArray:
	return _segments


## Blanks the percentage text, e.g. for a pure spinner.
func clear_value_text() -> void:
	set_caption_value("")


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_RESIZED:
		_sync_labels()
		queue_redraw()


func _ready() -> void:
	_sync_labels()
	queue_redraw()


func _draw() -> void:
	# 1. Geometry (R9 step 1).
	var t: float = thickness
	var center := size * 0.5
	var r: float = minf(size.x, size.y) * 0.5 - t * 0.5 - 2.0

	if r > 0.0:
		# 2. Track (R9 step 2).
		draw_arc(center, r, 0.0, TAU, 128, get_theme_color(&"track_color", &"ProgressRing"), t, true)

		var fill_color := get_theme_color(&"fill_color", &"ProgressRing")

		# 3. Fill (R9 step 3).
		if indeterminate:
			var from := deg_to_rad(fmod(Engine.get_frames_drawn() * 4.0, 360.0) - 90.0)
			draw_arc(center, r, from, from + deg_to_rad(INDETERMINATE_SWEEP_DEG), 128, fill_color, t, true)
			queue_redraw()
		else:
			var sweep: float = 360.0 * clampf(value, 0.0, 1.0)
			if sweep > 0.0:
				var points := maxi(16, int(128.0 * clampf(value, 0.0, 1.0)))
				draw_arc(center, r, deg_to_rad(start_angle_deg), deg_to_rad(start_angle_deg + sweep),
					points, fill_color, t, true)

		# 4. Segment ticks (R9 step 4) — PRD-09's week bits.
		if not _segments.is_empty():
			_draw_segments(center, r, fill_color,
				get_theme_color(&"track_color", &"ProgressRing"))

	# 5. Labels (R9 step 5).
	_sync_labels()


func _draw_segments(center: Vector2, r: float, on_color: Color, off_color: Color) -> void:
	var count := _segments.size()
	var half := TICK_LENGTH * 0.5
	for i in count:
		var angle := deg_to_rad(start_angle_deg + i * 360.0 / float(count))
		var dir := Vector2(cos(angle), sin(angle))
		var mid := center + dir * r
		var tick_color := on_color if _segments[i] != 0 else off_color
		draw_line(mid - dir * half, mid + dir * half, tick_color, TICK_LENGTH, true)


## Keeps the two labels in sync with [member value], [member caption] and [member show_caption].
## Called from `_draw()` as well as from every setter, so it is correct before the first frame.
func _sync_labels() -> void:
	var value_label := value_label_node()
	if value_label != null:
		if _has_value_text_override:
			value_label.text = _value_text_override
		else:
			value_label.text = "%d%%" % roundi(clampf(value, 0.0, 1.0) * 100.0)
		value_label.visible = size.x >= VALUE_LABEL_MIN_WIDTH
	var caption_label := caption_label_node()
	if caption_label != null:
		caption_label.text = _caption
		caption_label.visible = not _caption.is_empty() and show_caption


func value_label_node() -> Label:
	return get_node_or_null(^"Center/Stack/ValueLabel") as Label


func caption_label_node() -> Label:
	return get_node_or_null(^"Center/Stack/CaptionLabel") as Label
