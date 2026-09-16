extends Node
## Global application state and app-wide signals.
##
## PRD-01: skeleton only — in-memory defaults, no persistence.
## PRD-03 adds loading/saving through [Store]; PRD-06 adds the theme engine and
## the settings UI that mutate these values.

signal units_changed(units: String)
signal theme_changed(theme_name: String)
signal settings_changed
signal data_changed

const UNITS_LB := "lb"
const UNITS_KG := "kg"
const THEME_DARK := "dark"
const THEME_LIGHT := "light"

## Default settings. PRD-03 moves the authoritative copy into Store and makes
## this the fallback used when the settings file is missing or corrupt.
const DEFAULT_SETTINGS := {
	"schema_version": 1,
	"units": UNITS_LB,
	"theme": THEME_DARK,
	"weekly_goal_days": 4,
	"onboarding_complete": false,
	"rest_timer_enabled": true,
	"rest_timer_default_sec": 90,
	"haptics_enabled": true,
	"sfx_enabled": true,
}

var settings: Dictionary = DEFAULT_SETTINGS.duplicate(true)


func _ready() -> void:
	print("[App] ready — %s %s (%s)" % [AppInfo.NAME, AppInfo.VERSION, OS.get_name()])
