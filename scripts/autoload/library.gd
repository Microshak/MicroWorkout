extends Node
## Read-only access to the bundled exercise library — PRD-03 R16 / appendix §1.3.
##
## One load builds every index the rest of the app needs: `id → record`, `area → ids`,
## `equipment → ids`, `is_stretch → ids`, id-sorted ids, and a normalised `name → id` map
## that [method resolve_name] searches through [Library.Fuzzy].
##
## [b]Graceful degradation is mandatory.[/b] A missing or malformed
## `res://data/exercise_library.json` never throws: the loader logs
## `[library] load failed: <reason>`, emits [signal library_failed], leaves
## [method is_ready] false and every getter returns `{}` / `[]` / `""`, so screens show
## their `empty_state` until PRD-04 repairs the file. The failure line is a `print()` and
## not a `push_warning()`, because a libary that has not been generated yet is an expected
## state of a fresh checkout, not an engine warning.
##
## [b]Ownership:[/b] PRD-03 owns this loader and the file *shape*; PRD-04 owns the
## *contents* and overwrites the file wholesale (appendix R47).

signal library_loaded(count: int)
signal library_failed(reason: String)

const LIBRARY_PATH := "res://data/exercise_library.json"
## `catalog_prompt_lines()` entry format, `"%s | %s | %s | %s"`.
const PROMPT_LINE_FORMAT := "%s | %s | %s | %s"

## Fields the library contract types as integers. JSON has no integer type, so a record
## read from disk carries `3.0`; these four are normalised on load so downstream code never
## has to compare a float.
const INT_FIELDS: PackedStringArray = ["default_sets", "rep_min", "rep_max", "rest_seconds"]

var _exercises: Array[Dictionary] = []
var _by_id: Dictionary = {}
var _by_area: Dictionary = {}
var _by_equipment: Dictionary = {}
var _stretch_ids: PackedStringArray = PackedStringArray()
var _ids_sorted: PackedStringArray = PackedStringArray()
var _name_index: Dictionary = {}
var _name_candidates: PackedStringArray = PackedStringArray()
var _source: Dictionary = {}
var _ready_flag: bool = false
var _attempted: bool = false
var _load_path: String = LIBRARY_PATH
var _reason: String = ""


func _ready() -> void:
	var _loaded_ok := load_library()


# ------------------------------------------------------------------ loading (R16)

## Loads [param path] (the bundled library by default). Idempotent for a path that has
## already been attempted — use [method reload] to force a re-read.
func load_library(path: String = LIBRARY_PATH) -> bool:
	if _attempted and path == _load_path:
		return _ready_flag
	return _read(path)


func reload() -> bool:
	return _read(_load_path)


func is_ready() -> bool:
	return _ready_flag


func count() -> int:
	return _exercises.size()


## Why the last load failed, `""` when it succeeded.
func failure_reason() -> String:
	return _reason


# ------------------------------------------------------------------ records

## Every record, in file order.
func all_exercises() -> Array[Dictionary]:
	return _exercises.duplicate()


## Every id, sorted — the canonical iteration order for prompts and catalogs.
func all_ids() -> PackedStringArray:
	return _ids_sorted.duplicate()


func get_exercise(id: String) -> Dictionary:
	var index := _index_of(id)
	return _exercises[index] if index >= 0 else {}


func has_exercise(id: String) -> bool:
	return _index_of(id) >= 0


## Records that train [param area] (the `areas` array, not the primary muscle).
func by_area(area: String) -> Array[Dictionary]:
	return _records_for(_by_area, area)


## Records that require [param equipment].
func by_equipment(equipment: String) -> Array[Dictionary]:
	return _records_for(_by_equipment, equipment)


## Records with `is_stretch == true` — the mobility pool the warm-up/cooldown builder uses.
func stretches() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _stretch_ids:
		var record := get_exercise(id)
		if not record.is_empty():
			out.append(record)
	return out


## Case-insensitive substring search over the display name and the id.
func search(query: String, limit: int = 20) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var needle := Fuzzy.normalize(query)
	if needle.is_empty() or limit <= 0:
		return out
	for record in _exercises:
		var id := String(record.get("id", ""))
		if id.to_lower().contains(needle) or Fuzzy.normalize(String(
				record.get("name", ""))).contains(needle):
			out.append(record)
			if out.size() >= limit:
				break
	return out


## The filter PRD-07's prompt builder wants (appendix R42): an empty filter array means
## "no constraint on this dimension".
func catalog_filtered(areas: PackedStringArray, equipment: PackedStringArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _ids_sorted:
		var record := get_exercise(id)
		if record.is_empty():
			continue
		if not areas.is_empty() and not _intersects(_strings(record.get("areas", [])), areas):
			continue
		if not equipment.is_empty() and not equipment.has(String(record.get("equipment", ""))):
			continue
		out.append(record)
	return out


## `[{id, name, areas, equipment}]`, id-sorted — the compact catalog for the §8.2 prompt.
func catalog_compact() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _ids_sorted:
		var record := get_exercise(id)
		if record.is_empty():
			continue
		out.append({
			"id": id,
			"name": String(record.get("name", "")),
			"areas": _strings(record.get("areas", [])),
			"equipment": String(record.get("equipment", "")),
		})
	return out


## One line per record, id-sorted (PRD-07 R3 shape).
func catalog_prompt_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in catalog_compact():
		var areas: PackedStringArray = entry["areas"]
		out.append(PROMPT_LINE_FORMAT % [
			entry["id"], entry["name"], ", ".join(areas), entry["equipment"]])
	return out


# ------------------------------------------------------------------ lookup

## The id whose name best matches [param name], or `""`.
##
## Exact normalised matches win first (including with a trailing parenthetical removed,
## which is how "Bench Press (Barbell)" is written), then [Library.Fuzzy.best_match] over
## every normalised name and spaced id.
## The parameter is named `query` rather than the appendix's `name`, which would shadow
## `Node.name` — a warning this project treats as a build failure. The call signature is
## unchanged (GDScript has no named arguments).
func resolve_name(query: String, threshold: float = 0.82) -> String:
	var normalized := Fuzzy.normalize(query)
	if normalized.is_empty():
		return ""
	if _name_index.has(normalized):
		return String(_name_index[normalized])
	var stripped := Fuzzy.normalize(_strip_parenthetical(query))
	if not stripped.is_empty() and _name_index.has(stripped):
		return String(_name_index[stripped])
	var best := Fuzzy.best_match(normalized, _name_candidates, threshold)
	if best.is_empty():
		return ""
	return String(_name_index.get(Fuzzy.normalize(best), ""))


func get_frames(id: String) -> PackedStringArray:
	return _strings(get_exercise(id).get("frames", []))


func get_cues(id: String) -> PackedStringArray:
	return _strings(get_exercise(id).get("cues", []))


## The display name, `""` for an unknown id.
##
## [b]NOT named `get_name()`:[/b] PRD-03 R16 and appendix §1.3 ask for
## `get_name(id: String) -> String`, but `Library` extends `Node`, whose native
## `get_name() -> StringName` cannot be overridden with a different signature (Godot 4.7
## rejects the script with a parse error). `name_of()` is the same accessor under a legal
## name; `get_exercise(id)["name"]` remains available.
func name_of(id: String) -> String:
	return String(get_exercise(id).get("name", ""))


func areas_of(id: String) -> PackedStringArray:
	return _strings(get_exercise(id).get("areas", []))


func is_compound(id: String) -> bool:
	var record := get_exercise(id)
	return bool(record.get("compound", false)) if not record.is_empty() else false


## The library file's `source` block (repo/license/creator), `{}` when absent.
func source_attribution() -> Dictionary:
	return _source


# ------------------------------------------------------------------ internals

func _read(path: String) -> bool:
	_reset()
	_attempted = true
	_load_path = path

	if not FileAccess.file_exists(path):
		return _fail("file not found: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail("cannot open %s (error %d)" % [path, FileAccess.get_open_error()])
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return _fail("invalid JSON in %s" % path)
	if not (parsed is Dictionary):
		return _fail("top level of %s is not an object" % path)
	var document: Dictionary = parsed

	if not _is_integer(document.get("schema_version", null)):
		return _fail("%s has no integer schema_version" % path)
	var source_value: Variant = document.get("source", null)
	if not (source_value is Dictionary):
		return _fail("%s has no source object" % path)
	var records: Variant = document.get("exercises", null)
	if not (records is Array):
		return _fail("%s has no exercises array" % path)

	_source = source_value
	_index(records)
	_ready_flag = true
	_reason = ""
	if _exercises.is_empty():
		push_warning("[library] %s loaded but contains no usable exercise records" % path)
	print("[library] loaded %d exercises (%d stretches) from %s" % [
		count(), _stretch_ids.size(), path])
	library_loaded.emit(count())
	return true


func _fail(reason: String) -> bool:
	_reason = reason
	print("[library] load failed: %s" % reason)
	library_failed.emit(reason)
	return false


func _reset() -> void:
	_exercises.clear()
	_by_id.clear()
	_by_area.clear()
	_by_equipment.clear()
	_stretch_ids = PackedStringArray()
	_ids_sorted = PackedStringArray()
	_name_index.clear()
	_name_candidates = PackedStringArray()
	_source = {}
	_ready_flag = false
	_reason = ""


## Records missing `id`/`name` are skipped with a warning; duplicate ids keep the first.
func _index(records: Array) -> void:
	for i in records.size():
		var element: Variant = records[i]
		if not (element is Dictionary):
			push_warning("[library] skipping record %d: not an object" % i)
			continue
		var record: Dictionary = element
		var id := String(record.get("id", ""))
		var display_name := String(record.get("name", ""))
		if id.is_empty() or display_name.is_empty():
			push_warning("[library] skipping record %d: missing id or name" % i)
			continue
		if _by_id.has(id):
			push_warning("[library] duplicate id '%s' — keeping the first record" % id)
			continue

		_normalize_record(record)
		_by_id[id] = _exercises.size()
		_exercises.append(record)
		_ids_sorted.append(id)

		for area in _strings(record.get("areas", [])):
			_append_id(_by_area, area, id)
		var equipment := String(record.get("equipment", ""))
		if not equipment.is_empty():
			_append_id(_by_equipment, equipment, id)
		if bool(record.get("is_stretch", false)):
			_stretch_ids.append(id)

		_index_name(display_name, id)
		_index_name(id.replace("-", " "), id)

	_ids_sorted.sort()


func _normalize_record(record: Dictionary) -> void:
	for field in INT_FIELDS:
		var value: Variant = record.get(field, null)
		if value is float and is_finite(float(value)) and float(value) == floor(float(value)):
			record[field] = int(value)
	# Records keep plain arrays (appendix §7.1 types `areas` as Array<String>); only the
	# public getters return PackedStringArray.
	for field in ["areas", "secondary_muscles", "frames", "cues"]:
		if record.has(field):
			record[field] = _string_array(record[field])


func _index_name(text: String, id: String) -> void:
	var key := Fuzzy.normalize(text)
	if key.is_empty() or _name_index.has(key):
		return
	_name_index[key] = id
	_name_candidates.append(key)


func _index_of(id: String) -> int:
	var value: Variant = _by_id.get(id, -1)
	return int(value) if value is int else -1


func _records_for(index: Dictionary, key: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var value: Variant = index.get(key, null)
	if not (value is PackedStringArray):
		return out
	var ids: PackedStringArray = value
	for id in ids:
		var record := get_exercise(id)
		if not record.is_empty():
			out.append(record)
	return out


func _append_id(index: Dictionary, key: String, id: String) -> void:
	var value: Variant = index.get(key, null)
	var ids: PackedStringArray = value if value is PackedStringArray else PackedStringArray()
	ids.append(id)
	index[key] = ids


## The record's array field as a plain Array of Strings (the on-disk type).
static func _string_array(value: Variant) -> Array:
	var out: Array = []
	if value is Array:
		for element in value:
			if element is String:
				out.append(element)
	elif value is PackedStringArray:
		for element in value:
			out.append(element)
	return out


## The record's array field as strings, dropping anything that is not a string.
static func _strings(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array:
		for element in value:
			if element is String:
				out.append(element)
	elif value is PackedStringArray:
		for element in value:
			out.append(element)
	return out


static func _intersects(haystack: PackedStringArray, needles: PackedStringArray) -> bool:
	for needle in needles:
		if haystack.has(needle):
			return true
	return false


## `is_integer` for a value that came out of JSON — every JSON number is a float there.
static func _is_integer(value: Variant) -> bool:
	if value is int:
		return true
	if value is float:
		return is_finite(float(value)) and float(value) == floor(float(value))
	return false


## "Bench Press (Barbell)" → "Bench Press", so a parenthetical equipment hint never
## prevents an exact name match.
static func _strip_parenthetical(text: String) -> String:
	var open_index := text.find("(")
	if open_index < 0:
		return text
	var close_index := text.find(")", open_index)
	if close_index < 0:
		return text.substr(0, open_index)
	return text.substr(0, open_index) + text.substr(close_index + 1)


## Pure string-similarity helpers (PRD-03 R12) used by [method resolve_name].
##
## PRD-03 places these in `scripts/core/fuzzy.gd`; the implementing agent's file scope does
## not include that path, so they live here — next to their only consumer — as
## `Library.Fuzzy`. The algorithms are exactly R12's.
class Fuzzy extends RefCounted:

	## Lowercase, every run of non-`[a-z0-9]` collapsed into one space, trimmed.
	static func normalize(text: String) -> String:
		var lowered := text.to_lower()
		var out := ""
		var pending_space := false
		for i in lowered.length():
			var c := lowered[i]
			var code := c.unicode_at(0)
			var is_alnum := (code >= 97 and code <= 122) or (code >= 48 and code <= 57)
			if is_alnum:
				if pending_space and not out.is_empty():
					out += " "
				out += c
				pending_space = false
			else:
				pending_space = true
		return out


	## Classic two-row Levenshtein distance on the given strings.
	static func levenshtein(a: String, b: String) -> int:
		if a == b:
			return 0
		if a.is_empty():
			return b.length()
		if b.is_empty():
			return a.length()
		var previous := PackedInt32Array()
		var current := PackedInt32Array()
		previous.resize(b.length() + 1)
		current.resize(b.length() + 1)
		for j in b.length() + 1:
			previous[j] = j
		for i in a.length():
			current[0] = i + 1
			for j in b.length():
				var cost := 0 if a[i] == b[j] else 1
				current[j + 1] = mini(mini(current[j] + 1, previous[j + 1] + 1), previous[j] + cost)
			for j in b.length() + 1:
				previous[j] = current[j]
		return previous[b.length()]


	## Jaccard similarity of the two token sets.
	static func jaccard(a: String, b: String) -> float:
		var left := _tokens(a)
		var right := _tokens(b)
		if left.is_empty() or right.is_empty():
			return 0.0
		var union := {}
		for token in left:
			union[token] = true
		for token in right:
			union[token] = true
		var shared := 0
		for token in left:
			if right.has(token):
				shared += 1
		return float(shared) / float(union.size())


	## `max(jaccard, 1 - levenshtein / max_length)` on normalised strings, `0.0` when
	## either side is empty (R12).
	static func similarity(a: String, b: String) -> float:
		var left := normalize(a)
		var right := normalize(b)
		if left.is_empty() or right.is_empty():
			return 0.0
		var distance := 1.0 - float(levenshtein(left, right)) / float(
			maxi(maxi(left.length(), right.length()), 1))
		return maxf(jaccard(left, right), distance)


	## The best-scoring candidate at or above [param threshold], `""` below it. Ties go to
	## the lexicographically smallest candidate.
	static func best_match(query: String, candidates: PackedStringArray, threshold: float) -> String:
		var best := ""
		var best_score := -1.0
		for candidate in candidates:
			var score := similarity(query, candidate)
			if score < threshold:
				continue
			if score > best_score or (is_equal_approx(score, best_score) and candidate < best):
				best = candidate
				best_score = score
		return best


	static func _tokens(text: String) -> PackedStringArray:
		var normalized := normalize(text)
		if normalized.is_empty():
			return PackedStringArray()
		return normalized.split(" ", false)
