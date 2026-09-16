extends TestSuite
## PRD-07 R2 — the byte-exact request each adapter builds.
##
## [method LLMClient.build_request] is the **only** place a generation request is assembled, and
## it is static, so this suite proves the whole wire format with no socket, no scene tree and no
## provider: the method, the URL, the header set and the body bytes.
##
## The golden bodies below were produced from the same fixed prompt pair by an independent
## encoder (Python's `json.dumps(..., separators=(",", ":"))`), so a change to the client's
## escaping or key order shows up as a diff rather than as a silently different request.

## The fixed prompt pair every golden is built from. It contains a newline, a double quote and a
## non-ASCII character on purpose: escaping and UTF-8 pass-through are part of the wire format.
const SYSTEM := "SYSTEM\nline two \"quoted\" — dash"
const USER := "USER\n{\"a\": 1}"

const GOLDEN_DEEPSEEK := "{\"model\":\"deepseek-chat\",\"messages\":[{\"role\":\"system\",\"content\":\"SYSTEM\\nline two \\\"quoted\\\" — dash\"},{\"role\":\"user\",\"content\":\"USER\\n{\\\"a\\\": 1}\"}],\"temperature\":0.4,\"max_tokens\":4096,\"response_format\":{\"type\":\"json_object\"},\"stream\":false}"
const GOLDEN_OPENAI_NO_JSON := "{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"system\",\"content\":\"SYSTEM\\nline two \\\"quoted\\\" — dash\"},{\"role\":\"user\",\"content\":\"USER\\n{\\\"a\\\": 1}\"}],\"temperature\":0.4,\"max_tokens\":4096,\"stream\":false}"
const GOLDEN_ANTHROPIC := "{\"model\":\"claude-3-5-sonnet-latest\",\"max_tokens\":4096,\"temperature\":0.4,\"system\":\"SYSTEM\\nline two \\\"quoted\\\" — dash\",\"messages\":[{\"role\":\"user\",\"content\":\"USER\\n{\\\"a\\\": 1}\"}]}"
const GOLDEN_GEMINI := "{\"systemInstruction\":{\"parts\":[{\"text\":\"SYSTEM\\nline two \\\"quoted\\\" — dash\"}]},\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"USER\\n{\\\"a\\\": 1}\"}]}],\"generationConfig\":{\"temperature\":0.4,\"maxOutputTokens\":4096,\"responseMimeType\":\"application/json\"}}"
const GOLDEN_GEMINI_NO_JSON := "{\"systemInstruction\":{\"parts\":[{\"text\":\"SYSTEM\\nline two \\\"quoted\\\" — dash\"}]},\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"USER\\n{\\\"a\\\": 1}\"}]}],\"generationConfig\":{\"temperature\":0.4,\"maxOutputTokens\":4096}}"
const GOLDEN_REPAIR := "{\"model\":\"deepseek-chat\",\"messages\":[{\"role\":\"system\",\"content\":\"SYSTEM\\nline two \\\"quoted\\\" — dash\"},{\"role\":\"user\",\"content\":\"USER\\n{\\\"a\\\": 1}\"}],\"temperature\":0.2,\"max_tokens\":4096,\"response_format\":{\"type\":\"json_object\"},\"stream\":false}"

## A body must never carry the key in plain sight in a *test* expectation, so the key used here is
## the mock server's published placeholder.
const KEY := "sk-test-0000000000"


func _init() -> void:
	suite_name = "llm_request_build"


func run() -> void:
	_test_shape()
	_test_openai_family()
	_test_anthropic()
	_test_gemini()
	_test_golden_bodies()
	_test_header_sets()
	_test_json_mode_switches()
	_test_body_key_sets()
	_test_timeout()


func _cfg(key: String, overrides: Dictionary = {}) -> Dictionary:
	var cfg: Dictionary = {
		"provider": key,
		"base_url": LLMProviders.default_base_url(key),
		"model": LLMProviders.default_model(key),
		"api_key": KEY,
		"custom_auth_none": false,
		"custom_json_mode": true,
	}
	for field in overrides.keys():
		cfg[field] = overrides[field]
	return cfg


func _request(key: String, overrides: Dictionary = {}, opts: Dictionary = {}) -> Dictionary:
	return LLMClient.build_request(key, _cfg(key, overrides), SYSTEM, USER, opts)


# ------------------------------------------------------------------ shape

func _test_shape() -> void:
	begin("build_request() returns exactly R2's five fields")
	var request := _request("deepseek")
	for field in PackedStringArray(["method", "url", "headers", "body", "timeout_sec"]):
		assert_has_key(request, field, "missing %s" % field)
	assert_eq(request.size(), 5, "and nothing else")
	assert_eq(int(request["method"]), HTTPClient.METHOD_POST, "every adapter POSTs")
	assert_true(request["headers"] is PackedStringArray, "headers are a PackedStringArray")
	assert_true(request["body"] is String, "body is a String")

	begin("the request is deterministic: the same arguments give the same bytes")
	var again := _request("deepseek")
	assert_eq(String(again["body"]), String(request["body"]), "body identical")
	assert_eq(", ".join(again["headers"] as PackedStringArray),
		", ".join(request["headers"] as PackedStringArray), "headers identical")

	begin("no key is ever exposed through the request dictionary's shape")
	var gemini := _request("gemini")
	assert_true(String(gemini["url"]).contains("key=" + KEY),
		"gemini's key rides in the URL (the reason URLs are never logged)")
	assert_false(String(gemini["url"]).contains("Authorization"), "and never in a header")


# ------------------------------------------------------------------ adapter A

func _test_openai_family() -> void:
	begin("the OpenAI-compatible adapter serves five presets")
	for key in PackedStringArray(["openai", "deepseek", "openrouter", "groq", "custom"]):
		var request := _request(key, {"base_url": "https://example.test/v1"})
		assert_eq(String(request["url"]), "https://example.test/v1/chat/completions",
			"%s posts to /chat/completions" % key)

	begin("R2 A's body has exactly the documented keys")
	var parsed: Variant = JSON.parse_string(String(_request("deepseek")["body"]))
	assert_true(parsed is Dictionary, "the body is JSON")
	var body: Dictionary = parsed
	assert_eq(", ".join(PackedStringArray(["model", "messages", "temperature", "max_tokens",
		"response_format", "stream"])), "model, messages, temperature, max_tokens, "
		+ "response_format, stream", "the expected key order, for the reader's sake")
	assert_has_key(body, "model", "model")
	assert_has_key(body, "messages", "messages")
	assert_has_key(body, "temperature", "temperature")
	assert_has_key(body, "max_tokens", "max_tokens")
	assert_has_key(body, "response_format", "response_format")
	assert_has_key(body, "stream", "stream")
	assert_eq(body["stream"], false, "streaming is off (§8.2 is a single shot)")
	assert_eq(String(body["model"]), "deepseek-chat", "the model is the preset's default")
	assert_close(float(body["temperature"]), 0.4, 0.0001, "R2's default temperature")
	assert_eq(int(body["max_tokens"]), 4096, "R2's default token cap")

	begin("R2 A's system/user pair is messages[0]/messages[1]")
	var messages: Array = body["messages"]
	assert_eq(messages.size(), 2, "two messages")
	assert_eq(String((messages[0] as Dictionary)["role"]), "system", "system first")
	assert_eq(String((messages[0] as Dictionary)["content"]), SYSTEM, "the system prompt verbatim")
	assert_eq(String((messages[1] as Dictionary)["role"]), "user", "user second")
	assert_eq(String((messages[1] as Dictionary)["content"]), USER, "the user prompt verbatim")

	begin("no max_tokens omission: the cap is always present for this family")
	assert_false(String(_request("groq", {}, {"max_tokens": 512})["body"]).contains("4096"),
		"an override replaces the default")
	assert_true(String(_request("groq", {}, {"max_tokens": 512})["body"]).contains("\"max_tokens\":512"),
		"and is written as given")


# ------------------------------------------------------------------ adapter B

func _test_anthropic() -> void:
	begin("R2 B's Anthropic body has exactly the documented keys")
	var request := _request("anthropic")
	assert_eq(String(request["url"]), "https://api.anthropic.com/v1/messages", "the /messages path")
	var parsed: Variant = JSON.parse_string(String(request["body"]))
	assert_true(parsed is Dictionary, "the body is JSON")
	var body: Dictionary = parsed
	assert_eq(body.size(), 5, "exactly five keys")
	assert_has_key(body, "model", "model")
	assert_has_key(body, "max_tokens", "max_tokens")
	assert_has_key(body, "temperature", "temperature")
	assert_has_key(body, "system", "system")
	assert_has_key(body, "messages", "messages")
	assert_false(body.has("response_format"), "Anthropic has no JSON-mode flag")
	assert_false(body.has("stream"), "and no stream flag")
	assert_eq(int(body["max_tokens"]), 4096, "max_tokens is required, not optional")

	begin("the system prompt is a top-level `system`, not a message")
	assert_eq(String(body["system"]), SYSTEM, "system verbatim")
	var messages: Array = body["messages"]
	assert_eq(messages.size(), 1, "one message")
	assert_eq(String((messages[0] as Dictionary)["role"]), "user", "only the user turn")
	assert_eq(String((messages[0] as Dictionary)["content"]), USER, "user verbatim")

	begin("anthropic-version is sent, and x-api-key carries the credential")
	var headers := request["headers"] as PackedStringArray
	assert_true(headers.has("anthropic-version: 2023-06-01"), "the version header")
	assert_true(headers.has("x-api-key: " + KEY), "the key header")
	assert_false(_header_joined(headers).contains("Authorization"), "no bearer header")


# ------------------------------------------------------------------ adapter C

func _test_gemini() -> void:
	begin("R2 C's Gemini URL is /models/{model}:generateContent?key=")
	var request := _request("gemini")
	assert_eq(String(request["url"]), "https://generativelanguage.googleapis.com/v1beta/models/"
		+ "gemini-1.5-flash:generateContent?key=" + KEY, "verbatim")
	var headers := request["headers"] as PackedStringArray
	assert_false(_header_joined(headers).contains("Authorization"), "no Authorization header")
	assert_false(_header_joined(headers).contains(KEY), "and no key in a header either")

	begin("R2 C's Gemini body has exactly the documented keys")
	var parsed: Variant = JSON.parse_string(String(request["body"]))
	assert_true(parsed is Dictionary, "the body is JSON")
	var body: Dictionary = parsed
	assert_eq(body.size(), 3, "exactly three top-level keys")
	assert_has_key(body, "systemInstruction", "systemInstruction")
	assert_has_key(body, "contents", "contents")
	assert_has_key(body, "generationConfig", "generationConfig")
	assert_false(body.has("messages"), "no chat-style messages")
	assert_false(body.has("model"), "the model is in the URL, not the body")

	begin("the system prompt rides in systemInstruction.parts[0].text")
	var instruction: Dictionary = body["systemInstruction"]
	var parts: Array = instruction["parts"]
	assert_eq(parts.size(), 1, "one part")
	assert_eq(String((parts[0] as Dictionary)["text"]), SYSTEM, "system verbatim")

	begin("the user prompt rides in contents[0].parts[0].text")
	var contents: Array = body["contents"]
	assert_eq(contents.size(), 1, "one content entry")
	assert_eq(String((contents[0] as Dictionary)["role"]), "user", "role user")
	var content_parts: Array = (contents[0] as Dictionary)["parts"]
	assert_eq(content_parts.size(), 1, "one part")
	assert_eq(String((content_parts[0] as Dictionary)["text"]), USER, "user verbatim")

	begin("generationConfig uses maxOutputTokens and responseMimeType")
	var config: Dictionary = body["generationConfig"]
	assert_eq(config.size(), 3, "three fields")
	assert_eq(int(config["maxOutputTokens"]), 4096, "the Gemini token field name")
	assert_close(float(config["temperature"]), 0.4, 0.0001, "temperature")
	assert_eq(String(config["responseMimeType"]), "application/json", "JSON mode")


func _header_joined(headers: PackedStringArray) -> String:
	return ", ".join(headers)


# ------------------------------------------------------------------ goldens

func _test_golden_bodies() -> void:
	begin("the OpenAI-compatible body byte-equals the golden")
	assert_eq(String(_request("deepseek")["body"]), GOLDEN_DEEPSEEK, "deepseek golden")

	begin("the same body without JSON mode byte-equals its golden")
	assert_eq(String(_request("openai", {}, {"json_mode": false})["body"]), GOLDEN_OPENAI_NO_JSON,
		"no response_format")

	begin("the repair temperature produces its own golden")
	assert_eq(String(_request("deepseek", {}, {"temperature": 0.2})["body"]), GOLDEN_REPAIR,
		"temperature 0.2")

	begin("the Anthropic body byte-equals the golden")
	assert_eq(String(_request("anthropic")["body"]), GOLDEN_ANTHROPIC, "anthropic golden")

	begin("the Gemini body byte-equals the golden, with and without JSON mode")
	assert_eq(String(_request("gemini")["body"]), GOLDEN_GEMINI, "gemini golden")
	assert_eq(String(_request("gemini", {}, {"json_mode": false})["body"]), GOLDEN_GEMINI_NO_JSON,
		"gemini without responseMimeType")

	begin("the goldens really are different requests — the test is not vacuous")
	assert_ne(GOLDEN_DEEPSEEK, GOLDEN_OPENAI_NO_JSON, "JSON mode changes the bytes")
	assert_ne(GOLDEN_ANTHROPIC, GOLDEN_DEEPSEEK, "the adapters differ")
	assert_ne(GOLDEN_GEMINI, GOLDEN_DEEPSEEK, "the adapters differ")


# ------------------------------------------------------------------ headers

func _test_header_sets() -> void:
	begin("every request starts with Content-Type and Accept")
	for key in LLMProviders.keys():
		var headers := _request(key, {"base_url": "https://example.test/v1"})["headers"] \
			as PackedStringArray
		assert_eq(String(headers[0]), "Content-Type: application/json", "%s content type" % key)
		assert_eq(String(headers[1]), "Accept: application/json", "%s accept" % key)
		assert_false(_header_joined(headers).contains("Accept-Encoding"),
			"%s must not pin Accept-Encoding (R7: Godot decompresses)" % key)

	begin("the OpenAI family sends a bearer header, sorted extras and nothing else")
	for key in PackedStringArray(["openai", "deepseek", "groq"]):
		var headers := _request(key, {"base_url": "https://example.test/v1"})["headers"] \
			as PackedStringArray
		assert_eq(headers.size(), 3, "%s: Content-Type, Accept, Authorization" % key)
		assert_eq(String(headers[2]), "Authorization: Bearer " + KEY, "%s bearer" % key)

	begin("OpenRouter adds its two attribution headers before the bearer header")
	var openrouter := _request("openrouter", {"base_url": "https://example.test/v1"})["headers"] \
		as PackedStringArray
	assert_eq(openrouter.size(), 5, "two extras plus the bearer header")
	assert_eq(String(openrouter[2]), "HTTP-Referer: https://github.com/microshak/microworkout",
		"sorted: HTTP-Referer first")
	assert_eq(String(openrouter[3]), "X-Title: MicroWorkout", "then X-Title")
	assert_eq(String(openrouter[4]), "Authorization: Bearer " + KEY, "then auth")

	begin("a keyless custom server sends no Authorization header")
	var keyless := _request("custom", {"base_url": "http://10.0.2.2:8765/v1",
		"custom_auth_none": true})["headers"] as PackedStringArray
	assert_eq(keyless.size(), 2, "only the two content headers")
	assert_false(_header_joined(keyless).contains(KEY), "and no key anywhere")

	begin("Gemini's header set carries no credential at all")
	var gemini := _request("gemini")["headers"] as PackedStringArray
	assert_eq(gemini.size(), 2, "two headers")
	assert_false(_header_joined(gemini).contains(KEY), "the key is in the URL only")

	begin("no header value is repeated")
	for key in LLMProviders.keys():
		var headers := _request(key, {"base_url": "https://example.test/v1"})["headers"] \
			as PackedStringArray
		var seen: Dictionary = {}
		for header in headers:
			var name := String(header).split(":")[0].to_lower()
			assert_false(seen.has(name), "%s repeats the %s header" % [key, name])
			seen[name] = true


# ------------------------------------------------------------------ JSON mode switches

func _test_json_mode_switches() -> void:
	begin("response_format is included only when json_mode_ok() is true")
	assert_true(String(_request("openai")["body"]).contains("\"response_format\""),
		"openai supports JSON mode")
	assert_true(String(_request("deepseek")["body"]).contains("\"response_format\""),
		"deepseek supports JSON mode")
	assert_true(String(_request("openrouter")["body"]).contains("\"response_format\""),
		"openrouter supports JSON mode")
	assert_true(String(_request("gemini")["body"]).contains("\"responseMimeType\":\"application/json\""),
		"gemini expresses it as responseMimeType")

	begin("a provider that does not implement JSON mode never sees the flag")
	assert_false(String(_request("anthropic")["body"]).contains("response_format"),
		"anthropic")
	assert_false(String(_request("anthropic")["body"]).contains("responseMimeType"), "or its twin")

	begin("custom follows its own setting in both directions")
	assert_true(String(_request("custom", {"base_url": "https://example.test/v1"})["body"])
		.contains("\"response_format\""), "custom_json_mode defaults to true")
	assert_false(String(_request("custom",
		{"base_url": "https://example.test/v1", "custom_json_mode": false})["body"])
		.contains("\"response_format\""), "and switches off cleanly")

	begin("allow_json_mode: false removes the flag without changing anything else")
	var with := JSON.parse_string(String(_request("deepseek")["body"])) as Dictionary
	var without := JSON.parse_string(String(_request("deepseek", {},
		{"allow_json_mode": false})["body"])) as Dictionary
	assert_true(with.has("response_format"), "on by default")
	assert_false(without.has("response_format"), "off on request")
	with.erase("response_format")
	assert_eq(JSON.stringify(with), JSON.stringify(without), "the rest of the body is identical")

	begin("the explicit json_mode option wins over the provider rule (the 400 re-send)")
	var resent := JSON.parse_string(String(_request("deepseek", {},
		{"json_mode": false})["body"])) as Dictionary
	assert_false(resent.has("response_format"), "the re-shaped request drops it")
	assert_eq(resent.size(), 5, "and keeps every other key")


# ------------------------------------------------------------------ key sets

func _test_body_key_sets() -> void:
	begin("every body is valid JSON with the exact key set R2 documents")
	var expected: Dictionary = {
		"openai_compatible": PackedStringArray(["model", "messages", "temperature", "max_tokens",
			"response_format", "stream"]),
		"anthropic": PackedStringArray(["model", "max_tokens", "temperature", "system",
			"messages"]),
		"gemini": PackedStringArray(["systemInstruction", "contents", "generationConfig"]),
	}
	for key in LLMProviders.keys():
		var parsed: Variant = JSON.parse_string(String(_request(key)["body"]))
		assert_true(parsed is Dictionary, "%s body parses" % key)
		var adapter := LLMProviders.adapter_for(key)
		var wanted: PackedStringArray = expected[adapter]
		assert_eq((parsed as Dictionary).size(), wanted.size(), "%s key count" % key)
		for field in wanted:
			assert_has_key(parsed, field, "%s.%s" % [key, field])

	begin("a minimal invocation is still a complete body")
	var minimal := LLMClient.build_request("deepseek", {"provider": "deepseek", "api_key": KEY},
		"", "")
	var parsed_minimal: Variant = JSON.parse_string(String(minimal["body"]))
	assert_true(parsed_minimal is Dictionary, "parses")
	assert_eq(int((parsed_minimal as Dictionary)["max_tokens"]), 4096, "the default cap")
	assert_eq(String((parsed_minimal as Dictionary)["model"]), "deepseek-chat",
		"the preset default model")
	assert_eq(String(minimal["url"]), "https://api.deepseek.com/v1/chat/completions",
		"the preset default base URL")


func _test_timeout() -> void:
	begin("opts.timeout_sec wins, and the preset default is 45 s")
	assert_eq(int(_request("deepseek")["timeout_sec"]), 45, "default")
	assert_eq(int(_request("deepseek", {}, {"timeout_sec": 12})["timeout_sec"]), 12, "override")
	for key in LLMProviders.keys():
		assert_eq(int(_request(key)["timeout_sec"]), LLMProviders.default_timeout_sec(key),
			"%s uses its preset timeout" % key)

	begin("max_tokens and temperature defaults are R2's")
	assert_eq(int(LLMClient.DEFAULT_MAX_TOKENS), 4096, "4096 tokens")
	assert_close(LLMClient.DEFAULT_TEMPERATURE, 0.4, 0.0001, "0.4 temperature")
	assert_close(LLMClient.REPAIR_TEMPERATURE, 0.2, 0.0001, "the repair retry is colder")
	assert_eq(LLMClient.DEFAULT_RETRIES, 2, "exactly two extra attempts (R7)")
	assert_eq(", ".join(LLMClient.DEFAULT_BACKOFF_SEC), "1.0, 3.0", "1 s then 3 s (R7)")
	assert_eq(LLMClient.DEFAULT_BACKOFF_SEC.size(), 2, "two waits for two extra attempts")
