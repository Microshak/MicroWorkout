extends TestSuite
## PRD-07 R1/R3 — the provider table's request-shaping half and the result vocabulary.
##
## PRD-06's `test_settings_validation.gd` already pins the seven PRD-06 fields (`label`,
## `base_url`, `default_model`, `auth_style`, `adapter`, `editable_base_url`, `docs_url`) and the
## pinned `PRESETS[key].size() == 7`. This suite covers what PRD-07 adds: [LLMProviders.SHAPES],
## `resolve_url()`, `json_mode_ok()`, the auth-header builder, and the closed `error_code`
## vocabulary on [LLMResult] that the ladder's copy table and the retry rules both depend on.
##
## Nothing here touches the network, the scene tree or an autoload: the whole table is static data
## plus pure functions.

const KEY := "sk-test-0000000000"

## R1's table, restated here so a change to the implementation has to be a deliberate change to
## this expectation too.
const EXPECTED: Dictionary = {
	"openai": {
		"adapter": "openai_compatible", "base_url": "https://api.openai.com/v1",
		"default_model": "gpt-4o-mini", "auth_style": "bearer",
		"chat_path": "/chat/completions", "json_mode": true, "system_role": true,
		"max_tokens_key": "max_tokens", "prefix": "sk-",
	},
	"deepseek": {
		"adapter": "openai_compatible", "base_url": "https://api.deepseek.com/v1",
		"default_model": "deepseek-chat", "auth_style": "bearer",
		"chat_path": "/chat/completions", "json_mode": true, "system_role": true,
		"max_tokens_key": "max_tokens", "prefix": "sk-",
	},
	"anthropic": {
		"adapter": "anthropic", "base_url": "https://api.anthropic.com/v1",
		"default_model": "claude-3-5-sonnet-latest", "auth_style": "x_api_key",
		"chat_path": "/messages", "json_mode": false, "system_role": false,
		"max_tokens_key": "max_tokens_required", "prefix": "sk-ant-",
	},
	"gemini": {
		"adapter": "gemini", "base_url": "https://generativelanguage.googleapis.com/v1beta",
		"default_model": "gemini-1.5-flash", "auth_style": "query_key",
		"chat_path": "/models/{model}:generateContent", "json_mode": true, "system_role": false,
		"max_tokens_key": "maxOutputTokens", "prefix": "AIza",
	},
	"openrouter": {
		"adapter": "openai_compatible", "base_url": "https://openrouter.ai/api/v1",
		"default_model": "openai/gpt-4o-mini", "auth_style": "bearer",
		"chat_path": "/chat/completions", "json_mode": true, "system_role": true,
		"max_tokens_key": "max_tokens", "prefix": "sk-or-",
	},
	"groq": {
		"adapter": "openai_compatible", "base_url": "https://api.groq.com/openai/v1",
		"default_model": "llama-3.3-70b-versatile", "auth_style": "bearer",
		"chat_path": "/chat/completions", "json_mode": true, "system_role": true,
		"max_tokens_key": "max_tokens", "prefix": "gsk_",
	},
	"custom": {
		"adapter": "openai_compatible", "base_url": "", "default_model": "",
		"auth_style": "bearer", "chat_path": "/chat/completions", "json_mode": true,
		"system_role": true, "max_tokens_key": "max_tokens", "prefix": "",
	},
}


func _init() -> void:
	suite_name = "llm_providers"


func run() -> void:
	_test_table_shape()
	_test_verbatim_values()
	_test_shapes_per_preset()
	_test_extra_headers()
	_test_resolve_url()
	_test_json_mode_ok()
	_test_auth_styles()
	_test_models_and_timeouts()
	_test_result_vocabulary()
	_test_classification()
	_test_redaction_in_results()
	_test_log_line_shape()


# ------------------------------------------------------------------ R1 table

func _test_table_shape() -> void:
	begin("seven presets, in R1's order")
	assert_eq(", ".join(LLMProviders.keys()), ", ".join(PackedStringArray(EXPECTED.keys())),
		"keys() order is fixed")
	assert_eq(LLMProviders.keys().size(), 7, "seven presets")
	assert_eq(LLMProviders.DEFAULT_KEY, "deepseek", "the wiped-install default")
	assert_has_key(LLMProviders.SHAPES, "custom", "every preset has a shape row")

	begin("SHAPES has exactly R1's seven fields per preset, and no key it does not know")
	for key in LLMProviders.keys():
		var shape := LLMProviders.shape(key)
		assert_eq(shape.size(), LLMProviders.SHAPE_FIELDS.size(), "%s shape field count" % key)
		for field in LLMProviders.SHAPE_FIELDS:
			assert_has_key(shape, field, "%s.%s" % [key, field])
		assert_true(LLMProviders.MAX_TOKENS_KEYS.has(String(shape["max_tokens_key"])),
			"%s max_tokens_key is in the closed set" % key)
		assert_true(shape["extra_headers"] is Dictionary, "%s extra_headers is a dictionary" % key)
		assert_ge(float(shape["default_timeout_sec"]), 45.0,
			"%s timeout must be at least the 45 s the transport assumes" % key)

	begin("merged() is the two tables together, and neither loses a field")
	for key in LLMProviders.keys():
		var merged := LLMProviders.merged(key)
		assert_eq(merged.size(), 14, "%s merges 7 + 7 fields" % key)
		assert_has_key(merged, "label", "%s keeps its PRD-06 label" % key)
		assert_has_key(merged, "chat_path", "%s gains its R1 chat_path" % key)


func _test_verbatim_values() -> void:
	begin("the §8.1 values are verbatim")
	for key in LLMProviders.keys():
		var expected: Dictionary = EXPECTED[key]
		assert_eq(LLMProviders.default_base_url(key), String(expected["base_url"]),
			"%s base_url" % key)
		assert_eq(LLMProviders.default_model(key), String(expected["default_model"]),
			"%s default_model" % key)
		assert_eq(LLMProviders.preset(key)["auth_style"], String(expected["auth_style"]),
			"%s auth_style" % key)
		assert_false(String(LLMProviders.preset(key)["label"]).is_empty(), "%s has a label" % key)


func _test_shapes_per_preset() -> void:
	begin("adapter_for() maps each preset to its adapter")
	for key in LLMProviders.keys():
		assert_eq(LLMProviders.adapter_for(key), String((EXPECTED[key] as Dictionary)["adapter"]),
			"%s adapter" % key)
	assert_true(LLMProviders.ADAPTERS.has(LLMProviders.adapter_for("nope")),
		"an unknown preset degrades to an adapter that exists")

	begin("chat_path, json mode, system role and the token-cap field name are R1's")
	for key in LLMProviders.keys():
		var expected: Dictionary = EXPECTED[key]
		assert_eq(LLMProviders.chat_path_for(key), String(expected["chat_path"]), "%s chat_path" % key)
		assert_eq(LLMProviders.supports_json_mode(key), bool(expected["json_mode"]),
			"%s json mode" % key)
		assert_eq(LLMProviders.supports_system_role(key), bool(expected["system_role"]),
			"%s system role" % key)
		assert_eq(LLMProviders.max_tokens_key_for(key), String(expected["max_tokens_key"]),
			"%s max_tokens_key" % key)
		assert_eq(LLMProviders.key_prefix_hint(key), String(expected["prefix"]),
			"%s key_prefix_hint" % key)
		assert_eq(LLMProviders.default_timeout_sec(key), 45, "%s default timeout" % key)

	begin("only Gemini puts the model in the path, and only it uses a query key")
	assert_true(LLMProviders.chat_path_for("gemini").contains("{model}"), "gemini substitutes model")
	for key in LLMProviders.keys():
		if key != "gemini":
			assert_false(LLMProviders.chat_path_for(key).contains("{model}"),
				"%s has no model placeholder" % key)


func _test_extra_headers() -> void:
	begin("extra headers are exactly R1's")
	assert_eq(LLMProviders.extra_headers_for("anthropic").size(), 1, "anthropic: one header")
	assert_eq(String(LLMProviders.extra_headers_for("anthropic")["anthropic-version"]),
		LLMProviders.ANTHROPIC_VERSION, "anthropic version header")
	assert_eq(LLMProviders.ANTHROPIC_VERSION, "2023-06-01", "and it is the pinned value")

	var openrouter := LLMProviders.extra_headers_for("openrouter")
	assert_eq(openrouter.size(), 2, "openrouter: two headers")
	assert_eq(String(openrouter["HTTP-Referer"]), "https://github.com/microshak/microworkout",
		"openrouter referer")
	assert_eq(String(openrouter["X-Title"]), "MicroWorkout", "openrouter title")

	for key in PackedStringArray(["openai", "deepseek", "groq", "gemini", "custom"]):
		assert_empty(LLMProviders.extra_headers_for(key), "%s adds no headers" % key)

	begin("the returned dictionary is a copy: mutating it cannot corrupt the table")
	var mutated := LLMProviders.extra_headers_for("openrouter")
	mutated["X-Title"] = "tampered"
	assert_eq(String(LLMProviders.extra_headers_for("openrouter")["X-Title"]), "MicroWorkout",
		"the table still holds the original value")


# ------------------------------------------------------------------ resolve_url (R1)

func _test_resolve_url() -> void:
	begin("resolve_url() joins base + chat_path")
	assert_eq(LLMProviders.resolve_url("deepseek", {"api_key": KEY}),
		"https://api.deepseek.com/v1/chat/completions", "deepseek URL is verbatim")
	assert_eq(LLMProviders.resolve_url("openai", {"api_key": KEY}),
		"https://api.openai.com/v1/chat/completions", "openai URL")
	assert_eq(LLMProviders.resolve_url("anthropic", {"api_key": KEY}),
		"https://api.anthropic.com/v1/messages", "anthropic URL")
	assert_eq(LLMProviders.resolve_url("openrouter", {"api_key": KEY}),
		"https://openrouter.ai/api/v1/chat/completions", "openrouter URL")
	assert_eq(LLMProviders.resolve_url("groq", {"api_key": KEY}),
		"https://api.groq.com/openai/v1/chat/completions", "groq URL")

	begin("resolve_url('gemini', …) carries the model and the key")
	var gemini := LLMProviders.resolve_url("gemini", {"api_key": KEY})
	assert_true(gemini.contains("/models/"), "gemini URL names the model resource")
	assert_true(gemini.contains(":generateContent?key="), "gemini URL carries the key")
	assert_eq(gemini, "https://generativelanguage.googleapis.com/v1beta/models/"
		+ "gemini-1.5-flash:generateContent?key=" + KEY, "gemini URL is exact")
	assert_false(gemini.contains("{model}"), "the placeholder was substituted")
	var custom_model := LLMProviders.resolve_url("gemini",
		{"api_key": KEY, "model": "gemini-2.0 flash"})
	assert_true(custom_model.contains("gemini-2.0%20flash"), "the model is percent-encoded")

	begin("the base URL is user-editable where R1 says so, and trimming is safe")
	assert_eq(LLMProviders.resolve_url("custom",
		{"base_url": "http://10.0.2.2:8765/v1/", "api_key": KEY}),
		"http://10.0.2.2:8765/v1/chat/completions", "trailing slash is trimmed")
	assert_eq(LLMProviders.resolve_url("deepseek", {"base_url": "https://proxy.example/v1"}),
		"https://proxy.example/v1/chat/completions", "a custom base URL wins")
	assert_eq(LLMProviders.resolve_url("gemini", {}),
		"https://generativelanguage.googleapis.com/v1beta/models/"
		+ "gemini-1.5-flash:generateContent", "no key means no query parameter")
	assert_eq(LLMProviders.resolve_url("custom", {"custom_auth_none": true}),
		"/chat/completions", "custom with no base URL and no key is only the path")


# ------------------------------------------------------------------ json mode / auth

func _test_json_mode_ok() -> void:
	begin("json_mode_ok() follows R1's json-mode column")
	assert_false(LLMProviders.json_mode_ok("anthropic", {}), "anthropic has no JSON mode")
	for key in PackedStringArray(["openai", "deepseek", "openrouter", "groq"]):
		assert_true(LLMProviders.json_mode_ok(key, {}), "%s supports JSON mode" % key)
	assert_true(LLMProviders.json_mode_ok("gemini", {}), "gemini supports JSON mode")

	begin("custom's JSON mode is its own setting, defaulting to on")
	assert_true(LLMProviders.json_mode_ok("custom", {}), "default is on")
	assert_true(LLMProviders.json_mode_ok("custom", {"custom_json_mode": true}), "explicitly on")
	assert_false(LLMProviders.json_mode_ok("custom", {"custom_json_mode": false}), "explicitly off")
	assert_true(LLMProviders.json_mode_ok("openai", {"custom_json_mode": false}),
		"the custom flag never leaks into another preset")


func _test_auth_styles() -> void:
	begin("effective_auth_style() honours llm.custom_auth_none")
	assert_eq(LLMProviders.effective_auth_style("custom", {}), "bearer", "custom defaults to bearer")
	assert_eq(LLMProviders.effective_auth_style("custom", {"custom_auth_none": true}), "none",
		"custom can be keyless")
	assert_eq(LLMProviders.effective_auth_style("deepseek", {"custom_auth_none": true}), "bearer",
		"the keyless flag is custom-only")
	assert_eq(LLMProviders.effective_auth_style("gemini", {}), "query_key", "gemini uses a query key")
	assert_eq(LLMProviders.effective_auth_style("anthropic", {}), "x_api_key", "anthropic header")

	begin("requires_key() follows the effective style")
	assert_true(LLMProviders.requires_key("deepseek", {}), "deepseek needs a key")
	assert_true(LLMProviders.requires_key("custom", {}), "custom needs a key by default")
	assert_false(LLMProviders.requires_key("custom", {"custom_auth_none": true}),
		"custom + none needs no key")

	begin("auth_headers_for() puts the key in exactly one place per style")
	assert_eq(", ".join(LLMProviders.auth_headers_for("deepseek", {"api_key": KEY})),
		"Authorization: Bearer %s" % KEY, "bearer")
	assert_eq(", ".join(LLMProviders.auth_headers_for("anthropic", {"api_key": KEY})),
		"x-api-key: %s" % KEY, "x-api-key")
	assert_empty(LLMProviders.auth_headers_for("gemini", {"api_key": KEY}),
		"gemini carries the key in the URL, never in a header")
	assert_empty(LLMProviders.auth_headers_for("custom", {"api_key": KEY, "custom_auth_none": true}),
		"a keyless custom server sends no auth header")
	assert_empty(LLMProviders.auth_headers_for("deepseek", {"api_key": ""}),
		"an empty key adds no header")


func _test_models_and_timeouts() -> void:
	begin("model_for() prefers llm.model and falls back to the preset default")
	assert_eq(LLMProviders.model_for("deepseek", {}), "deepseek-chat", "preset default")
	assert_eq(LLMProviders.model_for("deepseek", {"model": "deepseek-reasoner"}), "deepseek-reasoner",
		"the user's model wins")
	assert_eq(LLMProviders.model_for("custom", {"model": "  "}), "", "custom has no default")
	assert_eq(LLMProviders.model_for("openai", {"model": " gpt-4o "}), "gpt-4o", "trimmed")

	begin("base_url_for() trims and falls back")
	assert_eq(LLMProviders.base_url_for("deepseek", {}), "https://api.deepseek.com/v1",
		"the shipped base URL")
	assert_eq(LLMProviders.base_url_for("deepseek", {"base_url": "http://127.0.0.1:8765/v1/"}),
		"http://127.0.0.1:8765/v1", "trimmed")
	assert_eq(LLMProviders.base_url_for("custom", {}), "", "custom has no base URL until it is set")


# ------------------------------------------------------------------ R3 result vocabulary

func _test_result_vocabulary() -> void:
	begin("the error vocabulary is the closed R3 set")
	var expected: PackedStringArray = [
		"", "no_key", "no_network", "tls", "timeout", "auth", "forbidden", "bad_path",
		"rate_limited", "server", "bad_response", "truncated", "blocked", "cancelled", "busy",
	]
	assert_eq(", ".join(LLMResult.ERROR_CODES), ", ".join(expected), "exactly R3's fifteen codes")
	for code in expected:
		assert_true(LLMResult.is_known_code(code), "'%s' is known" % code)
	assert_false(LLMResult.is_known_code("unknown"), "an invented code is not known")

	begin("the retry set is transport-only, and excludes every HTTP response")
	assert_eq(", ".join(LLMResult.TRANSPORT_FAILURES), "no_network, tls, timeout",
		"R6 step 4's three transport failures")
	assert_true(LLMResult.is_transport_failure("no_network"), "connection failures retry")
	assert_true(LLMResult.is_transport_failure("tls"), "TLS failures retry")
	assert_true(LLMResult.is_transport_failure("timeout"), "a hanging provider retries (R7's 3x45 s)")
	for code in PackedStringArray(["auth", "forbidden", "bad_path", "rate_limited", "server",
			"bad_response", "truncated", "blocked", "cancelled", "busy"]):
		assert_false(LLMResult.is_transport_failure(code), "'%s' is never retried" % code)

	begin("key failures are the four that send the user to Settings")
	assert_eq(", ".join(LLMResult.KEY_FAILURES), "auth, forbidden, no_key, bad_path",
		"R9's Fix in Settings set")
	for code in PackedStringArray(["auth", "forbidden", "no_key", "bad_path"]):
		assert_true(LLMResult.is_key_failure(code), "'%s' is a key failure" % code)
	for code in PackedStringArray(["server", "rate_limited", "no_network", "timeout"]):
		assert_false(LLMResult.is_key_failure(code), "'%s' is not a key failure" % code)

	begin("a success result carries the provider, the model and the text")
	var ok := LLMResult.success("deepseek", "deepseek-chat", "openai_compatible", "{}", 120, 1, {})
	assert_true(ok.ok, "ok")
	assert_eq(ok.text, "{}", "text")
	assert_eq(ok.error_code, "", "no error code")
	assert_eq(ok.attempts, 1, "attempts")
	assert_eq(ok.latency_ms, 120, "latency")
	assert_eq(ok.adapter, "openai_compatible", "adapter")
	assert_eq(ok.http_status, 200, "status")
	assert_empty(ok.usage, "no usage reported")

	begin("a failure result scrubs its detail at construction")
	var bad := LLMResult.failure("auth", "deepseek", "deepseek-chat", "openai_compatible", 401, 5, 1,
		'{"error":{"message":"bad key ' + KEY + '"}}', KEY)
	assert_false(bad.ok, "not ok")
	assert_eq(bad.error_code, "auth", "code")
	assert_eq(bad.http_status, 401, "status")
	assert_false(bad.redacted_detail.contains(KEY), "the key is gone")
	assert_true(bad.redacted_detail.contains(Redact.PLACEHOLDER), "[REDACTED] took its place")

	begin("with_attempts() changes only the counter and the latency")
	var updated := bad.with_attempts(3, 99)
	assert_eq(updated.attempts, 3, "attempts replaced")
	assert_eq(updated.latency_ms, 99, "latency replaced")
	assert_eq(updated.error_code, "auth", "code kept")
	assert_eq(updated.redacted_detail, bad.redacted_detail, "detail kept")


func _test_classification() -> void:
	begin("classify() maps HTTP status to the R3 vocabulary")
	var cases: Dictionary = {
		400: "bad_response", 401: "auth", 402: "bad_response", 403: "forbidden", 404: "bad_path",
		408: "bad_response", 418: "bad_response", 429: "rate_limited", 500: "server",
		502: "server", 503: "server", 504: "server", 599: "server", 600: "bad_response",
	}
	var codes: Array = cases.keys()
	codes.sort()
	for status in codes:
		assert_eq(LLMResult.classify(int(status)), String(cases[status]),
			"HTTP %d -> %s" % [int(status), String(cases[status])])
		assert_eq(LLMProviders.classify_status(int(status)), LLMResult.classify(int(status)),
			"PRD-06 and PRD-07 agree about HTTP %d" % int(status))

	begin("transport_code() maps HTTPRequest.Result to the same vocabulary")
	var transports: Dictionary = {
		HTTPRequest.RESULT_SUCCESS: "no_network",
		HTTPRequest.RESULT_CANT_RESOLVE: "no_network",
		HTTPRequest.RESULT_CANT_CONNECT: "no_network",
		HTTPRequest.RESULT_CONNECTION_ERROR: "no_network",
		HTTPRequest.RESULT_NO_RESPONSE: "no_network",
		HTTPRequest.RESULT_TIMEOUT: "timeout",
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "tls",
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: "bad_response",
	}
	var results: Array = transports.keys()
	results.sort()
	for code in results:
		assert_eq(LLMResult.transport_code(int(code)), String(transports[code]),
			"HTTPRequest.Result %d" % int(code))
		assert_true(LLMResult.is_known_code(LLMResult.transport_code(int(code))),
			"every transport code is in the closed set")

	begin("transport_detail() is human text and never a URL")
	for code in results:
		var detail := LLMResult.transport_detail(int(code))
		assert_false(detail.is_empty(), "Result %d has a description" % int(code))
		assert_false(detail.contains("http"), "no URL in '%s'" % detail)


func _test_redaction_in_results() -> void:
	begin("redacted_detail is capped at 300 characters")
	# A realistic multi-line provider error: long enough to need clipping, and free of the long
	# unbroken token runs `Redact` deliberately replaces wholesale.
	var long_body := "upstream said: something went wrong here\n".repeat(60)
	var capped := LLMResult.failure("server", "deepseek", "deepseek-chat", "openai_compatible",
		500, 5, 1, long_body, KEY)
	assert_eq(capped.redacted_detail.length(), Redact.SAFE_ERROR_MAX, "clipped")
	assert_eq(Redact.SAFE_ERROR_MAX, 300, "R3's cap is 300")

	begin("a key-shaped body is scrubbed even without being told the key")
	var shaped := LLMResult.failure("auth", "openai", "gpt-4o-mini", "openai_compatible", 401, 5, 1,
		"Authorization: Bearer sk-abcdefghijklmnop failed", "")
	assert_false(shaped.redacted_detail.contains("sk-abcdefghijklmnop"), "bearer token removed")
	assert_true(shaped.redacted_detail.contains(Redact.PLACEHOLDER), "replaced")

	begin("a Gemini key in a URL is scrubbed from any detail")
	var url_detail := Redact.safe_error(
		"GET https://generativelanguage.googleapis.com/v1beta/models/x:generateContent?key=" + KEY
		+ " returned 400", KEY)
	assert_false(url_detail.contains(KEY), "the query key is gone")
	assert_true(url_detail.contains("key=" + Redact.PLACEHOLDER), "the parameter name stays")

	begin("to_dictionary() is safe to log whole")
	var result := LLMResult.failure("server", "deepseek", "deepseek-chat", "openai_compatible",
		500, 5, 2, "upstream failure: " + KEY, KEY)
	var dumped := JSON.stringify(result.to_dictionary())
	assert_false(dumped.contains(KEY), "no key in the dump")
	assert_true(dumped.contains("redacted_detail"), "the field is still named")
	assert_eq(int(result.to_dictionary()["text_length"]), 0, "text length, not text")


func _test_log_line_shape() -> void:
	begin("the per-request log line is R7's format, with no URL and no key")
	var line := LLMResult.log_line("deepseek", "openai_compatible", 2, 3, 0, "no_network", 45012,
		"f27b567cdb5b69dc9b268141df824516029818f089ca87412c812c70dfd92b70", "mw-plan-prompt/1")
	assert_eq(line, "[llm] provider=deepseek adapter=openai_compatible attempt=2/3 status=0 "
		+ "code=no_network ms=45012 catalog=f27b567c prompt=mw-plan-prompt/1", "verbatim shape")
	assert_false(line.contains("http"), "no URL")
	assert_false(line.contains(KEY), "no key")
	assert_false(line.contains("Authorization"), "no headers")
	assert_false(line.contains("key="), "not even a key parameter")

	begin("an empty code renders as ok, so a success line is unambiguous")
	var ok_line := LLMResult.log_line("openai", "openai_compatible", 1, 3, 200, "", 900, "", "")
	assert_true(ok_line.contains("code=ok"), "code=ok")
	assert_true(ok_line.contains("catalog= prompt="), "an empty digest is visible, not invented")
