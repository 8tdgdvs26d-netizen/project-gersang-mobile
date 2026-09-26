extends SceneTree

## Uses its own save file so the player's real save is never touched.
const TEST_SAVE := "user://m2_07_test_save.json"
const CITIES := ["A", "B"]
const REFERENCE := {
	"A": {"test_good_01": 80, "test_good_02": 180, "test_good_03": 420, "test_good_04": 900, "test_good_05": 2100, "test_good_06": 3600},
	"B": {"test_good_01": 120, "test_good_02": 300, "test_good_03": 650, "test_good_04": 1250, "test_good_05": 1700, "test_good_06": 4300},
}
## Hand-computed: buy = ceil(reference x 1.05), buyback = floor(reference x 0.95).
const BUY := {
	"A": {"test_good_01": 84, "test_good_02": 189, "test_good_03": 441, "test_good_04": 945, "test_good_05": 2205, "test_good_06": 3780},
	"B": {"test_good_01": 126, "test_good_02": 315, "test_good_03": 683, "test_good_04": 1313, "test_good_05": 1785, "test_good_06": 4515},
}
const BUYBACK := {
	"A": {"test_good_01": 76, "test_good_02": 171, "test_good_03": 399, "test_good_04": 855, "test_good_05": 1995, "test_good_06": 3420},
	"B": {"test_good_01": 114, "test_good_02": 285, "test_good_03": 617, "test_good_04": 1187, "test_good_05": 1615, "test_good_06": 4085},
}
const SIZES := {"test_good_01": 1, "test_good_02": 1, "test_good_03": 2, "test_good_04": 2, "test_good_05": 3, "test_good_06": 4}
const IDS := ["test_good_01", "test_good_02", "test_good_03", "test_good_04", "test_good_05", "test_good_06"]
const STRESS_STEPS := 320

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_default_market()
	_verify_rules_and_quotes()
	_verify_stock_trades()
	_verify_same_city_loss()
	await _verify_ui()
	await _verify_journey()
	await _verify_persistence()
	await _verify_stress()
	_delete(TEST_SAVE)

	if _failures == 0:
		print("M2-07 basic market foundation verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Market state ----------------------------------------------------------------

func _verify_default_market() -> void:
	var market := MarketState.create_default()
	var snapshot := market.get_snapshot()
	_check(snapshot.keys() == CITIES, "Market must hold exactly the active cities A and B")
	for city in CITIES:
		_check(snapshot[city].keys() == IDS, "City %s market must hold the six goods" % city)
		for good_id in IDS:
			var entry: Dictionary = snapshot[city][good_id]
			_check(entry["current_stock"] == 100, "%s %s initial stock must be 100" % [city, good_id])
			_check(entry["target_stock"] == 100, "%s %s target stock must be 100" % [city, good_id])
			_check(entry["reference_price"] == REFERENCE[city][good_id], "%s %s reference must be the approved price" % [city, good_id])
	_check(MarketPrices.INITIAL_STOCK == 100 and MarketPrices.TARGET_STOCK == 100, "Baseline stock constants must be 100")
	_check(IDS == GoodsCatalog.get_ids(), "Internal good ids must be unchanged")

	# A and B are independent entries, not shared objects.
	market.remove_stock("A", "test_good_01", 5)
	_check(market.get_quote("A", "test_good_01")["stock"] == 95 and market.get_quote("B", "test_good_01")["stock"] == 100, "Changing A stock must not change B")
	_check(market.get_quote("A", "test_good_02")["stock"] == 100, "Changing one good must not change another")
	_check(MarketState.create_default().get_quote("A", "test_good_01")["stock"] == 100, "Default markets must not share state")
	var copy := market.get_snapshot()
	copy["A"]["test_good_01"]["current_stock"] = -50
	_check(market.get_quote("A", "test_good_01")["stock"] == 95, "Snapshots must be deep copies")
	var main_source := FileAccess.get_file_as_string("res://scripts/main.gd")
	_check(main_source.contains("var market := MarketState.create_default()") and not FileAccess.get_file_as_string("res://scripts/player.gd").contains("market"), "Market state must be owned by the world/session, not the player")


func _verify_rules_and_quotes() -> void:
	var market := MarketState.create_default()
	for city in CITIES:
		for good_id in IDS:
			var quote := market.get_quote(city, good_id)
			_check(quote["reference_price"] == REFERENCE[city][good_id], "%s %s quote reference" % [city, good_id])
			_check(quote["buy_price"] == BUY[city][good_id], "%s %s buy price must be ceil(ref x 1.05) = %d" % [city, good_id, BUY[city][good_id]])
			_check(quote["buyback_price"] == BUYBACK[city][good_id], "%s %s buyback must be floor(ref x 0.95) = %d" % [city, good_id, BUYBACK[city][good_id]])
			_check(quote["buy_price"] > quote["buyback_price"], "%s %s buy price must exceed buyback" % [city, good_id])
			_check(quote["stock"] == 100 and quote["target_stock"] == 100, "%s %s quote stock / target" % [city, good_id])
	var rounding := [[100, 105, 95], [80, 84, 76], [1250, 1313, 1187], [650, 683, 617], [20, 21, 19], [2, 3, 1], [7, 8, 6]]
	for case in rounding:
		_check(MarketRules.buy_price(case[0]) == case[1] and MarketRules.buyback_price(case[0]) == case[2], "Reference %d must quote %d / %d" % case)
	_check(MarketRules.buy_price(1) == 0 and MarketRules.buyback_price(0) == 0, "References below 2 cannot be quoted")
	for bad in [["C", "test_good_01"], ["D", "test_good_01"], ["", "test_good_01"], [null, "test_good_01"], ["A", "test_good_07"], ["A", null], ["a", "test_good_01"]]:
		_check(market.get_quote(bad[0], bad[1]).is_empty(), "Quote for %s must be empty" % str(bad))
	var trade_source := FileAccess.get_file_as_string("res://scripts/trade_service.gd")
	_check(trade_source.contains("get_quote(") and not trade_source.contains("MarketPrices") and not trade_source.contains("105") and not trade_source.contains("0.95"), "TradeService must use the market quote, not its own spread")


# --- Trades and stock -------------------------------------------------------------

func _verify_stock_trades() -> void:
	var wallet := Wallet.new()
	var cargo := Cargo.new()
	var market := MarketState.create_default()
	var before := market.get_snapshot()
	var result := TradeService.buy("A", "test_good_03", 2, wallet, cargo, market)
	_check(result["success"] and result["total_value"] == 882 and wallet.get_balance() == 10000 - 882, "Buy must charge the buy price")
	_check(market.get_quote("A", "test_good_03")["stock"] == 98, "Successful buy must reduce stock")
	_check(_changed_entries(before, market.get_snapshot()) == ["A/test_good_03"], "A buy must change only that city's good")
	_check(market.get_quote("A", "test_good_03")["reference_price"] == 420, "Buying must not move the reference price")

	before = market.get_snapshot()
	result = TradeService.sell("B", "test_good_03", 2, wallet, cargo, market)
	_check(result["success"] and result["total_value"] == 1234, "Sell must pay the buyback price")
	_check(market.get_quote("B", "test_good_03")["stock"] == 102, "Successful sell must increase stock")
	_check(_changed_entries(before, market.get_snapshot()) == ["B/test_good_03"], "A sell must change only that city's good")
	_check(market.get_quote("B", "test_good_03")["reference_price"] == 650, "Selling must not move the reference price")
	_check(market.get_quote("B", "test_good_03")["stock"] > market.get_quote("B", "test_good_03")["target_stock"], "Stock may rise above the target")

	# Not enough market stock.
	var low := _market_with({"A": {"test_good_01": 3}})
	var low_wallet := Wallet.new()
	var low_cargo := Cargo.new()
	var low_before := low.get_snapshot()
	result = TradeService.buy("A", "test_good_01", 4, low_wallet, low_cargo, low)
	_check(not result["success"] and result["reason"] == "insufficient_market_stock", "Buying more than the stock must be rejected")
	_check(low_wallet.get_balance() == 10000 and low_cargo.is_empty() and low.get_snapshot() == low_before, "Rejected stock buy must change nothing")
	_check(TradeService.buy("A", "test_good_01", 3, low_wallet, low_cargo, low)["success"] and low.get_quote("A", "test_good_01")["stock"] == 0, "Buying the exact stock must reach 0")
	_check(not TradeService.buy("A", "test_good_01", 1, low_wallet, low_cargo, low)["success"], "An empty stock must reject further buys")
	_check(low.get_quote("A", "test_good_01")["stock"] == 0, "Stock must never go below 0")

	# Rejected sells change nothing, including the market.
	var sell_wallet := Wallet.new()
	var sell_cargo := Cargo.new()
	sell_cargo.add("test_good_02", 2)
	var sell_market := MarketState.create_default()
	var sell_before := sell_market.get_snapshot()
	for attempt in [["A", "test_good_02", 3], ["A", "test_good_05", 1], ["C", "test_good_02", 1], ["A", "bad", 1], ["A", "test_good_02", 0], ["A", "test_good_02", -1], ["A", "test_good_02", 1.5]]:
		var rejected := TradeService.sell(attempt[0], attempt[1], attempt[2], sell_wallet, sell_cargo, sell_market)
		_check(not rejected["success"] and sell_wallet.get_balance() == 10000 and sell_cargo.get_items() == {"test_good_02": 2} and sell_market.get_snapshot() == sell_before, "Rejected sell %s must change nothing" % str(attempt))

	# Selling a lot pushes stock above target.
	var flood_cargo := Cargo.new()
	flood_cargo.add("test_good_01", 10)
	var flood_market := MarketState.create_default()
	_check(TradeService.sell("A", "test_good_01", 10, Wallet.new(), flood_cargo, flood_market)["success"] and flood_market.get_quote("A", "test_good_01")["stock"] == 110, "Selling 10 into 100 stock must reach 110 (no cap at target)")

	# Stock API guards.
	var guarded := MarketState.create_default()
	for quantity in [0, -1, 1.5, "1", null]:
		_check(not guarded.remove_stock("A", "test_good_01", quantity) and not guarded.add_stock("A", "test_good_01", quantity), "Stock quantity %s must be rejected" % str(quantity))
	_check(guarded.get_snapshot() == MarketState.create_default().get_snapshot(), "Rejected stock calls must change nothing")


func _verify_same_city_loss() -> void:
	# Every city/good: buy one and immediately sell it back must lose money.
	for city in CITIES:
		for good_id in IDS:
			var wallet := Wallet.new()
			var cargo := Cargo.new()
			var market := MarketState.create_default()
			TradeService.buy(city, good_id, 1, wallet, cargo, market)
			TradeService.sell(city, good_id, 1, wallet, cargo, market)
			var net := wallet.get_balance() - 10000
			_check(net < 0 and net == BUYBACK[city][good_id] - BUY[city][good_id], "%s %s same-city round trip must lose (net %d)" % [city, good_id, net])
			_check(market.get_quote(city, good_id)["stock"] == 100, "%s %s round trip must restore stock" % [city, good_id])

	# The approved same-city proof: A Good 1 x 10.
	var wallet := Wallet.new()
	var cargo := Cargo.new()
	var market := MarketState.create_default()
	_check(TradeService.buy("A", "test_good_01", 10, wallet, cargo, market)["success"] and wallet.get_balance() == 9160, "Same-city: buy 10 @84 -> 9160")
	_check(market.get_quote("A", "test_good_01")["stock"] == 90, "Same-city: stock 100 -> 90")
	_check(TradeService.sell("A", "test_good_01", 10, wallet, cargo, market)["success"] and wallet.get_balance() == 9920, "Same-city: sell 10 @76 -> 9920")
	_check(10000 - wallet.get_balance() == 80, "Same-city: loss must be 80")
	_check(market.get_quote("A", "test_good_01")["stock"] == 100 and market.get_quote("A", "test_good_01")["reference_price"] == 80, "Same-city: stock back to 100, reference 80 throughout")


# --- UI -----------------------------------------------------------------------------

func _verify_ui() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	await _enter(main, "A")
	var hub := main.get_node("CityHub") as CityHub
	_check(_ui_matches(main), "Market UI must show the A quotes, holdings and stock")
	var row := hub.get_market_row_texts("test_good_01")
	_check(row == {"name": "測試商品一", "buy_price": "買入價 84", "buyback_price": "賣出價 76", "held": "持有 0", "stock": "庫存 100"}, "Good 1 row must show Chinese name, prices, held and stock (%s)" % str(row))
	hub.get_market_button("test_good_01", "buy").pressed.emit()
	_check(hub.get_market_row_texts("test_good_01")["stock"] == "庫存 99" and hub.get_market_row_texts("test_good_01")["held"] == "持有 1", "Buying must refresh stock and held immediately")
	_check(hub.get_money_label_text() == "金錢：9916" and hub.get_cargo_label_text() == "貨物容量：1 / 20", "Money and cargo must refresh in Chinese")
	_check(hub.get_feedback_text() == "已買入 1 件測試商品一，支付 84", "Buy feedback must be Chinese")
	hub.get_market_button("test_good_01", "sell").pressed.emit()
	_check(hub.get_feedback_text() == "已賣出 1 件測試商品一，收入 76" and hub.get_market_row_texts("test_good_01")["stock"] == "庫存 100", "Sell feedback and stock must refresh")
	hub.get_market_button("test_good_01", "sell").pressed.emit()
	_check(hub.get_feedback_text() == "持有貨物不足", "Failure feedback must be Chinese")
	_check(_ui_matches(main), "UI must stay in sync with the quotes")
	_check(_player_text_is_chinese(hub), "All visible City Hub text must be Traditional Chinese (no Latin letters besides the city code)")
	for good_id in IDS:
		_check(hub.get_market_button(good_id, "buy").text == "買入 1" and hub.get_market_button(good_id, "sell").text == "賣出 1", "%s buttons must read 買入 1 / 賣出 1" % good_id)
	_check(hub.get_market_good_ids() == IDS, "UI rows must still be keyed by the internal ids")
	main.leave_city()
	await _destroy(main)

	# The UI must follow the quote, not any fixed price table: load a market whose
	# A Good 1 reference is 200 and B Good 2 stock is 7.
	_write_save({"version": 2, "money": 10000, "cargo": {}, "market": _snapshot_with({"A": {"test_good_01": {"reference_price": 200}}, "B": {"test_good_02": {"current_stock": 7}}})})
	var custom := await _new_main(TEST_SAVE)
	await _enter(custom, "A")
	var custom_hub := custom.get_node("CityHub") as CityHub
	_check(custom_hub.get_market_row_texts("test_good_01")["buy_price"] == "買入價 210" and custom_hub.get_market_row_texts("test_good_01")["buyback_price"] == "賣出價 190", "UI must display the quote from the loaded market")
	custom.leave_city()
	await _enter(custom, "B")
	_check(custom_hub.get_market_row_texts("test_good_02")["stock"] == "庫存 7" and custom_hub.get_market_row_texts("test_good_01")["buy_price"] == "買入價 126", "Entering B must show B's own market state")
	await _destroy(custom)
	_delete(TEST_SAVE)


# --- Journey ------------------------------------------------------------------------

func _verify_journey() -> void:
	_delete(TEST_SAVE)
	var first := await _new_main(TEST_SAVE)
	_check(first.wallet.get_balance() == 10000 and first.cargo.is_empty(), "Journey fresh: 10000 / empty")
	_check(_stock(first, "A", "test_good_01") == 100 and _stock(first, "B", "test_good_01") == 100, "Journey fresh: A and B Good 1 stock 100")
	await _enter(first, "A")
	var quote: Dictionary = first.market.get_quote("A", "test_good_01")
	_check(quote["reference_price"] == 80 and quote["buy_price"] == 84 and quote["buyback_price"] == 76, "Journey: A Good 1 is 80 / 84 / 76")
	var hub := first.get_node("CityHub") as CityHub
	for press in range(10):
		hub.get_market_button("test_good_01", "buy").pressed.emit()
	_check(first.wallet.get_balance() == 9160 and first.cargo.get_quantity("test_good_01") == 10, "Journey A buy: 9160 / 10")
	_check(_stock(first, "A", "test_good_01") == 90 and _stock(first, "B", "test_good_01") == 100, "Journey A buy: A stock 90, B stock 100")
	var first_market: MarketState = first.market
	await _destroy(first)

	var second := await _new_main(TEST_SAVE)
	_check(second.market != first_market, "Restart must build a new market object")
	_check(second.wallet.get_balance() == 9160 and second.cargo.get_quantity("test_good_01") == 10, "Journey restart #1: 9160 / 10")
	_check(_stock(second, "A", "test_good_01") == 90 and _stock(second, "B", "test_good_01") == 100, "Journey restart #1: A stock 90, B stock 100")
	await _enter(second, "B")
	var quote_b: Dictionary = second.market.get_quote("B", "test_good_01")
	_check(quote_b["reference_price"] == 120 and quote_b["buy_price"] == 126 and quote_b["buyback_price"] == 114, "Journey: B Good 1 is 120 / 126 / 114")
	var hub_b := second.get_node("CityHub") as CityHub
	_check(hub_b.get_market_row_texts("test_good_01")["stock"] == "庫存 100", "B market must show its own stock after restart")
	for press in range(10):
		hub_b.get_market_button("test_good_01", "sell").pressed.emit()
	_check(second.wallet.get_balance() == 10300 and second.cargo.is_empty(), "Journey B sell: 10300 / 0")
	_check(_stock(second, "A", "test_good_01") == 90 and _stock(second, "B", "test_good_01") == 110, "Journey B sell: A stock 90, B stock 110")
	await _destroy(second)

	var third := await _new_main(TEST_SAVE)
	_check(third.wallet.get_balance() == 10300 and third.cargo.is_empty(), "Journey restart #2: 10300 / 0")
	_check(_stock(third, "A", "test_good_01") == 90 and _stock(third, "B", "test_good_01") == 110, "Journey restart #2: A stock 90, B stock 110")
	_check(third.market.get_quote("A", "test_good_01")["reference_price"] == 80 and third.market.get_quote("B", "test_good_01")["reference_price"] == 120, "Journey: reference prices never moved")
	await _destroy(third)


# --- Persistence ----------------------------------------------------------------------

func _verify_persistence() -> void:
	# A successful trade writes the market.
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	await _enter(main, "B")
	main.buy_in_current_city("test_good_04", 3)
	var saved := _parse(TEST_SAVE)
	_check(int(saved.get("version", 0)) == 2 and saved.has("market"), "A successful trade must write a version 2 save with the market")
	_check(int(saved["market"]["B"]["test_good_04"]["current_stock"]) == 97 and int(saved["market"]["B"]["test_good_04"]["target_stock"]) == 100 and int(saved["market"]["B"]["test_good_04"]["reference_price"]) == 1250, "Saved market must hold stock, target and reference")
	var before_failure := _read(TEST_SAVE)
	main.buy_in_current_city("test_good_06", 10)
	_check(_read(TEST_SAVE) == before_failure, "A failed trade must not rewrite the market save")
	await _destroy(main)
	var reloaded := await _new_main(TEST_SAVE)
	_check(_stock(reloaded, "B", "test_good_04") == 97 and reloaded.cargo.get_quantity("test_good_04") == 3, "Restart must restore market stock and cargo")
	await _destroy(reloaded)

	# Legacy M2-06 save without a market: keep money/cargo, fresh market.
	_write_text(TEST_SAVE, '{"version": 1, "money": 7777, "cargo": {"test_good_02": 3}}')
	var legacy := await _new_main(TEST_SAVE)
	_check(legacy.wallet.get_balance() == 7777 and legacy.cargo.get_items() == {"test_good_02": 3}, "Legacy save must restore money and cargo")
	_check(legacy.market.get_snapshot() == MarketState.create_default().get_snapshot(), "Legacy save must get a fresh default market")
	_check(_read(TEST_SAVE) == '{"version": 1, "money": 7777, "cargo": {"test_good_02": 3}}', "Loading a legacy save must not rewrite it")
	await _enter(legacy, "A")
	legacy.sell_in_current_city("test_good_02", 1)
	var upgraded := _parse(TEST_SAVE)
	_check(int(upgraded.get("version", 0)) == 2 and int(upgraded["market"]["A"]["test_good_02"]["current_stock"]) == 101 and int(upgraded["money"]) == 7777 + 171, "The next trade must write a version 2 save with the market")
	await _destroy(legacy)
	_write_text(TEST_SAVE, '{"money": 500, "cargo": {}}')
	var unversioned := await _new_main(TEST_SAVE)
	_check(unversioned.wallet.get_balance() == 500, "An M2-06 save without a version field must still load")
	await _destroy(unversioned)

	# Invalid market data rejects the whole save (no partial restore).
	var broken := {
		"unknown city": _snapshot_plus_city("C"),
		"missing city": _snapshot_without_city("B"),
		"unknown good": _snapshot_plus_good("A", "test_good_07"),
		"missing good": _snapshot_without_good("A", "test_good_06"),
		"negative stock": _snapshot_with({"A": {"test_good_01": {"current_stock": -1}}}),
		"non-integer stock": _snapshot_with({"A": {"test_good_01": {"current_stock": 12.5}}}),
		"string stock": _snapshot_with({"B": {"test_good_03": {"current_stock": "90"}}}),
		"zero reference": _snapshot_with({"A": {"test_good_02": {"reference_price": 0}}}),
		"reference below 2": _snapshot_with({"A": {"test_good_02": {"reference_price": 1}}}),
		"zero target": _snapshot_with({"B": {"test_good_05": {"target_stock": 0}}}),
		"missing field": _snapshot_without_field("A", "test_good_01", "target_stock"),
		"extra field": _snapshot_with({"A": {"test_good_01": {"buy_price": 84}}}),
		"market not a dictionary": [1, 2],
		"city not a dictionary": {"A": 5, "B": 6},
	}
	for label in broken:
		var text := JSON.stringify({"version": 2, "money": 9160, "cargo": {"test_good_01": 10}, "market": broken[label]})
		_write_text(TEST_SAVE, text)
		var bad := await _new_main(TEST_SAVE)
		_check(bad.wallet.get_balance() == 10000 and bad.cargo.is_empty(), "Invalid market (%s) must not restore money or cargo" % label)
		_check(bad.market.get_snapshot() == MarketState.create_default().get_snapshot(), "Invalid market (%s) must fall back to the default market" % label)
		_check(_read(TEST_SAVE) == text, "Invalid market (%s) save must not be overwritten on load" % label)
		await _destroy(bad)
	_write_text(TEST_SAVE, '{"version": 2, "money": 9160, "cargo": {}}')
	var no_market := await _new_main(TEST_SAVE)
	_check(no_market.wallet.get_balance() == 10000, "A version 2 save without a market must be rejected")
	await _destroy(no_market)
	_delete(TEST_SAVE)


# --- Stress ----------------------------------------------------------------------------

## Deterministic trades, rejects, city switches and full recreate/load cycles,
## compared with an independent model of money, cargo, stock, reference and target.
func _verify_stress() -> void:
	# Start from a saved market with low stock so stock rejections happen.
	var low := {"A": {"test_good_01": {"current_stock": 4}, "test_good_05": {"current_stock": 2}}, "B": {"test_good_02": {"current_stock": 3}, "test_good_06": {"current_stock": 1}}}
	_write_save({"version": 2, "money": 10000, "cargo": {}, "market": _snapshot_with(low)})
	var main := await _new_main(TEST_SAVE)
	var city := "A"
	await _enter(main, city)
	var money := 10000
	var cargo := {}
	var stock := {}
	for c in CITIES:
		stock[c] = {}
		for good_id in IDS:
			stock[c][good_id] = low.get(c, {}).get(good_id, {}).get("current_stock", 100)
	var quantities := [1, 1, 1, 2, 3, 0, -1, 25]
	var seed := 70707
	var drift := 0
	var invariant_breaks := 0
	var counts := {"buy_ok": 0, "buy_rejected": 0, "stock_rejected": 0, "sell_ok": 0, "sell_rejected": 0, "recreate": 0, "switch": 0}
	for step in range(STRESS_STEPS):
		seed = (seed * 1103515245 + 12345) % 2147483648
		var bits := seed >> 8
		if step > 0 and step % 32 == 0:
			city = "B" if city == "A" else "A"
			main.leave_city()
			await _enter(main, city)
			counts["switch"] += 1
		if bits % 13 == 12:
			await _destroy(main)
			main = await _new_main(TEST_SAVE)
			await _enter(main, city)
			counts["recreate"] += 1
		else:
			var good_id: String = (IDS + ["bad_good"])[(bits >> 4) % 7]
			var quantity: int = quantities[(bits >> 7) % quantities.size()]
			var is_buy := (bits >> 10) % 2 == 0
			if not is_buy and not cargo.is_empty() and (bits >> 11) % 4 != 0:
				var held := cargo.keys()
				held.sort()
				good_id = held[(bits >> 13) % held.size()]
			var valid := good_id in IDS and quantity > 0
			var expected := false
			if is_buy:
				var price: int = BUY[city].get(good_id, 0)
				var stock_ok: bool = valid and quantity <= stock[city][good_id]
				if valid and not stock_ok:
					counts["stock_rejected"] += 1
				expected = stock_ok and _used(cargo) + quantity * SIZES[good_id] <= 20 and price * quantity <= money
				if expected:
					money -= price * quantity
					cargo[good_id] = cargo.get(good_id, 0) + quantity
					stock[city][good_id] -= quantity
			else:
				expected = valid and cargo.get(good_id, 0) >= quantity
				if expected:
					money += BUYBACK[city][good_id] * quantity
					cargo[good_id] -= quantity
					if cargo[good_id] == 0:
						cargo.erase(good_id)
					stock[city][good_id] += quantity
			var result: Dictionary = main.buy_in_current_city(good_id, quantity) if is_buy else main.sell_in_current_city(good_id, quantity)
			counts[("buy_" if is_buy else "sell_") + ("ok" if result["success"] else "rejected")] += 1
			if result["success"] != expected:
				drift += 1
		# Compare the full state with the model after every step.
		if main.wallet.get_balance() != money or main.cargo.get_items() != cargo:
			drift += 1
		for c in CITIES:
			for good_id in IDS:
				var quote: Dictionary = main.market.get_quote(c, good_id)
				if quote["stock"] != stock[c][good_id] or quote["reference_price"] != REFERENCE[c][good_id] or quote["target_stock"] != 100:
					drift += 1
				if quote["stock"] < 0 or quote["target_stock"] <= 0 or quote["reference_price"] <= 0 or quote["buy_price"] <= quote["buyback_price"]:
					invariant_breaks += 1
		if main.wallet.get_balance() < 0 or main.cargo.get_used_capacity() > 20:
			invariant_breaks += 1
	_check(drift == 0, "Stress: money, cargo, stock, reference and target must match the model (%d drifts)" % drift)
	_check(invariant_breaks == 0, "Stress: market and player invariants must hold (%d breaks)" % invariant_breaks)
	_check(counts["buy_ok"] >= 30 and counts["sell_ok"] >= 30 and counts["buy_rejected"] >= 30 and counts["sell_rejected"] >= 30, "Stress: must mix valid and rejected trades %s" % str(counts))
	_check(counts["stock_rejected"] >= 3 and counts["recreate"] >= 15 and counts["switch"] >= 8, "Stress: must hit stock rejections, recreates and switches %s" % str(counts))
	print("M2-07 stress counts: ", counts)
	await _destroy(main)


# --- Helpers ------------------------------------------------------------------------------

func _ui_matches(main: Node) -> bool:
	var hub := main.get_node("CityHub") as CityHub
	for good_id in IDS:
		var quote: Dictionary = main.market.get_quote(main.current_city_id, good_id)
		var texts := hub.get_market_row_texts(good_id)
		if texts["buy_price"] != "買入價 %d" % quote["buy_price"] or texts["buyback_price"] != "賣出價 %d" % quote["buyback_price"]:
			return false
		if texts["stock"] != "庫存 %d" % quote["stock"] or texts["held"] != "持有 %d" % main.cargo.get_quantity(good_id):
			return false
	return true


## True when every visible label and button in the hub has no Latin letters,
## apart from the placeholder city code in the city title.
func _player_text_is_chinese(hub: CityHub) -> bool:
	var latin := RegEx.new()
	latin.compile("[A-Za-z]")
	var texts := []
	for node in hub.find_children("*", "Label", true, false) + hub.find_children("*", "Button", true, false):
		texts.append((node as Control).get("text"))
	var city_title: String = hub.get_city_label_text()
	for text in texts:
		var checked: String = text
		if text == city_title:
			checked = text.replace(hub.city_id, "")
		if latin.search(checked) != null:
			push_error("Latin text in hub: %s" % text)
			return false
	return texts.size() >= 40


func _changed_entries(before: Dictionary, after: Dictionary) -> Array:
	var changed := []
	for city in before:
		for good_id in before[city]:
			if before[city][good_id] != after[city][good_id]:
				changed.append("%s/%s" % [city, good_id])
	return changed


func _market_with(stock_overrides: Dictionary) -> MarketState:
	var overrides := {}
	for city in stock_overrides:
		overrides[city] = {}
		for good_id in stock_overrides[city]:
			overrides[city][good_id] = {"current_stock": stock_overrides[city][good_id]}
	return MarketState.from_snapshot(_snapshot_with(overrides))


func _snapshot_with(overrides: Dictionary) -> Dictionary:
	var snapshot := MarketState.create_default().get_snapshot()
	for city in overrides:
		for good_id in overrides[city]:
			for key in overrides[city][good_id]:
				snapshot[city][good_id][key] = overrides[city][good_id][key]
	return snapshot


func _snapshot_plus_city(city: String) -> Dictionary:
	var snapshot := MarketState.create_default().get_snapshot()
	snapshot[city] = snapshot["A"].duplicate(true)
	return snapshot


func _snapshot_without_city(city: String) -> Dictionary:
	var snapshot := MarketState.create_default().get_snapshot()
	snapshot.erase(city)
	return snapshot


func _snapshot_plus_good(city: String, good_id: String) -> Dictionary:
	var snapshot := MarketState.create_default().get_snapshot()
	snapshot[city][good_id] = {"reference_price": 100, "current_stock": 100, "target_stock": 100}
	return snapshot


func _snapshot_without_good(city: String, good_id: String) -> Dictionary:
	var snapshot := MarketState.create_default().get_snapshot()
	snapshot[city].erase(good_id)
	return snapshot


func _snapshot_without_field(city: String, good_id: String, field: String) -> Dictionary:
	var snapshot := MarketState.create_default().get_snapshot()
	snapshot[city][good_id].erase(field)
	return snapshot


func _stock(main: Node, city: String, good_id: String) -> int:
	return main.market.get_quote(city, good_id)["stock"]


func _used(model: Dictionary) -> int:
	var used := 0
	for good_id in model:
		used += model[good_id] * SIZES[good_id]
	return used


func _new_main(path: String) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	root.add_child(main)
	await _settle()
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _enter(main: Node, city: String) -> void:
	var player := main.get_node("Actors/Player") as Player
	player.global_position = WorldLayout.CITY_ANCHORS[city]
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == city, "Must enter City %s" % city)


func _parse(path: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(_read(path)) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return {}
	return parser.data


func _write_save(data: Dictionary) -> void:
	_write_text(TEST_SAVE, JSON.stringify(data))


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else "<missing>"


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


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
