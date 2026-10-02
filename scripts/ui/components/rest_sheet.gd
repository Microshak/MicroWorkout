extends PanelContainer
## Bottom-sheet rest timer — PRD-10 R10.
##
## The player instantiates this as `RestSheet` and owns the interaction: it decides *whether* a rest
## happens (it was not the last set, the block asked for rest, `rest_timer.enabled` is on), plays
## `rest_skip` / `rest_done` / `rest_add`, and fires the haptics. This component only counts down,
## drains its bar and reports through [signal skipped] / [signal finished] / [signal time_added].
## It plays no sound, does no haptics, and never calls `Nav`.
##
## The countdown is driven by one internal 1 s `Timer` — never `_process` (R17) — and every path
## that leaves a rest (Next, Previous, Pause, another set check, `APPLICATION_PAUSED`) cancels it
## through [method stop_rest], which is deliberately silent: a countdown that "came back" after a
## backgrounding would be worse than no countdown at all.
##
## The sheet never gates anything (PRD-00 §9): it is anchored `offset_bottom = -136`, so the nav row
## below it stays fully visible and tappable while it is up.

## The owner tapped `Skip rest`.
signal skipped

## The countdown reached zero. Emitted at once; the sheet itself hides [constant HIDE_MS] later.
signal finished

## `+15s`: always [constant ADD_SECONDS], so the player can log/play the right cue.
signal time_added(seconds: int)

## `+15s` per tap (R10).
const ADD_SECONDS := 15

## R10: total *remaining* time is capped here, so a bored owner cannot stack a 10 minute rest.
const MAX_REMAINING := 300

## R10's clamp for [method start_rest]. PRD-03 validates `rest_timer.default_seconds` 15..300, but a
## stored block may legitimately be shorter, and a 600 s ceiling keeps a corrupt document sane.
const MIN_SECONDS := 1
const MAX_SECONDS := 600

## R10: slide up 200 ms ease-out, hide 400 ms after zero.
const SLIDE_MS := 200
const HIDE_MS := 400

## Shown before the first [method start_rest] — the scene's authored countdown text.
const IDLE_LABEL := "1:30"

## The anchored bottom offset the sheet rests at (R10's `offset_bottom = -136`), captured in
## `_ready()` *before* any slide moves `position`, so the resting place can always be recomputed
## exactly even after an interrupted slide.
var _rest_bottom_offset: float = -136.0

## Node references, cached on first use: `NOTIFICATION_THEME_CHANGED` can arrive before `_ready()`,
## and the 1 s tick must not call `get_node()` (R17).
var _countdown_label: Label = null
var _bar: ProgressBar = null
var _add_button: Button = null
var _skip_button: Button = null

var _timer: Timer = null
var _tween: Tween = null
var _total_seconds: int = 0
var _remaining: int = 0
var _active: bool = false
var _paused: bool = false


func _ready() -> void:
	_cache_nodes()
	# The resting offset must be read before the first slide can move `position` (which rewrites
	# both offsets), and after the first layout pass (which is what resolves the anchored rect).
	_rest_bottom_offset = offset_bottom
	_timer = Timer.new()
	_timer.name = &"RestTimer"
	_timer.wait_time = 1.0
	_timer.one_shot = false
	_timer.autostart = false
	add_child(_timer)
	_timer.timeout.connect(_on_countdown_tick)
	# Authored as `visible = false` too: a sheet that opens itself would cover the nav row before
	# the first set is checked.
	visible = false
	_add_button.pressed.connect(_on_add_pressed)
	_skip_button.pressed.connect(_on_skip_pressed)
	_sync()
	# Nothing here hard-codes a colour — the sheet, the labels and the two buttons take their whole
	# look from the theme's `Sheet` / `Caption` / `DisplayLabel` / `PrimaryButton` / `GhostButton`
	# variations — but a live dark↔light swap still has to re-render the state-derived text and bar.
	# Owner feedback (ADR-41): `Skip rest` is the primary action and `+15s` the quiet one, because
	# the sheet was reported as "a timer I can't get past" when the way out looked secondary.
	if is_instance_valid(App) and not App.theme_changed.is_connected(_on_theme_changed):
		App.theme_changed.connect(_on_theme_changed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()


# ------------------------------------------------------------------ R10 API

## Starts (or restarts) a rest of [param seconds], clamped to 1..600, and slides the sheet up
## 200 ms ease-out. Safe to call while a previous rest is still counting: the old countdown is
## replaced, never stacked.
func start_rest(seconds: int) -> void:
	_total_seconds = clampi(seconds, MIN_SECONDS, MAX_SECONDS)
	_remaining = _total_seconds
	_active = true
	_paused = false
	_sync()
	_show()


## Cancels the countdown and hides the sheet **immediately**, emitting nothing (R10: Next, Previous,
## Pause, another set check, `APPLICATION_PAUSED`). The remaining seconds are intentionally not
## restored by a later [method start_rest] — a rest timer that came back hours later is worse than
## no rest timer.
func stop_rest() -> void:
	_active = false
	_paused = false
	_stop_timer()
	_kill_tween()
	_hide_now()


## `Skip rest`: hides immediately and reports the skip, so the player can play `rest_skip`.
func skip() -> void:
	_active = false
	_paused = false
	_stop_timer()
	_kill_tween()
	_hide_now()
	skipped.emit()


## Freezes the countdown without hiding the sheet (the player calls this when it pauses).
func pause_countdown() -> void:
	if not _active:
		return
	_paused = true
	_stop_timer()


## Resumes a frozen countdown. The next tick is a full second later, which is what a paused clock
## should do — the elapsed pause is never silently counted as rest.
func resume_countdown() -> void:
	if not _active:
		return
	_paused = false
	_start_timer()


## Seconds left on the current countdown (`0` when it has never started or has finished).
func remaining_seconds() -> int:
	return _remaining


## Total seconds [method start_rest] was given, grown by any `+15s` taps.
func total_seconds() -> int:
	return _total_seconds


## True while the 1 s countdown is actually ticking — false while paused, finished, skipped or
## stopped. The player keeps its own `REST` state; this only reports the clock.
func is_running() -> bool:
	return _active and not _paused


## The `"1:30"` countdown label, for the player's assertions.
func countdown_label() -> Label:
	if _countdown_label == null:
		_countdown_label = get_node_or_null(^"RestVBox/RestCountdownLabel") as Label
	return _countdown_label


## The draining bar, for the player's assertions.
func bar() -> ProgressBar:
	if _bar == null:
		_bar = get_node_or_null(^"RestVBox/RestBar") as ProgressBar
	return _bar


# ------------------------------------------------------------------ countdown

func _on_countdown_tick() -> void:
	if not _active or _paused:
		return
	_remaining = maxi(_remaining - 1, 0)
	_sync()
	if _remaining == 0:
		_finish()


## Zero (R10): the player is told at once, so its `rest_done` cue and the double vibration are not
## delayed by the sheet's own fade, and the sheet hides [constant HIDE_MS] later.
func _finish() -> void:
	_active = false
	_paused = false
	_stop_timer()
	finished.emit()
	_kill_tween()
	var tween := create_tween()
	tween.tween_interval(float(HIDE_MS) / 1000.0)
	tween.tween_callback(_hide_now)
	_tween = tween


## `+15s` (R10): capped at [constant MAX_REMAINING] total *remaining*, and the bar's denominator
## grows with the numerator so adding time can never push the bar past 1.0.
func _on_add_pressed() -> void:
	if not _active:
		return
	_remaining = mini(_remaining + ADD_SECONDS, MAX_REMAINING)
	_total_seconds = maxi(_total_seconds, _remaining)
	_sync()
	time_added.emit(ADD_SECONDS)


func _on_skip_pressed() -> void:
	skip()


# ------------------------------------------------------------------ rendering and motion

## One place that renders state: the `"M:SS"` text ([method Dates.format_clock]) and the draining
## fraction, both re-applied after a theme switch and on every tick.
func _sync() -> void:
	var label := _countdown_label
	if label != null:
		label.text = Dates.format_clock(_remaining) if _total_seconds > 0 else IDLE_LABEL
	var progress := _bar
	if progress != null:
		var fraction := 1.0
		if _total_seconds > 0:
			fraction = clampf(float(_remaining) / float(_total_seconds), 0.0, 1.0)
		progress.value = fraction


func _apply_theme() -> void:
	_sync()


func _on_theme_changed(_mode: String) -> void:
	_apply_theme()


## R10: slides up 200 ms ease-out to its anchored resting place.
##
## The resting y is derived from the anchor math rather than from the current `position`, so a slide
## that was interrupted by [method stop_rest] can never leave the sheet parked in the wrong place:
## `offset_bottom` is the sheet's bottom edge, and its height comes from its own content.
## Re-anchors the sheet's bottom edge, in the same units as `offset_bottom`.
##
## The player calls this so the sheet *ends where the set chips begin*. R2 fixes `offset_bottom =
## -136` to keep the footer row tappable (`NavRow` when this was written; the swipe hint row
## since ADR-22), and measured on the device that put the sheet's own `+15s` /
## `Skip rest` buttons exactly over the chips (`SetRow` at viewport y 1933–2021, sheet at 1797–2069):
## tapping the next set hit `+15s` instead, i.e. the rest timer *did* gate another set check — the
## one thing R10 forbids. The height is measured per layout, so this works on any screen.
func set_bottom_offset(value: float) -> void:
	_rest_bottom_offset = value
	offset_bottom = value
	if visible:
		position.y = _resting_y()


func _show() -> void:
	_cache_nodes()
	_kill_tween()
	visible = true
	# Debug-build finding aid for the Android tap tests (`tools/tap_ui.sh`): they need the on-screen
	# rects of `+15s` and `Skip rest`, which only exist while the sheet is up.
	UiProbe.log_rect("rest_add_time", _add_button)
	UiProbe.log_rect("rest_skip", _skip_button)
	var rest_y := _resting_y()
	position.y = rest_y
	_start_timer()
	if _reduce_motion():
		# Appendix §4.4: decorative motion is skipped, never shortened.
		return
	# A layout that has not happened yet would make the slide zero-length; one pixel is the floor.
	position.y = rest_y + maxf(size.y, 1.0)
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "position:y", rest_y, float(SLIDE_MS) / 1000.0)
	_tween = tween


## The y the sheet rests at: its anchored bottom edge (R10's `offset_bottom = -136`) minus its own
## height. Recomputed on every show, so the slide always ends exactly where the anchors put it.
func _resting_y() -> float:
	return get_parent_area_size().y + _rest_bottom_offset - size.y


func _hide_now() -> void:
	_tween = null
	visible = false


func _start_timer() -> void:
	var timer := _timer
	if timer == null:
		return
	timer.stop()
	timer.start()


func _stop_timer() -> void:
	var timer := _timer
	if timer == null:
		return
	timer.stop()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


func _cache_nodes() -> void:
	if _countdown_label == null:
		_countdown_label = get_node_or_null(^"RestVBox/RestCountdownLabel") as Label
	if _bar == null:
		_bar = get_node_or_null(^"RestVBox/RestBar") as ProgressBar
	if _add_button == null:
		_add_button = get_node_or_null(^"RestVBox/RestButtons/AddTimeButton") as Button
	if _skip_button == null:
		_skip_button = get_node_or_null(^"RestVBox/RestButtons/SkipRestButton") as Button


## `Nav` exposes only `set_reduce_motion()`, so the setting is read through `Motion`, the one
## accessor every component shares (PRD-12 R1).
func _reduce_motion() -> bool:
	return not Motion.decorative_enabled()
