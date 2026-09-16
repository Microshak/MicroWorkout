extends Control
## Shared scaffolding for the four placeholder tabs built in PRD-02.
##
## Each tab becomes a real screen later; PRD-06/08/09/11 replace the empty-state body
## with product content. Keeping the scaffolding here means those PRDs only edit a tab's
## own script and scene, never the shell.
##
## Nodes are resolved lazily rather than with `@onready` so a subclass overriding
## `_ready()` cannot accidentally skip the base class's initialization.

const PAGE_PATH := "Scroll/Gutter/Page"


## Fills in the header and the "not built yet" empty state for this tab.
func configure(title: String, empty_title: String, empty_body: String,
		icon: StringName = &"info") -> void:
	var page := get_node_or_null(PAGE_PATH) as VBoxContainer
	var header := get_node_or_null("%s/SectionHeader" % PAGE_PATH)
	var empty := get_node_or_null("%s/EmptyState" % PAGE_PATH)

	if header != null and header.has_method(&"set_header"):
		header.call(&"set_header", title, "")
	if empty != null and empty.has_method(&"set_state"):
		empty.call(&"set_state", icon, empty_title, empty_body, "")
	if page != null:
		page.add_theme_constant_override(&"separation",
			LayoutUtil.section_spacing(App.layout_class()))


## Adds a row of buttons below the empty state (PRD-02 scaffolding only).
func add_actions(buttons: Array[Button]) -> void:
	var page := get_node_or_null(PAGE_PATH) as VBoxContainer
	if page == null:
		return
	for button in buttons:
		page.add_child(button)


## Nav calls this when the tab becomes visible.
func on_route_entered(_args: Dictionary) -> void:
	pass


## Nav calls this when the tab is hidden.
func on_route_exited() -> void:
	pass
