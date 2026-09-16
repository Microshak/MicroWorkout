extends SceneTree

func _init() -> void:
	print("uri_encode arity test:")
	print("  ", "a b/c".uri_encode())
	print("has_method create_timer: ", get_root() != null)
	print("SceneTree.root: ", root != null)
	_run()

func _run() -> void:
	print("start _run")
	var v: Variant = await _plain()
	print("await on plain value -> ", v, " (", typeof(v), ")")
	var s: String = await _coro_sync()
	print("await on sync coroutine -> ", s)
	var t: int = await _coro_async()
	print("await on async coroutine -> ", t)
	quit(0)

func _plain() -> int:
	return 7

func _coro_sync() -> String:
	return "sync-no-await-inside"

func _coro_async() -> int:
	await create_timer(0.05, true, false, true).timeout
	return 42
