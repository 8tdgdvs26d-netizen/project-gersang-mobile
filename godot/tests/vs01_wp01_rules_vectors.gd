extends RefCounted

## VS-01 WP01 — golden vectors from the EXISTING GDScript trade rules
## (MarketRules, MarketRecovery, MarketState, TradeService). The Nakama
## TypeScript port must reproduce every value (nakama/tests/unit); this file
## and verify_vs01_wp01_online_contract.gd re-check that the GDScript rules
## still produce nakama/tests/fixtures/rules_vectors.json, so drift on either
## side fails a test. Regenerate with nakama/scripts/generate_rules_vectors.gd.


static func build_vectors() -> Dictionary:
	var dynamic := []
	for baseline in [1, 2, 3, 79, 80, 99, 100, 101, 180, 420, 900, 2100, 3600, 4300, 12345, 9999999]:
		for target in [1, 7, 100, 250]:
			for stock in [0, 1, 9, 10, 50, 89, 99, 100, 101, 150, 199, 200, 250, 299, 300, 301, 1000]:
				dynamic.append([baseline, stock, target, MarketRules.dynamic_reference(baseline, stock, target)])
	var spread := []
	for reference in [0, 1, 2, 3, 19, 20, 21, 80, 84, 99, 100, 101, 999, 4300, 8600]:
		spread.append([reference, MarketRules.buy_price(reference), MarketRules.buyback_price(reference)])
	var recovery_steps := []
	for elapsed in [-1, 0, 1, 11999, 12000, 12001, 23999, 24000, 600000, 1799999, 1800000, 1800001, 99999999]:
		recovery_steps.append([elapsed, MarketRecovery.steps_for(elapsed)])
	return {
		"source": "godot/scripts market_rules.gd, market_recovery.gd, market_state.gd, trade_service.gd",
		"dynamic_reference": dynamic,
		"spread": spread,
		"recovery_steps": recovery_steps,
		"recovery_advance": _recovery_advance(),
		"trade_sequence": _trade_sequence(),
		"trade_sequence_low_stock": _trade_sequence_low_stock(),
		"capacity_default": CharacterStats.new().get_max_capacity(),
		"starting_money": Wallet.STARTING_MONEY,
	}


## MarketRecovery.advance over a market drained by trades, at fixed times.
static func _recovery_advance() -> Array:
	var market := MarketState.create_default()
	market.remove_stock("A", "test_good_01", 60)
	market.add_stock("B", "test_good_06", 40)
	var recovery := MarketRecovery.new()
	var rows := []
	for now_ms in [1000, 5000, 13000, 13000, 40000, 9000, 2000000, 2000001, 5000000]:
		var result := recovery.advance(market, now_ms)
		rows.append({
			"now_ms": now_ms, "steps": result["steps"], "anchor_ms": recovery.anchor_ms,
			"stock_A_01": market.get_quote("A", "test_good_01")["stock"],
			"stock_B_06": market.get_quote("B", "test_good_06")["stock"],
		})
	return rows


## A fixed order list run through TradeService on a fresh Prototype state
## (no ledger, no recovery), including rejections in every reason.
static func _trade_sequence() -> Array:
	var wallet := Wallet.new()
	var inventory := CharacterInventory.new("player", CharacterStats.new())
	var market := MarketState.create_default()
	var orders := [
		["buy", "A", "test_good_01", 10], ["buy", "A", "test_good_01", 10], ["buy", "A", "test_good_01", 1],
		["sell", "B", "test_good_01", 10], ["sell", "B", "test_good_01", 10], ["sell", "B", "test_good_01", 1],
		["sell", "B", "test_good_01", 1], ["buy", "A", "test_good_06", 10], ["buy", "B", "test_good_06", 1],
		["buy", "A", "test_good_05", 10], ["buy", "A", "test_good_04", 10], ["buy", "A", "test_good_02", 10],
		["buy", "A", "test_good_02", 10], ["buy", "A", "test_good_02", 10], ["buy", "A", "test_good_02", 10],
		["buy", "A", "test_good_03", 10], ["sell", "A", "test_good_02", 10], ["sell", "B", "test_good_04", 10],
		["sell", "B", "test_good_05", 10], ["buy", "C", "test_good_01", 1], ["buy", "A", "test_good_99", 1],
		["buy", "A", "test_good_01", 2], ["buy", "A", "test_good_01", 0], ["buy", "A", "test_good_01", -1],
		["sell", "A", "test_good_03", 2], ["buy", "B", "test_good_06", 10], ["buy", "B", "test_good_06", 10],
		["sell", "B", "test_good_06", 10], ["sell", "A", "test_good_06", 1],
	]
	for i in range(8):
		orders.append(["buy", "A", "test_good_01", 10])
	for i in range(8):
		orders.append(["sell", "A", "test_good_01", 10])
	var rows := []
	for order in orders:
		var result: Dictionary
		if order[0] == "buy":
			result = TradeService.buy(order[1], order[2], order[3], wallet, inventory, market)
		else:
			result = TradeService.sell(order[1], order[2], order[3], wallet, inventory, market)
		var quote := market.get_quote(order[1], order[2])
		rows.append({
			"action": order[0], "city_id": order[1], "good_id": order[2], "quantity": order[3],
			"success": result["success"], "reason": result["reason"], "total": result["total_value"],
			"unit_price": result.get("unit_price", 0),
			"money_after": wallet.get_balance(), "carried_after": inventory.get_quantity(order[2]),
			"stock_after": quote.get("stock", -1), "used_capacity_after": inventory.get_used_capacity(),
		})
	return rows


## Market stock limits: city A test_good_02 drained to 5 units first.
static func _trade_sequence_low_stock() -> Array:
	var wallet := Wallet.new()
	var inventory := CharacterInventory.new("player", CharacterStats.new())
	var market := MarketState.create_default()
	market.remove_stock("A", "test_good_02", 95)
	var rows := []
	for qty in [10, 1, 1, 1, 1, 1, 1, 10]:
		var result := TradeService.buy("A", "test_good_02", qty, wallet, inventory, market)
		rows.append({
			"quantity": qty, "success": result["success"], "reason": result["reason"],
			"total": result["total_value"], "money_after": wallet.get_balance(),
			"stock_after": market.get_quote("A", "test_good_02")["stock"],
		})
	return rows
