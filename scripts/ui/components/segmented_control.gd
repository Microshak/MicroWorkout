class_name SegmentedControl
extends HBoxContainer
## Segmented control — PRD-06 (appendix §3.2), used for `lb`/`kg`, `Dark`/`Light` and every
## later either/or choice.
##
## Built from [ChipToggle] instances rather than new drawing code: selection is the native
## `toggle_mode`/`button_pressed` pair, so the theme's `ChipToggle` pressed/hover_pressed styles
## do the heavy lifting and no colour is ever overridden (appendix §4.3 rule 8). A `ButtonGroup`
## makes "exactly one option is on" a property of the control instead of a rule each screen has
## to remember.
##
## The frozen API is index-based ([method set_selected] / [method selected] /
## [signal selected_changed]). [method set_values] adds an optional label→value mapping on top,
## which is what lets Settings store `"kg"` while the picker deals in option 1.

signal selected_changed(index: int)

const CHIP_SCENE := preload("res://scenes/components/chip_toggle.tscn")

var _labels: PackedStringArray = PackedStringArray()
var _values: PackedStringArray = PackedStringArray()
var _chips: Array[Button] = []
var _selected: int = 0
var _group: ButtonGroup = null


func _ready() -> void:
	_ensure_group()
	_rebuild()


## Replaces the option labels. The selection index is preserved when it still exists, otherwise
## it falls back to 0. Emits nothing: a rebuild is not a user action.
func set_options(labels: PackedStringArray) -> void:
	_labels = labels
	if _selected >= _labels.size():
		_selected = 0
	_rebuild()


## Optional parallel array of stored values, one per option (`["lb", "kg"]`). Order independent:
## call it before or after [method set_options].
func set_values(values: PackedStringArray) -> void:
	_values = values


## Selects an option programmatically. Silent by design — a screen restoring a stored setting is
## not the user changing it, and an echoing signal here is how feedback loops start.
func set_selected(index: int) -> void:
	if index < 0 or index >= _labels.size() or index == _selected:
		return
	_selected = index
	_apply_selection()


func selected() -> int:
	return _selected


func selected_value() -> String:
	if _selected >= 0 and _selected < _values.size():
		return _values[_selected]
	return ""


func option_count() -> int:
	return _labels.size()


func value_of(index: int) -> String:
	if index >= 0 and index < _values.size():
		return _values[index]
	return ""


## Selects the option whose value equals [param value]. Returns false when no option matches, so
## a caller can tell "restored" from "left on the default".
func select_value(value: String) -> bool:
	var index := _values.find(value)
	if index < 0:
		return false
	set_selected(index)
	return true


func is_option_visible(index: int) -> bool:
	if index < 0 or index >= _chips.size():
		return false
	return _chips[index].visible


## The chip `Control` for [param index], so a screen — or the Android rect probe — can address
## one option directly. `null` for an index that has no chip.
func option_control(index: int) -> Control:
	if index < 0 or index >= _chips.size():
		return null
	return _chips[index]


## The chip that is currently *not* selected: the natural target for a "toggle this setting"
## action, and what keeps PRD-02's `theme_button` probe name meaningful now that the theme row
## is a segmented control rather than one button.
func other_option_control() -> Control:
	if _chips.size() < 2:
		return null
	return _chips[1] if _selected == 0 else _chips[0]


# ------------------------------------------------------------------ internals

func _ensure_group() -> void:
	if _group == null:
		_group = ButtonGroup.new()


## Builds or resizes the chip row. Chips are only ever appended, so a chip's bound index stays
## valid for its whole life.
func _rebuild() -> void:
	_ensure_group()
	while _chips.size() > _labels.size():
		var extra: Button = _chips.pop_back()
		remove_child(extra)
		extra.queue_free()
	while _chips.size() < _labels.size():
		var chip: Button = CHIP_SCENE.instantiate()
		add_child(chip)
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.button_group = _group
		chip.toggled.connect(_on_chip_toggled.bind(_chips.size()))
		_chips.append(chip)
	for i in _chips.size():
		var chip: Button = _chips[i]
		chip.text = _labels[i]
		chip.toggle_mode = true
	_apply_selection()


func _apply_selection() -> void:
	for i in _chips.size():
		_chips[i].set_pressed_no_signal(i == _selected)


func _on_chip_toggled(pressed: bool, index: int) -> void:
	# A ButtonGroup emits `toggled(false)` for the option that just lost, which is not a change.
	if not pressed or index == _selected:
		return
	_selected = index
	selected_changed.emit(index)
