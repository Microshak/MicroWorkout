class_name PlanValidator
extends RefCounted
## PRD-07 R5 — the one gate a model's reply must pass before it can become a plan.
##
## [b]Contract.[/b] [method validate] parses the raw reply itself (tolerating a ```json fence and
## trailing prose), checks every field against the appendix §5.2/§7.3 schema, repairs what can be
## repaired, drops what cannot, and reports machine-readable errors and warnings. It never
## throws, never logs a key and never touches the network, the filesystem or the scene tree, so a
## provider reply can be replayed through it from a suite.
##
## [b]Errors vs warnings.[/b] `ok == true` requires `errors.is_empty()`. Dropping an exercise the
## catalog does not know is **not** an error — a plan may validate with dropped blocks (R5) — so
## the ladder only falls back when a *rule* was broken, not when the model invented an id.
##
## [b]Where this deviates from R5's prose, and why:[/b]
##   * `warmup`/`cooldown` are accepted with 1–3 items and truncated to 2 above 3. R5 says
##     "exactly 2", but the appendix §5.2 types both as lists with no count and its own validator
##     (`PlanModel.validate`) requires only a non-empty `warmup`; a two-item rule would fail a
##     whole plan over a cosmetic count while the closed warning set has no code for it. The
##     *prompt* still asks for exactly two (R4).
##   * `sets`/`rest_seconds`/`est_minutes`/`duration_sec` out of range are **clamped** with
##     `W_CLAMPED` rather than rejected, exactly as R5 says; a missing or non-numeric one is the
##     error (`E_MISSING_FIELD`, `E_BAD_SETS`, `E_BAD_REST`, `E_BAD_DURATION`, `E_WRONG_TYPE`).
##   * the adjacency repair rotates a conflicting block towards the end of the session instead of
##     swapping it with the immediately next block: one rotation provably removes the conflict at
##     that position, the loop then looks again, and `E_ADJACENT_MUSCLE` is reported only when no
##     rotation helps (a session whose blocks share one muscle).
##   * `est_minutes` tolerance is [constant EST_MINUTES_TOL] = 0.15 (appendix R39), not R5's 25 %.
##
## [b]Which catalog?[/b] The one that was embedded in the prompt (the ALLOWED EXERCISES list), so
## "unknown id" means "not offered to the model". The ladder passes the same array to
## [PlanPrompt.user_prompt] and to this function, which is what makes `dropped` meaningful.

## PRD-00 §5.2 / appendix §6.4.
const MAX_BLOCKS_PER_SESSION: int = 12
const SETS_MIN: int = 1
const SETS_MAX: int = 8
const REST_MIN: int = 15
const REST_MAX: int = 300
const DURATION_SEC_MIN: int = 20
const DURATION_SEC_MAX: int = 180
const TITLE_MAX_CHARS: int = 60

## Appendix R39 — one tolerance for both the generator and the LLM path.
const EST_MINUTES_TOL: float = 0.15

## R5's fuzzy resolution.
const FUZZY_THRESHOLD: float = 0.82
## Two candidates whose scores differ by less than this are a tie, and a tie drops the block.
const FUZZY_TIE_EPSILON: float = 0.001

## R4's mobility shape: the prompt asks for exactly two items per list; a reply with one or three
## is accepted (see the file header) and anything longer is truncated to two.
const MOBILITY_TARGET: int = 2
const MOBILITY_MAX_ACCEPTED: int = 3

## Error messages are clipped so one hostile reply cannot flood the repair prompt.
const MESSAGE_MAX: int = 200

## The closed error vocabulary (R5).
const ERROR_CODES: PackedStringArray = [
	"E_NOT_JSON", "E_ROOT_TYPE", "E_MISSING_FIELD", "E_WRONG_TYPE", "E_UNKNOWN_EXERCISE",
	"E_DUPLICATE_EXERCISE", "E_BAD_SETS", "E_BAD_REPS", "E_BAD_REST", "E_BAD_DURATION",
	"E_BAD_AREA", "E_SESSION_COUNT", "E_SESSION_INDEX", "E_NO_BLOCKS", "E_TOO_MANY_BLOCKS",
	"E_ADJACENT_MUSCLE", "E_NO_WARMUP", "E_BAD_STRETCH",
]

## The closed warning vocabulary (R5).
const WARNING_CODES: PackedStringArray = [
	"W_DROPPED_EXERCISE", "W_FUZZY_RESOLVED", "W_CLAMPED", "W_LOW_VOLUME", "W_NAME_MISMATCH",
]


# ===========================================================================
# R5 — validate()
# ===========================================================================

## Validate [param raw_text] against [param catalog] (the ALLOWED EXERCISES list) for the request
## [param input] (the wizard's own keys, which are authoritative for the plan's identity).
##
## Returns:
##     {"ok": bool, "plan": Dictionary, "errors": Array[Dictionary],
##      "warnings": Array[String], "dropped": PackedStringArray,
##      "repaired": PackedStringArray, "stats": {"blocks": int, "sets_per_area": Dictionary}}
static func validate(raw_text: String, catalog: Array[Dictionary],
		input: Dictionary) -> Dictionary:
	var result := empty_result()
	var sliced := slice_object(raw_text)
	if sliced.is_empty():
		add_error(result, "E_NOT_JSON", "root", "the reply contained no JSON object",
			clip(raw_text), "one JSON object")
		return result
	var parsed: Variant = JSON.parse_string(sliced)
	if not (parsed is Dictionary):
		add_error(result, "E_ROOT_TYPE", "root", "the reply was not a JSON object",
			type_name(parsed), "one JSON object")
		return result

	var root: Dictionary = parsed
	var index := CatalogIndex.build(catalog)
	var request := Request.resolve(input)

	var sessions_in: Variant = root.get("sessions")
	if not root.has("sessions"):
		add_error(result, "E_MISSING_FIELD", "sessions", "the reply has no sessions array",
			"", "an array of sessions")
		return result
	if not (sessions_in is Array):
		add_error(result, "E_WRONG_TYPE", "sessions", "sessions must be an array",
			type_name(sessions_in), "an array of sessions")
		return result
	var session_list: Array = sessions_in
	if session_list.size() != request.days_per_week:
		add_error(result, "E_SESSION_COUNT", "sessions", "the reply has %d sessions but %d were requested"
				% [session_list.size(), request.days_per_week],
			str(session_list.size()), str(request.days_per_week))

	var identity := _identity(root, request, result)
	var sessions: Array = []
	var sets_per_area: Dictionary = {}
	var blocks_total := 0
	var position := 0
	# A reply cannot legally carry more sessions than days_per_week allows, but a hostile one can
	# carry hundreds, so the loop is bounded independently of the reply.
	while position < mini(session_list.size(), PlanModel.DAYS_PER_WEEK_MAX * 2):
		var path := "sessions[%d]" % position
		var entry: Variant = session_list[position]
		position += 1
		if not (entry is Dictionary):
			add_error(result, "E_WRONG_TYPE", path, "a session must be an object",
				type_name(entry), "an object")
			continue
		var session := _validate_session(entry, position - 1, path, request, index, result)
		var blocks: Array = session["blocks"]
		blocks_total += blocks.size()
		for block in blocks:
			var exercise_id := String((block as Dictionary)["exercise_id"])
			var record := index.record(exercise_id)
			var area := Taxonomy.primary_area(record)
			if not area.is_empty():
				sets_per_area[area] = int(sets_per_area.get(area, 0)) \
					+ int((block as Dictionary)["sets"])
		sessions.append(session)

	if sessions.is_empty():
		add_error(result, "E_SESSION_COUNT", "sessions", "no usable session was found",
			str(session_list.size()), str(request.days_per_week))
	_warn_low_volume(result, request, sets_per_area)

	result["ok"] = (result["errors"] as Array).is_empty()
	result["stats"] = {"blocks": blocks_total, "sets_per_area": sets_per_area}
	result["plan"] = _build_plan(identity, request, sessions)
	return result


## An empty result dictionary — also what a caller gets to inspect when [method validate] returns
## early, so every caller can read the same keys unconditionally.
static func empty_result() -> Dictionary:
	# `errors` is `Array[Dictionary]` and `warnings` is `Array[String]` — the R5 shapes, and the
	# types [PlanPrompt.repair_prompt] requires, so the error list can be handed straight to the
	# repair prompt without a copy or a cast.
	var errors: Array[Dictionary] = []
	var warnings: Array[String] = []
	return {
		"ok": false,
		"plan": {},
		"errors": errors,
		"warnings": warnings,
		"dropped": PackedStringArray(),
		"repaired": PackedStringArray(),
		"stats": {"blocks": 0, "sets_per_area": {}},
	}


## The plan document, in exactly the appendix §5.2 key order. Unknown keys the model invented are
## never echoed (R5). `source` is `"llm"` because a validated reply can only have come from one;
## the ladder sets it again and owns `generation`.
static func _build_plan(identity: Dictionary, request: Request, sessions: Array) -> Dictionary:
	return {
		"id": String(identity["id"]),
		"name": String(identity["name"]),
		"created_at": String(identity["created_at"]),
		"source": "llm",
		"provider": String(identity["provider"]),
		"goal": request.goal,
		"days_per_week": request.days_per_week,
		"duration_min": request.duration_min,
		"areas": request.areas.duplicate(),
		"equipment": request.equipment.duplicate(),
		"notes": request.notes,
		"split_name": String(identity["split_name"]),
		"sessions": sessions,
	}


# ------------------------------------------------------------------ identity fields

## The plan's identity: everything the *request* pins (goal, days, duration, areas, equipment,
## notes) is taken from the request, and everything the model may name (`name`, `split_name`) is
## taken from the reply when it is usable. A disagreement is a warning, never a failure — the
## stored plan still says what the user asked for.
static func _identity(root: Dictionary, request: Request, result: Dictionary) -> Dictionary:
	var split_name := PlanModel.as_text(root.get("split_name"), "").strip_edges()
	if split_name.is_empty() or split_name.length() > TITLE_MAX_CHARS:
		if not split_name.is_empty() or root.has("split_name"):
			add_warning(result, "W_NAME_MISMATCH",
				"split_name was unusable, so the request's split name was used")
		split_name = canonical_split_name(request.days_per_week, request.areas.size())
	var plan_name := PlanModel.as_text(root.get("name"), "").strip_edges()
	if plan_name.is_empty():
		add_warning(result, "W_NAME_MISMATCH", "name was missing, so it was derived")
		plan_name = "%d-Day %s" % [request.days_per_week, split_name]
	elif plan_name.length() > TITLE_MAX_CHARS:
		plan_name = plan_name.substr(0, TITLE_MAX_CHARS)
		add_warning(result, "W_CLAMPED",
			"name was longer than %d characters" % TITLE_MAX_CHARS)

	if root.has("goal") and PlanModel.as_text(root.get("goal"), "") != request.goal:
		add_warning(result, "W_NAME_MISMATCH", "goal disagreed with the request, so the request won")
	if root.has("days_per_week") \
			and PlanModel.as_int(root.get("days_per_week"), -1) != request.days_per_week:
		add_warning(result, "W_NAME_MISMATCH",
			"days_per_week disagreed with the request, so the request won")
	if root.has("duration_min") \
			and PlanModel.as_int(root.get("duration_min"), -1) != request.duration_min:
		add_warning(result, "W_NAME_MISMATCH",
			"duration_min disagreed with the request, so the request won")
	if root.has("areas") and not _same_list(root["areas"], request.areas):
		add_warning(result, "W_NAME_MISMATCH", "areas disagreed with the request, so the request won")
	if root.has("equipment") and not _same_list(root["equipment"], request.equipment):
		add_warning(result, "W_NAME_MISMATCH",
			"equipment disagreed with the request, so the request won")

	return {
		"id": PlanModel.as_text(request.raw.get("id"),
			"plan-%d" % int(Time.get_unix_time_from_system())),
		"created_at": PlanModel.as_text(request.raw.get("created_at"), Dates.now_iso8601(true)),
		"provider": PlanModel.as_text(request.raw.get("provider"), ""),
		"name": plan_name,
		"split_name": split_name,
	}


static func _same_list(value: Variant, wanted: PackedStringArray) -> bool:
	if not (value is Array or value is PackedStringArray):
		return false
	if value.size() != wanted.size():
		return false
	for entry in value:
		if not wanted.has(String(entry)):
			return false
	return true


# ------------------------------------------------------------------ one session

static func _validate_session(entry: Dictionary, index_in_plan: int, path: String,
		request: Request, index: CatalogIndex, result: Dictionary) -> Dictionary:
	if not entry.has("index"):
		add_error(result, "E_MISSING_FIELD", "%s.index" % path, "the session has no index",
			"", str(index_in_plan))
	else:
		var declared := PlanModel.as_int(entry.get("index"), -1)
		if declared != index_in_plan:
			add_error(result, "E_SESSION_INDEX", "%s.index" % path,
				"index must be %d at this position" % index_in_plan, str(declared),
				str(index_in_plan))

	var title := PlanModel.as_text(entry.get("title"), "").strip_edges()
	if title.is_empty():
		add_error(result, "E_MISSING_FIELD", "%s.title" % path, "the session has no title",
			"", "a short title")
	elif title.length() > TITLE_MAX_CHARS:
		title = title.substr(0, TITLE_MAX_CHARS)
		add_warning(result, "W_CLAMPED",
			"%s.title was longer than %d characters" % [path, TITLE_MAX_CHARS])

	# One duplicate-detection set per session: appendix V18 counts warm-up ∪ blocks ∪ cooldown.
	var seen_ids: Dictionary = {}
	var focus := _validate_focus(entry, path, result)
	var warmup := _validate_mobility(entry, "warmup", path, index, seen_ids, result)
	var cooldown := _validate_mobility(entry, "cooldown", path, index, seen_ids, result)
	var blocks := _validate_blocks(entry, path, index, seen_ids, result)
	if blocks.is_empty():
		add_error(result, "E_NO_BLOCKS", "%s.blocks" % path,
			"the session has no usable working blocks", "0", "at least 1")

	return {
		"id": "s%d" % (index_in_plan + 1),
		"index": index_in_plan,
		"title": title,
		"focus": focus,
		"est_minutes": _validate_est_minutes(entry, path, request.duration_min, blocks, warmup,
			cooldown, result),
		"warmup": warmup,
		"blocks": blocks,
		"cooldown": cooldown,
	}


static func _validate_focus(entry: Dictionary, path: String, result: Dictionary) -> Array:
	if not entry.has("focus"):
		add_error(result, "E_MISSING_FIELD", "%s.focus" % path, "the session has no focus list",
			"", "one or more area keys")
		return []
	var raw: Variant = entry["focus"]
	if not (raw is Array or raw is PackedStringArray):
		add_error(result, "E_WRONG_TYPE", "%s.focus" % path, "focus must be an array",
			type_name(raw), "an array of area keys")
		return []
	var out: Array = []
	for value in raw:
		var area := String(value)
		if not Taxonomy.is_user_area(area):
			add_error(result, "E_BAD_AREA", "%s.focus" % path,
				"'%s' is not one of the seven areas" % area, area, "an area key")
			continue
		if not out.has(area):
			out.append(area)
	if out.is_empty():
		add_error(result, "E_BAD_AREA", "%s.focus" % path, "focus must name at least one area",
			"[]", "an area key")
	return out


## `warmup`/`cooldown`: a bounded list of mobility items whose exercise must be a library stretch
## (R5). A missing or empty list is `E_NO_WARMUP` — the closed code set has no `E_NO_COOLDOWN`,
## so the cooldown uses the same code with its own path.
static func _validate_mobility(entry: Dictionary, field: String, path: String, index: CatalogIndex,
		seen_ids: Dictionary, result: Dictionary) -> Array:
	var item_path := "%s.%s" % [path, field]
	if not entry.has(field):
		add_error(result, "E_NO_WARMUP", item_path, "the session has no %s list" % field,
			"", "%d stretch items" % MOBILITY_TARGET)
		return []
	var raw: Variant = entry[field]
	if not (raw is Array):
		add_error(result, "E_WRONG_TYPE", item_path, "%s must be an array" % field,
			type_name(raw), "an array of mobility items")
		return []
	var items: Array = raw
	if items.is_empty():
		add_error(result, "E_NO_WARMUP", item_path, "the %s list is empty" % field,
			"[]", "%d stretch items" % MOBILITY_TARGET)
		return []
	if items.size() > MOBILITY_MAX_ACCEPTED:
		items = items.slice(0, MOBILITY_TARGET)
		add_warning(result, "W_CLAMPED",
			"%s was longer than %d items" % [item_path, MOBILITY_MAX_ACCEPTED])
	var out: Array = []
	for position in items.size():
		var one_path := "%s[%d]" % [item_path, position]
		var value: Variant = items[position]
		if not (value is Dictionary):
			add_error(result, "E_WRONG_TYPE", one_path, "a mobility item must be an object",
				type_name(value), "an object")
			continue
		var item: Dictionary = value
		if not item.has("exercise_id"):
			add_error(result, "E_MISSING_FIELD", "%s.exercise_id" % one_path,
				"the item has no exercise_id", "", "a stretch id")
			continue
		var resolved := resolve_id(PlanModel.as_text(item.get("exercise_id"), ""), index,
			result, "%s.exercise_id" % one_path)
		if resolved.is_empty():
			continue
		if not index.is_stretch(resolved):
			add_error(result, "E_BAD_STRETCH", "%s.exercise_id" % one_path,
				"'%s' is not a stretch" % resolved, resolved, "a record with is_stretch")
			continue
		if seen_ids.has(resolved):
			add_error(result, "E_DUPLICATE_EXERCISE", "%s.exercise_id" % one_path,
				"'%s' is already used in this session" % resolved, resolved, "a new exercise")
			continue
		seen_ids[resolved] = true
		out.append({
			"exercise_id": resolved,
			"duration_sec": _mobility_duration(item, one_path, result),
		})
	return out


static func _mobility_duration(item: Dictionary, one_path: String, result: Dictionary) -> int:
	if not item.has("duration_sec"):
		add_error(result, "E_MISSING_FIELD", "%s.duration_sec" % one_path,
			"the item has no duration_sec", "", "seconds, %d to %d"
				% [DURATION_SEC_MIN, DURATION_SEC_MAX])
		return Generator.MOBILITY_ITEM_SEC
	var raw: Variant = item["duration_sec"]
	if not (raw is int or raw is float):
		add_error(result, "E_BAD_DURATION", "%s.duration_sec" % one_path,
			"duration_sec must be a whole number of seconds", clip(str(raw)), "20 to 180")
		return Generator.MOBILITY_ITEM_SEC
	var value := PlanModel.as_int(raw, Generator.MOBILITY_ITEM_SEC)
	var clamped := clampi(value, DURATION_SEC_MIN, DURATION_SEC_MAX)
	if clamped != value:
		add_warning(result, "W_CLAMPED",
			"%s.duration_sec was clamped from %d to %d" % [one_path, value, clamped])
	return clamped


static func _validate_blocks(entry: Dictionary, path: String, index: CatalogIndex,
		seen_ids: Dictionary, result: Dictionary) -> Array:
	var block_path := "%s.blocks" % path
	if not entry.has("blocks"):
		add_error(result, "E_MISSING_FIELD", block_path, "the session has no blocks",
			"", "1 to %d blocks" % MAX_BLOCKS_PER_SESSION)
		return []
	var raw: Variant = entry["blocks"]
	if not (raw is Array):
		add_error(result, "E_WRONG_TYPE", block_path, "blocks must be an array",
			type_name(raw), "an array of blocks")
		return []
	var blocks: Array = raw
	if blocks.size() > MAX_BLOCKS_PER_SESSION:
		add_error(result, "E_TOO_MANY_BLOCKS", block_path,
			"a session may hold at most %d blocks" % MAX_BLOCKS_PER_SESSION,
			str(blocks.size()), str(MAX_BLOCKS_PER_SESSION))
		return []
	var out: Array = []
	for position in blocks.size():
		var one_path := "%s[%d]" % [block_path, position]
		var value: Variant = blocks[position]
		if not (value is Dictionary):
			add_error(result, "E_WRONG_TYPE", one_path, "a block must be an object",
				type_name(value), "an object")
			continue
		var block: Dictionary = value
		if not block.has("exercise_id"):
			add_error(result, "E_MISSING_FIELD", "%s.exercise_id" % one_path,
				"the block has no exercise_id", "", "an id from ALLOWED EXERCISES")
			continue
		var resolved := resolve_id(PlanModel.as_text(block.get("exercise_id"), ""), index,
			result, "%s.exercise_id" % one_path)
		if resolved.is_empty():
			continue
		if index.is_stretch(resolved):
			add_error(result, "E_BAD_STRETCH", "%s.exercise_id" % one_path,
				"'%s' is a stretch and cannot be a working block" % resolved, resolved,
				"a non-stretch record")
			continue
		if seen_ids.has(resolved):
			add_error(result, "E_DUPLICATE_EXERCISE", "%s.exercise_id" % one_path,
				"'%s' is already used in this session" % resolved, resolved, "a new exercise")
			continue
		seen_ids[resolved] = true

		var sets := _int_field(block, "sets", one_path, "E_BAD_SETS", result)
		var clamped_sets := clampi(sets, SETS_MIN, SETS_MAX)
		if clamped_sets != sets:
			add_warning(result, "W_CLAMPED",
				"%s.sets was clamped from %d to %d" % [one_path, sets, clamped_sets])
			sets = clamped_sets

		var reps := ""
		if not block.has("reps"):
			add_error(result, "E_MISSING_FIELD", "%s.reps" % one_path, "the block has no reps",
				"", "e.g. \"8-10\"")
		else:
			var raw_reps := PlanModel.as_text(block.get("reps"), "")
			reps = normalize_reps(raw_reps)
			if not PlanModel.is_valid_reps(reps):
				add_error(result, "E_BAD_REPS", "%s.reps" % one_path,
					"'%s' is not a rep range" % raw_reps, clip(raw_reps), "e.g. \"8-10\"")

		var rest := _int_field(block, "rest_seconds", one_path, "E_BAD_REST", result)
		var clamped_rest := clampi(rest, REST_MIN, REST_MAX)
		if clamped_rest != rest:
			add_warning(result, "W_CLAMPED",
				"%s.rest_seconds was clamped from %d to %d" % [one_path, rest, clamped_rest])
			rest = clamped_rest

		out.append({
			"exercise_id": resolved,
			"sets": sets,
			"reps": reps,
			"rest_seconds": rest,
		})
	_break_adjacency(out, block_path, index, result)
	return out


## R5's anti-adjacency rule as a bounded rotation: a block that shares its `primary_muscle` with
## the one before it is moved to the end of the session and the rest shift up. A rotation that
## does not reduce the number of conflicts is undone and the loop stops, so a session whose
## blocks all train one muscle reports `E_ADJACENT_MUSCLE` instead of shuffling forever.
static func _break_adjacency(blocks: Array, path: String, index: CatalogIndex,
		result: Dictionary) -> void:
	var repairs := 0
	while true:
		var conflicts := _adjacent_conflicts(blocks, index)
		if conflicts.is_empty():
			break
		var before := conflicts.size()
		var offender: int = conflicts[0]
		var moved: Variant = blocks[offender]
		blocks.remove_at(offender)
		blocks.append(moved)
		if _adjacent_conflicts(blocks, index).size() >= before:
			blocks.remove_at(blocks.size() - 1)
			blocks.insert(offender, moved)
			break
		repairs += 1
	if repairs > 0:
		add_warning(result, "W_CLAMPED",
			"%s was reordered to break %d adjacency conflict(s)" % [path, repairs])
	for position in _adjacent_conflicts(blocks, index):
		var muscle := index.primary_muscle(String((blocks[int(position)] as Dictionary)["exercise_id"]))
		add_error(result, "E_ADJACENT_MUSCLE", "%s[%d]" % [path, int(position)],
			"two consecutive blocks share primary_muscle '%s'" % muscle, muscle,
			"a different muscle")


## The index of every block whose `primary_muscle` equals its predecessor's, left to right.
static func _adjacent_conflicts(blocks: Array, index: CatalogIndex) -> Array:
	var out: Array = []
	for position in range(1, blocks.size()):
		var previous := String((blocks[position - 1] as Dictionary)["exercise_id"])
		var current := String((blocks[position] as Dictionary)["exercise_id"])
		var muscle := index.primary_muscle(current)
		if not muscle.is_empty() and muscle == index.primary_muscle(previous):
			out.append(position)
	return out


## `est_minutes` inside ±15 % of the requested duration; outside it is recomputed from the §7.1
## set math and a `W_CLAMPED` is recorded (R5 / appendix R39).
static func _validate_est_minutes(entry: Dictionary, path: String, duration_min: int,
		blocks: Array, warmup: Array, cooldown: Array, result: Dictionary) -> int:
	var computed := estimate_minutes(blocks, warmup, cooldown)
	if not entry.has("est_minutes"):
		add_error(result, "E_MISSING_FIELD", "%s.est_minutes" % path,
			"the session has no est_minutes", "", "minutes near the requested duration")
		return computed
	var raw: Variant = entry["est_minutes"]
	if not (raw is int or raw is float):
		add_error(result, "E_WRONG_TYPE", "%s.est_minutes" % path,
			"est_minutes must be a whole number", type_name(raw), "minutes")
		return computed
	var value := PlanModel.as_int(raw, computed)
	if duration_min > 0 and not _within_tolerance(value, duration_min):
		add_warning(result, "W_CLAMPED",
			"%s.est_minutes was recomputed from %d to %d" % [path, value, computed])
		return computed
	return value


static func _within_tolerance(estimate: int, requested: int) -> bool:
	if requested <= 0:
		return true
	return absf(float(estimate) - float(requested)) / float(requested) <= EST_MINUTES_TOL


## PRD-05 R8's arithmetic, expressed on a finished session dictionary: `reps_used × REP_SEC +
## TRANSITION_SEC + rest` per set, plus one `MOBILITY_ITEM_SEC` per mobility item.
static func estimate_minutes(blocks: Array, warmup: Array, cooldown: Array) -> int:
	var total := (warmup.size() + cooldown.size()) * Generator.MOBILITY_ITEM_SEC
	for block in blocks:
		var entry: Dictionary = block
		total += PlanModel.as_int(entry.get("sets"), 0) \
			* (reps_used(PlanModel.as_text(entry.get("reps"), "")) * Generator.REP_SEC
				+ Generator.TRANSITION_SEC + PlanModel.as_int(entry.get("rest_seconds"), 0))
	return maxi(1, roundi(float(total) / 60.0))


## The top of a rep range, or the seconds value of an `"Ns"` block (PRD-05 R8).
static func reps_used(reps: String) -> int:
	if reps.ends_with("s"):
		return maxi(1, reps.substr(0, reps.length() - 1).to_int())
	if reps.contains("-"):
		var parts := reps.split("-", false)
		if parts.size() == 2:
			return maxi(1, parts[1].to_int())
	return maxi(1, reps.to_int())


## `"8 - 10"` and `"8–10"` become `"8-10"` before validation, so a typographic dash or a stray
## space is not a reason to throw a plan away.
static func normalize_reps(reps: String) -> String:
	return reps.strip_edges().replace(" ", "").replace("–", "-").replace("—", "-")


# ------------------------------------------------------------------ R5's resolution ladder

## id -> id, in R5's four steps, recording `dropped` / `repaired` / warnings on [param result]:
## 1. exact id match; 2. normalized id match; 3. fuzzy name/id match at
## [constant FUZZY_THRESHOLD] with a unique winner; 4. dropped.
static func resolve_id(raw_id: String, index: CatalogIndex, result: Dictionary,
		path: String) -> String:
	var candidate := raw_id.strip_edges()
	if candidate.is_empty():
		add_error(result, "E_UNKNOWN_EXERCISE", path, "an empty exercise_id was given",
			"", "an id from ALLOWED EXERCISES")
		return ""
	if index.has(candidate):
		return candidate

	var normalized := normalize_id(candidate)
	for position in index.norm_ids.size():
		if index.norm_ids[position] == normalized:
			var matched := index.ids[position]
			add_repaired(result, matched)
			add_warning(result, "W_FUZZY_RESOLVED",
				"'%s' resolved to the id '%s'" % [candidate, matched])
			return matched

	var normalized_text := normalize_text(candidate)
	var best_score := 0.0
	var best_id := ""
	var tied := false
	for position in index.ids.size():
		var score := maxf(normalized_text.similarity(index.norm_names[position]),
			normalized_text.similarity(index.norm_ids[position]))
		if score < FUZZY_THRESHOLD:
			continue
		if score > best_score + FUZZY_TIE_EPSILON:
			best_score = score
			best_id = index.ids[position]
			tied = false
		elif score >= best_score - FUZZY_TIE_EPSILON and index.ids[position] != best_id:
			tied = true
	if not best_id.is_empty() and not tied:
		add_repaired(result, best_id)
		add_warning(result, "W_FUZZY_RESOLVED",
			"'%s' resolved to '%s'" % [candidate, best_id])
		return best_id

	add_dropped(result, candidate)
	if tied:
		add_warning(result, "W_DROPPED_EXERCISE",
			"'%s' matched more than one exercise equally well, so it was dropped" % candidate)
	else:
		add_warning(result, "W_DROPPED_EXERCISE",
			"'%s' is not in ALLOWED EXERCISES" % candidate)
	return ""


## R5's parse tolerance: the object between the first `{` and the last `}`. A leading ```json
## fence, a trailing "here is your plan", or both, are irrelevant to a JSON object.
static func slice_object(text: String) -> String:
	var start := text.find("{")
	if start < 0:
		return ""
	var end := text.rfind("}")
	if end <= start:
		return ""
	return text.substr(start, end - start + 1)


## R5 step 2: lowercase, every non-alphanumeric except `-` to a space, spaces collapsed, a
## trailing plural `s` singularized. The id form keeps its hyphens, which is what lets a
## *name*-shaped candidate (`"Bench  Press"`) fall through to the fuzzy step and be reported as
## `W_FUZZY_RESOLVED` rather than silently accepted.
static func normalize_id(text: String) -> String:
	return _normalize(text, true)


## The same normalisation minus the hyphen exception: what a *name* collapses to.
static func normalize_text(text: String) -> String:
	return _normalize(text, false)


static func _normalize(text: String, keep_hyphen: bool) -> String:
	var lowered := text.to_lower()
	var out := ""
	for position in lowered.length():
		var character := lowered[position]
		var code := character.unicode_at(0)
		var is_alnum := (code >= 97 and code <= 122) or (code >= 48 and code <= 57)
		out += character if (is_alnum or (keep_hyphen and character == "-")) else " "
	while out.contains("  "):
		out = out.replace("  ", " ")
	return _singularize(out.strip_edges())


## Drops one trailing plural `s`, but never from a word ending in `ss` (`press` stays `press`)
## and never from a word of three characters or fewer (`abs` stays `abs`).
static func _singularize(text: String) -> String:
	if text.length() <= 3 or not text.ends_with("s") or text.ends_with("ss"):
		return text
	return text.substr(0, text.length() - 1)


# ------------------------------------------------------------------ volume reporting

## `W_LOW_VOLUME` per requested area whose direct weekly sets fall short of the appendix §6.4
## floor. A warning, never an error: the weekly budget is the generator's contract, and an LLM
## that under-prescribes is still a usable week.
static func _warn_low_volume(result: Dictionary, request: Request,
		sets_per_area: Dictionary) -> void:
	var area_count := maxi(1, request.areas.size())
	var available := maxi(0, request.duration_min * 60 - Generator.RESERVE_SEC)
	var target := clampi(roundi(float(available) / float(Generator.AVG_SET_CYCLE_SEC)),
		Generator.TARGET_SETS_MIN, Generator.TARGET_SETS_MAX)
	var floor_sets := mini(Generator.WEEKLY_MIN_SETS,
		floori(float(request.days_per_week * target) / float(area_count)))
	for area in request.areas:
		var direct := int(sets_per_area.get(area, 0))
		if direct < floor_sets:
			add_warning(result, "W_LOW_VOLUME",
				"%s got %d direct weekly sets, under the %d-set floor"
					% [area, direct, floor_sets])


# ------------------------------------------------------------------ request projection

## The request, projected once per [method validate] call. `input` is never mutated, and the five
## wizard keys are clamped into the appendix's ranges so a hostile caller cannot produce a plan
## the store would reject.
class Request extends RefCounted:
	var goal: String = ""
	var days_per_week: int = 0
	var duration_min: int = 0
	var areas: PackedStringArray = PackedStringArray()
	var equipment: PackedStringArray = PackedStringArray()
	var notes: String = ""
	var raw: Dictionary = {}

	static func resolve(input: Dictionary) -> Request:
		var request := Request.new()
		request.raw = input
		request.goal = String(input.get("goal", Generator.DEFAULT_GOAL))
		if not PlanModel.GOALS.has(request.goal):
			request.goal = Generator.DEFAULT_GOAL
		request.days_per_week = clampi(PlanModel.as_int(input.get("days_per_week"),
			Generator.DEFAULT_DAYS), PlanModel.DAYS_PER_WEEK_MIN, PlanModel.DAYS_PER_WEEK_MAX)
		request.duration_min = clampi(PlanModel.as_int(input.get("duration_min"),
			Generator.DEFAULT_DURATION_MIN), PlanModel.DURATION_MIN_MIN,
			PlanModel.DURATION_MIN_MAX)
		request.areas = string_array(input.get("areas", []))
		request.equipment = string_array(input.get("equipment", []))
		request.notes = String(input.get("notes", ""))
		return request

	static func string_array(value: Variant) -> PackedStringArray:
		var out := PackedStringArray()
		if value is Array or value is PackedStringArray:
			for entry in value:
				out.append(String(entry))
		return out


# ------------------------------------------------------------------ the catalog index

## `id -> record` plus the normalized name/id tables [method resolve_id] searches. Built once per
## [method validate] call so a four-session plan does not rebuild it forty times.
class CatalogIndex extends RefCounted:
	var by_id: Dictionary = {}
	var ids: PackedStringArray = PackedStringArray()
	var norm_ids: PackedStringArray = PackedStringArray()
	var norm_names: PackedStringArray = PackedStringArray()

	static func build(catalog: Array[Dictionary]) -> CatalogIndex:
		var index := CatalogIndex.new()
		var sorted_ids: Array = []
		for record in catalog:
			var id := String(record.get("id", ""))
			if id.is_empty() or index.by_id.has(id):
				continue
			index.by_id[id] = record
			sorted_ids.append(id)
		# Sorted so the fuzzy tie-break (and therefore the prompt's `repaired` list) is
		# deterministic whatever order the catalog arrived in.
		sorted_ids.sort()
		for entry in sorted_ids:
			var id := String(entry)
			index.ids.append(id)
			index.norm_ids.append(PlanValidator.normalize_id(id))
			index.norm_names.append(PlanValidator.normalize_text(
				String((index.by_id[id] as Dictionary).get("name", ""))))
		return index

	func has(id: String) -> bool:
		return by_id.has(id)

	func record(id: String) -> Dictionary:
		return by_id.get(id, {})

	func is_stretch(id: String) -> bool:
		return bool(record(id).get("is_stretch", false))

	func primary_muscle(id: String) -> String:
		return String(record(id).get("primary_muscle", ""))


# ------------------------------------------------------------------ shared helpers

static func add_error(result: Dictionary, code: String, path: String, message: String,
		got: String, expected: String) -> void:
	var errors: Array[Dictionary] = result["errors"]
	errors.append({
		"code": code,
		"path": path,
		"message": clip(message),
		"got": clip(got),
		"expected": clip(expected),
		"severity": "error",
	})


## One warning entry, rendered as `CODE: message` so a log line or a `plan.generation` field can
## carry it without a second structure. Only the closed [constant WARNING_CODES] are ever used.
static func add_warning(result: Dictionary, code: String, message: String) -> void:
	var warnings: Array[String] = result["warnings"]
	if message.is_empty():
		warnings.append(code)
		return
	warnings.append("%s: %s" % [code, clip(message)])


static func add_dropped(result: Dictionary, exercise_id: String) -> void:
	var dropped: PackedStringArray = result["dropped"]
	if not dropped.has(exercise_id):
		dropped.append(exercise_id)
		result["dropped"] = dropped


static func add_repaired(result: Dictionary, exercise_id: String) -> void:
	var repaired: PackedStringArray = result["repaired"]
	if not repaired.has(exercise_id):
		repaired.append(exercise_id)
		result["repaired"] = repaired


## One whole-number field with a code of its own. A missing key is `E_MISSING_FIELD`; anything
## that is not a whole number is the field's own error code; either way the caller gets a value it
## can clamp, so validation continues instead of aborting on the first typo.
static func _int_field(container: Dictionary, field: String, path: String, code: String,
		result: Dictionary) -> int:
	if not container.has(field):
		add_error(result, "E_MISSING_FIELD", "%s.%s" % [path, field],
			"the field %s is missing" % field, "", "a whole number")
		return 0
	var raw: Variant = container[field]
	if not (raw is int or raw is float):
		add_error(result, code, "%s.%s" % [path, field],
			"%s must be a whole number" % field, clip(type_name(raw)), "a whole number")
		return 0
	return PlanModel.as_int(raw, 0)


static func clip(text: String) -> String:
	if text.length() > MESSAGE_MAX:
		return text.substr(0, MESSAGE_MAX)
	return text


static func type_name(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "bool"
		TYPE_INT:
			return "int"
		TYPE_FLOAT:
			return "float"
		TYPE_STRING, TYPE_STRING_NAME:
			return "string"
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY:
			return "array"
		TYPE_DICTIONARY:
			return "object"
	return type_string(typeof(value))


# ------------------------------------------------------------------ canonical names

## R5's canonical split names (appendix §6.3). The generator resolves the same names from its own
## pool table; this copy exists only so a reply that omits `split_name` still gets a correct one
## without the validator depending on the generator's session planning.
static func canonical_split_name(days: int, area_count: int) -> String:
	match days:
		2:
			return "Full Body A / B"
		3:
			return "Full Body ×3" if area_count <= 3 else "Push / Pull / Legs"
		4:
			return "Upper / Lower"
		5:
			return "Push / Pull / Legs + Upper / Lower"
		6:
			return "Push / Pull / Legs ×2"
	return "Full Body"
