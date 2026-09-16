class_name LLMClient
extends Node
## PRD-07 R2 + R7 — the three adapters, the byte-exact requests, the transport retries and the
## one cancellation path. **Nothing else in the app builds a generation request.**
##
## [b]Shape of the module.[/b] Every provider-specific decision is *data* (a row of
## [LLMProviders.SHAPES]) except the body layout, which is a `match` on the adapter here. The
## request itself is built by the static [method build_request], so a suite can prove the exact
## method, URL, header set and body bytes with no socket, no scene tree and no `HTTPRequest` —
## which is what R11's `test_llm_request_build.gd` does.
##
## [b]The transport seam (R11).[/b] [member transport] is `null` in production, where the single
## [HTTPRequest] child does the work. A test assigns a `RefCounted` with
## `request(req: Dictionary) -> Dictionary` (and optionally `cancel()`), and then the whole
## ladder — retries, backoff, HTTP classification, envelope extraction — runs synchronously and
## headlessly. [member delay_seam] does the same for R7's 1 s / 3 s backoff, so the ladder suite
## can assert the *documented* backoff without spending four real seconds.
##
## [b]Key discipline (R12).[/b] The key enters a URL (Gemini) or a header (everyone else) and
## nowhere else. This file never logs a URL, a header or a body: the single line per request is
## [method LLMResult.log_line]. Cancellation, retries and failures all pass through
## [method Redact.safe_error] before anything leaves as text.

## Emitted exactly once per [method generate], whatever happened (R2).
signal request_finished(result: LLMResult)
## Emitted immediately before each request goes out, so the overlay can show `Attempt 2 of 3`
## (R9). Purely informational: the result still arrives on [signal request_finished].
signal attempt_started(attempt: int, total: int)

## R2 defaults. `max_tokens`, `temperature`, `timeout_sec`, `retries`, `backoff_sec`,
## `allow_json_mode` and `attempt` are the `opts` keys a caller may override.
const DEFAULT_MAX_TOKENS: int = 4096
const DEFAULT_TEMPERATURE: float = 0.4
## R2's repair retry is colder than the first ask, so a bad shape is less likely to repeat (R6).
const REPAIR_TEMPERATURE: float = 0.2
const DEFAULT_TIMEOUT_SEC: int = 45
const DEFAULT_RETRIES: int = 2
## R7's backoff: 1 s before attempt 2, 3 s before attempt 3, `Engine.time_scale`-independent.
const DEFAULT_BACKOFF_SEC: Array[float] = [1.0, 3.0]
## R7's belt-and-braces watchdog on top of `HTTPRequest.timeout` (45 s + 5 s = 50 s).
const WATCHDOG_MARGIN_SEC: float = 5.0
## The backoff is sliced so a cancel during it is noticed within a fraction of a second (R9
## "Cancel aborts within 2 s") without changing the total wait.
const CANCEL_SLICE_SEC: float = 0.25

## Test seam: `null` in production. A `RefCounted` with
## `request(req: Dictionary) -> Dictionary` returning `{result, status, body}`, and optionally
## `cancel() -> void`. When set, no socket is ever opened.
var transport: Object = null

## Test seam for [constant DEFAULT_BACKOFF_SEC]: `null` in production. A `RefCounted` with
## `delay(seconds: float) -> void` (a plain function, not a coroutine). When set, the documented
## backoff values still pass through it, so a suite can assert them exactly.
var delay_seam: Object = null

## R11/R12 seam: when valid, every log line this client emits is also handed to it, so
## `tests/suites/test_key_never_logged.gd` can assert on the exact text that would reach logcat
## instead of trusting that no `print()` was added later. Production never sets it.
var log_sink: Callable = Callable()

## True between [method generate] starting and its result being settled.
var is_running: bool = false

var _http: HTTPRequest = null
var _watchdog: Timer = null
## True once the in-flight attempt's outcome is known; when nothing is in flight it is `true`, so
## a signal that already fired is never awaited (which would hang forever).
var _attempt_settled: bool = true
var _pending: Dictionary = {}
var _cancelled: bool = false

signal _attempt_completed


func _ready() -> void:
	ensure_http()


# ===========================================================================
# R2 — request construction (the only place a request is assembled)
# ===========================================================================

## The complete request for [param key], as
## `{"method": int, "url": String, "headers": PackedStringArray, "body": String, "timeout_sec": int}`.
##
## [param opts] may carry `max_tokens`, `temperature`, `timeout_sec`, `allow_json_mode` and
## `json_mode` (the already-resolved answer, which the retry loop flips after a 400). Nothing in
## here reads a setting, a file or the scene tree, so two calls with the same arguments produce
## byte-identical output — which is what makes the golden-body test meaningful.
static func build_request(key: String, cfg: Dictionary, system_prompt: String, user_prompt: String,
		opts: Dictionary = {}) -> Dictionary:
	var adapter := LLMProviders.adapter_for(key)
	var model := LLMProviders.model_for(key, cfg)
	var max_tokens := int(opts.get("max_tokens", DEFAULT_MAX_TOKENS))
	var temperature := float(opts.get("temperature", DEFAULT_TEMPERATURE))
	var timeout_sec := int(opts.get("timeout_sec", LLMProviders.default_timeout_sec(key)))
	var json_mode := bool(opts.get("json_mode",
		bool(opts.get("allow_json_mode", true)) and LLMProviders.json_mode_ok(key, cfg)))

	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	# Provider-mandated headers, keys sorted so the header set is deterministic.
	var extra := LLMProviders.extra_headers_for(key)
	var extra_keys: Array = extra.keys()
	extra_keys.sort()
	for field in extra_keys:
		headers.append("%s: %s" % [String(field), String(extra[field])])
	headers.append_array(LLMProviders.auth_headers_for(key, cfg))

	var body := ""
	match adapter:
		"anthropic":
			body = ('{"model":%s,"max_tokens":%d,"temperature":%s,"system":%s,'
				+ '"messages":[{"role":"user","content":%s}]}') % [
					JSON.stringify(model), max_tokens, _number(temperature),
					JSON.stringify(system_prompt), JSON.stringify(user_prompt)]
		"gemini":
			var json_flag := ',"responseMimeType":"application/json"' if json_mode else ""
			body = ('{"systemInstruction":{"parts":[{"text":%s}]},'
				+ '"contents":[{"role":"user","parts":[{"text":%s}]}],'
				+ '"generationConfig":{"temperature":%s,"maxOutputTokens":%d%s}}') % [
					JSON.stringify(system_prompt), JSON.stringify(user_prompt),
					_number(temperature), max_tokens, json_flag]
		_:
			var format_flag := ',"response_format":{"type":"json_object"}' if json_mode else ""
			body = ('{"model":%s,"messages":[{"role":"system","content":%s},'
				+ '{"role":"user","content":%s}],"temperature":%s,"max_tokens":%d%s,'
				+ '"stream":false}') % [
					JSON.stringify(model), JSON.stringify(system_prompt),
					JSON.stringify(user_prompt), _number(temperature), max_tokens, format_flag]

	return {
		"method": HTTPClient.METHOD_POST,
		"url": LLMProviders.resolve_url(key, cfg),
		"headers": headers,
		"body": body,
		"timeout_sec": timeout_sec,
	}


## A JSON number for the body, without Godot's `1.0`-vs-`1` surprise: a whole temperature is
## written as `1` and anything else with [method String.num]'s shortest exact form. `0.4` — the
## R2 default — comes out as exactly `0.4`.
static func _number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	return String.num(value, 4).rstrip("0").rstrip(".")


# ===========================================================================
# R2 — envelope extraction
# ===========================================================================

## Turns a provider's 2xx body into `{"error_code", "text", "detail", "usage"}` for the adapter
## that produced it. An empty `error_code` means the reply was structurally readable; an empty
## `text` with an empty `error_code` is legal (the provider answered with nothing) and is left to
## the validator, which reports `E_NOT_JSON` and the ladder repairs it once.
##
## Pure and static so the envelope suite needs neither a socket nor a scene tree.
static func extract_envelope(adapter: String, body: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		return _envelope_error("bad_response", "reply was not a JSON object")
	var root: Dictionary = parsed
	match adapter:
		"anthropic":
			return _extract_anthropic(root)
		"gemini":
			return _extract_gemini(root)
	return _extract_openai(root)


static func _extract_openai(root: Dictionary) -> Dictionary:
	if root.get("error") is Dictionary:
		return _envelope_error("bad_response",
			String((root["error"] as Dictionary).get("message", "provider reported an error")))
	var choices: Variant = root.get("choices")
	if not (choices is Array) or (choices as Array).is_empty():
		return _envelope_error("bad_response", "reply had no choices")
	var choice: Variant = (choices as Array)[0]
	if not (choice is Dictionary):
		return _envelope_error("bad_response", "first choice was not an object")
	var first: Dictionary = choice
	var text := ""
	if first.get("message") is Dictionary:
		var message: Dictionary = first["message"]
		if message.get("content") is String:
			text = String(message["content"])
	if text.is_empty() and first.get("text") is String:
		text = String(first["text"])
	if not first.has("message") and not first.has("text"):
		return _envelope_error("bad_response", "first choice had neither message nor text")
	var finish := String(first.get("finish_reason", ""))
	if finish == "length":
		return _envelope_error("truncated", "the provider hit the token cap", text)
	if finish == "content_filter":
		return _envelope_error("blocked", "the provider filtered the reply", text)
	return _envelope_ok(text, root.get("usage", {}))


static func _extract_anthropic(root: Dictionary) -> Dictionary:
	if String(root.get("type", "")) == "error":
		var detail := "provider reported an error"
		if root.get("error") is Dictionary:
			detail = String((root["error"] as Dictionary).get("message", detail))
		return _envelope_error("bad_response", detail)
	var blocks: Variant = root.get("content")
	if not (blocks is Array):
		return _envelope_error("bad_response", "reply had no content array")
	# R2 B — the first block whose `type` is `text`. A `tool_use`-first reply (R11) is skipped
	# rather than mistaken for a plan; a reply with no text block at all is unusable.
	for block in blocks:
		if block is Dictionary and String((block as Dictionary).get("type", "")) == "text":
			var text := String((block as Dictionary).get("text", ""))
			if String(root.get("stop_reason", "")) == "max_tokens":
				return _envelope_error("truncated", "the provider hit the token cap", text)
			return _envelope_ok(text, root.get("usage", {}))
	return _envelope_error("bad_response", "reply had no text block")


static func _extract_gemini(root: Dictionary) -> Dictionary:
	if root.get("promptFeedback") is Dictionary:
		var feedback: Dictionary = root["promptFeedback"]
		if not String(feedback.get("blockReason", "")).is_empty():
			return _envelope_error("blocked",
				"prompt blocked: %s" % String(feedback.get("blockReason", "")))
	var candidates: Variant = root.get("candidates")
	if not (candidates is Array) or (candidates as Array).is_empty():
		return _envelope_error("bad_response", "reply had no candidates")
	var first: Variant = (candidates as Array)[0]
	if not (first is Dictionary):
		return _envelope_error("bad_response", "first candidate was not an object")
	var parts := _gemini_parts(first)
	if parts.is_empty():
		return _envelope_error("bad_response", "first candidate had no text parts")
	var text := String((parts[0] as Dictionary).get("text", ""))
	var finish := String((first as Dictionary).get("finishReason", ""))
	if finish == "MAX_TOKENS":
		return _envelope_error("truncated", "the provider hit the token cap", text)
	if finish == "SAFETY" or finish == "RECITATION" or finish == "PROHIBITED_CONTENT":
		return _envelope_error("blocked", "reply blocked: %s" % finish, text)
	return _envelope_ok(text, root.get("usageMetadata", {}))


## Every part of `candidates[0].content.parts` that carries a `text` key, in order. R2 C reads
## `parts[0].text`; collecting the text-bearing parts first means a reply whose first part is not
## a text part still yields the first text part instead of a `bad_response` (R11 covers a
## three-part reply with an empty part in it).
static func _gemini_parts(candidate: Variant) -> Array:
	if not (candidate is Dictionary):
		return []
	var content: Variant = (candidate as Dictionary).get("content")
	if not (content is Dictionary):
		return []
	var parts: Variant = (content as Dictionary).get("parts")
	if not (parts is Array):
		return []
	var out: Array = []
	for part in parts:
		if part is Dictionary and (part as Dictionary).get("text") is String:
			out.append(part)
	return out


static func _envelope_ok(text: String, usage: Variant) -> Dictionary:
	var usage_out: Dictionary = {}
	if usage is Dictionary:
		usage_out = usage
	return {"error_code": "", "text": text, "detail": "", "usage": usage_out}


static func _envelope_error(code: String, detail: String, text: String = "") -> Dictionary:
	return {"error_code": code, "text": text, "detail": detail, "usage": {}}


# ===========================================================================
# R6/R7 — the call, the retries and the cancel
# ===========================================================================

## Runs one generation. **Await it:**
##     var result: LLMResult = await client.generate(cfg, system_prompt, user_prompt, opts)
##
## Returns a complete [LLMResult] and emits [signal request_finished] exactly once. Never throws,
## even with no scene tree, no socket and no key.
func generate(cfg: Dictionary, system_prompt: String, user_prompt: String,
		opts: Dictionary = {}) -> LLMResult:
	var provider := String(cfg.get("provider", LLMProviders.DEFAULT_KEY))
	var adapter := LLMProviders.adapter_for(provider)
	var model := LLMProviders.model_for(provider, cfg)
	var api_key := String(cfg.get("api_key", "")).strip_edges()
	var retries := maxi(0, int(opts.get("retries", DEFAULT_RETRIES)))
	var max_attempts := 1 + retries
	var timeout_sec := int(opts.get("timeout_sec", LLMProviders.default_timeout_sec(provider)))
	var backoff: Array = opts.get("backoff_sec", DEFAULT_BACKOFF_SEC)
	var json_mode := bool(opts.get("allow_json_mode", true)) \
		and LLMProviders.json_mode_ok(provider, cfg)
	var catalog_digest := String(opts.get("catalog_digest", ""))
	var prompt_version := String(opts.get("prompt_version", ""))

	if is_running:
		# R7: `busy` is never retried and never reaches the provider. The ladder's own
		# single-flight guard means this is a belt-and-braces branch, not the normal path.
		# `request_finished` is deliberately **not** emitted here: the in-flight generation owns
		# this signal, and emitting would tell its listener that an unrelated call had finished.
		return LLMResult.failure("busy", provider, model, adapter, 0, 0, 0,
			"a request is already in flight")
	if LLMProviders.requires_key(provider, cfg) and api_key.is_empty():
		# R6 step 1 owns this; the client refuses early too so no code path can send a
		# request that is guaranteed to fail (and no attempt is counted).
		return _settle(LLMResult.failure("no_key", provider, model, adapter, 0, 0, 0,
			"no API key is configured", api_key), true)

	is_running = true
	_cancelled = false
	var started := Time.get_ticks_msec()
	var attempts := 0
	var request_opts: Dictionary = {
		"max_tokens": int(opts.get("max_tokens", DEFAULT_MAX_TOKENS)),
		"temperature": float(opts.get("temperature", DEFAULT_TEMPERATURE)),
		"timeout_sec": timeout_sec,
		"json_mode": json_mode,
	}
	var adapted := false

	while attempts < max_attempts:
		if _cancelled:
			break
		attempts += 1
		attempt_started.emit(attempts, max_attempts)
		var request := build_request(provider, cfg, system_prompt, user_prompt, request_opts)
		var outcome := await _attempt(request)
		var latency := Time.get_ticks_msec() - started

		if _cancelled:
			break
		var transport_result := int(outcome.get("result", HTTPRequest.RESULT_SUCCESS))
		if transport_result != HTTPRequest.RESULT_SUCCESS:
			var code := LLMResult.transport_code(transport_result)
			_log(provider, adapter, attempts, max_attempts, 0, code, latency, catalog_digest,
				prompt_version)
			if LLMResult.is_transport_failure(code) and attempts < max_attempts:
				await _delay(_backoff_for(backoff, attempts))
				continue
			return _settle(LLMResult.failure(code, provider, model, adapter, 0, latency,
				attempts, LLMResult.transport_detail(transport_result), api_key), true)

		var status := int(outcome.get("status", 0))
		var body := String(outcome.get("body", ""))

		# R2 A — request adaptation, not a transport retry: a 400 that names the JSON-mode flag
		# means the provider does not implement it, so the same request goes out again without
		# it and the re-send counts as the next attempt. It happens at most once.
		if status == 400 and json_mode and not adapted and _mentions_json_mode(body):
			adapted = true
			json_mode = false
			request_opts["json_mode"] = false
			_log(provider, adapter, attempts, max_attempts, status, "bad_response", latency,
				catalog_digest, prompt_version)
			if attempts < max_attempts:
				continue

		if status < 200 or status > 299:
			var http_code := LLMResult.classify(status)
			_log(provider, adapter, attempts, max_attempts, status, http_code, latency,
				catalog_digest, prompt_version)
			# R7: no HTTP response is ever retried — not 400, 401, 403, 404, 429 or any 5xx.
			return _settle(LLMResult.failure(http_code, provider, model, adapter, status,
				latency, attempts, body, api_key), true)

		var envelope := extract_envelope(adapter, body)
		var envelope_code := String(envelope.get("error_code", ""))
		_log(provider, adapter, attempts, max_attempts, status, envelope_code, latency,
			catalog_digest, prompt_version)
		if not envelope_code.is_empty():
			return _settle(LLMResult.failure(envelope_code, provider, model, adapter, status,
				latency, attempts, String(envelope.get("detail", "")), api_key,
				String(envelope.get("text", ""))), true)
		return _settle(LLMResult.success(provider, model, adapter,
			String(envelope.get("text", "")), latency, attempts,
			envelope.get("usage", {})), true)

	var latency_end := Time.get_ticks_msec() - started
	return _settle(LLMResult.failure("cancelled", provider, model, adapter, 0, latency_end,
		attempts, "cancelled by the user", api_key), true)


## R7's backoff for the attempt that just failed: 1 s before attempt 2, 3 s before attempt 3.
## The table is read positionally and the last value repeats if a caller asks for more attempts
## than the table holds, so a custom `retries` never waits zero seconds by accident.
static func _backoff_for(table: Array, attempt: int) -> float:
	if table.is_empty():
		return 0.0
	var index := clampi(attempt - 1, 0, table.size() - 1)
	return maxf(0.0, float(table[index]))


## True when a 400 body blames the JSON-mode flag — case-insensitive `response_format` or
## `json mode` (R2 A).
static func _mentions_json_mode(body: String) -> bool:
	var lowered := body.to_lower()
	return lowered.contains("response_format") or lowered.contains("json mode")


## Aborts an in-flight generation (R6 step 9): the request is dropped, no retry follows and the
## caller's next look at [method generate]'s result sees `cancelled`.
func cancel() -> void:
	if not is_running:
		return
	_cancelled = true
	_stop_watchdog()
	if _http != null and is_instance_valid(_http):
		_http.cancel_request()
	if transport != null and is_instance_valid(transport) and transport.has_method(&"cancel"):
		transport.call(&"cancel")
	if not _attempt_settled:
		_pending = {"result": HTTPRequest.RESULT_REQUEST_FAILED, "status": 0, "body": ""}
		_attempt_settled = true
		_attempt_completed.emit()


## The single [HTTPRequest] child, created on first use. Its timeout is overwritten per attempt.
func ensure_http() -> HTTPRequest:
	if _http == null or not is_instance_valid(_http):
		_http = HTTPRequest.new()
		_http.name = "GenerationRequest"
		_http.timeout = float(DEFAULT_TIMEOUT_SEC)
		add_child(_http)
		if not _http.request_completed.is_connected(_on_request_completed):
			_http.request_completed.connect(_on_request_completed)
	return _http


# ------------------------------------------------------------------ one attempt

## One attempt, however it is delivered. Returns `{result, status, body}` with `result` an
## `HTTPRequest.Result`, so a fake transport and a real socket are indistinguishable downstream.
func _attempt(request: Dictionary) -> Dictionary:
	if transport != null and is_instance_valid(transport):
		var raw: Variant = transport.call(&"request", request)
		if raw is Dictionary:
			return raw
		return {"result": HTTPRequest.RESULT_CANT_CONNECT, "status": 0, "body": ""}
	return await _http_attempt(request)


func _http_attempt(request: Dictionary) -> Dictionary:
	var http := ensure_http()
	var timeout_sec := float(request.get("timeout_sec", DEFAULT_TIMEOUT_SEC))
	http.timeout = timeout_sec
	_pending = {}
	_attempt_settled = false
	var err := http.request(String(request["url"]), request["headers"], int(request["method"]),
		String(request["body"]))
	if err != OK:
		_pending = {"result": HTTPRequest.RESULT_CANT_CONNECT, "status": 0, "body": ""}
		_attempt_settled = true
		return _pending
	_start_watchdog(timeout_sec + WATCHDOG_MARGIN_SEC)
	if _attempt_settled:
		return _pending
	await _attempt_completed
	return _pending


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if _attempt_settled:
		return
	_pending = {
		"result": result,
		"status": response_code,
		"body": body.get_string_from_utf8(),
	}
	_settle_attempt()


## R7's 50 s wall-clock watchdog: a provider that accepts the connection and then says nothing
## must not hold the attempt open past `timeout + 5 s`.
func _start_watchdog(seconds: float) -> void:
	if not is_inside_tree():
		return
	if _watchdog == null or not is_instance_valid(_watchdog):
		_watchdog = Timer.new()
		_watchdog.name = "Watchdog"
		_watchdog.one_shot = true
		_watchdog.timeout.connect(_on_watchdog_timeout)
		add_child(_watchdog)
	_watchdog.stop()
	_watchdog.wait_time = seconds
	_watchdog.start()


func _stop_watchdog() -> void:
	if _watchdog != null and is_instance_valid(_watchdog):
		_watchdog.stop()


func _on_watchdog_timeout() -> void:
	if _attempt_settled:
		return
	if _http != null and is_instance_valid(_http):
		_http.cancel_request()
	_pending = {"result": HTTPRequest.RESULT_TIMEOUT, "status": 0, "body": ""}
	_settle_attempt()


func _settle_attempt() -> void:
	_stop_watchdog()
	_attempt_settled = true
	_attempt_completed.emit()


## R7's backoff, `Engine.time_scale`-independent, and interruptible so a cancel during the wait
## does not make the user sit through it.
func _delay(seconds: float) -> void:
	if seconds <= 0.0 or _cancelled:
		return
	if delay_seam != null and is_instance_valid(delay_seam):
		await delay_seam.call(&"delay", seconds)
		return
	if not is_inside_tree():
		return
	var remaining := seconds
	while remaining > 0.0 and not _cancelled:
		var slice := minf(remaining, CANCEL_SLICE_SEC)
		await get_tree().create_timer(slice, true, false, true).timeout
		remaining -= slice


# ------------------------------------------------------------------ settling

## Clears the in-flight flag *before* the signal, so an `await`er that immediately starts another
## generation is never told the client is busy (R2: emitted once per generate).
func _settle(result: LLMResult, emit_signal_now: bool) -> LLMResult:
	is_running = false
	_cancelled = false
	_attempt_settled = true
	if emit_signal_now:
		request_finished.emit(result)
	return result


func _log(provider: String, adapter: String, attempt: int, total: int, status: int, code: String,
		latency_ms: int, catalog_digest: String, prompt_version: String) -> void:
	var line := LLMResult.log_line(provider, adapter, attempt, total, status, code, latency_ms,
		catalog_digest, prompt_version)
	print(line)
	if log_sink.is_valid():
		log_sink.call(line)
