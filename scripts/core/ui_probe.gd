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

static func log_rect(name: String, control: Control) -> void:
	if not OS.is_debug_build():
		return
	if control == null or not is_instance_valid(control):
		return
	var rect := control.get_global_rect()
	print("[ui] rect name=%s x=%d y=%d w=%d h=%d" % [
		name, int(rect.position.x), int(rect.position.y), int(rect.size.x), int(rect.size.y)])


## Logs several controls in one deferred call.
static func log_rects(entries: Dictionary) -> void:
	for name in entries:
		log_rect(String(name), entries[name] as Control)
