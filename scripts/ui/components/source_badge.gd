extends PanelContainer
## Plan-source badge — PRD-08 R11 (appendix §3.2: `source_badge.tscn` is PRD-08's; PRD-09 reuses
## it on the today card).
##
## Says *who wrote the plan* the owner is looking at, and nothing else: PRD-07's own copy decides
## what a fallback means, and the reason line under the badge is `result.user_message` verbatim.
##
## **Why the colours are built here rather than taken from a variation.** R11 asks for
## `success`/`warning` at 18 % fill with a matching 2 px border. The theme's variation set is
## frozen (`test_design_tokens.gd` asserts its exact size) and the colour-override theme API is
## forbidden (appendix §4.3 rule 8), so the badge builds its `StyleBoxFlat` from `DesignTokens`
## tokens — the same `add_theme_stylebox_override` route PRD-06's onboarding progress dots and
## PRD-08's area chips already ship.
##
## **Why the tint is not the only signal** (rule 6): every state carries a drawn glyph *and* a
## word. The glyph stays on the theme's muted colour rather than the accent, because a raw accent
## as a graphical mark on a light tint fails WCAG 1.4.11 — the text is `BodySmall`/`text` on a
## tint of the same surface, which is readable in both modes.

const SOURCE_LLM := "llm"
const SOURCE_BUILTIN := "builtin"

## R11's two badge strings. `{P}` is the provider display name PRD-07 owns.
const TEXT_LLM := "Written by %s"
const TEXT_BUILTIN := "Built on-device"

## Shown when the caller knows the source but not which provider wrote it.
const FALLBACK_PROVIDER := "your AI provider"

## R11: radius 12, min height 56.
const RADIUS := 12
const MIN_HEIGHT := 56.0

## R11: "at 18 %".
const FILL_ALPHA := 0.18

const GLYPH_LLM := &"check"
const GLYPH_BUILTIN := &"alert"
const GLYPH_UNKNOWN := &"dot"

var _source: String = ""
var _provider: String = ""
## The `mode/accent` pair the panel style was built for. Same reason as `area_chip`: a
## `add_theme_stylebox_override()` call notifies this node with `NOTIFICATION_THEME_CHANGED`, so
## without a recorded key the re-apply would recurse forever. Setting the key *before* the call
## makes the re-entrant pass a no-op whether the notification is immediate or deferred.
var _styled_key: String = ""


func _ready() -> void:
	custom_minimum_size.y = maxf(custom_minimum_size.y, MIN_HEIGHT)
	_apply()
	# Same reason as `area_chip`: a root-`Window.theme` swap does not notify descendants in
	# 4.7.2, so the app's own `theme_changed` signal is what re-renders on a dark↔light switch.
	if not App.theme_changed.is_connected(_on_app_theme_changed):
		App.theme_changed.connect(_on_app_theme_changed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply()


# ------------------------------------------------------------------ R11 API

## `llm` → `"Written by <provider>"`, `builtin` → `"Built on-device"` (the appendix's frozen
## signature). [param provider] is additive and optional: PRD-07's overlay resolves the display
## name from `plan.provider` through its own preset table and passes it in, so this component
## keeps no provider table of its own. An unknown source empties the badge and hides it, which
## is what a `busy`/`cancelled` result (no plan) needs.
func set_source(source: String, provider: String = "") -> void:
	_source = source
	_provider = provider.strip_edges()
	_apply()


## The source last handed to [method set_source]. Not named `source()`: the appendix's
## `set_source(source: String)` parameter name is frozen, and a same-named accessor would be
## reported as shadowing it.
func source_key() -> String:
	return _source


## The exact word on the badge — what a screenshot diff and a test both read.
func badge_text() -> String:
	match _source:
		SOURCE_LLM:
			return TEXT_LLM % (_provider if not _provider.is_empty() else FALLBACK_PROVIDER)
		SOURCE_BUILTIN:
			return TEXT_BUILTIN
	return ""


func text_node() -> Label:
	return get_node_or_null(^"Row/Text") as Label


func glyph_node() -> Control:
	return get_node_or_null(^"Row/Glyph") as Control


func style_box() -> StyleBoxFlat:
	var box := get_theme_stylebox(&"panel", &"PanelContainer")
	return box as StyleBoxFlat


# ------------------------------------------------------------------ rendering

## A dark↔light switch: drop the memoised style key and rebuild from the tokens.
func _on_app_theme_changed(_mode: String) -> void:
	_styled_key = ""
	_apply()

func _apply() -> void:
	var accent := _accent_token()
	var text := badge_text()
	visible = not text.is_empty()

	var label := text_node()
	if label != null:
		label.text = text

	var glyph := glyph_node()
	if glyph != null:
		glyph.set(&"kind", _glyph_kind())
		glyph.set(&"active", false)

	var key := "%s/%s" % [App.theme_mode, accent]
	if key != _styled_key:
		_styled_key = key
		add_theme_stylebox_override(&"panel", _badge_style(accent))


## `success` for a provider-written plan, `warning` for the built-in generator. The two are the
## appendix's own pairing for "went to plan" vs "fell back", and R11's table is verbatim.
func _accent_token() -> String:
	match _source:
		SOURCE_LLM:
			return "success"
		SOURCE_BUILTIN:
			return "warning"
	return "outline"


func _glyph_kind() -> StringName:
	match _source:
		SOURCE_LLM:
			return GLYPH_LLM
		SOURCE_BUILTIN:
			return GLYPH_BUILTIN
	return GLYPH_UNKNOWN


func _badge_style(accent_token: String) -> StyleBoxFlat:
	var mode := App.theme_mode
	var accent := DesignTokens.color(mode, accent_token)
	var box := StyleBoxFlat.new()
	if accent_token == "outline":
		box.bg_color = DesignTokens.color(mode, "surface_alt")
		box.border_color = accent
	else:
		box.bg_color = Color(accent.r, accent.g, accent.b, FILL_ALPHA)
		box.border_color = accent
	box.set_border_width_all(2)
	box.set_corner_radius_all(RADIUS)
	box.content_margin_left = 16.0
	box.content_margin_right = 16.0
	box.content_margin_top = 8.0
	box.content_margin_bottom = 8.0
	return box
