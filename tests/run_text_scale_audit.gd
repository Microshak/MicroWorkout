extends SceneTree
## PRD-12 R6's dynamic-type audit: instantiate scenes in a 1080×1920 SubViewport under a scaled
## theme and report three classes of layout failure:
##   clip     — a Label whose rect is shorter than its own minimum (text would be cut off)
##   xscroll  — a ScrollContainer that scrolls sideways (R6: content never scrolls horizontally)
##   overflow — visible content outside the viewport and not inside a scroll container
##
##   tools/audit_text_scale.sh [--text-scale 1.5] [scene…]
##
## `boot_screen` is excluded by the wrapper (it navigates away on a timer) and the debug gallery
## because it does not ship. The audit says nothing about looks; it measures geometry.
##
## The measurements themselves live in `tests/audit_geometry.gd`, shared with
## `tests/run_layout_audit.gd` (PRD-12 R3/R5) so the two audits cannot diverge.

const VIEWPORT_SIZE := Vector2i(1080, 1920)
## Entry transitions run `MOTION.screen_ms` (180 ms) plus slack, so the layout is settled before
## anything is measured — otherwise every pushed screen is caught mid-slide and every scene fails.
const SETTLE_SEC := 0.75
## Sub-pixel slack for rounded measurements.
const EPSILON := 2.0

var _scale: float = 1.5
var _theme: Theme = null
var _failures: int = 0
## Node names whose rects are printed for comparison between scales (`--rects A,B`): how the
## owner's "the illustration must not shrink" requirement is evidenced, not asserted.
var _rect_names := PackedStringArray()


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
		if text == "--rects" and i + 1 < args.size():
			_rect_names = String(args[i + 1]).split(",", false)
			i += 2
			continue
		if not text.begins_with("--"):
			scenes.append(text)
		i += 1

	var base: Theme = load("res://resources/themes/theme_dark.tres") as Theme
	if base == null:
		print("[fit] FAIL — theme_dark.tres did not load")
		quit(1)
		return
	_theme = ThemeScale.scaled(base, _scale)
	print("[fit] text-scale=%.2f default_font_size=%d scenes=%d" % [
		_scale, _theme.default_font_size, scenes.size()])

	for path in scenes:
		await _audit(path)

	if _failures == 0:
		print("[fit] RESULT: PASS (%d scene(s))" % scenes.size())
		quit(0)
	else:
		print("[fit] RESULT: FAIL (%d finding(s))" % _failures)
		quit(1)


func _audit(path: String) -> void:
	if not ResourceLoader.exists(path):
		print("[fit] FAIL %s — not found" % path)
		_failures += 1
		return
	var packed: PackedScene = load(path)
	var node: Node = packed.instantiate() if packed != null else null
	if node == null:
		print("[fit] FAIL %s — does not instantiate" % path)
		_failures += 1
		return

	var vp := SubViewport.new()
	vp.size = VIEWPORT_SIZE
	vp.disable_3d = true
	root.add_child(vp)
	vp.add_child(node)
	if node is Control:
		(node as Control).theme = _theme
	await process_frame
	await process_frame
	await create_timer(SETTLE_SEC).timeout
	await process_frame

	var found := AuditGeometry.geometry_findings(node, vp, VIEWPORT_SIZE)
	if found.is_empty():
		print("[fit] PASS %s" % path)
	else:
		for line in found:
			print("[fit] FAIL %s — %s" % [path, line])
			_failures += 1
	if not _rect_names.is_empty():
		_report_rects(node, vp, path)
	vp.queue_free()


func _report_rects(root_node: Node, vp: SubViewport, path: String) -> void:
	# `--rects '*'` dumps every Control — the tool for "what is filling this gap?". Hidden
	# nodes are included for `*` too (prefixed `hidden:`) because a container that still
	# reserves space for an invisible child is exactly the kind of thing this finds.
	var all := _rect_names.has("*")
	for node in AuditGeometry.walk(root_node):
		if not (node is Control) or (node as Control).get_viewport() != vp:
			continue
		if not all and not _rect_names.has(String(node.name)):
			continue
		var control: Control = node
		if not control.is_visible_in_tree() and not all:
			continue
		var rect := control.get_global_rect()
		var name_text := ("hidden:" if not control.is_visible_in_tree() else "") + String(node.name)
		print("[fit] rect %s %s (%.0f, %.0f, %.0f, %.0f)" % [
			path.get_file(), name_text, rect.position.x, rect.position.y,
			rect.size.x, rect.size.y])
