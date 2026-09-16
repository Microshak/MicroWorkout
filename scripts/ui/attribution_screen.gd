extends Control
## Attribution screen — PRD-06 R10 order 8, reached from `Settings → Attribution`.
##
## Minimal on purpose: PRD-13 owns the full credits page (build info, licence text, the release
## checklist). What this screen must do today is answer "where did the exercise illustrations
## come from, and under what licence?" with data the app actually has on the device.
##
## The credit itself comes from `Library.source_attribution()` — the `source` block of
## `res://data/exercise_library.json`, which is the runtime-visible record. `docs/ATTRIBUTION.md`
## is the human licence record but `docs/` is `.gdignore`d, so it cannot be read at runtime
## (PRD-06 §10 note 5); PRD-13 may add `res://data/attribution.json` and render it here.

const PAGE := "Layout/Scroll/Gutter/Page"

var _source_label: Label = null
var _count_label: Label = null
var _creator_label: Label = null
var _license_label: Label = null


func _ready() -> void:
	var top_bar := get_node_or_null(^"Layout/TopBar")
	if top_bar != null:
		if top_bar.has_method(&"set_title"):
			top_bar.call(&"set_title", "Attribution")
		top_bar.connect(&"back_pressed", _on_back_pressed)

	_source_label = _line("Source", "SourceLine")
	_count_label = _line("Source", "AssetCountLine")
	_creator_label = _line("Source", "CreatorLine")
	_license_label = _line("Source", "LicenseLine")
	_line("Notice", "MedicalLine").text = Strings.MEDICAL_DISCLAIMER
	_line("Notice", "LicenceFileLine").text = \
		"Full per-exercise credit ships with the app at assets/exercises/ATTRIBUTION.json."
	_render()


func _render() -> void:
	var source: Dictionary = Library.source_attribution() if is_instance_valid(Library) else {}
	var creator := String(source.get("creator", ""))
	var license_name := String(source.get("license", ""))
	var repo := String(source.get("repo", ""))
	var count := Library.count() if is_instance_valid(Library) else 0

	if repo.is_empty():
		_source_label.text = "Exercise illustrations: source unavailable"
	else:
		_source_label.text = "Exercise illustrations from %s" % repo
	_count_label.text = "%d exercises, each with three animation frames and three form cues." % count
	if creator.is_empty():
		_creator_label.text = "Creator not recorded in the library data."
	else:
		_creator_label.text = "Created by %s." % creator
	if license_name.is_empty():
		_license_label.text = "Licence not recorded in the library data."
	else:
		_license_label.text = "Licensed %s — derivative art keeps the same share-alike licence." \
			% license_name
	print("[attribution] repo=%s license=%s" % [repo, license_name])


## Adds a label to a card's `Items` column and returns it, so every line is addressable by name.
func _line(card_name: String, line_name: String) -> Label:
	var label := Label.new()
	label.name = line_name
	label.theme_type_variation = &"BodySmall"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var items := get_node_or_null(NodePath("%s/%s/Body/Items" % [PAGE, card_name])) as Node
	if items == null:
		push_error("[attribution] missing card %s" % card_name)
		add_child(label)
		return label
	items.add_child(label)
	return label


func _on_back_pressed() -> void:
	Nav.pop()
