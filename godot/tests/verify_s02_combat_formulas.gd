extends SceneTree

## Stage 7 S02: Combat Formula Integration. Effective STR / AGI / INT (Base +
## Growth + Allocated + Equipment) -> derived stats -> real friendly combat:
## Basic Attack damage, Physical Defense, Attack Interval (>= 300 ms), Move
## Speed (<= 7.0), Magic Attack (AoE, Lightning), Max MP, Magic Defense.
## Slow and Guard unchanged; enemies unchanged; Save v9 unchanged.

var _checks := 0
var _failures := 0
var _sections_done := []
var _hits := []


func _initialize() -> void:
	_verify_growth_layer()
	_verify_rounding()
	_verify_strength()
	_verify_agility()
	_verify_intelligence()
	_verify_skills()
	_verify_equipment_and_baseline()
	_verify_save()
	_check(_sections_done.size() == 8, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("S02 combat formulas verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Growth layer (S02 prerequisite correction) -------------------------------

func _verify_growth_layer() -> void:
	var stats := CharacterStats.for_character("hero")
	_check(CharacterConfig.STATS.all(func(s: String) -> bool: return stats.get_growth(s) == 0), "Growth defaults to 0 for every stat")
	_check(stats.set_growth("str", 1) and stats.set_allocated("str", 2) and stats.set_equipment_bonus("str", 3), "Growth / Allocated / Equipment hooks accept values")
	_check(stats.get_base("str") == 10 and stats.get_growth("str") == 1 and stats.get_allocated("str") == 2 and stats.get_equipment_bonus("str") == 3, "Each layer reads back on its own")
	_check(stats.get_effective("str") == 16, "Effective = Base 10 + Growth 1 + Allocated 2 + Equipment 3 = 16 (each once)")
	_check(stats.get_physical_attack() == 20 + 6 and stats.get_max_capacity() == 10 + 16 * 9, "Derived stats read Effective once (no double count)")
	_check(stats.set_growth("mp", 20) and stats.get_max_mp() == 220, "Growth may add MP (not player-allocatable, but growth can)")
	_check(not stats.set_growth("luck", 1) and not stats.set_growth("str", -1) and not stats.set_growth("str", 1.5) and stats.get_growth("str") == 1, "Invalid growth refused")
	var other := CharacterStats.for_character("hero")
	_check(other.get_growth("str") == 0 and other.get_effective("str") == 10, "Growth is per instance (no shared state)")
	_sections_done.append("growth")


# --- Rounding (all in CharacterStats) ------------------------------------------

func _verify_rounding() -> void:
	_check([0, 1, 2, 3, 4, 5, 9, 10].map(func(p: int) -> int: return CharacterStats.defense_for(p)) == [0, 0, 1, 1, 2, 2, 4, 5], "Defense = floor(points x 0.5)")
	_check(CharacterStats.defense_for(-3) == 0, "No negative defense")
	_check(CharacterStats.mitigate(20, 5) == 15 and CharacterStats.mitigate(4, 5) == 1 and CharacterStats.mitigate(4, 4) == 1 and CharacterStats.mitigate(1, 0) == 1, "Damage taken = max(1, incoming - defense)")
	_check(CharacterStats.mitigate(0, 0) == 0 and CharacterStats.mitigate(0, 3) == 0, "A non-damaging hit stays 0 (min 1 only for damaging hits)")
	_check(CharacterStats.gesture_damage(15, 50) == 57 and CharacterStats.gesture_damage(15, 120) == 138, "Lightning damage rounded down ((100 + 15) x 50% = 57)")
	_check(CharacterStats.attack_interval_for(1200, 10) == 960 and CharacterStats.attack_interval_for(1000, 30) == 618, "Attack Interval rounded to the nearest ms")
	_sections_done.append("rounding")


# --- STR ---------------------------------------------------------------------

func _verify_strength() -> void:
	var hero := CharacterStats.for_character("hero")
	_check(hero.get_physical_attack() == 20 and CharacterStats.for_character("merc_a").get_physical_attack() == 15 and CharacterStats.for_character("merc_b").get_physical_attack() == 12, "STR 10: Physical Attack 20 / 15 / 12")
	hero.set_allocated("str", 5)
	_check(hero.get_physical_attack() == 25, "Hero STR 15 -> 25")
	hero.set_allocated("str", 10)
	_check(hero.get_physical_attack() == 30, "Hero STR 20 -> 30 (the STR 10 baseline not double-counted)")
	_check(CharacterStats.for_character("hero").get_physical_defense() == 0, "STR 10: Physical Defense 0")
	_check(hero.get_physical_defense() == 5, "STR 20: Physical Defense 5")
	# Actual Basic Attack damage.
	var base_hit := _first_basic_hit("hero", null)
	var strong := CharacterStats.for_character("hero")
	strong.set_equipment_bonus("str", 5)
	var strong_hit := _first_basic_hit("hero", strong)
	_check(base_hit == 20 and strong_hit == 25, "Actual Basic Attack damage 20 -> 25 with Effective STR 15 (%d / %d)" % [base_hit, strong_hit])
	# Actual incoming physical damage (an enemy hits for 4).
	_check(_first_enemy_hit(null) == 4, "STR 10: an enemy hit deals 4")
	var tough := CharacterStats.for_character("hero")
	tough.set_allocated("str", 4)
	_check(_first_enemy_hit(tough) == 2, "STR 14 (defense 2): the enemy hit deals 2")
	tough.set_allocated("str", 30)
	_check(_first_enemy_hit(tough) == 1, "STR 40 (defense 15): a 4-damage hit still deals 1 (minimum)")
	_sections_done.append("strength")


## The first Basic Attack damage `id` deals to an adjacent 1000 HP enemy.
func _first_basic_hit(id: String, stats: CharacterStats) -> int:
	var party := {} if stats == null else {id: stats}
	var battle := CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE, party)
	battle.advance(CombatConfig.PREPARATION_MS)
	var friend := battle.get_hero() if id == "hero" else battle.get_friends()[1 if id == "merc_a" else 2]
	var enemy := battle.get_enemies()[0]
	enemy.max_hp = 1000
	enemy.hp = 1000
	enemy.attack_damage = 0
	_place(enemy, friend.cell + Vector2i(1, 0))
	battle.select_unit(friend)
	battle.command_target(enemy)
	_hits.clear()
	battle.damage_dealt.connect(_on_damage)
	for step in range(200):
		battle.advance(25)
		for hit in _hits:
			if hit[0] == friend:
				return hit[2]
	return -1


## The first damage the Hero takes from an adjacent enemy (attack 4).
func _first_enemy_hit(stats: CharacterStats) -> int:
	var battle := CombatBattle.create(1, CombatBattle.PartyFixture.HERO_ONLY, {} if stats == null else {"hero": stats})
	battle.advance(CombatConfig.PREPARATION_MS)
	var hero := battle.get_hero()
	var enemy := battle.get_enemies()[0]
	enemy.max_hp = 1000
	enemy.hp = 1000
	_place(enemy, hero.cell + Vector2i(1, 0))
	_hits.clear()
	battle.damage_dealt.connect(_on_damage)
	for step in range(400):
		battle.advance(25)
		for hit in _hits:
			if hit[1] == hero:
				return hit[2]
	return -1


# --- AGI ---------------------------------------------------------------------

func _verify_agility() -> void:
	var intervals := {}
	for agi in [10, 20, 30, 40, 60, 100, 1000, 1000000]:
		intervals[agi] = CharacterStats.attack_interval_for(1000, agi - 10)
	_check(intervals[10] == 1000 and CharacterStats.attack_interval_for(1200, 0) == 1200, "AGI 10 keeps each base interval (1000 / Merc B 1200)")
	_check(intervals[20] == 800 and intervals[40] >= 600 and intervals[40] <= 680 and intervals[100] >= 420 and intervals[100] <= 480, "Targets: AGI 20 0.80 s, 40 ~0.65 s, 100 ~0.45 s (%s)" % str(intervals))
	_check(intervals[20] < intervals[10] and intervals[30] < intervals[20] and intervals[100] < intervals[60], "Higher AGI -> shorter interval")
	_check(intervals[10] - intervals[20] > intervals[20] - intervals[30] and intervals[20] - intervals[30] > intervals[30] - intervals[40], "Diminishing returns (each +10 AGI saves less)")
	_check(intervals[1000] >= 300 and intervals[1000000] == 300 and CharacterStats.attack_interval_for(1200, 1000000) >= 300 and CharacterStats.attack_interval_for(500, 1000000) == 300 and CharacterStats.attack_interval_for(400, 100) == 300, "Extreme AGI never below 0.30 s (even for a short base interval)")
	var speeds := {}
	for agi in [10, 20, 30, 40, 100, 460, 1000000]:
		speeds[agi] = CharacterStats.move_speed_for(4.0, agi - 10)
	_check(speeds[10] == 4.0, "AGI 10 keeps Move Speed 4.0")
	_check(is_equal_approx(speeds[20], 4.8) and is_equal_approx(speeds[40], 5.6) and speeds[100] >= 6.3 and speeds[100] <= 6.6, "Targets: AGI 20 4.8, 40 5.6, 100 ~6.5 (%s)" % str(speeds))
	_check(speeds[20] > speeds[10] and speeds[30] - speeds[20] < speeds[20] - speeds[10] and speeds[40] - speeds[30] < speeds[30] - speeds[20], "Higher AGI -> faster, diminishing returns")
	_check(speeds[460] == 7.0 and speeds[1000000] == 7.0 and CharacterStats.move_speed_for(9.0, 0) == 7.0, "Never above the 7.0 cap")
	# Actual combat: the unit's interval and walking pace.
	var quick := CharacterStats.for_character("hero")
	quick.set_allocated("agi", 10)
	var battle := CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE, {"hero": quick})
	var hero := battle.get_hero()
	_check(hero.attack_interval_ms == 800 and is_equal_approx(hero.move_speed, 4.8) and battle.get_friends()[1].attack_interval_ms == 1000, "A battle uses the AGI-derived interval / speed (others unchanged)")
	battle.advance(CombatConfig.PREPARATION_MS)
	var enemy := battle.get_enemies()[0]
	enemy.max_hp = 100000
	enemy.hp = 100000
	enemy.attack_damage = 0
	_place(enemy, hero.cell + Vector2i(1, 0))
	battle.select_unit(hero)
	battle.command_target(enemy)
	var times := []
	_hits.clear()
	battle.damage_dealt.connect(_on_damage)
	for step in range(400):
		battle.advance(25)
		for hit in _hits:
			if hit[0] == hero:
				times.append(battle.get_elapsed_ms())
		_hits.clear()
		if times.size() >= 3:
			break
	_check(times.size() == 3 and times[1] - times[0] == 800 and times[2] - times[1] == 800, "Actual Basic Attacks every 0.80 s at AGI 20 (%s)" % str(times))
	_check(_cells_walked(null) < _cells_walked(quick), "Actual walking: AGI 20 covers more cells in the same time")
	_sections_done.append("agility")


## Columns the Hero walks in 3 s towards a far goal.
func _cells_walked(stats: CharacterStats) -> int:
	var battle := CombatBattle.create(1, CombatBattle.PartyFixture.HERO_ONLY, {} if stats == null else {"hero": stats})
	battle.advance(CombatConfig.PREPARATION_MS)
	var hero := battle.get_hero()
	var start := hero.cell.x
	battle.select_unit(hero)
	battle.command_move(Vector2i(40, hero.cell.y))
	for step in range(120):
		battle.advance(25)
	return hero.cell.x - start


# --- INT ---------------------------------------------------------------------

func _verify_intelligence() -> void:
	var mage := CharacterStats.for_character("merc_b")
	_check(mage.get_magic_attack() == 0 and mage.get_magic_defense() == 0 and mage.get_max_mp() == 100, "INT 10: Magic Attack 0, Magic Defense 0, Max MP 100")
	var magic := []
	for points in [5, 10, 20]:
		mage.set_allocated("int", points)
		magic.append([mage.get_magic_attack(), mage.get_max_mp(), mage.get_magic_defense()])
	_check(magic == [[10, 125, 2], [20, 150, 5], [40, 200, 10]], "INT 15 / 20 / 30: Magic Attack 10 / 20 / 40, Max MP 125 / 150 / 200, Magic Defense 2 / 5 / 10 (%s)" % str(magic))
	_check(CharacterStats.for_character("hero").get_max_mp() == 200 and CharacterStats.for_character("merc_a").get_max_mp() == 100, "INT 10 Max MP: Hero 200, Merc A 100")
	_check(not mage.set_allocated("mp", 5), "MP still not player-allocatable")
	mage.set_allocated("int", 10)
	var battle := CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE, {"merc_b": mage})
	var unit := battle.get_friends()[2]
	_check(unit.max_mp == 150 and unit.mp == 150 and unit.magic_attack == 20 and unit.magic_defense == 5, "A battle starts Merc B INT 20 with 150 / 150 MP, Magic Attack 20, Magic Defense 5")
	# Magic Defense: the MAGIC damage path uses it (no enemy deals magic damage yet).
	battle.advance(CombatConfig.PREPARATION_MS)
	var enemy := battle.get_enemies()[0]
	_check(battle.resolve_damage(enemy, unit, 12, CombatBattle.DamageKind.MAGIC) == 7 and battle.resolve_damage(enemy, unit, 12) == 12, "MAGIC damage meets Magic Defense (12 -> 7); PHYSICAL meets Physical Defense (0)")
	_sections_done.append("intelligence")


# --- Skills ------------------------------------------------------------------

func _verify_skills() -> void:
	_check(_aoe_damage(null) == 40, "AoE at INT 10: 40")
	var mage := CharacterStats.for_character("merc_b")
	mage.set_equipment_bonus("int", 10)
	_check(_aoe_damage(mage) == 60, "AoE at INT 20: 40 + 20 = 60")
	# Lightning, every grade.
	var bands := {}
	for magic_points in [0, 10]:
		var hero := CharacterStats.for_character("hero")
		hero.set_allocated("int", magic_points)
		var row := []
		for grade in [GestureMatcher.Grade.PERFECT, GestureMatcher.Grade.SUCCESS, GestureMatcher.Grade.PARTIAL, GestureMatcher.Grade.FAIL]:
			row.append(_lightning(hero, grade))
		bands[magic_points] = row
	_check(bands[0] == [120, 100, 50, 0], "Lightning at Magic Attack 0: 120 / 100 / 50 / 0 (%s)" % str(bands[0]))
	_check(bands[10] == [144, 120, 60, 0], "Lightning at Magic Attack 20: 144 / 120 / 60 / 0 (%s)" % str(bands[10]))
	_check(CombatConfig.GESTURE_MP_COST == 50 and CombatConfig.GESTURE_FAIL_MP_COST == 25 and CombatConfig.GESTURE_MAX_TARGETS == 10 and CombatConfig.GESTURE_DAMAGE_PERCENT == [120, 100, 50, 0], "Gesture cost / targets / grade multipliers unchanged")
	# Slow unchanged (no stat scaling).
	var slow_results := []
	for int_points in [0, 50]:
		var hero := CharacterStats.for_character("hero")
		hero.set_allocated("int", int_points)
		hero.set_allocated("str", int_points)
		var battle := CombatBattle.create(1, CombatBattle.PartyFixture.HERO_ONLY, {"hero": hero})
		battle.advance(CombatConfig.PREPARATION_MS)
		var enemy := battle.get_enemies()[0]
		enemy.max_hp = 1000
		enemy.hp = 1000
		enemy.attack_damage = 0
		_place(enemy, battle.get_hero().cell + Vector2i(2, 0))
		battle.select_unit(battle.get_hero())
		battle.command_skill(enemy)
		for step in range(200):
			battle.advance(25)
			if battle.get_slow_remaining(enemy) > 0:
				break
		slow_results.append([battle.get_slow_remaining(enemy), enemy.hp])
	_check(slow_results[0] == slow_results[1] and slow_results[0][0] == CombatConfig.SKILL_EFFECT_MS and slow_results[0][1] == 1000, "Slow identical at INT / STR 10 and 60; it deals no damage (%s)" % str(slow_results))
	_check(CombatConfig.SLOW_FACTOR == 2 and CombatConfig.SKILL_EFFECT_MS == 5000, "Slow factor / duration unchanged")
	# Guard unchanged: 50% of the hit after defense.
	var guarded := []
	for points in [0, 50]:
		var merc := CharacterStats.for_character("merc_a")
		merc.set_allocated("int", points)
		merc.set_allocated("agi", points)
		var battle := CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE, {"merc_a": merc})
		battle.advance(CombatConfig.PREPARATION_MS)
		var unit := battle.get_friends()[1]
		battle.select_unit(unit)
		battle.command_skill()
		for step in range(CombatConfig.SKILL_CAST_MS / 25 + 2):
			battle.advance(25)
		guarded.append(battle.resolve_damage(battle.get_enemies()[0], unit, 40))
	_check(guarded == [20, 20] and CombatConfig.GUARD_DIVISOR == 2, "Guard halves a 40 hit to 20 at INT / AGI 10 and 60 (%s)" % str(guarded))
	_sections_done.append("skills")


## Damage the Merc B AoE deals to one enemy.
func _aoe_damage(stats: CharacterStats) -> int:
	var battle := CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE, {} if stats == null else {"merc_b": stats})
	battle.advance(CombatConfig.PREPARATION_MS)
	var mage := battle.get_friends()[2]
	var enemy := battle.get_enemies()[0]
	enemy.max_hp = 1000
	enemy.hp = 1000
	enemy.attack_damage = 0
	enemy.move_speed = 0.001
	# MAGIC damage ignores Physical Defense (test-only defense on the enemy).
	enemy.physical_defense = 15
	_place(enemy, mage.cell + Vector2i(2, 0))
	battle.select_unit(mage)
	battle.command_skill(enemy)
	for step in range(200):
		battle.advance(25)
		if not battle.get_last_aoe().is_empty():
			break
	_check(int(battle.get_last_aoe().get("damage", -1)) == 1000 - enemy.hp, "The AoE mark shows the damage dealt")
	return 1000 - enemy.hp


## Damage the Lightning of `grade` deals to each target.
func _lightning(stats: CharacterStats, grade: GestureMatcher.Grade) -> int:
	var battle := CombatBattle.create(10, CombatBattle.PartyFixture.HERO_ONLY, {"hero": stats})
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		enemy.max_hp = 1000
		enemy.hp = 1000
	battle.gesture_rng.seed = 7
	battle.open_gesture()
	var result: Dictionary = battle._resolve_gesture(grade, 100, false)
	var lost := []
	for enemy in result["targets"]:
		lost.append(1000 - (enemy as CombatUnit).hp)
	if grade != GestureMatcher.Grade.FAIL:
		_check(not lost.is_empty() and lost.all(func(d: int) -> bool: return d == result["damage"]), "Every Lightning target takes the grade's damage")
	return int(result["damage"])


# --- Equipment hook and baseline ----------------------------------------------

func _verify_equipment_and_baseline() -> void:
	var gear := CharacterStats.for_character("hero")
	gear.set_equipment_bonus("str", 6)
	gear.set_equipment_bonus("agi", 10)
	gear.set_equipment_bonus("int", 10)
	var unit := CombatBattle.create(1, CombatBattle.PartyFixture.PROTOTYPE, {"hero": gear}).get_hero()
	_check(unit.attack_damage == 26 and unit.physical_defense == 3 and unit.attack_interval_ms == 800 and is_equal_approx(unit.move_speed, 4.8) and unit.magic_attack == 20 and unit.max_mp == 250 and unit.magic_defense == 5, "Equipment STR / AGI / INT flow into every derived combat value")
	_check(gear.get_max_capacity() == 10 + 16 * 9, "Equipment STR also raises Capacity")
	var expected := {
		"hero": [300, 200, 20, 1, 1000, 4.0, 0, 0, 0],
		"merc_a": [200, 100, 15, 1, 1000, 4.0, 0, 0, 0],
		"merc_b": [150, 100, 12, 3, 1200, 4.0, 0, 0, 0],
	}
	for friend in CombatBattle.create(10).get_friends():
		var want: Array = expected[friend.id]
		_check([friend.max_hp, friend.max_mp, friend.attack_damage, friend.attack_range, friend.attack_interval_ms, friend.move_speed, friend.magic_attack, friend.physical_defense, friend.magic_defense] == want, "Baseline %s unchanged %s" % [friend.id, str(want)])
	var enemy := CombatBattle.create(10).get_enemies()[0]
	_check(enemy.max_hp == 40 and enemy.attack_damage == 4 and enemy.attack_interval_ms == 1500 and enemy.move_speed == 2.0 and enemy.physical_defense == 0 and enemy.magic_attack == 0, "Enemies unchanged (no stats, no defense)")
	_sections_done.append("equipment_baseline")


# --- Save v9 -----------------------------------------------------------------

func _verify_save() -> void:
	var stats := CharacterStats.new(12)
	stats.set_growth("str", 3)
	stats.set_allocated("int", 4)
	stats.set_equipment_bonus("agi", 5)
	var data := SaveStore.serialize(Wallet.new(), CharacterInventory.new("player", stats), MarketState.create_default())
	_check(SaveStore.VERSION == 14 and data["version"] == 14, "Save v13 (Stage 9 P01) (S05 adds only the allocation)")
	_check(data["character"]["stats"] == {"strength": 12} and SaveStore.STATS_KEYS == ["strength"], "Saved stats exactly {strength: Base STR}: no growth / allocation / equipment")
	var keys := data.keys()
	keys.sort()
	# S05 added the allocation section (point counts only; v10); P01.5 the
	# Mercenary roster (v11); Stage 10 P00 the condition (v14).
	_check(keys == ["allocation", "carrying", "character", "condition", "cost_ledger", "location", "market", "market_recovery", "mercenaries", "money", "pending_legacy_mercenaries", "progression", "version", "warehouses"], "Save payload top-level keys: S02 added none; S05 added only allocation, P01.5 only mercenaries, P05 only pending_legacy_mercenaries, Stage 9 P01 only carrying, Stage 10 P00 only condition (%s)" % str(keys))
	_check((data["character"] as Dictionary).keys() == ["id", "stats", "inventory"], "Saved character keys unchanged")
	_sections_done.append("save")


func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


func _on_damage(attacker: CombatUnit, target: CombatUnit, amount: int) -> void:
	_hits.append([attacker, target, amount])


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
