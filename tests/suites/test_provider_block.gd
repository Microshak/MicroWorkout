extends TestSuite
## Owner bug report (2026-10-02): "it should be saved if they put it in". This suite drives the
## **real** `ProviderConfigBlock` — the one component onboarding and Settings share — through its
## own text fields and its own save path, then reads `settings.json` back through `Store`/`App`.
##
## It is the regression guard for the onboarding hole this pass fixed: `Test & continue` verified
## the key and never wrote it (the page hides the block's Save row), so a verified key evaporated
## before the first generation.
##
## Seeding follows the established convention (ADR-04): `Store` is pointed at a fresh directory
## under `res://.test_tmp/`, so the developer's real settings are never touched.

const TMP_ROOT := "res://.test_tmp/"
const TMP_DIR := "res://.test_tmp/provider_block/"
const BLOCK_PATH := "res://scenes/components/provider_config_block.tscn"
## A syntactically valid key that no provider will ever see.
const TEST_KEY := "sk-test-0123456789abcdef"

var _tree: SceneTree = null
var _viewport: SubViewport = null
var _block: ProviderConfigBlock = null


func _init() -> void:
	suite_name = "provider_block"


func run() -> void:
	_tree = Engine.get_main_loop() as SceneTree
	if _tree == null:
		_fail("no SceneTree — the suite cannot run")
		return
	_seed_store()
	_open_block()
	_test_save_round_trip()
	_test_invalid_key_is_refused()
	_test_keyless_provider()
	_teardown()


# ------------------------------------------------------------------ the owner's guarantee

func _test_save_round_trip() -> void:
	begin("save() writes the typed key and marks the provider configured")
	_key_field().text = TEST_KEY
	assert_true(_block.save(), "save() accepts a valid key")
	assert_eq(String(Store.get_setting("llm.api_key", "")), TEST_KEY,
		"settings.json carries the key after the flush")
	assert_eq(String(App.get_setting("llm.api_key", "")), TEST_KEY, "App reads the key back")
	assert_true(bool(App.get_setting("llm.configured", false)), "llm.configured is true")
	assert_true(LLM.is_configured(), "LLM.is_configured() is true after the save")

	begin("load_from_settings() shows the saved key back in the field")
	_block.load_from_settings()
	assert_eq(_key_field().text, TEST_KEY, "the field still holds the saved key")


func _test_invalid_key_is_refused() -> void:
	begin("an invalid key is refused and the stored one is untouched")
	_key_field().text = "sk short"
	assert_false(_block.save(), "save() refuses a key with whitespace / too short")
	assert_eq(String(Store.get_setting("llm.api_key", "")), TEST_KEY,
		"the stored key did not change")
	assert_true(LLM.is_configured(), "the provider is still configured")


func _test_keyless_provider() -> void:
	begin("custom + auth-none saves without a key")
	_select_provider("custom")
	_base_url_field().text = "https://api.example.com/v1"
	_key_field().text = ""
	_auth_none().button_pressed = true
	assert_true(_block.save(), "save() accepts an empty key when the provider needs none")
	assert_eq(String(Store.get_setting("llm.api_key", "")), "", "the key is now empty")
	assert_eq(String(Store.get_setting("llm.provider", "")), "custom", "provider is custom")
	assert_true(LLM.is_configured(), "LLM.is_configured() accepts a keyless provider")


# ------------------------------------------------------------------ harness

func _seed_store() -> void:
	_remove_tree(TMP_DIR)
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var ignore := FileAccess.open(TMP_ROOT + ".gdignore", FileAccess.WRITE)
	if ignore != null:
		ignore.close()
	Store.set_io_root_for_tests(TMP_DIR)
	Store.load_all()


func _open_block() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1080, 1920)
	_viewport.disable_3d = true
	_tree.root.add_child(_viewport)
	_block = (load(BLOCK_PATH) as PackedScene).instantiate() as ProviderConfigBlock
	_viewport.add_child(_block)


func _teardown() -> void:
	if _viewport != null:
		_tree.root.remove_child(_viewport)
		_viewport.free()
		_viewport = null
		_block = null


func _key_field() -> LineEdit:
	return _block.get_node(^"ApiKeyRow/ApiKeyField") as LineEdit


func _base_url_field() -> LineEdit:
	return _block.get_node(^"BaseUrlRow/BaseUrlField") as LineEdit


func _auth_none() -> CheckButton:
	return _block.get_node(^"CustomChecks/CustomAuthNoneCheck") as CheckButton


## Drives the real picker the way a tap does: select by item metadata, then emit the signal the
## block listens to (its `_on_provider_selected` reads the metadata, never the index).
func _select_provider(key: String) -> void:
	var picker := _block.get_node(^"ProviderRow/ProviderPicker") as OptionButton
	for index in picker.item_count:
		if String(picker.get_item_metadata(index)) == key:
			picker.select(index)
			picker.item_selected.emit(index)
			return
	_fail("provider '%s' is not in the picker" % key)


func _remove_tree(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			_remove_tree(dir_path + name + "/")
		else:
			DirAccess.remove_absolute(dir_path + name)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(dir_path)
