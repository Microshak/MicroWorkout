extends PanelContainer
## Transient message banner — PRD-02 R7 + R19.
##
## Timing comes from `MOTION` (in 120 ms / hold 2600 ms / out 180 ms) and is self-contained so
## the component works standalone; `Feedback` may also drive it and call [method hide_message]
## itself. The banner never blocks input (R19: the toast layer ignores the mouse), so it is
## `mouse_filter = IGNORE`.

signal dismissed

## R19's kind → glyph mapping. `danger` shares `warning`'s triangle because the icon set has
## no dedicated error icon; the two states are told apart by the message text, never by colour
## alone (§4.2 rule 6).
const KIND_GLYPHS: Dictionary = {
	"info": &"info",
	"success": &"check",
	"warning": &"warning",
	"danger": &"warning",
}

var _kind: StringName = &"info"
var _tween: Tween = null


## Shows [param text]. [param kind] ∈ `info|success|warning|danger`.
func show_message(text: String, kind: StringName = &"info") -> void:
	_kind = kind if KIND_GLYPHS.has(String(kind)) else &"info"
	var message := message_label()
	if message != null:
		message.text = text
	var icon := kind_icon()
	if icon != null:
		icon.set(&"kind", KIND_GLYPHS[String(_kind)])
	visible = true
	if not is_inside_tree():
		modulate.a = 1.0
		return
	_fade_in_then_auto_dismiss()


## Fades the banner out over `MOTION.toast_out_ms` and emits [signal dismissed] when hidden.
func hide_message() -> void:
	if not is_inside_tree():
		visible = false
		dismissed.emit()
		return
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0,
		float(DesignTokens.MOTION["toast_out_ms"]) / 1000.0) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_callback(_finish_dismiss)


func message_label() -> Label:
	return get_node_or_null(^"Row/Message") as Label


func kind_icon() -> Control:
	return get_node_or_null(^"Row/KindIcon") as Control


## The kind currently displayed, after validation against [constant KIND_GLYPHS].
func kind() -> StringName:
	return _kind


func _fade_in_then_auto_dismiss() -> void:
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0,
		float(DesignTokens.MOTION["toast_in_ms"]) / 1000.0) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_interval(float(DesignTokens.MOTION["toast_hold_ms"]) / 1000.0)
	_tween.tween_property(self, "modulate:a", 0.0,
		float(DesignTokens.MOTION["toast_out_ms"]) / 1000.0) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_callback(_finish_dismiss)


func _finish_dismiss() -> void:
	_tween = null
	visible = false
	dismissed.emit()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
