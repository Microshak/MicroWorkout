extends TestSuite
## PRD-07 R2 — envelope extraction, and the transport/HTTP classification behind it.
##
## [method LLMClient.extract_envelope] is static and pure, so every shape a provider can answer
## with is testable here: the three documented envelopes, the two "it answered but there is no
## plan in it" cases (an Anthropic tool_use-first reply, a Gemini candidate with no text part),
## the truncation and blocking signals, and the error envelopes.
##
## A 2xx body that carries *no* text is deliberately a success with `text == ""`: nothing in R2
## makes an empty reply a transport error, and the ladder's next step (`E_NOT_JSON` → one repair
## retry) is a better answer for it than a hard failure. That case is asserted below.

const ADAPTER_OPENAI := "openai_compatible"
const ADAPTER_ANTHROPIC := "anthropic"
const ADAPTER_GEMINI := "gemini"


func _init() -> void:
	suite_name = "llm_envelope"


func run() -> void:
	_test_openai()
	_test_anthropic()
	_test_gemini()
	_test_junk()
	_test_empty_text_paths()
	_test_usage()
	_test_transport_codes()
	_test_http_classification()
	_test_detail_scrubbing()


# ------------------------------------------------------------------ A: OpenAI-compatible

func _test_openai() -> void:
	begin("choices[0].message.content is the reply")
	var body := JSON.stringify({
		"id": "chatcmpl-1",
		"choices": [{"index": 0, "message": {"role": "assistant", "content": "{\"a\": 1}"},
			"finish_reason": "stop"}],
	})
	var envelope := LLMClient.extract_envelope(ADAPTER_OPENAI, body)
	assert_eq(String(envelope["error_code"]), "", "no error")
	assert_eq(String(envelope["text"]), "{\"a\": 1}", "the content")

	begin("choices[0].text is the documented fallback")
	var legacy := JSON.stringify({"choices": [{"text": "fallback text", "finish_reason": "stop"}]})
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_OPENAI, legacy)["text"]), "fallback text",
		"the text field")

	begin("finish_reason == length is `truncated` (R2 A)")
	var truncated := JSON.stringify({"choices": [{"message": {"content": "{\"a\":"},
		"finish_reason": "length"}]})
	var envelope_truncated := LLMClient.extract_envelope(ADAPTER_OPENAI, truncated)
	assert_eq(String(envelope_truncated["error_code"]), "truncated", "truncated")
	assert_eq(String(envelope_truncated["text"]), "{\"a\":", "the partial text is still reported")
	assert_true(LLMResult.is_known_code(String(envelope_truncated["error_code"])), "a closed code")

	begin("a content-filtered reply is `blocked`")
	var filtered := JSON.stringify({"choices": [{"message": {"content": ""},
		"finish_reason": "content_filter"}]})
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_OPENAI, filtered)["error_code"]), "blocked",
		"blocked")

	begin("an envelope with no choices is `bad_response`")
	for body_missing in PackedStringArray([
			"{}", "{\"choices\": []}", "{\"choices\": \"x\"}",
			"{\"choices\": [\"x\"]}"]):
		assert_eq(String(LLMClient.extract_envelope(ADAPTER_OPENAI, body_missing)["error_code"]),
			"bad_response", "body: %s" % body_missing)

	begin("a 2xx body carrying a provider error object is `bad_response` with its message")
	var error_body := JSON.stringify({"error": {"message": "model not found", "type": "invalid"}})
	var envelope_error := LLMClient.extract_envelope(ADAPTER_OPENAI, error_body)
	assert_eq(String(envelope_error["error_code"]), "bad_response", "bad_response")
	assert_eq(String(envelope_error["detail"]), "model not found", "the provider's own words")

	begin("a choice with neither message nor text is `bad_response`")
	var neither := JSON.stringify({"choices": [{"finish_reason": "stop"}]})
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_OPENAI, neither)["error_code"]),
		"bad_response", "bad_response")


# ------------------------------------------------------------------ B: Anthropic

func _test_anthropic() -> void:
	begin("the first text content block is the reply (R2 B)")
	var body := JSON.stringify({
		"id": "msg_1", "type": "message", "role": "assistant", "stop_reason": "end_turn",
		"content": [{"type": "text", "text": "{\"plan\": true}"}],
	})
	var envelope := LLMClient.extract_envelope(ADAPTER_ANTHROPIC, body)
	assert_eq(String(envelope["error_code"]), "", "no error")
	assert_eq(String(envelope["text"]), "{\"plan\": true}", "the text block")

	begin("a tool_use block first does not become the plan (R11)")
	var tool_first := JSON.stringify({
		"type": "message", "stop_reason": "tool_use",
		"content": [
			{"type": "tool_use", "id": "tu_1", "name": "plan", "input": {"a": 1}},
			{"type": "text", "text": "the real reply"},
		],
	})
	var envelope_tool := LLMClient.extract_envelope(ADAPTER_ANTHROPIC, tool_first)
	assert_eq(String(envelope_tool["error_code"]), "", "readable")
	assert_eq(String(envelope_tool["text"]), "the real reply", "the text block, not the tool call")
	assert_false(String(envelope_tool["text"]).contains("tool_use"), "the tool block is skipped")

	begin("a reply with no text block at all is `bad_response`")
	var no_text := JSON.stringify({"type": "message", "content": [{"type": "tool_use", "id": "x"}]})
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_ANTHROPIC, no_text)["error_code"]),
		"bad_response", "bad_response")
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_ANTHROPIC, "{\"type\": \"message\"}")
		["error_code"]), "bad_response", "a missing content array too")

	begin("stop_reason == max_tokens is `truncated` (R2 B)")
	var truncated := JSON.stringify({"type": "message", "stop_reason": "max_tokens",
		"content": [{"type": "text", "text": "{\"a\":"}]})
	var envelope_truncated := LLMClient.extract_envelope(ADAPTER_ANTHROPIC, truncated)
	assert_eq(String(envelope_truncated["error_code"]), "truncated", "truncated")
	assert_eq(String(envelope_truncated["text"]), "{\"a\":", "the partial text survives")

	begin("a top-level error is `bad_response` with error.message (R2 B)")
	var error_body := JSON.stringify({"type": "error",
		"error": {"type": "authentication_error", "message": "invalid x-api-key"}})
	var envelope_error := LLMClient.extract_envelope(ADAPTER_ANTHROPIC, error_body)
	assert_eq(String(envelope_error["error_code"]), "bad_response", "bad_response")
	assert_eq(String(envelope_error["detail"]), "invalid x-api-key", "the message is kept")
	assert_empty(envelope_error["text"], "and there is no text")

	begin("a refusal stop_reason with text still yields the text")
	var refusal := JSON.stringify({"type": "message", "stop_reason": "refusal",
		"content": [{"type": "text", "text": "I can't do that"}]})
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_ANTHROPIC, refusal)["error_code"]), "",
		"a refusal is readable; the validator will reject it as E_NOT_JSON")


# ------------------------------------------------------------------ C: Gemini

func _test_gemini() -> void:
	begin("candidates[0].content.parts[0].text is the reply (R2 C)")
	var body := JSON.stringify({"candidates": [{"content": {"parts": [{"text": "{\"plan\": 1}"}]},
		"finishReason": "STOP"}]})
	var envelope := LLMClient.extract_envelope(ADAPTER_GEMINI, body)
	assert_eq(String(envelope["error_code"]), "", "no error")
	assert_eq(String(envelope["text"]), "{\"plan\": 1}", "the first text part")

	begin("three parts with one blank still yields the reply (R11)")
	var three := JSON.stringify({"candidates": [{"finishReason": "STOP", "content": {"parts": [
		{"text": "first"}, {"text": ""}, {"text": "third"}]}}]})
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_GEMINI, three)["text"]), "first",
		"parts[0] wins, exactly as R2 C says")

	begin("a first part without text falls through to the first text part")
	var no_text_first := JSON.stringify({"candidates": [{"finishReason": "STOP", "content": {
		"parts": [{"inlineData": {"mimeType": "image/png"}}, {"text": "second part"}]}}]})
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_GEMINI, no_text_first)["text"]),
		"second part", "the first part carrying text")

	begin("promptFeedback.blockReason is `blocked` (R2 C)")
	var blocked := JSON.stringify({"promptFeedback": {"blockReason": "SAFETY"},
		"candidates": []})
	var envelope_blocked := LLMClient.extract_envelope(ADAPTER_GEMINI, blocked)
	assert_eq(String(envelope_blocked["error_code"]), "blocked", "blocked")
	assert_true(String(envelope_blocked["detail"]).contains("SAFETY"), "the reason is named")

	begin("an empty candidates array is `bad_response` (R2 C)")
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_GEMINI, "{\"candidates\": []}")
		["error_code"]), "bad_response", "empty")
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_GEMINI, "{}")["error_code"]),
		"bad_response", "missing")

	begin("finishReason == MAX_TOKENS is `truncated` (R2 C)")
	var truncated := JSON.stringify({"candidates": [{"finishReason": "MAX_TOKENS",
		"content": {"parts": [{"text": "{\"a\":"}]}}]})
	var envelope_truncated := LLMClient.extract_envelope(ADAPTER_GEMINI, truncated)
	assert_eq(String(envelope_truncated["error_code"]), "truncated", "truncated")
	assert_eq(String(envelope_truncated["text"]), "{\"a\":", "the partial text survives")

	begin("a safety finishReason is `blocked` too")
	for reason in PackedStringArray(["SAFETY", "RECITATION", "PROHIBITED_CONTENT"]):
		var safety := JSON.stringify({"candidates": [{"finishReason": reason,
			"content": {"parts": [{"text": "x"}]}}]})
		assert_eq(String(LLMClient.extract_envelope(ADAPTER_GEMINI, safety)["error_code"]),
			"blocked", "finishReason %s" % reason)

	begin("a candidate with no parts is `bad_response`")
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_GEMINI,
		"{\"candidates\": [{\"content\": {\"parts\": []}}]}")["error_code"]), "bad_response",
		"no parts")
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_GEMINI,
		"{\"candidates\": [{\"content\": {}}]}")["error_code"]), "bad_response", "no parts key")


# ------------------------------------------------------------------ junk

func _test_junk() -> void:
	begin("a body that is not JSON is `bad_response`, never a crash")
	for body in PackedStringArray(["", "not json", "<html>502 Bad Gateway</html>", "[1, 2]", "null",
			"\"a string\""]):
		var envelope := LLMClient.extract_envelope(ADAPTER_OPENAI, body)
		assert_eq(String(envelope["error_code"]), "bad_response", "body: '%s'" % body)
		assert_empty(envelope["text"], "and no text")

	begin("an unknown adapter falls back to the OpenAI shape")
	assert_eq(String(LLMClient.extract_envelope("nonsense",
		"{\"choices\": [{\"message\": {\"content\": \"x\"}}]}")["text"]), "x",
		"the OpenAI reader is the default")


func _test_empty_text_paths() -> void:
	begin("an empty content string is a readable success: the validator owns that failure")
	var empty := JSON.stringify({"choices": [{"message": {"content": ""}, "finish_reason": "stop"}]})
	var envelope := LLMClient.extract_envelope(ADAPTER_OPENAI, empty)
	assert_eq(String(envelope["error_code"]), "", "no transport-level error")
	assert_eq(String(envelope["text"]), "", "empty text")
	assert_false(String(envelope["detail"]).is_empty(), "but the envelope explains itself")

	begin("the validator turns that empty reply into E_NOT_JSON")
	var validation := PlanValidator.validate(String(envelope["text"]), [],
		{"goal": "hypertrophy", "days_per_week": 4, "duration_min": 40, "areas": ["chest"],
			"equipment": ["barbell"], "notes": ""})
	assert_false(bool(validation["ok"]), "not ok")
	assert_eq(String((validation["errors"] as Array)[0]["code"]), "E_NOT_JSON", "E_NOT_JSON")

	begin("an empty Anthropic text block behaves the same way")
	var anthropic_empty := JSON.stringify({"type": "message",
		"content": [{"type": "text", "text": ""}]})
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_ANTHROPIC, anthropic_empty)["error_code"]),
		"", "readable")
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_ANTHROPIC, anthropic_empty)["text"]), "",
		"empty")

	begin("an empty Gemini part behaves the same way")
	var gemini_empty := JSON.stringify({"candidates": [{"finishReason": "STOP",
		"content": {"parts": [{"text": ""}]}}]})
	assert_eq(String(LLMClient.extract_envelope(ADAPTER_GEMINI, gemini_empty)["error_code"]), "",
		"readable")


func _test_usage() -> void:
	begin("usage is carried through for the provider that reports it")
	var openai := JSON.stringify({"choices": [{"message": {"content": "x"}}],
		"usage": {"prompt_tokens": 1200, "completion_tokens": 800, "total_tokens": 2000}})
	assert_eq(int((LLMClient.extract_envelope(ADAPTER_OPENAI, openai)["usage"]
		as Dictionary)["total_tokens"]), 2000, "openai usage")

	var anthropic := JSON.stringify({"content": [{"type": "text", "text": "x"}],
		"usage": {"input_tokens": 1100, "output_tokens": 700}})
	assert_eq(int((LLMClient.extract_envelope(ADAPTER_ANTHROPIC, anthropic)["usage"]
		as Dictionary)["input_tokens"]), 1100, "anthropic usage")

	var gemini := JSON.stringify({"candidates": [{"content": {"parts": [{"text": "x"}]}}],
		"usageMetadata": {"promptTokenCount": 1000, "candidatesTokenCount": 500}})
	assert_eq(int((LLMClient.extract_envelope(ADAPTER_GEMINI, gemini)["usage"]
		as Dictionary)["promptTokenCount"]), 1000, "gemini usage")

	begin("a provider that reports nothing yields an empty usage dictionary")
	assert_empty(LLMClient.extract_envelope(ADAPTER_OPENAI, "{\"choices\": [{\"message\": "
		+ "{\"content\": \"x\"}}]}")["usage"], "no usage key")
	assert_empty(LLMClient.extract_envelope(ADAPTER_OPENAI, "{\"choices\": [{\"message\": "
		+ "{\"content\": \"x\"}}], \"usage\": \"lots\"}")["usage"], "usage of the wrong type")

	begin("a failure envelope never carries usage")
	assert_empty(LLMClient.extract_envelope(ADAPTER_OPENAI,
		"{\"error\": {\"message\": \"nope\"}}")["usage"], "empty")


# ------------------------------------------------------------------ transport and HTTP codes

func _test_transport_codes() -> void:
	begin("every HTTPRequest.Result maps into the closed vocabulary")
	var expected: Dictionary = {
		HTTPRequest.RESULT_CANT_RESOLVE: "no_network",
		HTTPRequest.RESULT_CANT_CONNECT: "no_network",
		HTTPRequest.RESULT_CONNECTION_ERROR: "no_network",
		HTTPRequest.RESULT_NO_RESPONSE: "no_network",
		HTTPRequest.RESULT_TIMEOUT: "timeout",
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "tls",
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: "bad_response",
		HTTPRequest.RESULT_REQUEST_FAILED: "no_network",
	}
	var results: Array = expected.keys()
	results.sort()
	for code in results:
		assert_eq(LLMResult.transport_code(int(code)), String(expected[code]),
			"result %d" % int(code))

	begin("exactly three of them are retryable, and they are R6 step 4's")
	var retryable := PackedStringArray()
	for code in results:
		if LLMResult.is_transport_failure(LLMResult.transport_code(int(code))):
			retryable.append(LLMResult.transport_code(int(code)))
	assert_eq(", ".join(retryable), "no_network, no_network, no_network, tls, no_network, "
		+ "no_network, timeout", "six result codes collapse to three retryable codes")
	assert_false(retryable.has("bad_response"),
		"a body-size overflow is the provider's answer, not the network")


func _test_http_classification() -> void:
	begin("HTTP statuses classify into the R3 vocabulary, and never as retryable")
	var statuses: Dictionary = {
		400: "bad_response", 401: "auth", 403: "forbidden", 404: "bad_path",
		409: "bad_response", 422: "bad_response", 429: "rate_limited", 500: "server",
		501: "server", 502: "server", 503: "server", 504: "server",
	}
	var codes: Array = statuses.keys()
	codes.sort()
	for status in codes:
		var code := LLMResult.classify(int(status))
		assert_eq(code, String(statuses[int(status)]), "HTTP %d" % int(status))
		assert_false(LLMResult.is_transport_failure(code),
			"HTTP %d must never be retried (R7)" % int(status))


func _test_detail_scrubbing() -> void:
	begin("a detail carrying a key is scrubbed before it can be stored")
	var key := "sk-test-0000000000"
	var body := JSON.stringify({"error": {"message": "Invalid API key: " + key}})
	var envelope := LLMClient.extract_envelope(ADAPTER_OPENAI, body)
	var result := LLMResult.failure("bad_response", "custom", "m", ADAPTER_OPENAI, 401, 5, 1,
		String(envelope["detail"]), key)
	assert_false(result.redacted_detail.contains(key), "the key is gone")
	assert_true(result.redacted_detail.contains(Redact.PLACEHOLDER), "[REDACTED] is in its place")
	assert_le(float(result.redacted_detail.length()), 300.0, "and it is still capped")

	begin("a Gemini key in a URL inside a detail is scrubbed too")
	var gemini_detail := "https://example.test/v1beta/models/x:generateContent?key=" + key
	var scrubbed := Redact.safe_error(gemini_detail, key)
	assert_false(scrubbed.contains(key), "gone")
	assert_true(scrubbed.contains("key=" + Redact.PLACEHOLDER), "parameter preserved")
