extends SceneTree


func _init() -> void:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	assert(main_scene != null, "Main scene must load")

	var main := main_scene.instantiate()
	root.add_child(main)
	var player := main.get_node_or_null("Actors/Player") as CharacterBody2D
	assert(player != null, "Main scene must contain the player")
	assert(main.get_node_or_null("WorldBoundary") is WorldBoundary)

	player.global_position = Vector2(-5000.0, -5000.0)
	player._clamp_to_world_boundary()
	assert(player.global_position == WorldBoundary.BOUNDS.position + Player.BOUNDARY_MIN_OFFSET)

	player.global_position = Vector2(50000.0, 50000.0)
	player._clamp_to_world_boundary()
	assert(player.global_position == WorldBoundary.BOUNDS.end - Player.BOUNDARY_MAX_OFFSET)

	print("M1-04 world boundary verification passed")
	quit()
