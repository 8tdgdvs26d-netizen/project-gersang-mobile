extends SceneTree

## Encounter E02: up to three World Enemy Groups join one encounter during the
## fixed 5 s join window (never resetting it); the planned Combat size follows
## the group count (1 -> 10, 2 -> 15, 3 -> 20). Real main scene with all
## three prototype groups, physics frames, fixed TimeSource (no sleeps).

const TEST_SAVE := "user://e02_multi_group_test_save.json"
const T0 := 1800000000000
const IDS := ["prototype_monster_01", "prototype_monster_02", "prototype_monster_03"]
const HOMES := [Vector2(760.0, 650.0), Vector2(1020.0, 650.0), Vector2(890.0, 860.0)]
const ZONE := Rect2(560.0, 450.0, 680.0, 580.0)
const CITY_A := Vector2(200.0, 200.0)
const FAR := Vector2(3000.0, 3000.0)
## Player spots (teleported to right after the scene starts, all groups at
## home): A near group 1 only; B right by group 1 and in group 2's range, out
## of group 3's whole loop; C within range of all three homes.
const SPOT_A := Vector2(640.0, 600.0)
const SPOT_B := Vector2(845.0, 645.0)
const SPOT_C := Vector2(890.0, 715.0)
## The clock moves on this much the moment a trigger fires, so a reset timer
## would show.
const ADVANCE_AT_TRIGGER_MS := 1200

var _checks := 0
var _failures := 0
var _sections_done := []
var _encounters := []
var _joins := []
var _phases := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	await _verify_layout()
	await _verify_case_a()
	await _verify_case_b()
	await _verify_case_c()
	await _verify_world_exit()
	await _verify_reload()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 7, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("E02 multi-group verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	var groups := WorldLayout.PROTOTYPE_GROUPS
	var ids := []
	for group in groups:
		ids.append(group["id"])
	_check(groups.size() == 3 and ids == IDS, "Exactly three prototype groups with stable ids (%s)" % str(ids))
	_check(groups[0]["id"] == WorldLayout.PROTOTYPE_MONSTER_ID and groups[0]["home"] == WorldLayout.PROTOTYPE_MONSTER_POSITION and groups[0]["patrol"] == WorldLayout.PROTOTYPE_MONSTER_PATROL, "Group 1 is the WT01–WT05 monster")
	_check(EncounterHandoff.MAX_GROUPS == 3, "At most 3 groups per encounter")
	_check(EncounterContext.PLANNED_COMBAT_ENEMIES == {1: 10, 2: 15, 3: 20}, "Planned Combat size: 1 -> 10, 2 -> 15, 3 -> 20")
	var planning := EncounterContext.new()
	var sizes := []
	for id in IDS:
		planning.group_monster_ids.append(id)
		sizes.append([planning.get_group_count(), planning.get_planned_combat_enemy_count()])
	_check(sizes == [[1, 10], [2, 15], [3, 20]], "Group count -> planned Combat enemies (%s)" % str(sizes))
	var scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_check(scene.count("instance=ExtResource(\"9_monster\")") == 3 and scene.count("group_index = 1") == 1 and scene.count("group_index = 2") == 1 and not scene.contains("group_index = 3"), "Exactly three monster instances (groups 1, 2, 3), no fourth")
	for path in ["res://scripts/encounter_session.gd", "res://scripts/encounter_handoff.gd", "res://scripts/world_monster.gd"]:
		var code := _code_only(path).to_lower()
		for word in ["battle", "damage", "health", "reward", "loot", "retreat", "passive", "aggressive", "challenge", "randi", "randf", "navigation"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	_check(not _code_only("res://scripts/save_store.gd").to_lower().contains("group") and SaveStore.VERSION == 8, "Save version 8; the save knows nothing about groups")
	_sections_done.append("static")


# --- Layout ----------------------------------------------------------------------------------

func _verify_layout() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var runtime_ids := []
	for monster in monsters:
		runtime_ids.append(monster.monster_id)
	_check(runtime_ids == IDS and main.find_children("*", "WorldMonster", true, false).size() == 3, "Three World Enemy Groups at runtime (%s)" % str(runtime_ids))
	_check(WorldThreatZones.LOW_THREAT_ZONE_01 == ZONE, "low_threat_zone_01 grown to x 560–1240, y 450–1030")
	for index in range(3):
		var group: Dictionary = WorldLayout.PROTOTYPE_GROUPS[index]
		var home: Vector2 = group["home"]
		var route: Array = group["patrol"]
		_check(monsters[index].global_position.distance_to(home) < 10.0 and home == HOMES[index] and route.back() == home, "Group %d starts at its home %s" % [index + 1, home])
		_check(PlayerLocation.is_valid_world_position(home) and not WorldThreatZones.is_in_city_safe_buffer(home) and WorldThreatZones.threat_zone_at(home) == WorldThreatZones.LOW_THREAT_ZONE_01_ID, "Group %d home: valid, outside every safe buffer, inside the zone" % (index + 1))
		var inside := true
		var clear := true
		for leg in range(route.size()):
			for step in range(51):
				var point := (route[leg - 1] as Vector2).lerp(route[leg], step / 50.0)
				inside = inside and ZONE.grow(-40.0).has_point(point) and not WorldThreatZones.is_in_city_safe_buffer(point)
				clear = clear and not _circle_hits_static(main, point, WorldMonster.BODY_RADIUS + 2.0)
		_check(inside, "Group %d patrol stays well inside the zone, out of every safe buffer" % (index + 1))
		_check(clear, "Group %d patrol legs are clear of the obstacles" % (index + 1))
		for spot in [PlayerLocation.DEFAULT_WORLD_SPAWN, WorldLayout.CITY_RETURN_POINTS["A"], WorldLayout.CITY_RETURN_POINTS["B"]]:
			_check(_route_distance(route, spot) > WorldMonster.AGGRO_RADIUS, "Group %d never threatens %s" % [index + 1, spot])
	# The three deliberate encounter spots.
	var reach := func(spot: Vector2, index: int) -> bool: return HOMES[index].distance_to(spot) < WorldMonster.AGGRO_RADIUS - 20.0
	var never := func(spot: Vector2, index: int) -> bool: return _route_distance(WorldLayout.PROTOTYPE_GROUPS[index]["patrol"], spot) > WorldMonster.AGGRO_RADIUS + 5.0
	_check(reach.call(SPOT_A, 0) and never.call(SPOT_A, 1) and never.call(SPOT_A, 2), "Spot A: only group 1 can reach it")
	_check(reach.call(SPOT_B, 0) and reach.call(SPOT_B, 1) and never.call(SPOT_B, 2) and HOMES[0].distance_to(SPOT_B) < 100.0, "Spot B: groups 1 and 2, never group 3")
	_check(reach.call(SPOT_C, 0) and reach.call(SPOT_C, 1) and reach.call(SPOT_C, 2), "Spot C: all three groups")
	for spot in [SPOT_A, SPOT_B, SPOT_C]:
		_check(not _circle_hits_static(main, spot + Vector2(0, -24), 30.0) and not WorldThreatZones.is_in_city_safe_buffer(spot), "Spot %s is open ground outside safety" % spot)
	await _destroy(main)
	_sections_done.append("layout")


# --- Case A: one group ---------------------------------------------------------------------------

func _verify_case_a() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	var session := _session(main)
	_listen(main)
	var money: int = main.wallet.get_balance()
	var context := await _caught_at(player, SPOT_A)
	_check(context != null and _encounters.size() == 1 and _phases == [EncounterSession.Phase.JOINING], "Case A: one physical catch starts one encounter")
	_check(context.monster_id == IDS[0] and context.group_monster_ids == [IDS[0]] and context.get_group_count() == 1 and context.get_planned_combat_enemy_count() == 10, "Case A: 1 group, planned Combat size 10")
	_check(not _groups_label(session).visible, "Case A: no 敵軍加入 line")
	await _run_to_lock(main)
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and context.get_group_count() == 1 and context.get_planned_combat_enemy_count() == 10 and _joins.is_empty(), "Case A: LOCKED with 1 group, size 10")
	_check(not monsters[1].is_held() and not monsters[2].is_held(), "Case A: groups 2 and 3 not involved")
	_check(main.wallet.get_balance() == money and main.location.is_in_world(), "Case A: no Combat, no reward")
	await _destroy(main)
	_sections_done.append("case_a")


# --- Case B: two groups ------------------------------------------------------------------------

func _verify_case_b() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	var session := _session(main)
	_listen(main)
	var context := await _caught_at(player, SPOT_B)
	_check(context != null and context.monster_id == IDS[0] and context.get_group_count() >= 1, "Case B: group 1 catches the player")
	var encounter_id := context.encounter_id
	var triggered_at := context.triggered_at_ms
	var frames := 0
	while context.get_group_count() < 2 and frames < 120:
		await physics_frame
		frames += 1
	await process_frame
	_check(context.group_monster_ids == [IDS[0], IDS[1]] and context.get_planned_combat_enemy_count() == 15, "Case B: group 2 joins -> 2 groups, planned size 15 (%s)" % str(context.group_monster_ids))
	_check(_joins.size() == 1 and _joins[0][0] == IDS[1] and _joins[0][1] > 100.0, "Group 2 joined by aggro range, not contact (%.0f px away)" % (_joins[0][1] if _joins.size() > 0 else -1.0))
	_check(_groups_label(session).visible and _groups_label(session).text == "敵軍加入 ×2", "Case B: 敵軍加入 ×2")
	_check(_encounters.size() == 1 and context.encounter_id == encounter_id and context.triggered_at_ms == triggered_at, "Joining created no new trigger, id or timestamp")
	_check(session.get_remaining_ms() == 5000 - ADVANCE_AT_TRIGGER_MS and _status_text(session) == "遭遇準備 3.8...", "The window was not reset by group 2 (%d ms left)" % session.get_remaining_ms())
	_check(monsters[0].is_held() and monsters[1].is_held() and not monsters[2].is_held(), "Joined group 2 is held; group 3 is not involved")
	var g3: Vector2 = monsters[2].global_position
	await _frames(60)
	_check(context.get_group_count() == 2 and monsters[2].global_position != g3 and monsters[2].get_state() == WorldMonster.State.IDLE, "Group 3 keeps patrolling normally, and never joins")
	await _run_to_lock(main)
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and context.get_group_count() == 2 and context.get_planned_combat_enemy_count() == 15, "Case B: LOCKED with 2 groups, size 15")
	# After LOCKED nobody joins, even inside the player's range.
	monsters[2].global_position = player.global_position + Vector2(120.0, 0.0)
	await _frames(30)
	_check(context.get_group_count() == 2 and _joins.size() == 1 and _encounters.size() == 1, "No group joins after LOCKED")
	_check(monsters[0].is_held() and monsters[1].is_held() and _groups_label(session).text == "敵軍加入 ×2", "LOCKED: participants held, count still shown")
	await _destroy(main)
	_sections_done.append("case_b")


# --- Case C: three groups, recovery, repeat ------------------------------------------------------

func _verify_case_c() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	var session := _session(main)
	var handoff := _handoff(main)
	_listen(main)
	var money: int = main.wallet.get_balance()
	var context := await _caught_at(player, SPOT_C)
	var frames := 0
	while context != null and context.get_group_count() < 3 and frames < 120:
		await physics_frame
		frames += 1
	await process_frame
	var sorted_ids := context.group_monster_ids.duplicate()
	sorted_ids.sort()
	_check(context.get_group_count() == 3 and sorted_ids == IDS and context.group_monster_ids[0] == context.monster_id, "Case C: all three groups, catcher first, no duplicate (%s)" % str(context.group_monster_ids))
	_check(context.get_planned_combat_enemy_count() == 20 and _groups_label(session).text == "敵軍加入 ×3", "Case C: 3 groups, planned size 20, 敵軍加入 ×3")
	_check(_encounters.size() == 1 and _joins.size() == 2 and context.encounter_id == "encounter_1" and context.triggered_at_ms == T0, "Two joins, one trigger, same id and timestamp")
	_check(session.get_remaining_ms() == 5000 - ADVANCE_AT_TRIGGER_MS, "The window was not reset by groups 2 and 3")
	_check(monsters[0].is_held() and monsters[1].is_held() and monsters[2].is_held(), "Every participating group is held")
	# Staying in range: nothing duplicates; the cap holds.
	await _frames(60)
	_check(context.get_group_count() == 3 and _joins.size() == 2, "Still qualifying for 60 frames: no duplicate joins")
	_check(handoff.join_groups_in_range() == 0, "A full encounter takes no more groups")
	var extra := (load("res://scenes/world_monster.tscn") as PackedScene).instantiate() as WorldMonster
	extra.monster_id = "test_monster_04"
	extra.home_position = player.global_position + Vector2(-100.0, 0.0)
	extra.patrol_points = []
	main.get_node("Actors").add_child(extra)
	handoff.watch([extra], player, func() -> bool: return main.location.is_in_world(), main.time_source)
	_check(handoff.join_groups_in_range() == 0 and context.get_group_count() == 3, "A fourth group in range cannot join (cap 3)")
	extra.get_parent().remove_child(extra)
	extra.free()
	await _run_to_lock(main)
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and context.get_group_count() == 3 and context.get_planned_combat_enemy_count() == 20, "Case C: LOCKED with 3 groups, size 20")
	_check(monsters[0].is_held() and monsters[1].is_held() and monsters[2].is_held(), "LOCKED: all three held")
	_check(main.wallet.get_balance() == money and main.location.is_in_world() and handoff.get_pending_encounter() == context, "No Combat, no reward; the context waits for Combat")
	# Prototype recovery resets every participant.
	_check(session.prototype_end_encounter(), "Prototype end")
	var reset := true
	for index in range(3):
		reset = reset and not monsters[index].is_held() and monsters[index].global_position == HOMES[index] and monsters[index].get_state() == WorldMonster.State.IDLE and monsters[index].get_patrol_index() == 0
	_check(reset, "Every participating group released, home, IDLE, patrol from the start")
	_check(not player.movement_locked and session.get_context() == null and not handoff.has_pending_encounter() and not _groups_label(session).visible, "Encounter cleared, player unlocked, no stale membership")
	player.global_position = FAR
	await _frames(60)
	var patrolling := true
	for index in range(3):
		patrolling = patrolling and monsters[index].global_position != HOMES[index] and monsters[index].get_state() == WorldMonster.State.IDLE
	_check(patrolling, "All three patrol again")
	# Another multi-group encounter afterwards.
	await _frames(300)
	for index in range(3):
		monsters[index].reset_to_home()
	var second := await _caught_at(player, SPOT_C)
	frames = 0
	while second != null and second.get_group_count() < 3 and frames < 120:
		await physics_frame
		frames += 1
	_check(second != null and second.encounter_id == "encounter_2" and second.get_group_count() == 3 and second != context, "Another three-group encounter works afterwards")
	await _destroy(main)
	_sections_done.append("case_c")


# --- WORLD exit ------------------------------------------------------------------------------------

func _verify_world_exit() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	var session := _session(main)
	var handoff := _handoff(main)
	_listen(main)
	var context := await _caught_at(player, SPOT_C)
	var frames := 0
	while context != null and context.get_group_count() < 3 and frames < 120:
		await physics_frame
		frames += 1
	_check(context.get_group_count() == 3, "Test setup: three groups joining")
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city(), "Entered City A during JOINING")
	var clean := true
	for index in range(3):
		clean = clean and not monsters[index].is_held() and monsters[index].global_position == HOMES[index]
	_check(clean, "Every participant released and home")
	_check(session.get_phase() == EncounterSession.Phase.NONE and not handoff.has_pending_encounter() and not player.movement_locked and session.get_context() == null, "No phantom encounter, no lock, no membership")
	await _destroy(main)
	_sections_done.append("world_exit")


# --- Reload ----------------------------------------------------------------------------------------

func _verify_reload() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var player := _player(main)
	_listen(main)
	var context := await _caught_at(player, SPOT_C)
	var frames := 0
	while context != null and context.get_group_count() < 3 and frames < 120:
		await physics_frame
		frames += 1
	var position := player.global_position
	_check(context.get_group_count() == 3 and main.save_world_position(), "Saved during a three-group JOINING")
	var text := FileAccess.get_file_as_string(TEST_SAVE)
	var lower := text.to_lower()
	_check(int(JSON.parse_string(text)["version"]) == 8 and not lower.contains("group") and not lower.contains("encounter") and not lower.contains("monster"), "Save version 8; no groups, encounter or monster saved")
	await _destroy(main)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0 + 10000)
	root.add_child(main)
	_check(main.get_world_position() == position, "Reload restores the exact position")
	_check(_session(main).get_phase() == EncounterSession.Phase.NONE and not _handoff(main).has_pending_encounter() and not _player(main).movement_locked, "Reload: no encounter, no lock")
	var fresh := true
	var monsters := _monsters(main)
	for index in range(3):
		fresh = fresh and not monsters[index].is_held() and monsters[index].global_position == HOMES[index]
	_check(monsters.size() == 3 and fresh, "Reload: all three groups rebuilt at home, none held")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("reload")


# --- Helpers ------------------------------------------------------------------------------------

## Teleports the player to `spot` and waits for the first trigger (the clock
## moves on ADVANCE_AT_TRIGGER_MS the moment it fires).
func _caught_at(player: Player, spot: Vector2) -> EncounterContext:
	var count := _encounters.size()
	player.global_position = spot
	var frames := 0
	while _encounters.size() == count and frames < 600:
		await physics_frame
		frames += 1
	return _encounters.back() as EncounterContext if _encounters.size() > count else null


func _run_to_lock(main: Node) -> void:
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame


func _listen(main: Node) -> void:
	_encounters.clear()
	_joins.clear()
	_phases.clear()
	var handoff := _handoff(main)
	handoff.encounter_triggered.connect(func(context: EncounterContext) -> void:
		_encounters.append(context)
		main.time_source.advance_ms(ADVANCE_AT_TRIGGER_MS))
	handoff.group_joined.connect(func(_context: EncounterContext, id: String) -> void:
		var monster: WorldMonster = null
		for candidate in _monsters(main):
			if candidate.monster_id == id:
				monster = candidate
		_joins.append([id, monster.global_position.distance_to(_player(main).global_position) if monster else -1.0]))
	_session(main).phase_changed.connect(func(phase: int) -> void: _phases.append(phase))


func _route_distance(route: Array, spot: Vector2) -> float:
	var nearest := INF
	for index in range(route.size()):
		nearest = minf(nearest, Geometry2D.get_closest_point_to_segment(spot, route[index - 1], route[index]).distance_to(spot))
	return nearest


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


func _monsters(main: Node) -> Array:
	var list := []
	for name in ["Actors/PrototypeMonster", "Actors/PrototypeMonster2", "Actors/PrototypeMonster3"]:
		list.append(main.get_node(name) as WorldMonster)
	return list


func _status_text(session: EncounterSession) -> String:
	return (session.get_node("EncounterOverlay").find_children("StatusLabel", "Label", true, false)[0] as Label).text


func _groups_label(session: EncounterSession) -> Label:
	return session.get_node("EncounterOverlay").find_children("GroupsLabel", "Label", true, false)[0] as Label


func _frames(count: int) -> void:
	for frame in range(count):
		await physics_frame


func _player(main: Node) -> Player:
	return main.get_node("Actors/Player") as Player


func _handoff(main: Node) -> EncounterHandoff:
	return main.get_node("EncounterHandoff") as EncounterHandoff


func _session(main: Node) -> EncounterSession:
	return main.get_node("EncounterSession") as EncounterSession


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
