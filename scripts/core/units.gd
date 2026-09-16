class_name Units
extends RefCounted
## The **only** place in MicroWorkout that converts or formats a weight or a length — PRD-06 R3.
##
## Why this exists as a class of pure statics: if two screens each own a `kg`/`lb` conversion,
## they disagree within a release. Every screen (Settings, the onboarding preview, PRD-09's
## Home, PRD-10's player, PRD-11's Tracker) calls these functions and none of them holds a
## conversion factor, a unit suffix or a rounding step of its own. `tests/suites/test_units.gd`
## and the `scripts/ui/` literal scan in `tests/suites/test_redaction.gd` both enforce that.
##
## Two rules are load-bearing:
##
## 1. **No locale-aware formatting.** `String.num()`/`String.num_int64()` always print a `.`
##    decimal separator, so an Android device set to a comma-decimal locale shows `22.5 kg`
##    rather than `22,5 kg` (R3).
## 2. **Increments are the smallest plate jump**, 5 lb and 2.5 kg. [method round_to_increment]
##    takes a value **already expressed in the target unit** — that is the only reading under
##    which `display_weight(45.36, "lb") == "100 lb"` and `display_weight(20.4, "kg") ==
##    "20 kg"` are both true. Use [method to_display] / [method to_kg] to cross the boundary.
##
## Everything here is static and pure: no scene tree, no autoloads, no I/O.

## Exact international avoirdupois pound. Never redefined anywhere else (R3).
const LB_PER_KG := 2.2046226218

## Exact international inch.
const CM_PER_IN := 2.54

const LB := "lb"
const KG := "kg"
const IN := "in"
const CM := "cm"

## Smallest loadable jump per unit — one pair of 2.5 lb plates, one 2.5 kg plate (R3).
const LB_INCREMENT := 5.0
const KG_INCREMENT := 2.5

## `{"lb","kg"}` — the closed set `settings.units` may hold.
const UNITS: PackedStringArray = [LB, KG]

## `{"in","cm"}` — the closed set [method display_length_cm] accepts.
const LENGTH_UNITS: PackedStringArray = [IN, CM]

## Returned by [method parse_weight] for anything that is not a number (R3).
const GARBAGE := -1.0


# ------------------------------------------------------------------ conversion (R3)

static func kg_to_lb(kg: float) -> float:
	return kg * LB_PER_KG


static func lb_to_kg(lb: float) -> float:
	return lb / LB_PER_KG


## kg -> the number a user reads in [param units]. The inverse of [method to_kg].
static func to_display(kg: float, units: String) -> float:
	return kg_to_lb(kg) if units == LB else kg


## A number the user typed in [param units] -> kg. The inverse of [method to_display].
static func to_kg(value: float, units: String) -> float:
	return lb_to_kg(value) if units == LB else value


## The loadable increment for [param units] (R3). An unknown unit rounds like kg.
static func increment_for(units: String) -> float:
	return LB_INCREMENT if units == LB else KG_INCREMENT


## Rounds a **display-unit** value to the nearest loadable increment, halves away from zero
## (`round()` in GDScript already does that, so `2.5 -> 5.0` and `-2.5 -> -5.0`).
static func round_to_increment(value: float, units: String) -> float:
	var step := increment_for(units)
	if step <= 0.0:
		return value
	return round(value / step) * step


## The number a user reads, rounded to the increment in [param units].
static func rounded_display(kg: float, units: String) -> float:
	return round_to_increment(to_display(kg, units), units)


# ------------------------------------------------------------------ formatting (R3)

## `"45 lb"` / `"22.5 kg"` — rounded to the increment first, whole values with no decimal.
static func display_weight(kg: float, units: String) -> String:
	return "%s %s" % [num_text(rounded_display(kg, units)), unit_label(units)]


## `"32 in"` / `"81 cm"`. Lengths carry no plate increment, so they round to whole units.
static func display_length_cm(cm: float, units: String) -> String:
	var value := cm / CM_PER_IN if units == IN else cm
	return "%s %s" % [num_text(round(value)), length_label(units)]


## The weight unit suffix. Anything that is not [constant KG] reads as [constant LB], so a
## corrupt `settings.units` can never reach the screen as an empty string.
static func unit_label(units: String) -> String:
	return KG if units == KG else LB


static func length_label(units: String) -> String:
	return IN if units == IN else CM


## `100.0 -> "100"`, `22.5 -> "22.5"`. Locale-independent by construction (R3).
static func num_text(value: float) -> String:
	if is_equal_approx(value, round(value)):
		return String.num_int64(int(round(value)))
	return String.num(value, 1)


# ------------------------------------------------------------------ parsing (R3)

## Inverse of [method display_weight]: strips a `lb`/`kg` suffix (with or without a space,
## singular or plural), accepts a leading `+`, and returns **kg**. Anything that is not a
## non-negative number yields [constant GARBAGE] (`-1.0`), which no real weight can equal.
static func parse_weight(text: String, units: String) -> float:
	var cleaned := text.strip_edges()
	if cleaned.begins_with("+"):
		cleaned = cleaned.substr(1).strip_edges()
	var lower := cleaned.to_lower()
	for suffix in ["lbs", "kgs", "lb", "kg"]:
		if lower.ends_with(suffix):
			cleaned = cleaned.substr(0, cleaned.length() - suffix.length()).strip_edges()
			break
	if cleaned.is_empty() or not _is_number(cleaned):
		return GARBAGE
	var value := float(cleaned)
	if not is_finite(value) or value < 0.0:
		return GARBAGE
	return to_kg(value, units)


# ------------------------------------------------------------------ validation (R3)

static func is_valid_units(u: String) -> bool:
	return UNITS.has(u)


static func is_valid_length_units(u: String) -> bool:
	return LENGTH_UNITS.has(u)


## `""` when [param u] is legal, else the PRD-06 R7 message for the field.
static func validate_units_value(u: String) -> String:
	return "" if is_valid_units(u) else "Pick lb or kg."


# ------------------------------------------------------------------ internals

static func _is_number(text: String) -> bool:
	var dots := 0
	for i in text.length():
		var c := text[i]
		if c == ".":
			dots += 1
			if dots > 1:
				return false
		elif c < "0" or c > "9":
			return false
	return true
