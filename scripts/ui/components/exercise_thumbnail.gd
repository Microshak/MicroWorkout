extends PanelContainer
## Exercise art slot — PRD-02 R7, appendix §3.1.
##
## The app ships **no** exercise art yet (PRD-04 owns the frames), so the placeholder path is
## the one that renders today: the flipbook shows a `dumbbell` glyph and hides the texture
## slot. Once `set_exercise()` receives real paths they are loaded once, cached in a static
## dictionary keyed by exercise id, and cycled **ping-pong** `0→1→2→1→0` off a `Timer` — no
## `_process` animation anywhere (appendix §4.4).

signal frame_changed(index: int)

## Drives the flipbook. `false` freezes on the current frame.
@export var animate: bool = true

## Texture paths, one per frame. Empty (the default) means "no art yet" → placeholder.
@export var frames: PackedStringArray = PackedStringArray()

## Glyph shown while no frame art exists.
const PLACEHOLDER_KIND := &"dumbbell"

## Decoded frames per exercise id, shared by every instance.
static var _texture_cache: Dictionary = {}
## Exercise ids in least-recently-used order (PRD-12 R10's P6 ceiling).
static var _cache_order: Array[String] = []
## Exercise ids whose declared art failed to load — one warning each (PRD-12 R8).
static var _missing_reported: Dictionary = {}

var _exercise_id: String = ""
var _sequence: PackedInt32Array = PackedInt32Array([0])
var _cursor: int = 0
var _textures: Array = []


func _ready() -> void:
	var timer := frame_timer()
	if timer != null:
		# Keep `MOTION.frame_ms` authoritative over the scene literal.
		timer.wait_time = float(DesignTokens.MOTION["frame_ms"]) / 1000.0
		if not timer.timeout.is_connected(_on_frame_timeout):
			timer.timeout.connect(_on_frame_timeout)
	var placeholder := placeholder_glyph()
	if placeholder != null:
		placeholder.set(&"kind", PLACEHOLDER_KIND)
	_refresh()


## Loads [param exercise_id] and its frames. [param frames_arg] may be omitted for
## art-less entries (`set_exercise("bench-press")`), which renders the placeholder.
func set_exercise(new_exercise_id: String, frames_arg: PackedStringArray = PackedStringArray()) -> void:
	_exercise_id = new_exercise_id
	if not frames_arg.is_empty():
		frames = frames_arg
	_cursor = 0
	_refresh()


func play() -> void:
	animate = true
	_apply_playback()


func stop() -> void:
	animate = false
	_apply_playback()


## Overrides the `MOTION.frame_ms` cadence with an explicit frame rate.
func set_fps(fps: float) -> void:
	if fps <= 0.0:
		return
	var timer := frame_timer()
	if timer == null:
		return
	timer.wait_time = 1.0 / fps
	if timer.is_stopped() and animate:
		timer.start()


## Index into [member frames] currently shown (0 when there is no art).
func current_frame_index() -> int:
	if _cursor < 0 or _cursor >= _sequence.size():
		return 0
	return _sequence[_cursor]


func frame_rect() -> TextureRect:
	return get_node_or_null(^"Pad/Stack/Frame") as TextureRect


func placeholder_glyph() -> Control:
	return get_node_or_null(^"Pad/Stack/Placeholder") as Control


func frame_timer() -> Timer:
	return get_node_or_null(^"Pad/Stack/FrameTimer") as Timer


func exercise_id() -> String:
	return _exercise_id


func _refresh() -> void:
	_textures = _resolve_textures()
	_sequence = _build_sequence(_textures.size())
	if _cursor >= _sequence.size():
		_cursor = 0
	_apply_frame()
	_apply_playback()
	frame_changed.emit(current_frame_index())


## Ping-pong order for [param count] frames: 0→1→…→n-1→n-2→…→1 (appendix §3.1).
static func _build_sequence(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if count <= 0:
		out.append(0)
		return out
	for i in count:
		out.append(i)
	for i in range(count - 2, 0, -1):
		out.append(i)
	return out


## PRD-12 R10 (P6): at most twelve decoded frames stay resident — four exercises' worth. The
## cache is shared by every instance, so the ceiling is a property of the app, not of a screen.
const MAX_CACHED_TEXTURES := 12


func _resolve_textures() -> Array:
	if _exercise_id.is_empty():
		return _texture_cache.get("", [])
	if _texture_cache.has(_exercise_id):
		_mark_used(_exercise_id)
		return _texture_cache[_exercise_id]
	var loaded: Array = []
	for path in frames:
		if not ResourceLoader.exists(path):
			continue
		var resource := ResourceLoader.load(path)
		if resource is Texture2D:
			loaded.append(resource)
	# PRD-12 R8: declared art that did not load is worth a warning once per exercise — the
	# placeholder is the designed path when a library has no art at all.
	if loaded.is_empty() and not frames.is_empty() and not _missing_reported.has(_exercise_id):
		_missing_reported[_exercise_id] = true
		Feedback.toast("Illustration missing for %s." % Library.name_of(_exercise_id), &"warning")
	_texture_cache[_exercise_id] = loaded
	_mark_used(_exercise_id)
	_evict()
	Perf.report_textures(_resident_textures())
	return loaded


## Least-recently-used bookkeeping: `_cache_order` holds exercise ids, oldest first.
static func _mark_used(new_id: String) -> void:
	_cache_order.erase(new_id)
	_cache_order.append(new_id)


## Drops whole exercises (never individual frames) until the ceiling holds. A evicted frames'
## resource is released by the engine once the last reference goes; the placeholder path stays
## correct because `_textures` on a live instance keeps its own reference.
static func _evict() -> void:
	while _resident_textures() > MAX_CACHED_TEXTURES and not _cache_order.is_empty():
		var oldest: String = _cache_order.pop_front()
		_texture_cache.erase(oldest)


static func _resident_textures() -> int:
	var total := 0
	for key in _texture_cache:
		var frames_in_cache: Array = _texture_cache[key]
		total += frames_in_cache.size()
	return total


func _apply_frame() -> void:
	var index := current_frame_index()
	var frame := frame_rect()
	if frame != null:
		frame.texture = _textures[index] if index >= 0 and index < _textures.size() else null
	var placeholder := placeholder_glyph()
	if placeholder != null:
		placeholder.visible = _textures.is_empty()


func _apply_playback() -> void:
	var timer := frame_timer()
	if timer == null:
		return
	if animate and not _textures.is_empty():
		timer.start()
	else:
		timer.stop()


func _on_frame_timeout() -> void:
	if _sequence.is_empty():
		return
	var previous := current_frame_index()
	_cursor = (_cursor + 1) % _sequence.size()
	_apply_frame()
	if current_frame_index() != previous:
		frame_changed.emit(current_frame_index())
