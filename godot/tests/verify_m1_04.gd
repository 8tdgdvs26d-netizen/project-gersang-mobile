extends SceneTree


func _init() -> void:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	assert(main_scene != null, "Main scene must load")

	var main := main_scene.instantiate()
	root.add_child(main)
	var player := main.get_node_or_null("Player") as CharacterBody2D
	assert(player != null, "Main scene must contain the player")
	assert(main.get_node_or_null("WorldBoundary") is WorldBoundary)

	player.global_position = Vector2(-5000.0, -5000.0)
	player._clamp_to_world_boundary()
	assert(player.global_position == WorldBoundary.BOUNDS.position + Player.BODY_HALF_EXTENTS)

	player.global_position = Vector2(5000.0, 5000.0)
	player._clamp_to_world_boundary()
	assert(player.global_position == WorldBoundary.BOUNDS.end - Player.BODY_HALF_EXTENTS)

	print("M1-04 world boundary verification passed")
	quit()
