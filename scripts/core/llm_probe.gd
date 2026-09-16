class_name LLMProbe
extends Node
## PRD-06 R9 — `Test connection`: **one** authenticated request, **one** attempt, 20 s, no
## retries, cancellable.
##
## [b]Why this is not in `scripts/autoload/llm.gd`:[/b] R9 assigns `LLM.test_connection()` there,
## and that file is outside this PRD's write scope (PRD-07 owns it and rebuilds the internals on
## the shared adapters). The provider block therefore prefers `LLM.test_connection()` the moment
## it exists and falls back to this probe until then. Everything provider-shaped lives in
## [LLMProviders] (URL, headers, body, every message), so when PRD-07 lands, this file is deleted
## and nothing else changes.
##
## Absolute rules, because this is the one code path that holds a real key in memory:
##
## * the key is never printed, never toasted, never stored in a result — only the provider's own
##   answer text is kept, and only after [method Redact.safe_error] has scrubbed it;
## * the URL (which carries `?key=` for Gemini) never reaches a log or a message either — the
##   copy table talks about the **host**, not the URL.
##
## The caller owns persistence: after [method run] returns, R9's `last_test_ok` /
## `last_tested_at` / `Store.save_settings()` are the screen's job, so this node stays a pure
## transport.

signal finished(result: Dictionary)

## True between [method run] starting and the result being settled.
var is_running: bool = false

var _http: HTTPRequest = null
var _provider: String = ""
var _base_url: String = ""
var _api_key: String = ""
var _started_ms: int = 0
var _settled: bool = true
var _last_result: Dictionary = {}


func _ready() -> void:
	ensure_http()


## The single [HTTPRequest] child, created on first use. Its timeout is R9's 20 s.
func ensure_http() -> HTTPRequest:
	if _http == null or not is_instance_valid(_http):
		_http = HTTPRequest.new()
		_http.name = "ConnectionRequest"
		_http.timeout = float(LLMProviders.TEST_TIMEOUT_SEC)
		add_child(_http)
	return _http


## Probes [param cfg] (an `llm` block) once. Await it:
##     var result: Dictionary = await probe.run(cfg)
##
## Returns `{}` when the configuration does not validate — a malformed base URL or model is a
## form problem, not a provider answer, and the screen already shows the field message. Every
## other return value is a complete R9 result dictionary.
func run(cfg: Dictionary) -> Dictionary:
	if is_running:
		return _last_result
	var report := StoreSchema.validate_llm(cfg)
	if not bool(report["ok"]):
		return {}

	var config: Dictionary = report["normalized"]
	_provider = String(config["provider"])
	_base_url = String(config["base_url"])
	_api_key = String(config["api_key"])
	_settled = false
	is_running = true

	if not is_inside_tree():
		# Without a scene tree there is no HTTPRequest peer; report the same branch a device
		# with no route out would report rather than throwing at the caller.
		_finish(LLMProviders.failure_result("no_network", _provider, _base_url, 0, 0,
			"probe is not in the scene tree", _api_key))
		return _last_result

	var request := LLMProviders.connection_request(_provider, config)
	var http := ensure_http()
	_started_ms = Time.get_ticks_msec()

	if not http.request_completed.is_connected(_on_request_completed):
		http.request_completed.connect(_on_request_completed)
	var err := http.request(String(request["url"]), request["headers"], int(request["method"]),
		String(request["body"]))
	if err != OK:
		_finish(LLMProviders.failure_result("no_network", _provider, _base_url, 0, 0,
			"HTTPRequest refused the request (error %d)" % err, _api_key))
	if _settled:
		# The failure above was synchronous, so `finished` has already fired and awaiting it
		# now would wait forever.
		return _last_result
	await finished
	return _last_result


## Aborts an in-flight probe — used when the user navigates away mid-test (R9).
func cancel() -> void:
	if not is_running:
		return
	if _http != null and is_instance_valid(_http):
		_http.cancel_request()
	_finish(LLMProviders.failure_result("cancelled", _provider, _base_url, 0, 0, "", _api_key))


# ------------------------------------------------------------------ internals

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if _settled:
		return
	var latency := Time.get_ticks_msec() - _started_ms
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish(LLMProviders.failure_result(transport_code(result), _provider, _base_url, 0,
			latency, transport_detail(result), _api_key))
		return

	var text := body.get_string_from_utf8()
	if response_code >= 200 and response_code <= 299:
		var parsed: Variant = JSON.parse_string(text)
		if not (parsed is Dictionary):
			_finish(LLMProviders.failure_result("bad_response", _provider, _base_url,
				response_code, latency, text, _api_key))
			return
		_finish(LLMProviders.success_result(_provider, latency))
		return

	_finish(LLMProviders.failure_result(LLMProviders.classify_status(response_code), _provider,
		_base_url, response_code, latency, text, _api_key))


## Settles the probe exactly once, whatever raced to finish it (a cancel and a late
## `request_completed` can both arrive). [member _settled] is true whenever nothing is in flight.
func _finish(result: Dictionary) -> void:
	if _settled:
		return
	_settled = true
	is_running = false
	_last_result = result
	# The one greppable line for this feature (PRD-06 §7). No key, no URL, no message body.
	print("[llm] test_connection ok=%s code=%s status=%d latency_ms=%d provider=%s" % [
		str(bool(result.get("ok", false))),
		String(result.get("error_code", "")) if not String(result.get("error_code", "")).is_empty() else "ok",
		int(result.get("http_status", 0)),
		int(result.get("latency_ms", 0)),
		_provider])
	finished.emit(result)


## `HTTPRequest.Result` -> the closed `error_code` vocabulary R9 defines.
static func transport_code(result: int) -> String:
	match result:
		HTTPRequest.RESULT_TIMEOUT:
			return "timeout"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "tls"
		HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CANT_CONNECT, \
		HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_NO_RESPONSE:
			return "no_network"
	return "no_network"


## A developer-facing description of a transport failure. Never contains the URL, because the
## URL can contain the key.
static func transport_detail(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "DNS lookup failed"
		HTTPRequest.RESULT_CANT_CONNECT:
			return "connection refused"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "connection error"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "no response"
		HTTPRequest.RESULT_TIMEOUT:
			return "timed out"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS handshake failed"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "response body too large"
	return "transport error %d" % result
