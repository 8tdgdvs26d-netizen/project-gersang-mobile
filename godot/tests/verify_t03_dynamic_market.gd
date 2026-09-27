extends SceneTree

## T03 Dynamic Market Pricing: trade -> stock -> price.
## Uses its own save file so the player's real save is never touched, and a
## fixed TimeSource so journeys are deterministic.

const DynamicPriceModel := preload("res://tests/dynamic_price_model.gd")
const FixedCapacityStats := preload("res://tests/fixed_capacity_stats.gd")
const TEST_SAVE := "user://t03_dynamic_market_test_save.json"
const T0 := 1800000000000
const IDS := ["test_good_01", "test_good_02", "test_good_03", "test_good_04", "test_good_05", "test_good_06"]
const BASELINES := {
	"A": {"test_good_01": 80, "test_good_02": 180, "test_good_03": 420, "test_good_04": 900, "test_good_05": 2100, "test_good_06": 3600},
	"B": {"test_good_01": 120, "test_good_02": 300, "test_good_03": 650, "test_good_04": 1250, "test_good_05": 1700, "test_good_06": 4300},
}
const MAX_VALUE := 9007199254740992

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_formula()
	_verify_bounds_and_safety()
	_verify_quotes()
	_verify_trade_reaction()
	_verify_independence_and_failures()
	_verify_extremes()
	_verify_order_locked_pricing()
	await _verify_game_integration()
	await _verify_save_reload()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 9, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("T03 dynamic market pricing verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Formula -------------------------------------------------------------------------------

func _verify_formula() -> void:
	# Equilibrium returns the baseline exactly, for every approved price and other targets.
	var equilibrium_ok := true
	for city in BASELINES:
		for good_id in IDS:
			for target in [1, 7, 100, 1000, 123456]:
				if MarketRules.dynamic_reference(BASELINES[city][good_id], target, target) != BASELINES[city][good_id]:
					equilibrium_ok = false
	_check(equilibrium_ok, "stock == target must give exactly the baseline")
	# Approved shape: every 10% stock deviation ~ 5% opposite price move.
	var shape := {80: 1100, 120: 900, 50: 1250, 150: 750, 90: 1050, 110: 950, 0: 1500, 200: 500}
	for stock in shape:
		_check(MarketRules.dynamic_reference(1000, stock, 100) == shape[stock], "Baseline 1000 at stock %d must be %d (got %d)" % [stock, shape[stock], MarketRules.dynamic_reference(1000, stock, 100)])
	_check(MarketRules.dynamic_reference(80, 80, 100) == 88 and MarketRules.dynamic_reference(80, 120, 100) == 72 and MarketRules.dynamic_reference(80, 50, 100) == 100 and MarketRules.dynamic_reference(80, 150, 100) == 60, "Baseline 80: +10% / -10% / +25% / -25%")
	_check(MarketRules.dynamic_reference(4300, 80, 100) == 4730 and MarketRules.dynamic_reference(4300, 150, 100) == 3225, "Baseline 4300 follows the same shape")
	# Direction and monotonicity across the whole stock range.
	var monotonic := true
	var direction := true
	for baseline in [2, 3, 80, 180, 420, 900, 3600, 4300, 99999]:
		var previous := MarketRules.dynamic_reference(baseline, 0, 100)
		for stock in range(0, 351):
			var price := MarketRules.dynamic_reference(baseline, stock, 100)
			if price > previous:
				monotonic = false
			previous = price
			if baseline >= 80 and stock <= 90 and price <= baseline:
				direction = false
			if baseline >= 80 and stock >= 110 and price >= baseline:
				direction = false
	_check(monotonic, "Price must never rise when stock rises (monotonic)")
	_check(direction, "Stock below target raises the price; stock above target lowers it")
	# Independent reference model agrees on a full grid (integer rounding included).
	var mismatches := 0
	for baseline in [2, 3, 5, 80, 180, 420, 900, 2100, 4300, 99999]:
		for target in [1, 7, 100, 1000]:
			for stock in range(0, 3 * target + 5, maxi(target / 50, 1)):
				if MarketRules.dynamic_reference(baseline, stock, target) != DynamicPriceModel.dynamic_reference(baseline, stock, target):
					mismatches += 1
	_check(mismatches == 0, "The formula must match the independent model everywhere (%d mismatches)" % mismatches)
	_sections_done.append("formula")


func _verify_bounds_and_safety() -> void:
	# Floor: 50% of baseline (rounded up), reached at stock 2 x target and beyond.
	for baseline in [80, 81, 4300, 99999]:
		var floor_price: int = (baseline + 1) / 2
		_check(MarketRules.dynamic_reference(baseline, 200, 100) == floor_price and MarketRules.dynamic_reference(baseline, 5000, 100) == floor_price and MarketRules.dynamic_reference(baseline, MAX_VALUE, 100) == floor_price, "Baseline %d floor must be %d" % [baseline, floor_price])
	# Ceiling: 200% of baseline. The approved linear slope tops out at +50%
	# (stock 0), so the ceiling is enforced by the clamp as a safety bound.
	for baseline in [80, 4300, 99999]:
		_check(MarketRules.clamp_reference(baseline, baseline * 5) == baseline * 2, "Clamp must cap baseline %d at 200%%" % baseline)
		_check(MarketRules.clamp_reference(baseline, 0) == (baseline + 1) / 2, "Clamp must floor baseline %d at 50%%" % baseline)
		_check(MarketRules.dynamic_reference(baseline, 0, 100) == (baseline * 3 + 1) / 2 and MarketRules.dynamic_reference(baseline, 0, 100) <= baseline * 2, "Stock 0 is the highest reachable price (+50%) and within the ceiling")
	var bounded := true
	for stock in range(0, 1001, 7):
		var price := MarketRules.dynamic_reference(4300, stock, 100)
		if price < 2150 or price > 8600:
			bounded = false
	_check(bounded, "Every stock level stays within 50%..200% of the baseline")
	# Never zero, always a usable price (buy and buyback positive).
	var positive := true
	for baseline in range(2, 40):
		for stock in [0, 1, 99, 100, 101, 250, MAX_VALUE]:
			var reference := MarketRules.dynamic_reference(baseline, stock, 100)
			if reference < MarketRules.MIN_REFERENCE_PRICE or MarketRules.buy_price(reference) <= 0 or MarketRules.buyback_price(reference) <= 0:
				positive = false
	_check(positive, "Valid market data never produces a zero or unusable price")
	# Integer safety at the largest values MarketState accepts.
	var huge := MarketRules.dynamic_reference(MAX_VALUE, 0, MAX_VALUE)
	_check(typeof(huge) == TYPE_INT and huge == MAX_VALUE / 2 * 3, "Largest baseline / target must not overflow (+50%%, got %d)" % huge)
	_check(MarketRules.dynamic_reference(MAX_VALUE, MAX_VALUE, MAX_VALUE) == MAX_VALUE and MarketRules.dynamic_reference(MAX_VALUE, MAX_VALUE, 1) == MAX_VALUE / 2, "Largest values must stay exact")
	_check(MarketRules.dynamic_reference(1, 100, 100) == 0 and MarketRules.dynamic_reference(80, -1, 100) == 0 and MarketRules.dynamic_reference(80, 100, 0) == 0, "Invalid inputs return 0 (rejected by MarketState validation anyway)")
	_check(MarketRules.dynamic_reference(80, 90, 100) == MarketRules.dynamic_reference(80, 90, 100), "The formula is deterministic")
	var source := _code_only("res://scripts/market_rules.gd")
	_check(not source.contains("float(") and not source.contains("round(") and not source.contains("ceil(") and not source.contains("floor("), "Pricing uses integer maths only")
	_check(FileAccess.get_file_as_string("res://scripts/market_rules.gd").contains("PROTOTYPE PARAMETERS"), "Sensitivity and bounds are marked as prototype parameters")
	# One authoritative formula: nothing else computes dynamic prices.
	for file_name in ["market_state.gd", "trade_service.gd", "city_hub.gd", "main.gd"]:
		var code := FileAccess.get_file_as_string("res://scripts/" + file_name)
		_check(not code.contains("PRICE_SENSITIVITY") and not code.contains("_scale_ppm") and not code.contains("* 105"), "%s must not re-implement pricing" % file_name)
	_sections_done.append("bounds")


# --- Quotes and trades ---------------------------------------------------------------------------

func _verify_quotes() -> void:
	var market := _market_with({"A": {"test_good_03": 80}, "B": {"test_good_05": 130}})
	for city in BASELINES:
		for good_id in IDS:
			var quote := market.get_quote(city, good_id)
			var dynamic := MarketRules.dynamic_reference(BASELINES[city][good_id], quote["stock"], 100)
			var ok: bool = quote["baseline_reference_price"] == BASELINES[city][good_id] and quote["reference_price"] == BASELINES[city][good_id] \
				and quote["dynamic_reference_price"] == dynamic and quote["target_stock"] == 100 \
				and quote["buy_price"] == MarketRules.buy_price(dynamic) and quote["buyback_price"] == MarketRules.buyback_price(dynamic) \
				and quote["buy_price"] > quote["buyback_price"]
			_check(ok, "%s %s quote must expose baseline, dynamic, stock and spread prices (%s)" % [city, good_id, str(quote)])
	var dear := market.get_quote("A", "test_good_03")
	_check(dear["dynamic_reference_price"] == 462 and dear["buy_price"] == 486 and dear["buyback_price"] == 438, "Stock 80 of a 420 good: dynamic 462, buy 486 (ceil x1.05), buyback 438 (floor x0.95)")
	var cheap := market.get_quote("B", "test_good_05")
	_check(cheap["dynamic_reference_price"] == 1445 and cheap["buy_price"] == 1518 and cheap["buyback_price"] == 1372, "Stock 130 of a 1700 good: dynamic 1445, buy 1518, buyback 1372")
	_sections_done.append("quotes")


func _verify_trade_reaction() -> void:
	var wallet := _rich_wallet()
	var inventory := CharacterInventory.new("player", CharacterStats.new(1000))
	var market := MarketState.create_default()
	var first := market.get_quote("A", "test_good_04")
	_check(TradeService.buy("A", "test_good_04", 1, wallet, inventory, market)["success"], "Buy must succeed")
	var after_one := market.get_quote("A", "test_good_04")
	_check(after_one["stock"] == 99 and after_one["dynamic_reference_price"] >= first["dynamic_reference_price"], "A buy lowers stock and never lowers the price")
	for press in range(9):
		TradeService.buy("A", "test_good_04", 1, wallet, inventory, market)
	var after_ten := market.get_quote("A", "test_good_04")
	_check(after_ten["stock"] == 90 and after_ten["dynamic_reference_price"] == 945 and after_ten["buy_price"] == 993 and after_ten["buyback_price"] == 897, "Ten buys: stock 90 -> +5%% (945), buy 993, buyback 897 (%s)" % str(after_ten))
	_check(after_ten["buy_price"] > first["buy_price"] and after_ten["buyback_price"] > first["buyback_price"], "Buy pressure raises both the buy and the sell price")
	for press in range(10):
		TradeService.sell("A", "test_good_04", 1, wallet, inventory, market)
	_check(market.get_quote("A", "test_good_04") == first, "Selling back to target returns the quote exactly to baseline")
	for press in range(20):
		TradeService.buy("A", "test_good_01", 1, wallet, inventory, market)
	var before_sell := market.get_quote("A", "test_good_05")
	_check(TradeService.buy("B", "test_good_05", 10, wallet, inventory, market)["success"] and TradeService.buy("B", "test_good_05", 10, wallet, inventory, market)["success"], "Setup: carry 20 x good 5 from B (two 10-unit orders)")
	for press in range(20):
		TradeService.sell("A", "test_good_05", 1, wallet, inventory, market)
	var after_sells := market.get_quote("A", "test_good_05")
	_check(after_sells["stock"] == 120 and after_sells["dynamic_reference_price"] == 1890 and after_sells["buy_price"] < before_sell["buy_price"], "Sell pressure: stock 120 -> -10%% (1890) and a cheaper quote (%s)" % str(after_sells))
	_check(market.get_quote("A", "test_good_01")["reference_price"] == 80 and market.get_quote("A", "test_good_05")["reference_price"] == 2100, "The baseline reference never moves with trades")
	_sections_done.append("trade_reaction")


func _verify_independence_and_failures() -> void:
	var market := MarketState.create_default()
	var wallet := _rich_wallet()
	var inventory := CharacterInventory.new("player", CharacterStats.new(1000))
	var before := _quotes(market)
	for press in range(15):
		TradeService.buy("A", "test_good_01", 1, wallet, inventory, market)
	var after := _quotes(market)
	var changed := []
	for key in before:
		if before[key] != after[key]:
			changed.append(key)
	_check(changed == ["A/test_good_01"], "Only the traded city x good may change (%s)" % str(changed))

	# Failed trades leave stock and price untouched.
	var poor := Wallet.new()
	poor.spend(10000 - 5)
	var small := CharacterInventory.new("player", FixedCapacityStats.new(2))
	var snapshot := market.get_snapshot()
	var quotes := _quotes(market)
	var attempts := [
		TradeService.buy("A", "test_good_06", 1, poor, inventory, market),
		TradeService.buy("A", "test_good_01", 10, wallet, small, market),
		TradeService.buy("A", "test_good_01", 86, wallet, inventory, market),
		TradeService.buy("A", "test_good_01", 0, wallet, inventory, market),
		TradeService.sell("A", "test_good_02", 1, wallet, small, market),
		TradeService.sell("B", "test_good_02", 10, wallet, inventory, market),
		TradeService.sell("B", "test_good_01", 16, wallet, inventory, market),
		TradeService.sell("C", "test_good_01", 1, wallet, inventory, market),
	]
	var all_failed := true
	for attempt in attempts:
		if attempt["success"]:
			all_failed = false
	_check(all_failed, "Every setup attempt must fail")
	_check(market.get_snapshot() == snapshot and _quotes(market) == quotes, "Failed buys and sells must not change stock or price")
	_sections_done.append("independence")


func _verify_extremes() -> void:
	# Repeated buys approach the ceiling side but never exceed it.
	var market := MarketState.create_default()
	var wallet := _rich_wallet()
	var inventory := CharacterInventory.new("player", CharacterStats.new(1000))
	var previous: int = market.get_quote("B", "test_good_06")["dynamic_reference_price"]
	var rising := true
	while market.get_quote("B", "test_good_06")["stock"] > 0:
		TradeService.buy("B", "test_good_06", 1, wallet, inventory, market)
		var price: int = market.get_quote("B", "test_good_06")["dynamic_reference_price"]
		if price < previous or price > 4300 * 2:
			rising = false
		previous = price
	_check(rising and previous == 6450, "Buying out the stock raises the price step by step to +50%% at stock 0 (6450), never above 200%% (got %d)" % previous)
	var sold_out := TradeService.buy("B", "test_good_06", 1, wallet, inventory, market)
	_check(not sold_out["success"] and sold_out["reason"] == "insufficient_market_stock", "Nothing can be bought at stock 0")
	# Repeated sells approach the floor but never go below it.
	for order in range(10):
		TradeService.buy("A", "test_good_06", 10, wallet, inventory, market)
	var floor_price := 4300 / 2
	previous = market.get_quote("B", "test_good_06")["dynamic_reference_price"]
	var falling := true
	for press in range(260):
		if not TradeService.sell("B", "test_good_06", 1, wallet, inventory, market)["success"]:
			break
		var price: int = market.get_quote("B", "test_good_06")["dynamic_reference_price"]
		if price > previous or price < floor_price:
			falling = false
		previous = price
	_check(falling and market.get_quote("B", "test_good_06")["stock"] >= 200 and previous == floor_price, "Selling a flood lowers the price to the 50%% floor (%d) and never below (got %d)" % [floor_price, previous])
	_check(market.get_quote("B", "test_good_06")["buyback_price"] > 0, "The floor price is still sellable")
	_check(market.get_quote("B", "test_good_06")["reference_price"] == 4300, "The baseline stays unchanged after extreme trading")
	_sections_done.append("extremes")

# --- Order-locked pricing (review fix) -------------------------------------------------------

## ONE ORDER = ONE PRICE: an order of 1 or 10 units uses the quote read before
## it; only after the whole order does the stock (and so the next quote) change.
func _verify_order_locked_pricing() -> void:
	var market := MarketState.create_default()
	var wallet := _rich_wallet()
	var inventory := CharacterInventory.new("player", CharacterStats.new(1000))
	_check(TradeService.ALLOWED_ORDER_QUANTITIES == [1, 10], "Only 1 and 10 are order sizes")

	# Sizes 1 and 10 work both ways.
	_check(TradeService.buy("A", "test_good_02", 1, wallet, inventory, market)["success"] and TradeService.sell("A", "test_good_02", 1, wallet, inventory, market)["success"], "Quantity 1 buy and sell succeed")
	# Buy 10 at displayed price P costs exactly P x 10, with P locked.
	var quote := market.get_quote("A", "test_good_04")
	var price: int = quote["buy_price"]
	var money := wallet.get_balance()
	var bought := TradeService.buy("A", "test_good_04", 10, wallet, inventory, market)
	_check(bought["success"] and bought["total_value"] == price * 10 and money - wallet.get_balance() == price * 10, "Buy 10 at %d costs exactly %d" % [price, price * 10])
	var per_unit := 0
	for unit in range(10):
		per_unit += DynamicPriceModel.buy(900, 100 - unit)
	_check(per_unit != price * 10, "Per-unit pricing would differ (%d), so the order really used one locked price" % per_unit)
	var after_buy := market.get_quote("A", "test_good_04")
	_check(after_buy["stock"] == quote["stock"] - 10 and after_buy["buy_price"] > price and after_buy["buy_price"] == DynamicPriceModel.buy(900, 90), "After Buy 10 the stock is 10 lower and only the NEXT quote is dearer")
	# Sell 10 at displayed buyback P earns exactly P x 10.
	var sell_quote := market.get_quote("A", "test_good_04")
	var sell_price: int = sell_quote["buyback_price"]
	money = wallet.get_balance()
	var sold := TradeService.sell("A", "test_good_04", 10, wallet, inventory, market)
	_check(sold["success"] and sold["total_value"] == sell_price * 10 and wallet.get_balance() - money == sell_price * 10, "Sell 10 at %d earns exactly %d" % [sell_price, sell_price * 10])
	var after_sell := market.get_quote("A", "test_good_04")
	_check(after_sell["stock"] == sell_quote["stock"] + 10 and after_sell["buyback_price"] < sell_price, "After Sell 10 the stock is 10 higher and the next quote is lower")

	# Every other size is rejected in the domain, changing nothing.
	inventory.restore_items({"test_good_01": 200})
	for size in [2, 3, 5, 9, 11, 20, 50, 99, 100, 1000]:
		var before_money := wallet.get_balance()
		var before_items := inventory.get_stacks()
		var before_market := market.get_snapshot()
		var buy := TradeService.buy("B", "test_good_01", size, wallet, inventory, market)
		var sell := TradeService.sell("B", "test_good_01", size, wallet, inventory, market)
		_check(not buy["success"] and buy["reason"] == "invalid_quantity" and not sell["success"] and sell["reason"] == "invalid_quantity", "Order size %d must be rejected both ways" % size)
		_check(wallet.get_balance() == before_money and inventory.get_stacks() == before_items and market.get_snapshot() == before_market, "Rejected size %d must change nothing" % size)

	# 100 units only as ten separate 10-unit orders, each at its own price.
	var hundred := MarketState.create_default()
	var h_wallet := _rich_wallet()
	var h_inventory := CharacterInventory.new("player", CharacterStats.new(1000))
	var totals := []
	var locked_ok := true
	for order in range(10):
		var unit: int = hundred.get_quote("A", "test_good_03")["buy_price"]
		var result := TradeService.buy("A", "test_good_03", 10, h_wallet, h_inventory, hundred)
		if not result["success"] or result["total_value"] != unit * 10 or unit != DynamicPriceModel.buy(420, 100 - order * 10):
			locked_ok = false
		totals.append(result["total_value"])
	var rising := true
	for i in range(1, totals.size()):
		if totals[i] <= totals[i - 1]:
			rising = false
	_check(locked_ok and rising and hundred.get_quote("A", "test_good_03")["stock"] == 0, "Ten Buy 10 orders: each uses its own locked price and later orders cost more %s" % str(totals))
	var sell_totals := []
	var sell_ok := true
	for order in range(10):
		var unit: int = hundred.get_quote("A", "test_good_03")["buyback_price"]
		var result := TradeService.sell("A", "test_good_03", 10, h_wallet, h_inventory, hundred)
		if not result["success"] or result["total_value"] != unit * 10:
			sell_ok = false
		sell_totals.append(result["total_value"])
	var falling := true
	for i in range(1, sell_totals.size()):
		if sell_totals[i] >= sell_totals[i - 1]:
			falling = false
	_check(sell_ok and falling and hundred.get_quote("A", "test_good_03")["stock"] == 100, "Ten Sell 10 orders: each uses its own locked price and later orders earn less %s" % str(sell_totals))
	var spent := 0
	var earned := 0
	for i in range(10):
		spent += totals[i]
		earned += sell_totals[i]
	_check(earned < spent, "Buying 100 then selling 100 in the same city in 10-unit orders loses money (spent %d, earned %d)" % [spent, earned])

	# The earlier exploit: buy 100 at the low pre-trade price, then sell 100 at
	# the post-trade price. Quantity 100 is not an order size, so it cannot run.
	var exploit := MarketState.create_default()
	var e_wallet := _rich_wallet()
	var e_inventory := CharacterInventory.new("player", CharacterStats.new(1000))
	e_inventory.restore_items({"test_good_06": 100})
	var e_before := e_wallet.get_balance()
	var big_buy := TradeService.buy("B", "test_good_06", 100, e_wallet, e_inventory, exploit)
	var big_sell := TradeService.sell("B", "test_good_06", 100, e_wallet, e_inventory, exploit)
	_check(big_buy["reason"] == "invalid_quantity" and big_sell["reason"] == "invalid_quantity" and e_wallet.get_balance() == e_before and exploit.get_snapshot() == MarketState.create_default().get_snapshot(), "Buy 100 / Sell 100 are rejected, closing the bulk-order exploit")
	# No free profit from any sequence of 10-unit orders against one market.
	var cycle_ok := true
	for good_id in IDS:
		for city in BASELINES:
			var cycle := MarketState.create_default()
			var c_wallet := _rich_wallet()
			var c_inventory := CharacterInventory.new("player", CharacterStats.new(1000))
			var start := c_wallet.get_balance()
			TradeService.buy(city, good_id, 10, c_wallet, c_inventory, cycle)
			TradeService.sell(city, good_id, 10, c_wallet, c_inventory, cycle)
			if c_wallet.get_balance() >= start or cycle.get_quote(city, good_id)["stock"] != 100:
				cycle_ok = false
	_check(cycle_ok, "Buy 10 then Sell 10 in the same city always loses money for every city and good")
	_sections_done.append("order_locked")


# --- Game integration ---------------------------------------------------------------------------

func _verify_game_integration() -> void:
	var main := await _new_main("")
	var hub := main.get_node("CityHub") as CityHub
	await _walk_in(main, "A")
	var shown_before := hub.get_market_row_texts("test_good_01")
	var labels := []
	for action in ["buy", "buy10", "sell", "sell10"]:
		labels.append(hub.get_market_button("test_good_01", action).text)
	var row_buttons := hub.get_market_button("test_good_01", "buy").get_parent().find_children("*", "Button", false, false)
	_check(labels == ["買入 1", "買入 10", "賣出 1", "賣出 10"] and row_buttons.size() == 4, "Each market row has exactly 買入 1 / 買入 10 / 賣出 1 / 賣出 10 (%s)" % str(labels))
	# 買入 10: one order at the displayed price, then the UI shows the new price.
	var displayed: int = main.market.get_quote("A", "test_good_01")["buy_price"]
	var money_before: int = main.wallet.get_balance()
	hub.get_market_button("test_good_01", "buy10").pressed.emit()
	_check(money_before - main.wallet.get_balance() == displayed * 10 and hub.get_feedback_text() == "已買入 10 件測試商品一，支付 %d" % (displayed * 10), "買入 10 charges exactly 10 x the displayed price (%d)" % displayed)
	_check(main.market.get_quote("A", "test_good_01")["stock"] == 90 and hub.get_market_row_texts("test_good_01")["buy_price"] == "買入價 %d" % DynamicPriceModel.buy(80, 90), "After 買入 10 the UI shows the new price")
	var sell_displayed: int = main.market.get_quote("A", "test_good_01")["buyback_price"]
	money_before = main.wallet.get_balance()
	hub.get_market_button("test_good_01", "sell10").pressed.emit()
	_check(main.wallet.get_balance() - money_before == sell_displayed * 10 and main.market.get_quote("A", "test_good_01")["stock"] == 100, "賣出 10 earns exactly 10 x the displayed buyback")
	_check(main.buy_in_current_city("test_good_01", 2)["reason"] == "invalid_quantity" and main.sell_in_current_city("test_good_01", 5)["reason"] == "invalid_quantity", "The game path rejects other order sizes too")
	for press in range(12):
		hub.get_market_button("test_good_01", "buy").pressed.emit()
	var quote: Dictionary = main.market.get_quote("A", "test_good_01")
	var shown := hub.get_market_row_texts("test_good_01")
	_check(quote["stock"] == 88 and shown["buy_price"] == "買入價 %d" % quote["buy_price"] and shown["buyback_price"] == "賣出價 %d" % quote["buyback_price"] and shown["stock"] == "庫存 88", "The market UI shows the updated dynamic prices at once (%s)" % str(shown))
	_check(shown["buy_price"] != shown_before["buy_price"] and quote["buy_price"] > 84, "Buying raised the displayed buy price")
	hub.get_market_button("test_good_01", "sell").pressed.emit()
	_check(hub.get_market_row_texts("test_good_01")["buy_price"] == "買入價 %d" % main.market.get_quote("A", "test_good_01")["buy_price"], "Selling refreshes the displayed prices")

	# Warehouse, remote view and transport never touch prices.
	var market_before: Dictionary = main.market.get_snapshot()
	var quotes_before := _quotes(main.market)
	hub.show_facility("warehouse")
	for press in range(3):
		hub.get_warehouse_button("test_good_01", "deposit").pressed.emit()
	hub.get_warehouse_button("test_good_01", "withdraw").pressed.emit()
	_check(main.market.get_snapshot() == market_before and _quotes(main.market) == quotes_before, "Warehouse deposit / withdraw must not change market stock or price")
	hub.show_warehouse_city("B")
	hub.show_warehouse_city("A")
	_check(_quotes(main.market) == quotes_before, "Remote warehouse viewing must not change prices")
	_check(main.request_transport("B", "t03-ride")["success"], "Passenger transport works")
	main.time_source.advance_ms(90000)
	await process_frame
	_check(main.current_city_id == "B" and _quotes(main.market) == quotes_before, "Passenger transport must not change prices")
	await _destroy(main)
	_sections_done.append("game_integration")


func _verify_save_reload() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	var hub := main.get_node("CityHub") as CityHub
	await _walk_in(main, "A")
	for press in range(7):
		hub.get_market_button("test_good_02", "buy").pressed.emit()
	for press in range(3):
		hub.get_market_button("test_good_02", "sell").pressed.emit()
	for press in range(5):
		hub.get_market_button("test_good_05", "buy").pressed.emit()
	var quotes := _quotes(main.market)
	var snapshot: Dictionary = main.market.get_snapshot()
	var saved := FileAccess.get_file_as_string(TEST_SAVE)
	_check(not saved.contains("dynamic") and not saved.contains("buy_price") and not saved.contains("buyback"), "The save stores stock, not derived prices")
	_check(SaveStore.VERSION == 5, "No save schema change (still version 5)")
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(main.market.get_snapshot() == snapshot, "Reload restores every stock exactly")
	_check(_quotes(main.market) == quotes, "Reload rebuilds identical dynamic reference, buy and buyback prices")
	_check(main.market.get_quote("A", "test_good_02")["stock"] == 96 and main.market.get_quote("A", "test_good_02")["dynamic_reference_price"] == DynamicPriceModel.dynamic_reference(180, 96), "Reloaded A good 2 is at stock 96 with its dynamic price")
	hub = main.get_node("CityHub") as CityHub
	_check(hub.get_market_row_texts("test_good_05")["buy_price"] == "買入價 %d" % quotes["A/test_good_05"]["buy_price"], "The reopened market UI shows the same prices")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("save_reload")


# --- Helpers ------------------------------------------------------------------------------------

## Source code without comment lines, for structural scans.
func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


func _quotes(market: MarketState) -> Dictionary:
	var quotes := {}
	for city in BASELINES:
		for good_id in IDS:
			quotes["%s/%s" % [city, good_id]] = market.get_quote(city, good_id)
	return quotes


func _market_with(stocks: Dictionary) -> MarketState:
	var snapshot := MarketState.create_default().get_snapshot()
	for city in stocks:
		for good_id in stocks[city]:
			snapshot[city][good_id]["current_stock"] = stocks[city][good_id]
	return MarketState.from_snapshot(snapshot)


func _rich_wallet() -> Wallet:
	var wallet := Wallet.new()
	wallet.add(100000000)
	return wallet


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


func _walk_in(main: Node, city: String) -> void:
	var player := main.get_node("Actors/Player") as Player
	player.global_position = WorldLayout.CITY_ANCHORS[city]
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == city, "Must enter City %s" % city)


func _delete(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _settle() -> void:
	# Area2D overlaps update a few physics frames after a teleport.
	for frame in range(4):
		await physics_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
