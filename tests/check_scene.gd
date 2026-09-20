extends SceneTree
## Scene smoke-checker — instantiates one scene under `--headless` and reports what happened.
##
##   tools/check_scene.sh res://scenes/ui/workout_player.tscn
##
## Why this exists: a hand-authored `.tscn` fails in ways the parser never sees — a node renamed in
## the scene while a script still points at the old path, an `ExtResource` that no longer resolves, a
## `@onready` that is `null` on the first frame. Instantiating the scene for real (one frame, no
## window) catches all three before an emulator run does. It asserts nothing about looks; it asserts
## that the scene loads, builds and survives its first frame.

func _initialize() -> void:
	var paths := PackedStringArray()
	for argument in OS.get_cmdline_user_args():
		var text := String(argument)
		if not text.begins_with("--"):
			paths.append(text)
	if paths.is_empty():
		print("usage: tools/check_scene.sh res://scenes/ui/foo.tscn [more…]")
		quit(2)
		return

	var failures := 0
	for path in paths:
		failures += await _check(path)
	print("  RESULT: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _check(path: String) -> int:
	if not ResourceLoader.exists(path):
		print("  ✘ %s — not found" % path)
		return 1
	var packed: PackedScene = load(path)
	if packed == null:
		print("  ✘ %s — load() returned null" % path)
		return 1
	var node: Node = packed.instantiate()
	if node == null:
		print("  ✘ %s — instantiate() returned null" % path)
		return 1
	root.add_child(node)
	# One frame: `@onready` vars are assigned on enter-tree, `_ready` runs, and any deferred or
	# `_process`-time failure surfaces before we quit.
	await process_frame
	await process_frame
	var script: Script = node.get_script()
	var script_path := "" if script == null else script.resource_path
	print("  ✔ %s — nodes=%d script=%s" % [path, _count(node), script_path])
	node.queue_free()
	return 0


func _count(node: Node) -> int:
	var total := 0
	for child in node.get_children():
		total += 1 + _count(child)
	return total
