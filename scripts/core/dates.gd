class_name Dates
extends RefCounted
## Pure civil-date, ISO-8601 and ISO-week helpers — PRD-03 R12 / R14.
##
## Every function here is static and reads nothing but its arguments, so the whole date
## layer is unit-testable headless (master plan §13: pure logic lives in scripts/core/).
##
## All day arithmetic runs on the *civil* date through Howard Hinnant's
## `days_from_civil()` / `civil_from_days()` pair and never through
## `Time.get_unix_time_from_datetime_string()`, so no timezone or DST transition can ever
## shift a workout onto the wrong day. The only calls into `Time` are the two clock reads
## (`today_iso`, `now_iso8601`), which is exactly where "what day is it for this user"
## has to be answered.
##
## Invalid input returns the neutral value ("", 0, {}) and pushes exactly one warning —
## never an error — so a malformed value in a stored document can never crash the app.

const SECONDS_PER_DAY := 86400
const SECONDS_PER_HOUR := 3600

## Abbreviations used by [method format_long]; index 0 is Monday (ISO).
const WEEKDAY_ABBREV: PackedStringArray = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
const MONTH_ABBREV: PackedStringArray = [
	"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

## Days elapsed per month in a non-leap year.
const MONTH_LENGTHS: PackedInt32Array = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]


# ------------------------------------------------------------------ clock reads

## The user's local calendar day ("YYYY-MM-DD"), or today's UTC day when [param utc] is true.
static func today_iso(utc: bool = false) -> String:
	return Time.get_date_string_from_system(utc)


## An ISO-8601 timestamp. UTC ("…Z") by default — the format every stored timestamp uses.
static func now_iso8601(utc: bool = true) -> String:
	return Time.get_datetime_string_from_system(utc, false) + "Z"


# ------------------------------------------------------------------ parsing

## Strict `YYYY-MM-DD` plus a real-calendar check (2026-02-30 is invalid, 2024-02-29 is not).
static func is_valid_iso_date(iso: String) -> bool:
	return not parse_iso_date(iso).is_empty()


## `{"y": int, "m": int, "d": int}` or `{}` when [param iso] is not a real date.
static func parse_iso_date(iso: String) -> Dictionary:
	if iso.length() != 10 or iso[4] != "-" or iso[7] != "-":
		return {}
	if not _is_digits(iso.substr(0, 4)) or not _is_digits(iso.substr(5, 2)) \
			or not _is_digits(iso.substr(8, 2)):
		return {}
	var y := int(iso.substr(0, 4))
	var m := int(iso.substr(5, 2))
	var d := int(iso.substr(8, 2))
	if m < 1 or m > 12 or d < 1 or d > days_in_month(y, m):
		return {}
	return {"y": y, "m": m, "d": d}


## `{"y","m","d","h","mi","s"}` for `YYYY-MM-DDTHH:MM:SS[Z]`, or `{}` when malformed.
## A date-only string parses as midnight, so callers never have to branch on the shape.
static func parse_iso_datetime(iso: String) -> Dictionary:
	var base := parse_iso_date(iso.substr(0, 10))
	if base.is_empty():
		return {}
	if iso.length() == 10:
		return {"y": base["y"], "m": base["m"], "d": base["d"], "h": 0, "mi": 0, "s": 0}
	if iso.length() < 19 or (iso[10] != "T" and iso[10] != " "):
		return {}
	if iso[13] != ":" or iso[16] != ":":
		return {}
	if not _is_digits(iso.substr(11, 2)) or not _is_digits(iso.substr(14, 2)) \
			or not _is_digits(iso.substr(17, 2)):
		return {}
	var h := int(iso.substr(11, 2))
	var mi := int(iso.substr(14, 2))
	var sec := int(iso.substr(17, 2))
	if h > 23 or mi > 59 or sec > 59:
		return {}
	return {"y": base["y"], "m": base["m"], "d": base["d"], "h": h, "mi": mi, "s": sec}


static func is_valid_iso_datetime(iso: String) -> bool:
	return not parse_iso_datetime(iso).is_empty()


# ------------------------------------------------------------------ civil calendar

## Days since 1970-01-01 (Howard Hinnant). `days_from_civil(1970, 1, 1) == 0`.
static func days_from_civil(y: int, m: int, d: int) -> int:
	var yy := y - (1 if m <= 2 else 0)
	var era := _idiv(yy, 400)
	var yoe := yy - era * 400
	var mp := (m + 9) % 12
	var doy := _idiv(153 * mp + 2, 5) + d - 1
	var doe := yoe * 365 + _idiv(yoe, 4) - _idiv(yoe, 100) + doy
	return era * 146097 + doe - 719468


## Inverse of [method days_from_civil] — `{"y","m","d"}`.
static func civil_from_days(z: int) -> Dictionary:
	var zz := z + 719468
	var era := _idiv(zz, 146097)
	var doe := zz - era * 146097
	var yoe := _idiv(doe - _idiv(doe, 1460) + _idiv(doe, 36524) - _idiv(doe, 146096), 365)
	var y := yoe + era * 400
	var doy := doe - (365 * yoe + _idiv(yoe, 4) - _idiv(yoe, 100))
	var mp := _idiv(5 * doy + 2, 153)
	var d := doy - _idiv(153 * mp + 2, 5) + 1
	var m := mp + (3 if mp < 10 else -9)
	y += (1 if m <= 2 else 0)
	return {"y": y, "m": m, "d": d}


## `YYYY-MM-DD` for a day count produced by [method days_from_civil].
static func date_from_days(z: int) -> String:
	var c := civil_from_days(z)
	return "%04d-%02d-%02d" % [int(c["y"]), int(c["m"]), int(c["d"])]


static func days_in_month(y: int, m: int) -> int:
	if m < 1 or m > 12:
		return 0
	if m == 2 and is_leap_year(y):
		return 29
	return MONTH_LENGTHS[m - 1]


static func is_leap_year(y: int) -> bool:
	return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0


## [param iso] shifted by [param delta] days. `""` for invalid input.
static func add_days(iso: String, delta: int) -> String:
	var p := parse_iso_date(iso)
	if p.is_empty():
		_warn_invalid("add_days", iso)
		return ""
	return date_from_days(days_from_civil(int(p["y"]), int(p["m"]), int(p["d"])) + delta)


## `a - b` in whole days. `0` for invalid input.
static func day_diff(a: String, b: String) -> int:
	if not is_valid_iso_date(a) or not is_valid_iso_date(b):
		_warn_invalid("day_diff", "%s/%s" % [a, b])
		return 0
	return _day_number(a) - _day_number(b)


## 0 = Monday … 6 = Sunday. `0` for invalid input.
static func weekday_index(iso: String) -> int:
	if not is_valid_iso_date(iso):
		_warn_invalid("weekday_index", iso)
		return 0
	# 1970-01-01 was a Thursday, which is index 3 in the Monday-based week.
	return ((_day_number(iso) + 3) % 7 + 7) % 7


# ------------------------------------------------------------------ ISO weeks (R14)

static func is_valid_iso_week_id(week_id: String) -> bool:
	return week_id.length() == 8 and week_id[4] == "-" and week_id[5] == "W" \
		and _is_digits(week_id.substr(0, 4)) and _is_digits(week_id.substr(6, 2)) \
		and int(week_id.substr(6, 2)) >= 1 and int(week_id.substr(6, 2)) <= 53


## `"2026-W38"` — the Thursday of [param iso]'s week defines the ISO week-year.
static func iso_week_id(iso: String) -> String:
	if not is_valid_iso_date(iso):
		_warn_invalid("iso_week_id", iso)
		return ""
	var thu := add_days(iso, 3 - weekday_index(iso))
	var p := parse_iso_date(thu)
	var py := int(p["y"])
	var doy := days_from_civil(py, int(p["m"]), int(p["d"])) - days_from_civil(py, 1, 1) + 1
	return "%04d-W%02d" % [py, _idiv(doy - 1, 7) + 1]


## The Monday that starts [param iso]'s ISO week.
static func iso_week_start(iso: String) -> String:
	if not is_valid_iso_date(iso):
		_warn_invalid("iso_week_start", iso)
		return ""
	return add_days(iso, -weekday_index(iso))


## The Monday that starts ISO week [param week_id], or `""` when malformed.
static func week_id_start(week_id: String) -> String:
	if not is_valid_iso_week_id(week_id):
		_warn_invalid("week_id_start", week_id)
		return ""
	var y := int(week_id.substr(0, 4))
	var w := int(week_id.substr(6, 2))
	# January 4th is always in ISO week 1, so its Monday is the anchor for the year.
	return add_days(iso_week_start("%04d-01-04" % y), (w - 1) * 7)


## The seven dates of [param iso]'s ISO week, Monday → Sunday.
static func iso_week_days(iso: String) -> PackedStringArray:
	var monday := iso_week_start(iso)
	var out := PackedStringArray()
	if monday.is_empty():
		return out
	for i in 7:
		out.append(add_days(monday, i))
	return out


# ------------------------------------------------------------------ formatting

## `"Tue, Sep 15"`.
static func format_long(iso: String) -> String:
	var p := parse_iso_date(iso)
	if p.is_empty():
		_warn_invalid("format_long", iso)
		return ""
	return "%s, %s %d" % [
		WEEKDAY_ABBREV[weekday_index(iso)], MONTH_ABBREV[int(p["m"]) - 1], int(p["d"])]


## `"40:30"` under an hour, `"1:05:00"` above it. Negative input clamps to `"0:00"`.
static func format_clock(seconds: int) -> String:
	var total := maxi(seconds, 0)
	var h := _idiv(total, 3600)
	var m := _idiv(total % 3600, 60)
	var s := total % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s]
	return "%d:%02d" % [m, s]


## `"Today"` / `"Yesterday"` / [method format_long] relative to [param today].
static func relative_day_label(iso: String, today: String) -> String:
	if is_valid_iso_date(today) and iso == today:
		return "Today"
	if is_valid_iso_date(today) and is_valid_iso_date(iso) and day_diff(today, iso) == 1:
		return "Yesterday"
	return format_long(iso)


# ------------------------------------------------------------------ timestamps

## UTC epoch seconds for a date or an ISO-8601 timestamp — timezone-free civil math.
static func epoch_seconds(iso: String) -> int:
	var p := parse_iso_datetime(iso)
	if p.is_empty():
		_warn_invalid("epoch_seconds", iso)
		return 0
	return days_from_civil(int(p["y"]), int(p["m"]), int(p["d"])) * SECONDS_PER_DAY \
		+ int(p["h"]) * 3600 + int(p["mi"]) * 60 + int(p["s"])


## `a - b` in seconds, for dates (midnight) and full timestamps alike. `0` when invalid.
static func seconds_between_iso(a: String, b: String) -> int:
	if not is_valid_iso_datetime(a) or not is_valid_iso_datetime(b):
		_warn_invalid("seconds_between_iso", "%s/%s" % [a, b])
		return 0
	return epoch_seconds(a) - epoch_seconds(b)


# ------------------------------------------------------------------ internals

static func _day_number(iso: String) -> int:
	var p := parse_iso_date(iso)
	return days_from_civil(int(p["y"]), int(p["m"]), int(p["d"]))


static func _is_digits(s: String) -> bool:
	if s.is_empty():
		return false
	for i in s.length():
		var c := s[i]
		if c < "0" or c > "9":
			return false
	return true


## Integer division for the civil-calendar formulas above.
##
## Written with an explicit float division because GDScript emits an
## `integer_division` warning for `int / int` at every call site, and this project treats
## that warning as a build failure. `floori()` also gives Hinnant's formulas the *floor*
## semantics they require (GDScript's `/` truncates towards zero), and doubles represent
## every value used here exactly.
static func _idiv(a: int, b: int) -> int:
	if b == 0:
		return 0
	return floori(float(a) / float(b))


static func _warn_invalid(fn: String, value: String) -> void:
	push_warning("[dates] %s: invalid input '%s'" % [fn, value])
