extends TestSuite
## PRD-12 R10 — the budget parser, tested against fixtures instead of a live device.
##
##   [perf] fixture rows=9 PASS=8 FAIL=1
##
## `tools/perf_report.sh` collects the real numbers from the emulator; the *verdicts* are
## computed by `Perf.parse_report()`, which is what this suite pins: a healthy fixture passes
## every row, a failing fixture fails every row, an empty fixture reports MISSING (never a
## silent PASS), and the stretch/ceiling split for the APK is a WARN rather than a FAIL.

## A run inside every budget, in the exact line formats the app and the tooling print.
const GOOD := """
[perf] cold_start_ms=1840 (budget 2500) PASS
[nav] transition route=home ms=142
[nav] transition route=player ms=188
[perf] fps avg=47 min=41 p1=41 (budget 45/30) PASS
[perf] max_frame_ms=21 (budget 33) PASS
[perf] textures=7 (budget 12) PASS
[perf] nodes=642 (budget 1200) PASS
               TOTAL PSS:     153600K     TOTAL RSS:    201000K
APK size: 58.3 MB
"""

## One value over the line in every row.
const BAD := """
[perf] cold_start_ms=3120 (budget 2500) FAIL
[nav] transition route=tracker ms=421
[perf] fps avg=38 min=24 p1=24 (budget 45/30) FAIL
[perf] max_frame_ms=48 (budget 33) FAIL
[perf] textures=18 (budget 12) FAIL
[perf] nodes=1503 (budget 1200) FAIL
               TOTAL PSS:     266240K     TOTAL RSS:    301000K
APK size: 81.2 MB
"""

## The APK between the 60 MB target and the 75 MB ceiling: allowed, called out.
const OVERSIZE := """
APK size: 68.4 MB
"""


func _init() -> void:
	suite_name = "perf_budgets"


func run() -> void:
	_check_budget_table()
	_check_good_fixture()
	_check_bad_fixture()
	_check_oversize_is_warn()
	_check_empty_is_missing()


func _check_budget_table() -> void:
	begin("the P1…P8 table is R10's table")
	assert_eq(Perf.BUDGETS.size(), 9, "nine metrics are tracked")
	assert_close(float(Perf.BUDGETS["cold_start_ms"]["max"]), 2500.0, 0.1, "P1 ≤ 2500 ms")
	assert_close(float(Perf.BUDGETS["screen_switch_ms"]["max"]), 250.0, 0.1, "P2 ≤ 250 ms")
	assert_close(float(Perf.BUDGETS["fps_avg"]["min"]), 45.0, 0.1, "P4 avg ≥ 45 fps")
	assert_close(float(Perf.BUDGETS["fps_min"]["min"]), 30.0, 0.1, "P4 min ≥ 30 fps")
	assert_close(float(Perf.BUDGETS["max_frame_ms"]["max"]), 33.0, 0.1, "P5 ≤ 33 ms")
	assert_close(float(Perf.BUDGETS["mem_total_mb"]["max"]), 220.0, 0.1, "P6 ≤ 220 MB")
	assert_close(float(Perf.BUDGETS["textures"]["max"]), 12.0, 0.1, "P6 ≤ 12 textures")
	assert_close(float(Perf.BUDGETS["nodes"]["max"]), 1200.0, 0.1, "P7 ≤ 1200 nodes")
	assert_close(float(Perf.BUDGETS["apk_mb"]["max"]), 75.0, 0.1, "P8 ≤ 75 MB ceiling")
	assert_close(float(Perf.BUDGETS["apk_mb"]["target"]), 60.0, 0.1, "P8 target 60 MB")


func _check_good_fixture() -> void:
	begin("a healthy run passes every row")
	var rows := Perf.parse_report(GOOD)
	var verdicts := _verdicts(rows)
	for key in verdicts:
		assert_eq(verdicts[key], "PASS", "%s passes in a healthy run" % key)


func _check_bad_fixture() -> void:
	begin("one value over the line fails its row (or is exempt with a reason)")
	var verdicts := _verdicts(Perf.parse_report(BAD))
	for key in verdicts:
		var expected := "EXEMPT" if Perf.DEVIATIONS.has(key) else "FAIL"
		assert_eq(verdicts[key], expected, "%s is over budget" % key)
	assert_eq(int(verdicts.size()), Perf.BUDGETS.size(), "every metric has a verdict")

	begin("every documented deviation names a real metric and a reason")
	for key in Perf.DEVIATIONS:
		assert_true(Perf.BUDGETS.has(key), "deviation '%s' is a real budget" % key)
		assert_gt(float(String(Perf.DEVIATIONS[key]).length()), 20.0,
			"deviation '%s' carries a written reason" % key)


func _check_oversize_is_warn() -> void:
	begin("an APK between the target and the ceiling is a warning, not a failure")
	var rows := Perf.parse_report(OVERSIZE)
	for row in rows:
		if String(row["key"]) == "apk_mb":
			assert_eq(String(row["verdict"]), "WARN", "68.4 MB warns")
	assert_eq(_verdicts(rows).size(), Perf.BUDGETS.size(), "the other rows report MISSING")


func _check_empty_is_missing() -> void:
	begin("an empty report measures nothing and says so")
	var rows := Perf.parse_report("")
	for row in rows:
		assert_eq(String(row["verdict"]), "MISSING",
			"%s is MISSING, never a silent pass" % row["key"])
	assert_not_empty(Perf.format_table(rows), "the table prints with dashes for absent values")


func _verdicts(rows: Array[Dictionary]) -> Dictionary:
	var out := {}
	for row in rows:
		out[String(row["key"])] = String(row["verdict"])
	return out
