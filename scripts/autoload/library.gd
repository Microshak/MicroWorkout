extends Node
## Read-only access to the bundled exercise library.
##
## PRD-01: skeleton only. PRD-04 builds res://data/exercise_library.json and
## implements loading, indexing, and lookup here.

const LIBRARY_PATH := "res://data/exercise_library.json"

var exercises: Array[Dictionary] = []
var is_loaded: bool = false


func _ready() -> void:
	print("[Library] ready (library not built yet — PRD-04)")


## Returns the exercise record for [param id], or an empty dictionary.
func get_exercise(id: String) -> Dictionary:
	for exercise in exercises:
		if exercise.get("id", "") == id:
			return exercise
	return {}
