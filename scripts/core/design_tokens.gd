class_name DesignTokens
extends RefCounted
## Single source of truth for every design token.
##
## Values follow the frozen interface appendix (the appendix wins over any earlier spec text).
## The theme resources in res://resources/themes/ are GENERATED from this file by
## scripts/dev/build_themes.gd — never hand-edit them. tests/suites/test_design_tokens.gd
## fails the suite if they drift.
##
## Every value here is static and pure: no scene-tree access, no autoloads, so the whole
## design system is unit-testable headless.

## Dark palette — the default theme (owner decision D9).
const DARK := {
	"bg": "#0F1116",
	"surface": "#171A21",
	"surface_alt": "#1F232C",
	"outline": "#2C313C",
	"outline_strong": "#616B7A",
	"primary": "#FF6B35",
	"primary_dim": "#C94F22",
	"secondary": "#31C6F7",
	"success": "#35D08A",
	"warning": "#FFB020",
	"danger": "#FF5C5C",
	"text": "#F4F6FA",
	"text_muted": "#9AA5B6",
	"text_disabled": "#5C6675",
	"on_accent": "#12151C",
}

## Light palette — only the keys that differ; accents are identical in both modes.
const LIGHT_OVERRIDES := {
	"bg": "#F6F7FB",
	"surface": "#FFFFFF",
	"surface_alt": "#EEF1F7",
	"outline": "#D8DEE9",
	"outline_strong": "#7E8A9C",
	"text": "#12151C",
	"text_muted": "#5A6472",
	# A raw accent used as light-theme TEXT fails WCAG AA (1.83:1–3.03:1), so light mode
	# gets dedicated darker text/icon colours. Fills still use the accents themselves.
	"primary_text_light": "#C2410C",
	"secondary_text_light": "#0B6E8F",
	"success_text_light": "#0F7A4F",
	"warning_text_light": "#8A5A00",
	"danger_text_light": "#C62828",
}

## Type scale, px at the 1080-wide design resolution.
const TYPE := {
	"display": 64, "h1": 44, "h2": 34, "h3": 26,
	"body": 22, "body_small": 19, "caption": 16, "button": 24,
}

## Spacing scale. No ad-hoc pixel numbers anywhere in the UI.
const SPACE := {"xs": 4, "sm": 8, "md": 12, "lg": 16, "xl": 24, "xxl": 32, "xxxl": 48}

const RADIUS := {
	"chip": 12, "card": 18, "sheet": 28, "button": 28, "bar": 9, "calendar_cell": 16,
}

const TOUCH_MIN := 88
const GUTTER := 24
const NAV_BAR_HEIGHT := 132
const TOP_BAR_HEIGHT := 132

## Motion constants, milliseconds unless noted.
const MOTION := {
	"screen_ms": 180,
	"screen_phase_ms": 90,
	"press_ms": 90,
	"press_scale": 0.97,
	"toast_in_ms": 120,
	"toast_out_ms": 180,
	"toast_hold_ms": 2600,
	"double_back_ms": 2000,
	"frame_ms": 455,
	"pop_ms": 200,
	"celebration_ms": 1600,
	"stagger_ms": 40,
	"stagger_max": 8,
	"ring_fill_ms": 420,
	"reduced_ms": 30,
}

## Safe-area fallback (design px) used when Android reports no cutout.
## Tuned against the first emulator screenshot; see DECISIONS.md ADR-09.
const SAFE_FALLBACK := Vector4(0.0, 72.0, 0.0, 48.0)

const MODE_DARK := "dark"
const MODE_LIGHT := "light"
const MODES: PackedStringArray = [MODE_DARK, MODE_LIGHT]


## Returns the full token dictionary for [param mode] (falls back to dark).
static func palette(mode: String) -> Dictionary:
	if mode == MODE_LIGHT:
		var merged := DARK.duplicate()
		merged.merge(LIGHT_OVERRIDES, true)
		return merged
	return DARK


static func hex_to_color(hex: String) -> Color:
	return Color.from_string(hex, Color.MAGENTA)


## Looks up one token. Unknown tokens are a programming error and return magenta so the
## mistake is visible on screen rather than silently invisible.
static func color(mode: String, token: String) -> Color:
	var pal := palette(mode)
	if not pal.has(token):
		push_error("[tokens] unknown token '%s' for mode '%s'" % [token, mode])
		return Color.MAGENTA
	return hex_to_color(pal[token])


static func is_valid_token(token: String) -> bool:
	return DARK.has(token)


## The only colour permitted on top of an accent fill (appendix §4).
static func on_accent(mode: String) -> Color:
	return color(mode, "on_accent")


## The colour to use when an accent must be rendered as TEXT or an ICON (not as a fill).
##
## In dark mode the raw accent is readable on our surfaces. In light mode it is not: a raw
## accent on white is only 1.83:1-3.03:1, far below the 4.5:1 that body text needs. Light mode
## therefore resolves through the dedicated `*_text_light` tokens, which sit at 5.18:1-6.5:1.
## Appendix §4.3 rule 2: fills keep the accents, text never uses a raw accent in light mode.
static func accent_text(mode: String, accent: String) -> Color:
	if mode != MODE_LIGHT:
		return color(mode, accent)
	var light_key := "%s_text_light" % accent
	if not palette(mode).has(light_key):
		# Every accent ships a light-mode counterpart (asserted by test_design_tokens), so
		# this is unreachable defensive code. It falls back to the raw accent deliberately
		# and warns, rather than returning magenta.
		push_warning("[tokens] no light-mode text colour for accent '%s'" % accent)
		return color(mode, accent)
	return color(mode, light_key)


static func accent_tokens() -> PackedStringArray:
	return PackedStringArray(["primary", "secondary", "success", "warning", "danger"])


## WCAG 2.1 relative luminance.
static func relative_luminance(c: Color) -> float:
	var channels := [c.r, c.g, c.b]
	var linear: Array[float] = []
	for channel in channels:
		var v: float = channel
		linear.append(v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4))
	return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


## WCAG 2.1 contrast ratio, always >= 1.0.
static func contrast_ratio(a: Color, b: Color) -> float:
	var la := relative_luminance(a)
	var lb := relative_luminance(b)
	var lighter := maxf(la, lb)
	var darker := minf(la, lb)
	return (lighter + 0.05) / (darker + 0.05)


## Every text-on-background pair that must clear WCAG AA for body text (4.5:1).
static func contrast_pairs() -> Array:
	return [
		["text", "bg"], ["text", "surface"], ["text", "surface_alt"],
		["text_muted", "bg"], ["text_muted", "surface"], ["text_muted", "surface_alt"],
		["on_accent", "primary"], ["on_accent", "secondary"], ["on_accent", "success"],
	]
