extends SceneTree
func _init() -> void:
	var script: GDScript = load("res://scripts/autoload/llm.gd")
	print("loaded: ", script != null)
	var node: Node = script.new()
	print("instantiated: ", node != null, " client=", node.get("_client"))
	quit(0)
