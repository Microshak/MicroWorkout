extends Control
## Temporary home screen for PRD-01.
##
## Its only job is to prove on a real Android device that the app boots, renders
## text at the right scale, and can read from the engine. PRD-09 replaces it.

@onready var _diag: Label = $Margin/VBox/Diagnostics/DiagMargin/DiagText


func _ready() -> void:
	print("[home] placeholder home ready")
	var viewport_size := get_viewport_rect().size
	var lines: PackedStringArray = [
		"Build: %s %s (code %d)" % [AppInfo.NAME, AppInfo.VERSION, AppInfo.VERSION_CODE],
		"Platform: %s" % OS.get_name(),
		"Viewport: %d x %d" % [int(viewport_size.x), int(viewport_size.y)],
		"Renderer: %s" % ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"),
		"Locale: %s" % OS.get_locale(),
	]
	if _diag != null:
		_diag.text = "\n".join(lines)
	for line in lines:
		print("[home] %s" % line)
