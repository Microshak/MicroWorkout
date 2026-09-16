class_name LayoutUtil
extends RefCounted
## Portrait layout classification. Pure, so it is unit-testable (PRD-02 R17).
##
## The app is portrait-only, so "short"/"tall" describe a narrower or taller *portrait*
## viewport. No landscape layout exists and none may be added.

enum Class { SHORT = 0, NORMAL = 1, TALL = 2 }

const DESIGN_W := 1080
const DESIGN_H := 1920

const SHORT_MAX_H := 2000.0
const TALL_MIN_H := 2200.0


static func classify(viewport_h: float) -> int:
	if viewport_h < SHORT_MAX_H:
		return Class.SHORT
	if viewport_h >= TALL_MIN_H:
		return Class.TALL
	return Class.NORMAL


## Height available beyond the design canvas — absorbed by an expanding spacer so the
## primary CTA sits just above the nav bar instead of floating mid-screen.
static func extra_height(viewport_h: float) -> float:
	return maxf(0.0, viewport_h - float(DESIGN_H))


static func section_spacing(cls: int) -> int:
	match cls:
		Class.SHORT:
			return 24
		Class.TALL:
			return 40
		_:
			return 32


static func hero_ring_size(cls: int) -> int:
	match cls:
		Class.SHORT:
			return 240
		Class.TALL:
			return 360
		_:
			return 320


static func card_min_height(cls: int) -> int:
	match cls:
		Class.SHORT:
			return 96
		Class.TALL:
			return 128
		_:
			return 112
