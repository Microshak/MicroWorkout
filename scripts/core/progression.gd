class_name Progression
extends RefCounted
## PRD-05 R15 (advice content) / PRD-10 R15 (the caller's contract) — what to do **next** time.
##
## The app deliberately does not log weight or reps per set (PRD-00 D6), so progression advice is
## the only "you are getting stronger" machinery in v1: one honest, goal-keyed line about the next
## session, shown on the completion screen. Everything here is a pure function of the plan, the
## session that was just finished and the history that exists — no `Store`, no scene tree, no
## timing — so the whole module is unit-testable under `--script`.
##
## Two contracts meet here and the name follows PRD-10's, because PRD-10 is the only consumer:
## PRD-05 R15 specified `note(plan, completed_sessions, area_reached_top)`; PRD-10 R15 specifies
## `advise(plan, session, history)`. They are implemented as **one** function — [method advise] —
## with PRD-05's four strings preserved verbatim. PRD-05's `area_reached_top` flag is dropped
## rather than accepted-and-ignored: with no weight logging there is nothing that can set it, and a
## dead parameter in a public API is a lie about what the function does. See `DECISIONS.md`.
##
## The advice is **never stored in the plan** (no schema change, PRD-05 R15): it is recomputed on
## every completion, which is also why it can get better in a later release without a migration.

## The four goal strings, verbatim from PRD-05 R15. `general_fitness` is PRD-00 §5.3's real id for
## what PRD-05's prose calls `general`; both spellings resolve to the same line, so a hand-edited
## plan that says `"general"` still gets advice instead of the fallback.
const ADVICE: Dictionary = {
	"strength": "Next session: if you hit the top of every rep range, add 2.5–5 lb to the bar. " \
		+ "If you missed reps, keep the weight the same.",
	"hypertrophy": "Next session: add one rep per set until you reach the top of the range, then " \
		+ "add the smallest weight jump you have and drop back to the bottom of the range.",
	"general_fitness": "Next session: aim for one more rep than last time on your first set of " \
		+ "each exercise.",
	"general": "Next session: aim for one more rep than last time on your first set of " \
		+ "each exercise.",
	"conditioning": "Next session: shorten your rest by 5 seconds or add one round — not both.",
}

## The goal whose string an unknown or missing goal falls back to (PRD-05 R15).
const FALLBACK_GOAL := "general_fitness"

## PRD-05 R15's consistency sentence, appended from the third completed session onwards.
const CONSISTENCY_MIN := 3
const CONSISTENCY_LINE := " You've finished %d sessions on this plan — consistency is doing the work."

## R12 shows exactly one line and clips it; both live here so the screen holds no string maths.
const DISPLAY_LIMIT := 120
const ELLIPSIS := "…"


## The advice for the session that was just finished, as it comes out of the model.
##
## Line 0 is the practical, goal-keyed line the completion screen shows; a second line carries the
## consistency sentence once the owner has finished [constant CONSISTENCY_MIN] sessions on this
## plan. Callers that show one line use [method first_line].
##
## [param session] is the session that was just finished. v1's advice is keyed by the plan's goal
## only, so the session changes exactly one thing honestly: an unresolved session — a player that
## lost its plan under itself — returns `""`, which is the documented trigger for the completion
## screen's fallback copy (PRD-10 R12) rather than advice invented from nothing.
static func advise(plan: Dictionary, session: Dictionary, history: Array) -> String:
	if session.is_empty():
		return ""
	var goal := PlanModel.as_text(plan.get("goal"), FALLBACK_GOAL).strip_edges().to_lower()
	var line := String(ADVICE.get(goal, ADVICE[FALLBACK_GOAL]))
	var finished := completed_sessions(plan, history)
	if finished >= CONSISTENCY_MIN:
		return line + "\n" + (CONSISTENCY_LINE % finished).strip_edges()
	return line


## Completed entries on [param plan] in [param history] — `completed == true` only, because a
## partial end is written to history but is deliberately not "a session finished" (PRD-10 §10 N3).
##
## [param history] is the caller's pre-entry list (`Store.all_entries()` read *before* the new
## entry is committed), so the count the owner sees excludes the session they just finished.
static func completed_sessions(plan: Dictionary, history: Array) -> int:
	var plan_id := PlanModel.as_text(plan.get("id"), "")
	if plan_id.is_empty():
		return 0
	var count := 0
	for element in history:
		if not (element is Dictionary):
			continue
		var entry: Dictionary = element
		if PlanModel.as_text(entry.get("plan_id"), "") != plan_id:
			continue
		if bool(entry.get("completed", false)):
			count += 1
	return count


## Line 0 of [param text], stripped — what the completion screen's card shows (PRD-10 R12).
static func first_line(text: String) -> String:
	var lines := text.split("\n", false)
	if lines.is_empty():
		return ""
	return String(lines[0]).strip_edges()


## [param text] clipped to [param limit] characters, ending in an ellipsis.
##
## The cut lands on the last word boundary inside the limit when there is one, because
## "…add 2.5–5 lb to the bar. If you missed…" reads like a sentence and "…add 2.5–5 lb to the b…"
## reads like a bug. A single unbroken word longer than the limit is cut at the limit.
static func clip(text: String, limit: int = DISPLAY_LIMIT) -> String:
	var source := text.strip_edges()
	if limit <= 0 or source.length() <= limit:
		return source
	var head := source.substr(0, limit)
	var space := head.rfind(" ")
	if space > int(float(limit) / 2.0):
		head = head.substr(0, space)
	return head.strip_edges() + ELLIPSIS
