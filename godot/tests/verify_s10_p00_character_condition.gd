extends SceneTree

## Stage 10 P00: Persistent Character Condition (Save v14 + Combat state).
##   model        CharacterCondition: actual values, the approved Max-change
##                clamp (30 / 100 -> 120 -> 30 / 120 ...), dead <=> HP 0,
##                stable ids, no record for pending / unknown ids
##   save         v14 shape, strict validation, v13 -> v14 migration (full /
##                alive at the effective maxima, nothing else changes),
##                save / reload exact (injured, dead)
##   battle       start from the persistent HP / MP; victory / defeat /
##                retreat write the participants back; dead Mercenaries never
##                fight and cannot be deployed; the Hero's death persists; no
##                living friend -> DEFEAT at once; non-participants and
##                same-type Mercenaries untouched; Level-up raises only Max
##   world        equipment / allocation never heal; no passive recovery
##                (movement, time, city, scene, reload); failed saves
##   scope        no Hospital, no penalty, formulas unchanged
##   stress       FULL: random battles / gear / deployment / saves / reloads /
##                save failures over several parties, plus v13 migrations

const TEST_SAVE := "user://s10_p00_condition_test.json"
const BAD_SAVE := "user://s10_p00_missing_dir/save.json"
const T0 := 1800000000000
const W1 := "test_weapon_01"
const W2 := "test_weapon_02"
const A1 := "test_armor_01"
const A2 := "test_armor_02"
const PASSIVE_ONLY := Vector2(950.0, 1080.0)

var _checks := 0
var _failures := 0
var _sections_done := []
## Stress seed (the runner may pass --seed=<n> after "--").
var _seed := 10000


## A carrying stand-in with fixed maxima (the exact WP numbers).
class FakeStats extends CharacterStats:
	var max_hp_value := 100
	var max_mp_value := 50

	func get_max_hp() -> int:
		return max_hp_value

	func get_max_mp() -> int:
		return max_mp_value


class FakeCarrying extends CharacterCarrying:
	var stats := {}
	var roster := MercenaryRoster.new()

	func is_character(id: Variant) -> bool:
		return typeof(id) == TYPE_STRING and stats.has(id)

	func get_stats(id: Variant) -> CharacterStats:
		return stats.get(id) if is_character(id) else null

	func get_roster() -> MercenaryRoster:
		return roster


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			_seed = int(arg.substr(7))
	_verify_model()
	_verify_save()
	await _verify_migration_game()
	await _verify_battle()
	await _verify_hero_death()
	await _verify_world()
	_verify_scope()
	await _verify_stress()
	_check(_sections_done.size() == 8, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S10 P00 character condition verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Model ------------------------------------------------------------------------------------------------

func _verify_model() -> void:
	var fake := FakeCarrying.new()
	var hero := FakeStats.new()
	fake.stats["hero"] = hero
	var c := CharacterCondition.new(func() -> CharacterCarrying: return fake)
	_check(c.sync() and c.get_condition("hero") == {"hp": 100, "mp": 50, "dead": false, "max_hp": 100, "max_mp": 50}, "A new character starts full / alive at its maxima")
	# 17I Max HP.
	c.set_condition("hero", 30, 50)
	hero.max_hp_value = 120
	c.sync()
	_check(c.get_hp("hero") == 30 and c.get_condition("hero")["max_hp"] == 120, "17I 30 / 100 -> Max 120 -> 30 / 120 (no scaling, no fill)")
	hero.max_hp_value = 100
	c.set_condition("hero", 100, 50)
	hero.max_hp_value = 120
	c.sync()
	_check(c.get_hp("hero") == 100, "17I 100 / 100 -> Max 120 -> 100 / 120")
	hero.max_hp_value = 80
	c.sync()
	_check(c.get_hp("hero") == 80, "17I 100 / 120 -> Max 80 -> 80 / 80")
	hero.max_hp_value = 120
	c.sync()
	_check(c.get_hp("hero") == 80, "17I ... and back to Max 120: still 80 (the clamp is permanent, no hidden heal)")
	# 17J Max MP.
	hero.max_mp_value = 100
	c.set_condition("hero", 80, 30)
	hero.max_mp_value = 120
	c.sync()
	_check(c.get_mp("hero") == 30, "17J MP 30 / 100 -> Max 120 -> 30 / 120")
	hero.max_mp_value = 100
	c.set_condition("hero", 80, 100)
	hero.max_mp_value = 120
	c.sync()
	_check(c.get_mp("hero") == 100, "17J MP 100 / 100 -> Max 120 -> 100 / 120")
	hero.max_mp_value = 80
	c.sync()
	_check(c.get_mp("hero") == 80, "17J MP 100 / 120 -> Max 80 -> 80 / 80")
	# get_condition also clamps (a read never shows more than Max).
	hero.max_hp_value = 50
	_check(c.get_condition("hero")["hp"] == 50 and c.get_hp("hero") == 50, "A read is clamped to the current Max")
	# Dead <=> HP 0; set_condition clamps to 0..Max.
	_check(c.set_condition("hero", 0, 7) and c.is_dead("hero") and c.get_mp("hero") == 7, "HP 0 = dead (MP kept)")
	_check(c.set_condition("hero", -5, -3) and c.get_hp("hero") == 0 and c.get_mp("hero") == 0 and c.is_dead("hero"), "Negative values are clamped to 0 (never a negative playable state)")
	_check(c.set_condition("hero", 999, 999) and c.get_hp("hero") == 50 and c.get_mp("hero") == 80 and not c.is_dead("hero"), "Above Max: clamped to Max")
	hero.max_hp_value = 120
	c.sync()
	_check(c.get_hp("hero") == 50, "No revival / refill by a later Max increase")
	# Identity: only characters, no fallback.
	var before := c.get_snapshot()
	_check(not c.set_condition("merc_9", 10, 10) and not c.set_condition("", 1, 1) and not c.set_condition(7, 1, 1) and not c.set_condition("hero", 1.5, 1) and c.get_snapshot() == before and c.get_condition("merc_9") == {}, "Unknown / invalid ids and non-integers refused, nothing changes, no Hero fallback")
	# Same-type Mercenaries by stable id (the real carrying).
	var party := _party(["GUARDIAN", "GUARDIAN", "MAGE"])
	var pc: CharacterCondition = party["condition"]
	pc.sync()
	var full_2 := pc.get_condition("merc_2")
	pc.set_condition("merc_1", 0, 3)
	_check(pc.is_dead("merc_1") and pc.get_condition("merc_2") == full_2 and not pc.is_dead("merc_2"), "17H Killing 守衛 #1 leaves 守衛 #2 (same type) untouched")
	(party["roster"] as MercenaryRoster).pend_legacy(Mercenary.create("merc_a", MercenaryRoster.LEGACY_TYPES["merc_a"]))
	pc.sync()
	_check(not pc.has_record("merc_a") and pc.get_condition("merc_a") == {} and not pc.set_condition("merc_a", 1, 1), "A pending legacy Mercenary has no condition")
	_check(pc.get_character_ids() == ["hero", "merc_1", "merc_2", "merc_3"], "Characters: the Hero, then the owned roster in order")
	_sections_done.append("model")


# --- Save -------------------------------------------------------------------------------------------------

func _verify_save() -> void:
	_check(SaveStore.VERSION == 14 and SaveStore.V14_KEYS == SaveStore.V13_KEYS + ["condition"] and SaveStore.INVENTORY_VERSIONS.back() == 14, "Save v14 = v13 + condition")
	var party := _party(["GUARDIAN", "MAGE"])
	var c: CharacterCondition = party["condition"]
	c.sync()
	c.set_condition("hero", 63, 8)
	c.set_condition("merc_1", 17, 4)
	c.set_condition("merc_2", 0, 11)
	var data := _serialize(party)
	_check(int(data["version"]) == 14 and data.keys().size() == 14 and data["condition"] == {"hero": {"hp": 63.0, "mp": 8.0, "dead": false}, "merc_1": {"hp": 17.0, "mp": 4.0, "dead": false}, "merc_2": {"hp": 0.0, "mp": 11.0, "dead": true}}, "The condition section: exactly hp / mp / dead per stable id (%s)" % str(data.get("condition")))
	var loaded := _load(data)
	_check(not loaded.is_empty() and loaded["condition"] == {"hero": {"hp": 63, "mp": 8, "dead": false}, "merc_1": {"hp": 17, "mp": 4, "dead": false}, "merc_2": {"hp": 0, "mp": 11, "dead": true}}, "17B v14 reload: exact HP / MP, the dead Mercenary still dead")
	# Strict validation: anything malformed rejects the whole save.
	var bad := {
		"negative hp": _with_condition(data, "hero", {"hp": -1, "mp": 8, "dead": false}),
		"negative mp": _with_condition(data, "hero", {"hp": 63, "mp": -1, "dead": false}),
		"fractional hp": _with_condition(data, "hero", {"hp": 6.5, "mp": 8, "dead": false}),
		"string hp": _with_condition(data, "hero", {"hp": "63", "mp": 8, "dead": false}),
		"dead with hp": _with_condition(data, "merc_2", {"hp": 5, "mp": 11, "dead": true}),
		"alive at 0 hp": _with_condition(data, "merc_1", {"hp": 0, "mp": 4, "dead": false}),
		"dead not bool": _with_condition(data, "merc_1", {"hp": 17, "mp": 4, "dead": 0}),
		"extra key": _with_condition(data, "merc_1", {"hp": 17, "mp": 4, "dead": false, "max_hp": 100}),
		"missing key": _with_condition(data, "merc_1", {"hp": 17, "mp": 4}),
		"beyond MAX_VALUE": _with_condition(data, "hero", {"hp": CharacterCondition.MAX_VALUE + 1, "mp": 8, "dead": false}),
		"unknown id": _with_condition(data, "merc_9", {"hp": 1, "mp": 1, "dead": false}),
		"missing Mercenary": _without_condition(data, "merc_2"),
		"missing Hero": _without_condition(data, "hero"),
		"not a dictionary": _with(data, {"condition": []}),
		"missing section": _without(data, "condition"),
	}
	var pending := _party(["GUARDIAN"])
	(pending["roster"] as MercenaryRoster).pend_legacy(Mercenary.create("merc_a", MercenaryRoster.LEGACY_TYPES["merc_a"]))
	var pending_data := _serialize(pending)
	bad["a pending id"] = _with_condition(pending_data, "merc_a", {"hp": 1, "mp": 1, "dead": false})
	for label in bad:
		_check(SaveStore.validate(_json(bad[label])).is_empty(), "Invalid v14 condition (%s): the whole save is rejected" % label)
	_check(not SaveStore.validate(_json(pending_data)).is_empty(), "... while the same save without it is valid")
	# A value above the current Max but within MAX_VALUE loads and is clamped
	# at once by the game (sync) — the approved Max-change rule.
	var high := _load(_with_condition(data, "hero", {"hp": 5000, "mp": 9000, "dead": false}))
	_check(not high.is_empty() and high["condition"]["hero"] == {"hp": 5000, "mp": 9000, "dead": false}, "A value above Max is valid data (clamped by the game after the stats are rebuilt)")
	# Older versions: no condition in the file -> {} (the game fills full).
	var v13 := _without(data, "condition")
	v13["version"] = 13
	var old := _load(v13)
	_check(not old.is_empty() and old["condition"] == {}, "A v13 save loads with no condition (to be filled full / alive)")
	_check(SaveStore.validate(_json(_with(v13, {"condition": data["condition"]}))).is_empty(), "A v13 save cannot carry a condition section")
	_check(SaveStore.validate(_json(_with(data, {"version": 15}))).is_empty(), "An unknown future v15 is rejected")
	# SaveStore.save refuses a condition that would not load back.
	var orphan := _party(["GUARDIAN"])
	(orphan["condition"] as CharacterCondition).sync()
	_check(SaveStore.save(TEST_SAVE, orphan["wallet"], orphan["inventory"], MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.new(), {"hero": orphan["stats"]}, orphan["roster"], orphan["carrying"], orphan["condition"]), "A valid condition saves")
	_clean()
	_sections_done.append("save")


## 17A: a real v13 game save -> v14: every character full / alive at its
## effective maxima (equipment and allocation included); everything else
## byte for byte.
func _verify_migration_game() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	await _enter_city(main)
	main.wallet.add(20000)
	main.recruit_mercenary("GUARDIAN")
	main.recruit_mercenary("GUARDIAN")
	main.recruit_mercenary("MAGE")
	main.buy_equipment("hero", W2)
	main.buy_equipment("merc_3", W2)
	main.buy_equipment("merc_1", A1)
	main.set_mercenary_deployed("merc_1", true)
	main.set_mercenary_deployed("merc_3", true)
	main.mercenary_roster.get_mercenary("merc_3")._level = 3
	main.mercenary_roster.get_mercenary("merc_3").allocate({"int": 2, "hp": 1})
	main.progression = ProgressionState.from_hero(2, 10)
	main._apply_level_growth()
	main.character_stats.confirm_allocation({"hp": 2, "int": 1})
	main.leave_city()
	await _settle()
	_check(main.equip_character_item("hero", W2)["success"] and main.equip_character_item("merc_3", W2)["success"], "Hero and 法師 #3 equip INT weapons (Max MP raised)")
	_check(main.save_world_position(), "Saved (v14)")
	var v14: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	var v13 := v14.duplicate(true)
	v13.erase("condition")
	v13["version"] = 13
	_write_text(TEST_SAVE, JSON.stringify(v13))
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(main.load_status["status"] == SaveStore.STATUS_LOADED and not main.save_locked, "17A The v13 save loads")
	var all_full := true
	for id in main.condition.get_character_ids():
		var stats: CharacterStats = main.carrying.get_stats(id)
		all_full = all_full and main.condition.get_condition(id) == {"hp": stats.get_max_hp(), "mp": stats.get_max_mp(), "dead": false, "max_hp": stats.get_max_hp(), "max_mp": stats.get_max_mp()}
	_check(all_full and main.condition.get_character_ids().size() == 4, "17A Hero and every owned Mercenary: alive, HP / MP = effective Max (equipment / allocation / Level included)")
	_check(main.condition.get_condition("hero")["max_mp"] == main.character_stats.get_max_mp() and main.character_stats.get_equipment_bonuses() == {"int": 2}, "17A The Hero's effective Max MP includes its INT weapon")
	_check(main.save_world_position(), "Rewritten at the next save")
	var rewritten: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	var same := true
	for key in SaveStore.V13_KEYS:
		if key != "version" and key != "location":
			same = same and JSON.stringify(rewritten[key]) == JSON.stringify(v14[key])
	_check(int(rewritten["version"]) == 14 and same and rewritten["location"]["mode"] == v14["location"]["mode"], "17A Rewritten as v14: money, Hero progression / allocation, roster (Level / EXP / allocation / ownership / deployment), carrying / equipment, warehouses, market, ledger … all unchanged")
	var expected := {}
	for id in main.condition.get_character_ids():
		var stats: CharacterStats = main.carrying.get_stats(id)
		expected[id] = {"hp": float(stats.get_max_hp()), "mp": float(stats.get_max_mp()), "dead": false}
	_check(rewritten["condition"] == expected, "17A The rewritten v14 condition: everyone full / alive at the effective maxima")
	_check(int(v14["condition"]["hero"]["mp"]) < int(expected["hero"]["mp"]), "(The v14 game itself had the Hero below its raised Max MP: equipping never heals)")
	await _destroy(main)
	_clean()
	_sections_done.append("migration")


# --- Battle -----------------------------------------------------------------------------------------------

func _verify_battle() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "GUARDIAN"), Mercenary.create("merc_3", "MAGE")], ["merc_1", "merc_2"])
	var c: CharacterCondition = main.condition
	c.sync()
	# 17C Battle start reads the persistent condition.
	c.set_condition("hero", 63, 8)
	c.set_condition("merc_1", 17, 4)
	var merc_3 := c.get_condition("merc_3")
	var battle: CombatBattle = await _start_battle(main)
	var hero := battle.get_hero()
	var m1 := _friend(battle, "merc_1")
	var m2 := _friend(battle, "merc_2")
	_check(hero.hp == 63 and hero.mp == 8 and hero.max_hp == main.character_stats.get_max_hp(), "17C Hero starts at 63 HP / 8 MP (not full)")
	_check(m1.hp == 17 and m1.mp == 4, "17C 守衛 #1 starts at 17 HP / 4 MP")
	_check(m2.hp == m2.max_hp and m2.mp == m2.max_mp, "守衛 #2 starts full (its own condition)")
	_check(_friend(battle, "merc_3") == null, "法師 #3 is not deployed: not in the battle")
	# 17D Victory: injuries persist; 17H same type; 17G non-participant.
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_enemies()[0], hero, 20)
	battle.resolve_damage(battle.get_enemies()[0], m2, 100000)
	for enemy in battle.get_enemies():
		battle.resolve_damage(m1, enemy, 100000)
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY and not m2.alive, "VICTORY; 守衛 #2 died in it")
	var final_hero := [hero.hp, hero.mp]
	var final_m1 := [m1.hp, m1.mp]
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(main.get_combat() == null and c.get_hp("hero") == final_hero[0] and c.get_mp("hero") == final_hero[1] and not c.is_dead("hero"), "17D After the commit the Hero keeps its final %d HP / %d MP (no victory heal)" % final_hero)
	_check(c.get_hp("merc_1") == final_m1[0] and c.get_mp("merc_1") == final_m1[1], "17D 守衛 #1 keeps its final values")
	_check(c.is_dead("merc_2") and c.get_hp("merc_2") == 0, "17E 守衛 #2 is dead after the battle")
	_check(not c.is_dead("merc_1") and c.get_hp("merc_1") > 0, "17H Same type: only 守衛 #2 died")
	_check(c.get_condition("merc_3") == merc_3, "17G 法師 #3 (not in the battle) exactly unchanged")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(saved["condition"]["merc_2"] == {"hp": 0.0, "mp": float(c.get_mp("merc_2")), "dead": true} and int(saved["condition"]["hero"]["hp"]) == final_hero[0], "Saved with the commit (v14)")
	# 17E Save / reload: still dead; the next battle excludes it.
	var state := _condition_state(main)
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	c = main.condition
	_check(_condition_state(main) == state and c.is_dead("merc_2"), "17B / 17E Reload: every condition exact, 守衛 #2 still dead")
	_check(main.mercenary_roster.get_deployed_ids() == ["merc_1", "merc_2"], "The dead 守衛 #2 stays owned and deployed (nothing deleted)")
	await _respawn(main)
	battle = await _start_battle(main)
	_check(battle != null and _friend(battle, "merc_2") == null and battle.get_friends().size() == 2, "17E The dead 守衛 #2 is not instantiated in the next battle")
	_check(battle.get_hero().hp == final_hero[0] and battle.get_hero().mp == final_hero[1] and _friend(battle, "merc_1").hp == final_m1[0], "17D The next battle uses the persisted values")
	# Retreat writes the participants back too.
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_enemies()[0], battle.get_hero(), 7)
	var retreat_hp := battle.get_hero().hp
	battle.start_retreat()
	for step in range(400):
		if battle.is_over():
			break
		battle.advance(50)
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT, "RETREAT")
	retreat_hp = battle.get_hero().hp
	var retreat_m1 := _friend(battle, "merc_1").hp
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(c.get_hp("hero") == retreat_hp and c.get_hp("merc_1") == retreat_m1 and c.is_dead("merc_2"), "Retreat: the participants' final HP persists; the excluded dead one untouched")
	# Deployment: a dead Mercenary cannot be deployed; undeploying works.
	await _enter_city(main)
	main.set_mercenary_deployed("merc_2", false)
	var before := _world(main)
	var refused: Dictionary = main.set_mercenary_deployed("merc_2", true)
	_check(not refused["success"] and refused["reason"] == PartyService.ERR_DEAD and _world(main) == before, "4D Deploying a dead Mercenary is refused (ERR_DEAD), nothing changes")
	_check(CityHub.PARTY_FAILURE_MESSAGES["ERR_DEAD"] == "此傭兵已陣亡，無法出戰", "The refusal text: 此傭兵已陣亡，無法出戰")
	_check(main.set_mercenary_deployed("merc_3", true)["success"], "A living Mercenary still deploys")
	_check(main.mercenary_roster.get_mercenary("merc_2") != null and main.mercenary_roster.get_mercenary("merc_2").get_level() == 1, "4D The dead Mercenary keeps ownership and Level")
	main.leave_city()
	await _settle()
	# Level-up (17L): the Hero alone kills 10 -> Lv2; Max HP rises, HP stays.
	main.mercenary_roster = MercenaryRoster.new()
	c.sync()
	c.set_condition("hero", 25, 9)
	var max_before: int = main.character_stats.get_max_hp()
	await _respawn(main)
	battle = await _start_battle(main)
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 100000)
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(main.progression.get_level("hero") == 2 and main.character_stats.get_max_hp() > max_before, "Level-up: Max HP %d -> %d" % [max_before, main.character_stats.get_max_hp()])
	_check(c.get_hp("hero") == 25 and c.get_mp("hero") == 9, "17L Level-up does not heal: 25 HP / 9 MP of the new Max")
	await _destroy(main)
	_clean()
	_sections_done.append("battle")


## 17F: the Hero's death persists (no revival here); a battle with no living
## friendly unit is a DEFEAT at once and commits cleanly.
func _verify_hero_death() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN")], ["merc_1"])
	var c: CharacterCondition = main.condition
	c.sync()
	var battle: CombatBattle = await _start_battle(main)
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_enemies()[0], battle.get_hero(), 100000)
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING, "The Hero's death alone does not end the battle (C03)")
	for enemy in battle.get_enemies():
		battle.resolve_damage(_friend(battle, "merc_1"), enemy, 100000)
	var mp_left := battle.get_hero().mp
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(c.is_dead("hero") and c.get_hp("hero") == 0 and c.get_mp("hero") == mp_left, "17F The Hero's death is recorded (HP 0, MP kept), not reset to full")
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	c = main.condition
	_check(c.is_dead("hero") and c.get_hp("hero") == 0, "17F ... and survives save / reload")
	await _respawn(main)
	battle = await _start_battle(main)
	_check(battle != null and not battle.get_hero().alive and battle.get_hero().hp == 0 and battle.get_phase() == CombatBattle.Phase.PREPARATION and battle.get_selected() == _friend(battle, "merc_1"), "A dead Hero enters as a dead unit; the living 守衛 #1 is selected")
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(_friend(battle, "merc_1"), enemy, 100000)
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(c.is_dead("hero") and main.progression.get_exp("hero") == 0, "No revival by a victory; a dead Hero earns nothing")
	# Everyone dead -> the next encounter is a DEFEAT at once (no hang).
	c.set_condition("merc_1", 0, 0)
	var before := _condition_state(main)
	await _respawn(main)
	battle = await _start_battle(main)
	_check(battle != null and battle.get_phase() == CombatBattle.Phase.DEFEAT and battle.get_result() != null and battle.get_result().encounter_id == battle.encounter_id and battle.encounter_id != "" and battle.get_friends().size() == 1, "No living friend: DEFEAT at once, the result carries the encounter")
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(main.get_combat() == null and _condition_state(main) == before and main.location.is_in_world(), "It commits cleanly; nothing revived; back in the world (no penalty)")
	await _destroy(main)
	_clean()
	_sections_done.append("hero_death")


# --- World: equipment, allocation, passive recovery, failed saves --------------------------------------------

func _verify_world() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	var c: CharacterCondition = main.condition
	await _enter_city(main)
	main.wallet.add(5000)
	main.buy_equipment("hero", W2)
	main.leave_city()
	await _settle()
	var max_mp: int = main.character_stats.get_max_mp()
	c.set_condition("hero", 40, max_mp - 50)
	_check(main.equip_character_item("hero", W2)["success"] and main.character_stats.get_max_mp() == max_mp + 10, "INT weapon: Max MP %d -> %d" % [max_mp, max_mp + 10])
	_check(c.get_mp("hero") == max_mp - 50 and c.get_hp("hero") == 40, "17K Equipping does not refill MP / HP")
	c.set_condition("hero", 40, max_mp + 10)
	_check(main.unequip_character_slot("hero", "WEAPON")["success"] and c.get_mp("hero") == max_mp, "17K Unequipping clamps MP to the lower Max (%d)" % c.get_mp("hero"))
	_check(main.equip_character_item("hero", W2)["success"] and c.get_mp("hero") == max_mp, "17K Re-equipping does not give the clamped MP back")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(saved["condition"]["hero"]["mp"]) == max_mp, "The clamp is what is saved")
	# A failed save restores the condition with the equipment (no clamp leak).
	c.set_condition("hero", 40, max_mp + 10)
	main.save_path = BAD_SAVE
	var before := _condition_state(main)
	_check(not main.unequip_character_slot("hero", "WEAPON")["success"] and _condition_state(main) == before and main.carrying.get_equipment("hero").get_equipped("WEAPON") == W2, "Failed save on 卸下: equipment and condition exactly restored")
	main.save_path = TEST_SAVE
	# Allocation raises Max HP: HP stays.
	main.progression = ProgressionState.from_hero(2, 0)
	main._apply_level_growth()
	c.set_condition("hero", 40, 10)
	var max_hp: int = main.character_stats.get_max_hp()
	_check(main.confirm_character_allocation("hero", {"hp": 2}) and main.character_stats.get_max_hp() > max_hp and c.get_hp("hero") == 40, "Allocating HP points raises Max HP; HP stays 40")
	main._save_session()
	# 17M No passive recovery: movement, time, city, scene changes, reload.
	var state := _condition_state(main)
	var player := main.get_node("Actors/Player") as Player
	player.global_position = Vector2(3000.0, 3000.0)
	await _settle()
	main.time_source.advance_ms(3600000)
	for frame in range(30):
		await process_frame
	main.save_world_position()
	_check(_condition_state(main) == state, "17M Walking and an hour of game time: nothing restored")
	await _enter_city(main)
	_check(_condition_state(main) == state, "17M Entering a city: nothing restored")
	main.leave_city()
	await _settle()
	_check(_condition_state(main) == state, "17M Leaving the city: nothing restored")
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(_condition_state(main) == state, "17M Save / reload: nothing restored (%s)" % _condition_state(main))
	# A failed save after a battle: the condition stays committed in memory
	# like the EXP (C02 / D4: a failed save never undoes the result).
	main.mercenary_roster = MercenaryRoster.new()
	await _respawn(main)
	var battle: CombatBattle = await _start_battle(main)
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_enemies()[0], battle.get_hero(), 11)
	battle.start_retreat()
	for step in range(400):
		if battle.is_over():
			break
		battle.advance(50)
	var hp := battle.get_hero().hp
	main.save_path = BAD_SAVE
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(main.get_combat() == null and main.condition.get_hp("hero") == hp, "Failed save after a battle: the condition is committed in memory (as the EXP), all participants together")
	main.save_path = TEST_SAVE
	await _destroy(main)
	_clean()
	_sections_done.append("world")


# --- Scope ------------------------------------------------------------------------------------------------

func _verify_scope() -> void:
	var code := ""
	for path in ["res://scripts/character_condition.gd", "res://scripts/main.gd", "res://scripts/combat_battle.gd", "res://scripts/party_service.gd", "res://scripts/save_store.gd"]:
		code += _code_only(path).to_lower()
	for word in ["hospital", "revive", "penalty", "regenerat", "recover_hp", "heal("]:
		_check(not code.contains(word), "No %s added (Hospital / penalties are later WPs)" % word)
	var combat := ""
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_view.gd", "res://scripts/combat_config.gd"]:
		combat += _code_only(path).to_lower()
	for word in ["equipment", "carrying", "bonus", "get_effective(", "mitigate(stats", "save"]:
		_check(not combat.contains(word), "Combat code computes / saves no %s" % word)
	# 17N Formulas unchanged: a full-condition party = the Stage 9 battle.
	var party := _party(["GUARDIAN", "MAGE"])
	(party["roster"] as MercenaryRoster).set_deployment(["merc_1", "merc_2"])
	var stats := {}
	for m in (party["roster"] as MercenaryRoster).get_deployed():
		stats[m.get_id()] = (party["carrying"] as CharacterCarrying).get_stats(m.get_id())
	var c: CharacterCondition = party["condition"]
	c.sync()
	var conditions := {}
	for id in ["hero", "merc_1", "merc_2"]:
		conditions[id] = c.get_condition(id)
	var plain := CombatBattle.create_party(10, party["stats"], (party["roster"] as MercenaryRoster).get_deployed(), stats)
	var full := CombatBattle.create_party(10, party["stats"], (party["roster"] as MercenaryRoster).get_deployed(), stats, conditions)
	var same := plain.get_friends().size() == full.get_friends().size()
	for i in range(plain.get_friends().size()):
		var a := plain.get_friends()[i]
		var b := full.get_friends()[i]
		same = same and [a.id, a.hp, a.max_hp, a.mp, a.max_mp, a.attack_damage, a.magic_attack, a.physical_defense, a.magic_defense, a.cell, a.alive] == [b.id, b.hp, b.max_hp, b.mp, b.max_mp, b.attack_damage, b.magic_attack, b.physical_defense, b.magic_defense, b.cell, b.alive]
	_check(same, "17N Full / alive condition: every unit identical to the Stage 9 battle (formulas, cells, stats)")
	plain.advance(CombatConfig.PREPARATION_MS)
	full.advance(CombatConfig.PREPARATION_MS)
	_check(plain.resolve_damage(plain.get_enemies()[0], plain.get_hero(), 50) == full.resolve_damage(full.get_enemies()[0], full.get_hero(), 50), "17N Damage unchanged")
	_check(ProgressionState.required_exp(1) == 100 and CombatConfig.EXP_PER_KILL == 10, "17N EXP formulas unchanged")
	_sections_done.append("scope")


# --- Stress (FULL) ----------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var bounds := 0
	var leak := 0
	var dead_fought := 0
	var non_participant := 0
	var reload_bad := 0
	var heal := 0
	var revived := 0
	var progression_lost := 0
	var migrate_bad := 0
	var refused_changed := 0
	var battles := 0
	var deaths := 0
	var outcomes := {"VICTORY": 0, "DEFEAT": 0, "RETREAT": 0}
	for run in range(60):
		var types := []
		for i in range(rng.randi_range(1, 5)):
			types.append(["GUARDIAN", "GUARDIAN", "MAGE", "STRATEGIST"][rng.randi_range(0, 3)])
		var party := _party(types)
		var roster: MercenaryRoster = party["roster"]
		var carrying: CharacterCarrying = party["carrying"]
		var c: CharacterCondition = party["condition"]
		c.sync()
		for id in c.get_character_ids():
			carrying.add_equipment(id, [W1, W2, A1, A2][rng.randi_range(0, 3)], 1)
		for step in range(14):
			var ids: Array = c.get_character_ids()
			var action := rng.randi_range(0, 9)
			var before := c.get_snapshot()
			var maxima := _maxima(c)
			if action <= 4:
				# Test stand-in for a future recovery (not a game path): now and
				# then everyone is restored before the battle, so the stress
				# keeps fighting living parties too.
				if rng.randi_range(0, 1) == 0:
					for id in ids:
						c.set_condition(id, CharacterCondition.MAX_VALUE, CharacterCondition.MAX_VALUE)
				# A battle of the Hero + up to 3 deployed (dead excluded).
				var owned := ids.slice(1)
				owned.shuffle()
				roster.set_deployment(owned.slice(0, mini(owned.size(), MercenaryRoster.MAX_DEPLOYED)))
				var deployed_stats := {}
				var conditions := {"hero": c.get_condition("hero")}
				for m in roster.get_deployed():
					deployed_stats[m.get_id()] = carrying.get_stats(m.get_id())
					conditions[m.get_id()] = c.get_condition(m.get_id())
				var battle := CombatBattle.create_party(10, party["stats"], roster.get_deployed(), deployed_stats, conditions)
				battles += 1
				for unit in battle.get_friends():
					var state: Dictionary = conditions[unit.id]
					if (state["dead"] and unit.alive) or (not state["dead"] and (unit.hp != state["hp"] or unit.mp != state["mp"])):
						dead_fought += 1
				for id in conditions:
					if conditions[id]["dead"] and id != "hero" and _friend(battle, id) != null:
						dead_fought += 1
				if not battle.is_over():
					battle.advance(CombatConfig.PREPARATION_MS)
					for hit in range(rng.randi_range(1, 12)):
						var living := battle.get_friends().filter(func(u: CombatUnit) -> bool: return u.alive)
						if living.is_empty() or battle.is_over():
							break
						battle.resolve_damage(battle.get_enemies()[0], living[rng.randi_range(0, living.size() - 1)], rng.randi_range(1, 260))
					var ending := rng.randi_range(0, 2)
					if not battle.is_over() and ending == 0:
						for enemy in battle.get_enemies():
							var shooter := battle.get_friends().filter(func(u: CombatUnit) -> bool: return u.alive)
							if shooter.is_empty() or battle.is_over():
								break
							battle.resolve_damage(shooter[0], enemy, 100000)
					elif not battle.is_over() and ending == 1:
						battle.start_retreat()
						for tick in range(600):
							if battle.is_over():
								break
							battle.advance(50)
					else:
						for unit in battle.get_friends():
							if unit.alive and not battle.is_over():
								battle.resolve_damage(battle.get_enemies()[0], unit, 1000000)
				if not battle.is_over():
					continue
				outcomes[CombatBattle.Phase.keys()[battle.get_phase()]] += 1
				var was_dead := {}
				for id in ids:
					was_dead[id] = c.is_dead(id)
				var participants := battle.get_friends().map(func(u: CombatUnit) -> String: return u.id)
				var untouched := {}
				for id in ids:
					if not participants.has(id):
						untouched[id] = c.get_condition(id)
				for unit in battle.get_friends():
					c.set_condition(unit.id, unit.hp if unit.alive else 0, unit.mp)
					if not unit.alive:
						deaths += 1
					if c.get_hp(unit.id) != (unit.hp if unit.alive else 0) or c.get_mp(unit.id) != unit.mp:
						leak += 1
				for id in untouched:
					if c.get_condition(id) != untouched[id]:
						non_participant += 1
				for id in ids:
					if was_dead[id] and not c.is_dead(id):
						revived += 1
			elif action <= 6:
				# Equip / unequip: never a heal.
				var id: String = ids[rng.randi_range(0, ids.size() - 1)]
				var hp_before := c.get_hp(id)
				var mp_before := c.get_mp(id)
				if rng.randi_range(0, 1) == 0:
					var carried := carrying.get_equipment(id).get_carried().keys()
					if not carried.is_empty():
						EquipmentService.equip(carrying, id, carried[0])
				else:
					EquipmentService.unequip(carrying, id, ["WEAPON", "ARMOR"][rng.randi_range(0, 1)])
				c.sync()
				if c.get_hp(id) > hp_before or c.get_mp(id) > mp_before:
					heal += 1
			elif action == 7:
				# Level / allocation change on a Mercenary: never a heal.
				var id: String = ids[rng.randi_range(0, ids.size() - 1)]
				if id != "hero":
					var m := roster.get_mercenary(id)
					var hp_before := c.get_hp(id)
					var mp_before := c.get_mp(id)
					m._level = mini(m.get_level() + 1, ProgressionState.MAX_LEVEL)
					m.allocate({"hp": mini(m.get_unspent_points(), 1)}) if m.get_unspent_points() > 0 else null
					c.sync()
					if c.get_hp(id) > hp_before or c.get_mp(id) > mp_before:
						heal += 1
			elif action == 8:
				# Invalid writes change nothing.
				var snapshot := c.get_snapshot()
				c.set_condition("merc_99", 1, 1)
				c.set_condition("hero", 1.0, 2)
				if c.get_snapshot() != snapshot:
					refused_changed += 1
			else:
				# Save -> reload.
				var data := _serialize(party)
				var loaded := _load(data)
				if loaded.is_empty():
					reload_bad += 1
				else:
					var next := _party_from(loaded)
					(next["condition"] as CharacterCondition).sync()
					if _party_state(next) != _party_state(party):
						reload_bad += 1
					if JSON.stringify(_serialize(next)) != JSON.stringify(data):
						reload_bad += 1
					var levels_before := roster.to_dict()
					party = next
					roster = party["roster"]
					carrying = party["carrying"]
					c = party["condition"]
					if roster.to_dict() != levels_before:
						progression_lost += 1
			# Invariants after every step.
			for id in c.get_character_ids():
				var state := c.get_condition(id)
				if state["hp"] < 0 or state["mp"] < 0 or state["hp"] > state["max_hp"] or state["mp"] > state["max_mp"] or state["dead"] != (state["hp"] == 0):
					bounds += 1
		# A v13 save of the same party migrates to full / alive.
		var v13 := _serialize(party)
		v13.erase("condition")
		v13["version"] = 13
		var migrated := _load(v13)
		if migrated.is_empty():
			migrate_bad += 1
		else:
			var next := _party_from(migrated)
			var mc: CharacterCondition = next["condition"]
			mc.sync()
			for id in mc.get_character_ids():
				var state := mc.get_condition(id)
				if state["dead"] or state["hp"] != state["max_hp"] or state["mp"] != state["max_mp"]:
					migrate_bad += 1
			var old_sections := _serialize(party)
			var new_sections := _serialize(next)
			for key in SaveStore.V13_KEYS:
				if JSON.stringify(old_sections[key]) != JSON.stringify(new_sections[key]):
					migrate_bad += 1
	print("Stress summary (seed %d): battles %d %s, deaths %d, bounds %d, leak %d, dead_fought %d, non_participant %d, reload %d, heal %d, revived %d, progression %d, migrate %d, refused %d" % [_seed, battles, str(outcomes), deaths, bounds, leak, dead_fought, non_participant, reload_bad, heal, revived, progression_lost, migrate_bad, refused_changed])
	_check(battles > 200 and deaths > 100 and outcomes["VICTORY"] > 30 and outcomes["DEFEAT"] > 30 and outcomes["RETREAT"] > 30, "Stress: %d battles, %d deaths, %s" % [battles, deaths, str(outcomes)])
	_check(bounds == 0, "Stress: HP / MP always within 0..effective Max, dead <=> HP 0 (%d)" % bounds)
	_check(leak == 0, "Stress: each participant's final values recorded on its own stable id (%d)" % leak)
	_check(dead_fought == 0, "Stress: no dead Mercenary ever fought; every unit started from its condition (%d)" % dead_fought)
	_check(non_participant == 0, "Stress: non-participants never changed (%d)" % non_participant)
	_check(reload_bad == 0, "Stress: save -> reload exact and deterministic (%d)" % reload_bad)
	_check(heal == 0, "Stress: equipment / Level / allocation never healed (%d)" % heal)
	_check(revived == 0, "Stress: no silent revival (%d)" % revived)
	_check(progression_lost == 0, "Stress: no progression / identity lost on reload (%d)" % progression_lost)
	_check(migrate_bad == 0, "Stress: v13 -> v14 migration full / alive, every other section unchanged (%d)" % migrate_bad)
	_check(refused_changed == 0, "Stress: refused writes changed nothing (%d)" % refused_changed)
	# Real game: battles -> save -> reload -> battle, with failed saves.
	_clean()
	var main := await _new_main(TEST_SAVE)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "GUARDIAN"), Mercenary.create("merc_3", "MAGE")], ["merc_1", "merc_2", "merc_3"])
	main.condition.sync()
	main._save_session()
	var game_bad := 0
	for cycle in range(6):
		await _respawn(main)
		var battle: CombatBattle = await _start_battle(main)
		if battle == null:
			game_bad += 1
			break
		var starts := {}
		for unit in battle.get_friends():
			var state: Dictionary = main.condition.get_condition(unit.id)
			if unit.hp != (state["hp"] if not state["dead"] else 0) or unit.mp != state["mp"]:
				game_bad += 1
			starts[unit.id] = true
		for id in main.condition.get_character_ids():
			if main.condition.is_dead(id) and id != "hero" and starts.has(id):
				game_bad += 1
		if not battle.is_over():
			battle.advance(CombatConfig.PREPARATION_MS)
			var living := battle.get_friends().filter(func(u: CombatUnit) -> bool: return u.alive)
			battle.resolve_damage(battle.get_enemies()[0], living[rng.randi_range(0, living.size() - 1)], rng.randi_range(5, 400))
			battle.start_retreat()
			for tick in range(600):
				if battle.is_over():
					break
				battle.advance(50)
		var finals := {}
		for unit in battle.get_friends():
			finals[unit.id] = [unit.hp if unit.alive else 0, unit.mp]
		main.save_path = BAD_SAVE if cycle % 3 == 2 else TEST_SAVE
		await process_frame
		(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
		await _settle()
		for id in finals:
			if [main.condition.get_hp(id), main.condition.get_mp(id)] != finals[id]:
				game_bad += 1
		main.save_path = TEST_SAVE
		main._save_session()
		var state := _condition_state(main)
		await _destroy(main)
		main = await _new_main(TEST_SAVE)
		if _condition_state(main) != state:
			game_bad += 1
	_check(game_bad == 0, "Stress: 6 real-game battle -> save (one failed) -> reload cycles exact (%d)" % game_bad)
	await _destroy(main)
	_clean()
	_sections_done.append("stress")


# --- Helpers ----------------------------------------------------------------------------------------------

func _party(types: Array) -> Dictionary:
	var stats := CharacterStats.new()
	var inventory := CharacterInventory.new("player", stats)
	var roster := MercenaryRoster.new()
	for type in types:
		roster.create_mercenary(type)
	var carrying := CharacterCarrying.new(inventory, func() -> MercenaryRoster: return roster)
	var condition := CharacterCondition.new(func() -> CharacterCarrying: return carrying)
	return {"carrying": carrying, "roster": roster, "inventory": inventory, "stats": stats, "wallet": Wallet.new(), "condition": condition}


## A party from a SaveStore rebuild (as main does).
func _party_from(loaded: Dictionary) -> Dictionary:
	var roster: MercenaryRoster = loaded["mercenaries"]
	var carrying: CharacterCarrying = loaded["carrying"]
	var condition := CharacterCondition.new(func() -> CharacterCarrying: return carrying)
	condition.restore_save(loaded["condition"])
	return {"carrying": carrying, "roster": roster, "inventory": loaded["inventory"], "stats": loaded["character_stats"], "wallet": loaded["wallet"], "condition": condition}


func _party_state(party: Dictionary) -> String:
	var c: CharacterCondition = party["condition"]
	var parts := [(party["roster"] as MercenaryRoster).to_dict()]
	for id in c.get_character_ids():
		parts.append([id, c.get_condition(id), (party["carrying"] as CharacterCarrying).get_equipment(id).get_equipped_items()])
	return JSON.stringify(parts)


func _maxima(c: CharacterCondition) -> Dictionary:
	var result := {}
	for id in c.get_character_ids():
		var state := c.get_condition(id)
		result[id] = [state["max_hp"], state["max_mp"]]
	return result


func _condition_state(main: Node) -> String:
	var parts := []
	for id in main.condition.get_character_ids():
		parts.append([id, main.condition.get_condition(id)])
	return JSON.stringify(parts)


func _world(main: Node) -> String:
	return JSON.stringify([_condition_state(main), main.mercenary_roster.to_dict(), main.wallet.get_balance()])


func _friend(battle: CombatBattle, id: String) -> CombatUnit:
	for unit in battle.get_friends():
		if unit.id == id:
			return unit
	return null


func _serialize(party: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(SaveStore.serialize(party["wallet"], party["inventory"], MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.new(), {"hero": party["stats"]}, party["roster"], party["carrying"], party["condition"])))


func _load(data: Dictionary) -> Dictionary:
	var payload := SaveStore.validate(_json(data))
	return {} if payload.is_empty() else SaveStore._rebuild(payload)


func _json(data: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(data))


func _with(data: Dictionary, changes: Dictionary) -> Dictionary:
	var copy := data.duplicate(true)
	for key in changes:
		copy[key] = changes[key]
	return copy


func _without(data: Dictionary, key: String) -> Dictionary:
	var copy := data.duplicate(true)
	copy.erase(key)
	return copy


func _with_condition(data: Dictionary, id: String, entry: Dictionary) -> Dictionary:
	var copy := data.duplicate(true)
	copy["condition"][id] = entry
	return copy


func _without_condition(data: Dictionary, id: String) -> Dictionary:
	var copy := data.duplicate(true)
	(copy["condition"] as Dictionary).erase(id)
	return copy


func _start_battle(main: Node) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	return main.get_combat()


## Lets defeated groups come back and the post-battle protection end.
func _respawn(main: Node) -> void:
	main.time_source.advance_ms(60000)
	await _settle()
	main.time_source.advance_ms(60000)
	await _settle()


func _enter_city(main: Node) -> void:
	(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
	await _settle()
	main.try_enter_city()
	await _settle()


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _clean() -> void:
	for p in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	var dir := DirAccess.open("user://")
	if dir != null:
		for name in dir.get_files():
			if name.begins_with("s10_p00_condition_test.json.unreadable-"):
				dir.remove(name)


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
