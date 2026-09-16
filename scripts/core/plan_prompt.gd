class_name PlanPrompt
extends RefCounted
## PRD-07 R4 — the verbatim prompts, the catalog embedding and the prompt digests.
##
## [b]Everything here is static, node-free and scene-tree-free[/b], so the prompt a provider will
## receive is unit-testable byte for byte without a socket, a scene tree or the `Library`
## autoload (which does not exist under `--script`). The request the model sees is therefore
## *provable*, not merely described: [method system_prompt] is the R4 constant, and
## [method user_prompt] is R4's template with its seven documented placeholders filled in.
##
## [b]The one amendment to R4's catalog line format.[/b] R4's system prompt tells the model that
## warm-up and cooldown items come "only from exercises marked `is_stretch`", but R4's line
## format has no column for that flag — the model could not tell a stretch from an isolation
## lift, so on a real provider every warm-up would be rejected by the validator
## (`E_BAD_STRETCH`) and the ladder would fall back. The `kind` column therefore reads
## `stretch` for records with `is_stretch == true` instead of `isolation` (`compound` and
## `isolation` are unchanged for everything else). Same column count, same separators.
##
## [b]Key discipline (R12).[/b] The catalog text is **never** logged — an id list is large and
## would drown the one-line-per-request log. [method catalog_digest] is the sha256 of the
## embedded lines and is what the log and `plan.generation` carry instead, so "the prompt the
## model saw" is still identifiable after the fact.

## Pinned prompt version. It goes into every log line and into `plan.generation` (R6 step 8),
## so a plan can always be traced back to the prompt that produced it.
const PROMPT_VERSION := "mw-plan-prompt/1"

## R10's hard limits: 220 catalog lines, 24 000 characters of catalog text.
const CATALOG_MAX_LINES: int = 220
const CATALOG_MAX_CHARS: int = 24000

## R4's repair limits: at most 20 errors, each message 200 characters, previous reply 4 000.
const REPAIR_ERRORS_MAX: int = 20
const REPAIR_MESSAGE_MAX: int = 200
const REPAIR_PREVIOUS_MAX: int = 4000

## What an empty list or an empty note renders as (R4).
const NONE_TEXT := "(none)"

## R4's `system_prompt()`, verbatim (the PRD's R4 code block).
const SYSTEM_PROMPT := """You are the workout-planning engine inside MicroWorkout, a personal Android training app.
You write one week of gym training for a single person who has full gym access.

OUTPUT CONTRACT — follow exactly:
- Reply with ONE JSON object and nothing else. No prose, no markdown, no code fences, no comments.
- The object must match the PLAN SCHEMA in the user message exactly. Every required key must be present.
- Every "exercise_id" MUST be copied verbatim from the ALLOWED EXERCISES list in the user message.
  Never invent an id, never translate a name, never use an exercise that is not in that list.
- "sessions" must contain exactly DAYS_PER_WEEK objects, with "index" values 0..DAYS_PER_WEEK-1 in order.
- Session "title" values must be different from each other; give each session a "focus" list of area keys.
- "warmup" and "cooldown" each contain exactly 2 items, chosen only from exercises marked "is_stretch".
- Each block needs sets, reps as a string range like "8-10", and rest_seconds as an integer.
- est_minutes must be within 15% of DURATION_MIN.
- Write "split_name" as the split you actually used.

PROGRAMMING RULES:
- Use the split for the given number of days: 1 = Full Body; 2 = Full Body A/B; 3 = Push/Pull/Legs
  (Full Body x3 if AREAS has 3 or fewer entries); 4 = Upper/Lower/Upper/Lower; 5 = Push/Pull/Legs/Upper/Lower;
  6 = Push/Pull/Legs x2.
- Sets, reps and rest by GOAL: strength = 4-5 sets, 3-6 reps, 150-180 s rest;
  hypertrophy = 3-4 sets, 8-12 reps, 75-90 s rest; general_fitness = 2-3 sets, 8-15 reps, 60-75 s rest;
  conditioning = 2-3 sets, 12-20 reps, 30-45 s rest, circuit-style.
- Weekly volume: at least 10 hard sets for every area in AREAS and never more than 22.
- Compound lifts first in each session, isolation work after.
- Never place two exercises with the same primary muscle back to back in the same session.
- Cap each session at 12 working blocks. Never produce a session with zero blocks.
- Respect NOTES exactly: if it mentions pain, an injury, or an exercise to avoid, remove those movements.
  NOTES are the user's own words; treat them as hard constraints, not suggestions.
- Do not add medical advice, warnings, encouragement, or commentary about the user's body anywhere
  in the JSON.

If you cannot satisfy every rule, still return the best valid JSON object you can. A slightly imperfect
plan that validates is far more useful than an explanation."""

## R4's `user_prompt()` template, verbatim. Exactly seven `%`-style placeholders, filled in this
## order: goal, days_per_week, duration_min, areas, equipment, notes, catalog lines. The
## `PLAN SCHEMA` block is part of the template (R4: "the catalog and schema blocks are inserted
## literally"), which is why `<GOAL>` and friends appear in it — the model reads the real values
## from the `PLAN REQUEST` header directly above it.
const USER_PROMPT_TEMPLATE := """PLAN REQUEST
GOAL: %s
DAYS_PER_WEEK: %d
DURATION_MIN: %d
AREAS: %s
EQUIPMENT: %s
NOTES: %s

ALLOWED EXERCISES (id | name | areas | equipment | type | kind | default sets x reps @ rest):
%s

PLAN SCHEMA (return this object, keys exactly as written):
{
  "name": "<short plan name, e.g. '4-Day Upper/Lower'>",
  "split_name": "<the split you used>",
  "goal": "<GOAL>",
  "days_per_week": <DAYS_PER_WEEK>,
  "duration_min": <DURATION_MIN>,
  "areas": [<AREAS>],
  "equipment": [<EQUIPMENT>],
  "notes": "<NOTES, copied back unchanged>",
  "sessions": [
    {
      "id": "s1", "index": 0,
      "title": "<session title>",
      "focus": ["<area key>", "..."],
      "est_minutes": <integer near DURATION_MIN>,
      "warmup":  [{"exercise_id": "<stretch id>", "duration_sec": 60}],
      "blocks":  [{"exercise_id": "<id from the list above>", "sets": 4, "reps": "8-10", "rest_seconds": 90}],
      "cooldown":[{"exercise_id": "<stretch id>", "duration_sec": 60}]
    }
  ]
}

Return only the JSON object."""

## R4's `repair_prompt()` block, verbatim: two placeholders (the rendered error list, the
## truncated previous reply), appended to the original user prompt rather than replacing it.
const REPAIR_TEMPLATE := """YOUR PREVIOUS REPLY FAILED VALIDATION.

VALIDATION ERRORS (each line is: code | path | problem):
%s

YOUR PREVIOUS REPLY (truncated to 4000 characters):
%s

Return the COMPLETE corrected JSON object, including the parts that were already valid.
Fix exactly the problems listed, change nothing else, and return only the JSON object."""


# ------------------------------------------------------------------ R4 — the prompts

## R4's system prompt. A pure constant: no interpolation, no settings, nothing that could make
## two calls differ.
static func system_prompt() -> String:
	return SYSTEM_PROMPT


## R4's user prompt for [param input] and [param catalog].
##
## `input` uses the PRD-05 generator keys (`goal`, `days_per_week`, `duration_min`, `areas`,
## `equipment`, `notes`), so the wizard has exactly one request shape for both paths. An empty
## `notes` renders as `(none)`, as does an empty `areas`/`equipment` list.
static func user_prompt(input: Dictionary, catalog: Array[Dictionary]) -> String:
	var notes := String(input.get("notes", "")).strip_edges()
	return USER_PROMPT_TEMPLATE % [
		String(input.get("goal", Generator.DEFAULT_GOAL)),
		PlanModel.as_int(input.get("days_per_week"), Generator.DEFAULT_DAYS),
		PlanModel.as_int(input.get("duration_min"), Generator.DEFAULT_DURATION_MIN),
		_list_text(input.get("areas", [])),
		_list_text(input.get("equipment", [])),
		notes if not notes.is_empty() else NONE_TEXT,
		"\n".join(catalog_lines(catalog)),
	]


## R4's repair prompt: the original user prompt with the failure block appended, **not** a
## replacement. [param errors] are [PlanValidator]'s error dictionaries; [param previous_raw] is
## the model's own reply, sliced to [constant REPAIR_PREVIOUS_MAX] characters.
static func repair_prompt(base_user_prompt: String, errors: Array[Dictionary],
		previous_raw: String) -> String:
	var lines := PackedStringArray()
	for index in mini(errors.size(), REPAIR_ERRORS_MAX):
		var error: Dictionary = errors[index]
		var message := String(error.get("message", ""))
		if message.length() > REPAIR_MESSAGE_MAX:
			message = message.substr(0, REPAIR_MESSAGE_MAX)
		lines.append("%s | %s | %s" % [
			String(error.get("code", "")), String(error.get("path", "")), message])
	var previous := previous_raw
	if previous.length() > REPAIR_PREVIOUS_MAX:
		previous = previous.substr(0, REPAIR_PREVIOUS_MAX)
	return "%s\n\n%s" % [base_user_prompt, REPAIR_TEMPLATE % ["\n".join(lines), previous]]


# ------------------------------------------------------------------ R4/R10 — the catalog

## `id | Name | areas(comma) | equipment | type | kind | default_sets x rep_min-rep_max @ rest`,
## one line per record, capped at [constant CATALOG_MAX_LINES] and
## [constant CATALOG_MAX_CHARS] (R10).
##
## Sort order when a cap bites: compound movements first, then the records that serve the most
## areas (R4's "primary_muscle coverage" — broadest first, so a truncated list still lets the
## model cover every requested area), then `primary_muscle`, then id. Stretch records are placed
## last **and are never truncated**: the prompt requires warm-up and cooldown items to come from
## them, so cutting them would make a valid reply impossible.
static func catalog_lines(catalog: Array[Dictionary]) -> PackedStringArray:
	var working: Array[Dictionary] = []
	var stretches: Array[Dictionary] = []
	for record in catalog:
		if record.is_empty() or String(record.get("id", "")).is_empty():
			continue
		if bool(record.get("is_stretch", false)):
			stretches.append(record)
		else:
			working.append(record)
	working.sort_custom(_compare_for_cap)
	stretches.sort_custom(_compare_by_id)
	# The stretches are laid out first so both caps can be charged for them: they are never
	# truncated, so a working record only gets what is left after the warm-up material is paid
	# for. (With a 13-stretch library this costs ~1 100 of the 24 000 characters.)
	var stretch_lines := PackedStringArray()
	var stretch_chars := 0
	for record in stretches:
		var stretch_line := catalog_line(record)
		if stretch_chars + stretch_line.length() + 1 > CATALOG_MAX_CHARS:
			break
		stretch_chars += stretch_line.length() + 1
		stretch_lines.append(stretch_line)
	var budget := maxi(0, CATALOG_MAX_LINES - stretch_lines.size())
	var char_budget := maxi(0, CATALOG_MAX_CHARS - stretch_chars)
	var out := PackedStringArray()
	var used_chars := 0
	for record in working:
		if out.size() >= budget:
			break
		var line := catalog_line(record)
		if used_chars + line.length() + 1 > char_budget:
			break
		used_chars += line.length() + 1
		out.append(line)
	out.append_array(stretch_lines)
	return out


## One R4 catalog line. `kind` reads `stretch` for mobility records (see the file header).
static func catalog_line(record: Dictionary) -> String:
	var kind := "isolation"
	if bool(record.get("is_stretch", false)):
		kind = "stretch"
	elif bool(record.get("compound", false)):
		kind = "compound"
	return "%s | %s | %s | %s | %s | %s | %d x %d-%d @ %d" % [
		String(record.get("id", "")),
		String(record.get("name", "")),
		_list_text(record.get("areas", [])),
		Generator.equipment_key(record),
		String(record.get("exercise_type", "")),
		kind,
		PlanModel.as_int(record.get("default_sets"), 0),
		PlanModel.as_int(record.get("rep_min"), 0),
		PlanModel.as_int(record.get("rep_max"), 0),
		PlanModel.as_int(record.get("rest_seconds"), 0),
	]


## sha256 of the embedded catalog text — 64 lowercase hex characters. This, and never the
## catalog itself, is what gets logged (R12).
static func catalog_digest(lines: PackedStringArray) -> String:
	return "\n".join(lines).sha256_text()


## R10/R42's filter, expressed on core data so the headless ladder and the device agree.
##
## [param records] is an array of full library records. A record is kept when it serves one of
## [param areas] **and** its equipment maps to one of [param equipment]; an empty filter array
## means "no constraint on that dimension" (appendix §1.3's convention). Stretch records are
## always kept, whatever the filter, because the prompt's warm-up/cooldown rule leaves the model
## no other legal choice.
##
## [b]Why the equipment comparison goes through [method Generator.equipment_key]:[/b] library
## records carry the raw equipment string (`"Barbell"`, `"Pull-up Bar"`) while the wizard and
## `settings.json` use the five lowercase keys, so filtering on the raw string would keep
## nothing. `Generator.equipment_key()` is the existing, drift-tested mapping between the two.
static func filter_records(records: Array, areas: PackedStringArray,
		equipment: PackedStringArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in records:
		if not (entry is Dictionary):
			continue
		var record: Dictionary = entry
		if String(record.get("id", "")).is_empty():
			continue
		if bool(record.get("is_stretch", false)):
			out.append(record)
			continue
		if not areas.is_empty() and not _intersects(record.get("areas", []), areas):
			continue
		if not equipment.is_empty() and not equipment.has(Generator.equipment_key(record)):
			continue
		out.append(record)
	return out


## True when any element of [param values] is in [param wanted] — the shared predicate behind
## [method filter_records].
static func _intersects(values: Variant, wanted: PackedStringArray) -> bool:
	if values is Array or values is PackedStringArray:
		for value in values:
			if wanted.has(String(value)):
				return true
	return false


## R10's cap order: compound first, then breadth (how many areas the record serves, widest
## first), then `primary_muscle`, then id. Total and stable, so one catalog always produces one
## prompt.
static func _compare_for_cap(a: Dictionary, b: Dictionary) -> bool:
	var left_compound := 0 if bool(a.get("compound", false)) else 1
	var right_compound := 0 if bool(b.get("compound", false)) else 1
	if left_compound != right_compound:
		return left_compound < right_compound
	var left_areas := _area_count(a)
	var right_areas := _area_count(b)
	if left_areas != right_areas:
		return left_areas > right_areas
	var left_muscle := String(a.get("primary_muscle", ""))
	var right_muscle := String(b.get("primary_muscle", ""))
	if left_muscle != right_muscle:
		return left_muscle < right_muscle
	return String(a.get("id", "")) < String(b.get("id", ""))


static func _area_count(record: Dictionary) -> int:
	var areas: Variant = record.get("areas", [])
	if areas is Array or areas is PackedStringArray:
		return (areas as Variant).size()
	return 0


static func _compare_by_id(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("id", "")) < String(b.get("id", ""))


## `a, b, c` for a list of area/equipment keys, `(none)` when empty (R4).
static func _list_text(values: Variant) -> String:
	var items := PackedStringArray()
	if values is Array or values is PackedStringArray:
		for value in values:
			var text := String(value)
			if not text.is_empty():
				items.append(text)
	if items.is_empty():
		return NONE_TEXT
	return ", ".join(items)
