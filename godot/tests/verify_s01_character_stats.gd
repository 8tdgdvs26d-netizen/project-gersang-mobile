extends SceneTree

## Stage 7 S01: Character Stat Foundation. One CharacterStats per combat
## character (Hero, Merc A, Merc B): Base + Allocated + Equipment = Effective
## for HP / MP / STR / AGI / INT; Capacity = 10 + Effective STR x 9; Max HP /
## Max MP feed the battle (Current HP / MP stay battle runtime on CombatUnit).
## Allocated and Equipment are 0 in the game (hooks only); Save stays v9 with
## character.stats.strength = the Hero's Base STR. C01-C08 combat values are
## unchanged (compatibility values until S02).

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_verify_layers()
	_verify_characters()
	_verify_capacity()
	_verify_hp_mp()
	_verify_combat_compatibility()
	_verify_save_v9()
	_verify_static()
	await _verify_in_game()
	_check(_sections_done.size() == 8, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("S01 character stats verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# 1-4, 8: Base / Allocated / Equipment / Effective.
func _verify_layers() -> void:
	var hero := CharacterStats.for_character("hero")
	for stat in CharacterConfig.STATS:
		_check(hero.get_base(stat) == int(CharacterConfig.BASE["hero"][stat]), "1. Base %s from CharacterConfig" % stat)
		_check(hero.get_allocated(stat) == 0 and hero.get_equipment_bonus(stat) == 0, "8. %s: Allocated 0, Equipment 0 by default" % stat)
		_check(hero.get_effective(stat) == hero.get_base(stat), "8. Zero bonuses: Effective %s = Base" % stat)
	_check(hero.get_base("str") == 10 and hero.get_base("agi") == 10 and hero.get_base("int") == 10 and hero.get_base("hp") == 300 and hero.get_base("mp") == 200, "Hero placeholders STR 10 / AGI 10 / INT 10, HP 300, MP 200")
	# 2. Allocated contribution (hook; MP is not allocatable).
	_check(hero.set_allocated("str", 4) and hero.get_allocated("str") == 4 and hero.get_effective("str") == 14, "2. Allocated STR 4: Effective 14")
	# S04: allocation counts Stat Points (1 HP point = +10 Max HP); was set_allocated("hp", 50).
	_check(hero.set_allocated("hp", 5) and hero.get_effective("hp") == 350 and hero.set_allocated("agi", 2) and hero.set_allocated("int", 3), "2. HP / AGI / INT allocatable")
	_check(not hero.set_allocated("mp", 10) and hero.get_allocated("mp") == 0 and hero.get_effective("mp") == 200, "2. MP is not player-allocatable")
	_check(not hero.set_allocated("str", -1) and not hero.set_allocated("str", 1.5) and not hero.set_allocated("luck", 1) and hero.get_allocated("str") == 4, "2. Invalid allocation refused, nothing changes")
	# 3. Equipment contribution (hook; any stat, MP / INT included).
	_check(hero.set_equipment_bonus("str", 5) and hero.get_equipment_bonus("str") == 5, "3. Equipment STR 5")
	# 4. Effective = Base + Allocated + Equipment (brief example: 10 + 4 + 5 = 19).
	_check(hero.get_effective("str") == 19 and hero.get_strength() == 19 and hero.get_base_strength() == 10, "4. Effective STR 19 = 10 + 4 + 5 (get_strength() is Effective)")
	_check(hero.set_equipment_bonus("int", 6) and hero.get_effective("int") == 10 + 3 + 6 and hero.set_equipment_bonus("mp", 20) and hero.get_max_mp() == 200 + 20 + (19 - 10) * 5, "4. Equipment INT / MP count toward Effective (S02: Max MP also + (INT - 10) x 5)")
	_check(not hero.set_equipment_bonus("luck", 1) and not hero.set_equipment_bonus("str", -2) and hero.get_equipment_bonus("str") == 5, "3. Invalid equipment bonus refused")
	_check(hero.set_strength(12) and hero.get_base("str") == 12 and hero.get_effective("str") == 21 and not hero.set_strength(-1) and not hero.set_strength(CharacterConfig.MAX_STAT + 1), "set_strength() sets Base STR (M2-08 API), range-checked")
	_sections_done.append("layers")


# 9-10: different characters, no shared mutable state.
func _verify_characters() -> void:
	var hero := CharacterStats.for_character("hero")
	var merc_a := CharacterStats.for_character("merc_a")
	var merc_b := CharacterStats.for_character("merc_b")
	_check(merc_a.get_base("hp") == 200 and merc_b.get_base("hp") == 150 and merc_a.get_base("mp") == 100 and merc_b.get_base("mp") == 100, "9. Each character has its own Base HP / MP")
	_check([hero, merc_a, merc_b].all(func(s: CharacterStats) -> bool: return s.get_base("str") == 10 and s.get_base("agi") == 10 and s.get_base("int") == 10), "Approved placeholders: every character STR / AGI / INT 10")
	_check(merc_b.get_attack_range() == 3 and merc_a.get_attack_range() == 1 and merc_b.get_attack_interval_ms() == 1200, "9. Characters differ (Merc B ranged)")
	merc_a.set_allocated("str", 7)
	merc_a.set_equipment_bonus("hp", 30)
	merc_a.set_strength(20)
	var again := CharacterStats.for_character("merc_a")
	_check(hero.get_effective("str") == 10 and merc_b.get_effective("str") == 10 and merc_b.get_max_hp() == 150, "10. Changing Merc A changes no other character")
	_check(again.get_effective("str") == 10 and again.get_max_hp() == 200 and int(CharacterConfig.BASE["merc_a"]["str"]) == 10, "10. New Merc A stats start from the config (config not mutated)")
	var two := CharacterStats.new()
	var three := CharacterStats.new()
	two.set_equipment_bonus("str", 9)
	_check(three.get_effective("str") == 10 and two.get_effective("str") == 19, "10. Two instances of the same character share nothing")
	_check(CharacterStats.for_character("merc_c") == null and CharacterStats.new().character_id == "hero", "No fourth character; the default (player backpack) character is the Hero")
	_sections_done.append("characters")


# 5: Effective STR -> Capacity; carrying rules unchanged.
func _verify_capacity() -> void:
	var stats := CharacterStats.new()
	_check(stats.get_max_capacity() == 100 and Cargo.CARGO_CAPACITY == 100, "5. Effective STR 10 -> Capacity 100")
	stats.set_allocated("str", 2)
	stats.set_equipment_bonus("str", 3)
	_check(stats.get_strength() == 15 and stats.get_max_capacity() == 145, "5. Effective STR 15 (incl. equipment) -> Capacity 145")
	var inventory := CharacterInventory.new("player", stats)
	_check(inventory.get_max_capacity() == 145 and inventory.add("test_good_01", 140), "Backpack follows Effective STR (140 of 145)")
	stats.set_equipment_bonus("str", 0)
	stats.set_allocated("str", 0)
	_check(inventory.get_max_capacity() == 100 and inventory.get_quantity("test_good_01") == 140 and inventory.is_over_capacity(), "Capacity drops below the load: no item deleted, over-capacity allowed")
	_check(not inventory.can_add("test_good_01", 1) and not inventory.add("test_good_01", 1) and inventory.get_quantity("test_good_01") == 140, "While over capacity nothing more can be added")
	_check(inventory.remove("test_good_01", 50) and not inventory.is_over_capacity() and inventory.add("test_good_01", 10), "Removing goods works; under capacity adding works again")
	# Each character's capacity is its own (only the Hero's backpack exists in the game).
	var merc := CharacterStats.for_character("merc_b")
	merc.set_equipment_bonus("str", 5)
	_check(merc.get_max_capacity() == 145 and CharacterStats.for_character("merc_a").get_max_capacity() == 100 and stats.get_max_capacity() == 100, "Capacity is per character (Effective STR of each)")
	_sections_done.append("capacity")


# 6-7: Current vs Max HP / MP.
func _verify_hp_mp() -> void:
	var stats := CharacterStats.for_character("hero")
	# S04: 4 HP points = +40 Max HP (was set_allocated("hp", 40)).
	stats.set_allocated("hp", 4)
	var battle := CombatBattle.create(10, CombatBattle.PartyFixture.PROTOTYPE, {"hero": stats})
	var hero := battle.get_hero()
	_check(hero.max_hp == 340 and hero.hp == 340 and hero.max_mp == 200 and hero.mp == 200, "6/7. A battle starts at Max HP = Effective HP, Max MP = Effective MP, both full")
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_enemies()[0], hero, 100)
	_check(hero.hp == 240 and hero.max_hp == 340 and stats.get_max_hp() == 340, "6. Damage lowers Current HP only (Max HP and the stats unchanged)")
	var merc_a := battle.get_friends()[1]
	battle.select_unit(merc_a)
	_check(battle.command_skill() and merc_a.mp == 75 and merc_a.max_mp == 100 and CharacterStats.for_character("merc_a").get_max_mp() == 100, "7. Spending MP (Guard) lowers Current MP only")
	stats.set_equipment_bonus("mp", 30)
	var next := CombatBattle.create(10, CombatBattle.PartyFixture.PROTOTYPE, {"hero": stats})
	_check(next.get_hero().max_mp == 230 and next.get_hero().mp == 230, "7. Max MP = Effective MP (equipment hook +30)")
	stats.set_equipment_bonus("mp", 0)
	next = CombatBattle.create(10, CombatBattle.PartyFixture.PROTOTYPE, {"hero": stats})
	_check(next.get_hero().hp == 340 and next.get_hero().mp == 200, "Current HP / MP do not carry over: the next battle starts full")
	_sections_done.append("hp_mp")


# 11: C01-C08 combat values unchanged.
func _verify_combat_compatibility() -> void:
	var plain := CombatBattle.create(10)
	var expected := {
		"hero": [300, 200, 20, 1, 1000, 4.0],
		"merc_a": [200, 100, 15, 1, 1000, 4.0],
		"merc_b": [150, 100, 12, 3, 1200, 4.0],
	}
	for unit in plain.get_friends():
		var want: Array = expected[unit.id]
		_check([unit.max_hp, unit.max_mp, unit.attack_damage, unit.attack_range, unit.attack_interval_ms, unit.move_speed] == want, "11. %s combat values unchanged %s" % [unit.id, str(want)])
	_check(plain.get_enemies()[0].max_hp == 40 and plain.get_enemies()[0].attack_damage == 4, "Enemies unchanged")
	var party := {"hero": CharacterStats.new(), "merc_a": CharacterStats.for_character("merc_a"), "merc_b": CharacterStats.for_character("merc_b")}
	var from_stats := CombatBattle.create(10, CombatBattle.PartyFixture.PROTOTYPE, party)
	for index in range(3):
		var a: CombatUnit = plain.get_friends()[index]
		var b: CombatUnit = from_stats.get_friends()[index]
		_check(a.max_hp == b.max_hp and a.max_mp == b.max_mp and a.attack_damage == b.attack_damage and a.attack_interval_ms == b.attack_interval_ms and a.move_speed == b.move_speed and a.skill == b.skill, "Battle from the party's stats = the Prototype battle (%s)" % a.id)
	# Legacy names are the same values as the authoritative config.
	_check(CombatConfig.HERO["max_hp"] == CharacterConfig.BASE["hero"]["hp"] and CombatConfig.MERC_B["attack_range"] == CharacterConfig.COMBAT_COMPAT["merc_b"]["attack_range"] and CombatConfig.HERO_MAX_MP == CharacterConfig.BASE["hero"]["mp"] and CombatConfig.MAX_MP == CharacterConfig.BASE["merc_a"]["mp"], "CombatConfig legacy names read CharacterConfig (no second value)")
	# STR / AGI / INT do not change combat in S01 (S02 integrates formulas).
	var strong := CharacterStats.new()
	strong.set_equipment_bonus("str", 50)
	strong.set_allocated("agi", 50)
	strong.set_allocated("int", 50)
	var unit := CombatBattle.create(10, CombatBattle.PartyFixture.PROTOTYPE, {"hero": strong}).get_hero()
	# S02 integrated the formulas (S01 expected 20 / 1000 / 4.0 / 200 / 0 here).
	_check(unit.attack_damage == 20 + 50 and unit.attack_interval_ms == CharacterStats.attack_interval_for(1000, 50) and unit.attack_interval_ms < 1000 and unit.move_speed == CharacterStats.move_speed_for(4.0, 50) and unit.move_speed > 4.0 and unit.max_mp == 200 + 50 * 5 and strong.get_physical_attack() == 70, "S02: STR / AGI / INT now feed the combat formulas")
	_check(strong.get_magic_attack() == 100 and strong.get_physical_defense() == 25 and strong.get_magic_defense() == 25 and unit.magic_attack == 100 and unit.physical_defense == 25, "S02: Magic Attack / defenses from INT / STR (were 0 placeholders in S01)")
	_sections_done.append("combat_compatibility")


# Save v9: unchanged schema; strength = the Hero's Base STR.
func _verify_save_v9() -> void:
	var stats := CharacterStats.new(13)
	stats.set_allocated("str", 4)
	stats.set_equipment_bonus("str", 5)
	var inventory := CharacterInventory.new("player", stats)
	var data := SaveStore.serialize(Wallet.new(), inventory, MarketState.create_default())
	_check(SaveStore.VERSION == 11 and data["version"] == 11, "Save v11 (S05 adds only the allocation)")
	_check(data["character"]["stats"] == {"strength": 13}, "character.stats is exactly {strength: Base STR} (no allocation / equipment saved)")
	_check(SaveStore.STATS_KEYS == ["strength"], "Saved stats keys unchanged")
	var path := "user://s01_character_stats_save.json"
	_check(SaveStore.save(path, Wallet.new(), inventory, MarketState.create_default()), "Save written")
	var loaded := SaveStore.load_session(path)
	var restored: CharacterStats = loaded["character_stats"]
	_check(restored.get_base_strength() == 13 and restored.get_strength() == 13 and restored.get_allocated("str") == 0 and restored.get_equipment_bonus("str") == 0 and restored.get_max_capacity() == 10 + 13 * 9 and restored.character_id == "hero", "Load: Base STR 13 restored as the Hero, Allocated / Equipment 0")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_sections_done.append("save_v9")


func _verify_static() -> void:
	var save_code := FileAccess.get_file_as_string("res://scripts/save_store.gd")
	for word in ["allocated", "equipment", "\"agi\"", "\"int\"", "merc_stats"]:
		_check(not save_code.contains(word), "save_store.gd saves no %s" % word)
	var stats_code := FileAccess.get_file_as_string("res://scripts/character_stats.gd") + FileAccess.get_file_as_string("res://scripts/character_config.gd")
	# S03 brought Level growth into the stats model ("level" left this list).
	for word in ["exp", "merc_c", "hospital", "crit", "dodge"]:
		_check(not stats_code.to_lower().contains(word), "Stats code has no %s (out of S01 scope)" % word)
	_check(CharacterConfig.PROTOTYPE_CHARACTERS == ["hero", "merc_a", "merc_b"] and CharacterConfig.BASE.size() == 3, "Exactly the three fixed characters")
	_sections_done.append("static")


# The game: the Hero's stats are the backpack's, battles use the party's stats.
func _verify_in_game() -> void:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = ""
	main.time_source = TimeSource.fixed(1800000000000)
	root.add_child(main)
	await process_frame
	var party: Dictionary = main.get_party_stats()
	_check(party["hero"] == main.character_stats and party["hero"] == main.inventory.get_stats(), "Hero stats = the backpack's stats (one source)")
	_check(party["merc_a"].character_id == "merc_a" and party["merc_b"].character_id == "merc_b" and party["merc_a"] != party["merc_b"], "Merc A / Merc B stats held for battles")
	_check(main.inventory.get_max_capacity() == 100 and main.character_stats.get_strength() == 10, "Game default: Hero Effective STR 10, Capacity 100")
	_check(party.values().all(func(s: CharacterStats) -> bool: return CharacterConfig.STATS.all(func(stat: String) -> bool: return s.get_allocated(stat) == 0 and s.get_equipment_bonus(stat) == 0)), "In the game every Allocated / Equipment value is 0")
	# A real encounter's battle is built from the game's party stats (a test-only
	# hook bonus makes it visible; the game itself never sets one).
	for frame in range(4):
		await physics_frame
	(main.get_node("Actors/Player") as Player).global_position = Vector2(950.0, 1080.0)
	for frame in range(4):
		await physics_frame
	await process_frame
	main.character_stats.set_equipment_bonus("hp", 25)
	(party["merc_b"] as CharacterStats).set_equipment_bonus("mp", 10)
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	var battle: CombatBattle = main.get_combat()
	_check(battle != null and battle.get_hero().max_hp == 325 and battle.get_friends()[2].max_mp == 110 and battle.get_friends()[1].max_hp == 200, "The game's battle reads the party's CharacterStats (Hero = backpack stats)")
	main.free()
	_sections_done.append("in_game")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
