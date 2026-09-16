extends SceneTree
## Headless unit test runner.
##
##   tools/run_tests.sh
## or directly:
##   ~/Applications/godot --headless --path . --script res://tests/run_tests.gd
##
## Exits 0 when every suite passes, 1 otherwise, so it can gate a PRD.

const SUITES: Array[Script] = [
	preload("res://tests/suites/test_boot.gd"),
	preload("res://tests/suites/test_design_tokens.gd"),
	preload("res://tests/suites/test_router.gd"),
	preload("res://tests/suites/test_layout_util.gd"),
	preload("res://tests/suites/test_store.gd"),
	preload("res://tests/suites/test_streak.gd"),
	preload("res://tests/suites/test_library.gd"),
	preload("res://tests/suites/test_library_data.gd"),
	preload("res://tests/suites/test_plan_model.gd"),
	preload("res://tests/suites/test_generator.gd"),
	preload("res://tests/suites/test_units.gd"),
	preload("res://tests/suites/test_settings_validation.gd"),
	preload("res://tests/suites/test_redaction.gd"),
	# PRD-07's seven suites exist on disk but are NOT registered yet: as of this commit
	# test_plan_validator has 12 failures, test_llm_envelope 1, test_llm_ladder 2, and
	# test_key_never_logged HANGS (which would stall the whole runner). Register them once
	# PRD-07 reports complete and all seven pass in isolation.
]


func _initialize() -> void:
	print("")
	print("══════════════════════════════════════════════════════════════")
	print("  MicroWorkout — headless test suite")
	print("══════════════════════════════════════════════════════════════")

	var total_assertions := 0
	var total_failures := 0
	var suite_failures := 0

	for suite_script in SUITES:
		var suite: TestSuite = suite_script.new()
		suite.run()
		total_assertions += suite.total_assertions
		if suite.failures.is_empty():
			print("  ✔ %-28s %3d assertions" % [suite.suite_name, suite.total_assertions])
		else:
			suite_failures += 1
			total_failures += suite.failures.size()
			print("  ✘ %-28s %3d assertions, %d FAILED" % [
				suite.suite_name, suite.total_assertions, suite.failures.size()])
			for failure in suite.failures:
				print("      - %s" % failure)

	print("──────────────────────────────────────────────────────────────")
	print("  %d suite(s), %d assertions, %d failure(s)" % [
		SUITES.size(), total_assertions, total_failures])

	if total_failures == 0:
		print("  RESULT: PASS")
		print("══════════════════════════════════════════════════════════════")
		print("")
		quit(0)
	else:
		print("  RESULT: FAIL")
		print("══════════════════════════════════════════════════════════════")
		print("")
		quit(1)
