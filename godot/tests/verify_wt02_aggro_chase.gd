extends SceneTree

## World Threat WT02: the prototype monster's IDLE -> CHASE -> RETURNING -> IDLE
## loop. Uses the real main scene, physics frames and a fixed TimeSource (no
## sleeps). Positions are chosen clear of obstacles, cities and return points.

const TEST_SAVE := "user://wt02_aggro_chase_test_save.json"
const T0 := 1800000000000
const MONSTER_ID := "prototype_monster_01"
## WT02 review: moved from (720, 320), away from City A's exit.
const HOME := Vector2(760.0, 650.0)
const PLAYER_SPEED := 220.0
const FAR := Vector2(3000.0, 3000.0)
## Just outside / inside the aggro radius, on the open ground east of home.
const OUTSIDE_AGGRO := Vector2(980.0, 650.0)
const INSIDE_AGGRO := Vector2(950.0, 650.0)
## Leaving a city must leave at least this much room before the aggro edge.
const CITY_EXIT_BUFFER := 100.0
const PLAYER_SIZE := Vector2(32, 48)
const PLAYER_OFFSET := Vector2(0, -24)
const CONTACT_RADIUS := 48.0
const RIGHT_OBSTACLE := Rect2(830.0, 460.0, 240.0, 40.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _events := []
var _states := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	await _verify_start()
	await _verify_placement()
	await _verify_aggro_chase_disengage()
	await _verify_obstacles()
	await _verify_bounds()
	await _verify_world_only()
	await _verify_save()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 8, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("WT02 aggro chase verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(WorldLayout.PROTOTYPE_MONSTER_ID == MONSTER_ID and WorldLayout.PROTOTYPE_MONSTER_POSITION == HOME, "Stable id and home are layout data")
	_check(WorldMonster.AGGRO_RADIUS == 200.0, "Aggro radius 200 (WT02 review: was 250)")
	_check(WorldMonster.LEASH_RADIUS == 450.0 and WorldMonster.LEASH_RADIUS >= WorldMonster.AGGRO_RADIUS + 150.0, "Leash 450, well beyond the aggro radius")
	_check(WorldMonster.MOVE_SPEED == 160.0 and WorldMonster.MOVE_SPEED < PLAYER_SPEED, "Chase speed 160 px/s, slower than the player")
	_check(WorldMonster.CHASE_STOP_DISTANCE < 48.0, "The chase closes into contact range")
	_check(WorldMonster.STATE_TEXT.size() == 3 and WorldMonster.STATE_TEXT.values() == ["待機", "追擊", "返回"], "Traditional Chinese state text for IDLE / CHASE / RETURNING")
	var script := _code_only("res://scripts/world_monster.gd")
	for word in ["randi", "randf", "RandomNumberGenerator", "randomize", "seed(", "Time.", "OS.", "Navigation", "AStar", "astar", "patrol", "encounter", "combat", "damage", "health", "respawn", "loot", "spawn"]:
		_check(not script.contains(word), "Not in the monster: %s" % word)
	for path in ["res://scripts/main.gd", "res://scripts/player.gd", "res://scripts/world_layout.gd"]:
		var code := _code_only(path)
		_check(not code.contains("Navigation") and not code.contains("AStar"), "No navigation / pathfinding in %s" % path)
	_check(not _code_only("res://scripts/save_store.gd").to_lower().contains("monster"), "The save format knows nothing about the monster")
	_check(SaveStore.VERSION == 8, "No save schema change (still version 8)")
	var scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_check(scene.count("world_monster.tscn") == 1 and scene.count("[node name=\"PrototypeMonster\"") == 1 and not scene.contains("Navigation"), "Still exactly one monster, no navigation nodes")
	_sections_done.append("static")


# --- Start state ---------------------------------------------------------------------------------

func _verify_start() -> void:
	var first := await _new_main("")
	var first_home: Vector2 = _monster(first).home_position
	await _destroy(first)
	var main := await _new_main("")
	var monster := _monster(main)
	_check(monster.monster_id == MONSTER_ID, "Stable monster id")
	_check(monster.home_position == first_home and monster.home_position == HOME, "Home is the same on every run")
	_check(monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE, "Starts IDLE at home")
	_check(_state_text(monster) == "待機" and (monster.get_node("StateLabel") as Label).is_visible_in_tree(), "Idle indicator shown")
	_check(_player(main).global_position.distance_to(HOME) > WorldMonster.AGGRO_RADIUS, "The new-game spawn is outside the aggro radius")
	for frame in range(60):
		await physics_frame
	_check(monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE, "A new game stays idle at home")
	await _destroy(main)
	_sections_done.append("start")


# --- Placement (WT02 review) ------------------------------------------------------------------------

func _verify_placement() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	_check(PlayerLocation.is_valid_world_position(HOME) and WorldBoundary.BOUNDS.grow(-WorldMonster.BODY_RADIUS).has_point(HOME), "Home is inside the playable world bounds")
	_check(not _overlaps_static(main, HOME + PLAYER_OFFSET, PLAYER_SIZE), "No obstacle under a player standing on home")
	_check(not _circle_hits_static(main, HOME, CONTACT_RADIUS), "The contact area overlaps no obstacle")
	_check(not _monster_in_obstacle(main, monster, 0.0), "The monster's body is clear of obstacles at home")
	for city in WorldLayout.ACTIVE_CITY_IDS:
		var marker := main.get_node("Cities/City%s" % city) as CityMarker
		var trigger := ((marker.get_node("TriggerShape") as CollisionShape2D).shape as CircleShape2D).radius
		_check(HOME.distance_to(marker.global_position) > trigger + WorldMonster.AGGRO_RADIUS, "City %s's entry trigger is entirely outside the aggro radius" % city)
		var exit: Vector2 = WorldLayout.CITY_RETURN_POINTS[city]
		_check(exit.distance_to(HOME) > WorldMonster.AGGRO_RADIUS + CITY_EXIT_BUFFER, "City %s's return point is %.0f px from home: safely outside the aggro radius" % [city, exit.distance_to(HOME)])
		_check(exit.distance_to(HOME) > CONTACT_RADIUS + WorldMonster.AGGRO_RADIUS, "City %s's return point is clear of the monster" % city)
	_check(PlayerLocation.DEFAULT_WORLD_SPAWN.distance_to(HOME) > WorldMonster.AGGRO_RADIUS + CITY_EXIT_BUFFER and PlayerLocation.DEFAULT_WORLD_SPAWN.distance_to(HOME) < 600.0, "A short walk from the new-game spawn, which is safely outside the aggro radius")
	# Reachable with normal movement, and the chase starts only once the player
	# deliberately walks into the radius.
	_listen(monster)
	var frames := await _walk(player, "move_down", func() -> bool: return player.global_position.y >= HOME.y)
	_check(frames < 300 and _states.is_empty(), "Walked down from the spawn: still outside the radius, idle (%d frames)" % frames)
	var entered_at := [0.0]
	frames = await _walk(player, "move_right", func() -> bool:
		if _states.is_empty():
			entered_at[0] = player.global_position.distance_to(HOME)
			return false
		return true)
	_check(frames < 300 and _states == [WorldMonster.State.CHASE], "Walking right toward the monster starts the chase (%d frames)" % frames)
	_check(entered_at[0] <= WorldMonster.AGGRO_RADIUS and entered_at[0] > WorldMonster.AGGRO_RADIUS - 10.0, "The chase starts at the aggro edge (%.1f px)" % entered_at[0])
	await _destroy(main)
	_sections_done.append("placement")


# --- Aggro, chase, contact, disengage, return, second cycle -----------------------------------------

func _verify_aggro_chase_disengage() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	_listen(monster)
	var max_step := WorldMonster.MOVE_SPEED / Engine.physics_ticks_per_second + 0.01

	# Outside the radius: nothing happens.
	player.global_position = OUTSIDE_AGGRO
	await _frames(120)
	_check(OUTSIDE_AGGRO.distance_to(HOME) > WorldMonster.AGGRO_RADIUS and monster.get_state() == WorldMonster.State.IDLE and monster.global_position == HOME and _states.is_empty(), "Outside the aggro radius: no chase, no movement")

	# Entering: exactly one CHASE transition, then the gap closes smoothly.
	player.global_position = INSIDE_AGGRO
	await physics_frame
	await physics_frame
	_check(_states == [WorldMonster.State.CHASE] and _state_text(monster) == "追擊", "Entering the radius starts the chase (%s)" % str(_states))
	var gap := monster.global_position.distance_to(player.global_position)
	var closing := true
	var smooth := true
	var in_bounds := true
	for frame in range(40):
		var before := monster.global_position
		await physics_frame
		var now := monster.global_position.distance_to(player.global_position)
		closing = closing and now < gap
		smooth = smooth and before.distance_to(monster.global_position) <= max_step
		in_bounds = in_bounds and PlayerLocation.is_valid_world_position(monster.global_position)
		gap = now
	_check(closing, "Every chase step reduces the distance to the player")
	_check(smooth, "Chase steps never exceed %.2f px (no teleport)" % max_step)
	_check(in_bounds, "The chase stays inside the world")

	# Contact while chasing: once per overlap, the chase continues.
	await _frames(120)
	_check(_events == [MONSTER_ID] and monster.is_in_contact(), "The chase reaches the player: exactly one contact (%s)" % str(_events))
	_check(monster.global_position.distance_to(player.global_position) <= WorldMonster.CHASE_STOP_DISTANCE + 0.5, "The monster holds at the stop distance")
	await _frames(120)
	_check(_events.size() == 1 and monster.get_state() == WorldMonster.State.CHASE and _states == [WorldMonster.State.CHASE], "Continuous overlap while chasing: one event, one CHASE transition")
	_check(player.global_position == INSIDE_AGGRO and player.is_physics_processing() and main.location.is_in_world(), "Contact changes no player state or mode")
	player.global_position = INSIDE_AGGRO + Vector2(200.0, 0.0)
	await _settle()
	_check(not monster.is_in_contact() and _events.size() == 1 and monster.get_state() == WorldMonster.State.CHASE, "Stepping out of contact (still inside the leash): no event, still chasing")
	await _frames(120)
	_check(_events == [MONSTER_ID, MONSTER_ID], "The chase catches up again: one new contact event")

	# Disengage: the player walks away with normal movement and escapes.
	var start_gap := monster.global_position.distance_to(player.global_position)
	var frames := await _walk(player, "move_right", func() -> bool: return monster.get_state() != WorldMonster.State.CHASE)
	_check(frames < 300 and monster.get_state() == WorldMonster.State.RETURNING, "Walking away creates the disengage condition (%d frames)" % frames)
	_check(player.global_position.distance_to(HOME) > WorldMonster.LEASH_RADIUS and monster.global_position.distance_to(player.global_position) > start_gap, "The player outran the monster past the leash")
	_check(_states == [WorldMonster.State.CHASE, WorldMonster.State.RETURNING] and _state_text(monster) == "返回", "Disengage enters RETURNING once (%s)" % str(_states))

	# Returning: toward home, ignoring the player until it is home.
	# The player stands inside the radius, right on the way home.
	player.global_position = HOME + Vector2(150.0, 60.0)
	await _settle()
	await physics_frame  # align samples: each later await follows one monster step
	var home_gap := monster.global_position.distance_to(HOME)
	var homing := true
	smooth = true
	var ignored := true
	frames = 0
	while monster.get_state() == WorldMonster.State.RETURNING and frames < 600:
		var before := monster.global_position
		await physics_frame
		frames += 1
		if monster.get_state() == WorldMonster.State.RETURNING:
			homing = homing and monster.global_position.distance_to(HOME) < home_gap
			home_gap = monster.global_position.distance_to(HOME)
		smooth = smooth and before.distance_to(monster.global_position) <= maxf(max_step, WorldMonster.HOME_SNAP_DISTANCE)
		ignored = ignored and (monster.get_state() != WorldMonster.State.CHASE or before == HOME)
	_check(homing, "Every return step gets closer to home")
	_check(smooth, "Return steps never jump (no teleport)")
	_check(ignored, "RETURNING ignores the player until home")
	_check(frames < 600 and _states.slice(0, 3) == [WorldMonster.State.CHASE, WorldMonster.State.RETURNING, WorldMonster.State.IDLE], "Reaching home ends the return in IDLE (%s)" % str(_states))

	# Home with the player still inside the radius: the next cycle starts.
	await physics_frame
	await physics_frame
	_check(_states == [WorldMonster.State.CHASE, WorldMonster.State.RETURNING, WorldMonster.State.IDLE, WorldMonster.State.CHASE], "Idle at home with the player inside the radius: a second chase (%s)" % str(_states))
	player.global_position = FAR
	await _frames(300)
	_check(monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE and _state_text(monster) == "待機", "Second cycle: back exactly at home, IDLE")
	_check(_states == [1, 2, 0, 1, 2, 0], "Two full cycles, no extra transitions (%s)" % str(_states))
	await _frames(120)
	_check(_states.size() == 6 and monster.global_position == HOME, "Idle with the player far away: no further transitions")
	await _destroy(main)
	_sections_done.append("cycle")


# --- Obstacles --------------------------------------------------------------------------------

func _verify_obstacles() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	_listen(monster)
	# Start a chase, then put the player straight behind (above) the right obstacle.
	player.global_position = Vector2(900.0, 560.0)
	await _frames(60)
	var behind := Vector2(950.0, 400.0)
	_check(behind.distance_to(HOME) < WorldMonster.LEASH_RADIUS and not _overlaps_static(main, behind + Vector2(0, -24), Vector2(32, 48)), "Test setup: a clear spot behind the obstacle inside the leash")
	player.global_position = behind
	var clean := true
	var touched := false
	for frame in range(300):
		await physics_frame
		clean = clean and not _monster_in_obstacle(main, monster)
		touched = touched or _monster_in_obstacle(main, monster, 1.0)
	_check(touched, "The chase ran up against the obstacle (within 1 px)")
	_check(clean, "The monster never entered an obstacle while chasing")
	_check(monster.get_state() == WorldMonster.State.CHASE, "Still chasing behind the obstacle")
	# Returning from straight above the obstacle, home being below it (test
	# setup puts the monster there): it slides along it and around, never
	# through, and home is never straight behind it (no dead end).
	var above := Vector2(950.0, 420.0)
	monster.global_position = above
	player.global_position = FAR
	_check(not _monster_in_obstacle(main, monster) and RIGHT_OBSTACLE.has_point(Vector2(above.x, RIGHT_OBSTACLE.get_center().y)), "Test setup: the monster is clear, directly above the obstacle")
	var frames := 0
	clean = true
	while monster.get_state() != WorldMonster.State.IDLE and frames < 900:
		await physics_frame
		frames += 1
		clean = clean and not _monster_in_obstacle(main, monster)
	_check(clean and frames < 900 and monster.global_position == HOME, "Returns home from above the obstacle without passing through it (%d frames)" % frames)
	await _destroy(main)
	_sections_done.append("obstacles")


# --- World bounds -------------------------------------------------------------------------------

func _verify_bounds() -> void:
	# A standalone monster whose home is near the corner chases a target that
	# sits outside the world: it stops at the edge.
	var unit := (load("res://scenes/world_monster.tscn") as PackedScene).instantiate() as WorldMonster
	unit.home_position = Vector2(60.0, 60.0)
	var target := Node2D.new()
	target.position = Vector2(-60.0, -60.0)
	root.add_child(target)
	root.add_child(unit)
	unit.set_chase_target(target)
	var inside := true
	var margin := Vector2(WorldMonster.BODY_RADIUS, WorldMonster.BODY_RADIUS)
	var allowed := Rect2(WorldBoundary.BOUNDS.position + margin, WorldBoundary.BOUNDS.size - margin * 2.0)
	for frame in range(120):
		await physics_frame
		inside = inside and allowed.grow(0.01).has_point(unit.global_position)
	_check(unit.get_state() == WorldMonster.State.CHASE, "Test setup: chasing a target beyond the corner")
	_check(inside and unit.global_position.is_equal_approx(allowed.position), "The chase stops at the world edge (%s)" % unit.global_position)
	root.remove_child(unit)
	unit.free()
	root.remove_child(target)
	target.free()
	await process_frame
	_sections_done.append("bounds")


# --- WORLD only -----------------------------------------------------------------------------------

func _verify_world_only() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var monster := _monster(main)
	var player := _player(main)
	_listen(monster)
	# Chase, then enter City A mid-chase.
	player.global_position = INSIDE_AGGRO
	await _frames(40)
	_check(monster.get_state() == WorldMonster.State.CHASE and monster.global_position != HOME, "Test setup: chasing away from home")
	player.global_position = WorldLayout.CITY_ANCHORS["A"]
	await _settle()
	_check(main.try_enter_city() and main.location.is_in_city(), "Entered City A")
	_check(not monster.is_threat_active() and monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE, "IN_CITY: the monster is reset to home and IDLE")
	_states.clear()
	player.global_position = HOME + Vector2(0.0, 100.0)
	await _frames(120)
	_check(monster.global_position == HOME and _states.is_empty() and _events.is_empty(), "IN_CITY: the AI does nothing with the player inside the radius")
	player.global_position = FAR
	await _settle()
	_check(main.request_transport("B", "wt02-ride")["success"] and main.is_traveling() and not monster.is_threat_active(), "TRAVELING: the threat is inactive")
	player.global_position = HOME + Vector2(0.0, 100.0)
	await _frames(120)
	_check(monster.global_position == HOME and _states.is_empty() and _events.is_empty(), "TRAVELING: the AI does nothing with the player inside the radius")
	player.global_position = FAR
	await _settle()
	main.time_source.advance_ms(90000)
	await process_frame
	_check(main.current_city_id == "B" and main.leave_city() and main.location.is_in_world(), "Arrived in B and left to the world")
	_check(monster.is_threat_active() and monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE, "Back in WORLD: active, at home, IDLE")
	await _frames(60)
	_check(monster.global_position == HOME and _states.is_empty(), "Leaving City B: no chase starts, stays idle at home")
	# WT02 review: leaving City A gives a safe exit too (no immediate chase).
	player.global_position = WorldLayout.CITY_ANCHORS["A"]
	await _frames(300)
	_states.clear()
	_check(main.try_enter_city() and main.leave_city() and monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE, "Leaving City A: the monster starts at home, IDLE")
	await _frames(120)
	_check(_states.is_empty() and monster.global_position == HOME and _events.is_empty(), "Leaving City A: no chase starts (%s)" % str(_states))
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("world_only")


# --- Save ----------------------------------------------------------------------------------------

func _verify_save() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var monster := _monster(main)
	var player := _player(main)
	player.global_position = Vector2(950.5, 650.25)
	await _frames(40)
	_check(monster.get_state() == WorldMonster.State.CHASE and monster.global_position != HOME, "Test setup: saving mid-chase")
	_check(main.save_world_position(), "Exact world position saves")
	var text := FileAccess.get_file_as_string(TEST_SAVE)
	var lower := text.to_lower()
	_check(int(JSON.parse_string(text)["version"]) == 8, "Save version unchanged (8)")
	_check(not lower.contains("monster") and not lower.contains("threat") and not lower.contains("chase") and not lower.contains("aggro"), "No monster state, position or timer is saved")
	await _destroy(main)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	monster = _monster(main)
	_check(monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE, "Reload rebuilds the monster at home, IDLE")
	_check(main.get_world_position() == Vector2(950.5, 650.25), "Reload restores the exact player position")
	await _frames(10)
	_check(FileAccess.get_file_as_string(TEST_SAVE) == text, "Loading and the new chase do not rewrite the save")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("save")


# --- Helpers ------------------------------------------------------------------------------------

func _listen(monster: WorldMonster) -> void:
	_events.clear()
	_states.clear()
	monster.player_contacted.connect(func(id: String) -> void: _events.append(id))
	monster.state_changed.connect(func(id: String, state: int) -> void:
		_check(id == MONSTER_ID, "State changes carry the monster id")
		_states.append(state))


func _state_text(monster: WorldMonster) -> String:
	return (monster.get_node("StateLabel") as Label).text


## Whether the monster's body circle (grown by `grow`; the default shrinks it
## by half a pixel for float tolerance) overlaps an obstacle.
func _monster_in_obstacle(main: Node, monster: WorldMonster, grow := -0.5) -> bool:
	var query := PhysicsShapeQueryParameters2D.new()
	var circle := CircleShape2D.new()
	circle.radius = WorldMonster.BODY_RADIUS + grow
	query.shape = circle
	query.transform = Transform2D(0.0, monster.global_position)
	for hit in main.get_world_2d().direct_space_state.intersect_shape(query, 32):
		if hit["collider"] is StaticBody2D:
			return true
	return false


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


func _overlaps_static(main: Node, center: Vector2, size: Vector2) -> bool:
	var query := PhysicsShapeQueryParameters2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	query.shape = rect
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


func _new_main(path: String, now: int = T0) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	main.time_source = TimeSource.fixed(now)
	root.add_child(main)
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


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
