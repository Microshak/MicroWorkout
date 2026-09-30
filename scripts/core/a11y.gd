class_name A11y
extends RefCounted
## PRD-12 R5 — screen-reader metadata, focus order, hit pads and the live region.
##
## Every interactive control gets a name a screen reader can say; the audit in
## `tests/run_layout_audit.gd` fails on an empty one, so a new button cannot ship without a
## label. The helpers never cache scene state and never touch `Store`.
##
## Godot 4.7.2 exposes the properties this module writes (`accessibility_name`,
## `accessibility_description`, `accessibility_live` — measured by a throwaway probe, and
## `ClassDB.class_has_property()` does not exist, so the check walks
## `ClassDB.class_get_property_list()`). On an engine without them everything still works:
## the name is mirrored into `tooltip_text` and kept in the `a11y_name` meta, and the first
## call logs the documented fallback line.

## Meta keys the audit and the fallback path agree on.
const NAME_META := &"a11y_name"
const HITPAD_META := &"a11y_hitpad"

## PRD-12 R5's live-region priority: Off=0, Polite=1, Assertive=2.
const LIVE_POLITE := 1

static var _fallback_logged := false


## True when the engine's Control class carries the accessibility properties.
static func properties_available() -> bool:
	return _has_property("Control", "accessibility_name") \
		and _has_property("Control", "accessibility_description")


## The name the audit checks: the meta first (works everywhere), the engine property after,
## and the tooltip last — so a control labelled before Godot 4.7.2's accessibility surface
## existed (or in a scene file by hand) is still recognised.
static func name_of(control: Control) -> String:
	if control == null:
		return ""
	var stored := String(control.get_meta(NAME_META, ""))
	if not stored.is_empty():
		return stored
	if properties_available() and not control.accessibility_name.is_empty():
		return control.accessibility_name
	return control.tooltip_text


## Names (and optionally describes) an interactive control.
##
##   A11y.label(button, "Start today's session")
##   A11y.label(cell, "Tuesday 15 September, completed", "Calendar day")
##
## `tooltip_text` mirrors the name so the information survives on an engine without the
## accessibility properties — and so a long-press on Android shows the same sentence.
static func label(control: Control, name: String, description := "") -> void:
	if control == null:
		return
	control.set_meta(NAME_META, name)
	control.tooltip_text = name
	if properties_available():
		control.accessibility_name = name
		if not description.is_empty():
			control.accessibility_description = description
	elif not _fallback_logged:
		_fallback_logged = true
		print("[a11y] accessibility properties unavailable; using tooltip_text")


## Description only — for a control whose accessible name already reads well.
static func describe(control: Control, description: String) -> void:
	if control == null:
		return
	if properties_available():
		control.accessibility_description = description


## Marks a custom-drawn Control as interactive (the audit's second way of recognising one,
## next to `TouchTargets.is_interactive()`).
static func make_interactive(control: Control, name: String, description := "") -> void:
	if control == null:
		return
	control.set_meta(&"a11y_interactive", true)
	label(control, name, description)


## Focus order equals visual order: each control points at its neighbours. Pass
## `horizontal = true` for a row (the settings chips, the weekday header).
static func chain_focus(controls: Array, horizontal := false) -> void:
	for i in controls.size():
		var control: Control = controls[i]
		if control == null or not is_instance_valid(control):
			continue
		control.focus_mode = Control.FOCUS_ALL
		if i > 0:
			var previous: Control = controls[i - 1]
			if horizontal:
				control.focus_neighbor_left = control.get_path_to(previous)
			else:
				control.focus_neighbor_top = control.get_path_to(previous)
		if i < controls.size() - 1:
			var following: Control = controls[i + 1]
			if horizontal:
				control.focus_neighbor_right = control.get_path_to(following)
			else:
				control.focus_neighbor_bottom = control.get_path_to(following)


## Wraps a control that must *look* smaller than the touch floor in a transparent hit pad.
##
## R3's audit has an empty allow-list by construction: a chip or a legend toggle is padded,
## never excepted. The pad is a plain 88×88 Control (meta `a11y_hitpad`) and the wrapped
## control is stretched to fill it, so the measured rect clears the floor for real.
static func pad(control: Control) -> Control:
	if control == null:
		return null
	var parent := control.get_parent()
	if parent == null:
		return control
	if parent.has_meta(HITPAD_META) or parent.get_parent() == null:
		return parent  # already padded
	var host := Control.new()
	host.name = "%sHitPad" % control.name
	host.set_meta(HITPAD_META, true)
	host.custom_minimum_size = Vector2(DesignTokens.TOUCH_MIN, DesignTokens.TOUCH_MIN)
	host.mouse_filter = Control.MOUSE_FILTER_PASS
	var index := control.get_index()
	parent.add_child(host)
	parent.move_child(host, index)
	control.reparent(host)
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return host


## Writes [param text] into the shell's polite live region and mirrors it to logcat.
##
## `Feedback.toast()` routes through here, so every toast is also spoken. Before the shell
## exists (boot) there is no region and this is a log line only — never an error.
static func announce(text: String) -> void:
	if text.is_empty():
		return
	if OS.is_debug_build():
		print("[a11y] announce %s" % text)
	var region := live_region()
	if region == null:
		return
	region.text = text
	if properties_available():
		region.accessibility_name = text


## The shell's live-region Label, or null when the shell is not up yet.
static func live_region() -> Label:
	var shell := _shell()
	if shell == null or not shell.has_method(&"live_region"):
		return null
	var region: Variant = shell.call(&"live_region")
	return region if region is Label else null


static func _shell() -> Node:
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	var nav := (loop as SceneTree).root.get_node_or_null(^"Nav")
	if nav == null or not nav.has_method(&"shell"):
		return null
	var shell: Variant = nav.call(&"shell")
	return shell if shell is Node else null


static func _has_property(type_name: String, property: String) -> bool:
	for entry in ClassDB.class_get_property_list(type_name, true):
		if String(entry["name"]) == property:
			return true
	return false
