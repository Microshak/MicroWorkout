extends Control
## Splash / boot screen.
##
## PRD-01: prints identity + platform (the Android smoke test greps for this line),
## holds the splash for a moment, then routes on.
##
## PRD-02 R20: boot is the only place allowed to replace the main scene. PRD-06 R4.3 uses that
## to gate first run: when `onboarding_complete` is false the wizard *is* the next main scene,
## otherwise the app goes straight to the shell. Nothing else in the app decides this, so
## "am I onboarded?" has exactly one answer and one code path.

## PRD-10 R5's file list adds one thing here: the debug-only `--autostart=player-fixture` smoke run
## needs the shell to exist before anything can be pushed into it, so it waits out the shell's own
## load. `App` returns no request outside a debug build, so a release APK never reaches this.

@onready var _status: Label = $Center/VBox/Status

## How long the shell is given to come up before the autostart push.
const AUTOSTART_DELAY_SEC := 1.2


func _ready() -> void:
	print("[boot] %s %s ready" % [AppInfo.NAME, AppInfo.VERSION])
	print("[boot] platform=%s" % OS.get_name())
	_boot()


func _boot() -> void:
	await get_tree().create_timer(AppInfo.MIN_SPLASH_SECONDS).timeout
	if is_instance_valid(_status):
		_status.text = "Ready"
	var first_run := not onboarding_complete()
	var autostart := App.autostart_request()
	# The flag implies the shell: the owner is already onboarded on the machine that runs it, and a
	# smoke run that lands in the wizard would prove nothing about the player.
	var target := Routes.ONBOARDING if first_run else Routes.SHELL
	if not autostart.is_empty():
		target = Routes.SHELL
	print("[boot] onboarding_complete=%s goto=%s" % [str(not first_run), target])
	if not autostart.is_empty():
		# Scheduled **before** the scene swap: `Nav.goto(SHELL)` frees this screen, so a timer awaited
		# on it would die with it (`get_tree()` on a freed node is a null call). `App` owns the wait.
		App.schedule_autostart(AUTOSTART_DELAY_SEC)
	_goto_main_scene(target)


## True once the wizard has been finished. `App.get_setting` delegates to `Store`, and a missing
## or unreadable `settings.json` yields the default `false` — which is precisely the first-run
## behaviour R4.3 asks for (appendix §5.1).
func onboarding_complete() -> bool:
	return bool(App.get_setting("onboarding_complete", false))


## Loads a main-scene route. The shell is installed by [Nav] (it owns the frame's lifecycle);
## the wizard is a plain main-scene replacement, which is what appendix §2 marks "main scene".
func _goto_main_scene(route: StringName) -> void:
	if route == Routes.SHELL:
		Nav.goto(Routes.SHELL)
		return
	var path := Routes.scene_for(route)
	if path.is_empty():
		push_error("[boot] no scene for route '%s'" % route)
		return
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("[boot] cannot load %s (error %d)" % [path, err])
