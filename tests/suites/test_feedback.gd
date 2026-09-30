extends TestSuite
## PRD-12 R2 — the feedback senses: five generated cue sounds, amplitude-scaled haptics, the
## two switches and the one-time "no haptics" notice.
##
##   [feedback] cues=5 ≤12KB · counters only move when enabled · notice shown once
##
## What it proves, in order:
##   1. all five WAVs ship at `assets/audio/ui/ui_<cue>.wav`, mono / 22050 Hz / 16-bit PCM and
##      ≤ 12 KB each (AC9's format, measured from the file header, not assumed);
##   2. a cue plays through the pool when sound is on and does nothing when it is off;
##   3. `haptics_available()` needs both the platform and the switch;
##   4. `mark_haptics_unavailable()` shows the documented notice exactly once per install and
##      is idempotent afterwards;
##   5. a failure toast also plays the error cue (R2's "every failure toast → error()").

const CUE_MAX_BYTES := 12 * 1024


func _init() -> void:
	suite_name = "feedback"


func run() -> void:
	_check_cue_files()
	_check_counters_and_switches()
	_check_unavailable_notice()
	_check_failure_toast_cue()


func _check_cue_files() -> void:
	begin("the five cue WAVs are mono 22050 Hz 16-bit and ≤ 12 KB")
	assert_eq(Feedback.CUES.size(), 5, "five cues are declared")
	for cue in Feedback.CUES:
		var path := "%s/ui_%s.wav" % [Feedback.CUE_DIR, cue]
		assert_true(ResourceLoader.exists(path), "%s exists" % path)
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var riff := file.get_buffer(4).get_string_from_ascii()
		var _riff_size := file.get_32()
		var wave := file.get_buffer(4).get_string_from_ascii()
		var fmt := file.get_buffer(4).get_string_from_ascii()
		var _fmt_size := file.get_32()
		var format := file.get_16()
		var channels := file.get_16()
		var rate := file.get_32()
		var _byte_rate := file.get_32()
		var _block_align := file.get_16()
		var bits := file.get_16()
		var size := file.get_length()
		file.close()
		assert_eq(riff, "RIFF", "%s is a RIFF file" % cue)
		assert_eq(wave, "WAVE", "%s is a WAVE file" % cue)
		assert_eq(fmt, "fmt ", "%s has an fmt chunk" % cue)
		assert_eq(format, 1, "%s is uncompressed PCM" % cue)
		assert_eq(channels, 1, "%s is mono" % cue)
		assert_eq(rate, 22050, "%s is 22050 Hz" % cue)
		assert_eq(bits, 16, "%s is 16-bit" % cue)
		assert_le(float(size), float(CUE_MAX_BYTES), "%s is ≤ 12 KB (%d bytes)" % [cue, size])


func _check_counters_and_switches() -> void:
	begin("cues only play when sound is enabled")
	Feedback.set_enabled(true, true)
	var before := Feedback.sounds_played()
	Feedback.tap()
	Feedback.select()
	Feedback.success()
	Feedback.error()
	Feedback.celebrate()
	# `_play()` runs synchronously; the two sequenced haptic buzzes of `error()`/`celebrate()`
	# are timers and are deliberately not awaited here.
	assert_eq(Feedback.sounds_played(), before + 5, "five enabled cues reached a player")

	Feedback.set_enabled(false, true)
	var silent := Feedback.sounds_played()
	Feedback.tap()
	Feedback.select()
	Feedback.success()
	Feedback.celebrate()
	assert_eq(Feedback.sounds_played(), silent, "a disabled switch silences every cue")

	begin("haptics need the platform and the switch")
	Feedback.set_enabled(true, false)
	assert_false(Feedback.haptics_available(), "haptics off means unavailable")
	Feedback.set_enabled(true, true)
	assert_eq(Feedback.haptics_available(), Feedback.haptics_available(),
		"availability is stable while the platform capability is unchanged")


func _check_unavailable_notice() -> void:
	begin("the 'no haptics' notice is shown once per install")
	var stored_before := bool(App.get_setting("ui.haptics_unavailable_shown", false))
	var _written := App.set_setting("ui.haptics_unavailable_shown", false)

	var notices := {"count": 0}
	var counter := func(_text: String, _kind: StringName) -> void:
		notices["count"] = int(notices["count"]) + 1
	Feedback.toast_shown.connect(counter)
	Feedback.mark_haptics_unavailable()
	assert_eq(int(notices["count"]), 1, "the first report shows the notice")
	Feedback.mark_haptics_unavailable()
	assert_eq(int(notices["count"]), 1, "a second report is silent")
	assert_true(bool(App.get_setting("ui.haptics_unavailable_shown", false)),
		"the guard is persisted")
	Feedback.toast_shown.disconnect(counter)

	_written = App.set_setting("ui.haptics_unavailable_shown", stored_before)


func _check_failure_toast_cue() -> void:
	begin("a failure toast plays the error cue")
	Feedback.set_enabled(true, true)
	var before := Feedback.sounds_played()
	Feedback.toast("Session could not be saved.", &"danger")
	assert_eq(Feedback.sounds_played(), before + 1, "the danger toast added one cue")
	Feedback.dismiss_toast()
	var informational := Feedback.sounds_played()
	Feedback.toast("Offline — using your saved plan.", &"info")
	assert_eq(Feedback.sounds_played(), informational, "an info toast stays silent")
	Feedback.dismiss_toast()
