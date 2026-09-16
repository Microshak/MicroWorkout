extends Node
## PRD-07 R6 — the resilience ladder: the app's single entry point for plan creation.
##
## [b]Contract (appendix §1.4).[/b] `LLM.generate_plan(input, opts)` always returns a usable plan
## — one written by a provider, or the PRD-05 built-in generator — except when the user cancelled
## (`ok == false`, `source == ""`, `plan == {}`) or another generation is already running
## (`reason_code == "busy"`). It never saves anything: PRD-08 saves after the user confirms.
##
## [b]The ladder, in order (R6):[/b] gate → single-flight → call → transport retries → HTTP
## status (never retried) → validate → **one** repair retry at temperature 0.2 → built-in
## fallback. Every branch ends in the same result shape, and every branch that reached a provider
## attaches `plan.generation` so a stored plan can always be traced back to what happened.
##
## [b]Testability (R11).[/b] Three seams make the whole ladder run headlessly and synchronously —
## no socket, no autoload, no main-loop iteration:
##   * `opts.cfg`   — the `llm` config block instead of reading it from `Store`
##   * `opts.catalog` — the ALLOWED EXERCISES list instead of `Library`/`res://data`
##   * [member LLMClient.transport] / [member LLMClient.delay_seam] — the transport and the
##     R7 backoff
## `tests/suites/test_llm_ladder.gd` drives every branch through them.
##
## [b]Key discipline (R12).[/b] This file never logs, copies, stores or emits the API key. The
## only provider-derived text that can leave is `Redact.safe_error()`'d (in [LLMResult]) and the
## only URL-shaped value is never logged at all.

## Emitted once per [method generate_plan], after `is_generating` has been cleared (R6 step 10).
signal generation_finished(result: Dictionary)
## `Attempt 2 of 3`, for the generating overlay's sub-label (R9). Additive: the appendix pins only
## `generation_finished`, and nothing has to listen to this.
signal generation_progress(attempt: int, total: int)

## True between [method generate_plan] starting and its result being settled. Second callers get
## `reason_code == "busy"` and no fallback (R6 step 2).
var is_generating: bool = false

## `opts` keys (R6). `cfg` and `catalog` are the two headless seams documented above.
const DEFAULT_TIMEOUT_SEC: int = 45
const DEFAULT_MAX_ATTEMPTS: int = 3

var _client: LLMClient = null
var _probe: LLMProbe = null
var _cancelled: bool = false
var _labels: Dictionary = {}


func _ready() -> void:
	_ensure_client()
	_ensure_probe()
	print("[llm] ready — prompt=%s adapters=%s" % [
		PlanPrompt.PROMPT_VERSION, ", ".join(LLMProviders.ADAPTERS)])


# ===========================================================================
# R6 — generate_plan
# ===========================================================================

## The ladder. **Await it:**
##     var result: Dictionary = await LLM.generate_plan(input, {"seed": 1})
##
## [param input] is the PRD-05 generator input (`goal`, `days_per_week`, `duration_min`, `areas`,
## `equipment`, `notes`), plus optional `id`/`created_at`/`provider` identity fields. [param opts]:
## `seed` (int, fallback only), `timeout_sec` (45), `max_attempts` (3), `allow_llm` (true),
## `provider_label` (String, for the copy), `cfg`, `catalog`.
##
## Returns `{"ok": bool, "plan": Dictionary, "source": "llm"|"builtin"|"", "reason_code": String,
## "user_message": String, "attempts": int, "repaired": bool,
## "error": {"code", "http_status", "redacted_detail", "latency_ms"}}`.
func generate_plan(input: Dictionary, opts: Dictionary = {}) -> Dictionary:
	if is_generating:
		# R6 step 2 — no fallback, no save: the in-flight generation owns the outcome.
		return _result(false, {}, "", "busy", _copy("busy", _label_for(opts)), 0, false,
			_error("", 0, "", 0))
	_cancelled = false
	is_generating = true
	var result := await _ladder(input, opts)
	# The `finally`-equivalent: `is_generating` is cleared before either emit or return.
	is_generating = false
	generation_finished.emit(result)
	return result


## Cancels an in-flight generation (R6 step 9): the request is dropped, no fallback runs and
## nothing is saved. Safe to call when nothing is running.
func cancel() -> void:
	_cancelled = true
	if _client != null and is_instance_valid(_client):
		_client.cancel()


## The complete R9 `Test connection` result for [param cfg], delegated to [LLMProbe] — one
## attempt, 20 s, no retries, and the same provider table this client uses. **Await it.**
func test_connection(cfg: Dictionary) -> Dictionary:
	var probe := _ensure_probe()
	if probe == null:
		return LLMProviders.failure_result("no_network",
			String(cfg.get("provider", LLMProviders.DEFAULT_KEY)),
			String(cfg.get("base_url", "")), 0, 0, "no probe available",
			String(cfg.get("api_key", "")))
	return await probe.run(cfg)


## Aborts an in-flight `Test connection` (PRD-06 R9).
func cancel_test_connection() -> void:
	if _probe != null and is_instance_valid(_probe):
		_probe.cancel()


## True when a provider is configured well enough to attempt a request — the R6 step 1 gate,
## exposed so a screen can grey out a button without duplicating the rule.
func is_configured(cfg: Dictionary = {}) -> bool:
	var config := cfg if not cfg.is_empty() else _config({})
	var provider := String(config.get("provider", LLMProviders.DEFAULT_KEY))
	if LLMProviders.base_url_for(provider, config).is_empty():
		return false
	if not LLMProviders.requires_key(provider, config):
		return true
	return not String(config.get("api_key", "")).strip_edges().is_empty()


# ===========================================================================
# R6 — the ladder itself
# ===========================================================================

func _ladder(input: Dictionary, opts: Dictionary) -> Dictionary:
	var seed := PlanModel.as_int(opts.get("seed"), 0)
	var timeout_sec := PlanModel.as_int(opts.get("timeout_sec"), DEFAULT_TIMEOUT_SEC)
	var max_attempts := maxi(1, PlanModel.as_int(opts.get("max_attempts"), DEFAULT_MAX_ATTEMPTS))
	var allow_llm := bool(opts.get("allow_llm", true))

	var cfg := _config(opts)
	var provider := String(cfg.get("provider", LLMProviders.DEFAULT_KEY))
	if not LLMProviders.has(provider):
		provider = LLMProviders.DEFAULT_KEY
	var model := LLMProviders.model_for(provider, cfg)
	var label := _label_for(opts, provider)
	var digest := ""
	var attempts := 0
	var latency := 0
	var http_status := 0
	var detail := ""

	# --- step 1: gate. No key, no base URL or `allow_llm == false` never touches the network and
	# never counts an attempt.
	var api_key := String(cfg.get("api_key", "")).strip_edges()
	var base_url := LLMProviders.base_url_for(provider, cfg)
	if not allow_llm or base_url.is_empty() \
			or (LLMProviders.requires_key(provider, cfg) and api_key.is_empty()):
		return _fallback(input, seed, "no_key", 0, provider, model, label, digest, 0, 0)

	# --- step 3: the catalog and the prompt. R10: an empty catalog is the missing library, which
	# no provider can fix.
	var catalog := _catalog(opts, input)
	if catalog.is_empty():
		print("[llm] catalog empty — using built-in generator")
		return _fallback(input, seed, "validation", 0, provider, model, label, digest, 0, 0)
	var lines := PlanPrompt.catalog_lines(catalog)
	digest = PlanPrompt.catalog_digest(lines)
	var user_prompt := PlanPrompt.user_prompt(input, catalog)

	var client := _ensure_client()
	if client == null:
		return _fallback(input, seed, "no_network", 0, provider, model, label, digest, 0, 0)
	var call_opts := {
		"timeout_sec": timeout_sec,
		"retries": max_attempts - 1,
		"catalog_digest": digest,
		"prompt_version": PlanPrompt.PROMPT_VERSION,
	}

	# --- steps 4/5: the first call. The client owns the transport retries and the never-retry
	# rule for HTTP statuses; this ladder only decides what a failure means.
	var first: LLMResult = await client.generate(cfg, PlanPrompt.system_prompt(), user_prompt,
		call_opts)
	attempts += first.attempts
	latency += first.latency_ms
	http_status = first.http_status
	if _cancelled:
		return _cancelled_result(attempts, latency, provider, model)
	if not first.ok:
		return _fallback(input, seed, _reason_for(first.error_code), attempts, provider, model,
			label, digest, latency, http_status, first.redacted_detail)

	# --- step 6: validate.
	var validation := PlanValidator.validate(first.text, catalog, input)
	if bool(validation["ok"]):
		return _llm_result(validation, attempts, false, provider, model, label, digest, latency,
			200)

	# --- step 7: exactly one repair, colder, with the validator's own error list fed back.
	var repair_opts := call_opts.duplicate()
	repair_opts["temperature"] = LLMClient.REPAIR_TEMPERATURE
	var repair_prompt := PlanPrompt.repair_prompt(user_prompt, validation["errors"], first.text)
	var repair: LLMResult = await client.generate(cfg, PlanPrompt.system_prompt(), repair_prompt,
		repair_opts)
	attempts += repair.attempts
	latency += repair.latency_ms
	if _cancelled:
		return _cancelled_result(attempts, latency, provider, model)
	if repair.ok:
		var second := PlanValidator.validate(repair.text, catalog, input)
		if bool(second["ok"]):
			return _llm_result(second, attempts, true, provider, model, label, digest, latency,
				200)
		_repair_failed(second, provider, model)
		return _fallback(input, seed, _reason_from_errors(second), attempts, provider, model,
			label, digest, latency, 200)
	_repair_failed(validation, provider, model)
	return _fallback(input, seed, _reason_for(repair.error_code), attempts, provider, model, label,
		digest, latency, repair.http_status, repair.redacted_detail)


## One greppable line when the single repair retry did not rescue the plan (R6 step 7). It carries
## no catalog text, no raw reply and no key — only counts and codes.
func _repair_failed(validation: Dictionary, provider: String, model: String) -> void:
	var codes := PackedStringArray()
	for error in validation["errors"]:
		var code := String((error as Dictionary).get("code", ""))
		if not codes.has(code):
			codes.append(code)
	print("[llm] repair_failed provider=%s model=%s reason=%s errors=%d codes=%s dropped=%d" % [
		provider, model, _reason_from_errors(validation), (validation["errors"] as Array).size(),
		",".join(codes), (validation["dropped"] as PackedStringArray).size()])


# ------------------------------------------------------------------ outcomes

## The provider path: the validated plan plus its `generation` attachment (R6 step 8).
func _llm_result(validation: Dictionary, attempts: int, repaired: bool, provider: String,
		model: String, label: String, digest: String, latency: int,
		http_status: int) -> Dictionary:
	var plan: Dictionary = validation["plan"]
	plan["source"] = "llm"
	plan["provider"] = provider
	plan["generation"] = _generation(attempts, repaired, "", provider, model, latency, digest)
	_dropped_note(validation, provider)
	return _result(true, plan, "llm", "", _copy("", label, repaired), attempts, repaired,
		_error("", http_status, "", latency))


## The built-in path (R6 step 8): `Generator.build_plan()`, renamed, un-provided and annotated
## with the reason it was needed.
func _fallback(input: Dictionary, seed: int, reason_code: String, attempts: int, provider: String,
		model: String, label: String, digest: String, latency: int, http_status: int = 0,
		detail: String = "") -> Dictionary:
	var plan := Generator.build_plan(input, seed)
	if plan.has("error"):
		# The built-in generator could not run either (`no areas`, `library_not_loaded`). There is
		# no plan to return, so the result is a failure — still with the full result shape.
		print("[llm] builtin_failed reason=%s" % String(plan.get("error", "")))
		return _result(false, {}, "", reason_code, _copy(reason_code, label), attempts, false,
			_error(reason_code, http_status, detail, latency))
	plan["source"] = "builtin"
	plan["provider"] = ""
	plan["name"] = "Built-in: %s" % String(plan.get("split_name", ""))
	plan["generation"] = _generation(attempts, false, reason_code, provider, model, latency,
		digest)
	print("[llm] fallback reason=%s attempts=%d provider=%s" % [reason_code, attempts, provider])
	return _result(true, plan, "builtin", reason_code, _copy(reason_code, label), attempts, false,
		_error(reason_code, http_status, detail, latency))


## Cancel (R6 step 9): no fallback, nothing saved, no provider label in the copy.
func _cancelled_result(attempts: int, latency: int, provider: String, model: String) -> Dictionary:
	print("[llm] cancelled attempts=%d provider=%s" % [attempts, provider])
	return _result(false, {}, "", "cancelled", _copy("cancelled", ""), attempts, false,
		_error("cancelled", 0, "", latency))


## `plan.generation` — the additive §5.2 field PRD-08/09 render and PRD-07 R12 keeps key-free.
func _generation(attempts: int, repaired: bool, error_code: String, provider: String,
		model: String, latency: int, digest: String) -> Dictionary:
	return {
		"attempts": attempts,
		"repaired": repaired,
		"error_code": error_code,
		"provider": provider,
		"model": model,
		"latency_ms": latency,
		"catalog_digest": digest,
		"prompt_version": PlanPrompt.PROMPT_VERSION,
	}


func _dropped_note(validation: Dictionary, provider: String) -> void:
	var dropped: PackedStringArray = validation["dropped"]
	var repaired: PackedStringArray = validation["repaired"]
	if dropped.is_empty() and repaired.is_empty():
		return
	print("[llm] validated provider=%s dropped=%d repaired=%d blocks=%d" % [provider,
		dropped.size(), repaired.size(), int((validation["stats"] as Dictionary)["blocks"])])


func _result(ok: bool, plan: Dictionary, source: String, reason_code: String, user_message: String,
		attempts: int, repaired: bool, error: Dictionary) -> Dictionary:
	return {
		"ok": ok,
		"plan": plan,
		"source": source,
		"reason_code": reason_code,
		"user_message": user_message,
		"attempts": attempts,
		"repaired": repaired,
		"error": error,
	}


func _error(code: String, http_status: int, redacted_detail: String,
		latency_ms: int) -> Dictionary:
	return {
		"code": code,
		"http_status": http_status,
		"redacted_detail": Redact.safe_error(redacted_detail),
		"latency_ms": latency_ms,
	}


# ------------------------------------------------------------------ reason codes and copy

## The client's `error_code` is already the ladder's `reason_code` for every transport and HTTP
## branch (the vocabularies are one closed set, R3). This exists so the mapping is explicit and
## testable rather than an implicit pass-through.
static func _reason_for(error_code: String) -> String:
	if error_code.is_empty():
		return "validation"
	if LLMResult.is_known_code(error_code):
		return error_code
	return "bad_response"


## `parse` when the reply could not even be read as JSON, `validation` when it was readable but
## broke a rule (R6's copy table renders both the same way).
static func _reason_from_errors(validation: Dictionary) -> String:
	var errors: Array = validation["errors"]
	for error in errors:
		var code := String((error as Dictionary).get("code", ""))
		if code != "E_NOT_JSON" and code != "E_ROOT_TYPE":
			return "validation"
	if errors.is_empty():
		return "validation"
	return "parse"


## R6's copy table, verbatim. `<P>` is the provider label. The strings never contain a key, a URL
## with `key=`, or any part of a response body — they are safe to toast, log and store.
func _copy(reason_code: String, label: String, repaired: bool = false) -> String:
	var provider := label if not label.is_empty() else "your AI provider"
	match reason_code:
		"":
			if repaired:
				return "Your plan was written by %s, after a quick fix-up." % provider
			return "Your plan was written by %s." % provider
		"no_key":
			return "No AI provider is set up yet, so MicroWorkout built your plan on-device."
		"no_network":
			return "Couldn't reach %s, so MicroWorkout built your plan on-device." % provider
		"tls":
			return ("Couldn't open a secure connection to %s, so MicroWorkout built your plan "
				+ "on-device.") % provider
		"timeout":
			return "%s took too long to answer, so MicroWorkout built your plan on-device." % provider
		"auth", "forbidden":
			return ("%s rejected the saved API key, so MicroWorkout built your plan on-device. "
				+ "Fix it in Settings → AI provider.") % provider
		"bad_path":
			return ("The AI address for %s looks wrong, so MicroWorkout built your plan "
				+ "on-device. Check the base URL in Settings.") % provider
		"rate_limited":
			return ("%s is rate-limiting this key right now, so MicroWorkout built your plan "
				+ "on-device.") % provider
		"server":
			return "%s had a server problem, so MicroWorkout built your plan on-device." % provider
		"bad_response", "truncated", "blocked":
			return ("%s sent a reply MicroWorkout couldn't use, so it built your plan on-device."
				% provider)
		"parse", "validation":
			return ("%s wrote a plan that didn't pass MicroWorkout's checks, so it built your "
				+ "plan on-device.") % provider
		"cancelled":
			return "Generation cancelled. Nothing was saved."
		"busy":
			return "A plan is already being generated."
	return "MicroWorkout built your plan on-device."


## The `provider_label` opt wins (it is what `Test plan generation` passes); otherwise the preset's
## own label.
func _label_for(opts: Dictionary, provider: String = "") -> String:
	var explicit := String(opts.get("provider_label", "")).strip_edges()
	if not explicit.is_empty():
		return explicit
	var key := provider
	if key.is_empty():
		var cfg := _config(opts)
		key = String(cfg.get("provider", LLMProviders.DEFAULT_KEY))
	return LLMProviders.label_for(key)


# ===========================================================================
# Inputs — the config and catalog seams
# ===========================================================================

## The `llm` configuration block. `opts.cfg` wins so the ladder is testable without `Store`; on
## device the values come from `settings.json` through the `Store` autoload, exactly like PRD-06's
## provider block reads them.
func _config(opts: Dictionary) -> Dictionary:
	var injected: Variant = opts.get("cfg")
	if injected is Dictionary and not (injected as Dictionary).is_empty():
		return (injected as Dictionary).duplicate()
	var cfg: Dictionary = {
		"provider": LLMProviders.DEFAULT_KEY,
		"base_url": LLMProviders.default_base_url(LLMProviders.DEFAULT_KEY),
		"model": LLMProviders.default_model(LLMProviders.DEFAULT_KEY),
		"api_key": "",
		"custom_auth_none": false,
		"custom_json_mode": true,
	}
	var store := _autoload(&"Store")
	if store == null:
		return cfg
	cfg["provider"] = _text(store.call(&"get_setting", "llm.provider", cfg["provider"]),
		cfg["provider"])
	cfg["base_url"] = _text(store.call(&"get_setting", "llm.base_url", cfg["base_url"]),
		cfg["base_url"])
	cfg["model"] = _text(store.call(&"get_setting", "llm.model", cfg["model"]), cfg["model"])
	cfg["api_key"] = _text(store.call(&"get_setting", "llm.api_key", ""), "")
	cfg["custom_auth_none"] = bool(store.call(&"get_setting", "llm.custom_auth_none", false))
	cfg["custom_json_mode"] = bool(store.call(&"get_setting", "llm.custom_json_mode", true))
	return cfg


## The ALLOWED EXERCISES list. `opts.catalog` wins (the headless seam); on device the records come
## from the `Library` autoload and are filtered by area and equipment. [PlanPrompt.filter_records]
## is used in both cases so the device and a suite cannot disagree about what the model was
## offered — it also always keeps the stretches, which the prompt's warm-up rule requires.
func _catalog(opts: Dictionary, input: Dictionary) -> Array[Dictionary]:
	var injected: Variant = opts.get("catalog")
	# `opts.has("catalog")` rather than a non-empty test: an explicitly injected *empty* catalog is
	# how a suite reaches the missing-library branch, so it must not fall through to the real one.
	if opts.has("catalog") and injected is Array:
		var typed: Array[Dictionary] = []
		for entry in injected:
			if entry is Dictionary:
				typed.append(entry)
		return typed
	var records: Array = []
	var library := _autoload(&"Library")
	if library != null and bool(library.call(&"is_ready")):
		var loaded: Variant = library.call(&"all_exercises")
		if loaded is Array:
			for record in loaded:
				records.append(record)
	if records.is_empty():
		# The pure-logic fallback: `PlanModel` reads `res://data/exercise_library.json` itself, so
		# the ladder still works with no autoloads at all (a suite under `--script`).
		var core := PlanModel.load_catalog()
		for id in core.keys():
			records.append(core[id])
	return PlanPrompt.filter_records(records, _array(input.get("areas", [])),
		_array(input.get("equipment", [])))


## An autoload by name, or `null`.
##
## [b]Why not the bare identifier:[/b] `Store` and `Library` are autoloads, and Godot only
## registers an autoload as a GDScript global once its node exists in the tree. A suite running
## under `--script` compiles this file before any autoload is created, so `Store.get_setting(...)`
## would be a compile error in exactly the context the ladder must be testable in. Looking the
## node up through the scene tree keeps this file loadable anywhere and degrades to the documented
## defaults when the app is not running.
func _autoload(singleton_name: StringName) -> Node:
	if not is_inside_tree():
		# `get_tree()` on an orphan node raises an engine error, and this file is deliberately
		# instantiable outside the tree, so the check comes first.
		return null
	var tree := get_tree()
	if tree == null:
		return null
	var tree_root := tree.root
	if tree_root == null:
		return null
	return tree_root.get_node_or_null(NodePath(String(singleton_name)))


static func _array(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array or value is PackedStringArray:
		for entry in value:
			out.append(String(entry))
	return out


static func _text(value: Variant, fallback: String) -> String:
	if value is String or value is StringName:
		return String(value)
	if value == null:
		return fallback
	return fallback


# ===========================================================================
# Nodes
# ===========================================================================

## The one [LLMClient] child, created on first use so the ladder is testable before `_ready()`.
func _ensure_client() -> LLMClient:
	if _client != null and is_instance_valid(_client):
		return _client
	_client = LLMClient.new()
	_client.name = "Client"
	_client.attempt_started.connect(_on_attempt_started)
	add_child(_client)
	return _client


func _ensure_probe() -> LLMProbe:
	if _probe != null and is_instance_valid(_probe):
		return _probe
	_probe = LLMProbe.new()
	_probe.name = "Probe"
	add_child(_probe)
	return _probe


func _on_attempt_started(attempt: int, total: int) -> void:
	generation_progress.emit(attempt, total)
