extends "res://scripts/ui/tab_scaffold.gd"
## Plan tab — the week view. The New Workout wizard (PRD-08) starts from here, and
## PRD-10 owns the day-card → session-preview → start flow.


func _ready() -> void:
	configure("This Week", "Coming in PRD-08",
		"Your generated week appears here as day cards. Tapping one previews the session "
		+ "before you start it.", &"plan")
