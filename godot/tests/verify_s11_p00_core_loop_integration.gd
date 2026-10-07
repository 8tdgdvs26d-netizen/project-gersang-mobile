extends SceneTree

## Stage 11 P00: Core Loop Integration Gate (verification only — no new
## gameplay). One player session through the REAL runtime paths (the City Hub
## signals the buttons emit, the encounter / combat / commit lifecycle, the
## Save v14 store), proving the approved Core Loop is connected end to end:
##   A baseline   wallet, goods, market, Hero progression, condition, roster /
##                deployment, equipment, location, save version recorded
##   buy in A     wallet, backpack, A market, cost lots and the save agree
##   leave A      WORLD, goods intact, no stale city view
##   battle       real Encounter -> Combat -> VICTORY -> commit (exactly
##                once): EXP / Level / growth / Stat Points as settled,
##                condition = the battle's final state, goods / wallet /
##                equipment / roster untouched, back in WORLD, no stale lock
##   to B         the minimum deterministic test mechanism: the player is
##                placed at City B's gate (standing in for the ~180 s walk;
##                no travel mechanic added) and enters through the real
##                Enter button; the stress also uses the existing passenger
##                transport (re-entering A)
##   sell in B    the wallet follows B's quote, B's market changes, the A
##                good's cost lots are consumed FIFO, A's market and
##                everything else preserved
##   leave B      WORLD ready again: no stale encounter / combat / result /
##                city lock; a fresh encounter can start
##   persistence  every step's save equals the runtime (Save v14); a reload
##                restores the whole loop state
##   dev save     only an isolated test save is used; Charlie's Development
##                Save (SaveStore.DEFAULT_PATH) is never touched
##   stress       seeded repeated Core Loops (buy / battle / duplicate-commit
##                attempts / walk or transport / sell / Hospital / reloads)

const TEST_SAVE := "user://s11_p00_core_loop_test.json"
const T0 := 1800000000000
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const GOOD := "test_good_02"
const WEAPON := "test_weapon_01"
const STRESS_ROUNDS := 40

var _checks := 0
var _failures := 0
var _sections_done := []
var _seed := 11000
var _commits := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			_seed = int(arg.substr(7))
	_check(TEST_SAVE != SaveStore.DEFAULT_PATH and not TEST_SAVE.contains("myrial_save"), "The test save is isolated from the Development Save")
	var dev_before := _dev_save_fingerprint()
	await _verify_core_loop()
	await _verify_stress()
	_check(_dev_save_fingerprint() == dev_before, "Charlie's Development Save (%s) is untouched: %s" % [SaveStore.DEFAULT_PATH, str(dev_before)])
	_check(_sections_done.size() == 2, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S11 P00 core loop integration verification passed (%d checks, seed %d)" % [_checks, _seed])
	quit(1 if _failures > 0 else 0)


# --- The Core Loop, step by step ----------------------------------------------------------------------------

func _verify_core_loop() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	var hub := main.get_node("CityHub") as CityHub
	main.battle_result_committed.connect(_on_committed)
	_check(main.location.is_in_world() and main.wallet.get_balance() == Wallet.STARTING_MONEY, "A new game starts in the world with the starting money")

	# 1 City A baseline (a realistic party set up through the hub's own buttons).
	await _enter_city(main, WorldLayout.CITY_A)
	_check(main.location.is_in_city() and main.current_city_id == "A" and hub.visible, "1 Entered City A through the Enter button")
	hub.recruit_requested.emit("GUARDIAN")
	var merc: Mercenary = main.mercenary_roster.get_owned()[0] if main.mercenary_roster.get_owned().size() == 1 else null
	_check(merc != null, "A 守衛 recruited at the 傭兵中心")
	var merc_id := merc.get_id() if merc != null else ""
	hub.deployment_requested.emit(merc_id, true)
	hub.equipment_buy_requested.emit("hero", WEAPON)
	_check(main.equip_character_item("hero", WEAPON)["success"], "The Hero bought and equipped %s" % WEAPON)
	_check(main.mercenary_roster.get_deployed_ids() == [merc_id], "The 守衛 is deployed")
	# Fixture: the Hero 1 EXP short of Lv.2, so this single victory proves
	# level growth (the stress reaches Level Ups by fighting alone).
	main.progression.award("hero", ProgressionState.required_exp(1) - 1)
	main._apply_level_growth()
	_check(main._persist(), "Baseline saved")
	var base := _state(main)
	var base_save := _read_save()
	_check(int(base_save.get("version", 0)) == 14 and _save_matches_runtime(main), "1 Baseline: Save v14, equal to the runtime")
	_check(main.progression.get_level("hero") == 1 and main.inventory.get_quantity(GOOD) == 0 and main.wallet.get_balance() == Wallet.STARTING_MONEY - RecruitmentService.PRICE - EquipmentShopService.get_price(WEAPON), "1 Baseline: Hero Lv.1, no %s, $%d" % [GOOD, main.wallet.get_balance()])

	# 2 Buy in A (the 市場 button: buy_requested).
	main.update_market_recovery()
	var quote_a: Dictionary = main.market.get_quote("A", GOOD)
	_check(_quote_is_independent(main, "A", GOOD, quote_a), "2 A's quote follows the approved market rules (%d / %d)" % [quote_a["buy_price"], quote_a["buyback_price"]])
	var before := _state(main)
	var lots_before: int = main.cost_ledger.get_lots(TradeCostLedger.BACKPACK, GOOD).size()
	hub.buy_requested.emit(GOOD, 10)
	var paid: int = quote_a["buy_price"] * 10
	_check(main.wallet.get_balance() == before["wallet"] - paid, "2 Wallet: -$%d (A's buy price %d x 10)" % [paid, quote_a["buy_price"]])
	_check(main.inventory.get_quantity(GOOD) == 10, "2 Backpack: +10 %s" % GOOD)
	_check(_only_stock_changed(before["market"], main.market.get_snapshot(), "A", GOOD, -10), "2 Market: A's %s stock -10, nothing else" % GOOD)
	var lots: Array = main.cost_ledger.get_lots(TradeCostLedger.BACKPACK, GOOD)
	_check(lots.size() == lots_before + 1 and int(lots[-1]["quantity"]) == 10 and int(lots[-1]["unit_cost"]) == quote_a["buy_price"] and main.cost_ledger.matches(main.inventory.get_items(), main.warehouses), "2 Cost lots: one lot of 10 at %d, in step with the backpack" % quote_a["buy_price"])
	_check(_same_except(before, _state(main), ["wallet", "inventory", "market", "ledger"]), "2 Nothing else changed (progression, roster, equipment, condition, location)")
	_check(_save_matches_runtime(main), "2 Saved at once and equal to the runtime")
	var bought := _state(main)

	# 3 Leave A -> WORLD (the 離開 button).
	hub.leave_requested.emit()
	await _settle()
	_check(_world_ready(main), "3 Back in the world, ready (no city view, moving, no encounter)")
	_check(main.inventory.get_quantity(GOOD) == 10 and _same_except(bought, _state(main), ["location"]), "3 Goods and everything else intact")
	_check(_save_matches_runtime(main), "3 Saved: IN WORLD, equal to the runtime")

	# 4 Encounter -> Combat -> VICTORY -> commit.
	var market_ref := _market_ref(main)
	var pre_battle := _state(main)
	var battle: CombatBattle = await _start_battle(main)
	_check(battle != null and main.get_node("EncounterSession").get_phase() == EncounterSession.Phase.LOCKED, "4 A real encounter locked and the battle opened")
	if battle == null:
		_sections_done.append("core_loop (aborted)")
		await _destroy(main)
		return
	_check(battle.get_friends().size() == 2 and _friend(battle, merc_id) != null, "4 The Hero and the deployed 守衛 fight")
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_enemies()[0], battle.get_hero(), 7)
	battle.get_hero().mp = maxi(0, battle.get_hero().mp - 3)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000000)
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY, "4 VICTORY")
	var result := battle.get_result()
	var shares := PartyProgression.preview(result, main.progression, main.mercenary_roster)
	var finals := _finals(battle)
	var merc_before := [merc.get_level(), merc.get_exp()]
	_commits = 0
	await _exit_battle(main)
	_check(_commits == 1 and result.is_committed(), "4 Committed exactly once through the real exit")
	_check(not main.commit_battle_result(result) and _commits == 1, "4 A second commit is refused")
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(_commits == 1, "4 A second exit press commits nothing")
	_check(shares.has("hero") and shares.has(merc_id) and int(shares["hero"]["exp"]) == result.exp_pool / 2, "4 The EXP pool %d is shared by the 2 survivors" % result.exp_pool)
	_check(main.progression.get_level("hero") == 2 and [main.progression.get_level("hero"), main.progression.get_exp("hero")] == ProgressionState.advance(1, ProgressionState.required_exp(1) - 1, int(shares["hero"]["exp"])), "4 Hero: Lv.2 with the remainder EXP (%d)" % main.progression.get_exp("hero"))
	_check(main.character_stats.get_earned_points() == CharacterStats.earned_points_for(2) and main.character_stats.get_unspent_points() == CharacterStats.earned_points_for(2) - main.character_stats.get_spent_points(), "4 Hero growth: Stat Points = Lv.2's (%d), unspent coherent" % main.character_stats.get_earned_points())
	_check(main.character_stats.get_growth("hp") == int(CharacterConfig.GROWTH_PER_LEVEL["hero"].get("hp", 0)), "4 Hero growth applied for one Level")
	_check([merc.get_level(), merc.get_exp()] == ProgressionState.advance(merc_before[0], merc_before[1], int(shares[merc_id]["exp"])), "4 守衛: its own share settled")
	_check(_condition_matches(main, finals), "4 Condition: every fighter keeps its final HP / MP (not healed)")
	_check(main.inventory.get_quantity(GOOD) == 10 and _same_except(pre_battle, _state(main), ["progression", "roster", "condition", "location", "stats", "market", "recovery"]), "4 Goods, wallet, equipment, deployment and cost lots untouched")
	_check(_market_only_recovered(main, market_ref), "4 Markets: only the approved timed recovery")
	_check(_world_ready(main, true), "4 Back in WORLD: no combat view, no result, no lock, moving")
	_check(_save_matches_runtime(main), "4 The committed result is saved (equal to the runtime)")
	var after_battle := _state(main)

	# 5 Continue to B (deterministic: placed at B's gate, enters through the Enter button).
	market_ref = _market_ref(main)
	await _enter_city(main, WorldLayout.CITY_B)
	_check(main.location.is_in_city() and main.current_city_id == "B" and hub.visible, "5 / 6 Entered City B")
	_check(_same_except(after_battle, _state(main), ["location", "market", "recovery"]) and _market_only_recovered(main, market_ref), "5 Arrived with everything intact")

	# 6 Sell the A good in B (sell_requested).
	main.update_market_recovery()
	var quote_b: Dictionary = main.market.get_quote("B", GOOD)
	_check(_quote_is_independent(main, "B", GOOD, quote_b), "6 B's quote follows the approved market rules (%d / %d)" % [quote_b["buy_price"], quote_b["buyback_price"]])
	var preview: Dictionary = TradeService.preview_sell("B", GOOD, 10, main.inventory, main.market, main.cost_ledger)
	before = _state(main)
	hub.sell_requested.emit(GOOD, 10)
	var revenue: int = quote_b["buyback_price"] * 10
	_check(quote_b["buyback_price"] > quote_a["buy_price"], "6 B's buyback (%d) beats A's buy price (%d): the trade route pays" % [quote_b["buyback_price"], quote_a["buy_price"]])
	_check(main.wallet.get_balance() == before["wallet"] + revenue and int(preview["total_value"]) == revenue, "6 Wallet: +$%d (B's buyback x 10)" % revenue)
	_check(bool(preview["cost_known"]) and int(preview["acquisition_cost"]) == paid and int(preview["realized_profit"]) == revenue - paid, "6 Realized profit %d = revenue - the A lot's cost" % (revenue - paid))
	_check(main.inventory.get_quantity(GOOD) == 0 and main.cost_ledger.get_lots(TradeCostLedger.BACKPACK, GOOD).is_empty() and main.cost_ledger.matches(main.inventory.get_items(), main.warehouses), "6 Backpack empty of %s; its cost lot consumed" % GOOD)
	_check(_only_stock_changed(before["market"], main.market.get_snapshot(), "B", GOOD, 10), "6 Market: B's %s stock +10; A's market untouched" % GOOD)
	_check(_same_except(before, _state(main), ["wallet", "inventory", "market", "ledger"]), "6 Unrelated state preserved")
	_check(main.wallet.get_balance() - base["wallet"] == revenue - paid, "6 One loop's money: %+d" % (revenue - paid))
	_check(_save_matches_runtime(main), "6 Saved at once and equal to the runtime")

	# 7 Leave B -> WORLD ready again; a fresh encounter can start.
	hub.leave_requested.emit()
	await _settle()
	_check(_world_ready(main) and main.location.get_world_position() == WorldLayout.CITY_RETURN_POINTS["B"], "7 Left B: in the world beside B, ready")
	_check(main.get_last_defeat_return_city() == "" and main.get_last_award().has("hero"), "7 No defeat routing; the last award is the victory's")

	# 8 Save / reload.
	var final_state := _state(main)
	var now: int = main.time_source.now_ms()
	_check(_save_matches_runtime(main), "8 Saved state equals the runtime")
	await _destroy(main)
	main = await _new_main(TEST_SAVE, now)
	_check(main.load_status["status"] == SaveStore.STATUS_LOADED, "8 The save loads")
	_check(_same_except(final_state, _state(main), []), "8 Reload restores the whole loop state")
	_check(_world_ready(main), "8 After reload: in the world, ready")
	main.time_source.advance_ms(60000)
	await _settle()
	main.time_source.advance_ms(60000)
	await _settle()
	main.battle_result_committed.connect(_on_committed)
	_commits = 0
	battle = await _start_battle(main)
	_check(battle != null, "8 After reload a new encounter starts (re-departure)")
	if battle != null:
		await _win(main, battle)
		_check(_commits == 1 and _world_ready(main, true), "8 ... and commits once")
	await _destroy(main)
	_clean()
	_sections_done.append("core_loop")


# --- Stress: repeated Core Loops ----------------------------------------------------------------------------

func _verify_stress() -> void:
	_clean()
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var main := await _new_main(TEST_SAVE)
	main.battle_result_committed.connect(_on_committed)
	var hub := main.get_node("CityHub") as CityHub
	await _enter_city(main, WorldLayout.CITY_A)
	hub.recruit_requested.emit(["GUARDIAN", "MAGE", "STRATEGIST"][rng.randi_range(0, 2)])
	var merc_id: String = main.mercenary_roster.get_owned()[0].get_id()
	hub.deployment_requested.emit(merc_id, true)
	var stats := {"rounds": 0, "bought": 0, "sold": 0, "victories": 0, "level_ups": 0, "transport": 0, "walk": 0, "reloads": 0, "duplicates": 0, "refused_trades": 0, "hospital": 0, "transport_refused": 0}
	var bad := {}
	var start_money: int = main.wallet.get_balance()
	var money_in := 0
	var money_out := 0
	for round_index in range(STRESS_ROUNDS):
		stats["rounds"] += 1
		_check(main.current_city_id == "A", "Round %d starts in A" % round_index)
		# Hospital in A (the free Hero treatment; a Mercenary when affordable).
		var c: CharacterCondition = main.condition
		if c.get_hp("hero") * 2 < int(c.get_condition("hero")["max_hp"]) or c.is_dead("hero"):
			_tally(bad, "hospital_hero", main.hospital_recover_hero()["success"])
			stats["hospital"] += 1
		if RecoveryService.needs_recovery(c.get_condition(merc_id)) and (c.is_dead(merc_id) or rng.randf() < 0.3) and main.wallet.get_balance() >= RecoveryService.MERCENARY_PRICE + 2000:
			var w: int = main.wallet.get_balance()
			_tally(bad, "hospital_merc", main.hospital_recover([merc_id])["success"] and main.wallet.get_balance() == w - RecoveryService.MERCENARY_PRICE)
			money_out += RecoveryService.MERCENARY_PRICE
			stats["hospital"] += 1
		# Buy 1-3 orders.
		for order in range(rng.randi_range(1, 3)):
			var good: String = GoodsCatalog.get_ids()[rng.randi_range(0, 5)]
			var qty: int = TradeService.ALLOWED_ORDER_QUANTITIES[rng.randi_range(0, 1)]
			main.update_market_recovery()
			var quote: Dictionary = main.market.get_quote("A", good)
			_tally(bad, "buy_quote", _quote_is_independent(main, "A", good, quote))
			var before := _state(main)
			hub.buy_requested.emit(good, qty)
			if main.wallet.get_balance() == before["wallet"]:
				stats["refused_trades"] += 1
				_tally(bad, "refused_buy_changes_nothing", _state(main) == before)
				continue
			stats["bought"] += qty
			money_out += quote["buy_price"] * qty
			var lot: Dictionary = main.cost_ledger.get_lots(TradeCostLedger.BACKPACK, good)[-1]
			_tally(bad, "buy_wallet", main.wallet.get_balance() == before["wallet"] - quote["buy_price"] * qty)
			_tally(bad, "buy_market", _only_stock_changed(before["market"], main.market.get_snapshot(), "A", good, -qty))
			_tally(bad, "buy_lot", int(lot["quantity"]) == qty and int(lot["unit_cost"]) == quote["buy_price"] and main.cost_ledger.matches(main.inventory.get_items(), main.warehouses))
			_tally(bad, "buy_rest", _same_except(before, _state(main), ["wallet", "inventory", "market", "ledger"]))
			_tally(bad, "buy_saved", _save_matches_runtime(main))
		var cargo: Dictionary = main.inventory.get_items()
		# Leave A.
		hub.leave_requested.emit()
		await _settle()
		_tally(bad, "left_a_ready", _world_ready(main) and main.inventory.get_items() == cargo)
		# Battle -> VICTORY (with duplicate-commit attempts).
		await _respawn(main)
		var market_ref := _market_ref(main)
		var pre := _state(main)
		var battle: CombatBattle = await _start_battle(main)
		if battle == null:
			_tally(bad, "battle_started", false)
			break
		battle.advance(CombatConfig.PREPARATION_MS)
		if rng.randf() < 0.7:
			battle.resolve_damage(battle.get_enemies()[0], battle.get_hero(), rng.randi_range(1, 25))
		for enemy in battle.get_enemies():
			battle.resolve_damage(battle.get_hero() if battle.get_hero().alive else battle.get_friends()[1], enemy, 1000000)
		_tally(bad, "victory", battle.get_phase() == CombatBattle.Phase.VICTORY)
		var result := battle.get_result()
		var shares := PartyProgression.preview(result, main.progression, main.mercenary_roster)
		var finals := _finals(battle)
		var level_before: int = main.progression.get_level("hero")
		_commits = 0
		if rng.randf() < 0.5:
			# The result is committed straight away (as the exit does) and the
			# exit button is pressed afterwards anyway.
			await process_frame
			_tally(bad, "direct_commit", main.commit_battle_result(result))
			stats["duplicates"] += 1
		await _exit_battle(main)
		for extra in range(rng.randi_range(0, 2)):
			stats["duplicates"] += 1
			_tally(bad, "duplicate_refused", not main.commit_battle_result(result))
			(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
			await process_frame
		_tally(bad, "committed_once", _commits == 1 and result.is_committed())
		stats["victories"] += 1
		var hero_share: Dictionary = shares.get("hero", {})
		if not hero_share.is_empty():
			_tally(bad, "hero_exp", main.progression.get_level("hero") == int(hero_share["level"]))
			if bool(hero_share["leveled"]):
				stats["level_ups"] += 1
		var level: int = main.progression.get_level("hero")
		_tally(bad, "stat_points", main.character_stats.get_earned_points() == CharacterStats.earned_points_for(level) and level >= level_before)
		_tally(bad, "condition", _condition_matches(main, finals))
		_tally(bad, "battle_rest", _same_except(pre, _state(main), ["progression", "roster", "condition", "location", "stats", "market", "recovery"]))
		_tally(bad, "battle_market", _market_only_recovered(main, market_ref))
		_tally(bad, "battle_world_ready", _world_ready(main, true))
		_tally(bad, "battle_saved", _save_matches_runtime(main))
		# To B: walk (placed at B's gate) or the passenger transport from A.
		market_ref = _market_ref(main)
		pre = _state(main)
		var fare: int = TransportRoutes.get_route("A", "B")["fare"]
		var by_transport := rng.randf() >= 0.5
		if by_transport:
			await _enter_city(main, WorldLayout.CITY_A)
			_tally(bad, "reentered_a", main.current_city_id == "A")
			if main.wallet.get_balance() < fare:
				# The existing transport refuses an unaffordable fare (金錢不足)
				# and changes nothing; the player walks instead.
				stats["transport_refused"] += 1
				var refused := _state(main)
				hub.transport_requested.emit("B", "s11_%d_%d" % [_seed, round_index])
				_tally(bad, "transport_refused", not main.is_traveling() and main.current_city_id == "A" and _same_except(refused, _state(main), []))
				hub.leave_requested.emit()
				await _settle()
				by_transport = false
		if not by_transport:
			stats["walk"] += 1
			await _enter_city(main, WorldLayout.CITY_B)
			_tally(bad, "walk_b", main.current_city_id == "B" and _same_except(pre, _state(main), ["location", "market", "recovery"]))
		else:
			stats["transport"] += 1
			hub.transport_requested.emit("B", "s11_%d_%d" % [_seed, round_index])
			_tally(bad, "transport_started", main.is_traveling() and main.wallet.get_balance() == pre["wallet"] - fare)
			money_out += fare
			main.time_source.advance_ms(TransportRoutes.get_route("A", "B")["duration_ms"])
			await _settle()
			_tally(bad, "transport_b", main.current_city_id == "B" and _same_except(pre, _state(main), ["location", "market", "recovery", "wallet"]))
		_tally(bad, "to_b_market", _market_only_recovered(main, market_ref))
		_tally(bad, "to_b_saved", _save_matches_runtime(main))
		# Sell everything in B (orders of 10, then 1).
		for good in GoodsCatalog.get_ids():
			while main.inventory.get_quantity(good) > 0:
				var qty: int = 10 if main.inventory.get_quantity(good) >= 10 else 1
				main.update_market_recovery()
				var preview: Dictionary = TradeService.preview_sell("B", good, qty, main.inventory, main.market, main.cost_ledger)
				var before_quote: Dictionary = main.market.get_quote("B", good)
				_tally(bad, "sell_quote", _quote_is_independent(main, "B", good, before_quote))
				var before := _state(main)
				hub.sell_requested.emit(good, qty)
				stats["sold"] += qty
				money_in += int(preview["total_value"])
				_tally(bad, "sell_wallet", main.wallet.get_balance() == before["wallet"] + int(preview["total_value"]) and int(preview["total_value"]) == int(before_quote["buyback_price"]) * qty)
				_tally(bad, "sell_profit", bool(preview["cost_known"]) and int(preview["realized_profit"]) == int(preview["total_value"]) - int(preview["acquisition_cost"]))
				_tally(bad, "sell_market", _only_stock_changed(before["market"], main.market.get_snapshot(), "B", good, qty))
				_tally(bad, "sell_lots", main.cost_ledger.matches(main.inventory.get_items(), main.warehouses))
				_tally(bad, "sell_rest", _same_except(before, _state(main), ["wallet", "inventory", "market", "ledger"]))
				_tally(bad, "sell_saved", _save_matches_runtime(main))
				if main.wallet.get_balance() == before["wallet"]:
					break
		_tally(bad, "sold_all", main.inventory.get_items().is_empty() and main.cost_ledger.get_quantities(TradeCostLedger.BACKPACK).is_empty())
		# Leave B -> WORLD ready.
		hub.leave_requested.emit()
		await _settle()
		_tally(bad, "left_b_ready", _world_ready(main) and main.location.get_world_position() == WorldLayout.CITY_RETURN_POINTS["B"])
		# Save / reload now and then.
		if rng.randf() < 0.3:
			stats["reloads"] += 1
			var snapshot := _state(main)
			var now: int = main.time_source.now_ms()
			await _destroy(main)
			main = await _new_main(TEST_SAVE, now)
			main.battle_result_committed.connect(_on_committed)
			hub = main.get_node("CityHub") as CityHub
			_tally(bad, "reload_state", main.load_status["status"] == SaveStore.STATUS_LOADED and _same_except(snapshot, _state(main), []) and _world_ready(main))
		# Back to A: walk or the transport from B.
		pre = _state(main)
		if rng.randf() < 0.5:
			await _enter_city(main, WorldLayout.CITY_A)
		else:
			await _enter_city(main, WorldLayout.CITY_B)
			if main.wallet.get_balance() >= TransportRoutes.get_route("B", "A")["fare"]:
				hub.transport_requested.emit("A", "s11_back_%d_%d" % [_seed, round_index])
				money_out += TransportRoutes.get_route("B", "A")["fare"]
				main.time_source.advance_ms(TransportRoutes.get_route("B", "A")["duration_ms"])
				await _settle()
			else:
				hub.leave_requested.emit()
				await _settle()
				await _enter_city(main, WorldLayout.CITY_A)
		_tally(bad, "back_in_a", main.current_city_id == "A" and main.inventory.get_items().is_empty())
	_check(bad.is_empty(), "Stress: every invariant held in every round (failures: %s)" % str(bad))
	_check(main.wallet.get_balance() == start_money + money_in - money_out, "Stress money: start %d + sales %d - purchases / fares / Hospital %d = %d" % [start_money, money_in, money_out, main.wallet.get_balance()])
	_check(stats["rounds"] == STRESS_ROUNDS and stats["victories"] == STRESS_ROUNDS and stats["bought"] > 0 and stats["sold"] == stats["bought"], "Stress coverage: %s" % str(stats))
	_check(stats["walk"] > 0 and stats["transport"] > 0 and stats["reloads"] > 0 and stats["duplicates"] > 0 and stats["level_ups"] > 0, "Stress paths covered: %s" % str(stats))
	print("S11 P00 stress (seed %d): %s" % [_seed, str(stats)])
	await _destroy(main)
	_clean()
	_sections_done.append("stress")


# --- Helpers -------------------------------------------------------------------------------------------

func _on_committed(_result: BattleResult, _saved: bool) -> void:
	_commits += 1


## The whole loop-relevant runtime state, comparable with ==.
func _state(main: Node) -> Dictionary:
	var roster := []
	for m in main.mercenary_roster.get_owned():
		roster.append([m.get_id(), m.get_type(), m.get_level(), m.get_exp(), m.get_allocation_points()])
	var equipment := []
	var condition := []
	for id in main.condition.get_character_ids():
		var e: CharacterEquipment = main.carrying.get_equipment(id)
		equipment.append([id, e.get_equipped_items(), e.get_carried()])
		condition.append([id, main.condition.get_condition(id)])
	return {
		"wallet": main.wallet.get_balance(),
		"inventory": main.inventory.get_items(),
		"market": main.market.get_snapshot(),
		"ledger": main.cost_ledger.get_snapshot(),
		"warehouses": main.warehouses.get_snapshot(),
		"progression": main.progression.to_dict(),
		"stats": [main.character_stats.get_allocation_points(), main.character_stats.get_earned_points()],
		"roster": roster,
		"deployed": main.mercenary_roster.get_deployed_ids(),
		"equipment": equipment,
		"condition": condition,
		"location": main.location.to_dict(),
		"recovery": main.market_recovery.to_dict(),
	}


func _same_except(a: Dictionary, b: Dictionary, keys: Array) -> bool:
	for key in a:
		if not key in keys and JSON.stringify(a[key], "", true) != JSON.stringify(b[key], "", true):
			push_warning("S11 P00: '%s' changed: %s -> %s" % [key, str(a[key]), str(b[key])])
			return false
	return true


## `after` = `before` with only (city, good)'s current stock moved by `delta`.
func _only_stock_changed(before: Dictionary, after: Dictionary, city: String, good: String, delta: int) -> bool:
	var expected := before.duplicate(true)
	expected[city][good]["current_stock"] += delta
	return JSON.stringify(expected, "", true) == JSON.stringify(after, "", true)


## `quote` = the approved pricing recomputed independently of MarketState:
## MarketPrices' baseline + the stock -> MarketRules' buy / buyback prices
## (the buyback below the buy price: no free round trip in one city).
func _quote_is_independent(main: Node, city: String, good: String, quote: Dictionary) -> bool:
	var entry: Dictionary = main.market.get_snapshot()[city][good]
	var dynamic := MarketRules.dynamic_reference(MarketPrices.get_price(city, good), int(entry["current_stock"]), int(entry["target_stock"]))
	return int(entry["reference_price"]) == MarketPrices.get_price(city, good) \
		and int(quote["buy_price"]) == MarketRules.buy_price(dynamic) and int(quote["buyback_price"]) == MarketRules.buyback_price(dynamic) \
		and int(quote["buyback_price"]) < int(quote["buy_price"])


func _market_ref(main: Node) -> Array:
	main.update_market_recovery()
	return [main.market.get_snapshot(), main.market_recovery.to_dict()]


## The markets changed only by the timed recovery since `ref` (replayed on a copy).
func _market_only_recovered(main: Node, ref: Array) -> bool:
	main.update_market_recovery()
	var market := MarketState.from_snapshot(ref[0])
	var recovery := MarketRecovery.from_dict(ref[1])
	recovery.advance(market, main.time_source.now_ms())
	return JSON.stringify(market.get_snapshot(), "", true) == JSON.stringify(main.market.get_snapshot(), "", true) \
		and JSON.stringify(recovery.to_dict(), "", true) == JSON.stringify(main.market_recovery.to_dict(), "", true)


func _finals(battle: CombatBattle) -> Dictionary:
	var finals := {}
	for unit in battle.get_friends():
		finals[unit.id] = [unit.hp if unit.alive else 0, unit.mp, not unit.alive]
	return finals


func _condition_matches(main: Node, finals: Dictionary) -> bool:
	for id in finals:
		var state: Dictionary = main.condition.get_condition(id)
		var hp: int = mini(int(finals[id][0]), int(state["max_hp"]))
		var mp: int = mini(int(finals[id][1]), int(state["max_mp"]))
		if int(state["hp"]) != hp or int(state["mp"]) != mp or bool(state["dead"]) != bool(finals[id][2]):
			push_warning("S11 P00: condition %s = %s, battle final %s" % [id, str(state), str(finals[id])])
			return false
	return true


## In WORLD and free to move: no city view, no combat view / battle, no
## encounter phase or context, no character panel lock.
func _world_ready(main: Node, after_battle: bool = false) -> bool:
	var session := main.get_node("EncounterSession") as EncounterSession
	var ok: bool = main.location.is_in_world() and not main.is_in_city() and main.current_city_id == "" \
		and not (main.get_node("CityHub") as CityHub).visible \
		and main.get_combat() == null and not (main.get_node("CombatView") as CombatView).is_open() \
		and session.get_phase() == EncounterSession.Phase.NONE and session.get_context() == null \
		and (main.get_node("Actors/Player") as Player).is_physics_processing() \
		and not (main.get_node("Actors/Player") as Player).movement_locked
	if after_battle:
		# The approved post-battle protection (C02) is the only thing left.
		ok = ok and session.is_protection_active()
	if not ok:
		push_warning("S11 P00: world not ready (mode %s, phase %d, combat %s)" % [main.location.get_mode(), session.get_phase(), str(main.get_combat())])
	return ok


func _read_save() -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	return data if typeof(data) == TYPE_DICTIONARY else {}


## The save file holds exactly the runtime state (Save v14).
func _save_matches_runtime(main: Node) -> bool:
	var file := _read_save()
	var live: Variant = JSON.parse_string(JSON.stringify(SaveStore.serialize(main.wallet, main.inventory, main.market, main.location, main.warehouses, main.market_recovery, main.cost_ledger, main.progression, main.get_party_stats(), main.mercenary_roster, main.carrying, main.condition)))
	var ok := int(file.get("version", 0)) == 14 and SaveStore.VERSION == 14 and JSON.stringify(file, "", true) == JSON.stringify(live, "", true)
	if not ok:
		push_warning("S11 P00: save differs from the runtime")
	return ok


## Every Development Save file (myrial_save*) in user://: name, size, MD5.
func _dev_save_fingerprint() -> Array:
	var found := []
	var dir := DirAccess.open("user://")
	if dir == null:
		return found
	for file in dir.get_files():
		if file.begins_with(SaveStore.DEFAULT_PATH.get_file().get_basename()):
			var path := "user://" + file
			found.append([file, FileAccess.get_file_as_bytes(path).size(), FileAccess.get_md5(path), FileAccess.get_modified_time(path)])
	found.sort()
	return found


func _tally(bad: Dictionary, name: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		bad[name] = int(bad.get(name, 0)) + 1


func _enter_city(main: Node, at: Vector2) -> void:
	(main.get_node("Actors/Player") as Player).global_position = at
	await _settle()
	(main.get_node("EnterControls/EnterCityButton") as Button).pressed.emit()
	await _settle()


func _start_battle(main: Node) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	return main.get_combat()


func _win(main: Node, battle: CombatBattle) -> void:
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000000)
	await _exit_battle(main)


func _exit_battle(main: Node) -> void:
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()


## Waits (in the world) until the defeated group is back at its home.
func _respawn(main: Node) -> void:
	main.time_source.advance_ms(60000)
	await _settle()
	main.time_source.advance_ms(60000)
	await _settle()


func _friend(battle: CombatBattle, id: String) -> CombatUnit:
	for unit in battle.get_friends():
		if unit.id == id:
			return unit
	return null


func _clean() -> void:
	for p in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


## `now`: the clock to resume at (a reload continues the session's time).
func _new_main(path: String, now: int = T0) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	main.time_source = TimeSource.fixed(now)
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


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
