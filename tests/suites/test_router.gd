extends TestSuite
## PRD-02 R12 — the navigation state machine, tested without a scene tree.
##
## This suite is the reason Router is a pure class: every rule about stacks, tabs,
## back-handling and the depth cap is verified here rather than by clicking around.


func _init() -> void:
	suite_name = "router"


func _make() -> Router:
	var router := Router.new(Routes.TAB_ROUTES)
	for route in Routes.TAB_SCENES:
		router.register(route, Routes.TAB_SCENES[route], Router.Mode.TAB)
	for route in Routes.TABLE:
		# Mirrors Nav: the shell is the root frame, never a pushable screen, so it is not
		# registered as a route at all.
		if route == Routes.SHELL:
			continue
		router.register(route, Routes.TABLE[route], Router.Mode.PUSH)
	return router


func run() -> void:
	_test_registration()
	_test_goto_and_push()
	_test_tab_switching()
	_test_stack_depth_cap()
	_test_pop_semantics()
	_test_back_handling()
	_test_args_retention()
	_test_unknown_route()
	_test_routes_table_integrity()


func _test_registration() -> void:
	begin("registration and lookup")
	var router := _make()
	assert_true(router.has(Routes.HOME), "home must be registered")
	assert_eq(router.mode_of(Routes.HOME), Router.Mode.TAB, "home is a tab route")
	assert_eq(router.mode_of(Routes.GALLERY), Router.Mode.PUSH, "gallery is a push route")
	assert_eq(router.tab_index_of(Routes.HOME), 0, "home is tab 0")
	assert_eq(router.tab_index_of(Routes.SETTINGS), 3, "settings is tab 3")
	assert_eq(router.tab_index_of(&"nope"), -1, "a non-tab route has index -1")
	assert_eq(router.scene_path_of(Routes.TRACKER), Routes.TAB_SCENES[Routes.TRACKER],
		"scene path resolves")


func _test_goto_and_push() -> void:
	begin("goto on a tab route switches tab (semantic 1)")
	var router := _make()
	var action := router.goto(Routes.TRACKER)
	assert_eq(action.kind, Router.ActionKind.TAB_SWITCH, "goto(tab) is a TAB_SWITCH")
	assert_eq(action.tab, 2, "and targets tab 2")
	assert_true(action.changed, "moving from tab 0 to tab 2 is a change")
	assert_eq(router.stack_depth(), 0, "switching tabs never touches the stack")

	begin("goto on a push route pushes (semantic 1)")
	action = router.goto(Routes.GALLERY)
	assert_eq(action.kind, Router.ActionKind.PUSH, "goto(push route) is a PUSH")
	assert_eq(router.stack_depth(), 1, "stack depth is 1")
	assert_eq(router.current().route, Routes.GALLERY, "gallery is current")

	begin("push of a tab route is converted to a tab switch (semantic 2)")
	action = router.push(Routes.HOME)
	assert_eq(action.kind, Router.ActionKind.TAB_SWITCH, "push(tab) becomes TAB_SWITCH")
	assert_eq(action.tab, 0, "targets tab 0")
	assert_eq(router.stack_depth(), 1, "stack untouched by the conversion")


func _test_tab_switching() -> void:
	begin("switch_tab semantics (semantic 5)")
	var router := _make()
	var action := router.switch_tab(99)
	assert_eq(action.kind, Router.ActionKind.NONE, "out-of-range tab does nothing")
	assert_false(action.changed, "and reports no change")
	action = router.switch_tab(-1)
	assert_eq(action.kind, Router.ActionKind.NONE, "negative tab does nothing")
	action = router.switch_tab(0)
	assert_eq(action.kind, Router.ActionKind.TAB_SWITCH, "valid tab is a TAB_SWITCH")
	assert_false(action.changed, "re-selecting the active tab is not a change")
	action = router.switch_tab(1)
	assert_true(action.changed, "selecting a different tab is a change")
	assert_eq(router.active_tab(), 1, "active_tab tracks the switch")


func _test_stack_depth_cap() -> void:
	begin("push honours MAX_STACK_DEPTH")
	var router := _make()
	# Register enough distinct push routes to overflow the cap.
	for i in range(Router.MAX_STACK_DEPTH + 3):
		var route := StringName("probe_%d" % i)
		router.register(route, "res://scenes/ui/dev_component_gallery.tscn", Router.Mode.PUSH)
		router.push(route)
	assert_eq(router.stack_depth(), Router.MAX_STACK_DEPTH,
		"depth is capped at %d" % Router.MAX_STACK_DEPTH)
	assert_eq(router.current().route, StringName("probe_%d" % (Router.MAX_STACK_DEPTH + 2)),
		"the newest push is on top")
	var routes := router.stack_routes()
	assert_eq(routes[0], StringName("probe_3"), "the oldest entries were dropped first")


func _test_pop_semantics() -> void:
	begin("pop at depth 0 is a no-op (semantic 3)")
	var router := _make()
	var action := router.pop()
	assert_eq(action.kind, Router.ActionKind.NONE, "pop with an empty stack does nothing")
	assert_false(action.changed, "and reports no change")

	begin("pop returns to the tab beneath")
	router.push(Routes.GALLERY)
	action = router.pop()
	assert_eq(action.kind, Router.ActionKind.POP, "pop is a POP")
	assert_eq(router.stack_depth(), 0, "stack is empty again")
	assert_eq(action.route, Routes.HOME, "the action points at the active tab")

	begin("pop_to_root clears the whole stack")
	router.push(Routes.GALLERY)
	router.push(Routes.GALLERY)
	assert_eq(router.stack_depth(), 2, "two pushed entries")
	action = router.pop_to_root()
	assert_eq(router.stack_depth(), 0, "pop_to_root clears everything")
	assert_eq(router.active_tab(), 0, "active tab is unchanged by pop_to_root")
	action = router.pop_to_root()
	assert_eq(action.kind, Router.ActionKind.NONE, "pop_to_root on an empty stack does nothing")


func _test_back_handling() -> void:
	begin("back pops a pushed screen first (semantic 4)")
	var router := _make()
	router.push(Routes.GALLERY)
	var action := router.handle_back(false)
	assert_eq(action.kind, Router.ActionKind.POP, "back pops while the stack is non-empty")
	assert_eq(router.stack_depth(), 0, "stack drained")

	begin("back on a non-home tab returns to home, not exit")
	router.switch_tab(3)
	action = router.handle_back(true)
	assert_eq(action.kind, Router.ActionKind.POP_TO_TAB, "back goes to the home tab")
	assert_eq(action.tab, 0, "home is tab 0")
	assert_eq(router.active_tab(), 0, "active tab is home again")

	begin("back on home with an unarmed double-back does nothing")
	action = router.handle_back(false)
	assert_eq(action.kind, Router.ActionKind.NONE, "first back must not quit")
	assert_false(action.changed, "and reports no change")

	begin("back on home when armed quits")
	action = router.handle_back(true)
	assert_eq(action.kind, Router.ActionKind.QUIT, "the second back within the window quits")
	assert_true(action.changed, "quitting is a change")

	begin("back never pops while a non-home tab is active")
	router = _make()
	router.switch_tab(2)
	router.push(Routes.GALLERY)
	action = router.handle_back(false)
	assert_eq(action.kind, Router.ActionKind.POP, "pushed screens still pop before tabs")


func _test_args_retention() -> void:
	begin("tab args are remembered per route")
	var router := _make()
	router.goto(Routes.PLAN, {"highlight": "day-2"})
	assert_eq(router.args_of(Routes.PLAN).get("highlight", ""), "day-2",
		"args survive on the tab route")
	assert_true(router.args_of(Routes.TRACKER).is_empty(),
		"an unrelated tab has no args")

	begin("push args reach the action")
	var action := router.push(Routes.GALLERY, {"section": "glyphs"})
	assert_eq(action.args.get("section", ""), "glyphs", "args are carried on the action")
	assert_eq(router.current().args.get("section", ""), "glyphs", "and stored on the entry")


func _test_unknown_route() -> void:
	begin("unknown routes are refused (semantic 6)")
	var router := _make()
	var action := router.goto(&"does_not_exist")
	assert_eq(action.kind, Router.ActionKind.NONE, "unknown goto does nothing")
	assert_false(action.changed, "and reports no change")
	assert_eq(router.stack_depth(), 0, "nothing was pushed")
	action = router.push(&"also_missing")
	assert_eq(action.kind, Router.ActionKind.NONE, "unknown push does nothing")


func _test_routes_table_integrity() -> void:
	begin("every declared route has a real scene file")
	for route in Routes.TAB_SCENES:
		var path: String = Routes.TAB_SCENES[route]
		assert_true(ResourceLoader.exists(path), "%s scene missing: %s" % [route, path])
	for route in Routes.TABLE:
		var path: String = Routes.TABLE[route]
		assert_true(ResourceLoader.exists(path), "%s scene missing: %s" % [route, path])

	begin("the shell is the root frame, not a navigable route")
	var router := _make()
	assert_false(router.has(Routes.SHELL),
		"the shell must not be registered as a pushable route (it would push itself)")
	assert_true(ResourceLoader.exists(Routes.TABLE[Routes.SHELL]),
		"but its scene must exist on disk")

	begin("tab metadata is consistent")
	assert_eq(Routes.TAB_ROUTES.size(), 4, "four tabs")
	assert_eq(Routes.TAB_TITLES.size(), Routes.TAB_ROUTES.size(), "a title per tab")
	assert_eq(Routes.TAB_GLYPHS.size(), Routes.TAB_ROUTES.size(), "a glyph per tab")
	assert_eq(Routes.TAB_ROUTES[0], Routes.HOME, "home is the first tab")
