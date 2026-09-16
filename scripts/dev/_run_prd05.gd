extends SceneTree

const SUITES: Array[Script] = [
	preload("res://tests/suites/test_plan_model.gd"),
	preload("res://tests/suites/test_generator.gd"),
]

func _initialize() -> void:
	print("")
	print("PRD-05 — plan model & generator suites")
	var total_assertions := 0
	var total_failures := 0
	for suite_script in SUITES:
		var suite: TestSuite = suite_script.new()
		suite.run()
		total_assertions += suite.total_assertions
		total_failures += suite.failures.size()
		if suite.failures.is_empty():
			print("  ✔ %-16s %3d assertions 0 failures" % [suite.suite_name, suite.total_assertions])
		else:
			print("  ✘ %-16s %3d assertions %d FAILURES" % [suite.suite_name, suite.total_assertions, suite.failures.size()])
			for failure in suite.failures:
				print("      - %s" % failure)
	print("  SUITES %d  ASSERTIONS %d  FAILURES %d" % [SUITES.size(), total_assertions, total_failures])
	print("  RESULT: %s" % ("PASS" if total_failures == 0 else "FAIL"))
	quit(0 if total_failures == 0 else 1)
