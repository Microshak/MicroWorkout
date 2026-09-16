extends SceneTree
## TEMPORARY PRD-07 runner — deleted once the seven suites are registered in `tests/run_tests.gd`.
##
##   timeout 250 ~/Applications/godot --headless --path . --script res://scripts/dev/_run_prd07.gd
##
## Runs only the PRD-07 suites, prints each one's name, assertion count and failures, and exits
## 0 when they all pass. It exists because `tests/run_tests.gd` is owned by the PRD-00 integrator,
## who registers the suites themselves.

const SUITES: Array[Script] = [
	preload("res://tests/suites/test_llm_providers.gd"),
	preload("res://tests/suites/test_llm_request_build.gd"),
	preload("res://tests/suites/test_plan_prompt.gd"),
	preload("res://tests/suites/test_plan_validator.gd"),
	preload("res://tests/suites/test_llm_envelope.gd"),
	preload("res://tests/suites/test_llm_ladder.gd"),
	preload("res://tests/suites/test_key_never_logged.gd"),
]


func _initialize() -> void:
	print("")
	print("══════════════════════════════════════════════════════════════")
	print("  MicroWorkout — PRD-07 suite runner")
	print("══════════════════════════════════════════════════════════════")

	var total_assertions := 0
	var total_failures := 0
	var failing_suites := 0

	for suite_script in SUITES:
		var suite: TestSuite = suite_script.new()
		suite.run()
		total_assertions += suite.total_assertions
		if suite.failures.is_empty():
			print("  ✔ %-24s %4d assertions" % [suite.suite_name, suite.total_assertions])
		else:
			failing_suites += 1
			total_failures += suite.failures.size()
			print("  ✘ %-24s %4d assertions, %d FAILED" % [
				suite.suite_name, suite.total_assertions, suite.failures.size()])
			for failure in suite.failures:
				print("      - %s" % failure)

	print("──────────────────────────────────────────────────────────────")
	print("  %d suite(s), %d assertions, %d failure(s)" % [
		SUITES.size(), total_assertions, total_failures])
	if total_failures == 0:
		print("  RESULT: PASS")
		quit(0)
	else:
		print("  RESULT: FAIL (%d suite(s) with failures)" % failing_suites)
		quit(1)
