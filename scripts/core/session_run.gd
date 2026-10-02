class_name SessionRun
extends RefCounted
## PRD-10 R3 — the pure session state model.
##
## A session is flattened once, at build time, into one ordered `steps` array: `w` warm-up items,
## then `b` working blocks, then `c` cool-down items. Everything the player does — which step is
## showing, which sets are checked, how long the owner has been working — is a function of that
## array plus three counters, which is what makes the whole loop testable under `--script` with no
## scene tree and no autoloads alive (PRD-00 rule 4: no scene-tree access, no `Store`, no `await`).
##
## Three rules that are easy to get wrong and are therefore stated once, here:
##
## 1. **`set_states` is keyed by `exercise_id`.** PRD-05's validator rejects a session that uses
##    the same exercise twice (see `tests/fixtures/bad_plan_duplicate_exercise.json`), so the id is
##    a safe key and R13's persistence shape — `{"bench-press": [true, true, false, false]}` — is
##    readable on its own.
## 2. **Navigating never mutates checks.** `next()`/`prev()` only move `step_index`; going back to
##    look at an earlier exercise keeps every check, because losing work by looking back would be
##    the single most annoying bug this screen could have.
## 3. **`prev()` always lands on a block when one exists before the current position**, otherwise
##    on step 0. Mobility items are not individually steppable backwards (R3) — stepping back from
##    a stretch into three more stretches is not a thing anybody wants.
##
## `REST` and `ZOOMED` are **sub-states of `ACTIVE`**, not model states: only [constant PAUSED] and
## [constant COMPLETING] are real states. The player tracks its overlays separately, so this model
## never has to know that a rest sheet is on screen.

# ------------------------------------------------------------------ step kinds

const KIND_WARMUP := "warmup"
const KIND_BLOCK := "block"
const KIND_COOLDOWN := "cooldown"

# ------------------------------------------------------------------ model states

const ACTIVE := "ACTIVE"
const PAUSED := "PAUSED"
const COMPLETING := "COMPLETING"

## R8's label matrix, verbatim. `NEXT` is the default for every position the table does not name.
const LABEL_NEXT := "Next"
const LABEL_START_SETS := "Start sets"
const LABEL_COOL_DOWN := "Cool down"
## Owner wording (2026-10-01): the last action is a button that literally says it.
const LABEL_DONE := "I'm finished"

## R13: a rest timer never resumes across a process kill (appendix §5.4), so this key is always
## written as `0`. It exists in the shape only so the document matches the frozen schema.
const REST_NEVER_RESUMES := 0

var plan_id: String = ""
var session_id: String = ""
var session_title: String = ""

## The flattened step list. Each entry is one of the three shapes in R3's table.
var steps: Array[Dictionary] = []

var step_index: int = 0

## `exercise_id -> Array[bool]`, one entry per block set. Seeded with every set unchecked at
## build time, so a caller never has to wonder whether a key exists.
var set_states: Dictionary = {}

## Unix seconds. `to_dict()` renders it as the ISO-8601 timestamp the store's schema wants.
var started_at: int = 0

## Active + rest + zoomed seconds only: it never accrues while paused or backgrounded, so a long
## interruption cannot inflate the `duration_sec` the history entry records (R14).
var elapsed_sec: int = 0

var paused_total_sec: int = 0

var state: String = ACTIVE

## Wall-clock seconds when the current step was entered, so a countdown can be derived from
## `elapsed_sec` instead of from a decrementing float (R9). Not persisted.
var step_entered_at_elapsed: int = 0


# ===========================================================================
# Construction (R3)
# ===========================================================================

## Flattens [param session] of [param plan] into one ordered step list.
##
## Tolerates `w == 0` and `c == 0` even though PRD-05 guarantees at least one of each: a hand-edited
## or older plan must degrade to a playable session rather than crash the player.
static func build(plan: Dictionary, session: Dictionary) -> SessionRun:
	var run := SessionRun.new()
	run.plan_id = PlanModel.as_text(plan.get("id"), "")
	run.session_id = PlanModel.as_text(session.get("id"), "")
	run.session_title = PlanModel.as_text(session.get("title"), "")

	var warmup := _dict_list(session.get("warmup", []))
	for index in warmup.size():
		var item: Dictionary = warmup[index]
		run.steps.append({
			"kind": KIND_WARMUP,
			"exercise_id": PlanModel.as_text(item.get("exercise_id"), ""),
			"duration_sec": PlanModel.as_int(item.get("duration_sec"), 0),
			"group_index": index,
		})

	var blocks := _dict_list(session.get("blocks", []))
	for index in blocks.size():
		var block: Dictionary = blocks[index]
		var exercise_id := PlanModel.as_text(block.get("exercise_id"), "")
		var sets := maxi(PlanModel.as_int(block.get("sets"), 0), 0)
		run.steps.append({
			"kind": KIND_BLOCK,
			"exercise_id": exercise_id,
			"sets": sets,
			"reps": PlanModel.as_text(block.get("reps"), ""),
			"rest_seconds": PlanModel.as_int(block.get("rest_seconds"), 0),
			"block_index": index,
		})
		run.set_states[exercise_id] = _unchecked(sets)

	var cooldown := _dict_list(session.get("cooldown", []))
	for index in cooldown.size():
		var item: Dictionary = cooldown[index]
		run.steps.append({
			"kind": KIND_COOLDOWN,
			"exercise_id": PlanModel.as_text(item.get("exercise_id"), ""),
			"duration_sec": PlanModel.as_int(item.get("duration_sec"), 0),
			"group_index": index,
		})

	run.step_entered_at_elapsed = 0
	return run


# ===========================================================================
# Step navigation (R3/R8)
# ===========================================================================

## The step dictionary at [member step_index], or `{}` when there is no such step.
func current_step() -> Dictionary:
	if step_index < 0 or step_index >= steps.size():
		return {}
	return steps[step_index]


## `"warmup"`, `"block"` or `"cooldown"`; `""` when there is no current step.
func step_kind() -> String:
	return PlanModel.as_text(current_step().get("kind"), "")


## The exercise id of the current step, or `""`.
func current_exercise_id() -> String:
	return PlanModel.as_text(current_step().get("exercise_id"), "")


func total_steps() -> int:
	return steps.size()


## `Σ block.sets` — R2's `sets` count for the log line and R13's `sets_total`.
func total_sets() -> int:
	var total := 0
	for step in steps:
		if PlanModel.as_text(step.get("kind"), "") == KIND_BLOCK:
			total += maxi(PlanModel.as_int(step.get("sets"), 0), 0)
	return total


func block_count() -> int:
	var total := 0
	for step in steps:
		if PlanModel.as_text(step.get("kind"), "") == KIND_BLOCK:
			total += 1
	return total


func is_last_step() -> bool:
	return steps.is_empty() or step_index >= steps.size() - 1


func can_prev() -> bool:
	return step_index > 0


## Advances one step. `false` when already on the last one.
func next() -> bool:
	if is_last_step():
		return false
	step_index += 1
	step_entered_at_elapsed = elapsed_sec
	return true


## Steps back. `false` when already on step 0. Lands on the nearest preceding **block** when one
## exists, otherwise on step 0 — mobility items are not individually steppable backwards (R3).
func prev() -> bool:
	if not can_prev():
		return false
	var target := -1
	for index in range(step_index - 1, -1, -1):
		if PlanModel.as_text(steps[index].get("kind"), "") == KIND_BLOCK:
			target = index
			break
	step_index = target if target >= 0 else 0
	step_entered_at_elapsed = elapsed_sec
	return true


## Jumps straight to [param index] (used by a restored `step_index` on resume). `false` when the
## index is out of range.
func goto_step(index: int) -> bool:
	if index < 0 or index >= steps.size():
		return false
	step_index = index
	step_entered_at_elapsed = elapsed_sec
	return true


## R8's label matrix, driven by position and the kind of the **next** step rather than by counting
## warm-ups against a second table — so it stays correct when `w == 0` or `c == 0`.
func next_label() -> String:
	if steps.is_empty() or is_last_step():
		return LABEL_DONE
	var kind := step_kind()
	if kind == KIND_WARMUP:
		# R8: `"Next"` while another warm-up follows, `"Start sets"` on the last one — the label is
		# about the *next* step, so it is derived from the next step's kind, not from a counter.
		if _kind_at(step_index + 1) == KIND_WARMUP:
			return LABEL_NEXT
		return LABEL_START_SETS
	if kind == KIND_BLOCK:
		var following := _kind_at(step_index + 1)
		if following == KIND_BLOCK:
			return LABEL_NEXT
		if following == KIND_COOLDOWN:
			return LABEL_COOL_DOWN
		# Last block, nothing after it.
		return LABEL_DONE
	# A cool-down item that is not the last step.
	return LABEL_NEXT


# ===========================================================================
# Set check-off (R7)
# ===========================================================================

## Flips set [param set_i] of [param exercise_id] and returns the **new** checked state.
## An unknown exercise or an out-of-range index is refused and returns `false` without mutating.
func set_toggle(exercise_id: String, set_i: int) -> bool:
	var sets := _states_for(exercise_id)
	if sets.is_empty() or set_i < 0 or set_i >= sets.size():
		return false
	var next_state: bool = not bool(sets[set_i])
	sets[set_i] = next_state
	return next_state


## Marks set [param set_i] of [param exercise_id] as checked and returns the resulting state.
## `false` when the exercise or index is unknown, so a bad restore cannot silently pass.
func set_checked(exercise_id: String, set_i: int) -> bool:
	var sets := _states_for(exercise_id)
	if sets.is_empty() or set_i < 0 or set_i >= sets.size():
		return false
	sets[set_i] = true
	return true


## R7's chip state for one set. Read-only counterpart of [method set_checked], used by the player to
## reconcile a `toggle_mode` button against the model instead of trusting it.
func is_set_checked(exercise_id: String, set_i: int) -> bool:
	var sets := _states_for(exercise_id)
	if set_i < 0 or set_i >= sets.size():
		return false
	return bool(sets[set_i])


func sets_checked(exercise_id: String) -> int:
	var sets := _states_for(exercise_id)
	var count := 0
	for checked in sets:
		if checked:
			count += 1
	return count


## How many sets the block at [param exercise_id] has — the denominator of R7's `"2/4 sets"` and of
## R13's resume log. `0` for an unknown block, so a stale cursor reads as "nothing to do here".
func block_sets(exercise_id: String) -> int:
	return _states_for(exercise_id).size()


## True when every set of [param exercise_id] is checked. A block with zero sets is never done.
func block_done(exercise_id: String) -> bool:
	var sets := _states_for(exercise_id)
	if sets.is_empty():
		return false
	return sets_checked(exercise_id) == sets.size()


## Owner request (2026-10-01): moving on means "I did this". Checks every remaining set of
## [param exercise_id] in one call and returns how many this call flipped — `0` for an unknown
## block or one that was already complete, so a caller can skip its cue on a no-op. The player
## calls this when the owner swipes forward or taps the action button, which is what lets a
## session finish without tapping each set chip. Never un-checks: a manual tap stays king.
func complete_block(exercise_id: String) -> int:
	var sets := _states_for(exercise_id)
	if sets.is_empty():
		return 0
	var newly := 0
	for index in sets.size():
		if not bool(sets[index]):
			sets[index] = true
			newly += 1
	return newly


## Σ checked sets across every block — R11's `sets_completed` and R12's `Sets` summary.
func sets_completed() -> int:
	var total := 0
	for exercise_id in set_states:
		total += sets_checked(String(exercise_id))
	return total


## Blocks with every set checked. R11's `exercises_completed` and the progress segments' `done`
## state are both this number.
func blocks_completed() -> int:
	var total := 0
	for exercise_id in set_states:
		if block_done(String(exercise_id)):
			total += 1
	return total


## The single predicate that decides the full celebration vs the sober variant (R8/R12).
func fully_completed() -> bool:
	return block_count() > 0 and blocks_completed() == block_count()


## R13's `completed_blocks` array, in step order so the document reads the way the session ran.
func completed_block_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for step in steps:
		if PlanModel.as_text(step.get("kind"), "") != KIND_BLOCK:
			continue
		var exercise_id := PlanModel.as_text(step.get("exercise_id"), "")
		if block_done(exercise_id) and not out.has(exercise_id):
			out.append(exercise_id)
	return out


## R11's `Restart exercise`: clears one block's checks and resets its timer, leaving `elapsed_sec`
## untouched. Returns the number of sets that were cleared.
func restart_block(exercise_id: String) -> int:
	var sets := _states_for(exercise_id)
	if sets.is_empty():
		return 0
	var cleared := 0
	for index in sets.size():
		if sets[index]:
			cleared += 1
		sets[index] = false
	step_entered_at_elapsed = elapsed_sec
	return cleared


# ===========================================================================
# Timed steps (R9)
# ===========================================================================

## Seconds left on the current timed step, derived from wall-clock `elapsed_sec` so it survives
## pauses, backgrounding and dropped frames exactly. Blocks and untimed steps return `0`.
func timed_seconds_remaining() -> int:
	var step := current_step()
	if step.is_empty():
		return 0
	var kind := PlanModel.as_text(step.get("kind"), "")
	if kind == KIND_BLOCK:
		return 0
	var duration := maxi(PlanModel.as_int(step.get("duration_sec"), 0), 0)
	var spent := maxi(elapsed_sec - step_entered_at_elapsed, 0)
	return maxi(duration - spent, 0)


# ===========================================================================
# Time and state
# ===========================================================================

## Adds [param delta] to the active clock. The player only calls this while the session is really
## running, which is what keeps `elapsed_sec` honest across pauses (R14).
func tick(delta: int) -> void:
	if delta > 0:
		elapsed_sec += delta


## Records a pause: the paused total and the state move, the clock stops.
func pause() -> bool:
	if state != ACTIVE:
		return false
	state = PAUSED
	return true


## Leaves `PAUSED` for `ACTIVE`. `false` when the run was not paused.
func resume() -> bool:
	if state != PAUSED:
		return false
	state = ACTIVE
	return true


## R11's label: `"12:04"`.
func elapsed_text() -> String:
	return Dates.format_clock(elapsed_sec)


# ===========================================================================
# Persistence (R13)
# ===========================================================================

## R13's `progress` object — the dictionary [method Store.save_session_progress] takes.
##
## `started_at`/`updated_at` are ISO-8601 because that is what the store's schema validates, while
## the model keeps `started_at` as unix seconds (R3). [param now_iso] is an injectable clock seam so
## a suite can pin `updated_at` without freezing time.
func to_dict(now_iso: String = "") -> Dictionary:
	var stamp := now_iso if not now_iso.is_empty() else Dates.now_iso8601(true)
	var states := {}
	for exercise_id in set_states:
		states[String(exercise_id)] = _copy_bools(_states_for(String(exercise_id)))
	return {
		"plan_id": plan_id,
		"session_id": session_id,
		"started_at": _iso_from_unix(started_at, stamp),
		"updated_at": stamp,
		"step_index": step_index,
		"elapsed_sec": elapsed_sec,
		"paused_total_sec": paused_total_sec,
		"set_states": states,
		"completed_blocks": Array(completed_block_ids()),
		"rest_remaining_sec": REST_NEVER_RESUMES,
	}


## Rebuilds a run from [method to_dict]'s output **plus** the plan/session it belongs to, which is
## why this is not a plain mirror: `steps` and the per-block set counts live in the plan, and a
## cursor with no steps to point at is not a session.
##
## Every field is validated rather than trusted — a hand-edited or truncated document degrades to
## "start at step 0 with nothing checked" instead of crashing the player.
static func from_dict(d: Dictionary, plan: Dictionary, session: Dictionary) -> SessionRun:
	var run := build(plan, session)
	if d.is_empty():
		return run
	run.started_at = _unix_from_iso(PlanModel.as_text(d.get("started_at"), ""))
	run.elapsed_sec = maxi(PlanModel.as_int(d.get("elapsed_sec"), 0), 0)
	run.paused_total_sec = maxi(PlanModel.as_int(d.get("paused_total_sec"), 0), 0)
	run.goto_step(PlanModel.as_int(d.get("step_index"), 0))

	var stored: Variant = d.get("set_states", null)
	if stored is Dictionary:
		for exercise_id in stored:
			var key := String(exercise_id)
			if not run.set_states.has(key):
				# The plan changed under the record: drop the unknown block rather than resurrect
				# a check that no longer has a chip to live on.
				continue
			var values: Variant = stored[exercise_id]
			if not (values is Array or values is PackedByteArray):
				continue
			var restored := _copy_bools(values)
			var current := run._states_for(key)
			for index in mini(restored.size(), current.size()):
				current[index] = restored[index]
	if run.state == "":
		run.state = ACTIVE
	return run


# ===========================================================================
# Internals
# ===========================================================================

## The live `Array[bool]` for [param exercise_id], or an empty array for an unknown block. Never
## returns a copy: callers mutate the model through it, which is what keeps `set_states` the one
## source of truth.
func _states_for(exercise_id: String) -> Array:
	if not set_states.has(exercise_id):
		return []
	var value: Variant = set_states[exercise_id]
	if value is Array:
		return value
	return []


func _kind_at(index: int) -> String:
	if index < 0 or index >= steps.size():
		return ""
	return PlanModel.as_text(steps[index].get("kind"), "")


static func _unchecked(count: int) -> Array[bool]:
	var out: Array[bool] = []
	for _i in maxi(count, 0):
		out.append(false)
	return out


## A plain `Array` copy (not `Array[bool]`) so the dictionary survives `JSON.stringify` and the
## store's own `_to_bool_lists` pass unchanged.
static func _copy_bools(values: Variant) -> Array:
	var out: Array = []
	if values is Array or values is PackedByteArray:
		for value in values:
			out.append(bool(value))
	return out


static func _dict_list(value: Variant) -> Array:
	var out: Array = []
	if value is Array:
		for element in value:
			if element is Dictionary:
				out.append(element)
	return out


## Unix seconds → the `"YYYY-MM-DDTHH:MM:SSZ"` shape every stored timestamp uses. Falls back to
## [param fallback] when the clock value is unusable, so `started_at` is never an empty string on a
## document the store validates.
static func _iso_from_unix(unix: int, fallback: String) -> String:
	if unix <= 0:
		return fallback
	# `false` = the `T` separator: the store validates `YYYY-MM-DDTHH:MM:SSZ` (appendix §5.3) and
	# `Time`'s default would write a space, which `Dates.is_valid_iso_datetime()` rejects.
	return Time.get_datetime_string_from_unix_time(unix, false) + "Z"


## The inverse of [method _iso_from_unix]. `0` when the stamp cannot be read; [method Dates.epoch_seconds]
## warns on invalid input, so it is only called once the string is known to be well-formed.
static func _unix_from_iso(iso: String) -> int:
	if iso.is_empty() or not Dates.is_valid_iso_datetime(iso):
		return 0
	return Dates.epoch_seconds(iso)
