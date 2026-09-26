extends SceneTree

const CYCLE_SEQUENCE := ["A", "A", "A", "B", "B", "B", "A", "B", "A", "B"]

var _checks := 0
var _failures := 0
var _main: Node2D
var _player: Player
var _joystick: TouchJoystick
var _hub: CityHub
var _city_a: CityMarker
var _city_b: CityMarker


func _initialize() -> void:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	_check(main_scene != null, "Main world scene must load")
	_main = main_scene.instantiate()
	root.add_child(_main)
	await _settle()

	_player = _main.get_node("Actors/Player") as Player
	_joystick = _main.get_node("TouchControls/Joystick") as TouchJoystick
	_hub = _main.get_node_or_null("CityHub") as CityHub
	_city_a = _main.get_node_or_null("Cities/CityA") as CityMarker
	_city_b = _main.get_node_or_null("Cities/CityB") as CityMarker

	_verify_structure()
	_verify_unchanged_world()
	await _verify_negative_cases()
	await _verify_return_points()
	await _verify_city_a_via_input()
	await _verify_city_b()
	await _verify_travel_a_to_b()
	await _verify_repeated_cycles()

	if _failures == 0:
		print("M2-02 city hub foundation verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_structure() -> void:
	_check(_city_a != null and _city_b != null, "City A and City B markers must exist")
	_check(_hub != null, "Main scene must contain the shared City Hub")
	_check(InputMap.has_action("interact"), "Interact action must exist")
	_check(_main.has_method("try_enter_city") and _main.has_method("enter_city"), "Enter must be callable")
	_check(_main.has_method("leave_city"), "Leave must be callable")
	_check(not _main.is_in_city() and not _hub.is_open(), "Game must start in the world")
	_check(_count_hubs(root) == 1, "Exactly one City Hub instance must exist")
	_check(_count_bodies(root) == 1, "Exactly one player body must exist")


func _verify_unchanged_world() -> void:
	_check(WorldLayout.WORLD_SIZE == Vector2(40000.0, 40000.0), "World must stay 40K")
	_check(WorldLayout.CITY_A == Vector2(200.0, 200.0) and WorldLayout.CITY_B == Vector2(39800.0, 200.0), "City anchors must not change")
	_check(_player.move_speed == 220.0, "Movement speed must stay 220")
	_check(_player._touch_joystick == _joystick, "Joystick must stay wired to the player")
	var player_source := FileAccess.get_file_as_string("res://scripts/player.gd")
	_check(player_source.count("move_and_slide()") == 1, "Player must keep one move_and_slide route")
	var joystick_source := FileAccess.get_file_as_string("res://scripts/touch_joystick.gd")
	_check(not joystick_source.contains("City"), "Joystick script must not know about cities")


func _verify_negative_cases() -> void:
	var spawn := _player.global_position
	_check(not _city_a.is_player_inside() and not _city_b.is_player_inside(), "Spawn must be outside city triggers")
	_check(not _main.try_enter_city(), "Enter must fail outside any city trigger")
	_check(not _main.enter_city("A"), "Enter A must fail outside the City A trigger")
	_check(not _main.is_in_city() and not _hub.is_open(), "Failed enter must leave the world state untouched")

	await _place(WorldLayout.CITY_A)
	for invalid_id in ["", "Z", "C", "D", "a"]:
		_check(not _main.enter_city(invalid_id), "Invalid or reserved city '%s' must not open the hub" % invalid_id)
	_check(not _main.enter_city("B"), "Standing in City A must not enter City B")
	_check(not _main.is_in_city(), "Rejected enters must not change the current city")

	_player.global_position = spawn
	_check(not _main.leave_city(), "Leave must fail while already in the world")
	_check(_player.global_position == spawn and not _main.is_in_city(), "Leave in the world must not move the player or change state")
	await _settle()


func _verify_return_points() -> void:
	_check(WorldLayout.CITY_RETURN_POINTS.keys() == ["A", "B"], "Only active cities may have return points")
	for city_id in WorldLayout.CITY_RETURN_POINTS:
		var point: Vector2 = WorldLayout.CITY_RETURN_POINTS[city_id]
		_check(WorldBoundary.BOUNDS.has_point(point), "City %s return point must be inside the world" % city_id)
		_check(point.distance_to(WorldLayout.CITY_ANCHORS[city_id]) < 600.0, "City %s return point must be near its city" % city_id)
		await _place(point)
		_check(not _city_a.is_player_inside() and not _city_b.is_player_inside(), "City %s return point must be outside every trigger" % city_id)
		_check(not _player.test_move(_player.global_transform, Vector2(0.5, 0.0)), "City %s return point must not overlap collision" % city_id)


func _verify_city_a_via_input() -> void:
	await _place(WorldLayout.CITY_A)
	_check(_city_a.is_player_inside(), "Player must be inside the City A trigger")
	_check(not _main.is_in_city(), "Standing in a trigger must not force entry")

	var interact := InputEventAction.new()
	interact.action = "interact"
	interact.pressed = true
	Input.parse_input_event(interact)
	await process_frame
	await process_frame
	var release := InputEventAction.new()
	release.action = "interact"
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame

	_check(_main.current_city_id == "A", "Interact inside City A must enter City A")
	_verify_hub_shows("A")
	await _verify_world_paused()
	_check(not _main.enter_city("B") and _main.current_city_id == "A", "Enter while in a hub must be rejected")

	(_hub.get_node("Center/Content/LeaveButton") as Button).pressed.emit()
	await _verify_returned_to("A")


func _verify_city_b() -> void:
	await _place(WorldLayout.CITY_B)
	_check(_main.try_enter_city(), "Enter must succeed inside City B")
	_check(_main.current_city_id == "B", "Hub current city must be B")
	_verify_hub_shows("B")
	_check(_main.leave_city(), "Leave B must succeed")
	await _verify_returned_to("B")


func _verify_travel_a_to_b() -> void:
	await _place(WorldLayout.CITY_A)
	_check(_main.try_enter_city() and _main.current_city_id == "A", "Travel test must start by entering A")
	_check(_main.leave_city(), "Travel test must leave A")
	await _verify_returned_to("A")

	# Travel: approach City B from the west and walk into its trigger.
	_player.global_position = WorldLayout.CITY_B - Vector2(420.0, 0.0)
	await _settle()
	Input.action_press("move_right")
	for frame in range(180):
		await physics_frame
		if _city_b.is_player_inside():
			break
	Input.action_release("move_right")
	await _settle()
	_check(_city_b.is_player_inside(), "Walking east must reach the City B trigger")
	_check(_main.try_enter_city() and _main.current_city_id == "B", "After travelling, enter must open City B")
	_verify_hub_shows("B")
	_check(_main.leave_city(), "After travelling, leave B must succeed")
	await _verify_returned_to("B")


func _verify_repeated_cycles() -> void:
	var cycles_ok := true
	for city_id in CYCLE_SEQUENCE:
		await _place(WorldLayout.CITY_ANCHORS[city_id])
		var entered: bool = _main.try_enter_city()
		var shown_ok: bool = _main.current_city_id == city_id and _hub.city_id == city_id \
			and _hub.get_city_label_text() == "【%s 城】" % city_id
		var left: bool = _main.leave_city()
		var returned_ok: bool = _player.global_position == WorldLayout.CITY_RETURN_POINTS[city_id]
		await _settle()
		var reset_ok: bool = not _main.is_in_city() and not _hub.is_open() and _hub.city_id == "" \
			and _player.is_physics_processing() and _joystick.is_processing_input() \
			and not _city_a.is_player_inside() and not _city_b.is_player_inside()
		if not (entered and shown_ok and left and returned_ok and reset_ok):
			cycles_ok = false
			push_error("FAILED: transition cycle for City %s" % city_id)
	_check(cycles_ok, "All %d enter/leave cycles must succeed" % CYCLE_SEQUENCE.size())
	_check(_count_hubs(root) == 1, "Repeated transitions must not leak City Hub instances")
	_check(_count_bodies(root) == 1, "Repeated transitions must not duplicate the player")
	_check(_hub.leave_requested.get_connections().size() == 1, "Leave signal must stay connected exactly once")
	var leave_button := _hub.get_node("Center/Content/LeaveButton") as Button
	_check(leave_button.pressed.get_connections().size() == 1, "Leave button must stay connected exactly once")
	_check(_city_a.body_entered.get_connections().size() == 1 and _city_b.body_entered.get_connections().size() == 1, "City triggers must not gain duplicate connections")
	_check(_player._touch_joystick == _joystick and _player.move_speed == 220.0, "Movement wiring must survive repeated transitions")


func _verify_hub_shows(city_id: String) -> void:
	var other := "B" if city_id == "A" else "A"
	_check(_hub.is_open(), "City Hub must be active after entering %s" % city_id)
	_check(_hub.city_id == city_id, "Hub current city must be %s" % city_id)
	_check(_hub.get_city_label_text() == "【%s 城】" % city_id, "Hub must display City %s" % city_id)
	_check(not _hub.get_city_label_text().contains(other), "Hub for %s must not display City %s" % [city_id, other])


func _verify_world_paused() -> void:
	_check(not _player.is_physics_processing(), "World movement must pause while the hub is open")
	_check(not _joystick.is_processing_input(), "Joystick must ignore touches while the hub is open")
	var before := _player.global_position
	Input.action_press("move_right")
	for frame in range(10):
		await physics_frame
	Input.action_release("move_right")
	_check(_player.global_position == before, "Keyboard must not move the player while in the hub")


func _verify_returned_to(city_id: String) -> void:
	var marker := _city_a if city_id == "A" else _city_b
	var other_anchor: Vector2 = WorldLayout.CITY_B if city_id == "A" else WorldLayout.CITY_A
	_check(not _main.is_in_city() and not _hub.is_open(), "Leave %s must return to the world" % city_id)
	_check(_hub.city_id == "", "Leave %s must clear the hub city" % city_id)
	_check(_player.global_position == WorldLayout.CITY_RETURN_POINTS[city_id], "Leave %s must use its return point" % city_id)
	_check(_player.global_position.distance_to(other_anchor) > 30000.0, "Leave %s must not return near the other city" % city_id)
	_check(not _main.try_enter_city() and not _main.is_in_city(), "Leave %s must not re-enter before physics catches up" % city_id)
	await _settle()
	_check(not marker.is_player_inside(), "Leave %s must not land inside its trigger" % city_id)
	_check(not _main.try_enter_city(), "Leave %s must not immediately re-enter" % city_id)
	_check(_player.is_physics_processing() and _joystick.is_processing_input(), "Leave %s must restore world input" % city_id)

	var camera := _player.get_node("Camera") as Camera2D
	_check(camera.enabled and camera.is_current(), "Leave %s must keep the player camera active" % city_id)
	var before := _player.global_position
	Input.action_press("move_down")
	for frame in range(10):
		await physics_frame
	Input.action_release("move_down")
	_check(_player.global_position.y > before.y, "Movement must work after leaving %s" % city_id)
	_check(camera.global_position.is_equal_approx(_player.global_position + Vector2(0.0, -24.0)), "Camera must follow after leaving %s" % city_id)
	_player.global_position = before
	await _settle()


func _place(position: Vector2) -> void:
	_player.global_position = position
	await _settle()


func _settle() -> void:
	# Area2D overlaps update a few physics frames after a teleport.
	for frame in range(4):
		await physics_frame
	await process_frame


func _count_hubs(node: Node) -> int:
	var total := 1 if node is CityHub else 0
	for child in node.get_children():
		total += _count_hubs(child)
	return total


func _count_bodies(node: Node) -> int:
	var total := 1 if node is CharacterBody2D else 0
	for child in node.get_children():
		total += _count_bodies(child)
	return total


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
