extends Control
## Drawn, asset-free icon set — PRD-02 R8, appendix §3.
##
## Icons are geometry, not textures: every shape is authored inside a normalised 24×24 box
## and scaled to [member size], so an icon is resolution independent, ships no binary asset
## and cannot produce a missing-glyph box (master plan §9 keeps the built-in font).
##
## Colour is never hard-coded. It is read from the theme's `Glyph` type variation, which is
## what makes a runtime dark↔light switch repaint live icons through
## [constant NOTIFICATION_THEME_CHANGED].
##
## Adding an icon is one entry in [constant ICONS]; nothing else changes.

## The design box every icon is authored in (R8: `p = pt / 24 * size`).
const BOX := 24.0

## Points used for a full or partial arc. R8 fixes this at 48.
const ARC_POINTS := 48

## Icon table. Each entry may carry any of:
##   "strokes": [{"pts": [Vector2, …], "closed": bool, "w3": bool, "fill": bool}, …]
##              `w3` strokes use width 3 (box units) instead of [member stroke_width];
##              `closed` joins the last point back to the first and can be solid-filled by
##              [member filled]; `fill` lets an open outline participate in [member filled].
##   "arcs":    [{"c": Vector2, "r": float, "deg0": float, "deg1": float}, …]
##              `deg1 - deg0 >= 360` draws a full circle (0 … TAU).
##   "fills":   [{"rect": Rect2} | {"circle_c": Vector2, "circle_r": float} | {"poly": [Vector2, …]}, …]
##
## R8 defines 16 kinds; the appendix §3 canonical set is 22, so `chevron_down`, `dot`,
## `trophy`, `calendar`, `alert` and `dumbbell` are authored here in the same 24-box language.
const ICONS: Dictionary = {
	"home": {
		"strokes": [
			{"pts": [Vector2(3, 11), Vector2(12, 3), Vector2(21, 11)], "fill": true},
			{"pts": [Vector2(6, 10), Vector2(6, 20), Vector2(18, 20), Vector2(18, 10)]},
			{"pts": [Vector2(10, 20), Vector2(10, 15), Vector2(14, 15), Vector2(14, 20)]},
		],
	},
	"plan": {
		"strokes": [
			{"pts": [Vector2(4, 5), Vector2(20, 5), Vector2(20, 20), Vector2(4, 20)], "closed": true, "fill": true},
			{"pts": [Vector2(4, 9), Vector2(20, 9)]},
			{"pts": [Vector2(8, 3), Vector2(8, 7)]},
			{"pts": [Vector2(16, 3), Vector2(16, 7)]},
		],
		"fills": [
			{"rect": Rect2(8, 13, 2, 2)},
			{"rect": Rect2(14, 13, 2, 2)},
		],
	},
	"tracker": {
		"strokes": [
			{"pts": [Vector2(5, 20), Vector2(5, 12)], "w3": true},
			{"pts": [Vector2(10, 20), Vector2(10, 8)], "w3": true},
			{"pts": [Vector2(15, 20), Vector2(15, 15)], "w3": true},
			{"pts": [Vector2(20, 20), Vector2(20, 5)], "w3": true},
		],
	},
	"settings": {
		"strokes": [
			{"pts": [Vector2(4, 8), Vector2(20, 8)]},
			{"pts": [Vector2(4, 12), Vector2(20, 12)]},
			{"pts": [Vector2(4, 16), Vector2(20, 16)]},
		],
		"fills": [
			{"circle_c": Vector2(9, 8), "circle_r": 2.5},
			{"circle_c": Vector2(15, 12), "circle_r": 2.5},
			{"circle_c": Vector2(7, 16), "circle_r": 2.5},
		],
	},
	"check": {
		"strokes": [
			{"pts": [Vector2(5, 12), Vector2(10, 17), Vector2(19, 7)], "w3": true},
		],
	},
	"chevron_right": {
		"strokes": [
			{"pts": [Vector2(9, 4), Vector2(16, 12), Vector2(9, 20)], "w3": true},
		],
	},
	"chevron_left": {
		"strokes": [
			{"pts": [Vector2(15, 4), Vector2(8, 12), Vector2(15, 20)], "w3": true},
		],
	},
	"chevron_down": {
		"strokes": [
			{"pts": [Vector2(4, 9), Vector2(12, 16), Vector2(20, 9)], "w3": true},
		],
	},
	"play": {
		"fills": [
			{"poly": [Vector2(8, 4), Vector2(21, 12), Vector2(8, 20)]},
		],
	},
	"pause": {
		"fills": [
			{"rect": Rect2(6, 4, 5, 16)},
			{"rect": Rect2(14, 4, 5, 16)},
		],
	},
	"plus": {
		"strokes": [
			{"pts": [Vector2(12, 5), Vector2(12, 19)], "w3": true},
			{"pts": [Vector2(5, 12), Vector2(19, 12)], "w3": true},
		],
	},
	"close": {
		"strokes": [
			{"pts": [Vector2(6, 6), Vector2(18, 18)], "w3": true},
			{"pts": [Vector2(18, 6), Vector2(6, 18)], "w3": true},
		],
	},
	"timer": {
		"arcs": [
			{"c": Vector2(12, 13), "r": 8.0},
		],
		"strokes": [
			{"pts": [Vector2(12, 13), Vector2(12, 8)]},
			{"pts": [Vector2(9, 3), Vector2(15, 3)]},
		],
	},
	"refresh": {
		"arcs": [
			{"c": Vector2(12, 12), "r": 8.0, "deg0": 40.0, "deg1": 320.0},
		],
		"fills": [
			{"poly": [Vector2(17, 3), Vector2(21, 7), Vector2(16, 9)]},
		],
	},
	"flame": {
		"strokes": [
			{
				"pts": [
					Vector2(12, 3), Vector2(16, 9), Vector2(18, 13), Vector2(17, 17),
					Vector2(12, 20), Vector2(7, 17), Vector2(6, 13), Vector2(9, 8),
					Vector2(11, 12), Vector2(12, 3),
				],
				"closed": true,
				"fill": true,
			},
		],
	},
	"info": {
		"arcs": [
			{"c": Vector2(12, 12), "r": 9.0},
		],
		"strokes": [
			{"pts": [Vector2(12, 11), Vector2(12, 17)], "w3": true},
		],
		"fills": [
			{"circle_c": Vector2(12, 7.5), "circle_r": 1.5},
		],
	},
	"warning": {
		"strokes": [
			{"pts": [Vector2(12, 4), Vector2(21, 20), Vector2(3, 20)], "closed": true, "fill": true},
			{"pts": [Vector2(12, 10), Vector2(12, 15)]},
		],
		"fills": [
			{"circle_c": Vector2(12, 17.5), "circle_r": 1.2},
		],
	},
	"dot": {
		"fills": [
			{"circle_c": Vector2(12, 12), "circle_r": 3.0},
		],
	},
	"trophy": {
		"strokes": [
			{"pts": [Vector2(7, 4), Vector2(8, 12), Vector2(16, 12), Vector2(17, 4)]},
			{"pts": [Vector2(7, 5), Vector2(4, 7), Vector2(5, 10), Vector2(7, 11)]},
			{"pts": [Vector2(17, 5), Vector2(20, 7), Vector2(19, 10), Vector2(17, 11)]},
			{"pts": [Vector2(12, 12), Vector2(12, 17)]},
			{"pts": [Vector2(8, 18), Vector2(16, 18)]},
		],
	},
	"calendar": {
		"strokes": [
			{"pts": [Vector2(4, 6), Vector2(20, 6), Vector2(20, 20), Vector2(4, 20)], "closed": true, "fill": true},
			{"pts": [Vector2(4, 10), Vector2(20, 10)]},
			{"pts": [Vector2(8, 3), Vector2(8, 7)]},
			{"pts": [Vector2(16, 3), Vector2(16, 7)]},
		],
		"fills": [
			{"circle_c": Vector2(9, 15), "circle_r": 1.5},
			{"circle_c": Vector2(15, 15), "circle_r": 1.5},
		],
	},
	"alert": {
		"arcs": [
			{"c": Vector2(12, 12), "r": 9.0},
		],
		"strokes": [
			{"pts": [Vector2(12, 6.5), Vector2(12, 13)], "w3": true},
		],
		"fills": [
			{"circle_c": Vector2(12, 16.5), "circle_r": 1.6},
		],
	},
	"dumbbell": {
		"strokes": [
			{"pts": [Vector2(8, 12), Vector2(16, 12)], "w3": true},
		],
		"fills": [
			{"rect": Rect2(3, 8, 2.5, 8)},
			{"rect": Rect2(18.5, 8, 2.5, 8)},
			{"rect": Rect2(6.5, 9.5, 2, 5)},
			{"rect": Rect2(15.5, 9.5, 2, 5)},
		],
	},
}

## Kinds already reported through [method push_warning] — R8: warn once per unknown kind.
static var _warned_kinds: Dictionary = {}

## Icon to draw. Unknown kinds draw nothing and warn once.
@export var kind: StringName = &"":
	set(value):
		if kind == value:
			return
		kind = value
		queue_redraw()

## Draws with the theme's `color_active` instead of `color` (active nav tab, toggle on).
@export var active: bool = false:
	set(value):
		if active == value:
			return
		active = value
		queue_redraw()

## Renders closed outlines solid. R8's base set is outline-first; a filled variant is a
## nav/selected affordance and is expressed here rather than as a second icon table.
@export var filled: bool = false:
	set(value):
		if filled == value:
			return
		filled = value
		queue_redraw()

## Stroke width in 24-box units (R8: scaled by `size.x / 24` at draw time).
@export var stroke_width: float = 2.0:
	set(value):
		if is_equal_approx(stroke_width, value):
			return
		stroke_width = value
		queue_redraw()


## True when [param k] is in the icon table. Lets tests and tools assert coverage without
## tripping the unknown-kind warning.
static func has_kind(k: StringName) -> bool:
	return ICONS.has(String(k))


## Every supported kind, sorted — the canonical appendix §3 set (22).
static func kinds() -> PackedStringArray:
	var out := PackedStringArray()
	for key: String in ICONS.keys():
		out.append(key)
	out.sort()
	return out


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_RESIZED \
			or what == NOTIFICATION_VISIBILITY_CHANGED:
		queue_redraw()


func _draw() -> void:
	# `&""` is the "no icon" default (see `stat_tile`, which hides its icon when the caller
	# passes no kind) — an empty slot, not a typo, so it stays silent.
	if kind == &"":
		return
	var icon: Dictionary = ICONS.get(String(kind), {})
	if icon.is_empty():
		_warn_unknown(kind)
		return

	var color := _current_color()
	var stroke := stroke_width * size.x / BOX
	var stroke_w3 := 3.0 * size.x / BOX
	var radius_scale := minf(size.x, size.y) / BOX

	for arc: Dictionary in icon.get("arcs", []):
		var center := _p(arc["c"])
		var arc_radius: float = arc["r"] * radius_scale
		var deg0: float = arc.get("deg0", 0.0)
		var deg1: float = arc.get("deg1", 360.0)
		if deg1 - deg0 >= 360.0:
			draw_arc(center, arc_radius, 0.0, TAU, ARC_POINTS, color, stroke, true)
		else:
			draw_arc(center, arc_radius, deg_to_rad(deg0), deg_to_rad(deg1), ARC_POINTS, color, stroke, true)

	for shape: Dictionary in icon.get("strokes", []):
		var pts := PackedVector2Array()
		for pt: Vector2 in shape["pts"]:
			pts.append(_p(pt))
		var width: float = stroke_w3 if shape.get("w3", false) else stroke
		var closed: bool = shape.get("closed", false)
		if filled and (closed or shape.get("fill", false)):
			draw_colored_polygon(pts, color)
		if closed:
			var loop := pts.duplicate()
			loop.append(pts[0])
			draw_polyline(loop, color, width, true)
		else:
			draw_polyline(pts, color, width, true)

	for fill: Dictionary in icon.get("fills", []):
		if fill.has("rect"):
			draw_rect(_r(fill["rect"]), color, true)
		elif fill.has("circle_c"):
			# Solid dot: draw_circle keeps it round at a single radius, which a thick
			# draw_arc can only fake.
			draw_circle(_p(fill["circle_c"]), float(fill["circle_r"]) * radius_scale, color, true, -1.0, true)
		elif fill.has("poly"):
			var poly := PackedVector2Array()
			for pt: Vector2 in fill["poly"]:
				poly.append(_p(pt))
			draw_colored_polygon(poly, color)


## R8 colour rule: invisible-tree state wins, then [member active], else the default colour.
func _current_color() -> Color:
	if not is_visible_in_tree():
		return get_theme_color(&"color_disabled", &"Glyph")
	if active:
		return get_theme_color(&"color_active", &"Glyph")
	return get_theme_color(&"color", &"Glyph")


func _warn_unknown(value: StringName) -> void:
	var key := String(value)
	if _warned_kinds.has(key):
		return
	_warned_kinds[key] = true
	push_warning("[ui] unknown glyph: %s" % key)


## Box point → pixel point (R8 scaling).
func _p(pt: Vector2) -> Vector2:
	return Vector2(pt.x / BOX * size.x, pt.y / BOX * size.y)


## Box rect → pixel rect.
func _r(rect: Rect2) -> Rect2:
	return Rect2(_p(rect.position), _p(rect.size))
