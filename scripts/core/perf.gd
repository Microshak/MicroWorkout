class_name Perf
extends RefCounted
## PRD-12 R10 — instrumentation and the P1…P8 budget table.
##
## A static, dependency-free module (**no new autoload**: PRD-00 §4.2 fixes the list). Debug
## builds measure by default — the emulator evidence AC10 asks for is gathered from the debug
## APK, and a release build pays nothing:
##
##   [perf] cold_start_ms=1840 (budget 2500) PASS
##   [perf] fps avg=47 min=41 p1=41 (budget 45/30) PASS
##   [perf] max_frame_ms=21 (budget 33) PASS
##   [perf] textures=7 (budget 12) PASS
##
## Sampling is timer-based on purpose: PRD-12 R1 forbids `_process`-driven work, and a 1 Hz
## `Timer` answering "how fast was the last second" is enough for a steady-state budget
## (the p1 column is the worst of the five samples in a window, measured, not interpolated).
##
## [method parse_report] is the only implementation of the verdicts: `tools/perf_report.sh`
## feeds it the collected log and `tests/suites/test_perf_budgets.gd` feeds it fixtures.

## P1…P8 as R10 states them. `max` is the failure threshold; `min` is a floor where one
## applies; `target` is the stretch value that turns a pass into a warning.
const BUDGETS := {
	"cold_start_ms": {"max": 2500.0, "target": 2500.0, "label": "P1 cold start"},
	"screen_switch_ms": {"max": 250.0, "target": 250.0, "label": "P2 screen switch"},
	"fps_avg": {"min": 45.0, "target": 60.0, "label": "P3/P4 steady-state fps (avg)"},
	"fps_min": {"min": 30.0, "target": 45.0, "label": "P3/P4 steady-state fps (min)"},
	"max_frame_ms": {"max": 33.0, "target": 33.0, "label": "P5 worst flipbook frame"},
	"mem_total_mb": {"max": 220.0, "target": 220.0, "label": "P6 peak memory"},
	"textures": {"max": 12.0, "target": 12.0, "label": "P6 resident exercise textures"},
	"nodes": {"max": 1200.0, "target": 1200.0, "label": "P7 nodes per screen"},
	"apk_mb": {"max": 75.0, "target": 60.0, "label": "P8 release APK size"},
}

## Documented deviations: metric -> reason. A failing metric that appears here is reported as
## `EXEMPT` instead of FAIL, exactly like `tools/check_contrast.py`'s EXEMPT table.
##
## The fps rows and P5 are exempt on this project's emulator for one measured reason: it has no
## GPU acceleration (swiftshader/`swangle_indirect`, `-no-window`), and `EGL_emulation`'s own
## `app_time_stats` reports `avg=171.76 ms` per frame — 5.8 fps — so no frame in this emulator
## can meet a 33 ms budget. The measurements stay in the report; only the verdict is excused
## (PRD-12 §8's "record the deviation, never remove the measurement").
const DEVIATIONS: Dictionary = {
	"fps_avg": "software-GPU emulator renders ~6 fps (EGL app_time_stats avg=171.76 ms); see DECISIONS",
	"fps_min": "same emulator: start-up samples as low as 1 fps",
	"max_frame_ms": "every emulator frame takes ~170 ms; the 33 ms budget needs a GPU",
}

const FPS_WINDOW_SEC := 5
const FPS_SAMPLE_SEC := 1

## True in debug builds (and when `debug/perf_log` is set in project settings). The release
## build logs nothing.
static var enabled: bool = OS.is_debug_build() \
	or bool(ProjectSettings.get_setting("debug/perf_log", false))

static var _boot_ticks: int = 0
static var _boot_reported: bool = false
static var _samples: PackedFloat32Array = PackedFloat32Array()
static var _max_frame_ms: float = 0.0
static var _texture_count: int = -1
static var _nodes_reported: bool = false


# ------------------------------------------------------------------ marks

## Starts the cold-start clock. `App._ready()` is the first line of app code that runs.
static func begin_boot() -> void:
	if not enabled:
		return
	_boot_ticks = Time.get_ticks_msec()
	_boot_reported = false


## Stops the clock and prints P1 once. Home calls this on its first real frame —
## "tap → first Home frame", the budget's own definition.
static func end_boot() -> void:
	if not enabled or _boot_reported or _boot_ticks == 0:
		return
	_boot_reported = true
	var elapsed := Time.get_ticks_msec() - _boot_ticks
	print("[perf] cold_start_ms=%d (budget %d) %s" % [
		elapsed, int(BUDGETS["cold_start_ms"]["max"]),
		"PASS" if float(elapsed) <= float(BUDGETS["cold_start_ms"]["max"]) else "FAIL"])


## A named point in time, for profiling a flow by hand: `Perf.mark("preview_open")`.
static func mark(name: String) -> void:
	if not enabled:
		return
	print("[perf] mark=%s t_ms=%d" % [name, Time.get_ticks_msec()])


# ------------------------------------------------------------------ fps window

## Attaches the 1 Hz sampler to [param host] (the shell). One timer, no per-frame work: each
## timeout folds `Engine.get_frames_per_second()` into the five-sample window and every fifth
## sample prints the window's avg / min / p1.
static func attach(host: Node) -> void:
	if not enabled or host == null or host.has_node(^"PerfSampler"):
		return
	var timer := Timer.new()
	timer.name = "PerfSampler"
	timer.wait_time = float(FPS_SAMPLE_SEC)
	timer.autostart = true
	timer.timeout.connect(_sample_fps)
	host.add_child(timer)


static func _sample_fps() -> void:
	_samples.append(Engine.get_frames_per_second())
	while _samples.size() > FPS_WINDOW_SEC:
		_samples.remove_at(0)
	if _samples.size() < FPS_WINDOW_SEC:
		return
	var total := 0.0
	var worst := INF
	for value in _samples:
		total += value
		worst = minf(worst, value)
	var average := total / float(_samples.size())
	print("[perf] fps avg=%d min=%d p1=%d (budget %d/%d) %s" % [
		int(round(average)), int(round(worst)), int(round(worst)),
		int(BUDGETS["fps_avg"]["min"]), int(BUDGETS["fps_min"]["min"]),
		verdict("fps_avg", average)])


# ------------------------------------------------------------------ session facts

## The worst frame time seen while the flipbook plays (P5). The player reports the frame time
## around each advance, which is the moment R10 worries about.
static func note_frame_ms(milliseconds: float) -> void:
	if not enabled:
		return
	_max_frame_ms = maxf(_max_frame_ms, milliseconds)


## Ends the flipbook measurement window and prints P5. A session with no report stays silent.
static func end_session() -> void:
	if not enabled or _max_frame_ms <= 0.0:
		return
	print("[perf] max_frame_ms=%d (budget %d) %s" % [
		int(round(_max_frame_ms)), int(BUDGETS["max_frame_ms"]["max"]),
		verdict("max_frame_ms", _max_frame_ms)])
	_max_frame_ms = 0.0


## How many exercise textures are currently resident (P6's LRU ceiling). Consecutive identical
## counts are printed once: the value only means something when it changes.
static func report_textures(count: int) -> void:
	if not enabled or count == _texture_count:
		return
	_texture_count = count
	var state := "PASS" if float(count) <= float(BUDGETS["textures"]["max"]) else "FAIL"
	print("[perf] textures=%d (budget %d) %s" % [count, int(BUDGETS["textures"]["max"]), state])


## The live node count for one screen (P7), read from the engine's own monitor. Printed once per
## run: the number is a property of the screen, not of how often it re-renders.
static func report_nodes() -> void:
	if not enabled or _nodes_reported:
		return
	_nodes_reported = true
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	print("[perf] nodes=%d (budget %d) %s" % [
		nodes, int(BUDGETS["nodes"]["max"]),
		"PASS" if float(nodes) <= float(BUDGETS["nodes"]["max"]) else "FAIL"])


# ------------------------------------------------------------------ verdicts

## The live verdict for one metric: `PASS`, `FAIL` or `EXEMPT` (see [constant DEVIATIONS]).
static func verdict(key: String, value: float) -> String:
	var budget: Dictionary = BUDGETS[key]
	var passed := true
	if budget.has("max"):
		passed = value <= float(budget["max"])
	if budget.has("min"):
		passed = passed and value >= float(budget["min"])
	if passed:
		return "PASS"
	return "EXEMPT" if DEVIATIONS.has(key) else "FAIL"


## Extracts every measurable value out of a collected log and returns one row per metric:
## `{key, label, value, verdict, detail}` with verdict `PASS`, `WARN`, `FAIL`, `EXEMPT` or
## `MISSING`. This is the parser AC10 and `test_perf_budgets.gd` share.
static func parse_report(text: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var values := {
		"cold_start_ms": _last_float(text, "cold_start_ms="),
		"screen_switch_ms": _max_transition_ms(text),
		"fps_avg": _last_float(text, "fps avg="),
		"fps_min": _value_after_within(text, "fps avg=", " min="),
		"max_frame_ms": _last_float(text, "max_frame_ms="),
		"mem_total_mb": _max_meminfo_mb(text),
		"textures": _last_float(text, "textures="),
		"nodes": _last_float(text, "[perf] nodes="),
		"apk_mb": _last_float(text, "APK size:"),
	}
	for key in BUDGETS:
		rows.append(_verdict_row(key, values.get(key, null)))
	return rows


static func _verdict_row(key: String, value: Variant) -> Dictionary:
	var budget: Dictionary = BUDGETS[key]
	var row := {"key": key, "label": String(budget["label"]), "value": value, "verdict": "MISSING"}
	if value == null:
		return row
	var number := float(value)
	var passed := true
	if budget.has("max"):
		passed = number <= float(budget["max"])
	if budget.has("min"):
		passed = passed and number >= float(budget["min"])
	if not passed and DEVIATIONS.has(key):
		row["verdict"] = "EXEMPT"
		row["detail"] = String(DEVIATIONS[key])
		return row
	if not passed:
		row["verdict"] = "FAIL"
		return row
	# A pass that misses the stretch target is a WARN, not a failure: only max-type budgets
	# carry one (P8: ≤ 60 MB target, ≤ 75 MB ceiling). A min-type budget passes on its floor —
	# AC10's emulator line is `fps avg=47 min=41 (budget 45/30) PASS`, and 60 fps remains the
	# desktop ideal that a desktop run reports on its own.
	var target := float(budget.get("target", number))
	if budget.has("max") and not budget.has("min") and number > target:
		row["verdict"] = "WARN"
	else:
		row["verdict"] = "PASS"
	return row


static func format_table(rows: Array[Dictionary]) -> String:
	var lines := PackedStringArray(["METRIC                           VALUE      VERDICT"])
	for row in rows:
		var value := "—" if row["value"] == null else str(row["value"])
		lines.append("%-32s %-10s %s%s" % [
			String(row["label"]), value, String(row["verdict"]),
			"" if not row.has("detail") else " (%s)" % row["detail"]])
	return "\n".join(lines)


static func _last_float(text: String, needle: String) -> Variant:
	var index := text.rfind(needle)
	if index < 0:
		return null
	return _float_after(text, index + needle.length())


## The number after [param needle] inside the same line as [param prefix] — for the two-value
## `fps avg=47 min=41` line, where `min` never appears as a standalone token.
static func _value_after_within(text: String, prefix: String, needle: String) -> Variant:
	for line in text.split("\n"):
		var start := line.find(prefix)
		if start < 0:
			continue
		var index := line.find(needle, start + prefix.length() - 1)
		if index < 0:
			continue
		var value: Variant = _float_after(line, index + needle.length())
		if value != null:
			return value
	return null


## P2: the largest `ms=` in any `[nav] transition route=… ms=N` line.
static func _max_transition_ms(text: String) -> Variant:
	var best: Variant = null
	for line in text.split("\n"):
		if not line.contains("transition route=") or not line.contains(" ms="):
			continue
		var index := line.find(" ms=")
		var value: Variant = _float_after(line, index + " ms=".length())
		if value != null:
			best = value if best == null else maxf(float(best), float(value))
	return best


## Parses the first number at or after [param from], skipping whitespace (the tools' output is
## aligned with padding: `TOTAL PSS:     153600K`).
static func _float_after(text: String, from: int) -> Variant:
	var start := from
	while start < text.length() and text[start] == " ":
		start += 1
	var end := start
	if end < text.length() and text[end] == "-":
		end += 1
	var digits := end
	while end < text.length() and (text[end].is_valid_int() or text[end] == "."):
		end += 1
	if end == digits:
		return null
	return text.substr(start, end - start).to_float()


## The largest `TOTAL PSS:` reading in an `adb shell dumpsys meminfo` dump, in MB.
static func _max_meminfo_mb(text: String) -> Variant:
	var best: Variant = null
	for line in text.split("\n"):
		var index := line.find("TOTAL PSS:")
		if index < 0:
			continue
		var value: Variant = _float_after(line, index + "TOTAL PSS:".length())
		if value != null:
			var megabytes := float(value) / 1024.0
			best = megabytes if best == null else maxf(float(best), megabytes)
	return best
