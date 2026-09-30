extends Control
## Tracker day detail — PRD-11 R7, appendix §2/R57.
##
## A pushed screen (not a sheet): `Nav`'s back handling and PRD-02's `top_bar` already exist, and
## a screen cannot strand a half-open sheet if the app dies mid-view.
##
## **What it shows.** The summary the entry itself carries — title, date, duration, `n of m`
## exercises, the real set counters when PRD-10 recorded them — plus the session *as prescribed*
## (name, sets × reps, rest) resolved through the plan.
##
## **What it never does.** It never fabricates per-exercise completion: entries carry only the
## totals (§5.3, PRD-11 §10 note 2), so check marks per exercise do not exist and are not drawn.
## When the plan has since been deleted, the prescribed sets/reps are gone too — the screen says
## so in [constant MISSING_COPY] and, when the entry carries `exercise_ids` (the additive field
## R29 added), still lists the exercises by name instead of blanking the list.

## When neither the plan nor the session can be resolved and the entry predates `exercise_ids`.
const MISSING_COPY := "The plan this session came from is no longer on this device. Only the summary is available."
## When the entry carries `exercise_ids`: the names survive, the prescription does not.
const PARTIAL_COPY := "The plan this session came from is no longer on this device. Exercise order is from the session log; prescribed sets and reps aren't available."

@onready var _background: ColorRect = $Background
@onready var _top_bar: PanelContainer = $SafeArea/Layout/TopBar
@onready var _title: Label = $SafeArea/Layout/Scroller/Column/TitleLabel
@onready var _meta: Label = $SafeArea/Layout/Scroller/Column/MetaLabel
@onready var _status: Button = $SafeArea/Layout/Scroller/Column/StatusChip
@onready var _list: VBoxContainer = $SafeArea/Layout/Scroller/Column/ExerciseList
@onready var _missing: Label = $SafeArea/Layout/Scroller/Column/MissingLabel

var _entry: Dictionary = {}


func _ready() -> void:
	_background.color = DesignTokens.color(App.theme_mode, "bg")
	if _top_bar.has_method(&"set_title"):
		_top_bar.call(&"set_title", "Session")
	if _top_bar.has_signal(&"back_pressed") and not _top_bar.is_connected(&"back_pressed",
			_on_back_pressed):
		_top_bar.connect(&"back_pressed", _on_back_pressed)


## Nav calls this after `add_child` (appendix §1.5). `args` is
## `{date: String, entry_id: String}`; `entry_id == ""` opens the day's first entry (R57).
func setup(args: Dictionary) -> void:
	var entry := _resolve(args)
	if entry.is_empty():
		Feedback.toast("That session is no longer on this device.", &"warning")
		Nav.pop()
		return
	_entry = entry
	_render()


func _on_back_pressed() -> void:
	Nav.pop()


# ------------------------------------------------------------------ resolution

func _resolve(args: Dictionary) -> Dictionary:
	var wanted_id := String(args.get("entry_id", ""))
	if not wanted_id.is_empty():
		var found := _entry_by_id(wanted_id)
		# A wrong id with a date is still salvageable: fall through to the day's first entry.
		if not found.is_empty():
			return found
	var date := String(args.get("date", ""))
	if Dates.is_valid_iso_date(date):
		var entries := Store.entries_on(date)
		if not entries.is_empty():
			return entries[0]
	return {}


func _entry_by_id(wanted_id: String) -> Dictionary:
	for entry in Store.all_entries():
		if String(entry.get("id", "")) == wanted_id:
			return entry
	return {}


# ------------------------------------------------------------------ rendering (R7)

func _render() -> void:
	var date := String(_entry.get("date", ""))
	var duration := int(_entry.get("duration_sec", 0))
	var completed := int(_entry.get("exercises_completed", 0))
	var total := int(_entry.get("exercises_total", 0))
	var title := String(_entry.get("session_title", ""))
	_title.text = title if not title.is_empty() else "Session"

	var pieces := PackedStringArray()
	pieces.append(Dates.format_long(date) if Dates.is_valid_iso_date(date) else date)
	pieces.append(Dates.format_clock(duration))
	pieces.append("%d of %d exercises" % [completed, total])
	# R7: the set counters are additive — present means shown, absent means omitted entirely.
	if _entry.has("sets_completed") or _entry.has("sets_total"):
		pieces.append("%d of %d sets" % [
			int(_entry.get("sets_completed", 0)), int(_entry.get("sets_total", 0))])
	_meta.text = " · ".join(pieces)

	_render_status(completed, total)
	_render_exercises()


func _render_status(completed: int, total: int) -> void:
	var done := bool(_entry.get("completed", false))
	_status.disabled = true
	_status.text = "Completed" if done else "Partial — %d of %d" % [completed, total]
	_status.add_theme_color_override(&"font_disabled_color",
		DesignTokens.accent_text(App.theme_mode, "success" if done else "warning"))


## R7: the list is the session *as prescribed*. When the plan is gone the entry's own
## `exercise_ids` still let the names through; without them the list hides and the copy explains
## why (never an invented prescription).
func _render_exercises() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	var plan := Store.get_plan(String(_entry.get("plan_id", "")))
	var session := _session_of(plan)
	var blocks := _blocks_of(session)
	if not blocks.is_empty():
		for block in blocks:
			_list.add_child(_block_row(block))
		_missing.visible = false
		return

	var ids := _string_array(_entry.get("exercise_ids", []))
	if not ids.is_empty():
		for exercise_id in ids:
			_list.add_child(_name_row(exercise_id))
		_missing.text = PARTIAL_COPY
		_missing.visible = true
		return

	_list.visible = false
	_missing.text = MISSING_COPY
	_missing.visible = true


func _block_row(block: Dictionary) -> Control:
	var exercise_id := String(block.get("exercise_id", ""))
	var exercise_name := Library.name_of(exercise_id)
	if exercise_name.is_empty():
		exercise_name = exercise_id
	var row := VBoxContainer.new()
	row.add_theme_constant_override(&"separation", 2)
	row.add_child(_label(exercise_name, &"BodyLabel"))
	row.add_child(_label("%d × %s · %ds rest" % [
		int(block.get("sets", 0)),
		String(block.get("reps", "")),
		int(block.get("rest_seconds", 0)),
	], &"MutedLabel"))
	return row


func _name_row(exercise_id: String) -> Control:
	var exercise_name := Library.name_of(exercise_id)
	if exercise_name.is_empty():
		exercise_name = exercise_id
	return _label(exercise_name, &"BodyLabel")


func _label(text: String, variation: StringName) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


# ------------------------------------------------------------------ helpers

func _session_of(plan: Dictionary) -> Dictionary:
	var session_id := String(_entry.get("session_id", ""))
	var raw: Variant = plan.get("sessions", [])
	if not (raw is Array) or session_id.is_empty():
		return {}
	for value in raw:
		if value is Dictionary and String(value.get("id", "")) == session_id:
			return value
	return {}


func _blocks_of(session: Dictionary) -> Array:
	var raw: Variant = session.get("blocks", [])
	return raw if raw is Array else []


static func _string_array(raw: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if raw is Array:
		for value in raw:
			var text := String(value)
			if not text.is_empty():
				out.append(text)
	return out
