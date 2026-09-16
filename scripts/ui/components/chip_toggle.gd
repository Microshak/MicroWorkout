extends Button
## Toggleable chip — PRD-02 R7, appendix §3.1.
##
## Selection lives in the native `toggle_mode`/`button_pressed` pair so the theme's
## `ChipToggle` `pressed`/`hover_pressed` styles apply without any colour override; the
## script only adds the programmatic API and the press affordance.

const TappableButton := preload("res://scripts/ui/components/tappable_button.gd")

## Scale applied while the chip is held (appendix §3.1 lists it for chips too).
@export var press_scale: float = 0.97

var _press_tween: Tween = null


## Selects the chip without emitting [signal toggled] (setters never fake user input).
func set_selected(v: bool) -> void:
	set_pressed_no_signal(v)
	_refresh_pivot()


func is_selected() -> bool:
	return button_pressed


func _ready() -> void:
	toggle_mode = true
	TappableButton.enforce_touch_minimum(self)
	pivot_offset = size * 0.5
	resized.connect(_refresh_pivot)
	button_down.connect(_on_button_down)
	button_up.connect(_on_button_up)


func _refresh_pivot() -> void:
	pivot_offset = size * 0.5


func _on_button_down() -> void:
	_animate_scale(press_scale)


func _on_button_up() -> void:
	_animate_scale(1.0)


func _animate_scale(target: float) -> void:
	if not is_inside_tree():
		return
	if _press_tween != null and _press_tween.is_valid():
		_press_tween.kill()
	_press_tween = create_tween()
	_press_tween.set_trans(Tween.TRANS_CUBIC)
	_press_tween.set_ease(Tween.EASE_OUT)
	_press_tween.tween_property(self, "scale", Vector2(target, target),
		float(DesignTokens.MOTION["press_ms"]) / 1000.0)
