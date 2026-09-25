class_name Player
extends CharacterBody2D

@export_range(1.0, 1000.0, 1.0, "or_greater") var move_speed: float = 220.0
@export var touch_joystick_path: NodePath

const BOUNDARY_MIN_OFFSET := Vector2(16.0, 48.0)
const BOUNDARY_MAX_OFFSET := Vector2(16.0, 0.0)

var _touch_joystick: TouchJoystick


func _ready() -> void:
	if not touch_joystick_path.is_empty():
		_touch_joystick = get_node_or_null(touch_joystick_path) as TouchJoystick


func _physics_process(_delta: float) -> void:
	velocity = get_movement_direction() * move_speed
	move_and_slide()
	_clamp_to_world_boundary()


func get_movement_direction() -> Vector2:
	var direction := Input.get_vector(
		"move_left",
		"move_right",
		"move_up",
		"move_down"
	)
	if _touch_joystick != null:
		direction += _touch_joystick.get_direction()
	return direction.limit_length(1.0)


func _clamp_to_world_boundary() -> void:
	var minimum := WorldBoundary.BOUNDS.position + BOUNDARY_MIN_OFFSET
	var maximum := WorldBoundary.BOUNDS.end - BOUNDARY_MAX_OFFSET
	global_position = global_position.clamp(minimum, maximum)
