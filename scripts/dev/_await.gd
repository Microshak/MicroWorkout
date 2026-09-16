extends SceneTree

class D extends RefCounted:
	var n := 0
	func delay(s: float) -> void:
		n += 1

func _init() -> void:
	_run()

func _run() -> void:
	print("before await null")
	await null
	print("after await null")
	var d := D.new()
	print("before await void call")
	await d.call(&"delay", 1.0)
	print("after await void call n=", d.n)
	quit(0)
