class_name LLMProviders
extends RefCounted
## The canonical provider table — PRD-06 R5 (§8.1 of the master plan), the copy every
## "Test connection" branch uses (R9), and the request shape each provider needs.
##
## [b]Ownership:[/b] this file is created by PRD-06 and owned by PRD-07. PRD-07 extends it with
## generation-time request shaping (`chat_path`, `supports_json_mode`, `supports_system_role`,
## `max_tokens_key`, `extra_headers`, `key_prefix_hint`, `default_timeout_sec`, `resolve_url()`,
## `json_mode_ok()`). It may not rename a preset key or change a base URL without a
## `DECISIONS.md` entry.
##
## [constant PRESETS] is **data**: seven dictionaries, each with exactly the seven keys R5 pins.
## Nothing in this file reads a setting, opens a socket or touches the scene tree, so the whole
## table and every message below is unit-testable headless.

## One entry per §8.1 preset, in [method keys] order.
##
## Key meanings:
##   `label`             user-facing provider name, interpolated into failure copy as `<P>`
##   `base_url`          the API root; `""` for `custom` because the user supplies it
##   `default_model`     prefilled into `llm.model`; `""` for `custom`
##   `auth_style`        `bearer` | `x_api_key` | `query_key` | `none`
##   `adapter`           `openai_compatible` | `anthropic` | `gemini`
##   `editable_base_url` false only for `anthropic` and `gemini` (R6, PRD-06 §10 note 1)
##   `docs_url`          opened by `ProviderHelpButton` through `OS.shell_open()`
const PRESETS: Dictionary = {
	"openai": {
		"label": "OpenAI",
		"base_url": "https://api.openai.com/v1",
		"default_model": "gpt-4o-mini",
		"auth_style": "bearer",
		"adapter": "openai_compatible",
		"editable_base_url": true,
		"docs_url": "https://platform.openai.com/docs/api-reference",
	},
	"deepseek": {
		"label": "DeepSeek",
		"base_url": "https://api.deepseek.com/v1",
		"default_model": "deepseek-chat",
		"auth_style": "bearer",
		"adapter": "openai_compatible",
		"editable_base_url": true,
		"docs_url": "https://api-docs.deepseek.com",
	},
	"anthropic": {
		"label": "Anthropic",
		"base_url": "https://api.anthropic.com/v1",
		"default_model": "claude-3-5-sonnet-latest",
		"auth_style": "x_api_key",
		"adapter": "anthropic",
		"editable_base_url": false,
		"docs_url": "https://docs.anthropic.com",
	},
	"gemini": {
		"label": "Google Gemini",
		"base_url": "https://generativelanguage.googleapis.com/v1beta",
		"default_model": "gemini-1.5-flash",
		"auth_style": "query_key",
		"adapter": "gemini",
		"editable_base_url": false,
		"docs_url": "https://ai.google.dev/gemini-api/docs",
	},
	"openrouter": {
		"label": "OpenRouter",
		"base_url": "https://openrouter.ai/api/v1",
		"default_model": "openai/gpt-4o-mini",
		"auth_style": "bearer",
		"adapter": "openai_compatible",
		"editable_base_url": true,
		"docs_url": "https://openrouter.ai/docs",
	},
	"groq": {
		"label": "Groq",
		"base_url": "https://api.groq.com/openai/v1",
		"default_model": "llama-3.3-70b-versatile",
		"auth_style": "bearer",
		"adapter": "openai_compatible",
		"editable_base_url": true,
		"docs_url": "https://console.groq.com/docs",
	},
	"custom": {
		"label": "Custom (OpenAI-compatible)",
		"base_url": "",
		"default_model": "",
		"auth_style": "bearer",
		"adapter": "openai_compatible",
		"editable_base_url": true,
		"docs_url": "",
	},
}

## Anthropic's required API version header (PRD-06 R9). Declared before [constant SHAPES]
## because the Anthropic entry carries it in `extra_headers`.
const ANTHROPIC_VERSION := "2023-06-01"

## PRD-07 R1 — the request-shaping half of the same table, keyed identically.
##
## [b]Why this is a second constant and not more keys inside [constant PRESETS]:[/b] PRD-06's
## suite (`tests/suites/test_settings_validation.gd`) pins `PRESETS[key].size() == 7` —
## "each preset carries exactly R5's seven keys" — and that suite is frozen. R1 says the table
## "gains, per preset" this metadata, and a parallel table keyed by the same seven names is how
## both requirements hold at once: [method preset] still returns PRD-06's seven fields, and
## [method shape] merges the two for every R2 request-building decision. There is exactly one
## entry per preset and each entry carries exactly R1's seven fields.
##
## Key meanings:
##   `chat_path`           appended to the base URL; `{model}` is substituted (Gemini only)
##   `supports_json_mode`  the provider has a JSON-mode request flag at all
##   `supports_system_role` true when the system prompt rides in `messages`/`contents`;
##                         false when it needs its own top-level field (Anthropic, Gemini)
##   `max_tokens_key`      what the token cap is called in the body — `max_tokens`
##                         (OpenAI-compatible), `max_tokens_required` (Anthropic: not optional),
##                         `maxOutputTokens` (Gemini)
##   `extra_headers`       provider-mandated headers beyond Content-Type/Accept/auth
##   `key_prefix_hint`     shown by Settings as a paste sanity check; never matched strictly
##   `default_timeout_sec` R2/R7's per-attempt timeout, 45 s for every preset
const SHAPES: Dictionary = {
	"openai": {
		"chat_path": "/chat/completions",
		"supports_json_mode": true,
		"supports_system_role": true,
		"max_tokens_key": "max_tokens",
		"extra_headers": {},
		"key_prefix_hint": "sk-",
		"default_timeout_sec": 45,
	},
	"deepseek": {
		"chat_path": "/chat/completions",
		"supports_json_mode": true,
		"supports_system_role": true,
		"max_tokens_key": "max_tokens",
		"extra_headers": {},
		"key_prefix_hint": "sk-",
		"default_timeout_sec": 45,
	},
	"anthropic": {
		"chat_path": "/messages",
		"supports_json_mode": false,
		"supports_system_role": false,
		"max_tokens_key": "max_tokens_required",
		"extra_headers": {"anthropic-version": ANTHROPIC_VERSION},
		"key_prefix_hint": "sk-ant-",
		"default_timeout_sec": 45,
	},
	"gemini": {
		"chat_path": "/models/{model}:generateContent",
		"supports_json_mode": true,
		"supports_system_role": false,
		"max_tokens_key": "maxOutputTokens",
		"extra_headers": {},
		"key_prefix_hint": "AIza",
		"default_timeout_sec": 45,
	},
	"openrouter": {
		"chat_path": "/chat/completions",
		"supports_json_mode": true,
		"supports_system_role": true,
		"max_tokens_key": "max_tokens",
		"extra_headers": {
			"HTTP-Referer": "https://github.com/microshak/microworkout",
			"X-Title": "MicroWorkout",
		},
		"key_prefix_hint": "sk-or-",
		"default_timeout_sec": 45,
	},
	"groq": {
		"chat_path": "/chat/completions",
		"supports_json_mode": true,
		"supports_system_role": true,
		"max_tokens_key": "max_tokens",
		"extra_headers": {},
		"key_prefix_hint": "gsk_",
		"default_timeout_sec": 45,
	},
	"custom": {
		"chat_path": "/chat/completions",
		"supports_json_mode": true,
		"supports_system_role": true,
		"max_tokens_key": "max_tokens",
		"extra_headers": {},
		"key_prefix_hint": "",
		"default_timeout_sec": 45,
	},
}

## R1's field names, in table order — what [method shape] must contain per preset.
const SHAPE_FIELDS: PackedStringArray = [
	"chat_path", "supports_json_mode", "supports_system_role", "max_tokens_key",
	"extra_headers", "key_prefix_hint", "default_timeout_sec",
]

## R1's closed set for `max_tokens_key`.
const MAX_TOKENS_KEYS: PackedStringArray = [
	"max_tokens", "maxOutputTokens", "max_tokens_required",
]

## The preset a wiped install starts on (`settings.json` `llm.provider`).
const DEFAULT_KEY := "deepseek"

## Fixed enumeration order (R5). Changing it reorders the picker in every build.
const ORDER: PackedStringArray = [
	"openai", "deepseek", "anthropic", "gemini", "openrouter", "groq", "custom",
]

## Provider shape vocabulary, closed sets (R5).
const AUTH_STYLES: PackedStringArray = ["bearer", "x_api_key", "query_key", "none"]
const ADAPTERS: PackedStringArray = ["openai_compatible", "anthropic", "gemini"]

## The API-key field is length-checked between these two bounds (R7).
const KEY_MIN_LENGTH := 8
const KEY_MAX_LENGTH := 512

## `Test connection` waits this long, once, and never retries (R9).
const TEST_TIMEOUT_SEC := 20


# ------------------------------------------------------------------ table access (R5)

## The entry for [param key], or the `custom` entry for an unknown key — a corrupt
## `settings.llm.provider` degrades to the one preset whose base URL the user controls rather
## than crashing the Settings tab.
static func preset(key: String) -> Dictionary:
	var entry: Dictionary = PRESETS.get(key, PRESETS["custom"])
	return entry


static func keys() -> PackedStringArray:
	return ORDER


static func has(key: String) -> bool:
	return PRESETS.has(key)


static func label_for(key: String) -> String:
	return String(preset(key).get("label", ""))


static func adapter_for(key: String) -> String:
	return String(preset(key).get("adapter", "openai_compatible"))


static func default_base_url(key: String) -> String:
	return String(preset(key).get("base_url", ""))


static func default_model(key: String) -> String:
	return String(preset(key).get("default_model", ""))


static func docs_url(key: String) -> String:
	return String(preset(key).get("docs_url", ""))


## R6: editable for `custom` and every OpenAI-compatible preset (openai, deepseek, openrouter,
## groq); read-only for `anthropic` and `gemini` (PRD-06 §10 note 1 tracks the `Edit anyway`
## toggle that would unlock them).
static func base_url_editable(key: String) -> bool:
	return bool(preset(key).get("editable_base_url", false))


## `custom` is the only preset without a shipped base URL, so it is the only one that must
## supply one (R7).
static func require_base_url(key: String) -> bool:
	return key == "custom" or default_base_url(key).is_empty()


## The auth style actually used, once `llm.custom_auth_none` is taken into account (R1 of PRD-07
## lists this static; PRD-06 needs it for the R7 key-required rule).
static func effective_auth_style(key: String, cfg: Dictionary) -> String:
	var style := String(preset(key).get("auth_style", "bearer"))
	if key == "custom" and bool(cfg.get("custom_auth_none", false)):
		return "none"
	return style


## True when this configuration must carry a non-empty key (R7).
static func requires_key(key: String, cfg: Dictionary) -> bool:
	return effective_auth_style(key, cfg) != "none"


## `api.deepseek.com` from `https://api.deepseek.com/v1` — the `<H>` in the R9 copy table.
static func host_of(url: String) -> String:
	var trimmed := url.strip_edges()
	var scheme_at := trimmed.find("://")
	var rest := trimmed.substr(scheme_at + 3) if scheme_at >= 0 else trimmed
	var slash := rest.find("/")
	var authority := rest.substr(0, slash) if slash >= 0 else rest
	var colon := authority.rfind(":")
	if colon > 0:
		return authority.substr(0, colon)
	return authority


# ------------------------------------------------------------------ request shaping (PRD-07 R1)

## The R1 entry for [param key], or `custom`'s for an unknown key (the same degradation
## [method preset] performs, so the two tables can never disagree about which key exists).
static func shape(key: String) -> Dictionary:
	var entry: Dictionary = SHAPES.get(key, SHAPES["custom"])
	return entry


## PRD-06's seven fields merged with R1's seven. Nothing but a reader needs this; it exists so a
## debug dump or a suite can show one complete picture of a preset.
static func merged(key: String) -> Dictionary:
	var out: Dictionary = preset(key).duplicate()
	for field in shape(key).keys():
		out[field] = shape(key)[field]
	return out


static func shape_field(key: String, field: String, fallback: Variant) -> Variant:
	return shape(key).get(field, fallback)


## Appended to the (possibly user-edited) base URL. Gemini's contains `{model}`.
static func chat_path_for(key: String) -> String:
	return String(shape(key).get("chat_path", "/chat/completions"))


static func supports_json_mode(key: String) -> bool:
	return bool(shape(key).get("supports_json_mode", true))


## False for Anthropic (`system` is a top-level field) and Gemini (`systemInstruction`).
static func supports_system_role(key: String) -> bool:
	return bool(shape(key).get("supports_system_role", true))


## `max_tokens` | `maxOutputTokens` | `max_tokens_required`.
static func max_tokens_key_for(key: String) -> String:
	return String(shape(key).get("max_tokens_key", "max_tokens"))


## Provider-mandated headers (Anthropic's version, OpenRouter's attribution pair). Returned as a
## fresh dictionary so a caller cannot mutate the table.
static func extra_headers_for(key: String) -> Dictionary:
	var out: Dictionary = {}
	var headers: Variant = shape(key).get("extra_headers", {})
	if headers is Dictionary:
		for field in (headers as Dictionary).keys():
			out[String(field)] = String((headers as Dictionary)[field])
	return out


## A paste sanity hint for Settings; never a validation rule (a provider may issue any shape).
static func key_prefix_hint(key: String) -> String:
	return String(shape(key).get("key_prefix_hint", ""))


static func default_timeout_sec(key: String) -> int:
	return int(shape(key).get("default_timeout_sec", 45))


## R1's `json_mode_ok`: the provider must support it *and* the configuration must not have
## switched it off. `custom` is the only preset whose flag is a user setting
## (`llm.custom_json_mode`, default true).
static func json_mode_ok(key: String, cfg: Dictionary) -> bool:
	if not supports_json_mode(key):
		return false
	if key == "custom":
		return bool(cfg.get("custom_json_mode", true))
	return true


## The model this configuration will ask for: the user's `llm.model` when set, else the preset
## default. Never empty for a shipped preset, which matters because Gemini's path contains it.
static func model_for(key: String, cfg: Dictionary) -> String:
	var model := String(cfg.get("model", "")).strip_edges()
	if not model.is_empty():
		return model
	return default_model(key)


## The base URL this configuration will use, with the trailing slash removed so the join with
## [method chat_path_for] never produces a double slash.
static func base_url_for(key: String, cfg: Dictionary) -> String:
	var base := String(cfg.get("base_url", "")).strip_edges()
	if base.is_empty():
		base = default_base_url(key)
	return base.trim_suffix("/")


## R1's `resolve_url`: base + `chat_path`, with `{model}` percent-encoded in, and `?key=` for the
## `query_key` auth style. This is the **only** function that builds a generation URL, so the one
## place a Gemini key can enter a URL is also the one place it is easy to audit (R12).
##
## `String.uri_encode()` takes no arguments in Godot 4.7.2 — R1's `uri_encode(model, false)`
## spelling does not exist (PRD-06 R9 already recorded this).
static func resolve_url(key: String, cfg: Dictionary) -> String:
	var url := base_url_for(key, cfg) + chat_path_for(key)
	url = url.replace("{model}", model_for(key, cfg).uri_encode())
	if effective_auth_style(key, cfg) == "query_key":
		var secret := String(cfg.get("api_key", "")).strip_edges()
		if not secret.is_empty():
			url = "%s?key=%s" % [url, secret.uri_encode()]
	return url


## The authentication headers for [param key], given the already-resolved [param style].
## Split out from the URL because Gemini's key never becomes a header and Anthropic's never
## becomes a query parameter.
static func auth_headers_for(key: String, cfg: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var secret := String(cfg.get("api_key", "")).strip_edges()
	match effective_auth_style(key, cfg):
		"bearer":
			if not secret.is_empty():
				out.append("Authorization: Bearer %s" % secret)
		"x_api_key":
			if not secret.is_empty():
				out.append("x-api-key: %s" % secret)
	return out


# ------------------------------------------------------------------ Test connection (R9)

## HTTP status -> `error_code`. 401 is `auth` (the key was rejected), 403 `forbidden`,
## 404 `bad_path`, 429 `rate_limited`, any 5xx `server`, and anything else non-2xx
## `bad_response`. PRD-07 pins the same vocabulary on `LLMResult.classify()`.
static func classify_status(status: int) -> String:
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


## True for the two branches that mean "the key itself is the problem" (R9's `key_rejected`).
static func key_rejected_for(error_code: String) -> bool:
	return error_code == "auth" or error_code == "forbidden"


## The verbatim R9 copy for one branch. `<P>` is the provider label, `<H>` the base-URL host.
## An unknown `error_code` falls back to the `bad_response` wording rather than showing nothing.
static func message_for(error_code: String, provider_key: String, base_url: String,
		http_status: int = 0) -> String:
	var label := label_for(provider_key)
	var host := host_of(base_url)
	match error_code:
		"":
			return "Connected to %s. The key works." % label
		"no_key":
			return "Paste your %s API key first." % label
		"no_network":
			return "Couldn't reach %s. Check the base URL and your internet connection." % host
		"tls":
			return "Couldn't establish a secure connection to %s. Check the base URL." % host
		"auth":
			return ("The key was rejected by %s. Check that you pasted the whole key and that "
				+ "it belongs to this provider.") % label
		"forbidden":
			return "%s refused this request (403). The key may lack access to this model." % label
		"bad_path":
			return ("Reached %s, but the API path wasn't found. Check the base URL — it usually "
				+ "ends in /v1.") % host
		"rate_limited":
			return ("%s is rate-limiting this key. The key looks fine; try again in a minute."
				% label)
		"server":
			return ("%s had a server problem (HTTP %d). MicroWorkout still works — it will use "
				+ "the built-in generator.") % [label, http_status]
		"timeout":
			return ("%s didn't answer within 20 seconds. Your key may still be fine — try again."
				% label)
		"cancelled":
			return "Test cancelled."
	return "Reached %s, but its reply couldn't be read. Check the model name." % label


## The complete R9 result dictionary for a successful probe.
static func success_result(provider_key: String, latency_ms: int,
		models_hint: String = "") -> Dictionary:
	return {
		"ok": true,
		"error_code": "",
		"http_status": 200,
		"latency_ms": latency_ms,
		"message": message_for("", provider_key, ""),
		"key_rejected": false,
		"models_hint": models_hint,
	}


## The complete R9 result dictionary for one failure branch. [param detail] is the provider's
## own words (an error body, a transport error) and always passes through
## [method Redact.safe_error] before it can reach a log, a toast or the settings document.
static func failure_result(error_code: String, provider_key: String, base_url: String,
		http_status: int = 0, latency_ms: int = 0, detail: String = "",
		api_key: String = "", models_hint: String = "") -> Dictionary:
	return {
		"ok": false,
		"error_code": error_code,
		"http_status": http_status,
		"latency_ms": latency_ms,
		"message": message_for(error_code, provider_key, base_url, http_status),
		"key_rejected": key_rejected_for(error_code),
		"models_hint": models_hint,
		"redacted_detail": Redact.safe_error(detail, api_key),
	}


## The minimal authenticated call R9 makes for a one-key probe: `{method, url, headers, body}`.
## `max_tokens` is 1 because the answer is never read — only the status and the envelope matter.
##
## PRD-07 replaces this with `LLMClient.build_request()` for generation; this stays the shape
## `test_connection` uses so the probe cannot accidentally ask a provider to write a plan.
static func connection_request(provider_key: String, cfg: Dictionary) -> Dictionary:
	var base := String(cfg.get("base_url", "")).strip_edges().trim_suffix("/")
	var model := String(cfg.get("model", "")).strip_edges()
	var key := String(cfg.get("api_key", "")).strip_edges()
	var style := effective_auth_style(provider_key, cfg)
	var body := '{"messages":[{"role":"user","content":"ping"}]}'
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	var url := base

	match adapter_for(provider_key):
		"anthropic":
			url = "%s/messages" % base
			headers.append("anthropic-version: %s" % ANTHROPIC_VERSION)
			if style == "x_api_key" and not key.is_empty():
				headers.append("x-api-key: %s" % key)
			body = ('{"model":%s,"max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
				% JSON.stringify(model))
		"gemini":
			# `String.uri_encode()` takes no arguments in Godot 4.7.2 (PRD-07's
			# `uri_encode(model, false)` spelling does not exist — it must be corrected there).
			url = "%s/models/%s:generateContent" % [base, model.uri_encode()]
			if style == "query_key" and not key.is_empty():
				url = "%s?key=%s" % [url, key.uri_encode()]
			body = ('{"contents":[{"role":"user","parts":[{"text":"ping"}]}],'
				+ '"generationConfig":{"maxOutputTokens":1}}')
		_:
			url = "%s/chat/completions" % base
			if style == "bearer" and not key.is_empty():
				headers.append("Authorization: Bearer %s" % key)
			body = ('{"model":%s,"messages":[{"role":"user","content":"ping"}],'
				+ '"max_tokens":1,"stream":false}') % JSON.stringify(model)

	return {
		"method": HTTPClient.METHOD_POST,
		"url": url,
		"headers": headers,
		"body": body,
		"timeout_sec": TEST_TIMEOUT_SEC,
	}
