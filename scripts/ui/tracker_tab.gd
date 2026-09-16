extends "res://scripts/ui/tab_scaffold.gd"
## Tracker tab — progress history. PRD-11 adds the calendar, streak detail, the weekly
## ring and the per-body-area balance view.


func _ready() -> void:
	configure("Progress", "Coming in PRD-11",
		"Your streak, completed days and which body areas you have been training will be "
		+ "tracked here.", &"tracker")
