extends Control
## Debug-only component gallery (PRD-02 R21).
##
## Renders every component in the shared library so a visual regression is obvious, and
## so PRD-02's screenshots can prove the library exists. It is excluded from release
## builds by the export preset's `exclude_filter` **and** refuses to build at runtime in a
## release binary, so it cannot ship even by accident.

const PAGE := "Layout/Scroll/Gutter/Content"
const OVERLAY_LAYER := "OverlayLayer"

const COMPONENTS := "res://scenes/components/"

## Label variations, in descending size, to prove the whole type scale renders.
const TYPE_VARIATIONS := [
	["DisplayLabel", "display 64"], ["H1", "h1 44"], ["H2", "h2 34"], ["H3", "h3 26"],
	["BodyLabel", "body 22"], ["BodySmall", "body_small 19"], ["Caption", "caption 16"],
	["MutedLabel", "muted 19"],
]

const GLYPH_KINDS := [
	"home", "plan", "tracker", "settings", "check", "chevron_right", "chevron_left",
	"play", "pause", "plus", "close", "timer", "refresh", "flame", "info", "warning",
]


func _ready() -> void:
	if OS.has_feature("release"):
		push_error("[gallery] refusing to build in a release build")
		return

	var top := get_node_or_null("Layout/TopBar")
	if top != null:
		if top.has_method(&"set_title"):
			top.call(&"set_title", "Component gallery")
		if top.has_signal(&"back_pressed"):
			top.connect(&"back_pressed", func() -> void: Nav.pop())

	_build()


func _build() -> void:
	var page := get_node_or_null(PAGE) as VBoxContainer
	if page == null:
		push_error("[gallery] content container missing")
		return

	_heading(page, "Typography")
	for entry in TYPE_VARIATIONS:
		page.add_child(_label(entry[1], entry[0]))

	_heading(page, "Buttons")
	var primary := _instance("primary_button", page)
	if primary is Button:
		(primary as Button).text = "Primary action"
	var secondary := _instance("secondary_button", page)
	if secondary is Button:
		(secondary as Button).text = "Secondary action"
	var danger := _instance("secondary_button", page)
	if danger is Button:
		var danger_button := danger as Button
		danger_button.text = "Danger action"
		danger_button.theme_type_variation = &"DangerButton"

	_heading(page, "Chips (two selected)")
	for i in range(4):
		var chip := _instance("chip_toggle", page)
		if chip is Button:
			var chip_button := chip as Button
			chip_button.text = ["Chest", "Back", "Shoulders", "Core"][i]
			if chip_button.has_method(&"set_selected"):
				chip_button.call(&"set_selected", i < 2)

	_heading(page, "Cards and stat tiles")
	var card := _instance("card", page)
	if card != null and card.has_method(&"body"):
		var body: VBoxContainer = card.call(&"body")
		body.add_child(_label("Card body text wraps inside the card's own padding.", "BodyLabel"))

	var tile_row := HBoxContainer.new()
	tile_row.add_theme_constant_override(&"separation", DesignTokens.SPACE["lg"])
	tile_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(tile_row)
	for spec in [["Streak", "4 days", "flame"], ["This week", "2 / 4", "tracker"]]:
		var tile := _instance("stat_tile", tile_row)
		if tile != null and tile.has_method(&"set_stat"):
			tile.call(&"set_stat", spec[0], spec[1], StringName(spec[2]))
		if tile is Control:
			(tile as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_heading(page, "Section header")
	var header := _instance("section_header", page)
	if header != null and header.has_method(&"set_header"):
		header.call(&"set_header", "Section title", "Action")

	_heading(page, "Progress rings at 0 / 25 / 60 / 100%")
	var ring_row := HBoxContainer.new()
	ring_row.add_theme_constant_override(&"separation", DesignTokens.SPACE["lg"])
	page.add_child(ring_row)
	for value in [0.0, 0.25, 0.6, 1.0]:
		var ring := _instance("progress_ring", ring_row)
		if ring is Control:
			var ring_control := ring as Control
			ring_control.custom_minimum_size = Vector2(160, 160)
			ring_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if ring != null:
			if ring.has_method(&"set_value"):
				ring.call(&"set_value", value)
			if ring.has_method(&"set_caption"):
				ring.call(&"set_caption", "%d%%" % roundi(value * 100.0))

	_heading(page, "Feedback")
	var toast_button := _instance("secondary_button", page)
	if toast_button is Button:
		(toast_button as Button).text = "Show toast"
		(toast_button as Button).pressed.connect(
			func() -> void: Feedback.toast("Saved to your device", &"success"))

	var loading_button := _instance("secondary_button", page)
	if loading_button is Button:
		(loading_button as Button).text = "Show loading overlay (1.5 s)"
		(loading_button as Button).pressed.connect(_show_loading)

	_heading(page, "Empty state")
	var empty := _instance("empty_state", page)
	if empty != null and empty.has_method(&"set_state"):
		empty.call(&"set_state", &"plan", "No plan yet",
			"Tell MicroWorkout what matters to you and it will build your week.", "New workout")

	_heading(page, "Exercise thumbnail (no art yet)")
	var thumb := _instance("exercise_thumbnail", page)
	if thumb != null and thumb.has_method(&"set_exercise"):
		thumb.call(&"set_exercise", "bench-press", PackedStringArray())

	_heading(page, "Glyphs (%d kinds)" % GLYPH_KINDS.size())
	var glyph_row := HBoxContainer.new()
	glyph_row.add_theme_constant_override(&"separation", DesignTokens.SPACE["sm"])
	page.add_child(glyph_row)
	for kind in GLYPH_KINDS:
		var glyph := _instance("glyph", glyph_row)
		if glyph is Control:
			(glyph as Control).custom_minimum_size = Vector2(96, 96)
		if glyph != null:
			glyph.set(&"kind", StringName(kind))


func _heading(page: VBoxContainer, text: String) -> void:
	var header := _instance("section_header", page)
	if header != null and header.has_method(&"set_header"):
		header.call(&"set_header", text, "")


func _label(text: String, variation: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = StringName(variation)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _instance(component: String, parent: Node) -> Node:
	var path := "%s%s.tscn" % [COMPONENTS, component]
	if not ResourceLoader.exists(path):
		push_warning("[gallery] missing component: %s" % path)
		return null
	var packed: PackedScene = load(path)
	var node: Node = packed.instantiate()
	parent.add_child(node)
	return node


func _show_loading() -> void:
	var layer := get_node_or_null(OVERLAY_LAYER)
	if layer == null:
		return
	var overlay := _instance("loading_overlay", layer)
	if overlay is Control:
		(overlay as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
	if overlay != null and overlay.has_method(&"show_overlay"):
		overlay.call(&"show_overlay", "Generating…")
		await get_tree().create_timer(1.5).timeout
		if is_instance_valid(overlay) and overlay.has_method(&"hide_overlay"):
			overlay.call(&"hide_overlay")
		if is_instance_valid(overlay):
			overlay.queue_free()
