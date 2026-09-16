extends HBoxContainer
## Section title with an optional trailing action — PRD-02 R7.
##
## `set_header("Today", "Edit")` shows the ghost action button; `set_header("Today")` hides it.

signal action_pressed


func _ready() -> void:
	var action := action_button()
	if action != null and not action.pressed.is_connected(_on_action_pressed):
		action.pressed.connect(_on_action_pressed)


## [param action_text] empty (the default) hides the action button entirely.
func set_header(title: String, action_text: String = "") -> void:
	var title_label := get_node_or_null(^"Title") as Label
	if title_label != null:
		title_label.text = title
	var action := action_button()
	if action != null:
		action.text = action_text
		action.visible = not action_text.is_empty()


func action_button() -> Button:
	return get_node_or_null(^"Action") as Button


func _on_action_pressed() -> void:
	action_pressed.emit()
