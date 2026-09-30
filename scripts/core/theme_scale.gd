class_name ThemeScale
extends RefCounted
## PRD-12 R6 — builds a font-size-scaled copy of a generated theme.
##
## The generated `res://resources/themes/theme_*.tres` files are the 1.0 step; dynamic type
## multiplies every `font_size` item and the root `default_font_size` by one of
## `StoreSchema.TEXT_SCALES`. Colours, styleboxes and constants are untouched, so only text
## metrics change and everything else (radii, margins, touch minimums) stays put — which is
## what makes a live `root.theme` swap re-lay-out without drifting from the design system.
##
## Pure and static: the `App` autoload calls it, the layout audit calls it, tests call it.

## Returns [param base] scaled by [param factor]. `factor == 1.0` returns the base untouched;
## a non-positive factor is refused the same way (there is no sensible scaled theme below 0).
static func scaled(base: Theme, factor: float) -> Theme:
	if base == null or factor <= 0.0 or is_equal_approx(factor, 1.0):
		return base
	var out: Theme = base.duplicate(true)
	out.default_font_size = _scale_size(base.default_font_size, factor)
	for type_name in out.get_type_list():
		for item_name in out.get_font_size_list(type_name):
			out.set_font_size(item_name, type_name,
				_scale_size(out.get_font_size(item_name, type_name), factor))
	return out


## Rounds to the nearest whole pixel; never returns 0 (a zero-size font is invisible).
static func _scale_size(size: int, factor: float) -> int:
	return maxi(1, int(round(float(size) * factor)))
