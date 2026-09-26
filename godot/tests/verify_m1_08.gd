extends SceneTree

const PORTRAIT_SIZE := Vector2(720.0, 1280.0)
const DESKTOP_WINDOW_SIZE := Vector2i(405, 720)

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_verify_project_settings()

	var main_scene := load("res://scenes/main.tscn") as PackedScene
	_check(main_scene != null, "Main scene must load")
	var main := main_scene.instantiate()
	main.save_path = ""  # M2-09: entering a city now saves; never touch the real save
	root.add_child(main)
	# Wait until the scene is inside the tree so _ready and the viewport exist.
	await physics_frame

	var visible_size := root.get_visible_rect().size
	_check(visible_size.is_equal_approx(PORTRAIT_SIZE), "Visible world must be the 720x1280 portrait rect")
	_check(visible_size.y > visible_size.x, "Visible world must be taller than wide")

	var player := main.get_node_or_null("Actors/Player") as Player
	var joystick := main.get_node_or_null("TouchControls/Joystick") as TouchJoystick
	_check(player != null, "Main scene must contain the player")
	_check(joystick != null, "M1-07 joystick must still load in portrait")
	_check(player._touch_joystick == joystick, "Player must still read the joystick")
	_check(joystick.get_viewport_rect().size.is_equal_approx(PORTRAIT_SIZE), "Joystick must use the portrait viewport")

	_verify_joystick_left_side(player, joystick)
	_verify_single_physics_path()

	if _failures == 0:
		print("M1-08 world portrait orientation verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_project_settings() -> void:
	_check(ProjectSettings.get_setting("display/window/size/viewport_width") == 720, "Viewport width must be 720")
	_check(ProjectSettings.get_setting("display/window/size/viewport_height") == 1280, "Viewport height must be 1280")
	_check(ProjectSettings.get_setting("display/window/handheld/orientation") == DisplayServer.SCREEN_PORTRAIT, "Handheld orientation must be portrait")
	_check(ProjectSettings.get_setting("display/window/stretch/mode") == "canvas_items", "Stretch mode must stay canvas_items")
	var desktop_window := Vector2i(
		ProjectSettings.get_setting("display/window/size/window_width_override"),
		ProjectSettings.get_setting("display/window/size/window_height_override")
	)
	_check(desktop_window == DESKTOP_WINDOW_SIZE, "Desktop test window override must be 405x720")
	_check(is_equal_approx(float(desktop_window.x) / desktop_window.y, PORTRAIT_SIZE.x / PORTRAIT_SIZE.y), "Desktop window must keep the portrait aspect")


func _verify_joystick_left_side(player: Player, joystick: TouchJoystick) -> void:
	_touch(joystick, 0, Vector2(500, 900), true)
	_check(not joystick.is_active(), "Right half of the portrait screen must not start the joystick")

	_touch(joystick, 0, Vector2(160, 1100), true)
	_check(joystick.is_active(), "Lower-left portrait press must start the joystick")
	_drag(joystick, 0, Vector2(160, 700))
	_check(player.get_movement_direction().is_equal_approx(Vector2.UP), "Portrait joystick must drive the player")
	_touch(joystick, 0, Vector2(160, 700), false)
	_check(player.get_movement_direction() == Vector2.ZERO, "Portrait release must stop the player")


func _verify_single_physics_path() -> void:
	var player_source := FileAccess.get_file_as_string("res://scripts/player.gd")
	_check(player_source.count("move_and_slide()") == 1, "Player must keep exactly one move_and_slide call")
	_check(player_source.contains("get_movement_direction() * move_speed"), "Player velocity must still come from the shared direction")


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
