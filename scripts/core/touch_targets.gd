class_name TouchTargets
extends RefCounted
## The 88 px touch floor as a shared, callable check — PRD-02 R6, appendix §4.4.
##
## `Shell` used to own this privately, which meant the only screen that could ever report a
## violation was the shell — and only for whatever tab happened to be visible one frame after
## boot. PRD-06 adds two more screens whose controls must clear the same bar (the onboarding
## wizard and the Settings tab, which is *not* visible when the shell checks), so the rule now
## lives here and every screen prints the identical, greppable line:
##
##     [ui] touch-target violations: 0
##
## A violation prints the control's full path and measured size on the following line, so a
## non-zero count is actionable without a screenshot.

## One interactive control below this on either axis is a violation, in design px.
const MIN_SIZE := 88


## True for the control types a thumb can actually operate. `Range` is deliberately excluded —
## a `ProgressBar` is a `Range` but is not interactive — while its two interactive subclasses
## are included.
static func is_interactive(control: Control) -> bool:
	return control is Button or control is CheckButton or control is LineEdit \
		or control is TextEdit or control is TextureButton or control is Slider \
		or control is ScrollBar or control is OptionButton


## Every visible interactive descendant of [param root] that is smaller than [constant MIN_SIZE]
## on either axis, as `path (WxH)` strings.
static func violations(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	_collect(root, out)
	return out


## Prints the standard line and returns the violation count.
static func report(root: Node) -> int:
	var found := violations(root)
	print("[ui] touch-target violations: %d" % found.size())
	for line in found:
		print("      %s" % line)
	return found.size()


## Raises an interactive control's `custom_minimum_size` to the touch floor. Used by the screens
## that build controls in code (`segmented_control`, the provider block, the settings rows).
static func enforce(control: Control) -> void:
	var minimum := Vector2(float(MIN_SIZE), float(MIN_SIZE))
	var current := control.custom_minimum_size
	var enforced := Vector2(maxf(current.x, minimum.x), maxf(current.y, minimum.y))
	if enforced != current:
		control.custom_minimum_size = enforced


static func _collect(node: Node, out: PackedStringArray) -> void:
	if node is Control:
		var control := node as Control
		if is_interactive(control) and control.is_visible_in_tree():
			if control.size.x < float(MIN_SIZE) or control.size.y < float(MIN_SIZE):
				out.append("%s (%dx%d)" % [
					String(control.get_path()), int(control.size.x), int(control.size.y)])
	for child in node.get_children():
		_collect(child, out)
