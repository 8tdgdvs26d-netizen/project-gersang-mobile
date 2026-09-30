extends SceneTree

## Combat C02: Combat <-> World lifecycle. A finished battle produces one
## BattleResult; main.commit_battle_result() consumes it exactly once:
## protection on, VICTORY removes the participating World Enemy Groups from
## the current session's world (DEFEAT resets them home), the encounter ends,
## the battle closes, the player is free where the encounter caught them, and
## the game saves once (a failed save never undoes the result). Victory
## removal is session only: a relaunch rebuilds the fixed Prototype groups
## (Approved Known Limitation). Real main scene, fixed TimeSource.

const TEST_SAVE := "user://c02_lifecycle_test_save.json"
const BAD_SAVE := "user://c02_missing_dir/save.json"
const T0 := 1800000000000
const IDS := ["prototype_monster_01", "prototype_monster_02", "prototype_monster_03"]
const NODES := ["Actors/PrototypeMonster", "Actors/PrototypeMonster2", "Actors/PrototypeMonster3"]
const HOMES := [Vector2(800.0, 700.0), Vector2(1100.0, 700.0), Vector2(950.0, 930.0)]
## E03 spots: groups 3 + 1 (group 2 out of reach) / only passive group 3.
const WITH_GROUP_1 := Vector2(800.0, 900.0)
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const HELD_SPOT := Vector2(990.0, 960.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _commits := []
var _removed := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	_verify_result()
	await _verify_victory()
	await _verify_defeat()
	await _verify_save_failure()
	await _verify_refusals()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 6, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("C02 world lifecycle verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(SaveStore.VERSION == 8 and SaveStore.V8_KEYS == SaveStore.V7_KEYS, "Save version 8, unchanged sections")
	for path in ["res://scripts/save_store.gd"]:
		var code := _code_only(path).to_lower()
		for word in ["combat", "battle", "defeated", "monster", "group", "respawn"]:
			_check(not code.contains(word), "%s knows nothing about %s" % [path.get_file(), word])
	for path in ["res://scripts/battle_result.gd", "res://scripts/main.gd", "res://scripts/encounter_handoff.gd", "res://scripts/encounter_session.gd"]:
		var code := _code_only(path).to_lower()
		for word in ["reward", "loot", "exp ", "experience", "hospital", "revive", "penalty", "respawn", "retreat"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	_check(main.combat_enabled, "Combat is on in the game")
	main.free()
	_sections_done.append("static")


# --- Battle Result ---------------------------------------------------------------------------------

func _verify_result() -> void:
	for victory in [true, false]:
		var context := EncounterContext.new()
		context.encounter_id = "encounter_7"
		context.group_monster_ids.append(IDS[2])
		context.group_monster_ids.append(IDS[0])
		var battle := CombatBattle.from_encounter(context)
		battle.advance(3000)
		_check(battle.get_result() == null, "No result while the battle runs")
		if victory:
			for enemy in battle.get_enemies():
				battle.resolve_damage(battle.get_hero(), enemy, 1000)
		else:
			battle.resolve_damage(battle.get_enemies()[0], battle.get_hero(), 1000)
		var result := battle.get_result()
		var label := "VICTORY" if victory else "DEFEAT"
		_check(result != null and result.outcome == (BattleResult.Outcome.VICTORY if victory else BattleResult.Outcome.DEFEAT) and result.is_victory() == victory, "%s produces a %s result" % [label, label])
		_check(result.encounter_id == "encounter_7" and result.group_monster_ids == [IDS[2], IDS[0]], "%s result keeps the encounter id and groups" % label)
		battle.advance(1000)
		battle.resolve_damage(battle.get_enemies()[1], battle.get_hero(), 5)
		_check(battle.get_result() == result and not result.is_committed(), "%s: one result object, not committed by Combat" % label)
		context.group_monster_ids.append(IDS[1])
		_check(result.group_monster_ids.size() == 2, "The result keeps its own copy of the groups")
		_check(result.claim_commit() and result.is_committed() and not result.claim_commit(), "A result can be claimed only once")
	_sections_done.append("result")


# --- Victory -------------------------------------------------------------------------------------

func _verify_victory() -> void:
	var main := await _new_main(TEST_SAVE)
	var player := _player(main)
	var session := _session(main)
	var handoff := _handoff(main)
	var view := main.get_node("CombatView") as CombatView
	var money: int = main.wallet.get_balance()
	var items: Dictionary = main.inventory.get_items().duplicate(true)
	var battle := await _locked_battle(main, WITH_GROUP_1, 2)
	_check(battle != null and battle.group_monster_ids == [IDS[2], IDS[0]], "Battle for groups 3 + 1 (group 2 not involved)")
	_check(not session.prototype_end_enabled and not _end_button(session).visible and not session.prototype_end_encounter() and session.get_phase() == EncounterSession.Phase.LOCKED, "The old bare-LOCKED prototype exit is off in the game")
	var spot := player.global_position
	var group_2 := main.get_node(NODES[1]) as WorldMonster
	(main.get_node(NODES[2]) as WorldMonster).global_position = HELD_SPOT
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)
	var result := battle.get_result()
	_check(result.is_victory() and not result.is_committed(), "VICTORY result waiting for the world")
	_delete(TEST_SAVE)
	var exit := view.get_node("ExitButton") as Button
	await process_frame
	_check(exit.visible and exit.text == "返回世界", "Result screen shows 返回世界")
	var group_2_position := group_2.global_position
	exit.pressed.emit()
	# Synchronous: everything below happened inside the one press.
	_check(result.is_committed() and _commits.size() == 1 and _commits[0][0] == result and _commits[0][1] == true, "One commit, saved")
	_check(not main.has_node(NODES[0]) and not main.has_node(NODES[2]), "Participating groups 1 and 3 left the world")
	_check(_removed.size() == 2 and _removed.map(func(entry: Array) -> String: return entry[0]).has(IDS[0]) and _removed.map(func(entry: Array) -> String: return entry[0]).has(IDS[2]), "Exactly the two participants were removed")
	_check(_removed.any(func(entry: Array) -> bool: return entry[0] == IDS[2] and entry[1] == HELD_SPOT), "Removed where they stood, never reset home")
	_check(main._world_monsters.size() == 1 and main._world_monsters[0] == group_2, "Only group 2 remains in the world list")
	_check(not handoff._monsters.has(IDS[0]) and not handoff._monsters.has(IDS[2]) and handoff._monsters.has(IDS[1]), "The handoff no longer watches the removed groups")
	_check(is_instance_valid(group_2) and group_2.is_threat_active() and not group_2.is_held() and group_2.global_position == group_2_position, "Group 2 untouched")
	_check(session.get_phase() == EncounterSession.Phase.NONE and not handoff.has_pending_encounter() and session.get_context() == null, "The encounter ended")
	_check(main.get_combat() == null and not view.visible and not view.is_open(), "The battle closed")
	_check(not player.movement_locked and player.global_position == spot and main.location.is_in_world(), "Player free at the encounter position, in WORLD")
	_check(_joystick(main).is_processing_input(), "World joystick input back")
	_check(session.is_protection_active() and session.get_protection_remaining_ms() == 5000 and handoff.is_protected(), "5 s recovery protection")
	_check(main.wallet.get_balance() == money and main.inventory.get_items() == items, "No reward, loot or item change")
	var saved: Variant = _read(TEST_SAVE)
	_check(saved != null and int(saved["version"]) == 8 and Vector2(saved["location"]["world_position"]["x"], saved["location"]["world_position"]["y"]) == spot, "Saved once after the commit: v8, the encounter position")
	_check(not FileAccess.get_file_as_string(TEST_SAVE).to_lower().contains("monster") and not FileAccess.get_file_as_string(TEST_SAVE).to_lower().contains("battle"), "The save holds no group or battle data")
	# Duplicates: button, signal, direct call, later frames.
	var saved_text := FileAccess.get_file_as_string(TEST_SAVE)
	_delete(TEST_SAVE)
	main.time_source.advance_ms(1000)
	exit.pressed.emit()
	view.exit_requested.emit()
	_check(not main.commit_battle_result(result), "A second commit is refused")
	await _settle()
	_check(_commits.size() == 1 and _removed.size() == 2 and not FileAccess.file_exists(TEST_SAVE), "Repeats change nothing: no second commit, removal or save")
	_check(session.get_protection_remaining_ms() == 4000, "Protection not restarted by a repeat (%d)" % session.get_protection_remaining_ms())
	_write(TEST_SAVE, saved_text)
	# Same session: world transitions never bring the groups back.
	player.global_position = WorldLayout.CITY_A
	await _settle()
	_check(main.try_enter_city() and main.leave_city(), "Enter and leave City A")
	await _settle()
	_check(not main.has_node(NODES[0]) and not main.has_node(NODES[2]) and main._world_monsters.size() == 1 and group_2.is_threat_active(), "After a city visit groups 1 and 3 are still gone")
	player.global_position = PASSIVE_ONLY
	main.time_source.advance_ms(10000)
	await _settle()
	_check(handoff.get_challengeable_group() == null and not session.challenge(), "Removed passive group 3 can no longer be challenged")
	var frames := 0
	while frames < 180:
		await physics_frame
		frames += 1
	_check(session.get_phase() == EncounterSession.Phase.NONE and not handoff.has_pending_encounter(), "No encounter from the removed groups")
	var last_saved: Variant = _read(TEST_SAVE)["location"]["world_position"]
	await _destroy(main)
	# Relaunch: the fixed Prototype groups come back (Approved Known Limitation).
	main = await _new_main(TEST_SAVE)
	var back := true
	for index in range(3):
		back = back and main.has_node(NODES[index]) and (main.get_node(NODES[index]) as WorldMonster).monster_id == IDS[index]
	_check(back and main._world_monsters.size() == 3, "Relaunch rebuilds all three Prototype groups (session-only removal)")
	_check(main.get_world_position() == Vector2(last_saved["x"], last_saved["y"]) and SaveStore.VERSION == 8, "Relaunch restores the last saved position; save v8")
	await _destroy(main)
	_sections_done.append("victory")


# --- Defeat --------------------------------------------------------------------------------------

func _verify_defeat() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	var player := _player(main)
	var session := _session(main)
	var handoff := _handoff(main)
	var view := main.get_node("CombatView") as CombatView
	var money: int = main.wallet.get_balance()
	var battle := await _locked_battle(main, WITH_GROUP_1, 2)
	var spot := player.global_position
	var groups := NODES.map(func(path: String) -> WorldMonster: return main.get_node(path) as WorldMonster)
	(groups[2] as WorldMonster).global_position = HELD_SPOT
	var group_2_position: Vector2 = (groups[1] as WorldMonster).global_position
	battle.resolve_damage(battle.get_enemies()[0], battle.get_hero(), 1000)
	var result := battle.get_result()
	_check(result != null and not result.is_victory() and result.group_monster_ids == [IDS[2], IDS[0]], "DEFEAT result for groups 3 + 1")
	_delete(TEST_SAVE)
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(result.is_committed() and _commits.size() == 1 and _commits[0][1] == true, "One commit, saved")
	var reset := true
	for index in [0, 2]:
		var monster := groups[index] as WorldMonster
		reset = reset and is_instance_valid(monster) and main.has_node(NODES[index]) and not monster.is_held() and monster.global_position == HOMES[index] and monster.get_state() == WorldMonster.State.IDLE and monster.is_threat_active()
	_check(reset and _removed.is_empty(), "Participants 1 and 3 reset home, IDLE; nothing removed")
	_check((groups[1] as WorldMonster).global_position == group_2_position and not (groups[1] as WorldMonster).is_held() and main._world_monsters.size() == 3, "Group 2 untouched; three groups in the world")
	_check(session.get_phase() == EncounterSession.Phase.NONE and not handoff.has_pending_encounter() and main.get_combat() == null and not view.visible, "Encounter ended, battle closed")
	_check(not player.movement_locked and player.global_position == spot and main.location.is_in_world() and not main.is_in_city(), "Player free at the encounter position, in WORLD (no city, no hospital)")
	_check(_joystick(main).is_processing_input(), "World joystick input back")
	_check(session.is_protection_active() and session.get_protection_remaining_ms() == 5000, "5 s recovery protection")
	_check(main.wallet.get_balance() == money and main.character_stats.get_strength() == CharacterStats.PROTOTYPE_DEFAULT_STRENGTH, "No money or stat penalty")
	var saved: Variant = _read(TEST_SAVE)
	_check(saved != null and int(saved["version"]) == 8 and Vector2(saved["location"]["world_position"]["x"], saved["location"]["world_position"]["y"]) == spot, "Saved once: v8, the encounter position")
	_delete(TEST_SAVE)
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(not main.commit_battle_result(result) and _commits.size() == 1 and not FileAccess.file_exists(TEST_SAVE), "A repeated DEFEAT commit changes nothing")
	# Group 1's home is 200 px from the player: protection keeps it away.
	var frames := 0
	while frames < 120:
		await physics_frame
		frames += 1
	_check((groups[0] as WorldMonster).get_state() == WorldMonster.State.IDLE and session.get_phase() == EncounterSession.Phase.NONE, "No re-aggro or re-trigger during protection")
	main.time_source.advance_ms(5000)
	frames = 0
	while session.get_phase() == EncounterSession.Phase.NONE and frames < 600:
		await physics_frame
		frames += 1
	_check(not session.is_protection_active() and session.get_phase() == EncounterSession.Phase.JOINING and session.get_context().monster_id == IDS[0] and session.get_context().encounter_id == "encounter_2", "After protection the reset group 1 catches the player again (normal rules)")
	await _destroy(main)
	_sections_done.append("defeat")


# --- Save failure --------------------------------------------------------------------------------

func _verify_save_failure() -> void:
	var main := await _new_main("")
	var session := _session(main)
	var battle := await _locked_battle(main, PASSIVE_ONLY, 1)
	main.save_path = BAD_SAVE
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)
	var result := battle.get_result()
	_check(main.commit_battle_result(result), "The commit succeeds although the save will fail")
	_check(_commits.size() == 1 and _commits[0][1] == false and not FileAccess.file_exists(BAD_SAVE), "The save failed (reported)")
	_check(not main.has_node(NODES[2]) and main.has_node(NODES[0]) and main.has_node(NODES[1]), "Committed VICTORY kept: group 3 removed, 1 and 2 stay")
	_check(session.get_phase() == EncounterSession.Phase.NONE and not _player(main).movement_locked and session.is_protection_active() and main.get_combat() == null, "No rollback: encounter ended, player free, protected")
	_check(not main.commit_battle_result(result) and _commits.size() == 1, "No second attempt for the same result")
	await _destroy(main)
	_sections_done.append("save_failure")


# --- Refusals ------------------------------------------------------------------------------------

func _verify_refusals() -> void:
	var main := await _new_main("")
	var session := _session(main)
	_check(not main.commit_battle_result(null), "No battle: nothing to commit")
	var battle := await _locked_battle(main, PASSIVE_ONLY, 1)
	_check(battle.get_result() == null and not main.commit_battle_result(battle.get_result()), "Running battle: no result, nothing committed")
	(main.get_node("CombatView") as CombatView).exit_requested.emit()
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and main.get_combat() == battle, "The exit is refused before a result")
	var handoff := _handoff(main)
	var pending := handoff.get_pending_encounter()
	_check(not handoff.resolve_encounter("encounter_999", true) and handoff.get_pending_encounter() == pending and main.has_node(NODES[2]) and (main.get_node(NODES[2]) as WorldMonster).is_held(), "The handoff refuses another encounter's id and changes nothing")
	_check(not session.end_resolved_encounter("encounter_999") and session.get_phase() == EncounterSession.Phase.LOCKED and _player(main).movement_locked, "The session refuses another encounter's id and stays LOCKED")
	var forged := BattleResult.create(battle.encounter_id, BattleResult.Outcome.VICTORY, battle.group_monster_ids)
	_check(not main.commit_battle_result(forged) and not forged.is_committed() and main.has_node(NODES[2]), "A result that is not the battle's own is refused")
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)
	var result := battle.get_result()
	# The encounter is cancelled (world exit) before the result is committed.
	session.cancel_for_world_exit()
	await _settle()
	_check(not main.commit_battle_result(result) and not result.is_committed() and _commits.is_empty(), "A result for an encounter that no longer exists is refused")
	_check(main.has_node(NODES[2]) and main._world_monsters.size() == 3, "…and changes no group")
	await _destroy(main)
	_sections_done.append("refusals")


# --- Helpers --------------------------------------------------------------------------------------

## Challenges passive group 3 from `spot`, waits for `groups` groups, then
## LOCKED: returns the battle, already past its 3 s preparation.
func _locked_battle(main: Node, spot: Vector2, groups: int) -> CombatBattle:
	_player(main).global_position = spot
	await _settle()
	var session := _session(main)
	session.challenge()
	var frames := 0
	while session.get_context() != null and session.get_context().get_group_count() < groups and frames < 120:
		await physics_frame
		frames += 1
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	var battle: CombatBattle = main.get_combat()
	if battle != null:
		battle.advance(CombatConfig.PREPARATION_MS)
	return battle


func _new_main(path: String) -> Node2D:
	_commits.clear()
	_removed.clear()
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	main.battle_result_committed.connect(func(result: BattleResult, saved: bool) -> void: _commits.append([result, saved]))
	_handoff(main).group_removed.connect(func(monster: WorldMonster) -> void: _removed.append([monster.monster_id, monster.global_position]))
	await _settle()
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _player(main: Node) -> Player:
	return main.get_node("Actors/Player") as Player


func _session(main: Node) -> EncounterSession:
	return main.get_node("EncounterSession") as EncounterSession


func _handoff(main: Node) -> EncounterHandoff:
	return main.get_node("EncounterHandoff") as EncounterHandoff


func _joystick(main: Node) -> Node:
	return main.get_node("TouchControls/Joystick")


func _end_button(session: EncounterSession) -> Button:
	return session.get_node("EncounterOverlay").find_children("PrototypeEndButton", "Button", true, false)[0] as Button


func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _delete(path: String) -> void:
	for p in [path, path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _settle() -> void:
	for frame in range(4):
		await physics_frame
	await process_frame


func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
