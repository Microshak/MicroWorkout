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
## PRD-12 R8 — the exact copy for the three boot states.
const LOADING_COPY := "Loading…"
const SLOW_COPY := "Still loading — first-time setup can take a few seconds."
const ERROR_COPY := "Something went wrong starting up."
## After this long, "Loading…" becomes the slow variant.
const SLOW_HINT_SEC := 4.0

var _slow_hint: Timer = null
## PRD-12 R8 — the boot error state's destructive escape hatch (see `_show_error()`).
var _reset_dialog: ConfirmationDialog = null
var _reset_field: LineEdit = null


func _ready() -> void:
	print("[boot] %s %s ready" % [AppInfo.NAME, AppInfo.VERSION])
	print("[boot] platform=%s" % OS.get_name())
	if is_instance_valid(_status):
		_status.text = LOADING_COPY
	_slow_hint = Timer.new()
	_slow_hint.name = "SlowHint"
	_slow_hint.wait_time = SLOW_HINT_SEC
	_slow_hint.one_shot = true
	_slow_hint.timeout.connect(_on_slow_hint)
	add_child(_slow_hint)
	_slow_hint.start()
	_boot()


func _on_slow_hint() -> void:
	# Only while still on this screen: once the shell owns the window the hint is meaningless.
	if is_instance_valid(_status) and _status.text == LOADING_COPY:
		_status.text = SLOW_COPY


## PRD-12 R8's boot failure state: the copy, a working retry, and a destructive way out that
## reuses PRD-06's type-the-word guard (`Strings.RESET_WORD`, the same constant Settings uses).
func _show_error() -> void:
	if is_instance_valid(_status):
		_status.text = ERROR_COPY
	print("[boot] error — store not loaded (%s)" % Store.last_error())
	var box := _status.get_parent() as VBoxContainer if is_instance_valid(_status) else null
	if box == null:
		return
	if box.has_node(^"RetryButton"):
		return
	var retry := Button.new()
	retry.name = "RetryButton"
	retry.text = "Try again"
	retry.theme_type_variation = &"PrimaryButton"
	TouchTargets.enforce(retry)
	A11y.label(retry, "Try again")
	retry.pressed.connect(_on_retry_pressed)
	box.add_child(retry)

	var reset := Button.new()
	reset.name = "ResetAppDataButton"
	reset.text = "Reset app data"
	reset.theme_type_variation = &"DangerButton"
	TouchTargets.enforce(reset)
	A11y.label(reset, "Reset all app data, cannot be undone")
	reset.pressed.connect(_on_reset_pressed)
	box.add_child(reset)

	_reset_dialog = ConfirmationDialog.new()
	_reset_dialog.name = "ResetConfirm"
	_reset_dialog.title = Strings.RESET_TITLE
	_reset_dialog.dialog_text = Strings.RESET_BODY + "\n\n" + Strings.RESET_WARNING
	_reset_dialog.ok_button_text = Strings.RESET_OK
	_reset_dialog.cancel_button_text = Strings.RESET_CANCEL
	_reset_dialog.exclusive = true
	add_child(_reset_dialog)
	_reset_field = LineEdit.new()
	_reset_field.name = "TypeReset"
	_reset_field.theme_type_variation = &"Input"
	_reset_field.placeholder_text = Strings.RESET_WORD
	TouchTargets.enforce(_reset_field)
	A11y.label(_reset_field, "Type %s to confirm" % Strings.RESET_WORD)
	_reset_dialog.add_child(_reset_field)
	_reset_dialog.about_to_popup.connect(_update_reset_guard)
	_reset_field.text_changed.connect(func(_text: String) -> void: _update_reset_guard())
	_reset_dialog.confirmed.connect(_on_reset_confirmed)


func _on_retry_pressed() -> void:
	Store.load_all()
	if is_instance_valid(_status):
		_status.text = LOADING_COPY
	if is_instance_valid(_slow_hint):
		_slow_hint.start()
	_boot()


func _on_reset_pressed() -> void:
	_reset_field.text = ""
	_update_reset_guard()
	_reset_dialog.popup_centered()


func _update_reset_guard() -> void:
	if _reset_dialog == null or _reset_field == null:
		return
	_reset_dialog.get_ok_button().disabled = \
		_reset_field.text.rstrip(" \t\r\n") != Strings.RESET_WORD


func _on_reset_confirmed() -> void:
	if _reset_field.text.rstrip(" \t\r\n") != Strings.RESET_WORD:
		return
	var _wiped: bool = Store.reset_all()
	print("[boot] reset_all done; restarting")
	# Back through boot, exactly like Settings' Danger section does (R12).
	var _err := get_tree().change_scene_to_file(Routes.scene_for(Routes.BOOT))


func _boot() -> void:
	await get_tree().create_timer(AppInfo.MIN_SPLASH_SECONDS).timeout
	# PRD-12 R8: a store that never loaded is the one boot failure this screen can see, and it is
	# the one the owner can act on — retry, or wipe what is broken (PRD-00 §6's quarantine has
	# already kept a backup).
	if is_instance_valid(Store) and not Store.is_loaded():
		_show_error()
		return
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
