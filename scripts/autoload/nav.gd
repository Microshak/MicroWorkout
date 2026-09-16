extends Node
## Navigation autoload: owns a pure [Router] plus all the scene-tree side effects.
##
## Split of responsibility (PRD-02 R12/R13): `Router` decides *what* should happen and is
## unit-tested headless; this node performs it — loading scenes, running the 180 ms
## transition, and handling the Android back button. Screens ask for a destination by
## name and never load scenes themselves.

signal route_changed(route: StringName, args: Dictionary)
signal tab_changed(index: int)
signal transition_started(route: StringName, direction: int)
signal transition_finished(route: StringName)
signal back_consumed()
signal quit_requested()

enum Direction { PUSH = 1, POP = -1 }

var _router: Router = null
var _shell: Shell = null
var _pending_route: StringName = &""
var _pending_args: Dictionary = {}
var _transitioning: bool = false
var _reduce_motion: bool = false
var _back_handling_enabled: bool = true
var _last_back_ms: int = 0


func _ready() -> void:
	_router = Router.new(Routes.TAB_ROUTES)
	for route in Routes.TAB_SCENES:
		_router.register(route, Routes.TAB_SCENES[route], Router.Mode.TAB)
	for route in Routes.TABLE:
		if route == Routes.SHELL:
			# The shell is the root frame itself, not a navigable screen. Registering it
			# as a push route would let it push a second copy of itself into its own
			# ScreenHost.
			continue
		_router.register(route, Routes.TABLE[route], Router.Mode.PUSH)
	print("[Nav] ready — %d routes, %d tabs" % [
		Routes.TABLE.size() - 1 + Routes.TAB_SCENES.size(), Routes.TAB_ROUTES.size()])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_handle_back()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_handle_back()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- shell wiring

## Called by Shell._ready(). Until this happens, `goto()` parks one pending route.
func register_shell(shell_node: Shell) -> void:
	_shell = shell_node
	if _pending_route == &"":
		return
	var route := _pending_route
	var args := _pending_args
	_pending_route = &""
	_pending_args = {}
	if route == Routes.SHELL:
		# The shell just finished loading itself; there is nothing to apply.
		return
	goto(route, args)


func shell() -> Shell:
	return _shell


func has_shell() -> bool:
	return is_instance_valid(_shell)


# ---------------------------------------------------------------- public API

func goto(route: StringName, args: Dictionary = {}) -> void:
	if route == Routes.SHELL:
		# The shell is the root frame: load it once, and never push it as a screen.
		if has_shell():
			push_warning("[nav] the shell is already active")
			return
		_load_shell(route, args)
		return
	if _transitioning:
		push_warning("[nav] ignored during transition: %s" % route)
		return
	_apply(_router.goto(route, args))


func push(route: StringName, args: Dictionary = {}) -> void:
	if _transitioning:
		push_warning("[nav] ignored during transition: %s" % route)
		return
	_apply(_router.push(route, args))


func pop() -> bool:
	if _transitioning:
		push_warning("[nav] pop ignored during transition")
		return false
	var action := _router.pop()
	_apply(action)
	return action.changed


func pop_to_root() -> void:
	if _transitioning:
		return
	_apply(_router.pop_to_root())


func switch_tab(index: int) -> void:
	if _transitioning:
		return
	_apply(_router.switch_tab(index))


## Aliases kept so later PRDs use one verb regardless of which spelling they picked.
func goto_tab(index: int) -> void:
	switch_tab(index)


func set_tab(index: int) -> void:
	switch_tab(index)


## Clears the stack, then pushes [param route] — lets a flow replace itself (wizard →
## preview) without leaking stack depth.
func replace(route: StringName, args: Dictionary = {}) -> void:
	if _transitioning:
		return
	_router.pop_to_root()
	_apply(_router.goto(route, args))


## PRD-01 entry point, retained: loads a raw scene into ScreenHost without registering a
## route.
func push_scene(scene_path: String) -> bool:
	if not has_shell():
		push_error("[nav] push_scene before a shell was registered: %s" % scene_path)
		return false
	if not ResourceLoader.exists(scene_path):
		push_error("[nav] scene not found: %s" % scene_path)
		return false
	_swap_screen(scene_path, {})
	return true


func current_route() -> StringName:
	var entry := _router.current()
	if entry != null:
		return entry.route
	var tab := _router.active_tab()
	if tab >= 0 and tab < Routes.TAB_ROUTES.size():
		return Routes.TAB_ROUTES[tab]
	return &""


func current_args() -> Dictionary:
	var entry := _router.current()
	if entry != null:
		return entry.args
	return _router.args_of(current_route())


func stack_depth() -> int:
	return _router.stack_depth()


func active_tab() -> int:
	return _router.active_tab()


func is_transitioning() -> bool:
	return _transitioning


func set_reduce_motion(value: bool) -> void:
	_reduce_motion = value


## False while a modal, a celebration or a blocking dialog owns the back gesture.
func set_back_handling(enabled: bool) -> void:
	_back_handling_enabled = enabled


# ---------------------------------------------------------------- back handling

func _handle_back() -> void:
	if not _back_handling_enabled:
		return
	var action := _router.handle_back(_double_back_armed())
	match action.kind:
		Router.ActionKind.QUIT:
			print("[nav] back → quit")
			quit_requested.emit()
			get_tree().quit()
		Router.ActionKind.NONE:
			# First back on Home: arm the double-back window and tell the user.
			_last_back_ms = Time.get_ticks_msec()
			print("[nav] back → arm-exit depth=%d tab=%d" % [
				_router.stack_depth(), _router.active_tab()])
			Feedback.toast("Press back again to exit")
			back_consumed.emit()
		_:
			print("[nav] back → %s depth=%d tab=%d" % [
				_kind_name(action.kind), _router.stack_depth(), _router.active_tab()])
			_apply(action)
			back_consumed.emit()


func _double_back_armed() -> bool:
	if _last_back_ms == 0:
		return false
	return Time.get_ticks_msec() - _last_back_ms <= int(DesignTokens.MOTION["double_back_ms"])


func _kind_name(kind: int) -> String:
	match kind:
		Router.ActionKind.TAB_SWITCH: return "tab_switch"
		Router.ActionKind.PUSH: return "push"
		Router.ActionKind.POP: return "pop"
		Router.ActionKind.POP_TO_TAB: return "pop_to_tab"
		Router.ActionKind.QUIT: return "quit"
		_: return "none"


# ---------------------------------------------------------------- application

func _load_shell(route: StringName, args: Dictionary) -> void:
	var path: String = Routes.TABLE.get(route, "")
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("[nav] shell scene missing: %s" % path)
		return
	_pending_route = route
	_pending_args = args
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("[nav] cannot load shell (error %d)" % err)
		_pending_route = &""
		return
	print("[nav] goto route=%s depth=0" % route)


func _apply(action: Router.Action) -> void:
	match action.kind:
		Router.ActionKind.TAB_SWITCH:
			_do_tab_switch(action)
		Router.ActionKind.POP_TO_TAB:
			_do_tab_switch(action)
		Router.ActionKind.PUSH:
			_transition_to(action.route, action.scene_path, action.args, Direction.PUSH)
		Router.ActionKind.POP:
			if action.scene_path.is_empty():
				_land_on_active_tab()
			else:
				_transition_to(action.route, action.scene_path, action.args, Direction.POP)
		_:
			return


func _land_on_active_tab() -> void:
	var index := _router.active_tab()
	var action := Router.Action.new()
	action.kind = Router.ActionKind.TAB_SWITCH
	action.tab = index
	action.changed = true
	if index >= 0 and index < Routes.TAB_ROUTES.size():
		action.route = StringName(Routes.TAB_ROUTES[index])
	_do_tab_switch(action)


func _do_tab_switch(action: Router.Action) -> void:
	var index := action.tab
	if index < 0 or index >= Routes.TAB_ROUTES.size():
		return
	if not has_shell():
		return

	var host := _shell.screen_host()
	if host != null:
		for child in host.get_children():
			child.queue_free()
		host.visible = false

	var previous := -1
	for i in range(Routes.TAB_ROUTES.size()):
		var tab_root := _shell.tab_root(i)
		if tab_root != null and tab_root.visible and i != index:
			previous = i

	var target := _shell.tab_root(index)
	if target == null:
		push_error("[nav] shell has no tab root %d" % index)
		return

	# Tab switching cross-fades both roots; the veil is reserved for pushed screens.
	if previous >= 0 and not _reduce_motion:
		var from := _shell.tab_root(previous)
		target.visible = true
		target.modulate.a = 0.0
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_property(target, "modulate:a", 1.0, _ms(DesignTokens.MOTION["screen_ms"]))
		if from != null:
			tween.tween_property(from, "modulate:a", 0.0, _ms(DesignTokens.MOTION["screen_ms"]))
		await tween.finished
		if from != null:
			from.visible = false
			from.modulate.a = 1.0
	else:
		for i in range(Routes.TAB_ROUTES.size()):
			var root := _shell.tab_root(i)
			if root != null:
				root.visible = i == index
				root.modulate.a = 1.0

	_enter_route(target, action.args)
	_shell.set_active_tab(index)

	print("[nav] goto route=%s depth=%d tab=%d" % [action.route, _router.stack_depth(), index])
	tab_changed.emit(index)
	route_changed.emit(action.route, action.args)
	transition_finished.emit(action.route)


func _transition_to(route: StringName, scene_path: String, args: Dictionary,
		direction: int) -> void:
	if not has_shell():
		push_warning("[nav] no shell registered; cannot navigate to %s" % route)
		return
	if _transitioning:
		return

	_transitioning = true
	transition_started.emit(route, direction)

	var phase := int(DesignTokens.MOTION["screen_phase_ms"])
	if _reduce_motion:
		phase = int(DesignTokens.MOTION["reduced_ms"])

	var veil := _shell.veil()
	if veil != null:
		veil.visible = true
		var out_tween := create_tween()
		out_tween.tween_property(veil, "modulate:a", 1.0, _ms(phase)) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		await out_tween.finished

	_swap_screen(scene_path, args)

	if veil != null:
		var in_tween := create_tween()
		in_tween.tween_property(veil, "modulate:a", 0.0, _ms(phase)) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		await in_tween.finished
		veil.visible = false

	_transitioning = false
	var verb := "push" if direction == Direction.PUSH else "pop"
	print("[nav] %s route=%s depth=%d" % [verb, route, _router.stack_depth()])
	print("[nav] transition route=%s ms=%d" % [route, DesignTokens.MOTION["screen_ms"]])
	route_changed.emit(route, args)
	transition_finished.emit(route)


func _swap_screen(scene_path: String, args: Dictionary) -> void:
	var host := _shell.screen_host()
	if host == null:
		push_error("[nav] shell has no ScreenHost")
		return
	for child in host.get_children():
		host.remove_child(child)
		child.queue_free()

	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("[nav] cannot load scene: %s" % scene_path)
		host.visible = false
		return

	var instance: Node = packed.instantiate()
	host.add_child(instance)
	host.visible = true
	_enter_route(instance, args)


func _enter_route(node: Node, args: Dictionary) -> void:
	if node.has_method(&"on_route_entered"):
		node.call(&"on_route_entered", args)
	if node.has_method(&"setup"):
		node.call(&"setup", args)


func _ms(msec: int) -> float:
	return float(msec) / 1000.0
