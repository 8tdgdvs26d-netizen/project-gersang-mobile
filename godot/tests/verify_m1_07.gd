extends SceneTree

var _checks := 0
var _failures := 0


func _initialize() -> void:
	var joystick_script := load("res://scripts/touch_joystick.gd") as GDScript
	_check(joystick_script != null and joystick_script.can_instantiate(), "Touch joystick script must parse and load")
	var joystick_scene := load("res://scenes/touch_joystick.tscn") as PackedScene
	_check(joystick_scene != null, "Touch joystick scene must load")

	var main_scene := load("res://scenes/main.tscn") as PackedScene
	var main := main_scene.instantiate()
	root.add_child(main)
	# Wait until the scene is inside the tree so _ready, viewport and physics exist.
	await physics_frame
	var player := main.get_node("Actors/Player") as Player
	var joystick := main.get_node("TouchControls/Joystick") as TouchJoystick
	_check(joystick != null, "Main scene must contain the touch joystick")
	_check(player._touch_joystick == joystick, "Player must read the main scene joystick")

	_verify_keyboard_path(player)
	_verify_direction(joystick)
	_verify_release_and_cancel(joystick)
	_verify_pointer_safety(joystick)
	_verify_shared_movement_path(player, joystick)
	_verify_single_physics_path()

	if _failures == 0:
		print("M1-07 mobile touch movement verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_keyboard_path(player: Player) -> void:
	_check(player.get_movement_direction() == Vector2.ZERO, "No input must mean no movement")
	Input.action_press("move_right")
	_check(player.get_movement_direction().is_equal_approx(Vector2.RIGHT), "Keyboard D must move right")
	Input.action_press("move_up")
	var diagonal := player.get_movement_direction()
	_check(is_equal_approx(diagonal.length(), 1.0), "Keyboard diagonal must stay normalized")
	Input.action_release("move_up")
	Input.action_release("move_right")
	_check(player.get_movement_direction() == Vector2.ZERO, "Keyboard release must stop movement")


func _verify_direction(joystick: TouchJoystick) -> void:
	_touch(joystick, 0, Vector2(200, 500), true)
	_check(joystick.is_active(), "Left-side press must start the joystick")
	_check(joystick.get_direction() == Vector2.ZERO, "Touch start must not move before dragging")

	_drag(joystick, 0, Vector2(205, 500))
	_check(joystick.get_direction() == Vector2.ZERO, "Small drag inside dead zone must not move")

	_drag(joystick, 0, Vector2(900, 500))
	_check(joystick.get_direction().is_equal_approx(Vector2.RIGHT), "Far right drag must be full right")

	for angle_degrees in range(0, 360, 15):
		var offset := Vector2.RIGHT.rotated(deg_to_rad(angle_degrees)) * 1000.0
		_drag(joystick, 0, Vector2(200, 500) + offset)
		var direction := joystick.get_direction()
		_check(direction.length() <= 1.0 + 0.0001, "Direction magnitude must not exceed 1")
		_check(is_equal_approx(direction.angle_to(offset), 0.0), "Direction must follow drag angle %d" % angle_degrees)

	_drag(joystick, 0, Vector2(200, 500) + Vector2(1, 1) * 60.0)
	var diagonal := joystick.get_direction()
	_check(diagonal.x > 0.0 and is_equal_approx(diagonal.x, diagonal.y), "Diagonal drag must move diagonally")
	_check(diagonal.length() < 1.0, "Partial drag must give partial strength")
	_touch(joystick, 0, Vector2(260, 560), false)


func _verify_release_and_cancel(joystick: TouchJoystick) -> void:
	_touch(joystick, 0, Vector2(200, 500), true)
	_drag(joystick, 0, Vector2(400, 500))
	_touch(joystick, 0, Vector2(400, 500), false)
	_check(joystick.get_direction() == Vector2.ZERO, "Release must reset direction")
	_check(not joystick.is_active(), "Release must free the movement pointer")

	_drag(joystick, 0, Vector2(500, 500))
	_check(joystick.get_direction() == Vector2.ZERO, "Drag after release must be ignored")

	_touch(joystick, 0, Vector2(200, 500), true)
	_drag(joystick, 0, Vector2(200, 300))
	var cancel := InputEventScreenTouch.new()
	cancel.index = 0
	cancel.position = Vector2(200, 300)
	cancel.pressed = false
	cancel.canceled = true
	joystick.handle_input_event(cancel)
	_check(joystick.get_direction() == Vector2.ZERO, "Touch cancel must reset direction")

	_touch(joystick, 0, Vector2(200, 500), true)
	_drag(joystick, 0, Vector2(200, 700))
	joystick.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(joystick.get_direction() == Vector2.ZERO, "Losing app focus must reset direction")
	_check(not joystick.is_active(), "Losing app focus must free the movement pointer")


func _verify_pointer_safety(joystick: TouchJoystick) -> void:
	_touch(joystick, 0, Vector2(1100, 500), true)
	_check(not joystick.is_active(), "Press outside the left control area must be ignored")

	_touch(joystick, 0, Vector2(200, 500), true)
	_drag(joystick, 0, Vector2(400, 500))
	var held := joystick.get_direction()

	_touch(joystick, 1, Vector2(300, 200), true)
	_drag(joystick, 1, Vector2(100, 100))
	_check(joystick.get_direction() == held, "Second finger press and drag must not change direction")
	_touch(joystick, 1, Vector2(100, 100), false)
	_check(joystick.get_direction() == held, "Second finger release must not stop movement")

	_drag(joystick, 0, Vector2(5000, 500))
	_check(joystick.get_direction().is_equal_approx(Vector2.RIGHT), "Dragging outside the visual must stay clamped")

	_touch(joystick, 0, Vector2(300, 400), true)
	_check(joystick.get_direction() == Vector2.ZERO, "Repeated press of movement finger must restart at rest")
	_touch(joystick, 0, Vector2(300, 400), false)
	_check(joystick.get_direction() == Vector2.ZERO and not joystick.is_active(), "Final release must leave no stuck movement")


func _verify_shared_movement_path(player: Player, joystick: TouchJoystick) -> void:
	_touch(joystick, 0, Vector2(200, 500), true)
	_drag(joystick, 0, Vector2(200, 900))
	_check(player.get_movement_direction().is_equal_approx(Vector2.DOWN), "Player must read touch direction")

	Input.action_press("move_right")
	var combined := player.get_movement_direction()
	_check(combined.length() <= 1.0 + 0.0001, "Keyboard plus touch must not exceed full speed")
	Input.action_release("move_right")

	var start := player.global_position
	player._physics_process(1.0 / 60.0)
	_check(player.global_position.y > start.y, "Touch direction must move the player through its physics step")

	_touch(joystick, 0, Vector2(200, 900), false)
	_check(player.get_movement_direction() == Vector2.ZERO, "Touch release must stop the player")


func _verify_single_physics_path() -> void:
	var player_source := FileAccess.get_file_as_string("res://scripts/player.gd")
	var joystick_source := FileAccess.get_file_as_string("res://scripts/touch_joystick.gd")
	_check(player_source.count("move_and_slide()") == 1, "Player must have exactly one move_and_slide call")
	for forbidden in ["move_and_slide", "velocity", "global_position", "Player", "move_speed"]:
		_check(not joystick_source.contains(forbidden), "Touch joystick must not reference %s" % forbidden)


func _touch(joystick: TouchJoystick, index: int, position: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = position
	event.pressed = pressed
	joystick.handle_input_event(event)


func _drag(joystick: TouchJoystick, index: int, position: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = position
	joystick.handle_input_event(event)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
