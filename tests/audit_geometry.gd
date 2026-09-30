class_name AuditGeometry
extends RefCounted
## The geometry walk both layout audits share — PRD-12 R3 (touch targets), R5 (a11y names)
## and R6 (dynamic type).
##
## `tests/run_text_scale_audit.gd` (PRD-12 R6, `tools/audit_text_scale.sh`) and
## `tests/run_layout_audit.gd` (R3/R5, `tools/audit_layout.sh`) instantiate the same scenes in
## the same 1080×1920 SubViewport and differ only in which findings they print and which
## scales they sweep — so the rules live here once and cannot drift apart.
##
## A finding is `"<kind> <path> (…)"`: the runners own the line format, this file owns the
## measurement.

const VIEWPORT_SIZE := Vector2i(1080, 1920)
## Sub-pixel slack for rounded measurements.
const EPSILON := 2.0


## Layout findings: clipped labels, sideways-scrolling containers, content a non-scrolling
## container can never reveal, and content outside the viewport.
static func geometry_findings(root_node: Node, vp: SubViewport,
		viewport_size := VIEWPORT_SIZE) -> PackedStringArray:
	var out := PackedStringArray()
	for node in walk(root_node):
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
			# R6's reachability rule: when the content fits (nothing to scroll), a child
			# drawn outside the scroller's rect can never be brought into view — it is
			# simply lost.
			var vbar := scroll.get_v_scroll_bar()
			var scrollable := vbar != null and vbar.max_value > vbar.page + 0.5
			if not scrollable:
				var bounds := scroll.get_global_rect()
				for inner in walk(scroll):
					if not (inner is Control) or inner == scroll:
						continue
					var ic: Control = inner
					if not ic.is_visible_in_tree() or ic.get_viewport() != vp \
							or nearest_scroll(ic) != scroll:
						continue
					var irect := ic.get_global_rect()
					if irect.end.y > bounds.end.y + EPSILON \
							or irect.position.y < bounds.position.y - EPSILON:
						out.append("unreachable %s (y %.0f..%.0f, scroller %.0f..%.0f)" % [
							ic.get_path(), irect.position.y, irect.end.y,
							bounds.position.y, bounds.end.y])

		if not inside_scroll(control):
			var rect := control.get_global_rect()
			if rect.end.y > viewport_size.y + EPSILON or rect.position.y < -EPSILON \
					or rect.end.x > viewport_size.x + EPSILON or rect.position.x < -EPSILON:
				out.append("overflow %s rect=(%.0f, %.0f, %.0f, %.0f)" % [
					control.get_path(), rect.position.x, rect.position.y,
					rect.size.x, rect.size.y])
	return out


## Interaction findings: PRD-12 R3's touch floor for every interactive control and R5's
## non-empty accessible name for the same set.
##
## "Interactive" is `TouchTargets.is_interactive()` plus anything a component marked with
## `A11y.make_interactive()` — the two ways this codebase states "a finger targets this".
static func interaction_findings(root_node: Node, vp: SubViewport) -> PackedStringArray:
	var out := PackedStringArray()
	for node in walk(root_node):
		if not (node is Control):
			continue
		var control: Control = node
		if not is_interactive(control):
			continue
		if not control.is_visible_in_tree() or control.get_viewport() != vp:
			continue
		if control.size.x + EPSILON < float(TouchTargets.MIN_SIZE) \
				or control.size.y + EPSILON < float(TouchTargets.MIN_SIZE):
			out.append("touchtarget %s (%.0fx%.0f)" % [
				control.get_path(), control.size.x, control.size.y])
		if A11y.name_of(control).strip_edges().is_empty():
			out.append("noname %s (%s)" % [control.get_path(), control.get_class()])
	return out


static func is_interactive(control: Control) -> bool:
	return TouchTargets.is_interactive(control) or control.has_meta(&"a11y_interactive")


## PRD-12 R6's absolute-position lint: a visible Control placed by literal coordinates.
##
## The rule is measured, not grepped, so Node2D decorations (`CPUParticles2D`'s
## `position = Vector2(540, 560)` confetti burst is not layout) never trip it: a Control is
## flagged when its parent is not a Container, it sets no anchor, and it is not the scene root
## — which is exactly "the rect comes from numbers in the editor, not from the layout".
static func absolute_findings(root_node: Node, vp: SubViewport) -> PackedStringArray:
	var out := PackedStringArray()
	for node in walk(root_node):
		if not (node is Control):
			continue
		var control: Control = node
		if control == root_node or not control.is_visible_in_tree() \
				or control.get_viewport() != vp:
			continue
		if control.get_parent() is Container:
			continue
		var anchored := not (is_zero_approx(control.anchor_left) \
				and is_zero_approx(control.anchor_top) \
				and is_zero_approx(control.anchor_right) \
				and is_zero_approx(control.anchor_bottom))
		if not anchored:
			out.append("absolute %s (position %.0f, %.0f)" % [
				control.get_path(), control.position.x, control.position.y])
	return out


static func walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(walk(child))
	return out


static func inside_scroll(control: Control) -> bool:
	return nearest_scroll(control) != null


## The nearest ScrollContainer ancestor, or null. Used to attribute a losing child to the
## scroll container whose viewport it should be visible in.
static func nearest_scroll(control: Control) -> ScrollContainer:
	var parent := control.get_parent()
	while parent != null:
		if parent is ScrollContainer:
			return parent
		parent = parent.get_parent()
	return null
