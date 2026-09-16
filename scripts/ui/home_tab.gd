extends "res://scripts/ui/tab_scaffold.gd"
## Home tab — the cover screen. PRD-09 builds the real thing: "Hey Workout", today's
## session card, the Start button, streak and the weekly ring.


func _ready() -> void:
	configure("Today", "Coming in PRD-09",
		"This is where your session for the day, your streak and your weekly goal ring "
		+ "will live.", &"home")
