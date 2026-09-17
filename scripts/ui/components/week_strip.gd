extends PanelContainer
## The week strip — PRD-09 R6, appendix §3.2.
##
## Seven day pills, Monday → Sunday, built at runtime (never authored in the scene) from
## `day_pill.tscn`. The pills carry the state ([method HomeState.build] decides it); this
## container only lays them out, forwards taps and can pulse one of them.
##
## **Tapping.** PRD-09 R6 v1 behaviour is "tapping anywhere on the strip opens the Plan tab, so
## the owner is never stuck"; the frozen API (appendix §3.2) is `signal pressed(date: String)`,
## so the strip reports *which* day was tapped and [HomeTab] decides what that means. Each pill
## owns its own `gui_input`, which is why no coordinate math is needed here and why a pill can
## never be a dead zone.

## Appendix §3.2. `date` is the tapped pill's local `YYYY-MM-DD` (empty for an unfilled pill).
signal pressed(date: String)

const DAY_PILL := preload("res://scenes/components/day_pill.tscn")

## A week is exactly seven days: Monday → Sunday (appendix §6.4).
const DAYS := 7

## R6: every pill is at least one touch target tall. Its *width* is flexible — the seven pills
## and their gutters have to fit inside the card's 24 px padding, which R6's own `140 px` figure
## did not account for (7 × 140 + 6 × 8 + 48 > the 1032 px content column), so they share the row
## evenly instead of overflowing it.
const PILL_MIN_HEIGHT := 88.0

var _pills: Array[PanelContainer] = []
var _dates: PackedStringArray = PackedStringArray()

## True when the project turns mouse clicks into touch events, in which case a desktop click
## arrives twice and only the touch is acted on.
var _mouse_is_emulated := false


func _ready() -> void:
	_mouse_is_emulated = bool(
		ProjectSettings.get_setting("input_devices/pointing/emulate_touch_from_mouse", false))
	_ensure_pills()


# ------------------------------------------------------------------ API

## Fills the strip from seven `{weekday_iso, letter, date, kind}` entries (R6).
func set_week(days: Array[Dictionary]) -> void:
	_ensure_pills()
	_dates = PackedStringArray()
	for index in DAYS:
		var day: Dictionary = days[index] if index < days.size() else {}
		if index < _pills.size() and _pills[index].has_method(&"set_day"):
			_pills[index].call(&"set_day", day)
		_dates.append(String(day.get("date", "")))


## Pops the pill for [param date_value] (R15: the pill that just became `done`).
func pulse_date(date_value: String) -> void:
	for index in _pills.size():
		if index < _dates.size() and _dates[index] == date_value:
			if _pills[index].has_method(&"pulse"):
				_pills[index].call(&"pulse")
			return


func pill_count() -> int:
	_ensure_pills()
	return _pills.size()


func pill_at(index: int) -> PanelContainer:
	_ensure_pills()
	if index < 0 or index >= _pills.size():
		return null
	return _pills[index]


## The rendered kind of one pill — the observable the desktop probe and the screenshot check
## compare against `HomeState`.
func kind_at(index: int) -> String:
	var pill := pill_at(index)
	if pill == null or not pill.has_method(&"kind"):
		return ""
	return String(pill.call(&"kind"))


## The weekday letter actually shown by one pill.
func letter_at(index: int) -> String:
	var pill := pill_at(index)
	if pill == null or not pill.has_method(&"letter"):
		return ""
	return String(pill.call(&"letter"))


## The drawn marker of one pill (`check`, `dot`, or none) — R16's "no state by colour alone".
func marker_at(index: int) -> String:
	var pill := pill_at(index)
	if pill == null or not pill.has_method(&"marker_visible"):
		return ""
	return String(pill.call(&"marker_visible"))


func strip_row() -> HBoxContainer:
	return get_node_or_null(^"StripRow") as HBoxContainer


# ------------------------------------------------------------------ internals

func _ensure_pills() -> void:
	if not _pills.is_empty():
		return
	var row := strip_row()
	if row == null:
		return
	for index in DAYS:
		var pill := DAY_PILL.instantiate() as PanelContainer
		if pill == null:
			continue
		pill.name = "DayPill%d" % (index + 1)
		pill.custom_minimum_size = Vector2(0.0, PILL_MIN_HEIGHT)
		pill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(pill)
		pill.gui_input.connect(_on_pill_input.bind(index))
		_pills.append(pill)


func _on_pill_input(event: InputEvent, index: int) -> void:
	if not _is_press(event):
		return
	# The pill that received the event already knows which day it is, so no coordinate math is
	# needed — and no pill can ever be a dead zone.
	accept_event()
	var date_value := _dates[index] if index < _dates.size() else ""
	pressed.emit(date_value)


## A tap (or a real desktop click) is a press; everything else — motion, release, a click that
## was already delivered as a touch — is ignored.
func _is_press(event: InputEvent) -> bool:
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).pressed
	if event is InputEventMouseButton and not _mouse_is_emulated:
		var click := event as InputEventMouseButton
		return click.button_index == MOUSE_BUTTON_LEFT and click.pressed
	return false
