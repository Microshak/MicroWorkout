extends TestSuite
## PRD-06 R5/R6/R7/R9/R12 — the provider table, the per-field rules, and the typed-RESET guard.
##
## Table-driven wherever the PRD gives a table, so adding a provider or a rule is one row.
## Autoload-free: everything under test is a pure static.

const SETTINGS_SCRIPT := "res://scripts/ui/settings_tab.gd"
const GOOD_KEY := "sk-test-0000000000"
const OPENAI_KEY := "openai"
const CUSTOM_KEY := "custom"

## A base URL and model that satisfy `custom`, which ships neither (R7).
const CUSTOM_URL := "https://api.example.com/v1"
const CUSTOM_MODEL := "my-model"


func _init() -> void:
	suite_name = "settings_validation"


func run() -> void:
	_test_provider_table()
	_test_preset_defaults_validate_clean()
	_test_base_url_rules()
	_test_model_rules()
	_test_api_key_rules()
	_test_scalar_rules()
	_test_normalize_is_idempotent()
	_test_validate_setting_paths()
	_test_connection_copy()
	_test_reset_guard()


# ------------------------------------------------------------------ R5/R6: the table

func _test_provider_table() -> void:
	begin("every §8.1 preset is present, in order")
	var expected: PackedStringArray = [
		"openai", "deepseek", "anthropic", "gemini", "openrouter", "groq", "custom",
	]
	assert_eq(", ".join(LLMProviders.keys()), ", ".join(expected), "keys() order is fixed")
	assert_eq(LLMProviders.keys().size(), 7, "seven presets")
	assert_eq(LLMProviders.DEFAULT_KEY, "deepseek", "the wiped-install default")

	begin("each preset carries exactly R5's seven keys")
	var required: PackedStringArray = [
		"label", "base_url", "default_model", "auth_style", "adapter", "editable_base_url",
		"docs_url",
	]
	for key in LLMProviders.keys():
		var entry := LLMProviders.preset(key)
		for field in required:
			assert_has_key(entry, field, "%s.%s" % [key, field])
		assert_eq(entry.size(), required.size(), "%s has no extra keys" % key)
		assert_true(LLMProviders.AUTH_STYLES.has(String(entry["auth_style"])),
			"%s auth_style is in the closed set" % key)
		assert_true(LLMProviders.ADAPTERS.has(String(entry["adapter"])),
			"%s adapter is in the closed set" % key)
		assert_false(String(entry["label"]).is_empty(), "%s has a label" % key)

	begin("the §8.1 values are verbatim")
	assert_eq(LLMProviders.default_base_url("openai"), "https://api.openai.com/v1", "openai url")
	assert_eq(LLMProviders.default_model("openai"), "gpt-4o-mini", "openai model")
	assert_eq(LLMProviders.default_base_url("deepseek"), "https://api.deepseek.com/v1", "deepseek")
	assert_eq(LLMProviders.default_model("deepseek"), "deepseek-chat", "deepseek model")
	assert_eq(LLMProviders.default_base_url("anthropic"), "https://api.anthropic.com/v1", "anthropic")
	assert_eq(LLMProviders.default_model("anthropic"), "claude-3-5-sonnet-latest", "anthropic model")
	assert_eq(LLMProviders.adapter_for("anthropic"), "anthropic", "anthropic adapter")
	assert_eq(LLMProviders.preset("anthropic")["auth_style"], "x_api_key", "anthropic auth")
	assert_eq(LLMProviders.default_base_url("gemini"),
		"https://generativelanguage.googleapis.com/v1beta", "gemini url")
	assert_eq(LLMProviders.default_model("gemini"), "gemini-1.5-flash", "gemini model")
	assert_eq(LLMProviders.preset("gemini")["auth_style"], "query_key", "gemini auth")
	assert_eq(LLMProviders.default_base_url("openrouter"), "https://openrouter.ai/api/v1", "openrouter")
	assert_eq(LLMProviders.default_model("openrouter"), "openai/gpt-4o-mini", "openrouter model")
	assert_eq(LLMProviders.default_base_url("groq"), "https://api.groq.com/openai/v1", "groq url")
	assert_eq(LLMProviders.default_model("groq"), "llama-3.3-70b-versatile", "groq model")
	assert_eq(LLMProviders.default_base_url(CUSTOM_KEY), "", "custom ships no base URL")
	assert_eq(LLMProviders.default_model(CUSTOM_KEY), "", "custom ships no model")

	begin("R6's base-URL editability rules")
	for key in ["openai", "deepseek", "openrouter", "groq", CUSTOM_KEY]:
		assert_true(LLMProviders.base_url_editable(key), "%s URL is editable" % key)
	for key in ["anthropic", "gemini"]:
		assert_false(LLMProviders.base_url_editable(key), "%s URL is fixed" % key)

	begin("unknown providers degrade instead of crashing")
	var fallback := LLMProviders.preset("nope")
	assert_eq(String(fallback["label"]), LLMProviders.preset(CUSTOM_KEY)["label"],
		"an unknown key returns the custom entry")
	assert_eq(LLMProviders.label_for("nope"), LLMProviders.label_for(CUSTOM_KEY), "label_for too")
	assert_false(LLMProviders.has("nope"), "has() is strict")
	assert_true(LLMProviders.require_base_url(CUSTOM_KEY), "custom must supply a base URL")
	assert_false(LLMProviders.require_base_url(OPENAI_KEY), "openai does not")

	begin("auth styles, including the custom override")
	assert_eq(LLMProviders.effective_auth_style(OPENAI_KEY, {}), "bearer", "openai is bearer")
	assert_eq(LLMProviders.effective_auth_style(CUSTOM_KEY, {}), "bearer", "custom defaults to bearer")
	assert_eq(LLMProviders.effective_auth_style(CUSTOM_KEY, {"custom_auth_none": true}), "none",
		"custom + custom_auth_none needs no key")
	assert_false(LLMProviders.requires_key(CUSTOM_KEY, {"custom_auth_none": true}),
		"and therefore does not require one")
	assert_true(LLMProviders.requires_key(CUSTOM_KEY, {}), "but does otherwise")

	begin("host_of feeds the R9 copy")
	assert_eq(LLMProviders.host_of("https://api.deepseek.com/v1"), "api.deepseek.com", "host")
	assert_eq(LLMProviders.host_of("http://10.0.2.2:8765/v1"), "10.0.2.2", "host with port")
	assert_eq(LLMProviders.host_of("http://localhost:8765"), "localhost", "bare host with port")
	assert_eq(LLMProviders.host_of(""), "", "empty url has no host")


func _test_preset_defaults_validate_clean() -> void:
	begin("every preset's own defaults validate clean (R14)")
	for key in LLMProviders.keys():
		var cfg := _config_for(key)
		var report := StoreSchema.validate_llm(cfg)
		assert_true(bool(report["ok"]), "%s defaults validate: %s" % [key, str(report["errors"])])
		var errors: Dictionary = report["errors"]
		assert_false(errors.has("provider"), "%s provider is accepted" % key)
		assert_false(errors.has("base_url"), "%s base_url is accepted" % key)
		assert_false(errors.has("model"), "%s model is accepted" % key)
		assert_false(errors.has("api_key"), "%s api_key is accepted" % key)

	begin("custom with no auth needs no key but does need a URL")
	var no_auth := _config_for(CUSTOM_KEY)
	no_auth["api_key"] = ""
	no_auth["custom_auth_none"] = true
	assert_true(bool(StoreSchema.validate_llm(no_auth)["ok"]), "custom + auth none is ok")
	no_auth["base_url"] = ""
	var missing := StoreSchema.validate_llm(no_auth)
	assert_false(bool(missing["ok"]), "custom without a base URL is not ok")
	assert_eq(String(missing["errors"].get("base_url", "")), StoreSchema.BASE_URL_MESSAGE,
		"R7's base-URL message")

	begin("an unknown provider is rejected with R7's message")
	var bogus := _config_for(OPENAI_KEY)
	bogus["provider"] = "not_a_provider"
	var report := StoreSchema.validate_llm(bogus)
	assert_false(bool(report["ok"]), "unknown provider fails")
	assert_eq(String(report["errors"].get("provider", "")), StoreSchema.PROVIDER_MESSAGE,
		"Choose a provider.")
	assert_eq(String(report["errors"].get("provider", "")), "Choose a provider.", "verbatim")


# ------------------------------------------------------------------ R7: base_url

func _test_base_url_rules() -> void:
	begin("https is always fine")
	for url in ["https://api.example.com/v1", "https://api.example.com",
			"https://api.example.com/a/b", "https://api.example.com:8443/v1"]:
		assert_eq(StoreSchema.validate_base_url(url), "", "accepted: %s" % url)

	begin("cleartext http is localhost-only (R7, R14)")
	assert_eq(StoreSchema.validate_base_url("http://10.0.2.2:8765/v1"), "",
		"the emulator alias is allowed")
	assert_eq(StoreSchema.validate_base_url("http://localhost:8765/v1"), "", "localhost is allowed")
	assert_eq(StoreSchema.validate_base_url("http://127.0.0.1:8765/v1"), "", "loopback is allowed")
	assert_eq(StoreSchema.validate_base_url("http://api.example.com/v1"), StoreSchema.BASE_URL_MESSAGE,
		"a remote cleartext host is not")
	assert_eq(StoreSchema.validate_base_url("http://10.0.2.3:8765/v1"), StoreSchema.BASE_URL_MESSAGE,
		"nor a near-miss of the emulator alias")

	begin("the URL must be complete and query-free")
	assert_eq(StoreSchema.validate_base_url(""), StoreSchema.BASE_URL_MESSAGE, "empty")
	assert_eq(StoreSchema.validate_base_url("api.example.com/v1"), StoreSchema.BASE_URL_MESSAGE,
		"no scheme")
	assert_eq(StoreSchema.validate_base_url("ftp://api.example.com/v1"), StoreSchema.BASE_URL_MESSAGE,
		"wrong scheme")
	assert_eq(StoreSchema.validate_base_url("https://api.example.com/v1?x=1"),
		StoreSchema.BASE_URL_MESSAGE, "query string")
	assert_eq(StoreSchema.validate_base_url("https://api.example.com/v1#frag"),
		StoreSchema.BASE_URL_MESSAGE, "fragment")
	assert_eq(StoreSchema.validate_base_url("https:///v1"), StoreSchema.BASE_URL_MESSAGE, "no host")
	assert_eq(StoreSchema.validate_base_url("https://api example.com/v1"),
		StoreSchema.BASE_URL_MESSAGE, "space in the host")
	assert_eq(StoreSchema.BASE_URL_MESSAGE,
		"Enter a full URL starting with https:// (http:// is allowed only for localhost).",
		"R7's message is verbatim")

	begin("a trailing slash is normalized away, duplicates collapse")
	assert_eq(StoreSchema.normalize_base_url("https://api.example.com/v1/"),
		"https://api.example.com/v1", "trailing slash")
	assert_eq(StoreSchema.normalize_base_url("  https://api.example.com//v1//  "),
		"https://api.example.com/v1", "duplicate slashes and padding")
	assert_eq(StoreSchema.normalize_base_url("https://api.example.com/"), "https://api.example.com",
		"bare host")
	assert_eq(StoreSchema.normalize_base_url(""), "", "empty stays empty")
	assert_eq(StoreSchema.validate_base_url("https://api.example.com//v1//"), "",
		"and the normalized form validates")
	var cfg := _config_for(OPENAI_KEY)
	cfg["base_url"] = "https://api.example.com//v1/"
	assert_eq(String(StoreSchema.validate_llm(cfg)["normalized"]["base_url"]),
		"https://api.example.com/v1", "normalized is what gets stored")


# ------------------------------------------------------------------ R7: model

func _test_model_rules() -> void:
	begin("model names (R7)")
	assert_eq(StoreSchema.validate_model("gpt-4o-mini"), "", "dashes and digits")
	assert_eq(StoreSchema.validate_model("openai/gpt-4o-mini"), "", "openrouter's vendor slash")
	assert_eq(StoreSchema.validate_model("claude-3-5-sonnet-latest"), "", "anthropic")
	assert_eq(StoreSchema.validate_model("models/gemini-1.5-flash:generateContent"), "",
		"colons and slashes")
	assert_eq(StoreSchema.validate_model("deepseek.chat-v2_1"), "", "dot and underscore")
	assert_eq(StoreSchema.validate_model(""), StoreSchema.MODEL_MESSAGE, "empty")
	assert_eq(StoreSchema.validate_model("   "), StoreSchema.MODEL_MESSAGE, "blank")
	assert_eq(StoreSchema.validate_model("gpt 4"), StoreSchema.MODEL_MESSAGE, "space")
	assert_eq(StoreSchema.validate_model("gpt-4o!"), StoreSchema.MODEL_MESSAGE, "punctuation")
	assert_eq(StoreSchema.validate_model("a".repeat(128)), "", "128 chars is the limit")
	assert_eq(StoreSchema.validate_model("a".repeat(129)), StoreSchema.MODEL_MESSAGE, "129 is too long")
	assert_eq(StoreSchema.MODEL_MESSAGE, "Model names may only contain letters, numbers, and . _ : / -",
		"R7's message is verbatim")


# ------------------------------------------------------------------ R7: api_key

func _test_api_key_rules() -> void:
	begin("an empty key is required unless the provider needs none")
	for key in LLMProviders.keys():
		var cfg := _config_for(key)
		cfg["api_key"] = ""
		var message := StoreSchema.validate_api_key("", key, cfg)
		if key == CUSTOM_KEY:
			assert_eq(message, "Paste your %s API key." % LLMProviders.label_for(CUSTOM_KEY),
				"custom with a bearer token still needs a key")
			var no_auth := _config_for(CUSTOM_KEY)
			no_auth["custom_auth_none"] = true
			assert_eq(StoreSchema.validate_api_key("", CUSTOM_KEY, no_auth), "",
				"custom + auth none may be empty")
		else:
			assert_eq(message, "Paste your %s API key." % LLMProviders.label_for(key),
				"%s requires a key" % key)
	assert_eq(StoreSchema.validate_api_key("", OPENAI_KEY, {}), "Paste your OpenAI API key.",
		"the message names the provider")

	begin("length and character rules (R7)")
	assert_eq(StoreSchema.validate_api_key(GOOD_KEY, OPENAI_KEY), "", "a normal key")
	assert_eq(StoreSchema.validate_api_key("abcdefg", OPENAI_KEY), StoreSchema.KEY_TOO_SHORT_MESSAGE,
		"7 characters is too short")
	assert_eq(StoreSchema.validate_api_key("sk-12345678", OPENAI_KEY), "", "8 characters is enough")
	assert_eq(StoreSchema.validate_api_key("sk-abc def123", OPENAI_KEY),
		StoreSchema.KEY_WHITESPACE_MESSAGE, "an embedded space")
	assert_eq(StoreSchema.validate_api_key("sk-abc\tdef123", OPENAI_KEY),
		StoreSchema.KEY_WHITESPACE_MESSAGE, "an embedded tab")
	assert_eq(StoreSchema.validate_api_key("sk-abc\ndef123", OPENAI_KEY),
		StoreSchema.KEY_WHITESPACE_MESSAGE, "an embedded newline")
	assert_eq(StoreSchema.validate_api_key("sk-abc\"def123", OPENAI_KEY),
		StoreSchema.KEY_WHITESPACE_MESSAGE, "an embedded quote")
	assert_eq(StoreSchema.validate_api_key("a".repeat(513), OPENAI_KEY),
		StoreSchema.KEY_TOO_LONG_MESSAGE % 512, "513 characters is too long")
	assert_eq(StoreSchema.validate_api_key("a".repeat(512), OPENAI_KEY), "", "512 is the limit")
	assert_eq(StoreSchema.KEY_TOO_SHORT_MESSAGE, "That key looks too short — paste the whole key.",
		"R7's message is verbatim")
	assert_eq(StoreSchema.KEY_WHITESPACE_MESSAGE,
		"That key contains spaces or line breaks. Paste it again.", "R7's message is verbatim")

	begin("surrounding whitespace is trimmed, not rejected")
	assert_eq(StoreSchema.validate_api_key("  %s  " % GOOD_KEY, OPENAI_KEY), "",
		"a pasted key with padding is fine")
	var cfg := _config_for(OPENAI_KEY)
	cfg["api_key"] = "  %s\n" % GOOD_KEY
	assert_eq(String(StoreSchema.validate_llm(cfg)["normalized"]["api_key"]), GOOD_KEY,
		"normalize trims it")


# ------------------------------------------------------------------ R7: scalars

func _test_scalar_rules() -> void:
	begin("weekly_goal_days is 1..7 (R7)")
	assert_eq(StoreSchema.validate_weekly_goal_days(0), StoreSchema.WEEKLY_GOAL_MESSAGE, "0 rejected")
	assert_eq(StoreSchema.validate_weekly_goal_days(8), StoreSchema.WEEKLY_GOAL_MESSAGE, "8 rejected")
	assert_eq(StoreSchema.validate_weekly_goal_days(-3), StoreSchema.WEEKLY_GOAL_MESSAGE,
		"negative rejected")
	assert_eq(StoreSchema.validate_weekly_goal_days(1), "", "1 accepted")
	assert_eq(StoreSchema.validate_weekly_goal_days(7), "", "7 accepted")
	assert_eq(StoreSchema.validate_setting("weekly_goal_days", 4), "", "the default is valid")
	assert_eq(StoreSchema.validate_setting("weekly_goal_days", 0), "Pick 1 to 7 days.",
		"R7's message is verbatim")

	begin("rest_timer.default_seconds is 15..300 in 15 s steps (R7)")
	assert_eq(StoreSchema.validate_rest_seconds(100), StoreSchema.REST_MESSAGE,
		"100 is not a multiple of 15")
	assert_eq(StoreSchema.validate_rest_seconds(0), StoreSchema.REST_MESSAGE, "below the range")
	assert_eq(StoreSchema.validate_rest_seconds(45), "", "45 is a step")
	assert_eq(StoreSchema.validate_rest_seconds(300), "", "the top of the range")
	assert_eq(StoreSchema.validate_rest_seconds(315), StoreSchema.REST_MESSAGE, "above the range")
	assert_eq(StoreSchema.validate_setting("rest_timer.default_seconds", 100),
		"Rest must be 15–300 seconds in 15-second steps.", "R7's message is verbatim")

	begin("units and theme (R7)")
	assert_eq(StoreSchema.validate_units(Units.LB), "", "lb is valid")
	assert_eq(StoreSchema.validate_units(Units.KG), "", "kg is valid")
	assert_eq(StoreSchema.validate_units("stone"), "Pick lb or kg.", "R7's message is verbatim")
	assert_eq(StoreSchema.validate_setting("units", "stone"), "Pick lb or kg.", "via the path")
	assert_eq(StoreSchema.validate_theme("dark"), "", "dark is valid")
	assert_eq(StoreSchema.validate_theme("light"), "", "light is valid")
	assert_eq(StoreSchema.validate_theme("blue"), "Pick a theme.", "R7's message is verbatim")
	assert_eq(StoreSchema.validate_setting("theme", "blue"), "Pick a theme.", "via the path")

	begin("booleans and text scale")
	assert_eq(StoreSchema.validate_setting("rest_timer.haptic", true), "", "a bool is fine")
	assert_eq(StoreSchema.validate_setting("rest_timer.haptic", "yes"), StoreSchema.BOOL_MESSAGE,
		"a string is not")
	assert_eq(StoreSchema.validate_setting("ui.reduce_motion", false), "", "reduce_motion bool")
	assert_eq(StoreSchema.validate_setting("ui.text_scale", 1.15), "", "a scaled text size")
	assert_eq(StoreSchema.validate_setting("ui.text_scale", 1.2), StoreSchema.TEXT_SCALE_MESSAGE,
		"an off-scale text size")
	assert_eq(StoreSchema.validate_setting("ui.last_tab", 3), "", "tab 3")
	assert_eq(StoreSchema.validate_setting("ui.last_tab", 4), StoreSchema.TAB_MESSAGE, "tab 4")
	assert_eq(StoreSchema.validate_setting("not.a.key", "whatever"), "",
		"an unknown path defers to the store")

	begin("defaults come from one table (appendix R24)")
	assert_eq(StoreSchema.default_settings().size(), Migrations.Schema.default_settings().size(),
		"the same key count as Migrations.Schema")
	assert_eq(String(StoreSchema.default_llm()["provider"]), "deepseek", "default provider")
	assert_eq(String(StoreSchema.default_llm()["base_url"]), "https://api.deepseek.com/v1",
		"default base URL")
	assert_eq(String(StoreSchema.default_llm()["model"]), "deepseek-chat", "default model")
	assert_eq(String(StoreSchema.default_llm()["api_key"]), "", "default key is empty")

	begin("connection_request shapes match R9")
	var openai_request := LLMProviders.connection_request(OPENAI_KEY, _config_for(OPENAI_KEY))
	assert_true(String(openai_request["url"]).ends_with("/chat/completions"), "openai path")
	var headers: PackedStringArray = openai_request["headers"]
	assert_true(", ".join(headers).contains("Authorization: Bearer %s" % GOOD_KEY),
		"openai carries a bearer header")
	var anthropic_request := LLMProviders.connection_request("anthropic", _config_for("anthropic"))
	assert_true(String(anthropic_request["url"]).ends_with("/messages"), "anthropic path")
	assert_true(", ".join(anthropic_request["headers"]).contains("x-api-key"),
		"anthropic uses x-api-key")
	assert_true(", ".join(anthropic_request["headers"]).contains("2023-06-01"),
		"and the version header")
	var gemini_request := LLMProviders.connection_request("gemini", _config_for("gemini"))
	assert_true(String(gemini_request["url"]).contains("/models/"), "gemini path has /models/")
	assert_true(String(gemini_request["url"]).contains(":generateContent?key="), "gemini uses ?key=")
	assert_eq(int(gemini_request["timeout_sec"]), 20, "R9's 20 s ceiling")


func _test_normalize_is_idempotent() -> void:
	begin("normalize_llm is idempotent and coerces types (R7/R14)")
	var messy := {
		"provider": "  deepseek  ",
		"base_url": "  https://api.deepseek.com//v1/  ",
		"model": " deepseek-chat ",
		"api_key": "  %s  " % GOOD_KEY,
		"temperature": "0.7",
		"timeout_sec": "60",
		"custom_auth_none": 0,
		"custom_json_mode": 1,
		"configured": 0,
	}
	var once := StoreSchema.normalize_llm(messy)
	var twice := StoreSchema.normalize_llm(once)
	assert_eq(str(once), str(twice), "normalize(normalize(x)) == normalize(x)")
	assert_eq(String(once["provider"]), "deepseek", "provider trimmed")
	assert_eq(String(once["base_url"]), "https://api.deepseek.com/v1", "URL normalized")
	assert_eq(String(once["model"]), "deepseek-chat", "model trimmed")
	assert_eq(String(once["api_key"]), GOOD_KEY, "key trimmed")
	assert_close(float(once["temperature"]), 0.7, 1e-9, "temperature coerced")
	assert_eq(int(once["timeout_sec"]), 60, "timeout coerced")
	assert_false(bool(once["custom_auth_none"]), "0 coerces to false")
	assert_true(bool(once["custom_json_mode"]), "1 coerces to true")

	begin("normalize fills every appendix §5.1 llm key")
	for field in Migrations.Schema.LLM_FIELDS:
		assert_has_key(once, field, "normalized carries %s" % field)
	assert_eq(once.size(), Migrations.Schema.LLM_FIELDS.size(), "and nothing else")
	assert_eq(StoreSchema.normalize_llm({}).size(), Migrations.Schema.LLM_FIELDS.size(),
		"an empty config normalizes to the full default block")
	assert_eq(String(StoreSchema.normalize_llm({})["provider"]), "deepseek", "empty → default")

	begin("normalize preserves an invalid provider for validation to reject")
	assert_eq(String(StoreSchema.normalize_llm({"provider": "nope"})["provider"]), "nope",
		"normalization is not validation")


func _test_validate_setting_paths() -> void:
	begin("validate_setting maps a path to R7's message")
	assert_eq(StoreSchema.validate_setting("units", "kg"), "", "units ok")
	assert_eq(StoreSchema.validate_setting("llm.provider", OPENAI_KEY), "", "provider ok")
	assert_eq(StoreSchema.validate_setting("llm.provider", "nope"), "Choose a provider.", "provider bad")
	assert_eq(StoreSchema.validate_setting("llm.base_url", "https://api.example.com/v1"), "",
		"url ok")
	assert_eq(StoreSchema.validate_setting("llm.base_url", "http://api.example.com/v1"),
		StoreSchema.BASE_URL_MESSAGE, "url bad")
	assert_eq(StoreSchema.validate_setting("llm.model", "gpt 4"), StoreSchema.MODEL_MESSAGE, "model bad")
	assert_eq(StoreSchema.validate_setting("llm.api_key", GOOD_KEY,
		{"provider": OPENAI_KEY}), "", "key ok with context")
	assert_eq(StoreSchema.validate_setting("llm.api_key", "", {"provider": OPENAI_KEY}),
		"Paste your OpenAI API key.", "key required with context")
	assert_eq(StoreSchema.validate_setting("llm.api_key", "",
		{"provider": CUSTOM_KEY, "custom_auth_none": true}), "",
		"custom with no auth needs no key")
	assert_eq(StoreSchema.validate_setting("llm.temperature", 1.5), "", "temperature in range")
	assert_eq(StoreSchema.validate_setting("llm.temperature", 3.0),
		"Temperature is 0.0 to 2.0.", "temperature out of range")
	assert_eq(StoreSchema.validate_setting("llm.timeout_sec", 45), "", "timeout in range")
	assert_eq(StoreSchema.validate_setting("llm.timeout_sec", 500),
		"Timeout is 5 to 120 seconds.", "timeout out of range")


# ------------------------------------------------------------------ R9: the copy table

func _test_connection_copy() -> void:
	begin("R9's copy table is verbatim")
	var label := LLMProviders.label_for(OPENAI_KEY)
	var host := "api.openai.com"
	var expected := {
		"": "Connected to %s. The key works." % label,
		"no_key": "Paste your %s API key first." % label,
		"no_network": "Couldn't reach %s. Check the base URL and your internet connection." % host,
		"tls": "Couldn't establish a secure connection to %s. Check the base URL." % host,
		"auth": ("The key was rejected by %s. Check that you pasted the whole key and that it "
			+ "belongs to this provider.") % label,
		"forbidden": "%s refused this request (403). The key may lack access to this model." % label,
		"bad_path": ("Reached %s, but the API path wasn't found. Check the base URL — it usually "
			+ "ends in /v1.") % host,
		"rate_limited": "%s is rate-limiting this key. The key looks fine; try again in a minute."
			% label,
		"server": ("%s had a server problem (HTTP 500). MicroWorkout still works — it will use "
			+ "the built-in generator.") % label,
		"timeout": "%s didn't answer within 20 seconds. Your key may still be fine — try again."
			% label,
		"bad_response": "Reached %s, but its reply couldn't be read. Check the model name." % label,
		"cancelled": "Test cancelled.",
	}
	for code in expected:
		var status := 500 if code == "server" else 0
		assert_eq(LLMProviders.message_for(code, OPENAI_KEY, "https://api.openai.com/v1", status),
			String(expected[code]), "message for '%s'" % code)

	begin("status classification and key_rejected")
	assert_eq(LLMProviders.classify_status(401), "auth", "401")
	assert_eq(LLMProviders.classify_status(403), "forbidden", "403")
	assert_eq(LLMProviders.classify_status(404), "bad_path", "404")
	assert_eq(LLMProviders.classify_status(429), "rate_limited", "429")
	assert_eq(LLMProviders.classify_status(500), "server", "500")
	assert_eq(LLMProviders.classify_status(503), "server", "503")
	assert_eq(LLMProviders.classify_status(400), "bad_response", "400")
	assert_eq(LLMProviders.classify_status(200), "bad_response", "an unparsable 200")
	for code in ["auth", "forbidden"]:
		assert_true(LLMProviders.key_rejected_for(code), "%s means the key was rejected" % code)
	for code in ["no_network", "timeout", "tls", "server", "rate_limited", "bad_path"]:
		assert_false(LLMProviders.key_rejected_for(code), "%s does not blame the key" % code)

	begin("result dictionaries carry R9's keys")
	var ok_result := LLMProviders.success_result(OPENAI_KEY, 123)
	for field in ["ok", "error_code", "http_status", "latency_ms", "message", "key_rejected",
			"models_hint"]:
		assert_has_key(ok_result, field, "success has %s" % field)
	assert_true(bool(ok_result["ok"]), "success is ok")
	assert_eq(String(ok_result["error_code"]), "", "success has no code")
	assert_eq(int(ok_result["latency_ms"]), 123, "latency is reported")
	var bad_result := LLMProviders.failure_result("auth", OPENAI_KEY,
		"https://api.openai.com/v1", 401, 88)
	for field in ["ok", "error_code", "http_status", "latency_ms", "message", "key_rejected",
			"models_hint", "redacted_detail"]:
		assert_has_key(bad_result, field, "failure has %s" % field)
	assert_false(bool(bad_result["ok"]), "failure is not ok")
	assert_eq(int(bad_result["http_status"]), 401, "status is reported")
	assert_true(bool(bad_result["key_rejected"]), "401 blames the key")


# ------------------------------------------------------------------ R12: typed RESET

func _test_reset_guard() -> void:
	begin("the destructive action needs the exact word (R12)")
	var script: GDScript = load(SETTINGS_SCRIPT)
	assert_true(script != null, "the settings script loads")
	if script == null:
		return

	# `is_reset_confirmation` is static, so it is callable straight off the script resource —
	# no scene tree, no autoloads, which is what makes this guard testable headlessly.
	assert_true(_confirm(script, "RESET"), "exactly RESET is accepted")
	assert_true(_confirm(script, "RESET "), "a trailing space is tolerated")
	assert_true(_confirm(script, "RESET\n"), "a trailing newline is tolerated")
	assert_false(_confirm(script, "reset"), "lower case is not")
	assert_false(_confirm(script, "Reset"), "mixed case is not")
	assert_false(_confirm(script, " RESET"), "a leading space is not tolerated")
	assert_false(_confirm(script, ""), "empty is not")
	assert_false(_confirm(script, "RESETT"), "a longer word is not")
	assert_false(_confirm(script, "RESE"), "a prefix is not")
	assert_false(_confirm(script, "RESET ALL"), "extra words are not")
	assert_false(_confirm(script, "RESETT"), "and the guard is not a substring test")
	assert_eq(Strings.RESET_WORD, "RESET", "the word itself is fixed copy")


func _confirm(script: GDScript, text: String) -> bool:
	var value: Variant = script.call(&"is_reset_confirmation", text)
	return value is bool and bool(value)


# ------------------------------------------------------------------ helpers

## A configuration for [param key] built from that preset's own defaults, with a valid key —
## except `custom`, which ships neither a URL nor a model (R7).
func _config_for(key: String) -> Dictionary:
	var cfg := StoreSchema.default_llm()
	cfg["provider"] = key
	cfg["api_key"] = GOOD_KEY
	if key == CUSTOM_KEY:
		cfg["base_url"] = CUSTOM_URL
		cfg["model"] = CUSTOM_MODEL
	else:
		cfg["base_url"] = LLMProviders.default_base_url(key)
		cfg["model"] = LLMProviders.default_model(key)
	return cfg
