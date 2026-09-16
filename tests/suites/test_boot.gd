extends TestSuite
## Suite 1 — sanity of the foundation itself.
##
## If this suite cannot run, nothing else in the project can be trusted.


func _init() -> void:
	suite_name = "boot"


func run() -> void:
	begin("app identity is present")
	assert_eq(AppInfo.NAME, "MicroWorkout", "launcher name is fixed by the owner")
	assert_true(not AppInfo.PACKAGE_ID.is_empty(), "package id must be set")
	assert_true(not AppInfo.PACKAGE_ID_DEBUG.is_empty(), "debug package id must be set")
	assert_ne(AppInfo.PACKAGE_ID, AppInfo.PACKAGE_ID_DEBUG,
		"debug and release packages must differ so both can be installed side by side")

	begin("version is semantic")
	var semver := RegEx.new()
	semver.compile("^\\d+\\.\\d+\\.\\d+$")
	assert_true(semver.search(AppInfo.VERSION) != null,
		"VERSION must be MAJOR.MINOR.PATCH, got '%s'" % AppInfo.VERSION)
	assert_gt(float(AppInfo.VERSION_CODE), 0.0, "version code must be positive")

	begin("design resolution is portrait")
	assert_gt(float(AppInfo.DESIGN_HEIGHT), float(AppInfo.DESIGN_WIDTH),
		"the app is portrait-only, so height must exceed width")
