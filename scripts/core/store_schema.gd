class_name StoreSchema
extends RefCounted
## Field-level validation and normalization for the settings the PRD-06 screens write —
## PRD-06 R7, appendix R24.
##
## [b]Why a separate class when `Migrations.Schema` already validates the document:[/b] the
## appendix (R24) pins one module for defaults/ranges/clamping and the LLM validator, and
## `Migrations.Schema` owns the first four. This file adds the one thing it does not have — the
## per-field rules the Settings tab needs *before* it writes, with a message the user can act on
## — and delegates every default to `Migrations.Schema` so there is still exactly one defaults
## table. `settings_schema.gd`/`SettingsSchema` are banned spellings (appendix §9).
##
## Two invariants:
##
## 1. [method validate_setting] never writes. The Settings tab validates first, writes second, so
##    an invalid field can never reach `settings.json` and never half-applies.
## 2. [method validate_llm] returns `normalized` — the trimmed, type-coerced configuration that
##    is what actually gets stored. Saving `normalized` is what makes "paste a key with a stray
##    space" harmless rather than a validation puzzle.
##
## Everything here is static and pure.

## R7 message strings, verbatim. Kept as constants so the suites assert on the same literal the
## UI shows and a copy change is one edit.
const BASE_URL_MESSAGE := \
	"Enter a full URL starting with https:// (http:// is allowed only for localhost)."
const MODEL_MESSAGE := "Model names may only contain letters, numbers, and . _ : / -"
const KEY_TOO_SHORT_MESSAGE := "That key looks too short — paste the whole key."
const KEY_WHITESPACE_MESSAGE := "That key contains spaces or line breaks. Paste it again."
const KEY_TOO_LONG_MESSAGE := "That key is longer than %d characters — paste just the key."
const PROVIDER_MESSAGE := "Choose a provider."
const WEEKLY_GOAL_MESSAGE := "Pick 1 to 7 days."
const UNITS_MESSAGE := "Pick lb or kg."
const THEME_MESSAGE := "Pick a theme."
const REST_MESSAGE := "Rest must be 15–300 seconds in 15-second steps."
const BOOL_MESSAGE := "Expected true or false."
const TEXT_SCALE_MESSAGE := "Pick a text size."
const TAB_MESSAGE := "Pick a tab from 0 to 3."

## `^https?://[^\s/?#]+(/[^\s?#]*)?$` — scheme, authority, optional path, no query, no fragment.
const BASE_URL_PATTERN := "^https?://[^\\s/?#]+(/[^\\s?#]*)?$"

## `^[A-Za-z0-9._:/-]+$` — model identifiers, including OpenRouter's `vendor/model` shape.
const MODEL_PATTERN := "^[A-Za-z0-9._:/-]+$"

## The only hosts for which a cleartext `http://` base URL is allowed (R7). `10.0.2.2` is the
## Android emulator's alias for the developer's machine, which is how the mock LLM server is
## reached on-device.
const LOCAL_HOSTS: PackedStringArray = ["localhost", "127.0.0.1", "10.0.2.2"]

## Settings keys that hold a boolean, so the UI can validate a toggle in one call.
const BOOL_KEYS: PackedStringArray = [
	"onboarding_complete", "attribution_seen",
	"rest_timer.enabled", "rest_timer.auto_start", "rest_timer.sound", "rest_timer.haptic",
	"ui.reduce_motion", "ui.sound_enabled", "ui.haptics_enabled", "ui.haptics_unavailable_shown",
	"llm.custom_auth_none", "llm.custom_json_mode", "llm.configured",
]

const THEMES: PackedStringArray = ["dark", "light"]
const TEXT_SCALES: PackedFloat32Array = [0.85, 1.0, 1.15, 1.3, 1.5]

## `rest_timer.default_seconds` must land on a 15-second step (R7).
const REST_STEP := 15
const REST_MIN := 15
const REST_MAX := 300

const WEEKLY_GOAL_MIN := 1
const WEEKLY_GOAL_MAX := 7


# ------------------------------------------------------------------ defaults (R1/R24)

## The one settings document shape. Delegates to [Migrations.Schema] so a wiped install and a
## missing key can never disagree (R1). Re-exported here because the appendix names this module
## as the owner of `validate_llm`/`normalize_llm`, and a caller validating an LLM config should
## not have to reach for two classes.
static func default_settings() -> Dictionary:
	return Migrations.Schema.default_settings()


## The `llm` block as a wiped install writes it.
static func default_llm() -> Dictionary:
	var block: Dictionary = default_settings()["llm"]
	return block.duplicate(true)


# ------------------------------------------------------------------ whole-config validation (R7)

## Validates an `llm` block. Returns `{"ok": bool, "errors": {field: message}, "normalized":
## Dictionary}`; `errors` is keyed by the bare field name (`base_url`, `model`, `api_key`,
## `provider`) because that is how the form maps a message onto a field.
##
## A failed `Test connection` is never an input to this function: R7/R9 keep "the fields are
## well-formed" and "the provider answered" strictly separate.
static func validate_llm(cfg: Dictionary) -> Dictionary:
	var normalized := normalize_llm(cfg)
	var errors: Dictionary = {}
	var provider := String(normalized["provider"])

	if not LLMProviders.has(provider):
		errors["provider"] = PROVIDER_MESSAGE

	var base_url := String(normalized["base_url"])
	var base_error := validate_base_url(base_url)
	if base_error.is_empty() and base_url.is_empty() and LLMProviders.require_base_url(provider):
		# `custom` is the only preset with no shipped base URL (R7).
		base_error = BASE_URL_MESSAGE
	if not base_error.is_empty():
		errors["base_url"] = base_error

	var model_error := validate_model(String(normalized["model"]))
	if not model_error.is_empty():
		errors["model"] = model_error

	var key_error := validate_api_key(String(normalized["api_key"]), provider, normalized)
	if not key_error.is_empty():
		errors["api_key"] = key_error

	return {"ok": errors.is_empty(), "errors": errors, "normalized": normalized}


## Trims, strips a trailing `/`, coerces every field's type and fills in the missing keys from
## [method default_llm]. Idempotent: `normalize_llm(normalize_llm(x)) == normalize_llm(x)`.
## An unknown `provider` is preserved — validation, not normalization, is what rejects it.
static func normalize_llm(cfg: Dictionary) -> Dictionary:
	var out := default_llm()
	for field in Migrations.Schema.LLM_FIELDS:
		if cfg.has(field):
			out[field] = cfg[field]

	out["provider"] = _as_string(out.get("provider", null), LLMProviders.DEFAULT_KEY).strip_edges()
	out["base_url"] = normalize_base_url(_as_string(out.get("base_url", null), ""))
	out["model"] = _as_string(out.get("model", null), "").strip_edges()
	out["api_key"] = _as_string(out.get("api_key", null), "").strip_edges()
	out["temperature"] = _as_float(out.get("temperature", null), 0.4)
	out["timeout_sec"] = _as_int(out.get("timeout_sec", null), 45)
	out["custom_auth_none"] = _as_bool(out.get("custom_auth_none", null), false)
	out["custom_json_mode"] = _as_bool(out.get("custom_json_mode", null), true)
	out["custom_name"] = _as_string(out.get("custom_name", null), "").strip_edges()
	out["configured"] = _as_bool(out.get("configured", null), false)
	out["last_tested_at"] = _as_nullable_string(out.get("last_tested_at", null))
	out["last_test_ok"] = _as_nullable_bool(out.get("last_test_ok", null))
	return out


# ------------------------------------------------------------------ field rules (R7)

## `""` when the URL is acceptable, else the R7 message. Trims, collapses duplicate `/` in the
## path and drops the trailing `/` first, so `https://api.example.com//v1/` is `…/v1`.
static func validate_base_url(raw: String) -> String:
	var value := normalize_base_url(raw)
	if value.is_empty():
		return BASE_URL_MESSAGE
	var re := RegEx.new()
	if re.compile(BASE_URL_PATTERN) != OK:
		return BASE_URL_MESSAGE
	var found := re.search(value)
	if found == null or found.get_string() != value:
		return BASE_URL_MESSAGE
	if value.begins_with("http://"):
		var host := LLMProviders.host_of(value).to_lower()
		if not LOCAL_HOSTS.has(host):
			return BASE_URL_MESSAGE
	return ""


## Trims trailing whitespace, a trailing `/` and duplicate `/` in the path — but never the `//`
## of the scheme itself.
static func normalize_base_url(raw: String) -> String:
	var value := raw.strip_edges()
	if value.is_empty():
		return ""
	var scheme_at := value.find("://")
	if scheme_at < 0:
		return _collapse_slashes(value)
	var scheme := value.substr(0, scheme_at + 3)
	var rest := _collapse_slashes(value.substr(scheme_at + 3))
	return scheme + rest.trim_suffix("/")


## 1–128 characters of `A-Za-z0-9._:/-`.
static func validate_model(raw: String) -> String:
	var value := raw.strip_edges()
	if value.is_empty() or value.length() > 128:
		return MODEL_MESSAGE
	var re := RegEx.new()
	if re.compile(MODEL_PATTERN) != OK:
		return MODEL_MESSAGE
	var found := re.search(value)
	if found == null or found.get_string() != value:
		return MODEL_MESSAGE
	return ""


## R7's key rules against the trimmed value: whitespace/quotes rejected, then 8–512 characters,
## then "required unless this provider needs no key". [param cfg] supplies `custom_auth_none`
## (and, for an unknown provider, nothing else).
static func validate_api_key(raw: String, provider: String, cfg: Dictionary = {}) -> String:
	var value := raw.strip_edges()
	if value.is_empty():
		if LLMProviders.requires_key(provider, cfg):
			return "Paste your %s API key." % LLMProviders.label_for(provider)
		return ""
	if _has_illegal_char(value):
		return KEY_WHITESPACE_MESSAGE
	if value.length() < LLMProviders.KEY_MIN_LENGTH:
		return KEY_TOO_SHORT_MESSAGE
	if value.length() > LLMProviders.KEY_MAX_LENGTH:
		return KEY_TOO_LONG_MESSAGE % LLMProviders.KEY_MAX_LENGTH
	return ""


static func validate_provider(key: String) -> String:
	return "" if LLMProviders.has(key) else PROVIDER_MESSAGE


static func validate_weekly_goal_days(days: int) -> String:
	return "" if days >= WEEKLY_GOAL_MIN and days <= WEEKLY_GOAL_MAX else WEEKLY_GOAL_MESSAGE


static func validate_units(units: String) -> String:
	return Units.validate_units_value(units)


static func validate_theme(theme: String) -> String:
	return "" if THEMES.has(theme) else THEME_MESSAGE


## `15..300` in 15-second steps — the one rule `Migrations.Schema` does not enforce, because the
## store clamps a hand-edited file rather than rejecting a user's slider value (R7).
static func validate_rest_seconds(seconds: int) -> String:
	if seconds < REST_MIN or seconds > REST_MAX:
		return REST_MESSAGE
	if seconds % REST_STEP != 0:
		return REST_MESSAGE
	return ""


static func validate_text_scale(scale: float) -> String:
	for candidate in TEXT_SCALES:
		if is_equal_approx(scale, candidate):
			return ""
	return TEXT_SCALE_MESSAGE


static func validate_last_tab(index: int) -> String:
	return "" if index >= 0 and index <= 3 else TAB_MESSAGE


# ------------------------------------------------------------------ one-key validation (R7)

## The message for a single `settings.json` path, or `""` when the value is acceptable. Used by
## the Settings tab to validate *before* [method Store.set_setting] so a rejected write can never
## leave the document half-applied.
##
## [param context] carries the neighbouring values a field depends on: `provider` and
## `custom_auth_none` for `llm.api_key`. An unknown path returns `""` — the store still owns the
## final say (it rejects unknown keys outright).
static func validate_setting(path: String, value: Variant, context: Dictionary = {}) -> String:
	if BOOL_KEYS.has(path):
		return "" if value is bool else BOOL_MESSAGE
	match path:
		"units":
			return validate_units(_as_string(value, ""))
		"theme":
			return validate_theme(_as_string(value, ""))
		"weekly_goal_days":
			return validate_weekly_goal_days(_as_int(value, 0))
		"rest_timer.default_seconds":
			return validate_rest_seconds(_as_int(value, 0))
		"ui.last_tab":
			return validate_last_tab(_as_int(value, 0))
		"ui.text_scale":
			return validate_text_scale(_as_float(value, 0.0))
		"llm.provider":
			return validate_provider(_as_string(value, ""))
		"llm.base_url":
			return validate_base_url(_as_string(value, ""))
		"llm.model":
			return validate_model(_as_string(value, ""))
		"llm.api_key":
			return validate_api_key(_as_string(value, ""),
				_as_string(context.get("provider", LLMProviders.DEFAULT_KEY), ""), context)
		"llm.temperature":
			var temperature := _as_float(value, 0.4)
			return "" if temperature >= 0.0 and temperature <= 2.0 else "Temperature is 0.0 to 2.0."
		"llm.timeout_sec":
			var timeout := _as_int(value, 45)
			return "" if timeout >= 5 and timeout <= 120 else "Timeout is 5 to 120 seconds."
	return ""


# ------------------------------------------------------------------ internals

static func _collapse_slashes(value: String) -> String:
	var out := value
	while out.contains("//"):
		out = out.replace("//", "/")
	return out


## Space, tab, newline, carriage return, vertical tab, form feed or a double quote — R7's
## "contains whitespace, `\"` or a newline". A key with any of these is a broken paste, and the
## message says so rather than letting a 512-character blob through.
static func _has_illegal_char(value: String) -> bool:
	for i in value.length():
		var c := value[i]
		if c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\u000b" or c == "\u000c" \
				or c == "\"":
			return true
	return false


static func _as_string(value: Variant, fallback: String) -> String:
	if value is String:
		return String(value)
	return fallback


static func _as_nullable_string(value: Variant) -> Variant:
	if value is String:
		var text := String(value).strip_edges()
		if not text.is_empty():
			return text
	return null


static func _as_nullable_bool(value: Variant) -> Variant:
	if value is bool:
		return bool(value)
	return null


static func _as_bool(value: Variant, fallback: bool) -> bool:
	if value is bool:
		return bool(value)
	return fallback


static func _as_int(value: Variant, fallback: int) -> int:
	if value is int:
		return int(value)
	if value is float:
		return int(value)
	if value is String:
		var text := String(value).strip_edges()
		return int(text) if text.is_valid_int() else fallback
	return fallback


static func _as_float(value: Variant, fallback: float) -> float:
	if value is float:
		return float(value)
	if value is int:
		return float(value)
	if value is String:
		var text := String(value).strip_edges()
		return float(text) if text.is_valid_float() else fallback
	return fallback
