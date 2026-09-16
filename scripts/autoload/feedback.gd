extends Node
## Haptics, UI sounds, and toasts.
##
## PRD-01: skeleton only. PRD-12 wires real haptics/sound and the global mute toggle.

var haptics_enabled: bool = true
var sfx_enabled: bool = true


func _ready() -> void:
	print("[Feedback] ready")


## Short haptic tap. No-op until PRD-12.
func tap() -> void:
	pass


## Success haptic. No-op until PRD-12.
func success() -> void:
	pass
