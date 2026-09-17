extends PanelContainer
## One day pill in PRD-09's week strip — R6.
##
## The pill shows nothing but its weekday letter; the state is carried by fill, border and
## letter colour, plus a drawn marker — a check for `done`, a dot for `missed` — so no state is
## conveyed by colour alone (R16/appendix §4.3 rule 6).
##
## **Why the stylebox is built from tokens.** R6's five kinds need five different fills and
## borders (`success` at 22 %, `surface_alt`, `surface`, `primary`/`outline`/`warning` borders).
## The theme's variation set is frozen and owned by PRD-02 (`resources/themes/` and
## `scripts/dev/build_themes.gd`), so there is no variation per kind; the pill builds its
## `StyleBoxFlat` from [DesignTokens] exactly the way PRD-06's onboarding dots and PRD-08's
## `source_badge` already do. No colour is hard-coded here.

const KIND_DONE := "done"
const KIND_TODAY := "today"
const KIND_UPCOMING := "upcoming"
const KIND_REST := "rest"
const KIND_MISSED := "missed"

## R6: chip radius, 22 % fill for a completed day, and the 88 px touch floor for the pill the
## strip's tap target sits in.
const RADIUS := 12
const DONE_ALPHA := 0.22
const MIN_HEIGHT := 88.0

## R15's "week pill that just became done" pop.
const PULSE_SCALE := 1.12
const PULSE_MS := 260

var _day: Dictionary = {}

## Setting a stylebox override inside `NOTIFICATION_THEME_CHANGED` propagates another theme
## change into this node, so the repaint has to be re-entrancy safe.
var _applying: bool = false


func _ready() -> void:
	custom_minimum_size.y = maxf(custom_minimum_size.y, MIN_HEIGHT)
	_apply()
	# Measured in 4.7.2: replacing the root `Window.theme` does **not** deliver
	# `NOTIFICATION_THEME_CHANGED` to descendants (a probe counted zero on a plain and on an
	# override-carrying panel). `App.set_theme_mode()` swaps the theme and then emits
	# `theme_changed`, which is what every screen and every PRD-08 component re-renders from, so
	# the pill listens to that as well. Without it a pill can keep its dark `surface_alt` fill
	# under the light theme — its colours are tokens, not variations.
	if not App.theme_changed.is_connected(_on_app_theme_changed):
		App.theme_changed.connect(_on_app_theme_changed)


func _notification(what: int) -> void:
	# The notification still matters: this pill's own `add_theme_*_override()` calls notify its
	# subtree, and a scene built before the theme was applied arrives through this path. The
	# guard exists because that propagation re-enters.
	if what == NOTIFICATION_THEME_CHANGED and not _applying:
		_repaint()


## Dark↔light switch (and any other theme change the app announces).
func _on_app_theme_changed(_mode: String) -> void:
	_repaint()


func _repaint() -> void:
	_applying = true
	_apply()
	_applying = false


# ------------------------------------------------------------------ API

## Fills the pill from one `HomeState` strip entry `{weekday_iso, letter, date, kind}`.
func set_day(day: Dictionary) -> void:
	_day = day
	_apply()


## The pill's kind (`done|today|upcoming|rest|missed`) — what the dev probe and the screenshot
## diffs read.
func kind() -> String:
	return String(_day.get("kind", ""))


func date() -> String:
	return String(_day.get("date", ""))


func letter() -> String:
	return String(_day.get("letter", ""))


func marker_visible() -> String:
	var check := get_node_or_null(^"Stack/Marker/CheckGlyph") as Control
	var dot := get_node_or_null(^"Stack/Marker/DotGlyph") as Control
	if check != null and check.visible:
		return "check"
	if dot != null and dot.visible:
		return "dot"
	return ""


## R15: a quick 1.0 → 1.12 → 1.0 pop, played when this pill just became `done`.
func pulse() -> void:
	if not is_inside_tree():
		return
	if bool(App.get_setting("ui.reduce_motion", false)):
		return
	pivot_offset = size * 0.5
	var half := float(PULSE_MS) / 2000.0
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2(PULSE_SCALE, PULSE_SCALE), half)
	tween.tween_property(self, "scale", Vector2.ONE, half)


# ------------------------------------------------------------------ rendering

func _apply() -> void:
	var mode := App.theme_mode
	var state := String(_day.get("kind", KIND_REST))

	var letter_node := get_node_or_null(^"Stack/PillLetter") as Label
	if letter_node != null:
		letter_node.text = String(_day.get("letter", ""))
		letter_node.add_theme_color_override(&"font_color", _letter_color(mode, state))

	var check := get_node_or_null(^"Stack/Marker/CheckGlyph") as Control
	if check != null:
		check.visible = state == KIND_DONE
		check.add_theme_color_override(&"color", DesignTokens.accent_text(mode, "success"))

	var dot := get_node_or_null(^"Stack/Marker/DotGlyph") as Control
	if dot != null:
		dot.visible = state == KIND_MISSED
		dot.add_theme_color_override(&"color", DesignTokens.accent_text(mode, "warning"))

	add_theme_stylebox_override(&"panel", _style_for(mode, state))


## R6's letter column. Accents resolve through [method DesignTokens.accent_text] so light mode
## gets the readable `*_text_light` colour instead of a raw accent (appendix §4.3 rule 2).
func _letter_color(mode: String, state: String) -> Color:
	match state:
		KIND_DONE:
			return DesignTokens.accent_text(mode, "success")
		KIND_TODAY:
			return DesignTokens.color(mode, "text")
		KIND_MISSED:
			return DesignTokens.accent_text(mode, "warning")
		KIND_REST:
			return DesignTokens.color(mode, "text_disabled")
	return DesignTokens.color(mode, "text_muted")


## R6's fill / border column.
func _style_for(mode: String, state: String) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.anti_aliasing = true
	box.corner_detail = 8
	box.set_corner_radius_all(RADIUS)
	box.set_content_margin_all(4.0)

	var surface := DesignTokens.color(mode, "surface")
	var surface_alt := DesignTokens.color(mode, "surface_alt")
	match state:
		KIND_DONE:
			var success := DesignTokens.color(mode, "success")
			box.bg_color = Color(success.r, success.g, success.b, DONE_ALPHA)
		KIND_TODAY:
			box.bg_color = surface_alt
			box.set_border_width_all(2)
			box.border_color = DesignTokens.color(mode, "primary")
		KIND_MISSED:
			box.bg_color = surface_alt
			box.set_border_width_all(1)
			box.border_color = DesignTokens.color(mode, "warning")
		KIND_UPCOMING:
			box.bg_color = surface_alt
			box.set_border_width_all(1)
			box.border_color = DesignTokens.color(mode, "outline")
		_:
			box.bg_color = surface
	return box
