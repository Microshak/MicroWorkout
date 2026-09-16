class_name Redact
extends RefCounted
## Secret hygiene: one place that masks an API key for display and one place that scrubs a
## secret out of any string that could reach a log, a toast, an error message or a plan's
## `generation` metadata — PRD-06 R8/R9, appendix §1.4.
##
## Two different jobs, deliberately kept apart:
##
## * [method mask_key] is **for display**: `sk-abcdef123456` -> `sk-••••••••3456`. It keeps a
##   recognisable head and tail so the owner can tell two keys apart, and it is stable — masking
##   a mask returns the same string, so a re-render can never progressively mangle a value.
## * [method redact] / [method safe_error] are **for safety**: they remove the secret from text
##   that is about to be printed or shown. They are deliberately over-eager — a scrubbed message
##   that lost a little context is fine, a leaked key is not.
##
## Nothing in this file ever prints, and it is exempted by path from the source scan in
## `tests/suites/test_redaction.gd` for exactly that reason.

## The text every scrubbed secret is replaced with. Asserted on by the suites and greppable in
## logcat (`adb logcat | grep -c '<test key>'` must be 0, `grep -c '\[REDACTED\]'` > 0).
const PLACEHOLDER := "[REDACTED]"

## Masking geometry: keep the scheme-ish head and the last four characters.
const BULLET := "•"
const VISIBLE_PREFIX := 3
const VISIBLE_SUFFIX := 4

## At or below this length nothing is shown at all — a 12-character key has no safe window.
const SHORT_KEY_MAX := 12

## `redacted_detail` is capped at 300 characters (PRD-06 R9 / appendix §1.4).
const SAFE_ERROR_MAX := 300

## Secrets shorter than this are never substituted verbatim: a 3-character "secret" would match
## half the alphabet and destroy the message it is meant to protect.
const MIN_SECRET_LENGTH := 4

## Patterns that are key-shaped even when we were not handed the secret. `[REDACTED]` is written
## with no capture-group backreference on purpose: the query form is handled by
## [method _scrub_key_param], which keeps the parameter name and needs no `$1` support.
const SK_PATTERN := "sk[-_][A-Za-z0-9_-]{8,}"
const GOOGLE_PATTERN := "AIza[0-9A-Za-z_-]{20,}"
const BEARER_PATTERN := "(?i)bearer\\s+[A-Za-z0-9._~+/-]{12,}=*"
const OPAQUE_PATTERN := "[A-Za-z0-9_-]{40,}"
const KEY_PARAM_PATTERN := "(?i)[?&]?key=[^&\\s\"'#]*"


# ------------------------------------------------------------------ display masking (R8)

## `sk-abcdef123456` -> `sk-••••••••3456`. A key of [constant SHORT_KEY_MAX] characters or fewer
## is masked completely; an empty key stays empty so an "unset" field renders as nothing at all.
static func mask_key(key: String) -> String:
	var value := key.strip_edges()
	if value.is_empty():
		return ""
	if value.length() <= SHORT_KEY_MAX:
		return BULLET.repeat(value.length())
	var hidden := value.length() - VISIBLE_PREFIX - VISIBLE_SUFFIX
	return value.substr(0, VISIBLE_PREFIX) + BULLET.repeat(hidden) \
		+ value.substr(value.length() - VISIBLE_SUFFIX)


## True when [param key] is set well enough to be masked rather than shown verbatim.
static func can_mask(key: String) -> bool:
	return key.strip_edges().length() > SHORT_KEY_MAX


# ------------------------------------------------------------------ scrubbing (R8/R9)

## Removes every occurrence of every secret in [param secrets] from [param text], then scrubs
## anything else that is key-shaped. Covers the verbatim secret, its percent-encoded form (the
## Gemini `?key=` shape), the `key=` query value and common provider key prefixes.
static func redact(text: String, secrets: PackedStringArray = PackedStringArray()) -> String:
	if text.is_empty():
		return ""
	var out := text
	for secret in secrets:
		var value := secret.strip_edges()
		if value.length() < MIN_SECRET_LENGTH:
			continue
		out = out.replace(value, PLACEHOLDER)
		var encoded := String.uri_encode(value)
		if encoded != value:
			out = out.replace(encoded, PLACEHOLDER)
	out = _sub(out, SK_PATTERN, PLACEHOLDER)
	out = _sub(out, GOOGLE_PATTERN, PLACEHOLDER)
	out = _sub(out, BEARER_PATTERN, "Bearer " + PLACEHOLDER)
	out = _scrub_key_param(out)
	out = _sub(out, OPAQUE_PATTERN, PLACEHOLDER)
	return out


## The one function every error string must pass through before it is displayed, stored in
## `plan.generation`, toasted or printed. Truncated to [constant SAFE_ERROR_MAX] characters.
static func safe_error(text: String, key: String = "") -> String:
	var secrets := PackedStringArray()
	var value := key.strip_edges()
	if not value.is_empty():
		secrets.append(value)
	var cleaned := redact(text, secrets)
	if cleaned.length() > SAFE_ERROR_MAX:
		return cleaned.substr(0, SAFE_ERROR_MAX)
	return cleaned


## True when [param text] still contains [param key] verbatim or percent-encoded — the check the
## redaction suite runs against every failure branch, and the guard the UI uses before showing a
## provider's own error text.
static func contains_secret(text: String, key: String) -> bool:
	var value := key.strip_edges()
	if value.is_empty() or text.is_empty():
		return false
	if text.contains(value):
		return true
	var encoded := String.uri_encode(value)
	return encoded != value and text.contains(encoded)


## A whole dictionary rendered for a log line with every value scrubbed: used by debug probes so
## a settings dump can never print a key (`llm.api_key` loses its value, keeps its key).
static func scrub_dict(source: Dictionary, secrets: PackedStringArray = PackedStringArray()) -> Dictionary:
	var out: Dictionary = {}
	for field in source:
		var field_name := String(field)
		var value: Variant = source[field]
		if value is Dictionary:
			out[field_name] = scrub_dict(value, secrets)
		elif field_name == "api_key" or field_name.ends_with("_key"):
			out[field_name] = PLACEHOLDER if not String(value).is_empty() else ""
		else:
			out[field_name] = redact(str(value), secrets)
	return out


# ------------------------------------------------------------------ internals

## `RegEx.sub` is used only with literal replacements, so no `$1` backreference semantics are
## relied on anywhere in this file.
static func _sub(text: String, pattern: String, replacement: String) -> String:
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return text
	return re.sub(text, replacement, true)


## `key=<value>` keeps the parameter name and loses the value, so a scrubbed URL still reads like
## the URL a provider returned: `...?key=[REDACTED]`.
static func _scrub_key_param(text: String) -> String:
	var re := RegEx.new()
	if re.compile(KEY_PARAM_PATTERN) != OK:
		return text
	var matches := re.search_all(text)
	if matches.is_empty():
		return text
	var out := ""
	var cursor := 0
	for entry in matches:
		var start := entry.get_start()
		var matched := entry.get_string()
		out += text.substr(cursor, start - cursor)
		var equals := matched.find("=")
		if equals >= 0:
			out += matched.substr(0, equals + 1) + PLACEHOLDER
		else:
			out += PLACEHOLDER
		cursor = entry.get_end()
	return out + text.substr(cursor)
