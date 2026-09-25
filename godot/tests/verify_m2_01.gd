extends SceneTree

const APPROVED_SPEED := 220.0
const A_TO_B_DISTANCE := 39600.0
const A_TO_B_SECONDS := 180.0
const PHYSICS_STEP := 1.0 / 60.0
const WALK_TOLERANCE := 5.0

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_verify_layout_constants()

	var main_scene := load("res://scenes/main.tscn") as PackedScene
	_check(main_scene != null, "Main scene must load")
	var main := main_scene.instantiate()
	root.add_child(main)
	# Wait until the scene is inside the tree so _ready, areas and physics exist.
	await physics_frame
	await physics_frame

	var player := main.get_node("Actors/Player") as Player
	var city_a := main.get_node_or_null("Cities/CityA") as CityMarker
	var city_b := main.get_node_or_null("Cities/CityB") as CityMarker

	_verify_existing_systems(main, player)
	_verify_cities(main, city_a, city_b)
	_verify_spawn(player, city_a)
	await _verify_boundary(player)
	await _verify_a_to_b_walk(player, city_a, city_b)

	if _failures == 0:
		print("M2-01 40K world and two corner cities verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_layout_constants() -> void:
	_check(WorldLayout.WORLD_SIZE == Vector2(40000.0, 40000.0), "World must be 40,000 x 40,000")
	_check(WorldBoundary.BOUNDS == Rect2(0.0, 0.0, 40000.0, 40000.0), "World boundary must use the 40K bounds")
	_check(WorldLayout.CITY_A == Vector2(200.0, 200.0), "City A anchor must be (200, 200)")
	_check(WorldLayout.CITY_B == Vector2(39800.0, 200.0), "City B anchor must be (39800, 200)")
	_check(WorldLayout.CITY_C == Vector2(200.0, 39800.0), "City C reserved anchor must be (200, 39800)")
	_check(WorldLayout.CITY_D == Vector2(39800.0, 39800.0), "City D reserved anchor must be (39800, 39800)")
	_check(WorldLayout.ACTIVE_CITY_IDS == ["A", "B"], "Only cities A and B may be active")
	_check(WorldLayout.RESERVED_CITY_IDS == ["C", "D"], "Cities C and D must be reserved")
	for city_id in WorldLayout.CITY_ANCHORS:
		_check(WorldBoundary.BOUNDS.has_point(WorldLayout.CITY_ANCHORS[city_id]), "City %s anchor must be inside the world" % city_id)

	var distance := WorldLayout.CITY_A.distance_to(WorldLayout.CITY_B)
	_check(is_equal_approx(distance, A_TO_B_DISTANCE), "A to B distance must be 39,600")
	_check(is_equal_approx(distance / APPROVED_SPEED, A_TO_B_SECONDS), "A to B theoretical travel time must be 180 seconds")


func _verify_existing_systems(main: Node, player: Player) -> void:
	_check(player.move_speed == APPROVED_SPEED, "Player speed must stay 220")
	var joystick := main.get_node_or_null("TouchControls/Joystick") as TouchJoystick
	_check(joystick != null and player._touch_joystick == joystick, "Joystick must stay wired to the player")
	var camera := player.get_node_or_null("Camera") as Camera2D
	_check(camera != null and camera.enabled, "Player must keep its enabled Camera2D")
	_check((main.get_node("Actors") as Node2D).y_sort_enabled, "Actors must keep Y-sort")

	Input.action_press("move_right")
	_check(player.get_movement_direction().is_equal_approx(Vector2.RIGHT), "Keyboard movement must still work")
	Input.action_release("move_right")
	_check(player.get_movement_direction() == Vector2.ZERO, "Keyboard release must still stop")

	var player_source := FileAccess.get_file_as_string("res://scripts/player.gd")
	_check(player_source.count("move_and_slide()") == 1, "Player must keep exactly one move_and_slide call")
	_check(player_source.contains("get_movement_direction() * move_speed"), "Velocity must still come from the shared direction")


func _verify_cities(main: Node, city_a: CityMarker, city_b: CityMarker) -> void:
	_check(city_a != null and city_b != null, "Cities A and B must exist")
	_check(city_a.global_position == WorldLayout.CITY_A, "City A marker must sit at its anchor")
	_check(city_b.global_position == WorldLayout.CITY_B, "City B marker must sit at its anchor")
	_check(city_a.get_node_or_null("TriggerShape") is CollisionShape2D, "City A must have a trigger zone")
	_check(city_b.get_node_or_null("TriggerShape") is CollisionShape2D, "City B must have a trigger zone")
	_check(city_a.monitoring and city_b.monitoring, "City triggers must monitor bodies")

	var city_ids := []
	for child in main.get_node("Cities").get_children():
		if child is CityMarker:
			city_ids.append((child as CityMarker).city_id)
	_check(city_ids == ["A", "B"], "Only cities A and B may have world markers")


func _verify_spawn(player: Player, city_a: CityMarker) -> void:
	var spawn := player.global_position
	_check(WorldBoundary.BOUNDS.has_point(spawn), "Spawn must be inside the world")
	_check(spawn.distance_to(WorldLayout.CITY_A) < 600.0, "Spawn must be near City A")
	_check(not player.test_move(player.global_transform, Vector2(0.5, 0.0)), "Spawn must not overlap collision")
	_check(not city_a.is_player_inside(), "Spawn must start just outside the City A trigger")

	var half_view := Vector2(720.0, 1280.0) / 2.0
	var camera_centre := player.get_node("Camera").global_position as Vector2
	var offset := (WorldLayout.CITY_A - camera_centre).abs()
	_check(offset.x < half_view.x and offset.y < half_view.y, "City A must be on screen at spawn")


func _verify_boundary(player: Player) -> void:
	var cases := [
		[Vector2(30.0, 20000.0), "move_left", Vector2(Player.BOUNDARY_MIN_OFFSET.x, 20000.0)],
		[Vector2(39970.0, 20000.0), "move_right", Vector2(40000.0 - Player.BOUNDARY_MAX_OFFSET.x, 20000.0)],
		[Vector2(20000.0, 70.0), "move_up", Vector2(20000.0, Player.BOUNDARY_MIN_OFFSET.y)],
		[Vector2(20000.0, 39990.0), "move_down", Vector2(20000.0, 40000.0 - Player.BOUNDARY_MAX_OFFSET.y)],
	]
	for case in cases:
		player.global_position = case[0]
		Input.action_press(case[1])
		for step in range(60):
			player._physics_process(PHYSICS_STEP)
		Input.action_release(case[1])
		_check(player.global_position.is_equal_approx(case[2]), "Boundary must stop %s at the 40K edge" % case[1])
	await physics_frame


func _verify_a_to_b_walk(player: Player, city_a: CityMarker, city_b: CityMarker) -> void:
	player.global_position = WorldLayout.CITY_A
	await physics_frame
	await physics_frame
	_check(city_a.is_player_inside(), "Standing at City A centre must be inside its trigger")
	_check(not city_b.is_player_inside(), "Player at City A must not be inside City B")

	var steps := roundi(A_TO_B_SECONDS / PHYSICS_STEP)
	Input.action_press("move_right")
	for step in range(steps):
		player._physics_process(PHYSICS_STEP)
	Input.action_release("move_right")

	var arrival := player.global_position
	_check(absf(arrival.x - WorldLayout.CITY_B.x) <= WALK_TOLERANCE, "180 seconds east from City A must reach City B (x=%.2f)" % arrival.x)
	_check(is_equal_approx(arrival.y, WorldLayout.CITY_B.y), "The top-edge route from A to B must be unobstructed")

	await physics_frame
	await physics_frame
	_check(city_b.is_player_inside(), "Arriving at City B must enter its trigger")
	_check(not city_a.is_player_inside(), "Leaving City A must exit its trigger")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
