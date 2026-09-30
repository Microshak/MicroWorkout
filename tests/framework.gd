class_name TestSuite
extends RefCounted
## Minimal headless test framework.
##
## Design notes (important for every later PRD):
## - Suites are plain [RefCounted] classes. Pure-logic suites must NOT depend on autoload
##   singletons or on a live scene tree — master plan §13 puts pure logic in `scripts/core/`
##   exactly so it can run standalone.
## - The runners (`tests/run_tests.gd`, `tests/run_suite.gd`) execute suites from a **deferred
##   call**, once the SceneTree is live: during `SceneTree._initialize()` the root is not yet
##   inside the tree and a node added there never gets `_ready` (measured). This is what lets
##   PRD-11's `test_tracker_screen.gd` instantiate a screen — and its `_ready` — for real.
## - Subclasses set [member suite_name] and override [method run].

var suite_name: String = "unnamed"
var total_assertions: int = 0
var failures: PackedStringArray = []

var _current_test: String = ""


## Starts a named test. Every assertion after this is attributed to it.
func begin(test_name: String) -> void:
	_current_test = test_name


## Override in subclasses.
func run() -> void:
	pass


func assert_true(value: bool, message: String = "") -> void:
	total_assertions += 1
	if not value:
		_fail("expected true but got false. %s" % message)


func assert_false(value: bool, message: String = "") -> void:
	total_assertions += 1
	if value:
		_fail("expected false but got true. %s" % message)


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	total_assertions += 1
	if actual != expected:
		_fail("expected <%s> but got <%s>. %s" % [str(expected), str(actual), message])


func assert_ne(actual: Variant, unexpected: Variant, message: String = "") -> void:
	total_assertions += 1
	if actual == unexpected:
		_fail("expected value different from <%s>. %s" % [str(unexpected), message])


func assert_close(actual: float, expected: float, tolerance: float = 0.0001, message: String = "") -> void:
	total_assertions += 1
	if absf(actual - expected) > tolerance:
		_fail("expected %f ±%f but got %f. %s" % [expected, tolerance, actual, message])


func assert_gt(actual: float, threshold: float, message: String = "") -> void:
	total_assertions += 1
	if not (actual > threshold):
		_fail("expected > %f but got %f. %s" % [threshold, actual, message])


func assert_ge(actual: float, threshold: float, message: String = "") -> void:
	total_assertions += 1
	if not (actual >= threshold):
		_fail("expected >= %f but got %f. %s" % [threshold, actual, message])


func assert_le(actual: float, threshold: float, message: String = "") -> void:
	total_assertions += 1
	if not (actual <= threshold):
		_fail("expected <= %f but got %f. %s" % [threshold, actual, message])


func assert_has_key(dictionary: Dictionary, key: String, message: String = "") -> void:
	total_assertions += 1
	if not dictionary.has(key):
		_fail("missing key <%s>. %s" % [key, message])


func assert_empty(value: Variant, message: String = "") -> void:
	total_assertions += 1
	var size := 0
	if value is Array or value is PackedStringArray:
		size = value.size()
	elif value is Dictionary:
		size = value.size()
	elif value is String:
		size = value.length()
	if size != 0:
		_fail("expected empty but had %d entries. %s" % [size, message])


func assert_not_empty(value: Variant, message: String = "") -> void:
	total_assertions += 1
	var size := 0
	if value is Array or value is PackedStringArray:
		size = value.size()
	elif value is Dictionary:
		size = value.size()
	elif value is String:
		size = value.length()
	if size == 0:
		_fail("expected non-empty. %s" % message)


func _fail(message: String) -> void:
	var where := _current_test if not _current_test.is_empty() else "<no test>"
	failures.append("%s :: %s" % [where, message])
