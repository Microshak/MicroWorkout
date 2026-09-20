extends Node
## Haptics, UI sounds, and toasts.
##
## PRD-02 R19 implements the toast layer; real haptics/sound land in PRD-12 (this file's
## `tap()`/`success()` stay no-ops until then, so nothing regresses).

signal toast_shown(text: String, kind: StringName)
signal toast_dismissed

const TOAST_SCENE := "res://scenes/components/toast.tscn"
const TOAST_GAP := 24       # px above the bottom nav

var haptics_enabled: bool = true
var sfx_enabled: bool = true

var _toast: Control = null


func _ready() -> void:
	print("[Feedback] ready")


## Three sequential phases from DesignTokens.MOTION: in 120 ms / hold 2600 ms / out 180 ms.
func toast(text: String, kind: StringName = &"info") -> void:
	var layer := _toast_layer()
	if layer == null:
		# Before the shell exists there is nowhere to show a toast; the log line keeps
		# the message discoverable rather than silently dropping it.
		print("[toast] %s (%s)" % [text, kind])
		return

	dismiss_toast()

	# Debug-only observability, like `UiProbe`'s rect lines: a toast is a user-visible outcome and
	# AC9 asserts one ("Session discarded."), but a toast layer that exists leaves nothing in logcat
	# to grep — and the banner is gone in 2.6 s, which is under two frames on the emulator.
	if OS.is_debug_build():
		print("[toast] %s (%s)" % [text, kind])

	if not ResourceLoader.exists(TOAST_SCENE):
		push_warning("[Feedback] toast scene missing: %s" % TOAST_SCENE)
		return

	var scene: PackedScene = load(TOAST_SCENE)
	_toast = scene.instantiate()
	layer.add_child(_toast)

	if _toast.has_method(&"show_message"):
		_toast.call(&"show_message", text, kind)

	_toast.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_toast.offset_left = DesignTokens.GUTTER
	_toast.offset_right = -DesignTokens.GUTTER
	_toast.offset_bottom = -(DesignTokens.NAV_BAR_HEIGHT + TOAST_GAP)

	_toast.modulate.a = 0.0
	var hold_ms := int(DesignTokens.MOTION["toast_hold_ms"])
	var tween := create_tween()
	tween.tween_property(_toast, "modulate:a", 1.0,
		float(DesignTokens.MOTION["toast_in_ms"]) / 1000.0)
	tween.tween_interval(float(hold_ms) / 1000.0)
	tween.tween_property(_toast, "modulate:a", 0.0,
		float(DesignTokens.MOTION["toast_out_ms"]) / 1000.0)
	tween.tween_callback(dismiss_toast)

	toast_shown.emit(text, kind)


func dismiss_toast() -> void:
	if _toast != null and is_instance_valid(_toast):
		_toast.queue_free()
		_toast = null
		toast_dismissed.emit()


func has_toast() -> bool:
	return _toast != null and is_instance_valid(_toast)


func _toast_layer() -> Control:
	var shell := Nav.shell()
	if shell == null or not is_instance_valid(shell):
		return null
	return shell.toast_layer()


# ------------------------------------------------------------------ haptics (PRD-12)

## Short haptic tap. No-op until PRD-12.
func tap() -> void:
	pass


## Success haptic. No-op until PRD-12.
func success() -> void:
	pass
