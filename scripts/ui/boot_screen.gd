extends Control
## Splash / boot screen.
##
## PRD-01: prints identity + platform (the Android smoke test greps for this line),
## holds the splash for a moment, then routes on.
##
## PRD-02 changes the destination to the real Shell and PRD-06 inserts onboarding
## when `onboarding_complete` is false.

const HOME_SCENE := "res://scenes/ui/placeholder_home.tscn"

@onready var _status: Label = $Center/VBox/Status


func _ready() -> void:
	print("[boot] %s %s ready" % [AppInfo.NAME, AppInfo.VERSION])
	print("[boot] platform=%s" % OS.get_name())
	_boot()


func _boot() -> void:
	await get_tree().create_timer(AppInfo.MIN_SPLASH_SECONDS).timeout
	if is_instance_valid(_status):
		_status.text = "Ready"
	Nav.goto(HOME_SCENE)
