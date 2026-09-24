extends SceneTree


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	assert(main_scene != null, "Main scene must load")

	var main := main_scene.instantiate()
	root.add_child(main)
	var player := main.get_node("Player") as CharacterBody2D
	var player_shape := player.get_node("CollisionShape") as CollisionShape2D
	var obstacle := main.get_node("RightObstacle") as StaticBody2D
	var obstacle_shape := obstacle.get_node("CollisionShape") as CollisionShape2D
	assert(player_shape.shape is RectangleShape2D)
	assert(obstacle_shape.shape is RectangleShape2D)

	Input.action_press("move_right")
	for frame in range(120):
		await physics_frame
	Input.action_release("move_right")

	assert(player.global_position.x > 800.0, "Player must move toward the obstacle")
	assert(player.global_position.x <= 814.1, "Player must not pass through the obstacle")
	print("M1-05 obstacle collision verification passed")
	quit()
