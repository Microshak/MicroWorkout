extends VBoxContainer
## Empty / zero-data state — PRD-02 R7 (`set_state(&"plan", "No plan yet", "Generate one", "Start")`).
##
## The call to action is optional: with no [param action_text] the button is hidden and the
## state stays purely informational.

signal action_pressed


func _ready() -> void:
	var action := action_button()
	if action != null and not action.pressed.is_connected(_on_action_pressed):
		action.pressed.connect(_on_action_pressed)


## Fills the state. [param icon] is any `Glyph` kind, [param action_text] empty hides the CTA.
func set_state(icon: StringName, title: String, body: String, action_text: String = "") -> void:
	var icon_node := get_node_or_null(^"Icon")
	if icon_node != null:
		icon_node.set(&"kind", icon)
		icon_node.visible = icon != &""
	var title_label := get_node_or_null(^"Title") as Label
	if title_label != null:
		title_label.text = title
	var body_label := get_node_or_null(^"Body") as Label
	if body_label != null:
		body_label.text = body
	var action := action_button()
	if action != null:
		action.text = action_text
		action.visible = not action_text.is_empty()
		if not action_text.is_empty():
			A11y.label(action, action_text, title)


func action_button() -> Button:
	return get_node_or_null(^"Action") as Button


func _on_action_pressed() -> void:
	action_pressed.emit()
