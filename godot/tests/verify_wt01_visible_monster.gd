extends SceneTree

## World Threat WT01: one visible prototype monster with a stable identity, a
## deterministic world position and edge-triggered player contact, active only
## in WORLD mode. Uses the real main scene and physics frames (no sleeps).

const TEST_SAVE := "user://wt01_visible_monster_test_save.json"
const T0 := 1800000000000
const MONSTER_ID := "prototype_monster_01"
const MONSTER_POS := Vector2(720.0, 320.0)
const CONTACT_RADIUS := 48.0
const PLAYER_SIZE := Vector2(32, 48)
const PLAYER_OFFSET := Vector2(0, -24)
const FAR := Vector2(3000.0, 3000.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _events := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	await _verify_position()
	await _verify_contact_lifecycle()
	await _verify_world_only()
	await _verify_world_position_unchanged()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 5, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("WT01 visible monster verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(WorldLayout.PROTOTYPE_MONSTER_ID == MONSTER_ID, "Stable explicit monster id")
	_check(WorldLayout.PROTOTYPE_MONSTER_POSITION == MONSTER_POS, "Monster position is layout data")
	var script := _code_only("res://scripts/world_monster.gd")
	for random in ["randi", "randf", "RandomNumberGenerator", "randomize", "seed("]:
		_check(not script.contains(random), "No randomness in the monster (%s)" % random)
	for unrelated in ["trade_service", "warehouse_service", "warehouse_state", "market_state", "market_rules", "transport_service", "save_store", "city_hub", "trade_cost_ledger", "player_location"]:
		var code := _code_only("res://scripts/%s.gd" % unrelated).to_lower()
		_check(not code.contains("monster") and not code.contains("threat"), "No world-threat logic in %s" % unrelated)
	for word in ["patrol", "aggro", "chase", "leash", "encounter", "combat", "damage", "health", "respawn", "loot"]:
		_check(not script.to_lower().contains(word), "No out-of-scope behaviour in the monster (%s)" % word)
	_check(SaveStore.VERSION == 8, "No save schema change (still version 8)")
	var scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_check(scene.count("world_monster.tscn") == 1 and scene.count("[node name=\"PrototypeMonster\"") == 1, "Exactly one monster in the main scene")
	var monster_scene := FileAccess.get_file_as_string("res://scenes/world_monster.tscn")
	_check(not monster_scene.contains(".png") and not monster_scene.contains(".ogg") and not monster_scene.contains(".wav") and not monster_scene.contains("AnimationPlayer"), "Minimal drawn visual: no imported art, audio or animation")
	_sections_done.append("static")


# --- Position ----------------------------------------------------------------------------------

func _verify_position() -> void:
	# Determinism across runs (one scene at a time: two loaded scenes would
	# share one physics space and push their players apart).
	var first := await _new_main("")
	var first_id: String = _monster(first).monster_id
	var first_pos: Vector2 = _monster(first).global_position
	await _destroy(first)
	var second := await _new_main("")
	_check(_monster(second).monster_id == first_id and _monster(second).global_position == first_pos, "A second run resolves to the same id and position")
	await _destroy(second)
	var main := await _new_main(TEST_SAVE)
	var monster := _monster(main)
	var monsters := main.find_children("*", "WorldMonster", true, false)
	_check(monsters.size() == 1 and monster != null, "Exactly one WorldMonster at runtime")
	_check(monster.monster_id == MONSTER_ID and monster.global_position == MONSTER_POS, "Runtime id and position are the layout data")
	_check(((monster.get_node("ContactShape") as CollisionShape2D).shape as CircleShape2D).radius == CONTACT_RADIUS, "Contact radius 48")
	_check(PlayerLocation.is_valid_world_position(MONSTER_POS), "Inside the playable world bounds")
	_check((monster.get_node("NameLabel") as Label).text == "怪物（原型）" and (monster.get_node("Body") as Polygon2D).visible and monster.is_visible_in_tree(), "Visible with a Traditional Chinese label")
	# Obstacles: a player standing on the monster touches no static body.
	var space := main.get_world_2d().direct_space_state
	var query := PhysicsShapeQueryParameters2D.new()
	var rect := RectangleShape2D.new()
	rect.size = PLAYER_SIZE
	query.shape = rect
	query.transform = Transform2D(0.0, MONSTER_POS + PLAYER_OFFSET)
	var static_hits := 0
	for hit in space.intersect_shape(query, 32):
		if hit["collider"] is StaticBody2D:
			static_hits += 1
	_check(static_hits == 0, "The monster is not inside an obstacle (player-sized probe)")
	var circle := CircleShape2D.new()
	circle.radius = CONTACT_RADIUS
	query.shape = circle
	query.transform = Transform2D(0.0, MONSTER_POS)
	static_hits = 0
	for hit in space.intersect_shape(query, 32):
		if hit["collider"] is StaticBody2D:
			static_hits += 1
	_check(static_hits == 0, "The contact area overlaps no obstacle")
	# Cities: the contact area never reaches a city trigger or a return point.
	for city in WorldLayout.ACTIVE_CITY_IDS:
		var marker := main.get_node("Cities/City%s" % city) as CityMarker
		var trigger := ((marker.get_node("TriggerShape") as CollisionShape2D).shape as CircleShape2D).radius
		_check(MONSTER_POS.distance_to(marker.global_position) > trigger + CONTACT_RADIUS, "Contact area clear of City %s's entry trigger" % city)
		_check(not marker.trigger_overlaps(Rect2(MONSTER_POS + PLAYER_OFFSET - PLAYER_SIZE / 2.0, PLAYER_SIZE)), "Standing on the monster is not inside City %s's trigger" % city)
		var ret: Vector2 = WorldLayout.CITY_RETURN_POINTS[city]
		var player_rect := Rect2(ret + PLAYER_OFFSET - PLAYER_SIZE / 2.0, PLAYER_SIZE)
		_check(MONSTER_POS.clamp(player_rect.position, player_rect.end).distance_to(MONSTER_POS) > CONTACT_RADIUS + 40.0, "A player at City %s's return point is well clear of the contact area" % city)
	_check(MONSTER_POS.distance_to(PlayerLocation.DEFAULT_WORLD_SPAWN) < 600.0, "Close to the spawn for development testing")
	# Reachable by normal movement: walk from the spawn with the move actions.
	_events.clear()
	monster.player_contacted.connect(_on_contact)
	var player := _player(main)
	_check(player.global_position == PlayerLocation.DEFAULT_WORLD_SPAWN, "New game starts at the spawn (%s)" % player.global_position)
	var frames := await _walk(player, "move_right", func() -> bool: return player.global_position.x >= MONSTER_POS.x)
	_check(frames < 300 and absf(player.global_position.y - 500.0) < 1.0, "Walked right from the spawn unobstructed (%d frames)" % frames)
	frames = await _walk(player, "move_up", func() -> bool: return _events.size() > 0)
	_check(frames < 300 and _events == [MONSTER_ID], "Walking up reaches the monster and makes contact (%d frames, %s)" % [frames, str(_events)])
	frames = await _walk(player, "move_up", func() -> bool: return player.global_position.y < MONSTER_POS.y - 150.0)
	_check(frames < 300 and _events.size() == 1 and not monster.is_in_contact(), "The player walks through and away normally; still one event")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("position")


# --- Contact lifecycle -------------------------------------------------------------------------

func _verify_contact_lifecycle() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	_events.clear()
	monster.player_contacted.connect(_on_contact)
	player.global_position = FAR
	await _settle()
	_check(_events.is_empty() and not monster.is_in_contact(), "Outside: no contact")
	player.global_position = MONSTER_POS + Vector2(0, 30)
	await _settle()
	_check(_events == [MONSTER_ID] and monster.is_in_contact(), "Enter: exactly one contact event with the monster id")
	for frame in range(120):
		await physics_frame
	_check(_events.size() == 1, "120 physics frames of continuous overlap: still one event")
	player.global_position = MONSTER_POS + Vector2(20, 10)
	await _settle()
	_check(_events.size() == 1, "Moving around inside the area: no new event")
	player.global_position = FAR
	await _settle()
	_check(not monster.is_in_contact() and _events.size() == 1, "Leave: contact ends, no event")
	player.global_position = MONSTER_POS + Vector2(-10, 40)
	await _settle()
	_check(_events == [MONSTER_ID, MONSTER_ID], "Re-enter: one new contact event")
	for cycle in range(3):
		player.global_position = FAR
		await _settle()
		player.global_position = MONSTER_POS + Vector2(0, 30)
		await _settle()
	_check(_events.size() == 5 and _events.count(MONSTER_ID) == 5, "Each leave + enter gives exactly one more event")
	# Just outside the edge: no contact.
	player.global_position = FAR
	await _settle()
	player.global_position = MONSTER_POS + Vector2(CONTACT_RADIUS + PLAYER_SIZE.x / 2.0 + 4.0, 24)
	await _settle()
	_check(_events.size() == 5, "Just outside the contact radius: no event")
	await _destroy(main)
	_sections_done.append("contact_lifecycle")


# --- WORLD only ----------------------------------------------------------------------------------

func _verify_world_only() -> void:
	# Unit level: an inactive monster ignores the player.
	var unit := (load("res://scenes/world_monster.tscn") as PackedScene).instantiate() as WorldMonster
	var body := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	root.add_child(unit)
	var count := [0]
	unit.player_contacted.connect(func(_id: String) -> void: count[0] += 1)
	unit.set_threat_active(false)
	unit._on_body_entered(body)
	_check(count[0] == 0 and not unit.is_in_contact(), "Inactive: a player entering produces no event")
	unit.set_threat_active(true)
	unit._on_body_entered(body)
	unit._on_body_entered(body)
	_check(count[0] == 1, "Active: one event; a duplicate enter without leaving is ignored")
	unit._on_body_exited(body)
	unit._on_body_entered(body)
	_check(count[0] == 2, "Exit then enter: a second event")
	unit.set_threat_active(false)
	_check(not unit.is_in_contact(), "Deactivating clears the contact")
	root.remove_child(unit)
	unit.free()
	body.free()

	# Game level: IN_CITY and TRAVELING never report contact.
	var main := await _new_main(TEST_SAVE, T0)
	var monster := _monster(main)
	var player := _player(main)
	_events.clear()
	monster.player_contacted.connect(_on_contact)
	_check(main.location.is_in_world() and monster.is_threat_active(), "WORLD: the threat is active")
	await _walk_in(main, "A")
	_check(main.location.is_in_city() and not monster.is_threat_active(), "IN_CITY: the threat is inactive")
	player.global_position = MONSTER_POS + Vector2(0, 30)
	await _settle()
	for frame in range(30):
		await physics_frame
	_check(_events.is_empty(), "IN_CITY: the player body over the monster produces no contact")
	player.global_position = FAR
	await _settle()
	_check(main.request_transport("B", "wt01-ride")["success"] and main.is_traveling() and not monster.is_threat_active(), "TRAVELING: the threat is inactive")
	player.global_position = MONSTER_POS + Vector2(0, 30)
	await _settle()
	_check(_events.is_empty(), "TRAVELING: no contact")
	player.global_position = FAR
	await _settle()
	main.time_source.advance_ms(90000)
	await process_frame
	_check(main.current_city_id == "B" and not monster.is_threat_active() and _events.is_empty(), "Arrival stays in the city: inactive, no contact")
	_check(main.leave_city() and main.location.is_in_world() and monster.is_threat_active(), "Leaving the city reactivates the threat")
	_check(_events.is_empty(), "Returning to the world at B's return point: no contact")
	player.global_position = MONSTER_POS + Vector2(0, 30)
	await _settle()
	_check(_events == [MONSTER_ID], "Back in WORLD: contact works again")
	# The contact does not change any player state.
	_check(main.location.is_in_world() and not main.is_in_city() and not main.is_traveling() and player.is_physics_processing(), "Contact changes no mode and does not stop movement (no dead end)")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("world_only")


# --- T06 unchanged -----------------------------------------------------------------------------

func _verify_world_position_unchanged() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var player := _player(main)
	player.global_position = Vector2(1500.5, 2500.25)
	_check(main.save_world_position(), "Exact world position saves")
	var text := FileAccess.get_file_as_string(TEST_SAVE)
	_check(not text.to_lower().contains("monster") and not text.to_lower().contains("threat") and int(JSON.parse_string(text)["version"]) == 8, "Nothing monster-related is saved; save version 8")
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0)
	_check(main.get_world_position() == Vector2(1500.5, 2500.25) and FileAccess.get_file_as_string(TEST_SAVE) == text, "Reload restores the exact position; the save is not rewritten")
	_check(_monster(main).global_position == MONSTER_POS and _monster(main).monster_id == MONSTER_ID, "The monster reconstructs from layout data on load")
	# Saved while standing on the monster: loading reports that contact once.
	_player(main).global_position = MONSTER_POS + Vector2(0, 30)
	await _settle()
	main.save_world_position()
	await _destroy(main)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	_events.clear()
	root.add_child(main)
	_monster(main).player_contacted.connect(_on_contact)
	for frame in range(60):
		await physics_frame
	_check(_events.size() <= 1 and _events.count(MONSTER_ID) == _events.size(), "Loading on top of the monster: at most one contact, never spam (%s)" % str(_events))
	_check(main.get_world_position() == MONSTER_POS + Vector2(0, 30), "The loaded position is exact")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("world_position_unchanged")


# --- Helpers ------------------------------------------------------------------------------------

func _on_contact(monster_id: String) -> void:
	_events.append(monster_id)


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


func _walk_in(main: Node, city: String) -> void:
	_player(main).global_position = WorldLayout.CITY_ANCHORS[city]
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == city, "Must enter City %s" % city)


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
