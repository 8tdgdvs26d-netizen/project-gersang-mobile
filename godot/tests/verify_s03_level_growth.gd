extends SceneTree

## Stage 7 S03: Level & Growth v0.1. Combat EXP -> Level Up (leaving Level L
## needs 100 + 50 x (L - 1); Lv100 cap, nothing kept at it) -> each Level
## gained adds the character's Base Growth and 3 unspent Stat Points -> the S02
## derived stats grow. Level Up never heals Current HP / MP. C05 EXP sharing
## is unchanged. Save stays v9 (Growth / points derive from the saved Level).

const TEST_SAVE := "user://s03_level_growth_test_save.json"
const T0 := 1800000000000
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const SLOTS := ["hero", "merc_a", "merc_b"]

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_verify_curve()
	_verify_growth()
	_verify_multi_level_and_cap()
	_verify_derived()
	_verify_exp_rules()
	_verify_save_and_scope()
	await _verify_in_game()
	_check(_sections_done.size() == 7, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("S03 level growth verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# 1-3: the EXP curve.
func _verify_curve() -> void:
	_check(ProgressionState.required_exp(1) == 100, "1. Lv1 -> Lv2 needs 100")
	_check(ProgressionState.required_exp(2) == 150, "2. Lv2 -> Lv3 needs 150")
	_check(ProgressionState.required_exp(3) == 200 and ProgressionState.required_exp(10) == 550 and ProgressionState.required_exp(99) == 5000, "Lv3 200, Lv10 550, Lv99 5000")
	var steps := []
	for level in range(1, 99):
		steps.append(ProgressionState.required_exp(level + 1) - ProgressionState.required_exp(level))
	_check(steps.all(func(step: int) -> bool: return step == 50), "3. +50 EXP per Level, Lv1 to Lv99")
	_check(ProgressionState.required_exp(100) == 0 and ProgressionState.MAX_LEVEL == 100, "Lv100 cap: nothing further required")
	var just := ProgressionState.new()
	just.apply(_result(99, ["hero"]))
	_check(just.get_level("hero") == 1 and just.get_exp("hero") == 99, "99 EXP stays Lv1")
	just.apply(_result(1, ["hero"]))
	_check(just.get_level("hero") == 2 and just.get_exp("hero") == 0, "100 EXP: Lv2")
	just.apply(_result(149, ["hero"]))
	_check(just.get_level("hero") == 2 and just.get_exp("hero") == 149, "149 more stays Lv2")
	just.apply(_result(1, ["hero"]))
	_check(just.get_level("hero") == 3 and just.get_exp("hero") == 0, "150 at Lv2: Lv3")
	_sections_done.append("curve")


# 4-7: Base Growth and Stat Points per Level.
func _verify_growth() -> void:
	var expected := {
		"hero": {"hp": 20, "mp": 5, "str": 1, "agi": 1, "int": 1},
		"merc_a": {"hp": 25, "mp": 0, "str": 2, "agi": 1, "int": 0},
		"merc_b": {"hp": 15, "mp": 10, "str": 0, "agi": 1, "int": 2},
	}
	for slot in SLOTS:
		var stats := CharacterStats.for_character(slot)
		var base_hp := stats.get_max_hp()
		stats.apply_level(1)
		_check(CharacterConfig.STATS.all(func(s: String) -> bool: return stats.get_growth(s) == 0) and stats.get_unspent_points() == 0, "%s Lv1: no Growth, no points" % slot)
		stats.apply_level(2)
		var per_level: Dictionary = expected[slot]
		_check(CharacterConfig.STATS.all(func(s: String) -> bool: return stats.get_growth(s) == per_level[s]), "%s Lv2: Growth %s" % [slot, str(per_level)])
		_check(stats.get_max_hp() == base_hp + per_level["hp"], "%s Lv2: Max HP +%d" % [slot, per_level["hp"]])
		_check(stats.get_unspent_points() == 3, "7. %s: one Level Up = +3 unspent Stat Points" % slot)
		stats.apply_level(10)
		_check(CharacterConfig.STATS.all(func(s: String) -> bool: return stats.get_growth(s) == 9 * per_level[s]) and stats.get_unspent_points() == 27, "%s Lv10: 9 x Growth, 27 points" % slot)
		_check(stats.get_base("str") == 10 and stats.get_allocated("str") == 0, "%s: Growth leaves Base / Allocated alone" % slot)
	_check(CharacterConfig.STAT_POINTS_PER_LEVEL == 3, "Stat Points per Level = 3")
	var hero := CharacterStats.for_character("hero")
	hero.apply_level(5)
	_check(hero.get_max_hp() == 300 + 80 and hero.get_effective("str") == 14 and hero.get_effective("int") == 14 and hero.get_max_mp() == 200 + 20 + 4 * 5, "4. Hero Lv5: HP 380, STR 14, INT 14, Max MP 200 + 20 + INT 20")
	var merc_a := CharacterStats.for_character("merc_a")
	merc_a.apply_level(5)
	_check(merc_a.get_max_hp() == 200 + 100 and merc_a.get_effective("str") == 18 and merc_a.get_effective("int") == 10 and merc_a.get_max_mp() == 100, "5. Merc A Lv5: HP 300, STR 18, INT 10, MP 100")
	var merc_b := CharacterStats.for_character("merc_b")
	merc_b.apply_level(5)
	_check(merc_b.get_max_hp() == 150 + 60 and merc_b.get_effective("str") == 10 and merc_b.get_effective("int") == 18 and merc_b.get_max_mp() == 100 + 40 + 8 * 5, "6. Merc B Lv5: HP 210, STR 10, INT 18, Max MP 100 + 40 + INT 40")
	_check(hero.get_effective("agi") == 14 and merc_a.get_effective("agi") == 14 and merc_b.get_effective("agi") == 14, "Everyone +1 AGI per Level")
	_sections_done.append("growth")


# 8-10: multi-Level, overflow, the cap.
func _verify_multi_level_and_cap() -> void:
	var progression := ProgressionState.new()
	var shares := progression.apply(_result(100 + 150 + 200 + 120, ["hero"]))
	_check(progression.get_level("hero") == 4 and progression.get_exp("hero") == 120, "8/9. 570 EXP at Lv1: Lv2, Lv3, Lv4 in turn, 120 carried")
	_check(shares["hero"]["leveled"] and shares["hero"]["level"] == 4, "The share reports the final Level")
	var stats := CharacterStats.for_character("hero")
	stats.apply_level(progression.get_level("hero"))
	_check(stats.get_unspent_points() == 9 and stats.get_growth("hp") == 60, "8. Three Levels: +9 points, +60 HP (every intermediate Level counted)")
	# To the cap.
	var total := 0
	for level in range(1, 100):
		total += ProgressionState.required_exp(level)
	var capped := ProgressionState.new()
	capped.apply(_result(total - 1, ["merc_b"]))
	_check(capped.get_level("merc_b") == 99 and capped.get_exp("merc_b") == ProgressionState.required_exp(99) - 1, "One EXP short of Lv100: Lv99 with the rest kept")
	capped.apply(_result(1 + 5000, ["merc_b"]))
	_check(capped.get_level("merc_b") == 100 and capped.get_exp("merc_b") == 0, "10. Lv100 reached: no overflow kept")
	capped.apply(_result(999999, ["merc_b"]))
	_check(capped.get_level("merc_b") == 100 and capped.get_exp("merc_b") == 0, "10. At Lv100 more EXP changes nothing")
	var preview := capped.preview(_result(500, ["merc_b"]))
	_check(not preview["merc_b"]["leveled"] and preview["merc_b"]["level"] == 100, "At Lv100 no Level Up is announced")
	var top := CharacterStats.for_character("merc_b")
	top.apply_level(100)
	var top_growth := top.get_growth("hp")
	var top_points := top.get_unspent_points()
	top.apply_level(101)
	top.apply_level(1000)
	_check(top_growth == 99 * 15 and top_points == 99 * 3 and top.get_growth("hp") == top_growth and top.get_unspent_points() == top_points, "10. Nothing past Lv100: Growth 99 x, 297 points")
	var huge := ProgressionState.new()
	huge.apply(_result(ProgressionState.MAX_EXP, ["hero"]))
	_check(huge.get_level("hero") == 100 and huge.get_exp("hero") == 0, "A huge award stops at Lv100 safely")
	_sections_done.append("multi_level_cap")


# 11-13: Current HP / MP, derived stats, capacity.
func _verify_derived() -> void:
	# 11. Level Up raises Max HP / MP and never touches Current HP / MP.
	var hero_stats := CharacterStats.for_character("hero")
	var battle := CombatBattle.create(10, CombatBattle.PartyFixture.PROTOTYPE, {"hero": hero_stats})
	battle.advance(CombatConfig.PREPARATION_MS)
	var hero := battle.get_hero()
	battle.resolve_damage(battle.get_enemies()[0], hero, 200)
	hero.mp = 120
	hero_stats.apply_level(2)
	_check(hero.hp == 100 and hero.mp == 120 and hero_stats.get_max_hp() == 320 and hero_stats.get_max_mp() == 200 + 5 + 5, "11. Level Up: Max HP 320 / Max MP 210 (+5 growth, +5 from INT 11); Current 100 HP / 120 MP not refilled")
	# 12. Growth flows into the S02 derived stats.
	var levels := {}
	for slot in SLOTS:
		var stats := CharacterStats.for_character(slot)
		var before := [stats.get_physical_attack(), stats.get_physical_defense(), stats.get_magic_attack(), stats.get_magic_defense(), stats.get_max_mp(), stats.get_attack_interval_ms(), stats.get_move_speed()]
		stats.apply_level(11)
		levels[slot] = [before, [stats.get_physical_attack(), stats.get_physical_defense(), stats.get_magic_attack(), stats.get_magic_defense(), stats.get_max_mp(), stats.get_attack_interval_ms(), stats.get_move_speed()]]
	_check(levels["hero"][1] == [30, 5, 20, 5, 200 + 50 + 50, CharacterStats.attack_interval_for(1000, 10), CharacterStats.move_speed_for(4.0, 10)], "12. Hero Lv11 (STR / AGI / INT 20): ATK 30, DEF 5, MATK 20, MDEF 5, MP 300, faster (%s)" % str(levels["hero"][1]))
	_check(levels["merc_a"][1] == [15 + 20, 10, 0, 0, 100, CharacterStats.attack_interval_for(1000, 10), CharacterStats.move_speed_for(4.0, 10)], "12. Merc A Lv11 (STR 30): ATK 35, DEF 10 (%s)" % str(levels["merc_a"][1]))
	_check(levels["merc_b"][1] == [12, 0, 40, 10, 100 + 100 + 100, CharacterStats.attack_interval_for(1200, 10), CharacterStats.move_speed_for(4.0, 10)], "12. Merc B Lv11 (INT 30): MATK 40, MDEF 10, MP 300 (%s)" % str(levels["merc_b"][1]))
	var grown := CharacterStats.for_character("merc_b")
	grown.apply_level(11)
	var unit := CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE, {"merc_b": grown}).get_friends()[2]
	_check(unit.max_hp == 300 and unit.max_mp == 300 and unit.mp == 300 and unit.magic_attack == 40 and unit.attack_interval_ms < 1200, "12. A battle uses the grown stats (Merc B Lv11 starts 300 HP / 300 MP)")
	# 13. Effective STR Growth -> Capacity.
	var carrier := CharacterStats.new()
	var inventory := CharacterInventory.new("player", carrier)
	carrier.apply_level(6)
	_check(carrier.get_strength() == 15 and inventory.get_max_capacity() == 10 + 15 * 9, "13. Hero Lv6 (STR 15): Capacity 145")
	var merc_a := CharacterStats.for_character("merc_a")
	merc_a.apply_level(6)
	_check(merc_a.get_max_capacity() == 10 + 20 * 9, "13. Merc A Lv6 (STR 20): Capacity 190")
	_sections_done.append("derived")


# 14-16: the C05 EXP rules are unchanged.
func _verify_exp_rules() -> void:
	var progression := ProgressionState.new()
	var shares := progression.apply(_result(100, ["hero", "merc_b"]))
	_check(shares.size() == 2 and shares["hero"]["exp"] == 50 and progression.get_exp("merc_a") == 0, "14. Survivors share equally; the dead get 0")
	var odd := ProgressionState.new()
	odd.apply(_result(40, ["hero", "merc_a", "merc_b"]))
	_check(SLOTS.all(func(s: String) -> bool: return odd.get_exp(s) == 13), "Remainder discarded (40 / 3 = 13 each)")
	var retreat := BattleResult.create("e", BattleResult.Outcome.RETREAT, [] as Array[String])
	retreat.exp_pool = 30
	retreat.survivor_ids.append("hero")
	_check(odd.apply(retreat)["hero"]["exp"] == 30 and odd.get_exp("hero") == 43, "15. RETREAT keeps the kills' EXP")
	var defeat := BattleResult.create("e", BattleResult.Outcome.DEFEAT, [] as Array[String])
	defeat.exp_pool = 500
	_check(odd.apply(defeat).is_empty() and odd.get_exp("hero") == 43 and odd.get_level("hero") == 1, "16. DEFEAT gives 0")
	# A real battle: kills fill the pool (10 each), VICTORY splits it.
	var battle := CombatBattle.create(10)
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)
	_check(battle.get_result().exp_pool == 100 and battle.get_result().survivor_ids.size() == 3, "VICTORY pool 100 from 10 kills, three survivors")
	_sections_done.append("exp_rules")


# 17-18: Save v9 and scope.
func _verify_save_and_scope() -> void:
	var progression := ProgressionState.from_dict({"hero": {"level": 4, "exp": 120}, "merc_a": {"level": 1, "exp": 0}, "merc_b": {"level": 100, "exp": 0}})
	_check(progression != null and progression.get_level("merc_b") == 100, "Saved Levels up to 100 load")
	var data := SaveStore.serialize(Wallet.new(), CharacterInventory.new(), MarketState.create_default(), PlayerLocation.new(), null, null, null, progression)
	_check(SaveStore.VERSION == 9 and data["version"] == 9 and data["progression"] == {"hero": {"level": 4, "exp": 120}, "merc_a": {"level": 1, "exp": 0}, "merc_b": {"level": 100, "exp": 0}}, "17. Save v9: progression still exactly {level, exp} per slot")
	_check(data["character"]["stats"] == {"strength": 10} and SaveStore.STATS_KEYS == ["strength"], "17. No Growth / Stat Points written")
	# A C05 save banked EXP at the Lv2 ceiling: it loads, carried through the S03 curve.
	var legacy := ProgressionState.from_dict({"hero": {"level": 2, "exp": 400}, "merc_a": {"level": 2, "exp": 149}, "merc_b": {"level": 1, "exp": 99}})
	_check(legacy != null and legacy.get_level("hero") == 4 and legacy.get_exp("hero") == 50 and legacy.get_level("merc_a") == 2 and legacy.get_exp("merc_a") == 149, "A C05 Lv2 save with 400 banked EXP loads as Lv4 50 (nothing refused)")
	_check(ProgressionState.from_dict({"hero": {"level": 100, "exp": 30}, "merc_a": {"level": 1, "exp": 0}, "merc_b": {"level": 1, "exp": 0}}).get_exp("hero") == 0, "EXP at Lv100 is not kept on load")
	_check(ProgressionState.from_dict({"hero": {"level": 101, "exp": 0}, "merc_a": {"level": 1, "exp": 0}, "merc_b": {"level": 1, "exp": 0}}) == null, "Lv101 is refused")
	# Scope: nothing spends points, no allocation UI, no new saved keys.
	var ui_code := FileAccess.get_file_as_string("res://scripts/combat_view.gd") + FileAccess.get_file_as_string("res://scripts/city_hub.gd")
	var game_code := ui_code + FileAccess.get_file_as_string("res://scripts/main.gd") + FileAccess.get_file_as_string("res://scripts/combat_battle.gd")
	_check(not ui_code.contains("unspent") and not game_code.contains("set_allocated") and not game_code.contains("set_growth"), "18. No allocation UI / gameplay (S04); the game sets Growth only through apply_level")
	_check(not FileAccess.get_file_as_string("res://scripts/save_store.gd").contains("growth") and not FileAccess.get_file_as_string("res://scripts/save_store.gd").contains("unspent"), "18. Save code knows nothing of Growth / points (S05)")
	_sections_done.append("save_scope")


# The game: a real settlement levels the Hero; the stats follow, survive a relaunch.
func _verify_in_game() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main()
	var view := main.get_node("CombatView") as CombatView
	var battle := await _locked_battle(main)
	var f := battle.get_friends()
	battle.resolve_damage(battle.get_enemies()[0], f[1], 1000)
	battle.resolve_damage(battle.get_enemies()[0], f[2], 1000)
	battle.resolve_damage(battle.get_enemies()[0], f[0], 200)
	var hero := f[0]
	for enemy in battle.get_enemies():
		battle.resolve_damage(hero, enemy, 1000)
	await process_frame
	_check(view.get_reward_text().contains("升至 2 級"), "Result screen announces the Hero's Level Up")
	(view.get_node("ExitButton") as Button).pressed.emit()
	var stats: CharacterStats = main.character_stats
	_check(main.progression.get_level("hero") == 2 and stats.get_growth("str") == 1 and stats.get_unspent_points() == 3 and stats.get_max_hp() == 320, "Settlement: Hero Lv2, Growth applied, 3 points, Max HP 320")
	_check(hero.hp == 100, "11. The settled battle's Hero stays at 100 HP (no refill)")
	_check(main.inventory.get_max_capacity() == 10 + 11 * 9 and main.merc_stats["merc_a"].get_unspent_points() == 0, "Hero backpack Capacity 109; the dead Mercs gained nothing")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(saved["version"]) == 9 and int(saved["progression"]["hero"]["level"]) == 2 and (saved["character"]["stats"] as Dictionary).keys() == ["strength"], "Saved v9: Level 2, stats still only strength")
	await _destroy(main)
	main = await _new_main()
	var reloaded: CharacterStats = main.character_stats
	_check(main.progression.get_level("hero") == 2 and reloaded.get_growth("str") == 1 and reloaded.get_unspent_points() == 3 and reloaded.get_base_strength() == 10, "Relaunch: Growth and points follow the saved Level 2 (Base STR still 10)")
	var next := await _locked_battle(main)
	_check(next.get_hero().max_hp == 320 and next.get_hero().hp == 320, "The next battle starts the Hero at its new Max HP (battle start fills, as before)")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("in_game")


func _result(pool: int, survivors: Array) -> BattleResult:
	var result := BattleResult.create("encounter_test", BattleResult.Outcome.VICTORY, [] as Array[String])
	result.exp_pool = pool
	for slot in survivors:
		result.survivor_ids.append(slot)
	return result


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


func _delete(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
