extends SceneTree

## Stage 7 S04: Stat Allocation & Character UI. Each Level gained earns 3 Stat
## Points ((level - 1) x 3); unspent = earned - allocated points, never below
## 0, and apply_level() never gives spent points back. HP / STR / AGI / INT
## are allocatable (1 HP point = +10 Max HP; MP is not). The Character UI
## previews + / - on a copy (before -> after) and 確認分配 applies the
## preview at once; - only removes current preview points; no Stat Reset.
## Allocation is runtime only: Save stays v9 and a restart gives the points
## back (persistence is S05).

const TEST_SAVE := "user://s04_stat_allocation_test_save.json"
const T0 := 1800000000000
const PASSIVE_ONLY := Vector2(950.0, 1080.0)

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_verify_accounting()
	_verify_confirm_rules()
	_verify_levels_and_resync()
	_verify_derived()
	await _verify_panel()
	_verify_save_and_scope()
	await _verify_in_game()
	_check(_sections_done.size() == 7, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("S04 stat allocation verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _at(id: String, level: int) -> CharacterStats:
	var stats := CharacterStats.for_character(id)
	stats.apply_level(level)
	return stats


# AC01, AC11, AC21: point accounting.
func _verify_accounting() -> void:
	var hero := _at("hero", 2)
	_check(hero.get_earned_points() == 3 and hero.get_unspent_points() == 3 and hero.get_spent_points() == 0, "AC01 Lv2: 3 earned, 3 unspent")
	_check(_at("hero", 1).get_unspent_points() == 0 and _at("merc_b", 10).get_unspent_points() == 27, "Lv1: 0 points; Lv10: 27")
	_check(CharacterConfig.ALLOCATABLE == ["hp", "str", "agi", "int"] and CharacterConfig.ALLOCATION_VALUE == {"hp": 10, "str": 1, "agi": 1, "int": 1}, "Allocatable HP / STR / AGI / INT; 1 HP point = +10 Max HP (config)")
	_check(not hero.confirm_allocation({"mp": 1}) and hero.get_max_mp() == _at("hero", 2).get_max_mp() and hero.get_unspent_points() == 3, "AC21 MP cannot be allocated")
	_check(not hero.confirm_allocation({"str": -1}) and not hero.confirm_allocation({"str": 1.0}) and not hero.confirm_allocation({"str": "1"}), "AC11 Negative / non-integer amounts refused")
	_check(not hero.confirm_allocation({"str": 3, "agi": -1}) and hero.get_allocated_points("agi") == 0, "AC11 A negative entry hidden in a positive total is refused")
	_check(hero.get_allocated_points("str") == 0 and hero.get_unspent_points() == 3, "AC11 Nothing changed by refused confirms")
	# The test hook can overspend; unspent still never shows negative.
	var hooked := _at("hero", 2)
	hooked.set_allocated("str", 9)
	_check(hooked.get_unspent_points() == 0, "AC11 Unspent never negative")
	_sections_done.append("accounting")


# AC09, AC10: confirm is atomic and within the budget.
func _verify_confirm_rules() -> void:
	var hero := _at("hero", 3)
	_check(not hero.confirm_allocation({"str": 4, "agi": 3}) and hero.get_spent_points() == 0, "AC10 7 points with 6 earned: refused, nothing spent")
	_check(not hero.confirm_allocation({"str": 2, "mp": 1}) and hero.get_allocated_points("str") == 0, "AC09 One bad entry refuses the whole confirm (no partial STR)")
	_check(not hero.confirm_allocation({}) and not hero.confirm_allocation({"str": 0}), "Nothing to confirm: refused")
	_check(hero.confirm_allocation({"hp": 1, "str": 3, "int": 1}) and hero.get_spent_points() == 5 and hero.get_unspent_points() == 1, "AC09 HP 1 / STR 3 / INT 1 applied together: 5 spent, 1 left")
	_check(hero.get_allocated_points("hp") == 1 and hero.get_allocated("hp") == 10 and hero.get_allocated("str") == 3 and hero.get_allocated("int") == 1, "Allocated layer: HP +10, STR +3, INT +1")
	_check(not hero.confirm_allocation({"agi": 2}) and hero.confirm_allocation({"agi": 1}) and hero.get_unspent_points() == 0, "AC10 Only the remaining point can be spent")
	_check(not hero.confirm_allocation({"str": 1}), "AC10 Nothing left: refused")
	_sections_done.append("confirm")


# AC13-AC15, AC20: Level recalculation never regenerates points.
func _verify_levels_and_resync() -> void:
	var hero := _at("hero", 3)
	hero.confirm_allocation({"hp": 1, "str": 3, "int": 1})
	for repeat in range(5):
		hero.apply_level(3)
	_check(hero.get_unspent_points() == 1 and hero.get_spent_points() == 5 and hero.get_allocated_points("str") == 3, "AC14 apply_level(3) x5: still 1 unspent (not 6), allocation kept")
	hero.apply_level(4)
	_check(hero.get_earned_points() == 9 and hero.get_unspent_points() == 4 and hero.get_allocated_points("str") == 3 and hero.get_allocated_points("hp") == 1, "AC15 Lv4: 9 earned, allocation 5 kept, 4 unspent")
	_check(hero.get_growth("str") == 3 and hero.get_effective("str") == 10 + 3 + 3 and hero.get_max_hp() == 300 + 60 + 10, "AC15 Lv4 Growth recalculated on top of the allocation (STR 16, HP 370)")
	# A battle and a settlement-style resync keep the allocation.
	var battle := CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE, {"hero": hero})
	_check(battle.get_hero().attack_damage == 20 + 6 and battle.get_hero().max_hp == 370, "AC13 A battle uses the confirmed allocation")
	hero.apply_level(4)
	_check(hero.get_unspent_points() == 4 and hero.get_allocated_points("str") == 3, "AC13 After the battle's resync the allocation stands")
	# AC20: three characters, independent.
	var merc_a := _at("merc_a", 2)
	var merc_b := _at("merc_b", 3)
	_check(merc_a.confirm_allocation({"str": 3}) and merc_b.confirm_allocation({"int": 6}), "AC20 Merc A and Merc B allocate their own points")
	_check(merc_a.get_unspent_points() == 0 and merc_b.get_unspent_points() == 0 and merc_a.get_effective("str") == 10 + 2 + 3 and merc_b.get_effective("int") == 10 + 4 + 6 and hero.get_allocated_points("int") == 1, "AC20 Each character keeps its own Level, points and allocation")
	_check(not merc_a.confirm_allocation({"agi": 1}), "AC20 Merc A Lv2 cannot spend a 4th point")
	_sections_done.append("levels")


# AC02-AC05, AC16, AC17: the S02 formulas and Capacity follow.
func _verify_derived() -> void:
	var stats := _at("hero", 2)
	var before := [stats.get_max_hp(), stats.get_physical_attack(), stats.get_physical_defense(), stats.get_max_capacity(), stats.get_attack_interval_ms(), stats.get_move_speed(), stats.get_magic_attack(), stats.get_magic_defense(), stats.get_max_mp()]
	var hp := stats.duplicate_stats()
	hp.confirm_allocation({"hp": 1})
	_check(hp.get_max_hp() == before[0] + 10, "AC02 HP +1: Max HP +10")
	var strength := stats.duplicate_stats()
	strength.confirm_allocation({"str": 1})
	_check(strength.get_physical_attack() == before[1] + 1 and strength.get_max_capacity() == before[3] + 9 and strength.get_physical_defense() == CharacterStats.defense_for(2), "AC03 STR 11 -> 12: ATK +1, DEF floor(2 x 0.5) = 1, Capacity +9")
	var agility := stats.duplicate_stats()
	agility.confirm_allocation({"agi": 1})
	_check(agility.get_attack_interval_ms() == CharacterStats.attack_interval_for(1000, 2) and agility.get_attack_interval_ms() < before[4] and agility.get_move_speed() == CharacterStats.move_speed_for(4.0, 2) and agility.get_move_speed() > before[5], "AC04 AGI 11 -> 12: shorter interval, faster")
	var intelligence := stats.duplicate_stats()
	intelligence.confirm_allocation({"int": 1})
	_check(intelligence.get_magic_attack() == before[6] + 2 and intelligence.get_max_mp() == before[8] + 5 and intelligence.get_magic_defense() == CharacterStats.defense_for(2), "AC05 INT 11 -> 12: MATK +2, Max MP +5, MDEF 1")
	_check(stats.get_max_hp() == before[0] and stats.get_physical_attack() == before[1] and stats.get_unspent_points() == 3, "Copies never touch the original")
	# AC16: the backpack follows Effective STR.
	var carrier := CharacterStats.new()
	carrier.apply_level(2)
	var inventory := CharacterInventory.new("player", carrier)
	var capacity := inventory.get_max_capacity()
	carrier.confirm_allocation({"str": 3})
	_check(inventory.get_max_capacity() == capacity + 27, "AC16 STR +3: backpack Capacity +27")
	# AC17: the battle's combat values are the S02 formulas of the new stats.
	var unit := CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE, {"hero": carrier}).get_hero()
	_check(unit.attack_damage == carrier.get_physical_attack() and unit.physical_defense == carrier.get_physical_defense() and unit.attack_interval_ms == carrier.get_attack_interval_ms() and unit.move_speed == carrier.get_move_speed() and unit.max_mp == carrier.get_max_mp(), "AC17 Battle values = CharacterStats formulas")
	_sections_done.append("derived")


# AC06-AC08, AC12, AC18, AC19, AC20, AC22: the Character UI.
func _verify_panel() -> void:
	var party := {"hero": _at("hero", 3), "merc_a": _at("merc_a", 2), "merc_b": _at("merc_b", 1)}
	var levels := {"hero": [3, 40], "merc_a": [2, 0], "merc_b": [1, 0]}
	var panel := CharacterPanel.new()
	panel.characters_provider = _entries.bind(party, levels)
	panel.can_open = func() -> bool: return true
	root.add_child(panel)
	await process_frame
	_check(panel.open() and panel.is_open() and panel.get_selected() == "hero", "Panel opens on the Hero")
	var hero: CharacterStats = party["hero"]
	var lines := panel.get_lines()
	var text := " | ".join(lines)
	for word in ["等級 3", "經驗 40 / 200", "未分配屬性點 6", "血量 340", "魔力 220", "力量 12", "敏捷 12", "智力 12", "物理攻擊 22", "魔法攻擊 4", "物理防禦 1", "魔法防禦 1", "攻擊間隔", "移動速度", "負重容量 118"]:
		_check(text.contains(word), "AC18 Shows %s (%s)" % [word, text])
	# AC06 / AC19: preview only, before -> after.
	var before_capacity := hero.get_max_capacity()
	_check(panel.press_plus("str") and panel.get_pending() == {"str": 1}, "+ STR: pending 1")
	text = " | ".join(panel.get_lines())
	_check(text.contains("力量 12 → 13") and text.contains("物理攻擊 22 → 23") and text.contains("負重容量 118 → 127") and text.contains("未分配屬性點 6 → 5"), "AC19 Preview shows STR 12 → 13, ATK 22 → 23, Capacity 118 → 127 (%s)" % text)
	_check(hero.get_allocated_points("str") == 0 and hero.get_effective("str") == 12 and hero.get_max_capacity() == before_capacity and hero.get_unspent_points() == 6, "AC06 The preview changes nothing real")
	_check(CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE, party).get_hero().attack_damage == 22, "AC06 A battle during the preview uses the confirmed stats only")
	panel.press_plus("hp")
	_check(" | ".join(panel.get_lines()).contains("血量 340 → 350"), "AC02 HP +1 previews Max HP +10")
	# AC07: - removes preview points.
	_check(panel.press_minus("hp") and panel.get_pending() == {"str": 1}, "AC07 - removes the preview HP point")
	for count in range(10):
		panel.press_plus("agi")
	_check(panel.get_pending() == {"str": 1, "agi": 5}, "AC10 + stops at the unspent points (6)")
	_check(not panel.press_plus("int"), "AC10 No 7th point")
	panel.press_minus("agi")
	panel.press_minus("agi")
	panel.press_minus("agi")
	panel.press_minus("agi")
	panel.press_minus("agi")
	_check(not panel.press_minus("agi") and panel.get_pending() == {"str": 1}, "AC07 - stops at this preview's 0")
	panel.press_plus("str")
	_check(panel.confirm() and hero.get_allocated_points("str") == 2 and hero.get_unspent_points() == 4 and panel.get_pending().is_empty(), "AC09 Confirm: STR +2 applied, preview cleared")
	_check(" | ".join(panel.get_lines()).contains("力量 14") and not " | ".join(panel.get_lines()).contains("→"), "The panel shows the confirmed values at once")
	# AC08: confirmed points cannot be taken back with -.
	_check(not panel.press_minus("str") and hero.get_allocated_points("str") == 2, "AC08 - cannot undo the confirmed STR")
	panel.press_plus("str")
	_check(panel.press_minus("str") and not panel.press_minus("str") and hero.get_allocated_points("str") == 2, "AC08 - removes only the new preview point")
	# AC12: close / reopen.
	panel.press_plus("int")
	panel.close()
	_check(not panel.is_open() and panel.get_pending().is_empty() and hero.get_allocated_points("int") == 0, "Closing discards the preview")
	panel.open()
	_check(hero.get_allocated_points("str") == 2 and " | ".join(panel.get_lines()).contains("未分配屬性點 4"), "AC12 Reopened: the confirmed allocation stands")
	# AC20: other characters.
	panel.select_character("merc_a")
	_check(" | ".join(panel.get_lines()).contains("等級 2") and " | ".join(panel.get_lines()).contains("未分配屬性點 3"), "AC20 Merc A: Lv2, 3 points")
	panel.press_plus("hp")
	panel.press_plus("hp")
	_check(panel.confirm() and (party["merc_a"] as CharacterStats).get_max_hp() == 200 + 25 + 20 and hero.get_allocated_points("hp") == 0, "AC20 Merc A HP +2 points = +20 Max HP; the Hero unchanged")
	panel.select_character("merc_b")
	_check(not panel.press_plus("str") and " | ".join(panel.get_lines()).contains("未分配屬性點 0"), "AC20 Merc B Lv1: no points to spend")
	# AC21 / AC22 in the UI.
	_check(not panel.has_node("Panel/Plus_mp") and panel.has_node("Panel/Plus_hp") and panel.has_node("Panel/Plus_int"), "AC21 No MP allocation row")
	var panel_code := _code_only("res://scripts/character_panel.gd").to_lower()
	_check(not panel_code.contains("reset") and not panel_code.contains("重置") and not panel_code.contains("洗點"), "AC22 No Stat Reset")
	panel.free()
	_sections_done.append("panel")


# AC22-AC25, AC28: Save and scope.
func _verify_save_and_scope() -> void:
	var stats := CharacterStats.new()
	stats.apply_level(3)
	stats.confirm_allocation({"str": 4, "hp": 2})
	var progression := ProgressionState.from_dict({"hero": {"level": 3, "exp": 0}})
	var data := SaveStore.serialize(Wallet.new(), CharacterInventory.new("player", stats), MarketState.create_default(), PlayerLocation.new(), null, null, null, progression)
	_check(SaveStore.VERSION == 14 and data["version"] == 14, "AC23 SaveStore.VERSION (S05: 10)")
	# S05 superseded AC24: the save now holds the allocation point counts (only).
	_check(data["character"]["stats"] == {"strength": 10} and SaveStore.STATS_KEYS == ["strength"] and data["progression"]["hero"] == {"level": 3, "exp": 0} and data["allocation"]["hero"] == {"hp": 0, "str": 0, "agi": 0, "int": 0}, "AC24 (S05) stats {strength: Base STR}, progression {level, exp}; allocation counts in their own section")
	var save_code := _code_only("res://scripts/save_store.gd").to_lower()
	_check(not save_code.contains("unspent") and not save_code.contains("get_earned_points"), "AC24 (S05) Save code stores no unspent / earned points")
	var code := ""
	for path in ["res://scripts/character_panel.gd", "res://scripts/character_stats.gd", "res://scripts/main.gd"]:
		code += _code_only(path).to_lower()
	# Stage 9 P03 (approved) brought Equip / Unequip into the Character UI:
	# "equip_slot" (no equipment in S04) is superseded by "helmet" (still no
	# slot beyond WEAPON / ARMOR).
	# Stage 10 P02 (approved) brought the Hospital into main.gd: "hospital" is
	# checked on the Character UI / stats alone.
	for word in ["mercenary_center", "helmet", "weapon", "armor", "hospital", "reset_stat", "merc_c", "crit", "dodge"]:
		var scope := (_code_only("res://scripts/character_panel.gd") + _code_only("res://scripts/character_stats.gd")).to_lower() if word == "hospital" else code
		_check(not scope.contains(word), "AC28 No %s" % word)
	# Stage 8 P02 brought recruitment into main.gd (the Mercenary Center);
	# the Character UI and the stats still know nothing about it.
	var character_code := (_code_only("res://scripts/character_panel.gd") + _code_only("res://scripts/character_stats.gd")).to_lower()
	_check(not character_code.contains("recruit"), "AC28 No recruit in the Character UI / stats")
	# Stage 8 P03 brought dismissal into main.gd as well.
	_check(not character_code.contains("dismiss"), "AC28 No dismiss in the Character UI / stats")
	_sections_done.append("save_scope")


# The game: Level Up feedback, the 角色 button, allocation, battle, settlement, restart.
func _verify_in_game() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main()
	# Stage 8 P04: the game's battle is the Hero + the deployed roster; a
	# deployed 守衛 #1 + 法師 #2 stand in for Merc A / Merc B.
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "MAGE")], ["merc_1", "merc_2"])
	var panel := main.get_node("CharacterPanel") as CharacterPanel
	var open_button := panel.get_node("OpenButton") as Button
	await process_frame
	_check(open_button.visible and open_button.text == "角色", "World: the 角色 button shows (no points yet)")
	# Level the Hero to Lv2 through a real battle.
	var battle := await _locked_battle(main)
	await process_frame
	_check(not open_button.visible and not panel.open(), "In battle: no Character UI")
	var f := battle.get_friends()
	battle.resolve_damage(battle.get_enemies()[0], f[1], 1000)
	battle.resolve_damage(battle.get_enemies()[0], f[2], 1000)
	for enemy in battle.get_enemies():
		battle.resolve_damage(f[0], enemy, 1000)
	var view := main.get_node("CombatView") as CombatView
	_check(view.get_reward_text().contains("主角 升至 2 級（屬性點 +3）"), "Level Up feedback: 升至 2 級（屬性點 +3） (%s)" % view.get_reward_text())
	(view.get_node("ExitButton") as Button).pressed.emit()
	await process_frame
	var hero: CharacterStats = main.character_stats
	_check(open_button.visible and open_button.text == "角色（屬性點 3）", "Back in the world: 角色（屬性點 3）")
	open_button.pressed.emit()
	await process_frame
	var joystick := main.get_node("TouchControls/Joystick") as Node
	_check(panel.is_open() and not joystick.is_processing_input(), "Character UI open: the joystick is paused")
	# Keyboard movement is locked too (Codex review on #109).
	var player := main.get_node("Actors/Player") as Player
	var spot := player.global_position
	Input.action_press("move_right")
	for frame in range(10):
		await physics_frame
	Input.action_release("move_right")
	_check(player.movement_locked and player.global_position == spot, "Character UI open: keyboard movement locked, the player stays put")
	var capacity: int = main.inventory.get_max_capacity()
	(panel.get_node("Panel/Plus_str") as Button).pressed.emit()
	(panel.get_node("Panel/Plus_str") as Button).pressed.emit()
	_check(main.inventory.get_max_capacity() == capacity and hero.get_unspent_points() == 3, "Preview: the backpack is unchanged")
	(panel.get_node("Panel/ConfirmButton") as Button).pressed.emit()
	_check(hero.get_allocated_points("str") == 2 and main.inventory.get_max_capacity() == capacity + 18 and hero.get_unspent_points() == 1, "Confirmed: STR +2, backpack +18, 1 point left")
	(panel.get_node("Panel/CloseButton") as Button).pressed.emit()
	await process_frame
	_check(not panel.is_open() and joystick.is_processing_input() and not player.movement_locked, "Closed: the joystick and keyboard movement work again")
	# A battle uses it; the settlement resync keeps it.
	battle = await _locked_battle_far(main)
	_check(battle != null and battle.get_hero().attack_damage == 20 + 1 + 2, "AC13 The next battle: Hero ATK 23 (base 20 + Growth 1 + 2 allocated)")
	if battle != null:
		for enemy in battle.get_enemies():
			battle.resolve_damage(battle.get_hero(), enemy, 1000)
		(view.get_node("ExitButton") as Button).pressed.emit()
		await process_frame
	_check(hero.get_allocated_points("str") == 2 and hero.get_spent_points() == 2, "AC13 After the settlement the allocation stands")
	# AC25 superseded by S05: an application restart keeps the confirmed allocation.
	var level: int = main.progression.get_level("hero")
	await _destroy(main)
	main = await _new_main()
	var reloaded: CharacterStats = main.character_stats
	_check(main.progression.get_level("hero") == level and reloaded.get_allocated_points("str") == 2 and reloaded.get_unspent_points() == reloaded.get_earned_points() - 2, "AC25 (S05) Restart: Level and the confirmed STR +2 kept; unspent derived")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("in_game")


func _locked_battle(main: Node) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	for frame in range(4):
		await physics_frame
	await process_frame
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	var battle: CombatBattle = main.get_combat()
	battle.advance(CombatConfig.PREPARATION_MS)
	return battle


## A second battle: the first group is gone, the protection must pass first.
func _locked_battle_far(main: Node) -> CombatBattle:
	main.time_source.advance_ms(60000)
	for frame in range(4):
		await physics_frame
	var monster: Node2D = null
	for child in main.get_node("Actors").get_children():
		if child is WorldMonster and child.is_inside_tree() and child.visible:
			monster = child
			break
	if monster == null:
		return null
	(main.get_node("Actors/Player") as Player).global_position = monster.global_position + Vector2(40.0, 0.0)
	for frame in range(4):
		await physics_frame
	await process_frame
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	var battle: CombatBattle = main.get_combat()
	if battle != null:
		battle.advance(CombatConfig.PREPARATION_MS)
	return battle


func _new_main() -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	for frame in range(4):
		await physics_frame
	await process_frame
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


## The script without its comment lines and trailing comments.
func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		var cut := line.find(" # ")
		lines.append(line.substr(0, cut) if cut >= 0 else line)
	return "\n".join(lines)


func _delete(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))



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
