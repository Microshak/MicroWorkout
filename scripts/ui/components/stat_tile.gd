extends PanelContainer
## Single-metric tile — PRD-02 R7 (`set_stat("Streak", "4", &"flame")`).
##
## The optional icon is hidden rather than emptied, so a text-only tile keeps its 24 px
## padding and never reserves a dead glyph box.

## Fills the tile. [param icon] is any `Glyph` kind; empty hides the icon row.
func set_stat(title: String, value: String, icon: StringName = &"") -> void:
	var icon_node := get_node_or_null(^"Stack/Icon")
	if icon_node != null:
		icon_node.set(&"kind", icon)
		icon_node.visible = icon != &""
	var value_label := get_node_or_null(^"Stack/ValueLabel") as Label
	if value_label != null:
		value_label.text = value
	var title_label := get_node_or_null(^"Stack/TitleLabel") as Label
	if title_label != null:
		title_label.text = title
