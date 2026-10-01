extends SceneTree

## T04 Market Recovery / Restock: every 12 s of market time each city x good
## stock moves 1 unit toward its target (never past it); at most 30 minutes of
## elapsed time count; trades never reset the market timeline; the save keeps
## the recovery anchor. Uses its own save files and a fixed TimeSource.

const DynamicPriceModel := preload("res://tests/dynamic_price_model.gd")
const RecoveryModel := preload("res://tests/market_recovery_model.gd")
const TEST_SAVE := "user://t04_market_recovery_test_save.json"
const UNWRITABLE_SAVE := "user://t04_missing_dir/nested/save.json"
const T0 := 1800000000000
const STEP := 12000
const HOUR := 3600000
const IDS := ["test_good_01", "test_good_02", "test_good_03", "test_good_04", "test_good_05", "test_good_06"]
const CITIES := ["A", "B"]
const IN_CITY_A := {"mode": "IN_CITY", "city_id": "A", "journey": null, "last_journey_id": "", "world_position": null}

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	_verify_basic_rules()
	_verify_remainder_and_cap()
	_verify_timestamp_safety()
	_verify_determinism()
	_verify_trades()
	await _verify_game_trade_timer()
	await _verify_save_reload()
	await _verify_migration()
	await _verify_independence()
	await _verify_live_ui()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 11, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("T04 market recovery verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(MarketRecovery.STEP_MS == 12000 and MarketRecovery.STOCK_PER_STEP == 1, "Approved rule: 1 stock unit every 12 seconds")
	_check(MarketRecovery.MAX_ELAPSED_MS == 30 * 60 * 1000, "Approved offline cap: 30 minutes")
	_check(MarketPrices.TARGET_STOCK == 100 and MarketPrices.INITIAL_STOCK == 100, "Target stock stays 100")
	_check(SaveStore.VERSION == 9 and SaveStore.V9_KEYS.has("market_recovery") and SaveStore.V6_KEYS.has("market_recovery") and SaveStore.V7_KEYS.has("market_recovery") and SaveStore.V8_KEYS.has("market_recovery"), "Save version 6 (and T05's 7, T06's 8) carries the market recovery anchor")
	var recovery := _code_only("res://scripts/market_recovery.gd")
	for clock in ["Time.", "OS.get_", "get_ticks"]:
		_check(not recovery.contains(clock), "Recovery must take time from its caller, never read %s" % clock)
	var rules := _code_only("res://scripts/market_rules.gd")
	_check(not rules.contains("Recovery") and not rules.contains("anchor") and not rules.contains("_ms"), "MarketRules stays pricing-only (no timing state)")
	var trade := _code_only("res://scripts/trade_service.gd")
	_check(not trade.contains("Recovery") and not trade.contains("recover") and not trade.contains("anchor"), "Trades never touch the recovery timeline")
	for path in ["res://scripts/warehouse_service.gd", "res://scripts/transport_service.gd", "res://scripts/character_inventory.gd", "res://scripts/city_hub.gd"]:
		var code := _code_only(path)
		_check(not code.contains("MarketRecovery") and not code.contains("recover_toward_target"), "%s must not drive market recovery" % path)
	# One authoritative implementation: only MarketRecovery calls the stock step.
	var main := _code_only("res://scripts/main.gd")
	_check(not main.contains("recover_toward_target") and main.count("market_recovery.advance(") == 1, "main.gd advances recovery in exactly one place")
	_check(not _code_only("res://scripts/save_store.gd").contains("recover_toward_target") and not _code_only("res://scripts/save_store.gd").contains(".advance("), "The save loader never applies recovery itself")
	# No countdown / restock UI.
	var hub := FileAccess.get_file_as_string("res://scripts/city_hub.gd") + FileAccess.get_file_as_string("res://scenes/city_hub.tscn")
	for word in ["補貨", "補給", "恢復", "下次"]:
		_check(not hub.contains(word), "The market UI must not add restock / countdown text (%s)" % word)
	_sections_done.append("static")


# --- Core rules -------------------------------------------------------------------------------

func _verify_basic_rules() -> void:
	var market := _market_with({"A": {"test_good_01": 60, "test_good_02": 140}, "B": {"test_good_01": 95}})
	var recovery := MarketRecovery.new()
	_check(not recovery.is_anchored(), "A new recovery has no anchor")
	var first := recovery.advance(market, T0)
	_check(first["steps"] == 0 and not first["changed"] and recovery.anchor_ms == T0, "The first advance only anchors the timeline")
	var r1 := recovery.advance(market, T0 + STEP)
	_check(r1["steps"] == 1 and r1["changed"], "One full 12 s interval is one step")
	_check(_stock(market, "A", "test_good_01") == 61, "Stock below target rises by exactly 1 per step")
	_check(_stock(market, "A", "test_good_02") == 139, "Stock above target falls by exactly 1 per step")
	_check(_stock(market, "A", "test_good_03") == 100, "Stock at target does not move")
	_check(_stock(market, "B", "test_good_01") == 96, "Every city x good recovers on its own")
	var r2 := recovery.advance(market, T0 + 3 * STEP)
	_check(r2["steps"] == 2 and _stock(market, "A", "test_good_01") == 63 and _stock(market, "A", "test_good_02") == 137, "24 s changes stock by exactly 2")
	var r3 := recovery.advance(market, T0 + 4 * STEP - 1)
	_check(r3["steps"] == 0 and not r3["changed"] and _stock(market, "A", "test_good_01") == 63 and recovery.anchor_ms == T0 + 3 * STEP, "A partial interval under 12 s changes nothing")
	# Full at-target market never changes, however long.
	var calm := MarketState.create_default()
	var calm_before := calm.get_snapshot()
	var calm_recovery := MarketRecovery.new()
	calm_recovery.advance(calm, T0)
	var calm_result := calm_recovery.advance(calm, T0 + HOUR)
	_check(calm_result["steps"] == 150 and not calm_result["changed"] and calm.get_snapshot() == calm_before, "Stock at target stays exactly at target")

	# No overshoot, from below and above, step by step.
	var edge := _market_with({"A": {"test_good_01": 95, "test_good_02": 105, "test_good_03": 99, "test_good_04": 101}})
	var edge_recovery := MarketRecovery.new()
	edge_recovery.advance(edge, T0)
	var below := [95]
	var above := [105]
	var crossed := false
	for step in range(1, 21):
		edge_recovery.advance(edge, T0 + step * STEP)
		below.append(_stock(edge, "A", "test_good_01"))
		above.append(_stock(edge, "A", "test_good_02"))
		if _stock(edge, "A", "test_good_03") != 100 or _stock(edge, "A", "test_good_04") != 100:
			crossed = true
	_check(below == [95, 96, 97, 98, 99, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100], "95 -> 96 -> ... -> 100 -> STOP (%s)" % str(below))
	_check(above == [105, 104, 103, 102, 101, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100], "105 -> 104 -> ... -> 100 -> STOP (%s)" % str(above))
	_check(not crossed, "99 never becomes 101 and 101 never becomes 99")
	var jump := _market_with({"A": {"test_good_01": 99, "test_good_02": 101}})
	_check(jump.recover_toward_target(50) and _stock(jump, "A", "test_good_01") == 100 and _stock(jump, "A", "test_good_02") == 100, "A large step count still stops exactly at target")

	# Independence: every entry follows its own stock and target only.
	var mixed := _market_with({"A": {"test_good_01": 10, "test_good_02": 100}, "B": {"test_good_01": 180, "test_good_02": 97}})
	var mixed_before := mixed.get_snapshot()
	var mixed_recovery := MarketRecovery.new()
	mixed_recovery.advance(mixed, T0)
	mixed_recovery.advance(mixed, T0 + 5 * STEP)
	_check(mixed.get_snapshot() == RecoveryModel.recovered_snapshot(mixed_before, 5), "Each city x good matches the independent model")
	_check(_stock(mixed, "A", "test_good_01") == 15 and _stock(mixed, "B", "test_good_01") == 175, "City A good 01 recovery does not alter City B good 01")
	_check(_stock(mixed, "A", "test_good_02") == 100 and _stock(mixed, "B", "test_good_02") == 100, "Good 01 recovery does not alter good 02")

	# Price follows stock; baseline and target never change.
	var priced := _market_with({"A": {"test_good_01": 60}, "B": {"test_good_05": 150}})
	var low_before := priced.get_quote("A", "test_good_01")
	var high_before := priced.get_quote("B", "test_good_05")
	var priced_recovery := MarketRecovery.new()
	priced_recovery.advance(priced, T0)
	priced_recovery.advance(priced, T0 + 10 * STEP)
	var low_after := priced.get_quote("A", "test_good_01")
	var high_after := priced.get_quote("B", "test_good_05")
	_check(low_after["stock"] == 70 and low_after["dynamic_reference_price"] == DynamicPriceModel.dynamic_reference(80, 70), "Recovered stock gives the dynamic price of the new stock")
	_check(low_after["buy_price"] == DynamicPriceModel.buy(80, 70) and low_after["buyback_price"] == DynamicPriceModel.buyback(80, 70), "Buy and buyback follow the recovered stock")
	_check(low_after["buy_price"] < low_before["buy_price"] and low_after["buy_price"] >= 84, "Low stock restocks: price falls back toward normal")
	_check(high_after["stock"] == 140 and high_after["buy_price"] > high_before["buy_price"] and high_after["buy_price"] <= MarketRules.buy_price(1700), "Oversupply is absorbed: price rises back toward normal")
	var targets_ok := true
	for city in CITIES:
		for good_id in IDS:
			var entry: Dictionary = priced.get_snapshot()[city][good_id]
			if entry["reference_price"] != MarketPrices.get_price(city, good_id) or entry["target_stock"] != 100:
				targets_ok = false
	_check(targets_ok, "Recovery never changes the baseline reference price or the target stock")
	_check(not priced.get_snapshot()["A"]["test_good_01"].has("dynamic_reference_price"), "Recovery never stores prices")
	_sections_done.append("basic_rules")


func _verify_remainder_and_cap() -> void:
	# 29 s: 2 steps, the 5 s remainder counts toward the next step.
	var market := _market_with({"A": {"test_good_01": 50}})
	var recovery := MarketRecovery.new()
	recovery.advance(market, T0)
	var r := recovery.advance(market, T0 + 29000)
	_check(r["steps"] == 2 and _stock(market, "A", "test_good_01") == 52 and recovery.anchor_ms == T0 + 24000, "29 s applies 2 steps and keeps the 5 s remainder")
	r = recovery.advance(market, T0 + 35999)
	_check(r["steps"] == 0 and _stock(market, "A", "test_good_01") == 52, "Remainder 5 s + 6.999 s is still under one step")
	r = recovery.advance(market, T0 + 36000)
	_check(r["steps"] == 1 and _stock(market, "A", "test_good_01") == 53, "Remainder 5 s + 7 s completes the third step at 36 s")
	# Many small or irregular updates equal one large one (frame drops lose nothing).
	var chunked := _market_with({"A": {"test_good_01": 0}, "B": {"test_good_06": 200}})
	var single := _market_with({"A": {"test_good_01": 0}, "B": {"test_good_06": 200}})
	var chunked_recovery := MarketRecovery.new()
	var single_recovery := MarketRecovery.new()
	chunked_recovery.advance(chunked, T0)
	single_recovery.advance(single, T0)
	var now := T0
	for delta in [16, 17, 1000, 5000, 11999, 1, 12000, 36000, 3, 7777, 250, 24001]:
		now += delta
		chunked_recovery.advance(chunked, now)
	single_recovery.advance(single, now)
	_check(chunked.get_snapshot() == single.get_snapshot() and chunked_recovery.anchor_ms == single_recovery.anchor_ms, "Irregular frames give exactly the same stock and anchor as one update")
	_check(_stock(single, "A", "test_good_01") == RecoveryModel.steps_for_ms(now - T0), "Elapsed-time steps, not callback count")
	# Offline cap: 1 hour counts as 30 minutes = 150 steps.
	var capped := _market_with({"A": {"test_good_01": 0}, "B": {"test_good_01": 400}})
	var capped_recovery := MarketRecovery.new()
	capped_recovery.advance(capped, T0)
	var c := capped_recovery.advance(capped, T0 + HOUR)
	_check(c["steps"] == 150 and _stock(capped, "B", "test_good_01") == 250, "At most 30 minutes (150 steps) count: 400 -> 250")
	_check(_stock(capped, "A", "test_good_01") == 100, "0 -> 100 within the cap, then stops at target")
	_check(capped_recovery.anchor_ms == T0 + HOUR, "After a capped update the timeline continues from now")
	c = capped_recovery.advance(capped, T0 + HOUR + STEP)
	_check(c["steps"] == 1 and _stock(capped, "B", "test_good_01") == 249, "Recovery continues normally after the cap")
	# Exactly 30 minutes and a little over.
	var exact := _market_with({"A": {"test_good_01": 400}})
	var exact_recovery := MarketRecovery.new()
	exact_recovery.advance(exact, T0)
	exact_recovery.advance(exact, T0 + 1800000 + 11999)
	_check(_stock(exact, "A", "test_good_01") == 250, "30 min + 11.999 s still counts only 150 steps")
	# A gigantic elapsed time.
	var huge := _market_with({"A": {"test_good_01": 0, "test_good_02": 9000}})
	var huge_recovery := MarketRecovery.new()
	huge_recovery.advance(huge, 0)
	var h := huge_recovery.advance(huge, MarketRecovery.MAX_ANCHOR_MS)
	_check(h["steps"] == 150 and _stock(huge, "A", "test_good_01") == 100 and _stock(huge, "A", "test_good_02") == 8850, "Extremely long elapsed time is capped and cannot pass target")
	_check(MarketRecovery.steps_for(1800000) == 150 and MarketRecovery.steps_for(HOUR) == 150 and MarketRecovery.steps_for(120000) == 10, "steps_for: 120 s = 10, 30 min = 150, 1 h = 150")
	_sections_done.append("remainder_and_cap")


func _verify_timestamp_safety() -> void:
	# Future anchor (clock moved back / negative elapsed): no stock change, re-anchor to now.
	var market := _market_with({"A": {"test_good_01": 60, "test_good_02": 140}})
	var before := market.get_snapshot()
	var recovery := MarketRecovery.from_dict({"anchor_ms": T0 + HOUR})
	var r := recovery.advance(market, T0)
	_check(r["steps"] == 0 and not r["changed"] and market.get_snapshot() == before, "A future timestamp applies zero recovery")
	_check(recovery.anchor_ms == T0, "A future timestamp re-anchors at now, never reversing stock")
	r = recovery.advance(market, T0 - 5000)
	_check(r["steps"] == 0 and market.get_snapshot() == before and recovery.anchor_ms == T0 - 5000, "Negative elapsed time applies zero recovery")
	r = recovery.advance(market, T0 - 5000 + STEP)
	_check(r["steps"] == 1 and _stock(market, "A", "test_good_01") == 61, "Recovery resumes normally after a clock step back")
	for elapsed in [-1, 0, -HOUR, 11999, 1.5, "12000", null]:
		_check(MarketRecovery.steps_for(elapsed) == 0, "steps_for(%s) must be 0" % str(elapsed))
	# Invalid "now" values change nothing.
	var still := _market_with({"A": {"test_good_01": 60}})
	var still_recovery := MarketRecovery.from_dict({"anchor_ms": T0})
	for bad_now in [-1, 1.5e12, "1800000012000", null, MarketRecovery.MAX_ANCHOR_MS + 1]:
		var bad := still_recovery.advance(still, bad_now)
		_check(bad["steps"] == 0 and _stock(still, "A", "test_good_01") == 60 and still_recovery.anchor_ms == T0, "Invalid now %s changes nothing" % str(bad_now))
	_check(still_recovery.advance(null, T0 + STEP)["steps"] == 0 and still_recovery.anchor_ms == T0, "A missing market changes nothing")
	# Malformed saved anchors become "no anchor": zero recovery, then normal.
	var malformed := {
		"null": null, "string": "abc", "array": [T0], "empty dict": {}, "string anchor": {"anchor_ms": "1800000000000"},
		"negative": {"anchor_ms": -5}, "fraction": {"anchor_ms": 1.5}, "huge": {"anchor_ms": 1e300},
		"bool": {"anchor_ms": true}, "extra key": {"anchor_ms": T0, "remainder": 5}, "wrong key": {"anchor": T0},
	}
	for label in malformed:
		var bad_recovery := MarketRecovery.from_dict(malformed[label])
		var m := _market_with({"A": {"test_good_01": 60}})
		var first := bad_recovery.advance(m, T0 + HOUR)
		_check(not first["changed"] and _stock(m, "A", "test_good_01") == 60 and bad_recovery.anchor_ms == T0 + HOUR, "Malformed anchor (%s) applies zero recovery and re-anchors" % label)
	_check(MarketRecovery.from_dict({"anchor_ms": float(T0)}).anchor_ms == T0, "A JSON float that is an exact integer is a valid anchor")
	_check(MarketRecovery.from_dict({"anchor_ms": 0}).anchor_ms == 0 and MarketRecovery.new().to_dict() == {"anchor_ms": -1}, "Anchor 0 is valid; no anchor saves as -1")
	# Stock step input validation.
	var guarded := _market_with({"A": {"test_good_01": 60}})
	for amount in [0, -1, 1.0, "1", null]:
		_check(not guarded.recover_toward_target(amount) and _stock(guarded, "A", "test_good_01") == 60, "recover_toward_target(%s) must be rejected" % str(amount))
	_sections_done.append("timestamp_safety")


func _verify_determinism() -> void:
	# Random stocks and irregular clocks against the independent one-unit-at-a-time model.
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	var all_ok := true
	for trial in range(40):
		var stocks := {}
		for city in CITIES:
			stocks[city] = {}
			for good_id in IDS:
				stocks[city][good_id] = rng.randi_range(0, 400)
		var market := _market_with(stocks)
		var model := market.get_snapshot()
		var recovery := MarketRecovery.new()
		recovery.advance(market, T0)
		var model_anchor := T0
		var now := T0
		for tick in range(12):
			now += rng.randi_range(0, 70000) if tick % 5 != 4 else rng.randi_range(1000000, 4000000)
			recovery.advance(market, now)
			var elapsed := now - model_anchor
			if elapsed > 1800000:
				model_anchor = now - 1800000
				elapsed = 1800000
			var steps := RecoveryModel.steps_for_ms(elapsed)
			model_anchor += steps * STEP
			model = RecoveryModel.recovered_snapshot(model, steps)
			if market.get_snapshot() != model or recovery.anchor_ms != model_anchor:
				all_ok = false
	_check(all_ok, "40 random markets x 12 irregular updates match the independent model exactly")
	# Same inputs, same output.
	var a := _market_with({"A": {"test_good_03": 17}})
	var b := _market_with({"A": {"test_good_03": 17}})
	var ra := MarketRecovery.from_dict({"anchor_ms": T0})
	var rb := MarketRecovery.from_dict({"anchor_ms": T0})
	ra.advance(a, T0 + 777777)
	rb.advance(b, T0 + 777777)
	_check(a.get_snapshot() == b.get_snapshot() and ra.anchor_ms == rb.anchor_ms and typeof(ra.anchor_ms) == TYPE_INT, "Identical inputs give identical integer results")
	_sections_done.append("determinism")


# --- Trades ------------------------------------------------------------------------------------

func _verify_trades() -> void:
	# A trade at 10 s does not reset the timeline: the step still lands at 12 s.
	var market := MarketState.create_default()
	var recovery := MarketRecovery.new()
	recovery.advance(market, T0)
	var wallet := Wallet.new()
	var inventory := CharacterInventory.new()
	recovery.advance(market, T0 + 10000)
	var quote := market.get_quote("A", "test_good_01")
	var buy10 := TradeService.buy("A", "test_good_01", 10, wallet, inventory, market)
	_check(buy10["success"] and buy10["total_value"] == quote["buy_price"] * 10, "Buy 10 still charges one locked price x 10")
	_check(_stock(market, "A", "test_good_01") == 90 and recovery.anchor_ms == T0, "A trade leaves the recovery anchor untouched")
	var at12 := recovery.advance(market, T0 + STEP)
	_check(at12["steps"] == 1 and _stock(market, "A", "test_good_01") == 91, "The 12 s step still happens 2 s after a trade at 10 s")
	_check(recovery.advance(market, T0 + 22000)["steps"] == 0, "No extra step at trade time + 12 s")
	_check(recovery.advance(market, T0 + 2 * STEP)["steps"] == 1 and _stock(market, "A", "test_good_01") == 92, "The next step lands on the original 24 s grid")

	# Buy 1 / Sell 1 / Sell 10 semantics unchanged, with recovery between orders.
	var q1 := market.get_quote("A", "test_good_01")
	var money := wallet.get_balance()
	var buy1 := TradeService.buy("A", "test_good_01", 1, wallet, inventory, market)
	_check(buy1["success"] and buy1["total_value"] == q1["buy_price"] and money - wallet.get_balance() == q1["buy_price"] and _stock(market, "A", "test_good_01") == 91, "Buy 1 pays the quoted price, stock -1")
	var q2 := market.get_quote("A", "test_good_01")
	_check(q2["buy_price"] == DynamicPriceModel.buy(80, 91), "The next quote follows the new stock")
	money = wallet.get_balance()
	var sell1 := TradeService.sell("A", "test_good_01", 1, wallet, inventory, market)
	_check(sell1["success"] and sell1["total_value"] == q2["buyback_price"] and wallet.get_balance() - money == q2["buyback_price"] and _stock(market, "A", "test_good_01") == 92, "Sell 1 earns the quoted buyback, stock +1")
	var q3 := market.get_quote("A", "test_good_01")
	money = wallet.get_balance()
	var sell10 := TradeService.sell("A", "test_good_01", 10, wallet, inventory, market)
	_check(sell10["success"] and sell10["total_value"] == q3["buyback_price"] * 10 and wallet.get_balance() - money == q3["buyback_price"] * 10 and _stock(market, "A", "test_good_01") == 102, "Sell 10 earns one locked buyback x 10")
	var q4 := market.get_quote("A", "test_good_01")
	var buy_again := TradeService.buy("A", "test_good_01", 10, wallet, inventory, market)
	_check(buy_again["total_value"] == q4["buy_price"] * 10 and _stock(market, "A", "test_good_01") == 92, "Buy 10 again: one price for the whole order")
	var frozen := market.get_snapshot()
	var money_frozen := wallet.get_balance()
	var held := inventory.get_items()
	for quantity in [0, -1, 2, 5, 9, 11, 20, 100, 1.0, "10", null]:
		var b := TradeService.buy("A", "test_good_01", quantity, wallet, inventory, market)
		var s := TradeService.sell("A", "test_good_01", quantity, wallet, inventory, market)
		_check(not b["success"] and not s["success"] and b["reason"] == "invalid_quantity" and s["reason"] == "invalid_quantity", "Order size %s stays rejected" % str(quantity))
	_check(market.get_snapshot() == frozen and wallet.get_balance() == money_frozen and inventory.get_items() == held and recovery.anchor_ms == T0 + 2 * STEP, "Rejected orders change nothing, including the recovery timeline")
	_check(TradeService.ALLOWED_ORDER_QUANTITIES == [1, 10], "Valid order sizes remain 1 and 10")
	_sections_done.append("trades")


func _verify_game_trade_timer() -> void:
	_write_save({"A": {}}, T0, IN_CITY_A)
	var main := await _new_main(TEST_SAVE, T0)
	_check(main.current_city_id == "A" and main.market_recovery.anchor_ms == T0, "Game starts in City A with the saved anchor")
	main.time_source.set_now_ms(T0 + 10000)
	await process_frame
	_check(main.buy_in_current_city("test_good_01", 10)["success"] and _stock(main.market, "A", "test_good_01") == 90, "Game buy 10 at 10 s")
	_check(main.market_recovery.anchor_ms == T0, "A game trade does not reset the recovery timer")
	_check(int(_read_json()["market_recovery"]["anchor_ms"]) == T0, "The trade save keeps the original anchor")
	main.time_source.set_now_ms(T0 + STEP)
	await process_frame
	_check(_stock(main.market, "A", "test_good_01") == 91 and main.market_recovery.anchor_ms == T0 + STEP, "The live 12 s step happens 2 s after the trade")
	# A trade applies any recovery that is due first, so the order uses the fresh stock.
	main.time_source.set_now_ms(T0 + 3 * STEP)
	var due_quote_stock: int = RecoveryModel.recovered_stock(91, 100, 2)
	var expected_price := DynamicPriceModel.buy(80, due_quote_stock)
	var money: int = main.wallet.get_balance()
	var result: Dictionary = main.buy_in_current_city("test_good_01", 1)
	_check(result["success"] and money - main.wallet.get_balance() == expected_price and _stock(main.market, "A", "test_good_01") == due_quote_stock - 1, "A trade first applies the due recovery, then uses the quote of that stock")
	_check(main.market_recovery.anchor_ms == T0 + 3 * STEP, "Timeline advanced by elapsed time only")
	await _destroy(main)
	_sections_done.append("game_trade_timer")


# --- Save / reload -----------------------------------------------------------------------------

func _verify_save_reload() -> void:
	# The v6 save carries the anchor; recovery state round-trips.
	_write_save({"A": {"test_good_01": 60}, "B": {"test_good_02": 130}}, T0)
	var raw := _read_json()
	_check(int(raw["version"]) == SaveStore.VERSION and raw["market_recovery"].keys() == ["anchor_ms"] and int(raw["market_recovery"]["anchor_ms"]) == T0, "The save stores only the anchor timestamp")
	_check(not JSON.stringify(raw).contains("dynamic") and not JSON.stringify(raw).contains("buy_price"), "The save never stores recovery prices")
	var loaded := SaveStore.load_session(TEST_SAVE)
	_check(not loaded.is_empty() and loaded["market_recovery"].anchor_ms == T0 and _stock(loaded["market"], "A", "test_good_01") == 60, "Loading restores stock and anchor unchanged (no recovery inside the loader)")

	# Offline 120 s = 10 steps.
	var text := _read(TEST_SAVE)
	var main := await _new_main(TEST_SAVE, T0 + 120000)
	_check(_stock(main.market, "A", "test_good_01") == 70 and _stock(main.market, "B", "test_good_02") == 120, "Offline 120 s applies 10 recovery steps: 60 -> 70, 130 -> 120")
	var quote: Dictionary = main.market.get_quote("A", "test_good_01")
	_check(quote["dynamic_reference_price"] == DynamicPriceModel.dynamic_reference(80, 70) and quote["buy_price"] == DynamicPriceModel.buy(80, 70), "Reloaded price matches the recovered stock")
	_check(main.market_recovery.anchor_ms == T0 + 120000, "The anchor moved by exactly 10 steps")
	_check(_read(TEST_SAVE) == text, "Loading never rewrites the save")
	await _destroy(main)

	# Repeated reloads at the same time do not double-apply.
	for repeat in range(3):
		main = await _new_main(TEST_SAVE, T0 + 120000)
		_check(_stock(main.market, "A", "test_good_01") == 70 and _read(TEST_SAVE) == text, "Reload #%d at the same time gives the same 70" % repeat)
		await _destroy(main)

	# A live step is saved; reloading at that time must not add it again.
	main = await _new_main(TEST_SAVE, T0 + 120000)
	main.time_source.set_now_ms(T0 + 132000)
	await process_frame
	_check(_stock(main.market, "A", "test_good_01") == 71 and int(_read_json()["market_recovery"]["anchor_ms"]) == T0 + 132000 and int(_read_json()["market"]["A"]["test_good_01"]["current_stock"]) == 71, "A live recovery step is saved with its anchor")
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0 + 132000)
	_check(_stock(main.market, "A", "test_good_01") == 71, "Reload after a saved live step does not double-apply it")
	await _destroy(main)

	# The remainder survives save / reload.
	_write_save({"A": {"test_good_01": 40}}, T0)
	main = await _new_main(TEST_SAVE, T0 + 18000)
	_check(_stock(main.market, "A", "test_good_01") == 41 and main.market_recovery.anchor_ms == T0 + STEP, "18 s offline: 1 step, 6 s remainder kept")
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0 + 24000)
	_check(_stock(main.market, "A", "test_good_01") == 42, "Reopening at 24 s gives exactly 2 steps in total")
	main.time_source.set_now_ms(T0 + 30000)
	await process_frame
	_check(_stock(main.market, "A", "test_good_01") == 42, "30 s: still 2 steps")
	main.time_source.set_now_ms(T0 + 36000)
	await process_frame
	_check(_stock(main.market, "A", "test_good_01") == 43 and int(_read_json()["market_recovery"]["anchor_ms"]) == T0 + 36000, "36 s: third step, saved")
	await _destroy(main)

	# Long offline: cap and target.
	_write_save({"A": {"test_good_01": 0}, "B": {"test_good_01": 400}}, T0)
	main = await _new_main(TEST_SAVE, T0 + HOUR)
	_check(_stock(main.market, "A", "test_good_01") == 100, "Stock 0 offline 1 h reaches target 100 and stops")
	_check(_stock(main.market, "B", "test_good_01") == 250, "Offline recovery counts at most 30 minutes (400 -> 250)")
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0 + 50 * HOUR)
	_check(_stock(main.market, "A", "test_good_01") == 100 and _stock(main.market, "B", "test_good_01") == 250, "Very long offline time is still capped and never passes target")
	await _destroy(main)

	# Future / malformed timestamps in the save.
	_write_save({"A": {"test_good_01": 60}}, T0 + HOUR)
	text = _read(TEST_SAVE)
	main = await _new_main(TEST_SAVE, T0)
	_check(_stock(main.market, "A", "test_good_01") == 60 and main.market_recovery.anchor_ms == T0 and _read(TEST_SAVE) == text, "A future saved timestamp applies zero recovery and re-anchors at now")
	await _destroy(main)
	for bad in [{"anchor_ms": "soon"}, {"anchor_ms": -7}, {"anchor_ms": 2.5}, {"anchor_ms": null}, {}, null, [1], "x"]:
		_write_save({"A": {"test_good_01": 60}}, T0)
		var data := _read_json()
		data["market_recovery"] = bad
		_write_json(data)
		main = await _new_main(TEST_SAVE, T0 + HOUR)
		_check(main.wallet.get_balance() == Wallet.STARTING_MONEY + 1234 and _stock(main.market, "A", "test_good_01") == 60 and main.market_recovery.anchor_ms == T0 + HOUR, "Malformed saved timestamp %s loads safely with zero recovery" % str(bad))
		main.time_source.set_now_ms(T0 + HOUR + STEP)
		await process_frame
		_check(_stock(main.market, "A", "test_good_01") == 61, "After a malformed timestamp recovery runs normally (%s)" % str(bad))
		await _destroy(main)
	# Structural damage still rejects the save, as for every other section.
	var v6 := _save_dict({"A": {"test_good_01": 60}}, T0)
	var no_key := v6.duplicate(true)
	no_key.erase("market_recovery")
	var future_version := v6.duplicate(true)
	future_version["version"] = 10
	var v5_with_key := v6.duplicate(true)
	v5_with_key["version"] = 5
	_check(SaveStore.validate(no_key).is_empty(), "A v6 save missing market_recovery is rejected as a whole")
	_check(SaveStore.validate(future_version).is_empty(), "An unknown future version is rejected")
	_check(SaveStore.validate(v5_with_key).is_empty(), "A v5 save cannot carry v6 data")

	# Save failure keeps a valid market; the old file is untouched and rebuilds the same result.
	_write_save({"A": {"test_good_01": 60}}, T0)
	text = _read(TEST_SAVE)
	main = await _new_main(TEST_SAVE, T0)
	main.save_path = UNWRITABLE_SAVE
	main.time_source.set_now_ms(T0 + 2 * STEP)
	await process_frame
	_check(_stock(main.market, "A", "test_good_01") == 62 and MarketState.from_snapshot(main.market.get_snapshot()) != null, "A failed save keeps a valid, correctly recovered market")
	_check(not FileAccess.file_exists(UNWRITABLE_SAVE) and _read(TEST_SAVE) == text, "A failed save leaves the previous save untouched")
	var buy: Dictionary = main.buy_in_current_city("test_good_01", 1)
	_check(not buy["success"] and buy["reason"] == "not_in_city" and _stock(main.market, "A", "test_good_01") == 62, "Nothing else changed the market")
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0 + 2 * STEP)
	_check(_stock(main.market, "A", "test_good_01") == 62, "Reloading the untouched save at the same time rebuilds the same stock")
	await _destroy(main)
	_sections_done.append("save_reload")


func _verify_migration() -> void:
	# Old saves (v1-v5) have no anchor: stock kept, anchor = now, no invented history.
	var v6 := _save_dict({"A": {"test_good_01": 60}, "B": {"test_good_04": 130}}, T0)
	var inventory := CharacterInventory.new()
	inventory.add("test_good_03", 4)
	var warehouses := WarehouseState.create_default()
	var full := SaveStore.serialize(_wallet(4321), inventory, _market_with({"A": {"test_good_01": 60}, "B": {"test_good_04": 130}}), PlayerLocation.from_dict(IN_CITY_A), warehouses)
	var v5 := full.duplicate(true)
	v5.erase("market_recovery")
	v5.erase("cost_ledger")  # T05 (v7) data is not part of a real v5 save
	v5["location"].erase("world_position")  # nor is T06's (v8) exact world position
	v5.erase("progression")  # nor C05's (v9) progression
	v5["version"] = 5
	v5["warehouses"] = {"A": {"items": {"test_good_02": 5}}, "B": {"items": {"test_good_06": 1}}}
	var v4 := v5.duplicate(true)
	v4.erase("warehouses")
	v4["version"] = 4
	var v3 := v4.duplicate(true)
	v3.erase("location")
	v3["version"] = 3
	var v2 := {"version": 2, "money": 4321, "cargo": {"test_good_03": 4}, "market": v6["market"]}
	var v1 := {"version": 1, "money": 4321, "cargo": {"test_good_03": 4}}
	var old := {"v5": v5, "v4": v4, "v3": v3, "v2": v2, "v1": v1}
	for label in old:
		_write_json(old[label])
		var text := _read(TEST_SAVE)
		var main := await _new_main(TEST_SAVE, T0 + HOUR)
		var expected_stock := 100 if label == "v1" else 60
		_check(main.wallet.get_balance() == 4321 and main.inventory.get_quantity("test_good_03") == 4, "%s: money and inventory preserved" % label)
		_check(_stock(main.market, "A", "test_good_01") == expected_stock and (label == "v1" or _stock(main.market, "B", "test_good_04") == 130), "%s: stock preserved, no historical recovery invented" % label)
		_check(main.market_recovery.anchor_ms == T0 + HOUR, "%s: the recovery anchor starts at the first T04-aware load" % label)
		_check(_read(TEST_SAVE) == text, "%s: loading does not rewrite the old save" % label)
		if label in ["v5", "v4"]:
			_check(main.current_city_id == "A", "%s: location preserved" % label)
		if label == "v5":
			_check(main.warehouses.get_quantity("A", "test_good_02") == 5 and main.warehouses.get_quantity("B", "test_good_06") == 1, "v5: warehouses preserved")
		main.time_source.set_now_ms(T0 + HOUR + 2 * STEP)
		await process_frame
		if label != "v1":
			_check(_stock(main.market, "A", "test_good_01") == 62 and _stock(main.market, "B", "test_good_04") == 128, "%s: recovery starts from the first load (2 steps after 24 s)" % label)
			var saved := _read_json()
			_check(int(saved["version"]) == SaveStore.VERSION and int(saved["market_recovery"]["anchor_ms"]) == T0 + HOUR + 2 * STEP and int(saved["money"]) == 4321, "%s: the first change writes a current-version save" % label)
		else:
			_check(_stock(main.market, "A", "test_good_01") == 100 and _read(TEST_SAVE) == text, "v1: a market already at target stays put and nothing is written")
		await _destroy(main)
	_sections_done.append("migration")


# --- Independence -------------------------------------------------------------------------------

func _verify_independence() -> void:
	# Backpack contents, money and warehouses never change recovery (and vice versa).
	var stocks := {"A": {"test_good_01": 60, "test_good_02": 130}, "B": {"test_good_03": 80}}
	var empty := _market_with(stocks)
	var loaded := _market_with(stocks)
	var empty_recovery := MarketRecovery.from_dict({"anchor_ms": T0})
	var loaded_recovery := MarketRecovery.from_dict({"anchor_ms": T0})
	var inventory := CharacterInventory.new()
	inventory.add("test_good_01", 30)
	empty_recovery.advance(empty, T0 + 7 * STEP)
	loaded_recovery.advance(loaded, T0 + 7 * STEP)
	_check(empty.get_snapshot() == loaded.get_snapshot() and inventory.get_quantity("test_good_01") == 30, "Recovery ignores backpack contents and never touches them")

	_write_save(stocks, T0, IN_CITY_A)
	var main := await _new_main(TEST_SAVE, T0)
	var start: Dictionary = main.market.get_snapshot()
	# Warehouse transfers.
	main.buy_in_current_city("test_good_05", 1)
	start = main.market.get_snapshot()
	var anchor: int = main.market_recovery.anchor_ms
	_check(main.deposit_to_warehouse("test_good_05", 1)["success"] and main.withdraw_from_warehouse("test_good_05", 1)["success"], "Warehouse transfers work")
	_check(main.market.get_snapshot() == start and main.market_recovery.anchor_ms == anchor, "Warehouse transfers change neither stock nor the recovery timeline")
	main.deposit_to_warehouse("test_good_05", 1)
	var stored: Dictionary = main.warehouses.get_snapshot()
	var held: Dictionary = main.inventory.get_items()
	var money: int = main.wallet.get_balance()
	main.time_source.set_now_ms(T0 + 5 * STEP)
	await process_frame
	_check(main.market.get_snapshot() == RecoveryModel.recovered_snapshot(start, 5), "Live recovery with goods in the warehouse matches the model")
	_check(main.warehouses.get_snapshot() == stored and main.inventory.get_items() == held and main.wallet.get_balance() == money, "Recovery never touches warehouse, backpack or money")
	# Passenger transport: market time keeps running during the ride, nothing else.
	var before_ride: Dictionary = main.market.get_snapshot()
	_check(main.request_transport("B", "t04-ride")["success"], "Passenger transport works")
	_check(main.market.get_snapshot() == before_ride and main.market_recovery.anchor_ms == T0 + 5 * STEP, "Boarding changes neither stock nor the recovery timeline")
	main.time_source.set_now_ms(T0 + 5 * STEP + 45000)
	await process_frame
	_check(main.is_traveling() and main.market.get_snapshot() == RecoveryModel.recovered_snapshot(before_ride, 3), "Recovery runs by time while traveling (3 steps in 45 s)")
	main.time_source.set_now_ms(T0 + 5 * STEP + 90000)
	await process_frame
	_check(main.current_city_id == "B" and main.market.get_snapshot() == RecoveryModel.recovered_snapshot(before_ride, 7), "Arrival adds no stock change beyond 7 time steps")
	_check(main.wallet.get_balance() == money - 300, "Transport only charged its fare")
	await _destroy(main)
	_sections_done.append("independence")


# --- Live UI ------------------------------------------------------------------------------------

func _verify_live_ui() -> void:
	_write_save({}, T0, IN_CITY_A)
	var main := await _new_main(TEST_SAVE, T0)
	var hub := main.get_node("CityHub") as CityHub
	hub.get_market_button("test_good_01", "buy10").pressed.emit()
	_check(hub.get_market_row_texts("test_good_01")["stock"] == "庫存 90", "After Buy 10 the market shows stock 90")
	var shown_low := hub.get_market_row_texts("test_good_01")
	main.time_source.set_now_ms(T0 + 2 * STEP)
	await process_frame
	var shown := hub.get_market_row_texts("test_good_01")
	var quote: Dictionary = main.market.get_quote("A", "test_good_01")
	_check(quote["stock"] == 92 and shown["stock"] == "庫存 92", "About 24 s later the open market shows stock +2 without any tap")
	_check(shown["buy_price"] == "買入價 %d" % quote["buy_price"] and shown["buyback_price"] == "賣出價 %d" % quote["buyback_price"], "The open market shows the recovered prices")
	_check(quote["buy_price"] == DynamicPriceModel.buy(80, 92) and shown["buy_price"] != shown_low["buy_price"], "Price moved back toward baseline")
	# One late frame after 36 s applies all 3 steps.
	main.time_source.set_now_ms(T0 + 5 * STEP)
	await process_frame
	_check(hub.get_market_row_texts("test_good_01")["stock"] == "庫存 95", "One delayed frame applies every due step (36 s -> 3 steps)")
	# Oversupply: selling the 10 back pushes stock above target, then it falls back.
	hub.get_market_button("test_good_01", "sell10").pressed.emit()
	_check(main.market.get_quote("A", "test_good_01")["stock"] == 105 and main.inventory.get_quantity("test_good_01") == 0, "Sell 10 pushes stock 95 -> 105")
	main.time_source.set_now_ms(T0 + 7 * STEP)
	await process_frame
	_check(hub.get_market_row_texts("test_good_01")["stock"] == "庫存 103", "Oversupply falls toward 100")
	main.time_source.set_now_ms(T0 + 7 * STEP + 10 * 60000)
	await process_frame
	_check(hub.get_market_row_texts("test_good_01")["stock"] == "庫存 100" and _stock(main.market, "A", "test_good_01") == 100, "Stock stops at 100")
	var text := _read(TEST_SAVE)
	main.time_source.set_now_ms(T0 + 7 * STEP + 20 * 60000)
	await process_frame
	_check(_stock(main.market, "A", "test_good_01") == 100 and _read(TEST_SAVE) == text, "At target: no change and no extra save")
	_check(hub.get_market_row_texts("test_good_01")["name"] != "" and _chinese_only(hub.get_market_row_texts("test_good_01")), "Market text stays Traditional Chinese")
	await _destroy(main)
	_sections_done.append("live_ui")


# --- Helpers ------------------------------------------------------------------------------------

func _stock(market: MarketState, city: String, good_id: String) -> int:
	return market.get_quote(city, good_id)["stock"]


func _market_with(stocks: Dictionary) -> MarketState:
	var snapshot := MarketState.create_default().get_snapshot()
	for city in stocks:
		for good_id in stocks[city]:
			snapshot[city][good_id]["current_stock"] = stocks[city][good_id]
	return MarketState.from_snapshot(snapshot)


func _wallet(money: int) -> Wallet:
	var wallet := Wallet.new()
	var difference := money - wallet.get_balance()
	if difference > 0:
		wallet.add(difference)
	elif difference < 0:
		wallet.spend(-difference)
	return wallet


## A v6 save dictionary (money = start + 1234) with the given stocks and anchor.
func _save_dict(stocks: Dictionary, anchor: int, location: Dictionary = {}) -> Dictionary:
	var place := PlayerLocation.new() if location.is_empty() else PlayerLocation.from_dict(location)
	return SaveStore.serialize(_wallet(Wallet.STARTING_MONEY + 1234), CharacterInventory.new(), _market_with(stocks), place, WarehouseState.create_default(), MarketRecovery.from_dict({"anchor_ms": anchor}))


func _write_save(stocks: Dictionary, anchor: int, location: Dictionary = {}) -> void:
	var place := PlayerLocation.new() if location.is_empty() else PlayerLocation.from_dict(location)
	_check(SaveStore.save(TEST_SAVE, _wallet(Wallet.STARTING_MONEY + 1234), CharacterInventory.new(), _market_with(stocks), place, WarehouseState.create_default(), MarketRecovery.from_dict({"anchor_ms": anchor})), "Fixture save must write")


func _chinese_only(texts: Dictionary) -> bool:
	for key in texts:
		for character in texts[key]:
			if character.unicode_at(0) < 128 and not character in "0123456789 ":
				return false
	return true


## Source code without comment lines, for structural scans.
func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


func _new_main(path: String, now: int) -> Node2D:
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


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


func _read_json() -> Dictionary:
	var parsed: Variant = JSON.parse_string(_read(TEST_SAVE))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _write_json(data: Variant) -> void:
	var file := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()


func _delete(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _settle() -> void:
	for frame in range(4):
		await physics_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
