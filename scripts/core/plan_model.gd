class_name PlanModel
extends RefCounted
## PRD-05 R2/R3 — the typed plan model plus the single validator every plan passes.
##
## `Plan` / `Session` / `Block` / `MobilityItem` are plain [RefCounted] inner classes
## with typed fields; the module is node-free and scene-tree-free (PRD-TEMPLATE rule 4)
## and never touches `user://`. `to_dict()` emits **exactly** the PRD-00 §5.3 key set
## plus any unrecognised keys preserved in `extra` (§6 forward compatibility), so a plan
## written by a newer build round-trips byte-identically.
##
## `validate()` is the shared contract: the built-in generator, PRD-07's LLM output and
## PRD-08's wizard all call this one function. It never throws and never crashes on an
## unknown exercise id — it reports.
##
## Numbers read back from JSON are floats in Godot (`JSON.parse_string("3")` is `3.0`),
## so every numeric field is coerced through [method as_int] while loading, and
## `validate()` accepts a whole float wherever the schema says "int". Without that a
## plan round-tripped through `plans.json` would not compare equal to the one written.

## PRD-00 §5.3 — the exact key sets. No `_meta`, no debug keys.
const PLAN_KEYS: PackedStringArray = [
	"id", "name", "created_at", "source", "provider", "goal", "days_per_week",
	"duration_min", "areas", "equipment", "notes", "split_name", "sessions",
]
const SESSION_KEYS: PackedStringArray = [
	"id", "index", "title", "focus", "est_minutes", "warmup", "blocks", "cooldown",
]
const BLOCK_KEYS: PackedStringArray = ["exercise_id", "sets", "reps", "rest_seconds"]
const MOBILITY_KEYS: PackedStringArray = ["exercise_id", "duration_sec"]

## Appendix §6.2 — canonical stored goal keys. `"general"` is banned (appendix R32).
const GOALS: PackedStringArray = [
	"strength", "hypertrophy", "general_fitness", "conditioning",
]
## Appendix R31 — exactly these two; `"generator"` is banned.
const SOURCES: PackedStringArray = ["builtin", "llm"]
const SCHEMA_VERSION: int = 1

## Validator bounds (PRD-05 R3, V1–V22).
const DAYS_PER_WEEK_MIN: int = 1
const DAYS_PER_WEEK_MAX: int = 6
const DURATION_MIN_MIN: int = 10
const DURATION_MIN_MAX: int = 120
const BLOCKS_MIN: int = 1
const BLOCKS_MAX: int = 12
const SETS_MIN: int = 1
const SETS_MAX: int = 8
const REST_MIN: int = 15
const REST_MAX: int = 300
const EST_MINUTES_MIN: int = 1
const EST_MINUTES_MAX: int = 180
const DURATION_SEC_MIN: int = 20
const DURATION_SEC_MAX: int = 180
const TITLE_MAX_CHARS: int = 60

## Appendix R39 — the single tolerance shared by the generator and PRD-07.
const EST_MINUTES_TOL: float = 0.15

const LIBRARY_PATH: String = "res://data/exercise_library.json"

## Read-only catalog cache (`id` → library record). Populated once per process so the
## pure-logic layer can resolve exercise ids without the `Library` autoload, which does
## not exist under `--script` (see tests/framework.gd).
static var _catalog_cache: Dictionary = {}
static var _catalog_loaded: bool = false


# ---------------------------------------------------------------------------
# Catalog access
# ---------------------------------------------------------------------------

## `{id: record}` for the shipped 204-record catalog, or `{}` when it is unreadable.
static func load_catalog() -> Dictionary:
	if _catalog_loaded:
		return _catalog_cache
	_catalog_loaded = true
	_catalog_cache = catalog_from_document(_read_library_document())
	return _catalog_cache


## Accepts either a raw library document (`{"exercises": [...]}`) or an `{id: record}`
## map, so a caller may inject a catalog without knowing which shape it holds.
static func catalog_from_document(document: Dictionary) -> Dictionary:
	var map: Dictionary = {}
	if document.has("exercises"):
		for record in document.get("exercises", []):
			if record is Dictionary and not String(record.get("id", "")).is_empty():
				map[String(record.get("id", ""))] = record
		return map
	for key in document.keys():
		var value: Variant = document[key]
		if value is Dictionary and (value as Dictionary).has("primary_muscle"):
			map[String(key)] = value
	return map


## Test seam: forget the cached catalog so a suite can reload it.
static func reset_catalog_cache() -> void:
	_catalog_loaded = false
	_catalog_cache = {}


static func _read_library_document() -> Dictionary:
	if not FileAccess.file_exists(LIBRARY_PATH):
		return {}
	var text := FileAccess.get_file_as_string(LIBRARY_PATH)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


# ---------------------------------------------------------------------------
# Small typed helpers shared by the model and the validator
# ---------------------------------------------------------------------------

## Integer view of a JSON number: whole floats count as ints (Godot parses every JSON
## number as a float), everything else falls back.
static func as_int(value: Variant, fallback: int = 0) -> int:
	if value is int:
		return value
	if value is float:
		var number := float(value)
		if is_finite(number) and number == floorf(number):
			return int(number)
	return fallback


## Text view of a JSON value that is never a crash: Godot's `String()` constructor
## rejects Array/Dictionary arguments outright, and `validate()` must report a hostile
## plan rather than die on it (`{"source": []}` is a malformed plan, not an exception).
static func as_text(value: Variant, fallback: String = "") -> String:
	if value is String:
		return value
	if value is StringName:
		return String(value)
	if value is int or value is float or value is bool:
		return str(value)
	return fallback


static func _string_array(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array or value is PackedStringArray:
		for entry in value:
			out.append(String(entry))
	return out


static func _plain_array(values: PackedStringArray) -> Array:
	var out: Array = []
	for value in values:
		out.append(value)
	return out


static func _is_digits(text: String, lo: int, hi: int) -> bool:
	if text.length() < lo or text.length() > hi:
		return false
	for index in text.length():
		var code := text.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true


## PRD-00 §7.3 — `"8"` | `"8-10"` | `"45s"`.
static func is_valid_reps(reps: String) -> bool:
	if reps.ends_with("s"):
		var seconds := reps.substr(0, reps.length() - 1)
		if not _is_digits(seconds, 2, 3):
			return false
		var value := seconds.to_int()
		return value >= 10 and value <= 300
	if reps.contains("-"):
		var parts := reps.split("-", false)
		if parts.size() != 2:
			return false
		if not _is_digits(parts[0], 1, 2) or not _is_digits(parts[1], 1, 2):
			return false
		var low := parts[0].to_int()
		var high := parts[1].to_int()
		return low >= 1 and high <= 30 and low < high
	if not _is_digits(reps, 1, 2):
		return false
	var single := reps.to_int()
	return single >= 1 and single <= 30


## `^plan-\d{10}$` (PRD-00 §5.2).
static func is_plan_id(value: String) -> bool:
	if not value.begins_with("plan-"):
		return false
	return _is_digits(value.substr(5), 10, 10)


# ---------------------------------------------------------------------------
# Typed model
# ---------------------------------------------------------------------------

class Block extends RefCounted:
	var exercise_id: String = ""
	var sets: int = 0
	var reps: String = ""
	var rest_seconds: int = 0
	## Keys the §5.3 schema does not know about, preserved verbatim.
	var extra: Dictionary = {}

	func to_dict() -> Dictionary:
		var out: Dictionary = {
			"exercise_id": exercise_id,
			"sets": sets,
			"reps": reps,
			"rest_seconds": rest_seconds,
		}
		for key in extra.keys():
			out[key] = extra[key]
		return out


class MobilityItem extends RefCounted:
	var exercise_id: String = ""
	var duration_sec: int = 0
	var extra: Dictionary = {}

	func to_dict() -> Dictionary:
		var out: Dictionary = {"exercise_id": exercise_id, "duration_sec": duration_sec}
		for key in extra.keys():
			out[key] = extra[key]
		return out


class Session extends RefCounted:
	var id: String = ""
	var index: int = 0
	var title: String = ""
	var focus: PackedStringArray = PackedStringArray()
	var est_minutes: int = 0
	var warmup: Array[MobilityItem] = []
	var blocks: Array[Block] = []
	var cooldown: Array[MobilityItem] = []
	var extra: Dictionary = {}

	func to_dict() -> Dictionary:
		var out: Dictionary = {
			"id": id,
			"index": index,
			"title": title,
			"focus": PlanModel._plain_array(focus),
			"est_minutes": est_minutes,
			"warmup": PlanModel._mobility_dicts(warmup),
			"blocks": PlanModel._block_dicts(blocks),
			"cooldown": PlanModel._mobility_dicts(cooldown),
		}
		for key in extra.keys():
			out[key] = extra[key]
		return out

	## Warm-up + blocks + cooldown, in workout order (PRD-05 R2).
	func exercise_ids() -> PackedStringArray:
		var out := PackedStringArray()
		for item in warmup:
			out.append(item.exercise_id)
		for block in blocks:
			out.append(block.exercise_id)
		for item in cooldown:
			out.append(item.exercise_id)
		return out


class Plan extends RefCounted:
	var id: String = ""
	var name: String = ""
	var created_at: String = ""
	var source: String = "builtin"
	var provider: String = ""
	var goal: String = ""
	var days_per_week: int = 0
	var duration_min: int = 0
	var areas: PackedStringArray = PackedStringArray()
	var equipment: PackedStringArray = PackedStringArray()
	var notes: String = ""
	var split_name: String = ""
	var sessions: Array[Session] = []
	## PRD-00 §6 forward compatibility — unknown keys survive a load/save cycle.
	var extra: Dictionary = {}

	func to_dict() -> Dictionary:
		var out: Dictionary = {
			"id": id,
			"name": name,
			"created_at": created_at,
			"source": source,
			"provider": provider,
			"goal": goal,
			"days_per_week": days_per_week,
			"duration_min": duration_min,
			"areas": PlanModel._plain_array(areas),
			"equipment": PlanModel._plain_array(equipment),
			"notes": notes,
			"split_name": split_name,
			"sessions": session_dicts(),
		}
		for key in extra.keys():
			out[key] = extra[key]
		return out

	func session_dicts() -> Array:
		var out: Array = []
		for session in sessions:
			out.append(session.to_dict())
		return out

	func session_count() -> int:
		return sessions.size()

	func session_by_id(session_id: String) -> Session:
		for session in sessions:
			if session.id == session_id:
				return session
		return null

	## Warm-up + blocks + cooldown exercise ids for one session (PRD-05 R2).
	func exercise_ids_in_session(index: int) -> PackedStringArray:
		if index < 0 or index >= sessions.size():
			return PackedStringArray()
		return sessions[index].exercise_ids()

	# -----------------------------------------------------------------------
	# validate() — PRD-05 R3, V1…V22
	# -----------------------------------------------------------------------

	## Every defect becomes one human-readable `"<path>: <problem> (got <value>)"` string.
	## An empty array means the plan is valid. `catalog` defaults to the shipped library;
	## when it cannot be resolved at all, the id-dependent rules (V14/V21/V22) are skipped
	## rather than reported as failures.
	func validate(catalog: Dictionary = {}) -> Array[String]:
		var errors: Array[String] = []
		var resolved := catalog
		if resolved.is_empty():
			resolved = PlanModel.load_catalog()
		var have_catalog := not resolved.is_empty()

		# V1 — absent schema_version is fine; when present it must be 1.
		if extra.has("schema_version"):
			var version := PlanModel.as_int(extra.get("schema_version"), -1)
			if version != PlanModel.SCHEMA_VERSION:
				errors.append("schema_version: must be %d (got %d)"
					% [PlanModel.SCHEMA_VERSION, version])
		# V2
		if not PlanModel.is_plan_id(id):
			errors.append("id: must match plan-<10 digits> (got '%s')" % id)
		# V3
		if days_per_week < PlanModel.DAYS_PER_WEEK_MIN \
				or days_per_week > PlanModel.DAYS_PER_WEEK_MAX:
			errors.append("days_per_week: must be an int in %d..%d (got %d)"
				% [PlanModel.DAYS_PER_WEEK_MIN, PlanModel.DAYS_PER_WEEK_MAX, days_per_week])
		# V5 / V4
		if sessions.is_empty():
			errors.append("sessions: must have at least 1 session (got 0)")
		elif sessions.size() != days_per_week:
			errors.append(
				"sessions: count must equal days_per_week (got %d sessions for days_per_week=%d)"
				% [sessions.size(), days_per_week])
		# V6
		if duration_min < PlanModel.DURATION_MIN_MIN \
				or duration_min > PlanModel.DURATION_MIN_MAX:
			errors.append("duration_min: must be an int in %d..%d (got %d)"
				% [PlanModel.DURATION_MIN_MIN, PlanModel.DURATION_MIN_MAX, duration_min])
		# V7
		if not PlanModel.GOALS.has(goal):
			errors.append("goal: must be one of %s (got '%s')"
				% ["|".join(PlanModel.GOALS), goal])
		# V8
		if not PlanModel.SOURCES.has(source):
			errors.append("source: must be 'builtin' or 'llm' (got '%s')" % source)
		# V9
		errors.append_array(_validate_areas())
		# V10
		if equipment.is_empty():
			errors.append("equipment: must be non-empty (got [])")

		var seen_session_ids: Dictionary = {}
		for index in sessions.size():
			var session := sessions[index]
			var path := "sessions[%d]" % index
			if not session.id.is_empty():
				if seen_session_ids.has(session.id):
					errors.append("%s.id: duplicate session id '%s' (got '%s')"
						% [path, session.id, session.id])
				seen_session_ids[session.id] = true
			if session.focus.is_empty():
				errors.append("%s.focus: must name at least one area (got [])" % path)
			if session.title.length() > PlanModel.TITLE_MAX_CHARS:
				errors.append("%s.title: must be <= %d characters (got %d)"
					% [path, PlanModel.TITLE_MAX_CHARS, session.title.length()])
			errors.append_array(_validate_session_blocks(session, path, resolved, have_catalog))
			errors.append_array(_validate_session_mobility(session, path, resolved, have_catalog))
			errors.append_array(_validate_session_duplicates(session, path))
			# V19
			if session.est_minutes < PlanModel.EST_MINUTES_MIN \
					or session.est_minutes > PlanModel.EST_MINUTES_MAX:
				errors.append("%s: est_minutes out of range (got %d)"
					% [path, session.est_minutes])
			# V21
			errors.append_array(_validate_adjacency(session, path, resolved, have_catalog))
		return errors

	func _validate_areas() -> Array[String]:
		var errors: Array[String] = []
		if areas.is_empty():
			errors.append("areas: must be a non-empty subset of the 7 user areas (got [])")
			return errors
		for area in areas:
			if not Taxonomy.is_user_area(area):
				errors.append("areas: unknown area '%s' (got '%s')" % [area, area])
		return errors

	func _validate_session_blocks(session: Session, path: String, catalog: Dictionary,
			have_catalog: bool) -> Array[String]:
		var errors: Array[String] = []
		# V11
		if session.blocks.is_empty():
			errors.append("%s.blocks: must have at least 1 block (got 0)" % path)
		# V13
		if session.blocks.size() > PlanModel.BLOCKS_MAX:
			errors.append("%s.blocks: must have at most %d blocks (got %d)"
				% [path, PlanModel.BLOCKS_MAX, session.blocks.size()])
		for index in session.blocks.size():
			var block := session.blocks[index]
			var block_path := "%s.blocks[%d]" % [path, index]
			var record: Dictionary = catalog.get(block.exercise_id, {})
			# V14
			if have_catalog and record.is_empty():
				errors.append("%s: unknown exercise_id '%s'" % [block_path, block.exercise_id])
			# V15
			if block.sets < PlanModel.SETS_MIN or block.sets > PlanModel.SETS_MAX:
				errors.append("%s: sets out of range (got %d)" % [block_path, block.sets])
			# V16
			if not PlanModel.is_valid_reps(block.reps):
				errors.append("%s: unparseable reps '%s' (got '%s')"
					% [block_path, block.reps, block.reps])
			# V17
			if block.rest_seconds < PlanModel.REST_MIN \
					or block.rest_seconds > PlanModel.REST_MAX:
				errors.append("%s: rest out of range (got %d)"
					% [block_path, block.rest_seconds])
			# V22
			if have_catalog and bool(record.get("is_stretch", false)):
				errors.append("%s: stretch used as a working block (got '%s')"
					% [block_path, block.exercise_id])
		return errors

	func _validate_session_mobility(session: Session, path: String, catalog: Dictionary,
			have_catalog: bool) -> Array[String]:
		var errors: Array[String] = []
		# V12
		if session.warmup.is_empty():
			errors.append("%s.warmup: must have at least 1 warm-up item (got 0)" % path)
		var groups: Array = [["warmup", session.warmup], ["cooldown", session.cooldown]]
		for group in groups:
			var label := String(group[0])
			var items: Array = group[1]
			for index in items.size():
				var item: MobilityItem = items[index]
				var item_path := "%s.%s[%d]" % [path, label, index]
				# V14
				if have_catalog and not catalog.has(item.exercise_id):
					errors.append("%s: unknown exercise_id '%s'" % [item_path, item.exercise_id])
				# V20
				if item.duration_sec < PlanModel.DURATION_SEC_MIN \
						or item.duration_sec > PlanModel.DURATION_SEC_MAX:
					errors.append("%s: duration_sec out of range (got %d)"
						% [item_path, item.duration_sec])
		return errors

	## V18 — no exercise id twice in one session (blocks ∪ warmup ∪ cooldown).
	func _validate_session_duplicates(session: Session, path: String) -> Array[String]:
		var errors: Array[String] = []
		var counts: Dictionary = {}
		for exercise_id in session.exercise_ids():
			if exercise_id.is_empty():
				continue
			counts[exercise_id] = int(counts.get(exercise_id, 0)) + 1
		var duplicates := PackedStringArray()
		for exercise_id in counts.keys():
			if int(counts[exercise_id]) > 1:
				duplicates.append(String(exercise_id))
		duplicates.sort()
		for exercise_id in duplicates:
			errors.append("%s: duplicate exercise '%s' (got %d)"
				% [path, exercise_id, int(counts[exercise_id])])
		return errors

	## V21 — anti-adjacency at `primary_muscle` granularity (master plan §7.2).
	func _validate_adjacency(session: Session, path: String, catalog: Dictionary,
			have_catalog: bool) -> Array[String]:
		var errors: Array[String] = []
		if not have_catalog:
			return errors
		var previous := ""
		for index in session.blocks.size():
			var record: Dictionary = catalog.get(session.blocks[index].exercise_id, {})
			if record.is_empty():
				continue
			var muscle := String(record.get("primary_muscle", ""))
			if index > 0 and not previous.is_empty() and muscle == previous:
				errors.append("%s.blocks[%d]: adjacent blocks share primary muscle '%s' (got '%s')"
					% [path, index, muscle, muscle])
			previous = muscle
		return errors


static func _block_dicts(blocks: Array[Block]) -> Array:
	var out: Array = []
	for block in blocks:
		out.append(block.to_dict())
	return out


static func _mobility_dicts(items: Array[MobilityItem]) -> Array:
	var out: Array = []
	for item in items:
		out.append(item.to_dict())
	return out


# ---------------------------------------------------------------------------
# from_dict
# ---------------------------------------------------------------------------

static func block_from_dict(data: Dictionary) -> Block:
	var block := Block.new()
	block.exercise_id = as_text(data.get("exercise_id"), "")
	block.sets = as_int(data.get("sets"), 0)
	block.reps = as_text(data.get("reps"), "")
	block.rest_seconds = as_int(data.get("rest_seconds"), 0)
	for key in data.keys():
		if not BLOCK_KEYS.has(key):
			block.extra[key] = data[key]
	return block


static func mobility_from_dict(data: Dictionary) -> MobilityItem:
	var item := MobilityItem.new()
	item.exercise_id = as_text(data.get("exercise_id"), "")
	item.duration_sec = as_int(data.get("duration_sec"), 0)
	for key in data.keys():
		if not MOBILITY_KEYS.has(key):
			item.extra[key] = data[key]
	return item


static func _mobility_list(value: Variant) -> Array[MobilityItem]:
	var out: Array[MobilityItem] = []
	if value is Array:
		for entry in value:
			if entry is Dictionary:
				out.append(mobility_from_dict(entry))
	return out


static func _block_list(value: Variant) -> Array[Block]:
	var out: Array[Block] = []
	if value is Array:
		for entry in value:
			if entry is Dictionary:
				out.append(block_from_dict(entry))
	return out


static func session_from_dict(data: Dictionary) -> Session:
	var session := Session.new()
	session.id = as_text(data.get("id"), "")
	session.index = as_int(data.get("index"), 0)
	session.title = as_text(data.get("title"), "")
	session.focus = _string_array(data.get("focus", []))
	session.est_minutes = as_int(data.get("est_minutes"), 0)
	session.warmup = _mobility_list(data.get("warmup", []))
	session.blocks = _block_list(data.get("blocks", []))
	session.cooldown = _mobility_list(data.get("cooldown", []))
	for key in data.keys():
		if not SESSION_KEYS.has(key):
			session.extra[key] = data[key]
	return session


static func plan_from_dict(data: Dictionary) -> Plan:
	var plan := Plan.new()
	plan.id = as_text(data.get("id"), "")
	plan.name = as_text(data.get("name"), "")
	plan.created_at = as_text(data.get("created_at"), "")
	plan.source = as_text(data.get("source"), "")
	plan.provider = as_text(data.get("provider"), "")
	plan.goal = as_text(data.get("goal"), "")
	plan.days_per_week = as_int(data.get("days_per_week"), 0)
	plan.duration_min = as_int(data.get("duration_min"), 0)
	plan.areas = _string_array(data.get("areas", []))
	plan.equipment = _string_array(data.get("equipment", []))
	plan.notes = as_text(data.get("notes"), "")
	plan.split_name = as_text(data.get("split_name"), "")
	var sessions: Array[Session] = []
	if data.get("sessions", []) is Array:
		for entry in data.get("sessions", []):
			if entry is Dictionary:
				sessions.append(session_from_dict(entry))
	plan.sessions = sessions
	for key in data.keys():
		if not PLAN_KEYS.has(key):
			plan.extra[key] = data[key]
	return plan


## Convenience for callers that hold an untyped plan (PRD-07): validate a raw dict.
static func validate_dict(data: Dictionary, catalog: Dictionary = {}) -> Array[String]:
	return plan_from_dict(data).validate(catalog)
