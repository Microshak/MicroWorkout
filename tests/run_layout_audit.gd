extends SceneTree
## PRD-12 R3/R5 — the build-time interaction audit: every interactive control in every shipping
## screen is at least 88×88 px (R3) and carries a non-empty accessible name (R5), at
## `--text-scale 1.0` **and** `1.5` (R6's layout-safety re-run).
##
##   tools/audit_layout.sh
##   tools/audit_layout.sh --text-scale 1.0 res://scenes/ui/home_tab.tscn
##
## Findings are the same four geometry classes `tools/audit_text_scale.sh` reports (clip,
## xscroll, unreachable, overflow — shared via `tests/audit_geometry.gd`) plus two this audit
## owns:
##
##   touchtarget <node> (WxH)   an interactive control smaller than 88 px on either axis
##   noname <node> (Class)      an interactive control with no accessible name
##   absolute <node> (x, y)     a Control laid out by literal coordinates (R6)
##
## The R3 allow-list is empty by construction: a control that must look smaller is wrapped in
## `A11y.pad()`, which stretches it to the floor, rather than excepted here.
##
## `boot_screen` never reaches a measurable layout inside a SubViewport (its 900 ms anti-flash
## timer navigates the tree) and the debug gallery does not ship; the wrapper filters both.

## Entry transitions run `MOTION.screen_ms` (180 ms) plus slack — the same settle the PRD-12 R6
## audit uses, so both audits measure the same moment in a screen's life.
const SETTLE_SEC := 0.75

var _scale: float = 1.0
var _theme: Theme = null
var _findings: int = 0
var _touch_findings: int = 0
var _name_findings: int = 0


func _initialize() -> void:
	var scenes := PackedStringArray()
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var text := String(args[i])
		if text == "--text-scale" and i + 1 < args.size():
			_scale = float(args[i + 1])
			i += 2
			continue
		if not text.begins_with("--"):
			scenes.append(text)
		i += 1

	var base: Theme = load("res://resources/themes/theme_dark.tres") as Theme
	if base == null:
		print("[layout] FAIL — theme_dark.tres did not load")
		quit(1)
		return
	_theme = ThemeScale.scaled(base, _scale)
	print("[layout] text-scale=%.2f default_font_size=%d scenes=%d" % [
		_scale, _theme.default_font_size, scenes.size()])

	for path in scenes:
		await _audit(path)

	if _findings == 0:
		print("[layout] RESULT: PASS (%d scene(s))" % scenes.size())
		quit(0)
	else:
		print("[layout] RESULT: FAIL (%d finding(s): %d touch-target, %d accessible-name)" % [
			_findings, _touch_findings, _name_findings])
		quit(1)


func _audit(path: String) -> void:
	if not ResourceLoader.exists(path):
		print("[layout] FAIL %s — not found" % path)
		_findings += 1
		return
	var packed: PackedScene = load(path)
	var node: Node = packed.instantiate() if packed != null else null
	if node == null:
		print("[layout] FAIL %s — does not instantiate" % path)
		_findings += 1
		return

	var vp := SubViewport.new()
	vp.size = AuditGeometry.VIEWPORT_SIZE
	vp.disable_3d = true
	root.add_child(vp)
	vp.add_child(node)
	if node is Control:
		(node as Control).theme = _theme
	await process_frame
	await process_frame
	await create_timer(SETTLE_SEC).timeout
	await process_frame

	var found := AuditGeometry.geometry_findings(node, vp)
	found.append_array(AuditGeometry.interaction_findings(node, vp))
	found.append_array(AuditGeometry.absolute_findings(node, vp))

	if found.is_empty():
		print("[layout] PASS %s" % path)
	else:
		for line in found:
			if line.begins_with("touchtarget"):
				_touch_findings += 1
			elif line.begins_with("noname"):
				_name_findings += 1
			print("[layout] FAIL %s %s" % [path, line])
			_findings += 1
	vp.queue_free()
