extends Node
## Persistence entry point for settings, plans, and history.
##
## PRD-01: skeleton only. PRD-03 implements the real store: atomic JSON writes to
## user://data/, .bak backups, corruption quarantine, and a migration chain.
##
## Rule (master plan §13): UI code never touches user:// directly — it goes through here.

const DATA_DIR := "user://data"
const SETTINGS_FILE := "user://data/settings.json"
const PLANS_FILE := "user://data/plans.json"
const HISTORY_FILE := "user://data/history.json"


func _ready() -> void:
	print("[Store] ready")


## Creates the data directory if it does not exist. Returns true on success.
func ensure_data_dir() -> bool:
	if DirAccess.dir_exists_absolute(DATA_DIR):
		return true
	var err := DirAccess.make_dir_recursive_absolute(DATA_DIR)
	if err != OK:
		push_error("[Store] cannot create %s (error %d)" % [DATA_DIR, err])
		return false
	return true
