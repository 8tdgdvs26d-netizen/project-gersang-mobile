extends SceneTree


func _init() -> void:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	assert(main_scene != null, "Main scene must load")

	var main := main_scene.instantiate()
	main.save_path = ""  # M2-09: entering a city now saves; never touch the real save
	root.add_child(main)
	var player := main.get_node_or_null("Actors/Player") as CharacterBody2D
	assert(player != null, "Main scene must contain the player")

	var camera := player.get_node_or_null("Camera") as Camera2D
	assert(camera != null, "Player must own a Camera2D")
	assert(camera.enabled, "Player camera must be enabled")
	assert(camera.position == Vector2(0.0, -24.0), "Camera must follow the player's visual centre")

	print("M1-03 structural verification passed")
	quit()
