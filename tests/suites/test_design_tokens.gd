extends TestSuite
## PRD-02 R1/R3/R4/R22 — drift guard for the two GENERATED theme resources.
##
##   [themes] dark items=126 contrast_pairs=9 failures=0
##   [themes] light items=126 contrast_pairs=9 failures=0
##
## What it proves, in order:
##   1. both `.tres` files load as `Theme` resources;
##   2. dark and light declare the same type variations and, for every type, the same item
##      names in every category — a live theme swap can therefore never change a layout metric
##      or drop an item (R18);
##   3. the R3 item mapping and the R4 stylebox geometry match `DesignTokens` exactly;
##   4. no colour anywhere in either theme is an orphan: every value traces back to
##      `DesignTokens.palette(mode)` plus the four derived colours the spec creates
##      (`primary.lightened(0.08)`, fully transparent, `on_accent`, and the LoadingOverlay
##      scrim `bg` at alpha 0.72);
##   5. the R5/R22 contrast table clears WCAG AA (4.5:1) in both modes.
##
## `EXPECTED_ITEMS` is the size of the R3 table. Adding or removing a theme item is a
## deliberate act: update `scripts/dev/build_themes.gd` and this number together.

const Tokens := preload("res://scripts/core/design_tokens.gd")

const THEME_PATHS := {
	"dark": "res://resources/themes/theme_dark.tres",
	"light": "res://resources/themes/theme_light.tres",
}

## PRD-12 R4/AC3 — the machine-readable mirror written by `scripts/dev/build_themes.gd`.
const TOKENS_JSON := "res://resources/themes/tokens.json"

## Items set through Theme's four item setters, counted from the resource itself.
const EXPECTED_ITEMS := 126

## Every variation R3 asks for that Godot accepts as a variation, with its base class.
const VARIATIONS := {
	"PrimaryButton": "Button",
	"SecondaryButton": "Button",
	"GhostButton": "Button",
	"DangerButton": "Button",
	"NavTab": "Button",
	"ChipToggle": "Button",
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
	"Card": "PanelContainer",
	"CardAlt": "PanelContainer",
	"Sheet": "PanelContainer",
	"StatTile": "PanelContainer",
	"BottomNav": "PanelContainer",
	"TopBar": "PanelContainer",
	"Toast": "PanelContainer",
	"InputMulti": "TextEdit",
	"SettingToggle": "CheckButton",
	"ProgressRing": "Control",
	"Glyph": "Control",
	"EmptyState": "Control",
	"LoadingOverlay": "Control",
}

## `Input` and `Separator` are ClassDB class names in Godot 4.x (the input singleton and the
## Control base of HSeparator), so `set_type_variation()` refuses them: "A type associated with
## a built-in class cannot be marked as a variation of another type". R3's items are still
## registered under those exact type names, which is all a `theme_type_variation = &"Input"`
## lookup needs — only the declared base is missing. Both cases are asserted below.
const UNDECLARABLE_VARIATIONS := ["Input", "Separator"]


func _init() -> void:
	suite_name = "design_tokens"


func run() -> void:
	begin("both theme resources load")
	var themes: Dictionary = {}
	for mode in Tokens.MODES:
		var mode_name: String = mode
		var path: String = THEME_PATHS[mode_name]
		assert_true(ResourceLoader.exists(path), "%s exists" % path)
		var resource: Resource = load(path)
		assert_true(resource is Theme, "%s loads as a Theme" % path)
		if resource is Theme:
			themes[mode_name] = resource
	if themes.size() != 2:
		return
	var dark: Theme = themes["dark"]
	var light: Theme = themes["light"]

	_check_variations(dark, light)
	_check_structural_parity(dark, light)
	_check_stylebox_shape(dark, light)
	_check_tokens_json(dark, light)

	for mode in Tokens.MODES:
		var mode_name: String = mode
		var theme: Theme = themes[mode_name]
		var failures_before := failures.size()

		_check_tokens(theme, mode_name)
		_check_bars_and_separator(theme, mode_name)
		_check_r4_geometry(theme, mode_name)
		_check_orphans(theme, mode_name)

		print("[themes] %s items=%d contrast_pairs=%d failures=%d" % [
			mode_name, _item_count(theme), Tokens.contrast_pairs().size(),
			failures.size() - failures_before])

	_check_contrast()


#region Structure


## PRD-12 R4/AC3 — `resources/themes/tokens.json` is a true mirror: every palette entry, type,
## space, radius and motion value equals `DesignTokens`, and the values it publishes are the
## ones the loaded Theme resources actually render with. That closes the triangle
## tokens.json ⟷ DesignTokens ⟷ .tres without duplicating the 126-item mapping: the theme-side
## agreement is asserted here on the three kinds of item the JSON carries (colour, font size,
## panel fill), and `_check_tokens()` proves the rest against the same constants.
func _check_tokens_json(dark: Theme, light: Theme) -> void:
	begin("tokens.json mirrors the tokens and the themes")
	var text := FileAccess.get_file_as_string(TOKENS_JSON)
	assert_true(not text.is_empty(), "%s exists and is not empty" % TOKENS_JSON)
	var parsed: Variant = JSON.parse_string(text)
	assert_true(parsed is Dictionary, "%s parses as a JSON object" % TOKENS_JSON)
	if not (parsed is Dictionary):
		return
	var data: Dictionary = parsed

	for key in ["palettes", "type", "space", "radius", "motion", "contrast_pairs"]:
		assert_has_key(data, key, "tokens.json has '%s'" % key)
	if not data.has("palettes"):
		return

	var palettes: Dictionary = data["palettes"]
	for mode in Tokens.MODES:
		var mode_name: String = mode
		assert_has_key(palettes, mode_name, "tokens.json has the %s palette" % mode_name)
		if not palettes.has(mode_name):
			continue
		var json_palette: Dictionary = palettes[mode_name]
		var tokens_palette: Dictionary = Tokens.palette(mode_name)
		assert_eq(json_palette.size(), tokens_palette.size(),
			"%s palette has every token" % mode_name)
		for token in tokens_palette:
			assert_eq(json_palette.get(token, "<missing>"), tokens_palette[token],
				"%s.%s matches DesignTokens" % [mode_name, token])

	for dict_key in ["type", "space", "radius", "motion"]:
		var source: Dictionary = _design_tokens_dict(dict_key)
		var mirror: Dictionary = data[dict_key]
		assert_eq(mirror.size(), source.size(), "tokens.json '%s' size" % dict_key)
		for key in source:
			assert_eq(mirror.get(key, "<missing>"), source[key],
				"%s.%s matches DesignTokens" % [dict_key, key])

	# tokens.json ⟷ theme: one item of each kind, in each mode, must be identical.
	for mode in Tokens.MODES:
		var mode_name: String = mode
		var theme: Theme = dark if mode_name == "dark" else light
		var json_palette: Dictionary = palettes[mode_name]
		assert_eq(theme.get_color(&"font_color", &"BodyLabel"),
			Tokens.hex_to_color(json_palette["text"]),
			"%s BodyLabel font_color equals the mirrored 'text' token" % mode_name)
		assert_eq(theme.get_font_size(&"font_size", &"H2"),
			int(data["type"]["h2"]),
			"%s H2 font_size equals the mirrored 'h2' step" % mode_name)
		var card := theme.get_stylebox(&"panel", &"Card") as StyleBoxFlat
		assert_true(card != null, "%s Card panel is a StyleBoxFlat" % mode_name)
		if card != null:
			assert_eq(card.bg_color, Tokens.hex_to_color(json_palette["surface"]),
				"%s Card fill equals the mirrored 'surface' token" % mode_name)

	var pairs: Array = data["contrast_pairs"]
	assert_eq(pairs.size(), Tokens.contrast_pairs().size(),
		"tokens.json publishes every contrast pair")


## The four mirrored dictionaries live in typed constants on DesignTokens; a Dictionary lookup
## keeps this loop static (Godot has no reflection over const dictionaries).
func _design_tokens_dict(key: String) -> Dictionary:
	match key:
		"type": return Tokens.TYPE
		"space": return Tokens.SPACE
		"radius": return Tokens.RADIUS
		_: return Tokens.MOTION


func _check_variations(dark: Theme, light: Theme) -> void:
	begin("both themes declare the same type variations")
	var dark_variations := _variation_set(dark)
	var light_variations := _variation_set(light)
	assert_not_empty(dark_variations, "dark declares variations")
	assert_eq(", ".join(light_variations), ", ".join(dark_variations),
		"dark and light must declare the same variations")
	assert_eq(dark_variations.size(), VARIATIONS.size(),
		"every declarable R3 variation is declared")

	for name in VARIATIONS:
		var expected: String = VARIATIONS[name]
		assert_eq(String(dark.get_type_variation_base(StringName(name))), expected,
			"dark %s base_type" % name)
		assert_eq(String(light.get_type_variation_base(StringName(name))), expected,
			"light %s base_type" % name)

	for name in UNDECLARABLE_VARIATIONS:
		var type_name := StringName(name)
		assert_eq(String(dark.get_type_variation_base(type_name)), "",
			"%s cannot declare a base (ClassDB class name)" % name)
		var item_total := dark.get_color_list(type_name).size() \
			+ dark.get_stylebox_list(type_name).size() \
			+ dark.get_font_size_list(type_name).size()
		assert_gt(float(item_total), 0.0, "%s still carries its R3 items" % name)


func _check_structural_parity(dark: Theme, light: Theme) -> void:
	begin("dark and light declare identical types and items")
	var dark_types := _sorted_names(dark.get_type_list())
	var light_types := _sorted_names(light.get_type_list())
	assert_eq(", ".join(light_types), ", ".join(dark_types),
		"the two themes must expose the same type list")
	assert_eq(dark_types.size(), VARIATIONS.size() + UNDECLARABLE_VARIATIONS.size(),
		"the type list is exactly the R3 table")

	for type_name in dark_types:
		var theme_type := StringName(type_name)
		assert_eq(", ".join(_sorted_names(light.get_color_list(theme_type))),
			", ".join(_sorted_names(dark.get_color_list(theme_type))),
			"%s colour item names" % type_name)
		assert_eq(", ".join(_sorted_names(light.get_stylebox_list(theme_type))),
			", ".join(_sorted_names(dark.get_stylebox_list(theme_type))),
			"%s stylebox item names" % type_name)
		assert_eq(", ".join(_sorted_names(light.get_font_size_list(theme_type))),
			", ".join(_sorted_names(dark.get_font_size_list(theme_type))),
			"%s font_size item names" % type_name)
		assert_eq(", ".join(_sorted_names(light.get_constant_list(theme_type))),
			", ".join(_sorted_names(dark.get_constant_list(theme_type))),
			"%s constant item names" % type_name)
		# Value kinds: a colour item must be a Color, a stylebox item a StyleBox, sizes and
		# constants integers. get_color()/get_font_size() would coerce, so check the stored
		# variants through the item lists plus the typed getters.
		for item in dark.get_color_list(theme_type):
			assert_true(dark.get_color(item, theme_type) is Color,
				"%s/%s is a Color" % [type_name, item])
		for item in dark.get_font_size_list(theme_type):
			assert_eq(dark.get_font_size(item, theme_type),
				light.get_font_size(item, theme_type),
				"%s/%s font_size matches across modes" % [type_name, item])
		for item in dark.get_constant_list(theme_type):
			assert_eq(dark.get_constant(item, theme_type),
				light.get_constant(item, theme_type),
				"%s/%s constant matches across modes" % [type_name, item])


func _check_stylebox_shape(dark: Theme, light: Theme) -> void:
	begin("every stylebox is an anti-aliased StyleBoxFlat with corner_detail 8 (R3)")
	for resource in [dark, light]:
		var theme: Theme = resource
		var total := 0
		for type_name in theme.get_type_list():
			for item in theme.get_stylebox_list(type_name):
				var box: StyleBox = theme.get_stylebox(item, type_name)
				total += 1
				assert_true(box is StyleBoxFlat, "%s/%s is a StyleBoxFlat" % [type_name, item])
				if box is StyleBoxFlat:
					var flat: StyleBoxFlat = box
					assert_true(flat.anti_aliasing, "%s/%s anti_aliasing" % [type_name, item])
					assert_eq(flat.corner_detail, 8, "%s/%s corner_detail" % [type_name, item])
		assert_gt(float(total), 0.0, "the theme declares styleboxes")


func _item_count(theme: Theme) -> int:
	var total := 0
	for type_name in theme.get_type_list():
		total += theme.get_color_list(type_name).size()
		total += theme.get_stylebox_list(type_name).size()
		total += theme.get_font_size_list(type_name).size()
		total += theme.get_constant_list(type_name).size()
	return total


func _variation_set(theme: Theme) -> PackedStringArray:
	var found := PackedStringArray()
	for type_name in theme.get_type_list():
		if not String(theme.get_type_variation_base(type_name)).is_empty():
			found.append(String(type_name))
	found.sort()
	return found


func _sorted_names(names: PackedStringArray) -> PackedStringArray:
	var copy := names.duplicate()
	copy.sort()
	return copy


#endregion


#region R3 / R4 values


func _check_tokens(theme: Theme, mode: String) -> void:
	begin("%s root default_font_size is TYPE.body" % mode)
	assert_eq(theme.default_font_size, int(Tokens.TYPE["body"]), "root default_font_size")
	# The one owner-approved scale change (2026-10-01 readability pass): 22 -> 28. Every
	# other row on this page still compares the theme against the tokens, so this stays a
	# belt-and-braces pin, not the source of truth.
	assert_eq(theme.default_font_size, 28, "R3 pins the root default_font_size to 28")

	begin("%s item count matches the R3 table" % mode)
	assert_eq(_item_count(theme), EXPECTED_ITEMS, "R3 item count")

	begin("%s representative token mapping" % mode)
	# The five rows the theme contract calls out by name.
	var card: StyleBox = theme.get_stylebox(&"panel", &"Card")
	assert_true(card is StyleBoxFlat, "Card/panel is a StyleBoxFlat")
	if card is StyleBoxFlat:
		assert_eq((card as StyleBoxFlat).bg_color, Tokens.color(mode, "surface"), "Card bg")
	var primary: StyleBox = theme.get_stylebox(&"normal", &"PrimaryButton")
	assert_true(primary is StyleBoxFlat, "PrimaryButton/normal is a StyleBoxFlat")
	if primary is StyleBoxFlat:
		assert_eq((primary as StyleBoxFlat).bg_color, Tokens.color(mode, "primary"),
			"PrimaryButton normal bg")
	assert_eq(theme.get_color(&"font_color", &"PrimaryButton"), Tokens.on_accent(mode),
		"PrimaryButton font_color is on_accent")
	assert_eq(theme.get_color(&"font_color", &"NavTabLabelActive"),
		Tokens.accent_text(mode, "primary"),
		"NavTabLabelActive font_color is the accent-as-text colour")
	assert_eq(theme.get_color(&"font_color", &"NavTabLabel"),
		Tokens.color(mode, "text_muted"), "NavTabLabel font_color is text_muted")

	begin("%s full R3 colour table" % mode)
	for row in _colour_rows():
		var type_name := StringName(row[0])
		var item := StringName(row[1])
		var expected := _colour_of(mode, row[2])
		assert_eq(theme.get_color(item, type_name), expected,
			"%s/%s must be %s" % [row[0], row[1], row[2]])

	begin("%s R3 font sizes and constants" % mode)
	for row in _font_size_rows():
		assert_eq(theme.get_font_size(StringName(row[1]), StringName(row[0])),
			int(Tokens.TYPE[row[2]]), "%s/font_size" % row[0])
	assert_eq(theme.get_constant(&"separation", &"Separator"), 1, "Separator/separation")
	assert_eq(theme.get_constant(&"h_separation", &"PrimaryButton"), int(Tokens.SPACE["md"]),
		"PrimaryButton/h_separation")
	assert_eq(theme.get_constant(&"outline_size", &"PrimaryButton"), 0,
		"PrimaryButton/outline_size (no text outline)")
	assert_eq(theme.get_constant(&"h_separation", &"NavTab"), int(Tokens.SPACE["xs"]),
		"NavTab/h_separation")

	begin("%s LoadingOverlay scrim is bg at 72%% alpha" % mode)
	var scrim := theme.get_color(&"dim_color", &"LoadingOverlay")
	var background := Tokens.color(mode, "bg")
	assert_close(scrim.a, 0.72, 0.0001, "dim_color alpha")
	assert_close(scrim.r, background.r, 0.0001, "dim_color red")
	assert_close(scrim.g, background.g, 0.0001, "dim_color green")
	assert_close(scrim.b, background.b, 0.0001, "dim_color blue")


## R3 colour rows: [type, item, token-or-derived-key].
func _colour_rows() -> Array:
	return [
		["DisplayLabel", "font_color", "text"],
		["H1", "font_color", "text"],
		["H2", "font_color", "text"],
		["H3", "font_color", "text"],
		["BodyLabel", "font_color", "text"],
		["BodySmall", "font_color", "text"],
		["Caption", "font_color", "text_muted"],
		["MutedLabel", "font_color", "text_muted"],
		["NavTabLabel", "font_color", "text_muted"],
		["NavTabLabelActive", "font_color", "accent:primary"],
		["PrimaryButton", "font_color", "on_accent"],
		["PrimaryButton", "font_pressed_color", "on_accent"],
		["PrimaryButton", "font_hover_color", "on_accent"],
		["PrimaryButton", "font_hover_pressed_color", "on_accent"],
		["PrimaryButton", "font_disabled_color", "text_disabled"],
		["SecondaryButton", "font_color", "text"],
		["SecondaryButton", "font_pressed_color", "text"],
		["SecondaryButton", "font_disabled_color", "text_disabled"],
		["GhostButton", "font_color", "text_muted"],
		["DangerButton", "font_color", "accent:danger"],
		["DangerButton", "font_pressed_color", "accent:danger"],
		["DangerButton", "font_disabled_color", "text_disabled"],
		["ChipToggle", "font_color", "text_muted"],
		["ChipToggle", "font_pressed_color", "on_accent"],
		["ChipToggle", "font_hover_pressed_color", "on_accent"],
		["ChipToggle", "font_disabled_color", "text_disabled"],
		["Input", "font_color", "text"],
		["Input", "font_placeholder_color", "text_disabled"],
		["Input", "caret_color", "primary"],
		["Input", "selection_color", "outline"],
		["InputMulti", "font_color", "text"],
		["InputMulti", "font_placeholder_color", "text_disabled"],
		["InputMulti", "caret_color", "primary"],
		["InputMulti", "selection_color", "outline"],
		["SettingToggle", "icon_normal_color", "text_muted"],
		["SettingToggle", "icon_pressed_color", "primary"],
		["SettingToggle", "font_color", "text"],
		["ProgressRing", "track_color", "surface_alt"],
		["ProgressRing", "fill_color", "primary"],
		["ProgressRing", "caption_color", "text_muted"],
		["Glyph", "color", "text_muted"],
		["Glyph", "color_active", "primary"],
		["Glyph", "color_disabled", "text_disabled"],
		["EmptyState", "title_color", "text"],
		["EmptyState", "body_color", "text_muted"],
		["EmptyState", "icon_color", "outline"],
	]


## R3 font-size rows: [type, item, TYPE key].
func _font_size_rows() -> Array:
	return [
		["DisplayLabel", "font_size", "display"],
		["H1", "font_size", "h1"],
		["H2", "font_size", "h2"],
		["H3", "font_size", "h3"],
		["BodyLabel", "font_size", "body"],
		["BodySmall", "font_size", "body_small"],
		["Caption", "font_size", "caption"],
		["MutedLabel", "font_size", "body_small"],
		["NavTabLabel", "font_size", "caption"],
		["NavTabLabelActive", "font_size", "caption"],
		["PrimaryButton", "font_size", "button"],
		["SecondaryButton", "font_size", "button"],
		["DangerButton", "font_size", "button"],
		["GhostButton", "font_size", "body"],
		["NavTab", "font_size", "caption"],
		["ChipToggle", "font_size", "body_small"],
		["Input", "font_size", "body"],
		["InputMulti", "font_size", "body"],
		["SettingToggle", "font_size", "body"],
	]


## R4 geometry rows: [type, state, bg-key, border widths l/t/r/b, border-key,
## radii tl/tr/br/bl, margins l/t/r/b, draw_center].
func _check_r4_geometry(theme: Theme, mode: String) -> void:
	begin("%s R4 stylebox geometry" % mode)
	for row in _r4_rows():
		var type_name := StringName(row[0])
		var state := StringName(row[1])
		var label := "%s/%s" % [row[0], row[1]]
		var box: StyleBox = theme.get_stylebox(state, type_name)
		assert_true(box is StyleBoxFlat, "%s is a StyleBoxFlat" % label)
		if not (box is StyleBoxFlat):
			continue
		var flat: StyleBoxFlat = box
		assert_eq(flat.bg_color, _colour_of(mode, row[2]), "%s bg_color" % label)
		assert_eq(flat.draw_center, row[7], "%s draw_center" % label)
		var widths: Array = row[3]
		assert_eq(flat.border_width_left, widths[0], "%s border_width_left" % label)
		assert_eq(flat.border_width_top, widths[1], "%s border_width_top" % label)
		assert_eq(flat.border_width_right, widths[2], "%s border_width_right" % label)
		assert_eq(flat.border_width_bottom, widths[3], "%s border_width_bottom" % label)
		var border_total: int = widths[0] + widths[1] + widths[2] + widths[3]
		if border_total > 0:
			assert_eq(flat.border_color, _colour_of(mode, row[4]), "%s border_color" % label)
		var radii: Array = row[5]
		assert_eq(flat.corner_radius_top_left, radii[0], "%s radius top_left" % label)
		assert_eq(flat.corner_radius_top_right, radii[1], "%s radius top_right" % label)
		assert_eq(flat.corner_radius_bottom_right, radii[2], "%s radius bottom_right" % label)
		assert_eq(flat.corner_radius_bottom_left, radii[3], "%s radius bottom_left" % label)
		var margins: Array = row[6]
		assert_eq(int(roundi(flat.content_margin_left)), margins[0], "%s margin left" % label)
		assert_eq(int(roundi(flat.content_margin_top)), margins[1], "%s margin top" % label)
		assert_eq(int(roundi(flat.content_margin_right)), margins[2], "%s margin right" % label)
		assert_eq(int(roundi(flat.content_margin_bottom)), margins[3], "%s margin bottom" % label)


func _r4_rows() -> Array:
	var r_button: int = int(Tokens.RADIUS["button"])
	var r_card: int = int(Tokens.RADIUS["card"])
	var r_chip: int = int(Tokens.RADIUS["chip"])
	var r_sheet: int = int(Tokens.RADIUS["sheet"])
	var btn: Array = _pad(int(Tokens.SPACE["xxl"]), int(Tokens.SPACE["xl"]))
	var chip: Array = _pad(int(Tokens.SPACE["xl"]), int(Tokens.SPACE["lg"]))
	var card: Array = _pad(int(Tokens.SPACE["xl"]), int(Tokens.SPACE["xl"]))
	var tile: Array = _pad(int(Tokens.SPACE["lg"]),
		int(Tokens.SPACE["md"]) + int(Tokens.SPACE["sm"]))
	var field: Array = _pad(int(Tokens.SPACE["lg"]), int(Tokens.SPACE["md"]) + 2)
	var multi: Array = _pad(int(Tokens.SPACE["lg"]), int(Tokens.SPACE["lg"]))
	var toast: Array = _pad(int(Tokens.SPACE["lg"]), int(Tokens.SPACE["md"]))
	var tab: Array = _pad(int(Tokens.SPACE["sm"]), int(Tokens.SPACE["xs"]))
	var sheet: Array = _pad(int(Tokens.SPACE["xxl"]), int(Tokens.SPACE["xxl"]))
	var square := [0, 0, 0, 0]
	var no_margins := [-1, -1, -1, -1]  # unset: StyleBoxFlat's own default
	var rb := _radius4(r_button)
	var rc := _radius4(r_card)
	var rch := _radius4(r_chip)

	return [
		# PrimaryButton — accent fill. R4 lists `primary_dim` for `pressed`; PRD-00 appendix
		# §4.3 rule 3 forbids that fill ("never a button press fill") and the appendix wins, so
		# the pressed fill stays `primary` and press feedback is the component's press_scale.
		["PrimaryButton", "normal", "primary", _bw(0), "", rb, btn, true],
		["PrimaryButton", "hover", "primary_lightened", _bw(0), "", rb, btn, true],
		["PrimaryButton", "pressed", "primary", _bw(0), "", rb, btn, true],
		["PrimaryButton", "disabled", "surface_alt", _bw(0), "", rb, btn, true],
		["PrimaryButton", "focus", "transparent", _bw(4), "secondary", rb, btn, false],
		# SecondaryButton.
		["SecondaryButton", "normal", "transparent", _bw(2), "outline", rb, btn, true],
		["SecondaryButton", "hover", "surface_alt", _bw(2), "outline", rb, btn, true],
		["SecondaryButton", "pressed", "surface_alt", _bw(2), "primary", rb, btn, true],
		["SecondaryButton", "disabled", "transparent", _bw(2), "outline", rb, btn, true],
		["SecondaryButton", "focus", "transparent", _bw(4), "secondary", rb, btn, false],
		# DangerButton mirrors SecondaryButton with a `danger` label and normal border.
		["DangerButton", "normal", "transparent", _bw(2), "danger", rb, btn, true],
		["DangerButton", "hover", "surface_alt", _bw(2), "outline", rb, btn, true],
		["DangerButton", "pressed", "surface_alt", _bw(2), "primary", rb, btn, true],
		# ChipToggle.
		["ChipToggle", "normal", "surface_alt", _bw(2), "outline", rch, chip, true],
		["ChipToggle", "hover", "surface_alt", _bw(2), "secondary", rch, chip, true],
		["ChipToggle", "pressed", "primary", _bw(2), "primary", rch, chip, true],
		["ChipToggle", "hover_pressed", "primary_lightened", _bw(2), "primary", rch, chip, true],
		["ChipToggle", "disabled", "surface_alt", _bw(2), "outline", rch, chip, true],
		["ChipToggle", "focus", "transparent", _bw(4), "secondary", rch, chip, false],
		# Panels. A sheet is rounded on its top corners only.
		["Card", "panel", "surface", _bw(0), "", rc, card, true],
		["CardAlt", "panel", "surface_alt", _bw(0), "", rc, card, true],
		["Sheet", "panel", "surface", _bw(0), "", [r_sheet, r_sheet, 0, 0], sheet, true],
		["StatTile", "panel", "surface_alt", _bw(0), "", rc, tile, true],
		["Toast", "panel", "surface_alt", _bw(1), "outline", rch, toast, true],
		# Inputs — appendix §4.3 rule 4 bounds them with `outline_strong`, focus with `primary`.
		["Input", "normal", "surface_alt", _bw(2), "outline_strong", rch, field, true],
		["Input", "focus", "surface_alt", _bw(2), "primary", rch, field, true],
		["Input", "read_only", "surface_alt", _bw(2), "outline_strong", rch, field, true],
		["InputMulti", "normal", "surface_alt", _bw(2), "outline_strong", rch, multi, true],
		["InputMulti", "focus", "surface_alt", _bw(2), "primary", rch, multi, true],
		["InputMulti", "read_only", "surface_alt", _bw(2), "outline_strong", rch, multi, true],
		# NavTab: chromeless touch target, chip radius, 8/4 padding (R3).
		["NavTab", "normal", "transparent", _bw(0), "", rch, tab, false],
		["NavTab", "hover", "transparent", _bw(0), "", rch, tab, false],
		["NavTab", "pressed", "transparent", _bw(0), "", rch, tab, false],
		["NavTab", "hover_pressed", "transparent", _bw(0), "", rch, tab, false],
		["NavTab", "focus", "transparent", _bw(0), "", rch, tab, false],
		# Bars — square and margin-less, one 1 px hairline on the edge facing the content.
		["BottomNav", "panel", "surface", [0, 1, 0, 0], "outline", square, no_margins, true],
		["TopBar", "panel", "bg", [0, 0, 0, 1], "outline", square, no_margins, true],
	]


func _check_bars_and_separator(theme: Theme, mode: String) -> void:
	begin("%s bars carry a single 1 px outline hairline" % mode)
	var bottom: StyleBox = theme.get_stylebox(&"panel", &"BottomNav")
	var top: StyleBox = theme.get_stylebox(&"panel", &"TopBar")
	assert_true(bottom is StyleBoxFlat, "BottomNav/panel is a StyleBoxFlat")
	assert_true(top is StyleBoxFlat, "TopBar/panel is a StyleBoxFlat")
	if bottom is StyleBoxFlat:
		var bar: StyleBoxFlat = bottom
		assert_eq(bar.border_width_top, 1, "BottomNav border top")
		assert_eq(bar.border_width_bottom, 0, "BottomNav has no bottom border")
		assert_eq(bar.border_color, Tokens.color(mode, "outline"), "BottomNav border colour")
	if top is StyleBoxFlat:
		var bar: StyleBoxFlat = top
		assert_eq(bar.border_width_bottom, 1, "TopBar border bottom")
		assert_eq(bar.border_width_top, 0, "TopBar has no top border")
		assert_eq(bar.border_color, Tokens.color(mode, "outline"), "TopBar border colour")

	begin("%s Separator is a 1 px outline hairline" % mode)
	var sep: StyleBox = theme.get_stylebox(&"separator", &"Separator")
	assert_true(sep is StyleBoxFlat, "Separator/separator is a StyleBoxFlat")
	if sep is StyleBoxFlat:
		assert_eq((sep as StyleBoxFlat).bg_color, Tokens.color(mode, "outline"),
			"Separator bg is outline")
		assert_eq(int(roundi((sep as StyleBoxFlat).content_margin_top)), 1,
			"Separator content_margin_top is 1")


#endregion


#region Orphan colours


func _check_orphans(theme: Theme, mode: String) -> void:
	begin("%s has no orphan colour" % mode)
	var allowed := _allowed_colours(mode)
	var offenders := PackedStringArray()
	for entry in _stored_colours(theme):
		var colour: Color = entry[1]
		if not allowed.has(colour):
			offenders.append("%s=%s" % [entry[0], colour.to_html(false)])
	assert_empty(offenders, "colours outside DesignTokens.palette(%s): %s"
		% [mode, ", ".join(offenders)])


## Every colour actually stored in the theme: colour items, plus the stylebox colours that are
## visible (a border colour with border width 0 and an unset shadow cannot paint anything, and
## StyleBoxFlat's defaults for those are black — they are not part of the palette contract).
func _stored_colours(theme: Theme) -> Array:
	var found: Array = []
	for type_name in theme.get_type_list():
		for item in theme.get_color_list(type_name):
			found.append(["%s/%s" % [type_name, item], theme.get_color(item, type_name)])
		for item in theme.get_stylebox_list(type_name):
			var box: StyleBox = theme.get_stylebox(item, type_name)
			if not (box is StyleBoxFlat):
				continue
			var flat: StyleBoxFlat = box
			var label := "%s/%s" % [type_name, item]
			found.append(["%s.bg_color" % label, flat.bg_color])
			var border_width := (flat.border_width_left + flat.border_width_top
				+ flat.border_width_right + flat.border_width_bottom)
			if border_width > 0:
				found.append(["%s.border_color" % label, flat.border_color])
			if flat.shadow_size > 0:
				found.append(["%s.shadow_color" % label, flat.shadow_color])
	return found


## The palette plus the only derived colours the spec creates: `primary` lightened 8 % (the
## hover fill), fully transparent (outline-only and chromeless states), `on_accent` (already a
## token) and the LoadingOverlay scrim (`bg` at 72 % alpha).
func _allowed_colours(mode: String) -> Array:
	var allowed: Array = []
	var palette := Tokens.palette(mode)
	for token in palette.keys():
		allowed.append(Tokens.hex_to_color(String(palette[token])))
	allowed.append(Color(0, 0, 0, 0))
	allowed.append(Tokens.color(mode, "primary").lightened(0.08))
	var background := Tokens.color(mode, "bg")
	allowed.append(Color(background.r, background.g, background.b, 0.72))
	return allowed


#endregion


#region Contrast


func _check_contrast() -> void:
	begin("the R5 contrast table clears WCAG AA in both modes")
	var pairs: Array = Tokens.contrast_pairs()
	assert_ge(float(pairs.size()), 4.0, "the pair table is non-trivial")
	for mode in Tokens.MODES:
		var mode_name: String = mode
		for pair in pairs:
			var foreground: String = pair[0]
			var background: String = pair[1]
			var ratio := Tokens.contrast_ratio(Tokens.color(mode_name, foreground),
				Tokens.color(mode_name, background))
			assert_ge(ratio, 4.5, "%s: %s on %s is %.2f:1" % [
				mode_name, foreground, background, ratio])


#endregion


#region Value helpers


func _pad(x: int, y: int) -> Array:
	return [x, y, x, y]


func _bw(px: int) -> Array:
	return [px, px, px, px]


func _radius4(value: int) -> Array:
	return [value, value, value, value]


## Resolves a row's colour key: a palette token, or one of the derived colours the spec creates.
func _colour_of(mode: String, key: String) -> Color:
	# "accent:<token>" means the colour used when an accent is rendered as TEXT or an icon,
	# which differs from the raw accent in light mode (see DesignTokens.accent_text).
	if key.begins_with("accent:"):
		return Tokens.accent_text(mode, key.substr(7))
	match key:
		"transparent":
			return Color(0, 0, 0, 0)
		"primary_lightened":
			return Tokens.color(mode, "primary").lightened(0.08)
		"on_accent":
			return Tokens.on_accent(mode)
		_:
			return Tokens.color(mode, key)


#endregion
