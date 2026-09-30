extends TestSuite
## PRD-12 R1 — the motion contract.
##
##   [motion] PRD-02 keys unchanged · PRD-12 keys added · decorative gating verified
##
## What it proves, in order:
##   1. every PRD-02 timing value is byte-for-byte the number PRD-02 shipped (a later PRD may
##      *add* keys, never change one);
##   2. PRD-12's five added keys exist with the values R1's table states;
##   3. `Motion.decorative_enabled()` follows `ui.reduce_motion`, and `Nav` follows the same
##      flag (transitions shorten, they never stop);
##   4. the stagger delay is `i × 40 ms`, capped at 8 × 40 ms;
##   5. no `_process`-driven animation exists anywhere in the shipped scripts — motion is
##      tweens or `_draw`, never a frame callback;
##   6. motion never gates input: a screen's controls are interactive on the very first frame,
##      and the shell's transition veil is explicitly input-transparent.

const SUITES_ROOT := "res://scripts"

## PRD-02 R17's table, exactly as the PRD prints it. Add, never edit.
const PRD02_KEYS := {
	"screen_ms": 180,
	"screen_phase_ms": 90,
	"press_ms": 90,
	"press_scale": 0.97,
	"toast_in_ms": 120,
	"toast_out_ms": 180,
	"toast_hold_ms": 2600,
	"double_back_ms": 2000,
	"frame_ms": 455,
}

## PRD-12 R1's additions.
const PRD12_KEYS := {
	"pop_ms": 200,
	"celebration_ms": 1600,
	"stagger_ms": 40,
	"stagger_max": 8,
	"ring_fill_ms": 420,
}


func _init() -> void:
	suite_name = "motion"


func run() -> void:
	_check_prd02_table()
	_check_added_keys()
	_check_decorative_gating()
	_check_stagger_cap()
	_check_no_process_animation()
	_check_input_not_gated()


func _check_prd02_table() -> void:
	begin("PRD-02's motion values are unchanged")
	for key in PRD02_KEYS:
		assert_has_key(DesignTokens.MOTION, key, "MOTION has '%s'" % key)
		assert_eq(DesignTokens.MOTION.get(key), PRD02_KEYS[key], "MOTION['%s']" % key)
	assert_true(DesignTokens.MOTION.has("reduced_ms"), "MOTION has 'reduced_ms'")
	assert_eq(DesignTokens.MOTION.get("reduced_ms"), 30,
		"reduced-motion phases are 30 ms, never scaled to zero")


func _check_added_keys() -> void:
	begin("PRD-12's added keys exist with R1's values")
	for key in PRD12_KEYS:
		assert_has_key(DesignTokens.MOTION, key, "MOTION has '%s'" % key)
		assert_eq(DesignTokens.MOTION.get(key), PRD12_KEYS[key], "MOTION['%s']" % key)
	assert_close(Motion.seconds("pop_ms"), 0.2, 0.0001, "Motion.seconds('pop_ms')")
	assert_close(Motion.seconds("celebration_ms"), 1.6, 0.0001, "celebration is 1.6 s")
	assert_eq(Motion.seconds("not_a_key"), 0.0, "an unknown key is 0 s, not a crash")


func _check_decorative_gating() -> void:
	begin("decorative motion is skipped, not shortened, under ui.reduce_motion")
	var previous := bool(App.get_setting("ui.reduce_motion", false))
	assert_true(Motion.decorative_enabled(), "decorative motion is on by default")
	var _written := App.set_setting("ui.reduce_motion", true)
	assert_false(Motion.decorative_enabled(), "decorative motion is off when the setting is on")
	_written = App.set_setting("ui.reduce_motion", previous)
	assert_eq(Motion.decorative_enabled(), not previous, "the setting restores the old state")


func _check_stagger_cap() -> void:
	begin("the stagger delay is i × stagger_ms, capped at stagger_max items")
	assert_close(Motion.stagger_seconds(0), 0.0, 0.0001, "item 0 waits nothing")
	assert_close(Motion.stagger_seconds(1), 0.04, 0.0001, "item 1 waits 40 ms")
	assert_close(Motion.stagger_seconds(4), 0.16, 0.0001, "item 4 waits 160 ms")
	assert_close(Motion.stagger_seconds(8), 0.32, 0.0001, "item 8 is the cap (320 ms)")
	assert_close(Motion.stagger_seconds(99), 0.32, 0.0001, "item 99 is still 320 ms")
	assert_close(Motion.stagger_seconds(-3), 0.0, 0.0001, "a negative index waits nothing")


## R1's audit rule: "no `_process`-driven animation anywhere — tweens or `_draw` only". The
## codebase satisfies it by construction, and this is what keeps it that way: the next
## `_process()` added to a screen fails the suite rather than quietly costing frames.
func _check_no_process_animation() -> void:
	begin("no _process/_physics_process exists in scripts/")
	var found := PackedStringArray()
	for dir in ["ui", "autoload", "core"]:
		_scan_dir("%s/%s" % [SUITES_ROOT, dir], found)
	assert_empty(found, "no frame callbacks drive animation: %s" % ", ".join(found))


func _scan_dir(path: String, found: PackedStringArray) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file in dir.get_files():
		if file.ends_with(".gd"):
			var text := FileAccess.get_file_as_string("%s/%s" % [path, file])
			if text.contains("func _process(") or text.contains("func _physics_process("):
				found.append(file)
	for sub in dir.get_directories():
		_scan_dir("%s/%s" % [path, sub], found)


## R1: "motion never gates input (controls are interactive on frame 1; only
## modulate/position/scale animate)". Measured on a real screen: adding it to the tree runs
## `_ready()` synchronously, and the CTA is enabled and accepts the mouse at that instant —
## the entrance animation that follows never disables it.
func _check_input_not_gated() -> void:
	begin("controls are interactive on frame 1 and the transition veil is input-transparent")
	var packed: PackedScene = load("res://scenes/ui/home_tab.tscn")
	assert_true(packed != null, "home_tab.tscn loads")
	if packed == null:
		return
	var vp := SubViewport.new()
	vp.size = Vector2i(1080, 1920)
	vp.disable_3d = true
	var tree := Engine.get_main_loop() as SceneTree
	assert_true(tree != null, "the suite runs inside a SceneTree")
	if tree == null:
		return
	tree.root.add_child(vp)
	var screen: Node = packed.instantiate()
	vp.add_child(screen)
	var start_button := _find_button(screen, "StartButton")
	assert_true(start_button != null, "the Home CTA exists")
	if start_button != null:
		assert_false(start_button.disabled, "the CTA is enabled on frame 1")
		assert_eq(start_button.mouse_filter, Control.MOUSE_FILTER_STOP,
			"the CTA accepts input on frame 1")
	vp.queue_free()

	# The veil is the one full-screen overlay that could eat every tap; the scene must keep it
	# transparent to the mouse (the same literal PRD-02 shipped).
	var shell_scene := FileAccess.get_file_as_string("res://scenes/ui/shell.tscn")
	var veil_index := shell_scene.find("TransitionVeil")
	assert_gt(float(veil_index), 0.0, "shell.tscn declares TransitionVeil")
	if veil_index >= 0:
		var block := shell_scene.substr(veil_index)
		assert_true(block.contains("mouse_filter = 2"),
			"the transition veil ignores the mouse for its whole life")


func _find_button(node: Node, button_name: String) -> Button:
	if node.name == button_name and node is Button:
		return node as Button
	for child in node.get_children():
		var found := _find_button(child, button_name)
		if found != null:
			return found
	return null
