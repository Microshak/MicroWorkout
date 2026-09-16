class_name Routes
extends RefCounted
## The route table. Adding a screen means adding one entry here — no other file changes
## (PRD-02 R12). Route names are StringNames so comparisons are cheap and typos are loud.

const SHELL := &"shell"
const HOME := &"home"
const PLAN := &"plan"
const TRACKER := &"tracker"
const SETTINGS := &"settings"
const GALLERY := &"gallery"

## Tab routes, in bottom-nav order. Index in this array == nav tab index.
const TAB_ROUTES: PackedStringArray = [HOME, PLAN, TRACKER, SETTINGS]

## Pushed routes (full-screen, cover the bottom nav).
const TABLE := {
	SHELL: "res://scenes/ui/shell.tscn",
	GALLERY: "res://scenes/ui/dev_component_gallery.tscn",
}

const TAB_SCENES := {
	HOME: "res://scenes/ui/home_tab.tscn",
	PLAN: "res://scenes/ui/plan_tab.tscn",
	TRACKER: "res://scenes/ui/tracker_tab.tscn",
	SETTINGS: "res://scenes/ui/settings_tab.tscn",
}

## Human-readable tab titles, used by the bottom nav captions and top bars.
const TAB_TITLES: PackedStringArray = ["Home", "Plan", "Tracker", "Settings"]

## Glyph kinds for the four tabs (PRD-02 R10).
const TAB_GLYPHS: PackedStringArray = ["home", "plan", "tracker", "settings"]
