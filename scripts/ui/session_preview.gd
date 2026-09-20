extends Control
## PRD-10 R1 — the small "what's in today's session" list PRD-09 links to.
##
## Home's `See the exercises` link pushes this screen; its one action pushes the player with the
## **same two ids**, so the preview and the workout can never disagree about what is about to run.
##
## Decisions worth knowing before editing:
##
## * **The list is [SessionRun]'s output, not a second reading of the plan.** `SessionRun.build()`
##   is the single place a session is flattened in this app (R3), so the warm-up/block/cool-down
##   order, the set counts and the rest seconds shown here are exactly the steps the player will
##   walk through. Re-flattening the plan in a screen is how two screens drift apart.
## * **Read-only, deliberately.** No set chips, no check-off, no timers: all of that is the
##   player's, and a preview that looks tappable but is not is worse than a plain list.
## * **A missing plan or session never leaves an empty shell.** `Nav` can be handed a stale pair
##   (a plan replaced from Settings while the link sat on screen), so this screen toasts and pops
##   to the root rather than rendering nothing (R1). Being instantiated *without* `setup()` — what
##   `tools/check_scene.sh` does — is the one case that may draw empty labels, and that state is
##   unreachable through `Nav`.
## * **Route names come from the frozen route table**, with appendix §2's names as a fallback —
##   the same `route_named()` pattern `home_tab.gd` uses, so this file does not depend on another
##   PRD's edit to `routes.gd` landing in the same commit.
## * **`SourceHost` carries the badge's 56 px minimum height.** The badge is instanced with
##   `layout_mode = 0` (it sizes itself, exactly as on `plan_preview`), and a plain `Control`
##   parent contributes nothing to a `VBoxContainer`, so without that floor the badge would draw
##   over the Start button.

const ROUTES_PATH := "res://scripts/core/routes.gd"

## Appendix §2's route names, which are also the constants PRD-10 adds to `routes.gd`.
## [method route_named] prefers whatever the real table declares.
const ROUTE_FALLBACKS := {
	"SESSION_PREVIEW": &"session_preview",
	"WORKOUT_PLAYER": &"workout_player",
}

## R1's copy, verbatim.
const GONE_TOAST := "That session is gone — pick one from your plan."
const START_LABEL := "Start workout"

## The three section captions. Warm-up and cool-down are named exactly as the player's own
## sub-flows are, so the two screens read as one flow.
const WARMUP_CAPTION := "WARM-UP"
const WORK_CAPTION := "WORK"
const COOLDOWN_CAPTION := "COOL-DOWN"

## The one place each row's shape is spelled out (R1): `"Arm Circles · 60s"`,
## `"1. Bench Press"`, `"4 × 8-10"`, `"90s rest"`.
const MOBILITY_FORMAT := "%s · %ds"
const BLOCK_NAME_FORMAT := "%d. %s"
const SETS_REPS_FORMAT := "%d × %s"
const REST_FORMAT := "%ds rest"
const META_FORMAT := "%d exercises · %d min"

@onready var _bg: ColorRect = $Background
@onready var _back_button: Button = $SafeArea/Layout/Header/BackButton
@onready var _title_label: Label = $SafeArea/Layout/Header/SessionTitleLabel
@onready var _meta_label: Label = $SafeArea/Layout/MetaLabel
@onready var _warmup_list: VBoxContainer = $SafeArea/Layout/Scroller/Lists/WarmupList
@onready var _block_list: VBoxContainer = $SafeArea/Layout/Scroller/Lists/BlockList
@onready var _cooldown_list: VBoxContainer = $SafeArea/Layout/Scroller/Lists/CooldownList
@onready var _source_host: Control = $SafeArea/Layout/SourceHost
@onready var _source_badge: Control = $SafeArea/Layout/SourceHost/SourceBadge
@onready var _start_button: Button = $SafeArea/Layout/StartButton

var _plan: Dictionary = {}
var _session: Dictionary = {}
var _run: SessionRun = null

## The two ids that actually resolved, which is what the player is pushed with. They are the
## *resolved* ids rather than the requested ones, so the empty-`plan_id` fallback still sends the
## player a pair that exists.
var _plan_id: String = ""
var _session_id: String = ""

var _route_player: StringName = &""

## `setup()` arriving before the node is in the tree: the arguments are parked here and
## [method _ready] resolves them. `Nav._enter_route` always calls `add_child` first, so this only
## covers a hand-rolled caller (a probe, a test harness) that does it the other way round.
var _args: Dictionary = {}
var _setup_pending: bool = false


# ===========================================================================
# Lifecycle
# ===========================================================================

func _ready() -> void:
	_route_player = route_named("WORKOUT_PLAYER")
	_bg.color = DesignTokens.color(App.theme_mode, "bg")
	if not App.theme_changed.is_connected(_on_theme_changed):
		App.theme_changed.connect(_on_theme_changed)

	_back_button.pressed.connect(_on_back_pressed)
	_start_button.pressed.connect(_on_start_pressed)
	_start_button.text = START_LABEL

	# The no-`setup()` state: empty labels, nothing resolved, no crash.
	_render()
	if _setup_pending:
		_setup_pending = false
		var parked := _args
		_args = {}
		_resolve(parked)

	# One frame later, so both the touch-target check and the tap-test rectangles measure a
	# laid-out screen rather than a zero-sized one.
	_report_layout.call_deferred()


# ===========================================================================
# R1 — entry
# ===========================================================================

## `Nav` calls this immediately after `add_child`. [param args]:
##   `plan_id: String`    — the plan to preview; `""` means "whatever is active".
##   `session_id: String` — the session inside it.
##
## Every other outcome is the R1 failure path: toast, pop to the root, and leave nothing behind.
func setup(args: Dictionary) -> void:
	if not is_node_ready():
		_args = args
		_setup_pending = true
		return
	_resolve(args)


func _resolve(args: Dictionary) -> void:
	var wanted_plan_id := PlanModel.as_text(args.get("plan_id"), "")
	var wanted_session_id := PlanModel.as_text(args.get("session_id"), "")

	var plan := Store.get_plan(wanted_plan_id)
	if plan.is_empty() and wanted_plan_id.is_empty():
		plan = Store.active_plan()
	var session := _session_in(plan, wanted_session_id)

	if plan.is_empty() or session.is_empty():
		print("[session_preview] gone plan_id=%s session_id=%s" % [wanted_plan_id, wanted_session_id])
		Feedback.toast(GONE_TOAST, &"warning")
		Nav.pop_to_root()
		return

	_plan = plan
	_session = session
	_plan_id = PlanModel.as_text(plan.get("id"), wanted_plan_id)
	_session_id = PlanModel.as_text(session.get("id"), wanted_session_id)
	_render()
	print("[session_preview] open plan=%s session=%s steps=%d" % [
		_plan_id, _session_id, _run.total_steps() if _run != null else 0])


# ===========================================================================
# Rendering
# ===========================================================================

## Renders the resolved session, or the empty state when nothing has been resolved yet. Both
## branches are total: every label is written on every call, so a re-render can never leave a
## stale line from the previous session behind.
func _render() -> void:
	if _plan.is_empty() or _session.is_empty():
		_render_empty()
		return

	_run = SessionRun.build(_plan, _session)
	_title_label.text = PlanModel.as_text(_session.get("title"), "")
	# R1: mobility items are not "exercises" — the count is `blocks`, never `steps`.
	_meta_label.text = META_FORMAT % [_run.block_count(),
		PlanModel.as_int(_session.get("est_minutes"), 0)]
	_render_source()
	_render_mobility(_warmup_list, SessionRun.KIND_WARMUP, WARMUP_CAPTION)
	_render_blocks()
	_render_mobility(_cooldown_list, SessionRun.KIND_COOLDOWN, COOLDOWN_CAPTION)
	_start_button.text = START_LABEL
	_start_button.disabled = false


func _render_empty() -> void:
	_run = null
	_title_label.text = ""
	_meta_label.text = ""
	_start_button.text = START_LABEL
	_start_button.disabled = true
	_clear_list(_warmup_list)
	_clear_list(_block_list)
	_clear_list(_cooldown_list)
	_warmup_list.visible = false
	_block_list.visible = false
	_cooldown_list.visible = false
	_source_badge.call(&"set_source", "", "")
	_source_host.visible = false


## R1: who wrote the plan, with PRD-08's own component and no re-diagnosis of the source. The host
## follows the badge, because a badge that has nothing to say hides itself.
func _render_source() -> void:
	if _source_badge == null or not _source_badge.has_method(&"set_source"):
		_source_host.visible = false
		return
	_source_badge.call(&"set_source",
		PlanModel.as_text(_plan.get("source"), ""), PlanModel.as_text(_plan.get("provider"), ""))
	_source_host.visible = _source_badge.visible


## One warm-up or cool-down block: a caption, then `"<name> · 60s"` per item. An empty group is
## hidden whole — a `WARM-UP` caption over nothing would be a lie about the session.
func _render_mobility(list: VBoxContainer, kind: String, caption: String) -> void:
	_clear_list(list)
	var items := _steps_of_kind(kind)
	list.visible = not items.is_empty()
	if items.is_empty():
		return
	list.add_child(_caption_label(caption))
	for step in items:
		list.add_child(_mobility_row(step))


## R1's working blocks: a `WORK` caption, then one row per block — `"1. Bench Press"` on the
## left, `"4 × 8-10"` and `"90s rest"` on the right. One `HBoxContainer` per block and no per-set
## chips: set check-off is the player's job, not this screen's.
func _render_blocks() -> void:
	_clear_list(_block_list)
	var blocks := _steps_of_kind(SessionRun.KIND_BLOCK)
	_block_list.visible = not blocks.is_empty()
	if blocks.is_empty():
		return
	_block_list.add_child(_caption_label(WORK_CAPTION))
	for index in blocks.size():
		_block_list.add_child(_block_row(blocks[index], index))


func _mobility_row(step: Dictionary) -> Label:
	var row := Label.new()
	row.name = "MobilityRow"
	row.theme_type_variation = &"BodyLabel"
	row.text = MOBILITY_FORMAT % [
		_exercise_name(PlanModel.as_text(step.get("exercise_id"), "")),
		PlanModel.as_int(step.get("duration_sec"), 0),
	]
	row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return row


func _block_row(step: Dictionary, index: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "BlockRow%d" % (index + 1)
	row.add_theme_constant_override(&"separation", int(DesignTokens.SPACE["md"]))

	var name_label := Label.new()
	name_label.name = "BlockName"
	name_label.theme_type_variation = &"BodyLabel"
	name_label.text = BLOCK_NAME_FORMAT % [index + 1,
		_exercise_name(PlanModel.as_text(step.get("exercise_id"), ""))]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(name_label)

	var scheme := Label.new()
	scheme.name = "BlockScheme"
	scheme.theme_type_variation = &"BodyLabel"
	scheme.text = SETS_REPS_FORMAT % [
		PlanModel.as_int(step.get("sets"), 0),
		PlanModel.as_text(step.get("reps"), ""),
	]
	scheme.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(scheme)

	var rest := Label.new()
	rest.name = "BlockRest"
	rest.theme_type_variation = &"MutedLabel"
	rest.text = REST_FORMAT % PlanModel.as_int(step.get("rest_seconds"), 0)
	rest.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(rest)
	return row


func _caption_label(caption: String) -> Label:
	var label := Label.new()
	label.name = "Caption"
	label.theme_type_variation = &"Caption"
	label.text = caption
	return label


## Removes and frees every row a previous render built, so a re-render cannot stack two sessions.
func _clear_list(list: VBoxContainer) -> void:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()


func _steps_of_kind(kind: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _run == null:
		return out
	for step in _run.steps:
		if PlanModel.as_text(step.get("kind"), "") == kind:
			out.append(step)
	return out


## The library's display name, falling back to the raw id — the same graceful degradation
## `day_card` uses, so a plan whose ids predate the loaded library shows *which* exercise it
## means instead of a blank row.
func _exercise_name(exercise_id: String) -> String:
	if exercise_id.is_empty():
		return ""
	var resolved := Library.name_of(exercise_id)
	return resolved if not resolved.is_empty() else exercise_id


# ===========================================================================
# Actions
# ===========================================================================

func _on_back_pressed() -> void:
	Nav.pop()


## R1: the player gets the same two ids that resolved this screen, so what was previewed is
## exactly what is played.
func _on_start_pressed() -> void:
	if _plan_id.is_empty() or _session_id.is_empty():
		return
	Nav.push(_route_player, {
		"plan_id": _plan_id,
		"session_id": _session_id,
	})


func _on_theme_changed(mode: String) -> void:
	_bg.color = DesignTokens.color(mode, "bg")


# ===========================================================================
# Internals
# ===========================================================================

## The entry of `plan.sessions[]` whose `id` matches [param session_id], or `{}`. A plain
## `Array` walk: a session list read back from JSON is not a typed array.
static func _session_in(plan: Dictionary, session_id: String) -> Dictionary:
	var raw: Variant = plan.get("sessions", null)
	if not (raw is Array):
		return {}
	for entry in (raw as Array):
		if entry is Dictionary and PlanModel.as_text((entry as Dictionary).get("id"), "") == session_id:
			return entry as Dictionary
	return {}


## Resolves a route constant out of the frozen route table, falling back to appendix §2's route
## name. Binding through the table means this screen picks up the real value the moment
## PRD-10's constants land, with no edit here.
static func route_named(constant_name: String) -> StringName:
	var script: Script = load(ROUTES_PATH)
	if script != null:
		var constants: Dictionary = script.get_script_constant_map()
		var value: Variant = constants.get(constant_name, null)
		if value is StringName:
			return value
		if value is String:
			return StringName(value)
	return StringName(ROUTE_FALLBACKS.get(constant_name, ""))


## The greppable line PRD-02 R6 requires of every screen that owns controls, plus R1's tap-test
## rectangles. Deferred one frame so both measure a laid-out screen.
func _report_layout() -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var _violations := TouchTargets.report(self)
	UiProbe.log_rect("session_preview_start", _start_button)
	UiProbe.log_rect("session_preview_back", _back_button)
