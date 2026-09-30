extends TestSuite
## PRD-12 R6 — dynamic type: the pure theme scaler behind the "Text size" step.
##
## The scaler must multiply every font size, leave every colour and stylebox alone, and never
## mutate the shared generated theme resource (it is loaded once and cached by the engine).

const DARK_THEME := "res://resources/themes/theme_dark.tres"


func _init() -> void:
	suite_name = "theme_scale"


func run() -> void:
	var base: Theme = load(DARK_THEME) as Theme
	begin("the generated dark theme loads")
	assert_true(base != null, DARK_THEME)
	if base == null:
		return

	begin("factors at or below 1.0 are refused")
	assert_true(ThemeScale.scaled(base, 1.0) == base, "1.0 returns the same instance")
	assert_true(ThemeScale.scaled(base, 0.0) == base, "0.0 returns the base")
	assert_true(ThemeScale.scaled(base, -1.0) == base, "a negative factor returns the base")
	assert_true(ThemeScale.scaled(null, 1.5) == null, "null base returns null")

	begin("every font size scales by 1.5 (the XXL step)")
	var big := ThemeScale.scaled(base, 1.5)
	assert_eq(big.default_font_size, 33, "root default 22 -> 33")
	assert_eq(big.get_font_size(&"font_size", &"Caption"), 24, "caption 16 -> 24")
	assert_eq(big.get_font_size(&"font_size", &"BodySmall"), 29, "body_small 19 -> 29")
	assert_eq(big.get_font_size(&"font_size", &"BodyLabel"), 33, "body 22 -> 33")
	assert_eq(big.get_font_size(&"font_size", &"PrimaryButton"), 36, "button 24 -> 36")
	assert_eq(big.get_font_size(&"font_size", &"DisplayLabel"), 96, "display 64 -> 96")
	var lists_match := true
	for type_name in base.get_type_list():
		if base.get_font_size_list(type_name) != big.get_font_size_list(type_name):
			lists_match = false
	assert_true(lists_match, "scaled and base declare the same font_size item names")
	var values_match := true
	for type_name in base.get_type_list():
		for item_name in base.get_font_size_list(type_name):
			var expected := int(round(float(base.get_font_size(item_name, type_name)) * 1.5))
			if big.get_font_size(item_name, type_name) != expected:
				values_match = false
	assert_true(values_match, "every item equals round(base * 1.5)")

	begin("colours, styleboxes and constants are untouched")
	assert_eq(big.get_color(&"font_color", &"BodyLabel"),
		base.get_color(&"font_color", &"BodyLabel"), "BodyLabel font_color")
	assert_eq(big.get_color(&"font_color", &"Caption"),
		base.get_color(&"font_color", &"Caption"), "Caption font_color")
	assert_eq(big.get_constant(&"outline_size", &"PrimaryButton"),
		base.get_constant(&"outline_size", &"PrimaryButton"), "PrimaryButton outline_size")
	var big_normal := big.get_stylebox(&"normal", &"PrimaryButton") as StyleBoxFlat
	var base_normal := base.get_stylebox(&"normal", &"PrimaryButton") as StyleBoxFlat
	assert_true(big_normal != null and base_normal != null, "PrimaryButton normal exists")
	if big_normal != null and base_normal != null:
		assert_eq(big_normal.bg_color, base_normal.bg_color, "normal bg_color")
		assert_eq(big_normal.border_width_left, base_normal.border_width_left, "border width")

	begin("the shared resource is never mutated")
	assert_eq(base.default_font_size, 22, "base default stays 22")
	assert_eq(base.get_font_size(&"font_size", &"Caption"), 16, "base caption stays 16")

	begin("the S step rounds and never reaches zero")
	var small := ThemeScale.scaled(base, 0.85)
	assert_eq(small.get_font_size(&"font_size", &"Caption"), 14, "caption 16 * 0.85 -> 14")
	assert_eq(small.default_font_size, 19, "root 22 * 0.85 -> 19")
	var tiny := Theme.new()
	tiny.default_font_size = 1
	tiny.set_font_size(&"font_size", &"Caption", 1)
	var tiny_small := ThemeScale.scaled(tiny, 0.85)
	assert_eq(tiny_small.default_font_size, 1, "a 1 px default cannot round to 0")
	assert_eq(tiny_small.get_font_size(&"font_size", &"Caption"), 1, "a 1 px item cannot round to 0")
