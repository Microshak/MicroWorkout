extends "res://scripts/ui/tab_scaffold.gd"
## Settings tab — placeholder for PRD-06, plus two PRD-02 scaffolding controls.
##
## The theme toggle and the component gallery are deliberately temporary: PRD-06 replaces
## this body with real settings rows and PRD-12 removes the debug entry point. They exist
## now because PRD-02's acceptance criteria require a live dark↔light switch on the device
## (AC8/AC9) and a way to reach the component gallery (AC12).

const PAGE := "Scroll/Gutter/Page"


func _ready() -> void:
	configure("Settings", "Coming in PRD-06",
		"Units, theme, weekly goal days and your LLM provider will be configured here. "
		+ "The API key stays on this device.", &"settings")

	var theme_button := get_node_or_null("%s/ThemeButton" % PAGE) as Button
	if theme_button != null:
		theme_button.pressed.connect(_on_toggle_theme)
		_refresh_theme_label(theme_button)
		App.theme_changed.connect(func(_mode: String) -> void: _refresh_theme_label(theme_button))

	var gallery_button := get_node_or_null("%s/GalleryButton" % PAGE) as Button
	if gallery_button != null:
		gallery_button.pressed.connect(_on_open_gallery)

	# Publish tap targets so the Android test tooling can drive them (debug builds only).
	_publish_probe_rects.call_deferred()


func _publish_probe_rects() -> void:
	UiProbe.log_rects({
		"theme_button": get_node_or_null("%s/ThemeButton" % PAGE) as Control,
		"gallery_button": get_node_or_null("%s/GalleryButton" % PAGE) as Control,
	})


## Re-publish on every entry, so the Android test tooling can always find these controls
## even if logcat was cleared since the app started.
func on_route_entered(_args: Dictionary) -> void:
	_publish_probe_rects.call_deferred()


func _on_toggle_theme() -> void:
	App.toggle_theme()


func _on_open_gallery() -> void:
	Nav.push(Routes.GALLERY)


func _refresh_theme_label(button: Button) -> void:
	button.text = "Theme: %s" % App.theme_mode
