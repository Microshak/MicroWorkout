extends SceneTree
## Headless unit test runner.
##
##   tools/run_tests.sh
## or directly:
##   ~/Applications/godot --headless --path . --script res://tests/run_tests.gd
##
## Exits 0 when every suite passes, 1 otherwise, so it can gate a PRD.

## Suite paths, **loaded lazily** inside [method _run_all] instead of `preload()`ed.
##
## Why: at the moment this script is parsed the autoloads are not registered yet, so a suite that
## names an autoload (`Store`, `Library`) fails to compile there — measured as
## `Identifier not found: Library` when PRD-11's screen suite was preloaded. `load()` runs once
## the tree is live, where the identifiers resolve; `run_suite.gd` has always taken this route.
const SUITES: PackedStringArray = [
	"res://tests/suites/test_boot.gd",
	"res://tests/suites/test_design_tokens.gd",
	"res://tests/suites/test_theme_scale.gd",
	"res://tests/suites/test_router.gd",
	"res://tests/suites/test_layout_util.gd",
	"res://tests/suites/test_store.gd",
	"res://tests/suites/test_streak.gd",
	"res://tests/suites/test_library.gd",
	"res://tests/suites/test_library_data.gd",
	"res://tests/suites/test_plan_model.gd",
	"res://tests/suites/test_generator.gd",
	"res://tests/suites/test_units.gd",
	"res://tests/suites/test_settings_validation.gd",
	"res://tests/suites/test_redaction.gd",
	"res://tests/suites/test_llm_providers.gd",
	"res://tests/suites/test_llm_request_build.gd",
	"res://tests/suites/test_plan_prompt.gd",
	"res://tests/suites/test_plan_validator.gd",
	"res://tests/suites/test_llm_envelope.gd",
	"res://tests/suites/test_llm_ladder.gd",
	"res://tests/suites/test_key_never_logged.gd",
	"res://tests/suites/test_wizard_state.gd",
	"res://tests/suites/test_plan_schedule.gd",
	"res://tests/suites/test_home_state.gd",
	"res://tests/suites/test_session_run.gd",
	"res://tests/suites/test_progression.gd",
	"res://tests/suites/test_month_grid.gd",
	"res://tests/suites/test_area_balance.gd",
	"res://tests/suites/test_tracker_screen.gd",
	"res://tests/suites/test_motion.gd",
	"res://tests/suites/test_feedback.gd",
	"res://tests/suites/test_perf_budgets.gd",
]


func _initialize() -> void:
	# Suites run from a deferred call, not from `_initialize()` itself: while `_initialize()`
	# runs, the root Window is not inside the tree yet, so a node added there never receives
	# `_ready` (measured). A screen-level suite — PRD-11's `test_tracker_screen.gd` instantiates
	# the Tracker into a `SubViewport` — needs a live tree, and every pure suite behaves
	# identically one frame later.
	_run_all.call_deferred()


func _run_all() -> void:
	print("")
	print("══════════════════════════════════════════════════════════════")
	print("  MicroWorkout — headless test suite")
	print("══════════════════════════════════════════════════════════════")

	var total_assertions := 0
	var total_failures := 0
	var suite_failures := 0

	for path in SUITES:
		var suite_script: Script = load(path)
		# A suite that does not compile must not take the run down with it. `load()` still returns a
		# GDScript object for a file with parse errors — only `can_instantiate()` is false — and
		# without this guard the failed `.new()` errored and the SceneTree never quit: a hung runner
		# instead of an actionable "this suite does not compile" line.
		if suite_script == null or not suite_script.can_instantiate():
			print("  ✘ %s — does not compile" % path)
			suite_failures += 1
			total_failures += 1
			continue
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
