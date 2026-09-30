extends PanelContainer
## Screen header — PRD-02 R7.
##
## Back and action are ghost buttons, so the bar carries no fill of its own beyond the
## `TopBar` variation's hairline border.

signal back_pressed
signal action_pressed


func _ready() -> void:
	custom_minimum_size.y = float(DesignTokens.TOP_BAR_HEIGHT)
	var back := back_button()
	if back != null and not back.pressed.is_connected(_on_back_pressed):
		back.pressed.connect(_on_back_pressed)
	A11y.label(back, "Back")
	var action := action_button()
	if action != null and not action.pressed.is_connected(_on_action_pressed):
		action.pressed.connect(_on_action_pressed)
	if action != null and not action.text.is_empty():
		A11y.label(action, action.text)


func set_title(t: String) -> void:
	var title := get_node_or_null(^"Row/Title") as Label
	if title != null:
		title.text = t


## [param text] empty hides the trailing action button.
func set_action(text: String) -> void:
	var action := action_button()
	if action == null:
		return
	action.text = text
	action.visible = not text.is_empty()
	if not text.is_empty():
		A11y.label(action, text)


func back_button() -> Button:
	return get_node_or_null(^"Row/Back") as Button


func action_button() -> Button:
	return get_node_or_null(^"Row/Action") as Button


func _on_back_pressed() -> void:
	back_pressed.emit()


func _on_action_pressed() -> void:
	action_pressed.emit()
