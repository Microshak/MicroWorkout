extends Control
## Blocking "working…" overlay — PRD-02 R7.
##
## Hidden by default so an instantiated component is inert until [method show_overlay] is
## called. The scrim (`Dim`) already stops the mouse; the root stays `IGNORE` so no invisible
## full-screen Control ever eats input while the overlay is hidden.

## Scrim colour: the theme's `dim_color` (bg at 72 % alpha, R3), read — never hard-coded.
func _apply_theme() -> void:
	var dim := get_node_or_null(^"Dim") as ColorRect
	if dim != null:
		dim.color = get_theme_color(&"dim_color", &"LoadingOverlay")


func _ready() -> void:
	_apply_theme()
	# The spinner carries no number: blank the ring's automatic "0%" text (appendix §3.1).
	var spinner := ring()
	if spinner != null and spinner.has_method(&"set_caption_value"):
		spinner.call(&"set_caption_value", "")


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()


## Shows the overlay, optionally with a message under the spinner.
func show_overlay(message: String = "") -> void:
	var label := message_label()
	if label != null:
		label.text = message
		label.visible = not message.is_empty()
	visible = true


func hide_overlay() -> void:
	visible = false


func is_showing() -> bool:
	return visible


func message_label() -> Label:
	return get_node_or_null(^"Center/Stack/Message") as Label


## The indeterminate ring driving the spinner.
func ring() -> Control:
	return get_node_or_null(^"Center/Stack/progress_ring") as Control
