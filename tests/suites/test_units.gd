extends TestSuite
## PRD-06 R3/R14 — the one place that converts or formats a weight or a length.
##
## Everything here is pure: no autoloads, no scene tree, no I/O (suites run under `--script`,
## where autoloads are constructed only after `SceneTree._initialize()` returns).
##
## Two notes on the PRD's own test list:
##
## 1. R14's round-trip formula is written as `round_to_increment(kg, u)`, i.e. it rounds the **kg**
##    value by the target unit's step. That cannot be what `display_weight()` does — it converts
##    to the target unit first and then rounds, otherwise `display_weight(45.36, "lb")` could not
##    be `"100 lb"`. The round-trip is therefore asserted against `Units.to_kg(Units.
##    round_to_increment(Units.to_display(kg, u), u))`, which is exactly the value
##    `parse_weight(display_weight(kg, u), u)` must reproduce.
## 2. Everything that a device could get wrong by locale (a comma decimal separator) is asserted
##    as a `.` explicitly.

func _init() -> void:
	suite_name = "units"


func run() -> void:
	_test_exact_factor()
	_test_increments()
	_test_display_weight()
	_test_display_length()
	_test_parse_weight()
	_test_round_trip()
	_test_labels_and_validation()
	_test_no_locale_formatting()
	_test_no_ui_formatting()
	_test_format_helper()


func _test_exact_factor() -> void:
	begin("kg↔lb is an exact round trip")
	for value in [0.0, 2.5, 45.0, 100.0, 102.5, 1000.0]:
		assert_close(Units.kg_to_lb(Units.lb_to_kg(value)), value, 1e-9,
			"kg_to_lb(lb_to_kg(%s))" % str(value))
		assert_close(Units.lb_to_kg(Units.kg_to_lb(value)), value, 1e-9,
			"lb_to_kg(kg_to_lb(%s))" % str(value))

	begin("the factor is the international pound")
	assert_close(Units.LB_PER_KG, 2.2046226218, 1e-10, "LB_PER_KG")
	assert_close(Units.lb_to_kg(1.0), 0.45359237, 1e-8, "1 lb in kg")
	assert_close(Units.kg_to_lb(1.0), 2.2046226218, 1e-9, "1 kg in lb")
	assert_close(Units.CM_PER_IN, 2.54, 1e-12, "1 in in cm")


func _test_increments() -> void:
	begin("increments are one plate jump per unit")
	assert_close(Units.increment_for("lb"), 5.0, 1e-9, "lb step")
	assert_close(Units.increment_for("kg"), 2.5, 1e-9, "kg step")

	begin("rounding is to the increment, halves away from zero")
	assert_close(Units.round_to_increment(43.0, "lb"), 45.0, 1e-9, "43 lb → 45 lb")
	assert_close(Units.round_to_increment(42.5, "lb"), 45.0, 1e-9, "42.5 lb → 45 lb (half up)")
	assert_close(Units.round_to_increment(42.4, "lb"), 40.0, 1e-9, "42.4 lb → 40 lb")
	assert_close(Units.round_to_increment(1.25, "kg"), 2.5, 1e-9, "1.25 kg → 2.5 kg (half up)")
	assert_close(Units.round_to_increment(3.74, "kg"), 2.5, 1e-9, "3.74 kg → 2.5 kg")
	assert_close(Units.round_to_increment(3.75, "kg"), 5.0, 1e-9, "3.75 kg → 5.0 kg")
	assert_close(Units.round_to_increment(-1.25, "kg"), -2.5, 1e-9, "negative halves go away from 0")
	assert_close(Units.round_to_increment(0.0, "kg"), 0.0, 1e-9, "zero stays zero")


func _test_display_weight() -> void:
	begin("R14's display cases")
	assert_eq(Units.display_weight(45.36, "lb"), "100 lb", "45.36 kg renders as 100 lb")
	assert_eq(Units.display_weight(20.0, "kg"), "20 kg", "whole kg has no decimal")
	assert_eq(Units.display_weight(20.4, "kg"), "20 kg", "20.4 kg rounds to the 2.5 kg step")

	begin("display formatting")
	assert_eq(Units.display_weight(20.4116566497, "lb"), "45 lb", "45 lb is a whole 5 lb step")
	assert_eq(Units.display_weight(Units.lb_to_kg(135.0), "lb"), "135 lb", "the wizard's example")
	assert_eq(Units.display_weight(Units.lb_to_kg(135.0), "kg"), "60 kg", "the same weight in kg")
	assert_eq(Units.display_weight(0.0, "kg"), "0 kg", "zero")
	assert_eq(Units.display_weight(11.34, "kg"), "12.5 kg", "half-step prints one decimal")
	assert_eq(Units.display_weight(1.0, "lb"), "0 lb", "below half a step rounds down")


func _test_display_length() -> void:
	begin("R14's length case")
	assert_eq(Units.display_length_cm(81.28, "in"), "32 in", "81.28 cm is exactly 32 in")
	assert_eq(Units.display_length_cm(81.0, "cm"), "81 cm", "cm lengths stay cm")
	assert_eq(Units.display_length_cm(2.54, "in"), "1 in", "one inch")
	assert_eq(Units.display_length_cm(0.0, "cm"), "0 cm", "zero length")
	assert_true(Units.is_valid_length_units("in"), "in is a length unit")
	assert_true(Units.is_valid_length_units("cm"), "cm is a length unit")
	assert_false(Units.is_valid_length_units("ft"), "ft is not")
	assert_eq(Units.length_label("in"), "in", "length label in")
	assert_eq(Units.length_label("nonsense"), "cm", "unknown length units read as cm")


func _test_parse_weight() -> void:
	begin("parse_weight is the inverse of display_weight")
	assert_close(Units.parse_weight("45 lb", "lb"), 20.4116566497, 0.005, "45 lb in kg")
	assert_close(Units.parse_weight("45lb", "lb"), 20.4116566497, 0.005, "no space")
	assert_close(Units.parse_weight("45 lbs", "lb"), 20.4116566497, 0.005, "plural")
	assert_close(Units.parse_weight("+45 lb", "lb"), 20.4116566497, 0.005, "leading plus")
	assert_close(Units.parse_weight("  22.5 kg  ", "kg"), 22.5, 1e-9, "whitespace and kg suffix")
	assert_close(Units.parse_weight("22.5", "kg"), 22.5, 1e-9, "no suffix at all")
	assert_close(Units.parse_weight("100", "lb"), 45.359237, 1e-6, "100 lb in kg")

	begin("garbage yields the sentinel")
	assert_close(Units.parse_weight("abc", "lb"), -1.0, 1e-9, "letters")
	assert_close(Units.parse_weight("", "lb"), -1.0, 1e-9, "empty")
	assert_close(Units.parse_weight("lb", "lb"), -1.0, 1e-9, "suffix only")
	assert_close(Units.parse_weight("4.5.6 kg", "kg"), -1.0, 1e-9, "two decimal points")
	assert_close(Units.parse_weight("-45 lb", "lb"), -1.0, 1e-9, "negative weight")
	assert_close(Units.parse_weight("1,5 kg", "kg"), -1.0, 1e-9, "comma decimal is not a number")
	assert_true(Units.GARBAGE < 0.0, "the sentinel is negative so it can never be a weight")


func _test_round_trip() -> void:
	begin("display → parse round-trips within one increment (200 pseudo-random values)")
	# A local LCG keeps this deterministic and independent of the engine RNG, so a failure is
	# always reproducible from the printed index.
	var state := 987654321
	var worst_miss := 0.0
	var worst_index := -1
	var checked := 0
	for i in 200:
		state = (state * 1103515245 + 12345) & 0x7fffffff
		var kg := float(state % 200000) / 1000.0        # 0.000 .. 199.999 kg
		for units in Units.UNITS:
			var text := Units.display_weight(kg, units)
			var parsed := Units.parse_weight(text, units)
			var expected := Units.to_kg(Units.round_to_increment(Units.to_display(kg, units), units),
				units)
			var miss := absf(parsed - expected)
			checked += 1
			if miss > worst_miss:
				worst_miss = miss
				worst_index = i
			if miss > 0.01:
				failures.append("round trip #%d units=%s %s (from %f kg): parsed %f expected %f" % [
					i, units, text, kg, parsed, expected])
			total_assertions += 1
	print("[units] round-trip checked=%d worst=%.6f (at #%d)" % [checked, worst_miss, worst_index])
	assert_eq(checked, 400, "both units were exercised for all 200 values")


func _test_labels_and_validation() -> void:
	begin("unit labels")
	assert_eq(Units.unit_label("lb"), "lb", "lb label")
	assert_eq(Units.unit_label("kg"), "kg", "kg label")
	assert_eq(Units.unit_label("stone"), "lb", "an unknown set of units reads as lb, never empty")

	begin("unit validation (R7)")
	assert_true(Units.is_valid_units("lb"), "lb is valid")
	assert_true(Units.is_valid_units("kg"), "kg is valid")
	assert_false(Units.is_valid_units("stone"), "stone is not")
	assert_false(Units.is_valid_units("LB"), "case matters")
	assert_false(Units.is_valid_units(""), "empty is not")
	assert_eq(Units.validate_units_value("kg"), "", "valid units produce no message")
	assert_eq(Units.validate_units_value("stone"), "Pick lb or kg.", "R7's exact message")
	assert_eq(Units.UNITS.size(), 2, "the closed set has two members")


## R11's storage formatter rides along here because it lives in the same "one place per kind of
## number" contract as [Units]: no screen divides by 1024 either.
func _test_format_helper() -> void:
	begin("R11's byte table")
	assert_eq(Format.bytes(0), "0 B", "zero")
	assert_eq(Format.bytes(-5), "0 B", "a negative count is not a size")
	assert_eq(Format.bytes(1), "1 B", "one byte")
	assert_eq(Format.bytes(1023), "1023 B", "just under a kilobyte")
	assert_eq(Format.bytes(1024), "1.0 KB", "exactly a kilobyte")
	assert_eq(Format.bytes(1536), "1.5 KB", "a kilobyte and a half")
	assert_eq(Format.bytes(1048575), "1024.0 KB", "just under a megabyte")
	assert_eq(Format.bytes(1048576), "1.0 MB", "exactly a megabyte")
	assert_eq(Format.bytes(43253760), "41.2 MB", "megabytes to one decimal")
	assert_false(Format.bytes(1536).contains(","), "no locale decimal separator")

	begin("the storage line the Settings tab shows (R11)")
	var line := Format.storage_line(42190, {
		"settings": 2150, "plans": 32153, "history": 7885, "backups": 0,
	})
	assert_eq(line, "Storage: 41.2 KB used (settings.json 2.1 KB \u00b7 plans.json 31.4 KB "
		+ "\u00b7 history.json 7.7 KB \u00b7 backups 0 B)", "R11's example line, verbatim")
	assert_eq(Format.storage_line(0, {}), "Storage: 0 B used (settings.json 0 B \u00b7 "
		+ "plans.json 0 B \u00b7 history.json 0 B \u00b7 backups 0 B)", "an empty directory")

	begin("relative timestamps (R11)")
	assert_eq(Format.relative_time(""), "never", "an unset timestamp")
	assert_eq(Format.relative_time("<null>"), "never", "a stringified null")
	assert_eq(Format.relative_time("tomorrow"), "never", "garbage")
	var now := Dates.now_iso8601(true)
	assert_eq(Format.relative_time(now), "just now", "now")
	var ages := {
		"5 min ago": 300, "12 min ago": 720, "3 h ago": 3 * 3600, "2 days ago": 2 * 86400,
	}
	for expected in ages:
		var stamp := _iso_seconds_ago(int(ages[expected]))
		assert_eq(Format.relative_time(stamp), String(expected), "%s seconds ago" % ages[expected])
	assert_eq(Format.relative_time(_iso_seconds_ago(86400)), "1 day ago", "singular day")
	assert_eq(Format.relative_time(_iso_seconds_ago(-30)), "just now",
		"a stamp in the future is clock skew, not time travel")


## A UTC ISO-8601 stamp [param seconds] in the past, built from the real clock so the relative
## comparison cannot drift with the date the suite happens to run on.
func _iso_seconds_ago(seconds: int) -> String:
	var stamp := int(Time.get_unix_time_from_system()) - seconds
	return Time.get_datetime_string_from_unix_time(stamp, true) + "Z"


## R13's hard rule with a scanner behind it: no file under `scripts/ui/` or `scenes/ui/` may hold
## a unit suffix, a conversion factor or the exact pound constant. This is the suite version of
## `grep -rnE '" (lb|kg)"|2\.2046|2\.54' scripts/ui/`, which PRD-06 AC13 runs by hand.
func _test_no_ui_formatting() -> void:
	begin("no screen formats a weight or a length (R13)")
	var patterns: PackedStringArray = [
		"\" lb", "\" kg", "2.2046", "2.54", "LB_PER_KG", "CM_PER_IN", "0.45359237",
	]
	var violations := PackedStringArray()
	var files := 0
	for root in ["res://scripts/ui", "res://scenes/ui"]:
		files += _scan(root, patterns, violations)
	print("[units] scanned %d UI file(s) for unit literals, %d violation(s)" % [
		files, violations.size()])
	assert_gt(float(files), 10.0, "the scan found the UI tree")
	assert_eq(violations.size(), 0, "violations: %s" % ", ".join(violations))

	begin("the scanner would catch a screen that did its own math")
	assert_true(_matches("var label := str(kg) + \" lb\"", patterns),
		"a lb suffix literal matches")
	assert_true(_matches("return kg * 2.2046226218", patterns), "the pound factor matches")
	assert_false(_matches("return Units.display_weight(kg, App.units())", patterns),
		"calling Units does not")


func _matches(line: String, patterns: PackedStringArray) -> bool:
	for pattern in patterns:
		if line.contains(pattern):
			return true
	return false


## Walks [param path] recursively, counting `.gd`/`.tscn` files and appending `path:line` for any
## line containing one of [param patterns].
func _scan(path: String, patterns: PackedStringArray, violations: PackedStringArray) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	var count := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := "%s/%s" % [path, entry]
		if dir.current_is_dir():
			count += _scan(child, patterns, violations)
		elif ["gd", "tscn", "tres"].has(child.get_extension().to_lower()):
			count += 1
			_scan_file(child, patterns, violations)
		entry = dir.get_next()
	dir.list_dir_end()
	return count


func _scan_file(path: String, patterns: PackedStringArray, violations: PackedStringArray) -> void:
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var number := 0
	while not file.eof_reached():
		var line := file.get_line()
		number += 1
		if _matches(line, patterns):
			violations.append("%s:%d: %s" % [path, number, line.strip_edges()])
	file.close()


func _test_no_locale_formatting() -> void:
	begin("formatting never depends on the device locale")
	assert_false(Units.display_weight(45.36, "lb").contains(","), "no comma in a lb weight")
	assert_false(Units.display_weight(11.34, "kg").contains(","), "no comma in a kg weight")
	assert_false(Units.display_length_cm(81.28, "in").contains(","), "no comma in a length")
	assert_eq(Units.num_text(22.5), "22.5", "decimal point is always '.'")
	assert_eq(Units.num_text(100.0), "100", "whole numbers lose the decimal entirely")
	assert_eq(Units.num_text(0.0), "0", "zero")
	assert_eq(Units.num_text(-5.0), "-5", "negative whole")
	var big := Units.num_text(1234567.0)
	assert_eq(big, "1234567", "no thousands separator")
