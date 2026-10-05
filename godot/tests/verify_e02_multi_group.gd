extends SceneTree

## Encounter E02: up to three World Enemy Groups join one encounter during the
## fixed 5 s join window (never resetting it); the planned Combat size follows
## the group count (1 -> 10, 2 -> 15, 3 -> 20). Real main scene with all
## three prototype groups, physics frames, fixed TimeSource (no sleeps).

const TEST_SAVE := "user://e02_multi_group_test_save.json"
const T0 := 1800000000000
const IDS := ["prototype_monster_01", "prototype_monster_02", "prototype_monster_03"]
## E02 fix pass: new homes (aggro 240 px) and zone (30 px further south).
const HOMES := [Vector2(800.0, 700.0), Vector2(1100.0, 700.0), Vector2(950.0, 930.0)]
const ZONE := Rect2(560.0, 450.0, 680.0, 610.0)
const CITY_A := Vector2(200.0, 200.0)
const FAR := Vector2(3000.0, 3000.0)
## Player spots (teleported to right after the scene starts, all groups at
## home): A west of group 1, out of reach of groups 2 and 3; B north between
## groups 1 and 2 (group 1 clearly nearer, so it catches first), out of group
## 3's whole itinerary; C the middle, within range of all three homes.
const SPOT_A := Vector2(640.0, 700.0)
const SPOT_B := Vector2(900.0, 600.0)
const SPOT_C := Vector2(950.0, 780.0)
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
	await _verify_patrol_fix()
	await _verify_protection()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 9, "Every test section must run to completion (%s)" % str(_sections_done))
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
		# E03 brought Aggressive / Passive and the manual challenge into scope
		# (verify_e03_disposition_challenge).
		for word in ["battle", "damage", "health", "reward", "loot", "retreat", "randi", "randf", "navigation"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	_check(not _code_only("res://scripts/save_store.gd").to_lower().contains("group") and SaveStore.VERSION == 13, "Save version 13 (Stage 9 P01); the save knows nothing about groups")
	_sections_done.append("static")


# --- Layout ----------------------------------------------------------------------------------

func _verify_layout() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var runtime_ids := []
	for monster in monsters:
		runtime_ids.append(monster.monster_id)
	_check(runtime_ids == IDS and main.find_children("*", "WorldMonster", true, false).size() == 3, "Three World Enemy Groups at runtime (%s)" % str(runtime_ids))
	_check(WorldThreatZones.LOW_THREAT_ZONE_01 == ZONE, "low_threat_zone_01 grown to x 560–1240, y 450–1060")
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
	var reach := func(spot: Vector2, index: int) -> bool: return HOMES[index].distance_to(spot) < WorldMonster.AGGRO_RADIUS - 10.0
	var never := func(spot: Vector2, index: int) -> bool: return _route_distance(WorldLayout.PROTOTYPE_GROUPS[index]["patrol"], spot) > WorldMonster.AGGRO_RADIUS + 5.0
	_check(reach.call(SPOT_A, 0) and never.call(SPOT_A, 1) and never.call(SPOT_A, 2), "Spot A: only group 1 can reach it")
	_check(reach.call(SPOT_B, 0) and reach.call(SPOT_B, 1) and never.call(SPOT_B, 2) and HOMES[0].distance_to(SPOT_B) + 60.0 < HOMES[1].distance_to(SPOT_B), "Spot B: groups 1 and 2, never group 3")
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
	# Another multi-group encounter afterwards (after the 5 s recovery
	# protection that follows the prototype end).
	main.time_source.advance_ms(EncounterSession.PROTECTION_MS)
	await process_frame
	await process_frame
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
	_check(int(JSON.parse_string(text)["version"]) == 13 and not lower.contains("group") and not lower.contains("encounter") and not lower.contains("monster"), "Save version 13 (Stage 9 P01); no groups, encounter or monster saved")
	await _destroy(main)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.combat_enabled = false  # C01 test seam: observe the bare LOCKED phase
	_all_aggressive(main)
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


# --- E02 fix pass: controlled irregular patrol with pauses ------------------------------------------

func _verify_patrol_fix() -> void:
	_check(WorldMonster.AGGRO_RADIUS == 240.0, "Aggro radius 240 (was 200)")
	var groups := WorldLayout.PROTOTYPE_GROUPS
	var shapes := []
	for index in range(3):
		var group: Dictionary = groups[index]
		var route: Array = group["patrol"]
		var pauses: Array = group["pauses"]
		var shape := []
		for point in route:
			shape.append((point as Vector2) - (group["home"] as Vector2))
		shapes.append(shape)
		_check(pauses.size() == route.size(), "Group %d: one pause entry per stop" % (index + 1))
		var paused_stops := 0
		var in_bounds := true
		for pause in pauses:
			if pause > 0.0:
				paused_stops += 1
				in_bounds = in_bounds and pause >= 0.5 and pause <= 2.0
		_check(paused_stops >= 1 and paused_stops < route.size() and in_bounds, "Group %d pauses at some stops (not all), 0.5–2.0 s each" % (index + 1))
		_check(_has_varied_order(route), "Group %d revisits a point with a different next stop (not one rigid loop)" % (index + 1))
	_check(groups[0]["patrol"] != groups[1]["patrol"] and groups[1]["patrol"] != groups[2]["patrol"] and groups[0]["patrol"] != groups[2]["patrol"], "Three distinct itineraries")
	_check(shapes[0] != shapes[1] and shapes[1] != shapes[2] and shapes[0] != shapes[2], "Different route shapes, not one shifted loop")
	for pair in [[0, 1], [1, 2], [0, 2]]:
		var gap := _routes_gap(groups[pair[0]]["patrol"], groups[pair[1]]["patrol"])
		_check(gap > 50.0 and gap < WorldMonster.AGGRO_RADIUS * 2.0, "Groups %d and %d roam separately but their reach overlaps (%.0f px apart at closest)" % [pair[0] + 1, pair[1] + 1, gap])
		_check(HOMES[pair[0]].distance_to(HOMES[pair[1]]) > 250.0, "Groups %d and %d do not stack together" % [pair[0] + 1, pair[1] + 1])
	# Determinism: two fresh starts move all three groups identically.
	var first := await _world_track(900)
	var second := await _world_track(900)
	_check(first["positions"] == second["positions"], "Patrol is deterministic across runs (900 frames, 3 groups)")
	# Pauses: group 1's first pause is its 1.2 s stop at (900, 790).
	var pause_frames: Array = first["pause_frames"][0]
	_check(pause_frames.size() >= 1, "Group 1 pauses during its itinerary")
	if pause_frames.size() >= 1:
		var length: int = pause_frames[0][1]
		_check(absi(length - 72) <= 2 and pause_frames[0][2] == Vector2(900.0, 790.0), "Pause of 1.2 s (%d frames) at its stop" % length)
	_check(first["moved_after_pause"][0], "Patrol resumes after the pause")
	for index in range(3):
		_check((first["pause_frames"][index] as Array).size() >= 1, "Group %d pauses at some point" % (index + 1))
	# A chase ends a pause at once.
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	var frames := 0
	while not monsters[0].is_patrol_paused() and frames < 900:
		await physics_frame
		frames += 1
	_check(monsters[0].is_patrol_paused(), "Test setup: group 1 paused")
	var paused_at: Vector2 = monsters[0].global_position
	player.global_position = paused_at + Vector2(-140.0, -60.0)
	await physics_frame
	await physics_frame
	await physics_frame
	_check(monsters[0].get_state() == WorldMonster.State.CHASE and not monsters[0].is_patrol_paused() and monsters[0].global_position != paused_at, "A player in range ends the pause: CHASE at once")
	monsters[0].reset_to_home()
	_check(not monsters[0].is_patrol_paused() and monsters[0].get_patrol_index() == 0 and monsters[0].global_position == HOMES[0], "Reset: home, itinerary from its start, no pause left")
	# A reset in the middle of a pause (e.g. leaving WORLD) clears the pause.
	frames = 0
	while not monsters[1].is_patrol_paused() and frames < 900:
		await physics_frame
		frames += 1
	_check(monsters[1].is_patrol_paused(), "Test setup: group 2 paused")
	monsters[1].reset_to_home()
	var reset_at: Vector2 = monsters[1].global_position
	await _frames(20)
	_check(monsters[1].get_patrol_index() == 0 and monsters[1].global_position != reset_at, "Reset during a pause: no pause left, the itinerary restarts at once")
	await _destroy(main)
	_sections_done.append("patrol_fix")


# --- E02 fix pass: 5 s recovery protection -------------------------------------------------------------

func _verify_protection() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var monsters := _monsters(main)
	var player := _player(main)
	var session := _session(main)
	var handoff := _handoff(main)
	_listen(main)
	_check(EncounterSession.PROTECTION_MS == 5000, "Recovery protection lasts 5000 ms")
	# A monster chasing when protection starts turns back.
	player.global_position = SPOT_A
	var frames := 0
	while monsters[0].get_state() != WorldMonster.State.CHASE and frames < 60:
		await physics_frame
		frames += 1
	await _frames(15)
	var chased_to: Vector2 = monsters[0].global_position
	_check(monsters[0].get_state() == WorldMonster.State.CHASE and chased_to.distance_to(HOMES[0]) > 20.0, "Test setup: group 1 chasing, away from home")
	handoff.set_protected(true)
	await physics_frame
	await physics_frame
	_check(monsters[0].get_state() == WorldMonster.State.RETURNING and monsters[0].global_position.distance_to(HOMES[0]) < chased_to.distance_to(HOMES[0]) and _encounters.is_empty(), "Protection turns a chasing group back")
	handoff.set_protected(false)
	player.global_position = FAR
	await _frames(300)
	# Encounter -> LOCKED -> prototype end -> protection.
	var context := await _caught_at(player, SPOT_A)
	await _run_to_lock(main)
	_check(context != null and session.get_phase() == EncounterSession.Phase.LOCKED, "Test setup: LOCKED")
	_check(not session.is_protection_active() and not handoff.is_protected(), "No protection before the prototype end")
	var money: int = main.wallet.get_balance()
	_end_button(session).pressed.emit()
	_check(session.is_protection_active() and handoff.is_protected() and session.get_protection_remaining_ms() == 5000, "Prototype end starts exactly 5000 ms of protection")
	_check(_protection_label(session).visible and _protection_label(session).text == "遭遇保護 5.0...", "遭遇保護 5.0... shown")
	var suppressed := true
	for monster in monsters:
		suppressed = suppressed and monster.is_aggro_suppressed() and not monster.is_held()
	_check(suppressed, "Every group's aggro is suppressed; none held")
	_check(not player.movement_locked, "The player is free")
	var at := player.global_position
	Input.action_press("move_left")
	await _frames(10)
	Input.action_release("move_left")
	await physics_frame
	_check(player.global_position != at, "The player moves during protection")
	var before := []
	for monster in monsters:
		before.append(monster.global_position)
	await _frames(60)
	var patrolling := false
	var calm := true
	for index in range(3):
		patrolling = patrolling or monsters[index].global_position != before[index]
		calm = calm and monsters[index].get_state() != WorldMonster.State.CHASE
	_check(patrolling and calm, "Groups keep patrolling, nobody chases")
	# Right next to and even on top of group 1: no aggro, no encounter.
	player.global_position = monsters[0].global_position + Vector2(120.0, 0.0)
	await _frames(60)
	_check(monsters[0].get_state() != WorldMonster.State.CHASE and _encounters.size() == 1, "In range during protection: no aggro")
	player.global_position = monsters[0].global_position + Vector2(0.0, 20.0)
	await _settle()
	await _frames(30)
	_check(_encounters.size() == 1 and not handoff.has_pending_encounter() and session.get_phase() == EncounterSession.Phase.NONE, "Touching a group during protection: no new encounter")
	# Countdown on the fixed clock.
	main.time_source.advance_ms(4999)
	await process_frame
	await process_frame
	_check(session.is_protection_active() and session.get_protection_remaining_ms() == 1 and _protection_label(session).text == "遭遇保護 0.1...", "4999 ms: still protected (遭遇保護 0.1...)")
	# Reload during protection restores none of it.
	_check(main.save_world_position(), "Saved during protection")
	var text := FileAccess.get_file_as_string(TEST_SAVE)
	_check(int(JSON.parse_string(text)["version"]) == 13 and not text.to_lower().contains("protect"), "Save version 13 (Stage 9 P01); no protection saved")
	main.time_source.advance_ms(1)
	await process_frame
	await process_frame
	_check(not session.is_protection_active() and not handoff.is_protected() and not _protection_label(session).visible, "5000 ms: protection over, label gone")
	var restored := true
	for monster in monsters:
		restored = restored and not monster.is_aggro_suppressed()
	_check(restored, "Every group can aggro again")
	# Encounter protection recheck (corrective): the player still touches
	# group 1 (contact reported, and ignored, during protection), so the end
	# of protection starts the normal encounter at once.
	_check(_encounters.size() == 2 and (_encounters.back() as EncounterContext).encounter_id == "encounter_2" and (_encounters.back() as EncounterContext).monster_id == monsters[0].monster_id and session.get_phase() == EncounterSession.Phase.JOINING, "Still touching group 1 when protection ends: encounter at once")
	await _run_to_lock(main)
	_end_button(session).pressed.emit()
	player.global_position = FAR
	await _settle()
	main.time_source.advance_ms(EncounterSession.PROTECTION_MS)
	await process_frame
	await process_frame
	_check(not session.is_protection_active() and session.get_phase() == EncounterSession.Phase.NONE and _encounters.size() == 2, "That encounter ended (prototype end; the player left before its protection ran out), nothing pending")
	await _frames(300)
	var again := await _caught_at(player, SPOT_A)
	_check(again != null and again.encounter_id == "encounter_3", "After protection, a new catch starts an encounter")
	_check(main.wallet.get_balance() == money, "No reward at any point")
	await _destroy(main)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.combat_enabled = false  # C01 test seam: observe the bare LOCKED phase
	_all_aggressive(main)
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	var fresh := not _session(main).is_protection_active() and not _handoff(main).is_protected()
	for monster in _monsters(main):
		fresh = fresh and not monster.is_aggro_suppressed()
	_check(fresh, "Reload: no protection restored")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("protection")


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
	main.combat_enabled = false  # C01 test seam: observe the bare LOCKED phase
	_all_aggressive(main)
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


## Whether an itinerary revisits some point with a different next stop.
func _has_varied_order(route: Array) -> bool:
	var next_of := {}
	for index in range(route.size()):
		var point: Vector2 = route[index]
		var next: Vector2 = route[(index + 1) % route.size()]
		if next_of.has(point) and next_of[point] != next:
			return true
		next_of[point] = next
	return false


## Closest distance between two itineraries' straight legs.
func _routes_gap(a: Array, b: Array) -> float:
	var gap := INF
	for i in range(a.size()):
		for step in range(21):
			var point := (a[i - 1] as Vector2).lerp(a[i], step / 20.0)
			gap = minf(gap, _route_distance(b, point))
	return gap


## Every group's position per physics frame after a fresh start (player far),
## plus each group's pauses as [start frame, length, position].
func _world_track(frames: int) -> Dictionary:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.combat_enabled = false  # C01 test seam: observe the bare LOCKED phase
	_all_aggressive(main)
	main.save_path = ""
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	var monsters := _monsters(main)
	var positions := []
	var pauses := [[], [], []]
	var moved_after := [false, false, false]
	var started := [-1, -1, -1]
	for frame in range(frames):
		await physics_frame
		var row := []
		for index in range(3):
			var monster: WorldMonster = monsters[index]
			row.append(monster.global_position)
			if monster.is_patrol_paused() and started[index] < 0:
				started[index] = frame
			elif not monster.is_patrol_paused() and started[index] >= 0:
				pauses[index].append([started[index], frame - started[index], positions.back()[index] if positions.size() > 0 else monster.global_position])
				started[index] = -1
			elif pauses[index].size() > 0 and started[index] < 0 and positions.size() > 0 and monster.global_position != positions.back()[index]:
				moved_after[index] = true
		positions.append(row)
	await _destroy(main)
	return {"positions": positions, "pause_frames": pauses, "moved_after_pause": moved_after}


func _protection_label(session: EncounterSession) -> Label:
	return session.get_node("EncounterOverlay").find_children("ProtectionLabel", "Label", true, false)[0] as Label


func _end_button(session: EncounterSession) -> Button:
	return session.get_node("EncounterOverlay").find_children("PrototypeEndButton", "Button", true, false)[0] as Button


## E03: all three groups AGGRESSIVE (group 3 is PASSIVE by design): the
## all-hostile world these E02 checks were written for;
## verify_e03_disposition_challenge covers the real dispositions.
func _all_aggressive(main: Node) -> void:
	(main.get_node("Actors/PrototypeMonster3") as WorldMonster).disposition = WorldLayout.Disposition.AGGRESSIVE


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
