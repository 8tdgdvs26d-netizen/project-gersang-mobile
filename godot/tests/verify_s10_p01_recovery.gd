extends SceneTree

## Stage 10 P01: Hospital / Recovery foundation (RecoveryService).
##   hero         free, unconditional (HP / MP to Max, revived; $0 wallet, no
##                Mercenaries, all Mercenaries dead), never charged $100
##   mercenary    $100 each whatever is missing; HP / MP to Max, revived;
##                a healthy one: refused, no charge
##   selection    exact totals, wallet boundaries, unaffordable requests
##                refused whole, nothing chosen on the player's behalf
##   identity     duplicates, unknown / pending / dismissed ids, the Hero
##                as a paid id, same-type isolation, unselected untouched
##   persistence  the real game: recovery -> Save v14 -> reload
##   rollback     injected save failures restore wallet + conditions exactly
##   boundaries   no equipment / goods / allocation / Level / EXP / roster /
##                deployment / market / warehouse change
##   scope        Save v14, no Hospital UI / routing / penalty
##   stress       TARGETED: wallet boundaries x parties x conditions x
##                selections x saves / reloads / failures

const TEST_SAVE := "user://s10_p01_recovery_test.json"
const BAD_SAVE := "user://s10_p01_missing_dir/save.json"
const T0 := 1800000000000
const W1 := "test_weapon_01"
const W2 := "test_weapon_02"
const A1 := "test_armor_01"
const PASSIVE_ONLY := Vector2(950.0, 1080.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _seed := 10100


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			_seed = int(arg.substr(7))
	_verify_hero()
	_verify_mercenary()
	_verify_selection()
	_verify_identity()
	_verify_rollback()
	_verify_boundaries()
	await _verify_game()
	_verify_scope()
	_verify_stress()
	_check(_sections_done.size() == 9, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S10 P01 recovery verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Hero ---------------------------------------------------------------------------------------------------

func _verify_hero() -> void:
	# 1 Injured Hero.
	var p := _party([], 1000)
	_hurt(p, "hero", 50, 20)
	var r := _recover(p, [])
	_check(r["success"] and r["hero_recovered"] and r["total"] == 0 and _full(p, "hero") and _money(p) == 1000, "1 / 4 Injured Hero: HP / MP to Max, $0 charged")
	# 2 MP only.
	p = _party([], 1000)
	var max_hp: int = _cond(p).get_condition("hero")["max_hp"]
	_cond(p).set_condition("hero", max_hp, 3)
	r = _recover(p, [])
	_check(r["success"] and _cond(p).get_hp("hero") == max_hp and _full(p, "hero"), "2 MP-only Hero: HP stays Max, MP to Max")
	# 3 Dead Hero.
	p = _party([], 1000)
	_cond(p).set_condition("hero", 0, 9)
	r = _recover(p, [])
	_check(r["success"] and not _cond(p).is_dead("hero") and _full(p, "hero") and _money(p) == 1000, "3 Dead Hero: revived, HP / MP to Max, $0")
	# 5 $0 wallet; 7 no Mercenaries.
	p = _party([], 0)
	_cond(p).set_condition("hero", 0, 0)
	r = RecoveryService.recover_hero(_cond(p), p["wallet"])
	_check(r["success"] and _full(p, "hero") and _money(p) == 0, "5 / 7 $0 wallet, no Mercenaries: the Hero recovers (recover_hero)")
	p = _party([], 0)
	_cond(p).set_condition("hero", 0, 0)
	_check(_recover(p, [])["success"] and _full(p, "hero") and _money(p) == 0, "5 ... and through recover() with no choice")
	# 6 Never charged $100; 8 all Mercenaries dead / unrecovered.
	p = _party(["GUARDIAN", "MAGE", "STRATEGIST"], 50)
	for id in ["hero", "merc_1", "merc_2", "merc_3"]:
		_cond(p).set_condition(id, 0, 0)
	var dead_mercs := _states(p, ["merc_1", "merc_2", "merc_3"])
	r = _recover(p, [])
	_check(r["success"] and r["total"] == 0 and _money(p) == 50 and _full(p, "hero") and _states(p, ["merc_1", "merc_2", "merc_3"]) == dead_mercs, "6 / 8 Every Mercenary dead, $50: the Hero recovers for $0, the Mercenaries stay dead")
	# Unaffordable / invalid choice: recover_hero is still always available.
	p = _party(["GUARDIAN"], 0)
	_cond(p).set_condition("hero", 0, 0)
	_cond(p).set_condition("merc_1", 0, 0)
	var before := _snapshot(p)
	r = _recover(p, ["merc_1"])
	_check(not r["success"] and r["reason"] == RecoveryService.ERR_INSUFFICIENT_FUNDS and _snapshot(p) == before, "An unaffordable paid choice refuses that whole request (nothing changes)")
	r = RecoveryService.recover_hero(_cond(p), p["wallet"])
	_check(r["success"] and _full(p, "hero") and _cond(p).is_dead("merc_1") and _money(p) == 0, "8 ... and the Hero still recovers for free right after (recover_hero)")
	# A healthy Hero: nothing to do, no save.
	var saves := [0]
	var count := func() -> bool:
		saves[0] += 1
		return true
	p = _party([], 100)
	r = RecoveryService.recover_hero(_cond(p), p["wallet"], count)
	_check(not r["success"] and r["reason"] == RecoveryService.ERR_NOTHING_TO_RECOVER and saves[0] == 0 and _money(p) == 100, "A healthy Hero: ERR_NOTHING_TO_RECOVER, nothing saved")
	_check(not _recover(p, [], count)["success"] and saves[0] == 0, "recover() with a healthy Hero and no choice: refused, nothing saved")
	# Status entry.
	p = _party(["GUARDIAN"], 100)
	_hurt(p, "hero", 10, 0)
	var status := RecoveryService.get_status(_cond(p), p["wallet"])
	var hero_entry: Dictionary = status["hero"]
	_check(hero_entry["id"] == "hero" and hero_entry["hero"] and hero_entry["needs_recovery"] and hero_entry["price"] == 0 and hero_entry["hp"] == hero_entry["max_hp"] - 10 and not hero_entry["dead"], "Status: the Hero's entry (needs recovery, HP / Max, price $0)")
	_sections_done.append("hero")


# --- Mercenary ----------------------------------------------------------------------------------------------

func _verify_mercenary() -> void:
	for n in [1, 2, 3]:
		var p := _party(["GUARDIAN", "MAGE", "STRATEGIST"], 1000)
		var ids := ["merc_1", "merc_2", "merc_3"].slice(0, n)
		for id in ids:
			_hurt(p, id, 5, 0)
		var r := _recover(p, ids)
		_check(r["success"] and r["total"] == n * 100 and _money(p) == 1000 - n * 100 and ids.all(func(id: String) -> bool: return _full(p, id)), "%d eligible Mercenar%s: exactly $%d" % [n, "y" if n == 1 else "ies", n * 100])
	# 12 HP + MP damaged; 13 MP only; 14 dead; 1 HP missing.
	var p := _party(["GUARDIAN", "MAGE", "STRATEGIST", "GUARDIAN"], 1000)
	_hurt(p, "merc_1", 40, 30)
	var max_hp_2: int = _cond(p).get_condition("merc_2")["max_hp"]
	_cond(p).set_condition("merc_2", max_hp_2, 0)
	_cond(p).set_condition("merc_3", 0, 7)
	_hurt(p, "merc_4", 1, 0)
	for id in ["merc_1", "merc_2", "merc_3", "merc_4"]:
		var entry := RecoveryService.get_entry(_cond(p), id)
		_check(entry["needs_recovery"] and entry["price"] == 100, "%s needs recovery: $100 (%s)" % [id, str([entry["hp"], entry["mp"], entry["dead"]])])
		var balance := _money(p)
		var r := _recover(p, [id])
		_check(r["success"] and _money(p) == balance - 100 and _full(p, id) and not _cond(p).is_dead(id), "12-14 %s recovered for exactly $100: HP / MP to Max, alive" % id)
	# 15 A healthy living Mercenary: refused, no charge.
	var saves := [0]
	var count := func() -> bool:
		saves[0] += 1
		return true
	var before := _snapshot(p)
	var r := _recover(p, ["merc_1"], count)
	_check(not r["success"] and r["reason"] == RecoveryService.ERR_NOT_NEEDED and _snapshot(p) == before and saves[0] == 0, "15 A healthy Mercenary: ERR_NOT_NEEDED, no $100, nothing saved")
	var entry := RecoveryService.get_entry(_cond(p), "merc_1")
	_check(not entry["needs_recovery"] and entry["price"] == 0, "15 Status: a healthy Mercenary needs nothing, price 0")
	# The price ignores Level / stats / equipment.
	var q := _party(["GUARDIAN", "GUARDIAN"], 1000)
	(q["roster"] as MercenaryRoster).get_mercenary("merc_1")._level = 5
	(q["carrying"] as CharacterCarrying).add_equipment("merc_1", A1, 1)
	EquipmentService.equip(q["carrying"], "merc_1", A1)
	_cond(q).sync()
	_hurt(q, "merc_1", 1, 0)
	_hurt(q, "merc_2", 150, 90)
	_check(RecoveryService.get_entry(_cond(q), "merc_1")["price"] == 100 and RecoveryService.get_entry(_cond(q), "merc_2")["price"] == 100 and RecoveryService.quote(_cond(q), q["wallet"], ["merc_1", "merc_2"])["total"] == 200, "Lv5 + armour missing 1 HP and Lv1 badly hurt: $100 each")
	_sections_done.append("mercenary")


# --- Selection / affordability -------------------------------------------------------------------------------

func _verify_selection() -> void:
	# 16 $250, three eligible, two chosen.
	var p := _party(["GUARDIAN", "MAGE", "STRATEGIST"], 250)
	for id in ["merc_1", "merc_2", "merc_3"]:
		_cond(p).set_condition(id, 0, 1)
	var third := _states(p, ["merc_3"])
	var r := _recover(p, ["merc_1", "merc_2"])
	_check(r["success"] and r["total"] == 200 and _money(p) == 50 and _full(p, "merc_1") and _full(p, "merc_2") and _states(p, ["merc_3"]) == third, "16 $250: 守衛 #1 + 法師 #2 for $200, $50 left, 軍師 #3 unchanged (dead)")
	# 17 $250, all three: refused whole (the Hero too).
	p = _party(["GUARDIAN", "MAGE", "STRATEGIST"], 250)
	for id in ["hero", "merc_1", "merc_2", "merc_3"]:
		_cond(p).set_condition(id, 0, 1)
	var before := _snapshot(p)
	var quote := RecoveryService.quote(_cond(p), p["wallet"], ["merc_1", "merc_2", "merc_3"])
	_check(not quote["success"] and quote["reason"] == RecoveryService.ERR_INSUFFICIENT_FUNDS and quote["total"] == 300 and not quote["affordable"] and _snapshot(p) == before, "17 Quote: 3 x $100 = $300, not affordable with $250 (reads only)")
	r = _recover(p, ["merc_1", "merc_2", "merc_3"])
	_check(not r["success"] and r["reason"] == RecoveryService.ERR_INSUFFICIENT_FUNDS and _money(p) == 250 and _snapshot(p) == before, "17 Recovering all three with $250: refused, $250 kept, nobody recovered (the Hero's free path stays separate)")
	# 18 $99; 19 exactly $100.
	p = _party(["GUARDIAN"], 99)
	_cond(p).set_condition("merc_1", 0, 0)
	before = _snapshot(p)
	r = _recover(p, ["merc_1"])
	_check(not r["success"] and r["reason"] == RecoveryService.ERR_INSUFFICIENT_FUNDS and _money(p) == 99 and _snapshot(p) == before, "18 $99: refused, no recovery, money unchanged (never negative)")
	p = _party(["GUARDIAN"], 100)
	_cond(p).set_condition("merc_1", 0, 0)
	r = _recover(p, ["merc_1"])
	_check(r["success"] and _money(p) == 0 and _full(p, "merc_1"), "19 Exactly $100: recovered, $0 left")
	# Status / quote output for the future UI.
	p = _party(["GUARDIAN", "MAGE"], 180)
	_hurt(p, "hero", 1, 0)
	_cond(p).set_condition("merc_2", 0, 0)
	var status := RecoveryService.get_status(_cond(p), p["wallet"])
	_check(status["balance"] == 180 and status["mercenary_price"] == 100 and status["mercenaries"].map(func(e: Dictionary) -> String: return e["id"]) == ["merc_1", "merc_2"] and not status["mercenaries"][0]["needs_recovery"] and status["mercenaries"][1]["needs_recovery"] and status["mercenaries"][1]["dead"] and status["mercenaries"][1]["price"] == 100, "Status: every owned Mercenary in roster order, who needs recovery, dead, price")
	quote = RecoveryService.quote(_cond(p), p["wallet"], ["merc_2"])
	_check(quote["success"] and quote["total"] == 100 and quote["affordable"] and quote["hero_recovered"] and quote["mercenary_ids"] == ["merc_2"] and quote["balance"] == 180, "Quote: chosen ids, total, affordable, Hero included free")
	_sections_done.append("selection")


# --- Identity / safety ---------------------------------------------------------------------------------------

func _verify_identity() -> void:
	var p := _party(["GUARDIAN", "GUARDIAN", "MAGE"], 1000)
	for id in ["merc_1", "merc_2", "merc_3"]:
		_cond(p).set_condition(id, 0, 0)
	(p["roster"] as MercenaryRoster).pend_legacy(Mercenary.create("merc_a", MercenaryRoster.LEGACY_TYPES["merc_a"]))
	var before := _snapshot(p)
	var cases := [
		["20 duplicate id", ["merc_1", "merc_1"], RecoveryService.ERR_DUPLICATE],
		["21 unknown id", ["merc_9"], RecoveryService.ERR_UNKNOWN_MERCENARY],
		["22 pending id", ["merc_a"], RecoveryService.ERR_UNKNOWN_MERCENARY],
		["24 the Hero as a paid id", ["hero"], RecoveryService.ERR_HERO_SELECTED],
		["24 the Hero among paid ids", ["merc_1", "hero"], RecoveryService.ERR_HERO_SELECTED],
		["a role name", ["GUARDIAN"], RecoveryService.ERR_UNKNOWN_MERCENARY],
		["an empty id", [""], RecoveryService.ERR_UNKNOWN_MERCENARY],
		["a non-string id", [1], RecoveryService.ERR_INVALID_REQUEST],
		["valid + unknown", ["merc_1", "merc_9"], RecoveryService.ERR_UNKNOWN_MERCENARY],
	]
	for c in cases:
		var r := _recover(p, c[1])
		_check(not r["success"] and r["reason"] == c[2] and _snapshot(p) == before, "%s: refused (%s), nothing changes, no charge" % [c[0], r["reason"]])
	_check(not _recover(p, "merc_1")["success"] and not _recover(p, null)["success"] and _snapshot(p) == before, "A request that is not a list: refused")
	_check(_cond(p).get_condition("merc_a") == {} and _cond(p).get_condition("merc_9") == {}, "No condition was created for pending / unknown ids")
	# 23 dismissed.
	var d := _party(["GUARDIAN", "MAGE"], 1000)
	_check(PartyService.dismiss(d["roster"], "merc_2", Callable(), d["carrying"])["success"], "法師 #2 dismissed")
	before = _snapshot(d)
	var r := _recover(d, ["merc_2"])
	_check(not r["success"] and r["reason"] == RecoveryService.ERR_UNKNOWN_MERCENARY and _snapshot(d) == before, "23 A dismissed Mercenary: refused, no charge")
	# 25 / 26 / 27 same-type isolation.
	_cond(p).set_condition("merc_1", 0, 2)
	_hurt(p, "merc_2", 70, 30)
	var merc_2 := _states(p, ["merc_2"])
	var merc_3 := _states(p, ["merc_3"])
	r = _recover(p, ["merc_1"])
	_check(r["success"] and _full(p, "merc_1") and _states(p, ["merc_2"]) == merc_2 and _states(p, ["merc_3"]) == merc_3, "25 / 26 / 27 守衛 #1 recovered; 守衛 #2 (same type) and 法師 #3 keep their exact HP / MP / dead")
	_sections_done.append("identity")


# --- Rollback -----------------------------------------------------------------------------------------------

func _verify_rollback() -> void:
	var p := _party(["GUARDIAN", "MAGE", "STRATEGIST"], 250)
	_cond(p).set_condition("hero", 0, 4)
	_cond(p).set_condition("merc_1", 0, 0)
	_hurt(p, "merc_2", 20, 0)
	_hurt(p, "merc_3", 9, 9)
	var before := _snapshot(p)
	var calls := [0]
	var fail := func() -> bool:
		calls[0] += 1
		return false
	var r := _recover(p, ["merc_1", "merc_2"], fail)
	_check(not r["success"] and r["reason"] == RecoveryService.ERR_SAVE_FAILED and calls[0] == 1, "Save failure: ERR_SAVE_FAILED (tried once)")
	_check(_money(p) == 250, "32 The wallet is exactly $250 again")
	_check(_snapshot(p) == before, "33-36 The Hero, both chosen and the unchosen 軍師 #3: exact previous condition, nothing partial")
	r = RecoveryService.recover_hero(_cond(p), p["wallet"], fail)
	_check(not r["success"] and r["reason"] == RecoveryService.ERR_SAVE_FAILED and _snapshot(p) == before, "recover_hero save failure: the Hero stays dead exactly")
	# Retry after the failure.
	r = _recover(p, ["merc_1", "merc_2"])
	_check(r["success"] and _money(p) == 50 and _full(p, "hero") and _full(p, "merc_1") and _full(p, "merc_2") and not _full(p, "merc_3"), "Retry: §7 example — Hero free, two for $200, $250 -> $50, 軍師 #3 unchanged")
	_sections_done.append("rollback")


# --- Regression boundaries ------------------------------------------------------------------------------------

func _verify_boundaries() -> void:
	var p := _party(["GUARDIAN", "MAGE"], 500)
	var carrying: CharacterCarrying = p["carrying"]
	carrying.add_equipment("merc_1", A1, 1)
	EquipmentService.equip(carrying, "merc_1", A1)
	carrying.add_equipment("merc_2", W2, 2)
	(p["inventory"] as CharacterInventory).add("test_good_01", 3)
	var roster: MercenaryRoster = p["roster"]
	roster.get_mercenary("merc_2")._level = 3
	roster.get_mercenary("merc_2").allocate({"int": 2})
	roster.set_deployment(["merc_2"])
	(p["stats"] as CharacterStats).apply_level(2)
	(p["stats"] as CharacterStats).confirm_allocation({"str": 1})
	_cond(p).sync()
	for id in ["hero", "merc_1", "merc_2"]:
		_cond(p).set_condition(id, 0, 0)
	var other := _other_state(p)
	var r := _recover(p, ["merc_1", "merc_2"])
	_check(r["success"] and _other_state(p) == other, "Recovery changes no equipment, carried gear, goods, allocation, Level, EXP, roster, ids or deployment")
	_sections_done.append("boundaries")


# --- The real game: Save v14 / reload, failures, combat ---------------------------------------------------------

func _verify_game() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	main.wallet.spend(main.wallet.get_balance())
	main.wallet.add(250)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "GUARDIAN"), Mercenary.create("merc_3", "MAGE")], ["merc_1", "merc_2"])
	var c: CharacterCondition = main.condition
	c.sync()
	c.set_condition("hero", 0, 3)
	c.set_condition("merc_1", 0, 0)
	c.set_condition("merc_2", 40, 1)
	c.set_condition("merc_3", 0, 5)
	_check(main._persist(), "Saved: a dead Hero, dead 守衛 #1, hurt 守衛 #2, dead 法師 #3, $250")
	var market: String = JSON.stringify(main.market.get_snapshot())
	var warehouses: String = JSON.stringify(main.warehouses.get_snapshot())
	var status: Dictionary = main.get_recovery_status()
	_check(status["balance"] == 250 and status["hero"]["dead"] and status["mercenaries"].size() == 3, "main.get_recovery_status: the Hospital's view")
	# Save failure through the game's persist.
	main.save_path = BAD_SAVE
	var before := _main_state(main)
	var r: Dictionary = main.recover_characters(["merc_1", "merc_2"])
	_check(not r["success"] and r["reason"] == "ERR_SAVE_FAILED" and _main_state(main) == before and main.wallet.get_balance() == 250, "32-36 Game save failure: $250 and every condition exactly restored")
	main.save_path = TEST_SAVE
	# 31 Mixed: Hero free + two paid.
	r = main.recover_characters(["merc_1", "merc_2"])
	_check(r["success"] and r["hero_recovered"] and r["total"] == 200 and main.wallet.get_balance() == 50, "31 Hero (free) + 守衛 #1 + 守衛 #2: $200, $50 left")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(saved["version"]) == 14 and int(saved["money"]) == 50 and saved["condition"]["hero"]["dead"] == false and saved["condition"]["merc_3"]["dead"] == true, "Saved at once as v14: money $50, Hero alive, 法師 #3 still dead")
	var state := _main_state(main)
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(_main_state(main) == state and main.wallet.get_balance() == 50, "28-31 Reload: the recovered Hero / Mercenaries, the dead 法師 #3 and the exact $50")
	_check(main.condition.get_hp("hero") == main.character_stats.get_max_hp() and main.condition.get_mp("hero") == main.character_stats.get_max_mp(), "28 The Hero at its effective Max HP / MP after reload")
	_check(JSON.stringify(main.market.get_snapshot()) == market and JSON.stringify(main.warehouses.get_snapshot()) == warehouses, "Market and warehouses unchanged")
	# The recovered Mercenary can fight again; the unrecovered one cannot.
	var battle: CombatBattle = await _start_battle(main)
	_check(battle != null and _friend(battle, "merc_1") != null and _friend(battle, "merc_1").hp == _friend(battle, "merc_1").max_hp and battle.get_hero().alive, "Recovered 守衛 #1 and the Hero fight again at full")
	# No recovery during a battle.
	main.condition.set_condition("merc_2", 1, 1)
	before = _main_state(main)
	r = main.recover_characters(["merc_2"])
	var hero_r: Dictionary = main.recover_hero()
	_check(r["reason"] == "ERR_IN_COMBAT" and hero_r["reason"] == "ERR_IN_COMBAT" and _main_state(main) == before and main.wallet.get_balance() == 50, "No recovery during a battle (ERR_IN_COMBAT), nothing changes")
	await _destroy(main)
	_clean()
	_sections_done.append("game")


# --- Scope ------------------------------------------------------------------------------------------------

func _verify_scope() -> void:
	_check(SaveStore.VERSION == 14 and SaveStore.V14_KEYS == SaveStore.V13_KEYS + ["condition"], "Save stays v14 (no new section, no migration)")
	var service := _code_only("res://scripts/recovery_service.gd").to_lower()
	for word in ["penalty", "exp", "level", "equip", "carrying.", "roster.", "inventory", "save_store", "saveStore", "nearest", "distance", "city"]:
		_check(not service.contains(word.to_lower()), "RecoveryService touches no %s" % word)
	_check(service.contains("condition.set_condition(") and service.contains("wallet.spend(") and not service.contains("_records"), "Orchestrates CharacterCondition + Wallet (no second state)")
	_check(RecoveryService.MERCENARY_PRICE == 100 and RecoveryService.HERO_PRICE == 0, "Prices: Mercenary $100, Hero $0")
	var hub := _code_only("res://scripts/city_hub.gd").to_lower()
	_check(not hub.contains("recover") and not hub.contains("hospital"), "No Hospital UI yet")
	_sections_done.append("scope")


# --- Stress (TARGETED) ----------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var wallets := [0, 99, 100, 199, 200, 249, 250, 299, 300, 301, 1000]
	var hero_charged := 0
	var price_bad := 0
	var negative := 0
	var unselected := 0
	var unauthorized := 0
	var other_bad := 0
	var rollback_bad := 0
	var reload_bad := 0
	var query_mutated := 0
	var refused_mutated := 0
	var successes := 0
	var refusals := 0
	var failures := 0
	var hero_recoveries := 0
	var paid_recoveries := 0
	var reasons := {}
	for run in range(400):
		var n := rng.randi_range(0, 3)
		var types := []
		for i in range(n):
			types.append(["GUARDIAN", "GUARDIAN", "MAGE", "STRATEGIST"][rng.randi_range(0, 3)])
		var p := _party(types, wallets[rng.randi_range(0, wallets.size() - 1)])
		if rng.randi_range(0, 3) == 0:
			(p["roster"] as MercenaryRoster).pend_legacy(Mercenary.create("merc_a", MercenaryRoster.LEGACY_TYPES["merc_a"]))
		var ids: Array = _cond(p).get_character_ids()
		for step in range(8):
			# Random conditions: healthy, HP, MP, HP + MP, dead.
			for id in ids:
				var state := _cond(p).get_condition(id)
				match rng.randi_range(0, 5):
					0, 1:
						pass
					2:
						_cond(p).set_condition(id, maxi(state["hp"] - rng.randi_range(1, 50), 1), state["mp"])
					3:
						_cond(p).set_condition(id, state["hp"], state["mp"] - rng.randi_range(1, 50))
					4:
						_cond(p).set_condition(id, maxi(state["hp"] - rng.randi_range(1, 50), 1), state["mp"] - rng.randi_range(1, 50))
					5:
						_cond(p).set_condition(id, 0, rng.randi_range(0, state["max_mp"]))
			# A selection: none / some / all / duplicate / unknown / Hero / pending.
			var mercs := _shuffled(ids.slice(1), rng)
			var selection: Array = mercs.slice(0, rng.randi_range(0, mercs.size()))
			match rng.randi_range(0, 11):
				0:
					if not selection.is_empty():
						selection.append(selection[0])
				1:
					selection.append("merc_9")
				2:
					selection.append("hero")
				3:
					selection.append("merc_a")
			var before := _snapshot(p)
			var other := _other_state(p)
			var balance := _money(p)
			# Queries never change anything.
			RecoveryService.get_status(_cond(p), p["wallet"])
			var q := RecoveryService.quote(_cond(p), p["wallet"], selection)
			if _snapshot(p) != before:
				query_mutated += 1
			var fail := rng.randi_range(0, 5) == 0
			var persist := func() -> bool: return not fail
			var hero_needed := RecoveryService.needs_recovery(_cond(p).get_condition("hero"))
			var r: Dictionary
			var hero_only := rng.randi_range(0, 4) == 0
			if hero_only:
				r = RecoveryService.recover_hero(_cond(p), p["wallet"], persist)
				if r["success"] and _money(p) != balance:
					hero_charged += 1
			else:
				r = RecoveryService.recover(_cond(p), p["wallet"], selection, persist)
			reasons[r["reason"]] = int(reasons.get(r["reason"], 0)) + 1
			if _money(p) < 0:
				negative += 1
			if _other_state(p) != other:
				other_bad += 1
			if r["success"]:
				successes += 1
				var paid: Array = r["mercenary_ids"]
				paid_recoveries += paid.size()
				if balance - _money(p) != paid.size() * 100 or r["total"] != paid.size() * 100:
					price_bad += 1
				if r["hero_recovered"]:
					hero_recoveries += 1
				if hero_needed != r["hero_recovered"] or not _full(p, "hero") and hero_needed:
					hero_charged += 1
				for id in ids:
					var was: Dictionary = before[id]
					if id == "hero" or paid.has(id):
						if not _full(p, id):
							price_bad += 1
					elif _states(p, [id])[id] != was:
						unselected += 1
				if not hero_only and (q["success"] != true or q["total"] != r["total"]):
					price_bad += 1
			else:
				if r["reason"] == RecoveryService.ERR_SAVE_FAILED:
					failures += 1
					if _snapshot(p) != before or _money(p) != balance:
						rollback_bad += 1
				else:
					refusals += 1
					if _snapshot(p) != before or _money(p) != balance:
						refused_mutated += 1
			# Nobody revived / healed unless chosen (or the free Hero).
			for id in ids:
				if before[id]["dead"] and not _cond(p).is_dead(id) and not r["success"]:
					unauthorized += 1
			# Save -> reload.
			if step % 3 == 2:
				var data := _serialize(p)
				var loaded := _load(data)
				if loaded.is_empty():
					reload_bad += 1
				else:
					var next := _party_from(loaded)
					_cond(next).sync()
					if _snapshot(next) != _snapshot(p) or _money(next) != _money(p) or JSON.stringify(_serialize(next)) != JSON.stringify(data):
						reload_bad += 1
					p = next
	print("Stress summary (seed %d): successes %d (Hero %d, paid Mercenaries %d), refusals %d, save failures %d, reasons %s, hero_charged %d, price %d, negative %d, unselected %d, unauthorized %d, other %d, rollback %d, refused_mutated %d, query %d, reload %d" % [_seed, successes, hero_recoveries, paid_recoveries, refusals, failures, str(reasons), hero_charged, price_bad, negative, unselected, unauthorized, other_bad, rollback_bad, refused_mutated, query_mutated, reload_bad])
	_check(paid_recoveries > 300 and successes > 300 and refusals > 300 and failures > 100 and hero_recoveries > 100 and reasons.has(RecoveryService.ERR_INSUFFICIENT_FUNDS) and reasons.has(RecoveryService.ERR_DUPLICATE) and reasons.has(RecoveryService.ERR_HERO_SELECTED) and reasons.has(RecoveryService.ERR_UNKNOWN_MERCENARY) and reasons.has(RecoveryService.ERR_NOT_NEEDED), "Stress coverage: %d successes, %d refusals, %d save failures, %s" % [successes, refusals, failures, str(reasons)])
	_check(hero_charged == 0, "Stress: the Hero always free and recovered when it needed it (%d)" % hero_charged)
	_check(price_bad == 0, "Stress: exactly $100 per recovered Mercenary, everyone recovered reaches Max (%d)" % price_bad)
	_check(negative == 0, "Stress: never a negative wallet (%d)" % negative)
	_check(unselected == 0, "Stress: unselected Mercenaries never changed (%d)" % unselected)
	_check(unauthorized == 0, "Stress: no revival without a successful recovery (%d)" % unauthorized)
	_check(other_bad == 0, "Stress: no equipment / Level / EXP / roster / goods change (%d)" % other_bad)
	_check(rollback_bad == 0, "Stress: every save failure rolled back exactly (%d)" % rollback_bad)
	_check(refused_mutated == 0, "Stress: every refusal changed nothing (%d)" % refused_mutated)
	_check(query_mutated == 0, "Stress: status / quote never change anything (%d)" % query_mutated)
	_check(reload_bad == 0, "Stress: save -> reload reproduces the committed result (%d)" % reload_bad)
	_sections_done.append("stress")


# --- Helpers ----------------------------------------------------------------------------------------------

func _party(types: Array, money: int) -> Dictionary:
	var stats := CharacterStats.new()
	var inventory := CharacterInventory.new("player", stats)
	var roster := MercenaryRoster.new()
	for type in types:
		roster.create_mercenary(type)
	var carrying := CharacterCarrying.new(inventory, func() -> MercenaryRoster: return roster)
	var condition := CharacterCondition.new(func() -> CharacterCarrying: return carrying)
	condition.sync()
	var wallet := Wallet.new()
	wallet.spend(wallet.get_balance())
	if money > 0:
		wallet.add(money)
	return {"carrying": carrying, "roster": roster, "inventory": inventory, "stats": stats, "wallet": wallet, "condition": condition}


func _party_from(loaded: Dictionary) -> Dictionary:
	var carrying: CharacterCarrying = loaded["carrying"]
	var condition := CharacterCondition.new(func() -> CharacterCarrying: return carrying)
	condition.restore_save(loaded["condition"])
	return {"carrying": carrying, "roster": loaded["mercenaries"], "inventory": loaded["inventory"], "stats": loaded["character_stats"], "wallet": loaded["wallet"], "condition": condition}


## A deterministic shuffle (the stress seed alone decides).
func _shuffled(items: Array, rng: RandomNumberGenerator) -> Array:
	var result := items.duplicate()
	for i in range(result.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var swap: Variant = result[i]
		result[i] = result[j]
		result[j] = swap
	return result


func _cond(p: Dictionary) -> CharacterCondition:
	return p["condition"]


func _money(p: Dictionary) -> int:
	return (p["wallet"] as Wallet).get_balance()


func _recover(p: Dictionary, ids: Variant, persist: Callable = Callable()) -> Dictionary:
	return RecoveryService.recover(_cond(p), p["wallet"], ids, persist)


func _hurt(p: Dictionary, id: String, hp_loss: int, mp_loss: int) -> void:
	var state := _cond(p).get_condition(id)
	_cond(p).set_condition(id, state["hp"] - hp_loss, state["mp"] - mp_loss)


func _full(p: Dictionary, id: String) -> bool:
	var state := _cond(p).get_condition(id)
	return not state.is_empty() and not state["dead"] and state["hp"] == state["max_hp"] and state["mp"] == state["max_mp"]


func _states(p: Dictionary, ids: Array) -> Dictionary:
	var result := {}
	for id in ids:
		result[id] = _cond(p).get_condition(id)
	return result


## Every character's condition by id (the Hero + owned).
func _snapshot(p: Dictionary) -> Dictionary:
	var result := _states(p, _cond(p).get_character_ids())
	result["_balance"] = _money(p)
	return result


## Everything recovery must not touch.
func _other_state(p: Dictionary) -> String:
	var carrying: CharacterCarrying = p["carrying"]
	var roster: MercenaryRoster = p["roster"]
	var parts := [roster.to_dict(), roster.pending_to_list(), (p["inventory"] as CharacterInventory).get_items(), (p["stats"] as CharacterStats).get_allocation_points(), (p["stats"] as CharacterStats).get_level() if (p["stats"] as CharacterStats).has_method("get_level") else 0]
	for id in _cond(p).get_character_ids():
		var equipment := carrying.get_equipment(id)
		parts.append([id, equipment.get_equipped_items(), equipment.get_carried(), carrying.get_inventory(id).get_items(), carrying.get_stats(id).get_combat_profile()])
	return JSON.stringify(parts)


func _main_state(main: Node) -> String:
	var parts := [main.wallet.get_balance(), main.mercenary_roster.to_dict()]
	for id in main.condition.get_character_ids():
		parts.append([id, main.condition.get_condition(id)])
	return JSON.stringify(parts)


func _friend(battle: CombatBattle, id: String) -> CombatUnit:
	for unit in battle.get_friends():
		if unit.id == id:
			return unit
	return null


func _serialize(p: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(SaveStore.serialize(p["wallet"], p["inventory"], MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.new(), {"hero": p["stats"]}, p["roster"], p["carrying"], p["condition"])))


func _load(data: Dictionary) -> Dictionary:
	var payload := SaveStore.validate(JSON.parse_string(JSON.stringify(data)))
	return {} if payload.is_empty() else SaveStore._rebuild(payload)


func _start_battle(main: Node) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	return main.get_combat()


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
