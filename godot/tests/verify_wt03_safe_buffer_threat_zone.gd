extends SceneTree

## World Threat WT03: city safe buffers and the one prototype low-level threat
## zone, and the prototype monster respecting them. Uses the real main scene,
## physics frames and a fixed TimeSource (no sleeps).

const TEST_SAVE := "user://wt03_safe_buffer_test_save.json"
const T0 := 1800000000000
const ZONE_ID := "low_threat_zone_01"
## E02 grew the zone east and south (was Rect2(560, 450, 440, 400)); the
## corner nearest City A is unchanged.
const ZONE := Rect2(560.0, 450.0, 680.0, 610.0)
const SAFE_RADIUS := 420.0
## E02 fix pass: group 1's home moved from (760, 650) to (800, 700).
const HOME := Vector2(800.0, 700.0)
const CITY_A := Vector2(200.0, 200.0)
const PLAYER_SIZE := Vector2(32, 48)
const FAR := Vector2(3000.0, 3000.0)
## Standalone-monster setup east of City A: a home just outside its buffer,
## one spot inside the buffer but within aggro range, one outside both.
const UNIT_HOME := Vector2(720.0, 200.0)
const UNIT_SAFE := Vector2(600.0, 200.0)
const UNIT_OPEN := Vector2(650.0, 200.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _events := []
var _states := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_layout()
	await _verify_scene_layout()
	await _verify_unit_rules()
	await _verify_acceptance_flow()
	await _verify_world_only()
	await _verify_save()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 6, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("WT03 safe buffer threat zone verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Layout data ---------------------------------------------------------------------------------

func _verify_layout() -> void:
	_check(WorldThreatZones.CITY_SAFE_BUFFER_RADIUS == SAFE_RADIUS, "Prototype safe-buffer radius 420")
	for city in WorldLayout.ACTIVE_CITY_IDS:
		var anchor: Vector2 = WorldLayout.CITY_ANCHORS[city]
		_check(WorldThreatZones.safe_buffer_city_at(anchor) == city, "City %s has a safe buffer" % city)
		var exit: Vector2 = WorldLayout.CITY_RETURN_POINTS[city]
		var exit_rect := Rect2(exit + Vector2(-PLAYER_SIZE.x / 2.0, -PLAYER_SIZE.y), PLAYER_SIZE)
		var covered := true
		for corner in [exit_rect.position, exit_rect.end, Vector2(exit_rect.position.x, exit_rect.end.y), Vector2(exit_rect.end.x, exit_rect.position.y)]:
			covered = covered and WorldThreatZones.safe_buffer_city_at(corner) == city
		_check(covered, "City %s's return point (the whole player) is inside its safe buffer" % city)
		_check(exit.distance_to(anchor) + 60.0 <= SAFE_RADIUS, "City %s: safe ground continues past the return point" % city)
		_check(HOME.distance_to(anchor) > SAFE_RADIUS + WorldMonster.AGGRO_RADIUS, "The monster's aggro circle never reaches City %s's safe buffer" % city)
		_check(_rect_distance(ZONE, anchor) > SAFE_RADIUS, "The threat zone does not overlap City %s's safe buffer" % city)
	for city in WorldLayout.RESERVED_CITY_IDS:
		_check(WorldThreatZones.safe_buffer_city_at(WorldLayout.CITY_ANCHORS[city]) == "", "Reserved City %s has no buffer yet (not implemented)" % city)
	_check(WorldLayout.PROTOTYPE_MONSTER_POSITION == HOME, "Monster home (800, 700)")
	_check(not WorldThreatZones.is_in_city_safe_buffer(HOME), "The monster home lies outside every safe buffer")
	_check(WorldThreatZones.is_in_city_safe_buffer(PlayerLocation.DEFAULT_WORLD_SPAWN), "The new-game spawn is inside City A's safe buffer")
	# The zone.
	_check(WorldThreatZones.LOW_THREAT_ZONE_01_ID == ZONE_ID and WorldThreatZones.LOW_THREAT_ZONE_01 == ZONE, "Stable zone id and geometry")
	_check(WorldThreatZones.threat_zone_at(HOME) == ZONE_ID and WorldThreatZones.threat_zone_at(HOME) == WorldThreatZones.threat_zone_at(HOME), "The monster home is inside low_threat_zone_01 (deterministic)")
	_check(ZONE.encloses(Rect2(HOME - Vector2.ONE * WorldMonster.AGGRO_RADIUS, Vector2.ONE * WorldMonster.AGGRO_RADIUS * 2.0)), "The whole aggro circle is threat territory")
	_check(WorldBoundary.BOUNDS.encloses(ZONE) and PlayerLocation.is_valid_world_position(ZONE.position) and PlayerLocation.is_valid_world_position(ZONE.end), "The zone is inside the playable world")
	_check(WorldThreatZones.threat_zone_at(FAR) == "" and WorldThreatZones.threat_zone_at(CITY_A) == "" and WorldThreatZones.safe_buffer_city_at(FAR) == "", "Positions elsewhere belong to neither")
	_check(WorldThreatZones.safe_buffer_city_at(Vector2(39460.0, 200.0)) == "B" and WorldThreatZones.safe_buffer_city_at(CITY_A + Vector2(SAFE_RADIUS + 1.0, 0.0)) == "", "Membership follows the circle edge")
	# Kept apart from unrelated systems; nothing is saved.
	var zones := _code_only("res://scripts/world_threat_zones.gd")
	for word in ["randi", "randf", "RandomNumberGenerator", "Time.", "OS.", "Navigation", "AStar", "level", "boss"]:
		_check(not zones.contains(word), "Not in the zone rules: %s" % word)
	for unrelated in ["trade_service", "warehouse_service", "market_state", "market_rules", "transport_service", "save_store", "city_hub", "player_location", "trade_cost_ledger"]:
		var code := _code_only("res://scripts/%s.gd" % unrelated)
		_check(not code.contains("WorldThreatZones") and not code.to_lower().contains("safe_buffer"), "No zone logic in %s" % unrelated)
	_check(SaveStore.VERSION == 11, "No save schema change (still version 11 (P01.5))")
	var scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_check(scene.count("[node name=\"PrototypeMonster\"") == 1 and scene.count("world_monster.tscn") == 1, "Still exactly one monster")
	_sections_done.append("layout")


# --- Runtime layout and overlay ------------------------------------------------------------------

func _verify_scene_layout() -> void:
	var main := await _new_main("")
	for city in WorldLayout.ACTIVE_CITY_IDS:
		var marker := main.get_node("Cities/City%s" % city) as CityMarker
		var trigger := ((marker.get_node("TriggerShape") as CollisionShape2D).shape as CircleShape2D).radius
		_check(marker.global_position.distance_to(WorldLayout.CITY_ANCHORS[city]) + trigger <= SAFE_RADIUS, "City %s's whole entry trigger (r %.0f) is inside its safe buffer" % [city, trigger])
	# The zone crosses obstacles (normal terrain) but the home itself is clear.
	_check(not _overlaps_static(main, HOME + Vector2(0, -24), PLAYER_SIZE), "The monster home in the zone is clear ground")
	var overlay := main.get_node("ThreatZones") as ThreatZoneOverlay
	_check(overlay != null and overlay.is_visible_in_tree() and overlay.get_index() < main.get_node("Cities").get_index(), "Prototype zone markings draw under the cities and actors")
	var texts := []
	for label in overlay.find_children("*", "Label", true, false):
		texts.append((label as Label).text)
	texts.sort()
	var expected := ["安全區", "安全區", "低級威脅區"]
	expected.sort()
	_check(texts == expected, "Traditional Chinese markings: 安全區 per city, 低級威脅區 (%s)" % str(texts))
	await _destroy(main)
	_sections_done.append("scene_layout")


# --- Monster rules (standalone monster, target node) ----------------------------------------------

func _verify_unit_rules() -> void:
	_check(WorldThreatZones.safe_buffer_city_at(UNIT_SAFE) == "A" and not WorldThreatZones.is_in_city_safe_buffer(UNIT_OPEN) and not WorldThreatZones.is_in_city_safe_buffer(UNIT_HOME), "Test setup: one spot inside City A's buffer, two outside")
	_check(UNIT_HOME.distance_to(UNIT_SAFE) <= WorldMonster.AGGRO_RADIUS, "Test setup: the safe spot is within aggro range")
	var unit := (load("res://scenes/world_monster.tscn") as PackedScene).instantiate() as WorldMonster
	unit.patrol_points = []  # WT05: stationary while idle, as this check assumes
	unit.home_position = UNIT_HOME
	var target := Node2D.new()
	target.position = UNIT_SAFE
	root.add_child(target)
	root.add_child(unit)
	unit.set_chase_target(target)
	_listen(unit)
	await _frames(60)
	_check(_states.is_empty() and unit.global_position == UNIT_HOME, "Within aggro range but inside the safe buffer: no aggro")
	target.position = UNIT_OPEN
	await _frames(40)
	_check(_states == [WorldMonster.State.CHASE], "The same player just outside the buffer: chased")
	target.position = UNIT_SAFE
	var deepest := INF
	var frames := 0
	while unit.get_state() != WorldMonster.State.IDLE and frames < 300:
		await physics_frame
		frames += 1
		deepest = minf(deepest, unit.global_position.distance_to(CITY_A))
	_check(_states == [WorldMonster.State.CHASE, WorldMonster.State.RETURNING, WorldMonster.State.IDLE] and unit.global_position == UNIT_HOME, "Player steps into safety: RETURNING once, back home, IDLE (%s)" % str(_states))
	_check(deepest > SAFE_RADIUS, "The monster never followed into the safe buffer (closest %.1f px from City A)" % deepest)
	await _frames(60)
	_check(_states.size() == 3, "Still no aggro on the player in safety")
	# The monster itself reaching safety also ends the chase.
	target.position = UNIT_OPEN
	await _frames(3)
	unit.global_position = UNIT_SAFE + Vector2(-40.0, 0.0)
	await _frames(2)
	_check(_states.slice(3) == [WorldMonster.State.CHASE, WorldMonster.State.RETURNING], "A chasing monster inside a safe buffer turns back (%s)" % str(_states))
	unit.set_chase_target(null)
	unit.reset_to_home()
	# Contact: none inside safety, normal outside.
	var body := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	body.position = UNIT_SAFE
	unit._on_body_entered(body)
	_check(_events.is_empty() and not unit.is_in_contact(), "No contact event for a player inside the safe buffer")
	body.position = UNIT_OPEN
	unit._on_body_entered(body)
	unit._on_body_entered(body)
	_check(_events == [unit.monster_id] and unit.is_in_contact(), "Outside safety: exactly one contact event")
	unit._on_body_exited(body)
	unit._on_body_entered(body)
	_check(_events.size() == 2, "Outside safety: leave + enter gives one more")
	body.free()
	root.remove_child(unit)
	unit.free()
	root.remove_child(target)
	target.free()
	await process_frame
	_sections_done.append("unit_rules")


# --- Acceptance flow in the real game --------------------------------------------------------------

func _verify_acceptance_flow() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	_listen(monster)
	# 1-3: leave City A; safe; the monster idles.
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city() and main.leave_city(), "Entered and left City A")
	_check(WorldThreatZones.safe_buffer_city_at(player.global_position) == "A", "Leaving City A: the player stands in its safe buffer")
	await _frames(60)
	_check(_states.is_empty() and monster.global_position == HOME, "The monster stays idle")
	# 4: walk out of safety, still outside aggro range: safe.
	var left_safety_idle := [false]
	var frames := await _walk(player, "move_down", func() -> bool:
		if not WorldThreatZones.is_in_city_safe_buffer(player.global_position) and _states.is_empty():
			left_safety_idle[0] = true
		return player.global_position.y >= HOME.y)
	_check(frames < 300 and left_safety_idle[0] and not WorldThreatZones.is_in_city_safe_buffer(player.global_position), "Out of the safe buffer but outside aggro range: still no chase")
	_check(_states.is_empty() and player.global_position.distance_to(HOME) > WorldMonster.AGGRO_RADIUS, "Walked down to the monster's row: still idle")
	# 5-6: approach deliberately.
	frames = await _walk(player, "move_right", func() -> bool: return not _states.is_empty())
	_check(frames < 300 and _states == [WorldMonster.State.CHASE], "Approaching the monster starts the chase (%d frames)" % frames)
	_check(WorldThreatZones.threat_zone_at(player.global_position) == ZONE_ID, "The chase started in low_threat_zone_01")
	await _frames(20)
	_check(monster.get_state() == WorldMonster.State.CHASE and monster.global_position.distance_to(HOME) > 20.0, "The chase runs normally outside safety")
	# 7-10: run back to City A's safety.
	var deepest := [INF]
	var disengaged_at := [Vector2.ZERO]
	frames = await _walk(player, "move_up", func() -> bool:
		deepest[0] = minf(deepest[0], monster.global_position.distance_to(CITY_A))
		if _states.size() == 2 and disengaged_at[0] == Vector2.ZERO:
			disengaged_at[0] = player.global_position
		return WorldThreatZones.is_in_city_safe_buffer(player.global_position) and _states.size() >= 2)
	_check(frames < 300 and _states == [WorldMonster.State.CHASE, WorldMonster.State.RETURNING], "Reaching City A's safety: RETURNING exactly once (%s)" % str(_states))
	_check(WorldThreatZones.safe_buffer_city_at(disengaged_at[0]) == "A" and disengaged_at[0].distance_to(HOME) < WorldMonster.LEASH_RADIUS, "It was the safe buffer, not the leash, that ended the chase")
	frames = 0
	while monster.get_state() != WorldMonster.State.IDLE and frames < 600:
		await physics_frame
		frames += 1
		deepest[0] = minf(deepest[0], monster.global_position.distance_to(CITY_A))
	_check(monster.global_position == HOME and _states == [1, 2, 0], "The monster returns home and idles (%d frames)" % frames)
	_check(deepest[0] > SAFE_RADIUS, "The monster never entered City A's safe buffer (closest %.1f px)" % deepest[0])
	_check(_events.is_empty(), "No contact: no encounter, no combat")
	# 11: leave safety again: a new chase, and safety ends it again.
	frames = await _walk(player, "move_down", func() -> bool: return _states.size() > 3)
	_check(frames < 300 and _states == [1, 2, 0, 1], "Leaving safety later starts another chase")
	frames = await _walk(player, "move_up", func() -> bool: return _states.size() > 4)
	_check(frames < 300 and _states == [1, 2, 0, 1, 2], "Retreating to safety ends it again")
	await _frames(300)
	_check(monster.global_position == HOME and _states == [1, 2, 0, 1, 2, 0], "Home and idle again; no developer rescue needed")
	# 18: WT01 contact outside safety still works.
	player.global_position = HOME + Vector2(0.0, 30.0)
	await _settle()
	_check(_events == [monster.monster_id] and main.location.is_in_world() and player.is_physics_processing(), "Contact outside safety: one event, player state unchanged")
	await _destroy(main)
	_sections_done.append("acceptance")


# --- WORLD only -----------------------------------------------------------------------------------

func _verify_world_only() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var monster := _monster(main)
	var player := _player(main)
	_listen(monster)
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city() and not monster.is_threat_active(), "IN_CITY: the threat is inactive")
	player.global_position = HOME + Vector2(0.0, 100.0)
	await _frames(60)
	_check(_states.is_empty() and _events.is_empty() and monster.global_position == HOME, "IN_CITY: no AI with the player in threat territory")
	player.global_position = FAR
	await _settle()
	_check(main.request_transport("B", "wt03-ride")["success"] and main.is_traveling() and not monster.is_threat_active(), "TRAVELING: the threat is inactive")
	player.global_position = HOME + Vector2(0.0, 100.0)
	await _frames(60)
	_check(_states.is_empty() and _events.is_empty() and monster.global_position == HOME, "TRAVELING: no AI with the player in threat territory")
	player.global_position = FAR
	await _settle()
	main.time_source.advance_ms(90000)
	await process_frame
	_check(main.current_city_id == "B" and main.leave_city() and WorldThreatZones.safe_buffer_city_at(player.global_position) == "B", "Leaving City B: inside its safe buffer")
	await _frames(60)
	_check(monster.is_threat_active() and _states.is_empty() and monster.global_position == HOME, "Back in WORLD: active, home, idle")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("world_only")


# --- Save ----------------------------------------------------------------------------------------

func _verify_save() -> void:
	for spot in [[Vector2(560.5, 300.25), "A", ""], [Vector2(900.5, 700.25), "", ZONE_ID]]:
		var position: Vector2 = spot[0]
		var main := await _new_main(TEST_SAVE, T0)
		_player(main).global_position = position
		_check(main.save_world_position(), "Exact world position saves (%s)" % position)
		var text := FileAccess.get_file_as_string(TEST_SAVE)
		var lower := text.to_lower()
		_check(int(JSON.parse_string(text)["version"]) == 11, "Save version 11 (C05)")
		_check(not lower.contains("zone") and not lower.contains("safe") and not lower.contains("threat") and not lower.contains("monster"), "No zone, safety or monster data is saved")
		await _destroy(main)
		main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
		_single_group(main)
		_no_patrol(main)
		main.save_path = TEST_SAVE
		main.time_source = TimeSource.fixed(T0)
		root.add_child(main)
		var loaded: Vector2 = main.get_world_position()
		_check(loaded == position, "Reload restores the exact position (%s)" % loaded)
		_check(WorldThreatZones.safe_buffer_city_at(loaded) == spot[1] and WorldThreatZones.threat_zone_at(loaded) == spot[2], "Membership derives from the reloaded position (%s / %s)" % [spot[1], spot[2]])
		_check(_monster(main).global_position == HOME and _monster(main).get_state() == WorldMonster.State.IDLE, "The monster starts at home, IDLE")
		await _frames(30)
		var expected := WorldMonster.State.IDLE if spot[1] != "" else WorldMonster.State.CHASE
		_check(_monster(main).get_state() == expected, "After loading: %s" % ("safe, no chase" if spot[1] != "" else "in the monster's range, chased"))
		_check(FileAccess.get_file_as_string(TEST_SAVE) == text, "Loading does not rewrite the save")
		await _destroy(main)
		_delete(TEST_SAVE)
	_sections_done.append("save")


# --- Helpers ------------------------------------------------------------------------------------

func _listen(monster: WorldMonster) -> void:
	_events.clear()
	_states.clear()
	monster.player_contacted.connect(func(id: String) -> void: _events.append(id))
	monster.state_changed.connect(func(_id: String, state: int) -> void: _states.append(state))


func _rect_distance(rect: Rect2, point: Vector2) -> float:
	return point.clamp(rect.position, rect.end).distance_to(point)


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
	_single_group(main)
	_no_patrol(main)
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


## WT05: the monster stands at home while idle (no patrol loop), the
## premise these checks were written for; verify_wt05_patrol covers patrol.
func _no_patrol(main: Node) -> void:
	(main.get_node("Actors/PrototypeMonster") as WorldMonster).patrol_points = []


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
