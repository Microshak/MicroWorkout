extends SceneTree
## Single-suite runner — the fast loop while implementing.
##
##   tools/run_suite.sh test_session_run
##
## `tools/run_tests.sh` takes minutes because it runs every suite; this runs exactly one, which is
## what makes a red/green cycle on one new module bearable. It deliberately shares `TestSuite` with
## the full runner, so a suite that passes here passes there.

const SUITES: PackedStringArray = [
	"test_boot",
	"test_design_tokens",
	"test_router",
	"test_layout_util",
	"test_store",
	"test_streak",
	"test_library",
	"test_library_data",
	"test_plan_model",
	"test_generator",
	"test_units",
	"test_settings_validation",
	"test_redaction",
	"test_llm_providers",
	"test_llm_request_build",
	"test_plan_prompt",
	"test_plan_validator",
	"test_llm_envelope",
	"test_llm_ladder",
	"test_key_never_logged",
	"test_wizard_state",
	"test_plan_schedule",
	"test_home_state",
	"test_session_run",
	"test_progression",
	"test_month_grid",
	"test_area_balance",
	"test_plan_screen",
	"test_tracker_screen",
	"test_motion",
	"test_feedback",
	"test_perf_budgets",
]


func _initialize() -> void:
	# See `run_tests.gd`: suites run once the tree is live, so a scene-level suite can
	# instantiate a screen and have its `_ready` run.
	_run_all.call_deferred()


func _run_all() -> void:
	var wanted := ""
	for argument in OS.get_cmdline_user_args():
		var text := String(argument)
		if not text.begins_with("--"):
			wanted = text
	if wanted.is_empty():
		print("usage: tools/run_suite.sh <suite> [more…]")
		print("known: %s" % ", ".join(SUITES))
		quit(2)
		return

	var names := PackedStringArray()
	for argument in OS.get_cmdline_user_args():
		var text := String(argument)
		if not text.begins_with("--"):
			names.append(text)

	var total_assertions := 0
	var total_failures := 0
	for name in names:
		if not SUITES.has(name):
			print("  ✘ %s — not a known suite (add it to SUITES here)" % name)
			total_failures += 1
			continue
		var path := "res://tests/suites/%s.gd" % name
		if not ResourceLoader.exists(path):
			print("  ✘ %s — %s does not exist" % [name, path])
			total_failures += 1
			continue
		var script: Script = load(path)
		# A suite that does not compile must not take the run down with it. `load()` still returns a
		# GDScript object for a file with parse errors — only `can_instantiate()` is false — and
		# without this guard the failed `.new()` errored and the SceneTree never quit: a hung runner
		# instead of an actionable "this suite does not compile" line.
		if script == null or not script.can_instantiate():
			print("  ✘ %s — %s does not compile" % [name, path])
			total_failures += 1
			continue
		var suite: TestSuite = script.new()
		suite.run()
		total_assertions += suite.total_assertions
		if suite.failures.is_empty():
			print("  ✔ %-28s %3d assertions" % [suite.suite_name, suite.total_assertions])
		else:
			total_failures += suite.failures.size()
			print("  ✘ %-28s %3d assertions, %d FAILED" % [
				suite.suite_name, suite.total_assertions, suite.failures.size()])
			for failure in suite.failures:
				print("      - %s" % failure)

	print("  %d suite(s), %d assertions, %d failure(s)" % [
		names.size(), total_assertions, total_failures])
	print("  RESULT: %s" % ("PASS" if total_failures == 0 else "FAIL"))
	quit(0 if total_failures == 0 else 1)
