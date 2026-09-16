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

## Anthropic's required API version header (R9).
const ANTHROPIC_VERSION := "2023-06-01"


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
