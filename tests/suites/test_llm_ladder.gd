extends TestSuite
## PRD-07 R6/R11 — the resilience ladder, proved headlessly through the injected transport.
##
## [b]How the seam works.[/b] `scripts/autoload/llm.gd` is instantiated directly, and the
## `LLMClient` child it creates gets
##
##   * [member LLMClient.transport]  — a [FakeTransport] returning canned
##     `{result, status, body}` triples, and
##   * [member LLMClient.delay_seam] — a [FakeDelay] that records the requested backoff instead of
##     waiting for it,
##
## plus `opts.cfg` / `opts.catalog` so neither `Store` nor `Library` is needed. Every canned reply
## is available synchronously, so the whole ladder — retries, HTTP classification, validation, the
## repair retry and the fallback — runs to completion inside one call: no socket, no timer, no
## scene tree, no main-loop iteration.
##
## [b]What is deliberately not simulated:[/b] the wall-clock cost of the backoff. The fake records
## the values the client asked for (1 s before attempt 2, 3 s before attempt 3), which is R7's
## contract; `scripts/dev/_run_prd07.gd` additionally measures the real elapsed time with a live
## main loop.

const LLM_SCRIPT := "res://scripts/autoload/llm.gd"
const FIXTURE_PATH := "res://tools/fixtures/mock_plan_valid.json"
const INVALID_PATH := "res://tools/fixtures/mock_plan_invalid.json"
const KEY := "sk-test-0000000000"

const INPUT: Dictionary = {
	"goal": "hypertrophy",
	"days_per_week": 4,
	"duration_min": 40,
	"areas": ["chest", "back", "shoulders", "core"],
	"equipment": ["barbell", "machine", "cable", "dumbbell", "bodyweight"],
	"notes": "",
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

const RESULT_KEYS: PackedStringArray = [
	"ok", "plan", "source", "reason_code", "user_message", "attempts", "repaired", "error",
]
const ERROR_KEYS: PackedStringArray = [
	"code", "http_status", "redacted_detail", "latency_ms",
]
const GENERATION_KEYS: PackedStringArray = [
	"attempts", "repaired", "error_code", "provider", "model", "latency_ms", "catalog_digest",
	"prompt_version",
]


## A `RefCounted` standing in for the network. `replies` is consumed in order and the last entry
## repeats, so a one-element list means "always this answer".
class FakeTransport extends RefCounted:
	var replies: Array = []
	var requests: Array = []
	var order: int = 0
	var cancel_calls: int = 0
	## Called before each canned reply is handed back, so a test can act *during* a request — which
	## is how cancel-in-flight is simulated.
	var on_request: Callable = Callable()

	func _init(canned: Array) -> void:
		replies = canned

	func request(req: Dictionary) -> Dictionary:
		requests.append(req)
		if on_request.is_valid():
			on_request.call()
		if replies.is_empty():
			return {"result": HTTPRequest.RESULT_CANT_CONNECT, "status": 0, "body": ""}
		var reply: Dictionary = replies[mini(order, replies.size() - 1)]
		order += 1
		return reply

	func cancel() -> void:
		cancel_calls += 1

	func count() -> int:
		return requests.size()

	func body_at(index: int) -> String:
		if index >= requests.size():
			return ""
		return String((requests[index] as Dictionary)["body"])

	func url_at(index: int) -> String:
		if index >= requests.size():
			return ""
		return String((requests[index] as Dictionary)["url"])

	func headers_at(index: int) -> PackedStringArray:
		if index >= requests.size():
			return PackedStringArray()
		return (requests[index] as Dictionary)["headers"]

	func reset(canned: Array) -> void:
		replies = canned
		requests = []
		order = 0
		cancel_calls = 0
		on_request = Callable()


## A `RefCounted` standing in for R7's backoff timer: it records what was asked for.
class FakeDelay extends RefCounted:
	var waits: Array = []
	var on_delay: Callable = Callable()

	func delay(seconds: float) -> void:
		waits.append(seconds)
		if on_delay.is_valid():
			on_delay.call()

	func total() -> float:
		var sum := 0.0
		for wait in waits:
			sum += float(wait)
		return sum


## One ladder instance with both seams wired up.
class Harness extends RefCounted:
	var llm: Node = null
	var client: Node = null
	var transport: FakeTransport = null
	var delay: FakeDelay = null
	var cfg: Dictionary = {}

	func run(opts: Dictionary = {}, input: Dictionary = INPUT) -> Dictionary:
		var merged: Dictionary = {"cfg": cfg, "seed": 7}
		for field in opts.keys():
			merged[field] = opts[field]
		var result: Variant = llm.call("generate_plan", input, merged)
		if result is Dictionary:
			return result
		return {}

	## Releases the ladder and its children, so the runner's leak check stays quiet. Not named
	## `free()` because that is `Object`'s.
	func dispose() -> void:
		if llm != null and is_instance_valid(llm):
			llm.free()
		llm = null
		client = null


func _init() -> void:
	suite_name = "llm_ladder"


func run() -> void:
	_test_valid_first_attempt()
	_test_repair_after_malformed()
	_test_schema_invalid_twice()
	_test_not_json_twice()
	_test_http_failures_are_never_retried()
	_test_json_mode_adaptation()
	_test_transport_retries()
	_test_cancel_in_flight()
	_test_cancel_during_backoff()
	_test_gate_branches()
	_test_busy()
	_test_empty_catalog()
	_test_generator_failure()
	_test_fallback_is_the_golden_plan()
	_test_dropped_blocks_do_not_fall_back()
	_test_signals_and_progress()
	_test_shapes_and_copies()


# ------------------------------------------------------------------ the ladder's branches

func _test_valid_first_attempt() -> void:
	begin("a valid reply is the plan: source llm, one attempt, not repaired (R11)")
	var harness := _harness([_openai(_fixture_text())])
	var result: Dictionary = await harness.run()
	assert_true(bool(result["ok"]), "ok")
	assert_eq(String(result["source"]), "llm", "source")
	assert_eq(int(result["attempts"]), 1, "one attempt")
	assert_eq(bool(result["repaired"]), false, "not repaired")
	assert_eq(String(result["reason_code"]), "", "no reason code")
	assert_eq(harness.transport.count(), 1, "exactly one request")
	assert_eq(String(result["user_message"]), "Your plan was written by Custom "
		+ "(OpenAI-compatible).", "R6's copy for the clean path")

	begin("the plan carries the provider, the source and the generation block (R6 step 8)")
	var plan: Dictionary = result["plan"]
	assert_eq(String(plan["source"]), "llm", "source")
	assert_eq(String(plan["provider"]), "custom", "provider")
	assert_eq((plan["sessions"] as Array).size(), 4, "four sessions")
	var generation: Dictionary = plan["generation"]
	assert_eq(generation.size(), GENERATION_KEYS.size(), "eight generation fields")
	for field in GENERATION_KEYS:
		assert_has_key(generation, field, "missing %s" % field)
	assert_eq(int(generation["attempts"]), 1, "attempts")
	assert_eq(bool(generation["repaired"]), false, "repaired")
	assert_eq(String(generation["error_code"]), "", "no error code on the llm path")
	assert_eq(String(generation["provider"]), "custom", "provider")
	assert_eq(String(generation["model"]), "deepseek-chat", "model")
	assert_eq(String(generation["prompt_version"]), PlanPrompt.PROMPT_VERSION, "prompt version")
	assert_eq(String(generation["catalog_digest"]).length(), 64, "a real catalog digest")

	begin("the resulting plan is storable (PlanModel accepts it)")
	assert_empty(PlanModel.validate_dict(plan), "no PlanModel errors")

	begin("the request the client actually sent is R2's shape")
	assert_eq(harness.transport.url_at(0), "http://127.0.0.1:8765/v1/chat/completions", "URL")
	assert_true(harness.transport.body_at(0).contains("\"response_format\""),
		"custom's json mode is on by default")
	assert_true(harness.transport.body_at(0).contains(
		"You are the workout-planning engine inside MicroWorkout"), "the system prompt is embedded")
	assert_true(harness.transport.body_at(0).contains("ALLOWED EXERCISES"),
		"the catalog is embedded")
	assert_true(harness.transport.headers_at(0).has("Authorization: Bearer " + KEY),
		"the bearer header is present")
	harness.dispose()


func _test_repair_after_malformed() -> void:
	begin("a malformed reply is repaired by exactly one retry (R11)")
	var harness := _harness([_openai("{\"name\": \"X\", \"sessions\": [{\"id\": \"s1\","),
		_openai(_fixture_text())])
	var result: Dictionary = await harness.run()
	assert_true(bool(result["ok"]), "ok")
	assert_eq(String(result["source"]), "llm", "source")
	assert_eq(bool(result["repaired"]), true, "repaired")
	assert_eq(int(result["attempts"]), 2, "two attempts")
	assert_eq(harness.transport.count(), 2, "two requests")
	assert_eq(String(result["user_message"]), "Your plan was written by Custom "
		+ "(OpenAI-compatible), after a quick fix-up.", "R6's repaired copy")
	assert_eq(bool((result["plan"] as Dictionary)["generation"]["repaired"]), true,
		"generation.repaired")

	begin("the repair request carries the failure block and is colder (R6 step 7)")
	var repair_body := harness.transport.body_at(1)
	assert_true(repair_body.contains("YOUR PREVIOUS REPLY FAILED VALIDATION."), "the repair block")
	assert_true(repair_body.contains("E_NOT_JSON | root | "), "the validator's own error list")
	assert_true(repair_body.contains("PLAN REQUEST"),
		"appended to the original prompt, not a replacement")
	assert_true(repair_body.contains("\"temperature\":0.2"), "temperature 0.2")
	assert_true(harness.transport.body_at(0).contains("\"temperature\":0.4"), "the first ask is 0.4")

	begin("exactly one repair: a third request never happens")
	assert_eq(harness.transport.count(), 2, "no second repair attempt")

	begin("a validator rule break is repaired too, not only a parse failure")
	var rule_break := _harness([_openai(_invalid_text()), _openai(_fixture_text())])
	var result_rule: Dictionary = await rule_break.run()
	assert_eq(String(result_rule["source"]), "llm", "the repaired plan is used")
	assert_eq(bool(result_rule["repaired"]), true, "repaired")
	assert_eq(int(result_rule["attempts"]), 2, "two attempts")
	assert_true(rule_break.transport.body_at(1).contains("E_"), "the error codes are fed back")
	rule_break.dispose()

	harness.dispose()


func _test_schema_invalid_twice() -> void:
	begin("a schema-invalid reply that stays invalid falls back to the built-in plan (R11)")
	var harness := _harness([_openai(_invalid_text()), _openai(_invalid_text())])
	var result: Dictionary = await harness.run()
	assert_eq(String(result["source"]), "builtin", "source")
	assert_eq(String(result["reason_code"]), "validation", "reason_code")
	assert_true(bool(result["ok"]), "the user still gets a usable plan")
	assert_eq(harness.transport.count(), 2, "one call plus one repair")
	assert_eq(String(result["user_message"]), "Custom (OpenAI-compatible) wrote a plan that "
		+ "didn't pass MicroWorkout's checks, so it built your plan on-device.", "R6's copy")

	begin("the fallback plan is renamed, un-provided and annotated")
	var plan: Dictionary = result["plan"]
	assert_eq(String(plan["source"]), "builtin", "source")
	assert_eq(String(plan["provider"]), "", "builtin plans carry no provider (appendix R31)")
	assert_true(String(plan["name"]).begins_with("Built-in: "), "name: %s" % plan["name"])
	assert_eq((plan["sessions"] as Array).size(), 4, "four sessions")
	assert_eq(String(plan["generation"]["error_code"]), "validation", "generation.error_code")
	assert_eq(bool(plan["generation"]["repaired"]), false, "a fallback is never 'repaired'")
	assert_eq(int(plan["generation"]["attempts"]), 2, "both attempts are recorded")
	assert_empty(PlanModel.validate_dict(plan), "the built-in plan is storable too")
	harness.dispose()


func _test_not_json_twice() -> void:
	begin("two unparseable replies fall back with reason `parse`")
	var harness := _harness([_openai("nonsense"), _openai("still nonsense")])
	var result: Dictionary = await harness.run()
	assert_eq(String(result["source"]), "builtin", "source")
	assert_eq(String(result["reason_code"]), "parse", "parse")
	assert_eq(int(result["attempts"]), 2, "two attempts")
	assert_eq(String(result["user_message"]), "Custom (OpenAI-compatible) wrote a plan that "
		+ "didn't pass MicroWorkout's checks, so it built your plan on-device.",
		"the same copy as validation (R6 renders them identically)")
	harness.dispose()

	begin("a repair whose request itself fails falls back with that failure's code")
	var http := _harness([_openai("nonsense"), _reply(500, "{}")])
	var result_http: Dictionary = await http.run()
	assert_eq(String(result_http["source"]), "builtin", "source")
	assert_eq(String(result_http["reason_code"]), "server", "the repair's HTTP failure")
	assert_eq(int(result_http["attempts"]), 2, "both attempts counted")
	http.dispose()


func _test_http_failures_are_never_retried() -> void:
	begin("HTTP 401 is one request, one attempt, then the built-in plan (R11)")
	var harness := _harness([_reply(401, "{\"error\": {\"message\": \"Invalid API key\"}}")])
	var result: Dictionary = await harness.run()
	assert_eq(int(result["attempts"]), 1, "one attempt")
	assert_eq(harness.transport.count(), 1, "exactly one request — a 401 is never retried")
	assert_empty(harness.delay.waits, "and no backoff")
	assert_eq(String(result["source"]), "builtin", "source")
	assert_eq(String(result["reason_code"]), "auth", "reason_code")
	assert_eq(String(result["user_message"]), "Custom (OpenAI-compatible) rejected the saved API "
		+ "key, so MicroWorkout built your plan on-device. Fix it in Settings → AI provider.",
		"R6's auth copy, verbatim")
	assert_eq(String(result["error"]["code"]), "auth", "error.code")
	assert_eq(int(result["error"]["http_status"]), 401, "error.http_status")
	assert_true(String(result["error"]["redacted_detail"]).contains("Invalid API key"),
		"the provider's own words are kept")
	harness.dispose()

	begin("every other HTTP status is also a single request")
	var cases: Dictionary = {
		400: "bad_response", 403: "forbidden", 404: "bad_path", 429: "rate_limited",
		500: "server", 502: "server", 503: "server",
	}
	var statuses: Array = cases.keys()
	statuses.sort()
	for status in statuses:
		var one := _harness([_reply(int(status), "{\"error\": {\"message\": \"no\"}}")])
		var result_status: Dictionary = await one.run()
		assert_eq(int(result_status["attempts"]), 1, "HTTP %d: one attempt" % int(status))
		assert_eq(one.transport.count(), 1, "HTTP %d: one request" % int(status))
		assert_eq(String(result_status["reason_code"]), String(cases[int(status)]),
			"HTTP %d code" % int(status))
		assert_eq(String(result_status["source"]), "builtin", "HTTP %d falls back" % int(status))
		one.dispose()

	begin("the copy for a server problem names the provider, not the status")
	var server := _harness([_reply(503, "{}")])
	var result_server: Dictionary = await server.run()
	assert_eq(String(result_server["user_message"]), "Custom (OpenAI-compatible) had a server "
		+ "problem, so MicroWorkout built your plan on-device.", "R6's server copy")
	server.dispose()

	begin("a truncated reply falls back with R6's bad_response copy")
	var truncated := _harness([_openai(_fixture_text(), "length")])
	var result_truncated: Dictionary = await truncated.run()
	assert_eq(String(result_truncated["reason_code"]), "truncated", "truncated")
	assert_eq(String(result_truncated["user_message"]), "Custom (OpenAI-compatible) sent a reply "
		+ "MicroWorkout couldn't use, so it built your plan on-device.", "R6's copy")
	truncated.dispose()

	begin("a blocked prompt falls back with the same copy")
	var blocked := _harness([_reply(200, JSON.stringify({"promptFeedback": {"blockReason": "SAFETY"},
		"candidates": []}))])
	var result_blocked: Dictionary = await blocked.run()
	assert_eq(String(result_blocked["reason_code"]), "blocked", "blocked")
	assert_eq(String(result_blocked["source"]), "builtin", "source")
	blocked.dispose()

	begin("an empty reply costs one repair, and the repair's success still wins")
	var empty_first := _harness([_openai(""), _openai(_fixture_text())])
	var result_empty: Dictionary = await empty_first.run()
	assert_eq(String(result_empty["source"]), "llm", "source")
	assert_eq(bool(result_empty["repaired"]), true, "repaired")
	assert_eq(int(result_empty["attempts"]), 2, "two attempts")
	empty_first.dispose()


func _test_json_mode_adaptation() -> void:
	begin("a 400 that blames response_format is re-sent without it (R2 A, counted as an attempt)")
	var harness := _harness([
		_reply(400, "{\"error\": {\"message\": \"Unsupported parameter: 'response_format'\"}}"),
		_openai(_fixture_text()),
	])
	var result: Dictionary = await harness.run()
	assert_true(bool(result["ok"]), "ok")
	assert_eq(String(result["source"]), "llm", "source")
	assert_eq(int(result["attempts"]), 2, "the re-send counts as the next attempt")
	assert_eq(harness.transport.count(), 2, "two requests")
	assert_true(harness.transport.body_at(0).contains("\"response_format\""),
		"the first request asked for JSON mode")
	assert_false(harness.transport.body_at(1).contains("response_format"),
		"the re-shaped request does not")
	harness.dispose()

	begin("the flag is re-sent without triggering a transport retry, and the 400 is not fatal")
	var second := _harness([
		_reply(400, "json mode is not supported by this model"),
		_openai(_fixture_text()),
	])
	var result_second: Dictionary = await second.run()
	assert_eq(int(result_second["attempts"]), 2, "two attempts")
	assert_empty(second.delay.waits, "no backoff: this is request adaptation, not a retry")
	second.dispose()

	begin("the adaptation happens at most once")
	var twice := _harness([
		_reply(400, "response_format is not supported"),
		_reply(400, "response_format is not supported"),
	])
	var result_twice: Dictionary = await twice.run()
	assert_eq(twice.transport.count(), 2, "two requests, then the fallback")
	assert_eq(String(result_twice["source"]), "builtin", "builtin")
	assert_eq(String(result_twice["reason_code"]), "bad_response", "the second 400 is final")
	twice.dispose()

	begin("a 400 about anything else is not adapted")
	var other := _harness([_reply(400, "{\"error\": {\"message\": \"model does not exist\"}}")])
	var result_other: Dictionary = await other.run()
	assert_eq(other.transport.count(), 1, "one request")
	assert_eq(String(result_other["reason_code"]), "bad_response", "bad_response")
	other.dispose()

	begin("a provider without JSON mode never sends the flag in the first place")
	var anthropic := _harness([_openai(_fixture_text())], {"provider": "anthropic",
		"base_url": "https://api.anthropic.com/v1", "model": "claude-3-5-sonnet-latest"})
	var result_anthropic: Dictionary = await anthropic.run()
	assert_true(bool(result_anthropic["ok"]), "ok")
	assert_false(anthropic.transport.body_at(0).contains("response_format"),
		"anthropic's body has no JSON-mode flag")
	assert_eq(anthropic.transport.url_at(0), "https://api.anthropic.com/v1/messages",
		"the Anthropic path")
	assert_true(anthropic.transport.headers_at(0).has("anthropic-version: 2023-06-01"),
		"and the version header")
	anthropic.dispose()


func _test_transport_retries() -> void:
	begin("a refused connection is retried twice: three attempts, 1 s then 3 s (R7/R11)")
	var harness := _harness([_transport_failure(HTTPRequest.RESULT_CANT_CONNECT)])
	var result: Dictionary = await harness.run()
	assert_eq(int(result["attempts"]), 3, "three attempts")
	assert_eq(harness.transport.count(), 3, "three requests")
	assert_eq(_waits(harness), "1.0, 3.0", "the documented backoff, in order")
	assert_close(harness.delay.total(), 4.0, 0.0001, "4 s of backoff in total")
	assert_eq(String(result["source"]), "builtin", "source")
	assert_eq(String(result["reason_code"]), "no_network", "no_network")
	assert_eq(String(result["user_message"]), "Couldn't reach Custom (OpenAI-compatible), so "
		+ "MicroWorkout built your plan on-device.", "R6's no_network copy")
	harness.dispose()

	begin("a TLS handshake failure is retried the same way")
	var tls := _harness([_transport_failure(HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR)])
	var result_tls: Dictionary = await tls.run()
	assert_eq(int(result_tls["attempts"]), 3, "three attempts")
	assert_eq(_waits(tls), "1.0, 3.0", "the same waits")
	assert_eq(String(result_tls["reason_code"]), "tls", "tls")
	assert_eq(String(result_tls["user_message"]), "Couldn't open a secure connection to Custom "
		+ "(OpenAI-compatible), so MicroWorkout built your plan on-device.", "R6's tls copy")
	tls.dispose()

	begin("a timeout is retried too (R7's own worst case is 3 x 45 s + 1 s + 3 s)")
	var timeout := _harness([_transport_failure(HTTPRequest.RESULT_TIMEOUT)])
	var result_timeout: Dictionary = await timeout.run()
	assert_eq(int(result_timeout["attempts"]), 3, "three attempts")
	assert_eq(_waits(timeout), "1.0, 3.0", "waits")
	assert_eq(String(result_timeout["reason_code"]), "timeout", "timeout")
	assert_eq(String(result_timeout["user_message"]), "Custom (OpenAI-compatible) took too long "
		+ "to answer, so MicroWorkout built your plan on-device.", "R6's timeout copy")
	timeout.dispose()

	begin("a retry that succeeds is not a fallback")
	var recovered := _harness([_transport_failure(HTTPRequest.RESULT_CANT_CONNECT),
		_transport_failure(HTTPRequest.RESULT_CANT_RESOLVE), _openai(_fixture_text())])
	var result_recovered: Dictionary = await recovered.run()
	assert_eq(String(result_recovered["source"]), "llm", "source")
	assert_eq(int(result_recovered["attempts"]), 3, "three attempts")
	assert_eq(_waits(recovered), "1.0, 3.0", "both waits happened")
	assert_eq(String(result_recovered["reason_code"]), ""	, "no reason code")
	assert_eq(String(result_recovered["plan"]["generation"]["error_code"]), "",
		"and generation records success")
	recovered.dispose()

	begin("a transport failure on the repair request retries within that request's own budget")
	var mid_repair := _harness([_openai("nonsense"),
		_transport_failure(HTTPRequest.RESULT_CANT_CONNECT)])
	var result_mid: Dictionary = await mid_repair.run()
	assert_eq(int(result_mid["attempts"]), 4, "1 + 3: the repair request retried its own network "
		+ "failure")
	assert_eq(String(result_mid["source"]), "builtin", "and then fell back")
	assert_eq(String(result_mid["reason_code"]), "no_network", "no_network")
	mid_repair.dispose()

	begin("max_attempts is honoured")
	var one := _harness([_transport_failure(HTTPRequest.RESULT_CANT_CONNECT)])
	var result_one: Dictionary = await one.run({"max_attempts": 1})
	assert_eq(int(result_one["attempts"]), 1, "one attempt")
	assert_eq(one.transport.count(), 1, "one request")
	assert_empty(one.delay.waits, "and no backoff")
	assert_eq(String(result_one["reason_code"]), "no_network", "the failure is still reported")
	one.dispose()

	begin("a two-attempt budget waits once")
	var two := _harness([_transport_failure(HTTPRequest.RESULT_CANT_CONNECT)])
	var result_two: Dictionary = await two.run({"max_attempts": 2})
	assert_eq(int(result_two["attempts"]), 2, "two attempts")
	assert_eq(_waits(two), "1.0", "only the 1 s wait")
	two.dispose()


func _test_cancel_in_flight() -> void:
	begin("cancel() mid-flight returns ok=false with no fallback and nothing saved (R11)")
	var harness := _harness([_openai(_fixture_text())])
	harness.transport.on_request = func() -> void: harness.llm.cancel()
	var result: Dictionary = await harness.run()
	assert_false(bool(result["ok"]), "not ok")
	assert_empty(result["plan"], "no plan")
	assert_eq(String(result["source"]), "", "no source")
	assert_eq(String(result["reason_code"]), "cancelled", "cancelled")
	assert_eq(String(result["user_message"]), "Generation cancelled. Nothing was saved.",
		"R6's copy")
	assert_eq(int(result["attempts"]), 1, "the in-flight attempt is counted")
	assert_eq(harness.transport.cancel_calls, 1, "the transport was cancelled")
	harness.dispose()

	begin("a cancel is never retried and never repaired")
	var retried := _harness([_transport_failure(HTTPRequest.RESULT_CANT_CONNECT),
		_openai(_fixture_text())])
	retried.transport.on_request = func() -> void: retried.llm.cancel()
	var result_retried: Dictionary = await retried.run()
	assert_eq(String(result_retried["reason_code"]), "cancelled", "cancelled")
	assert_eq(retried.transport.count(), 1, "no retry followed the cancel")
	assert_empty(retried.delay.waits, "and no backoff either")

	begin("a cancelled LLM does not stay cancelled for the next call")
	retried.transport.reset([_openai(_fixture_text())])
	var result_next: Dictionary = await retried.run()
	assert_true(bool(result_next["ok"]), "ok: the next generation is unaffected")
	assert_eq(String(result_next["source"]), "llm", "source")
	retried.dispose()


func _test_cancel_during_backoff() -> void:
	begin("a cancel during the backoff stops before the next attempt")
	var harness := _harness([_transport_failure(HTTPRequest.RESULT_CANT_CONNECT),
		_openai(_fixture_text())])
	harness.delay.on_delay = func() -> void: harness.llm.cancel()
	var result: Dictionary = await harness.run()
	assert_eq(String(result["reason_code"]), "cancelled", "cancelled")
	assert_eq(int(result["attempts"]), 1, "only the first attempt happened")
	assert_eq(harness.transport.count(), 1, "and only one request was sent")
	assert_eq(_waits(harness), "1.0", "the first wait had already started")
	harness.dispose()


func _test_gate_branches() -> void:
	begin("an empty API key skips the network entirely: zero attempts (R6 step 1 / R11)")
	var harness := _harness([_openai(_fixture_text())], {"api_key": ""})
	var result: Dictionary = await harness.run()
	assert_eq(int(result["attempts"]), 0, "zero attempts")
	assert_eq(harness.transport.count(), 0, "not one request")
	assert_eq(String(result["source"]), "builtin", "the built-in plan")
	assert_eq(String(result["reason_code"]), "no_key", "no_key")
	assert_eq(String(result["user_message"]), "No AI provider is set up yet, so MicroWorkout built "
		+ "your plan on-device.", "R6's no_key copy")
	assert_eq(String(result["error"]["code"]), "no_key", "error.code")
	harness.dispose()

	begin("an empty base URL is the same gate")
	var no_url := _harness([_openai(_fixture_text())], {"base_url": ""})
	var result_url: Dictionary = await no_url.run()
	assert_eq(int(result_url["attempts"]), 0, "zero attempts")
	assert_eq(no_url.transport.count(), 0, "no request")
	assert_eq(String(result_url["reason_code"]), "no_key", "no_key")
	no_url.dispose()

	begin("allow_llm = false behaves exactly like an unconfigured provider")
	var off := _harness([_openai(_fixture_text())])
	var result_off: Dictionary = await off.run({"allow_llm": false})
	assert_eq(int(result_off["attempts"]), 0, "zero attempts")
	assert_eq(off.transport.count(), 0, "no request")
	assert_eq(String(result_off["reason_code"]), "no_key", "no_key")
	assert_eq(String(result_off["source"]), "builtin", "builtin")
	assert_eq(String(result_off["user_message"]), "No AI provider is set up yet, so MicroWorkout "
		+ "built your plan on-device.", "the no_key copy")
	off.dispose()

	begin("a keyless custom server (custom_auth_none) does reach the network")
	var keyless := _harness([_openai(_fixture_text())],
		{"api_key": "", "custom_auth_none": true})
	var result_keyless: Dictionary = await keyless.run()
	assert_eq(int(result_keyless["attempts"]), 1, "one attempt")
	assert_eq(String(result_keyless["source"]), "llm", "source")
	for header in keyless.transport.headers_at(0):
		assert_false(String(header).begins_with("Authorization"),
			"no Authorization header for a keyless server")
	keyless.dispose()

	begin("is_configured() answers the same question the gate asks")
	var harness_configured := _harness([])
	assert_true(bool(harness_configured.llm.call("is_configured", CFG)), "a full config is ready")
	var empty_cfg := CFG.duplicate()
	empty_cfg["api_key"] = ""
	assert_false(bool(harness_configured.llm.call("is_configured", empty_cfg)),
		"a missing key is not ready")
	assert_true(bool(harness_configured.llm.call("is_configured",
		{"provider": "custom", "base_url": "http://x/v1", "api_key": "",
			"custom_auth_none": true})), "a keyless custom server is ready")
	harness_configured.dispose()


func _test_busy() -> void:
	begin("a second generation while one is running returns busy, with no fallback (R6 step 2)")
	var harness := _harness([])
	harness.llm.is_generating = true
	var result: Dictionary = await harness.run()
	assert_false(bool(result["ok"]), "not ok")
	assert_empty(result["plan"], "no plan")
	assert_eq(String(result["source"]), "", "no source")
	assert_eq(String(result["reason_code"]), "busy", "busy")
	assert_eq(String(result["user_message"]), "A plan is already being generated.", "R6's busy copy")
	assert_eq(int(result["attempts"]), 0, "zero attempts")
	assert_eq(harness.transport.count(), 0, "and nothing was sent")
	assert_true(harness.llm.is_generating, "the in-flight generation is left alone")

	begin("is_generating is cleared before generation_finished, on every branch")
	harness.llm.is_generating = false
	harness.transport.reset([_reply(401, "{}")])
	var flags: Array = []
	harness.llm.generation_finished.connect(func(_result: Dictionary) -> void:
		flags.append(harness.llm.is_generating))
	var _result_failed: Dictionary = await harness.run()
	assert_eq(flags.size(), 1, "one emission")
	assert_eq(flags[0], false, "cleared before the signal")
	assert_eq(harness.llm.is_generating, false, "and after the call")
	harness.dispose()


func _test_empty_catalog() -> void:
	begin("an empty catalog goes straight to the built-in generator (R10)")
	var harness := _harness([_openai(_fixture_text())])
	var result: Dictionary = await harness.run({"catalog": []})
	assert_eq(int(result["attempts"]), 0, "zero attempts")
	assert_eq(harness.transport.count(), 0, "no request: no provider can fix a missing library")
	assert_eq(String(result["source"]), "builtin", "builtin")
	assert_eq(String(result["reason_code"]), "validation", "validation (R10)")
	assert_eq((result["plan"] as Dictionary).get("sessions", []).size(), 4, "four sessions")
	harness.dispose()


func _test_generator_failure() -> void:
	begin("if even the built-in generator cannot run, the result is a failure with the full shape")
	var input: Dictionary = INPUT.duplicate()
	input["areas"] = []
	var harness := _harness([_reply(401, "{}")])
	var result: Dictionary = await harness.run({}, input)
	assert_false(bool(result["ok"]), "not ok")
	assert_empty(result["plan"], "no plan")
	assert_eq(String(result["source"]), "", "no source")
	assert_eq(String(result["reason_code"]), "auth", "the provider's failure is still the reason")
	_assert_result_shape(result)
	harness.dispose()


func _test_fallback_is_the_golden_plan() -> void:
	begin("the fallback is PRD-05's Generator.build_plan() for the same seed (R11)")
	var harness := _harness([_reply(401, "{}")])
	var result: Dictionary = await harness.run({"seed": 4242})
	var expected := Generator.build_plan(INPUT, 4242)
	assert_eq(JSON.stringify(result["plan"]["sessions"]), JSON.stringify(expected["sessions"]),
		"the sessions are the generator's own, unchanged")
	assert_eq(String(result["plan"]["split_name"]), String(expected["split_name"]), "split name")
	assert_eq(JSON.stringify(result["plan"]["areas"]), JSON.stringify(expected["areas"]), "areas")
	assert_eq(int(result["plan"]["days_per_week"]), int(expected["days_per_week"]), "days")
	assert_eq(String(result["plan"]["generation"]["error_code"]), "auth", "the reason is attached")

	begin("the same seed produces the same fallback twice (determinism preserved)")
	var again := _harness([_reply(401, "{}")])
	var result_again: Dictionary = await again.run({"seed": 4242})
	assert_eq(JSON.stringify(result_again["plan"]), JSON.stringify(result["plan"]),
		"byte-identical fallback")
	again.dispose()

	begin("a different seed is really used")
	var other := _harness([_reply(401, "{}")])
	var result_other: Dictionary = await other.run({"seed": 99})
	assert_eq(JSON.stringify(result_other["plan"]["sessions"]),
		JSON.stringify(Generator.build_plan(INPUT, 99)["sessions"]),
		"the second seed's own sessions")
	other.dispose()

	harness.dispose()


func _test_dropped_blocks_do_not_fall_back() -> void:
	begin("a plan with an invented id still ships: one dropped block is not a failure")
	var plan: Dictionary = JSON.parse_string(_fixture_text())
	var blocks: Array = (plan["sessions"] as Array)[0]["blocks"]
	(blocks[2] as Dictionary)["exercise_id"] = "incline-fly-machine"
	var harness := _harness([_openai(JSON.stringify(plan))])
	var result: Dictionary = await harness.run()
	assert_true(bool(result["ok"]), "ok")
	assert_eq(String(result["source"]), "llm", "source")
	assert_eq(int(result["attempts"]), 1, "and it did not even need the repair retry")
	assert_eq((((result["plan"]["sessions"] as Array)[0] as Dictionary)["blocks"] as Array).size(),
		4, "the invented block is gone")
	assert_empty(PlanModel.validate_dict(result["plan"]), "the surviving plan is storable")
	harness.dispose()

	begin("a plan whose only block is invented falls back, because the session emptied")
	var single: Dictionary = {
		"name": "T",
		"split_name": "Full Body",
		"sessions": [{"id": "s1", "index": 0, "title": "T", "focus": ["chest"],
			"est_minutes": 40,
			"warmup": [{"exercise_id": "arm-circles", "duration_sec": 60}],
			"cooldown": [{"exercise_id": "childs-pose", "duration_sec": 60}],
			"blocks": [{"exercise_id": "ghost", "sets": 3, "reps": "8-10", "rest_seconds": 90}]}],
	}
	var empty_session := _harness([_openai(JSON.stringify(single)),
		_openai(JSON.stringify(single))])
	var result_empty: Dictionary = await empty_session.run()
	assert_eq(String(result_empty["source"]), "builtin", "builtin")
	assert_eq(String(result_empty["reason_code"]), "validation", "validation")
	empty_session.dispose()


func _test_signals_and_progress() -> void:
	begin("generation_finished fires exactly once per call, after is_generating is cleared")
	var harness := _harness([_openai(_fixture_text())])
	var finished: Array = []
	harness.llm.generation_finished.connect(func(result: Dictionary) -> void:
		finished.append(result))
	var result: Dictionary = await harness.run()
	assert_eq(finished.size(), 1, "one emission")
	assert_eq(JSON.stringify(finished[0]), JSON.stringify(result), "carrying the returned result")
	harness.dispose()

	begin("generation_progress reports `Attempt 1 of 3` for the overlay (R9)")
	var progress := _harness([_openai(_fixture_text())])
	var seen: Array = []
	progress.llm.generation_progress.connect(func(attempt: int, total: int) -> void:
		seen.append("%d/%d" % [attempt, total]))
	var result_progress: Dictionary = await progress.run()
	assert_eq(", ".join(PackedStringArray(seen.map(_as_text))), "1/3", "one attempt of three")
	assert_true(bool(result_progress["ok"]), "and it worked")
	progress.dispose()

	begin("a retried attempt advances the counter")
	var retried := _harness([_transport_failure(HTTPRequest.RESULT_CANT_CONNECT),
		_transport_failure(HTTPRequest.RESULT_CANT_RESOLVE), _openai(_fixture_text())])
	var counter: Array = []
	retried.llm.generation_progress.connect(func(attempt: int, _total: int) -> void:
		counter.append(attempt))
	var result_retried: Dictionary = await retried.run()
	assert_eq(", ".join(PackedStringArray(counter.map(_as_text))), "1, 2, 3", "1/3, 2/3, 3/3")
	assert_true(bool(result_retried["ok"]), "and the third one worked")
	retried.dispose()

	begin("attempts accumulate across the first call and the repair")
	var accumulated := _harness([_transport_failure(HTTPRequest.RESULT_CANT_CONNECT),
		_openai("nonsense"), _openai(_fixture_text())])
	var result_accumulated: Dictionary = await accumulated.run()
	assert_eq(int(result_accumulated["attempts"]), 3, "1 transport retry + the repair")
	assert_eq(bool(result_accumulated["repaired"]), true, "the repair rescued it")
	assert_eq(accumulated.transport.count(), 3, "three requests")
	assert_eq(_waits(accumulated), "1.0", "one backoff, inside the first call")
	accumulated.dispose()


func _test_shapes_and_copies() -> void:
	begin("every result has R6's exact key set, on every branch")
	var branches: Array = [
		[_openai(_fixture_text()), {}],
		[_reply(401, "{}"), {}],
		[_transport_failure(HTTPRequest.RESULT_CANT_CONNECT), {}],
		[_openai(_fixture_text()), {"allow_llm": false}],
		[_openai(_fixture_text()), {"catalog": []}],
		[_openai(_fixture_text()), {"max_attempts": 1}],
	]
	for entry in branches:
		var one := _harness((entry as Array)[0] as Array)
		var result_branch: Dictionary = await one.run((entry as Array)[1] as Dictionary)
		_assert_result_shape(result_branch)
		one.dispose()

	begin("the error sub-dictionary always has R6's four fields")
	var harness := _harness([_reply(429, "{\"error\": {\"message\": \"slow down\"}}")])
	var result: Dictionary = await harness.run()
	assert_eq((result["error"] as Dictionary).size(), ERROR_KEYS.size(), "four fields")
	for field in ERROR_KEYS:
		assert_has_key(result["error"], field, "missing %s" % field)
	assert_eq(int(result["error"]["http_status"]), 429, "the status is reported")
	assert_eq(String(result["reason_code"]), "rate_limited", "rate_limited")
	assert_eq(String(result["user_message"]), "Custom (OpenAI-compatible) is rate-limiting this "
		+ "key right now, so MicroWorkout built your plan on-device.", "R6's rate_limited copy")
	harness.dispose()

	begin("a bad_path failure tells the user to check the base URL")
	var missing := _harness([_reply(404, "{}")])
	var result_missing: Dictionary = await missing.run()
	assert_eq(String(result_missing["user_message"]), "The AI address for Custom "
		+ "(OpenAI-compatible) looks wrong, so MicroWorkout built your plan on-device. Check the "
		+ "base URL in Settings.", "R6's bad_path copy")
	missing.dispose()

	begin("provider_label overrides the preset label in the copy")
	var labelled := _harness([_reply(401, "{}")])
	var result_labelled: Dictionary = await labelled.run({"provider_label": "DeepSeek"})
	assert_true(String(result_labelled["user_message"]).begins_with(
		"DeepSeek rejected the saved API key"),
		"the label is used: %s" % result_labelled["user_message"])
	labelled.dispose()

	begin("timeout_sec reaches the request the transport sees")
	var timed := _harness([_openai(_fixture_text())])
	var _result_timed: Dictionary = await timed.run({"timeout_sec": 12})
	assert_eq(int((timed.transport.requests[0] as Dictionary)["timeout_sec"]), 12,
		"the caller's timeout is used")
	timed.dispose()


# ------------------------------------------------------------------ harness

func _harness(replies: Array, cfg_overrides: Dictionary = {}) -> Harness:
	var harness := Harness.new()
	harness.llm = (load(LLM_SCRIPT) as GDScript).new()
	harness.client = harness.llm.call("_ensure_client")
	harness.transport = FakeTransport.new(replies)
	harness.delay = FakeDelay.new()
	harness.client.set("transport", harness.transport)
	harness.client.set("delay_seam", harness.delay)
	harness.cfg = CFG.duplicate()
	for field in cfg_overrides.keys():
		harness.cfg[field] = cfg_overrides[field]
	return harness


# ------------------------------------------------------------------ canned replies

func _openai(text: String, finish: String = "stop") -> Dictionary:
	return _reply(200, JSON.stringify({
		"id": "chatcmpl-test",
		"object": "chat.completion",
		"choices": [{"index": 0, "message": {"role": "assistant", "content": text},
			"finish_reason": finish}],
		"usage": {"prompt_tokens": 100, "completion_tokens": 200, "total_tokens": 300},
	}))


func _reply(status: int, body: String) -> Dictionary:
	return {"result": HTTPRequest.RESULT_SUCCESS, "status": status, "body": body}


func _transport_failure(result: int) -> Dictionary:
	return {"result": result, "status": 0, "body": ""}


func _fixture_text() -> String:
	return FileAccess.get_file_as_string(FIXTURE_PATH)


func _invalid_text() -> String:
	return FileAccess.get_file_as_string(INVALID_PATH)


## The recorded backoff as `1.0, 3.0`, so the assertion reads like R7's own sentence.
func _waits(harness: Harness) -> String:
	var parts := PackedStringArray()
	for wait in harness.delay.waits:
		parts.append(String.num(float(wait), 1))
	return ", ".join(parts)


func _assert_result_shape(result: Dictionary) -> void:
	assert_eq(result.size(), RESULT_KEYS.size(), "eight result keys")
	for field in RESULT_KEYS:
		assert_has_key(result, field, "missing %s" % field)
	assert_true(result["ok"] is bool, "ok is a bool")
	assert_true(result["plan"] is Dictionary, "plan is a dictionary")
	assert_true(result["source"] is String, "source is a string")
	assert_true(result["reason_code"] is String, "reason_code is a string")
	assert_true(result["user_message"] is String, "user_message is a string")
	assert_true(result["attempts"] is int, "attempts is an int")
	assert_true(result["repaired"] is bool, "repaired is a bool")
	assert_true(result["error"] is Dictionary, "error is a dictionary")
	assert_true(PlanModel.SOURCES.has(String(result["source"])) or String(result["source"]).is_empty(),
		"source is builtin, llm or empty")


static func _as_text(value: Variant) -> String:
	return str(value)
