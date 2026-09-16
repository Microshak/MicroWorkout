extends Node
## Screen router.
##
## PRD-01: plain scene swap, enough to prove the boot path on Android.
## PRD-02 replaces this with a real screen stack, tab switching, transitions, and
## Android hardware back-button handling.

var current_scene_path: String = ""


func _ready() -> void:
	print("[Nav] ready")


## Replaces the current screen with the scene at [param scene_path].
func goto(scene_path: String) -> void:
	if scene_path == current_scene_path:
		return
	if not ResourceLoader.exists(scene_path):
		push_error("[Nav] scene not found: %s" % scene_path)
		return
	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		push_error("[Nav] cannot load %s (error %d)" % [scene_path, err])
		return
	current_scene_path = scene_path
	print("[Nav] -> %s" % scene_path)
