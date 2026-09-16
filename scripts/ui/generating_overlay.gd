extends CanvasLayer
## PRD-07 R9 — the non-blocking, cancellable "Generating…" state.
##
## [b]Contract (appendix §3.2).[/b] Signals `cancel_requested` and `finished(result: Dictionary)`;
## API `start(message := "Generating…")`, `set_attempt(n, total)`, `stop()`. PRD-08 embeds it in
## the wizard and awaits `LLM.generate_plan()` itself; this component only *renders* the wait,
## forwards the cancel, and reports the result.
##
## [b]Non-blocking, by construction.[/b] The root `Control` is `mouse_filter = IGNORE` and there
## is no scrim, so a touch outside the card reaches the screen underneath and the wizard stays
## scrollable for the whole R7 window (up to 139 s). Only the `Card` stops input, which is what
## makes `Cancel` reachable without freezing everything else.
##
## [b]Why the source banner is a `status_chip` and not a coloured label.[/b] R9 asks for a
## "success colour" / "warning colour" banner. The generated theme has no success/warning *label*
## variation, `theme_override_colors` is banned (appendix §4.3 rule 8) and colour-only state is
## banned as well (rule 6). PRD-06's `status_chip` is this codebase's answer — a glyph *and* a
## word — so `Written by <P>` renders as `verified` (check) and `Built on-device` as
## `unreachable` (alert), exactly like every other status in the app.
##
## [b]Autoloads are looked up, never referenced by identifier.[/b] Same reason as
## `scripts/autoload/llm.gd`: an autoload name only resolves once its node exists in the tree, and
## a component that cannot be instantiated outside a running app could not be tested.

## R9's default message, and the copy shown while a cancel is in flight.
const DEFAULT_MESSAGE := "Generating…"
const CANCELLING_MESSAGE := "Cancelling…"
## The `Fix in Settings` button appears for these reason codes (R6's key failures).
const FIXABLE_REASONS: PackedStringArray = ["auth", "forbidden", "no_key", "bad_path"]
## How long the result banner stays up before the overlay hides itself; `stop()` may be called
## sooner by the parent.
const RESULT_HOLD_SEC := 2.6
## Settings is tab index 3 (appendix §2), and this button only ever navigates there.
const SETTINGS_TAB_INDEX := 3

## Emitted when the user taps Cancel; [method stop] is deliberately *not* called here, because the
## cancel is not final until `LLM` answers (R6 step 9).
signal cancel_requested
## Emitted once per generation, after the result has been rendered.
signal finished(result: Dictionary)

var _provider_label: String = ""
var _attempt: int = 0
var _total: int = 0
var _busy: bool = false


func _ready() -> void:
	visible = false
	var llm := _autoload(&"LLM")
	if llm != null:
		if not llm.is_connected(&"generation_finished", _on_generation_finished):
			llm.connect(&"generation_finished", _on_generation_finished)
		if not llm.is_connected(&"generation_progress", _on_generation_progress):
			llm.connect(&"generation_progress", _on_generation_progress)
	var cancel := cancel_button()
	if cancel != null:
		cancel.pressed.connect(_on_cancel_pressed)
	var fix := fix_button()
	if fix != null:
		fix.pressed.connect(_on_fix_pressed)
	var timer := result_timer()
	if timer != null:
		timer.timeout.connect(stop)
	# The spinner is a `progress_ring`: blank its automatic "0%" caption (appendix §3.1).
	var spinner := spinner_node()
	if spinner != null and spinner.has_method(&"set_caption_value"):
		spinner.call(&"set_caption_value", "")


# ------------------------------------------------------------------ R9 API

## Shows the overlay with [param message]. Calling it again simply restarts the card, so a caller
## cannot stack two overlays.
func start(message: String = DEFAULT_MESSAGE) -> void:
	_busy = true
	_attempt = 0
	_total = 0
	visible = true
	set_message(message)
	set_sub_text("")
	show_banner(false, &"dot", "")
	set_cancel_enabled(true)
	var timer := result_timer()
	if timer != null:
		timer.stop()


## `Attempt 2 of 3` (R9). Ignored before [method start] or after the result has arrived.
func set_attempt(n: int, total: int) -> void:
	if not _busy:
		return
	_attempt = n
	_total = total
	if _provider_label.is_empty():
		set_sub_text("Attempt %d of %d" % [n, total])
	else:
		set_sub_text("Talking to %s… — attempt %d of %d" % [_provider_label, n, total])


## `Talking to DeepSeek…` — R9's other sub-label. The label comes from the provider preset, so it
## is never a key.
func set_provider(label: String) -> void:
	_provider_label = label
	if _attempt > 0 and _total > 0:
		set_attempt(_attempt, _total)
	elif not label.is_empty():
		set_sub_text("Talking to %s…" % label)


## Shows whether the card is currently tracking a generation.
func is_generating() -> bool:
	return _busy


## Hides the overlay and clears every field, so the next [method start] begins clean.
func stop() -> void:
	_busy = false
	visible = false
	set_message(DEFAULT_MESSAGE)
	set_sub_text("")
	show_banner(false, &"dot", "")
	set_cancel_enabled(true)
	var timer := result_timer()
	if timer != null:
		timer.stop()


# ------------------------------------------------------------------ behaviour

func _on_cancel_pressed() -> void:
	if not _busy:
		return
	cancel_requested.emit()
	set_message(CANCELLING_MESSAGE)
	set_cancel_enabled(false)
	var llm := _autoload(&"LLM")
	if llm != null and llm.has_method(&"cancel"):
		llm.call(&"cancel")


func _on_fix_pressed() -> void:
	var nav := _autoload(&"Nav")
	if nav != null and nav.has_method(&"goto_tab"):
		nav.call(&"goto_tab", SETTINGS_TAB_INDEX)
	stop()


func _on_generation_progress(attempt: int, total: int) -> void:
	set_attempt(attempt, total)


## `LLM.generation_finished`: render the outcome, then hand it to the parent. The user message is
## R6's own copy, so this component never composes a sentence about a failure.
func _on_generation_finished(result: Dictionary) -> void:
	if not _busy:
		return
	_busy = false
	var source := String(result.get("source", ""))
	var reason := String(result.get("reason_code", ""))
	if reason == "cancelled":
		# Nothing was saved and there is nothing to show: R6's copy is the parent's to display.
		stop()
		finished.emit(result)
		return
	if source == "llm":
		show_banner(true, &"verified", "Written by %s" % _label_for(result))
	elif source == "builtin":
		show_banner(true, &"unreachable", "Built on-device")
	else:
		show_banner(false, &"dot", "")
	set_message(String(result.get("user_message", "")))
	set_sub_text("")
	set_cancel_enabled(false)
	set_fix_visible(source == "builtin" and FIXABLE_REASONS.has(reason))
	var timer := result_timer()
	if timer != null:
		timer.start(RESULT_HOLD_SEC)
	finished.emit(result)


## `<P>` for the banner: the plan's provider key resolved through the preset table, so a raw
## settings value can never reach a label.
func _label_for(result: Dictionary) -> String:
	var plan: Variant = result.get("plan", {})
	if plan is Dictionary and not (plan as Dictionary).is_empty():
		var provider := String((plan as Dictionary).get("provider", ""))
		if not provider.is_empty():
			return LLMProviders.label_for(provider)
	if not _provider_label.is_empty():
		return _provider_label
	return "your AI provider"


# ------------------------------------------------------------------ node access

func card() -> Control:
	return get_node_or_null(^"Root/Gutter/Card") as Control


func spinner_node() -> Control:
	return get_node_or_null(^"Root/Gutter/Card/Body/Spinner") as Control


func message_label() -> Label:
	return get_node_or_null(^"Root/Gutter/Card/Body/MessageLabel") as Label


func sub_label() -> Label:
	return get_node_or_null(^"Root/Gutter/Card/Body/SubLabel") as Label


func banner() -> Control:
	return get_node_or_null(^"Root/Gutter/Card/Body/SourceBanner") as Control


func cancel_button() -> Button:
	return get_node_or_null(^"Root/Gutter/Card/Body/CancelButton") as Button


func fix_button() -> Button:
	return get_node_or_null(^"Root/Gutter/Card/Body/FixButton") as Button


func result_timer() -> Timer:
	return get_node_or_null(^"ResultTimer") as Timer


func set_message(text: String) -> void:
	var label := message_label()
	if label != null:
		label.text = text


func set_sub_text(text: String) -> void:
	var label := sub_label()
	if label != null:
		label.text = text
		label.visible = not text.is_empty()


func set_cancel_enabled(enabled: bool) -> void:
	var button := cancel_button()
	if button != null:
		button.disabled = not enabled


func set_fix_visible(shown: bool) -> void:
	var button := fix_button()
	if button != null:
		button.visible = shown


func show_banner(shown: bool, state: StringName, text: String) -> void:
	var chip := banner()
	if chip == null:
		return
	chip.visible = shown
	if shown and chip.has_method(&"set_status"):
		chip.call(&"set_status", state, text)
	if not shown:
		set_fix_visible(false)


## An autoload by name, or `null` — see the file header.
func _autoload(singleton_name: StringName) -> Node:
	if not is_inside_tree():
		return null
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(String(singleton_name)))
