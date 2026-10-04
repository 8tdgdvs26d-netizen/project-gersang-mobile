extends SceneTree

## Stage 8 P04: Dynamic Combat + Strategist (戰鬥改為主角＋出戰傭兵).
##   config       type -> existing profile (守衛 = merc_a, 法師 = merc_b, 軍師 =
##                merc_b PROTOTYPE), skills (軍師 冰場 PROTOTYPE from C06 values),
##                the 4 start cells; no new number
##   stats        each instance's own stats (Base + Growth + Allocated) with
##                the Stage 7 formulas; same type, different instances
##   party        Hero + 0 / 1 / 2 / 3 deployed -> 1 / 2 / 3 / 4 units (ids,
##                roles, labels, cells, skills, HP / MP); invalid lists refused
##   independence two 守衛: own selection, Skill, HP / MP, orders
##   ice field    冰場 slows every alive enemy on the 5 cells, no damage, MP /
##                cooldown as C06, refresh not stack
##   settlement   PartyProgression: all survivors divide, the Hero's share to
##                its slot, each Mercenary's to its own Level / EXP; DEFEAT /
##                RETREAT / dead; roster before legacy slots; never twice
##   game         real main: Hero alone, Hero + 3 (portraits, names, skill
##                bar, result), commit once, save, restart, save failure (C02),
##                legacy Merc A / B untouched, Character UI Hero only, AC03 rows
##   layout       4 portraits / skill bar / names fit 720 x 1280
##   + scope      Save v11; seeded stress
## Real main scene, fixed TimeSource.

const TEST_SAVE := "user://p04_dynamic_combat_test_save.json"
const BAD_SAVE := "user://p04_missing_dir/save.json"
const T0 := 1800000000000
const PASSIVE_ONLY := Vector2(950.0, 1080.0)

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_config()
	_verify_stats()
	_verify_party()
	_verify_independence()
	_verify_ice_field()
	_verify_settlement()
	await _verify_game_hero_alone()
	await _verify_game_party()
	await _verify_game_save_failure()
	await _verify_character_panel()
	await _verify_mercenary_rows()
	_verify_scope()
	_verify_stress()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 13, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("P04 dynamic combat verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Config ---------------------------------------------------------------------------------------------

func _verify_config() -> void:
	_check(CharacterConfig.MERCENARY_PROFILE == {"GUARDIAN": "merc_a", "MAGE": "merc_b", "STRATEGIST": "merc_b"}, "AC01 守衛 uses merc_a, 法師 merc_b, 軍師 merc_b (Prototype)")
	_check(CombatConfig.MERCENARY_SKILLS["GUARDIAN"] == CombatConfig.MERC_A_SKILL and CombatConfig.MERCENARY_SKILLS["MAGE"] == CombatConfig.MERC_B_SKILL, "AC01 守衛 Guard, 法師 AoE (the existing Skills)")
	_check(CombatConfig.STRATEGIST_SKILL == {"kind": "ice_field", "range": CombatConfig.MERC_B_SKILL["range"]} and CombatConfig.MERCENARY_SKILLS["STRATEGIST"] == CombatConfig.STRATEGIST_SKILL, "AC02 軍師 冰場, range = the AoE range 5")
	# Approved numbers unchanged (no new value hidden in the existing ones).
	_check(CharacterConfig.BASE.keys() == ["hero", "merc_a", "merc_b"] and CharacterConfig.COMBAT_COMPAT.keys() == ["hero", "merc_a", "merc_b"] and CharacterConfig.GROWTH_PER_LEVEL.keys() == ["hero", "merc_a", "merc_b"], "No new stat profile was added")
	_check(CharacterConfig.BASE["merc_a"] == {"hp": 200, "mp": 100, "str": 10, "agi": 10, "int": 10} and CharacterConfig.BASE["merc_b"] == {"hp": 150, "mp": 100, "str": 10, "agi": 10, "int": 10}, "Base values unchanged")
	_check(CharacterConfig.GROWTH_PER_LEVEL["merc_a"] == {"hp": 25, "mp": 0, "str": 2, "agi": 1, "int": 0} and CharacterConfig.GROWTH_PER_LEVEL["merc_b"] == {"hp": 15, "mp": 10, "str": 0, "agi": 1, "int": 2}, "Growth unchanged")
	_check(CombatConfig.SKILL_MP_COST == 25 and CombatConfig.SKILL_CAST_MS == 1000 and CombatConfig.SKILL_COOLDOWN_MS == 8000 and CombatConfig.SKILL_EFFECT_MS == 5000 and CombatConfig.SLOW_FACTOR == 2 and CombatConfig.AOE_DAMAGE == 40, "C06 Skill values unchanged")
	var cells := CombatConfig.PARTY_START_CELLS
	_check(cells.size() == 3 and cells[0] == CombatConfig.MERC_A_START_CELL and cells[1] == CombatConfig.MERC_B_START_CELL and cells[2] == Vector2i(2, 2), "Start cells: (1,1), (1,3), (2,2)")
	var all_cells := cells.duplicate()
	all_cells.append(CombatConfig.HERO_START_CELL)
	var distinct := {}
	for cell: Vector2i in all_cells:
		distinct[cell] = true
		_check(cell.x >= CombatConfig.PREPARATION_FIRST_COLUMN and cell.x < CombatConfig.PREPARATION_FIRST_COLUMN + CombatConfig.PREPARATION_COLUMNS and cell.y >= 0 and cell.y < CombatConfig.ROWS, "%s is in the preparation area" % str(cell))
	_check(distinct.size() == 4, "4 distinct start cells")
	# The Strategist settings are marked Prototype where they live.
	for path in ["res://scripts/character_config.gd", "res://scripts/combat_config.gd"]:
		var text := FileAccess.get_file_as_string(path)
		var at := text.find("STRATEGIST")
		var before := text.substr(maxi(at - 700, 0), 700)
		_check(at >= 0 and before.contains("PROTOTYPE"), "AC02 %s marks the Strategist settings PROTOTYPE" % path.get_file())
	_check(CombatView.SKILL_NAMES["ice_field"] == "冰場" and CombatView.SKILL_MARKS["ice_field"] == "冰", "冰場 / 冰 names")
	_sections_done.append("config")


# --- Stats -----------------------------------------------------------------------------------------------

func _verify_stats() -> void:
	for type in Mercenary.TYPES:
		var stats := CharacterStats.for_mercenary(Mercenary.create("merc_1", type))
		var profile := CharacterStats.for_character(CharacterConfig.MERCENARY_PROFILE[type])
		_check(stats != null and stats.get_combat_profile() == profile.get_combat_profile() and stats.get_max_mp() == profile.get_max_mp(), "AC03 Lv1 %s = its profile's stats" % type)
	var guardian := CharacterStats.for_mercenary(Mercenary.create("merc_1", "GUARDIAN"))
	_check(guardian.get_max_hp() == 200 and guardian.get_max_mp() == 100 and guardian.get_physical_attack() == 15 and guardian.get_attack_range() == 1 and guardian.get_attack_interval_ms() == 1000 and is_equal_approx(guardian.get_move_speed(), 4.0), "AC03 守衛 Lv1: HP 200, MP 100, attack 15, range 1, 1.0 s, 4.0")
	# 法師 Lv3, HP 1 + INT 2 points: HP 150 + 2 x 15 + 10 = 190; INT 10 + 4 + 2 = 16
	# (Magic Attack 12, Magic Defense 3); MP 100 + 20 + 6 x 5 = 150; AGI 12.
	var mage := CharacterStats.for_mercenary(Mercenary.create("merc_2", "MAGE", 3, 10, {"hp": 1, "str": 0, "agi": 0, "int": 2}))
	_check(mage.get_max_hp() == 190 and mage.get_max_mp() == 150 and mage.get_effective("int") == 16 and mage.get_effective("agi") == 12 and mage.get_magic_attack() == 12 and mage.get_magic_defense() == 3, "AC03 法師 Lv3 + points: HP 190, MP 150, INT 16, AGI 12, Magic Attack 12, Magic Defense 3")
	_check(mage.get_attack_interval_ms() == CharacterStats.attack_interval_for(1200, 2) and mage.get_attack_interval_ms() == 1138 and is_equal_approx(mage.get_move_speed(), 4.2) and mage.get_attack_range() == 3, "AC03 法師 Lv3 AGI 12: 1138 ms, 4.2, range 3 (S02 formulas)")
	var low := CharacterStats.for_mercenary(Mercenary.create("merc_3", "MAGE"))
	_check(low.get_max_hp() == 150 and mage.get_max_hp() == 190, "AC04 Two 法師 instances keep their own stats")
	var strategist := CharacterStats.for_mercenary(Mercenary.create("merc_4", "STRATEGIST", 3, 10, {"hp": 1, "str": 0, "agi": 0, "int": 2}))
	_check(strategist.get_combat_profile() == mage.get_combat_profile(), "AC02 軍師 at the same Level / points = 法師 (Prototype)")
	_check(CharacterStats.for_mercenary(null) == null, "null -> null")
	# Nothing derived is stored on the instance.
	_check(Mercenary.create("merc_9", "MAGE", 3, 10, {"hp": 1, "str": 0, "agi": 0, "int": 2}).to_dict().keys() == Mercenary.KEYS, "The instance still holds only id / type / Level / EXP / allocation")
	_sections_done.append("stats")


# --- Party ------------------------------------------------------------------------------------------------

func _verify_party() -> void:
	var team := [Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "MAGE", 2, 0, {"hp": 0, "str": 0, "agi": 0, "int": 3}), Mercenary.create("merc_3", "STRATEGIST")]
	for count in range(4):
		var battle := CombatBattle.create_party(10, null, team.slice(0, count))
		var friends := battle.get_friends()
		_check(friends.size() == count + 1 and friends[0].id == "hero" and friends[0].is_hero and friends[0].cell == CombatConfig.HERO_START_CELL and battle.get_selected() == friends[0], "AC05 %d deployed -> %d friendly units, the Hero first and selected" % [count, count + 1])
		for index in range(count):
			var unit := friends[index + 1]
			var mercenary: Mercenary = team[index]
			var stats := CharacterStats.for_mercenary(mercenary)
			_check(unit.id == mercenary.get_id() and unit.team == CombatUnit.Team.FRIEND and unit.role == CombatUnit.ROLE_BY_TYPE[mercenary.get_type()] and unit.label == RecruitmentService.label(mercenary), "%s: id, role, label 「%s」" % [mercenary.get_id(), unit.label])
			_check(unit.cell == CombatConfig.PARTY_START_CELLS[index] and unit.max_hp == stats.get_max_hp() and unit.hp == unit.max_hp and unit.max_mp == stats.get_max_mp() and unit.mp == unit.max_mp and unit.skill == CombatConfig.MERCENARY_SKILLS[mercenary.get_type()], "%s: cell, full HP / MP from its own stats, its type's Skill" % mercenary.get_id())
			_check(unit.attack_damage == stats.get_physical_attack() and unit.attack_range == stats.get_attack_range() and unit.attack_interval_ms == stats.get_attack_interval_ms() and unit.magic_attack == stats.get_magic_attack(), "%s: Basic Attack profile and Magic Attack" % mercenary.get_id())
		_check(battle.get_enemies().size() == 10 and battle.get_friend_hp_ratio() == 1.0, "10 enemies, full HP")
	var labels := []
	for unit in CombatBattle.create_party(10, null, team).get_friends():
		labels.append(CombatView.unit_name(unit))
	_check(labels == ["主角", "守衛 #1", "法師 #2", "軍師 #3"], "AC06 Names 主角 / 守衛 #1 / 法師 #2 / 軍師 #3 (%s)" % str(labels))
	var hero_stats := CharacterStats.for_character("hero")
	hero_stats.apply_level(4)
	_check(CombatBattle.create_party(10, hero_stats, []).get_hero().max_hp == hero_stats.get_max_hp(), "The Hero uses the given stats")
	var dup := [Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_1", "MAGE")]
	_check(CombatBattle.create_party(10, null, dup) == null, "Duplicate instance ids refused")
	_check(CombatBattle.create_party(10, null, team + [Mercenary.create("merc_4", "MAGE")]) == null, "4 Mercenaries refused (Hero + 3 at most)")
	_check(CombatBattle.create_party(10, null, [null]) == null and CombatBattle.create_party(10, null, ["merc_1"]) == null, "A non-instance refused")
	_check(CombatBattle.from_party(null, null, []) == null, "No context -> null")
	_sections_done.append("party")


# --- Independence ----------------------------------------------------------------------------------------

func _verify_independence() -> void:
	var battle := CombatBattle.create_party(10, null, [Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "GUARDIAN", 3, 0, {"hp": 6, "str": 0, "agi": 0, "int": 0})])
	var a := battle.get_friends()[1]
	var b := battle.get_friends()[2]
	_check(a.role == b.role and a.max_hp == 200 and b.max_hp == 200 + 2 * 25 + 60 and a.label == "守衛 #1" and b.label == "守衛 #2", "AC07 Two 守衛: one role, own HP (200 / 310), own labels")
	battle.advance(CombatConfig.PREPARATION_MS)
	_check(battle.select_unit(a) and battle.get_selected() == a and battle.command_skill(), "Select 守衛 #1 alone, Guard")
	battle.advance(CombatConfig.SKILL_CAST_MS)
	_check(a.mp == a.max_mp - CombatConfig.SKILL_MP_COST and b.mp == b.max_mp and battle.get_guard_remaining(a) > 0 and battle.get_guard_remaining(b) == 0, "AC07 Only 守衛 #1 paid MP and is guarded")
	_check(battle.get_skill_readiness(a) == CombatBattle.SkillReadiness.COOLDOWN and battle.get_skill_readiness(b) == CombatBattle.SkillReadiness.READY, "AC07 Own cooldowns")
	var enemy := battle.get_enemies()[0]
	battle.resolve_damage(enemy, b, 50)
	_check(b.hp == b.max_hp - CharacterStats.mitigate(50, b.physical_defense) and b.hp < b.max_hp and a.hp == a.max_hp, "AC07 Damage to #2 leaves #1 untouched")
	_check(battle.select_unit(b) and battle.command_move(Vector2i(3, 4)) and b.has_goal and not a.has_goal, "AC07 #2's move order is its own")
	battle.resolve_damage(enemy, a, 10000)
	_check(not a.alive and b.alive and battle.get_phase() == CombatBattle.Phase.FIGHTING, "#1 dead, #2 fights on")
	_sections_done.append("independence")


# --- 冰場 ----------------------------------------------------------------------------------------------------

func _verify_ice_field() -> void:
	var battle := CombatBattle.create_party(10, null, [Mercenary.create("merc_1", "STRATEGIST")])
	var strategist := battle.get_friends()[1]
	var enemies := battle.get_enemies()
	# Fixture: enemies frozen in place (no step finishes) so the cells are exact.
	var spots := [Vector2i(5, 1), Vector2i(5, 0), Vector2i(5, 2), Vector2i(4, 1), Vector2i(6, 1), Vector2i(6, 2), Vector2i(5, 3)]
	for index in range(enemies.size()):
		var enemy := enemies[index]
		enemy.move_speed = 0.001
		if index < spots.size():
			_place(enemy, spots[index])
	battle.advance(CombatConfig.PREPARATION_MS)
	var hp_before := enemies.map(func(e: CombatUnit) -> int: return e.hp)
	_check(battle.select_unit(strategist) and battle.command_skill(enemies[0]), "AC08 軍師 orders 冰場 on the enemy at (5,1)")
	var resolved := []
	battle.skill_resolved.connect(func(unit: CombatUnit) -> void: resolved.append(battle.get_elapsed_ms()))
	battle.advance(50)
	_check(strategist.skill_state == CombatUnit.SkillState.CASTING and strategist.mp == strategist.max_mp - CombatConfig.SKILL_MP_COST, "Within range 5: cast begins, 25 MP paid")
	battle.advance(CombatConfig.SKILL_CAST_MS)
	_check(resolved.size() == 1 and battle.get_skill_readiness(strategist) == CombatBattle.SkillReadiness.COOLDOWN and battle.get_skill_cooldown_remaining(strategist) > CombatConfig.SKILL_COOLDOWN_MS - 100, "Resolved once, C06 cooldown")
	for index in range(spots.size()):
		var inside := index < 5
		_check(battle.get_slow_remaining(enemies[index]) > 0 == inside, "AC08 Enemy at %s %s" % [str(spots[index]), "slowed" if inside else "not slowed"])
	_check(battle.get_slow_remaining(enemies[0]) <= CombatConfig.SKILL_EFFECT_MS and battle.get_slow_remaining(enemies[0]) > CombatConfig.SKILL_EFFECT_MS - 100, "5 s Slow")
	_check(enemies.all(func(e: CombatUnit) -> bool: return e.hp == hp_before[enemies.find(e)]), "AC08 冰場 deals no damage")
	var aoe := battle.get_last_aoe()
	_check(aoe["kind"] == "ice_field" and aoe["damage"] == 0 and (aoe["cells"] as Array).size() == 5, "The 5 cells are marked as 冰場")
	_check(enemies[0].step_ms() == roundi(1000.0 / enemies[0].move_speed) * CombatConfig.SLOW_FACTOR, "Slowed steps take x2 (C06 Slow)")
	_check(strategist.mp == strategist.max_mp - CombatConfig.SKILL_MP_COST, "MP 25 for the cast")
	# Refresh, never stack: a second 軍師 re-applies 冰場 while the Slow runs.
	var pair := CombatBattle.create_party(10, null, [Mercenary.create("merc_1", "STRATEGIST"), Mercenary.create("merc_2", "STRATEGIST")])
	var first := pair.get_friends()[1]
	var second := pair.get_friends()[2]
	var target := pair.get_enemies()[0]
	for enemy in pair.get_enemies():
		enemy.move_speed = 0.001
	_place(target, Vector2i(4, 2))
	pair.advance(CombatConfig.PREPARATION_MS)
	pair.select_unit(first)
	pair.command_skill(target)
	pair.advance(50)
	pair.advance(CombatConfig.SKILL_CAST_MS)
	_check(pair.get_slow_remaining(target) > CombatConfig.SKILL_EFFECT_MS - 100, "First 冰場: 5 s")
	pair.advance(3000)
	var left := pair.get_slow_remaining(target)
	pair.select_unit(second)
	_check(pair.command_skill(target), "Second 軍師 casts on the slowed enemy")
	pair.advance(50)
	pair.advance(CombatConfig.SKILL_CAST_MS)
	_check(left > 0 and left < CombatConfig.SKILL_EFFECT_MS - 2000 and pair.get_slow_remaining(target) <= CombatConfig.SKILL_EFFECT_MS and pair.get_slow_remaining(target) > CombatConfig.SKILL_EFFECT_MS - 100, "AC08 Re-applied: refreshed to 5 s, not stacked (%d -> %d)" % [left, pair.get_slow_remaining(target)])
	_check(first.mp == first.max_mp - CombatConfig.SKILL_MP_COST and second.mp == second.max_mp - CombatConfig.SKILL_MP_COST, "Each 軍師 paid its own MP")
	_sections_done.append("ice_field")


# --- Settlement --------------------------------------------------------------------------------------------

func _verify_settlement() -> void:
	var roster := MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "MAGE", 1, 90), Mercenary.create("merc_3", "STRATEGIST")], ["merc_1", "merc_2", "merc_3"])
	var progression := ProgressionState.new()
	var victory := _result(BattleResult.Outcome.VICTORY, 200, ["hero", "merc_1", "merc_2", "merc_3"])
	var shares := PartyProgression.preview(victory, progression, roster)
	_check(shares.keys() == ["hero", "merc_1", "merc_2", "merc_3"] and shares.values().all(func(s: Dictionary) -> bool: return s["exp"] == 50), "AC09 200 / 4 survivors = 50 each")
	_check(shares["merc_2"]["leveled"] and shares["merc_2"]["from_level"] == 1 and shares["merc_2"]["level"] == 2 and not shares["merc_1"]["leveled"], "AC09 法師 #2 (90 EXP) reaches Lv2; preview")
	_check(roster.get_mercenary("merc_2").get_exp() == 90 and progression.get_exp("hero") == 0, "preview changes nothing")
	var applied := PartyProgression.apply(victory, progression, roster)
	_check(applied == shares and progression.get_exp("hero") == 50 and roster.get_mercenary("merc_1").get_exp() == 50 and roster.get_mercenary("merc_2").get_level() == 2 and roster.get_mercenary("merc_2").get_exp() == 40 and roster.get_mercenary("merc_3").get_exp() == 50, "AC09 Applied: Hero slot 50, each Mercenary its own EXP (法師 #2 Lv2 40)")
	_check(progression.get_exp("merc_a") == 0 and progression.get_exp("merc_b") == 0 and progression.get_level("merc_a") == 1, "AC10 Legacy Merc A / B slots get nothing")
	_check(roster.get_mercenary("merc_2").get_unspent_points() == 3, "Level Up brings the instance its 3 points")
	var dead := _result(BattleResult.Outcome.VICTORY, 100, ["hero", "merc_3"])
	var before_1 := roster.get_mercenary("merc_1").get_exp()
	_check(PartyProgression.apply(dead, progression, roster).keys() == ["hero", "merc_3"] and roster.get_mercenary("merc_1").get_exp() == before_1 and roster.get_mercenary("merc_3").get_level() == 2 and roster.get_mercenary("merc_3").get_exp() == 0, "Dead 守衛 #1 gets nothing; 100 / 2 (軍師 #3 50 + 50 -> Lv2)")
	var retreat := _result(BattleResult.Outcome.RETREAT, 30, ["merc_1"])
	_check(PartyProgression.apply(retreat, progression, roster) == {"merc_1": {"exp": 30, "from_level": 1, "level": 1, "leveled": false}} and roster.get_mercenary("merc_1").get_exp() == before_1 + 30, "RETREAT keeps the kills' EXP (Hero dead: the survivor gets all)")
	var snapshot := JSON.stringify(roster.get_snapshot())
	var hero_exp := progression.get_exp("hero")
	_check(PartyProgression.apply(_result(BattleResult.Outcome.DEFEAT, 100, []), progression, roster).is_empty() and JSON.stringify(roster.get_snapshot()) == snapshot and progression.get_exp("hero") == hero_exp, "DEFEAT: nothing")
	_check(PartyProgression.preview(_result(BattleResult.Outcome.VICTORY, 3, ["hero", "merc_1", "merc_2", "merc_3"]), progression, roster).is_empty(), "3 EXP over 4: 0 each, nothing")
	_check(PartyProgression.preview(null, progression, roster).is_empty() and PartyProgression.preview(victory, null, roster).is_empty(), "null result / progression: nothing")
	# An unknown survivor id still divides, gets nothing.
	var foreign := PartyProgression.preview(_result(BattleResult.Outcome.VICTORY, 100, ["hero", "merc_99"]), progression, roster)
	_check(foreign.keys() == ["hero"] and foreign["hero"]["exp"] == 50, "An unknown survivor counts in the division, awarded nowhere")
	# A roster instance whose id is a legacy slot name feeds the instance only.
	var legacy_named := MercenaryRoster.new()
	legacy_named.add(Mercenary.create("merc_a", "GUARDIAN"))
	var p := ProgressionState.new()
	PartyProgression.apply(_result(BattleResult.Outcome.VICTORY, 60, ["hero", "merc_a"]), p, legacy_named)
	_check(legacy_named.get_mercenary("merc_a").get_exp() == 30 and p.get_exp("merc_a") == 0 and p.get_exp("hero") == 30, "Roster before legacy slot: merc_a instance 30, legacy slot 0")
	# Without a roster (the C01-C08 fixture) the legacy slots settle as C05.
	var fixture := ProgressionState.new()
	PartyProgression.apply(_result(BattleResult.Outcome.VICTORY, 90, ["hero", "merc_a", "merc_b"]), fixture, null)
	_check(fixture.get_exp("hero") == 30 and fixture.get_exp("merc_a") == 30 and fixture.get_exp("merc_b") == 30, "Fixture party: same as ProgressionState.apply")
	_check(not fixture.award("merc_9", 10) and not fixture.award("hero", -1) and fixture.award("hero", 0) and fixture.get_exp("hero") == 30, "award(): unknown slot / negative refused")
	_sections_done.append("settlement")


# --- Game: Hero alone --------------------------------------------------------------------------------------

func _verify_game_hero_alone() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	var view := main.get_node("CombatView") as CombatView
	var battle := await _locked_battle(main, PASSIVE_ONLY)
	_check(battle != null and battle.get_friends().size() == 1 and battle.get_hero() != null and view.get_portrait_unit(0) == battle.get_hero() and view.get_portrait_unit(1) == null, "AC11 No deployed Mercenary: the Hero fights alone (approved D2)")
	_check(battle.get_friends().all(func(u: CombatUnit) -> bool: return u.id != "merc_a" and u.id != "merc_b"), "AC10 Legacy Merc A / B no longer fight")
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)
	await process_frame
	_check(view.get_victory_lines().has("主角　經驗 +100"), "The Hero takes the whole pool (10 kills = 100)")
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(main.progression.get_exp("hero") == 0 and main.progression.get_level("hero") == 2 and main.progression.get_exp("merc_a") == 0, "Hero Lv2 (100 EXP), legacy slots untouched")
	await _destroy(main)
	_sections_done.append("game_hero_alone")


# --- Game: Hero + 3 ----------------------------------------------------------------------------------------

func _verify_game_party() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "GUARDIAN", 2, 0, {"hp": 3, "str": 0, "agi": 0, "int": 0}), Mercenary.create("merc_3", "STRATEGIST", 1, 80), Mercenary.create("merc_4", "MAGE")], ["merc_3", "merc_1", "merc_2"])
	var legacy_before: Dictionary = main.progression.to_dict()["merc_a"]
	var view := main.get_node("CombatView") as CombatView
	var battle := await _locked_battle(main, PASSIVE_ONLY)
	var friends := battle.get_friends()
	_check(friends.size() == 4 and friends.map(func(u: CombatUnit) -> String: return u.id) == ["hero", "merc_3", "merc_1", "merc_2"], "AC05 Hero + the 3 deployed, in deployment order (not merc_4)")
	_check(friends[1].cell == Vector2i(1, 1) and friends[2].cell == Vector2i(1, 3) and friends[3].cell == Vector2i(2, 2), "Start cells by deployment order")
	_check(friends[3].max_hp == 200 + 25 + 30 and friends[2].max_hp == 200, "Each 守衛 from its own Level / points (255 / 200)")
	await process_frame
	for index in range(4):
		_check(view.get_portrait_unit(index) == friends[index], "AC12 Portrait %d is %s" % [index, friends[index].id])
	_check(view.get_info_text(friends[1]).begins_with("軍師 #3\n") and view.get_info_text(friends[1]).contains("等級 1　經驗 80") and view.get_info_text(friends[3]).contains("等級 2　經驗 0"), "AC12 ⓘ info: the instance's label and its own Level / EXP")
	_check(view.press_all(), "全體")
	var entries := view.get_skill_bar_entries()
	var owners := entries.map(func(e: Dictionary) -> String: return (e["owner"] as CombatUnit).id)
	_check(entries.size() == 5 and owners == ["hero", "hero", "merc_3", "merc_1", "merc_2"] and entries.all(func(e: Dictionary) -> bool: return e["compact"]), "AC12 Skill bar: Hero x2 + one per Mercenary (%s)" % str(owners))
	_check(entries[2]["kind"] == "ice_field" and entries[2]["text"].begins_with("軍師 #3") and entries[3]["text"].begins_with("守衛 #1") and entries[4]["kind"] == "guard", "AC12 Compact icons named by instance")
	for index in range(entries.size()):
		var slot := view.get_node("SkillSlot%d" % index) as Control
		_check(slot.visible and Rect2(0.0, 0.0, 720.0, 1280.0).encloses(slot.get_global_rect()), "Skill slot %d inside the screen" % index)
	# Hero + 守衛 #1 + 軍師 #3 survive; 守衛 #2 dies.
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_enemies()[0], friends[3], 10000)
	for enemy in battle.get_enemies():
		battle.resolve_damage(friends[0], enemy, 1000)
	await process_frame
	_check(battle.get_result().survivor_ids == ["hero", "merc_3", "merc_1"], "Survivors: Hero, 軍師 #3, 守衛 #1")
	var lines := view.get_victory_lines()
	_check(lines.has("主角　經驗 +33") and lines.has("軍師 #3　經驗 +33") and lines.has("守衛 #1　經驗 +33") and not str(lines).contains("守衛 #2"), "AC13 Result: 100 / 3 = 33 each, by instance label (%s)" % str(lines))
	_check(lines.has(CombatView.LEVEL_UP_TEXT % ["軍師 #3", 2, 3]), "AC13 軍師 #3 Level Up line (80 + 33)")
	_check(view.get_reward_text().contains("軍師 #3 經驗 +33"), "Reward text by instance name")
	(view.get_node("ExitButton") as Button).pressed.emit()
	var roster: MercenaryRoster = main.mercenary_roster
	_check(main.get_last_award().keys() == ["hero", "merc_3", "merc_1"] and main.progression.get_exp("hero") == 33 and roster.get_mercenary("merc_3").get_level() == 2 and roster.get_mercenary("merc_3").get_exp() == 13 and roster.get_mercenary("merc_1").get_exp() == 33 and roster.get_mercenary("merc_2").get_exp() == 0 and roster.get_mercenary("merc_4").get_exp() == 0, "AC13 Committed: Hero 33, 軍師 #3 Lv2 13, 守衛 #1 33, dead #2 / waiting #4 0")
	_check(main.progression.to_dict()["merc_a"] == legacy_before and main.progression.get_exp("merc_b") == 0, "AC10 Legacy Merc A / B progression unchanged")
	_check(not main.commit_battle_result(battle.get_result()) and roster.get_mercenary("merc_1").get_exp() == 33, "AC14 A second commit is refused: nothing settled twice")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(saved != null and int(saved["version"]) == 11 and saved.keys().size() == 11, "AC15 Saved: v11, same sections")
	var saved_merc_3: Dictionary = (saved["mercenaries"]["owned"] as Array).filter(func(m: Dictionary) -> bool: return m["id"] == "merc_3")[0]
	_check(int(saved_merc_3["level"]) == 2 and int(saved_merc_3["exp"]) == 13 and (saved_merc_3 as Dictionary).keys().size() == Mercenary.KEYS.size(), "AC15 The saved instance holds its new Level / EXP (nothing derived)")
	await _destroy(main)
	# Restart.
	main = await _new_main(TEST_SAVE)
	roster = main.mercenary_roster
	_check(roster.get_mercenary("merc_3").get_level() == 2 and roster.get_mercenary("merc_3").get_exp() == 13 and roster.get_mercenary("merc_1").get_exp() == 33 and roster.get_deployed_ids() == ["merc_3", "merc_1", "merc_2"] and main.progression.get_exp("hero") == 33, "AC15 Restart: Levels, EXP, deployment and the Hero restored")
	var again := await _locked_battle(main, PASSIVE_ONLY)
	_check(again.get_friends().size() == 4 and again.get_friends()[1].max_mp == CharacterStats.for_mercenary(roster.get_mercenary("merc_3")).get_max_mp(), "After restart the next battle uses the restored stats")
	await _destroy(main)
	_sections_done.append("game_party")


# --- Game: save failure (C02, approved D4) -----------------------------------------------------------------

func _verify_game_save_failure() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "MAGE")], ["merc_1"])
	main._save_session()
	var view := main.get_node("CombatView") as CombatView
	var battle := await _locked_battle(main, PASSIVE_ONLY)
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)
	await process_frame
	var good := FileAccess.get_file_as_string(TEST_SAVE)
	_check(good.contains("merc_1"), "The last good save holds the roster")
	main.save_path = BAD_SAVE
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(main.get_combat() == null and main.progression.get_exp("hero") == 50 and main.mercenary_roster.get_mercenary("merc_1").get_exp() == 50, "AC16 Save failed: the committed result stays (C02), Hero and 法師 #1 both 50")
	_check(FileAccess.get_file_as_string(TEST_SAVE) == good, "AC16 The last good save is untouched")
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(main.progression.get_exp("hero") == 0 and main.mercenary_roster.get_mercenary("merc_1").get_exp() == 0, "AC16 Restart after the failed save: Hero and Mercenary both back to the last good save (in step)")
	await _destroy(main)
	_sections_done.append("game_save_failure")


# --- Character UI (approved D3) ----------------------------------------------------------------------------

func _verify_character_panel() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	var panel := main.get_node("CharacterPanel") as CharacterPanel
	_check(panel.shown_ids == ["hero"], "AC17 Character UI shows only the Hero")
	_check(panel.open(), "Opened in the world")
	await process_frame
	_check((panel.get_node("Panel/Tab_hero") as Button).visible and not (panel.get_node("Panel/Tab_merc_a") as Button).visible and not (panel.get_node("Panel/Tab_merc_b") as Button).visible, "AC17 Tabs: 主角 only (傭兵A / 傭兵B hidden)")
	panel.select_character("merc_a")
	_check(panel.get_selected() == "hero", "AC17 A hidden character cannot be selected")
	# Legacy points do not count on the 角色 button.
	main.progression = ProgressionState.from_dict({"hero": {"level": 1, "exp": 0}, "merc_a": {"level": 3, "exp": 0}, "merc_b": {"level": 1, "exp": 0}})
	main._apply_level_growth()
	panel.progression = main.progression
	panel.close()
	await process_frame
	await process_frame
	_check((panel.get_node("OpenButton") as Button).text == CharacterPanel.OPEN_TEXT, "AC17 Merc A's unspent points are not shown on 角色")
	await _destroy(main)
	# A standalone panel keeps S04's three tabs (default).
	var standalone := CharacterPanel.new()
	_check(standalone.shown_ids == CharacterPanel.ORDER, "Default panel: every ORDER character (S04 unchanged)")
	standalone.free()
	_sections_done.append("character_panel")


# --- Mercenary Center rows (P03 AC03) ----------------------------------------------------------------------

func _verify_mercenary_rows() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "MAGE", 3, 10, {"hp": 1, "str": 0, "agi": 0, "int": 2}), Mercenary.create("merc_3", "STRATEGIST"), Mercenary.create("merc_4", "GUARDIAN", 5, 0, {"hp": 0, "str": 12, "agi": 0, "int": 0}), Mercenary.create("merc_5", "MAGE")], ["merc_1"])
	var hub := main.get_node("CityHub") as CityHub
	(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
	await _settle()
	main._on_enter_city_button_pressed()
	await _settle()
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	hub.show_mercenary_view(CityHub.MERCENARY_VIEW_ROSTER)
	await process_frame
	await process_frame
	var guardian := hub.get_roster_row_texts("merc_1")
	_check(guardian["StatsLabel"] == "血量 200　魔力 100　力量 10　敏捷 10　智力 10", "AC03 守衛 #1 Lv1 stats (%s)" % guardian["StatsLabel"])
	_check(guardian["DerivedLabel"] == "物攻 15　魔攻 0　物防 0　魔防 0　間隔 1.00秒　移速 4.0", "AC03 守衛 #1 derived (%s)" % guardian["DerivedLabel"])
	var mage := hub.get_roster_row_texts("merc_2")
	_check(mage["StatsLabel"] == "血量 190　魔力 150　力量 10　敏捷 12　智力 16" and mage["DerivedLabel"] == "物攻 12　魔攻 12　物防 0　魔防 3　間隔 1.14秒　移速 4.2", "AC03 法師 #2 Lv3 + points (%s / %s)" % [mage["StatsLabel"], mage["DerivedLabel"]])
	# 守衛 Lv5: STR 10 + 8 + 12 = 30 -> attack 15 + 20 = 35, defense 10; HP 300.
	var strong := hub.get_roster_row_texts("merc_4")
	_check(strong["StatsLabel"] == "血量 300　魔力 100　力量 30　敏捷 14　智力 10" and strong["DerivedLabel"].begins_with("物攻 35　魔攻 0　物防 10　魔防 0"), "AC03 守衛 #4 Lv5 STR 12 points (%s / %s)" % [strong["StatsLabel"], strong["DerivedLabel"]])
	_check(hub.get_roster_row_texts("merc_3")["StatsLabel"] == hub.get_roster_row_texts("merc_5")["StatsLabel"], "AC03 軍師 Lv1 = 法師 Lv1 (Prototype)")
	_check(guardian["PendingLabel"] == "裝備：尚未開放", "AC03 Equipment still not open (Stage 9)")
	var canvas := Rect2(0.0, 0.0, 720.0, 1280.0)
	_check(canvas.encloses((hub.get_node("Center/Content") as Control).get_global_rect()), "AC18 5 rows with stats fit 720 x 1280 (%s)" % str((hub.get_node("Center/Content") as Control).get_global_rect()))
	for id in hub.get_roster_ids():
		var row: Node = hub._roster_rows[id]
		for name in ["StatsLabel", "DerivedLabel"]:
			var label := row.find_child(name, true, false) as Label
			var width := label.get_theme_font("font").get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
			_check(width <= label.size.x and label.get_global_rect().end.x <= hub.get_deploy_button(id).get_global_rect().position.x, "AC18 %s %s fits its row (%.0f <= %.0f)" % [id, name, width, label.size.x])
	# Levelling the instance updates the row.
	main.mercenary_roster.get_mercenary("merc_1").add_exp(100)
	main._refresh_mercenary_view()
	_check(hub.get_roster_row_texts("merc_1")["StatsLabel"].begins_with("血量 225"), "AC03 The row follows the instance's Level (Lv2: 225)")
	await _destroy(main)
	_sections_done.append("mercenary_rows")


# --- Scope ---------------------------------------------------------------------------------------------------

func _verify_scope() -> void:
	_check(SaveStore.VERSION == 11 and ProgressionState.SLOTS == ["hero", "merc_a", "merc_b"] and CharacterConfig.PROTOTYPE_CHARACTERS == ["hero", "merc_a", "merc_b"], "AC19 Save v11 and the legacy slots unchanged (P05 maps them)")
	var save_code := _code_only("res://scripts/save_store.gd").to_lower()
	_check(not save_code.contains("partyprogression") and not save_code.contains("for_mercenary") and not save_code.contains("ice_field"), "AC19 The save knows nothing about P04")
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_view.gd", "res://scripts/party_progression.gd"]:
		var code := _code_only(path).to_lower()
		for word in ["equipment", "hospital", "revive", "formation", "loot"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	_check(not _code_only("res://scripts/combat_battle.gd").contains("PartyService") and not _code_only("res://scripts/combat_battle.gd").contains("create_mercenary"), "Combat does not manage the roster")
	_sections_done.append("scope")


# --- Stress ---------------------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	var bad := 0
	for round in range(300):
		var count := rng.randi_range(0, 3)
		var team := []
		for index in range(count):
			var level := rng.randi_range(1, 20)
			team.append(Mercenary.create("merc_%d" % (index + 1), Mercenary.TYPES[rng.randi_range(0, 2)], level, 0, {"hp": 0, "str": 0, "agi": 0, "int": CharacterStats.earned_points_for(level)}))
		var roster := MercenaryRoster.build(team, team.map(func(m: Mercenary) -> String: return m.get_id()))
		var battle := CombatBattle.create_party(rng.randi_range(1, 3) * 5 + 5, null, roster.get_deployed())
		if battle == null or battle.get_friends().size() != count + 1:
			bad += 1
			continue
		battle.advance(CombatConfig.PREPARATION_MS)
		for unit in battle.get_friends():
			if rng.randf() < 0.3 and unit != battle.get_friends()[-1]:
				battle.resolve_damage(battle.get_enemies()[0], unit, 100000)
		var kills := rng.randi_range(0, battle.get_enemies().size())
		for index in range(kills):
			battle.resolve_damage(battle.get_friends()[-1], battle.get_enemies()[index], 100000)
		if not battle.is_over():
			battle.start_retreat()
			for step in range(200):
				battle.advance(100)
				if battle.is_over():
					break
		var result := battle.get_result()
		if result == null:
			continue
		var progression := ProgressionState.new()
		var before := {}
		for m in roster.get_owned():
			before[m.get_id()] = [m.get_level(), m.get_exp()]
		var shares := PartyProgression.apply(result, progression, roster)
		var total := 0
		for id in shares:
			total += int(shares[id]["exp"])
			if not result.survivor_ids.has(id):
				bad += 1
		if total > result.exp_pool or (result.outcome == BattleResult.Outcome.DEFEAT and not shares.is_empty()):
			bad += 1
		for m in roster.get_owned():
			var gained := m.get_id() in shares
			var expected: Array = ProgressionState.advance(before[m.get_id()][0], before[m.get_id()][1], int(shares[m.get_id()]["exp"])) if gained else before[m.get_id()]
			if [m.get_level(), m.get_exp()] != expected:
				bad += 1
		if progression.get_exp("merc_a") != 0 or progression.get_exp("merc_b") != 0:
			bad += 1
	_check(bad == 0, "300 seeded battles: 0-3 random deployed, random deaths / kills / retreats; every share to its survivor once, within the pool, legacy slots untouched (%d bad)" % bad)
	_sections_done.append("stress")


# --- Helpers ---------------------------------------------------------------------------------------------------

func _result(outcome: BattleResult.Outcome, pool: int, survivors: Array) -> BattleResult:
	var result := BattleResult.create("enc", outcome, [] as Array[String])
	result.exp_pool = pool
	for id in survivors:
		result.survivor_ids.append(id)
	return result


func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


func _locked_battle(main: Node, spot: Vector2) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = spot
	await _settle()
	var session := main.get_node("EncounterSession") as EncounterSession
	session.challenge()
	for frame in range(60):
		await physics_frame
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	return main.get_combat()


func _new_main(path: String) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	main.time_source = TimeSource.fixed(T0)
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
