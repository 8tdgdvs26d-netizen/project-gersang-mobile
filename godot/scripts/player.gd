class_name Player
extends CharacterBody2D

@export_range(1.0, 1000.0, 1.0, "or_greater") var move_speed: float = 220.0


func _physics_process(_delta: float) -> void:
	var input_direction := Input.get_vector(
		"move_left",
		"move_right",
		"move_up",
		"move_down"
	)
	velocity = input_direction * move_speed
	move_and_slide()
