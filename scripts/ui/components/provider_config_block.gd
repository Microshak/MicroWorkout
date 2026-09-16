class_name ProviderConfigBlock
extends VBoxContainer
## The AI-provider block: pick a preset, edit the fields that preset allows, test the key, save
## it — PRD-06 R6/R7/R8/R9, appendix §3.2. **One** implementation, instantiated by both
## `Pages/LLM` (onboarding) and `Sections/AIProvider` (Settings), which is the only way the two
## can never drift apart.
##
## Node names are part of the contract (R6/R10): `ProviderPicker`, `BaseUrlField`, `ModelField`,
## `ApiKeyField`, `CustomAuthNoneCheck`, `CustomJsonModeCheck`, `ProviderHelpButton`,
## `TestConnectionButton`, `SaveAiButton`, `StatusChip`, `InfoButton`.
##
## House rules this file obeys: look comes only from `theme_type_variation` (no per-control
## colour or font-size theme overrides anywhere), every interactive control ends up at least
## 88×88, and the only way a setting is written is `App.set_setting()` — so every write is
## validated by [StoreSchema] first and by `Store` second.
##
## The key's life cycle, which is the point of this screen:
##   typed  -> `LineEdit` with `secret = true` (dots), Show/Hide toggle, re-masked on focus loss
##   stored -> only ever rendered as `Redact.mask_key()` in [member _saved_label]
##   sent   -> only to the provider, only from [LLMProbe]/`LLM.test_connection()`
##   logged -> never: every message that could contain it goes through `Redact.safe_error()`

## Emitted whenever the edits differ from what is stored (R10's `•` unsaved-edits marker).
signal dirty_changed(is_dirty: bool)
## Emitted with a complete R9 result dictionary after every test attempt.
signal test_finished(result: Dictionary)
## Emitted after a successful save, with the normalized `llm` block that was written.
signal saved(cfg: Dictionary)

const EDITABLE_FIELDS: PackedStringArray = [
	"provider", "base_url", "model", "api_key", "custom_auth_none", "custom_json_mode",
]

const STATUS_CHIP_SCENE := preload("res://scenes/components/status_chip.tscn")

var _provider: String = LLMProviders.DEFAULT_KEY
var _dirty: bool = false
var _loading: bool = false
var _probe: LLMProbe = null

var _picker: OptionButton = null
var _base_url_field: LineEdit = null
var _base_url_hint: Label = null
var _base_url_error: Label = null
var _model_field: LineEdit = null
var _model_error: Label = null
var _key_field: LineEdit = null
var _key_error: Label = null
var _saved_label: Label = null
var _show_key_button: Button = null
var _custom_auth_none: CheckButton = null
var _custom_json_mode: CheckButton = null
var _custom_checks: VBoxContainer = null
var _help_button: Button = null
var _test_button: Button = null
var _save_button: Button = null
var _status_chip: StatusChip = null
var _message_label: Label = null
var _privacy_header: Label = null
var _privacy_note: Label = null
var _info_button: Button = null
var _dirty_marker: Label = null
var _actions_row: HBoxContainer = null


func _ready() -> void:
	_build()
	_probe = LLMProbe.new()
	_probe.name = "ConnectionProbe"
	add_child(_probe)
	_load_from_settings()
	_publish_probe_rects.call_deferred()


func _exit_tree() -> void:
	cancel_test()


# ------------------------------------------------------------------ public API (R6/R10)

## Reads the stored `llm` block into the fields. Safe to call again after an external change.
func load_from_settings() -> void:
	_load_from_settings()


## The configuration as edited (normalized, not yet stored).
func current_config() -> Dictionary:
	var cfg := default_config()
	cfg["provider"] = _provider
	cfg["base_url"] = _base_url_field.text
	cfg["model"] = _model_field.text
	cfg["api_key"] = _key_field.text
	cfg["custom_auth_none"] = _custom_auth_none.button_pressed
	cfg["custom_json_mode"] = _custom_json_mode.button_pressed
	cfg["configured"] = _was_configured()
	return StoreSchema.normalize_llm(cfg)


## R7 validation of the edited fields: `{ok, errors, normalized}`.
func validate() -> Dictionary:
	return StoreSchema.validate_llm(current_config())


## True while the edits differ from the stored configuration.
func is_dirty() -> bool:
	return _dirty


func provider_key() -> String:
	return _provider


## Validates, then writes the editable `llm.*` keys and flushes. Returns false and leaves the
## document untouched when a field is invalid (R10 order 5).
func save() -> bool:
	var report := validate()
	_show_errors(report["errors"])
	if not bool(report["ok"]):
		return false
	var normalized: Dictionary = report["normalized"]
	var wrote := true
	for field in EDITABLE_FIELDS:
		wrote = _write("llm.%s" % field, normalized[field]) and wrote
	wrote = _write("llm.configured", true) and wrote
	if not wrote:
		Feedback.toast(Strings.TOAST_SAVE_FAILED, &"danger")
		return false
	Store.save_settings()
	_set_dirty(false)
	_saved_label.text = _saved_summary(normalized)
	_saved_label.visible = true
	Feedback.toast(Strings.TOAST_AI_SAVED, &"success")
	saved.emit(normalized)
	return true


## Runs `Test connection` (R9): one attempt, 20 s, no retries. Returns the complete R9 result
## dictionary, or `{}` when the fields themselves do not validate (in which case the inline
## messages are the feedback, because that is a form problem and not a provider answer).
func run_test_connection() -> Dictionary:
	var cfg := current_config()
	var report := StoreSchema.validate_llm(cfg)
	_show_errors(report["errors"])

	if not bool(report["ok"]):
		var errors: Dictionary = report["errors"]
		if errors.size() == 1 and errors.has("api_key"):
			# A missing or short key is R9's `no_key` branch, not a form error: it has copy of
			# its own and it still records an attempt.
			var no_key := LLMProviders.failure_result("no_key", _provider,
				String(cfg["base_url"]), 0, 0, "", String(cfg["api_key"]))
			_apply_result(no_key)
			return no_key
		_set_chip(&"unverified", Strings.STATUS_UNVERIFIED)
		_message_label.text = String(errors.values()[0]) if not errors.is_empty() else ""
		_message_label.visible = not _message_label.text.is_empty()
		return {}

	_test_button.disabled = true
	_test_button.text = "Testing…"
	var result: Dictionary = {}
	var via_llm: Variant = null
	if is_instance_valid(LLM) and LLM.has_method(&"test_connection"):
		via_llm = await LLM.call(&"test_connection", cfg)
	if via_llm is Dictionary and not (via_llm as Dictionary).is_empty():
		result = via_llm
	else:
		result = await _probe.run(cfg)
	_test_button.disabled = false
	_test_button.text = Strings.TEST_BUTTON
	if result.is_empty():
		return {}
	_apply_result(result)
	return result


## Aborts an in-flight probe — the wizard calls this when the user leaves `Pages/LLM` (R9).
func cancel_test() -> void:
	if _probe != null and is_instance_valid(_probe):
		_probe.cancel()
		if _test_button != null:
			_test_button.disabled = false
			_test_button.text = Strings.TEST_BUTTON


## Hides the test/save row: the onboarding wizard drives both from its footer button (R4).
func set_actions_visible(test_visible: bool, save_visible: bool) -> void:
	_test_button.visible = test_visible
	_save_button.visible = save_visible
	_actions_row.visible = test_visible or save_visible


## Collapses or expands the R8 privacy note. Settings shows it behind `InfoButton`; the wizard
## shows it open.
func set_privacy_expanded(expanded: bool) -> void:
	_privacy_note.visible = expanded
	_privacy_header.visible = expanded
	_sync_info_button()


## Adds the account/server name field that only `custom` uses? No — `custom_name` is PRD-07's.
## Exposed so the wizard can show which provider is currently selected in its summary line.
func provider_label() -> String:
	return LLMProviders.label_for(_provider)


# ------------------------------------------------------------------ construction

func default_config() -> Dictionary:
	var value: Variant = App.get_setting("llm", {})
	var cfg: Dictionary = value if value is Dictionary else {}
	if cfg.is_empty():
		cfg = StoreSchema.default_llm()
	return StoreSchema.normalize_llm(cfg)


func _build() -> void:
	add_theme_constant_override(&"separation", DesignTokens.SPACE["md"])

	# --- provider ---------------------------------------------------------------
	var provider_row := _row("ProviderRow")
	_caption(provider_row, Strings.PROVIDER_LABEL)
	_picker = OptionButton.new()
	_picker.name = "ProviderPicker"
	_picker.theme_type_variation = &"Input"
	TouchTargets.enforce(_picker)
	for key in LLMProviders.keys():
		_picker.add_item(LLMProviders.label_for(key))
		_picker.set_item_metadata(_picker.item_count - 1, key)
	_picker.item_selected.connect(_on_provider_selected)
	provider_row.add_child(_picker)
	provider_row.add_child(_error_label("ProviderError"))

	# --- base URL ---------------------------------------------------------------
	var base_row := _row("BaseUrlRow")
	_caption(base_row, Strings.BASE_URL_LABEL)
	_base_url_field = _line_edit("BaseUrlField")
	_base_url_field.placeholder_text = "https://api.example.com/v1"
	_base_url_field.text_changed.connect(_on_text_changed)
	base_row.add_child(_base_url_field)
	_base_url_hint = _caption(base_row, Strings.BASE_URL_FIXED_HINT)
	_base_url_hint.visible = false
	_base_url_error = _error_label("BaseUrlError")
	base_row.add_child(_base_url_error)

	# --- model ------------------------------------------------------------------
	var model_row := _row("ModelRow")
	_caption(model_row, Strings.MODEL_LABEL)
	_model_field = _line_edit("ModelField")
	_model_field.placeholder_text = "model-name"
	_model_field.text_changed.connect(_on_text_changed)
	model_row.add_child(_model_field)
	_model_error = _error_label("ModelError")
	model_row.add_child(_model_error)

	# --- API key ----------------------------------------------------------------
	var key_row := _row("ApiKeyRow")
	_caption(key_row, Strings.API_KEY_LABEL)
	_key_field = _line_edit("ApiKeyField")
	_key_field.secret = true
	_key_field.secret_character = "•"
	_key_field.caret_blink = false
	_key_field.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	_key_field.placeholder_text = "sk-…"
	_key_field.text_changed.connect(_on_key_changed)
	_key_field.focus_exited.connect(_remask_key)
	key_row.add_child(_key_field)

	var key_buttons := HBoxContainer.new()
	key_buttons.name = "KeyButtons"
	key_buttons.add_theme_constant_override(&"separation", DesignTokens.SPACE["sm"])
	key_row.add_child(key_buttons)

	_show_key_button = Button.new()
	_show_key_button.name = "ShowKeyToggle"
	_show_key_button.text = Strings.SHOW_KEY
	_show_key_button.toggle_mode = true
	_show_key_button.theme_type_variation = &"SecondaryButton"
	TouchTargets.enforce(_show_key_button)
	_show_key_button.toggled.connect(_on_show_key_toggled)
	key_buttons.add_child(_show_key_button)

	_help_button = Button.new()
	_help_button.name = "ProviderHelpButton"
	_help_button.text = Strings.HELP_BUTTON
	_help_button.theme_type_variation = &"SecondaryButton"
	TouchTargets.enforce(_help_button)
	_help_button.pressed.connect(_on_help_pressed)
	key_buttons.add_child(_help_button)

	_key_error = _error_label("ApiKeyError")
	key_row.add_child(_key_error)

	_saved_label = _caption(key_row, "")
	_saved_label.name = "SavedKeyLabel"
	_saved_label.visible = false

	# --- custom-only checks -----------------------------------------------------
	_custom_checks = VBoxContainer.new()
	_custom_checks.name = "CustomChecks"
	_custom_checks.add_theme_constant_override(&"separation", DesignTokens.SPACE["xs"])
	add_child(_custom_checks)

	_custom_auth_none = _check("CustomAuthNoneCheck", Strings.CUSTOM_AUTH_NONE)
	_custom_json_mode = _check("CustomJsonModeCheck", Strings.CUSTOM_JSON_MODE)
	_custom_checks.add_child(_custom_auth_none)
	_custom_checks.add_child(_custom_json_mode)

	# --- status -----------------------------------------------------------------
	var status_row := HBoxContainer.new()
	status_row.name = "StatusRow"
	status_row.add_theme_constant_override(&"separation", DesignTokens.SPACE["sm"])
	add_child(status_row)

	_status_chip = STATUS_CHIP_SCENE.instantiate() as StatusChip
	_status_chip.name = "StatusChip"
	status_row.add_child(_status_chip)
	_set_chip(&"unverified", Strings.STATUS_UNVERIFIED)

	_message_label = Label.new()
	_message_label.name = "TestMessage"
	_message_label.theme_type_variation = &"BodySmall"
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.visible = false
	add_child(_message_label)

	# --- actions ----------------------------------------------------------------
	_actions_row = HBoxContainer.new()
	_actions_row.name = "AiActions"
	_actions_row.add_theme_constant_override(&"separation", DesignTokens.SPACE["sm"])
	add_child(_actions_row)

	_test_button = Button.new()
	_test_button.name = "TestConnectionButton"
	_test_button.text = Strings.TEST_BUTTON
	_test_button.theme_type_variation = &"SecondaryButton"
	TouchTargets.enforce(_test_button)
	_test_button.pressed.connect(_on_test_pressed)
	_actions_row.add_child(_test_button)

	_save_button = Button.new()
	_save_button.name = "SaveAiButton"
	_save_button.text = Strings.SAVE_AI_BUTTON
	_save_button.theme_type_variation = &"PrimaryButton"
	TouchTargets.enforce(_save_button)
	_save_button.pressed.connect(_on_save_pressed)
	_actions_row.add_child(_save_button)

	_dirty_marker = Label.new()
	_dirty_marker.name = "DirtyMarker"
	_dirty_marker.text = "•"
	_dirty_marker.theme_type_variation = &"Caption"
	_dirty_marker.visible = false
	_actions_row.add_child(_dirty_marker)

	# --- privacy (R8) -----------------------------------------------------------
	var privacy_row := HBoxContainer.new()
	privacy_row.name = "PrivacyRow"
	privacy_row.add_theme_constant_override(&"separation", DesignTokens.SPACE["sm"])
	add_child(privacy_row)

	_privacy_header = Label.new()
	_privacy_header.name = "PrivacyHeader"
	_privacy_header.text = Strings.PRIVACY_HEADING
	_privacy_header.theme_type_variation = &"H3"
	_privacy_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_privacy_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	privacy_row.add_child(_privacy_header)

	_info_button = Button.new()
	_info_button.name = "InfoButton"
	_info_button.text = "i"
	_info_button.theme_type_variation = &"GhostButton"
	TouchTargets.enforce(_info_button)
	_info_button.pressed.connect(_on_info_pressed)
	privacy_row.add_child(_info_button)

	_privacy_note = Label.new()
	_privacy_note.name = "PrivacyNote"
	_privacy_note.text = Strings.privacy_note()
	_privacy_note.theme_type_variation = &"BodySmall"
	_privacy_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_privacy_note)


## Rows are vertical stacks: a label above its field is the only layout that survives a 360 dp
## screen with a 1.5 text scale.
func _row(row_name: String) -> VBoxContainer:
	var row := VBoxContainer.new()
	row.name = row_name
	row.add_theme_constant_override(&"separation", DesignTokens.SPACE["xs"])
	add_child(row)
	return row


func _caption(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"Caption"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _error_label(label_name: String) -> Label:
	var label := Label.new()
	label.name = label_name
	label.theme_type_variation = &"Caption"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.visible = false
	return label


func _line_edit(field_name: String) -> LineEdit:
	var field := LineEdit.new()
	field.name = field_name
	field.theme_type_variation = &"Input"
	TouchTargets.enforce(field)
	return field


func _check(check_name: String, text: String) -> CheckButton:
	var check := CheckButton.new()
	check.name = check_name
	check.text = text
	check.theme_type_variation = &"SettingToggle"
	TouchTargets.enforce(check)
	check.toggled.connect(_on_check_toggled)
	return check


# ------------------------------------------------------------------ settings I/O

func _load_from_settings() -> void:
	_loading = true
	var cfg := default_config()
	_provider = String(cfg["provider"])
	if not LLMProviders.has(_provider):
		_provider = LLMProviders.DEFAULT_KEY
	_select_picker(_provider)
	_base_url_field.text = String(cfg["base_url"])
	_model_field.text = String(cfg["model"])
	_key_field.text = String(cfg["api_key"])
	_custom_auth_none.button_pressed = bool(cfg["custom_auth_none"])
	_custom_json_mode.button_pressed = bool(cfg["custom_json_mode"])
	_apply_provider_rules()
	_refresh_saved_summary(cfg)
	_set_chip(_stored_chip_state(cfg), "")
	_message_label.visible = false
	_show_errors({})
	_loading = false
	_set_dirty(false)


func _write(path: String, value: Variant) -> bool:
	var message := StoreSchema.validate_setting(path, value, _context())
	if not message.is_empty():
		_show_field_error(path, message)
		return false
	return App.set_setting(path, value)


func _context() -> Dictionary:
	return {
		"provider": _provider,
		"custom_auth_none": _custom_auth_none.button_pressed,
	}


func _was_configured() -> bool:
	return bool(App.get_setting("llm.configured", false))


# ------------------------------------------------------------------ interactions

func _on_provider_selected(index: int) -> void:
	var key := String(_picker.get_item_metadata(index))
	if key == _provider:
		return
	_provider = key
	# R6: the base URL and model follow the preset; the pasted key deliberately does not — a
	# mistap must not destroy a key the user just pasted.
	var entry := LLMProviders.preset(key)
	var _p := _write("llm.provider", key)
	var _u := _write("llm.base_url", String(entry["base_url"]))
	var model := String(entry["default_model"])
	if not model.is_empty():
		var _m := _write("llm.model", model)
	_base_url_field.text = String(entry["base_url"])
	if not model.is_empty():
		_model_field.text = model
	var _c := _write("llm.configured", false)
	_apply_provider_rules()
	_set_chip(&"unverified", Strings.STATUS_UNVERIFIED)
	_message_label.visible = false
	_show_errors({})
	_set_dirty(true)


func _on_text_changed(_text: String) -> void:
	if not _loading:
		_set_dirty(true)


func _on_key_changed(_text: String) -> void:
	if _loading:
		return
	_set_dirty(true)
	# A fresh paste invalidates the previous verification, and the stored-key summary is now
	# describing a key that is no longer in the field.
	_set_chip(&"unverified", Strings.STATUS_UNVERIFIED)
	_saved_label.visible = false


func _on_check_toggled(_pressed: bool) -> void:
	if not _loading:
		_set_dirty(true)


func _on_show_key_toggled(pressed: bool) -> void:
	_key_field.secret = not pressed
	_show_key_button.text = Strings.HIDE_KEY if pressed else Strings.SHOW_KEY
	if pressed:
		_key_field.caret_column = _key_field.text.length()
		_key_field.grab_focus()


## Re-masks on focus loss so the full key is never left on screen (R8 risk table).
func _remask_key() -> void:
	_key_field.secret = true
	if _show_key_button.button_pressed:
		_show_key_button.set_pressed_no_signal(false)
	_show_key_button.text = Strings.SHOW_KEY


func _on_help_pressed() -> void:
	var url := LLMProviders.docs_url(_provider)
	if url.is_empty():
		return
	var _opened := OS.shell_open(url)


func _on_info_pressed() -> void:
	set_privacy_expanded(not _privacy_note.visible)


func _on_test_pressed() -> void:
	var _result := await run_test_connection()


func _on_save_pressed() -> void:
	var _ok := save()


# ------------------------------------------------------------------ rendering

## Applies the R6 rules for the selected preset: base-URL editability, the custom-only checks,
## and whether a docs link exists.
func _apply_provider_rules() -> void:
	var editable := LLMProviders.base_url_editable(_provider)
	_base_url_field.editable = editable
	_base_url_hint.visible = not editable
	var is_custom := _provider == "custom"
	_custom_checks.visible = is_custom
	_help_button.visible = not LLMProviders.docs_url(_provider).is_empty()
	_sync_info_button()


func _sync_info_button() -> void:
	_info_button.text = "i" if not _privacy_note.visible else "×"


func _select_picker(key: String) -> void:
	for i in _picker.item_count:
		if String(_picker.get_item_metadata(i)) == key:
			_picker.select(i)
			return


## After any test branch: chip, message and the stored outcome (R9). The message is scrubbed
## even though [LLMProviders] already redacted it — belt and braces on the one string that came
## from a remote server.
func _apply_result(result: Dictionary) -> void:
	var ok := bool(result.get("ok", false))
	var code := String(result.get("error_code", ""))
	_set_chip(_chip_state_for(code, ok), "")
	_message_label.text = Redact.safe_error(String(result.get("message", "")), _key_field.text)
	_message_label.visible = not _message_label.text.is_empty()
	var _a := App.set_setting("llm.last_test_ok", ok)
	var _b := App.set_setting("llm.last_tested_at", Dates.now_iso8601(true))
	var _flushed := Store.save_settings()
	_refresh_saved_summary(current_config())
	test_finished.emit(result)


static func _chip_state_for(error_code: String, ok: bool) -> StringName:
	if ok:
		return &"verified"
	match error_code:
		"auth", "forbidden":
			return &"rejected"
		"no_key":
			return &"unverified"
	return &"unreachable"


## The chip a stored configuration deserves before any test this session: a remembered failure
## is shown as unreachable because `last_test_ok` is a bool and the code was not stored.
static func _stored_chip_state(cfg: Dictionary) -> StringName:
	var tested: Variant = cfg.get("last_test_ok", null)
	if tested is bool:
		return &"verified" if bool(tested) else &"unreachable"
	return &"unverified"


func _refresh_saved_summary(cfg: Dictionary) -> void:
	var key := String(cfg.get("api_key", ""))
	if key.is_empty():
		_saved_label.visible = false
		return
	_saved_label.text = "Stored key: %s" % Redact.mask_key(key)
	_saved_label.visible = true


func _saved_summary(cfg: Dictionary) -> String:
	var key := String(cfg.get("api_key", ""))
	if key.is_empty():
		return "Stored: %s (no key)" % LLMProviders.label_for(String(cfg["provider"]))
	return "Stored: %s · %s" % [LLMProviders.label_for(String(cfg["provider"])),
		Redact.mask_key(key)]


# ------------------------------------------------------------------ errors / dirtiness

func _show_errors(errors: Dictionary) -> void:
	_show_field_error("provider", String(errors.get("provider", "")))
	_show_field_error("base_url", String(errors.get("base_url", "")))
	_show_field_error("model", String(errors.get("model", "")))
	_show_field_error("api_key", String(errors.get("api_key", "")))


func _show_field_error(field: String, message: String) -> void:
	var label: Label = null
	match field:
		"provider":
			label = get_node_or_null(^"ProviderRow/ProviderError") as Label
		"llm.provider":
			label = get_node_or_null(^"ProviderRow/ProviderError") as Label
		"base_url", "llm.base_url":
			label = _base_url_error
		"model", "llm.model":
			label = _model_error
		"api_key", "llm.api_key":
			label = _key_error
	if label == null:
		return
	label.text = message
	label.visible = not message.is_empty()


func _set_dirty(value: bool) -> void:
	if _dirty == value:
		return
	_dirty = value
	_dirty_marker.visible = value
	dirty_changed.emit(value)


# ------------------------------------------------------------------ small helpers

## One place that talks to the chip, so the method name lives in a single call site (the
## component keeps PRD-02's convention of no `class_name`).
func _set_chip(state: StringName, text: String) -> void:
	if _status_chip != null and is_instance_valid(_status_chip):
		_status_chip.set_status(state, text)


func _publish_probe_rects() -> void:
	UiProbe.log_rects({
		"provider_picker": _picker,
		"api_key_field": _key_field,
		"test_connection_button": _test_button,
		"save_ai_button": _save_button,
	})
