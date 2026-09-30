extends Node
## Haptics, UI sounds, and toasts.
##
## PRD-02 R19 implements the toast layer; PRD-12 R2 adds the other two senses: five generated
## cue sounds (`assets/audio/ui/ui_{tap,select,success,error,celebrate}.wav`, mono 22050 Hz,
## routed to the `UI` bus `App` creates) and amplitude-scaled `Input.vibrate_handheld()`
## patterns. Every cue is a no-op when its switch is off, when the asset is missing, or on a
## platform without a vibrator — feedback never blocks an input path and never throws.
##
## `Feedback.toast()` also writes into the shell's polite live region through `A11y.announce()`,
## so anything shown is spoken, and a failure toast additionally plays the error cue.

signal toast_shown(text: String, kind: StringName)
signal toast_dismissed

const TOAST_SCENE := "res://scenes/components/toast.tscn"
const TOAST_GAP := 24       # px above the bottom nav

## The five cues, by name — the file name is `ui_<cue>.wav`.
const CUE_DIR := "res://assets/audio/ui"
const CUES: PackedStringArray = ["tap", "select", "success", "error", "celebrate"]
## Overlapping cues (a tap under a celebration) need more than one player; three is enough for
## a hand-held UI and costs nothing until it plays.
const SFX_POOL_SIZE := 3

## ui.sound_enabled / ui.haptics_enabled — written by App on boot and on every change.
var sfx_enabled: bool = true
var haptics_enabled: bool = true

var _toast: Control = null
var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_cache: Dictionary = {}
var _sfx_cursor: int = 0
## True once a caller has reported that this device cannot vibrate (see
## [method mark_haptics_unavailable]); haptics then stay silent for the whole run.
var _haptics_available: bool = OS.has_feature("android")
## One notice per process as well as per install: a failed settings write must not turn the
## message into a per-tap popup.
var _unavailable_notice_shown: bool = false

# Debug observability, like `[tracker]` and `[ui]` lines: AC9 asserts that a tap, a set, a
# session and an error each produced the specified feedback, and a silent no-op leaves nothing
# in logcat to grep. Counters are the evidence a headless suite can also assert on.
var _sounds_played: int = 0
var _haptics_fired: int = 0


func _ready() -> void:
	print("[Feedback] ready cues=%d android=%s" % [CUES.size(), OS.has_feature("android")])


## Three sequential phases from DesignTokens.MOTION: in 120 ms / hold 2600 ms / out 180 ms.
func toast(text: String, kind: StringName = &"info") -> void:
	# PRD-12 R5: shown and spoken. R2: a failure also gets the error cue. Both happen before the
	# visual layer is looked up, so a boot-time toast (no shell yet) is still announced, still
	# sounds, and is still observed by `toast_shown` — the log line below is not the only thing
	# that survives.
	A11y.announce(text)
	if kind == &"danger" or kind == &"warning":
		error()
	toast_shown.emit(text, kind)

	var layer := _toast_layer()
	if layer == null:
		# Before the shell exists there is nowhere to show a toast; the log line keeps the
		# message discoverable rather than silently dropping it.
		print("[toast] %s (%s)" % [text, kind])
		return

	dismiss_toast()

	# Debug-only observability, like `UiProbe`'s rect lines: a toast is a user-visible outcome and
	# AC9 asserts one ("Session discarded."), but a toast layer that exists leaves nothing in logcat
	# to grep — and the banner is gone in 2.6 s, which is under two frames on the emulator.
	if OS.is_debug_build():
		print("[toast] %s (%s)" % [text, kind])

	if not ResourceLoader.exists(TOAST_SCENE):
		push_warning("[Feedback] toast scene missing: %s" % TOAST_SCENE)
		return

	var scene: PackedScene = load(TOAST_SCENE)
	_toast = scene.instantiate()
	layer.add_child(_toast)

	if _toast.has_method(&"show_message"):
		_toast.call(&"show_message", text, kind)

	_toast.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_toast.offset_left = DesignTokens.GUTTER
	_toast.offset_right = -DesignTokens.GUTTER
	_toast.offset_bottom = -(DesignTokens.NAV_BAR_HEIGHT + TOAST_GAP)

	_toast.modulate.a = 0.0
	var hold_ms := int(DesignTokens.MOTION["toast_hold_ms"])
	var tween := create_tween()
	tween.tween_property(_toast, "modulate:a", 1.0,
		float(DesignTokens.MOTION["toast_in_ms"]) / 1000.0)
	tween.tween_interval(float(hold_ms) / 1000.0)
	tween.tween_property(_toast, "modulate:a", 0.0,
		float(DesignTokens.MOTION["toast_out_ms"]) / 1000.0)
	tween.tween_callback(dismiss_toast)

	toast_shown.emit(text, kind)


func dismiss_toast() -> void:
	if _toast != null and is_instance_valid(_toast):
		_toast.queue_free()
		_toast = null
		toast_dismissed.emit()


func has_toast() -> bool:
	return _toast != null and is_instance_valid(_toast)


func _toast_layer() -> Control:
	var shell := Nav.shell()
	if shell == null or not is_instance_valid(shell):
		return null
	return shell.toast_layer()


# ------------------------------------------------------------------ cues (PRD-12 R2)

## A button was pressed: the shortest acknowledgement there is.
func tap() -> void:
	_buzz(12, 0.4)
	_play(&"tap")


## A choice was made — a set checked off, an option selected.
func select() -> void:
	_buzz(20, 0.5)
	_play(&"select")


## A unit of work completed: the last set, a partial session ending, a goal reached.
func success() -> void:
	_buzz(30, 0.7)
	_play(&"success")


## Something failed. Two short buzzes 60 ms apart, mirroring the two falling notes.
func error() -> void:
	_play(&"error")
	_buzz(60, 0.9)
	_buzz_after(0.06, 60, 0.9)


## The session finished. The PRD-10 completion sequence calls this once, starts the haptic
## pattern and does **not** await it (R2: never awaiting in a signal path).
func celebrate() -> void:
	_play(&"celebrate")
	_celebrate_pattern()


## PRD-12 R2 — one switch per sense. App calls this on boot and whenever
## `ui.sound_enabled` / `ui.haptics_enabled` changes.
func set_enabled(sound: bool, haptics: bool) -> void:
	sfx_enabled = sound
	haptics_enabled = haptics


## Called when a caller detects that this device cannot vibrate (no permission in the built
## manifest, or no vibrator): haptics stay off for the rest of the run and the owner is told
## **once per install**, guarded by `ui.haptics_unavailable_shown`.
func mark_haptics_unavailable() -> void:
	_haptics_available = false
	if _unavailable_notice_shown:
		return
	_unavailable_notice_shown = true
	if bool(App.get_setting("ui.haptics_unavailable_shown", false)):
		return
	var _written := App.set_setting("ui.haptics_unavailable_shown", true)
	toast("Haptics aren't available on this device.", &"info")


func haptics_available() -> bool:
	return _haptics_available and haptics_enabled


## How many cues have actually reached an AudioStreamPlayer, and how many haptic calls were
## made. Tests and the AC9 evidence read these; production code never does.
func sounds_played() -> int:
	return _sounds_played


func haptics_fired() -> int:
	return _haptics_fired


# ------------------------------------------------------------------ internals

func _play(cue: StringName) -> void:
	if not sfx_enabled:
		return
	var path := "%s/ui_%s.wav" % [CUE_DIR, cue]
	var stream: AudioStream = _sfx_cache.get(path)
	if stream == null:
		if not ResourceLoader.exists(path):
			# PRD-12 ships the WAVs; a stripped build without them stays silent rather than
			# erroring, exactly like PRD-10's optional `.ogg` hooks did.
			_sfx_cache[path] = null
			return
		stream = ResourceLoader.load(path) as AudioStream
		_sfx_cache[path] = stream
		if stream == null:
			return
	var player := _next_player()
	player.stream = stream
	player.play()
	_sounds_played += 1
	if OS.is_debug_build():
		print("[feedback] cue=%s sounds=%d" % [cue, _sounds_played])


## Round-robin over the pool so a tap during a celebration still sounds.
func _next_player() -> AudioStreamPlayer:
	if _sfx_players.is_empty():
		for i in SFX_POOL_SIZE:
			var fresh := AudioStreamPlayer.new()
			fresh.name = "Cue%d" % (i + 1)
			fresh.bus = "UI"
			add_child(fresh)
			_sfx_players.append(fresh)
	var chosen: AudioStreamPlayer = _sfx_players[_sfx_cursor % _sfx_players.size()]
	_sfx_cursor += 1
	return chosen


func _buzz(ms: int, amplitude: float) -> void:
	if not haptics_available() or ms <= 0:
		return
	_haptics_fired += 1
	Input.vibrate_handheld(ms, amplitude)


## Waits [param delay] seconds, then buzzes — the sequenced half of [method error] and
## [method celebrate]. Started, never awaited (R2).
func _buzz_after(delay: float, ms: int, amplitude: float) -> void:
	if not haptics_available():
		return
	var timer := get_tree().create_timer(delay)
	timer.timeout.connect(_buzz.bind(ms, amplitude), CONNECT_ONE_SHOT)


## 40/0.7 → 60 ms → 40/0.7 → 60 ms → 80/1.0, the sequence R2 specifies for a finished session.
func _celebrate_pattern() -> void:
	if not haptics_available():
		return
	_buzz(40, 0.7)
	_buzz_after(0.06, 40, 0.7)
	_buzz_after(0.12, 80, 1.0)
