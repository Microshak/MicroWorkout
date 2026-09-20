class_name Routes
extends RefCounted
## The route table. Adding a screen means adding one entry here — no other file changes
## (PRD-02 R12). Route names are StringNames so comparisons are cheap and typos are loud.
##
## PRD-06 adds three routes (appendix §2): the onboarding wizard, the boot screen (so the
## reset-all-data flow can send the user back through onboarding) and the attribution screen
## reached from Settings. Nothing existing was restructured.
##
## PRD-08 adds the two the New Workout wizard needs: the six-step wizard and the generated-plan
## preview. Both are PUSH routes, so they cover the bottom nav until the flow ends (PRD-08 R1/R12).
##
## PRD-10 adds the three the workout flow needs: the session preview Home links to, the player
## itself, and the completion celebration (PRD-10 R1). All three are PUSH routes; the completion
## screen is reached with `Nav.replace`, so the player it replaces can never be backed into.

const SHELL := &"shell"
const BOOT := &"boot"
const ONBOARDING := &"onboarding"
const HOME := &"home"
const PLAN := &"plan"
const TRACKER := &"tracker"
const SETTINGS := &"settings"
const ATTRIBUTION := &"attribution"
const GALLERY := &"gallery"
const NEW_WORKOUT_WIZARD := &"new_workout_wizard"
const PLAN_PREVIEW := &"plan_preview"
const SESSION_PREVIEW := &"session_preview"
const WORKOUT_PLAYER := &"workout_player"
const COMPLETION := &"completion"

## Tab routes, in bottom-nav order. Index in this array == nav tab index.
const TAB_ROUTES: PackedStringArray = [HOME, PLAN, TRACKER, SETTINGS]

## Routes that replace the **main scene** instead of being pushed inside the shell's ScreenHost
## (appendix §1.5's `res://…tscn` rule, appendix §2's "Mode: main scene" column). These are the
## only legal targets of a main-scene replacement.
const MAIN_SCENE_ROUTES: PackedStringArray = [SHELL, BOOT, ONBOARDING]

## Pushed routes (full-screen, cover the bottom nav) plus the two main-scene flows.
const TABLE := {
	SHELL: "res://scenes/ui/shell.tscn",
	BOOT: "res://scenes/ui/boot_screen.tscn",
	ONBOARDING: "res://scenes/ui/onboarding_flow.tscn",
	GALLERY: "res://scenes/ui/dev_component_gallery.tscn",
	ATTRIBUTION: "res://scenes/ui/attribution_screen.tscn",
	NEW_WORKOUT_WIZARD: "res://scenes/ui/new_workout_wizard.tscn",
	PLAN_PREVIEW: "res://scenes/ui/plan_preview.tscn",
	SESSION_PREVIEW: "res://scenes/ui/session_preview.tscn",
	WORKOUT_PLAYER: "res://scenes/ui/workout_player.tscn",
	COMPLETION: "res://scenes/ui/completion_screen.tscn",
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


## The scene for [param route], or `""` when it is not a route.
static func scene_for(route: StringName) -> String:
	if TAB_SCENES.has(route):
		return String(TAB_SCENES[route])
	return String(TABLE.get(route, ""))


## True when [param route] must be loaded with `change_scene_to_file()` rather than pushed into
## the shell's ScreenHost. `BootScreen` and the wizard call this instead of guessing.
static func is_main_scene(route: StringName) -> bool:
	return MAIN_SCENE_ROUTES.has(route)
