class_name Format
extends RefCounted
## Human-readable numbers for the parts of the UI that are not weights or lengths — PRD-06 R11.
##
## Weights and lengths live in [Units] and nowhere else; this file owns byte counts, relative
## timestamps and the storage line the Settings tab renders. Like [Units] it is pure, static and
## deterministic (no locale-aware formatting: an Android device with a comma decimal separator
## must still read `41.2 KB`).

const KB := 1024
const MB := 1048576
const MINUTE := 60
const HOUR := 3600
const DAY := 86400


## `"0 B"`, `"512 B"`, `"41.2 KB"`, `"7.7 MB"` — 1024-based (R11).
static func bytes(n: int) -> String:
	if n <= 0:
		return "0 B"
	if n < KB:
		return "%d B" % n
	if n < MB:
		return "%.1f KB" % (float(n) / float(KB))
	return "%.1f MB" % (float(n) / float(MB))


## Relative age of a stored UTC ISO-8601 timestamp (R11): `"never"` for an absent or malformed
## value, then `"just now"`, `"12 min ago"`, `"3 h ago"`, `"3 days ago"`.
static func relative_time(iso: String) -> String:
	var stamp := iso.strip_edges()
	if stamp.is_empty() or not Dates.is_valid_iso_datetime(stamp):
		return "never"
	var seconds := int(Time.get_unix_time_from_system()) - Dates.epoch_seconds(stamp)
	if seconds < 0:
		# A stamp in the future is clock skew, not a time traveller: show it as "now".
		seconds = 0
	if seconds < MINUTE:
		return "just now"
	if seconds < HOUR:
		return "%d min ago" % _idiv(seconds, MINUTE)
	if seconds < DAY:
		return "%d h ago" % _idiv(seconds, HOUR)
	var days := _idiv(seconds, DAY)
	return "1 day ago" if days == 1 else "%d days ago" % days


## The whole `Sections/Storage` line: `Storage: 41.2 KB used (settings.json 2.1 KB ·
## plans.json 31.4 KB · history.json 7.7 KB · backups 0 B)` (R10 order 7 / R11).
static func storage_line(usage_bytes: int, breakdown: Dictionary) -> String:
	return "Storage: %s used (%s)" % [bytes(usage_bytes), storage_parts(breakdown)]


## The parenthesised part of [method storage_line], on its own so a narrow layout can wrap it.
static func storage_parts(breakdown: Dictionary) -> String:
	var parts := PackedStringArray()
	for doc_name in ["settings.json", "plans.json", "history.json", "backups"]:
		var key := doc_name.trim_suffix(".json")
		parts.append("%s %s" % [doc_name, bytes(_as_int(breakdown.get(key, 0)))])
	return " · ".join(parts)


## `GB`-free integer division without tripping GDScript's `integer_division` warning.
static func _idiv(a: int, b: int) -> int:
	if b == 0:
		return 0
	return int(floor(float(a) / float(b)))


## JSON has no integer type, so a byte count read back from a document arrives as a float.
static func _as_int(value: Variant) -> int:
	if value is int:
		return int(value)
	if value is float:
		return int(value)
	return 0
