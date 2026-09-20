class_name UiProbe
extends RefCounted
## Debug-only helper that logs the on-screen rectangle of an interactive control.
##
## Why: the Android acceptance tests drive the app with `adb shell input tap`, which needs
## *screen* coordinates, while GDScript knows *viewport* coordinates. Guessing a tap
## coordinate silently lands on empty padding and looks exactly like a passing test that
## captured the same screen twice. So the app publishes where its controls actually are,
## and `tools/tap_ui.sh` translates those rects into screen space using the bottom nav as
## a calibration anchor.
##
## Output is emitted in debug builds only, so release logcat stays clean.
## Format (greppable, one line per control):
##   [ui] rect name=<name> x=<x> y=<y> w=<w> h=<h>

static func log_rect(name: String, control: Control, settled: bool = false) -> void:
	if not OS.is_debug_build():
		return
	if control == null or not is_instance_valid(control):
		return
	var rect := control.get_global_rect()
	# `settled=1` marks a publication made after the layout has had time to stop moving. The Android
	# flows wait for that marker rather than for "a rect exists": the first publication happens a
	# frame after a refresh, which on the emulator is ~2 s and can be ~300 px out of date.
	print("[ui] rect name=%s x=%d y=%d w=%d h=%d%s" % [
		name, int(rect.position.x), int(rect.position.y), int(rect.size.x), int(rect.size.y),
		" settled=1" if settled else ""])


## Publishes a set of rects now, then again after [param delay_sec] — for screens whose controls
## keep moving after a refresh.
##
## Why this exists: `log_rect()` reports whatever the layout is at that instant. On the emulator a
## frame can take ~2 s, so a rect logged one frame after a refresh can be seconds stale, and a
## `ScrollContainer` that is still settling puts the button somewhere else by the time the test taps
## it — which reads as "the tap did nothing" while every log line looks correct. The second
## publication makes the newest line the settled one, and `tools/tap_ui.sh` reads the newest.
static func log_rects_settled(tree: SceneTree, entries: Dictionary,
		delay_sec: float = 1.5) -> void:
	log_rects(entries)
	if tree == null:
		return
	var timer := tree.create_timer(delay_sec)
	timer.timeout.connect(_log_rects_settled.bind(entries), CONNECT_ONE_SHOT)


static func _log_rects_settled(entries: Dictionary) -> void:
	for name in entries:
		log_rect(String(name), entries[name] as Control, true)


## Logs several controls in one deferred call.
static func log_rects(entries: Dictionary) -> void:
	for name in entries:
		log_rect(String(name), entries[name] as Control)
