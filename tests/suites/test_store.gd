extends TestSuite
## PRD-03 — the data layer, exercised end to end against a real filesystem.
##
## Every test points the store at a directory under `res://.test_tmp/` (ADR-04): `user://`
## is read-only on this machine, and a suite must never touch the developer's real app
## data. The helper creates that directory (and the `.gdignore` that keeps Godot's importer
## out of it) before each test, so `Store.set_io_root_for_tests()` is always called before
## `load_all()` — R17.
##
## The suite instantiates the `Store` autoload script directly instead of using the
## singleton, because suites run under `--script`, where autoloads are constructed only
## after `SceneTree._initialize()` returns.

const STORE_SCRIPT := "res://scripts/autoload/store.gd"
const TMP_ROOT := "res://.test_tmp/"
const SUITE_DIR := "res://.test_tmp/store/"


## Counts what a store signalled, so the suite can assert on the event stream (R11).
class Probe extends RefCounted:
	var events: Array[String] = []

	func record(text: String) -> void:
		events.append(text)

	func count_of(prefix: String) -> int:
		var total := 0
		for event in events:
			if event.begins_with(prefix):
				total += 1
		return total

	func has(prefix: String) -> bool:
		return count_of(prefix) > 0


func _init() -> void:
	suite_name = "store"


func run() -> void:
	_write_gdignore()
	_test_first_run_and_paths()
	_test_roundtrip_and_backup()
	_test_debounce_and_forced_flush()
	_test_settings_api()
	_test_unknown_fields()
	_test_clamping()
	_test_migration()
	_test_future_version()
	_test_corruption_recovery()
	_test_quarantine_retention()
	_test_session_progress()
	_test_history_api()
	_test_malformed_history_entry()
	_test_plans_api()
	_test_export_import_and_reset()
	_test_weekly_goal_precedence()
	_cleanup()


# ------------------------------------------------------------------ R1: paths, first run

func _test_first_run_and_paths() -> void:
	begin("first run creates the durable documents and nothing else")
	var dir := SUITE_DIR + "first_run/"
	var store := _store_for(dir, null)

	assert_true(store.is_loaded(), "store reports loaded after load_all()")
	assert_false(store.is_dirty(), "a freshly created store has nothing pending")
	assert_true(store.storage_dir().ends_with("/"), "storage_dir() ends with a slash")
	assert_eq(store.storage_dir(), dir, "storage_dir() is the injected root")
	assert_eq(store.file_path("settings"), dir + "settings.json", "file_path joins the root")
	assert_eq(store.file_path("session_progress"), dir + "session_progress.json", "fourth doc")

	assert_eq(store.settings().get("schema_version", 0), 3, "settings schema_version is 3")
	assert_eq(store.settings().get("units", ""), "lb", "default units")
	assert_eq(store.settings().get("theme", ""), "dark", "default theme")
	assert_eq(store.settings().get("weekly_goal_days", 0), 4, "default weekly goal")
	assert_eq(store.settings().get("onboarding_complete", true), false, "onboarding starts off")
	assert_eq(store.get_setting("rest_timer.default_seconds", 0), 90, "default rest seconds")
	assert_eq(store.get_setting("llm.provider", ""), "deepseek", "default LLM provider")
	assert_eq(store.get_setting("llm.api_key", "x"), "", "default API key is empty")
	assert_eq(store.get_setting("llm.last_tested_at", "x"), null, "last_tested_at is null")
	assert_eq(store.get_setting("ui.last_tab", -1), 0, "default last tab")
	assert_true(not String(store.get_setting("meta.created_at", "")).is_empty(),
		"meta.created_at is stamped")
	assert_true(String(store.get_setting("meta.created_at", "")).ends_with("Z"),
		"meta.created_at is UTC")

	assert_eq(store.all_plans().size(), 0, "no plans on a first run")
	assert_eq(store.all_entries().size(), 0, "no history on a first run")
	assert_eq(store.active_plan_id(), "", "no active plan on a first run")

	begin("the three durable files exist, session_progress does not")
	assert_gt(_file_size(dir, "settings.json"), 0.0, "settings.json is written on first run")
	assert_gt(_file_size(dir, "plans.json"), 0.0, "plans.json is written on first run")
	assert_gt(_file_size(dir, "history.json"), 0.0, "history.json is written on first run")
	assert_false(FileAccess.file_exists(dir + "session_progress.json"),
		"session_progress.json appears only when a workout starts")
	assert_true(FileAccess.file_exists(dir + "settings.json.bak") == false,
		"a first write has no previous revision to back up")

	begin("the on-disk document is the documented v3 shape")
	var document := _read_json(dir, "settings.json")
	assert_eq(document.get("schema_version", 0), 3, "on-disk schema_version")
	assert_eq(document.get("units", ""), "lb", "on-disk units")
	assert_true(document.has("attribution_seen"), "appendix §5.1 key present")
	assert_true(document.has("rest_timer"), "nested rest_timer block present")
	assert_true(document.has("llm"), "llm block present")
	assert_true(document.has("ui"), "ui block present")
	assert_true(document.has("meta"), "meta block present")
	assert_true((document.get("rest_timer", {}) as Dictionary).has("default_seconds"),
		"rest_timer is nested, never flat")

	begin("now_iso()/today_local_iso() shapes and usage accounting")
	var stamp: String = store.now_iso()
	assert_eq(stamp.length(), 20, "now_iso() is 20 characters")
	assert_true(stamp.ends_with("Z"), "now_iso() is UTC")
	assert_eq(stamp[10], "T", "now_iso() separates date and time with T")
	assert_true(Dates.is_valid_iso_date(store.today_local_iso()), "today_local_iso() is a date")
	assert_gt(float(store.data_dir_usage_bytes()), 0.0, "usage counts the created files")
	var breakdown: Dictionary = store.data_dir_breakdown()
	assert_true(breakdown.has("settings") and breakdown.has("backups") and breakdown.has("total"),
		"breakdown reports per-document bytes, backups and a total")

	begin("a second load on the same root is stable and is not a first run")
	var probe := Probe.new()
	var second := _open(dir, probe)
	assert_false(probe.has("data_loaded:true"), "an existing store is not a first run")
	assert_eq(second.settings().get("units", ""), "lb", "reload keeps the defaults")
	_free(store, second)

	begin("the test helper kept Godot's importer out of the temp tree")
	assert_true(FileAccess.file_exists(TMP_ROOT + ".gdignore"), "res://.test_tmp/.gdignore exists")


# ------------------------------------------------------------------ R2/R4: write, .bak, quarantine

func _test_roundtrip_and_backup() -> void:
	begin("write, flush and a fresh store read back identical views")
	var dir := SUITE_DIR + "roundtrip/"
	var store := _store_for(dir, null)
	assert_true(store.set_setting("units", "kg"), "units kg accepted")
	assert_true(store.add_entry(_entry(store.today_local_iso(), true)) != "", "entry stored")
	assert_true(store.upsert_plan(_plan("plan-1758000000", "Roundtrip")), "plan stored")
	assert_true(store.flush(), "flush reports success")
	assert_false(store.is_dirty(), "flush clears every dirty flag")

	var reloaded := _open(dir)
	assert_eq(_fingerprint(reloaded.settings()), _fingerprint(store.settings()),
		"settings survive a round trip")
	assert_eq(_fingerprint(reloaded.plans_doc()), _fingerprint(store.plans_doc()),
		"plans survive a round trip")
	assert_eq(_fingerprint(reloaded.history_doc()), _fingerprint(store.history_doc()),
		"history survives a round trip")
	assert_eq(reloaded.all_entries().size(), 1, "the entry is on disk")

	begin("the on-disk text is sorted, tab-indented JSON with a trailing newline")
	var text := _read_raw(dir, "settings.json")
	assert_true(JSON.parse_string(text) is Dictionary, "on-disk settings parse as JSON")
	assert_true(text.ends_with("\n"), "documents end with a newline")
	assert_true(text.contains("\n\t\""), "documents are tab-indented")
	assert_true(text.find("\"attribution_seen\"") < text.find("\"units\""),
		"keys are written sorted")

	begin("no .tmp sibling survives a successful flush")
	assert_false(_has_tmp(dir), "no *.tmp file remains")

	begin("the backup holds the previous revision, taken before the replace")
	assert_true(store.set_setting("theme", "light"), "theme light accepted")
	assert_true(store.flush(), "second flush succeeds")
	var backup := _read_json(dir, "settings.json.bak")
	var live := _read_json(dir, "settings.json")
	assert_eq(backup.get("units", ""), "kg", "the backup keeps the previous units value")
	assert_eq(backup.get("theme", ""), "dark", "the backup keeps the previous theme")
	assert_eq(live.get("theme", ""), "light", "the live file has the new value")
	assert_eq(live.get("units", ""), "kg", "unchanged values are carried forward")

	begin("save_settings() force-writes without waiting for the debounce")
	assert_true(store.set_setting("units", "lb"), "units lb accepted")
	assert_true(store.save_settings(), "save_settings() writes now")
	assert_eq(_read_json(dir, "settings.json").get("units", ""), "lb", "the file is current")
	assert_false(store.is_dirty(), "save_settings() clears the dirty flag")
	_free(store, reloaded)


# ------------------------------------------------------------------ R3: debounce, forced flush

func _test_debounce_and_forced_flush() -> void:
	begin("a mutation marks the document dirty and updates the view before the write")
	var dir := SUITE_DIR + "debounce/"
	var store := _store_for(dir, null)
	assert_true(store.set_setting("units", "kg"), "units kg accepted")
	assert_true(store.is_dirty(), "the settings document is pending")
	assert_eq(store.settings().get("units", ""), "kg", "the view is newest immediately")
	assert_eq(_read_json(dir, "settings.json").get("units", ""), "lb",
		"the file still holds the previous revision until the timer fires")

	begin("one one-shot timer per document, 400 ms")
	var timers: Array[Timer] = []
	for timer_name in ["SettingsTimer", "PlansTimer", "HistoryTimer", "SessionProgressTimer"]:
		var timer := store.get_node_or_null(NodePath(timer_name)) as Timer
		assert_true(timer != null, "timer %s exists" % timer_name)
		if timer != null:
			assert_true(timer.one_shot, "%s is one-shot" % timer_name)
			assert_close(timer.wait_time, 0.4, 0.0001, "%s waits DEBOUNCE_SEC" % timer_name)
			timers.append(timer)

	begin("the debounce timeout performs the write")
	var settings_timer := store.get_node_or_null(^"SettingsTimer") as Timer
	settings_timer.emit_signal("timeout")
	assert_false(store.is_dirty(), "the timeout flushed the settings document")
	assert_eq(_read_json(dir, "settings.json").get("units", ""), "kg", "the file caught up")

	begin("every forced-flush notification writes synchronously (R3)")
	var constants: PackedInt32Array = [
		Node.NOTIFICATION_APPLICATION_PAUSED,
		Node.NOTIFICATION_APPLICATION_FOCUS_OUT,
		Node.NOTIFICATION_WM_GO_BACK_REQUEST,
		Node.NOTIFICATION_WM_CLOSE_REQUEST,
	]
	var index := 0
	for what in constants:
		index += 1
		var units := "kg" if index % 2 == 0 else "lb"
		assert_true(store.set_setting("units", units), "mutation %d accepted" % index)
		assert_true(store.is_dirty(), "mutation %d is pending" % index)
		store.notification(what)
		assert_false(store.is_dirty(), "notification %d flushed" % index)
		assert_eq(_read_json(dir, "settings.json").get("units", ""), units,
			"notification %d wrote the newest value" % index)
	_free(store)


# ------------------------------------------------------------------ R7/R10: settings API

func _test_settings_api() -> void:
	begin("get_setting walks dotted paths and honours the default")
	var dir := SUITE_DIR + "settings_api/"
	var store := _store_for(dir, null)
	assert_eq(store.get_setting("llm.model", ""), "deepseek-chat", "nested read")
	assert_eq(store.get_setting("nope.nope", "fallback"), "fallback", "unknown path default")
	assert_eq(store.get_setting("llm", {}) is Dictionary, true, "a section reads as an object")

	begin("valid writes are accepted and signal exactly once")
	var probe := Probe.new()
	_attach(store, probe)
	assert_true(store.set_setting("units", "kg"), "units kg accepted")
	assert_eq(store.settings().get("units", ""), "kg", "the view changed")
	assert_eq(probe.count_of("settings_changed"), 1, "one settings_changed signal")

	begin("unknown sections and out-of-range values are refused (R10)")
	assert_false(store.set_setting("nope", 1), "unknown top-level key refused")
	assert_false(store.set_setting("llm.nope", 1), "unknown nested key refused")
	assert_false(store.set_setting("units", "stone"), "units enum enforced")
	assert_false(store.set_setting("theme", "sepia"), "theme enum enforced")
	assert_false(store.set_setting("weekly_goal_days", 9), "weekly goal upper bound")
	assert_false(store.set_setting("weekly_goal_days", 0), "weekly goal lower bound")
	assert_false(store.set_setting("ui.text_scale", 2.0), "text scale membership")
	assert_false(store.set_setting("rest_timer.default_seconds", 5), "rest lower bound")
	assert_false(store.set_setting("llm.timeout_sec", 400), "timeout upper bound")
	assert_false(store.set_setting("llm.temperature", 3.0), "temperature upper bound")
	assert_false(store.set_setting("llm.last_test_ok", "yes"), "nullable bool enforced")
	assert_eq(store.settings().get("units", ""), "kg", "a refused write leaves the document alone")
	assert_eq(probe.count_of("settings_changed"), 1, "a refused write signals nothing")

	begin("boundary values inside the range are accepted")
	assert_true(store.set_setting("weekly_goal_days", 7), "weekly goal 7 accepted")
	assert_true(store.set_setting("weekly_goal_days", 1), "weekly goal 1 accepted")
	assert_true(store.set_setting("rest_timer.default_seconds", 15), "rest 15 accepted")
	assert_true(store.set_setting("rest_timer.default_seconds", 300), "rest 300 accepted")
	assert_true(store.set_setting("llm.temperature", 0.0), "temperature 0.0 accepted")
	assert_true(store.set_setting("llm.temperature", 2.0), "temperature 2.0 accepted")
	assert_true(store.set_setting("llm.timeout_sec", 120), "timeout 120 accepted")
	assert_true(store.set_setting("ui.text_scale", 1.3), "text scale 1.3 accepted")
	assert_true(store.set_setting("ui.last_tab", 3), "last tab 3 accepted")
	assert_true(store.set_setting("ui.wizard_draft", {"step": 2}), "wizard draft accepted")
	assert_true(store.set_setting("llm.api_key", "sk-live-secret-value"), "api key accepted")

	begin("reset_settings restores the defaults and keeps created_at")
	var created := String(store.get_setting("meta.created_at", ""))
	store.reset_settings()
	assert_eq(store.settings().get("units", ""), "lb", "units reset")
	assert_eq(store.settings().get("theme", ""), "dark", "theme reset")
	assert_eq(store.get_setting("llm.api_key", "x"), "", "the api key is cleared")
	assert_eq(String(store.get_setting("meta.created_at", "")), created,
		"meta.created_at survives a reset")
	assert_true(probe.has("settings_changed"), "reset signals settings_changed")
	_free(store)


# ------------------------------------------------------------------ R6: unknown fields

func _test_unknown_fields() -> void:
	begin("a document written by a newer app survives a load/save cycle unchanged")
	var dir := _fresh(SUITE_DIR + "unknown/")
	_write_raw(dir, "settings.json", JSON.stringify({
		"schema_version": 2,
		"units": "kg",
		"future_top_level": {"nested": [1, 2, 3]},
		"rest_timer": {"enabled": false, "future_rest_key": "keep me"},
		"llm": {"model": "custom-model", "future_llm_key": 42},
		"ui": {"last_tab": 2, "future_ui_key": true},
	}, "\t", true, false) + "\n")
	_write_raw(dir, "plans.json", JSON.stringify({
		"schema_version": 1,
		"active_plan_id": "plan-1758000000",
		"future_plans_root": "keep",
		"plans": [{
			"id": "plan-1758000000",
			"name": "Unknown Fields",
			"goal": "strength",
			"days_per_week": 1,
			"duration_min": 40,
			"source": "llm",
			"provider": "deepseek",
			"areas": ["chest"],
			"equipment": ["barbell"],
			"notes": "",
			"split_name": "Full Body",
			"future_plan_key": "keep",
			"sessions": [{
				"id": "s1",
				"index": 0,
				"title": "Full Body A",
				"focus": ["chest"],
				"est_minutes": 40,
				"future_session_key": "keep",
				"warmup": [{"exercise_id": "world-greatest-stretch", "duration_sec": 45,
					"future_warmup_key": "keep"}],
				"blocks": [{"exercise_id": "bench-press", "sets": 3, "reps": "8-10",
					"rest_seconds": 90, "future_block_key": "keep"}],
				"cooldown": [],
			}],
		}],
	}, "\t", true, false) + "\n")
	_write_raw(dir, "history.json", JSON.stringify({
		"schema_version": 1,
		"future_history_root": "keep",
		"entries": [{
			"id": "h-1758000000",
			"plan_id": "plan-1758000000",
			"session_id": "s1",
			"session_title": "Full Body A",
			"date": "2026-09-15",
			"started_at": "2026-09-15T12:00:00Z",
			"completed_at": "2026-09-15T12:40:00Z",
			"duration_sec": 2400,
			"exercises_completed": 1,
			"exercises_total": 1,
			"completed": true,
			"future_entry_key": "keep",
		}],
	}, "\t", true, false) + "\n")

	var store := _open(dir)
	var plan: Dictionary = store.get_plan("plan-1758000000")
	var session: Dictionary = (plan.get("sessions", []) as Array)[0]
	var block: Dictionary = (session.get("blocks", []) as Array)[0]
	var warmup: Dictionary = (session.get("warmup", []) as Array)[0]
	var entry: Dictionary = store.all_entries()[0]

	begin("unknown keys are visible in the typed view")
	assert_eq(store.get_setting("future_top_level.nested", []).size(), 3, "settings root unknown")
	assert_eq(store.get_setting("rest_timer.future_rest_key", ""), "keep me", "rest unknown")
	assert_eq(store.get_setting("llm.future_llm_key", 0), 42, "llm unknown")
	assert_eq(store.get_setting("ui.future_ui_key", false), true, "ui unknown")
	assert_eq(store.plans_doc().get("future_plans_root", ""), "keep", "plans root unknown")
	assert_eq(plan.get("future_plan_key", ""), "keep", "plan unknown")
	assert_eq(session.get("future_session_key", ""), "keep", "session unknown")
	assert_eq(block.get("future_block_key", ""), "keep", "block unknown")
	assert_eq(warmup.get("future_warmup_key", ""), "keep", "warm-up unknown")
	assert_eq(entry.get("future_entry_key", ""), "keep", "entry unknown")

	begin("a known field mutated through the API keeps its unknown siblings")
	assert_true(store.set_setting("units", "lb"), "units changed")
	assert_true(store.set_setting("rest_timer.enabled", true), "a nested field changed")
	var plan_edit: Dictionary = JsonStore.Json.deep_copy(plan)
	var plan_dict: Dictionary = plan_edit
	plan_dict["name"] = "Renamed Through The API"
	assert_true(store.upsert_plan(plan_dict), "the plan was upserted in place")
	var entry_id := String(entry.get("id", ""))
	assert_true(store.update_entry(entry_id, {"duration_sec": 2500}), "the entry was updated")
	assert_true(store.flush(), "everything was written")

	begin("the unknown keys are still on disk after the round trip (AC10)")
	var settings_on_disk := _read_json(dir, "settings.json")
	var plans_on_disk := _read_json(dir, "plans.json")
	var history_on_disk := _read_json(dir, "history.json")
	assert_eq(settings_on_disk.get("future_top_level", {}).get("nested", []).size(), 3,
		"settings root unknown survived")
	assert_eq(settings_on_disk.get("units", ""), "lb", "the typed change was written")
	assert_eq((settings_on_disk.get("rest_timer", {}) as Dictionary).get("future_rest_key", ""),
		"keep me", "rest_timer unknown survived")
	assert_eq((settings_on_disk.get("llm", {}) as Dictionary).get("future_llm_key", 0), 42,
		"llm unknown survived")
	assert_eq(plans_on_disk.get("future_plans_root", ""), "keep", "plans root unknown survived")
	var plan_out: Dictionary = (plans_on_disk.get("plans", []) as Array)[0]
	assert_eq(plan_out.get("future_plan_key", ""), "keep", "plan unknown survived")
	assert_eq(plan_out.get("name", ""), "Renamed Through The API", "the plan edit was written")
	var session_out: Dictionary = (plan_out.get("sessions", []) as Array)[0]
	assert_eq(session_out.get("future_session_key", ""), "keep", "session unknown survived")
	var block_out: Dictionary = (session_out.get("blocks", []) as Array)[0]
	assert_eq(block_out.get("future_block_key", ""), "keep", "block unknown survived")
	assert_eq((history_on_disk.get("entries", []) as Array)[0].get("future_entry_key", ""),
		"keep", "entry unknown survived")
	assert_eq(history_on_disk.get("future_history_root", ""), "keep", "history root survived")

	begin("keys the store owns are re-filled when a record is missing them")
	var refilled := _open(dir)
	assert_eq(refilled.get_setting("theme", ""), "dark", "a missing known key is defaulted")
	assert_true(refilled.get_plan("plan-1758000000").has("notes"),
		"apply_plan_defaults re-fills plan.notes")
	_free(store, refilled)


# ------------------------------------------------------------------ R7: clamping

func _test_clamping() -> void:
	begin("out-of-range values in a hand-edited file are clamped, not obeyed (R7)")
	var dir := _fresh(SUITE_DIR + "clamping/")
	_write_raw(dir, "settings.json", JSON.stringify({
		"schema_version": 2,
		"units": "stone",
		"theme": "sepia",
		"weekly_goal_days": 99,
		"onboarding_complete": "yes",
		"rest_timer": {"enabled": "no", "default_seconds": 5},
		"llm": {"provider": "nope", "temperature": 9.5, "timeout_sec": 400,
			"last_tested_at": 17, "last_test_ok": "yes"},
		"ui": {"last_tab": 9, "text_scale": 1.9, "wizard_draft": "nope"},
	}, "\t", true, false) + "\n")

	var store := _open(dir)
	assert_eq(store.get_setting("units", ""), "lb", "an unknown unit falls back to lb")
	assert_eq(store.get_setting("theme", ""), "dark", "an unknown theme falls back to dark")
	assert_eq(store.get_setting("weekly_goal_days", 0), 7, "a goal above 7 clamps to 7")
	assert_eq(store.get_setting("onboarding_complete", true), false, "a non-boolean becomes false")
	assert_eq(store.get_setting("rest_timer.enabled", true), false,
		"a non-boolean nested value becomes false")
	assert_eq(store.get_setting("rest_timer.default_seconds", 0), 15,
		"a rest below 15 s clamps to 15")
	assert_eq(store.get_setting("llm.provider", ""), "deepseek", "an unknown provider is replaced")
	assert_close(float(store.get_setting("llm.temperature", 0.0)), 2.0, 0.0001,
		"a temperature above 2.0 clamps to 2.0")
	assert_eq(store.get_setting("llm.timeout_sec", 0), 120, "a timeout above 120 clamps to 120")
	assert_eq(store.get_setting("llm.last_tested_at", "x"), null,
		"a non-string timestamp becomes null")
	assert_eq(store.get_setting("llm.last_test_ok", true), null,
		"a non-boolean test result becomes null")
	assert_eq(store.get_setting("ui.last_tab", -1), 3, "a tab index above 3 clamps to 3")
	assert_close(float(store.get_setting("ui.text_scale", 0.0)), 1.5, 0.0001,
		"a text scale snaps to the nearest legal value")
	assert_true(store.get_setting("ui.wizard_draft", {}) is Dictionary,
		"a non-object draft becomes an empty object")

	begin("a clamped document is valid and writable")
	var clamped: Dictionary = store.settings()
	assert_empty(Migrations.Schema.validate_settings(clamped),
		"clamping always produces a valid document")
	assert_true(store.set_setting("units", "kg"), "the clamped store still accepts writes")
	assert_true(store.flush(), "and writes")
	assert_eq(_read_json(dir, "settings.json").get("units", ""), "kg", "the write landed")
	_free(store)


# ------------------------------------------------------------------ R5: migration chain

func _test_migration() -> void:
	begin("a version-less settings document migrates 0 -> 1 -> 2")
	var dir := _fresh(SUITE_DIR + "migration/")
	_write_raw(dir, "settings.json", JSON.stringify({
		"units": "kg",
		"mystery_legacy_key": 7,
		"llm": {"api_key": "legacy-key"},
	}, "\t", true, false) + "\n")
	_write_raw(dir, "plans.json", JSON.stringify({
		"id": "plan-1758000000",
		"name": "Legacy Plan",
		"goal": "hypertrophy",
		"days_per_week": 1,
		"duration_min": 30,
		"areas": ["back"],
		"equipment": ["dumbbell"],
		"split_name": "Full Body",
		"sessions": [{"id": "s1", "index": 0, "title": "Full Body A", "focus": ["back"],
			"est_minutes": 30, "warmup": [], "blocks": [{"exercise_id": "bent-over-row",
				"sets": 3, "reps": "8-10", "rest_seconds": 90}], "cooldown": []}],
	}, "\t", true, false) + "\n")
	_write_raw(dir, "history.json", JSON.stringify({
		"entries": [{"id": "h-1758000000", "plan_id": "plan-1758000000", "session_id": "s1",
			"session_title": "Full Body A", "date": "2026-09-14",
			"started_at": "2026-09-14T12:00:00Z"}],
	}, "\t", true, false) + "\n")

	var probe := Probe.new()
	var store := _open(dir, probe)

	assert_eq(probe.count_of("migrated:settings:0:3:3"), 1,
		"settings migrated 0 -> 3 in three steps")
	assert_eq(probe.count_of("migrated:plans:0:1:1"), 1, "plans migrated 0 -> 1")
	assert_eq(probe.count_of("migrated:history:0:1:1"), 1, "history migrated 0 -> 1")

	begin("the migrated settings document has every current key and keeps legacy values")
	assert_eq(store.settings().get("schema_version", 0), 3, "version 3 after migration")
	assert_eq(store.settings().get("units", ""), "kg", "a legacy value is preserved")
	assert_true(store.settings().has("attribution_seen"), "v2 adds attribution_seen")
	assert_true(store.settings().has("rest_timer"), "v2 adds the rest_timer block")
	assert_eq(store.get_setting("rest_timer.default_seconds", 0), 90, "rest default applied")
	assert_eq(store.get_setting("llm.model", ""), "deepseek-chat", "llm defaults filled in")
	assert_eq(store.get_setting("llm.api_key", ""), "legacy-key", "a legacy key survives")
	assert_eq(store.get_setting("ui.text_scale", 0.0), 1.15,
		"v3 lifts the old M default to L")
	assert_eq(store.get_setting("mystery_legacy_key", 0), 7, "an unknown key survives migration")

	begin("the migrated plans document is wrapped and defaulted")
	var plan: Dictionary = store.active_plan()
	assert_eq(store.active_plan_id(), "plan-1758000000", "the bare plan became active")
	assert_eq(plan.get("source", ""), "builtin", "migration writes source=builtin (R31)")
	assert_eq(plan.get("provider", ""), "", "builtin implies an empty provider")
	assert_eq(plan.get("notes", ""), "", "migration adds notes")
	assert_eq(store.all_plans().size(), 1, "one plan after migration")

	begin("the migrated history document marks existing entries completed")
	assert_eq(store.all_entries().size(), 1, "one entry after migration")
	assert_eq(store.all_entries()[0].get("completed", false), true, "migration adds completed=true")

	begin("the migrated documents are rewritten at the current version")
	assert_true(store.flush(), "flush after migration")
	assert_eq(_read_json(dir, "settings.json").get("schema_version", 0), 3, "settings v3 on disk")
	assert_eq(_read_json(dir, "plans.json").get("schema_version", 0), 1, "plans v1 on disk")
	assert_eq(_read_json(dir, "history.json").get("schema_version", 0), 1, "history v1 on disk")
	assert_false(FileAccess.file_exists(dir + "settings.json.corrupt-20200101T000000Z.json"),
		"a migrated file is never quarantined")
	_free(store)


func _test_future_version() -> void:
	begin("a document from a newer app version is quarantined, never downgraded")
	var dir := _fresh(SUITE_DIR + "future/")
	_write_raw(dir, "settings.json", JSON.stringify({
		"schema_version": 99,
		"units": "kg",
		"theme": "light",
		"only_a_newer_build_knows": true,
	}, "\t", true, false) + "\n")

	var probe := Probe.new()
	var store := _open(dir, probe)

	assert_eq(probe.count_of("quarantined:settings:future_version"), 1,
		"quarantined with reason=future_version")
	assert_eq(store.settings().get("schema_version", 0), 3, "defaults are loaded instead")
	assert_eq(store.settings().get("units", ""), "lb", "defaults, not the newer document")

	begin("the newer document is kept verbatim for the newer app to recover")
	var quarantined: PackedStringArray = store.quarantine_paths("settings")
	assert_eq(quarantined.size(), 1, "one quarantine copy")
	var kept: Variant = JSON.parse_string(_read_raw_absolute(quarantined[0]))
	assert_true(kept is Dictionary, "the quarantine copy is still valid JSON")
	assert_eq((kept as Dictionary).get("schema_version", 0), 99, "the newer version is intact")
	assert_eq((kept as Dictionary).get("only_a_newer_build_knows", false), true, "content intact")

	begin("a fresh valid document replaces the quarantined one")
	var live := _read_json(dir, "settings.json")
	assert_eq(live.get("schema_version", 0), 3, "a fresh v3 settings.json exists")
	assert_true(live.has("llm"), "the fresh document is complete")
	_free(store)


# ------------------------------------------------------------------ R4: corruption

func _test_corruption_recovery() -> void:
	begin("a damaged live file is repaired from the backup, which is kept")
	var dir := _fresh(SUITE_DIR + "recover_bak/")
	_write_raw(dir, "settings.json.bak", JSON.stringify({
		"schema_version": 2,
		"units": "kg",
		"theme": "light",
		"weekly_goal_days": 5,
		"llm": {"model": "recovered-model"},
	}, "\t", true, false) + "\n")
	_write_raw(dir, "settings.json", "{ this is not json")

	var probe := Probe.new()
	var store := _open(dir, probe)
	assert_eq(probe.count_of("recovered:settings"), 1, "recovered_from_backup was signalled")
	assert_eq(store.settings().get("units", ""), "kg", "the recovered values are in use")
	assert_eq(store.get_setting("llm.model", ""), "recovered-model", "nested value recovered")
	assert_eq(store.quarantine_paths("settings").size(), 0,
		"no quarantine copy when the backup saved us")
	assert_true(FileAccess.file_exists(dir + "settings.json.bak"), "the backup is kept")
	var repaired := _read_json(dir, "settings.json")
	assert_eq(repaired.get("units", ""), "kg", "the live file was repaired from the backup")
	assert_eq(repaired.get("weekly_goal_days", 0), 5, "the repair keeps the backup's values")

	begin("a damaged live file with no usable backup is quarantined and defaults load")
	var dir2 := _fresh(SUITE_DIR + "recover_none/")
	_write_raw(dir2, "settings.json", "{ also not json")
	_write_raw(dir2, "settings.json.bak", "}[ still not json")
	var probe2 := Probe.new()
	var store2 := _open(dir2, probe2)
	assert_eq(probe2.count_of("quarantined:settings:parse"), 1, "quarantined with reason=parse")
	assert_eq(store2.settings().get("units", ""), "lb", "defaults are loaded")
	var copies: PackedStringArray = store2.quarantine_paths("settings")
	assert_eq(copies.size(), 2, "both the live file and its backup were quarantined")
	var has_primary := false
	var has_backup := false
	var shared_tag := ""
	for copy_path in copies:
		if copy_path.ends_with("-bak.json"):
			has_backup = true
			shared_tag = copy_path.get_file().replace("-bak.json", "")
		else:
			has_primary = true
	assert_true(has_primary, "the live file became a .corrupt-<TS>.json copy")
	assert_true(has_backup, "the backup became a .corrupt-<TS>-bak.json copy")
	assert_true(shared_tag.begins_with("settings.json.corrupt-"),
		"the quarantine name follows the documented shape")
	assert_true(copies[0].get_file().contains(shared_tag.substr("settings.json.".length())),
		"both copies share one timestamp (R4.4)")
	assert_true(FileAccess.file_exists(dir2 + "settings.json"),
		"a fresh valid document replaces the quarantined one")
	assert_eq(_read_json(dir2, "settings.json").get("schema_version", 0), 3,
		"the replacement is a complete v3 document")

	begin("truncated JSON, a top-level array and an empty file are all quarantined")
	var cases: Array[Array] = [
		["truncated", "{\"units\": \"kg\""],
		["not_an_object", "[1, 2, 3]"],
		["empty", ""],
	]
	var expected_reasons: PackedStringArray = ["parse", "not_object", "empty"]
	for i in cases.size():
		var label: String = cases[i][0]
		var text: String = cases[i][1]
		var case_dir := _fresh(SUITE_DIR + "corrupt_%s/" % label)
		_write_raw(case_dir, "settings.json", text)
		var case_probe := Probe.new()
		var case_store := _open(case_dir, case_probe)
		assert_eq(case_probe.count_of("quarantined:settings:%s" % expected_reasons[i]), 1,
			"%s is quarantined with reason=%s" % [label, expected_reasons[i]])
		assert_eq(case_store.settings().get("schema_version", 0), 3,
			"%s falls back to defaults" % label)
		assert_eq(case_store.quarantine_paths("settings").size(), 1, "%s left one copy" % label)
		_free(case_store)

	begin("corruption in one document never damages the others")
	var dir3 := _fresh(SUITE_DIR + "corrupt_isolated/")
	_write_raw(dir3, "settings.json", "garbage")
	_write_raw(dir3, "plans.json", JSON.stringify({"schema_version": 1,
		"active_plan_id": "", "plans": []}) + "\n")
	var probe3 := Probe.new()
	var store3 := _open(dir3, probe3)
	assert_eq(probe3.count_of("quarantined:settings"), 1, "settings was quarantined")
	assert_eq(probe3.count_of("quarantined:plans"), 0, "plans was untouched")
	assert_eq(store3.plans_doc().get("schema_version", 0), 1, "plans loaded normally")
	assert_false(probe3.has("save_failed"), "the store never reported a save failure")
	_free(store, store2, store3)


func _test_quarantine_retention() -> void:
	begin("at most MAX_QUARANTINES corrupted copies are kept per document (AC13)")
	var dir := _fresh(SUITE_DIR + "retention/")
	# Five pre-existing copies from "the past" plus one fresh incident: the oldest is pruned.
	var old_paths := PackedStringArray()
	for i in 5:
		var old_path := "%ssettings.json.corrupt-20200101T00000%dZ.json" % [dir, i + 1]
		_write_raw_absolute(old_path, "{ old corruption %d" % i)
		old_paths.append(old_path)
	_write_raw(dir, "settings.json", "{ fresh corruption")

	var store := _open(dir)
	var kept: PackedStringArray = store.quarantine_paths("settings")
	assert_eq(kept.size(), 5, "the cap is MAX_QUARANTINES = 5")
	assert_false(kept.has(old_paths[0]), "the oldest copy was pruned")
	assert_true(kept.has(old_paths[4]), "the newest old copy survives")
	assert_eq(kept.size(), store.quarantine_paths("settings").size(), "the list is stable")

	begin("only .corrupt-* copies are ever pruned")
	var live_files := _list(dir)
	assert_true(live_files.has("settings.json"), "the live document is never deleted")
	for entry in live_files:
		if entry.begins_with("settings.json.corrupt-"):
			continue
		assert_false(entry.contains("corrupt"), "%s is not a quarantine copy" % entry)
	assert_true(store.set_setting("units", "kg"), "a settings write after the pruning")
	assert_true(store.flush(), "flushed")
	var after_write := _list(dir)
	assert_true(after_write.has("settings.json"), "the live document survives the pruning")
	assert_true(after_write.has("settings.json.bak"), "the .bak sibling survives the pruning")
	assert_le(float(store.quarantine_paths("settings").size()), 5.0,
		"and the cap is still enforced")

	begin("repeated corruption in the same second never overwrites a copy")
	for i in 3:
		_write_raw(dir, "settings.json", "{ corruption round %d" % i)
		store.load_all()
		assert_le(float(store.quarantine_paths("settings").size()), 5.0,
			"the cap holds after round %d" % i)
	assert_eq(_read_json(dir, "settings.json").get("schema_version", 0), 3,
		"a valid document is always left behind")
	assert_le(float(store.quarantine_paths("settings").size()), 5.0,
		"never more than MAX_QUARANTINES copies")
	_free(store)


# ------------------------------------------------------------------ R9b: session progress

func _test_session_progress() -> void:
	begin("session progress round-trips through the nested document shape")
	var dir := _fresh(SUITE_DIR + "progress/")
	var store := _open(dir)
	assert_true(store.upsert_plan(_plan("plan-1758000000", "Progress")), "plan stored")
	assert_true(store.set_active_plan("plan-1758000000"), "plan activated")
	assert_false(FileAccess.file_exists(dir + "session_progress.json"),
		"no cursor before a workout starts")

	var saved := {
		"plan_id": "plan-1758000000",
		"session_id": "s1",
		"started_at": store.now_iso(),
		"updated_at": store.now_iso(),
		"step_index": 2,
		"elapsed_sec": 1320,
		"paused_total_sec": 30,
		"set_states": {"bench-press": [true, true, false]},
		"completed_blocks": ["bench-press"],
		"rest_remaining_sec": 45,
	}
	assert_true(store.save_session_progress(saved), "progress saved")
	assert_true(store.is_dirty(), "the session document is debounced like the others")
	assert_true(store.flush(), "progress flushed")

	var document := _read_json(dir, "session_progress.json")
	assert_eq(document.get("schema_version", 0), 1, "session_progress schema_version")
	assert_true(document.get("progress") is Dictionary, "progress is a nested object")
	var inner: Dictionary = document.get("progress", {})
	assert_eq(inner.get("step_index", -1), 2, "step_index stored")
	assert_eq(inner.get("elapsed_sec", -1), 1320, "elapsed_sec stored")
	assert_eq(inner.get("rest_remaining_sec", -1), 0, "rest_remaining_sec is persisted as 0")

	begin("a second store on the same root resumes the session")
	var resumed_store := _open(dir)
	var loaded: Dictionary = resumed_store.load_session_progress()
	assert_eq(loaded.get("plan_id", ""), "plan-1758000000", "plan_id survives a restart")
	assert_eq(loaded.get("session_id", ""), "s1", "session_id survives a restart")
	assert_eq(loaded.get("step_index", -1), 2, "the cursor survives a restart")
	assert_eq((loaded.get("set_states", {}) as Dictionary).get("bench-press", []).size(), 3,
		"set states survive a restart")
	assert_eq(loaded.get("rest_remaining_sec", -1), 0, "a rest timer never resumes")

	begin("a stale cursor is dropped and its file removed")
	var stale_dir := _fresh(SUITE_DIR + "progress_stale/")
	var stale_store := _open(stale_dir)
	assert_true(stale_store.upsert_plan(_plan("plan-1758000000", "Stale")), "plan stored")
	# Midnight UTC yesterday is always more than 12 h ago, so the stamp is stale by
	# construction and the assertion below cannot depend on the wall clock.
	var stale_stamp := "%sT00:00:00Z" % Dates.add_days(
		Dates.now_iso8601(true).substr(0, 10), -1)
	_write_raw(stale_dir, "session_progress.json", JSON.stringify({
		"schema_version": 1,
		"progress": {
			"plan_id": "plan-1758000000",
			"session_id": "s1",
			"started_at": stale_stamp,
			"updated_at": stale_stamp,
			"step_index": 1,
		},
	}, "\t", true, false) + "\n")
	# The stamp is a whole day old, i.e. well past STALE_PROGRESS_HOURS = 12.
	assert_eq(stale_store.load_session_progress(), {}, "a cursor older than 12 h is dropped")
	assert_false(FileAccess.file_exists(stale_dir + "session_progress.json"),
		"the stale file is removed")
	assert_gt(float(Dates.seconds_between_iso(Dates.now_iso8601(true), stale_stamp)),
		12.0 * 3600.0, "the fixture really is older than STALE_PROGRESS_HOURS")

	begin("an unresolvable cursor is dropped, a resolvable one is kept")
	var gone_dir := _fresh(SUITE_DIR + "progress_unresolvable/")
	var gone_store := _open(gone_dir)
	assert_true(gone_store.upsert_plan(_plan("plan-1758000000", "Gone")), "plan stored")
	assert_true(gone_store.save_session_progress({
		"plan_id": "plan-1758000000", "session_id": "s1"}), "progress for a real plan")
	assert_true(gone_store.flush(), "flushed")
	assert_eq(gone_store.load_session_progress().get("session_id", ""), "s1", "it resolves")

	assert_true(gone_store.save_session_progress({
		"plan_id": "plan-9999999999", "session_id": "s1"}), "progress for a foreign plan")
	assert_true(gone_store.flush(), "flushed")
	assert_eq(gone_store.load_session_progress(), {}, "an unknown plan_id is unresolvable")
	assert_false(FileAccess.file_exists(gone_dir + "session_progress.json"),
		"the unresolvable file is removed")

	assert_true(gone_store.save_session_progress({
		"plan_id": "plan-1758000000", "session_id": "s9"}), "progress for a foreign session")
	assert_true(gone_store.flush(), "flushed")
	assert_eq(gone_store.load_session_progress(), {}, "an unknown session_id is unresolvable")

	begin("clearing deletes the file instead of blanking it")
	assert_true(gone_store.save_session_progress({
		"plan_id": "plan-1758000000", "session_id": "s1"}), "progress again")
	assert_true(gone_store.flush(), "flushed")
	assert_true(FileAccess.file_exists(gone_dir + "session_progress.json"), "file exists")
	assert_true(gone_store.clear_session_progress(), "clear_session_progress() succeeds")
	assert_false(FileAccess.file_exists(gone_dir + "session_progress.json"),
		"the file is removed, not emptied")
	assert_eq(gone_store.load_session_progress(), {}, "nothing to resume")

	begin("progress without ids is refused")
	assert_false(store.save_session_progress({}), "an empty progress is refused")
	assert_false(store.save_session_progress({"step_index": 1}), "missing ids are refused")
	assert_true(store.save_session_progress({"plan_id": "plan-1758000000"}) == false,
		"a missing session_id is refused")

	begin("a malformed progress file is quarantined and treated as absent")
	var broken_dir := _fresh(SUITE_DIR + "progress_broken/")
	var broken_store := _open(broken_dir)
	var broken_probe := Probe.new()
	_attach(broken_store, broken_probe)
	_write_raw(broken_dir, "session_progress.json", "{ broken")
	assert_eq(broken_store.load_session_progress(), {}, "a broken cursor reads as absent")
	assert_eq(broken_probe.count_of("quarantined:session_progress:parse"), 1,
		"the broken cursor was quarantined, not fatal")
	_free(store, resumed_store, stale_store, gone_store, broken_store)


# ------------------------------------------------------------------ R9: history

func _test_history_api() -> void:
	begin("entries are added with a generated id and stay sorted by date")
	var dir := _fresh(SUITE_DIR + "history/")
	var store := _open(dir)
	var probe := Probe.new()
	_attach(store, probe)
	var today: String = store.today_local_iso()
	var yesterday := Dates.add_days(today, -1)

	var generated_id: String = store.add_entry(_entry(today, true))
	var yesterday_id: String = store.add_entry(_entry(yesterday, true))
	assert_true(generated_id.begins_with("h-"), "add_entry returns a generated id")
	assert_true(yesterday_id.begins_with("h-"), "the second entry got an id")
	assert_ne(yesterday_id, generated_id, "generated ids are unique")

	begin("an id collision follows the documented -2 rule (R9)")
	var explicit_one := _entry(today, true)
	explicit_one["id"] = "h-1758000000"
	assert_eq(store.add_entry(explicit_one), "h-1758000000", "an explicit id is honoured")
	var explicit_two := _entry(today, true)
	explicit_two["id"] = "h-1758000000"
	assert_eq(store.add_entry(explicit_two), "h-1758000000-2", "a colliding id appends -2")
	var explicit_three := _entry(yesterday, true)
	explicit_three["id"] = "h-1758000000"
	assert_eq(store.add_entry(explicit_three), "h-1758000000-3", "the next collision appends -3")

	assert_eq(store.all_entries().size(), 5, "five entries stored")
	assert_true(String(store.all_entries()[0].get("date", ""))
			<= String(store.all_entries()[1].get("date", "")),
		"entries are sorted by date ascending")
	assert_eq(probe.count_of("entry_added"), 5, "entry_added fired per entry")
	assert_eq(probe.count_of("history_changed"), 5, "history_changed fired per entry")

	begin("queries by date and range are inclusive")
	assert_eq(store.entries_on(today).size(), 3, "three entries today")
	assert_eq(store.entries_on(yesterday).size(), 2, "two entries yesterday")
	assert_eq(store.entries_between(yesterday, today).size(), 5, "the range is inclusive")
	assert_eq(store.entries_between(today, today).size(), 3, "a one-day range works")
	assert_eq(store.entries_between(Dates.add_days(today, -7), Dates.add_days(today, -2)).size(), 0,
		"an empty range yields nothing")
	assert_eq(store.entries_on("1999-01-01").size(), 0, "an empty day yields nothing")

	begin("an entry with an invalid date is refused")
	assert_eq(store.add_entry(_entry("not-a-date", true)), "", "an invalid date is refused")
	assert_eq(store.all_entries().size(), 5, "nothing was added")
	assert_eq(store.add_entry({}), "", "an empty entry is refused")

	begin("entries can be updated and deleted")
	var target_id := "h-1758000000-3"
	assert_true(store.update_entry(target_id, {"duration_sec": 1234}), "update accepted")
	var updated := _entry_by_id(store, target_id)
	assert_eq(int(updated.get("duration_sec", 0)), 1234, "value changed")
	assert_eq(updated.get("date", ""), yesterday, "the entry stayed on its own day")
	assert_eq(updated.get("session_title", ""), "Full Body A", "the other fields are untouched")
	assert_false(store.update_entry("h-does-not-exist", {"duration_sec": 1}), "unknown id refused")
	assert_false(store.update_entry(target_id, {"date": "nope"}), "invalid date refused")
	assert_eq(int(_entry_by_id(store, target_id).get("duration_sec", 0)), 1234,
		"a refused update changes nothing")
	assert_true(store.delete_entry(target_id), "delete accepted")
	assert_eq(store.all_entries().size(), 4, "one entry removed")
	assert_true(_entry_by_id(store, target_id).is_empty(), "the entry is gone")
	assert_false(store.delete_entry(target_id), "deleting twice is refused")
	assert_true(store.flush(), "history flushed")
	assert_eq((_read_json(dir, "history.json").get("entries", []) as Array).size(), 4,
		"the deletion reached the disk")

	begin("streak and week helpers read the real history")
	assert_eq(store.streak_days(), 2, "today and yesterday form a two day streak")
	assert_ge(float(store.completed_days_in_week()), 1.0, "today counts towards the week")
	assert_le(float(store.completed_days_in_week()), 2.0, "and never more than two days")
	assert_eq(store.current_week_id(), Dates.iso_week_id(today), "current_week_id matches")
	assert_gt(float(store.data_dir_usage_bytes()), 0.0, "history bytes are counted")
	_free(store)


func _test_malformed_history_entry() -> void:
	begin("one malformed row is dropped without costing the streak (R9)")
	var dir := _fresh(SUITE_DIR + "history_bad_row/")
	var today := Dates.today_iso(false)
	var yesterday := Dates.add_days(today, -1)
	_write_raw(dir, "history.json", JSON.stringify({
		"schema_version": 1,
		"entries": [
			{"id": "h-1", "date": yesterday, "started_at": "%sT10:00:00Z" % yesterday,
				"completed": true, "plan_id": "p", "session_id": "s", "session_title": "S"},
			{"id": "h-bad", "date": "2026-13-45", "started_at": "2026-13-45T10:00:00Z",
				"completed": true},
			{"id": "h-2", "date": today, "started_at": "%sT10:00:00Z" % today,
				"completed": true, "plan_id": "p", "session_id": "s", "session_title": "S"},
		],
	}, "\t", true, false) + "\n")

	var store := _open(dir)
	assert_eq(store.all_entries().size(), 2, "the malformed row was dropped")
	assert_eq(store.streak_days(), 2, "the streak is intact across the bad row")
	var added: String = store.add_entry(_entry(today, true))
	assert_true(added.begins_with("h-"), "a new entry got a generated id")
	assert_true(store.flush(), "flush after the drop")
	var on_disk: Array = _read_json(dir, "history.json").get("entries", [])
	assert_eq(on_disk.size(), 3, "two kept rows plus the new one, and the bad row is gone")
	for element in on_disk:
		assert_ne(String((element as Dictionary).get("id", "")), "h-bad",
			"the malformed row is not written back")
	var ids := PackedStringArray()
	for entry in store.all_entries():
		ids.append(String(entry.get("id", "")))
	assert_false(ids.has("h-bad"), "only the malformed row is gone")
	_free(store)


# ------------------------------------------------------------------ R8: plans

func _test_plans_api() -> void:
	begin("upsert_plan inserts newest first and replaces in place")
	var dir := _fresh(SUITE_DIR + "plans/")
	var store := _open(dir)
	var probe := Probe.new()
	_attach(store, probe)

	assert_true(store.upsert_plan(_plan("plan-1758000001", "First")), "first plan stored")
	assert_true(store.upsert_plan(_plan("plan-1758000002", "Second")), "second plan stored")
	assert_eq(store.all_plans().size(), 2, "two plans")
	assert_eq(String(store.all_plans()[0].get("id", "")), "plan-1758000002",
		"the newest plan is at index 0")
	assert_eq(store.active_plan_id(), "", "upserting does not activate a plan")
	assert_eq(probe.count_of("plans_changed"), 2, "plans_changed fired per upsert")

	var edited: Dictionary = JsonStore.Json.deep_copy(store.get_plan("plan-1758000001"))
	var edited_dict: Dictionary = edited
	edited_dict["name"] = "First (edited)"
	edited_dict["unknown_kept"] = "yes"
	assert_true(store.upsert_plan(edited_dict), "the plan was replaced")
	assert_eq(store.all_plans().size(), 2, "no duplicate was created")
	assert_eq(String(store.all_plans()[1].get("id", "")), "plan-1758000001",
		"the replaced plan kept its position")
	assert_eq(store.get_plan("plan-1758000001").get("name", ""), "First (edited)", "edit applied")
	assert_eq(store.get_plan("plan-1758000001").get("unknown_kept", ""), "yes",
		"an unknown plan field survives an in-place upsert")

	begin("a plan without an id gets the documented id shape")
	assert_true(store.upsert_plan(_plan("", "Generated")), "an id-less plan is stored")
	var generated: Dictionary = store.all_plans()[0]
	var generated_id := String(generated.get("id", ""))
	assert_true(generated_id.begins_with("plan-"), "the id has the plan- prefix")
	assert_eq(generated_id.length(), 15, "plan-<10 digits>")
	assert_true(generated_id.substr(5).is_valid_int(), "the suffix is an integer")
	assert_true(generated.get("created_at", "").ends_with("Z"), "created_at is UTC")

	begin("active plan selection validates the id")
	assert_true(store.set_active_plan("plan-1758000002"), "a real plan can be activated")
	assert_eq(store.active_plan_id(), "plan-1758000002", "active_plan_id updated")
	assert_eq(store.active_plan().get("id", ""), "plan-1758000002", "active_plan resolves")
	assert_false(store.set_active_plan("plan-does-not-exist"), "an unknown plan is refused")
	assert_eq(store.active_plan_id(), "plan-1758000002", "the refused call changed nothing")
	assert_true(store.set_active_plan(""), "clearing the active plan is allowed")
	assert_eq(store.active_plan(), {}, "no active plan resolves to {}")
	assert_true(store.set_active_plan("plan-1758000002"), "re-activated")

	begin("deleting the active plan clears the pointer")
	assert_true(store.delete_plan("plan-1758000002"), "delete accepted")
	assert_eq(store.all_plans().size(), 2, "one plan removed")
	assert_eq(store.active_plan_id(), "", "the active pointer was cleared")
	assert_false(store.delete_plan("plan-1758000002"), "deleting twice is refused")
	assert_false(store.upsert_plan({}), "an empty plan is refused")
	assert_eq(store.get_plan("plan-1758000001").get("id", ""), "plan-1758000001", "lookup works")

	begin("duplicate_plan copies the content under a fresh id")
	var original: Dictionary = store.get_plan("plan-1758000001")
	var copy: Dictionary = store.duplicate_plan(original, "First (repeat)")
	assert_false(copy.is_empty(), "a copy was returned")
	assert_ne(String(copy.get("id", "")), "plan-1758000001", "the copy has a fresh id")
	assert_eq(copy.get("name", ""), "First (repeat)", "the copy has the new name")
	assert_eq((copy.get("sessions", []) as Array).size(), 1, "the content was copied")
	assert_eq(store.all_plans().size(), 3, "the copy was stored")
	var unnamed: Dictionary = store.duplicate_plan(original, "")
	assert_eq(unnamed.get("name", ""), "First (edited) (copy)",
		"an empty name gets a default built from the current name")

	begin("plan documents persist and reload")
	assert_true(store.flush(), "plans flushed")
	var reloaded := _open(dir)
	assert_eq(reloaded.all_plans().size(), 4, "all plans survive a restart")
	assert_eq(reloaded.get_plan("plan-1758000001").get("unknown_kept", ""), "yes",
		"an unknown plan field survives a restart")
	_free(store, reloaded)


# ------------------------------------------------------------------ export / import / reset

func _test_export_import_and_reset() -> void:
	begin("export_all never carries the API key by default (R7)")
	var dir := _fresh(SUITE_DIR + "export/")
	var store := _open(dir)
	assert_true(store.set_setting("llm.api_key", "sk-live-do-not-export"), "key stored")
	assert_ne(store.add_entry(_entry(store.today_local_iso(), true)), "", "entry stored")
	assert_true(store.upsert_plan(_plan("plan-1758000001", "Exported")), "plan stored")

	var bundle: Dictionary = store.export_all()
	var text := JSON.stringify(bundle, "\t", true, false)
	assert_false(text.contains("sk-live-do-not-export"), "the key is absent from the export")
	var exported_settings: Dictionary = bundle.get("settings", {})
	assert_true(exported_settings.get("llm") is Dictionary, "the llm block is exported")
	assert_eq((exported_settings.get("llm", {}) as Dictionary).get("api_key", "x"), "",
		"the exported api_key is empty")
	assert_eq(bundle.get("export_version", 0), 1, "the bundle is versioned")
	assert_true(String(bundle.get("exported_at", "")).ends_with("Z"), "exported_at is UTC")
	assert_eq((bundle.get("plans", {}) as Dictionary).get("plans", []).size(), 1, "plans exported")
	assert_eq((bundle.get("history", {}) as Dictionary).get("entries", []).size(), 1,
		"history exported")

	begin("include_api_key is the documented escape hatch")
	var full := JSON.stringify(store.export_all(true), "\t", true, false)
	assert_true(full.contains("sk-live-do-not-export"), "the explicit opt-in includes the key")

	begin("import_bundle restores a bundle and backs up what it replaces")
	var target_dir := _fresh(SUITE_DIR + "import/")
	var target := _open(target_dir)
	assert_true(target.upsert_plan(_plan("plan-1758000009", "Doomed")), "pre-existing plan")
	assert_true(target.flush(), "flushed")
	assert_true(target.import_bundle(bundle), "import accepted")
	assert_eq(target.all_entries().size(), 1, "history imported")
	assert_eq(target.all_plans().size(), 1, "plans imported")
	assert_eq(target.get_plan("plan-1758000001").get("name", ""), "Exported", "plan content")
	assert_eq(target.get_plan("plan-1758000009"), {}, "the old plan is gone")
	assert_true(FileAccess.file_exists(target_dir + "plans.json.bak"),
		"the previous document was backed up before the import")

	begin("import_bundle refuses what it cannot understand")
	assert_false(target.import_bundle({}), "an empty bundle is refused")
	assert_false(target.import_bundle({"settings": {"schema_version": 99}}),
		"a newer document is refused")
	assert_eq(target.all_entries().size(), 1, "a refused import changed nothing")
	assert_false(target.import_bundle({"unknown_document": {}}), "an unknown bundle is refused")

	begin("reset_all() returns every document to defaults")
	assert_true(target.reset_all(), "reset_all succeeded")
	assert_eq(target.all_plans().size(), 0, "plans cleared")
	assert_eq(target.all_entries().size(), 0, "history cleared")
	assert_eq(target.settings().get("units", ""), "lb", "settings reset")
	assert_eq(target.active_plan_id(), "", "no active plan after a reset")
	assert_false(FileAccess.file_exists(target_dir + "session_progress.json"),
		"the session cursor is deleted by a reset")
	assert_eq(_read_json(target_dir, "history.json").get("entries", []).size(), 0,
		"the reset reached the disk")
	_free(store, target)


# ------------------------------------------------------------------ R15: goal precedence

func _test_weekly_goal_precedence() -> void:
	begin("without a plan the settings goal is the denominator")
	var dir := _fresh(SUITE_DIR + "goal/")
	var store := _open(dir)
	assert_eq(store.weekly_goal_days_effective(), 4, "the default settings goal")
	assert_true(store.set_setting("weekly_goal_days", 6), "goal raised")
	assert_eq(store.weekly_goal_days_effective(), 6, "settings wins with no active plan")

	begin("an active plan owns the ring denominator (R15 / R50)")
	var plan := _plan("plan-1758000001", "Three Day")
	plan["days_per_week"] = 3
	assert_true(store.upsert_plan(plan), "plan stored")
	assert_true(store.set_active_plan("plan-1758000001"), "plan activated")
	assert_eq(store.weekly_goal_days_effective(), 3, "the plan's days_per_week wins")

	begin("progress is unique completed days over that denominator")
	assert_ne(store.add_entry(_entry(store.today_local_iso(), true)), "", "today completed")
	assert_eq(store.completed_days_in_week(), 1, "one completed day")
	assert_close(store.weekly_goal_progress(), 1.0 / 3.0, 0.0001, "one of three days")
	assert_eq(store.streak_days(), 1, "a streak of one")
	assert_eq(store.longest_streak(), 1, "the longest streak is one")

	begin("a partial entry neither extends the streak nor fills the ring")
	assert_ne(store.add_entry(_entry(Dates.add_days(store.today_local_iso(), -1), false)), "",
		"a partial entry is stored")
	assert_eq(store.streak_days(), 1, "the partial entry does not extend the streak")
	assert_eq(store.completed_days_in_week(), 1, "the partial entry does not fill the ring")

	begin("removing the plan falls back to the settings goal")
	assert_true(store.delete_plan("plan-1758000001"), "plan deleted")
	assert_eq(store.weekly_goal_days_effective(), 6, "back to the settings goal")
	assert_close(store.weekly_goal_progress(), 1.0 / 6.0, 0.0001, "one of six days")
	_free(store)


# ------------------------------------------------------------------ helpers

## Wipes the directory, then opens a store on it.
func _store_for(dir_path: String, probe: Probe = null) -> Node:
	return _open(_fresh(dir_path), probe)


## Opens a store on an existing directory — no wiping, so the suite can seed fixtures first
## or simulate a relaunch. The probe is attached *before* `load_all()` so every signal the
## load emits is captured.
func _open(dir_path: String, probe: Probe = null) -> Node:
	var script: GDScript = load(STORE_SCRIPT)
	var store: Node = script.new()
	if probe != null:
		_attach(store, probe)
	store.set_io_root_for_tests(dir_path)
	store.load_all()
	return store


func _free(store: Node, other: Node = null, third: Node = null, fourth: Node = null,
		fifth: Node = null) -> void:
	for candidate in [store, other, third, fourth, fifth]:
		if candidate != null:
			candidate.free()


func _attach(store: Node, probe: Probe) -> void:
	store.data_loaded.connect(func(first_run: bool) -> void:
		probe.record("data_loaded:%s" % first_run))
	store.settings_changed.connect(func() -> void: probe.record("settings_changed"))
	store.plans_changed.connect(func() -> void: probe.record("plans_changed"))
	store.history_changed.connect(func() -> void: probe.record("history_changed"))
	store.session_progress_changed.connect(func() -> void:
		probe.record("session_progress_changed"))
	store.entry_added.connect(func(entry: Dictionary) -> void:
		probe.record("entry_added:%s" % entry.get("id", "")))
	store.save_failed.connect(func(doc_name: String, reason: String) -> void:
		probe.record("save_failed:%s:%s" % [doc_name, reason]))
	store.recovered_from_backup.connect(func(doc_name: String) -> void:
		probe.record("recovered:%s" % doc_name))
	store.quarantined.connect(func(doc_name: String, _path: String, reason: String) -> void:
		probe.record("quarantined:%s:%s" % [doc_name, reason]))
	store.migrated.connect(func(doc_name: String, from_version: int, to_version: int,
			steps: PackedStringArray) -> void:
		probe.record("migrated:%s:%d:%d:%d" % [
			doc_name, from_version, to_version, steps.size()]))


func _entry(date_iso: String, completed: bool) -> Dictionary:
	return {
		"plan_id": "plan-1758000000",
		"session_id": "s1",
		"session_title": "Full Body A",
		"date": date_iso,
		"started_at": "%sT12:00:00Z" % date_iso,
		"completed_at": "%sT12:40:00Z" % date_iso if completed else "",
		"duration_sec": 2400,
		"exercises_completed": 1 if completed else 0,
		"exercises_total": 1,
		"completed": completed,
	}


func _plan(plan_id: String, plan_name: String) -> Dictionary:
	return {
		"id": plan_id,
		"name": plan_name,
		"created_at": "2026-09-15T12:00:00Z",
		"source": "llm",
		"provider": "deepseek",
		"goal": "hypertrophy",
		"days_per_week": 1,
		"duration_min": 40,
		"areas": ["chest"],
		"equipment": ["barbell"],
		"notes": "",
		"split_name": "Full Body",
		"sessions": [{
			"id": "s1",
			"index": 0,
			"title": "Full Body A",
			"focus": ["chest"],
			"est_minutes": 40,
			"warmup": [{"exercise_id": "world-greatest-stretch", "duration_sec": 45}],
			"blocks": [{"exercise_id": "bench-press", "sets": 3, "reps": "8-10",
				"rest_seconds": 90}],
			"cooldown": [{"exercise_id": "childs-pose", "duration_sec": 60}],
		}],
	}


## The entry with [param entry_id], or `{}` — order-independent for stable assertions.
func _entry_by_id(store: Node, entry_id: String) -> Dictionary:
	for entry in store.all_entries():
		if String(entry.get("id", "")) == entry_id:
			return entry
	return {}


## Sorted-key JSON, so two views can be compared without depending on key order.
func _fingerprint(value: Variant) -> String:
	return JSON.stringify(value, "", true, false)


# ------------------------------------------------------------------ filesystem helpers

## Wipes and recreates a directory under res://.test_tmp/ (which is writable, unlike
## user://), and keeps Godot's importer out of it.
func _fresh(dir_path: String) -> String:
	_remove_tree(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)
	_write_gdignore()
	return JsonStore.normalize_dir(dir_path)


func _write_gdignore() -> void:
	var path := TMP_ROOT + ".gdignore"
	if FileAccess.file_exists(path):
		return
	DirAccess.make_dir_recursive_absolute(TMP_ROOT)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string("# Generated by tests/suites/test_store.gd — keeps the importer out.\n")
		file.close()


func _remove_tree(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	for entry in DirAccess.get_files_at(dir_path):
		DirAccess.remove_absolute(dir_path.path_join(entry))
	for entry in DirAccess.get_directories_at(dir_path):
		_remove_tree(dir_path.path_join(entry))
	DirAccess.remove_absolute(dir_path)


func _write_raw(dir_path: String, file_name: String, text: String) -> void:
	_write_raw_absolute(dir_path.path_join(file_name), text)


func _write_raw_absolute(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


func _read_raw(dir_path: String, file_name: String) -> String:
	return _read_raw_absolute(dir_path.path_join(file_name))


func _read_raw_absolute(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _read_json(dir_path: String, file_name: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(_read_raw(dir_path, file_name))
	return parsed if parsed is Dictionary else {}


func _list(dir_path: String) -> PackedStringArray:
	if not DirAccess.dir_exists_absolute(dir_path):
		return PackedStringArray()
	return DirAccess.get_files_at(dir_path)


func _file_size(dir_path: String, file_name: String) -> float:
	return float(_read_raw(dir_path, file_name).length())


func _has_tmp(dir_path: String) -> bool:
	for entry in _list(dir_path):
		if entry.ends_with(".tmp"):
			return true
	return false


func _cleanup() -> void:
	_remove_tree(SUITE_DIR)
