extends SceneTree
## PRD-02 R1/R3/R4 — generates res://resources/themes/theme_dark.tres and theme_light.tres.
##
##   ~/Applications/godot --headless --path . --script res://scripts/dev/build_themes.gd
##   bash tools/build_themes.sh          # wrapper: generate, then git diff --exit-code
##
## The two .tres files are GENERATED ARTIFACTS. `scripts/core/design_tokens.gd` is the single
## source of truth for every colour, size, radius and margin; nothing else may write them, and
## `tests/suites/test_theme_drift.gd` fails the suite when they drift from the tokens.
##
## This is a plain SceneTree script (no @tool, no scene access) so it also runs on a machine
## with no display. It prints exactly three lines (R1 + PRD-12 R4):
##   [themes] wrote theme_dark.tres (N items)
##   [themes] wrote theme_light.tres (N items)
##   [tokens] wrote tokens.json (N bytes)
## N counts the items set through Theme's four item setters (set_color/set_stylebox/
## set_font_size/set_constant) — 126 for the R3 table. The root `default_font_size` and the
## `set_type_variation()` declarations are not items: they are what the remaining 30 property
## lines of `[resource]` are (156 = 126 + 29 declared variations + 1 default_font_size).
##
## DETERMINISM (AC3 — a second run must leave `git diff --exit-code resources/themes/` clean):
## Godot's text resource saver inlines every StyleBoxFlat as a sub-resource carrying a RANDOM
## 5-character id and emits sub-resources in hash-map order, so two runs of the very same
## build binarily differ (`primary` button probe: ids c38uw/… vs s0c7j/…). After
## `ResourceSaver.save()` this script therefore rewrites each file into a canonical form:
##   - sub-resources sorted by their serialized body, ids derived from that order
##     (`StyleBoxFlat_0` …); bodies that compare equal are interchangeable, so the sort is
##     deterministic even though Godot's Array.sort() is not stable;
##   - every `SubResource("…")` reference remapped to the canonical id;
##   - the `[resource]` properties sorted by name, with any random `uid="uid://…"` stripped
##     from the header so the bytes cannot depend on the resource UID cache.
## The result is byte-identical for identical tokens.

const Tokens := preload("res://scripts/core/design_tokens.gd")

const THEMES_DIR := "res://resources/themes"
## PRD-12 R4/AC3 — the machine-readable mirror written beside the themes, measured by
## `tools/check_contrast.py` and cross-checked against the loaded themes by the suite.
const TOKENS_JSON := "res://resources/themes/tokens.json"
## Sentinel for "this stylebox sets no content margins" (StyleBoxFlat's own default is -1).
const NO_MARGINS := Vector4(-1.0, -1.0, -1.0, -1.0)
const TRANSPARENT := Color(0, 0, 0, 0)

## Every non-built-in type this theme declares, mapped to the built-in class it varies.
## `set_type_variation()` is called for each one (R3); the dark and the light theme declare
## exactly the same set, so a live theme swap cannot change a single layout metric.
const VARIATIONS: Dictionary = {
	# Buttons (R4 geometry).
	"PrimaryButton": "Button",
	"SecondaryButton": "Button",
	"GhostButton": "Button",
	"DangerButton": "Button",
	"NavTab": "Button",
	"ChipToggle": "Button",
	# Typography (R3).
	"DisplayLabel": "Label",
	"H1": "Label",
	"H2": "Label",
	"H3": "Label",
	"BodyLabel": "Label",
	"BodySmall": "Label",
	"Caption": "Label",
	"MutedLabel": "Label",
	"NavTabLabel": "Label",
	"NavTabLabelActive": "Label",
	# Surfaces.
	"Card": "PanelContainer",
	"CardAlt": "PanelContainer",
	"Sheet": "PanelContainer",
	"StatTile": "PanelContainer",
	"BottomNav": "PanelContainer",
	"TopBar": "PanelContainer",
	"Toast": "PanelContainer",
	# Inputs.
	"Input": "LineEdit",
	"InputMulti": "TextEdit",
	"SettingToggle": "CheckButton",
	"Separator": "HSeparator",
	# Custom-drawn Controls (their colours are read from `_draw()` — R8/R9).
	"ProgressRing": "Control",
	"Glyph": "Control",
	"EmptyState": "Control",
	"LoadingOverlay": "Control",
}

var _items: int = 0


func _initialize() -> void:
	var dir_err := _ensure_dir()
	if dir_err != OK:
		push_error("[themes] cannot create %s (error %d)" % [THEMES_DIR, dir_err])
		quit(1)
		return

	for mode in Tokens.MODES:
		var mode_name: String = mode
		var theme := _build(mode_name)
		var path := "%s/theme_%s.tres" % [THEMES_DIR, mode_name]
		var save_err := _save_canonical(theme, path)
		if save_err != OK:
			push_error("[themes] failed to write %s (error %d)" % [path, save_err])
			quit(1)
			return
		print("[themes] wrote %s (%d items)" % [path.get_file(), _items])

	var json_err := _write_tokens_json()
	if json_err != OK:
		push_error("[tokens] failed to write %s (error %d)" % [TOKENS_JSON, json_err])
		quit(1)
		return
	quit(0)


#region tokens.json (PRD-12 R4/AC3)

## Writes [constant TOKENS_JSON], the machine-readable mirror of `DesignTokens`, from the same
## source the two themes are built from — so the palette in the JSON, the palette in the
## `.tres` files and the constants can never disagree without `tools/build_themes.sh` failing
## its `git diff --exit-code` gate.
##
## The JSON is the input `tools/check_contrast.py` measures (it must not import GDScript) and
## the artefact `tests/suites/test_design_tokens.gd` cross-checks against the loaded themes.
## `JSON.stringify(data, indent, sort_keys = true)` gives byte-identical output for identical
## tokens: keys are sorted at every level and the value formatting is fixed.
func _write_tokens_json() -> Error:
	var palettes: Dictionary = {}
	for mode in Tokens.MODES:
		var mode_name: String = mode
		var resolved: Dictionary = {}
		for token in Tokens.palette(mode_name):
			resolved[token] = Tokens.palette(mode_name)[token]
		palettes[mode_name] = resolved

	var pairs: Array = []
	for pair in Tokens.contrast_pairs():
		pairs.append([String(pair[0]), String(pair[1])])

	var data := {
		"palettes": palettes,
		"type": Tokens.TYPE.duplicate(),
		"space": Tokens.SPACE.duplicate(),
		"radius": Tokens.RADIUS.duplicate(),
		"motion": Tokens.MOTION.duplicate(),
		"contrast_pairs": pairs,
		"touch_min": Tokens.TOUCH_MIN,
		"gutter": Tokens.GUTTER,
		"nav_bar_height": Tokens.NAV_BAR_HEIGHT,
		"top_bar_height": Tokens.TOP_BAR_HEIGHT,
		"safe_fallback": [
			Tokens.SAFE_FALLBACK.x, Tokens.SAFE_FALLBACK.y,
			Tokens.SAFE_FALLBACK.z, Tokens.SAFE_FALLBACK.w,
		],
	}

	var file := FileAccess.open(TOKENS_JSON, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "  ", true) + "\n")
	file.close()
	print("[tokens] wrote %s (%d bytes)" % [TOKENS_JSON.get_file(), FileAccess.get_file_as_string(TOKENS_JSON).length()])
	return OK


#endregion


#region Theme construction


## Builds the complete theme for [param mode] ("dark" or "light").
func _build(mode: String) -> Theme:
	_items = 0
	var theme := Theme.new()

	# R3 root row. TYPE["body"] is the design body size (22) and doubles as the root default.
	theme.default_font_size = _ts("body")

	# R3 — declare every variation whose name is not itself a built-in class name. Godot 4.7
	# refuses to alias a ClassDB class ("A type associated with a built-in class cannot be
	# marked as a variation of another type"), and two names the spec asks for are exactly
	# that: `Input` is the engine input singleton and `Separator` is the Control base of
	# HSeparator. Those two keep every item registered under the requested type name — which
	# is all a `theme_type_variation = &"Input"` lookup needs, because Theme resolves the type
	# name directly — but they have no declared base, so `get_type_variation_base()` returns
	# "" for them and `get_type_variation_list()` cannot list them.
	for variation in _sorted_keys(VARIATIONS):
		var variation_name: String = variation
		if ClassDB.class_exists(variation_name):
			continue
		var base: String = VARIATIONS[variation]
		theme.set_type_variation(StringName(variation_name), StringName(base))

	_apply_typography(theme, mode)
	_apply_buttons(theme, mode)
	_apply_containers(theme, mode)
	_apply_inputs(theme, mode)
	_apply_widgets(theme, mode)
	return theme


## R3 — DisplayLabel/H1/H2/H3/BodyLabel/BodySmall (text) and Caption/MutedLabel (muted).
func _apply_typography(t: Theme, mode: String) -> void:
	var text := Tokens.color(mode, "text")
	var muted := Tokens.color(mode, "text_muted")

	_item(t, &"DisplayLabel", _ts("display"), text)
	_item(t, &"H1", _ts("h1"), text)
	_item(t, &"H2", _ts("h2"), text)
	_item(t, &"H3", _ts("h3"), text)
	_item(t, &"BodyLabel", _ts("body"), text)
	_item(t, &"BodySmall", _ts("body_small"), text)
	_item(t, &"Caption", _ts("caption"), muted)
	_item(t, &"MutedLabel", _ts("body_small"), muted)

	# The two bottom-nav captions (R10): muted inactive, primary active.
	_item(t, &"NavTabLabel", _ts("caption"), muted)
	_item(t, &"NavTabLabelActive", _ts("caption"), Tokens.accent_text(mode, "primary"))


## Minimal helper for a Label-like type: font_size + font_color.
func _item(t: Theme, variation: StringName, font_size: int, font_color: Color) -> void:
	_f(t, variation, &"font_size", font_size)
	_c(t, variation, &"font_color", font_color)


## R3/R4 — the four button variations plus NavTab and ChipToggle.
func _apply_buttons(t: Theme, mode: String) -> void:
	var surface_alt := Tokens.color(mode, "surface_alt")
	var outline := Tokens.color(mode, "outline")
	var primary := Tokens.color(mode, "primary")
	# The primary action fill (comp's white pill in dark mode, ink pill in light mode).
	var button := Tokens.color(mode, "button")
	var button_text := Tokens.color(mode, "button_text")
	var secondary := Tokens.color(mode, "secondary")
	var danger := Tokens.color(mode, "danger")
	# ...but text drawn ON an accent must use the light-mode text token, which is
	# what accent_text() resolves (raw accent on white is only 3.03:1).
	var danger_text := Tokens.accent_text(mode, "danger")
	var text := Tokens.color(mode, "text")
	var text_muted := Tokens.color(mode, "text_muted")
	var text_disabled := Tokens.color(mode, "text_disabled")

	var r_button := _rad("button")
	var r_chip := _rad("chip")
	var pad_x := _sp("xxl")
	var pad_y := _sp("xl")
	var pad_button := Vector4(pad_x, pad_y, pad_x, pad_y)
	var pad_chip := Vector4(_sp("xl"), _sp("lg"), _sp("xl"), _sp("lg"))

	# --- PrimaryButton: the button token (white pill on dark, ink pill on light) ------------
	_s(t, &"PrimaryButton", &"normal",
		_sb(button, 0, TRANSPARENT, _radius(r_button), pad_button))
	_s(t, &"PrimaryButton", &"hover",
		_sb(button, 0, TRANSPARENT, _radius(r_button), pad_button))
	# R4 writes `primary_dim` here; PRD-00 appendix §4.3 rule 3 ("a primary button never swaps
	# its fill to primary_dim … press feedback is press_scale 0.97 + an 8 % black scrim") wins,
	# so the fill stays `button` and the press feedback stays a component concern (R7).
	_s(t, &"PrimaryButton", &"pressed",
		_sb(button, 0, TRANSPARENT, _radius(r_button), pad_button))
	_s(t, &"PrimaryButton", &"disabled",
		_sb(surface_alt, 0, TRANSPARENT, _radius(r_button), pad_button))
	_s(t, &"PrimaryButton", &"focus",
		_sb(TRANSPARENT, 4, secondary, _radius(r_button), pad_button, false))
	_c(t, &"PrimaryButton", &"font_color", button_text)
	_c(t, &"PrimaryButton", &"font_pressed_color", button_text)
	_c(t, &"PrimaryButton", &"font_disabled_color", text_disabled)
	_c(t, &"PrimaryButton", &"font_hover_color", button_text)
	_c(t, &"PrimaryButton", &"font_hover_pressed_color", button_text)
	_f(t, &"PrimaryButton", &"font_size", _ts("button"))
	_k(t, &"PrimaryButton", &"h_separation", _sp("md"))
	_k(t, &"PrimaryButton", &"outline_size", 0)

	# --- SecondaryButton: outline only, `text` label ----------------------------------------
	_s(t, &"SecondaryButton", &"normal",
		_sb(TRANSPARENT, 2, outline, _radius(r_button), pad_button))
	_s(t, &"SecondaryButton", &"hover",
		_sb(surface_alt, 2, outline, _radius(r_button), pad_button))
	_s(t, &"SecondaryButton", &"pressed",
		_sb(surface_alt, 2, primary, _radius(r_button), pad_button))
	_s(t, &"SecondaryButton", &"disabled",
		_sb(TRANSPARENT, 2, outline, _radius(r_button), pad_button))
	_s(t, &"SecondaryButton", &"focus",
		_sb(TRANSPARENT, 4, secondary, _radius(r_button), pad_button, false))
	_c(t, &"SecondaryButton", &"font_color", text)
	_c(t, &"SecondaryButton", &"font_pressed_color", text)
	_c(t, &"SecondaryButton", &"font_disabled_color", text_disabled)
	_c(t, &"SecondaryButton", &"font_hover_color", text)
	_c(t, &"SecondaryButton", &"font_hover_pressed_color", text)
	_f(t, &"SecondaryButton", &"font_size", _ts("button"))

	# --- GhostButton: no chrome; only hover gets a chip-radius surface_alt plate -------------
	_s(t, &"GhostButton", &"normal",
		_sb(TRANSPARENT, 0, TRANSPARENT, _radius(r_chip), pad_button, false))
	_s(t, &"GhostButton", &"hover",
		_sb(surface_alt, 0, TRANSPARENT, _radius(r_chip), pad_button))
	_s(t, &"GhostButton", &"pressed",
		_sb(TRANSPARENT, 0, TRANSPARENT, _radius(r_chip), pad_button, false))
	_s(t, &"GhostButton", &"disabled",
		_sb(TRANSPARENT, 0, TRANSPARENT, _radius(r_chip), pad_button, false))
	_s(t, &"GhostButton", &"focus",
		_sb(TRANSPARENT, 4, secondary, _radius(r_chip), pad_button, false))
	_c(t, &"GhostButton", &"font_color", text_muted)
	_c(t, &"GhostButton", &"font_hover_color", text_muted)
	_f(t, &"GhostButton", &"font_size", _ts("body"))

	# --- DangerButton: SecondaryButton geometry, `danger` label and normal border -----------
	_s(t, &"DangerButton", &"normal",
		_sb(TRANSPARENT, 2, danger, _radius(r_button), pad_button))
	_s(t, &"DangerButton", &"hover",
		_sb(surface_alt, 2, outline, _radius(r_button), pad_button))
	_s(t, &"DangerButton", &"pressed",
		_sb(surface_alt, 2, primary, _radius(r_button), pad_button))
	_s(t, &"DangerButton", &"disabled",
		_sb(TRANSPARENT, 2, outline, _radius(r_button), pad_button))
	_s(t, &"DangerButton", &"focus",
		_sb(TRANSPARENT, 4, secondary, _radius(r_button), pad_button, false))
	_c(t, &"DangerButton", &"font_color", danger_text)
	_c(t, &"DangerButton", &"font_pressed_color", danger_text)
	_c(t, &"DangerButton", &"font_disabled_color", text_disabled)
	_c(t, &"DangerButton", &"font_hover_color", danger_text)
	_c(t, &"DangerButton", &"font_hover_pressed_color", danger_text)
	_f(t, &"DangerButton", &"font_size", _ts("button"))

	# --- NavTab: chromeless touch target; its Caption Label carries the state colour ---------
	var pad_tab := Vector4(_sp("sm"), _sp("xs"), _sp("sm"), _sp("xs"))
	for state in [&"normal", &"hover", &"pressed", &"hover_pressed", &"focus", &"disabled"]:
		_s(t, &"NavTab", state,
			_sb(TRANSPARENT, 0, TRANSPARENT, _radius(r_chip), pad_tab, false))
	_f(t, &"NavTab", &"font_size", _ts("caption"))
	_k(t, &"NavTab", &"h_separation", _sp("xs"))

	# --- ChipToggle: selectable chip, accent fill while pressed ------------------------------
	_s(t, &"ChipToggle", &"normal",
		_sb(surface_alt, 2, outline, _radius(r_chip), pad_chip))
	_s(t, &"ChipToggle", &"hover",
		_sb(surface_alt, 2, secondary, _radius(r_chip), pad_chip))
	# Selected = the button token (comp's white `kg` pill): a neutral pill, not an accent fill.
	_s(t, &"ChipToggle", &"pressed",
		_sb(button, 2, button, _radius(r_chip), pad_chip))
	_s(t, &"ChipToggle", &"hover_pressed",
		_sb(button, 2, button, _radius(r_chip), pad_chip))
	_s(t, &"ChipToggle", &"disabled",
		_sb(surface_alt, 2, outline, _radius(r_chip), pad_chip))
	_s(t, &"ChipToggle", &"focus",
		_sb(TRANSPARENT, 4, secondary, _radius(r_chip), pad_chip, false))
	_c(t, &"ChipToggle", &"font_color", text_muted)
	_c(t, &"ChipToggle", &"font_pressed_color", button_text)
	_c(t, &"ChipToggle", &"font_hover_color", text_muted)
	_c(t, &"ChipToggle", &"font_hover_pressed_color", button_text)
	_c(t, &"ChipToggle", &"font_disabled_color", text_disabled)
	_f(t, &"ChipToggle", &"font_size", _ts("body_small"))


## R3 — Card / CardAlt / Sheet / StatTile and the three bars.
func _apply_containers(t: Theme, mode: String) -> void:
	var bg := Tokens.color(mode, "bg")
	var surface := Tokens.color(mode, "surface")
	var surface_alt := Tokens.color(mode, "surface_alt")
	var outline := Tokens.color(mode, "outline")

	var r_card := _rad("card")
	var r_sheet := _rad("sheet")
	var r_chip := _rad("chip")
	var pad_card := Vector4(_sp("xl"), _sp("xl"), _sp("xl"), _sp("xl"))
	var pad_tile := Vector4(_sp("lg"), _sp("md") + _sp("sm"), _sp("lg"), _sp("md") + _sp("sm"))
	var pad_toast := Vector4(_sp("lg"), _sp("md"), _sp("lg"), _sp("md"))

	_s(t, &"Card", &"panel",
		_sb(surface, 0, TRANSPARENT, _radius(r_card), pad_card))
	_s(t, &"CardAlt", &"panel",
		_sb(surface_alt, 0, TRANSPARENT, _radius(r_card), pad_card))
	# A bottom sheet is only rounded at the top (R3/R4).
	_s(t, &"Sheet", &"panel",
		_sb(surface, 0, TRANSPARENT, Vector4i(r_sheet, r_sheet, 0, 0),
			Vector4(_sp("xxl"), _sp("xxl"), _sp("xxl"), _sp("xxl"))))
	_s(t, &"StatTile", &"panel",
		_sb(surface_alt, 0, TRANSPARENT, _radius(r_card), pad_tile))

	# Bars: square, one hairline on the edge that faces the content. Their height is pinned by
	# the component (`NAV_BAR_HEIGHT` / `TOP_BAR_HEIGHT`), so they carry no content margins.
	_s(t, &"BottomNav", &"panel", _sb_edge(surface, outline, SIDE_TOP))
	_s(t, &"TopBar", &"panel", _sb_edge(bg, outline, SIDE_BOTTOM))
	_s(t, &"Toast", &"panel",
		_sb(surface_alt, 1, outline, _radius(r_chip), pad_toast))


## A square stylebox with a single 1 px edge hairline (bars).
func _sb_edge(bg: Color, line: Color, side: int) -> StyleBoxFlat:
	var sb := _sb(bg, 0, TRANSPARENT, Vector4i(0, 0, 0, 0))
	sb.border_width_top = 1 if side == SIDE_TOP else 0
	sb.border_width_bottom = 1 if side == SIDE_BOTTOM else 0
	sb.border_color = line
	return sb


## R3 — Input (LineEdit) and InputMulti (TextEdit).
func _apply_inputs(t: Theme, mode: String) -> void:
	var surface_alt := Tokens.color(mode, "surface_alt")
	var outline := Tokens.color(mode, "outline")
	var outline_strong := Tokens.color(mode, "outline_strong")
	var primary := Tokens.color(mode, "primary")
	var text := Tokens.color(mode, "text")
	var text_disabled := Tokens.color(mode, "text_disabled")

	var r_chip := _rad("chip")
	var pad_field := Vector4(_sp("lg"), _sp("md") + 2, _sp("lg"), _sp("md") + 2)
	var pad_multi := Vector4(_sp("lg"), _sp("lg"), _sp("lg"), _sp("lg"))

	# Appendix §4.3 rule 4: `outline_strong` — never `outline` — borders an input; R3 gives the
	# focus border its `primary` colour.
	_s(t, &"Input", &"normal",
		_sb(surface_alt, 2, outline_strong, _radius(r_chip), pad_field))
	_s(t, &"Input", &"focus",
		_sb(surface_alt, 2, primary, _radius(r_chip), pad_field))
	_s(t, &"Input", &"read_only",
		_sb(surface_alt, 2, outline_strong, _radius(r_chip), pad_field))
	_c(t, &"Input", &"font_color", text)
	_c(t, &"Input", &"font_placeholder_color", text_disabled)
	_c(t, &"Input", &"caret_color", primary)
	_c(t, &"Input", &"selection_color", outline)
	_c(t, &"Input", &"font_selected_color", text)
	_c(t, &"Input", &"font_uneditable_color", text_disabled)
	_f(t, &"Input", &"font_size", _ts("body"))

	_s(t, &"InputMulti", &"normal",
		_sb(surface_alt, 2, outline_strong, _radius(r_chip), pad_multi))
	_s(t, &"InputMulti", &"focus",
		_sb(surface_alt, 2, primary, _radius(r_chip), pad_multi))
	_s(t, &"InputMulti", &"read_only",
		_sb(surface_alt, 2, outline_strong, _radius(r_chip), pad_multi))
	_c(t, &"InputMulti", &"font_color", text)
	_c(t, &"InputMulti", &"font_placeholder_color", text_disabled)
	_c(t, &"InputMulti", &"caret_color", primary)
	_c(t, &"InputMulti", &"selection_color", outline)
	_c(t, &"InputMulti", &"font_selected_color", text)
	_c(t, &"InputMulti", &"font_readonly_color", text_disabled)
	_f(t, &"InputMulti", &"font_size", _ts("body"))


## R3 — SettingToggle, Separator and the four custom-drawn Controls.
func _apply_widgets(t: Theme, mode: String) -> void:
	var bg := Tokens.color(mode, "bg")
	var surface_alt := Tokens.color(mode, "surface_alt")
	var outline := Tokens.color(mode, "outline")
	var primary := Tokens.color(mode, "primary")
	var text := Tokens.color(mode, "text")
	var text_muted := Tokens.color(mode, "text_muted")
	var text_disabled := Tokens.color(mode, "text_disabled")

	# CheckButton's own styleboxes are StyleBoxEmpty in Godot's default theme, so only the
	# icon/label colours are needed here.
	_c(t, &"SettingToggle", &"icon_normal_color", text_muted)
	_c(t, &"SettingToggle", &"icon_pressed_color", primary)
	_c(t, &"SettingToggle", &"font_color", text)
	_f(t, &"SettingToggle", &"font_size", _ts("body"))

	# HSeparator: a 1 px `outline` hairline (the default StyleBoxLine would ignore the tokens).
	var sep := _sb(outline, 0, TRANSPARENT, Vector4i(0, 0, 0, 0))
	sep.content_margin_top = 1
	_s(t, &"Separator", &"separator", sep)
	_k(t, &"Separator", &"separation", 1)

	_c(t, &"ProgressRing", &"track_color", surface_alt)
	_c(t, &"ProgressRing", &"fill_color", primary)
	_c(t, &"ProgressRing", &"caption_color", text_muted)

	_c(t, &"Glyph", &"color", text_muted)
	_c(t, &"Glyph", &"color_active", primary)
	_c(t, &"Glyph", &"color_disabled", text_disabled)

	_c(t, &"EmptyState", &"title_color", text)
	_c(t, &"EmptyState", &"body_color", text_muted)
	_c(t, &"EmptyState", &"icon_color", outline)

	# R3: the scrim is `bg` at 72 % — a derived colour, not a token of its own.
	_c(t, &"LoadingOverlay", &"dim_color",
		Color(bg.r, bg.g, bg.b, 0.72))


#endregion


#region Stylebox + item helpers


## Builds one StyleBoxFlat. R3: every stylebox has `anti_aliasing = true` and
## `corner_detail = 8`, but the saved file stays minimal — defaults are not written out, so a
## zero border width never carries a border colour.
func _sb(bg: Color, border_px: int, border_color: Color, radii: Vector4i,
		margins: Vector4 = NO_MARGINS, draw_center: bool = true) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.anti_aliasing = true
	sb.corner_detail = 8
	sb.bg_color = bg
	sb.draw_center = draw_center
	sb.corner_radius_top_left = radii.x
	sb.corner_radius_top_right = radii.y
	sb.corner_radius_bottom_right = radii.z
	sb.corner_radius_bottom_left = radii.w
	if border_px > 0:
		sb.set_border_width_all(border_px)
		sb.border_color = border_color
	if margins != NO_MARGINS:
		sb.content_margin_left = margins.x
		sb.content_margin_top = margins.y
		sb.content_margin_right = margins.z
		sb.content_margin_bottom = margins.w
	return sb


func _radius(all: int) -> Vector4i:
	return Vector4i(all, all, all, all)


func _c(t: Theme, variation: StringName, item: StringName, value: Color) -> void:
	t.set_color(item, variation, value)
	_items += 1


func _s(t: Theme, variation: StringName, item: StringName, value: StyleBox) -> void:
	t.set_stylebox(item, variation, value)
	_items += 1


func _f(t: Theme, variation: StringName, item: StringName, value: int) -> void:
	t.set_font_size(item, variation, value)
	_items += 1


func _k(t: Theme, variation: StringName, item: StringName, value: int) -> void:
	t.set_constant(item, variation, value)
	_items += 1


## Token shortcuts — every pixel number in this file comes from DesignTokens.
func _ts(key: String) -> int:
	return int(Tokens.TYPE[key])


func _sp(key: String) -> int:
	return int(Tokens.SPACE[key])


func _rad(key: String) -> int:
	return int(Tokens.RADIUS[key])


func _sorted_keys(source: Dictionary) -> Array:
	var keys := source.keys()
	keys.sort()
	return keys


#endregion


#region Saving + canonical output


func _ensure_dir() -> Error:
	if DirAccess.dir_exists_absolute(THEMES_DIR):
		return OK
	var err := DirAccess.make_dir_recursive_absolute(THEMES_DIR)
	return OK if err == ERR_ALREADY_EXISTS else err


## Saves [param theme] to [param path] and rewrites the file into its canonical byte form so
## that regenerating an unchanged theme is a no-op in git (AC3).
func _save_canonical(theme: Theme, path: String) -> Error:
	var err := ResourceSaver.save(theme, path)
	if err != OK:
		return err
	var raw := FileAccess.get_file_as_string(path)
	if raw.is_empty():
		return ERR_CANT_OPEN
	var canonical := _canonicalize(raw)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(canonical)
	file.close()
	return OK


## Rewrites a Godot text resource into a deterministic form (see the file header).
func _canonicalize(raw: String) -> String:
	var header := PackedStringArray()
	var properties := PackedStringArray()
	var blocks: Array[Dictionary] = []
	var current: Dictionary = {}
	var in_resource := false

	for raw_line in raw.split("\n"):
		var line: String = raw_line
		if line.begins_with("[gd_resource"):
			# A resource UID is random per machine/checkout — never let it into the bytes.
			header.append(_strip_uid(line))
			current = {}
			continue
		if line.begins_with("[sub_resource "):
			current = {
				"type": _attribute(line, "type"),
				"id": _attribute(line, "id"),
				"body": PackedStringArray(),
			}
			blocks.append(current)
			in_resource = false
			continue
		if line.begins_with("[resource"):
			in_resource = true
			current = {}
			continue
		if line.strip_edges().is_empty():
			continue
		if in_resource:
			properties.append(line)
		elif not current.is_empty():
			var body: PackedStringArray = current["body"]
			body.append(line)

	# Sort the sub-resources by content. Array.sort_custom() is not stable, but two blocks with
	# equal bodies are byte-identical, so whichever lands first the file comes out the same.
	var order: Array[int] = []
	for i in blocks.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return _block_key(blocks[a]) < _block_key(blocks[b]))

	var rename: Dictionary = {}
	var out := PackedStringArray()
	for line in header:
		out.append(line)
	for position in order.size():
		var block: Dictionary = blocks[order[position]]
		var new_id := "%s_%d" % [block["type"], position]
		rename[block["id"]] = new_id
		out.append("")
		out.append("[sub_resource type=\"%s\" id=\"%s\"]" % [block["type"], new_id])
		var body: PackedStringArray = block["body"]
		for line in body:
			out.append(line)

	# Remap every reference, then sort the theme's own properties by name. The keys are
	# disjoint, so the order in which the replacements run cannot matter.
	var rewritten := PackedStringArray()
	for raw_property in properties:
		var property: String = raw_property
		for old_id in rename:
			property = property.replace("SubResource(\"%s\")" % old_id,
				"SubResource(\"%s\")" % rename[old_id])
		rewritten.append(property)
	rewritten.sort()

	out.append("")
	out.append("[resource]")
	for line in rewritten:
		out.append(line)
	return "\n".join(out) + "\n"


func _block_key(block: Dictionary) -> String:
	var body: PackedStringArray = block["body"]
	return "%s\n%s" % [block["type"], "\n".join(body)]


func _attribute(line: String, key: String) -> String:
	var needle := "%s=\"" % key
	var start := line.find(needle)
	if start < 0:
		return ""
	start += needle.length()
	var end := line.find("\"", start)
	if end < 0:
		return ""
	return line.substr(start, end - start)


func _strip_uid(header_line: String) -> String:
	var start := header_line.find(" uid=\"")
	if start < 0:
		return header_line
	var end := header_line.find("\"", start + 6)
	if end < 0:
		return header_line
	return header_line.substr(0, start) + header_line.substr(end + 1)


#endregion
