extends Node
## Global application state: theme, safe-area insets, layout class, and app-wide signals.
##
## PRD-02 R16/R17/R18. Settings persistence arrives in PRD-03; the units/settings UI in
## PRD-06. This autoload deliberately does NOT touch other autoloads in `_ready()` —
## Godot fires `_ready` as each autoload is added, so cross-singleton work is deferred
## through `_boot.call_deferred()`.

signal units_changed(units: String)
signal theme_changed(mode: String)
signal settings_changed(key: String)          # "" means a bulk change
## Emitted by Store once persistence exists (PRD-03); declared here so every consumer can
## connect from the start.
@warning_ignore("unused_signal")
signal data_changed()
signal safe_area_changed(insets: Vector4)
signal layout_class_changed(cls: int)

const UNITS_LB := "lb"
const UNITS_KG := "kg"
const THEME_DARK := DesignTokens.MODE_DARK
const THEME_LIGHT := DesignTokens.MODE_LIGHT

const THEME_PATHS := {
	THEME_DARK: "res://resources/themes/theme_dark.tres",
	THEME_LIGHT: "res://resources/themes/theme_light.tres",
}

## Default settings. PRD-03 makes the stored copy authoritative and this the fallback
## used when the settings document is missing or corrupt.
const DEFAULT_SETTINGS := {
	"schema_version": 2,
	"units": UNITS_LB,
	"theme": THEME_DARK,
	"weekly_goal_days": 4,
	"onboarding_complete": false,
	"rest_timer_enabled": true,
	"rest_timer_default_sec": 90,
	"haptics_enabled": true,
	"sfx_enabled": true,
	"reduce_motion": false,
}

var settings: Dictionary = DEFAULT_SETTINGS.duplicate(true)

var theme_mode: String = THEME_DARK
var _layout_class: int = LayoutUtil.Class.NORMAL
var _insets: Vector4 = Vector4.ZERO


func _ready() -> void:
	theme_mode = String(settings.get("theme", THEME_DARK))
	_apply_theme()
	var root := get_tree().root
	if root != null:
		if not root.size_changed.is_connected(_on_root_resized):
			root.size_changed.connect(_on_root_resized)
	_recompute_layout()
	print("[App] ready — %s %s (%s)" % [AppInfo.NAME, AppInfo.VERSION, OS.get_name()])
	_boot.call_deferred()


func _boot() -> void:
	# Runs after every autoload is in the tree, so touching other singletons is safe.
	print("[theme] mode=%s applied" % theme_mode)
	print("[ui] insets=(%d, %d, %d, %d) class=%d" % [
		int(_insets.x), int(_insets.y), int(_insets.z), int(_insets.w), _layout_class])


# ------------------------------------------------------------------ theme

func theme_resource() -> Theme:
	var path: String = THEME_PATHS.get(theme_mode, THEME_PATHS[THEME_DARK])
	if not ResourceLoader.exists(path):
		push_warning("[theme] missing theme resource: %s" % path)
		return null
	return load(path) as Theme


func _apply_theme() -> void:
	var theme := theme_resource()
	if theme == null:
		return
	var root := get_tree().root
	if root != null:
		root.theme = theme


## Switches dark/light live — no scene reload, restyles every live Control because the
## theme is applied at the Window root. Returns false for an unknown mode.
func set_theme_mode(mode: String) -> bool:
	if not DesignTokens.MODES.has(mode):
		push_error("[theme] unknown mode '%s'" % mode)
		return false
	if mode == theme_mode:
		return true
	theme_mode = mode
	settings["theme"] = mode
	_apply_theme()
	print("[theme] mode=%s applied" % mode)
	theme_changed.emit(mode)
	settings_changed.emit("theme")
	return true


func toggle_theme() -> bool:
	return set_theme_mode(THEME_LIGHT if theme_mode == THEME_DARK else THEME_DARK)


# ------------------------------------------------------------------ layout

func layout_class() -> int:
	return _layout_class


func safe_area_insets() -> Vector4:
	return _insets


func _on_root_resized() -> void:
	_recompute_layout()


func _recompute_layout() -> void:
	var insets := _compute_insets()
	var changed_insets := not insets.is_equal_approx(_insets)
	_insets = insets

	var cls := LayoutUtil.classify(get_viewport().get_visible_rect().size.y)
	var changed_class := cls != _layout_class
	_layout_class = cls

	if changed_insets:
		safe_area_changed.emit(_insets)
	if changed_class:
		layout_class_changed.emit(_layout_class)


## Safe-area insets in design px (left, top, right, bottom) — PRD-02 R16.
func _compute_insets() -> Vector4:
	if not OS.has_feature("mobile"):
		return Vector4.ZERO

	var screen := Vector2(DisplayServer.screen_get_size())
	var safe := DisplayServer.get_display_safe_area()
	var vp := get_viewport().get_visible_rect().size
	if screen.x <= 0.0 or screen.y <= 0.0:
		return DesignTokens.SAFE_FALLBACK

	# Android reporting the whole screen means "no cutout information", which is
	# indistinguishable from "no cutout" — fall back to tuned constants.
	if safe.position == Vector2i.ZERO and safe.size == Vector2i(screen):
		return DesignTokens.SAFE_FALLBACK

	var sx := vp.x / screen.x
	var sy := vp.y / screen.y
	return Vector4(
		maxf(safe.position.x * sx, 0.0),
		maxf(safe.position.y * sy, 0.0),
		maxf((screen.x - safe.end.x) * sx, 0.0),
		maxf((screen.y - safe.end.y) * sy, 0.0))


# ------------------------------------------------------------------ units / settings

func units() -> String:
	return String(settings.get("units", UNITS_LB))


func set_units(new_units: String) -> bool:
	if new_units != UNITS_LB and new_units != UNITS_KG:
		push_error("[App] unknown units '%s'" % new_units)
		return false
	if new_units == units():
		return true
	settings["units"] = new_units
	units_changed.emit(new_units)
	settings_changed.emit("units")
	return true


## Applies a settings patch and emits the matching signals. Persistence is PRD-03's job.
func apply_settings(patch: Dictionary) -> void:
	for key in patch:
		settings[key] = patch[key]
	if patch.has("theme"):
		set_theme_mode(String(patch["theme"]))
	if patch.has("reduce_motion"):
		Nav.set_reduce_motion(bool(patch["reduce_motion"]))
	if patch.has("units"):
		units_changed.emit(String(patch["units"]))
	settings_changed.emit("")
