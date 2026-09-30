extends HBoxContainer
## One body-area row — PRD-11 R9.
##
## `AreaLabel · [track/fill bar] · ! · count · recency`. The track and the fill are drawn in one
## [_draw] call (R9) behind a spacer control, so the row is three labels, one invisible spacer
## and two styleboxes — nothing that can get out of sync.
##
## **Neglect carries three cues, only one of them colour** (R9/R12): the fill and the count turn
## `warning`, the literal `" · Neglected"` is appended to the recency text, and the `alert` glyph
## appears before the count.
##
## The bar's minimum width is 240 px rather than the PRD's fixed 520: at text scale 1.5 the four
## labels need the room, and the bar expands to fill whatever the labels leave (≈ 500 px at
## scale 1.0). This is the same class of correction as the day cell's size (ADR-25).

const BAR_RADIUS := 9
const BAR_HEIGHT := 18.0
const BAR_MIN_WIDTH := 240.0

var _sessions: int = 0
var _highest: int = 1
var _days_since: int = -1
var _neglected: bool = false

var _track_box: StyleBoxFlat = null
var _fill_box: StyleBoxFlat = null
var _box_mode: String = ""
var _box_state: String = ""

@onready var _area_label: Label = $AreaLabel
@onready var _bar: Control = $Bar
@onready var _alert: Control = $AlertGlyph
@onready var _count: Label = $CountLabel
@onready var _recency: Label = $RecencyLabel


func _ready() -> void:
	_bar.resized.connect(_on_bar_resized)
	resized.connect(_on_bar_resized)
	if not App.theme_changed.is_connected(_on_theme_changed):
		App.theme_changed.connect(_on_theme_changed)
	_apply()


func _on_theme_changed(_mode: String) -> void:
	_apply()


func _on_bar_resized() -> void:
	queue_redraw()


# ------------------------------------------------------------------ API (R9)

## Fills the row. [param area_label] is the §6.1 display label, [param highest] the largest
## session count in the card (the bar scale), [param days_since] `-1` for "never".
func set_area(area_label: String, sessions: int, days_since: int, highest: int,
		neglected: bool) -> void:
	_area_label.text = area_label
	_sessions = maxi(sessions, 0)
	_highest = maxi(highest, 1)
	_days_since = days_since
	_neglected = neglected
	_apply()


func session_count() -> int:
	return _sessions


func is_neglected() -> bool:
	return _neglected


# ------------------------------------------------------------------ rendering

func _apply() -> void:
	_count.text = str(_sessions)
	_recency.text = _recency_text()
	_alert.visible = _neglected
	_build_boxes()
	var mode := App.theme_mode
	var count_token := "warning" if _neglected else "primary"
	_count.add_theme_color_override(&"font_color", DesignTokens.accent_text(mode, count_token))
	_alert.add_theme_color_override(&"color", DesignTokens.accent_text(mode, "warning"))
	queue_redraw()


## `"today"` / `"2d ago"` / `"never"`, with R9's literal marker appended when neglected.
func _recency_text() -> String:
	var text := "never"
	if _days_since == 0:
		text = "today"
	elif _days_since > 0:
		text = "%dd ago" % _days_since
	if _neglected:
		text += " · Neglected"
	return text


func _build_boxes() -> void:
	var mode := App.theme_mode
	var state := "%s|%s" % [mode, "neglected" if _neglected else "normal"]
	if _track_box != null and _box_mode == mode and _box_state == state:
		return
	_box_mode = mode
	_box_state = state
	_track_box = StyleBoxFlat.new()
	_track_box.bg_color = DesignTokens.color(mode, "surface_alt")
	_round(_track_box, BAR_RADIUS)
	_fill_box = StyleBoxFlat.new()
	_fill_box.bg_color = DesignTokens.color(mode, "warning" if _neglected else "primary")
	_round(_fill_box, BAR_RADIUS)


static func _round(box: StyleBoxFlat, radius: int) -> void:
	box.corner_radius_top_left = radius
	box.corner_radius_top_right = radius
	box.corner_radius_bottom_right = radius
	box.corner_radius_bottom_left = radius
	box.anti_aliasing = true


func _draw() -> void:
	if _track_box == null or not is_instance_valid(_bar):
		return
	var track := Rect2(_bar.position, _bar.size)
	draw_style_box(_track_box, track)
	if _sessions > 0:
		var fraction := clampf(float(_sessions) / float(_highest), 0.0, 1.0)
		draw_style_box(_fill_box, Rect2(track.position, Vector2(track.size.x * fraction,
			track.size.y)))
