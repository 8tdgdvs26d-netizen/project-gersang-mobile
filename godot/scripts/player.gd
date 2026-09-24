class_name Player
extends CharacterBody2D

@export_range(1.0, 1000.0, 1.0, "or_greater") var move_speed: float = 220.0

const BOUNDARY_MIN_OFFSET := Vector2(16.0, 48.0)
const BOUNDARY_MAX_OFFSET := Vector2(16.0, 0.0)


func _physics_process(_delta: float) -> void:
	var input_direction := Input.get_vector(
		"move_left",
		"move_right",
		"move_up",
		"move_down"
	)
	velocity = input_direction * move_speed
	move_and_slide()
	_clamp_to_world_boundary()


func _clamp_to_world_boundary() -> void:
	var minimum := WorldBoundary.BOUNDS.position + BOUNDARY_MIN_OFFSET
	var maximum := WorldBoundary.BOUNDS.end - BOUNDARY_MAX_OFFSET
	global_position = global_position.clamp(minimum, maximum)
