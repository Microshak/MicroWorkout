class_name WizardState
extends RefCounted
## PRD-08 R9 — the New Workout wizard's pure input model.
##
## Six steps, five answers, one deliberate omission: **`goal` is never persisted** (PRD-00 D4,
## R7). `to_dict()` writes the draft the settings document stores, and that dictionary has no
## `goal` key at all, so a restored draft can never pre-answer the question the owner is
## supposed to answer every single time. `apply_dict()` clears `goal` and `seed` as well, so a
## hand-edited `settings.json` cannot smuggle one in either.
##
## This file has no scene tree, no `Store`, no `LLM` and no `Library` (PRD-00 rule 4): every
## method is a pure function of the fields, which is what makes the whole model testable under
## `--script` with no autoloads alive.
##
## Step order is PRD-08 §10 note N1's resolution — the owner's own words first, the training
## goal last, immediately before the review.

## Step enum (R2). The **values** are the array indices the UI switches on, so they are part of
## the contract and are asserted in `tests/suites/test_wizard_state.gd`.
const STEP_NOTES := 0
const STEP_AREAS := 1
const STEP_DAYS := 2
const STEP_DURATION := 3
const STEP_GOAL := 4
const STEP_REVIEW := 5
const STEP_COUNT := 6

## The five answer steps, in order — `STEP_REVIEW` is not one of them.
const ANSWER_STEPS := 5

## R2's table, verbatim.
const STEP_TITLES: PackedStringArray = [
	"What matters to you?",
	"Which areas?",
	"How many days a week?",
	"How long per session?",
	"What are you training for?",
	"Ready to build your week",
]

## R2's `StepIndicator` column, verbatim.
const STEP_INDICATORS: PackedStringArray = [
	"STEP 1/5", "STEP 2/5", "STEP 3/5", "STEP 4/5", "STEP 5/5", "REVIEW",
]

const DAYS_MIN := 1
const DAYS_MAX := 6
const DEFAULT_DAYS := 4

## R6's five segments, in order. Any other value is not reachable from the UI and is rejected
## by [method is_step_valid].
const DURATION_OPTIONS: PackedInt32Array = [20, 30, 40, 50, 60]
const DEFAULT_DURATION_MIN := 40

## R3: the `TextEdit` `max_length` and the character counter's denominator.
const NOTES_MAX := 500

## R9: a draft older than this is ignored on load and silently replaced.
const DRAFT_MAX_AGE_DAYS := 30

## R7's four goals. The left column is the canonical `Plan.goal` value (appendix §6.2 / R32:
## `general_fitness`, never `general`), and copy is fixed by the appendix so no screen
## re-invents it.
const GOAL_KEYS: PackedStringArray = [
	"strength", "hypertrophy", "general_fitness", "conditioning",
]
const GOAL_TITLES: PackedStringArray = [
	"Strength", "Hypertrophy", "General fitness", "Conditioning",
]
const GOAL_DESCRIPTIONS: PackedStringArray = [
	"Heavy and low reps. 3–6 reps, 4–5 sets, long rests.",
	"Build muscle. 8–12 reps, 3–4 sets, 75–90s rests.",
	"Feel better all round. 8–15 reps, 2–3 sets, 60–75s rests.",
	"Get your heart rate up. 12–20 reps, 2–3 sets, short rests.",
]

## R4's exact validation copy for the area step.
const MESSAGE_AREAS := "Pick at least one area to train."

## `"" | strength | hypertrophy | general_fitness | conditioning`. Never defaulted, never
## restored from the draft (D4).
var goal: String = ""

## The `Taxonomy.USER_AREAS` subset the owner picked, in **insertion order** (R9) — the review
## row and the request carry that order.
var areas: Array[String] = []

## 1..6 (appendix §6.4 / R60 — 7 is settings-only).
var days_per_week: int = DEFAULT_DAYS

## One of [constant DURATION_OPTIONS].
var duration_min: int = DEFAULT_DURATION_MIN

## The owner's own words, `strip_edges()`d on the way into the request, truncated at
## [constant NOTES_MAX]. Empty means "no constraints" and is valid (R3).
var notes: String = ""

## The generation seed. `0` = not yet assigned; the **wizard** assigns
## `Time.get_unix_time_from_system()` before the first generation and `seed + 1` per
## regeneration (R9/R13). Never persisted.
##
## The name is R9's and is therefore kept verbatim, even though it shadows GDScript's global
## `seed()` helper — hence the suppression rather than a rename that would break the frozen API.
@warning_ignore("shadowed_global_identifier")
var seed: int = 0


# ===========================================================================
# Step validity (R2.2)
# ===========================================================================

## True when [param step] may be left forward. `STEP_REVIEW` is valid exactly when every answer
## step is, which is what enables `Generate my plan`.
func is_step_valid(step: int) -> bool:
	match step:
		STEP_NOTES:
			# R3: empty notes are valid and mean "no constraints".
			return true
		STEP_AREAS:
			return not areas.is_empty()
		STEP_DAYS:
			return days_per_week >= DAYS_MIN and days_per_week <= DAYS_MAX
		STEP_DURATION:
			return DURATION_OPTIONS.has(duration_min)
		STEP_GOAL:
			return GOAL_KEYS.has(goal)
		STEP_REVIEW:
			return is_complete()
	return false


## R2.2/R4's `ValidationLabel` text for [param step], or `""` when the step is valid. Only the
## area step has prescribed copy; the others disable `Next` without a sentence.
func validation_message(step: int) -> String:
	if is_step_valid(step):
		return ""
	if step == STEP_AREAS:
		return MESSAGE_AREAS
	return ""


## Every answer step valid — `Generate my plan` is enabled exactly here.
func is_complete() -> bool:
	for step in range(ANSWER_STEPS):
		if not is_step_valid(step):
			return false
	return true


## R2.3's "nothing to lose" test: every field at its default and no notes. The goal is at its
## default `""`, which is where it always starts.
func is_pristine() -> bool:
	return goal.is_empty() \
		and areas.is_empty() \
		and days_per_week == DEFAULT_DAYS \
		and duration_min == DEFAULT_DURATION_MIN \
		and notes.strip_edges().is_empty()


## The first answer step that is not valid, or `-1` when they all are. Drives the review
## screen's one-tap jumps back after a partial restore.
func next_invalid_step() -> int:
	for step in range(ANSWER_STEPS):
		if not is_step_valid(step):
			return step
	return -1


# ===========================================================================
# Display helpers
# ===========================================================================

## The R7 title for the chosen goal, or `""` when the owner has not chosen one yet. Returning
## `""` rather than a default is deliberate: a screen that renders this cannot accidentally
## show a goal that was never picked.
func goal_label() -> String:
	return title_for_goal(goal)


## R7's title for a stored goal key, `""` for anything that is not one of the four. Static so a
## screen that only has a stored `goal` string (the preview's meta row) can reuse it.
static func title_for_goal(key: String) -> String:
	var index := GOAL_KEYS.find(key)
	return GOAL_TITLES[index] if index >= 0 else ""


## The R4 chip labels for the chosen areas, in the order they were picked.
func area_labels() -> PackedStringArray:
	var out := PackedStringArray()
	for area in areas:
		out.append(Taxonomy.label(area))
	return out


## `"40 min"` — R6's segment label, reusable as the review row value.
func duration_label() -> String:
	return "%d min" % duration_min


## The R8 review row for the notes: the first 60 characters plus an ellipsis, or the exact
## "nothing here" copy. Trimmed first so leading whitespace does not eat the preview budget.
func notes_preview() -> String:
	var text := notes.strip_edges()
	if text.is_empty():
		return "None — that's fine."
	if text.length() <= 60:
		return text
	return text.substr(0, 60) + "…"


## `"4/500"` — R3's character counter.
func notes_counter() -> String:
	return "%d/%d" % [notes.length(), NOTES_MAX]


# ===========================================================================
# Mutation (used by the UI and by the tests)
# ===========================================================================

## Adds or removes [param area]. Unknown and reserved keys (`mobility`) are refused, so the
## grid can never put the model into a state the generator would reject.
func toggle_area(area: String) -> void:
	if not Taxonomy.is_user_area(area):
		return
	if areas.has(area):
		areas.erase(area)
	else:
		areas.append(area)


## Sets one area explicitly (the UI's `set_area(area, selected)` path).
func set_area(area: String, selected: bool) -> void:
	if not Taxonomy.is_user_area(area):
		return
	var present := areas.has(area)
	if selected and not present:
		areas.append(area)
	elif not selected and present:
		areas.erase(area)


## The R3 paste rule: text longer than [constant NOTES_MAX] is truncated, so the caret-keeps-up
## branch in the screen has a single source of truth for the limit.
func set_notes(text: String) -> void:
	notes = text.substr(0, NOTES_MAX) if text.length() > NOTES_MAX else text


## One of [constant DURATION_OPTIONS], or ignored. Returns whether the value was accepted.
func set_duration_min(value: int) -> bool:
	if not DURATION_OPTIONS.has(value):
		return false
	duration_min = value
	return true


## One of [constant GOAL_KEYS], or ignored. Returns whether the value was accepted.
func set_goal(key: String) -> bool:
	if not GOAL_KEYS.has(key):
		return false
	goal = key
	return true


## Clamped into 1..6 (appendix §6.4).
func set_days_per_week(value: int) -> void:
	days_per_week = clampi(value, DAYS_MIN, DAYS_MAX)


# ===========================================================================
# Serialisation
# ===========================================================================

## R9's request — the exact dictionary `LLM.generate_plan()` is called with. Every key is
## always present and `null` is never used, so the prompt builder and the built-in generator
## see the same shape. `seed` is the wizard's, not this class's to choose.
func to_request(equipment: Array[String]) -> Dictionary:
	return {
		"goal": goal,
		"areas": areas.duplicate(),
		"days_per_week": days_per_week,
		"duration_min": duration_min,
		"notes": notes.strip_edges(),
		"equipment": equipment.duplicate(),
		"seed": seed,
	}


## The draft persisted at `settings.json → ui.wizard_draft` (R9). **Never contains `goal` or
## `seed`** — that is the mechanism that enforces PRD-00 D4.
##
## [param now_iso] is injectable so a suite can pin `saved_at` without touching the clock.
func to_dict(now_iso: String = "") -> Dictionary:
	var stamp := now_iso if not now_iso.is_empty() else Dates.now_iso8601(true)
	return {
		"areas": areas.duplicate(),
		"days_per_week": days_per_week,
		"duration_min": duration_min,
		"notes": notes,
		"saved_at": stamp,
	}


## Restores a draft written by [method to_dict]. Unknown areas, out-of-range numbers and a
## duration that is not one of R6's five segments are dropped rather than trusted, and `goal`
## and `seed` are cleared unconditionally (D4).
func apply_dict(d: Dictionary) -> void:
	if d.is_empty():
		return
	areas = _areas_from(d.get("areas", []))
	days_per_week = clampi(PlanModel.as_int(d.get("days_per_week"), DEFAULT_DAYS),
		DAYS_MIN, DAYS_MAX)
	var duration := PlanModel.as_int(d.get("duration_min"), DEFAULT_DURATION_MIN)
	duration_min = duration if DURATION_OPTIONS.has(duration) else DEFAULT_DURATION_MIN
	set_notes(text_of(d.get("notes", "")))
	goal = ""
	seed = 0


## The full field set — used by the preview screen to hand the wizard back to itself when the
## owner taps `Edit answers`. Unlike [method to_dict] this one **does** carry `goal` and `seed`,
## because it never reaches disk: it travels as route arguments inside the process.
func to_full_dict() -> Dictionary:
	return {
		"goal": goal,
		"areas": areas.duplicate(),
		"days_per_week": days_per_week,
		"duration_min": duration_min,
		"notes": notes,
		"seed": seed,
	}


## The inverse of [method to_full_dict]. Still refuses anything the model would not accept.
func apply_full_dict(d: Dictionary) -> void:
	apply_dict(d)
	var restored := text_of(d.get("goal", ""))
	goal = restored if GOAL_KEYS.has(restored) else ""
	seed = PlanModel.as_int(d.get("seed"), 0)


## Back to R5/R6's defaults with the goal unanswered and no areas — R8's `Start over`.
func reset() -> void:
	goal = ""
	areas = []
	days_per_week = DEFAULT_DAYS
	duration_min = DEFAULT_DURATION_MIN
	notes = ""
	seed = 0


# ===========================================================================
# Draft freshness
# ===========================================================================

## True when [param draft] carries a parseable `saved_at` no older than
## [constant DRAFT_MAX_AGE_DAYS]. A draft with no usable timestamp is **not** fresh: restoring
## answers the owner may have moved on from is worse than asking again (PRD-08 §8's stale-draft
## risk row).
##
## [param now_unix] is injectable (`0` = read the clock) so the rule is testable without
## freezing time.
static func is_fresh(draft: Dictionary, now_unix: int = 0) -> bool:
	if draft.is_empty():
		return false
	var saved_at := text_of(draft.get("saved_at", ""))
	var saved_unix := unix_from_iso(saved_at)
	if saved_unix <= 0:
		return false
	var now := now_unix if now_unix > 0 else int(Time.get_unix_time_from_system())
	# A draft stamped in the future (a clock that moved backwards) is treated as fresh: the
	# alternative is silently deleting the owner's answers.
	if saved_unix > now:
		return true
	return now - saved_unix <= DRAFT_MAX_AGE_DAYS * 86400


## Unix seconds for an ISO-8601 timestamp, `0` when it cannot be read. [Dates] parses the
## string (so a malformed one is rejected the same way everywhere) and the civil fields are
## handed to the engine as UTC, matching the `…Z` stamps every stored timestamp uses.
static func unix_from_iso(iso: String) -> int:
	var parts := Dates.parse_iso_datetime(iso)
	if parts.is_empty():
		return 0
	return int(Time.get_unix_time_from_datetime_dict({
		"year": int(parts["y"]),
		"month": int(parts["m"]),
		"day": int(parts["d"]),
		"hour": int(parts["h"]),
		"minute": int(parts["mi"]),
		"second": int(parts["s"]),
	}))


# ===========================================================================
# Internals
# ===========================================================================

## Text view of a JSON value that is never a crash. [method PlanModel.as_text] is the same
## helper the plan validator uses, for the same reason it documents: Godot's `String()`
## constructor rejects an Array/Dictionary argument outright, and a hand-edited
## `settings.json` must not be able to kill the wizard.
static func text_of(value: Variant, fallback: String = "") -> String:
	return PlanModel.as_text(value, fallback)


## A plain, untyped copy of an array-ish value. Iterating the *plain* Array keeps the element
## type `Variant`; iterating the caller's `Array[String]` would make `String(entry)` a
## statically-bound constructor call, which is exactly the call that fails at runtime.
static func plain_list(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array or raw is PackedStringArray:
		for entry in raw:
			out.append(entry)
	return out


## The seven user areas only, deduplicated, insertion order preserved (R9). A reserved area
## (`mobility`) or an unknown key in a hand-edited draft is dropped.
static func _areas_from(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	for entry in plain_list(raw):
		var key := text_of(entry, "")
		if Taxonomy.is_user_area(key) and not out.has(key):
			out.append(key)
	return out
