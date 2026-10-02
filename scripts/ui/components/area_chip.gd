extends Button
## Area chip — PRD-08 R4 (appendix §3.2: `area_chip.tscn` is PRD-08's).
##
## A 2-column grid of these is the wizard's step 2. Four things are deliberate:
##
## * **The look comes from the theme's `ChipToggle` variation**, not from bespoke drawing:
##   the chip inherits the theme's radii, padding, type size, press feedback and focus ring.
## * **The selected chip is `primary`-outlined** (owner palette pick, 2026-10-02 — the
##   reference's selection language, shared with the wizard's goal cards): selected = `surface_alt`
##   fill with a 2 px `primary` border and a check glyph; unselected = `surface_alt` fill with a
##   2 px `outline` border. Only those two states are overridden, and
##   they are built from `DesignTokens` tokens — never a literal colour, and never through the
##   colour-override theme API the appendix §4.3 rule 8 forbids. This is the same
##   `add_theme_stylebox_override` pattern PRD-06's onboarding progress dots already ship.
## * **The label keeps its colour through its *variation*, not a colour override**: selected is
##   `BodyLabel` (`text`), unselected is `MutedLabel` (`text_muted`). Switching a variation is the
##   only sanctioned way to change how something looks in this codebase.
## * **State is never colour-only** (appendix §4.3 rule 6): the selected chip draws a `check`
##   glyph. The glyph slot is always present — unselected sets `kind` to the documented empty
##   slot `&""` — so selecting a chip cannot shift the centred label sideways.
## * **The glyph is drawn, not typed.** R4 writes a `✓` character and R16 warns that Godot's
##   built-in font is not guaranteed to cover U+2713; the drawn `check` glyph is R16's own
##   prescribed substitution and cannot render as tofu.
##
## `signal toggled(selected: bool)` is PRD-08's frozen API and is inherited from `Button`
## unchanged — selection *is* `button_pressed`, so there is no second source of truth.

const GLYPH_KIND_CHECK := &"check"
const GLYPH_KIND_EMPTY := &""

var _area: String = ""
## The theme mode the overrides below were built for. `add_theme_stylebox_override()` notifies
## the node itself with `NOTIFICATION_THEME_CHANGED`, so re-applying from that notification
## without a guard is infinite recursion — and a guard that only covers *this* call is not
## enough if the notification is ever deferred. Recording the key first makes the second entry a
## no-op no matter when it arrives.
var _styled_mode: String = ""


func _ready() -> void:
	# `toggle_mode` is set in the scene as well; repeating it here keeps an `AreaChip.new()`
	# usable from code (the wizard's compile/test paths build one that way).
	toggle_mode = true
	_apply_theme()
	_refresh()
	if not toggled.is_connected(_on_toggled):
		toggled.connect(_on_toggled)
	# Measured in 4.7.2: replacing the root `Window.theme` does **not** deliver
	# `NOTIFICATION_THEME_CHANGED` to descendants (a probe counted six notifications from this
	# node's own stylebox overrides and none from the theme swap). `App.set_theme_mode()` swaps
	# that theme and then emits `theme_changed`, which is the signal every other screen
	# re-renders from (`Shell._apply_palette`, `OnboardingFlow`), so that is the trigger used
	# here. The notification handler stays: the override calls themselves do notify.
	if not App.theme_changed.is_connected(_on_app_theme_changed):
		App.theme_changed.connect(_on_app_theme_changed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
		_refresh()


# ------------------------------------------------------------------ R4 API

## Sets the area and its selected state. Emits nothing: a screen restoring a stored answer is
## not the user tapping the chip, and an echoed signal is how feedback loops start.
func set_area(area: String, selected: bool) -> void:
	_area = area
	var label := label_node()
	if label != null:
		label.text = Taxonomy.label(area)
	set_pressed_no_signal(selected)
	_refresh()


## The area key this chip stands for (`""` before [method set_area]). Not named `area()`:
## R4's `set_area(area: String, selected: bool)` parameter name is part of the frozen
## signature, and a same-named accessor would be reported as shadowing it.
func area_key() -> String:
	return _area


func is_selected() -> bool:
	return button_pressed


func label_node() -> Label:
	return get_node_or_null(^"Row/AreaLabel") as Label


func check_node() -> Control:
	return get_node_or_null(^"Row/CheckGlyph") as Control


# ------------------------------------------------------------------ internals

func _on_toggled(_pressed: bool) -> void:
	_refresh()


## A dark↔light switch: drop the memoised mode and rebuild from the tokens.
func _on_app_theme_changed(_mode: String) -> void:
	_styled_mode = ""
	_apply_theme()
	_refresh()


## Selected/unselected rendering. Called from every setter, from `_ready()` and on every theme
## change, so the chip is correct before its first frame and after a dark↔light switch.
func _refresh() -> void:
	var label := label_node()
	if label != null:
		label.theme_type_variation = &"BodyLabel" if button_pressed else &"MutedLabel"
	var glyph := check_node()
	if glyph != null:
		glyph.set(&"kind", GLYPH_KIND_CHECK if button_pressed else GLYPH_KIND_EMPTY)


## R4's two states. Rebuilt rather than mutated because a `StyleBoxFlat` is a shared resource
## once it has been handed to a theme item.
func _apply_theme() -> void:
	var mode := App.theme_mode
	if mode == _styled_mode:
		return
	_styled_mode = mode
	add_theme_stylebox_override(&"normal", _chip_style(mode, "outline"))
	add_theme_stylebox_override(&"pressed", _chip_style(mode, "primary"))
	add_theme_stylebox_override(&"hover", _chip_style(mode, "outline_strong"))
	add_theme_stylebox_override(&"hover_pressed", _chip_style(mode, "primary"))
	add_theme_stylebox_override(&"disabled", _chip_style(mode, "outline"))
	add_theme_stylebox_override(&"focus", _chip_style(mode, "outline_strong"))


## R4: `surface_alt` fill, 2 px border in [param border_token], chip radius. The padding the
## theme's chip uses is preserved so a chip built here and a theme-styled chip line up.
func _chip_style(mode: String, border_token: String) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = DesignTokens.color(mode, "surface_alt")
	box.border_color = DesignTokens.color(mode, border_token)
	box.set_border_width_all(2)
	box.set_corner_radius_all(int(DesignTokens.RADIUS["chip"]))
	box.content_margin_left = 24.0
	box.content_margin_right = 24.0
	box.content_margin_top = 16.0
	box.content_margin_bottom = 16.0
	return box
