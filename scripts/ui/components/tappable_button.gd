extends Button
## Shared behaviour for `primary_button` and `secondary_button` — PRD-02 R7.
##
## Look is selected exclusively by the scene's `theme_type_variation`, so this script only
## owns interaction: the press-scale affordance (§4.2 rule 3: press feedback is
## `press_scale` + scrim, never a fill swap to `primary_dim`) and the touch-target floor.

## Scale applied while the button is held (from `MOTION.press_scale`).
@export var press_scale: float = 0.97

var _press_tween: Tween = null


## Raises a Control's `custom_minimum_size` to the touch minimum on both axes.
## Static so `chip_toggle` (which extends Button directly, R7) reuses the same rule.
static func enforce_touch_minimum(control: Control) -> void:
	var minimum := float(DesignTokens.TOUCH_MIN)
	var current := control.custom_minimum_size
	var enforced := Vector2(maxf(current.x, minimum), maxf(current.y, minimum))
	if enforced != current:
		control.custom_minimum_size = enforced


func _ready() -> void:
	enforce_touch_minimum(self)
	pivot_offset = size * 0.5
	resized.connect(_on_resized)
	button_down.connect(_on_button_down)
	button_up.connect(_on_button_up)
	# PRD-12 R2: every button built on this component acknowledges the press.
	if not pressed.is_connected(_on_pressed):
		pressed.connect(_on_pressed)


func _on_pressed() -> void:
	Feedback.tap()


func _on_resized() -> void:
	# R7: the scale animation must grow from the button's centre.
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
