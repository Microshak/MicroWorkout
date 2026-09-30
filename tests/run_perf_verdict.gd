extends SceneTree
## PRD-12 R10 — prints the P1…P8 verdict table for a collected log.
##
##   ~/Applications/godot --headless --path . --script res://tests/run_perf_verdict.gd \
##       -- build/perf/20260930-150000.txt
##
## `tools/perf_report.sh` calls this; the verdicts themselves live in `Perf.parse_report()`
## (one implementation, exercised by `tests/suites/test_perf_budgets.gd`). Exit 0 when every
## row is PASS/WARN/EXEMPT; 1 when any row FAILs; 2 when a file cannot be read.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("[perf] usage: run_perf_verdict.gd -- <report file>")
		quit(2)
		return
	var path := String(args[0])
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		print("[perf] FAIL — cannot read %s" % path)
		quit(2)
		return

	var rows := Perf.parse_report(text)
	print("[perf] report=%s" % path)
	print(Perf.format_table(rows))

	var failed := PackedStringArray()
	var missing := PackedStringArray()
	for row in rows:
		match String(row["verdict"]):
			"FAIL":
				failed.append(String(row["key"]))
			"MISSING":
				missing.append(String(row["key"]))
	if not missing.is_empty():
		print("[perf] NOTE — not measured in this report: %s" % ", ".join(missing))
	if not failed.is_empty():
		print("[perf] RESULT: FAIL — over budget: %s" % ", ".join(failed))
		quit(1)
		return
	print("[perf] RESULT: PASS (%d metric(s))" % rows.size())
	quit(0)
