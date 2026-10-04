extends SceneTree

## Stage 7 Gate corrective: Player Clarity + Victory UI + World Monster
## Respawn.
##   A identity  主角 / 傭兵A（守護） / 傭兵B（術法） (Prototype labels, one source)
##   B copy      血量 / 魔力 as plain values, no formula or 上限 / 不可直接分配
##               copy; the HP / MP / INT math unchanged
##   C respawn   a group removed by a committed VICTORY comes back
##               WorldLayout.GROUP_RESPAWN_MS (10 s) after the player returned
##               to the world, at its home, in its default state, once; never
##               under a battle / result screen; nothing saved (Save v10)
##   D victory   the Victory Result Modal: 勝利, enemies defeated, EXP, Level Up
##               + Stat Points, 返回世界 reachable, input behind it blocked,
##               long content scrolls, one settlement only
## Real main scene, fixed TimeSource.

const TEST_SAVE := "user://s07c_corrective_test_save.json"
const T0 := 1800000000000
const IDS := ["prototype_monster_01", "prototype_monster_02", "prototype_monster_03"]
const NODES := ["Actors/PrototypeMonster", "Actors/PrototypeMonster2", "Actors/PrototypeMonster3"]
const HOMES := [Vector2(800.0, 700.0), Vector2(1100.0, 700.0), Vector2(950.0, 930.0)]
## E03 spots: groups 3 + 1 (group 2 out of reach) / only passive group 3.
const WITH_GROUP_1 := Vector2(800.0, 900.0)
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const CANVAS := Rect2(0.0, 0.0, 720.0, 1280.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _commits := []
var _removed := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_identity()
	await _verify_panel_copy()
	_verify_combat_copy()
	_verify_schedule()
	_verify_static()
	await _verify_victory_and_respawn()
	await _verify_aggressive_respawn()
	await _verify_deferred_respawn()
	await _verify_long_result()
	await _verify_other_outcomes()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 10, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("Stage 7 gate corrective verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- A. Identity ---------------------------------------------------------------------------------

func _verify_identity() -> void:
	_check(CharacterConfig.DISPLAY_NAMES == {"hero": "主角", "merc_a": "傭兵A（守護）", "merc_b": "傭兵B（術法）"}, "Labels: 主角 / 傭兵A（守護） / 傭兵B（術法）")
	_check(CharacterConfig.DISPLAY_NAMES.keys() == CharacterConfig.PROTOTYPE_CHARACTERS and CharacterConfig.PROTOTYPE_CHARACTERS.size() == 3, "Exactly the three fixed Prototype characters (no new character)")
	# Stage 8 P05: the game's Character UI names the Hero from DISPLAY_NAMES and
	# each roster Mercenary by RecruitmentService.label (one source each).
	var main_code := _code_only("res://scripts/main.gd")
	_check(main_code.contains("\"name\": CharacterConfig.DISPLAY_NAMES[\"hero\"]") and main_code.contains("\"name\": RecruitmentService.label(mercenary)"), "The Character UI uses the one label source")
	_check(CombatView.ROLE_LABELS[CombatUnit.Role.HERO] == "主角" and CombatView.ROLE_LABELS[CombatUnit.Role.MERC_A] == "傭兵A（守護）" and CombatView.ROLE_LABELS[CombatUnit.Role.MERC_B] == "傭兵B（術法）", "Combat info / result use the same labels")
	_check(CombatView.ROLE_TAGS[CombatUnit.Role.MERC_A] == "守護" and CombatView.ROLE_TAGS[CombatUnit.Role.MERC_B] == "術法" and CombatView.ROLE_TAGS[CombatUnit.Role.HERO] == "", "Portraits carry the merc role tags")
	_check(CombatConfig.MERC_A_SKILL["kind"] == "guard" and CombatConfig.MERC_B_SKILL["kind"] == "aoe", "The labels follow the approved roles (Merc A Guard, Merc B AoE magic)")
	var latin := RegEx.new()
	latin.compile("[A-Za-z]")
	var approved := RegEx.new()
	approved.compile("(?<![A-Za-z])[ABE](?![A-Za-z])")
	for label in CharacterConfig.DISPLAY_NAMES.values():
		_check(latin.search(approved.sub(label, "", true)) == null, "Traditional Chinese label (only standalone A / B): %s" % label)
	var config := _code_only("res://scripts/character_config.gd")
	for word in ["biography", "lore", "personality", "portrait"]:
		_check(not config.to_lower().contains(word), "No %s system" % word)
	_sections_done.append("identity")


# --- B. Character UI copy ------------------------------------------------------------------------

func _verify_panel_copy() -> void:
	var party := {"hero": _at("hero", 3), "merc_a": _at("merc_a", 2), "merc_b": _at("merc_b", 1)}
	var levels := {"hero": [3, 40], "merc_a": [2, 0], "merc_b": [1, 0]}
	var panel := CharacterPanel.new()
	panel.characters_provider = _entries.bind(party, levels)
	panel.can_open = func() -> bool: return true
	root.add_child(panel)
	await process_frame
	panel.open()
	for id in party:
		panel.select_character(id)
		await process_frame
		var stats: CharacterStats = party[id]
		var lines := panel.get_lines()
		var text := " | ".join(lines)
		_check(panel.get_tab(id).text == CharacterConfig.DISPLAY_NAMES[id], "Tab %s reads %s" % [id, CharacterConfig.DISPLAY_NAMES[id]])
		_check(panel.get_tab(id).disabled and panel.get_tab(id).get_theme_color("font_disabled_color") == Color(1.0, 0.85, 0.4), "The selected tab is highlighted, not greyed")
		_check(lines[0] == CharacterConfig.DISPLAY_NAMES[id] and (panel.get_node("Panel/Info0") as Label).text == CharacterConfig.DISPLAY_NAMES[id], "The selected character is named at the top (%s)" % lines[0])
		_check(lines.has("血量 %d" % stats.get_max_hp()) and (panel.get_node("Panel/Row_hp") as Label).text == "血量 %d" % stats.get_max_hp(), "血量 %d shown plainly (%s)" % [stats.get_max_hp(), text])
		_check(lines.has("魔力 %d" % stats.get_max_mp()) and (panel.get_node("Panel/Mp") as Label).text == "魔力 %d" % stats.get_max_mp(), "魔力 %d shown plainly" % stats.get_max_mp())
		for word in ["生命", "上限", "不可直接分配", "不可分配", "每點", "+10"]:
			_check(not text.contains(word), "No %s copy for %s" % [word, id])
		var shown := []
		for node in panel.find_children("*", "Label", true, false):
			shown.append((node as Label).text)
		for node in panel.find_children("*", "Button", true, false):
			shown.append((node as Button).text)
		_check(not " ".join(shown).contains("生命") and not " ".join(shown).contains("上限") and not " ".join(shown).contains("不可直接分配"), "No on-screen 生命 / 上限 / 不可直接分配 (%s)" % id)
	# The math behind the copy is unchanged.
	panel.select_character("hero")
	var hero: CharacterStats = party["hero"]
	var hp := hero.get_max_hp()
	var mp := hero.get_max_mp()
	panel.press_plus("hp")
	_check(panel.get_lines().has("血量 %d → %d" % [hp, hp + 10]), "HP +1 point still previews +10 血量")
	panel.press_minus("hp")
	panel.press_plus("int")
	_check(panel.get_lines().has("魔力 %d → %d" % [mp, mp + CharacterConfig.MP_PER_INT]), "INT +1 still previews 魔力 +%d" % CharacterConfig.MP_PER_INT)
	_check(panel.confirm() and hero.get_max_mp() == mp + CharacterConfig.MP_PER_INT and hero.get_max_hp() == hp, "INT confirmed: MP by the existing formula, HP unchanged")
	_check(not hero.confirm_allocation({"mp": 1}) and not panel.has_node("Panel/Plus_mp"), "MP is still not allocatable")
	_check(CharacterConfig.ALLOCATION_VALUE == {"hp": 10, "str": 1, "agi": 1, "int": 1} and CharacterConfig.ALLOCATABLE == ["hp", "str", "agi", "int"], "Allocation config unchanged")
	var code := _code_only("res://scripts/character_panel.gd")
	_check(not code.contains("生命") and not code.contains("上限") and not code.contains("不可直接分配"), "character_panel.gd holds no old copy")
	panel.free()
	_sections_done.append("panel_copy")


func _verify_combat_copy() -> void:
	_check(CombatView.INFO_TEXT.contains("血量 %d / %d") and not CombatView.INFO_TEXT.contains("生命"), "Combat info reads 血量 (not 生命)")
	var battle := CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE)
	var view := CombatView.new()
	root.add_child(view)
	view.open(battle)
	var friends := battle.get_friends()
	_check(view.get_info_text(friends[1]).begins_with("傭兵A（守護）\n血量 200 / 200") and view.get_info_text(friends[2]).begins_with("傭兵B（術法）\n血量 150 / 150") and view.get_info_text(friends[0]).begins_with("主角\n血量 300 / 300"), "ⓘ names each character with its role label")
	view.close()
	view.free()
	_sections_done.append("combat_copy")


# --- C. Respawn: schedule + static -----------------------------------------------------------------

func _verify_schedule() -> void:
	_check(WorldLayout.GROUP_RESPAWN_MS == 10000, "Prototype respawn delay is 10 s (config)")
	var monster := (load("res://scenes/world_monster.tscn") as PackedScene).instantiate() as WorldMonster
	monster.group_index = 2
	var schedule := GroupRespawn.new()
	_check(schedule.schedule(monster, 1000) and schedule.is_scheduled(IDS[2]), "Scheduled")
	_check(not schedule.schedule(monster, 5000) and schedule.get_remaining_ms(IDS[2], 1000) == 10000, "A second schedule is refused (the first due time stands)")
	_check(schedule.take_due(10999).is_empty() and schedule.get_remaining_ms(IDS[2], 10999) == 1, "Not due 1 ms early")
	var due := schedule.take_due(11000)
	_check(due.size() == 1 and due[0]["monster_id"] == IDS[2] and due[0]["group_index"] == 2, "Due at exactly 10 s")
	_check(schedule.take_due(99999).is_empty() and not schedule.is_scheduled(IDS[2]) and schedule.get_remaining_ms(IDS[2], 0) == -1, "Taken once only")
	# A watched group joins under the current protection; a live duplicate id is refused.
	var handoff := EncounterHandoff.new()
	handoff.set_protected(true)
	_check(handoff.watch_monster(monster) and monster.is_aggro_suppressed(), "A respawned group takes the current protection")
	_check(not handoff.watch_monster(monster), "The same live group is never watched twice")
	handoff.free()
	monster.free()
	_sections_done.append("schedule")


func _verify_static() -> void:
	_check(SaveStore.VERSION == 12 and SaveStore.V10_KEYS == SaveStore.V9_KEYS + ["allocation"], "Save v12 (P05), sections unchanged")
	var save := _code_only("res://scripts/save_store.gd").to_lower()
	for word in ["respawn", "monster", "group", "victory"]:
		_check(not save.contains(word), "save_store.gd knows nothing about %s" % word)
	var inline := RegEx.new()
	inline.compile("(?<![0-9.])(10000|10\\.0)(?![0-9])")
	for path in ["res://scripts/main.gd", "res://scripts/group_respawn.gd", "res://scripts/encounter_handoff.gd"]:
		_check(inline.search(_code_only(path)) == null, "%s has no inline respawn delay" % path.get_file())
	var monster := _code_only("res://scripts/world_monster.gd").to_lower()
	_check(not monster.contains("respawn") and not monster.contains("spawn"), "WorldMonster itself is unchanged (no spawn logic)")
	_check(EncounterSession.PROTECTION_MS == 5000 and WorldMonster.AGGRO_RADIUS == 240.0 and EncounterHandoff.CHALLENGE_RANGE == 200.0 and EncounterHandoff.MAX_GROUPS == 3, "Protection, aggro radius, challenge range, group cap unchanged")
	var respawn := _code_only("res://scripts/group_respawn.gd")
	for word in ["randi", "randf", "RandomNumberGenerator", "Time.", "OS.", "SaveStore", "save"]:
		_check(not respawn.contains(word), "GroupRespawn is deterministic and unsaved (%s)" % word)
	_sections_done.append("static")


# --- C + D. Victory modal, settlement, respawn (passive group 3) --------------------------------

func _verify_victory_and_respawn() -> void:
	var main := await _new_main()
	# Stage 8 P04: the game's battle is the Hero + the deployed roster; a
	# deployed 守衛 #1 + 法師 #2 stand in for Merc A / Merc B.
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "MAGE")], ["merc_1", "merc_2"])
	var view := main.get_node("CombatView") as CombatView
	var session := _session(main)
	var handoff := _handoff(main)
	var battle := await _locked_battle(main, PASSIVE_ONLY, 1)
	_check(battle != null and battle.group_monster_ids == [IDS[2]], "Battle for passive group 3")
	_check(not view.is_result_modal_open() and not (view.get_node("ResultModal") as Control).visible, "No result modal while fighting")
	var friends := battle.get_friends()
	_check(view.open_info(friends[0]), "ⓘ open when the battle ends")
	battle.resolve_damage(battle.get_enemies()[0], friends[1], 1000)
	for enemy in battle.get_enemies():
		battle.resolve_damage(friends[0], enemy, 1000)
	await process_frame
	var defeated := battle.get_enemies().size()
	var modal := view.get_node("ResultModal") as Control
	var exit := view.get_node("ExitButton") as Button
	var panel := modal.get_node("ResultPanel") as Control
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY and view.is_result_modal_open() and modal.visible, "VICTORY opens the Victory Result Modal")
	_check((panel.get_node("ResultTitle") as Label).text == "勝利", "Title 勝利")
	var lines := view.get_victory_lines()
	var share: int = defeated * CombatConfig.EXP_PER_KILL / 2
	# Stage 8 P04 (approved D5): a roster Mercenary is named by its own label.
	_check(lines == ["擊敗敵人 %d 名" % defeated, "主角　經驗 +%d" % share, "法師 #2　經驗 +%d" % share], "Defeated count and each survivor's EXP (%s)" % str(lines))
	var shown := []
	for label in panel.find_children("ResultLine*", "Label", true, false):
		shown.append((label as Label).text)
	_check(shown == lines, "The modal shows those lines (%s)" % str(shown))
	_check(not (view.get_node("RewardLabel") as Label).visible, "The old one-line reward is not shown on VICTORY")
	_check(exit.visible and exit.text == "返回世界", "返回世界 shown")
	# Layout: inside the canvas (iPhone safe area under the 720 x 1280 letterbox).
	var panel_rect := panel.get_global_rect()
	_check(CANVAS.encloses(panel_rect) and panel_rect.position.y >= 120.0 and panel_rect.end.y <= 1280.0 - 120.0, "The panel fits the canvas with room for the safe area (%s)" % str(panel_rect))
	_check(panel_rect.encloses(exit.get_global_rect()), "返回世界 sits on the panel (%s)" % str(exit.get_global_rect()))
	var scroll := panel.get_node("ResultScroll") as ScrollContainer
	_check(scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED and panel_rect.encloses(scroll.get_global_rect()) and not scroll.get_global_rect().intersects(exit.get_global_rect()), "Content scrolls vertically only, inside the panel, clear of 返回世界")
	for label in panel.find_children("ResultLine*", "Label", true, false):
		_check(scroll.get_global_rect().encloses((label as Label).get_global_rect()), "Line fits the width: %s" % (label as Label).text)
	_check(exit.get_index() > modal.get_index() and modal.mouse_filter == Control.MOUSE_FILTER_STOP and modal.get_global_rect().encloses(CANVAS), "The modal covers the screen; 返回世界 is above it")
	_check(not (view.get_node("InfoPanel") as Control).visible, "The info panel is not drawn over the modal")
	# Input behind the modal is blocked (real touches through the viewport).
	var hits := {}
	for node_name in ["Field", "Portrait0", "CameraNavigator", "AttackAllButton"]:
		hits[node_name] = 0
		var target := view.get_node(node_name) as Control
		target.gui_input.connect(func(_event: InputEvent) -> void: hits[node_name] += 1)
	var selected_before := battle.get_selection().duplicate()
	for at in [Vector2(360.0, 600.0), Vector2(60.0, 330.0), Vector2(360.0, 1148.0), Vector2(600.0, 50.0)]:
		await _click(at)
	_check(hits.values().all(func(count: int) -> bool: return count == 0), "No touch reaches the battlefield, portraits, navigator or buttons behind (%s)" % str(hits))
	_check(battle.get_selection() == selected_before and _commits.is_empty() and view.is_open(), "Nothing behind changed; no commit")
	# The modal holds: time passes, nothing comes back, no new battle.
	main.time_source.advance_ms(30000)
	await _settle()
	_check(view.is_result_modal_open() and main.get_combat() == battle and session.get_phase() == EncounterSession.Phase.LOCKED, "The modal waits for the player")
	_check(main.has_node(NODES[2]) and not main.get_group_respawn().is_scheduled(IDS[2]) and _removed.is_empty(), "No respawn timer while the result is up (the group leaves only on 返回世界)")
	# 返回世界 by a real touch: one commit, the group leaves, the timer starts.
	var hero_exp: int = main.progression.get_exp("hero")
	await _click(exit.get_global_rect().get_center())
	_check(_commits.size() == 1 and battle.get_result().is_committed() and main.get_combat() == null and not view.visible, "返回世界 commits once and closes the battle")
	_check(main.progression.get_exp("hero") == hero_exp + share and main.progression.get_exp("merc_a") == 0 and main.mercenary_roster.get_mercenary("merc_1").get_exp() == 0 and main.mercenary_roster.get_mercenary("merc_2").get_exp() == share, "Settlement as C05 (no new reward; P04: 法師 #2 its share, dead 守衛 #1 none)")
	_check(_removed.size() == 1 and _removed[0] == IDS[2] and not main.has_node(NODES[2]), "Group 3 removed")
	_check(main.get_group_respawn().get_remaining_ms(IDS[2], main.time_source.now_ms()) == WorldLayout.GROUP_RESPAWN_MS, "Its 10 s start when the player returns to the world")
	_check(session.is_protection_active() and session.get_protection_remaining_ms() == 5000, "The 5 s protection unchanged")
	exit.pressed.emit()
	view.exit_requested.emit()
	_check(not main.commit_battle_result(battle.get_result()) and _commits.size() == 1 and main.progression.get_exp("hero") == hero_exp + share, "No second settlement")
	var saved_text := FileAccess.get_file_as_string(TEST_SAVE)
	var saved: Variant = JSON.parse_string(saved_text)
	_check(int(saved["version"]) == 12 and (saved as Dictionary).keys().size() == SaveStore.V12_KEYS.size() and not saved_text.to_lower().contains("monster") and not saved_text.to_lower().contains("respawn"), "Saved as v12 (P05) with no group / respawn data")
	# No immediate respawn; still gone just before 10 s.
	await _settle()
	_check(not main.has_node(NODES[2]) and main._world_monsters.size() == 2, "No immediate respawn")
	main.time_source.advance_ms(WorldLayout.GROUP_RESPAWN_MS - 1)
	await _settle()
	_check(not main.has_node(NODES[2]) and main.get_group_respawn().get_remaining_ms(IDS[2], main.time_source.now_ms()) == 1, "Still absent 1 ms before 10 s")
	main.time_source.advance_ms(1)
	await _settle()
	_check(main.has_node(NODES[2]), "Back at 10 s")
	var back := main.get_node(NODES[2]) as WorldMonster
	_check(back.monster_id == IDS[2] and back.group_index == 2 and back.is_passive(), "The same group, still PASSIVE")
	_check(back.get_state() == WorldMonster.State.IDLE and back.is_threat_active() and not back.is_held() and back.home_position == HOMES[2], "Default state: IDLE, active, not held, same home")
	_check(back.patrol_points == WorldLayout.PROTOTYPE_GROUPS[2]["patrol"] and back.get_patrol_index() == 0, "Its own patrol loop, from its start")
	_check(back.global_position.distance_to(HOMES[2]) <= WorldMonster.PATROL_SPEED * 0.2, "At its original spawn position (%s)" % str(back.global_position))
	_check(handoff._monsters.has(IDS[2]) and handoff._monsters[IDS[2]] == back and main._world_monsters.has(back) and main._world_monsters.size() == 3, "Watched again and in the world list")
	_check(not main.get_group_respawn().is_scheduled(IDS[2]), "Its timer is gone")
	main.time_source.advance_ms(60000)
	await _settle()
	_check(_count(main, IDS[2]) == 1 and main._world_monsters.size() == 3, "No duplicate group later")
	_check(_player(main).get_index() > back.get_index(), "Drawn under the player like the scene's groups")
	# Encounter it again without a relaunch (normal E03 challenge rules).
	_player(main).global_position = PASSIVE_ONLY
	back.reset_to_home()
	await _settle()
	_check(handoff.get_challengeable_group() == back and session.challenge() and session.get_phase() == EncounterSession.Phase.JOINING and session.get_context().monster_id == IDS[2] and session.get_context().encounter_id == "encounter_2", "The player can fight it again in the same session")
	main.time_source.advance_ms(5000)
	await _settle()
	var again: CombatBattle = main.get_combat()
	_check(again != null and again.group_monster_ids == [IDS[2]] and again.get_enemies().size() == battle.get_enemies().size(), "A normal battle with the same group composition")
	await _destroy(main)
	# Relaunch: the scene's three groups, no carried-over timer.
	main = await _new_main()
	_check(_count(main, IDS[0]) == 1 and _count(main, IDS[1]) == 1 and _count(main, IDS[2]) == 1 and main._world_monsters.size() == 3 and main.get_group_respawn().take_due(T0 + 999999999).is_empty(), "Relaunch: three groups, no respawn state")
	await _destroy(main)
	_sections_done.append("victory_respawn")


# --- C. Aggressive group: behaviour after its respawn ---------------------------------------------

func _verify_aggressive_respawn() -> void:
	var main := await _new_main()
	var view := main.get_node("CombatView") as CombatView
	var session := _session(main)
	var battle := await _locked_battle(main, WITH_GROUP_1, 2)
	_check(battle != null and battle.group_monster_ids == [IDS[2], IDS[0]], "Battle for groups 3 + 1")
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)
	await process_frame
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(_removed.size() == 2 and not main.has_node(NODES[0]) and not main.has_node(NODES[2]), "Both participants removed")
	main.time_source.advance_ms(WorldLayout.GROUP_RESPAWN_MS)
	await _settle()
	_check(_count(main, IDS[0]) == 1 and _count(main, IDS[2]) == 1 and main._world_monsters.size() == 3, "Both come back once")
	var group_1 := main.get_node(NODES[0]) as WorldMonster
	_check(not group_1.is_passive() and group_1.disposition == WorldLayout.Disposition.AGGRESSIVE and not group_1.is_aggro_suppressed(), "Group 1 is still AGGRESSIVE (protection already over)")
	# Aggressive: it chases a player inside its aggro radius, and its catch starts an encounter.
	group_1.reset_to_home()
	_player(main).global_position = HOMES[0] + Vector2(0.0, 150.0)
	var frames := 0
	while group_1.get_state() != WorldMonster.State.CHASE and frames < 30:
		await physics_frame
		frames += 1
	_check(group_1.get_state() == WorldMonster.State.CHASE, "It aggroes the player normally")
	frames = 0
	while session.get_phase() == EncounterSession.Phase.NONE and frames < 240:
		await physics_frame
		frames += 1
	_check(session.get_phase() == EncounterSession.Phase.JOINING and session.get_context().monster_id == IDS[0], "Its catch starts a normal encounter")
	await _destroy(main)
	_sections_done.append("aggressive_respawn")


# --- C. Respawn waits outside the world / during an encounter -------------------------------------

func _verify_deferred_respawn() -> void:
	var main := await _new_main()
	var view := main.get_node("CombatView") as CombatView
	var session := _session(main)
	var battle := await _locked_battle(main, PASSIVE_ONLY, 1)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)
	await process_frame
	(view.get_node("ExitButton") as Button).pressed.emit()
	# Due while in a city: it waits for the world.
	_player(main).global_position = WorldLayout.CITY_A
	await _settle()
	_check(main.try_enter_city() and main.is_in_city(), "In City A")
	main.time_source.advance_ms(WorldLayout.GROUP_RESPAWN_MS + 5000)
	await _settle()
	_check(not main.has_node(NODES[2]) and main.get_group_respawn().is_scheduled(IDS[2]), "Not spawned while the player is in a city")
	_check(main.leave_city(), "Leave the city")
	await _settle()
	_check(_count(main, IDS[2]) == 1 and (main.get_node(NODES[2]) as WorldMonster).is_threat_active(), "Spawned back in the world, active")
	await _destroy(main)
	# Due during another encounter: it waits until the encounter is over.
	main = await _new_main()
	view = main.get_node("CombatView") as CombatView
	session = _session(main)
	battle = await _locked_battle(main, PASSIVE_ONLY, 1)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)
	await process_frame
	(view.get_node("ExitButton") as Button).pressed.emit()
	main.time_source.advance_ms(6000)
	_player(main).global_position = HOMES[1] + Vector2(0.0, 40.0)
	var frames := 0
	while session.get_phase() == EncounterSession.Phase.NONE and frames < 240:
		await physics_frame
		frames += 1
	_check(session.get_phase() == EncounterSession.Phase.JOINING and session.get_context().monster_id == IDS[1], "Group 2 catches the player")
	main.time_source.advance_ms(WorldLayout.GROUP_RESPAWN_MS)
	await _settle()
	_check(not main.has_node(NODES[2]) and main.get_group_respawn().is_scheduled(IDS[2]) and session.get_context().group_monster_ids == [IDS[1]], "Not spawned (nor joined) during the encounter")
	await _settle()
	var second: CombatBattle = main.get_combat()
	_check(second != null and not main.has_node(NODES[2]), "Not spawned under the battle")
	second.advance(CombatConfig.PREPARATION_MS)
	_check(second.start_retreat(), "Retreat")
	for step in range(40):
		second.advance(500)
		if second.is_over():
			break
	await process_frame
	_check(second.get_phase() == CombatBattle.Phase.RETREAT and not main.has_node(NODES[2]), "Not spawned under the result screen")
	(view.get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(_count(main, IDS[2]) == 1 and session.get_phase() == EncounterSession.Phase.NONE, "Spawned once the encounter is over")
	await _destroy(main)
	_sections_done.append("deferred_respawn")


# --- D. Long result content scrolls, 返回世界 stays reachable ---------------------------------------

func _verify_long_result() -> void:
	var main := await _new_main()
	var view := main.get_node("CombatView") as CombatView
	var battle := await _locked_battle(main, PASSIVE_ONLY, 1)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)
	await process_frame
	var long_lines: Array[String] = []
	for index in range(24):
		long_lines.append("傭兵B（術法） 升至 %d 級（屬性點 +3）　這是一段刻意加長的測試結果文字，確認會自動換行而不會超出畫面" % (index + 2))
	view._show_result_lines(long_lines)
	view.set_process(false)
	await process_frame
	await process_frame
	var panel := view.get_node("ResultModal/ResultPanel") as Control
	var scroll := panel.get_node("ResultScroll") as ScrollContainer
	var content := scroll.get_node("ResultLines") as Control
	var exit := view.get_node("ExitButton") as Button
	_check(content.size.y > scroll.size.y, "Long content is taller than the view: it scrolls (%d > %d)" % [content.size.y, scroll.size.y])
	_check(content.size.x <= scroll.size.x and scroll.get_h_scroll_bar().visible == false, "No horizontal overflow (%d <= %d)" % [content.size.x, scroll.size.x])
	for label in content.get_children():
		_check((label as Label).size.x <= scroll.size.x and (label as Label).get_line_count() > 1, "A long line wraps inside the width")
	_check(CANVAS.encloses(panel.get_global_rect()) and panel.get_global_rect().encloses(exit.get_global_rect()) and exit.visible, "返回世界 still on screen")
	scroll.scroll_vertical = 100000
	await process_frame
	_check(scroll.scroll_vertical > 0 and panel.get_global_rect().encloses(exit.get_global_rect()), "Scrolling moves the content, not 返回世界")
	view.set_process(true)
	await _click(exit.get_global_rect().get_center())
	_check(_commits.size() == 1 and main.get_combat() == null, "返回世界 reached and committed")
	await _destroy(main)
	_sections_done.append("long_result")


# --- DEFEAT / RETREAT keep the C05 result --------------------------------------------------------

func _verify_other_outcomes() -> void:
	var main := await _new_main()
	var view := main.get_node("CombatView") as CombatView
	var battle := await _locked_battle(main, PASSIVE_ONLY, 1)
	for friend in battle.get_friends():
		battle.resolve_damage(battle.get_enemies()[0], friend, 1000)
	await process_frame
	_check(battle.get_phase() == CombatBattle.Phase.DEFEAT and not view.is_result_modal_open() and view.get_victory_lines().is_empty() and (view.get_node("RewardLabel") as Label).visible and (view.get_node("ExitButton") as Button).get_global_rect() == CombatView.EXIT_RECT, "DEFEAT: no Victory modal, the C05 result")
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(_removed.is_empty() and main.get_group_respawn().take_due(T0 + 999999999).is_empty() and main.has_node(NODES[2]), "DEFEAT removes nothing, schedules nothing")
	await _destroy(main)
	_sections_done.append("other_outcomes")


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
	await _settle()
	var battle: CombatBattle = main.get_combat()
	if battle != null:
		battle.advance(CombatConfig.PREPARATION_MS)
	return battle


## A real tap (press + release) at a 720 x 1280 canvas point, through the
## root viewport as a device sends it (the emulated mouse of finger 0).
func _click(at: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.device = InputEvent.DEVICE_ID_EMULATION
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = root.get_final_transform() * at
		event.global_position = event.position
		root.push_input(event)
		await process_frame


func _count(main: Node, monster_id: String) -> int:
	var count := 0
	for child in main.get_node("Actors").get_children():
		if child is WorldMonster and (child as WorldMonster).monster_id == monster_id and not child.is_queued_for_deletion():
			count += 1
	return count


func _at(id: String, level: int) -> CharacterStats:
	var stats := CharacterStats.for_character(id)
	stats.apply_level(level)
	return stats


func _new_main() -> Node2D:
	_delete(TEST_SAVE)
	_commits.clear()
	_removed.clear()
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	main.battle_result_committed.connect(func(result: BattleResult, saved: bool) -> void: _commits.append([result, saved]))
	_handoff(main).group_removed.connect(func(monster: WorldMonster) -> void: _removed.append(monster.monster_id))
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



## Stage 8 P05: the Character UI takes its characters from a provider (the
## game: the Hero + the roster). This fixture lists the Stage 7 three
## CharacterStats with their labels and Level / EXP.
func _entries(party: Dictionary, levels: Dictionary) -> Array:
	var entries := []
	for id in party:
		entries.append({"id": id, "name": CharacterConfig.DISPLAY_NAMES[id], "stats": party[id], "level": levels[id][0], "exp": levels[id][1]})
	return entries

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
