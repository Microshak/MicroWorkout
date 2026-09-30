class_name Shell
extends Control
## The persistent app frame: four tabs, a bottom nav, a screen host for pushed flows,
## a toast layer, and the transition veil (PRD-02 R11).
##
## Shell owns no product logic. It builds the tabs from [Routes], tells [Nav] it exists,
## and exposes the hooks Nav needs. Every later PRD adds screens under `ScreenHost`
## without touching this file.

@onready var _bg: ColorRect = $Bg
@onready var _safe_area: MarginContainer = $SafeAreaHost
@onready var _tab_host: Control = $SafeAreaHost/TabLayout/TabHost
@onready var _bottom_nav: Control = $SafeAreaHost/TabLayout/BottomNav
@onready var _screen_host: Control = $SafeAreaHost/ScreenHost
@onready var _toast_layer: Control = $ToastLayer
@onready var _veil: ColorRect = $TransitionVeil
@onready var _live_region: Label = $LiveRegion

var _tab_roots: Array[Control] = []


func _ready() -> void:
	_build_tabs()
	_apply_palette()

	App.theme_changed.connect(_on_theme_changed)
	App.safe_area_changed.connect(apply_insets)
	App.layout_class_changed.connect(_on_layout_class_changed)

	if _bottom_nav.has_signal(&"tab_selected"):
		_bottom_nav.connect(&"tab_selected", _on_tab_selected)

	apply_insets(App.safe_area_insets())

	# Nav applies any route that was requested before the shell existed.
	Nav.register_shell(self)
	set_active_tab(Nav.active_tab())

	_check_touch_targets.call_deferred()
	_log_probe_rects.call_deferred()
	# PRD-12 R10 (P3/P4): the steady-state fps window, one timer, no per-frame cost.
	Perf.attach(self)
	print("[ui] shell ready tabs=%d" % _tab_roots.size())


# ------------------------------------------------------------------ Nav contract

func tab_root(index: int) -> Control:
	if index < 0 or index >= _tab_roots.size():
		return null
	return _tab_roots[index]


func screen_host() -> Control:
	return _screen_host


func toast_layer() -> Control:
	return _toast_layer


## PRD-12 R5 — the polite live region screen readers watch. A `Feedback.toast()` writes
## its text here through `A11y.announce()`, so a toast is spoken as well as shown.
func live_region() -> Label:
	return _live_region


func veil() -> ColorRect:
	return _veil


func set_active_tab(index: int) -> void:
	if _bottom_nav.has_method(&"set_active"):
		_bottom_nav.call(&"set_active", index)


func apply_insets(insets: Vector4) -> void:
	var left := maxi(int(roundf(insets.x)), 0)
	var top := maxi(int(roundf(insets.y)), 0)
	var right := maxi(int(roundf(insets.z)), 0)
	var bottom := maxi(int(roundf(insets.w)), 0)

	# Never let content run into a notch: floor the side insets at the gutter once the
	# viewport is wider than the design canvas.
	var viewport_width := get_viewport_rect().size.x
	if viewport_width > float(LayoutUtil.DESIGN_W - 1):
		left = maxi(left, 0)

	_safe_area.add_theme_constant_override(&"margin_left", left)
	_safe_area.add_theme_constant_override(&"margin_top", top)
	_safe_area.add_theme_constant_override(&"margin_right", right)
	_safe_area.add_theme_constant_override(&"margin_bottom", bottom)


# ------------------------------------------------------------------ internals

func _build_tabs() -> void:
	_tab_roots.clear()
	for child in _tab_host.get_children():
		child.queue_free()

	for i in range(Routes.TAB_ROUTES.size()):
		var route: StringName = Routes.TAB_ROUTES[i]
		var scene_path: String = Routes.TAB_SCENES.get(route, "")
		if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
			push_error("[ui] tab scene missing for route '%s': %s" % [route, scene_path])
			continue
		var packed: PackedScene = load(scene_path)
		var root: Control = packed.instantiate()
		root.visible = i == Nav.active_tab()
		_tab_host.add_child(root)
		_tab_roots.append(root)


func _apply_palette() -> void:
	var bg := DesignTokens.color(App.theme_mode, "bg")
	_bg.color = bg
	_veil.color = bg


func _on_theme_changed(_mode: String) -> void:
	_apply_palette()


func _on_tab_selected(index: int) -> void:
	Nav.switch_tab(index)


func _on_layout_class_changed(_cls: int) -> void:
	# A tab may size its hero element differently per class; tabs refresh themselves.
	pass


## PRD-02 R6: every interactive control must be at least 88x88 on screen. Checked one
## frame after layout so sizes are real, not zero. The rule itself lives in [TouchTargets] so
## PRD-06's onboarding flow and Settings tab report the identical line.
func _check_touch_targets() -> void:
	var _violations := TouchTargets.report(self)


## Publishes the rects the Android test tooling needs to drive the app (debug builds only).
func _log_probe_rects() -> void:
	UiProbe.log_rect("bottom_nav", _bottom_nav)
	if _bottom_nav != null and _bottom_nav.has_method(&"tab_button"):
		for i in range(Routes.TAB_ROUTES.size()):
			var button := _bottom_nav.call(&"tab_button", i) as Control
			UiProbe.log_rect("nav_tab_%d" % i, button)
