extends TestSuite
## PRD-02 R17 — portrait layout classification and the size helpers it drives.


func _init() -> void:
	suite_name = "layout_util"


func run() -> void:
	begin("classify() boundaries")
	assert_eq(LayoutUtil.classify(1799.0), LayoutUtil.Class.SHORT, "1799 is SHORT")
	assert_eq(LayoutUtil.classify(1800.0), LayoutUtil.Class.SHORT, "1800 is still SHORT")
	assert_eq(LayoutUtil.classify(1999.0), LayoutUtil.Class.SHORT, "1999 is SHORT")
	assert_eq(LayoutUtil.classify(2000.0), LayoutUtil.Class.NORMAL, "2000 is NORMAL")
	assert_eq(LayoutUtil.classify(2199.0), LayoutUtil.Class.NORMAL, "2199 is NORMAL")
	assert_eq(LayoutUtil.classify(2200.0), LayoutUtil.Class.TALL, "2200 is TALL")
	assert_eq(LayoutUtil.classify(2400.0), LayoutUtil.Class.TALL, "2400 is TALL")

	begin("real device geometries classify as expected")
	# The emulator reports a 2205-tall app viewport (1080x2400 minus system bars).
	assert_eq(LayoutUtil.classify(2205.0), LayoutUtil.Class.TALL,
		"the Pixel 8 test device is TALL")
	# At exactly the design canvas there is no vertical slack at all
	# (extra_height(1920) == 0), so the spec's thresholds put it in the compact class.
	assert_eq(LayoutUtil.classify(1920.0), LayoutUtil.Class.SHORT,
		"the 1080x1920 design canvas has no slack and is classified SHORT")
	assert_true(LayoutUtil.extra_height(1920.0) == 0.0,
		"which is consistent with there being zero extra height to absorb")

	begin("extra_height()")
	assert_close(LayoutUtil.extra_height(1920.0), 0.0, 0.001, "design height has no slack")
	assert_close(LayoutUtil.extra_height(1600.0), 0.0, 0.001,
		"a short screen never yields negative slack")
	assert_close(LayoutUtil.extra_height(2400.0), 480.0, 0.001, "tall screens expose the slack")

	begin("section spacing is ordered short < normal < tall")
	assert_true(LayoutUtil.section_spacing(LayoutUtil.Class.SHORT)
		< LayoutUtil.section_spacing(LayoutUtil.Class.NORMAL), "short < normal")
	assert_true(LayoutUtil.section_spacing(LayoutUtil.Class.NORMAL)
		< LayoutUtil.section_spacing(LayoutUtil.Class.TALL), "normal < tall")

	begin("hero ring sizes match the PRD")
	assert_eq(LayoutUtil.hero_ring_size(LayoutUtil.Class.SHORT), 240, "short hero ring")
	assert_eq(LayoutUtil.hero_ring_size(LayoutUtil.Class.NORMAL), 320, "normal hero ring")
	assert_eq(LayoutUtil.hero_ring_size(LayoutUtil.Class.TALL), 360, "tall hero ring")

	begin("card heights are ordered and positive")
	assert_eq(LayoutUtil.card_min_height(LayoutUtil.Class.SHORT), 96, "short card height")
	assert_eq(LayoutUtil.card_min_height(LayoutUtil.Class.NORMAL), 112, "normal card height")
	assert_eq(LayoutUtil.card_min_height(LayoutUtil.Class.TALL), 128, "tall card height")
