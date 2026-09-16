extends Node
## Persistence entry point for the whole app — PRD-03.
##
## `Store` is the **only** code allowed to reach the four documents in `user://data/`
## (`settings.json`, `plans.json`, `history.json`, `session_progress.json`). Every other
## script asks this autoload. The raw file I/O itself lives in the pure, injectable
## [JsonStore] (ADR-04), which takes its base directory as a constructor argument so the
## identical code path runs in the app and in `res://.test_tmp/…` under test.
##
## What this file adds on top of [JsonStore]:
## - the four typed in-memory views plus the raw `_shadow` copy of each document, so a
##   field written by a newer app version survives a load/save cycle (R6);
## - the schema-version migration chain and the `future_version` refusal (R5/R4.6);
## - 400 ms debounced writes with a synchronous [method flush] on every notification that
##   can precede an Android process kill (R3);
## - the section signals the UI listens to, emitted *after* the in-memory view changes and
##   *before* the write happens (R11);
## - the derived streak / ISO-week / ring numbers PRD-09 and PRD-11 display (R13–R15).
##
## Test isolation (R17/ADR-04): call [method set_io_root_for_tests] **before**
## [method load_all]. Suites use `res://.test_tmp/<suite>/` because `user://` is
## read-only on this machine; the real app uses the default `user://data/`.

signal data_loaded(first_run: bool)
signal settings_changed()
signal plans_changed()
signal history_changed()
signal session_progress_changed()
signal entry_added(entry: Dictionary)
signal save_failed(name: String, error: String)
signal recovered_from_backup(name: String)
signal quarantined(name: String, quarantine_path: String, reason: String)
signal migrated(name: String, from_version: int, to_version: int, steps: PackedStringArray)

const DEBOUNCE_SEC := 0.4
const MAX_DOC_BYTES := 262144
const MAX_QUARANTINES := 5
const STALE_PROGRESS_HOURS := 12

const DEFAULT_IO_ROOT := "user://data/"
const DOCUMENTS: PackedStringArray = ["settings", "plans", "history", "session_progress"]
## Created by [method load_all] on a first run, so the documents AC4 expects exist after the
## very first launch. `session_progress.json` is deliberately NOT in this list: it appears
## only when a workout starts, and a resume cursor nobody wrote must not exist.
const CREATED_ON_BOOT: PackedStringArray = ["settings", "plans", "history"]
const FILE_LABELS := {
	"settings": "Settings",
	"plans": "Plans",
	"history": "History",
	"session_progress": "Session",
}
const TIMER_NAMES := {
	"settings": "SettingsTimer",
	"plans": "PlansTimer",
	"history": "HistoryTimer",
	"session_progress": "SessionProgressTimer",
}

var _io_root: String = DEFAULT_IO_ROOT
var _store: JsonStore = null
var _loaded: bool = false
var _first_run: bool = false
var _last_error: String = ""
## Raw document exactly as read (post-migration, pre-defaults) — the unknown-field keeper.
var _shadow: Dictionary = {}
## Typed, defaulted and clamped view of each document. Getter callers treat it as
## read-only; every mutation goes through this API.
var _views: Dictionary = {}
var _dirty: Dictionary = {}
var _timers: Dictionary = {}


func _ready() -> void:
	_store = JsonStore.new(_io_root, MAX_DOC_BYTES, MAX_QUARANTINES)
	_ensure_timers()
	load_all()


# ------------------------------------------------------------------ lifecycle (R10/R19)

## Loads (or creates) all four documents, runs the migration chain, applies defaults and
## emits `migrated` / `recovered_from_backup` / `quarantined` as they happen, then exactly
## one `data_loaded(first_run)`. Never awaits (R19).
##
## On a first run the three durable documents are written immediately (see
## [constant CREATED_ON_BOOT]); the session cursor is not. When the storage root cannot be
## created — a read-only `user://` mount on a development machine — creation is deferred to
## the first real mutation instead of shouting at boot: nothing has been mutated yet, so
## nothing can be lost.
func load_all() -> void:
	if _store == null:
		_store = JsonStore.new(_io_root, MAX_DOC_BYTES, MAX_QUARANTINES)
	_ensure_timers()
	_reset_state()
	for doc_name in DOCUMENTS:
		_load_document(doc_name)
	_create_boot_documents()
	_loaded = true
	data_loaded.emit(_first_run)


func is_loaded() -> bool:
	return _loaded


## True when at least one document has changes waiting for its debounce timer.
func is_dirty() -> bool:
	for doc_name in DOCUMENTS:
		if bool(_dirty.get(doc_name, false)):
			return true
	return false


## Stops every timer and writes every dirty document synchronously. Returns true only when
## all of them reached the disk (R3).
func flush() -> bool:
	_ensure_timers()
	for doc_name in DOCUMENTS:
		var timer: Timer = _timers.get(doc_name, null)
		if timer != null:
			timer.stop()
	var ok := true
	for doc_name in DOCUMENTS:
		if bool(_dirty.get(doc_name, false)):
			if not _write_document(doc_name):
				ok = false
	return ok


func storage_dir() -> String:
	return _io_root


## `doc_name` rather than the appendix's `name`: a parameter called `name` shadows
## `Node.name` and the project rejects that warning. GDScript has no named arguments, so
## the call signature is unchanged.
func file_path(doc_name: String) -> String:
	if _store == null:
		_store = JsonStore.new(_io_root, MAX_DOC_BYTES, MAX_QUARANTINES)
	return _store.file_path(doc_name)


func last_error() -> String:
	return _last_error


## Points the storage engine somewhere else — a path under `res://.test_tmp/` in tests
## (ADR-04: `user://` is read-only on this machine). Resets every in-memory view and stops
## every timer, so it MUST be called before [method load_all].
func set_io_root_for_tests(dir_path: String) -> void:
	_reset_state()
	_io_root = JsonStore.normalize_dir(dir_path)
	_store = JsonStore.new(_io_root, MAX_DOC_BYTES, MAX_QUARANTINES)
	print("[store] io_root=%s" % _io_root)


func quarantine_paths(doc_name: String) -> PackedStringArray:
	if _store == null:
		return PackedStringArray()
	return _store.quarantine_paths(doc_name)


func now_iso() -> String:
	return Dates.now_iso8601(true)


func today_local_iso() -> String:
	return Dates.today_iso(false)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, \
		NOTIFICATION_WM_GO_BACK_REQUEST, NOTIFICATION_WM_CLOSE_REQUEST:
			# Android can kill a backgrounded process without ever delivering a pause, so
			# all five of these force a flush (R3; appendix §5 lists the same five).
			var _forced := flush()


func _exit_tree() -> void:
	var _final := flush()


# ------------------------------------------------------------------ settings (R7)

func settings() -> Dictionary:
	_ensure_loaded()
	var view: Dictionary = _views.get("settings", {})
	return view


## `get_setting("llm.model")` walks dotted paths. Unknown paths yield [param default_value].
func get_setting(path: String, default_value: Variant = null) -> Variant:
	var node: Variant = settings()
	for segment in path.split(".", false):
		if not (node is Dictionary) or not (node as Dictionary).has(segment):
			return default_value
		node = (node as Dictionary)[segment]
	return node


## Writes one settings value, validating it against the schema. Returns false — leaving the
## document untouched — for an unknown section or an out-of-range value (R10).
func set_setting(path: String, value: Variant) -> bool:
	var segments := path.split(".", false)
	if segments.is_empty():
		return _reject_setting(path, "empty path")
	var candidate_dict: Dictionary = JsonStore.Json.deep_copy(settings())
	if not _path_exists(candidate_dict, segments):
		return _reject_setting(path, "unknown settings key")

	var cursor: Dictionary = candidate_dict
	for i in range(segments.size() - 1):
		cursor = cursor[segments[i]]
	cursor[segments[segments.size() - 1]] = JsonStore.Json.deep_copy(value)

	var errors := Migrations.Schema.validate_settings(candidate_dict)
	if not errors.is_empty():
		return _reject_setting(path, errors[0])

	_touch_settings_meta(candidate_dict)
	_views["settings"] = candidate_dict
	_mark_dirty("settings")
	settings_changed.emit()
	return true


## Force-writes the settings document now, bypassing the debounce.
func save_settings() -> bool:
	_ensure_loaded()
	_dirty["settings"] = true
	return _write_document("settings")


## Every settings key back to its default. `meta.created_at` survives, because it records
## when this install was created, not what the user configured (R7).
func reset_settings() -> void:
	var created := String(get_setting("meta.created_at", now_iso()))
	var fresh := Migrations.Schema.default_settings()
	var meta: Dictionary = fresh["meta"]
	meta["created_at"] = created
	fresh["meta"] = meta
	_views["settings"] = fresh
	_shadow["settings"] = {}
	_mark_dirty("settings")
	settings_changed.emit()


# ------------------------------------------------------------------ plans (R8)

func plans_doc() -> Dictionary:
	_ensure_loaded()
	var doc: Dictionary = _views.get("plans", {})
	return doc


func all_plans() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for element in _live_plan_list(plans_doc()):
		if element is Dictionary:
			out.append(element)
	return out


func active_plan_id() -> String:
	var doc := plans_doc()
	var value: Variant = doc.get("active_plan_id", "")
	return String(value) if value is String else ""


func active_plan() -> Dictionary:
	var id := active_plan_id()
	if id.is_empty():
		return {}
	return get_plan(id)


func get_plan(plan_id: String) -> Dictionary:
	if plan_id.is_empty():
		return {}
	for plan in all_plans():
		if String(plan.get("id", "")) == plan_id:
			return plan
	return {}


## Inserts a plan at index 0 (newest first), or replaces a plan with a matching `id`
## **in place**, preserving its position and every unknown field it carries (R8, R58).
func upsert_plan(plan: Dictionary) -> bool:
	_ensure_loaded()
	if plan.is_empty():
		_last_error = "upsert_plan: empty plan"
		push_warning("[store] upsert_plan rejected an empty plan")
		return false
	var doc := plans_doc()
	var list := _live_plan_list(doc)
	var record := Migrations.Schema.apply_plan_defaults(plan)
	var plan_id := String(record.get("id", ""))
	if plan_id.is_empty():
		plan_id = _unique_id("plan-", _plan_ids())
		record["id"] = plan_id

	var index := JsonStore.Json.index_of_id(list, plan_id)
	if index >= 0:
		list[index] = record
	else:
		list.insert(0, record)
	doc["plans"] = list
	_mark_dirty("plans")
	plans_changed.emit()
	return true


## `""` clears the active pointer. An unknown id is refused rather than silently stored.
func set_active_plan(plan_id: String) -> bool:
	_ensure_loaded()
	if not plan_id.is_empty() and get_plan(plan_id).is_empty():
		_last_error = "set_active_plan: unknown plan '%s'" % plan_id
		push_warning("[store] %s" % _last_error)
		return false
	plans_doc()["active_plan_id"] = plan_id
	_mark_dirty("plans")
	plans_changed.emit()
	return true


func delete_plan(plan_id: String) -> bool:
	_ensure_loaded()
	var doc := plans_doc()
	var list := _live_plan_list(doc)
	var index := JsonStore.Json.index_of_id(list, plan_id)
	if index < 0:
		_last_error = "delete_plan: unknown plan '%s'" % plan_id
		return false
	list.remove_at(index)
	if active_plan_id() == plan_id:
		doc["active_plan_id"] = ""
	_mark_dirty("plans")
	plans_changed.emit()
	# A resume cursor pointing at a deleted plan is meaningless (R9b).
	var inner := _memory_progress()
	if String(inner.get("plan_id", "")) == plan_id:
		var _cleared := clear_session_progress()
	return true


## A copy of [param plan] under a fresh id, stored and returned. PRD-09's "Repeat this
## plan" then calls [method set_active_plan] on the result (appendix §6.3).
func duplicate_plan(plan: Dictionary, new_name: String) -> Dictionary:
	if plan.is_empty():
		_last_error = "duplicate_plan: empty plan"
		return {}
	var copy_dict: Dictionary = JsonStore.Json.deep_copy(plan)
	copy_dict["id"] = _unique_id("plan-", _plan_ids())
	copy_dict["name"] = new_name if not new_name.is_empty() else "%s (copy)" % String(
		plan.get("name", ""))
	copy_dict["created_at"] = now_iso()
	if not upsert_plan(copy_dict):
		return {}
	return get_plan(String(copy_dict["id"]))


# ------------------------------------------------------------------ history (R9)

func history_doc() -> Dictionary:
	_ensure_loaded()
	var doc: Dictionary = _views.get("history", {})
	return doc


func all_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for element in _live_entry_list(history_doc()):
		if element is Dictionary:
			out.append(element)
	return out


func entries_on(date_iso: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in all_entries():
		if String(entry.get("date", "")) == date_iso:
			out.append(entry)
	return out


## Inclusive on both ends.
func entries_between(from_iso: String, to_iso: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in all_entries():
		var date := String(entry.get("date", ""))
		if date >= from_iso and date <= to_iso:
			out.append(entry)
	return out


## Appends an entry and returns its new id, or `""` when it was refused (R9).
func add_entry(entry: Dictionary) -> String:
	_ensure_loaded()
	if entry.is_empty():
		_last_error = "add_entry: empty entry"
		push_warning("[store] add_entry rejected an empty entry")
		return ""
	var record := Migrations.Schema.apply_entry_defaults(entry)
	var date := String(record.get("date", ""))
	if not Dates.is_valid_iso_date(date):
		_last_error = "add_entry: invalid date '%s'" % date
		push_warning("[store] rejected history entry with invalid date '%s'" % date)
		return ""

	var entry_id := String(record.get("id", ""))
	if entry_id.is_empty():
		entry_id = _unique_id("h-", _entry_ids())
	else:
		entry_id = _dedupe_id(entry_id, _entry_ids())
	record["id"] = entry_id
	if String(record.get("started_at", "")).is_empty():
		record["started_at"] = now_iso()

	var doc := history_doc()
	var list := _live_entry_list(doc)
	list.append(record)
	doc["entries"] = Migrations.Schema.sort_entries(list)
	_mark_dirty("history")
	history_changed.emit()
	entry_added.emit(record)
	return entry_id


func update_entry(entry_id: String, fields: Dictionary) -> bool:
	_ensure_loaded()
	var doc := history_doc()
	var list := _live_entry_list(doc)
	var index := JsonStore.Json.index_of_id(list, entry_id)
	if index < 0:
		_last_error = "update_entry: unknown entry '%s'" % entry_id
		return false
	var merged := JsonStore.Json.merge_record(list[index], fields)
	var record := Migrations.Schema.apply_entry_defaults(merged)
	if not Migrations.Schema.validate_entry(record).is_empty():
		return _reject_entry(record, entry_id)
	list[index] = record
	doc["entries"] = Migrations.Schema.sort_entries(list)
	_mark_dirty("history")
	history_changed.emit()
	return true


func delete_entry(entry_id: String) -> bool:
	_ensure_loaded()
	var doc := history_doc()
	var list := _live_entry_list(doc)
	var index := JsonStore.Json.index_of_id(list, entry_id)
	if index < 0:
		_last_error = "delete_entry: unknown entry '%s'" % entry_id
		return false
	list.remove_at(index)
	doc["entries"] = list
	_mark_dirty("history")
	history_changed.emit()
	return true


# ------------------------------------------------------------------ session progress (R9b)

## Upserts the inner progress dictionary and marks the document dirty. The ids must be
## present: a cursor that resolves to nothing is worse than no cursor.
func save_session_progress(progress: Dictionary) -> bool:
	_ensure_loaded()
	if progress.is_empty():
		_last_error = "save_session_progress: empty progress"
		return false
	var inner := Migrations.Schema.apply_progress_defaults(progress)
	if String(inner.get("plan_id", "")).is_empty() or String(inner.get("session_id", "")).is_empty():
		_last_error = "save_session_progress: plan_id and session_id are required"
		push_warning("[store] rejected session progress without plan_id/session_id")
		return false
	if String(inner.get("started_at", "")).is_empty():
		inner["started_at"] = now_iso()
	if not Dates.is_valid_iso_datetime(String(inner.get("updated_at", ""))):
		inner["updated_at"] = now_iso()
	# A rest timer never resumes across a process kill (appendix §5.4).
	inner["rest_remaining_sec"] = 0

	var doc := Migrations.Schema.default_session_progress()
	doc["progress"] = inner
	_views["session_progress"] = doc
	_shadow["session_progress"] = {}
	_mark_dirty("session_progress")
	session_progress_changed.emit()
	return true


## `{}` when the file is absent, unresolvable, malformed or older than
## [constant STALE_PROGRESS_HOURS] — in which case the file is removed (R9b).
func load_session_progress() -> Dictionary:
	_ensure_loaded()
	var disk_progress: Dictionary = {}
	if _store != null and _store.file_exists("session_progress"):
		var result: JsonStore.ReadResult = _store.read_document("session_progress")
		if result.status == JsonStore.STATUS_QUARANTINED:
			_announce_quarantine("session_progress", result.quarantine_path, result.reason)
		elif result.is_usable():
			var value: Variant = result.data.get("progress", null)
			if value is Dictionary:
				disk_progress = Migrations.Schema.apply_progress_defaults(value)

	var chosen := _newer_progress(disk_progress, _memory_progress())
	if chosen.is_empty():
		return {}
	if not _progress_resolves(chosen) or _progress_is_stale(chosen):
		_discard_session_progress()
		return {}
	return chosen


## Deletes the file — an emptied document would still look like a resumable session.
func clear_session_progress() -> bool:
	var removed := true
	if _store != null:
		removed = _store.delete_document("session_progress")
	_views["session_progress"] = Migrations.Schema.default_session_progress()
	_dirty["session_progress"] = false
	session_progress_changed.emit()
	return removed


# ------------------------------------------------------------------ export / import / reset

## `llm.api_key` never leaves the app unless [param include_api_key] is explicitly true,
## and never appears in the returned text otherwise (R7/R21, appendix §1.2).
func export_all(include_api_key: bool = false) -> Dictionary:
	var settings_copy: Dictionary = JsonStore.Json.deep_copy(settings())
	var llm_value: Variant = settings_copy.get("llm", null)
	if llm_value is Dictionary:
		var llm: Dictionary = JsonStore.Json.strip_unknown(llm_value,
			Migrations.Schema.LLM_FIELDS)
		llm["api_key"] = String(llm.get("api_key", "")) if include_api_key else ""
		settings_copy["llm"] = llm
	return {
		"export_version": 1,
		"exported_at": now_iso(),
		"app_version": AppInfo.VERSION,
		"settings": settings_copy,
		"plans": JsonStore.Json.deep_copy(plans_doc()),
		"history": JsonStore.Json.deep_copy(history_doc()),
	}


## Restores a bundle produced by [method export_all]. Refuses any document whose version is
## newer than this build understands, and copies every live document to `.bak` first, so a
## bad bundle can never destroy data that is already on the device.
func import_bundle(bundle: Dictionary) -> bool:
	_ensure_loaded()
	if bundle.is_empty():
		_last_error = "import_bundle: empty bundle"
		return false
	var present: PackedStringArray = []
	for doc_name in ["settings", "plans", "history"]:
		if bundle.get(doc_name) is Dictionary:
			present.append(doc_name)
	if present.is_empty():
		_last_error = "import_bundle: no documents in the bundle"
		return false

	# Refuse before writing anything.
	for doc_name in present:
		var incoming: Dictionary = bundle[doc_name]
		if Migrations.version_of(doc_name, incoming) > Migrations.current_version(doc_name):
			_last_error = "import_bundle: %s.json is from a newer app version" % doc_name
			push_warning("[store] %s" % _last_error)
			return false

	for doc_name in DOCUMENTS:
		if _store != null:
			var _backed_up := _store.backup_document(doc_name)

	for doc_name in present:
		var incoming: Dictionary = bundle[doc_name]
		var data := incoming
		if Migrations.version_of(doc_name, incoming) < Migrations.current_version(doc_name):
			var migration := Migrations.migrate(doc_name, incoming)
			if not migration.ok:
				_last_error = "import_bundle: %s" % migration.error
				return false
			data = migration.data
		_shadow[doc_name] = data
		_views[doc_name] = _build_view(doc_name, data)
		_dirty[doc_name] = true

	if bool(_dirty.get("settings", false)):
		settings_changed.emit()
	if bool(_dirty.get("plans", false)):
		plans_changed.emit()
	if bool(_dirty.get("history", false)):
		history_changed.emit()
	if not flush():
		_last_error = "import_bundle: write failed"
		return false
	_last_error = ""
	return true


## Every document back to defaults, then a synchronous flush. The session cursor is deleted
## rather than blanked (R9b).
func reset_all() -> bool:
	_ensure_loaded()
	_views["settings"] = Migrations.Schema.default_settings()
	_views["plans"] = Migrations.Schema.default_plans()
	_views["history"] = Migrations.Schema.default_history()
	_shadow["settings"] = {}
	_shadow["plans"] = {}
	_shadow["history"] = {}
	for doc_name in ["settings", "plans", "history"]:
		_dirty[doc_name] = true
	settings_changed.emit()
	plans_changed.emit()
	history_changed.emit()
	var cleared := clear_session_progress()
	var written := flush()
	return written and cleared


func data_dir_usage_bytes() -> int:
	if _store == null:
		return 0
	return _store.dir_usage_bytes()


## Per-document bytes plus a `backups` bucket and the `total`, for the debug probe.
func data_dir_breakdown() -> Dictionary:
	if _store == null:
		return {}
	return _store.breakdown(DOCUMENTS)


# ------------------------------------------------------------------ derived (R13/R14/R15)

func streak_days(today_iso: String = "") -> int:
	var today := today_iso if not today_iso.is_empty() else today_local_iso()
	return Streak.current_streak(all_entries(), today)


func longest_streak() -> int:
	return Streak.longest_streak(all_entries())


func completed_days_in_week(week_id: String = "") -> int:
	var week := week_id if not week_id.is_empty() else current_week_id()
	return Streak.completed_days_in_week(all_entries(), week)


func current_week_id() -> String:
	return Dates.iso_week_id(today_local_iso())


## Appendix R50: the active plan owns the ring denominator; `weekly_goal_days` is the goal
## used when there is no plan (PRD-03 R15).
func weekly_goal_days_effective() -> int:
	var plan := active_plan()
	if not plan.is_empty():
		var days := Migrations.Schema.as_int(plan.get("days_per_week", null), 0)
		if days >= 1:
			return days
	return Migrations.Schema.as_int(get_setting("weekly_goal_days", 4), 4)


func weekly_goal_progress() -> float:
	return Streak.week_goal_progress(all_entries(), today_local_iso(), weekly_goal_days_effective())


# ------------------------------------------------------------------ loading internals

func _reset_state() -> void:
	for doc_name in _timers:
		var timer: Timer = _timers[doc_name]
		timer.stop()
	_loaded = false
	_first_run = false
	_last_error = ""
	_shadow.clear()
	_views.clear()
	_dirty.clear()


func _ensure_loaded() -> void:
	if not _loaded:
		load_all()


func _ensure_timers() -> void:
	for doc_name in DOCUMENTS:
		if _timers.has(doc_name):
			continue
		var timer := Timer.new()
		timer.name = String(TIMER_NAMES[doc_name])
		timer.one_shot = true
		timer.wait_time = DEBOUNCE_SEC
		timer.autostart = false
		add_child(timer)
		timer.timeout.connect(_on_debounce_timeout.bind(doc_name))
		_timers[doc_name] = timer


func _load_document(doc_name: String) -> void:
	var result: JsonStore.ReadResult = _store.read_document(doc_name)
	var raw: Dictionary = {}
	var usable := result.is_usable()

	var needs_creation := false
	match result.status:
		JsonStore.STATUS_MISSING:
			# Only the durable documents decide "first run": a missing session cursor is
			# the normal state of an install that has never started a workout.
			if CREATED_ON_BOOT.has(doc_name):
				_first_run = true
			needs_creation = true
		JsonStore.STATUS_QUARANTINED:
			needs_creation = true
			_announce_quarantine(doc_name, result.quarantine_path, result.reason)
		JsonStore.STATUS_RECOVERED:
			print("[store] recovered %s.json from backup" % doc_name)
			recovered_from_backup.emit(doc_name)
			raw = result.data
		_:
			raw = result.data

	if usable:
		var current := Migrations.current_version(doc_name)
		var stored := Migrations.version_of(doc_name, raw)
		if stored > current:
			# Never migrate downwards: a newer build must still be able to read this file.
			var future_path := _quarantine(doc_name, JsonStore.REASON_FUTURE_VERSION, false)
			_announce_quarantine(doc_name, future_path, JsonStore.REASON_FUTURE_VERSION)
			raw = {}
			needs_creation = true
		elif stored < current:
			var migration := Migrations.migrate(doc_name, raw)
			if migration.ok:
				raw = migration.data
				print("[store] migrated %s.json %d -> %d steps=%d" % [
					doc_name, stored, current, migration.steps.size()])
				migrated.emit(doc_name, stored, current, migration.steps)
				# A migrated document is written back at the current version right away, so
				# the chain runs once instead of on every launch.
				needs_creation = true
			else:
				var failed_path := _quarantine(doc_name, JsonStore.REASON_MIGRATION, true)
				_announce_quarantine(doc_name, failed_path, JsonStore.REASON_MIGRATION)
				push_warning("[store] migration failed for %s.json: %s" % [doc_name, migration.error])
				raw = {}
				needs_creation = true

	# Written once the whole load is done, so a document created here is complete and valid
	# even if a later document turns out to be corrupt, and so AC8's "a fresh valid
	# settings.json" holds after a quarantine.
	if needs_creation and CREATED_ON_BOOT.has(doc_name):
		_dirty[doc_name] = true

	_shadow[doc_name] = JsonStore.Json.deep_copy(raw)
	var view := _build_view(doc_name, raw)
	_views[doc_name] = view
	var suffix := "" if usable else " (defaults)"
	print("[store] load %s.json v=%d bytes=%d%s" % [
		doc_name, Migrations.version_of(doc_name, view), result.bytes, suffix])


## Creates the missing durable documents on a first run (AC4). Never reports through
## `push_error`: a storage root that does not exist yet is a normal state on a development
## machine, and the first real mutation retries the exact same write.
func _create_boot_documents() -> void:
	if _store == null:
		return
	if not _store.dir_exists() and not _store.ensure_dir():
		for doc_name in CREATED_ON_BOOT:
			_dirty[doc_name] = false
		_last_error = "storage root is not writable yet: %s" % _io_root
		return
	for doc_name in CREATED_ON_BOOT:
		if not bool(_dirty.get(doc_name, false)):
			continue
		var document := _serialize(doc_name)
		# Cleared either way: nothing has been mutated yet, so there is nothing to retry —
		# the next real mutation marks the document dirty again.
		_dirty[doc_name] = false
		if _store.write_document(doc_name, document):
			_shadow[doc_name] = document
		else:
			_last_error = "%s: %s" % [doc_name, _store.last_error()]
			print("[store] could not create %s.json yet: %s" % [doc_name, _store.last_error()])
			save_failed.emit(doc_name, _last_error)


func _build_view(doc_name: String, raw: Dictionary) -> Dictionary:
	match doc_name:
		"settings":
			var clamped: Array = Migrations.Schema.clamp_settings(raw)
			for line in clamped[1]:
				print("[store] clamped %s" % String(line))
			var fixed: Dictionary = clamped[0]
			return fixed
		"plans":
			return Migrations.Schema.apply_plans_defaults(raw)
		"history":
			return _build_history_view(raw)
		"session_progress":
			return _build_progress_view(raw)
	return {}


func _build_history_view(raw: Dictionary) -> Dictionary:
	var kept: Array = []
	var entries_value: Variant = raw.get("entries", null)
	if entries_value is Array:
		for element in entries_value:
			if not (element is Dictionary):
				push_warning("[store] dropped malformed history entry %s" % str(element))
				continue
			var entry: Dictionary = element
			if not Dates.is_valid_iso_date(String(entry.get("date", ""))):
				# One bad row must never cost the user their streak (R9).
				push_warning("[store] dropped malformed history entry %s" % String(entry.get("id", "")))
				continue
			kept.append(entry)
	var reduced := JsonStore.Json.merge_known(raw, {"entries": kept})
	return Migrations.Schema.apply_history_defaults(reduced)


func _build_progress_view(raw: Dictionary) -> Dictionary:
	var doc := Migrations.Schema.default_session_progress()
	var value: Variant = raw.get("progress", null)
	if value is Dictionary:
		doc["progress"] = Migrations.Schema.apply_progress_defaults(value)
	return doc


func _quarantine(doc_name: String, reason: String, include_backup: bool) -> String:
	if _store == null:
		return ""
	var path := _store.quarantine(doc_name, reason, include_backup)
	if path.is_empty():
		_last_error = _store.last_error()
	return path


## The one place a damaged document becomes user-visible: signal + toast (R4.4, R11).
func _announce_quarantine(doc_name: String, quarantine_path: String, reason: String) -> void:
	_last_error = "%s.json was quarantined (%s)" % [doc_name, reason]
	quarantined.emit(doc_name, quarantine_path, reason)
	var label := String(FILE_LABELS.get(doc_name, doc_name))
	_toast("%s was damaged — starting fresh. A copy was kept." % label, &"warning")


## Toasts go through the Feedback autoload when it exists. The lookup is by node path and
## guarded, because a headless suite instantiates this class without a scene tree and the
## store must keep loading even when nothing can display a toast.
func _toast(text: String, kind: StringName) -> void:
	if not is_inside_tree():
		return
	var feedback := get_node_or_null(^"/root/Feedback")
	if feedback != null and feedback.has_method(&"toast"):
		feedback.call(&"toast", text, kind)


# ------------------------------------------------------------------ writing internals

func _mark_dirty(doc_name: String) -> void:
	_dirty[doc_name] = true
	var timer: Timer = _timers.get(doc_name, null)
	# A headless suite has no scene tree, so the timer cannot run there; the suite drives
	# the same code path by emitting the timer's `timeout` signal.
	if timer != null and timer.is_inside_tree():
		timer.start()


func _on_debounce_timeout(doc_name: String) -> void:
	if not bool(_dirty.get(doc_name, false)):
		return
	var _written := _write_document(doc_name)


## Serializes the typed view over the raw shadow so unknown fields survive (R6), then
## writes it atomically. A failure keeps the document dirty so a later flush retries.
func _write_document(doc_name: String) -> bool:
	if _store == null:
		_store = JsonStore.new(_io_root, MAX_DOC_BYTES, MAX_QUARANTINES)
	var document := _serialize(doc_name)
	if not _store.write_document(doc_name, document):
		_last_error = "%s: %s" % [doc_name, _store.last_error()]
		push_error("[store] save failed for %s.json: %s" % [doc_name, _store.last_error()])
		save_failed.emit(doc_name, _last_error)
		return false
	_shadow[doc_name] = document
	_dirty[doc_name] = false
	_last_error = ""
	return true


func _serialize(doc_name: String) -> Dictionary:
	var view: Dictionary = _views.get(doc_name, {})
	var raw: Dictionary = _shadow.get(doc_name, {})
	return JsonStore.Json.merge_record(raw, view)


# ------------------------------------------------------------------ small helpers

func _path_exists(root: Dictionary, segments: PackedStringArray) -> bool:
	var node: Variant = root
	for segment in segments:
		if not (node is Dictionary) or not (node as Dictionary).has(segment):
			return false
		node = (node as Dictionary)[segment]
	return true


func _reject_setting(path: String, reason: String) -> bool:
	_last_error = "set_setting(%s): %s" % [path, reason]
	# The reason never contains the value, so an invalid API key can never be logged (R7).
	push_warning("[store] %s" % _last_error)
	return false


func _reject_entry(record: Dictionary, entry_id: String) -> bool:
	var errors := Migrations.Schema.validate_entry(record)
	_last_error = "update_entry(%s): %s" % [entry_id, errors[0] if not errors.is_empty() else ""]
	push_warning("[store] %s" % _last_error)
	return false


func _touch_settings_meta(doc: Dictionary) -> void:
	var meta_value: Variant = doc.get("meta", null)
	var meta: Dictionary = meta_value if meta_value is Dictionary else {}
	meta["updated_at"] = now_iso()
	doc["meta"] = meta


func _live_plan_list(doc: Dictionary) -> Array:
	var value: Variant = doc.get("plans", null)
	if value is Array:
		return value
	doc["plans"] = []
	var fresh: Array = doc["plans"]
	return fresh


func _live_entry_list(doc: Dictionary) -> Array:
	var value: Variant = doc.get("entries", null)
	if value is Array:
		return value
	doc["entries"] = []
	var fresh: Array = doc["entries"]
	return fresh


func _plan_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for plan in all_plans():
		ids.append(String(plan.get("id", "")))
	return ids


func _entry_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for entry in all_entries():
		ids.append(String(entry.get("id", "")))
	return ids


## `"plan-1758000000"`, then `-2`, `-3`, … on collision (R8/R9). The unix time is cast to
## int because `Time.get_unix_time_from_system()` returns a float and the id format is
## `^plan-\d{10}$`.
func _unique_id(prefix: String, taken: PackedStringArray) -> String:
	return _dedupe_id(prefix + str(int(Time.get_unix_time_from_system())), taken)


## `base`, or `base-2`, `base-3`, … when that id is already taken (R8/R9).
func _dedupe_id(base: String, taken: PackedStringArray) -> String:
	var candidate := base
	var n := 2
	while taken.has(candidate):
		candidate = "%s-%d" % [base, n]
		n += 1
	return candidate


func _memory_progress() -> Dictionary:
	var doc: Dictionary = _views.get("session_progress", {})
	var value: Variant = doc.get("progress", null)
	if value is Dictionary:
		return Migrations.Schema.apply_progress_defaults(value)
	return {}


func _newer_progress(disk: Dictionary, memory: Dictionary) -> Dictionary:
	if disk.is_empty():
		return memory
	if memory.is_empty():
		return disk
	var disk_stamp := Dates.epoch_seconds(String(disk.get("updated_at", "")))
	var memory_stamp := Dates.epoch_seconds(String(memory.get("updated_at", "")))
	return memory if memory_stamp > disk_stamp else disk


func _progress_resolves(progress: Dictionary) -> bool:
	var plan := get_plan(String(progress.get("plan_id", "")))
	if plan.is_empty():
		return false
	var session_id := String(progress.get("session_id", ""))
	var sessions: Variant = plan.get("sessions", null)
	if not (sessions is Array):
		return false
	for element in sessions:
		if element is Dictionary and String(element.get("id", "")) == session_id:
			return true
	return false


func _progress_is_stale(progress: Dictionary) -> bool:
	var updated := String(progress.get("updated_at", ""))
	if not Dates.is_valid_iso_datetime(updated):
		return true
	var age := Dates.seconds_between_iso(now_iso(), updated)
	return age > STALE_PROGRESS_HOURS * Dates.SECONDS_PER_HOUR


func _discard_session_progress() -> void:
	_last_error = "session progress discarded (stale or unresolvable)"
	if _store != null:
		var _removed := _store.delete_document("session_progress")
	_views["session_progress"] = Migrations.Schema.default_session_progress()
	_dirty["session_progress"] = false
	session_progress_changed.emit()
