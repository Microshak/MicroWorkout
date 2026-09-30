extends Button
## One row in the Tracker's recent-sessions list — PRD-11 R8.
##
## A whole-row button (the 96 px floor is applied in [_ready]) carrying a title, a meta line
## (`relative day · duration · exercises`) and — for a partial session — a trailing `warning`
## `!` glyph, so "ended early" is never conveyed by the title alone.
##
## The row renders an entry it is given and nothing else: sorting, pooling and navigation belong
## to the screen. `stagger_index` metadata is set by the screen for PRD-12 R1, which is why no
## animation lives here.

## The screen's hook — the row reports, it does not navigate.
signal row_pressed(entry_id: String)

## R8's row height.
const ROW_MIN_HEIGHT := 96.0

var _entry_id: String = ""

@onready var _title: Label = $Row/Texts/TitleLabel
@onready var _meta: Label = $Row/Texts/MetaLabel
@onready var _partial: Control = $Row/PartialGlyph


func _ready() -> void:
	custom_minimum_size.y = maxf(custom_minimum_size.y, ROW_MIN_HEIGHT)
	if not pressed.is_connected(_on_pressed):
		pressed.connect(_on_pressed)
	if not App.theme_changed.is_connected(_on_theme_changed):
		App.theme_changed.connect(_on_theme_changed)


func _on_theme_changed(_mode: String) -> void:
	_recolour()


# ------------------------------------------------------------------ API (R8)

## Fills the row from a history entry (§5.3). Missing fields degrade to safe defaults so an
## older entry can never blank the list.
func set_entry(entry: Dictionary, today_iso: String) -> void:
	_entry_id = String(entry.get("id", ""))
	var title := String(entry.get("session_title", ""))
	_title.text = title if not title.is_empty() else "Session"

	_meta.text = _meta_text(entry, today_iso)
	_partial.visible = not bool(entry.get("completed", false))
	_recolour()
	tooltip_text = "%s — %s" % [_title.text, "completed" if not _partial.visible else "partial"]


func entry_id() -> String:
	return _entry_id


func is_partial() -> bool:
	return _partial.visible


# ------------------------------------------------------------------ internals

func _meta_text(entry: Dictionary, today_iso: String) -> String:
	var pieces := PackedStringArray()
	var date := String(entry.get("date", ""))
	if Dates.is_valid_iso_date(date):
		pieces.append(Dates.relative_day_label(date, today_iso))
	pieces.append(Dates.format_clock(int(entry.get("duration_sec", 0))))
	pieces.append("%d/%d" % [
		int(entry.get("exercises_completed", 0)),
		int(entry.get("exercises_total", 0)),
	])
	return " · ".join(pieces)


## The partial mark is `warning`, resolved for the current mode (light mode needs the
## `*_text_light` reading — appendix §4.3 rule 2).
func _recolour() -> void:
	_partial.add_theme_color_override(&"color",
		DesignTokens.accent_text(App.theme_mode, "warning"))


func _on_pressed() -> void:
	row_pressed.emit(_entry_id)
