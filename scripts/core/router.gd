class_name Router
extends RefCounted
## Pure navigation state machine. **No scene-tree access** — this class decides *what*
## should happen, `Nav` (autoload) performs it. Keeping the decision pure is what makes
## the whole navigation contract unit-testable headless (PRD-02 R12).

enum Mode { TAB = 0, PUSH = 1 }
enum ActionKind { NONE, TAB_SWITCH, PUSH, POP, POP_TO_TAB, QUIT }

const MAX_STACK_DEPTH := 8


class Entry extends RefCounted:
	var route: StringName = &""
	var scene_path: String = ""
	var args: Dictionary = {}


class Action extends RefCounted:
	# 0 = NONE, 1 = TAB_SWITCH, 2 = PUSH, 3 = POP, 4 = POP_TO_TAB, 5 = QUIT
	# (literals rather than the outer enum: GDScript inner classes cannot see the
	# enclosing class's constants.)
	var kind: int = 0
	var route: StringName = &""
	var scene_path: String = ""
	var args: Dictionary = {}
	var tab: int = -1
	var changed: bool = false


var _tab_routes: PackedStringArray = PackedStringArray()
var _registered: Dictionary = {}          # route -> {"scene_path": String, "mode": int}
var _stack: Array[Entry] = []
var _active_tab: int = 0
var _tab_args: Dictionary = {}            # route -> last args seen for that tab


func _init(tab_routes: PackedStringArray) -> void:
	_tab_routes = tab_routes


# ---------------------------------------------------------------- registration

func register(route: StringName, scene_path: String, mode: int) -> bool:
	if route == &"" or scene_path.is_empty():
		push_warning("[nav] refusing to register empty route or scene path")
		return false
	_registered[route] = {"scene_path": scene_path, "mode": mode}
	return true


func has(route: StringName) -> bool:
	return _registered.has(route)


func mode_of(route: StringName) -> int:
	if not _registered.has(route):
		return Mode.PUSH
	return int(_registered[route]["mode"])


func scene_path_of(route: StringName) -> String:
	if not _registered.has(route):
		return ""
	return String(_registered[route]["scene_path"])


func tab_index_of(route: StringName) -> int:
	return _tab_routes.find(route)

# ---------------------------------------------------------------- actions

func goto(route: StringName, args: Dictionary = {}) -> Action:
	if not has(route):
		return _unknown(route)
	if mode_of(route) == Mode.TAB:
		return _tab_switch(tab_index_of(route), args)
	return push(route, args)


func push(route: StringName, args: Dictionary = {}) -> Action:
	if not has(route):
		return _unknown(route)
	if mode_of(route) == Mode.TAB:
		return _tab_switch(tab_index_of(route), args)

	var entry := Entry.new()
	entry.route = route
	entry.scene_path = scene_path_of(route)
	entry.args = args

	if _stack.size() >= MAX_STACK_DEPTH:
		_stack.pop_front()   # drop the bottom-most entry to respect the depth cap
	_stack.append(entry)

	var action := Action.new()
	action.kind = ActionKind.PUSH
	action.route = route
	action.scene_path = entry.scene_path
	action.args = args
	action.changed = true
	return action


func pop() -> Action:
	var action := Action.new()
	if _stack.is_empty():
		action.kind = ActionKind.NONE
		action.changed = false
		return action

	_stack.pop_back()
	action.kind = ActionKind.POP
	action.changed = true
	var entry := current()
	if entry != null:
		action.route = entry.route
		action.scene_path = entry.scene_path
		action.args = entry.args
	elif _active_tab >= 0 and _active_tab < _tab_routes.size():
		action.route = StringName(_tab_routes[_active_tab])
	return action


func pop_to_root() -> Action:
	var action := Action.new()
	if _stack.is_empty():
		action.kind = ActionKind.NONE
		action.changed = false
		return action
	_stack.clear()
	action.kind = ActionKind.POP
	action.changed = true
	if _active_tab >= 0 and _active_tab < _tab_routes.size():
		action.route = StringName(_tab_routes[_active_tab])
	return action


func switch_tab(index: int) -> Action:
	return _tab_switch(index, {})


func handle_back(double_back_armed: bool) -> Action:
	var action := Action.new()
	if not _stack.is_empty():
		return pop()

	if _active_tab != 0:
		_active_tab = 0
		action.kind = ActionKind.POP_TO_TAB
		action.tab = 0
		if _tab_routes.size() > 0:
			action.route = StringName(_tab_routes[0])
		action.changed = true
		return action

	if double_back_armed:
		action.kind = ActionKind.QUIT
		action.changed = true
		return action

	action.kind = ActionKind.NONE
	action.changed = false
	return action


# ---------------------------------------------------------------- queries

func current() -> Entry:
	if _stack.is_empty():
		return null
	return _stack[_stack.size() - 1]


func stack_depth() -> int:
	return _stack.size()


func stack_routes() -> PackedStringArray:
	var routes := PackedStringArray()
	for entry in _stack:
		routes.append(entry.route)
	return routes


func active_tab() -> int:
	return _active_tab


## Last args seen for a tab route (tab routes are not stacked, so their args are
## remembered separately).
func args_of(route: StringName) -> Dictionary:
	return _tab_args.get(route, {})


# ---------------------------------------------------------------- internals

func _tab_switch(index: int, args: Dictionary) -> Action:
	var action := Action.new()
	if index < 0 or index >= _tab_routes.size():
		action.kind = ActionKind.NONE
		action.changed = false
		return action

	var route := StringName(_tab_routes[index])
	if not args.is_empty():
		_tab_args[route] = args

	action.kind = ActionKind.TAB_SWITCH
	action.tab = index
	action.route = route
	action.args = args
	action.changed = index != _active_tab
	_active_tab = index
	return action


func _unknown(route: StringName) -> Action:
	push_warning("[nav] unknown route: %s" % route)
	var action := Action.new()
	action.kind = ActionKind.NONE
	action.changed = false
	return action
