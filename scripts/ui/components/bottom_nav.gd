extends PanelContainer
## Four-tab bottom navigation — PRD-02 R7 + R10.
##
## Behaviour is fixed by R10: the bar is pinned to `NAV_BAR_HEIGHT` with `SHRINK_END`, tab
## indices 0..3 map to `home`/`plan`/`tracker`/`settings`, [method set_active] is idempotent
## and silent, and [signal tab_selected] fires **only** on a real user press — never from
## [method set_active], so `Nav` stays the single owner of tab state.

signal tab_selected(index: int)

const TAB_COUNT := 4

## R10 tab index → caption. Kept here (not only in the scene) so the table is the one truth.
const TAB_CAPTIONS: Array[String] = ["Home", "Plan", "Tracker", "Settings"]

## R10 tab index → `Glyph.kind`.
const TAB_GLYPHS: Array[StringName] = [&"home", &"plan", &"tracker", &"settings"]

const VARIATION_IDLE := &"NavTabLabel"
const VARIATION_ACTIVE := &"NavTabLabelActive"

var _active: int = -1


func _ready() -> void:
	# Keep the tokens and the R10 tables authoritative even if the scene literals ever drift.
	custom_minimum_size.y = float(DesignTokens.NAV_BAR_HEIGHT)
	for i in TAB_COUNT:
		var tab := tab_button(i)
		if tab == null:
			continue
		var caption := tab.get_node_or_null(^"Stack/Caption") as Label
		if caption != null:
			caption.text = TAB_CAPTIONS[i]
		var icon := tab.get_node_or_null(^"Stack/Icon")
		if icon != null:
			icon.set(&"kind", TAB_GLYPHS[i])
		# PRD-12 R5: the required copy for the four tab buttons.
		A11y.label(tab, "%s tab, %d of %d" % [TAB_CAPTIONS[i], i + 1, TAB_COUNT])
		if not tab.toggled.is_connected(_on_tab_toggled):
			tab.toggled.connect(_on_tab_toggled.bind(i))
	set_active(0)


## Highlights tab [param index] without emitting [signal tab_selected].
func set_active(index: int) -> void:
	if index < 0 or index >= TAB_COUNT:
		push_warning("[ui] bottom_nav: tab index out of range: %d" % index)
		return
	_active = index
	for i in TAB_COUNT:
		var tab := tab_button(i)
		if tab == null:
			continue
		var selected := i == index
		tab.set_pressed_no_signal(selected)
		var caption := tab.get_node_or_null(^"Stack/Caption") as Label
		if caption != null:
			caption.theme_type_variation = VARIATION_ACTIVE if selected else VARIATION_IDLE
		var icon := tab.get_node_or_null(^"Stack/Icon")
		if icon != null:
			icon.set(&"active", selected)


func active_tab() -> int:
	return _active


## The `Button` for tab [param index], or `null` when out of range.
func tab_button(index: int) -> Button:
	if index < 0 or index >= TAB_COUNT:
		return null
	return get_node_or_null("Tabs/Tab%d" % index) as Button


func _on_tab_toggled(selected: bool, index: int) -> void:
	if not selected:
		return
	# Repaint immediately so the bar is correct even when nothing is listening; the shell
	# calls set_active() again from Nav.tab_changed, which is silent and idempotent.
	set_active(index)
	tab_selected.emit(index)
