extends SceneTree


func _init() -> void:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	assert(main_scene != null, "Main scene must load")

	var main := main_scene.instantiate()
	root.add_child(main)
	var player := main.get_node_or_null("Player") as CharacterBody2D
	assert(player != null, "Main scene must contain the player")

	var camera := player.get_node_or_null("Camera") as Camera2D
	assert(camera != null, "Player must own a Camera2D")
	assert(camera.enabled, "Player camera must be enabled")
	assert(camera.position == Vector2.ZERO, "Camera must follow the player without an offset")

	print("M1-03 structural verification passed")
	quit()
