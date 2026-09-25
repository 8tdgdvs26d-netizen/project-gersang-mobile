extends SceneTree

const APPROVED_PRICES := {
	"A": {"test_good_01": 80, "test_good_02": 180, "test_good_03": 420, "test_good_04": 900, "test_good_05": 2100, "test_good_06": 3600},
	"B": {"test_good_01": 120, "test_good_02": 300, "test_good_03": 650, "test_good_04": 1250, "test_good_05": 1700, "test_good_06": 4300},
}
const APPROVED_SIZES := {"test_good_01": 1, "test_good_02": 1, "test_good_03": 2, "test_good_04": 2, "test_good_05": 3, "test_good_06": 4}
const INVALID_AMOUNTS := [0, -1, -500, 1.5, 100.0, NAN, INF, "100", null]
const INVALID_QUANTITIES := [0, -1, -3, 1.5, 2.0, NAN, INF, "2", null]
const INVALID_CITIES := ["", "C", "D", "a", "Z", null, 1]
const INVALID_GOODS := ["", "test_good_07", "TEST_GOOD_01", null, 5]
const STRESS_STEPS := 600

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_verify_wallet()
	_verify_price_table()
	_verify_buy()
	_verify_sell()
	_verify_reverse_and_loss()
	_verify_single_execution()
	_verify_stress()
	await _verify_trade_loop_in_game()

	if _failures == 0:
		print("M2-04 money and buy/sell core verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Wallet ----------------------------------------------------------------

func _verify_wallet() -> void:
	var wallet := Wallet.new()
	_check(Wallet.STARTING_MONEY == 10000 and wallet.get_balance() == 10000, "Starting money must be 10000")
	_check(wallet.can_spend(1500) and wallet.spend(1500) and wallet.get_balance() == 8500, "Valid spend must reduce the balance")
	_check(wallet.can_add(700) and wallet.add(700) and wallet.get_balance() == 9200, "Valid add must increase the balance")
	for amount in INVALID_AMOUNTS:
		_check(not wallet.spend(amount) and not wallet.add(amount), "Amount %s must be rejected" % str(amount))
	_check(not wallet.can_spend(9201) and not wallet.spend(9201), "Overspending must be rejected")
	_check(wallet.get_balance() == 9200, "Rejected wallet calls must leave the balance unchanged")
	_check(wallet.spend(9200) and wallet.get_balance() == 0, "Spending the full balance must reach exactly 0")
	_check(not wallet.spend(1) and wallet.get_balance() == 0, "Money must never become negative")
	_check(not wallet.add(Wallet.MAX_BALANCE) or wallet.get_balance() >= 0, "Huge adds must not overflow")
	var full := Wallet.new()
	full.add(Wallet.MAX_BALANCE - Wallet.STARTING_MONEY)
	_check(not full.add(1) and full.get_balance() == Wallet.MAX_BALANCE, "Adding past the int limit must be rejected")


# --- Prices ----------------------------------------------------------------

func _verify_price_table() -> void:
	_check(MarketPrices.PRICES.keys() == ["A", "B"], "Price table must cover exactly the 2 active cities")
	var entries := 0
	for city_id in APPROVED_PRICES:
		_check(MarketPrices.PRICES[city_id].size() == 6, "City %s must price exactly 6 goods" % city_id)
		for good_id in GoodsCatalog.get_ids():
			var price := MarketPrices.get_price(city_id, good_id)
			_check(typeof(MarketPrices.PRICES[city_id][good_id]) == TYPE_INT and price > 0, "%s %s price must be a positive int" % [city_id, good_id])
			_check(price == APPROVED_PRICES[city_id][good_id], "%s %s price must be the approved test value" % [city_id, good_id])
			entries += 1
	_check(entries == 12, "Price table must hold 12 entries")
	for city_id in INVALID_CITIES:
		_check(MarketPrices.get_price(city_id, "test_good_01") == 0 and not MarketPrices.has_price(city_id, "test_good_01"), "City %s must have no price" % str(city_id))
	for good_id in INVALID_GOODS:
		_check(MarketPrices.get_price("A", good_id) == 0, "Good %s must have no price" % str(good_id))

	var profitable_a_to_b := 0
	var profitable_b_to_a := 0
	for good_id in GoodsCatalog.get_ids():
		if APPROVED_PRICES["B"][good_id] > APPROVED_PRICES["A"][good_id]:
			profitable_a_to_b += 1
		elif APPROVED_PRICES["A"][good_id] > APPROVED_PRICES["B"][good_id]:
			profitable_b_to_a += 1
	_check(profitable_a_to_b > 0 and profitable_b_to_a > 0, "Both route directions must have a profitable good")


# --- Buy -------------------------------------------------------------------

func _verify_buy() -> void:
	var wallet := Wallet.new()
	var cargo := Cargo.new()
	var result := TradeService.buy("A", "test_good_03", 3, wallet, cargo)
	_check(result["success"] and result["total_value"] == 1260 and result["reason"] == "", "Valid buy must succeed with its total")
	_check(wallet.get_balance() == 10000 - 1260, "Buy must reduce money by price x quantity")
	_check(cargo.get_quantity("test_good_03") == 3, "Buy must add the exact quantity")
	_check(cargo.get_used_capacity() == 6, "Buy must update used capacity")
	_check(TradeService.buy("A", "test_good_03", 1, wallet, cargo)["success"] and cargo.get_quantity("test_good_03") == 4, "Buying the same good must stack")
	_check(TradeService.buy("B", "test_good_02", 2, wallet, cargo)["success"], "Buying a second good must succeed")
	_check(cargo.get_items() == {"test_good_03": 4, "test_good_02": 2} and cargo.get_used_capacity() == 10, "Multiple goods must be held together")
	_check(wallet.get_balance() == 10000 - 1680 - 600, "Money must reflect every buy exactly")

	# Money is enough but cargo is full: nothing may change.
	var full_cargo := Cargo.new()
	full_cargo.add("test_good_06", 5)
	var rich := Wallet.new()
	_expect_buy_rejected("A", "test_good_01", 1, rich, full_cargo, "insufficient_cargo_space", "Full cargo")

	# Cargo has room but money is short: nothing may change.
	var poor := Wallet.new()
	poor.spend(9000)
	_expect_buy_rejected("A", "test_good_06", 1, poor, Cargo.new(), "insufficient_money", "Insufficient money")
	_expect_buy_rejected("B", "test_good_02", 4, poor, Cargo.new(), "insufficient_money", "Insufficient money by 200")

	for city_id in INVALID_CITIES:
		_expect_buy_rejected(city_id, "test_good_01", 1, Wallet.new(), Cargo.new(), "invalid_city_or_good", "Invalid city %s" % str(city_id))
	for good_id in INVALID_GOODS:
		_expect_buy_rejected("A", good_id, 1, Wallet.new(), Cargo.new(), "invalid_city_or_good", "Invalid good %s" % str(good_id))
	for quantity in INVALID_QUANTITIES:
		_expect_buy_rejected("A", "test_good_01", quantity, Wallet.new(), Cargo.new(), "invalid_quantity", "Quantity %s" % str(quantity))
	_expect_buy_rejected("A", "test_good_01", 1_000_000_000_000_000, Wallet.new(), Cargo.new(), "insufficient_cargo_space", "Huge quantity")
	_check(not TradeService.buy("A", "test_good_01", 1, null, Cargo.new())["success"], "Buy without a wallet must fail")
	_check(not TradeService.buy("A", "test_good_01", 1, Wallet.new(), null)["success"], "Buy without a cargo must fail")

	var exact := Wallet.new()
	var exact_cargo := Cargo.new()
	exact.spend(10000 - 3600)
	_check(TradeService.buy("A", "test_good_06", 1, exact, exact_cargo)["success"] and exact.get_balance() == 0, "Buying with exactly enough money must succeed")


func _expect_buy_rejected(city_id: Variant, good_id: Variant, quantity: Variant, wallet: Wallet, cargo: Cargo, reason: String, label: String) -> void:
	var balance := wallet.get_balance()
	var items := cargo.get_items()
	var result := TradeService.buy(city_id, good_id, quantity, wallet, cargo)
	_check(not result["success"] and result["reason"] == reason, "%s buy must fail with %s (got %s)" % [label, reason, result["reason"]])
	_check(wallet.get_balance() == balance, "%s failed buy must leave money unchanged" % label)
	_check(cargo.get_items() == items, "%s failed buy must leave cargo unchanged" % label)


# --- Sell ------------------------------------------------------------------

func _verify_sell() -> void:
	var wallet := Wallet.new()
	var cargo := Cargo.new()
	cargo.add("test_good_04", 5)
	cargo.add("test_good_01", 2)
	var result := TradeService.sell("B", "test_good_04", 2, wallet, cargo)
	_check(result["success"] and result["total_value"] == 2500, "Valid sell must succeed with its total")
	_check(cargo.get_quantity("test_good_04") == 3, "Sell must reduce the exact quantity")
	_check(wallet.get_balance() == 12500, "Sell must add price x quantity")
	_check(TradeService.sell("A", "test_good_04", 3, wallet, cargo)["success"], "Selling the rest must succeed")
	_check(not cargo.get_items().has("test_good_04") and wallet.get_balance() == 12500 + 2700, "Selling to zero must remove the entry")

	_expect_sell_rejected("A", "test_good_01", 3, wallet, cargo, "insufficient_cargo", "Too many")
	_expect_sell_rejected("A", "test_good_06", 1, wallet, cargo, "insufficient_cargo", "Not held")
	for city_id in INVALID_CITIES:
		_expect_sell_rejected(city_id, "test_good_01", 1, wallet, cargo, "invalid_city_or_good", "Invalid city %s" % str(city_id))
	for good_id in INVALID_GOODS:
		_expect_sell_rejected("B", good_id, 1, wallet, cargo, "invalid_city_or_good", "Invalid good %s" % str(good_id))
	for quantity in INVALID_QUANTITIES:
		_expect_sell_rejected("B", "test_good_01", quantity, wallet, cargo, "invalid_quantity", "Quantity %s" % str(quantity))
	_check(not TradeService.sell("B", "test_good_01", 1, null, cargo)["success"] and cargo.get_quantity("test_good_01") == 2, "Sell without a wallet must fail without touching cargo")


func _expect_sell_rejected(city_id: Variant, good_id: Variant, quantity: Variant, wallet: Wallet, cargo: Cargo, reason: String, label: String) -> void:
	var balance := wallet.get_balance()
	var items := cargo.get_items()
	var result := TradeService.sell(city_id, good_id, quantity, wallet, cargo)
	_check(not result["success"] and result["reason"] == reason, "%s sell must fail with %s (got %s)" % [label, reason, result["reason"]])
	_check(wallet.get_balance() == balance, "%s failed sell must leave money unchanged" % label)
	_check(cargo.get_items() == items, "%s failed sell must leave cargo unchanged" % label)


# --- Route examples --------------------------------------------------------

func _verify_reverse_and_loss() -> void:
	var wallet := Wallet.new()
	var cargo := Cargo.new()
	_check(not TradeService.buy("B", "test_good_05", 7, wallet, cargo)["success"], "7 x good 5 (21 units) must not fit")
	_check(TradeService.buy("B", "test_good_05", 2, wallet, cargo)["success"] and wallet.get_balance() == 6600, "Reverse: buy 2 x good 5 in B for 3400")
	_check(TradeService.sell("A", "test_good_05", 2, wallet, cargo)["success"] and wallet.get_balance() == 10800, "Reverse: sell 2 x good 5 in A for 4200")
	_check(wallet.get_balance() - Wallet.STARTING_MONEY == 800 and cargo.is_empty(), "B to A good 5 must profit +800")

	var loss_wallet := Wallet.new()
	var loss_cargo := Cargo.new()
	_check(TradeService.buy("A", "test_good_05", 2, loss_wallet, loss_cargo)["success"] and loss_wallet.get_balance() == 5800, "Loss: buy 2 x good 5 in A for 4200")
	_check(TradeService.sell("B", "test_good_05", 2, loss_wallet, loss_cargo)["success"] and loss_wallet.get_balance() == 9200, "Loss: sell 2 x good 5 in B for 3400")
	_check(loss_wallet.get_balance() - Wallet.STARTING_MONEY == -800, "A to B good 5 must lose -800")


func _verify_single_execution() -> void:
	var wallet := Wallet.new()
	var cargo := Cargo.new()
	TradeService.buy("A", "test_good_02", 1, wallet, cargo)
	_check(wallet.get_balance() == 10000 - 180 and cargo.get_quantity("test_good_02") == 1, "One buy call must apply exactly once")
	TradeService.sell("B", "test_good_02", 1, wallet, cargo)
	_check(wallet.get_balance() == 10000 - 180 + 300 and cargo.is_empty(), "One sell call must apply exactly once")
	var source := FileAccess.get_file_as_string("res://scripts/trade_service.gd")
	_check(not source.contains("_items") and not source.contains("_balance"), "Trade core must use the Cargo and Wallet APIs, not their internals")
	_check(not source.contains("signal") and not source.contains(".connect("), "Trade core must not use signals that could double-fire")


# --- Stress ----------------------------------------------------------------

## Deterministic transaction stress test against an independent reference model.
func _verify_stress() -> void:
	var wallet := Wallet.new()
	var cargo := Cargo.new()
	var model_money := Wallet.STARTING_MONEY
	var model_cargo := {}
	var cities := ["A", "A", "B", "B", "A", "B", "C", ""]
	var goods := GoodsCatalog.get_ids() + ["bad_good"]
	var quantities := [1, 1, 1, 2, 2, 3, 4, 0, -1, 25]
	var seed := 424242
	var mismatches := 0
	var invariant_breaks := 0
	var impure_failures := 0
	var counts := {"buy_ok": 0, "buy_rejected": 0, "sell_ok": 0, "sell_rejected": 0}
	var cities_used := {}
	var goods_traded := {}
	for step in range(STRESS_STEPS):
		seed = (seed * 1103515245 + 12345) % 2147483648
		var bits := seed >> 8
		var city_id: String = cities[bits % cities.size()]
		var good_id: String = goods[(bits >> 3) % goods.size()]
		var quantity: Variant = quantities[(bits >> 6) % quantities.size()]
		if (bits >> 10) % 23 == 0:
			quantity = 1.5
		var is_buy := (bits >> 12) % 2 == 0
		if not is_buy and not model_cargo.is_empty() and (bits >> 13) % 4 != 0:
			var held := model_cargo.keys()
			held.sort()
			good_id = held[(bits >> 15) % held.size()]

		var money_before := wallet.get_balance()
		var items_before := cargo.get_items()
		var price: int = APPROVED_PRICES.get(city_id, {}).get(good_id, 0)
		var valid_quantity: bool = typeof(quantity) == TYPE_INT and quantity > 0
		var expected := false
		var result := {}
		if is_buy:
			var used := _model_used(model_cargo)
			expected = price > 0 and valid_quantity and used + quantity * APPROVED_SIZES.get(good_id, 0) <= 20 \
				and price * quantity <= model_money
			if expected:
				model_money -= price * quantity
				model_cargo[good_id] = model_cargo.get(good_id, 0) + quantity
			result = TradeService.buy(city_id, good_id, quantity, wallet, cargo)
			counts["buy_ok" if result["success"] else "buy_rejected"] += 1
		else:
			expected = price > 0 and valid_quantity and model_cargo.get(good_id, 0) >= quantity
			if expected:
				model_money += price * quantity
				model_cargo[good_id] -= quantity
				if model_cargo[good_id] == 0:
					model_cargo.erase(good_id)
			result = TradeService.sell(city_id, good_id, quantity, wallet, cargo)
			counts["sell_ok" if result["success"] else "sell_rejected"] += 1
		if result["success"]:
			cities_used[city_id] = true
			goods_traded[good_id] = true

		if result["success"] != expected or wallet.get_balance() != model_money or cargo.get_items() != model_cargo:
			mismatches += 1
		if not result["success"] and (wallet.get_balance() != money_before or cargo.get_items() != items_before):
			impure_failures += 1
		if not _state_valid(wallet, cargo):
			invariant_breaks += 1
	_check(mismatches == 0, "Stress: wallet and cargo must match the reference model on all %d steps (%d mismatches)" % [STRESS_STEPS, mismatches])
	_check(impure_failures == 0, "Stress: every failed transaction must be state-neutral (%d impure)" % impure_failures)
	_check(invariant_breaks == 0, "Stress: invariants must hold on every step (%d breaks)" % invariant_breaks)
	_check(counts["buy_ok"] >= 50 and counts["sell_ok"] >= 50, "Stress: must exercise successful buys and sells %s" % str(counts))
	_check(counts["buy_rejected"] >= 50 and counts["sell_rejected"] >= 50, "Stress: must exercise rejected buys and sells %s" % str(counts))
	_check(cities_used.size() == 2 and goods_traded.size() == 6, "Stress: successful trades must cover both cities and all six goods")
	print("M2-04 stress counts: ", counts)


func _model_used(model: Dictionary) -> int:
	var used := 0
	for good_id in model:
		used += model[good_id] * APPROVED_SIZES[good_id]
	return used


func _state_valid(wallet: Wallet, cargo: Cargo) -> bool:
	if typeof(wallet.get_balance()) != TYPE_INT or wallet.get_balance() < 0:
		return false
	var used := 0
	for good_id in cargo.get_items():
		var quantity = cargo.get_items()[good_id]
		if not GoodsCatalog.has_good(good_id) or typeof(quantity) != TYPE_INT or quantity <= 0:
			return false
		used += quantity * GoodsCatalog.get_unit_size(good_id)
	return used == cargo.get_used_capacity() and used >= 0 and used <= Cargo.CARGO_CAPACITY


# --- In-game loop ----------------------------------------------------------

func _verify_trade_loop_in_game() -> void:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await _settle()
	var player := main.get_node("Actors/Player") as Player
	var hub := main.get_node("CityHub") as CityHub
	var wallet := main.wallet as Wallet
	var cargo := main.cargo as Cargo

	_check(Cargo.CARGO_CAPACITY == 20, "Cargo capacity must stay 20")
	_check(GoodsCatalog.get_ids().size() == 6 and GoodsCatalog.get_unit_size("test_good_06") == 4 and GoodsCatalog.get_good("test_good_06")["base_value"] == 4000, "Six goods must be unchanged")
	_check(WorldLayout.WORLD_SIZE == Vector2(40000.0, 40000.0), "World size must be unchanged")
	_check(WorldLayout.CITY_A == Vector2(200.0, 200.0) and WorldLayout.CITY_B == Vector2(39800.0, 200.0), "City anchors must be unchanged")
	_check(player.move_speed == 220.0, "Movement speed must be unchanged")
	_check(wallet != null and wallet.get_balance() == 10000 and cargo.is_empty(), "Session must start with 10000 money and empty cargo")

	var outside: Dictionary = main.buy_in_current_city("test_good_01", 1)
	_check(not outside["success"] and outside["reason"] == "not_in_city", "Trading outside a city must fail")
	_check(wallet.get_balance() == 10000 and cargo.is_empty(), "Trading outside a city must not change state")

	player.global_position = WorldLayout.CITY_A
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == "A", "Must enter City A")
	_check(hub.get_money_label_text() == "Money: 10000", "City A hub must show starting money")
	var bought: Dictionary = main.buy_in_current_city("test_good_01", 10)
	_check(bought["success"] and bought["total_value"] == 800, "A: buying 10 x good 1 must cost 800")
	_check(wallet.get_balance() == 9200, "A: money must be 9200")
	_check(cargo.get_quantity("test_good_01") == 10 and cargo.get_used_capacity() == 10, "A: cargo must hold 10 x good 1 (10 units)")
	_check(hub.get_money_label_text() == "Money: 9200" and hub.get_cargo_label_text() == "Cargo: 10 / 20", "A: hub debug lines must update after the buy")
	_check(hub.leave_requested.get_connections().size() == 1, "Hub leave signal must stay connected once")

	_check(main.leave_city(), "Must leave City A")
	await _settle()
	_check(main.wallet == wallet and main.cargo == cargo, "Wallet and cargo must stay the same session objects")
	_check(wallet.get_balance() == 9200 and cargo.get_quantity("test_good_01") == 10, "Leaving A must preserve money and cargo")

	player.global_position = WorldLayout.CITY_B
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == "B", "City Hub transition to B must still work")
	_check(wallet.get_balance() == 9200 and cargo.get_quantity("test_good_01") == 10, "Entering B must preserve money and cargo")
	_check(hub.get_money_label_text() == "Money: 9200" and hub.get_cargo_label_text() == "Cargo: 10 / 20", "B: hub must show the carried state")
	var sold: Dictionary = main.sell_in_current_city("test_good_01", 10)
	_check(sold["success"] and sold["total_value"] == 1200, "B: selling 10 x good 1 must earn 1200")
	_check(wallet.get_balance() == 10400, "B: final money must be 10400")
	_check(wallet.get_balance() - Wallet.STARTING_MONEY == 400, "A to B good 1 must profit +400")
	_check(cargo.get_quantity("test_good_01") == 0 and cargo.is_empty(), "B: cargo must be empty after selling")
	_check(hub.get_money_label_text() == "Money: 10400" and hub.get_cargo_label_text() == "Cargo: 0 / 20", "B: hub debug lines must update after the sell")
	var oversell: Dictionary = main.sell_in_current_city("test_good_01", 1)
	_check(not oversell["success"] and wallet.get_balance() == 10400, "Selling again must fail without paying")
	_check(main.leave_city() and wallet.get_balance() == 10400, "Leaving B must preserve money")


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
