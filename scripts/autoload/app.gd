extends Node
## Global application state: theme, safe-area insets, layout class, and app-wide signals.
##
## PRD-02 R16/R17/R18. Settings persistence arrives in PRD-03; the units/settings UI in
## PRD-06. This autoload deliberately does NOT touch other autoloads in `_ready()` —
## Godot fires `_ready` as each autoload is added, so cross-singleton work is deferred
## through `_boot.call_deferred()`.
##
## PRD-06 R2 adds the two delegation methods every screen uses ([method get_setting] /
## [method set_setting]) and the live-apply fan-out: writing `units` or `theme` repaints the
## running UI **before** the signal fires, so a slot that re-renders a weight reads the new
## unit. `Store` remains the single source of truth; `settings` here is only the mirror used
## before `Store` finishes loading and by [method units] / [method theme_mode].

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
## used when the settings document is missing or corrupt. The key set mirrors appendix §5.1;
## `Migrations.Schema.default_settings()` is the canonical table and the source of these values.
const DEFAULT_SETTINGS := {
	"schema_version": 2,
	"units": UNITS_LB,
	"theme": THEME_DARK,
	"weekly_goal_days": 4,
	"onboarding_complete": false,
	"attribution_seen": false,
	"rest_timer": {
		"enabled": true,
		"auto_start": true,
		"sound": true,
		"haptic": true,
		"default_seconds": 90,
	},
	"llm": {
		"provider": "deepseek",
		"base_url": "https://api.deepseek.com/v1",
		"model": "deepseek-chat",
		"api_key": "",
		"temperature": 0.4,
		"timeout_sec": 45,
		"custom_auth_none": false,
		"custom_json_mode": true,
		"custom_name": "",
		"configured": false,
		"last_tested_at": null,
		"last_test_ok": null,
	},
	"ui": {
		"last_tab": 0,
		"reduce_motion": false,
		"sound_enabled": true,
		"haptics_enabled": true,
		"haptics_unavailable_shown": false,
		"text_scale": 1.0,
		"wizard_draft": {},
	},
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
	# Runs after every autoload is in the tree, so reading Store is safe here (R20).
	_adopt_stored_settings()
	_apply_theme()
	print("[theme] mode=%s applied" % theme_mode)
	print("[ui] insets=(%d, %d, %d, %d) class=%d" % [
		int(_insets.x), int(_insets.y), int(_insets.z), int(_insets.w), _layout_class])
	# Data probe: one greppable line proving the store and the library are live.
	if is_instance_valid(Store):
		print("[data] settings_keys=%d history=%d library=%d" % [
			Store.settings().size(),
			Store.history_doc().get("entries", []).size(),
			Library.count() if is_instance_valid(Library) else 0])


## Adopts whatever Store loaded from disk, so a persisted theme/units choice survives a
## restart. Store remains the single source of truth; App keeps a working copy.
func _adopt_stored_settings() -> void:
	if not is_instance_valid(Store):
		return
	var stored: Dictionary = Store.settings()
	if stored.is_empty():
		return
	for key in DEFAULT_SETTINGS:
		if stored.has(key):
			settings[key] = stored[key]
	var mode := String(settings.get("theme", THEME_DARK))
	theme_mode = mode if DesignTokens.MODES.has(mode) else THEME_DARK
	Nav.set_reduce_motion(bool(_mirror_get("ui.reduce_motion", false)))
	if is_instance_valid(Feedback):
		Feedback.haptics_enabled = bool(_mirror_get("ui.haptics_enabled", true))
		Feedback.sfx_enabled = bool(_mirror_get("ui.sound_enabled", true))


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
	if is_instance_valid(Store):
		Store.set_setting("theme", mode)
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
	if not Units.is_valid_units(new_units):
		push_error("[App] unknown units '%s'" % new_units)
		return false
	return set_setting("units", new_units)


## Dotted-path read (`"llm.model"`, `"ui.reduce_motion"`). Delegates to [method Store.get_setting]
## so a screen never reads the file and never caches a stale copy (appendix §1.1/R20).
func get_setting(path: String, default_value: Variant = null) -> Variant:
	if is_instance_valid(Store) and Store.is_loaded():
		return Store.get_setting(path, default_value)
	return _mirror_get(path, default_value)


## Dotted-path write (appendix §1.1, PRD-06 R2). Writes through to [Store] first — an invalid or
## out-of-range value is rejected there and returns false without emitting — then applies any
## visual consequence of [param path] **before** emitting, so a slot that re-renders a weight on
## [signal units_changed] already reads the new unit.
##
## Signal order: [signal units_changed] / [signal theme_changed] first, then
## [signal settings_changed] with the key that changed.
func set_setting(path: String, value: Variant) -> bool:
	if is_instance_valid(Store):
		if not Store.set_setting(path, value):
			return false
	_mirror_set(path, value)

	match path:
		"theme":
			var mode := String(value)
			if DesignTokens.MODES.has(mode):
				theme_mode = mode
				_apply_theme()
				print("[theme] mode=%s applied" % mode)
			theme_changed.emit(theme_mode)
		"units":
			units_changed.emit(units())
		"ui.reduce_motion":
			Nav.set_reduce_motion(bool(value))
	settings_changed.emit(path)
	return true


## Applies a settings patch and emits the matching signals. Persistence is PRD-03's job.
## Keys are appendix §5.1 dotted paths, so `ui.reduce_motion` — not the pre-PRD-03 flat alias.
func apply_settings(patch: Dictionary) -> void:
	for key in patch:
		var _written := set_setting(String(key), patch[key])
	settings_changed.emit("")


# ------------------------------------------------------------------ mirror helpers

## Reads the local mirror with the same dotted-path semantics as `Store.get_setting`.
func _mirror_get(path: String, default_value: Variant = null) -> Variant:
	var node: Variant = settings
	for segment in path.split(".", false):
		if not (node is Dictionary) or not (node as Dictionary).has(segment):
			return default_value
		node = (node as Dictionary)[segment]
	return node


## Writes one path in the local mirror, creating nothing: an unknown key is ignored, because
## `Store` (the source of truth) has already rejected it by the time this is called.
func _mirror_set(path: String, value: Variant) -> void:
	var segments := path.split(".", false)
	if segments.is_empty():
		return
	var cursor: Dictionary = settings
	for i in range(segments.size() - 1):
		var next: Variant = cursor.get(segments[i], null)
		if not (next is Dictionary):
			return
		cursor = next
	cursor[segments[segments.size() - 1]] = value
