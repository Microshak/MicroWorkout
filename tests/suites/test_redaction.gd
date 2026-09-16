extends TestSuite
## PRD-06 R8/R9/R14 — the key is masked for display, scrubbed from every user-visible string, and
## provably absent from every failure branch and every logging call in the project.
##
## Three layers, weakest to strongest:
##
## 1. [b]Unit[/b] — `Redact.mask_key` / `redact` / `safe_error` / `contains_secret` do what R14
##    says, including the percent-encoded and `key=` forms.
## 2. [b]End-to-end over the failure paths[/b] — every R9 branch is built with a provider body
##    that *echoes the key back* (real providers do this), and the complete result dictionary is
##    checked for a leak, including via `str()` and `JSON.stringify()`, which is what a careless
##    `print(result)` would emit.
## 3. [b]Static[/b] — a source scan over `res://scripts/**/*.gd` and `res://tools/**/*.py` fails on
##    any line that both logs and names a credential, which is R14's `test_no_key_logging` folded
##    into this suite (the two are the same claim).

## Folders the scan walks. `tools/` is `.gdignore`d for the *importer*, but `DirAccess` still
## lists it at runtime, which the run proves.
const SCAN_ROOTS: PackedStringArray = ["res://scripts", "res://tools"]
## Compared against `String.get_extension()`, which returns "gd" — no dot.
const SCAN_EXTENSIONS: PackedStringArray = ["gd", "py"]
## R14 exempts the redaction implementation by path — it is the one file whose job is to handle
## secrets, and it contains no logging call at all.
const SCAN_EXEMPT: PackedStringArray = ["scripts/core/redact.gd"]
## Lines that match both patterns but log something that is *not* a credential: a glyph kind and a
## colour token. Named explicitly so a new offender cannot hide behind them.
const SCAN_ALLOWED_LINES: PackedStringArray = ["unknown glyph", "unknown token"]

const LOG_CALL_PATTERN := "(print|print_rich|printt|prints|push_error|push_warning|printerr)\\("
const SECRET_TOKEN_PATTERN := "(?i)\\b(api_key|secret|password|token|bearer|authorization|key)\\b"

## The key used throughout: real enough to look like one, obviously fake, and containing
## characters whose percent-encoded form differs from the raw form.
const KEY := "sk-live-ABC123"
const TRICKY_KEY := "sk-live+ABC/123"
const TEST_URL := "https://api.openai.com/v1"


func _init() -> void:
	suite_name = "redaction"


func run() -> void:
	_test_mask_key()
	_test_masking_is_stable()
	_test_redact_forms()
	_test_safe_error()
	_test_contains_secret()
	_test_scrub_dict()
	_test_failure_branches_never_leak()
	_test_request_url_is_scrubbable()
	_test_source_scan()


# ------------------------------------------------------------------ masking (R8/R14)

func _test_mask_key() -> void:
	begin("R14's masking case")
	assert_eq(Redact.mask_key("sk-abcdef123456"), "sk-••••••••3456", "head, eight bullets, tail")
	assert_eq(Redact.mask_key("sk-abcdef123456"), "sk-" + "•".repeat(8) + "3456",
		"the same string, built from its parts")

	begin("short keys are masked completely")
	assert_eq(Redact.mask_key("sk-abc"), "••••••", "a 6-character key shows nothing")
	assert_eq(Redact.mask_key("123456789012"), "•".repeat(12), "12 characters is the boundary")
	assert_eq(Redact.mask_key("1234567890123"), "123" + "•".repeat(6) + "0123",
		"13 characters starts showing a window")
	assert_eq(Redact.mask_key(""), "", "empty stays empty so an unset field renders as nothing")
	assert_eq(Redact.mask_key("   "), "", "whitespace is not a key")
	assert_false(Redact.can_mask("short"), "a short key cannot be masked, only hidden")
	assert_true(Redact.can_mask(KEY), "a real key can")

	begin("a masked key never contains the key")
	for key in [KEY, TRICKY_KEY, "x".repeat(64)]:
		var masked := Redact.mask_key(key)
		assert_false(masked.contains(key), "mask of %s hides it" % key.substr(0, 6))
		assert_false(Redact.contains_secret(masked, key), "contains_secret agrees")
	assert_true(Redact.mask_key(KEY).ends_with("C123"), "the tail is kept for recognition")


func _test_masking_is_stable() -> void:
	begin("masking a mask is a no-op (R14)")
	for key in [KEY, TRICKY_KEY, "12345678901234567890", "sk-abcdef123456"]:
		var once := Redact.mask_key(key)
		assert_eq(Redact.mask_key(once), once, "stable for %s" % key.substr(0, 6))
	assert_eq(Redact.mask_key(Redact.mask_key("")), "", "and for the empty key")


# ------------------------------------------------------------------ scrubbing (R8/R9)

func _test_redact_forms() -> void:
	begin("every occurrence of the secret is replaced")
	assert_eq(Redact.redact("key %s and again %s" % [KEY, KEY], PackedStringArray([KEY])),
		"key [REDACTED] and again [REDACTED]", "both occurrences")
	assert_eq(Redact.redact("HTTP 401 for key %s" % KEY, PackedStringArray([KEY])),
		"HTTP 401 for key [REDACTED]", "the R14 example")
	assert_eq(Redact.redact("nothing to do here", PackedStringArray([KEY])),
		"nothing to do here", "clean text is untouched")
	assert_eq(Redact.redact("", PackedStringArray([KEY])), "", "empty stays empty")

	begin("the percent-encoded form is replaced too (Gemini's ?key=)")
	var encoded := TRICKY_KEY.uri_encode()
	assert_ne(encoded, TRICKY_KEY, "the fixture actually encodes differently")
	var scrubbed := Redact.redact("GET /v1?key=%s" % encoded, PackedStringArray([TRICKY_KEY]))
	assert_false(scrubbed.contains(encoded), "the encoded form is gone")
	assert_false(scrubbed.contains(TRICKY_KEY), "and so is the raw form")
	assert_true(scrubbed.contains("[REDACTED]"), "something was replaced")

	begin("the value after key= is scrubbed even with no secret given")
	var with_param := Redact.redact("POST https://api.example.com/v1?key=sk-live-UNKNOWN-VALUE")
	assert_false(with_param.contains("sk-live-UNKNOWN-VALUE"), "an unknown key is still scrubbed")
	assert_true(with_param.contains("key=[REDACTED]"), "the parameter name survives: %s" % with_param)
	var and_form := Redact.redact("https://x/v1?a=1&key=abc123def456")
	assert_false(and_form.contains("abc123def456"), "the & form too")
	assert_true(and_form.contains("a=1"), "other parameters are untouched")

	begin("key-shaped strings are scrubbed without being told the secret")
	assert_false(Redact.redact("token sk-abcdefghijklmnop").contains("sk-abcdefghijklmnop"),
		"an sk- token")
	assert_false(Redact.redact("Authorization: Bearer abcdefghijklmnop").contains("abcdefghijklmnop"),
		"a bearer token")
	assert_false(Redact.redact("key AIzaSyA1234567890abcdefghijklmnopq").contains(
		"AIzaSyA1234567890abcdefghijklmnopq"), "a Google API key")
	assert_false(Redact.redact("hash %s" % "a1b2c3d4e5".repeat(5)).contains("a1b2c3d4e5".repeat(5)),
		"a long opaque blob")

	begin("a short secret is ignored rather than destroying the message")
	var short := Redact.redact("the key is ab", PackedStringArray(["ab"]))
	assert_eq(short, "the key is ab", "a 2-character secret is not substituted")

	begin("padding around a pasted key is part of the secret")
	assert_false(Redact.redact("bad key '  %s  '" % KEY, PackedStringArray(["  %s  " % KEY]))
		.contains(KEY), "the padded form is replaced as a whole")


func _test_safe_error() -> void:
	begin("R14's safe_error case")
	var cleaned := Redact.safe_error("HTTP 401 for key %s" % KEY, KEY)
	assert_false(cleaned.contains(KEY), "no key survives")
	assert_true(cleaned.contains("[REDACTED]"), "and [REDACTED] appears instead")
	assert_eq(cleaned, "HTTP 401 for key [REDACTED]", "verbatim result")

	begin("safe_error without a secret still scrubs key-shaped text")
	assert_false(Redact.safe_error("Bearer abcdefghijklmnopq").contains("abcdefghijklmnopq"),
		"the bearer pattern applies")
	assert_eq(Redact.safe_error(""), "", "empty in, empty out")

	begin("safe_error truncates to 300 characters (R9)")
	# Prose, not a run of characters: a 40+ character run of `[A-Za-z0-9_-]` is itself
	# key-shaped and is scrubbed to `[REDACTED]` before the length cap applies (by design).
	var long := "provider said no ".repeat(30)
	var truncated := Redact.safe_error(long)
	assert_eq(truncated.length(), Redact.SAFE_ERROR_MAX, "exactly the cap")
	assert_eq(Redact.SAFE_ERROR_MAX, 300, "which R9 pins at 300")
	var short := Redact.safe_error("short")
	assert_eq(short.length(), 5, "shorter text is untouched")
	assert_eq(long.length(), 510, "the fixture really is longer than the cap")
	var long_with_key := Redact.safe_error("%s %s" % [KEY, "more detail ".repeat(40)], KEY)
	assert_eq(long_with_key.length(), Redact.SAFE_ERROR_MAX, "a truncated error is still capped")
	assert_false(long_with_key.contains(KEY), "and still scrubbed")


func _test_contains_secret() -> void:
	begin("contains_secret is the leak detector the other assertions use")
	assert_true(Redact.contains_secret("a %s b" % KEY, KEY), "raw form found")
	assert_true(Redact.contains_secret("a %s b" % TRICKY_KEY.uri_encode(), TRICKY_KEY),
		"encoded form found")
	assert_false(Redact.contains_secret("nothing here", KEY), "clean text")
	assert_false(Redact.contains_secret("", KEY), "empty text")
	assert_false(Redact.contains_secret("a key b", ""), "an empty secret can never leak")
	assert_false(Redact.contains_secret("a key b", "   "), "nor can whitespace")


func _test_scrub_dict() -> void:
	begin("a whole settings dump can be logged safely")
	var dump := {
		"units": "lb",
		"llm": {
			"provider": "deepseek",
			"api_key": KEY,
			"model": "deepseek-chat",
			"base_url": "https://api.deepseek.com/v1",
		},
	}
	var scrubbed := Redact.scrub_dict(dump, PackedStringArray([KEY]))
	assert_false(Redact.contains_secret(str(scrubbed), KEY), "str() of the dump has no key")
	assert_false(Redact.contains_secret(JSON.stringify(scrubbed), KEY), "nor does JSON")
	assert_eq(String((scrubbed["llm"] as Dictionary)["api_key"]), Redact.PLACEHOLDER,
		"api_key is replaced")
	assert_eq(String((scrubbed["llm"] as Dictionary)["provider"]), "deepseek",
		"non-secret fields survive")
	assert_eq(String(scrubbed["units"]), "lb", "and so does the rest of the document")

	begin("an empty api_key stays empty rather than becoming [REDACTED]")
	var empty_dump := Redact.scrub_dict({"llm": {"api_key": ""}})
	assert_eq(String((empty_dump["llm"] as Dictionary)["api_key"]), "",
		"nothing is hidden because nothing is there")


# ------------------------------------------------------------------ R9 failure paths

func _test_failure_branches_never_leak() -> void:
	begin("no R9 failure branch leaks the key, even when the provider echoes it back")
	var codes: PackedStringArray = [
		"no_key", "no_network", "tls", "auth", "forbidden", "bad_path", "rate_limited", "server",
		"timeout", "bad_response", "cancelled",
	]
	for code in codes:
		var status := 401 if code == "auth" else 0
		if code == "server":
			status = 500
		var detail := _provider_body(code)
		var result := LLMProviders.failure_result(code, "openai", TEST_URL, status, 42, detail, KEY)

		# The provider's own words, the message, and the whole dictionary — through str() and
		# JSON, which is exactly what a `print(result)` or a toast would carry.
		assert_false(Redact.contains_secret(String(result["message"]), KEY),
			"%s: message is clean" % code)
		assert_false(Redact.contains_secret(String(result["redacted_detail"]), KEY),
			"%s: redacted_detail is clean" % code)
		assert_false(Redact.contains_secret(str(result), KEY),
			"%s: str(result) is clean" % code)
		assert_false(Redact.contains_secret(JSON.stringify(result), KEY),
			"%s: JSON of the result is clean" % code)
		assert_true(String(result["redacted_detail"]).contains(Redact.PLACEHOLDER),
			"%s: the echoed secret became [REDACTED]" % code)
		# The user-visible copy is still exactly R9's table row.
		assert_eq(String(result["message"]),
			LLMProviders.message_for(code, "openai", TEST_URL, status), "%s: copy" % code)
		assert_eq(bool(result["key_rejected"]), LLMProviders.key_rejected_for(code),
			"%s: key_rejected" % code)

	begin("the no_key branch never contains a key by construction")
	var empty_key := LLMProviders.failure_result("no_key", "openai", TEST_URL, 0, 0, "", "")
	assert_false(Redact.contains_secret(str(empty_key), KEY), "nothing to leak")
	assert_eq(String(empty_key["message"]), "Paste your OpenAI API key first.", "R9's copy")

	begin("the success branch carries no key either")
	var ok_result := LLMProviders.success_result("openai", 123)
	assert_false(Redact.contains_secret(str(ok_result), KEY), "success is clean")
	assert_true(bool(ok_result["ok"]), "and is ok")


## A realistic provider failure body: providers echo the offending key back in the message, in
## the URL they were called with, and sometimes percent-encoded.
func _provider_body(code: String) -> String:
	var body := '{"error":{"message":"invalid api key %s","type":"authentication_error"}}' % KEY
	var url := "https://api.openai.com/v1/chat/completions?key=%s" % KEY
	var encoded := "https://api.openai.com/v1?key=%s" % TRICKY_KEY.uri_encode()
	match code:
		"auth":
			return body
		"forbidden":
			return '{"error":{"message":"forbidden for key %s"}}' % KEY
		"bad_path":
			return "404 for %s" % url
		"rate_limited":
			return '{"error":{"message":"rate limit for %s"}}' % KEY
		"server":
			return "<html>500 for %s</html>" % url
	return "transport failure for %s (%s)" % [url, encoded]


func _test_request_url_is_scrubbable() -> void:
	begin("the one place a key travels in a URL can be scrubbed")
	var gemini := LLMProviders.connection_request("gemini", {
		"provider": "gemini",
		"base_url": "https://generativelanguage.googleapis.com/v1beta",
		"model": "gemini-1.5-flash",
		"api_key": KEY,
	})
	var url := String(gemini["url"])
	assert_true(url.contains("?key=%s" % KEY), "gemini really does put the key in the query")
	assert_false(Redact.contains_secret(Redact.redact(url, PackedStringArray([KEY])), KEY),
		"and redact() removes it")
	var headers: PackedStringArray = gemini["headers"]
	assert_false(", ".join(headers).contains(KEY), "no Authorization header for gemini")
	var openai := LLMProviders.connection_request("openai", {
		"provider": "openai",
		"base_url": "https://api.openai.com/v1",
		"model": "gpt-4o-mini",
		"api_key": KEY,
	})
	assert_false(String(openai["url"]).contains(KEY), "openai never puts the key in the URL")
	assert_true(", ".join(openai["headers"] as PackedStringArray).contains(KEY),
		"but it is in the header, which is why no header may ever be logged")


# ------------------------------------------------------------------ source scan (R14)

func _test_source_scan() -> void:
	begin("no logging call in the project mentions a credential (R14)")
	var log_re := RegEx.new()
	var secret_re := RegEx.new()
	assert_eq(log_re.compile(LOG_CALL_PATTERN), OK, "the log pattern compiles")
	assert_eq(secret_re.compile(SECRET_TOKEN_PATTERN), OK, "the secret pattern compiles")

	var files := 0
	var violations := PackedStringArray()
	for root in SCAN_ROOTS:
		files += _scan_dir(root, log_re, secret_re, violations)

	print("[redaction] scanned %d source file(s), %d violation(s)" % [files, violations.size()])
	# The scan is only meaningful if it actually walked the tree.
	assert_gt(float(files), 30.0, "the scan found the project's sources")
	assert_eq(violations.size(), 0, "violations: %s" % ", ".join(violations))

	begin("the scan would catch a real offender")
	var offender := 'print("key=%s" % api_key)'
	assert_true(log_re.search(offender) != null and secret_re.search(offender) != null,
		"a print of a key matches both patterns")
	assert_true(log_re.search("print(\"hello\")") != null
		and secret_re.search("print(\"hello\")") == null, "a plain print does not")
	assert_true(secret_re.search("settings_keys=%d") == null,
		"'settings_keys' is not the word 'key'")
	assert_true(secret_re.search("var key := icon.kind") != null,
		"a bare 'key' identifier is matched (and allowed by SCAN_ALLOWED_LINES where justified)")


## Walks [param path] recursively, returning the number of scannable files and appending any
## `path:line` that both logs and names a credential.
func _scan_dir(path: String, log_re: RegEx, secret_re: RegEx,
		violations: PackedStringArray) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	var count := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := "%s/%s" % [path, entry]
		if dir.current_is_dir():
			count += _scan_dir(child, log_re, secret_re, violations)
		elif SCAN_EXTENSIONS.has(child.get_extension().to_lower()) \
				and not _is_exempt(child):
			count += 1
			_scan_file(child, log_re, secret_re, violations)
		entry = dir.get_next()
	dir.list_dir_end()
	return count


func _is_exempt(path: String) -> bool:
	for exempt in SCAN_EXEMPT:
		if path.ends_with(exempt):
			return true
	return false


func _scan_file(path: String, log_re: RegEx, secret_re: RegEx,
		violations: PackedStringArray) -> void:
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		violations.append("%s: cannot open" % path)
		return
	var number := 0
	while not file.eof_reached():
		var line := file.get_line()
		number += 1
		if log_re.search(line) == null or secret_re.search(line) == null:
			continue
		var allowed := false
		for allowance in SCAN_ALLOWED_LINES:
			if line.contains(allowance):
				allowed = true
		if not allowed:
			violations.append("%s:%d: %s" % [path, number, line.strip_edges()])
	file.close()
