extends SceneTree

## World Threat WT05: the prototype monster patrols a fixed loop inside
## low_threat_zone_01 while IDLE, and every WT02-WT04 rule still holds with
## patrol on. Real main scene, physics frames, fixed TimeSource (no sleeps).

const TEST_SAVE := "user://wt05_patrol_test_save.json"
const T0 := 1800000000000
const MONSTER_ID := "prototype_monster_01"
## E02 fix pass: home (800, 700) and a controlled irregular itinerary (four
## points revisited in a varied order, with pauses) instead of the WT05 loop.
const HOME := Vector2(800.0, 700.0)
const ROUTE := [Vector2(900.0, 640.0), Vector2(900.0, 790.0), Vector2(800.0, 700.0), Vector2(740.0, 640.0), Vector2(760.0, 790.0), Vector2(900.0, 790.0), Vector2(900.0, 640.0), Vector2(800.0, 700.0)]
const PATROL_SPEED := 60.0
const CITY_A := Vector2(200.0, 200.0)
const FAR := Vector2(3000.0, 3000.0)
## Within aggro range of the first stop (900, 640) but not of home.
const WAIT_SPOT := Vector2(1100.0, 560.0)
const ZONE_MARGIN := 100.0

var _checks := 0
var _failures := 0
var _sections_done := []
var _events := []
var _states := []
var _encounters := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	await _verify_route_geometry()
	await _verify_patrol()
	await _verify_aggro_chase_return()
	await _verify_safe_buffer_retreat()
	await _verify_encounter()
	await _verify_world_only()
	await _verify_reload()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 8, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("WT05 patrol verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(WorldLayout.PROTOTYPE_MONSTER_ID == MONSTER_ID and WorldLayout.PROTOTYPE_MONSTER_POSITION == HOME, "Monster id and home unchanged")
	_check(WorldLayout.PROTOTYPE_MONSTER_PATROL == ROUTE and ROUTE.back() == HOME, "Fixed patrol loop, ending back at home")
	_check(WorldMonster.PATROL_SPEED == PATROL_SPEED and WorldMonster.PATROL_SPEED < WorldMonster.MOVE_SPEED and WorldMonster.MOVE_SPEED == 160.0, "Patrol 60 px/s, slower than the 160 px/s chase")
	_check(WorldMonster.PATROL_TEXT == "巡邏", "Patrol indicator 巡邏")
	var zone := WorldThreatZones.LOW_THREAT_ZONE_01.grow(-ZONE_MARGIN)
	var legs_ok := true
	var buffer_ok := true
	var bounds_ok := true
	for index in range(ROUTE.size()):
		var from: Vector2 = ROUTE[index - 1]
		var to: Vector2 = ROUTE[index]
		for step in range(101):
			var point := from.lerp(to, step / 100.0)
			legs_ok = legs_ok and zone.has_point(point)
			buffer_ok = buffer_ok and not WorldThreatZones.is_in_city_safe_buffer(point) \
				and point.distance_to(CITY_A) > WorldThreatZones.CITY_SAFE_BUFFER_RADIUS + WorldMonster.AGGRO_RADIUS
			bounds_ok = bounds_ok and PlayerLocation.is_valid_world_position(point)
	_check(legs_ok, "Every patrol point and leg is well inside low_threat_zone_01 (%d px margin)" % ZONE_MARGIN)
	_check(buffer_ok, "The patrol never nears a city safe buffer (not even its aggro circle)")
	_check(bounds_ok, "The patrol stays inside the world")
	for spot in [PlayerLocation.DEFAULT_WORLD_SPAWN, WorldLayout.CITY_RETURN_POINTS["A"]]:
		var nearest := INF
		for index in range(ROUTE.size()):
			nearest = minf(nearest, Geometry2D.get_closest_point_to_segment(spot, ROUTE[index - 1], ROUTE[index]).distance_to(spot))
		_check(nearest > WorldMonster.AGGRO_RADIUS, "The patrol never brings aggro range to %s (%.0f px)" % [spot, nearest])
	var monster := _code_only("res://scripts/world_monster.gd") + _code_only("res://scripts/world_layout.gd")
	for word in ["randi", "randf", "RandomNumberGenerator", "randomize", "Navigation", "AStar", "spawn"]:
		_check(not monster.contains(word), "No %s in the monster / layout" % word)
	_check(not _code_only("res://scripts/save_store.gd").to_lower().contains("patrol"), "The save format knows nothing about patrol")
	_check(SaveStore.VERSION == 8, "No save schema change (still version 8)")
	var scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_check(scene.count("world_monster.tscn") == 1 and scene.count("[node name=\"PrototypeMonster\"") == 1, "Exactly one monster in the main scene")
	_sections_done.append("static")


# --- Route geometry vs obstacles ------------------------------------------------------------------

func _verify_route_geometry() -> void:
	var main := await _new_main("")
	var clear := true
	for index in range(ROUTE.size()):
		for step in range(101):
			clear = clear and not _circle_hits_static(main, (ROUTE[index - 1] as Vector2).lerp(ROUTE[index], step / 100.0), WorldMonster.BODY_RADIUS + 2.0)
	_check(clear, "Every patrol leg is a straight line clear of both obstacles")
	_check(main.find_children("*", "WorldMonster", true, false).size() == 1, "Exactly one WorldMonster at runtime")
	await _destroy(main)
	_sections_done.append("route_geometry")


# --- Patrol ------------------------------------------------------------------------------------

func _verify_patrol() -> void:
	var main := await _new_main("", T0, false)
	var monster := _monster(main)
	_listen(main)
	_check(monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE and monster.get_patrol_index() == 0, "Starts at home, IDLE, heading for the first patrol point")
	_check((monster.get_node("StateLabel") as Label).text == "巡邏", "Patrol indicator shown")
	var max_step := PATROL_SPEED / Engine.physics_ticks_per_second + 0.01
	var smooth := true
	var in_zone := true
	var safe := true
	var clean := true
	var reached := []
	var at_points := true
	var farthest := 0.0
	var index := monster.get_patrol_index()
	# One full itinerary (8 stops, ~21 s with pauses) and the start of the next.
	for frame in range(1400):
		var before := monster.global_position
		await physics_frame
		smooth = smooth and before.distance_to(monster.global_position) <= max_step
		in_zone = in_zone and WorldThreatZones.threat_zone_at(monster.global_position) == WorldThreatZones.LOW_THREAT_ZONE_01_ID
		safe = safe and not WorldThreatZones.is_in_city_safe_buffer(monster.global_position) and PlayerLocation.is_valid_world_position(monster.global_position)
		clean = clean and not _circle_hits_static(main, monster.global_position, WorldMonster.BODY_RADIUS - 0.5)
		farthest = maxf(farthest, monster.global_position.distance_to(HOME))
		if monster.get_patrol_index() != index:
			at_points = at_points and monster.global_position == ROUTE[index]
			reached.append(index)
			index = monster.get_patrol_index()
	_check(_states.is_empty() and _events.is_empty(), "No player nearby: patrols without aggro or contact")
	_check(farthest > 80.0, "The monster visibly moves (up to %.0f px from home)" % farthest)
	_check(smooth, "Patrol steps never exceed %.2f px (60 px/s, no teleport)" % max_step)
	_check(reached.slice(0, 9) == [0, 1, 2, 3, 4, 5, 6, 7, 0], "Deterministic order: the whole itinerary, then again (%s)" % str(reached))
	_check(at_points, "Each patrol point is reached exactly")
	_check(in_zone, "Patrol stays inside low_threat_zone_01")
	_check(safe, "Patrol never enters a city safe buffer or leaves the world")
	_check(clean, "Patrol never overlaps an obstacle")
	# The encounter hold freezes the patrol itself too (in play the monster is
	# always chasing when caught, since aggro range exceeds contact range).
	monster.set_hold(true)
	var held_at := monster.global_position
	var held_index := monster.get_patrol_index()
	await _frames(120)
	_check(monster.global_position == held_at and monster.get_patrol_index() == held_index and (monster.get_node("StateLabel") as Label).text == "遭遇觸發", "Held while patrolling: position and patrol target frozen")
	monster.set_hold(false)
	await _frames(10)
	_check(monster.global_position != held_at and (monster.get_node("StateLabel") as Label).text == "巡邏", "Released: the patrol carries on")
	await _destroy(main)
	_sections_done.append("patrol")


# --- Aggro, chase, return, resume -------------------------------------------------------------------

func _verify_aggro_chase_return() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	_listen(main)
	# Out of range: patrol continues.
	player.global_position = FAR
	await _frames(120)
	_check(_states.is_empty() and monster.global_position != HOME, "Player far away: patrol continues, no chase")
	# The patrol brings the monster into range of a waiting player.
	_check(WAIT_SPOT.distance_to(HOME) > WorldMonster.AGGRO_RADIUS, "Test setup: the waiting spot is out of range of home")
	player.global_position = WAIT_SPOT
	var gap_at_aggro := [0.0]
	var frames := 0
	while _states.is_empty() and frames < 900:
		await physics_frame
		frames += 1
		gap_at_aggro[0] = monster.global_position.distance_to(player.global_position)
	_check(_states == [WorldMonster.State.CHASE] and gap_at_aggro[0] <= WorldMonster.AGGRO_RADIUS + 1.0, "Patrolling into range of the player: CHASE (%.0f px)" % gap_at_aggro[0])
	_check((monster.get_node("StateLabel") as Label).text == "追擊", "Chase indicator shown")
	# Chase: WT02 speed, closing in.
	await physics_frame
	var chase_ok := true
	var chase_steps := []
	for frame in range(20):
		var before := monster.global_position
		var gap := before.distance_to(player.global_position)
		await physics_frame
		chase_steps.append(before.distance_to(monster.global_position))
		chase_ok = chase_ok and monster.global_position.distance_to(player.global_position) < gap
	var fastest: float = chase_steps.max()
	_check(chase_ok and absf(fastest - WorldMonster.MOVE_SPEED / Engine.physics_ticks_per_second) < 0.05, "The chase closes in at 160 px/s (%.2f px/frame)" % fastest)
	# Escape past the leash -> RETURNING -> home -> patrol resumes.
	frames = await _walk(player, "move_right", func() -> bool: return monster.get_state() == WorldMonster.State.RETURNING)
	_check(frames < 300 and _states == [WorldMonster.State.CHASE, WorldMonster.State.RETURNING], "Escaping past the leash: RETURNING")
	player.global_position = FAR
	frames = 0
	while monster.get_state() != WorldMonster.State.IDLE and frames < 600:
		await physics_frame
		frames += 1
	_check(monster.global_position == HOME and monster.get_patrol_index() == 0 and _states == [1, 2, 0], "Back exactly at home, IDLE, patrol loop restarted")
	var to_first := monster.global_position.distance_to(ROUTE[0])
	await _frames(60)
	_check(monster.global_position.distance_to(ROUTE[0]) < to_first - 50.0 and (monster.get_node("StateLabel") as Label).text == "巡邏", "Patrol resumes toward the first point")
	await _destroy(main)
	_sections_done.append("aggro_chase_return")


# --- Safe buffer retreat ------------------------------------------------------------------------

func _verify_safe_buffer_retreat() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	_listen(main)
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city() and main.leave_city(), "Left City A")
	await _frames(60)
	_check(_states.is_empty(), "Leaving City A: safe while the monster patrols")
	var frames := await _walk(player, "move_down", func() -> bool: return player.global_position.y >= 650.0 or not _states.is_empty())
	# Wait by the patrol's west side until the monster comes into range.
	frames = 0
	while _states.is_empty() and frames < 900:
		await physics_frame
		frames += 1
	_check(_states == [WorldMonster.State.CHASE] and not WorldThreatZones.is_in_city_safe_buffer(player.global_position), "The patrol comes within range: CHASE (%d frames)" % frames)
	var deepest := [INF]
	frames = await _walk(player, "move_up", func() -> bool:
		deepest[0] = minf(deepest[0], monster.global_position.distance_to(CITY_A))
		return _states.size() >= 2)
	_check(frames < 300 and _states == [1, 2] and WorldThreatZones.safe_buffer_city_at(player.global_position) == "A" and player.global_position.distance_to(HOME) < WorldMonster.LEASH_RADIUS, "Retreating into City A's safe buffer forces RETURNING")
	frames = 0
	while monster.get_state() != WorldMonster.State.IDLE and frames < 600:
		await physics_frame
		frames += 1
		deepest[0] = minf(deepest[0], monster.global_position.distance_to(CITY_A))
	_check(deepest[0] > WorldThreatZones.CITY_SAFE_BUFFER_RADIUS and monster.global_position == HOME and _states == [1, 2, 0], "The monster never entered the buffer, returned home and patrols again")
	await _destroy(main)
	_sections_done.append("safe_buffer_retreat")


# --- Encounter -------------------------------------------------------------------------------------

func _verify_encounter() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	var handoff := main.get_node("EncounterHandoff") as EncounterHandoff
	_listen(main)
	await _frames(90)
	player.global_position = monster.global_position + Vector2(150.0, 0.0)
	var frames := 0
	while _encounters.is_empty() and frames < 300:
		await physics_frame
		frames += 1
	_check(_encounters.size() == 1 and (_encounters[0] as EncounterContext).monster_id == MONSTER_ID, "Chase during patrol catches the player: one Encounter Trigger")
	var frozen := monster.global_position
	var frozen_index := monster.get_patrol_index()
	var frozen_state := monster.get_state()
	await _frames(180)
	_check(monster.global_position == frozen and monster.get_patrol_index() == frozen_index and monster.get_state() == frozen_state and (monster.get_node("StateLabel") as Label).text == "遭遇觸發", "Pending: the monster and its patrol stay frozen")
	_check(_encounters.size() == 1, "Pending: no duplicate trigger")
	# Consume: normal continuation (escape, return, patrol).
	_check(handoff.consume_pending_encounter() != null and not monster.is_held(), "Consume releases the monster")
	player.global_position = FAR
	frames = 0
	while monster.get_state() != WorldMonster.State.IDLE and frames < 600:
		await physics_frame
		frames += 1
	await _frames(60)
	_check(monster.get_state() == WorldMonster.State.IDLE and monster.global_position != HOME and monster.get_patrol_index() == 0 and _encounters.size() == 1, "After the consume: returned and patrolling again")
	# Caught again, then leave WORLD: cancel resets the patrol.
	player.global_position = monster.global_position + Vector2(150.0, 0.0)
	frames = 0
	while _encounters.size() < 2 and frames < 300:
		await physics_frame
		frames += 1
	_check(_encounters.size() == 2 and handoff.has_pending_encounter(), "Caught again: a second trigger")
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city() and not handoff.has_pending_encounter() and not monster.is_held() and monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE and monster.get_patrol_index() == 0, "Entering the city cancels it: home, IDLE, patrol from the start")
	await _destroy(main)
	_sections_done.append("encounter")


# --- WORLD only ----------------------------------------------------------------------------------

func _verify_world_only() -> void:
	var reference := await _patrol_track("", 150)
	var main := await _new_main(TEST_SAVE, T0)
	var monster := _monster(main)
	var player := _player(main)
	_listen(main)
	await _frames(100)
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city() and monster.global_position == HOME and monster.get_patrol_index() == 0, "IN_CITY: the monster is back at home")
	await _frames(120)
	_check(monster.global_position == HOME and monster.get_patrol_index() == 0, "IN_CITY: no patrol")
	_check(main.request_transport("B", "wt05-ride")["success"] and main.is_traveling(), "TRAVELING")
	await _frames(120)
	_check(monster.global_position == HOME and monster.get_patrol_index() == 0, "TRAVELING: no patrol")
	player.global_position = FAR
	main.time_source.advance_ms(90000)
	await process_frame
	await process_frame
	_check(main.current_city_id == "B" and main.leave_city() and main.location.is_in_world(), "Back in WORLD at City B")
	var track := []
	for frame in range(150):
		await physics_frame
		track.append(monster.global_position)
	_check(track == reference, "Back in WORLD the patrol restarts exactly like a fresh start")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("world_only")


# --- Reload --------------------------------------------------------------------------------------

func _verify_reload() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var player := _player(main)
	await _frames(200)
	_check(_monster(main).global_position != HOME, "Test setup: saved while the monster is mid-patrol")
	player.global_position = Vector2(1500.5, 2500.25)
	_check(main.save_world_position(), "Exact world position saves")
	var text := FileAccess.get_file_as_string(TEST_SAVE)
	_check(int(JSON.parse_string(text)["version"]) == 8 and not text.to_lower().contains("patrol") and not text.to_lower().contains("monster"), "Save version 8; nothing about patrol or the monster")
	await _destroy(main)
	var reference := await _patrol_track("", 200)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	_single_group(main)
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	_check(main.get_world_position() == Vector2(1500.5, 2500.25), "Reload restores the exact player position")
	_check(_monster(main).global_position == HOME and _monster(main).get_patrol_index() == 0 and _monster(main).get_state() == WorldMonster.State.IDLE, "Reload: the monster starts at home, patrol from the start")
	var track := []
	for frame in range(200):
		await physics_frame
		track.append(_monster(main).global_position)
	_check(track == reference, "Reload resumes the same deterministic patrol")
	_check(main.find_children("*", "WorldMonster", true, false).size() == 1, "Still exactly one monster")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("reload")


# --- Helpers ------------------------------------------------------------------------------------

## The monster's position on each of `frames` physics frames after a fresh
## main scene is added (player far away).
func _patrol_track(path: String, frames: int) -> Array:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	_single_group(main)
	main.save_path = path
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	var track := []
	for frame in range(frames):
		await physics_frame
		track.append(_monster(main).global_position)
	await _destroy(main)
	return track


func _listen(main: Node) -> void:
	_events.clear()
	_states.clear()
	_encounters.clear()
	_monster(main).player_contacted.connect(func(id: String) -> void: _events.append(id))
	_monster(main).state_changed.connect(func(_id: String, state: int) -> void: _states.append(state))
	(main.get_node("EncounterHandoff") as EncounterHandoff).encounter_triggered.connect(func(context: EncounterContext) -> void: _encounters.append(context))


func _circle_hits_static(main: Node, center: Vector2, radius: float) -> bool:
	var query := PhysicsShapeQueryParameters2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	query.shape = circle
	query.transform = Transform2D(0.0, center)
	for hit in main.get_world_2d().direct_space_state.intersect_shape(query, 32):
		if hit["collider"] is StaticBody2D:
			return true
	return false


## Holds a move action for physics frames until `done` or 300 frames.
func _walk(player: Player, action: String, done: Callable) -> int:
	var frames := 0
	Input.action_press(action)
	while not done.call() and frames < 300:
		await physics_frame
		frames += 1
	Input.action_release(action)
	await physics_frame
	return frames


func _frames(count: int) -> void:
	for frame in range(count):
		await physics_frame


func _monster(main: Node) -> WorldMonster:
	return main.get_node("Actors/PrototypeMonster") as WorldMonster


func _player(main: Node) -> Player:
	return main.get_node("Actors/Player") as Player


func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


## `settle` false keeps the monster exactly at its start (no physics frames).
func _new_main(path: String, now: int = T0, settle := true) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	_single_group(main)
	main.save_path = path
	main.time_source = TimeSource.fixed(now)
	root.add_child(main)
	if settle:
		await _settle()
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _delete(path: String) -> void:
	for p in [path, path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _settle() -> void:
	# Area2D overlaps update a few physics frames after a teleport.
	for frame in range(4):
		await physics_frame
	await process_frame


## E02: only World Enemy Group 1 (groups 2 and 3 removed before the scene
## starts): the one-group world these checks were written for;
## verify_e02_multi_group covers all three groups.
func _single_group(main: Node) -> void:
	for extra in ["Actors/PrototypeMonster2", "Actors/PrototypeMonster3"]:
		main.get_node(extra).free()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
