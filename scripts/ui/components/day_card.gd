extends PanelContainer
## Day card — PRD-08 R12 (appendix §3.2; PRD-09/PRD-10 reuse it, so it is written to stand
## alone rather than to fit one screen).
##
## One card per `plan.sessions[i]`: the day number, the session's focus areas, an exercise
## count with its estimated minutes, and an accordion that reveals the working blocks.
##
## Three contract details worth stating out loud:
##
## * **`DayHeader` is a `Button`, not a bare `HBoxContainer`.** R12 draws it as an HBox, but the
##   same paragraph says tapping it expands the list, and an `HBoxContainer` cannot be tapped
##   (and would not clear the 88 px touch floor). It keeps the `DayHeader` name and the
##   `HBoxContainer` look — a `GhostButton` variation is a transparent box with no fill — and its
##   three labels live in a mouse-transparent `Row` exactly as the tree describes.
## * **The card toggles itself and then announces it.** `pressed(session_id)` fires *after* the
##   accordion has opened, so the screen that owns the list can close the other cards and get
##   R12's "one open at a time" without the card needing to know its siblings.
## * **Warm-up and cool-down are not exercises** (R12): the meta line counts `session.blocks`
##   only, so it never disagrees with the player's exercise list.
##
## `kind` is the appendix §6.4 day kind (`done | today | upcoming | rest | missed`) and
## `weekday_name` is PRD-09's mapping — this card renders both if it is given them and invents
## neither.

signal pressed(session_id: String)

## R12 / PRD-00 §7.2: a session holds at most 12 blocks, and the list says so when it does not.
const MAX_ROWS := 12

## R12's accordion timing.
const ACCORDION_SEC := 0.18

## R12's per-row floor (rows are not interactive, so this is breathing room, not a touch
## target).
const ROW_MIN_HEIGHT := 72.0

const GLYPH_OPEN := &"chevron_down"
const GLYPH_CLOSED := &"chevron_right"

var _session: Dictionary = {}
var _kind: StringName = &"upcoming"
var _expanded: bool = false
var _rows: Array[Control] = []
var _tween: Tween = null


func _ready() -> void:
	var header := header_button()
	if header != null and not header.pressed.is_connected(_on_header_pressed):
		header.pressed.connect(_on_header_pressed)
	_sync_chevron()


# ------------------------------------------------------------------ R12 API

## Fills the card from [param session] (`Plan.Session`, appendix §5.2). [param kind] is stored
## for later reuse and [param weekday_name] is rendered only when non-empty — PRD-08 labels
## days `Day 1..N` on purpose so the weekday decision lives in exactly one place (§10 note N3).
func set_day(session: Dictionary, kind: StringName = &"upcoming",
		weekday_name: String = "") -> void:
	_session = session.duplicate(true)
	_kind = kind

	var index := PlanModel.as_int(_session.get("index"), 0)
	var number := number_label()
	if number != null:
		number.text = "Day %d" % (index + 1)
		if not weekday_name.is_empty():
			number.text = "Day %d · %s" % [index + 1, weekday_name]

	var focus := focus_label()
	if focus != null:
		# A separator, so `Day 1 · Monday` and `Chest · Back` do not read as one run-on
		# sentence (owner readability pass, 2026-10-02).
		var focus_text := _focus_text()
		focus.text = "· %s" % focus_text if not focus_text.is_empty() else ""

	var meta := meta_label()
	if meta != null:
		meta.text = "%d exercises · %d min" % [_blocks().size(), est_minutes()]

	# R5: the header is the card's one interactive control, so it carries the name —
	# "Day 2 · Chest + Back, show exercises" — instead of the scene fallback "Session".
	var header := header_button()
	if header != null:
		var header_name: String = number.text if number != null else "Session"
		var raw_focus := _focus_text()
		if not raw_focus.is_empty():
			header_name = "%s, %s" % [header_name, raw_focus]
		A11y.label(header, header_name, "Show exercises")

	_build_rows()
	set_expanded(false)


## Opens or closes the accordion. Idempotent, so a screen can close every card in a list
## without checking which one is already shut.
func set_expanded(value: bool) -> void:
	if value == _expanded:
		return
	_expanded = value
	_sync_chevron()
	var list := exercise_list()
	if list == null:
		return
	if not _motion_enabled():
		_kill_tween()
		list.visible = value
		list.modulate.a = 1.0
		return
	_kill_tween()
	if value:
		list.visible = true
		list.modulate.a = 0.0
		_tween = create_tween()
		_tween.set_trans(Tween.TRANS_CUBIC)
		_tween.set_ease(Tween.EASE_OUT)
		_tween.tween_property(list, "modulate:a", 1.0, ACCORDION_SEC)
	else:
		_tween = create_tween()
		_tween.set_trans(Tween.TRANS_CUBIC)
		_tween.set_ease(Tween.EASE_OUT)
		_tween.tween_property(list, "modulate:a", 0.0, ACCORDION_SEC)
		_tween.tween_callback(_after_collapse)


func is_expanded() -> bool:
	return _expanded


## The session this card is showing (a copy — mutating it changes nothing on screen). Not
## named `session()`: R12's `set_day(session, kind, weekday_name)` parameter names are the
## frozen signature, and same-named accessors would be reported as shadowing them.
func session_data() -> Dictionary:
	return _session.duplicate(true)


func session_id() -> String:
	return PlanModel.as_text(_session.get("id", ""), "")


func session_title() -> String:
	return PlanModel.as_text(_session.get("title", ""), "")


## The appendix §6.4 day kind stored by [method set_day] (`upcoming` by default).
func day_kind() -> StringName:
	return _kind


## The session's `est_minutes`, `0` when the plan does not carry one.
func est_minutes() -> int:
	return PlanModel.as_int(_session.get("est_minutes"), 0)


## `7` for a 7-block session — what the meta line counts and what a test can check.
func exercise_count() -> int:
	return _blocks().size()


## The exercise rows currently built, so a screen (or the compile/test path) can address them.
func rows() -> Array[Control]:
	return _rows


# ------------------------------------------------------------------ nodes

func header_button() -> Button:
	return get_node_or_null(^"Body/DayHeader") as Button


func number_label() -> Label:
	return get_node_or_null(^"Body/DayHeader/Row/DayNumberLabel") as Label


func focus_label() -> Label:
	return get_node_or_null(^"Body/DayHeader/Row/DayFocusLabel") as Label


func chevron_node() -> Control:
	return get_node_or_null(^"Body/DayHeader/Row/ChevronGlyph") as Control


func meta_label() -> Label:
	return get_node_or_null(^"Body/DayMetaLabel") as Label


func exercise_list() -> VBoxContainer:
	return get_node_or_null(^"Body/ExerciseList") as VBoxContainer


# ------------------------------------------------------------------ internals

func _on_header_pressed() -> void:
	set_expanded(not _expanded)
	pressed.emit(session_id())


func _after_collapse() -> void:
	if _expanded:
		return
	var list := exercise_list()
	if list != null:
		list.visible = false


func _sync_chevron() -> void:
	var chevron := chevron_node()
	if chevron != null:
		chevron.set(&"kind", GLYPH_OPEN if _expanded else GLYPH_CLOSED)


## R12: the `Taxonomy` labels for `session.focus`, joined `" · "`. Unknown keys fall back to the
## key itself (`Taxonomy.label`'s documented behaviour), so a hand-written plan still renders.
func _focus_text() -> String:
	var out := PackedStringArray()
	for area in _list(_session.get("focus", [])):
		var key := PlanModel.as_text(area, "")
		if not key.is_empty():
			out.append(Taxonomy.label(key))
	return " · ".join(out)


func _blocks() -> Array:
	return _list(_session.get("blocks", []))


## One row per working block, capped at [constant MAX_ROWS] with R12's muted tail row.
func _build_rows() -> void:
	var list := exercise_list()
	if list == null:
		return
	_kill_tween()
	for row in _rows:
		if is_instance_valid(row):
			list.remove_child(row)
			row.queue_free()
	_rows.clear()
	list.visible = false
	list.modulate.a = 1.0

	var blocks := _blocks()
	var shown: int = mini(blocks.size(), MAX_ROWS)
	for i in shown:
		var block: Dictionary = blocks[i] if blocks[i] is Dictionary else {}
		var row := _build_row(block)
		list.add_child(row)
		_rows.append(row)
	if blocks.size() > shown:
		var more := Label.new()
		more.name = "MoreLabel"
		more.theme_type_variation = &"MutedLabel"
		more.text = "…and %d more" % (blocks.size() - shown)
		list.add_child(more)
		_rows.append(more)


## `<name>` on the left, `"3 × 8-10 · 90s"` on the right (R12's `"%d × %s · %ds"`).
func _build_row(block: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.name = "ExerciseRow"
	row.custom_minimum_size = Vector2(0.0, ROW_MIN_HEIGHT)
	row.add_theme_constant_override(&"separation", int(DesignTokens.SPACE["md"]))

	var exercise_id := PlanModel.as_text(block.get("exercise_id", ""), "")
	var name_label := Label.new()
	name_label.name = "ExerciseName"
	name_label.theme_type_variation = &"BodyLabel"
	name_label.text = _exercise_name(exercise_id)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(name_label)

	var scheme := Label.new()
	scheme.name = "ExerciseScheme"
	scheme.theme_type_variation = &"MutedLabel"
	scheme.text = "%d × %s · %ds" % [
		PlanModel.as_int(block.get("sets"), 0),
		PlanModel.as_text(block.get("reps", ""), ""),
		PlanModel.as_int(block.get("rest_seconds"), 0),
	]
	scheme.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(scheme)
	return row


## The library's display name, or the raw id when the library is not loaded or does not know it
## — a card is never blank, and a missing id is a data problem the exercise list should show
## rather than hide.
func _exercise_name(exercise_id: String) -> String:
	if exercise_id.is_empty():
		return ""
	if is_instance_valid(Library) and Library.is_ready():
		var resolved := Library.name_of(exercise_id)
		if not resolved.is_empty():
			return resolved
	return exercise_id


## R17 / appendix §4.4: animations are *skipped*, never shortened, under `ui.reduce_motion`.
func _motion_enabled() -> bool:
	if not is_inside_tree():
		return false
	return not bool(App.get_setting("ui.reduce_motion", false))


## A plain, untyped copy of an array-ish value. Iterating a **plain** `Array` keeps each
## element a `Variant`; iterating a typed `Array[String]` makes a `String(entry)` conversion a
## statically-bound constructor call, which is the one form that fails at runtime. So every
## JSON-ish list this component walks goes through here first.
static func _list(value: Variant) -> Array:
	var out: Array = []
	if value is Array or value is PackedStringArray:
		for entry in value:
			out.append(entry)
	return out


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
