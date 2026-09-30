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

	var found := _findings(node, vp)
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
	for node in _walk(root_node):
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


func _findings(root_node: Node, vp: SubViewport) -> PackedStringArray:
	var out := PackedStringArray()
	for node in _walk(root_node):
		if not (node is Control):
			continue
		var control: Control = node
		if not control.is_visible_in_tree() or control.get_viewport() != vp:
			# Invisible, or inside an embedded Window (a dialog) — not this viewport's layout.
			continue

		if control is Label or control is RichTextLabel:
			var minimum := control.get_combined_minimum_size().y
			if control.size.y + EPSILON < minimum:
				out.append("clip %s (%.0f < %.0f)" % [
					control.get_path(), control.size.y, minimum])

		if control is ScrollContainer:
			var scroll: ScrollContainer = control
			if scroll.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
				var bar := scroll.get_h_scroll_bar()
				if bar != null and bar.max_value > bar.page + 0.5:
					out.append("xscroll %s (max=%.0f page=%.0f)" % [
						control.get_path(), bar.max_value, bar.page])
			# R6's reachability rule: when the content fits (nothing to scroll), a child drawn
			# outside the scroller's rect can never be brought into view — it is simply lost.
			# This is how Home kept ghost gaps: the body's content was 938 px while the week
			# strip was staged at y≈5 700, invisible and unreachable, with no scroll range that
			# could ever reveal it.
			var vbar := scroll.get_v_scroll_bar()
			var scrollable := vbar != null and vbar.max_value > vbar.page + 0.5
			if not scrollable:
				var bounds := scroll.get_global_rect()
				for inner in _walk(scroll):
					if not (inner is Control) or inner == scroll:
						continue
					var ic: Control = inner
					if not ic.is_visible_in_tree() or ic.get_viewport() != vp \
							or _nearest_scroll(ic) != scroll:
						continue
					var irect := ic.get_global_rect()
					if irect.end.y > bounds.end.y + EPSILON \
							or irect.position.y < bounds.position.y - EPSILON:
						out.append("unreachable %s (y %.0f..%.0f, scroller %.0f..%.0f)" % [
							ic.get_path(), irect.position.y, irect.end.y,
							bounds.position.y, bounds.end.y])

		if not _inside_scroll(control):
			var rect := control.get_global_rect()
			if rect.end.y > VIEWPORT_SIZE.y + EPSILON or rect.position.y < -EPSILON \
					or rect.end.x > VIEWPORT_SIZE.x + EPSILON or rect.position.x < -EPSILON:
				out.append("overflow %s rect=(%.0f, %.0f, %.0f, %.0f)" % [
					control.get_path(), rect.position.x, rect.position.y,
					rect.size.x, rect.size.y])
	return out


func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out


func _inside_scroll(control: Control) -> bool:
	var parent := control.get_parent()
	while parent != null:
		if parent is ScrollContainer:
			return true
		parent = parent.get_parent()
	return false


## The nearest ScrollContainer ancestor, or null. Used to attribute a losing child to the scroll
## container whose viewport it should be visible in.
func _nearest_scroll(control: Control) -> ScrollContainer:
	var parent := control.get_parent()
	while parent != null:
		if parent is ScrollContainer:
			return parent
		parent = parent.get_parent()
	return null
