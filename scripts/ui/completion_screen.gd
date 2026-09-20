extends Control
## PRD-10 R12 — the payoff screen: a real celebration, then one `Done` action back to Home.
##
## This is the moment the whole app exists for, so it is written as a **timeline** rather than as a
## pile of animations: `_play_celebration()` is R12's table read top to bottom, every entry is a
## tween with its own delay, and `_apply_final_state()` is the single place that knows what "the end
## of the timeline" looks like — which is what makes the celebration skippable in one frame (R12: no
## animation may gate input, and `Done` is live from frame 0).
##
## Numbers are never re-derived here. `Streak`/`Store` own the streak and the ring (PRD-03), PRD-09's
## `weekly_ring` owns the ring's own sweep, PRD-05's `Progression` owns the advice line, and this
## screen only shows what they say. `partial` is the honest variant: a session ended early gets
## `"Session logged."`, a warning-tinted check, no confetti, no streak count-up and no ring sweep.

## R12's copy.
const TITLE_FULL := "You finished."
const TITLE_PARTIAL := "Session logged."
const ADVICE_TITLE := "NEXT TIME"

## R12: when PRD-05's `Progression.advise()` is missing or returns nothing.
const ADVICE_FALLBACK := "Keep the same weights next time and add one rep to your last set."

## R12's timeline, milliseconds from the screen being ready.
const CELEBRATION_MS := 1600
const FADE_IN_MS := 150
const CHECK_MS := 260
const VIBRATE_AT_MS := 200
const TITLE_AT_MS := 160
const TITLE_MS := 240
const ROW_AT_MS := 300
const ROW_MS := 320
const ROW_STAGGER_MS := 80
const STREAK_AT_MS := 400
const STREAK_MS := 500
const FLAME_AT_MS := 900
const FLAME_MS := 320
const RING_AT_MS := 500
const ADVICE_AT_MS := 1100
const ADVICE_MS := 160

## R2/R12: the check mark is a drawn glyph, and R16 forbids a filled-box substitute.
const CHECK_SIZE := 160.0

@onready var _background: ColorRect = $Background
@onready var _confetti: CPUParticles2D = $Confetti
@onready var _check: Control = $SafeArea/Content/CheckMark
@onready var _title: Label = $SafeArea/Content/TitleLabel
@onready var _subtitle: Label = $SafeArea/Content/SubtitleLabel
@onready var _summary_card: PanelContainer = $SafeArea/Content/SummaryCard
@onready var _time_value: Label = $SafeArea/Content/SummaryCard/SummaryVBox/SummaryRow_Time/ValueLabel
@onready var _exercises_value: Label = $SafeArea/Content/SummaryCard/SummaryVBox/SummaryRow_Exercises/ValueLabel
@onready var _sets_value: Label = $SafeArea/Content/SummaryCard/SummaryVBox/SummaryRow_Sets/ValueLabel
@onready var _stats_row: HBoxContainer = $SafeArea/Content/StatsRow
@onready var _streak_tile: PanelContainer = $SafeArea/Content/StatsRow/StreakTile
@onready var _ring_tile: Control = $SafeArea/Content/StatsRow/RingTile
@onready var _advice_card: PanelContainer = $SafeArea/Content/AdviceCard
@onready var _advice_label: Label = $SafeArea/Content/AdviceCard/AdviceVBox/AdviceLabel
@onready var _done_button: Button = $SafeArea/Content/DoneButton
@onready var _sfx_player: AudioStreamPlayer = $SfxPlayer

var _entry: Dictionary = {}
var _partial: bool = false
var _plan: Dictionary = {}
var _started_ms: int = 0
var _celebration_running: bool = false
var _skipped: bool = false
var _owns_back: bool = false
var _tweens: Array[Tween] = []

var _streak_before: int = 0
var _streak_after: int = 0
var _ring_before: float = 0.0
var _ring_after: float = 0.0
var _ring_target: int = 0
var _row_nodes: Array[Control] = []

static var _stream_cache: Dictionary = {}


# ===========================================================================
# Lifecycle
# ===========================================================================

func _ready() -> void:
	_background.color = DesignTokens.color(App.theme_mode, "bg")
	_confetti.color_ramp = _confetti_ramp()
	if not App.theme_changed.is_connected(_on_theme_changed):
		App.theme_changed.connect(_on_theme_changed)
	_done_button.pressed.connect(_on_done_pressed)
	_check.custom_minimum_size = Vector2(CHECK_SIZE, CHECK_SIZE)
	_row_nodes = [
		$SafeArea/Content/SummaryCard/SummaryVBox/SummaryRow_Time,
		$SafeArea/Content/SummaryCard/SummaryVBox/SummaryRow_Exercises,
		$SafeArea/Content/SummaryCard/SummaryVBox/SummaryRow_Sets,
	]
	# R12: the celebration owns back while it is up; the router must not pop it into a finished
	# player (the player is already gone — `Nav.replace` cleared the stack).
	Nav.set_back_handling(false)
	_owns_back = true
	# Published twice (immediately, then 1 s later with `settled=1`): `_ready()` runs before the first
	# layout, so the immediate rect is `(0, 72)` and a tap computed from it lands nowhere.
	UiProbe.log_rects_settled(get_tree(), {"complete_done": _done_button}, 1.0)


## `Nav` calls this right after `add_child`.
func setup(args: Dictionary) -> void:
	var raw: Variant = args.get("entry", null)
	if raw is Dictionary:
		_entry = raw
	_partial = bool(args.get("partial", not bool(_entry.get("completed", false))))
	_plan = Store.get_plan(String(_entry.get("plan_id", "")))
	_fill_content()
	_started_ms = Time.get_ticks_msec()
	_play_celebration()


func _exit_tree() -> void:
	# Same idempotent hand-back as the player: the router frees this node *after* the next screen's
	# `_ready()`, so an unconditional restore here would turn back handling on under Home's feet.
	_release_back()


# ===========================================================================
# Content (R12)
# ===========================================================================

func _fill_content() -> void:
	var duration := int(_entry.get("duration_sec", 0))
	var completed := int(_entry.get("exercises_completed", 0))
	var total := int(_entry.get("exercises_total", 0))
	var sets_done := int(_entry.get("sets_completed", 0))
	var sets_total := int(_entry.get("sets_total", 0))
	var title := TITLE_PARTIAL if _partial else TITLE_FULL

	_title.text = title
	_subtitle.text = String(_entry.get("session_title", ""))
	_time_value.text = Dates.format_clock(duration)
	_exercises_value.text = "%d of %d" % [completed, total]
	_sets_value.text = "%d of %d" % [sets_done, sets_total]

	var check_token := "warning" if _partial else "success"
	_check.add_theme_color_override(&"color", DesignTokens.color(App.theme_mode, check_token))

	_streak_before = _streak_for(_history_before())
	_streak_after = Store.streak_days()
	_streak_tile.call(&"set_stat", "DAY STREAK", str(_streak_after), &"flame")

	_ring_target = Store.weekly_goal_days_effective()
	# `_history_before()` is typed `Array[Dictionary]` on purpose: `Streak`'s helpers take that exact
	# type, and an untyped `Array` is a runtime error ("does not have the same element type as the
	# expected typed array argument") that silently skipped the rest of this function — including the
	# advice line, which shipped empty on the first device run of the celebration.
	_ring_before = Streak.week_goal_progress(_history_before(), Store.today_local_iso(),
		_ring_target)
	_ring_after = Store.weekly_goal_progress()
	# The pre-entry state is painted first so the sweep has something to travel from (R12). The
	# partial variant has no sweep, so it is painted once, at the end, by [method _apply_final_state].
	if not _partial:
		_apply_ring(_ring_before, _history_before())

	_advice_label.text = _advice_line()

	print("[complete] entry=%s partial=%s duration=%d exercises=%d/%d sets=%d/%d streak=%d" % [
		String(_entry.get("id", "")), str(_partial), duration, completed, total, sets_done, sets_total,
		_streak_after])


## The history as it was **before** this entry was committed — the only way to show a count-up
## without the player having to pass the old numbers in.
func _history_before() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var entry_id := String(_entry.get("id", ""))
	for element in Store.all_entries():
		var other: Dictionary = element
		if not entry_id.is_empty() and String(other.get("id", "")) == entry_id:
			continue
		out.append(other)
	return out


func _streak_for(entries: Array[Dictionary]) -> int:
	return Streak.current_streak(entries, Store.today_local_iso())


func _apply_ring(fraction: float, entries: Array[Dictionary]) -> void:
	var week_id := Store.current_week_id()
	var bits := Streak.ring_segments(entries, week_id, _ring_target)
	var completed := Streak.completed_days_in_week(entries, week_id)
	_ring_tile.call(&"set_week", completed, _ring_target, fraction, bits)


## R15: the first line of `Progression.advise()`, clipped for the card. PRD-05 owns the words; this
## screen only decides what to show when it has nothing.
func _advice_line() -> String:
	var session := _session_dict()
	var advice := ""
	if session.is_empty():
		print("[complete] advice=fallback reason=session")
	else:
		advice = Progression.advise(_plan, session, _history_before())
	var line := Progression.clip(Progression.first_line(advice))
	if line.is_empty():
		print("[complete] advice=fallback")
		return ADVICE_FALLBACK
	return line


func _session_dict() -> Dictionary:
	var session_id := String(_entry.get("session_id", ""))
	for element in _plan.get("sessions", []):
		if not (element is Dictionary):
			continue
		var candidate: Dictionary = element
		if String(candidate.get("id", "")) == session_id:
			return candidate
	return {}


# ===========================================================================
# The celebration (R12)
# ===========================================================================

## R12's timeline, in order. Every entry is a tween with its own delay, so the whole sequence is one
## table read top to bottom and [method _apply_final_state] can short-circuit it in a single frame.
func _play_celebration() -> void:
	_celebration_running = true
	modulate.a = 0.0
	var fade := _track(create_tween())
	fade.tween_property(self, "modulate:a", 1.0, float(FADE_IN_MS) / 1000.0)

	if _partial:
		# The sober variant: everything is on screen at once. No confetti, no count-up, no sweep,
		# and no skip log — there is nothing to skip.
		fade.kill()
		_celebration_running = false
		_apply_final_state()
		_sfx(&"celebration")
		return

	_confetti.emitting = true
	_prepare_hidden()

	# 0–260: the check draws itself, overshooting to 1.08 on `TRANS_BACK` before settling.
	_check.scale = Vector2.ZERO
	_check.pivot_offset = _check.size * 0.5
	var check := _track(create_tween())
	check.set_trans(Tween.TRANS_BACK)
	check.set_ease(Tween.EASE_OUT)
	check.tween_property(_check, "scale", Vector2.ONE * 1.08, float(CHECK_MS) / 1000.0 * 0.75)
	check.tween_property(_check, "scale", Vector2.ONE, float(CHECK_MS) / 1000.0 * 0.25)

	# 200: one strong beat, once.
	get_tree().create_timer(float(VIBRATE_AT_MS) / 1000.0).timeout.connect(_vibrate_celebration)

	# 160–400: the title rises into place.
	_rise(_title, TITLE_AT_MS, TITLE_MS, 16.0)

	# 300–620: the three summary rows stagger in from the left.
	for index in _row_nodes.size():
		var row: Control = _row_nodes[index]
		row.position.x = -12.0
		_rise(row, ROW_AT_MS + index * ROW_STAGGER_MS, ROW_MS, 0.0, true)

	# 400–900: the streak counts up, then the flame gives one pulse.
	_count_streak()
	get_tree().create_timer(float(FLAME_AT_MS) / 1000.0).timeout.connect(_pulse_flame)

	# 500–1080: the ring sweeps to the new fraction — or pulses when it is already full.
	_sweep_ring()

	# 1100–1260: the advice line fades up last, because it is the thing to read afterwards.
	_rise(_advice_card, ADVICE_AT_MS, ADVICE_MS, 12.0)

	_sfx(&"celebration")
	# AC13's "an untouched completion logs the full sequence and finishes within 1.6 s": the pair of
	# lines below is that evidence, and `celebration_skipped` is the other side of it.
	get_tree().create_timer(float(CELEBRATION_MS) / 1000.0).timeout.connect(_on_celebration_end)
	print("[complete] celebration start t=0.00")


## Everything the timeline animates starts hidden, so the celebration has a beginning.
func _prepare_hidden() -> void:
	_summary_card.modulate.a = 0.0
	_stats_row.modulate.a = 0.0
	_advice_card.modulate.a = 0.0
	_title.modulate.a = 0.0
	_title.position.y = 16.0
	_advice_card.position.y = 12.0


## Fade + move, delayed. [param axis_x] moves on the x axis instead of y (the summary rows).
func _rise(node: Control, delay_ms: int, duration_ms: int, distance: float,
		axis_x: bool = false) -> void:
	node.modulate.a = 0.0
	var tween := _track(create_tween())
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	if delay_ms > 0:
		tween.tween_interval(float(delay_ms) / 1000.0)
	if axis_x:
		tween.tween_property(node, "position:x", 0.0, float(duration_ms) / 1000.0)
	else:
		tween.tween_property(node, "position:y", 0.0, float(duration_ms) / 1000.0)
	tween.parallel().tween_property(node, "modulate:a", 1.0, float(duration_ms) / 1000.0)
	# The two cards animate as one block, so their child rows are not animated separately.
	if distance > 0.0 and not axis_x:
		node.position.y = distance


## R12's 400–900 ms window: the tiles fade in while the number rolls from the pre-entry streak to the
## post-entry one. The pre-entry number is written first so the count has a starting value.
func _count_streak() -> void:
	_streak_tile.call(&"set_stat", "DAY STREAK", str(_streak_before), &"flame")
	_stats_row.modulate.a = 0.0
	var tween := _track(create_tween())
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_interval(float(STREAK_AT_MS) / 1000.0)
	tween.tween_property(_stats_row, "modulate:a", 1.0, float(STREAK_MS) / 1000.0)
	tween.parallel().tween_method(_set_streak_text, float(_streak_before), float(_streak_after),
		float(STREAK_MS) / 1000.0)


func _set_streak_text(value: float) -> void:
	_streak_tile.call(&"set_stat", "DAY STREAK", str(roundi(value)), &"flame")


## R12: at `t = 900` the flame scales 1.0 → 1.18 → 1.0 over 320 ms.
func _pulse_flame() -> void:
	if _skipped:
		return
	var tween := _track(create_tween())
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(_streak_tile, "scale", Vector2(1.18, 1.18), float(FLAME_MS) / 2000.0)
	tween.tween_property(_streak_tile, "scale", Vector2.ONE, float(FLAME_MS) / 2000.0)


## R12: the ring tweens from the pre-entry fraction to the new one; when it is **already** full it
## pulses instead, because a sweep from 1.0 to 1.0 would look like nothing happened.
##
## The sweep itself belongs to PRD-09's `weekly_ring` (it tweens its own `progress_ring` over
## `MOTION.ring_fill_ms` when the value changes after the first paint), so this only re-paints the
## pre-entry state at `t = 0` and hands over the post-entry state at [constant RING_AT_MS] — the
## ring is never re-implemented or double-tweened from here.
func _sweep_ring() -> void:
	var tween := _track(create_tween())
	tween.tween_interval(float(RING_AT_MS) / 1000.0)
	if _ring_before >= 1.0:
		tween.tween_property(_ring_tile, "scale", Vector2(1.06, 1.06), 0.18) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(_ring_tile, "scale", Vector2.ONE, 0.18)
		# The already-full ring still gets its final value, just without a visible sweep.
		tween.tween_callback(_apply_ring_after)
		return
	tween.tween_callback(_apply_ring_after)


func _apply_ring_after() -> void:
	if _skipped:
		return
	_apply_ring(_ring_after, Store.all_entries())


func _vibrate_celebration() -> void:
	if _skipped:
		return
	Input.vibrate_handheld(200)


# ===========================================================================
# Skipping (R12: motion is skippable and must never gate input)
# ===========================================================================

## A tap anywhere before the timeline finishes ends it immediately. `Done` works from frame 0 either
## way — that is the point of the rule.
##
## This is `_input`, not `_unhandled_input`: the screen's root is a full-rect `Control`, whose default
## `mouse_filter = STOP` consumes the tap, so it never *becomes* unhandled input and R12's "a tap
## anywhere skips" silently did nothing on the device. `_input` runs before GUI handling, so the tap
## is always seen — and `Done` still receives its own press, because skipping only touches the
## animated values.
func _input(event: InputEvent) -> void:
	if not _celebration_running or _skipped:
		return
	if event is InputEventScreenTouch:
		if not (event as InputEventScreenTouch).pressed:
			_finish_from_input()
	elif event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.button_index == MOUSE_BUTTON_LEFT and not mouse.pressed:
			_finish_from_input()


func _finish_from_input() -> void:
	get_viewport().set_input_as_handled()
	_skip_celebration()


## Sets every animated node to its end value in a single frame, stops the confetti and says so.
func _skip_celebration() -> void:
	if _skipped or not _celebration_running:
		return
	_skipped = true
	_celebration_running = false
	for tween in _tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_confetti.emitting = false
	_apply_final_state()
	print("[complete] celebration_skipped t=%.2f" % (float(_elapsed_ms()) / 1000.0))


## The uninterrupted finish, 1.6 s after the screen came up.
func _on_celebration_end() -> void:
	if _skipped or not _celebration_running:
		return
	_celebration_running = false
	print("[complete] celebration end t=%.2f" % (float(_elapsed_ms()) / 1000.0))


func _apply_final_state() -> void:
	modulate.a = 1.0
	_check.scale = Vector2.ONE
	_title.modulate.a = 1.0
	_title.position.y = 0.0
	_summary_card.modulate.a = 1.0
	_stats_row.modulate.a = 1.0
	_advice_card.modulate.a = 1.0
	_advice_card.position.y = 0.0
	_streak_tile.scale = Vector2.ONE
	_ring_tile.scale = Vector2.ONE
	_streak_tile.call(&"set_stat", "DAY STREAK", str(_streak_after), &"flame")
	for row in _row_nodes:
		row.modulate.a = 1.0
		row.position.x = 0.0
	_apply_ring(_ring_after, Store.all_entries())


func _elapsed_ms() -> int:
	return maxi(Time.get_ticks_msec() - _started_ms, 0)


func celebration_running() -> bool:
	return _celebration_running


func skipped() -> bool:
	return _skipped


func _track(tween: Tween) -> Tween:
	_tweens.append(tween)
	return tween


# ===========================================================================
# Exit (R12)
# ===========================================================================

## R12's single action: `Nav.replace(Routes.HOME, {})` clears this screen and lands on the Home tab,
## which is already correct because `Store.entry_added` fired before the celebration started.
func _on_done_pressed() -> void:
	_release_back()
	Nav.replace(Routes.HOME, {})


func _release_back() -> void:
	if _owns_back:
		Nav.set_back_handling(true)
		_owns_back = false


# ===========================================================================
# Theme and sound
# ===========================================================================

func _on_theme_changed(_mode: String) -> void:
	_background.color = DesignTokens.color(App.theme_mode, "bg")
	_confetti.color_ramp = _confetti_ramp()
	var check_token := "warning" if _partial else "success"
	_check.add_theme_color_override(&"color", DesignTokens.color(App.theme_mode, check_token))


## R12: the burst cycles `primary` → `secondary` → `success` → `warning`, read from the tokens so a
## theme swap cannot leave it off-palette.
func _confetti_ramp() -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.34, 0.67, 1.0])
	gradient.colors = PackedColorArray([
		DesignTokens.color(App.theme_mode, "primary"),
		DesignTokens.color(App.theme_mode, "secondary"),
		DesignTokens.color(App.theme_mode, "success"),
		DesignTokens.color(App.theme_mode, "warning"),
	])
	return gradient


func _sfx(sound_name: StringName) -> void:
	var path := "res://assets/audio/sfx/%s.ogg" % sound_name
	if not ResourceLoader.exists(path):
		return
	var stream: AudioStream = null
	if _stream_cache.has(path):
		stream = _stream_cache[path]
	else:
		stream = ResourceLoader.load(path) as AudioStream
		_stream_cache[path] = stream
	if stream == null:
		return
	_sfx_player.stream = stream
	_sfx_player.play()
