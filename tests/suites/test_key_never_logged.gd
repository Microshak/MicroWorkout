extends TestSuite
## PRD-07 R12 — the API key never leaves the three places it is allowed to be.
##
## R12 allows the key in exactly three places: `settings.json` `llm.api_key`, the `LLMClient`
## request under construction, and PRD-06's masked `LineEdit`. Everything else — logs,
## `push_error`, toasts, `redacted_detail`, `user_message`, `plan.generation`, the overlay's
## labels — must be key-free.
##
## Three independent checks, because each one alone is escapable:
##
##   1. **Captured log lines.** [member LLMClient.log_sink] hands this suite the exact text the
##      client would print for every branch below (that is the seam's only purpose), and every
##      line is searched for the key, the key's percent-encoded form, and any URL-shaped text.
##   2. **Every value the user or the store can see.** `user_message`, `error.redacted_detail`,
##      the whole `plan` (including `plan.generation`) and [method LLMResult.to_dictionary] are
##      serialised and searched the same way.
##   3. **A source scan over the files PRD-07 owns.** Any `print()` that mentions a key, a URL, a
##      header or a body fails the build, so the check survives the next person who adds a log
##      line. `scripts/core/redact.gd` is exempt by path for the same reason PRD-06 exempted it:
##      it *is* the scrubber, and it holds no secret.

const LLM_SCRIPT := "res://scripts/autoload/llm.gd"
const FIXTURE_PATH := "res://tools/fixtures/mock_plan_valid.json"
const KEY := "sk-test-0000000000"
const SECRET_PATTERN := "sk-[A-Za-z0-9]{8,}"

## The files this PRD owns that may hold a secret at any moment. `redact.gd` is deliberately
## absent (see the file header).
const SCANNED_FILES: PackedStringArray = [
	"res://scripts/core/llm_client.gd",
	"res://scripts/core/llm_result.gd",
	"res://scripts/core/llm_providers.gd",
	"res://scripts/core/plan_prompt.gd",
	"res://scripts/core/plan_validator.gd",
	"res://scripts/autoload/llm.gd",
	"res://scripts/ui/generating_overlay.gd",
]

## Tokens that must never appear inside a `print(...)` argument list in those files.
const FORBIDDEN_IN_PRINTS: PackedStringArray = [
	"api_key", "Authorization", "x-api-key", "headers", "\"url\"", "request[\"url\"]",
	"body", "key=", "secret",
]

const INPUT: Dictionary = {
	"goal": "hypertrophy",
	"days_per_week": 4,
	"duration_min": 40,
	"areas": ["chest", "back", "shoulders", "core"],
	"equipment": ["barbell", "machine", "cable", "dumbbell", "bodyweight"],
	"notes": "no deadlift",
	"id": "plan-1758000000",
	"created_at": "2026-09-15T00:00:00Z",
}

const CFG: Dictionary = {
	"provider": "custom",
	"base_url": "http://127.0.0.1:8765/v1",
	"model": "deepseek-chat",
	"api_key": KEY,
	"custom_auth_none": false,
	"custom_json_mode": true,
}


class FakeTransport extends RefCounted:
	var replies: Array = []
	var order: int = 0

	func _init(canned: Array) -> void:
		replies = canned

	func request(_req: Dictionary) -> Dictionary:
		if replies.is_empty():
			return {"result": HTTPRequest.RESULT_CANT_CONNECT, "status": 0, "body": ""}
		var reply: Dictionary = replies[mini(order, replies.size() - 1)]
		order += 1
		return reply

	func cancel() -> void:
		pass


class Harness extends RefCounted:
	var llm: Node = null
	var client: Node = null
	var lines: Array = []
	var cfg: Dictionary = {}

	func run(opts: Dictionary = {}) -> Dictionary:
		var merged: Dictionary = {"cfg": cfg, "seed": 7}
		for field in opts.keys():
			merged[field] = opts[field]
		var result: Variant = llm.call("generate_plan", INPUT, merged)
		if result is Dictionary:
			return result
		return {}

	## Everything the client asked to log, joined.
	func log_text() -> String:
		return "\n".join(PackedStringArray(lines.map(func(line: Variant) -> String:
			return str(line))))

	func dispose() -> void:
		if llm != null and is_instance_valid(llm):
			llm.free()
		llm = null
		client = null


func _init() -> void:
	suite_name = "key_never_logged"


func run() -> void:
	_test_every_failure_mode()
	_test_success_path()
	_test_gemini_url_is_never_logged()
	_test_result_objects_are_clean()
	_test_copy_table_is_clean()
	_test_generation_block_is_clean()
	_test_redaction_helper_contract()
	_test_source_scan()


# ------------------------------------------------------------------ the failure modes

func _test_every_failure_mode() -> void:
	begin("every failure branch logs, shows and stores no key (R12's acceptance criterion)")
	var modes: Dictionary = {
		"valid": [_openai(_fixture_text())],
		"malformed then valid": [_openai("{\"name\":"), _openai(_fixture_text())],
		"malformed twice": [_openai("nope"), _openai("nope")],
		"schema_invalid twice": [_openai(_invalid_text()), _openai(_invalid_text())],
		"http400": [_reply(400, "{\"error\": {\"message\": \"bad request\"}}")],
		"http401": [_reply(401, "{\"error\": {\"message\": \"Invalid API key: " + KEY + "\"}}")],
		"http403": [_reply(403, "{\"error\": {\"message\": \"forbidden " + KEY + "\"}}")],
		"http404": [_reply(404, "{}")],
		"http429": [_reply(429, "{\"error\": {\"message\": \"rate limited\"}}")],
		"http500": [_reply(500, "{\"error\": {\"message\": \"upstream " + KEY + "\"}}")],
		"timeout x3": [_transport_failure(HTTPRequest.RESULT_TIMEOUT)],
		"refused x3": [_transport_failure(HTTPRequest.RESULT_CANT_CONNECT)],
		"tls x3": [_transport_failure(HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR)],
		"body size overflow": [_transport_failure(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED)],
		"device blocked": [_reply(200, "{}")],
		"no key": [_openai(_fixture_text())],
		"empty catalog": [_openai(_fixture_text())],
	}
	# The three branches that never reach a provider: no request log line exists for them, which
	# is itself the property being asserted (the gate must not log anything either).
	var gated: PackedStringArray = ["no key", "empty catalog", "device blocked"]
	var keys: Array = modes.keys()
	keys.sort()
	for name in keys:
		var harness := _harness(modes[name])
		var opts: Dictionary = {}
		if String(name) == "no key":
			opts["cfg"] = _cfg_without_key()
		elif String(name) == "empty catalog":
			opts["catalog"] = []
		elif String(name) == "device blocked":
			opts["allow_llm"] = false
		var result: Dictionary = await harness.run(opts)
		_assert_clean("log lines for '%s'" % name, harness.log_text())
		_assert_clean("user_message for '%s'" % name, String(result["user_message"]))
		_assert_clean("error for '%s'" % name, JSON.stringify(result["error"]))
		_assert_clean("plan for '%s'" % name, JSON.stringify(result["plan"]))
		if gated.has(String(name)):
			assert_eq(harness.lines.size(), 0, "'%s' never reaches a provider, so it must not log "
				% name)
		else:
			assert_true(harness.lines.size() > 0, "'%s' produced at least one log line" % name)
		harness.dispose()

	begin("a provider that echoes the key back is scrubbed in redacted_detail")
	var echoing := _harness([_reply(401, "{\"error\": {\"message\": \"Invalid API key: " + KEY
		+ "\", see https://example.test/v1/chat/completions?key=" + KEY + "\"}}")])
	var result_echo: Dictionary = await echoing.run()
	var detail := String(result_echo["error"]["redacted_detail"])
	assert_false(detail.contains(KEY), "the key is gone")
	assert_true(detail.contains(Redact.PLACEHOLDER), "[REDACTED] is in its place")
	assert_true(detail.contains("Invalid API key"), "the useful part of the message survives")
	_assert_clean("echoed detail", detail)
	echoing.dispose()

	begin("a transport-level failure detail carries no URL either")
	var refused := _harness([_transport_failure(HTTPRequest.RESULT_CANT_CONNECT)])
	var result_refused: Dictionary = await refused.run()
	assert_false(String(result_refused["error"]["redacted_detail"]).contains("http"),
		"no URL in a transport detail")
	assert_eq(String(result_refused["error"]["redacted_detail"]), "connection refused",
		"a plain description instead")
	refused.dispose()


func _test_success_path() -> void:
	begin("the successful path is key-free too")
	var harness := _harness([_openai(_fixture_text())])
	var result: Dictionary = await harness.run()
	assert_true(bool(result["ok"]), "ok")
	_assert_clean("success log lines", harness.log_text())
	_assert_clean("success user_message", String(result["user_message"]))
	_assert_clean("success error", JSON.stringify(result["error"]))
	_assert_clean("success plan", JSON.stringify(result["plan"]))

	begin("the digest in the log stands in for the catalog, which is never logged")
	assert_true(harness.log_text().contains("catalog=" + String(result["plan"]["generation"]
		["catalog_digest"]).substr(0, 8)), "the digest prefix is logged")
	assert_false(harness.log_text().contains("bench-press"),
		"but no catalog text is: the log line must not carry the prompt")
	assert_eq(harness.log_text().count("[llm] provider="), 1, "exactly one line per request")

	begin("the request itself is not logged, in any form")
	for token in PackedStringArray(["http://", "https://", "Authorization", "Content-Type",
			"{\"model\"", "messages"]):
		assert_false(harness.log_text().contains(token), "the log must not contain '%s'" % token)
	harness.dispose()


func _test_gemini_url_is_never_logged() -> void:
	begin("Gemini's ?key= URL is the radioactive case: it never reaches a log (R12)")
	var harness := _harness([_gemini(_fixture_text())], {"provider": "gemini",
		"base_url": "https://generativelanguage.googleapis.com/v1beta",
		"model": "gemini-1.5-flash"})
	var result: Dictionary = await harness.run()
	assert_true(bool(result["ok"]), "ok")
	_assert_clean("gemini log lines", harness.log_text())
	_assert_clean("gemini plan", JSON.stringify(result["plan"]))
	assert_false(harness.log_text().contains("generativelanguage"), "not even the host")
	assert_eq(String(result["error"]["redacted_detail"]), "", "and no detail on the happy path")
	harness.dispose()

	begin("a Gemini failure body that quotes the URL is scrubbed")
	var failure := _harness([_reply(400, "{\"error\": {\"message\": \"bad request to "
		+ "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:"
		+ "generateContent?key=" + KEY + "\"}}")], {"provider": "gemini",
		"base_url": "https://generativelanguage.googleapis.com/v1beta"})
	var result_failure: Dictionary = await failure.run()
	var detail := String(result_failure["error"]["redacted_detail"])
	assert_false(detail.contains(KEY), "the key is gone from the detail")
	assert_false(detail.contains("key=" + KEY), "including in its query form")
	_assert_clean("gemini failure detail", detail)
	_assert_clean("gemini failure logs", failure.log_text())
	failure.dispose()


func _test_result_objects_are_clean() -> void:
	begin("an LLMResult never stores the key, whatever it is constructed with")
	var result := LLMResult.failure("auth", "custom", "deepseek-chat", "openai_compatible", 401, 12,
		1, "Invalid API key: " + KEY, KEY)
	var dumped := JSON.stringify(result.to_dictionary())
	_assert_clean("LLMResult.to_dictionary()", dumped)
	assert_false(result.text.contains(KEY), "text is empty, not an echo of the request")
	assert_true(result.usage.is_empty(), "and no usage was invented")

	begin("the provider table and the prompt contain no key")
	_assert_clean("LLMProviders merged table",
		JSON.stringify(LLMProviders.merged("custom")))
	for key in LLMProviders.keys():
		_assert_clean("shape row %s" % key, JSON.stringify(LLMProviders.shape(key)))
	_assert_clean("system prompt", PlanPrompt.system_prompt())
	_assert_clean("user prompt template", PlanPrompt.USER_PROMPT_TEMPLATE)
	_assert_clean("repair template", PlanPrompt.REPAIR_TEMPLATE)


func _test_copy_table_is_clean() -> void:
	begin("every R6 copy line is key-free, in every provider's words (R12)")
	for key in LLMProviders.keys():
		for reason in PackedStringArray(["", "no_key", "no_network", "tls", "timeout", "auth",
				"forbidden", "bad_path", "rate_limited", "server", "bad_response", "truncated",
				"blocked", "parse", "validation", "cancelled", "busy"]):
			var harness := _harness([])
			var copy := String(harness.llm.call("_copy", reason,
				LLMProviders.label_for(key), reason.is_empty()))
			_assert_clean("copy(%s, %s)" % [reason, key], copy)
			assert_false(copy.is_empty(), "copy(%s, %s) is not empty" % [reason, key])
			harness.dispose()

	begin("no copy line mentions a URL, a header or the word 'key' as a value")
	var harness := _harness([])
	for reason in PackedStringArray(["auth", "bad_path", "no_network"]):
		var copy := String(harness.llm.call("_copy", reason, "DeepSeek", false))
		assert_false(copy.contains("http"), "no URL in the copy for %s" % reason)
		assert_false(copy.contains("Bearer"), "no header in the copy for %s" % reason)
	assert_true(String(harness.llm.call("_copy", "auth", "DeepSeek", false)).contains(
		"rejected the saved API key"), "the copy describes the problem without the secret")
	harness.dispose()


func _test_generation_block_is_clean() -> void:
	begin("plan.generation carries the digests and never a credential (R12)")
	var harness := _harness([_reply(200, JSON.stringify({"choices": [{"message": {"content":
		_fixture_text()}, "finish_reason": "stop"}]}))])
	var result: Dictionary = await harness.run()
	var generation: Dictionary = result["plan"]["generation"]
	var dumped := JSON.stringify(generation)
	_assert_clean("plan.generation", dumped)
	assert_eq(generation.size(), 8, "eight documented fields")
	for field in PackedStringArray(["attempts", "repaired", "error_code", "provider", "model",
			"latency_ms", "catalog_digest", "prompt_version"]):
		assert_has_key(generation, field, "missing %s" % field)
	assert_false(dumped.contains("api_key"), "no key field")
	assert_false(dumped.contains("base_url"), "and no URL field either")
	assert_false(dumped.contains(KEY), "and no value")
	harness.dispose()


func _test_redaction_helper_contract() -> void:
	begin("Redact.safe_error is the only scrubber, and it is applied at construction")
	var long_key := "sk-verylongtestkey1234567890"
	var detail := "request to https://api.example.test/v1/chat/completions?key=" + long_key \
		+ " failed with Bearer " + long_key
	var scrubbed := Redact.safe_error(detail, long_key)
	assert_false(scrubbed.contains(long_key), "the key is gone")
	assert_false(scrubbed.contains(long_key.uri_encode()), "and so is its encoded form")
	assert_true(scrubbed.contains(Redact.PLACEHOLDER), "[REDACTED] appears")
	assert_le(float(scrubbed.length()), 300.0, "and the result is capped")

	begin("a key-shaped value is scrubbed even when the scrubber was not told the key")
	var caught := Redact.safe_error("the server answered: " + KEY, "")
	assert_false(caught.contains(KEY), "the sk- pattern is caught without help")
	assert_true(caught.contains(Redact.PLACEHOLDER), "replaced")

	begin("contains_secret() is the predicate the suites and the UI use")
	assert_true(Redact.contains_secret("x " + KEY + " y", KEY), "verbatim")
	assert_true(Redact.contains_secret("x " + KEY.uri_encode() + " y", KEY), "percent-encoded")
	assert_false(Redact.contains_secret("nothing here", KEY), "absent")
	assert_false(Redact.contains_secret("", KEY), "empty text")
	assert_false(Redact.contains_secret(KEY, ""), "no secret to look for")

	begin("mask_key() is for display and is stable, never a leak of the middle")
	var masked := Redact.mask_key(long_key)
	assert_false(masked.contains("testkey"), "the middle is hidden")
	assert_true(masked.begins_with("sk-"), "the head is kept for recognition")
	assert_true(masked.ends_with("7890"), "the tail is kept")
	assert_eq(Redact.mask_key(masked), masked, "masking a mask is idempotent")
	assert_eq(Redact.mask_key(""), "", "an unset key renders as nothing")


# ------------------------------------------------------------------ the source scan

func _test_source_scan() -> void:
	begin("no print() in the files PRD-07 owns mentions a key, a URL, a header or a body")
	var checked := 0
	for path in SCANNED_FILES:
		if not FileAccess.file_exists(path):
			# A file that does not exist yet (the overlay lands with R9) is skipped rather than
			# silently counted as clean.
			assert_true(path == "res://scripts/ui/generating_overlay.gd",
				"%s exists" % path)
			continue
		checked += 1
		var source := FileAccess.get_file_as_string(path)
		assert_false(source.is_empty(), "%s is readable" % path)
		var line_number := 0
		for line in source.split("\n"):
			line_number += 1
			var text := String(line)
			if not text.contains("print("):
				continue
			for token in FORBIDDEN_IN_PRINTS:
				assert_false(text.contains(token),
					"%s:%d logs '%s'" % [path.get_file(), line_number, token])

	begin("the scan really looked at the files that hold the secret")
	assert_ge(float(checked), 6.0, "six files were scanned")

	begin("only the four files on the request path may even name the key")
	# `llm.gd` reads it out of settings, `llm_client.gd` puts it in a header or a URL,
	# `llm_providers.gd` knows where it goes and `llm_result.gd` scrubs it. The prompt builder,
	# the validator and the overlay must not reference it at all.
	var allowed: PackedStringArray = [
		"res://scripts/core/llm_client.gd",
		"res://scripts/core/llm_result.gd",
		"res://scripts/core/llm_providers.gd",
		"res://scripts/autoload/llm.gd",
	]
	for path in SCANNED_FILES:
		if not FileAccess.file_exists(path) or allowed.has(path):
			continue
		var source := FileAccess.get_file_as_string(path)
		assert_false(source.contains("api_key"),
			"%s must not reference api_key at all" % path.get_file())

	begin("the log sink seam exists and is what produced the lines above")
	var client: Node = (load("res://scripts/core/llm_client.gd") as GDScript).new()
	assert_true(client.get("log_sink") is Callable, "log_sink is a Callable")
	assert_false((client.get("log_sink") as Callable).is_valid(),
		"and it is unset in production, so nothing is captured or forwarded")
	client.free()


# ------------------------------------------------------------------ helpers

func _fixture_text() -> String:
	return FileAccess.get_file_as_string(FIXTURE_PATH)


func _invalid_text() -> String:
	return FileAccess.get_file_as_string("res://tools/fixtures/mock_plan_invalid.json")


func _openai(text: String, finish: String = "stop") -> Dictionary:
	return {"result": HTTPRequest.RESULT_SUCCESS, "status": 200, "body": JSON.stringify({
		"choices": [{"index": 0, "message": {"role": "assistant", "content": text},
			"finish_reason": finish}],
	})}


## The Gemini wire shape (R2 C): the same plan text, in the envelope that adapter expects.
func _gemini(text: String) -> Dictionary:
	return {"result": HTTPRequest.RESULT_SUCCESS, "status": 200, "body": JSON.stringify({
		"candidates": [{"content": {"parts": [{"text": text}]}, "finishReason": "STOP"}],
	})}


func _reply(status: int, body: String) -> Dictionary:
	return {"result": HTTPRequest.RESULT_SUCCESS, "status": status, "body": body}


func _transport_failure(result: int) -> Dictionary:
	return {"result": result, "status": 0, "body": ""}


func _cfg_without_key() -> Dictionary:
	var cfg := CFG.duplicate()
	cfg["api_key"] = ""
	return cfg


func _harness(replies: Array, cfg_overrides: Dictionary = {}) -> Harness:
	var harness := Harness.new()
	harness.llm = (load(LLM_SCRIPT) as GDScript).new()
	harness.client = harness.llm.call("_ensure_client")
	harness.client.set("transport", FakeTransport.new(replies))
	var cfg := CFG.duplicate()
	for field in cfg_overrides.keys():
		cfg[field] = cfg_overrides[field]
	harness.cfg = cfg
	var lines: Array = harness.lines
	harness.client.set("log_sink", func(line: String) -> void: lines.append(line))
	return harness


## Fails when [param text] contains the key, its encodings, or anything key-shaped.
func _assert_clean(label: String, text: String) -> void:
	assert_false(text.contains(KEY), "%s must not contain the key" % label)
	assert_false(text.contains(KEY.uri_encode()), "%s must not contain the encoded key" % label)
	assert_false(Redact.contains_secret(text, KEY), "%s must not contain the key in any form"
		% label)
	var pattern := RegEx.new()
	pattern.compile(SECRET_PATTERN)
	assert_true(pattern.search(text) == null, "%s must not contain key-shaped text" % label)
	assert_false(text.contains("key=" + KEY), "%s must not contain a key= parameter" % label)
