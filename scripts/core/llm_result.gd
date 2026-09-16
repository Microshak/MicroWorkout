class_name LLMResult
extends RefCounted
## PRD-07 R3 — the one value object every adapter, retry and ladder branch fills in.
##
## It is deliberately dumb data plus three pure statics, because it is the *only* thing that
## crosses the `LLMClient` -> `LLM` boundary: a fake transport can therefore produce a complete,
## realistic result without a socket, which is what makes `tests/suites/test_llm_ladder.gd`
## run headless (R11).
##
## [b]Key discipline (R12).[/b] The API key never reaches any field of this object:
## [member redacted_detail] is always produced through [method Redact.safe_error] and
## [member text] is provider output, never a request echo, so a result can be logged, shown or
## stored in `plan.generation` without leaking a credential. [method to_dictionary] exists so a
## caller can log the whole object at once and still be safe.

## The closed `error_code` vocabulary (R3). `""` is success; every other value has exactly one
## meaning, so a caller never has to parse a message to branch.
const ERROR_CODES: PackedStringArray = [
	"", "no_key", "no_network", "tls", "timeout", "auth", "forbidden", "bad_path",
	"rate_limited", "server", "bad_response", "truncated", "blocked", "cancelled", "busy",
]

## Transport failures worth 1 s / 3 s of backoff and up to [constant RETRIES] re-sends — and
## nothing else is ever retried (R7). A 5xx is a *response*, so it is deliberately absent.
const TRANSPORT_FAILURES: PackedStringArray = ["no_network", "tls", "timeout"]

## Failures that name the saved key rather than the network; R6's copy sends the user to
## Settings for these, and the generating overlay shows its `Fix in Settings` button (R9).
const KEY_FAILURES: PackedStringArray = ["auth", "forbidden", "no_key", "bad_path"]

## `redacted_detail` cap (R3, PRD-06 R9).
const DETAIL_MAX: int = 300

var ok: bool = false
var text: String = ""
var error_code: String = ""
var http_status: int = 0
var attempts: int = 0
var latency_ms: int = 0
var provider: String = ""
var model: String = ""
## `openai_compatible` | `anthropic` | `gemini` (§8.1).
var adapter: String = ""
## The provider's or the transport's own words, scrubbed of every secret and capped at
## [constant DETAIL_MAX]. Safe to log; never contains a key, a header or a full URL.
var redacted_detail: String = ""
## Token accounting when the provider reports it (`usage` / `usageMetadata`), else `{}`.
var usage: Dictionary = {}


# ------------------------------------------------------------------ construction

## The success shape. [param text] is the model's own reply (still unvalidated — the ladder
## hands it to [PlanValidator] next).
static func success(provider_key: String, model_name: String, adapter_name: String,
		text_value: String, latency: int, attempts_made: int,
		usage_value: Dictionary = {}) -> LLMResult:
	var result := LLMResult.new()
	result.ok = true
	result.text = text_value
	result.http_status = 200
	result.attempts = attempts_made
	result.latency_ms = latency
	result.provider = provider_key
	result.model = model_name
	result.adapter = adapter_name
	result.usage = usage_value
	return result


## The failure shape. [param detail] is scrubbed here, once, so no caller can forget to.
## [param api_key] is used only as a redaction secret and is never stored.
static func failure(error: String, provider_key: String, model_name: String, adapter_name: String,
		http_status_value: int, latency: int, attempts_made: int, detail: String = "",
		api_key: String = "", text_value: String = "") -> LLMResult:
	var result := LLMResult.new()
	result.ok = false
	result.error_code = error
	result.http_status = http_status_value
	result.attempts = attempts_made
	result.latency_ms = latency
	result.provider = provider_key
	result.model = model_name
	result.adapter = adapter_name
	result.redacted_detail = Redact.safe_error(detail, api_key)
	result.text = text_value
	return result


## A copy with the attempt counter and latency replaced — the retry loop owns those two fields
## and nothing else changes between attempts.
func with_attempts(attempts_made: int, latency: int) -> LLMResult:
	var copy := duplicate_result()
	copy.attempts = attempts_made
	copy.latency_ms = latency
	return copy


func duplicate_result() -> LLMResult:
	var copy := LLMResult.new()
	copy.ok = ok
	copy.text = text
	copy.error_code = error_code
	copy.http_status = http_status
	copy.attempts = attempts
	copy.latency_ms = latency_ms
	copy.provider = provider
	copy.model = model
	copy.adapter = adapter
	copy.redacted_detail = redacted_detail
	copy.usage = usage.duplicate()
	return copy


# ------------------------------------------------------------------ classification (R3)

## HTTP status -> `error_code`. 401 -> `auth`, 403 -> `forbidden`, 404 -> `bad_path`,
## 429 -> `rate_limited`, any 5xx -> `server`, everything else non-2xx -> `bad_response`.
## The same mapping [LLMProviders.classify_status] uses for `Test connection`, kept in one
## vocabulary so the two code paths cannot disagree.
static func classify(status: int) -> String:
	if status == 401:
		return "auth"
	if status == 403:
		return "forbidden"
	if status == 404:
		return "bad_path"
	if status == 429:
		return "rate_limited"
	if status >= 500 and status <= 599:
		return "server"
	return "bad_response"


## `HTTPRequest.Result` -> `error_code`. Only the connection-class failures come back as
## retryable; a body-size overflow is the provider's answer being unusable, not the network.
static func transport_code(result: int) -> String:
	match result:
		HTTPRequest.RESULT_TIMEOUT:
			return "timeout"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "tls"
		HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CANT_CONNECT, \
		HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_NO_RESPONSE:
			return "no_network"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "bad_response"
	return "no_network"


## A developer-facing description of a transport failure. Never contains the URL, because a
## Gemini URL carries `?key=` (R12).
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


## True for the three failures R7 retries with the 1 s / 3 s backoff.
static func is_transport_failure(code: String) -> bool:
	return TRANSPORT_FAILURES.has(code)


## True when `error_code` names the key rather than the request (R6's copy, R9's button).
static func is_key_failure(code: String) -> bool:
	return KEY_FAILURES.has(code)


## True for a code inside the closed R3 vocabulary — a test-time guard against a typo
## inventing a sixteenth code that no copy table knows how to render.
static func is_known_code(code: String) -> bool:
	return ERROR_CODES.has(code)


# ------------------------------------------------------------------ serialisation

## The complete object as a dictionary, provably free of secrets (R12): the key is not a field
## of this class, and `redacted_detail` was scrubbed at construction.
func to_dictionary() -> Dictionary:
	return {
		"ok": ok,
		"error_code": error_code,
		"http_status": http_status,
		"attempts": attempts,
		"latency_ms": latency_ms,
		"provider": provider,
		"model": model,
		"adapter": adapter,
		"redacted_detail": redacted_detail,
		"text_length": text.length(),
		"usage": usage.duplicate(),
	}


## The one log line the whole client emits per request (R7). No URL, no headers, no body, no
## key — `provider`, `adapter`, `attempt`, `status`, `code`, `ms` only.
static func log_line(provider_key: String, adapter_name: String, attempt: int, total: int,
		status: int, code: String, latency_ms_value: int, catalog_digest: String,
		prompt_version: String) -> String:
	var short_digest := catalog_digest.substr(0, 8)
	return "[llm] provider=%s adapter=%s attempt=%d/%d status=%d code=%s ms=%d catalog=%s prompt=%s" % [
		provider_key, adapter_name, attempt, total, status,
		code if not code.is_empty() else "ok", latency_ms_value, short_digest, prompt_version]
