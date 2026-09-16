class_name Migrations
extends RefCounted
## Schema versions, the ordered migration chain and the on-disk shape of every document
## — PRD-03 R5 / R7 / R8 / R9 / R9b, appendix §5.
##
## Two responsibilities that belong together, because a migration step is defined by the
## shape it produces:
##
## 1. [b]Versions and steps.[/b] [constant SETTINGS_CURRENT] = 2, [constant PLANS_CURRENT]
##    = 1, [constant HISTORY_CURRENT] = 1, [constant SESSION_PROGRESS_CURRENT] = 1.
##    Version 0 means "a file with no `schema_version`" — the pre-schema app. A version
##    *above* current is never migrated downwards; the caller quarantines it with
##    `reason = future_version` (R4.6), so a newer build can still recover the file.
## 2. [b]Shape.[/b] [Migrations.Schema] holds the default documents, the allow-lists, the
##    per-field defaults, the validators and the clamps. It is the single source of the
##    document shape: nothing else may invent a settings key (ADR-24/R25, appendix R23).
##
## [b]Deviation from PRD-03 §5 (documented in the PRD-03 report):[/b] PRD-03 lists this
## contract in two extra files, `scripts/core/schema_migrations.gd` (this file) and
## `scripts/core/store_schema.gd`. The implementing agent's file scope pins the first and
## does not include the second, so the schema lives here as [Migrations.Schema] instead of
## as a second top-level `StoreSchema` class. Every default, allow-list, validator and
## clamp PRD-03 assigns to `store_schema.gd` is implemented — unchanged — under
## `Migrations.Schema`.
##
## Everything here is static and pure; the only side effects are `push_warning` calls on
## genuinely invalid input.

const SETTINGS_CURRENT := 2
const PLANS_CURRENT := 1
const HISTORY_CURRENT := 1
const SESSION_PROGRESS_CURRENT := 1

const KIND_SETTINGS := &"settings"
const KIND_PLANS := &"plans"
const KIND_HISTORY := &"history"
const KIND_SESSION_PROGRESS := &"session_progress"

## Every document `Store` owns, in load order.
const KINDS: PackedStringArray = ["settings", "plans", "history", "session_progress"]


## Result of [method migrate]: the migrated document, the steps that ran, and whether the
## caller may use it at all. A failed step must quarantine rather than guess (R5).
class Result extends RefCounted:
	var data: Dictionary = {}
	var steps: PackedStringArray = PackedStringArray()
	var ok: bool = true
	var error: String = ""


static func current_version(kind: StringName) -> int:
	match String(kind):
		"settings":
			return SETTINGS_CURRENT
		"plans":
			return PLANS_CURRENT
		"history":
			return HISTORY_CURRENT
		"session_progress":
			return SESSION_PROGRESS_CURRENT
	return 0


## The document's stored version. Absent, negative or non-integral => 0.
##
## JSON has no integer type: `JSON.parse_string()` turns every number into a float, so a
## file containing `"schema_version": 2` arrives as `2.0` and must still read as 2.
static func version_of(kind: StringName, data: Dictionary) -> int:
	if current_version(kind) == 0:
		return 0
	var raw: Variant = data.get("schema_version", null)
	if raw is int:
		return maxi(int(raw), 0)
	if raw is float:
		var f := float(raw)
		if is_finite(f) and f == floor(f):
			return maxi(int(f), 0)
	return 0


## Runs the chain from the document's own version up to [method current_version].
static func migrate(kind: StringName, data: Dictionary) -> Result:
	var result := Result.new()
	result.data = JsonStore.Json.deep_copy(data)
	var target := current_version(kind)
	if target == 0:
		result.ok = false
		result.error = "unknown document kind '%s'" % String(kind)
		return result

	var version := version_of(kind, result.data)
	if version > target:
		result.ok = false
		result.error = "%s is version %d, newer than %d" % [String(kind), version, target]
		return result

	while version < target:
		var next := version + 1
		var stepped := _apply_step(String(kind), version, result.data)
		if stepped.is_empty():
			result.ok = false
			result.error = "no migration step for %s:%d->%d" % [String(kind), version, next]
			return result
		result.data = stepped
		result.steps.append("%s:%d->%d" % [String(kind), version, next])
		version = next

	result.data["schema_version"] = target
	result.ok = true
	return result


# ------------------------------------------------------------------ steps (R5)

static func _apply_step(kind: String, from_version: int, data: Dictionary) -> Dictionary:
	match kind:
		"settings":
			if from_version == 0:
				return _settings_0_to_1(data)
			if from_version == 1:
				return _settings_1_to_2(data)
		"plans":
			if from_version == 0:
				return _plans_0_to_1(data)
		"history":
			if from_version == 0:
				return _history_0_to_1(data)
		"session_progress":
			if from_version == 0:
				return _session_progress_0_to_1(data)
	return {}


## 0 → 1: the app before settings existed only had whatever the user had edited in.
## Adds the `llm` block with the DeepSeek defaults plus units/theme/weekly_goal_days/
## onboarding_complete/meta, without clobbering anything already present.
static func _settings_0_to_1(data: Dictionary) -> Dictionary:
	var out := Schema._deep_merge(Schema.v1_defaults(), data)
	out["schema_version"] = 1
	return out


## 1 → 2: adds the nested `rest_timer` block, the remaining `ui.*` keys, `attribution_seen`
## and every LLM key the first pass did not carry (R23: flat rest keys are banned).
static func _settings_1_to_2(data: Dictionary) -> Dictionary:
	var out := Schema._deep_merge(Schema.default_settings(), data)
	out["schema_version"] = 2
	return out


## 0 → 1: wraps a bare plan object into `{active_plan_id, plans: [plan]}` and adds
## `source = "builtin"`, `provider = ""`, `notes = ""`.
##
## A bare JSON *array* cannot reach this step: `JsonStore` rejects a non-object root
## before a version can be read, and R4 quarantines it with `reason = not_object`.
static func _plans_0_to_1(data: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if data.has("plans") or data.has("active_plan_id"):
		out = JsonStore.Json.merge_known({"active_plan_id": "", "plans": []}, data)
	elif data.has("id") or data.has("name") or data.has("sessions"):
		var plan: Dictionary = JsonStore.Json.deep_copy(data)
		plan.erase("schema_version")
		out = {"active_plan_id": String(plan.get("id", "")), "plans": [plan]}
	else:
		out = {"active_plan_id": "", "plans": []}

	var plans: Array = out.get("plans", [])
	for i in plans.size():
		var plan: Variant = plans[i]
		if plan is Dictionary:
			var record: Dictionary = plan
			# R31: whatever the pre-schema app stored, a migrated plan is a built-in plan.
			var had_source := record.has("source") and not String(record["source"]).is_empty()
			var applied := Schema.apply_plan_defaults(record)
			if not had_source:
				applied["source"] = "builtin"
				applied["provider"] = ""
			plans[i] = applied
	out["plans"] = plans
	out["active_plan_id"] = String(out.get("active_plan_id", ""))
	out["schema_version"] = 1
	return out


## 0 → 1: gives a version-less history document its root keys and marks every existing
## entry `completed = true` — before partial sessions existed, a stored entry was a
## finished workout.
static func _history_0_to_1(data: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if data.has("entries"):
		out = JsonStore.Json.merge_known({"entries": []}, data)
	elif data.has("date") or data.has("id"):
		out = {"entries": [JsonStore.Json.deep_copy(data)]}
	else:
		out = {"entries": []}

	var entries: Array = out.get("entries", [])
	for i in entries.size():
		var entry: Variant = entries[i]
		if entry is Dictionary:
			var record: Dictionary = entry
			record["completed"] = true
			entries[i] = record
	out["entries"] = entries
	out["schema_version"] = 1
	return out


## 0 → 1: moves the flat progress fields under the nested `progress` object the appendix
## pins (§5.4, appendix R27) and renames the old flat cursor `index` to `step_index`.
static func _session_progress_0_to_1(data: Dictionary) -> Dictionary:
	var inner: Dictionary = {}
	if data.get("progress") is Dictionary:
		inner = JsonStore.Json.deep_copy(data["progress"])
	else:
		inner = JsonStore.Json.deep_copy(data)
		inner.erase("schema_version")
		inner.erase("progress")
	if inner.has("index") and not inner.has("step_index"):
		inner["step_index"] = inner["index"]
	inner.erase("index")
	inner.erase("completed_sets")
	return {"schema_version": 1, "progress": Schema.apply_progress_defaults(inner)}


## The document shape, its defaults, its allow-lists and its validators.
##
## Two rules make this the single source of truth for stored data:
## - [method apply_*] only *adds* what is missing (never rewrites a present value), so a
##   document written by a newer app keeps its values and its unknown keys;
## - [method clamp_settings] turns anything out of range into a legal value and reports
##   every single fix, so a hand-edited file can never wedge the app.
class Schema extends RefCounted:

	## R7 ranges.
	const UNITS: PackedStringArray = ["lb", "kg"]
	const THEMES: PackedStringArray = ["dark", "light"]
	const LLM_PROVIDERS: PackedStringArray = [
		"openai", "deepseek", "anthropic", "gemini", "openrouter", "groq", "custom",
	]
	const TEXT_SCALES: PackedFloat64Array = [0.85, 1.0, 1.15, 1.3, 1.5]
	## Appendix §6.2 — `general` is not a valid stored key (R32).
	const GOALS: PackedStringArray = ["strength", "hypertrophy", "general_fitness", "conditioning"]
	## Appendix §6.4 — exactly these two, `generator` is banned (R31).
	const SOURCES: PackedStringArray = ["builtin", "llm"]
	const EQUIPMENT_KINDS: PackedStringArray = ["barbell", "machine", "cable", "dumbbell", "bodyweight"]

	const DEFAULT_LLM_BASE_URL := "https://api.deepseek.com/v1"
	const DEFAULT_LLM_MODEL := "deepseek-chat"
	const DEFAULT_TEMPERATURE := 0.4
	const DEFAULT_TIMEOUT_SEC := 45
	const DEFAULT_REST_SECONDS := 90
	const DEFAULT_WEEKLY_GOAL_DAYS := 4
	const DEFAULT_DAYS_PER_WEEK := 4
	const DEFAULT_DURATION_MIN := 40

	## Allow-lists (R12). Unknown keys are preserved on disk but never invented here.
	const SETTINGS_FIELDS: PackedStringArray = [
		"schema_version", "units", "theme", "weekly_goal_days", "onboarding_complete",
		"attribution_seen", "rest_timer", "llm", "ui", "meta",
	]
	const REST_TIMER_FIELDS: PackedStringArray = [
		"enabled", "auto_start", "sound", "haptic", "default_seconds",
	]
	const LLM_FIELDS: PackedStringArray = [
		"provider", "base_url", "model", "api_key", "temperature", "timeout_sec",
		"custom_auth_none", "custom_json_mode", "custom_name", "configured",
		"last_tested_at", "last_test_ok",
	]
	const UI_FIELDS: PackedStringArray = [
		"last_tab", "reduce_motion", "sound_enabled", "haptics_enabled",
		"haptics_unavailable_shown", "text_scale", "wizard_draft",
	]
	const META_FIELDS: PackedStringArray = ["created_at", "updated_at", "app_version"]

	const PLAN_FIELDS: PackedStringArray = [
		"id", "name", "created_at", "source", "provider", "goal", "days_per_week",
		"duration_min", "areas", "equipment", "notes", "split_name", "sessions",
		"generation",
	]
	const SESSION_FIELDS: PackedStringArray = [
		"id", "index", "title", "focus", "est_minutes", "warmup", "blocks", "cooldown",
	]
	const BLOCK_FIELDS: PackedStringArray = ["exercise_id", "sets", "reps", "rest_seconds"]
	const MOBILITY_FIELDS: PackedStringArray = ["exercise_id", "duration_sec"]

	const ENTRY_FIELDS: PackedStringArray = [
		"id", "plan_id", "session_id", "session_title", "date", "started_at",
		"completed_at", "duration_sec", "exercises_completed", "exercises_total",
		"completed", "sets_completed", "sets_total", "focus", "exercise_ids",
	]
	const PROGRESS_FIELDS: PackedStringArray = [
		"plan_id", "session_id", "started_at", "updated_at", "step_index", "elapsed_sec",
		"paused_total_sec", "set_states", "completed_blocks", "rest_remaining_sec",
	]

	# -------------------------------------------------------------- defaults

	## The complete `settings.json` shape — appendix §5.1, which supersedes PRD-03 R7
	## (it adds `attribution_seen`, `ui.text_scale`, `ui.sound_enabled`,
	## `ui.haptics_enabled`, `ui.haptics_unavailable_shown`, `ui.wizard_draft` and the
	## four `llm.custom_*`/`configured` keys; appendix R25).
	static func default_settings() -> Dictionary:
		var now := Dates.now_iso8601(true)
		return {
			"schema_version": Migrations.SETTINGS_CURRENT,
			"units": "lb",
			"theme": "dark",
			"weekly_goal_days": DEFAULT_WEEKLY_GOAL_DAYS,
			"onboarding_complete": false,
			"attribution_seen": false,
			"rest_timer": {
				"enabled": true,
				"auto_start": true,
				"sound": true,
				"haptic": true,
				"default_seconds": DEFAULT_REST_SECONDS,
			},
			"llm": {
				"provider": "deepseek",
				"base_url": DEFAULT_LLM_BASE_URL,
				"model": DEFAULT_LLM_MODEL,
				"api_key": "",
				"temperature": DEFAULT_TEMPERATURE,
				"timeout_sec": DEFAULT_TIMEOUT_SEC,
				"custom_auth_none": false,
				"custom_json_mode": true,
				"custom_name": "",
				"configured": false,
				"last_tested_at": null,
				"last_test_ok": null,
			},
			"ui": {
				"last_tab": 0,
				"reduce_motion": false,
				"sound_enabled": true,
				"haptics_enabled": true,
				"haptics_unavailable_shown": false,
				"text_scale": 1.0,
				"wizard_draft": {},
			},
			"meta": {
				"created_at": now,
				"updated_at": now,
				"app_version": AppInfo.VERSION,
			},
		}

	## The version-1 shape, used only by the migration chain: settings before the nested
	## `rest_timer` block and the extra `ui.*`/`llm.*` keys existed.
	static func v1_defaults() -> Dictionary:
		var now := Dates.now_iso8601(true)
		return {
			"schema_version": 1,
			"units": "lb",
			"theme": "dark",
			"weekly_goal_days": DEFAULT_WEEKLY_GOAL_DAYS,
			"onboarding_complete": false,
			"llm": {
				"provider": "deepseek",
				"base_url": DEFAULT_LLM_BASE_URL,
				"model": DEFAULT_LLM_MODEL,
				"api_key": "",
				"temperature": DEFAULT_TEMPERATURE,
				"timeout_sec": DEFAULT_TIMEOUT_SEC,
				"last_tested_at": null,
				"last_test_ok": null,
			},
			"meta": {
				"created_at": now,
				"updated_at": now,
				"app_version": AppInfo.VERSION,
			},
		}

	static func default_plans() -> Dictionary:
		return {
			"schema_version": Migrations.PLANS_CURRENT,
			"active_plan_id": "",
			"plans": [],
		}

	static func default_history() -> Dictionary:
		return {
			"schema_version": Migrations.HISTORY_CURRENT,
			"entries": [],
		}

	static func default_session_progress() -> Dictionary:
		return {
			"schema_version": Migrations.SESSION_PROGRESS_CURRENT,
			"progress": {},
		}

	## The inner `progress` object `save/load_session_progress()` exchange (appendix §5.4).
	static func default_progress() -> Dictionary:
		var now := Dates.now_iso8601(true)
		return {
			"plan_id": "",
			"session_id": "",
			"started_at": now,
			"updated_at": now,
			"step_index": 0,
			"elapsed_sec": 0,
			"paused_total_sec": 0,
			"set_states": {},
			"completed_blocks": [],
			"rest_remaining_sec": 0,
		}

	# -------------------------------------------------------------- apply defaults

	## Fills in every key the document is missing. Present values (and unknown keys) win.
	static func apply_settings_defaults(data: Dictionary) -> Dictionary:
		var out := _deep_merge(default_settings(), data)
		# `created_at` is written once, on creation, and never rewritten (R7).
		var meta_value: Variant = out.get("meta", null)
		if not (meta_value is Dictionary):
			meta_value = {}
		var meta: Dictionary = meta_value
		if String(meta.get("created_at", "")).is_empty():
			meta["created_at"] = Dates.now_iso8601(true)
		out["meta"] = meta
		return out

	## Fills in the missing scalar fields of one plan, its sessions, blocks and mobility.
	## A key that is absent *or* an empty string takes the appendix §5.2 default — the store
	## owns these fields, so a blank one is a missing one.
	static func apply_plan_defaults(data: Dictionary) -> Dictionary:
		var out := JsonStore.Json.merge_known({}, data)
		out["id"] = _as_string(out.get("id", null), "")
		out["name"] = _filled(out, "name", "")
		out["created_at"] = _filled(out, "created_at", Dates.now_iso8601(true))
		out["source"] = _filled(out, "source", "llm")
		out["provider"] = _filled(out, "provider", "")
		out["goal"] = _filled(out, "goal", "general_fitness")
		out["days_per_week"] = _to_int(out.get("days_per_week", null), DEFAULT_DAYS_PER_WEEK)
		out["duration_min"] = _to_int(out.get("duration_min", null), DEFAULT_DURATION_MIN)
		out["areas"] = _to_string_array(out.get("areas", []))
		out["equipment"] = _to_string_array(out.get("equipment", []))
		out["notes"] = _filled(out, "notes", "")
		out["split_name"] = _filled(out, "split_name", "")
		out["sessions"] = _apply_session_defaults(out.get("sessions", []))
		return out

	static func apply_plans_defaults(data: Dictionary) -> Dictionary:
		var out := _deep_merge(default_plans(), data)
		var plans: Array = out.get("plans", [])
		var applied: Array = []
		for element in plans:
			if element is Dictionary:
				applied.append(apply_plan_defaults(element))
		out["plans"] = applied
		# JSON has no integer type, so a reloaded `"schema_version": 1` arrives as `1.0`;
		# the typed view always carries the integer, and so does the next write.
		out["schema_version"] = Migrations.PLANS_CURRENT
		out["active_plan_id"] = _as_string(out.get("active_plan_id", ""), "")
		# A dangling active pointer must never survive a load.
		if not String(out["active_plan_id"]).is_empty():
			if JsonStore.Json.index_of_id(applied, String(out["active_plan_id"])) < 0:
				out["active_plan_id"] = ""
		return out

	## Fills in the missing fields of one history entry (R9 / appendix §5.3).
	static func apply_entry_defaults(data: Dictionary) -> Dictionary:
		var out := JsonStore.Json.merge_known({}, data)
		out["id"] = _as_string(out.get("id", ""), "")
		out["plan_id"] = _as_string(out.get("plan_id", ""), "")
		out["session_id"] = _as_string(out.get("session_id", ""), "")
		out["session_title"] = _as_string(out.get("session_title", ""), "")
		out["date"] = _as_string(out.get("date", ""), "")
		out["started_at"] = _as_string(out.get("started_at", ""), "")
		out["completed_at"] = _as_string(out.get("completed_at", ""), "")
		out["duration_sec"] = _to_int(out.get("duration_sec", null), 0)
		out["exercises_completed"] = _to_int(out.get("exercises_completed", null), 0)
		out["exercises_total"] = _to_int(out.get("exercises_total", null), 0)
		out["completed"] = _to_bool(out.get("completed", null), false)
		# Additive PRD-10/PRD-11 fields; a missing value reads as its default (R29).
		out["sets_completed"] = _to_int(out.get("sets_completed", null), 0)
		out["sets_total"] = _to_int(out.get("sets_total", null), 0)
		out["focus"] = _to_string_array(out.get("focus", []))
		out["exercise_ids"] = _to_string_array(out.get("exercise_ids", []))
		return out

	## The appendix §5.3 canonical order: `date` ascending, then `started_at` ascending.
	static func sort_entries(entries: Array) -> Array:
		var out := entries.duplicate()
		out.sort_custom(_entry_before)
		return out


	## Fills in the missing root keys, applies per-entry defaults and sorts the entries by
	## `date` ascending, then `started_at` ascending (R9).
	static func apply_history_defaults(data: Dictionary) -> Dictionary:
		var out := _deep_merge(default_history(), data)
		var entries: Array = out.get("entries", [])
		var applied: Array = []
		for element in entries:
			if element is Dictionary:
				applied.append(apply_entry_defaults(element))
		out["entries"] = sort_entries(applied)
		out["schema_version"] = Migrations.HISTORY_CURRENT
		return out

	## The inner progress object of `session_progress.json`.
	static func apply_progress_defaults(data: Dictionary) -> Dictionary:
		if data.is_empty():
			return {}
		var out := _deep_merge(default_progress(), data)
		out["set_states"] = _to_bool_lists(out.get("set_states", {}))
		out["completed_blocks"] = _to_string_array(out.get("completed_blocks", []))
		return out

	# -------------------------------------------------------------- validation

	## Empty array = valid (R12).
	static func validate_settings(data: Dictionary) -> PackedStringArray:
		var errors := PackedStringArray()
		if not UNITS.has(_as_string(data.get("units", null), "")):
			errors.append("settings.units: '%s' is not one of %s" % [str(data.get("units")), UNITS])
		if not THEMES.has(_as_string(data.get("theme", null), "")):
			errors.append("settings.theme: '%s' is not one of %s" % [str(data.get("theme")), THEMES])
		_check_int_range(errors, data, "settings.weekly_goal_days", 1, 7)
		_check_bool(errors, data, "settings.onboarding_complete")
		_check_bool(errors, data, "settings.attribution_seen")

		if not (data.get("rest_timer") is Dictionary):
			errors.append("settings.rest_timer: expected an object")
		else:
			var rest: Dictionary = data["rest_timer"]
			_check_bool(errors, rest, "settings.rest_timer.enabled")
			_check_bool(errors, rest, "settings.rest_timer.auto_start")
			_check_bool(errors, rest, "settings.rest_timer.sound")
			_check_bool(errors, rest, "settings.rest_timer.haptic")
			_check_int_range(errors, rest, "settings.rest_timer.default_seconds", 15, 300)

		if not (data.get("llm") is Dictionary):
			errors.append("settings.llm: expected an object")
		else:
			var llm: Dictionary = data["llm"]
			if not LLM_PROVIDERS.has(_as_string(llm.get("provider", null), "")):
				errors.append("settings.llm.provider: '%s' is not one of %s" % [
					str(llm.get("provider")), LLM_PROVIDERS])
			_check_string(errors, llm, "settings.llm.base_url", 0, 512)
			_check_string(errors, llm, "settings.llm.model", 1, 128)
			_check_string(errors, llm, "settings.llm.api_key", 0, 512)
			_check_float_range(errors, llm, "settings.llm.temperature", 0.0, 2.0)
			_check_int_range(errors, llm, "settings.llm.timeout_sec", 5, 120)
			_check_bool(errors, llm, "settings.llm.custom_auth_none")
			_check_bool(errors, llm, "settings.llm.custom_json_mode")
			_check_string(errors, llm, "settings.llm.custom_name", 0, 128)
			_check_bool(errors, llm, "settings.llm.configured")
			_check_nullable_string(errors, llm, "settings.llm.last_tested_at")
			_check_nullable_bool(errors, llm, "settings.llm.last_test_ok")

		if not (data.get("ui") is Dictionary):
			errors.append("settings.ui: expected an object")
		else:
			var ui: Dictionary = data["ui"]
			_check_int_range(errors, ui, "settings.ui.last_tab", 0, 3)
			_check_bool(errors, ui, "settings.ui.reduce_motion")
			_check_bool(errors, ui, "settings.ui.sound_enabled")
			_check_bool(errors, ui, "settings.ui.haptics_enabled")
			_check_bool(errors, ui, "settings.ui.haptics_unavailable_shown")
			if not _is_text_scale(ui.get("text_scale", null)):
				errors.append("settings.ui.text_scale: '%s' is not one of %s" % [
					str(ui.get("text_scale")), TEXT_SCALES])
			if not (ui.get("wizard_draft") is Dictionary):
				errors.append("settings.ui.wizard_draft: expected an object")

		if not (data.get("meta") is Dictionary):
			errors.append("settings.meta: expected an object")
		else:
			var meta: Dictionary = data["meta"]
			_check_string(errors, meta, "settings.meta.created_at", 1, 64)
			_check_string(errors, meta, "settings.meta.updated_at", 1, 64)
			_check_string(errors, meta, "settings.meta.app_version", 1, 32)
		return errors

	## Empty array = valid. Checks the appendix §5.2 rules PRD-05 will rely on.
	static func validate_plan(data: Dictionary) -> PackedStringArray:
		var errors := PackedStringArray()
		if _as_string(data.get("id", null), "").is_empty():
			errors.append("plan.id: required")
		if _as_string(data.get("name", null), "").is_empty():
			errors.append("plan.name: required")
		if _as_string(data.get("created_at", null), "").is_empty():
			errors.append("plan.created_at: required")
		if not SOURCES.has(_as_string(data.get("source", null), "")):
			errors.append("plan.source: '%s' is not one of %s" % [str(data.get("source")), SOURCES])
		if not GOALS.has(_as_string(data.get("goal", null), "")):
			errors.append("plan.goal: '%s' is not one of %s" % [str(data.get("goal")), GOALS])
		_check_int_range(errors, data, "plan.days_per_week", 1, 6)
		_check_int_range(errors, data, "plan.duration_min", 10, 120)
		if _to_string_array(data.get("areas", [])).is_empty():
			errors.append("plan.areas: at least one area is required")
		if _to_string_array(data.get("equipment", [])).is_empty():
			errors.append("plan.equipment: at least one equipment kind is required")

		var sessions: Array = data.get("sessions", []) if data.get("sessions") is Array else []
		if sessions.is_empty():
			errors.append("plan.sessions: at least one session is required")
		var seen_indexes := {}
		for element in sessions:
			if not (element is Dictionary):
				errors.append("plan.sessions: every session must be an object")
				continue
			var session: Dictionary = element
			if _as_string(session.get("id", null), "").is_empty():
				errors.append("plan.sessions[].id: required")
			var index := _to_int(session.get("index", null), -1)
			if index < 0 or seen_indexes.has(index):
				errors.append("plan.sessions[].index: '%s' is missing or duplicated" % str(index))
			seen_indexes[index] = true
			if _as_string(session.get("title", null), "").length() > 60:
				errors.append("plan.sessions[].title: longer than 60 characters")
			if _to_string_array(session.get("focus", [])).is_empty():
				errors.append("plan.sessions[].focus: at least one area is required")
			_check_int_range(errors, session, "plan.sessions[].est_minutes", 1, 180)
			var blocks: Array = session.get("blocks", []) if session.get("blocks") is Array else []
			if blocks.is_empty() or blocks.size() > 12:
				errors.append("plan.sessions[].blocks: expected 1..12 blocks")
			for block_element in blocks:
				if not (block_element is Dictionary):
					errors.append("plan.sessions[].blocks: every block must be an object")
					continue
				var block: Dictionary = block_element
				if _as_string(block.get("exercise_id", null), "").is_empty():
					errors.append("plan.sessions[].blocks[].exercise_id: required")
				_check_int_range(errors, block, "plan.sessions[].blocks[].sets", 1, 8)
				_check_int_range(errors, block, "plan.sessions[].blocks[].rest_seconds", 15, 300)
				if not is_valid_reps(_as_string(block.get("reps", null), "")):
					errors.append("plan.sessions[].blocks[].reps: '%s' is not a valid rep scheme" % str(
						block.get("reps")))
			for key in ["warmup", "cooldown"]:
				var items: Array = session.get(key, []) if session.get(key) is Array else []
				for item_element in items:
					if not (item_element is Dictionary):
						continue
					var item: Dictionary = item_element
					if _as_string(item.get("exercise_id", null), "").is_empty():
						errors.append("plan.sessions[].%s[].exercise_id: required" % key)
					_check_int_range(errors, item, "plan.sessions[].%s[].duration_sec" % key, 20, 180)

		if sessions.size() != _to_int(data.get("days_per_week", null), -1):
			errors.append("plan.sessions: size does not match days_per_week")
		return errors

	## Empty array = valid. `date` is the only field the streak math depends on.
	static func validate_entry(data: Dictionary) -> PackedStringArray:
		var errors := PackedStringArray()
		if _as_string(data.get("id", null), "").is_empty():
			errors.append("entry.id: required")
		if not Dates.is_valid_iso_date(_as_string(data.get("date", null), "")):
			errors.append("entry.date: '%s' is not a YYYY-MM-DD date" % str(data.get("date")))
		if not Dates.is_valid_iso_datetime(_as_string(data.get("started_at", null), "")):
			errors.append("entry.started_at: '%s' is not an ISO-8601 timestamp" % str(
				data.get("started_at")))
		var completed_at := _as_string(data.get("completed_at", null), "")
		if not completed_at.is_empty() and not Dates.is_valid_iso_datetime(completed_at):
			errors.append("entry.completed_at: '%s' is not an ISO-8601 timestamp" % completed_at)
		_check_int_range(errors, data, "entry.duration_sec", 0, 604800)
		_check_int_range(errors, data, "entry.exercises_completed", 0, 99)
		_check_int_range(errors, data, "entry.exercises_total", 0, 99)
		_check_bool(errors, data, "entry.completed")
		return errors

	## PRD-05 owns the plan validator; the store only needs to know whether a rep scheme
	## is one of appendix §7.3's three forms.
	static func is_valid_reps(reps: String) -> bool:
		if reps.ends_with("s"):
			var digits := reps.substr(0, reps.length() - 1)
			if digits.length() < 2 or digits.length() > 3 or not _all_digits(digits):
				return false
			var seconds := int(digits)
			return seconds >= 10 and seconds <= 300
		if reps.contains("-"):
			var parts := reps.split("-", false)
			if parts.size() != 2:
				return false
			if not _is_rep_count(parts[0]) or not _is_rep_count(parts[1]):
				return false
			return int(parts[0]) < int(parts[1])
		return _is_rep_count(reps)

	# -------------------------------------------------------------- clamping (R7)

	## Returns `[fixed_dictionary, clamps]`. Every entry of `clamps` is one line of the
	## `[store] clamped settings.<path> <old> -> <new>` log, so the owner can see exactly
	## what a hand-edited or downgraded file lost.
	static func clamp_settings(data: Dictionary) -> Array:
		var clamps := PackedStringArray()
		var out := apply_settings_defaults(data)

		if not UNITS.has(_as_string(out.get("units", null), "")):
			clamps.append(_clamp_line("settings.units", out.get("units"), "lb"))
			out["units"] = "lb"
		if not THEMES.has(_as_string(out.get("theme", null), "")):
			clamps.append(_clamp_line("settings.theme", out.get("theme"), "dark"))
			out["theme"] = "dark"
		out["weekly_goal_days"] = _clamp_int(clamps, "settings.weekly_goal_days",
			out.get("weekly_goal_days"), 1, 7, DEFAULT_WEEKLY_GOAL_DAYS)
		out["onboarding_complete"] = _clamp_bool(clamps, "settings.onboarding_complete",
			out.get("onboarding_complete"))
		out["attribution_seen"] = _clamp_bool(clamps, "settings.attribution_seen",
			out.get("attribution_seen"))

		var rest_value: Variant = out.get("rest_timer", null)
		if not (rest_value is Dictionary):
			clamps.append(_clamp_line("settings.rest_timer", rest_value, "object"))
			rest_value = default_settings()["rest_timer"]
		var rest: Dictionary = _deep_merge(default_settings()["rest_timer"], rest_value)
		rest["enabled"] = _clamp_bool(clamps, "settings.rest_timer.enabled", rest.get("enabled"))
		rest["auto_start"] = _clamp_bool(clamps, "settings.rest_timer.auto_start",
			rest.get("auto_start"))
		rest["sound"] = _clamp_bool(clamps, "settings.rest_timer.sound", rest.get("sound"))
		rest["haptic"] = _clamp_bool(clamps, "settings.rest_timer.haptic", rest.get("haptic"))
		rest["default_seconds"] = _clamp_int(clamps, "settings.rest_timer.default_seconds",
			rest.get("default_seconds"), 15, 300, DEFAULT_REST_SECONDS)
		out["rest_timer"] = rest

		var llm_value: Variant = out.get("llm", null)
		if not (llm_value is Dictionary):
			clamps.append(_clamp_line("settings.llm", llm_value, "object"))
			llm_value = default_settings()["llm"]
		var llm: Dictionary = _deep_merge(default_settings()["llm"], llm_value)
		if not LLM_PROVIDERS.has(_as_string(llm.get("provider", null), "")):
			clamps.append(_clamp_line("settings.llm.provider", llm.get("provider"), "deepseek"))
			llm["provider"] = "deepseek"
		llm["base_url"] = _clamp_string(clamps, "settings.llm.base_url", llm.get("base_url"),
			DEFAULT_LLM_BASE_URL)
		llm["model"] = _clamp_string(clamps, "settings.llm.model", llm.get("model"),
			DEFAULT_LLM_MODEL)
		# The API key is never logged — not even its length (R7/R21).
		llm["api_key"] = _as_string(llm.get("api_key", null), "")
		llm["temperature"] = _clamp_float(clamps, "settings.llm.temperature",
			llm.get("temperature"), 0.0, 2.0, DEFAULT_TEMPERATURE)
		llm["timeout_sec"] = _clamp_int(clamps, "settings.llm.timeout_sec", llm.get("timeout_sec"),
			5, 120, DEFAULT_TIMEOUT_SEC)
		llm["custom_auth_none"] = _clamp_bool(clamps, "settings.llm.custom_auth_none",
			llm.get("custom_auth_none"))
		llm["custom_json_mode"] = _clamp_bool(clamps, "settings.llm.custom_json_mode",
			llm.get("custom_json_mode"))
		llm["custom_name"] = _clamp_string(clamps, "settings.llm.custom_name",
			llm.get("custom_name"), "")
		llm["configured"] = _clamp_bool(clamps, "settings.llm.configured", llm.get("configured"))
		# Nullable fields: `null` is a legal value, so only a wrong type is a clamp.
		var tested: Variant = llm.get("last_tested_at", null)
		if tested != null and not (tested is String):
			clamps.append(_clamp_line("settings.llm.last_tested_at", tested, "null"))
			tested = null
		llm["last_tested_at"] = tested
		var tested_ok: Variant = llm.get("last_test_ok", null)
		if tested_ok != null and not (tested_ok is bool):
			clamps.append(_clamp_line("settings.llm.last_test_ok", tested_ok, "null"))
			tested_ok = null
		llm["last_test_ok"] = tested_ok
		out["llm"] = llm

		var ui_value: Variant = out.get("ui", null)
		if not (ui_value is Dictionary):
			clamps.append(_clamp_line("settings.ui", ui_value, "object"))
			ui_value = default_settings()["ui"]
		var ui: Dictionary = _deep_merge(default_settings()["ui"], ui_value)
		ui["last_tab"] = _clamp_int(clamps, "settings.ui.last_tab", ui.get("last_tab"), 0, 3, 0)
		ui["reduce_motion"] = _clamp_bool(clamps, "settings.ui.reduce_motion", ui.get("reduce_motion"))
		ui["sound_enabled"] = _clamp_bool(clamps, "settings.ui.sound_enabled", ui.get("sound_enabled"))
		ui["haptics_enabled"] = _clamp_bool(clamps, "settings.ui.haptics_enabled",
			ui.get("haptics_enabled"))
		ui["haptics_unavailable_shown"] = _clamp_bool(clamps,
			"settings.ui.haptics_unavailable_shown", ui.get("haptics_unavailable_shown"))
		if not _is_text_scale(ui.get("text_scale", null)):
			var fixed := _nearest_text_scale(ui.get("text_scale", null))
			clamps.append(_clamp_line("settings.ui.text_scale", ui.get("text_scale"), str(fixed)))
			ui["text_scale"] = fixed
		if not (ui.get("wizard_draft") is Dictionary):
			clamps.append(_clamp_line("settings.ui.wizard_draft", ui.get("wizard_draft"), "object"))
			ui["wizard_draft"] = {}
		out["ui"] = ui

		var meta_value: Variant = out.get("meta", null)
		if not (meta_value is Dictionary):
			clamps.append(_clamp_line("settings.meta", meta_value, "object"))
			meta_value = default_settings()["meta"]
		var meta: Dictionary = _deep_merge(default_settings()["meta"], meta_value)
		var created := _as_string(meta.get("created_at", null), "")
		if created.is_empty():
			clamps.append(_clamp_line("settings.meta.created_at", meta.get("created_at"),
				"timestamp"))
			meta["created_at"] = Dates.now_iso8601(true)
		if _as_string(meta.get("updated_at", null), "").is_empty():
			meta["updated_at"] = meta["created_at"]
		meta["app_version"] = _as_string(meta.get("app_version", null), AppInfo.VERSION)
		out["meta"] = meta

		out["schema_version"] = Migrations.SETTINGS_CURRENT
		return [out, clamps]

	# -------------------------------------------------------------- coercion helpers

	## Public wrapper around [method _to_int] for callers outside this class (the store
	## reads `days_per_week` and `weekly_goal_days` out of live documents).
	static func as_int(value: Variant, fallback: int) -> int:
		return _to_int(value, fallback)

	static func _deep_merge(base: Dictionary, over: Dictionary) -> Dictionary:
		var out: Dictionary = JsonStore.Json.deep_copy(base)
		for key in over:
			var value: Variant = over[key]
			var current: Variant = out.get(key, null)
			if current is Dictionary and value is Dictionary:
				out[key] = _deep_merge(current, value)
			else:
				out[key] = JsonStore.Json.deep_copy(value)
		return out

	static func _to_int(value: Variant, fallback: int) -> int:
		if value is int:
			return int(value)
		if value is float:
			var f := float(value)
			if is_finite(f) and f == floor(f):
				return int(f)
		return fallback

	static func _to_bool(value: Variant, fallback: bool) -> bool:
		return bool(value) if value is bool else fallback

	static func _as_string(value: Variant, fallback: String) -> String:
		return String(value) if value is String else fallback


	## [param fallback] when the key is absent, the wrong type or an empty string.
	static func _filled(data: Dictionary, key: String, fallback: String) -> String:
		var value: Variant = data.get(key, null)
		if value is String and (not String(value).is_empty() or fallback.is_empty()):
			return String(value)
		return fallback

	static func _to_string_array(value: Variant) -> Array:
		var out: Array = []
		if value is Array:
			for element in value:
				if element is String:
					out.append(element)
		return out

	## `exercise_id -> [bool, …]` for PRD-10's set states.
	static func _to_bool_lists(value: Variant) -> Dictionary:
		var out: Dictionary = {}
		if not (value is Dictionary):
			return out
		for key in value:
			var flags: Array = []
			var raw: Variant = value[key]
			if raw is Array:
				for element in raw:
					flags.append(bool(element) if element is bool else false)
			out[String(key)] = flags
		return out

	## `{"y","m","d"}` sorting for history entries: date ascending, then started_at.
	static func _entry_before(a: Variant, b: Variant) -> bool:
		var left: Dictionary = a
		var right: Dictionary = b
		var left_date := String(left.get("date", ""))
		var right_date := String(right.get("date", ""))
		if left_date != right_date:
			return left_date < right_date
		return String(left.get("started_at", "")) < String(right.get("started_at", ""))

	static func _is_rep_count(text: String) -> bool:
		if text.length() < 1 or text.length() > 2 or not _all_digits(text):
			return false
		var count := int(text)
		return count >= 1 and count <= 30

	static func _all_digits(text: String) -> bool:
		if text.is_empty():
			return false
		for i in text.length():
			var c := text[i]
			if c < "0" or c > "9":
				return false
		return true

	static func _is_text_scale(value: Variant) -> bool:
		if not (value is float or value is int):
			return false
		var f := float(value)
		for scale in TEXT_SCALES:
			if is_equal_approx(float(scale), f):
				return true
		return false

	static func _nearest_text_scale(value: Variant) -> float:
		if not (value is float or value is int):
			return 1.0
		var f := float(value)
		var best := 1.0
		var best_distance := INF
		for scale in TEXT_SCALES:
			var distance := absf(float(scale) - f)
			if distance < best_distance:
				best_distance = distance
				best = float(scale)
		return best

	static func _apply_session_defaults(value: Variant) -> Array:
		var out: Array = []
		if not (value is Array):
			return out
		for element in value:
			if not (element is Dictionary):
				continue
			var session: Dictionary = JsonStore.Json.merge_known({}, element)
			session["id"] = _as_string(session.get("id", ""), "")
			session["index"] = _to_int(session.get("index", null), out.size())
			session["title"] = _as_string(session.get("title", ""), "")
			session["focus"] = _to_string_array(session.get("focus", []))
			session["est_minutes"] = _to_int(session.get("est_minutes", null), 0)
			session["warmup"] = _apply_mobility_defaults(session.get("warmup", []))
			session["blocks"] = _apply_block_defaults(session.get("blocks", []))
			session["cooldown"] = _apply_mobility_defaults(session.get("cooldown", []))
			out.append(session)
		return out

	static func _apply_block_defaults(value: Variant) -> Array:
		var out: Array = []
		if not (value is Array):
			return out
		for element in value:
			if not (element is Dictionary):
				continue
			var block: Dictionary = JsonStore.Json.merge_known({}, element)
			block["exercise_id"] = _as_string(block.get("exercise_id", ""), "")
			block["sets"] = _to_int(block.get("sets", null), 0)
			block["reps"] = _as_string(block.get("reps", ""), "")
			block["rest_seconds"] = _to_int(block.get("rest_seconds", null), 0)
			out.append(block)
		return out

	static func _apply_mobility_defaults(value: Variant) -> Array:
		var out: Array = []
		if not (value is Array):
			return out
		for element in value:
			if not (element is Dictionary):
				continue
			var item: Dictionary = JsonStore.Json.merge_known({}, element)
			item["exercise_id"] = _as_string(item.get("exercise_id", ""), "")
			item["duration_sec"] = _to_int(item.get("duration_sec", null), 0)
			out.append(item)
		return out

	# -------------------------------------------------------------- clamp reporting

	static func _clamp_line(path: String, old_value: Variant, new_value: String) -> String:
		return "%s %s -> %s" % [path, str(old_value), new_value]

	static func _clamp_int(clamps: PackedStringArray, path: String, value: Variant, low: int,
			high: int, fallback: int) -> int:
		var number := _to_int(value, fallback)
		var clamped := clampi(number, low, high)
		if number != clamped or not (value is int or value is float):
			clamps.append(_clamp_line(path, value, str(clamped)))
		return clamped

	static func _clamp_float(clamps: PackedStringArray, path: String, value: Variant, low: float,
			high: float, fallback: float) -> float:
		var number := fallback
		if value is float or value is int:
			number = float(value)
		var clamped := clampf(number, low, high)
		if not is_equal_approx(number, clamped) or not (value is float or value is int):
			clamps.append(_clamp_line(path, value, str(clamped)))
		return clamped

	static func _clamp_bool(clamps: PackedStringArray, path: String, value: Variant) -> bool:
		if value is bool:
			return bool(value)
		clamps.append(_clamp_line(path, value, "false"))
		return false

	static func _clamp_string(clamps: PackedStringArray, path: String, value: Variant,
			fallback: String) -> String:
		# An empty string is a legitimate value for a free-text field (`custom_name`), but
		# not for one with a real default (`model`), which must not end up blank on disk.
		if value is String and (not String(value).is_empty() or fallback.is_empty()):
			return String(value)
		clamps.append(_clamp_line(path, value, fallback))
		return fallback

	# -------------------------------------------------------------- validation helpers

	static func _check_bool(errors: PackedStringArray, data: Dictionary, path: String) -> void:
		var leaf := path.get_slice(".", path.get_slice_count(".") - 1)
		if not (data.get(leaf, null) is bool):
			errors.append("%s: expected a boolean" % path)

	static func _check_string(errors: PackedStringArray, data: Dictionary, path: String, min_len: int,
			max_len: int) -> void:
		var leaf := path.get_slice(".", path.get_slice_count(".") - 1)
		var value: Variant = data.get(leaf, null)
		if not (value is String):
			errors.append("%s: expected a string" % path)
			return
		var text := String(value)
		if text.length() < min_len or text.length() > max_len:
			errors.append("%s: length %d is outside %d..%d" % [path, text.length(), min_len, max_len])

	static func _check_nullable_string(errors: PackedStringArray, data: Dictionary,
			path: String) -> void:
		var leaf := path.get_slice(".", path.get_slice_count(".") - 1)
		var value: Variant = data.get(leaf, null)
		if value != null and not (value is String):
			errors.append("%s: expected a string or null" % path)

	static func _check_nullable_bool(errors: PackedStringArray, data: Dictionary,
			path: String) -> void:
		var leaf := path.get_slice(".", path.get_slice_count(".") - 1)
		var value: Variant = data.get(leaf, null)
		if value != null and not (value is bool):
			errors.append("%s: expected a boolean or null" % path)

	static func _check_int_range(errors: PackedStringArray, data: Dictionary, path: String, low: int,
			high: int) -> void:
		var leaf := path.get_slice(".", path.get_slice_count(".") - 1)
		var value: Variant = data.get(leaf, null)
		if not (value is int or value is float):
			errors.append("%s: expected an integer" % path)
			return
		var number := _to_int(value, low - 1)
		if number < low or number > high:
			errors.append("%s: %d is outside %d..%d" % [path, number, low, high])

	static func _check_float_range(errors: PackedStringArray, data: Dictionary, path: String,
			low: float, high: float) -> void:
		var leaf := path.get_slice(".", path.get_slice_count(".") - 1)
		var value: Variant = data.get(leaf, null)
		if not (value is int or value is float):
			errors.append("%s: expected a number" % path)
			return
		var number := float(value)
		if number < low or number > high:
			errors.append("%s: %s is outside %s..%s" % [path, str(number), str(low), str(high)])
