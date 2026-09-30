extends Control
## One calendar day cell — PRD-11 R6.
##
## The whole cell is geometry: no child nodes, no textures. It draws its background, its day
## number and one mark in a fixed band, and it reports taps and horizontal drags to the screen
## that owns it. Keeping 42 cells childless is what makes "42 cells, zero node churn on refresh"
## (R2/R12) trivially true.
##
## **Kind vocabulary** is PRD-09's `done | today | upcoming | rest | missed` plus PRD-11's
## `padding` (an off-month cell); the kind is computed by [method MonthGrid.DayStatus.resolve] and
## handed to [method set_day] — this file never decides what a day is.
##
## **Colours** come from [DesignTokens] at draw time, so a dark↔light switch is a `queue_redraw()`
## and nothing else. `outline_strong` is the `upcoming` ring because `outline` is 1.34:1 against
## `surface` — unusable for a mark (appendix §4.2/R07).
##
## **Size:** the PRD's arithmetic (7 × 140 + 6 × 8 = 1028 ≤ 1032) forgot the card's 24 px content
## margins and the scroll container's scrollbar, so the cell is 128 px — see ADR-25. The drawing
## coordinates below are still the PRD's (baseline 44, mark band 78–120), which fit inside 128.

signal pressed(date: String)
## A horizontal drag on this cell. [param dx] is the total x delta; the screen applies R11's
## ≥ 64 px / |dx| > |dy| × 1.5 rule and changes the month.
signal swiped(dx: float, dy: float)

const KIND_PADDING := "padding"
const KIND_DONE := "done"
const KIND_TODAY := "today"
const KIND_UPCOMING := "upcoming"
const KIND_REST := "rest"
const KIND_MISSED := "missed"

## R6's cell size, reduced from 140 to fit the real card interior (ADR-25). 7 × 128 + 6 × 8 = 944.
const CELL_SIZE := Vector2(128.0, 128.0)
## R6's visual constants. All of them fit a 128 px cell unchanged.
const BODY_RADIUS := 16
const BORDER_WIDTH := 3.0
const NUMBER_BASELINE := 44.0
const MARK_CENTER_Y := 99.0
const MARK_RADIUS := 10.0
const MARK_WIDTH := 3.0
## Movement under this counts as a tap; movement past [constant SWIPE_MIN] (with R11's ratio)
## counts as a month swipe. Between the two, nothing happens — a jittery finger is not a gesture.
const TAP_SLOP := 16.0
const SWIPE_MIN := 64.0

var _iso: String = ""
var _kind: String = KIND_REST
var _in_month: bool = true
var _is_today: bool = false

var _tracking: bool = false
var _press_pos: Vector2 = Vector2.ZERO

## Cached styleboxes for the two rounded primitives, invalidated by mode or state changes.
var _bg_box: StyleBoxFlat = null
var _border_box: StyleBoxFlat = null
var _box_mode: String = ""
var _box_state: String = ""


func _ready() -> void:
	custom_minimum_size = CELL_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	if not App.theme_changed.is_connected(_on_theme_changed):
		App.theme_changed.connect(_on_theme_changed)


func _notification(what: int) -> void:
	# A redraw is always safe here: this control sets no theme overrides, so the notification
	# cannot re-enter itself.
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		queue_redraw()


func _on_theme_changed(_mode: String) -> void:
	queue_redraw()


# ------------------------------------------------------------------ API (R6)

## Fills the cell. [param iso] is the cell's date, [param day_kind] one of the vocabulary
## above, [param in_displayed_month] false for the padding days of a six-row month page, and
## [param today] draws the primary border regardless of kind.
func set_day(iso: String, day_kind: String, in_displayed_month: bool, today: bool) -> void:
	if iso == _iso and day_kind == _kind and in_displayed_month == _in_month \
			and today == _is_today:
		return
	_iso = iso
	_kind = day_kind
	_in_month = in_displayed_month
	_is_today = today
	tooltip_text = _tooltip()
	# PRD-12 R5: a calendar cell is a real control — it is tappable and it must be spoken as
	# "Tuesday 15 September, completed", never as a bare number.
	A11y.make_interactive(self, _tooltip())
	queue_redraw()


func date() -> String:
	return _iso


func kind() -> String:
	return _kind


func in_month() -> bool:
	return _in_month


func is_today() -> bool:
	return _is_today


# ------------------------------------------------------------------ input

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_begin(touch.position)
		else:
			_end(touch.position)
		accept_event()
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_begin(button.position)
			else:
				_end(button.position)
			accept_event()


func _begin(pos: Vector2) -> void:
	_tracking = true
	_press_pos = pos


func _end(pos: Vector2) -> void:
	if not _tracking:
		return
	_tracking = false
	var delta := pos - _press_pos
	if delta.length() <= TAP_SLOP:
		pressed.emit(_iso)
	elif absf(delta.x) >= SWIPE_MIN and absf(delta.x) > absf(delta.y) * 1.5:
		swiped.emit(delta.x, delta.y)
	# Anything between a tap and a swipe is deliberately dropped: it is neither.


# ------------------------------------------------------------------ drawing (R6)

func _draw() -> void:
	var mode := App.theme_mode
	var state := "%s|%s" % [_kind, "today" if _is_today else ""]
	if _bg_box == null or _box_mode != mode or _box_state != state:
		_build_boxes(mode, state)

	if _is_today:
		draw_style_box(_bg_box, Rect2(Vector2.ZERO, size))
		draw_style_box(_border_box, Rect2(Vector2.ZERO, size))

	_draw_number(mode)
	_draw_mark(mode)


func _draw_number(mode: String) -> void:
	if _iso.length() != 10:
		return
	var day_number := str(int(_iso.substr(8, 2)))
	var font := get_theme_default_font()
	if font == null:
		return
	var colour := DesignTokens.color(mode, "text" if _in_month else "text_disabled")
	draw_string(font, Vector2(0.0, NUMBER_BASELINE), day_number,
		HORIZONTAL_ALIGNMENT_CENTER, size.x, get_theme_default_font_size(), colour)


## R6's mark band, `y = 78 … 120` — one shape per kind, each distinguishable without colour
## (filled circle, ring + slash, hollow rings).
func _draw_mark(mode: String) -> void:
	var centre := Vector2(size.x * 0.5, MARK_CENTER_Y)
	match _kind:
		KIND_DONE:
			draw_circle(centre, MARK_RADIUS, DesignTokens.color(mode, "success"))
			var check := PackedVector2Array([
				centre + Vector2(-4.5, 0.0),
				centre + Vector2(-1.5, 3.0),
				centre + Vector2(5.0, -4.5),
			])
			draw_polyline(check, DesignTokens.color(mode, "bg"), MARK_WIDTH, false)
		KIND_MISSED:
			var danger := DesignTokens.color(mode, "danger")
			draw_arc(centre, MARK_RADIUS, 0.0, TAU, 32, danger, MARK_WIDTH, true)
			draw_line(centre + Vector2(-4.5, 4.5), centre + Vector2(4.5, -4.5),
				danger, MARK_WIDTH, true)
		KIND_TODAY:
			draw_arc(centre, MARK_RADIUS, 0.0, TAU, 32,
				DesignTokens.color(mode, "primary"), MARK_WIDTH, true)
		KIND_UPCOMING:
			draw_arc(centre, MARK_RADIUS, 0.0, TAU, 32,
				DesignTokens.color(mode, "outline_strong"), MARK_WIDTH, true)
		_:
			pass  # rest / padding: the band stays empty


func _build_boxes(mode: String, state: String) -> void:
	_box_mode = mode
	_box_state = state
	_bg_box = StyleBoxFlat.new()
	_bg_box.bg_color = DesignTokens.color(mode, "surface_alt")
	_bg_box.corner_radius_top_left = BODY_RADIUS
	_bg_box.corner_radius_top_right = BODY_RADIUS
	_bg_box.corner_radius_bottom_right = BODY_RADIUS
	_bg_box.corner_radius_bottom_left = BODY_RADIUS
	_bg_box.anti_aliasing = true

	_border_box = StyleBoxFlat.new()
	_border_box.draw_center = false
	_border_box.border_color = DesignTokens.color(mode, "primary")
	_border_box.set_border_width_all(int(BORDER_WIDTH))
	_border_box.corner_radius_top_left = BODY_RADIUS
	_border_box.corner_radius_top_right = BODY_RADIUS
	_border_box.corner_radius_bottom_right = BODY_RADIUS
	_border_box.corner_radius_bottom_left = BODY_RADIUS
	_border_box.anti_aliasing = true


## The spoken description PRD-12 R5 expects to find in `tooltip_text` — the day in words, so the
## meaning never depends on the drawn mark.
func _tooltip() -> String:
	if _iso.length() != 10:
		return ""
	var label := Dates.format_long(_iso)
	match _kind:
		KIND_DONE:
			return "%s — completed" % label
		KIND_MISSED:
			return "%s — missed" % label
		KIND_TODAY:
			return "%s — today's session" % label
		KIND_UPCOMING:
			return "%s — planned" % label
		KIND_REST:
			return "%s — rest day" % label
		_:
			return label
