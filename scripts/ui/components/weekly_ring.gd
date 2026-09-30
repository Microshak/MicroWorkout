extends Control
## The weekly goal ring — PRD-09 R8, appendix §R10.
##
## A `card` wrapping PRD-02's `progress_ring`: this composite **composes** the shared ring
## ([method ProgressRing.set_segments] draws one tick per planned day, `set_caption_value` writes
## the `"3/4"` label) and draws no ring geometry of its own — a second ring implementation is a
## review rejection (appendix §3.1/R10).
##
## The one thing `progress_ring` cannot express is R8's fill colour rule (`primary` below target,
## `success` at or above it, `text_disabled` when there is no goal yet), so the colour is applied
## through a theme colour override on the ring instance — the same route PRD-06's onboarding dots
## and PRD-08's `source_badge` use for per-state colour.
##
## R15's 420 ms ease-out sweep is tweened here rather than in `progress_ring.gd`, because
## `progress_ring` is PRD-02's file and exposes no animated setter.

## R8: the ring's caption.
const CAPTION := "THIS WEEK"

## R8: the composite is never smaller than the ring it holds.
const RING_MIN_SIZE := Vector2(200.0, 200.0)

var _completed: int = 0
var _target: int = 0
var _fraction: float = 0.0
var _tween: Tween = null
var _drawn_once: bool = false
## PRD-12 R2: the cue fires on *reaching* the goal, not on seeing it — the first paint of an
## already-complete week stays silent, and the two live instances (Home and Tracker) speak once
## per ISO week because the week id is remembered process-wide.
var _was_at_goal: bool = true
static var _celebrated_week: String = ""

## See day_pill: a colour override set from inside the theme notification re-enters it.
var _applying: bool = false


func _ready() -> void:
	_apply_fill_color()
	# Same measured gap as day_pill: a root-theme swap does not notify descendants in 4.7.2, so
	# the composite also listens to the app's own signal (the pattern PRD-06's `area_chip` and
	# PRD-08's `source_badge` ship).
	if not App.theme_changed.is_connected(_on_app_theme_changed):
		App.theme_changed.connect(_on_app_theme_changed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and not _applying:
		_repaint()


## Dark↔light switch.
func _on_app_theme_changed(_mode: String) -> void:
	_repaint()


func _repaint() -> void:
	_applying = true
	_apply_fill_color()
	_applying = false


# ------------------------------------------------------------------ API (appendix §3.2)

## Fills the ring. [param bits] is `Streak.ring_segments(entries, week_id, target)` — one tick
## per planned day; [param fraction] is `Store.weekly_goal_progress()`, whose denominator is
## `Store.weekly_goal_days_effective()` (PRD-03, appendix R50). `0/0` (no goal yet) renders a
## muted empty ring, never a division by zero.
func set_week(completed: int, target: int, fraction: float, bits: PackedByteArray) -> void:
	_completed = maxi(completed, 0)
	_target = maxi(target, 0)
	_fraction = clampf(fraction, 0.0, 1.0)
	_announce_goal_if_reached()

	var ring := ring_node()
	if ring == null:
		return
	if ring.has_method(&"set_segments"):
		ring.call(&"set_segments", bits)
	if ring.has_method(&"set_caption"):
		ring.call(&"set_caption", CAPTION)
	if ring.has_method(&"set_caption_value"):
		# The value text keeps counting past the target ("5/4") while the arc caps at 100 % (R8).
		ring.call(&"set_caption_value", "%d/%d" % [_completed, _target])
	_apply_fill_color()
	_sweep_to(_fraction)


## The ring instance this composite drives. `Card` is a plain `PanelContainer` carrying the
## `Card` variation with its own `CardBody` — **not** an instance of `card.tscn`: a node attached
## under an instanced scene's internal nodes is silently dropped by the .tscn → .scn conversion
## the Android export uses (measured 2026-09-30; see ADR-26), which left this ring undrawn in
## every device build until PRD-11 found it.
func ring_node() -> Control:
	return get_node_or_null(^"Card/CardBody/Ring") as Control


## PRD-12 R2 — a below-target ring that becomes a complete one plays `success()` exactly once
## per ISO week, whichever of the two instances notices it first.
func _announce_goal_if_reached() -> void:
	var at_goal := _target > 0 and _completed >= _target
	if at_goal and not _was_at_goal:
		var week := Dates.iso_week_id(Dates.today_iso())
		if not week.is_empty() and week != _celebrated_week:
			_celebrated_week = week
			Feedback.success()
	_was_at_goal = at_goal


## The value label's verbatim text — what the AC8 screenshot and probe check reads.
func value_text() -> String:
	var ring := ring_node()
	if ring == null or not ring.has_method(&"value_label_node"):
		return ""
	var label := ring.call(&"value_label_node") as Label
	return "" if label == null else label.text


## The fraction the arc is actually drawn at (0 … 1).
func arc_fraction() -> float:
	var ring := ring_node()
	if ring == null or not ring.has_method(&"value_label_node"):
		return 0.0
	return float(ring.get(&"value"))


## The numerator shown by the ring's label (unique completed days this ISO week).
func completed_days() -> int:
	return _completed


## The denominator shown by the ring's label (the plan's cadence, or 0 with no plan).
func target_days() -> int:
	return _target


# ------------------------------------------------------------------ rendering

## R8's fill rule, plus the "no goal yet" case R10 renders as `0/0`.
func _apply_fill_color() -> void:
	var ring := ring_node()
	if ring == null:
		return
	var token := "text_disabled"
	if _target > 0:
		token = "success" if _completed >= _target else "primary"
	ring.add_theme_color_override(&"fill_color", DesignTokens.color(App.theme_mode, token))


## R15: the first paint snaps (there is nothing to animate from), every later change sweeps.
func _sweep_to(value: float) -> void:
	var ring := ring_node()
	if ring == null:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if _drawn_once and not _reduce_motion():
		_tween = create_tween()
		_tween.set_trans(Tween.TRANS_CUBIC)
		_tween.set_ease(Tween.EASE_OUT)
		_tween.tween_property(ring, "value", value,
			float(DesignTokens.MOTION["ring_fill_ms"]) / 1000.0)
	elif ring.has_method(&"set_value"):
		ring.call(&"set_value", value)
	_drawn_once = true


## Decorative motion is skipped under `ui.reduce_motion` (PRD-12 R1).
func _reduce_motion() -> bool:
	return not Motion.decorative_enabled()
