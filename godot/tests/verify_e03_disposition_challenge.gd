extends SceneTree

## Encounter E03: Aggressive / Passive World Enemy Groups and the manual
## challenge. Groups 1 and 2 are AGGRESSIVE, group 3 PASSIVE. A passive group
## never aggroes, chases, starts an encounter by contact or auto-joins; the
## player challenges it with 「挑戰」, which starts the normal encounter with it
## as the primary group (AGGRESSIVE groups may then join). Recovery protection
## blocks automatic aggro but never the challenge. Real main scene, physics
## frames, fixed TimeSource (no sleeps).

const TEST_SAVE := "user://e03_disposition_test_save.json"
const T0 := 1800000000000
const IDS := ["prototype_monster_01", "prototype_monster_02", "prototype_monster_03"]
const HOMES := [Vector2(800.0, 700.0), Vector2(1100.0, 700.0), Vector2(950.0, 930.0)]
const CITY_A := Vector2(200.0, 200.0)
const FAR := Vector2(3000.0, 3000.0)
## Player spots (teleported to right after the scene starts):
## PASSIVE_ONLY: in group 3's challenge range, out of groups 1 and 2's reach.
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
## WITH_GROUP_1: in group 3's challenge range and group 1's aggro range, out of
## group 2's whole itinerary.
const WITH_GROUP_1 := Vector2(800.0, 900.0)
## MIDDLE: in group 3's challenge range and both aggressive groups' range.
const MIDDLE := Vector2(950.0, 800.0)
## Only group 1 can reach it (the E02 one-group spot).
const AGGRESSIVE_ONLY := Vector2(640.0, 700.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _encounters := []
var _joins := []
var _phases := []
var _states := [[], [], []]


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	await _verify_aggressive()
	await _verify_passive()
	await _verify_challenge_ui()
	await _verify_challenge()
	await _verify_aggressive_primary()
	await _verify_protection()
	await _verify_world_exit_and_reload()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 8, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("E03 disposition challenge verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	var groups := WorldLayout.PROTOTYPE_GROUPS
	var ids := []
	var dispositions := []
	for group in groups:
		ids.append(group["id"])
		dispositions.append(group["disposition"])
	_check(groups.size() == 3 and ids == IDS, "Exactly three prototype groups (%s)" % str(ids))
	_check(WorldLayout.Disposition.keys() == ["AGGRESSIVE", "PASSIVE"], "Dispositions: AGGRESSIVE, PASSIVE")
	_check(dispositions == [WorldLayout.Disposition.AGGRESSIVE, WorldLayout.Disposition.AGGRESSIVE, WorldLayout.Disposition.PASSIVE], "Group 1 Aggressive, group 2 Aggressive, group 3 Passive")
	_check(EncounterHandoff.CHALLENGE_RANGE == 200.0 and WorldMonster.AGGRO_RADIUS == 240.0, "Challenge range 200 px; aggro radius still 240 px")
	_check(EncounterSession.CHALLENGE_TEXT == "挑戰", "Challenge button text 挑戰")
	_check(EncounterSession.JOIN_WINDOW_MS == 5000 and EncounterHandoff.MAX_GROUPS == 3 and EncounterContext.PLANNED_COMBAT_ENEMIES == {1: 10, 2: 15, 3: 20}, "Join window 5 s, at most 3 groups, sizes 10 / 15 / 20")
	var save_code := _code_only("res://scripts/save_store.gd").to_lower()
	_check(not save_code.contains("disposition") and not save_code.contains("passive") and not save_code.contains("challenge") and SaveStore.VERSION == 11, "Save version 11; dispositions and challenges are never saved")
	for path in ["res://scripts/encounter_session.gd", "res://scripts/encounter_handoff.gd", "res://scripts/world_monster.gd", "res://scripts/world_layout.gd"]:
		var code := _code_only(path).to_lower()
		for word in ["hostile", "neutral", "faction", "reputation", "battle", "damage", "health", "reward", "loot", "retreat", "cooldown", "randi", "randf"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	var scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_check(scene.count("instance=ExtResource(\"9_monster\")") == 3, "No fourth group in the scene")
	# Runtime: the same dispositions on every start.
	var first := await _new_main("")
	var runtime := []
	for monster in _monsters(first):
		runtime.append(monster.disposition)
	await _destroy(first)
	var second := await _new_main("")
	var again := []
	for monster in _monsters(second):
		again.append(monster.disposition)
	_check(runtime == dispositions and again == runtime and not _monsters(second)[0].is_passive() and not _monsters(second)[1].is_passive() and _monsters(second)[2].is_passive(), "Runtime dispositions match the config on every start")
	_check(second.find_children("*", "WorldMonster", true, false).size() == 3, "Three groups at runtime")
	await _destroy(second)
	_sections_done.append("static")


# --- Aggressive groups ---------------------------------------------------------------------------

func _verify_aggressive() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	_listen(main)
	var context := await _caught_at(player, AGGRESSIVE_ONLY)
	_check(1 in _states[0] and context != null and context.monster_id == IDS[0] and context.group_monster_ids == [IDS[0]], "Aggressive group 1 aggroes, chases and catches: it starts the encounter")
	_check(_session(main).get_phase() == EncounterSession.Phase.JOINING and player.movement_locked, "The catch starts the normal JOINING")
	await _destroy(main)
	# Safe buffer: an aggressive group next to a player inside safety does nothing.
	main = await _new_main("")
	monsters = _monsters(main)
	player = _player(main)
	_listen(main)
	monsters[0].patrol_points = []
	player.global_position = Vector2(560.0, 300.0)
	monsters[0].global_position = Vector2(720.0, 300.0)
	await _frames(60)
	_check(WorldThreatZones.is_in_city_safe_buffer(player.global_position) and not 1 in _states[0] and _encounters.is_empty(), "Aggressive group next to a player in a safe buffer: no aggro, no encounter")
	await _destroy(main)
	_sections_done.append("aggressive")


# --- Passive group ---------------------------------------------------------------------------------

func _verify_passive() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	_listen(main)
	player.global_position = PASSIVE_ONLY
	var start: Vector2 = monsters[2].global_position
	var paused := false
	var closest := INF
	for frame in range(600):
		await physics_frame
		paused = paused or monsters[2].is_patrol_paused()
		closest = minf(closest, monsters[2].global_position.distance_to(player.global_position))
	_check(closest < WorldMonster.AGGRO_RADIUS, "Test setup: the player stood inside group 3's aggro radius (%.0f px)" % closest)
	_check(_states[2].is_empty() and monsters[2].get_state() == WorldMonster.State.IDLE, "Passive group 3 never aggroes or chases")
	_check(monsters[2].global_position != start and paused, "Passive group 3 patrols and pauses normally")
	_check(_encounters.is_empty() and _states[0].is_empty() and _states[1].is_empty(), "Nothing else reacted")
	# Physical contact alone starts nothing.
	player.global_position = monsters[2].global_position + Vector2(0.0, 20.0)
	await _settle()
	await _frames(30)
	_check(monsters[2].is_in_contact() and _encounters.is_empty() and _session(main).get_phase() == EncounterSession.Phase.NONE, "Touching the passive group starts no encounter")
	_check(_challenge_button(main).visible, "It stays challengeable (挑戰 shown)")
	await _destroy(main)
	_sections_done.append("passive")


# --- Challenge button ----------------------------------------------------------------------------

func _verify_challenge_ui() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	var button := _challenge_button(main)
	player.global_position = FAR
	await _frames(3)
	_check(not button.visible, "Hidden with the passive group out of range")
	player.global_position = PASSIVE_ONLY
	await _frames(3)
	_check(button.visible and button.text == "挑戰" and not button.disabled and button.size.x >= 200.0 and button.size.y >= 72.0, "Shown in range: 挑戰, enabled, touch-sized (%s)" % button.size)
	player.global_position = monsters[2].global_position + Vector2(0.0, EncounterHandoff.CHALLENGE_RANGE + 20.0)
	await _frames(1)
	_check(not button.visible, "Hidden just outside the 200 px challenge range")
	# Outside WORLD (location data only, player still next to the group).
	player.global_position = PASSIVE_ONLY
	await _frames(2)
	_check(main.location.enter_city("A"), "Test setup: location IN_CITY")
	await _frames(2)
	_check(not button.visible and _handoff(main).get_challengeable_group() == null, "Hidden outside WORLD")
	await _destroy(main)
	# Inside a safe buffer, even with the passive group right there.
	main = await _new_main("")
	monsters = _monsters(main)
	player = _player(main)
	button = _challenge_button(main)
	monsters[2].patrol_points = []
	player.global_position = Vector2(560.0, 300.0)
	monsters[2].global_position = Vector2(660.0, 300.0)
	await _frames(3)
	_check(WorldThreatZones.is_in_city_safe_buffer(player.global_position) and not button.visible and not _session(main).challenge(), "Hidden and refused inside a city safe buffer")
	# Inactive target.
	player.global_position = PASSIVE_ONLY
	monsters[2].reset_to_home()
	await _frames(3)
	_check(button.visible, "Test setup: shown again")
	monsters[2].set_threat_active(false)
	await _frames(2)
	_check(not button.visible and not _session(main).challenge(), "Hidden and refused with the passive group inactive")
	await _destroy(main)
	_sections_done.append("challenge_ui")


# --- Manual challenge: passive primary, aggressive joiners --------------------------------------------

func _verify_challenge() -> void:
	# x2: group 3 challenged next to group 1.
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	var session := _session(main)
	_listen(main)
	var money: int = main.wallet.get_balance()
	player.global_position = WITH_GROUP_1
	await _frames(1)
	_check(_encounters.is_empty() and _challenge_button(main).visible, "Before the press: nothing started, 挑戰 shown")
	main.time_source.advance_ms(700)
	_challenge_button(main).pressed.emit()
	_challenge_button(main).pressed.emit()
	_check(_encounters.size() == 1 and session.challenge() == false, "Pressing 挑戰 (even twice) starts exactly one encounter")
	var context := _encounters[0] as EncounterContext
	_check(context.monster_id == IDS[2] and context.group_monster_ids == [IDS[2]] and context.encounter_id == "encounter_1", "Passive group 3 is the primary group, one encounter id")
	_check(context.triggered_at_ms == T0 + 700, "Timestamp = the challenge moment")
	_check(session.get_phase() == EncounterSession.Phase.JOINING and player.movement_locked and session.get_remaining_ms() == 5000 and monsters[2].is_held(), "JOINING, player locked, 5000 ms, group 3 held")
	_check(context.get_group_count() == 1 and context.get_planned_combat_enemy_count() == 10, "Starts with 1 group, planned size 10")
	_check(not _challenge_button(main).visible, "挑戰 hidden during JOINING")
	main.time_source.advance_ms(1000)
	var frames := 0
	while context.get_group_count() < 2 and frames < 120:
		await physics_frame
		frames += 1
	await process_frame
	_check(context.group_monster_ids == [IDS[2], IDS[0]] and context.get_planned_combat_enemy_count() == 15 and monsters[0].is_held(), "Aggressive group 1 joins by aggro: 2 groups, size 15")
	_check(_groups_label(session).text == "敵軍加入 ×2" and session.get_remaining_ms() == 4000 and context.triggered_at_ms == T0 + 700 and context.encounter_id == "encounter_1", "敵軍加入 ×2; the window was not reset")
	await _frames(120)
	_check(context.get_group_count() == 2 and not monsters[1].is_held(), "Group 2, out of reach, never joins")
	main.time_source.advance_ms(4000)
	await process_frame
	await process_frame
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and not _challenge_button(main).visible, "LOCKED at 5 s; 挑戰 hidden")
	_check(main.wallet.get_balance() == money and main.location.is_in_world(), "No Combat, no reward")
	_check(_handoff(main).get_challengeable_group() == null and _handoff(main).challenge(IDS[2]) == null and _encounters.size() == 1, "The handoff refuses a challenge while the encounter is pending")
	# The future Combat System takes the context: the handoff has nothing pending, the session is still LOCKED.
	_handoff(main).consume_pending_encounter()
	await process_frame
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and not _challenge_button(main).visible and session.challenge() == false and _encounters.size() == 1, "Still LOCKED after the hand-back: no 挑戰, no second encounter")
	await _destroy(main)
	# x3: group 3 challenged in the middle.
	main = await _new_main("")
	monsters = _monsters(main)
	player = _player(main)
	session = _session(main)
	_listen(main)
	player.global_position = MIDDLE
	_check(session.challenge(), "Challenge in the middle")
	context = _encounters[0] as EncounterContext
	frames = 0
	while context.get_group_count() < 3 and frames < 120:
		await physics_frame
		frames += 1
	await process_frame
	_check(context.group_monster_ids == [IDS[2], IDS[0], IDS[1]] and context.get_planned_combat_enemy_count() == 20, "Both aggressive groups join: [03, 01, 02], size 20")
	_check(_groups_label(session).text == "敵軍加入 ×3" and session.get_remaining_ms() == 5000 and _encounters.size() == 1, "敵軍加入 ×3; same window, one encounter")
	# Recovery resets every participant and starts protection.
	await _run_to_lock(main)
	_check(session.prototype_end_encounter(), "Prototype end")
	var reset := true
	for index in range(3):
		reset = reset and not monsters[index].is_held() and monsters[index].global_position == HOMES[index] and monsters[index].get_state() == WorldMonster.State.IDLE
	_check(reset and not player.movement_locked and session.is_protection_active(), "All participants reset home, player free, protection started")
	await _destroy(main)
	_sections_done.append("challenge")


# --- Aggressive primary: passive never auto-joins ----------------------------------------------------

func _verify_aggressive_primary() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	var session := _session(main)
	_listen(main)
	var context := await _caught_at(player, WITH_GROUP_1)
	_check(context != null and context.monster_id == IDS[0], "Group 1 catches the player next to passive group 3")
	await _frames(120)
	_check(monsters[2].global_position.distance_to(player.global_position) < WorldMonster.AGGRO_RADIUS, "Test setup: group 3 within the player's range")
	_check(context.group_monster_ids == [IDS[0]] and not monsters[2].is_held() and _joins.is_empty(), "Passive group 3 does not auto-join")
	_check(not _challenge_button(main).visible and session.challenge() == false and _handoff(main).get_challengeable_group() == null, "No 挑戰 while an encounter is active")
	await _destroy(main)
	# Both aggressive groups, passive in range too: 2 groups, never 3.
	main = await _new_main("")
	monsters = _monsters(main)
	player = _player(main)
	_listen(main)
	context = await _caught_at(player, Vector2(950.0, 700.0))
	var frames := 0
	while context != null and context.get_group_count() < 2 and frames < 120:
		await physics_frame
		frames += 1
	await _frames(120)
	var sorted_ids := context.group_monster_ids.duplicate()
	sorted_ids.sort()
	_check(sorted_ids == [IDS[0], IDS[1]] and not monsters[2].is_held(), "The other aggressive group joins; passive group 3 never does (%s)" % str(context.group_monster_ids))
	_check(monsters[2].global_position.distance_to(player.global_position) < WorldMonster.AGGRO_RADIUS + 10.0, "Test setup: group 3 was close by")
	await _destroy(main)
	_sections_done.append("aggressive_primary")


# --- Protection and the challenge ---------------------------------------------------------------------

func _verify_protection() -> void:
	var main := await _new_main("")
	var monsters := _monsters(main)
	var player := _player(main)
	var session := _session(main)
	var handoff := _handoff(main)
	_listen(main)
	await _caught_at(player, AGGRESSIVE_ONLY)
	await _run_to_lock(main)
	_check(session.prototype_end_encounter() and session.is_protection_active(), "Prototype end: protection on")
	# Aggressive groups do not aggro during protection.
	player.global_position = monsters[0].global_position + Vector2(120.0, 0.0)
	for index in range(3):
		_states[index].clear()
	await _frames(60)
	_check(_states[0].is_empty() and _encounters.size() == 1, "Protection: aggressive group 1 does not aggro")
	# The player walks up to the passive group: 挑戰 is offered and works.
	player.global_position = MIDDLE
	await _frames(2)
	_check(session.is_protection_active() and _protection_label(session).visible and _challenge_button(main).visible, "During protection 挑戰 is shown")
	_check(session.challenge(), "Challenge during protection")
	var context := _encounters.back() as EncounterContext
	_check(not session.is_protection_active() and not handoff.is_protected() and not _protection_label(session).visible, "The challenge ends protection; its countdown is gone")
	var stale := false
	for monster in monsters:
		stale = stale or monster.is_aggro_suppressed()
	_check(not stale, "No aggro suppression left")
	_check(context.monster_id == IDS[2] and session.get_phase() == EncounterSession.Phase.JOINING and player.movement_locked and session.get_remaining_ms() == 5000 and _status_text(session) == "遭遇準備 5.0...", "Normal JOINING from 5.0, player locked, group 3 primary")
	var frames := 0
	while context.get_group_count() < 3 and frames < 120:
		await physics_frame
		frames += 1
	_check(context.get_group_count() == 3, "Aggressive groups join the new encounter normally (%s)" % str(context.group_monster_ids))
	await _destroy(main)
	_sections_done.append("protection")


# --- WORLD exit and reload --------------------------------------------------------------------------

func _verify_world_exit_and_reload() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var monsters := _monsters(main)
	var player := _player(main)
	var session := _session(main)
	_listen(main)
	player.global_position = MIDDLE
	_check(session.challenge(), "Challenge")
	var frames := 0
	while (_encounters[0] as EncounterContext).get_group_count() < 3 and frames < 120:
		await physics_frame
		frames += 1
	var position := player.global_position
	_check(main.save_world_position(), "Saved during a challenged encounter")
	var saved := FileAccess.get_file_as_string(TEST_SAVE)
	var text := saved.to_lower()
	_check(int(JSON.parse_string(text)["version"]) == 11 and not text.contains("disposition") and not text.contains("passive") and not text.contains("challenge") and not text.contains("encounter"), "Save version 11; nothing about dispositions or the challenge")
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city(), "Entered City A during JOINING")
	var clean := true
	for index in range(3):
		clean = clean and not monsters[index].is_held() and monsters[index].global_position == HOMES[index]
	_check(clean and session.get_phase() == EncounterSession.Phase.NONE and not player.movement_locked and not _handoff(main).has_pending_encounter(), "WORLD exit clears every participant")
	await _frames(2)
	_check(not _challenge_button(main).visible, "No 挑戰 left in the city")
	await _destroy(main)
	# Entering the city saved the city; reload the save written during the encounter.
	var file := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	file.store_string(saved)
	file.close()
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.combat_enabled = false  # C01 test seam: observe the bare LOCKED phase
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	_check(main.get_world_position() == position and _session(main).get_phase() == EncounterSession.Phase.NONE and not _handoff(main).has_pending_encounter() and not _player(main).movement_locked, "Reload: exact position, no encounter, no lock")
	var fresh := true
	for monster in _monsters(main):
		fresh = fresh and not monster.is_held()
	_check(fresh and _monsters(main)[2].is_passive() and not _monsters(main)[0].is_passive(), "Reload: groups free, dispositions from config")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("world_exit_reload")


# --- Helpers ------------------------------------------------------------------------------------

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
	_states = [[], [], []]
	var handoff := _handoff(main)
	handoff.encounter_triggered.connect(func(context: EncounterContext) -> void: _encounters.append(context))
	handoff.group_joined.connect(func(_context: EncounterContext, id: String) -> void: _joins.append(id))
	var monsters := _monsters(main)
	for index in range(3):
		var list: Array = _states[index]
		monsters[index].state_changed.connect(func(_id: String, state: int) -> void: list.append(state))
	_session(main).phase_changed.connect(func(phase: int) -> void: _phases.append(phase))


func _monsters(main: Node) -> Array:
	var list := []
	for name in ["Actors/PrototypeMonster", "Actors/PrototypeMonster2", "Actors/PrototypeMonster3"]:
		list.append(main.get_node(name) as WorldMonster)
	return list


func _overlay(main_or_session: Node) -> Node:
	var session := main_or_session as EncounterSession
	if session == null:
		session = _session(main_or_session)
	return session.get_node("EncounterOverlay")


func _challenge_button(main: Node) -> Button:
	return _overlay(main).find_children("ChallengeButton", "Button", true, false)[0] as Button


func _status_text(session: EncounterSession) -> String:
	return (_overlay(session).find_children("StatusLabel", "Label", true, false)[0] as Label).text


func _groups_label(session: EncounterSession) -> Label:
	return _overlay(session).find_children("GroupsLabel", "Label", true, false)[0] as Label


func _protection_label(session: EncounterSession) -> Label:
	return _overlay(session).find_children("ProtectionLabel", "Label", true, false)[0] as Label


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
