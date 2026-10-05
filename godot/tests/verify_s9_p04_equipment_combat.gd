extends SceneTree

## Stage 9 P04: Equipment Stats -> Combat Integration.
## The chain under test: EquipmentCatalog -> CharacterCarrying ->
## CharacterStats -> get_combat_profile() -> CombatUnit -> the existing
## Combat damage / Skill paths (resolve_damage + CharacterStats.mitigate, the
## Gesture, the Mage AoE). Every core case runs a real CombatBattle and reads
## the damage actually dealt.
##   hero         STR / INT weapon, Physical / Magic Defense armor: units,
##                real Basic Attack, real Gesture, real incoming hits
##   mercenary    the same through a deployed Mercenary (Stage 9 P04 fix:
##                its authoritative CharacterCarrying stats), Mage AoE
##   identity     two same-type Mercenaries with different gear; no leak,
##                no double count, no Hero fallback
##   lifecycle    equip -> next battle, unequip -> next battle, save ->
##                reload -> battle, battle never changes equipment, no
##                equipment change mid-battle (the real game)
##   baseline     no equipment: units identical to the Stage 8 path
##   scope        Save v13, no new formula in Combat
##   stress       TARGETED: repeated battles over random gear / ids

const TEST_SAVE := "user://s9_p04_combat_test.json"
const T0 := 1800000000000
const W1 := "test_weapon_01"
const W2 := "test_weapon_02"
const A1 := "test_armor_01"
const A2 := "test_armor_02"
const ALL := [W1, W2, A1, A2]
const PASSIVE_ONLY := Vector2(950.0, 1080.0)

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_verify_hero()
	_verify_mercenary()
	_verify_identity()
	_verify_baseline()
	await _verify_lifecycle()
	_verify_scope()
	await _verify_stress()
	_check(_sections_done.size() == 7, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S9 P04 equipment combat verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Hero -------------------------------------------------------------------------------------------------

func _verify_hero() -> void:
	var plain := _party([])
	var geared := _party([])
	var c: CharacterCarrying = geared["carrying"]
	c.add_equipment("hero", W1, 1)
	EquipmentService.equip(c, "hero", W1)
	var base_unit := _battle(plain).get_hero()
	var unit := _battle(geared).get_hero()
	_check(base_unit.attack_damage == 20 and unit.attack_damage == 22 and unit.attack_damage == (geared["stats"] as CharacterStats).get_physical_attack(), "AC01 / AC02 Hero STR +2: CombatUnit Physical Attack 20 -> 22 (= CharacterStats)")
	_check(unit.physical_defense == 1 and base_unit.physical_defense == 0, "AC02 STR also raises Physical Defense through the existing formula (0 -> 1)")
	_check(_hit_by_hero(_battle(plain)) == 20 and _hit_by_hero(_battle(geared)) == 22, "AC03 Real Basic Attack: 20 -> 22 damage dealt")
	# INT weapon: Magic Attack and the Gesture (existing magic path).
	var magic := _party([])
	var mc: CharacterCarrying = magic["carrying"]
	mc.add_equipment("hero", W2, 1)
	EquipmentService.equip(mc, "hero", W2)
	var magic_unit := _battle(magic).get_hero()
	_check(magic_unit.magic_attack == 4 and base_unit.magic_attack == 0 and magic_unit.max_mp == base_unit.max_mp + 10, "AC04 Hero INT +2: CombatUnit Magic Attack 0 -> 4, Max MP +10")
	var plain_gesture := _gesture_damage(_battle(plain))
	var magic_gesture := _gesture_damage(_battle(magic))
	_check(plain_gesture == CharacterStats.gesture_damage(0, 120) and magic_gesture == CharacterStats.gesture_damage(4, 120) and magic_gesture == plain_gesture + 4 * 120 / 100, "AC05 Real Gesture (Perfect) on tough enemies: %d -> %d damage" % [plain_gesture, magic_gesture])
	# Physical Defense armor: a real enemy Basic Attack.
	var armored := _party([])
	var ac: CharacterCarrying = armored["carrying"]
	ac.add_equipment("hero", A1, 1)
	EquipmentService.equip(ac, "hero", A1)
	var armored_unit := _battle(armored).get_hero()
	_check(armored_unit.physical_defense == 2 and armored_unit.attack_damage == 20, "AC06 Hero 測試防具一: CombatUnit Physical Defense 0 -> 2, attack unchanged")
	_check(_hit_on_hero(_battle(plain)) == 4 and _hit_on_hero(_battle(armored)) == 2, "AC07 Real enemy Basic Attack (4): 4 -> 2 taken (CharacterStats.mitigate)")
	# Magic Defense armor: an incoming MAGIC hit through the damage path.
	var warded := _party([])
	var wc: CharacterCarrying = warded["carrying"]
	wc.add_equipment("hero", A2, 1)
	EquipmentService.equip(wc, "hero", A2)
	var warded_unit := _battle(warded).get_hero()
	_check(warded_unit.magic_defense == 2 and warded_unit.physical_defense == 0, "AC08 Hero 測試防具二: CombatUnit Magic Defense 0 -> 2 only")
	_check(_magic_hit_on(_battle(plain), "hero", 10) == 10 and _magic_hit_on(_battle(warded), "hero", 10) == 8 and _physical_hit_on(_battle(warded), "hero", 10) == 10, "AC09 Incoming MAGIC 10: 10 -> 8; PHYSICAL 10 still 10")
	# Weapon + armor together: each once.
	var both := _party([])
	var bc: CharacterCarrying = both["carrying"]
	bc.add_equipment("hero", W1, 1)
	bc.add_equipment("hero", A1, 1)
	EquipmentService.equip(bc, "hero", W1)
	EquipmentService.equip(bc, "hero", A1)
	var both_unit := _battle(both).get_hero()
	_check(both_unit.attack_damage == 22 and both_unit.physical_defense == 3 and _hit_on_hero(_battle(both)) == 1, "AC15 STR weapon + armor: attack 22, defense 1 + 2 = 3, a 4 hit -> 1 (each bonus once)")
	_sections_done.append("hero")


# --- Mercenary --------------------------------------------------------------------------------------------

func _verify_mercenary() -> void:
	var plain := _party(["MAGE"])
	var geared := _party(["MAGE"])
	var c: CharacterCarrying = geared["carrying"]
	for item_id in [W1, A1]:
		c.add_equipment("merc_1", item_id, 1)
		EquipmentService.equip(c, "merc_1", item_id)
	var base_unit := _friend(_battle(plain), "merc_1")
	var unit := _friend(_battle(geared), "merc_1")
	var stats := c.get_stats("merc_1")
	_check(unit.attack_damage == base_unit.attack_damage + 2 and unit.attack_damage == stats.get_physical_attack(), "AC10 Deployed 法師 merc_1: Physical Attack +2 reaches its own unit (%d -> %d)" % [base_unit.attack_damage, unit.attack_damage])
	_check(unit.physical_defense == base_unit.physical_defense + 1 + 2 and unit.physical_defense == stats.get_physical_defense(), "AC10 Physical Defense from STR (+1) and armor (+2)")
	_check(_combat_profile(unit) == _profile_of(stats), "AC10 The whole unit profile = its authoritative CharacterCarrying stats")
	_check(_physical_hit_on(_battle(plain), "merc_1", 10) == 10 - base_unit.physical_defense and _physical_hit_on(_battle(geared), "merc_1", 10) == 10 - unit.physical_defense, "AC12 Real incoming PHYSICAL 10 on merc_1: %d -> %d" % [10 - base_unit.physical_defense, 10 - unit.physical_defense])
	_check(_hit_by(_battle(geared), "merc_1") == unit.attack_damage and _hit_by(_battle(plain), "merc_1") == base_unit.attack_damage, "AC11 Real Basic Attack by merc_1: %d -> %d" % [base_unit.attack_damage, unit.attack_damage])
	# INT weapon on a Mage: Magic Attack and the real AoE.
	var caster := _party(["MAGE"])
	var cc: CharacterCarrying = caster["carrying"]
	cc.add_equipment("merc_1", W2, 1)
	EquipmentService.equip(cc, "merc_1", W2)
	var caster_unit := _friend(_battle(caster), "merc_1")
	_check(caster_unit.magic_attack == base_unit.magic_attack + 4, "AC10 merc_1 INT +2: Magic Attack %d -> %d" % [base_unit.magic_attack, caster_unit.magic_attack])
	var plain_aoe := _aoe_damage(_battle(plain))
	var caster_aoe := _aoe_damage(_battle(caster))
	_check(plain_aoe == CombatConfig.AOE_DAMAGE + base_unit.magic_attack and caster_aoe == plain_aoe + 4, "AC11 Real Mage AoE (existing Skill): %d -> %d damage" % [plain_aoe, caster_aoe])
	# Magic Defense armor on a Mercenary.
	var warded := _party(["GUARDIAN"])
	var wc: CharacterCarrying = warded["carrying"]
	wc.add_equipment("merc_1", A2, 1)
	EquipmentService.equip(wc, "merc_1", A2)
	_check(_friend(_battle(warded), "merc_1").magic_defense == 2 and _magic_hit_on(_battle(warded), "merc_1", 10) == 8 and _magic_hit_on(_battle(_party(["GUARDIAN"])), "merc_1", 10) == 10, "AC12 merc_1 測試防具二: incoming MAGIC 10 -> 8")
	_sections_done.append("mercenary")


# --- Identity ---------------------------------------------------------------------------------------------

func _verify_identity() -> void:
	var party := _party(["GUARDIAN", "GUARDIAN", "MAGE"])
	var c: CharacterCarrying = party["carrying"]
	c.add_equipment("merc_1", W1, 1)
	EquipmentService.equip(c, "merc_1", W1)
	c.add_equipment("merc_2", A1, 1)
	EquipmentService.equip(c, "merc_2", A1)
	c.add_equipment("hero", A2, 1)
	EquipmentService.equip(c, "hero", A2)
	var battle := _battle(party)
	var one := _friend(battle, "merc_1")
	var two := _friend(battle, "merc_2")
	var three := _friend(battle, "merc_3")
	var hero := battle.get_hero()
	var plain_guardian := CharacterStats.for_mercenary(Mercenary.create("x", "GUARDIAN"))
	_check(one.attack_damage == plain_guardian.get_physical_attack() + 2 and two.attack_damage == plain_guardian.get_physical_attack(), "AC13 Same-type GUARDIANs: merc_1 (STR weapon) attacks for 2 more than merc_2")
	_check(two.physical_defense == plain_guardian.get_physical_defense() + 2 and one.physical_defense == plain_guardian.get_physical_defense() + 1, "AC13 merc_2 (armor) Physical Defense +2; merc_1 only its STR-derived +1")
	_check(_combat_profile(one) != _combat_profile(two) and _combat_profile(one) == _profile_of(c.get_stats("merc_1")) and _combat_profile(two) == _profile_of(c.get_stats("merc_2")), "AC13 Each GUARDIAN gets its own stable-id profile")
	_check(_combat_profile(three) == _profile_of(CharacterStats.for_mercenary((party["roster"] as MercenaryRoster).get_mercenary("merc_3"))), "AC14 merc_3 (no gear) gets nothing from the others")
	_check(hero.magic_defense == 2 and hero.attack_damage == 20 and hero.physical_defense == 0, "AC14 The Hero has only its own Magic Defense armor")
	_check(one.magic_defense == plain_guardian.get_magic_defense() and two.magic_defense == plain_guardian.get_magic_defense(), "AC14 No Mercenary got the Hero's Magic Defense")
	# A missing / wrong stats entry never falls back to another character.
	var roster: MercenaryRoster = party["roster"]
	_check(CombatBattle.create_party(10, party["stats"], roster.get_owned(), {"merc_1": null}) == null, "A null authoritative stats entry: no battle (never a silent fallback)")
	var swapped := CombatBattle.create_party(10, party["stats"], [roster.get_mercenary("merc_2"), roster.get_mercenary("merc_1")], _stats_of(party))
	_check(_combat_profile(_friend(swapped, "merc_1")) == _combat_profile(one) and _combat_profile(_friend(swapped, "merc_2")) == _combat_profile(two), "Deployment order changes nothing: profiles follow the id")
	_sections_done.append("identity")


# --- Baseline ---------------------------------------------------------------------------------------------

func _verify_baseline() -> void:
	for types in [[], ["GUARDIAN"], ["MAGE", "STRATEGIST"], ["GUARDIAN", "MAGE", "STRATEGIST"]]:
		var party := _party(types)
		var roster: MercenaryRoster = party["roster"]
		var with_carrying := _battle(party)
		var stage8 := CombatBattle.create_party(10, party["stats"], roster.get_deployed())
		var same := with_carrying.get_friends().size() == stage8.get_friends().size()
		for index in range(stage8.get_friends().size()):
			same = same and _combat_profile(with_carrying.get_friends()[index]) == _combat_profile(stage8.get_friends()[index]) and with_carrying.get_friends()[index].max_mp == stage8.get_friends()[index].max_mp
		_check(same, "AC20 No equipment, party %s: every unit identical to the Stage 8 path" % str(types))
	_sections_done.append("baseline")


# --- Lifecycle in the real game ---------------------------------------------------------------------------

func _verify_lifecycle() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "GUARDIAN")], ["merc_1", "merc_2"])
	var c: CharacterCarrying = main.carrying
	c.add_equipment("merc_1", W1, 1)
	c.add_equipment("merc_2", A1, 1)
	c.add_equipment("hero", W2, 1)
	_check(main.equip_character_item("merc_1", W1)["success"] and main.equip_character_item("merc_2", A1)["success"] and main.equip_character_item("hero", W2)["success"], "Equipped through the game (saved)")
	var battle: CombatBattle = await _start_battle(main)
	var plain_guardian := CharacterStats.for_mercenary(Mercenary.create("x", "GUARDIAN"))
	_check(battle != null and _friend(battle, "merc_1").attack_damage == plain_guardian.get_physical_attack() + 2 and _friend(battle, "merc_2").physical_defense == plain_guardian.get_physical_defense() + 2 and battle.get_hero().magic_attack == 4, "AC10 / AC13 The real game battle: merc_1 STR weapon, merc_2 armor, Hero INT weapon, each on its own unit")
	var gear := _gear_state(main)
	var state := _main_state(main)
	_check(not main.unequip_character_slot("merc_1", "WEAPON")["success"] and _main_state(main) == state, "AC19 Mid-battle: equipment cannot change")
	# The battle fights a while, then retreats (the groups stay in the world).
	await _end_battle(main, battle)
	_check(main.get_combat() == null and _gear_state(main) == gear, "AC18 After a fought / retreated battle: every character's equipment unchanged")
	# Unequip -> next battle without the bonus.
	_check(main.unequip_character_slot("merc_1", "WEAPON")["success"], "Unequip merc_1's weapon after the battle")
	battle = await _start_battle(main)
	var no_gear := CharacterStats.for_mercenary(main.mercenary_roster.get_mercenary("merc_1"))
	_check(battle != null and _combat_profile(_friend(battle, "merc_1")) == no_gear.get_combat_profile() and _friend(battle, "merc_1").attack_damage == plain_guardian.get_physical_attack(), "AC16 Unequipped: the next battle has merc_1 without any gear")
	_check(battle != null and _friend(battle, "merc_2").physical_defense == plain_guardian.get_physical_defense() + 2, "merc_2 keeps its armor in the next battle")
	await _end_battle(main, battle)
	# Equip -> save -> reload -> battle.
	_check(main.equip_character_item("merc_1", W1)["success"], "Re-equip merc_1 (saved)")
	var expected := {}
	for id in ["hero", "merc_1", "merc_2"]:
		expected[id] = _profile_of(main.carrying.get_stats(id))
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	battle = await _start_battle(main)
	var reloaded_ok := battle != null
	for id in ["hero", "merc_1", "merc_2"]:
		reloaded_ok = reloaded_ok and _combat_profile(_friend(battle, id)) == expected[id]
	_check(reloaded_ok, "AC17 Equip -> save -> restart -> battle: every unit has its equipped profile")
	# This one is won (Victory, EXP): still no equipment change.
	gear = _gear_state(main)
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.select_all()
	battle.attack_all()
	for step in range(100):
		battle.advance(50)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000000)
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY, "Victory")
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(main.get_combat() == null and _gear_state(main) == gear and main.carrying.get_equipment("merc_1").get_equipped("WEAPON") == W1, "AC18 After Victory and the EXP settlement: equipment unchanged")
	await _destroy(main)
	_clean()
	_sections_done.append("lifecycle")


func _verify_scope() -> void:
	_check(SaveStore.VERSION == 13 and SaveStore.V13_KEYS.size() == 13, "AC25 Save v13, no new section")
	var combat := ""
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_view.gd", "res://scripts/combat_config.gd"]:
		combat += _code_only(path).to_lower()
	for word in ["equipment", "carrying", "bonus", "equipmentcatalog", "get_effective(", "defense_for(", "_above_baseline"]:
		_check(not combat.contains(word), "Combat code computes no %s (one stat engine: CharacterStats)" % word)
	_check(_code_only("res://scripts/main.gd").contains("carrying.get_stats(mercenary.get_id())"), "main passes the authoritative CharacterCarrying stats into the battle")
	_sections_done.append("scope")


# --- Stress (TARGETED) ------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9044
	var mismatch := 0
	var leaked := 0
	var mutated := 0
	var reload := 0
	var battles := 0
	for run in range(60):
		var types := []
		for i in range(rng.randi_range(1, 3)):
			types.append(["GUARDIAN", "GUARDIAN", "MAGE", "STRATEGIST"][rng.randi_range(0, 3)])
		var party := _party(types)
		var c: CharacterCarrying = party["carrying"]
		var ids: Array = ["hero"] + (party["roster"] as MercenaryRoster).get_owned().map(func(m: Mercenary) -> String: return m.get_id())
		for id in ids:
			for item_id in ALL:
				c.add_equipment(id, item_id, rng.randi_range(0, 1))
		for round in range(12):
			var id: String = ids[rng.randi_range(0, ids.size() - 1)]
			if rng.randi_range(0, 2) == 0:
				EquipmentService.unequip(c, id, ["WEAPON", "ARMOR"][rng.randi_range(0, 1)])
			else:
				EquipmentService.equip(c, id, ALL[rng.randi_range(0, 3)])
			var before := _state(party)
			var battle := _battle(party)
			battles += 1
			for each in ids:
				var unit := _friend(battle, each)
				if unit == null or _combat_profile(unit) != _profile_of(c.get_stats(each)) or unit.max_mp != c.get_stats(each).get_max_mp():
					mismatch += 1
				# Leak / double count: the unit equals Base + Growth + Allocation + only its own gear.
				var own := CharacterStats.for_mercenary((party["roster"] as MercenaryRoster).get_mercenary(each)) if each != "hero" else CharacterStats.new()
				own.apply_equipment_bonuses(c.get_equipment(each).get_bonuses())
				if unit != null and _combat_profile(unit) != _profile_of(own):
					leaked += 1
			battle.advance(CombatConfig.PREPARATION_MS + rng.randi_range(0, 3000))
			if _state(party) != before:
				mutated += 1
			if round % 4 == 3:
				var reloaded := _load(_serialize(party))
				if reloaded.is_empty():
					reload += 1
					continue
				var next := {"carrying": reloaded["carrying"], "roster": reloaded["mercenaries"], "inventory": reloaded["inventory"], "stats": reloaded["character_stats"], "wallet": reloaded["wallet"]}
				var a := _battle(party)
				var b := _battle(next)
				for each in ids:
					if _combat_profile(_friend(a, each)) != _combat_profile(_friend(b, each)):
						reload += 1
				party = next
				c = party["carrying"]
	_check(battles == 720, "Stress: %d battles created over random gear" % battles)
	_check(mismatch == 0, "Stress: every unit = its authoritative stats (%d)" % mismatch)
	_check(leaked == 0, "Stress: no bonus leak / double count (unit = own Base..Allocation + own gear) (%d)" % leaked)
	_check(mutated == 0, "Stress: running a battle never changed equipment (%d)" % mutated)
	_check(reload == 0, "Stress: save / reload gives the same battle profiles (%d)" % reload)
	_sections_done.append("stress")


# --- Helpers ----------------------------------------------------------------------------------------------

func _party(types: Array) -> Dictionary:
	var stats := CharacterStats.new()
	var inventory := CharacterInventory.new("player", stats)
	var roster := MercenaryRoster.new()
	for type in types:
		roster.create_mercenary(type)
	var ids := []
	for m in roster.get_owned():
		ids.append(m.get_id())
	roster.set_deployment(ids)
	var carrying := CharacterCarrying.new(inventory, func() -> MercenaryRoster: return roster)
	return {"carrying": carrying, "roster": roster, "inventory": inventory, "stats": stats, "wallet": Wallet.new()}


## id -> authoritative stats of the deployed Mercenaries (what main passes).
func _stats_of(party: Dictionary) -> Dictionary:
	var result := {}
	for m in (party["roster"] as MercenaryRoster).get_deployed():
		result[m.get_id()] = (party["carrying"] as CharacterCarrying).get_stats(m.get_id())
	return result


## The game's battle construction for `party` (Hero stats + deployed with
## their CharacterCarrying stats).
func _battle(party: Dictionary) -> CombatBattle:
	return CombatBattle.create_party(10, party["stats"], (party["roster"] as MercenaryRoster).get_deployed(), _stats_of(party))


func _friend(battle: CombatBattle, id: String) -> CombatUnit:
	if battle == null:
		return null
	for unit in battle.get_friends():
		if unit.id == id:
			return unit
	return null


func _combat_profile(unit: CombatUnit) -> Dictionary:
	if unit == null:
		return {}
	return {"max_hp": unit.max_hp, "attack_damage": unit.attack_damage, "attack_range": unit.attack_range, "attack_interval_ms": unit.attack_interval_ms, "move_speed": unit.move_speed, "magic_attack": unit.magic_attack, "physical_defense": unit.physical_defense, "magic_defense": unit.magic_defense}


func _profile_of(stats: CharacterStats) -> Dictionary:
	return stats.get_combat_profile()


func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


## The damage one real Basic Attack by `id` deals to an adjacent tough enemy.
func _hit_by(battle: CombatBattle, id: String) -> int:
	battle.advance(CombatConfig.PREPARATION_MS)
	var attacker := _friend(battle, id)
	var enemy := battle.get_enemies()[0]
	enemy.max_hp = 100000
	enemy.hp = 100000
	enemy.attack_damage = 0
	_place(attacker, Vector2i(20, 2))
	_place(enemy, Vector2i(21, 2))
	for other in battle.get_enemies().slice(1):
		_place(other, Vector2i(55, other.cell.y))
	var hits := []
	battle.damage_dealt.connect(func(a: CombatUnit, t: CombatUnit, amount: int) -> void:
		if a == attacker:
			hits.append(amount))
	battle.select_unit(attacker)
	battle.command_target(enemy)
	attacker.attack_cooldown_ms = 0
	battle.advance(10)
	return hits[0] if hits.size() == 1 else -1


func _hit_by_hero(battle: CombatBattle) -> int:
	return _hit_by(battle, "hero")


## The damage one real enemy Basic Attack deals to the Hero.
func _hit_on_hero(battle: CombatBattle) -> int:
	battle.advance(CombatConfig.PREPARATION_MS)
	var hero := battle.get_hero()
	var enemy := battle.get_enemies()[0]
	_place(hero, Vector2i(20, 2))
	_place(enemy, Vector2i(21, 2))
	for other in battle.get_enemies().slice(1):
		_place(other, Vector2i(55, other.cell.y))
	var hits := []
	battle.damage_dealt.connect(func(a: CombatUnit, t: CombatUnit, amount: int) -> void:
		if t == hero:
			hits.append(amount))
	enemy.attack_cooldown_ms = 0
	battle.advance(10)
	return hits[0] if hits.size() == 1 else -1


## An incoming hit of `amount` on `id` through the battle's damage path.
func _magic_hit_on(battle: CombatBattle, id: String, amount: int) -> int:
	battle.advance(CombatConfig.PREPARATION_MS)
	return battle.resolve_damage(battle.get_enemies()[0], _friend(battle, id), amount, CombatBattle.DamageKind.MAGIC)


func _physical_hit_on(battle: CombatBattle, id: String, amount: int) -> int:
	battle.advance(CombatConfig.PREPARATION_MS)
	return battle.resolve_damage(battle.get_enemies()[0], _friend(battle, id), amount, CombatBattle.DamageKind.PHYSICAL)


## The damage a real Perfect Gesture deals to each (tough) enemy.
func _gesture_damage(battle: CombatBattle) -> int:
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		enemy.max_hp = 100000
		enemy.hp = 100000
	var hits := []
	battle.damage_dealt.connect(func(a: CombatUnit, t: CombatUnit, amount: int) -> void:
		if a == battle.get_hero():
			hits.append(amount))
	if not battle.open_gesture():
		return -1
	var result := battle.submit_gesture(_ideal())
	if result.get("grade") != GestureMatcher.Grade.PERFECT or hits.is_empty() or not hits.all(func(h: int) -> bool: return h == hits[0]):
		return -2
	return hits[0]


## The damage a real Mage AoE (merc_1) deals to a tough enemy on its cell.
func _aoe_damage(battle: CombatBattle) -> int:
	battle.advance(CombatConfig.PREPARATION_MS)
	var mage := _friend(battle, "merc_1")
	var enemy := battle.get_enemies()[0]
	enemy.max_hp = 100000
	enemy.hp = 100000
	enemy.move_speed = 0.001
	_place(mage, Vector2i(20, 2))
	_place(enemy, Vector2i(23, 2))
	for other in battle.get_enemies().slice(1):
		_place(other, Vector2i(55, other.cell.y))
		other.move_speed = 0.001
	var hits := []
	battle.damage_dealt.connect(func(a: CombatUnit, t: CombatUnit, amount: int) -> void:
		if a == mage and t == enemy:
			hits.append(amount))
	battle.select_unit(mage)
	if not battle.command_skill_at(enemy.cell):
		return -1
	for step in range(150):
		battle.advance(10)
		if not hits.is_empty():
			break
	return hits[0] if hits.size() == 1 else -2


func _ideal() -> PackedVector2Array:
	var points: Array = GestureMatcher.GUIDE
	var out := PackedVector2Array()
	for index in range(points.size() - 1):
		for k in range(10):
			out.append((points[index] as Vector2).lerp(points[index + 1], float(k) / 10))
	out.append(points[-1])
	return out


func _state(party: Dictionary) -> String:
	var carrying: CharacterCarrying = party["carrying"]
	var parts := [(party["roster"] as MercenaryRoster).to_dict()]
	var ids := ["hero"]
	for m in (party["roster"] as MercenaryRoster).get_owned():
		ids.append(m.get_id())
	for id in ids:
		parts.append([id, carrying.get_equipment(id).get_equipped_items(), carrying.get_equipment(id).get_carried(), carrying.get_stats(id).get_combat_profile()])
	return JSON.stringify(parts)


func _main_state(main: Node) -> String:
	return _state({"carrying": main.carrying, "roster": main.mercenary_roster})


func _start_battle(main: Node) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	return main.get_combat()


func _end_battle(main: Node, battle: CombatBattle) -> void:
	if battle == null:
		return
	battle.advance(CombatConfig.PREPARATION_MS + 2000)
	battle.start_retreat()
	for step in range(400):
		if battle.is_over():
			break
		battle.advance(50)
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	main.time_source.advance_ms(60000)
	await _settle()


## Every character's equipped / carried items only (stats may change with EXP).
func _gear_state(main: Node) -> String:
	var parts := []
	for id in ["hero"] + main.mercenary_roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id()):
		parts.append([id, main.carrying.get_equipment(id).get_equipped_items(), main.carrying.get_equipment(id).get_carried()])
	return JSON.stringify(parts)


func _serialize(party: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(SaveStore.serialize(party["wallet"], party["inventory"], MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.new(), {"hero": party["stats"]}, party["roster"], party["carrying"])))


func _load(data: Dictionary) -> Dictionary:
	var payload := SaveStore.validate(JSON.parse_string(JSON.stringify(data)))
	return {} if payload.is_empty() else SaveStore._rebuild(payload)


func _clean() -> void:
	for p in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


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
