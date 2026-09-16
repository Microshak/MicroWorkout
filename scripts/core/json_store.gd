class_name JsonStore
extends RefCounted
## Pure, injectable JSON document storage engine — PRD-03 R1–R4/R6, ADR-04.
##
## This class owns **all** file I/O for the app's four documents and knows nothing about
## the scene tree, autoloads, signals or UI. Its base directory is a constructor argument
## (ADR-04), so the very same code path runs in the app (`user://data/`) and in the
## headless suites (`res://.test_tmp/…`) — a test can therefore never touch the
## developer's real app data.
##
## Every document has three siblings:
## [codeblock]
## settings.json  settings.json.tmp  settings.json.bak  settings.json.corrupt-<TS>.json
## [/codeblock]
##
## Guests of the R2 write algorithm, in order: serialize (tab-indented, sorted keys) →
## size guard → write the `.tmp` sibling → verify the tmp file's byte count → copy the
## current file to `.bak` → *atomic* rename over the live file. The backup is taken
## before the replace, never after, so a crash mid-write can only ever lose the newest
## revision, never the previous one.
##
## `Store` (the autoload) is the only caller; it owns the typed views, the debounce
## timers, the migration chain and the signals. This class only reports what happened,
## through [member ReadResult.status] and [method last_error].

## 256 KiB — a single-user document this large means a bug, not a big workout history.
const DEFAULT_MAX_DOC_BYTES := 262144
## At most this many `<name>.json.corrupt-*` files per document (R4.5).
const DEFAULT_MAX_QUARANTINES := 5
## A flush slower than this is reported with a warning (R2.7).
const SLOW_FLUSH_MS := 250

## [member ReadResult.status] values.
const STATUS_OK := "ok"
const STATUS_MISSING := "missing"
const STATUS_RECOVERED := "recovered"
const STATUS_QUARANTINED := "quarantined"

## Quarantine reasons — `future_version` means "valid JSON from a newer app", which is a
## different problem from corruption and must never be repaired by guessing (R4.6).
const REASON_PARSE := "parse"
const REASON_NOT_OBJECT := "not_object"
const REASON_EMPTY := "empty"
const REASON_FUTURE_VERSION := "future_version"
const REASON_MIGRATION := "migration_failed"


## What [method read_document] found. [member data] is empty unless the status is
## [constant STATUS_OK] or [constant STATUS_RECOVERED].
class ReadResult extends RefCounted:
	var status: String = JsonStore.STATUS_OK
	var data: Dictionary = {}
	var reason: String = ""
	var quarantine_path: String = ""
	var bytes: int = 0

	func is_usable() -> bool:
		return status == JsonStore.STATUS_OK or status == JsonStore.STATUS_RECOVERED


## Pure helpers for the plain-JSON dictionary shapes the documents use (PRD-03 R6).
## Unknown-field preservation lives here: [method merge_known] keeps every key the caller
## knows nothing about, so a document written by a newer app version survives a
## load/save cycle of an older one.
class Json extends RefCounted:

	## True for a JSON object (an empty `{}` is an object, `[]` is not).
	static func is_object(v: Variant) -> bool:
		return v is Dictionary

	static func deep_copy(v: Variant) -> Variant:
		if v is Dictionary or v is Array:
			return v.duplicate(true)
		return v

	## Copy of [param base] with every key of [param known] written over it.
	## Keys that only [param base] has are retained — that is the whole point.
	static func merge_known(base: Dictionary, known: Dictionary) -> Dictionary:
		var out: Dictionary = {}
		for key in base:
			out[key] = deep_copy(base[key])
		for key in known:
			out[key] = deep_copy(known[key])
		return out

	## Copy of [param d] keeping only [param allowed] keys.
	static func strip_unknown(d: Dictionary, allowed: PackedStringArray) -> Dictionary:
		var out: Dictionary = {}
		for key in d:
			if allowed.has(key):
				out[key] = deep_copy(d[key])
		return out

	## Merge a typed record over its raw counterpart, recursing into every array field so
	## that unknown keys survive at record, session, block, warm-up and entry level (R6).
	static func merge_record(raw: Dictionary, typed: Dictionary) -> Dictionary:
		var out := merge_known(raw, typed)
		for key in typed:
			var typed_value: Variant = typed[key]
			if typed_value is Array:
				var raw_value: Variant = raw.get(key, [])
				var raw_list: Array = raw_value if raw_value is Array else []
				out[key] = merge_list(raw_list, typed_value)
		return out

	## Merge a list of typed records over the raw list, keyed by `id` — or by index when
	## the element carries no `id`. Membership follows [param typed_list]: a raw element
	## the typed view dropped is dropped (the typed view is authoritative).
	static func merge_list(raw_list: Array, typed_list: Array) -> Array:
		var out: Array = []
		for i in typed_list.size():
			var typed_element: Variant = typed_list[i]
			if typed_element is Dictionary:
				var raw_element: Dictionary = {}
				var element_id := String((typed_element as Dictionary).get("id", ""))
				if not element_id.is_empty():
					raw_element = find_by_id(raw_list, element_id)
				elif i < raw_list.size() and raw_list[i] is Dictionary:
					raw_element = raw_list[i]
				out.append(merge_record(raw_element, typed_element))
			else:
				out.append(deep_copy(typed_element))
		return out

	## The first dictionary in [param list] whose `id` equals [param record_id].
	static func find_by_id(list: Array, record_id: String) -> Dictionary:
		for element in list:
			if element is Dictionary and String((element as Dictionary).get("id", "")) == record_id:
				return element
		return {}

	## Index of the first dictionary in [param list] whose `id` equals [param record_id].
	static func index_of_id(list: Array, record_id: String) -> int:
		for i in list.size():
			var element: Variant = list[i]
			if element is Dictionary and String((element as Dictionary).get("id", "")) == record_id:
				return i
		return -1


var _base_dir: String
var _max_doc_bytes: int
var _max_quarantines: int
var _last_error: String = ""
var _dir_ready: bool = false


## Parameters are named to avoid shadowing the accessors below (the project treats
## GDScript warnings as build failures). Callers pass them positionally.
func _init(dir_path: String = "user://data/", capacity_bytes: int = DEFAULT_MAX_DOC_BYTES,
		quarantine_limit: int = DEFAULT_MAX_QUARANTINES) -> void:
	_base_dir = normalize_dir(dir_path)
	_max_doc_bytes = maxi(capacity_bytes, 1024)
	_max_quarantines = maxi(quarantine_limit, 1)


## Every path this engine touches is derived from here; always ends with a slash.
static func normalize_dir(dir_path: String) -> String:
	var out := dir_path.strip_edges()
	if out.is_empty():
		out = "user://data"
	if not out.ends_with("/"):
		out += "/"
	return out


func base_dir() -> String:
	return _base_dir


func max_doc_bytes() -> int:
	return _max_doc_bytes


func last_error() -> String:
	return _last_error


# ------------------------------------------------------------------ paths (R1)

func file_path(doc_name: String) -> String:
	return _base_dir + doc_name + ".json"


func tmp_path(doc_name: String) -> String:
	return _base_dir + doc_name + ".json.tmp"


func bak_path(doc_name: String) -> String:
	return _base_dir + doc_name + ".json.bak"


func file_exists(doc_name: String) -> bool:
	return FileAccess.file_exists(file_path(doc_name))


func dir_exists() -> bool:
	return DirAccess.dir_exists_absolute(_base_dir)


## Creates the base directory when it is missing and reports the [enum Error] (R1).
func ensure_dir() -> bool:
	if _dir_ready:
		return true
	if dir_exists():
		_dir_ready = true
		return true
	var err := DirAccess.make_dir_recursive_absolute(_base_dir)
	if err != OK:
		_last_error = "cannot create %s (error %d)" % [_base_dir, err]
		return false
	_dir_ready = true
	return true


# ------------------------------------------------------------------ read (R4)

## Reads `<doc_name>.json`, falling back to its `.bak`, quarantining both when neither
## parses. Never throws and never deletes the live file except into a quarantine copy.
func read_document(doc_name: String) -> ReadResult:
	var result := ReadResult.new()
	var final := file_path(doc_name)
	if not FileAccess.file_exists(final):
		# First run: the caller applies defaults. No quarantine, no toast (R4.1).
		result.status = STATUS_MISSING
		return result

	var text := _read_text(final)
	result.bytes = text.to_utf8_buffer().size()
	var primary := _parse_object(text)
	if bool(primary["ok"]):
		result.status = STATUS_OK
		result.data = primary["data"]
		_last_error = ""
		return result

	var reason := String(primary["reason"])
	var backup := bak_path(doc_name)
	if FileAccess.file_exists(backup):
		var backup_parsed := _parse_object(_read_text(backup))
		if bool(backup_parsed["ok"]):
			# The backup is the thing that saved us: repair the live file from it and
			# keep the backup (write without rotating, or we would clobber it) — R4.3.
			result.status = STATUS_RECOVERED
			result.data = backup_parsed["data"]
			var repaired: bool = write_document(doc_name, result.data, false)
			if not repaired:
				push_warning("[store] could not repair %s.json from backup: %s" % [
					doc_name, _last_error])
			_last_error = ""
			return result

	# Both files are unusable: quarantine them together under one timestamp (R4.4/R4.5).
	result.status = STATUS_QUARANTINED
	result.reason = reason
	result.quarantine_path = quarantine(doc_name, reason, true)
	return result


# ------------------------------------------------------------------ write (R2)

## Serializes [param doc] and writes it atomically. When [param rotate_backup] is false the
## current file is replaced *without* being copied to `.bak` first — used by the recovery
## path, where the backup is the good copy that must survive.
func write_document(doc_name: String, doc: Dictionary, rotate_backup: bool = true) -> bool:
	var started := Time.get_ticks_msec()
	if not ensure_dir():
		return false

	# 1. Tab-indented (the owner reads these files), sorted keys, 4-decimal floats.
	var text: String = JSON.stringify(doc, "\t", true, false) + "\n"

	# 2. A single-user document over MAX_DOC_BYTES means a bug, not a big history.
	if text.length() > _max_doc_bytes:
		_last_error = "%s.json is %d bytes, over the %d byte cap" % [
			doc_name, text.length(), _max_doc_bytes]
		return false

	var final := file_path(doc_name)
	var tmp := tmp_path(doc_name)

	# 3./4. Write the sibling first, then prove it arrived complete.
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		_last_error = "cannot open %s for writing (error %d)" % [tmp, FileAccess.get_open_error()]
		return false
	file.store_string(text)
	file.flush()
	file.close()

	var expected := text.to_utf8_buffer().size()
	var written := _file_size(tmp)
	if written != expected:
		_last_error = "short write to %s (%d of %d bytes)" % [tmp, written, expected]
		_remove_file(tmp)
		return false

	# 5. Backup *before* replace: a crash between the two can only lose the newest copy.
	if rotate_backup and FileAccess.file_exists(final):
		var copy_err := DirAccess.copy_absolute(final, bak_path(doc_name))
		if copy_err != OK:
			_last_error = "cannot back up %s (error %d)" % [final, copy_err]
			_remove_file(tmp)
			return false

	# 6. POSIX rename: atomic on the same filesystem and replaces the target.
	var rename_err := DirAccess.rename_absolute(tmp, final)
	if rename_err != OK:
		_last_error = "cannot rename %s -> %s (error %d)" % [tmp, final, rename_err]
		_remove_file(tmp)
		return false

	# 7. Observability: the app's only record of what reached the disk, and how fast.
	var elapsed := Time.get_ticks_msec() - started
	print("[store] flush %s.json bytes=%d ms=%d" % [doc_name, text.length(), elapsed])
	if elapsed > SLOW_FLUSH_MS:
		push_warning("[store] slow flush %s.json %d ms" % [doc_name, elapsed])
	_last_error = ""
	return true


## Copies the live document over its `.bak` (used by `import_bundle`, which promises a
## backup before it overwrites anything). A missing live file is not an error.
func backup_document(doc_name: String) -> bool:
	var final := file_path(doc_name)
	if not FileAccess.file_exists(final):
		return true
	if not ensure_dir():
		return false
	var err := DirAccess.copy_absolute(final, bak_path(doc_name))
	if err != OK:
		_last_error = "cannot back up %s (error %d)" % [final, err]
		return false
	return true


## Removes the live document (not an emptied document) plus any stray `.tmp` sibling.
func delete_document(doc_name: String) -> bool:
	var final := file_path(doc_name)
	var removed := not FileAccess.file_exists(final)
	if not removed:
		removed = _remove_file(final)
	_remove_file(tmp_path(doc_name))
	if not removed:
		_last_error = "cannot remove %s" % final
		return false
	_last_error = ""
	return true


# ------------------------------------------------------------------ quarantine (R4.4/R4.5)

## `<name>.json.corrupt-<TS>.json` files for [param doc_name], oldest first (sorted by
## name, which the `<TS>` prefix makes chronological).
func quarantine_paths(doc_name: String) -> PackedStringArray:
	var paths := PackedStringArray()
	if not dir_exists():
		return paths
	var prefix := doc_name + ".json.corrupt-"
	for entry in DirAccess.get_files_at(_base_dir):
		if entry.begins_with(prefix):
			paths.append(_base_dir + entry)
	paths.sort()
	return paths


## Renames the live file (and, when [param include_backup] is true, its `.bak`) to
## `.corrupt-<TS>` copies sharing one timestamp, then prunes the oldest beyond the cap.
## Returns the primary quarantine path, or `""` when there was nothing to quarantine.
func quarantine(doc_name: String, reason: String, include_backup: bool = false) -> String:
	if not ensure_dir():
		return ""
	var tag := _unique_tag(doc_name)
	var primary := ""
	var final := file_path(doc_name)
	if FileAccess.file_exists(final):
		primary = "%s%s.json.corrupt-%s.json" % [_base_dir, doc_name, tag]
		_rename(final, primary)
	if include_backup:
		var backup := bak_path(doc_name)
		if FileAccess.file_exists(backup):
			var backup_target := "%s%s.json.corrupt-%s-bak.json" % [_base_dir, doc_name, tag]
			_rename(backup, backup_target)
			if primary.is_empty():
				primary = backup_target
	# The one log line the owner needs to find a damaged file again (R21).
	print("[store] quarantined %s.json -> %s reason=%s" % [
		doc_name, primary if not primary.is_empty() else "(nothing to quarantine)", reason])
	_prune_quarantines(doc_name)
	return primary


# ------------------------------------------------------------------ usage

func list_files() -> PackedStringArray:
	if not dir_exists():
		return PackedStringArray()
	return DirAccess.get_files_at(_base_dir)


## Bytes used by every document, backup, temp file and quarantine copy.
func dir_usage_bytes() -> int:
	var total := 0
	for entry in list_files():
		total += _file_size(_base_dir + entry)
	return total


## Per-document bytes plus a `backups` bucket and the `total`, for the probe screen.
func breakdown(doc_names: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	var counted := 0
	for doc_name in doc_names:
		var main_bytes := _file_size(file_path(doc_name))
		out[doc_name] = main_bytes
		counted += main_bytes
	out["backups"] = maxi(dir_usage_bytes() - counted, 0)
	out["total"] = dir_usage_bytes()
	return out


# ------------------------------------------------------------------ internals

## `20260915T120000Z` — R1's timestamp, with `-`, `:` and the space stripped.
static func timestamp_tag() -> String:
	var stamp := Time.get_datetime_string_from_system(true, true)
	return stamp.replace("-", "").replace(":", "").replace(" ", "") + "Z"


## `{}` plus `ok`/`data`/`reason`, so an empty-but-valid `{}` is distinguishable from a
## parse failure — the difference between "use defaults" and "quarantine the file".
func _parse_object(text: String) -> Dictionary:
	if text.strip_edges().is_empty():
		return {"ok": false, "data": {}, "reason": REASON_EMPTY}
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return {"ok": false, "data": {}, "reason": REASON_PARSE}
	if not (parsed is Dictionary):
		return {"ok": false, "data": {}, "reason": REASON_NOT_OBJECT}
	return {"ok": true, "data": parsed, "reason": ""}


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_last_error = "cannot open %s for reading (error %d)" % [path, FileAccess.get_open_error()]
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := file.get_length()
	file.close()
	return size


func _remove_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(path) == OK


func _rename(from: String, to: String) -> bool:
	if FileAccess.file_exists(to):
		_remove_file(to)
	var err := DirAccess.rename_absolute(from, to)
	if err != OK:
		_last_error = "cannot quarantine %s -> %s (error %d)" % [from, to, err]
		push_warning("[store] %s" % _last_error)
		return false
	return true


## The first free timestamp tag for this document. Timestamps have one-second resolution,
## so a second quarantine inside the same second gets `-2`, `-3`, … instead of silently
## overwriting the first one.
func _unique_tag(doc_name: String) -> String:
	var stamp := timestamp_tag()
	var tag := stamp
	var n := 2
	while _quarantine_name_taken(doc_name, tag):
		tag = "%s-%d" % [stamp, n]
		n += 1
	return tag


func _quarantine_name_taken(doc_name: String, tag: String) -> bool:
	var primary := "%s%s.json.corrupt-%s.json" % [_base_dir, doc_name, tag]
	var backup := "%s%s.json.corrupt-%s-bak.json" % [_base_dir, doc_name, tag]
	return FileAccess.file_exists(primary) or FileAccess.file_exists(backup)


## Retention: only `<name>.json.corrupt-*` copies are ever removed this way. The live
## document and its `.bak` are never auto-deleted (R4.5, ADR-13).
func _prune_quarantines(doc_name: String) -> void:
	var paths := quarantine_paths(doc_name)
	while paths.size() > _max_quarantines:
		var oldest := paths[0]
		paths.remove_at(0)
		if _remove_file(oldest):
			print("[store] pruned quarantine %s" % oldest)
		else:
			push_warning("[store] could not prune quarantine %s" % oldest)
