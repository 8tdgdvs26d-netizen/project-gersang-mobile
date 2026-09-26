extends SceneTree


func _init() -> void:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	assert(main_scene != null, "Main scene must load")

	var main := main_scene.instantiate()
	main.save_path = ""  # M2-09: entering a city now saves; never touch the real save
	root.add_child(main)
	var actors := main.get_node("Actors") as Node2D
	var player := actors.get_node("Player") as CharacterBody2D
	var obstacle := actors.get_node("RightObstacle") as StaticBody2D
	var player_shape := player.get_node("CollisionShape") as CollisionShape2D
	var obstacle_shape := obstacle.get_node("CollisionShape") as CollisionShape2D

	assert(actors.y_sort_enabled, "Actors must use Y-sort")
	assert(player_shape.position.y == -24.0, "Player node origin must be at its feet")
	assert(obstacle_shape.position.y == -20.0, "Obstacle node origin must be at its base")
	print("M1-06 y-sort and occlusion verification passed")
	quit()
