class_name StatusChip
extends PanelContainer
## Provider/connection status — PRD-06 (appendix §3.2).
##
## The appendix's rule 6 is the whole reason this exists: **no state is colour-only**. Every
## status carries a glyph *and* a word, so it survives a greyscale screenshot and the
## `primary`/`danger` greyscale near-collision the appendix calls out. Colour is deliberately
## not used at all: colouring by state would need one theme variation per state, and the theme's
## variation set is frozen by `test_design_tokens.gd`.

const STATE_VERIFIED := &"verified"
const STATE_UNVERIFIED := &"unverified"
const STATE_REJECTED := &"rejected"
const STATE_UNREACHABLE := &"unreachable"

var _state: StringName = STATE_UNVERIFIED


## Sets the state and its words. An empty [param text] uses the canonical word for the state, so
## a caller that only knows the state still renders the right label (R9's four chip values).
func set_status(state: StringName, text: String = "") -> void:
	_state = state
	var icon := icon_node()
	if icon != null:
		icon.set(&"kind", glyph_for(state))
	var label := text_node()
	if label != null:
		label.text = text if not text.is_empty() else label_for(state)


func status() -> StringName:
	return _state


func text_node() -> Label:
	return get_node_or_null(^"Row/Text") as Label


func icon_node() -> Control:
	return get_node_or_null(^"Row/Icon") as Control


## The word shown for [param state] when the caller passes no text.
static func label_for(state: StringName) -> String:
	match String(state):
		"verified":
			return Strings.STATUS_VERIFIED
		"rejected":
			return Strings.STATUS_REJECTED
		"unreachable":
			return Strings.STATUS_UNREACHABLE
	return Strings.STATUS_UNVERIFIED


## The glyph kind that carries [param state] without relying on colour. All four are in the
## appendix's canonical 22-kind set.
static func glyph_for(state: StringName) -> StringName:
	match String(state):
		"verified":
			return &"check"
		"rejected":
			return &"warning"
		"unreachable":
			return &"alert"
	return &"dot"
