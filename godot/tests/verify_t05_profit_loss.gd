extends SceneTree

## T05 Profit / Loss + Trading Integration: purchase lots -> FIFO cost
## consumption -> realized merchandise P/L per sale. Uses its own save files,
## a fixed TimeSource, test-only failing subclasses for fault injection and an
## independent FIFO model (plain arrays of unit costs, "U" for unknown).

const DynamicPriceModel := preload("res://tests/dynamic_price_model.gd")
const RecoveryModel := preload("res://tests/market_recovery_model.gd")
const TEST_SAVE := "user://t05_profit_loss_test_save.json"
const UNWRITABLE_SAVE := "user://t05_missing_dir/nested/save.json"
const T0 := 1800000000000
const BP := TradeCostLedger.BACKPACK
const IDS := ["test_good_01", "test_good_02", "test_good_03", "test_good_04", "test_good_05", "test_good_06"]
const U := "U"
const IN_CITY_A := {"mode": "IN_CITY", "city_id": "A", "journey": null, "last_journey_id": ""}
const PORTRAIT := Rect2(0, 0, 720, 1280)

var _checks := 0
var _failures := 0
var _sections_done := []


## Test-only market whose stock changes can be made to fail.
class FailingMarket extends MarketState:
	var fail_remove := false
	var fail_add := false

	func remove_stock(city_id: Variant, good_id: Variant, quantity: Variant) -> bool:
		return false if fail_remove else super(city_id, good_id, quantity)

	func add_stock(city_id: Variant, good_id: Variant, quantity: Variant) -> bool:
		return false if fail_add else super(city_id, good_id, quantity)


## Test-only ledger that fails a step, optionally AFTER changing its lots
## (the worst case: a half-applied step that must still be rolled back).
class FailingLedger extends TradeCostLedger:
	var fail_purchase := false
	var fail_consume := false
	var fail_move := false
	var mutate_first := false

	func add_purchase(container_id: Variant, good_id: Variant, quantity: Variant, unit_cost: Variant) -> bool:
		if fail_purchase:
			if mutate_first:
				super(container_id, good_id, quantity, unit_cost)
			return false
		return super(container_id, good_id, quantity, unit_cost)

	func consume_fifo(container_id: Variant, good_id: Variant, quantity: Variant) -> Dictionary:
		if fail_consume:
			if mutate_first:
				super(container_id, good_id, quantity)
			return {"success": false, "cost_known": false, "acquisition_cost": null, "known_quantity": 0, "unknown_quantity": 0}
		return super(container_id, good_id, quantity)

	func move_fifo(from_id: Variant, to_id: Variant, good_id: Variant, quantity: Variant) -> bool:
		if fail_move:
			if mutate_first:
				super(from_id, to_id, good_id, quantity)
			return false
		return super(from_id, to_id, good_id, quantity)


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	_verify_ledger_lots()
	_verify_ledger_unknown_and_moves()
	_verify_trade_accounting()
	_verify_unknown_trades()
	_verify_warehouse_accounting()
	_verify_acquisition_order()
	_verify_atomic_rollback()
	_verify_save_and_migration()
	_verify_save_validation()
	await _verify_save_write_invariant()
	_verify_multi_city_model()
	await _verify_game_flow()
	await _verify_game_save_failure()
	await _verify_recovery_interplay()
	await _verify_ui_and_layout()
	_verify_stress()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 17, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("T05 profit / loss verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(SaveStore.VERSION == 12 and SaveStore.V9_KEYS.has("cost_ledger") and SaveStore.V7_KEYS.has("cost_ledger") and SaveStore.V8_KEYS.has("cost_ledger"), "Save version 7 (and T06's 8) carries the cost ledger")
	var ledger := _code_only("res://scripts/trade_cost_ledger.gd")
	_check(not ledger.contains("\"A\"") and not ledger.contains("\"B\"") and not ledger.contains("ACTIVE_CITY_IDS.size"), "The ledger has no fixed city ids or city count")
	_check(not ledger.to_lower().contains("average") and not ledger.contains("/ total") and not ledger.contains("/ quantity"), "No average-cost accounting")
	_check(not ledger.contains("Time.") and not ledger.contains("Wallet") and not ledger.contains("MarketState"), "The ledger never touches money, market or time")
	var inventory := _code_only("res://scripts/character_inventory.gd")
	_check(not inventory.contains("unit_cost") and not inventory.contains("Ledger") and not inventory.contains("fifo"), "CharacterInventory stays a quantity container")
	var hub := _code_only("res://scripts/city_hub.gd")
	_check(not hub.contains("TradeCostLedger") and not hub.contains("preview_fifo") and not hub.contains("consume") and not hub.contains("unit_cost"), "The UI never computes FIFO cost itself")
	var main := _code_only("res://scripts/main.gd")
	_check(main.contains("TradeService.preview_sell(") and not main.contains("preview_fifo"), "The preview goes through the trade domain's own sale rules")
	var everything := ""
	for path in ["res://scripts/trade_service.gd", "res://scripts/trade_cost_ledger.gd", "res://scripts/main.gd", "res://scripts/city_hub.gd", "res://scripts/save_store.gd", "res://scripts/warehouse_service.gd"]:
		everything += _code_only(path).to_lower()
	for word in ["trading_run", "start_run", "end_run", "trip_profit", "net_profit", "route_profit", "daily", "fare_cost"]:
		_check(not everything.contains(word), "No Trading Run / transport-net-profit scope (%s)" % word)
	_check(TradeService.ALLOWED_ORDER_QUANTITIES == [1, 10], "Order sizes remain 1 and 10")
	_check(MarketRecovery.STEP_MS == 12000 and MarketRecovery.MAX_ELAPSED_MS == 1800000 and MarketPrices.TARGET_STOCK == 100, "T04 constants unchanged")
	_check(MarketRules.dynamic_reference(1000, 0, 100) == 1500 and MarketRules.dynamic_reference(1000, 200, 100) == 500 and MarketRules.buy_price(1000) == 1050 and MarketRules.buyback_price(1000) == 950, "T03 pricing unchanged")
	_sections_done.append("static")


# --- Ledger unit ------------------------------------------------------------------------------

func _verify_ledger_lots() -> void:
	var ledger := TradeCostLedger.new()
	_check(ledger.add_purchase(BP, "test_good_01", 1, 80), "Buy 1 creates a lot")
	_check(_lots(ledger, BP, "test_good_01") == [{"quantity": 1, "unit_cost": 80}], "One known-cost lot of 1 @ 80")
	var ten := TradeCostLedger.new()
	_check(ten.add_purchase(BP, "test_good_01", 10, 80) and _lots(ten, BP, "test_good_01") == [{"quantity": 10, "unit_cost": 80}], "Buy 10 creates ONE 10-unit lot at one price")
	_check(ten.add_purchase(BP, "test_good_01", 10, 90) and _lots(ten, BP, "test_good_01") == [{"quantity": 10, "unit_cost": 80}, {"quantity": 10, "unit_cost": 90}], "A second price creates a second lot (no 20 @ 85 average)")
	_check(ten.get_quantity(BP, "test_good_01") == 20, "The combined quantity is 20")
	_check(ten.preview_fifo(BP, "test_good_01", 10) == {"success": true, "cost_known": true, "acquisition_cost": 800, "known_quantity": 10, "unknown_quantity": 0}, "FIFO 10: 10 @ 80 = 800")
	_check(ten.preview_fifo(BP, "test_good_01", 15)["acquisition_cost"] == 1250, "FIFO 15: 10 @ 80 + 5 @ 90 = 1250")
	_check(ten.preview_fifo(BP, "test_good_01", 20)["acquisition_cost"] == 1700 and ten.get_quantity(BP, "test_good_01") == 20, "Previews change nothing")
	var consumed := ten.consume_fifo(BP, "test_good_01", 15)
	_check(consumed["acquisition_cost"] == 1250 and _lots(ten, BP, "test_good_01") == [{"quantity": 5, "unit_cost": 90}], "Consuming 15 leaves 5 @ 90")
	var exact := TradeCostLedger.new()
	exact.add_purchase(BP, "test_good_02", 10, 180)
	exact.add_purchase(BP, "test_good_02", 10, 200)
	exact.consume_fifo(BP, "test_good_02", 10)
	_check(_lots(exact, BP, "test_good_02") == [{"quantity": 10, "unit_cost": 200}], "Exact lot consumption removes that lot cleanly")
	exact.consume_fifo(BP, "test_good_02", 10)
	_check(_lots(exact, BP, "test_good_02") == [] and exact.get_all_lots() == {} and exact.get_quantity(BP, "test_good_02") == 0, "Consuming everything leaves no empty lots")
	var partial := TradeCostLedger.new()
	partial.add_purchase(BP, "test_good_03", 10, 400)
	partial.consume_fifo(BP, "test_good_03", 1)
	_check(_lots(partial, BP, "test_good_03") == [{"quantity": 9, "unit_cost": 400}], "Partial consumption keeps the remainder of that lot")
	# Every purchase is its own lot with its own acquisition seq, even at the same price.
	var merge := TradeCostLedger.new()
	merge.add_purchase(BP, "test_good_01", 10, 84)
	merge.add_purchase(BP, "test_good_01", 1, 84)
	merge.add_purchase(BP, "test_good_01", 1, 85)
	merge.add_purchase(BP, "test_good_02", 1, 180)
	merge.add_purchase(BP, "test_good_01", 1, 84)
	_check(merge.get_lots(BP, "test_good_01") == [{"seq": 1, "quantity": 10, "unit_cost": 84}, {"seq": 2, "quantity": 1, "unit_cost": 84}, {"seq": 3, "quantity": 1, "unit_cost": 85}, {"seq": 5, "quantity": 1, "unit_cost": 84}], "Each purchase keeps its own seq in purchase order; nothing merges")
	_check(merge.get_lots(BP, "test_good_02") == [{"seq": 4, "quantity": 1, "unit_cost": 180}] and merge.get_next_seq() == 6, "One global acquisition counter across goods")
	# Invalid input changes nothing.
	var guard := TradeCostLedger.new()
	var rejected := true
	for bad in [[BP, "test_good_01", 0, 80], [BP, "test_good_01", -1, 80], [BP, "test_good_01", 1, 0], [BP, "test_good_01", 1, -5], [BP, "test_good_01", 1, 1.5], [BP, "test_good_01", 1.0, 80], [BP, "unknown_good", 1, 80], ["cart", "test_good_01", 1, 80], ["warehouse:C", "test_good_01", 1, 80], [BP, "test_good_01", 1, "80"], [BP, "test_good_01", 1, TradeCostLedger.MAX_UNIT_COST + 1]]:
		if guard.add_purchase(bad[0], bad[1], bad[2], bad[3]):
			rejected = false
	_check(rejected and guard.get_all_lots() == {}, "Negative / zero / non-integer costs and quantities, unknown goods and containers are rejected")
	_check(not ten.preview_fifo(BP, "test_good_01", 6)["success"] and not ten.consume_fifo(BP, "test_good_01", 6)["success"] and ten.get_quantity(BP, "test_good_01") == 5, "Cannot consume more than the lots hold")
	for bad_quantity in [0, -1, 1.0, "1", null]:
		_check(not ten.preview_fifo(BP, "test_good_01", bad_quantity)["success"], "preview_fifo(%s) must fail" % str(bad_quantity))
	var copy := _lots(ten, BP, "test_good_01")
	copy[0]["quantity"] = 999
	_check(ten.get_quantity(BP, "test_good_01") == 5, "Changing a returned copy never changes the ledger")
	_sections_done.append("ledger_lots")


func _verify_ledger_unknown_and_moves() -> void:
	var ledger := TradeCostLedger.new()
	_check(ledger.add_unknown(BP, "test_good_01", 5) and ledger.add_purchase(BP, "test_good_01", 10, 80), "5 unknown then 10 @ 80")
	var preview := ledger.preview_fifo(BP, "test_good_01", 10)
	_check(preview["success"] and not preview["cost_known"] and preview["acquisition_cost"] == null and preview["unknown_quantity"] == 5 and preview["known_quantity"] == 5, "A preview over unknown units has no cost number (never 0)")
	_check(ledger.preview_fifo(BP, "test_good_01", 5)["acquisition_cost"] == null, "Unknown is never treated as zero")
	var consumed := ledger.consume_fifo(BP, "test_good_01", 10)
	_check(not consumed["cost_known"] and _lots(ledger, BP, "test_good_01") == [{"quantity": 5, "unit_cost": 80}], "Mixed FIFO: 5 unknown + 5 @ 80 consumed, 5 @ 80 remain")
	_check(ledger.preview_fifo(BP, "test_good_01", 5) == {"success": true, "cost_known": true, "acquisition_cost": 400, "known_quantity": 5, "unknown_quantity": 0}, "After the unknown units are gone the cost is known again")

	# Moves carry exact costs, oldest first, appended at the destination's end.
	var moves := TradeCostLedger.new()
	moves.add_purchase(BP, "test_good_01", 10, 80)
	moves.add_purchase(BP, "test_good_01", 10, 90)
	var wa := TradeCostLedger.warehouse("A")
	var wb := TradeCostLedger.warehouse("B")
	_check(moves.move_fifo(BP, wa, "test_good_01", 1) and _lots(moves, wa, "test_good_01") == [{"quantity": 1, "unit_cost": 80}], "Deposit 1 carries cost 80")
	for i in range(10):
		moves.move_fifo(BP, wa, "test_good_01", 1)
	_check(_lots(moves, wa, "test_good_01") == [{"quantity": 10, "unit_cost": 80}, {"quantity": 1, "unit_cost": 90}], "After the first lot, deposits take the next lot")
	_check(_lots(moves, BP, "test_good_01") == [{"quantity": 9, "unit_cost": 90}], "The backpack keeps the rest in order")
	_check(moves.move_fifo(wa, BP, "test_good_01", 2) and moves.get_lots(BP, "test_good_01") == [{"seq": 1, "quantity": 2, "unit_cost": 80}, {"seq": 2, "quantity": 9, "unit_cost": 90}], "Withdrawn units keep their acquisition seq: the older 80s stay ahead of the 90s")
	_check(moves.get_lots(wa, "test_good_01") == [{"seq": 1, "quantity": 8, "unit_cost": 80}, {"seq": 2, "quantity": 1, "unit_cost": 90}], "The warehouse keeps acquisition order")
	moves.add_purchase(BP, "test_good_01", 3, 70)
	_check(moves.move_fifo(BP, wb, "test_good_01", 9) and moves.get_lots(wb, "test_good_01") == [{"seq": 1, "quantity": 2, "unit_cost": 80}, {"seq": 2, "quantity": 7, "unit_cost": 90}] and _lots(moves, wa, "test_good_01").size() == 2, "City warehouses keep independent lots; deposits take the oldest acquisitions")
	_check(moves.get_lots(BP, "test_good_01") == [{"seq": 2, "quantity": 2, "unit_cost": 90}, {"seq": 3, "quantity": 3, "unit_cost": 70}], "The backpack keeps the newer purchases")
	_check(not moves.move_fifo(BP, BP, "test_good_01", 1) and not moves.move_fifo(BP, wa, "test_good_01", 99) and not moves.move_fifo(BP, "warehouse:C", "test_good_01", 1) and not moves.move_fifo(BP, wa, "test_good_01", 0), "Invalid moves change nothing")
	var total := 0
	for container in [BP, wa, wb]:
		total += moves.get_quantity(container, "test_good_01")
	_check(total == 23, "Moves never lose, duplicate or fabricate units")
	# Unknown lots move as unknown.
	var old := TradeCostLedger.new()
	old.add_unknown(BP, "test_good_02", 3)
	old.move_fifo(BP, wa, "test_good_02", 2)
	_check(_lots(old, wa, "test_good_02") == [{"quantity": 2, "unknown": true}] and _lots(old, BP, "test_good_02") == [{"quantity": 1, "unknown": true}], "Unknown cost stays unknown through the warehouse")
	# Invariant helper.
	var ws := WarehouseState.create_default()
	ws._warehouse("A").restore_items({"test_good_01": 9})
	ws._warehouse("B").restore_items({"test_good_01": 9})
	_check(moves.matches({"test_good_01": 5}, ws), "The invariant holds when every container matches")
	_check(not moves.matches({"test_good_01": 6}, ws) and not moves.matches({"test_good_01": 5, "test_good_02": 1}, ws), "Backpack mismatches are detected")
	ws._warehouse("B").restore_items({"test_good_01": 8})
	_check(not moves.matches({"test_good_01": 5}, ws), "Warehouse mismatches are detected")
	var unknown := TradeCostLedger.unknown_for({"test_good_01": 4}, ws)
	_check(_lots(unknown, BP, "test_good_01") == [{"quantity": 4, "unknown": true}] and _lots(unknown, wa, "test_good_01") == [{"quantity": 9, "unknown": true}] and unknown.matches({"test_good_01": 4}, ws), "Migration lots: every unit unknown, quantities exact")
	_sections_done.append("ledger_unknown_moves")


# --- TradeService -----------------------------------------------------------------------------

func _verify_trade_accounting() -> void:
	var one := _session()
	var q1 := one.market.get_quote("A", "test_good_01")
	var buy1 := TradeService.buy("A", "test_good_01", 1, one.wallet, one.inventory, one.market, one.ledger)
	_check(buy1["success"] and buy1["total_value"] == q1["buy_price"] and buy1["unit_price"] == q1["buy_price"], "Buy 1 pays the locked price (T03 unchanged)")
	_check(_lots(one.ledger, BP, "test_good_01") == [{"quantity": 1, "unit_cost": q1["buy_price"]}], "Buy 1 creates one known-cost lot")
	var s := _session()
	var p1: int = s.market.get_quote("A", "test_good_01")["buy_price"]
	var buy10 := TradeService.buy("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
	_check(buy10["success"] and buy10["total_value"] == p1 * 10 and buy10["unit_price"] == p1, "Buy 10 pays one locked price x 10 (T03 unchanged)")
	_check(_lots(s.ledger, BP, "test_good_01") == [{"quantity": 10, "unit_cost": p1}], "Buy 10 creates ONE 10-unit lot at the locked price")
	var p2: int = s.market.get_quote("A", "test_good_01")["buy_price"]
	_check(p2 != p1 and p2 == DynamicPriceModel.buy(80, 90), "Post-order repricing: the next quote follows stock 90")
	TradeService.buy("A", "test_good_01", 1, s.wallet, s.inventory, s.market, s.ledger)
	_check(_lots(s.ledger, BP, "test_good_01") == [{"quantity": 10, "unit_cost": p1}, {"quantity": 1, "unit_cost": p2}], "A purchase at another price creates another lot (no average)")
	_check(s.inventory.get_items() == {"test_good_01": 11}, "The inventory shows one combined stack of 11")
	# Sell 1: FIFO takes one unit of the oldest lot.
	var sq := s.market.get_quote("A", "test_good_01")
	var sell1 := TradeService.sell("A", "test_good_01", 1, s.wallet, s.inventory, s.market, s.ledger)
	_check(sell1["success"] and sell1["total_value"] == sq["buyback_price"] and sell1["revenue"] == sq["buyback_price"] and sell1["unit_price"] == sq["buyback_price"], "Sell 1 revenue = locked buyback (T03 unchanged)")
	_check(sell1["cost_known"] and sell1["acquisition_cost"] == p1 and sell1["realized_profit"] == sq["buyback_price"] - p1, "Sell 1 consumes FIFO: exact cost and result")
	_check(_lots(s.ledger, BP, "test_good_01") == [{"quantity": 9, "unit_cost": p1}, {"quantity": 1, "unit_cost": p2}], "Partial consumption leaves 9 of the first lot")
	# Sell 10 across both lots.
	var sq10 := s.market.get_quote("A", "test_good_01")
	var sell10 := TradeService.sell("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
	_check(sell10["total_value"] == sq10["buyback_price"] * 10 and sell10["acquisition_cost"] == p1 * 9 + p2, "Sell 10: one locked buyback x 10, FIFO cost 9 @ %d + 1 @ %d" % [p1, p2])
	_check(sell10["realized_profit"] == sq10["buyback_price"] * 10 - (p1 * 9 + p2) and sell10["realized_profit"] < 0, "Same-city round trip: exact loss (spread)")
	_check(s.ledger.get_all_lots() == {} and s.inventory.is_empty(), "Everything sold: no lots, no goods")
	# Sale across two lots at different costs.
	var across := _session()
	p1 = across.market.get_quote("A", "test_good_02")["buy_price"]
	TradeService.buy("A", "test_good_02", 10, across.wallet, across.inventory, across.market, across.ledger)
	p2 = across.market.get_quote("A", "test_good_02")["buy_price"]
	TradeService.buy("A", "test_good_02", 1, across.wallet, across.inventory, across.market, across.ledger)
	TradeService.sell("A", "test_good_02", 1, across.wallet, across.inventory, across.market, across.ledger)
	var bq: int = across.market.get_quote("B", "test_good_02")["buyback_price"]
	var cross := TradeService.sell("B", "test_good_02", 10, across.wallet, across.inventory, across.market, across.ledger)
	_check(cross["acquisition_cost"] == p1 * 9 + p2 and cross["revenue"] == bq * 10 and cross["realized_profit"] == bq * 10 - (p1 * 9 + p2), "A sale across two lots sums exact FIFO costs (9 @ %d + 1 @ %d)" % [p1, p2])
	_check(cross["realized_profit"] > 0, "A -> B for good 02 makes a profit")
	# Zero-profit sale: a lot whose cost equals the current buyback.
	var zero := _session()
	var bb: int = zero.market.get_quote("A", "test_good_03")["buyback_price"]
	zero.inventory.add("test_good_03", 1)
	zero.ledger.add_purchase(BP, "test_good_03", 1, bb)
	var z := TradeService.sell("A", "test_good_03", 1, zero.wallet, zero.inventory, zero.market, zero.ledger)
	_check(z["success"] and z["cost_known"] and z["acquisition_cost"] == bb and z["realized_profit"] == 0, "Zero-profit sale is exactly 0")
	# Invalid quantities: nothing at all changes.
	var inv := _session()
	TradeService.buy("A", "test_good_01", 10, inv.wallet, inv.inventory, inv.market, inv.ledger)
	var before := _state(inv)
	for quantity in [0, -1, 2, 5, 9, 11, 20, 100, 1.0, "10", null]:
		var b := TradeService.buy("A", "test_good_01", quantity, inv.wallet, inv.inventory, inv.market, inv.ledger)
		var sl := TradeService.sell("A", "test_good_01", quantity, inv.wallet, inv.inventory, inv.market, inv.ledger)
		var pv := TradeService.preview_sell("A", "test_good_01", quantity, inv.inventory, inv.market, inv.ledger)
		_check(b["reason"] == "invalid_quantity" and sl["reason"] == "invalid_quantity" and pv["reason"] == "invalid_quantity", "Order size %s stays rejected (buy, sell and preview)" % str(quantity))
	_check(_state(inv) == before, "Rejected orders change no wallet, inventory, market or lots")
	# A ledger out of step with the inventory is refused, not silently patched.
	var drift := _session()
	drift.inventory.add("test_good_01", 3)
	var drift_before := _state(drift)
	_check(TradeService.sell("A", "test_good_01", 1, drift.wallet, drift.inventory, drift.market, drift.ledger)["reason"] == "invalid_state" and TradeService.buy("A", "test_good_01", 1, drift.wallet, drift.inventory, drift.market, drift.ledger)["reason"] == "invalid_state", "Trades refuse a ledger that does not match the inventory")
	_check(_state(drift) == drift_before, "A refused trade changes nothing")
	# Without a ledger (historical callers) the trade works and invents no cost.
	var plain := _session()
	TradeService.buy("A", "test_good_01", 1, plain.wallet, plain.inventory, plain.market)
	var legacy := TradeService.sell("A", "test_good_01", 1, plain.wallet, plain.inventory, plain.market)
	_check(legacy["success"] and not legacy["cost_known"] and legacy["acquisition_cost"] == null and legacy["realized_profit"] == null, "Without a ledger no cost or profit is invented")
	# Preview equals execution when nothing changed in between.
	var pe := _session()
	pe.wallet.add(100000)
	TradeService.buy("A", "test_good_04", 10, pe.wallet, pe.inventory, pe.market, pe.ledger)
	TradeService.buy("A", "test_good_04", 1, pe.wallet, pe.inventory, pe.market, pe.ledger)
	var same := true
	for quantity in [1, 10]:
		var p := TradeService.preview_sell("B", "test_good_04", quantity, pe.inventory, pe.market, pe.ledger)
		var snapshot := _state(pe)
		var executed := TradeService.sell("B", "test_good_04", quantity, pe.wallet, pe.inventory, pe.market, pe.ledger)
		for key in ["total_value", "revenue", "cost_known", "acquisition_cost", "realized_profit", "unit_price"]:
			if p[key] != executed[key]:
				same = false
		if snapshot == _state(pe):
			same = false
	_check(same, "Preview (1 and 10) equals the executed sale exactly")
	_check(not TradeService.preview_sell("A", "test_good_04", 1, pe.inventory, pe.market, pe.ledger)["success"], "No preview for units not held")
	_sections_done.append("trade_accounting")


func _verify_unknown_trades() -> void:
	var s := _session()
	s.inventory.add("test_good_01", 5)
	s.ledger.add_unknown(BP, "test_good_01", 5)
	var price: int = s.market.get_quote("A", "test_good_01")["buy_price"]
	TradeService.buy("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
	_check(_lots(s.ledger, BP, "test_good_01") == [{"quantity": 5, "unknown": true}, {"quantity": 10, "unit_cost": price}], "FIFO order: old unknown first, then the new purchase")
	var preview := TradeService.preview_sell("B", "test_good_01", 10, s.inventory, s.market, s.ledger)
	_check(preview["success"] and not preview["cost_known"] and preview["realized_profit"] == null and preview["acquisition_cost"] == null, "The preview of a mixed sale shows no P/L number")
	var money: int = s.wallet.get_balance()
	var bb: int = s.market.get_quote("B", "test_good_01")["buyback_price"]
	var sold := TradeService.sell("B", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
	_check(sold["success"] and sold["revenue"] == bb * 10 and s.wallet.get_balance() - money == bb * 10, "A sale with unknown units still pays full revenue")
	_check(not sold["cost_known"] and sold["acquisition_cost"] == null and sold["realized_profit"] == null, "Any unknown unit: cost_known = false and no invented P/L")
	_check(_lots(s.ledger, BP, "test_good_01") == [{"quantity": 5, "unit_cost": price}], "Remaining after the mixed sale: 5 @ %d" % price)
	var next := TradeService.sell("B", "test_good_01", 1, s.wallet, s.inventory, s.market, s.ledger)
	_check(next["cost_known"] and next["acquisition_cost"] == price, "The next sale uses the known lot")
	# Pure unknown.
	var old := _session()
	old.inventory.add("test_good_02", 10)
	old.ledger.add_unknown(BP, "test_good_02", 10)
	var u := TradeService.sell("A", "test_good_02", 10, old.wallet, old.inventory, old.market, old.ledger)
	_check(u["success"] and not u["cost_known"] and u["realized_profit"] == null and old.ledger.get_all_lots() == {}, "An all-unknown sale succeeds with no P/L")
	_sections_done.append("unknown_trades")


# --- Warehouse --------------------------------------------------------------------------------

func _verify_warehouse_accounting() -> void:
	var s := _session()
	s.wallet.add(1000000)
	TradeService.buy("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
	var first := _lots(s.ledger, BP, "test_good_01")[0]["unit_cost"] as int
	TradeService.buy("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
	var second := _lots(s.ledger, BP, "test_good_01")[1]["unit_cost"] as int
	var money: int = s.wallet.get_balance()
	var market: Dictionary = s.market.get_snapshot()
	var wa := TradeCostLedger.warehouse("A")
	var d := WarehouseService.deposit(s.location, s.inventory, s.warehouses, "A", "test_good_01", 1, "", Callable(), s.ledger)
	_check(d["success"] and _lots(s.ledger, wa, "test_good_01") == [{"quantity": 1, "unit_cost": first}], "Deposit 1 carries the oldest cost")
	for i in range(10):
		WarehouseService.deposit(s.location, s.inventory, s.warehouses, "A", "test_good_01", 1, "", Callable(), s.ledger)
	_check(_lots(s.ledger, wa, "test_good_01") == [{"quantity": 10, "unit_cost": first}, {"quantity": 1, "unit_cost": second}], "Partial deposits keep FIFO across lots")
	_check(s.ledger.matches(s.inventory.get_items(), s.warehouses), "Invariant after deposits")
	var w := WarehouseService.withdraw(s.location, s.inventory, s.warehouses, "A", "test_good_01", 1, "", Callable(), s.ledger)
	_check(w["success"] and _lots(s.ledger, BP, "test_good_01") == [{"quantity": 1, "unit_cost": first}, {"quantity": 9, "unit_cost": second}], "Withdraw 1 brings back the oldest purchase (cost %d), still ahead of the newer one" % first)
	_check(s.wallet.get_balance() == money and s.market.get_snapshot() == market and not d.has("realized_profit"), "Deposit / withdraw realizes no profit and touches no money or market")
	# Withdraw all back and sell: the exact costs survived.
	for i in range(10):
		WarehouseService.withdraw(s.location, s.inventory, s.warehouses, "A", "test_good_01", 1, "", Callable(), s.ledger)
	_check(s.warehouses.get_quantity("A", "test_good_01") == 0 and s.ledger.get_quantity(wa, "test_good_01") == 0 and s.inventory.get_quantity("test_good_01") == 20, "Everything withdrawn")
	var sold := TradeService.sell("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
	_check(sold["acquisition_cost"] == first * 10, "After a warehouse round trip Sell 10 still uses the first purchase (10 @ %d), not the newer one" % first)
	# City independence.
	s.location.leave_city()
	s.location.enter_city("B")
	WarehouseService.deposit(s.location, s.inventory, s.warehouses, "B", "test_good_01", 1, "", Callable(), s.ledger)
	_check(s.ledger.get_quantity(TradeCostLedger.warehouse("B"), "test_good_01") == 1 and s.ledger.get_quantity(wa, "test_good_01") == 0, "Each city warehouse keeps its own lots")
	_check(WarehouseService.deposit(s.location, s.inventory, s.warehouses, "A", "test_good_01", 1, "", Callable(), s.ledger)["reason"] == WarehouseService.ERR_WRONG_CITY, "Remote warehouse still rejected")
	_check(s.ledger.matches(s.inventory.get_items(), s.warehouses), "Invariant across both warehouses")
	# Save failure rolls back items AND lots (the warehouse's own contract).
	var before := _state(s)
	var fail := WarehouseService.deposit(s.location, s.inventory, s.warehouses, "B", "test_good_01", 1, "", func() -> bool: return false, s.ledger)
	_check(fail["reason"] == WarehouseService.ERR_SAVE_FAILED and _state(s) == before, "Warehouse save failure rolls back quantity and cost lots")
	fail = WarehouseService.withdraw(s.location, s.inventory, s.warehouses, "B", "test_good_01", 1, "", func() -> bool: return false, s.ledger)
	_check(fail["reason"] == WarehouseService.ERR_SAVE_FAILED and _state(s) == before, "Withdraw save failure rolls back quantity and cost lots")
	# Lot transfer failure (after the quantity moved) rolls back too, even half-applied.
	for mutate in [false, true]:
		var f := _session(FailingLedger.new())
		f.wallet.add(100000)
		TradeService.buy("A", "test_good_01", 10, f.wallet, f.inventory, f.market, f.ledger)
		var f_before := _state(f)
		(f.ledger as FailingLedger).fail_move = true
		(f.ledger as FailingLedger).mutate_first = mutate
		var r := WarehouseService.deposit(f.location, f.inventory, f.warehouses, "A", "test_good_01", 1, "", Callable(), f.ledger)
		_check(r["reason"] == WarehouseService.ERR_TRANSFER_FAILED and _state(f) == f_before, "A failed lot transfer undoes the quantity transfer (half-applied: %s)" % mutate)
	# Out-of-step ledger is refused.
	var drift := _session()
	drift.inventory.add("test_good_02", 2)
	_check(WarehouseService.deposit(drift.location, drift.inventory, drift.warehouses, "A", "test_good_02", 1, "", Callable(), drift.ledger)["reason"] == WarehouseService.ERR_INVALID_STATE and drift.inventory.get_quantity("test_good_02") == 2, "A ledger out of step with the goods is refused")
	_sections_done.append("warehouse_accounting")


# --- Acquisition-order FIFO (T05 review fix) -------------------------------------------------------

func _verify_acquisition_order() -> void:
	var wa := TradeCostLedger.warehouse("A")
	var wb := TradeCostLedger.warehouse("B")
	# Required scenario: 10 @ 80, 10 @ 90; the 80s go into the warehouse and come back.
	var s := _session()
	_stock_lot(s, "test_good_01", 10, 80)
	_stock_lot(s, "test_good_01", 10, 90)
	var original := s.ledger.get_lots(BP, "test_good_01")
	_check(original == [{"seq": 1, "quantity": 10, "unit_cost": 80}, {"seq": 2, "quantity": 10, "unit_cost": 90}], "Lot #1: 10 @ 80, lot #2: 10 @ 90")
	_check(_deposit(s, "A", "test_good_01", 10) and s.ledger.get_lots(wa, "test_good_01") == [{"seq": 1, "quantity": 10, "unit_cost": 80}], "All of lot #1 (the 80s) goes into warehouse A")
	_check(s.ledger.get_lots(BP, "test_good_01") == [{"seq": 2, "quantity": 10, "unit_cost": 90}], "Only lot #2 stays carried")
	_check(_withdraw(s, "A", "test_good_01", 10) and s.ledger.get_lots(BP, "test_good_01") == original, "Withdrawn, lot #1 is again ahead of lot #2")
	var sold := TradeService.sell("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
	_check(sold["success"] and sold["acquisition_cost"] == 800, "Sell 10 after the round trip costs 800 (10 @ 80), not 900")
	_check(s.ledger.get_lots(BP, "test_good_01") == [{"seq": 2, "quantity": 10, "unit_cost": 90}], "Lot #2 remains")

	# Partial deposit / withdraw: the same seq splits and rejoins.
	var p := _session()
	_stock_lot(p, "test_good_02", 10, 80)
	_stock_lot(p, "test_good_02", 10, 90)
	var before := p.ledger.get_lots(BP, "test_good_02")
	_check(_deposit(p, "A", "test_good_02", 3), "Deposit 3")
	_check(p.ledger.get_lots(BP, "test_good_02") == [{"seq": 1, "quantity": 7, "unit_cost": 80}, {"seq": 2, "quantity": 10, "unit_cost": 90}] and p.ledger.get_lots(wa, "test_good_02") == [{"seq": 1, "quantity": 3, "unit_cost": 80}], "Lot #1 splits: 7 carried, 3 stored, same seq")
	var preview := TradeService.preview_sell("A", "test_good_02", 10, p.inventory, p.market, p.ledger)
	_check(preview["acquisition_cost"] == 7 * 80 + 3 * 90, "While 3 are stored, Sell 10 uses the carried units in acquisition order")
	_check(_withdraw(p, "A", "test_good_02", 3) and p.ledger.get_lots(BP, "test_good_02") == before and p.ledger.get_lots(wa, "test_good_02") == [], "Withdrawing the 3 rejoins lot #1 exactly")
	_check(TradeService.preview_sell("A", "test_good_02", 10, p.inventory, p.market, p.ledger)["acquisition_cost"] == 800, "Partial round trip: FIFO unchanged (800)")
	# Deposit one at a time, withdraw one at a time.
	for i in range(13):
		_deposit(p, "A", "test_good_02", 1)
	_check(p.ledger.get_lots(wa, "test_good_02") == [{"seq": 1, "quantity": 10, "unit_cost": 80}, {"seq": 2, "quantity": 3, "unit_cost": 90}], "One-at-a-time deposits finish lot #1 before taking lot #2")
	for i in range(13):
		_withdraw(p, "A", "test_good_02", 1)
	_check(p.ledger.get_lots(BP, "test_good_02") == before, "One-at-a-time withdrawals restore the exact lots")

	# Multiple round trips through both warehouses, in any order.
	var m := _session()
	_stock_lot(m, "test_good_03", 10, 400)
	_stock_lot(m, "test_good_03", 10, 430)
	_stock_lot(m, "test_good_03", 1, 390)
	var start := m.ledger.get_lots(BP, "test_good_03")
	_deposit(m, "A", "test_good_03", 12)
	_withdraw(m, "A", "test_good_03", 5)
	_deposit(m, "A", "test_good_03", 7)
	_move_to(m, "B")
	_deposit(m, "B", "test_good_03", 2)
	_check(m.ledger.get_lots(wb, "test_good_03") == [{"seq": 2, "quantity": 2, "unit_cost": 430}] and m.ledger.get_lots(wa, "test_good_03") == [{"seq": 1, "quantity": 10, "unit_cost": 400}, {"seq": 2, "quantity": 4, "unit_cost": 430}], "A and B warehouses hold independent parts of the same lots")
	_withdraw(m, "B", "test_good_03", 2)
	_move_to(m, "A")
	_withdraw(m, "A", "test_good_03", 14)
	_check(m.ledger.get_lots(BP, "test_good_03") == start and m.ledger.get_all_lots().size() == 1, "After many round trips the backpack holds exactly the original lots")
	var trip := TradeService.sell("A", "test_good_03", 10, m.wallet, m.inventory, m.market, m.ledger)
	_check(trip["acquisition_cost"] == 4000, "Multiple round trips: Sell 10 still takes lot #1 (10 @ 400)")

	# Known + unknown lots keep a stable order through the warehouse.
	var k := _session()
	k.inventory.add("test_good_04", 5)
	k.ledger.add_unknown(BP, "test_good_04", 5)
	_stock_lot(k, "test_good_04", 10, 900)
	var mixed := k.ledger.get_lots(BP, "test_good_04")
	_check(mixed == [{"seq": 1, "quantity": 5, "unknown": true}, {"seq": 2, "quantity": 10, "unit_cost": 900}], "Unknown lot #1 before known lot #2")
	_deposit(k, "A", "test_good_04", 7)
	_check(k.ledger.get_lots(wa, "test_good_04") == [{"seq": 1, "quantity": 5, "unknown": true}, {"seq": 2, "quantity": 2, "unit_cost": 900}], "The unknown lot moves first and stays first")
	_withdraw(k, "A", "test_good_04", 3)
	_check(k.ledger.get_lots(BP, "test_good_04") == [{"seq": 1, "quantity": 3, "unknown": true}, {"seq": 2, "quantity": 8, "unit_cost": 900}], "Withdrawn unknown units rejoin lot #1 ahead of lot #2")
	_withdraw(k, "A", "test_good_04", 4)
	_check(k.ledger.get_lots(BP, "test_good_04") == mixed, "Known + unknown round trip restores the exact order")
	var mixed_sale := TradeService.preview_sell("A", "test_good_04", 10, k.inventory, k.market, k.ledger)
	_check(not mixed_sale["cost_known"] and mixed_sale["acquisition_cost"] == null, "Sell 10 still starts with the unknown units: no P/L number")

	# Save / reload keeps seqs, split parts and the counter.
	var r := _session()
	_stock_lot(r, "test_good_05", 1, 2000)
	_stock_lot(r, "test_good_05", 1, 2100)
	_stock_lot(r, "test_good_05", 1, 2200)
	_deposit(r, "A", "test_good_05", 2)
	_withdraw(r, "A", "test_good_05", 1)
	var lots_before := r.ledger.get_all_lots()
	_check(SaveStore.save(TEST_SAVE, r.wallet, r.inventory, r.market, r.location, r.warehouses, MarketRecovery.new(), r.ledger), "Save after moves")
	var loaded := SaveStore.load_session(TEST_SAVE)
	var ledger: TradeCostLedger = loaded.get("cost_ledger")
	_check(ledger != null and ledger.get_all_lots() == lots_before and ledger.get_next_seq() == 4, "Reload restores every seq, split part and the counter")
	_check(ledger.get_lots(BP, "test_good_05") == [{"seq": 1, "quantity": 1, "unit_cost": 2000}, {"seq": 3, "quantity": 1, "unit_cost": 2200}] and ledger.get_lots(wa, "test_good_05") == [{"seq": 2, "quantity": 1, "unit_cost": 2100}], "Reloaded order is acquisition order")
	_check(ledger.add_purchase(BP, "test_good_05", 1, 2300) and ledger.get_lots(BP, "test_good_05").back()["seq"] == 4, "A purchase after reload continues the sequence")
	_check(ledger.move_fifo(wa, BP, "test_good_05", 1) and _lots(ledger, BP, "test_good_05") == [{"quantity": 1, "unit_cost": 2000}, {"quantity": 1, "unit_cost": 2100}, {"quantity": 1, "unit_cost": 2200}, {"quantity": 1, "unit_cost": 2300}], "After reload a withdrawal still slots in by acquisition order")

	# Migration order is deterministic and documented: backpack, then A, then B.
	var ws := WarehouseState.create_default()
	ws._warehouse("A").restore_items({"test_good_06": 2, "test_good_01": 3})
	ws._warehouse("B").restore_items({"test_good_01": 4})
	var migrated := TradeCostLedger.unknown_for({"test_good_03": 1, "test_good_01": 5}, ws)
	var again := TradeCostLedger.unknown_for({"test_good_01": 5, "test_good_03": 1}, ws)
	_check(migrated.get_all_lots() == again.get_all_lots() and migrated.get_next_seq() == again.get_next_seq(), "Migration order does not depend on dictionary order")
	_check(migrated.get_lots(BP, "test_good_01")[0]["seq"] < migrated.get_lots(wa, "test_good_01")[0]["seq"] and migrated.get_lots(wa, "test_good_01")[0]["seq"] < migrated.get_lots(wb, "test_good_01")[0]["seq"], "Migrated good 01: backpack older than warehouse A older than warehouse B")
	_check(migrated.get_lots(BP, "test_good_01")[0]["seq"] == 1 and migrated.get_lots(BP, "test_good_03")[0]["seq"] == 2 and migrated.get_lots(wa, "test_good_01")[0]["seq"] == 3 and migrated.get_lots(wa, "test_good_06")[0]["seq"] == 4 and migrated.get_lots(wb, "test_good_01")[0]["seq"] == 5 and migrated.get_next_seq() == 6, "Migration numbers containers in order, goods in catalog order")
	migrated.move_fifo(TradeCostLedger.warehouse("B"), BP, "test_good_01", 4)
	migrated.move_fifo(wa, BP, "test_good_01", 3)
	_check(migrated.get_lots(BP, "test_good_01") == [{"seq": 1, "quantity": 5, "unknown": true}, {"seq": 3, "quantity": 3, "unknown": true}, {"seq": 5, "quantity": 4, "unknown": true}], "Unknown lots never reorder when moved")
	_sections_done.append("acquisition_order")


# --- Atomicity --------------------------------------------------------------------------------

func _verify_atomic_rollback() -> void:
	for mutate in [false, true]:
		# Buy: lot creation fails after the quantity changed.
		var b := _session(FailingLedger.new())
		var before := _state(b)
		(b.ledger as FailingLedger).fail_purchase = true
		(b.ledger as FailingLedger).mutate_first = mutate
		_check(TradeService.buy("A", "test_good_01", 10, b.wallet, b.inventory, b.market, b.ledger)["reason"] == "invalid_state" and _state(b) == before, "Buy: failure after the quantity mutation restores all four (half-applied lot: %s)" % mutate)
		# Sell: FIFO consumption fails after the quantity changed.
		var s := _session(FailingLedger.new())
		TradeService.buy("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
		before = _state(s)
		(s.ledger as FailingLedger).fail_consume = true
		(s.ledger as FailingLedger).mutate_first = mutate
		_check(TradeService.sell("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)["reason"] == "invalid_state" and _state(s) == before, "Sell: failure after the quantity mutation restores all four (half-consumed: %s)" % mutate)
	# Buy: market fails after the lot was created.
	var m := _session(null, FailingMarket.new())
	var mb := _state(m)
	(m.market as FailingMarket).fail_remove = true
	_check(TradeService.buy("A", "test_good_01", 10, m.wallet, m.inventory, m.market, m.ledger)["reason"] == "invalid_state" and _state(m) == mb, "Buy: failure after lot creation restores wallet, inventory, market and lots")
	# Sell: market fails after FIFO consumption and payment.
	var ms := _session(null, FailingMarket.new())
	TradeService.buy("A", "test_good_01", 10, ms.wallet, ms.inventory, ms.market, ms.ledger)
	var msb := _state(ms)
	(ms.market as FailingMarket).fail_add = true
	_check(TradeService.sell("A", "test_good_01", 10, ms.wallet, ms.inventory, ms.market, ms.ledger)["reason"] == "invalid_state" and _state(ms) == msb, "Sell: failure after FIFO consumption restores wallet, inventory, market and lots")
	_check(ms.ledger.matches(ms.inventory.get_items(), ms.warehouses), "The invariant holds after every rollback")
	_sections_done.append("atomic_rollback")


# --- Save --------------------------------------------------------------------------------------

func _verify_save_and_migration() -> void:
	var s := _session()
	s.wallet.add(1000000)
	s.inventory.add("test_good_05", 3)
	s.ledger.add_unknown(BP, "test_good_05", 3)
	TradeService.buy("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
	TradeService.buy("A", "test_good_01", 1, s.wallet, s.inventory, s.market, s.ledger)
	TradeService.buy("A", "test_good_05", 1, s.wallet, s.inventory, s.market, s.ledger)
	WarehouseService.deposit(s.location, s.inventory, s.warehouses, "A", "test_good_01", 2, "", Callable(), s.ledger)
	var snapshot := s.ledger.get_snapshot()
	_check(SaveStore.save(TEST_SAVE, s.wallet, s.inventory, s.market, s.location, s.warehouses, MarketRecovery.new(), s.ledger), "v7 save writes")
	var raw := _read_json()
	_check(int(raw["version"]) == SaveStore.VERSION and raw.has("cost_ledger") and raw["cost_ledger"].size() == 3 and raw["cost_ledger"].has_all(["next_seq", "backpack", "warehouses"]), "The save holds the cost ledger (next_seq, backpack, warehouses)")
	_check(not JSON.stringify(raw).contains("profit") and not JSON.stringify(raw).contains("preview") and not JSON.stringify(raw).contains("acquisition"), "No derived P/L or preview state is saved")
	var loaded := SaveStore.load_session(TEST_SAVE)
	var ledger: TradeCostLedger = loaded.get("cost_ledger")
	_check(ledger != null and ledger.get_snapshot() == snapshot, "Reload restores every lot exactly (order, quantity, unit cost, unknown)")
	_check(_lots(ledger, BP, "test_good_05") == [{"quantity": 3, "unknown": true}, {"quantity": 1, "unit_cost": _lots(s.ledger, BP, "test_good_05")[1]["unit_cost"]}], "UNKNOWN lots survive and stay first")
	_check(_lots(ledger, TradeCostLedger.warehouse("A"), "test_good_01").size() == 1 and ledger.matches(loaded["inventory"].get_items(), loaded["warehouses"]), "Warehouse lots survive and match")
	_check(typeof(_lots(ledger, BP, "test_good_01")[0]["quantity"]) == TYPE_INT and typeof(_lots(ledger, BP, "test_good_01")[0]["unit_cost"]) == TYPE_INT, "JSON numbers come back as exact integers")
	# Repeated save / load is stable.
	SaveStore.save(TEST_SAVE, loaded["wallet"], loaded["inventory"], loaded["market"], loaded["location"], loaded["warehouses"], loaded["market_recovery"], ledger)
	_check(SaveStore.load_session(TEST_SAVE)["cost_ledger"].get_snapshot() == snapshot, "A second save / reload changes nothing")

	# v1-v6: every unit becomes UNKNOWN, quantities exact, nothing else lost.
	var market := MarketState.create_default().get_snapshot()
	market["A"]["test_good_01"]["current_stock"] = 70
	var character := {"id": "player", "stats": {"strength": 10}, "inventory": {"items": {"test_good_01": {"quantity": 10}, "test_good_03": {"quantity": 2}}}}
	var stored := {"A": {"items": {"test_good_02": 5}}, "B": {"items": {"test_good_06": 1}}}
	var old := {
		"v1": {"version": 1, "money": 4321, "cargo": {"test_good_01": 10, "test_good_03": 2}},
		"v2": {"version": 2, "money": 4321, "cargo": {"test_good_01": 10, "test_good_03": 2}, "market": market},
		"v3": {"version": 3, "money": 4321, "character": character, "market": market},
		"v4": {"version": 4, "money": 4321, "character": character, "market": market, "location": IN_CITY_A},
		"v5": {"version": 5, "money": 4321, "character": character, "market": market, "location": IN_CITY_A, "warehouses": stored},
		"v6": {"version": 6, "money": 4321, "character": character, "market": market, "location": IN_CITY_A, "warehouses": stored, "market_recovery": {"anchor_ms": T0}},
	}
	for label in old:
		_write_json(old[label])
		var text := _read(TEST_SAVE)
		var l := SaveStore.load_session(TEST_SAVE)
		_check(not l.is_empty(), "%s save loads" % label)
		if l.is_empty():
			continue
		var lg: TradeCostLedger = l["cost_ledger"]
		_check(l["wallet"].get_balance() == 4321 and l["inventory"].get_items() == {"test_good_01": 10, "test_good_03": 2}, "%s: money and quantities preserved" % label)
		_check(_lots(lg, BP, "test_good_01") == [{"quantity": 10, "unknown": true}] and _lots(lg, BP, "test_good_03") == [{"quantity": 2, "unknown": true}], "%s: carried goods get UNKNOWN cost (no 0, no current price, no baseline)" % label)
		var has_warehouse: bool = label in ["v5", "v6"]
		_check(_lots(lg, TradeCostLedger.warehouse("A"), "test_good_02") == ([{"quantity": 5, "unknown": true}] if has_warehouse else []) and lg.matches(l["inventory"].get_items(), l["warehouses"]), "%s: warehouse goods get UNKNOWN cost; invariant holds" % label)
		_check(not JSON.stringify(lg.get_snapshot()).contains("unit_cost"), "%s: no historical cost invented" % label)
		_check(label in ["v1"] or l["market"].get_quote("A", "test_good_01")["stock"] == 70, "%s: market preserved" % label)
		_check(label not in ["v4", "v5", "v6"] or l["location"].get_city_id() == "A", "%s: location preserved" % label)
		_check(label != "v6" or l["market_recovery"].anchor_ms == T0, "v6: recovery anchor preserved")
		_check(_read(TEST_SAVE) == text, "%s: loading does not rewrite the save" % label)
	_sections_done.append("save_and_migration")


## GPT review fix: SaveStore.save() refuses to write a ledger that does not
## match every carried and stored quantity, before touching any file.
func _verify_save_write_invariant() -> void:
	var tmp := TEST_SAVE + ".tmp"
	_delete(TEST_SAVE)
	_delete(tmp)
	var base := _session()
	TradeService.buy("A", "test_good_01", 10, base.wallet, base.inventory, base.market, base.ledger)
	TradeService.buy("A", "test_good_02", 1, base.wallet, base.inventory, base.market, base.ledger)
	WarehouseService.deposit(base.location, base.inventory, base.warehouses, "A", "test_good_01", 2, "", Callable(), base.ledger)
	var recovery := MarketRecovery.from_dict({"anchor_ms": T0})
	# (e) A matching ledger saves and reloads normally.
	_check(SaveStore.save(TEST_SAVE, base.wallet, base.inventory, base.market, base.location, base.warehouses, recovery, base.ledger), "A matching ledger saves")
	var loaded := SaveStore.load_session(TEST_SAVE)
	_check(not loaded.is_empty() and loaded["cost_ledger"].get_snapshot() == base.ledger.get_snapshot() and loaded["inventory"].get_items() == base.inventory.get_items() and loaded["warehouses"].get_snapshot() == base.warehouses.get_snapshot(), "The matching save reloads exactly")
	var bytes := FileAccess.get_file_as_bytes(TEST_SAVE)
	_check(bytes.size() > 0 and not FileAccess.file_exists(tmp), "Reference save on disk, no temp file left")

	var cases := {}
	# (a) Backpack quantity mismatch: one more carried unit than lots.
	var a := _clone(base)
	a.inventory.add("test_good_01", 1)
	cases["backpack mismatch (traded good)"] = a
	# (b) Warehouse quantity mismatch.
	var b := _clone(base)
	b.warehouses._warehouse("A").restore_items({"test_good_01": 3})
	cases["warehouse mismatch"] = b
	# (c) Mismatch in an unrelated good (never traded, no lots at all).
	var c := _clone(base)
	c.inventory.add("test_good_05", 1)
	cases["unrelated good mismatch"] = c
	var c2 := _clone(base)
	c2.warehouses._warehouse("B").restore_items({"test_good_06": 1})
	cases["unrelated good in warehouse B"] = c2
	# Lots without goods, anywhere.
	var d := _clone(base)
	d.ledger.add_purchase(BP, "test_good_04", 1, 900)
	cases["lots without carried goods"] = d
	var e := _clone(base)
	e.ledger.add_unknown(TradeCostLedger.warehouse("B"), "test_good_03", 2)
	cases["lots without stored goods"] = e
	var f := _clone(base)
	f.inventory.remove("test_good_02", 1)
	cases["carried good gone, lot left"] = f
	for label in cases:
		var bad: Session = cases[label]
		_check(not bad.ledger.matches(bad.inventory.get_items(), bad.warehouses), "Setup: %s breaks the invariant" % label)
		_check(not SaveStore.save(TEST_SAVE, bad.wallet, bad.inventory, bad.market, bad.location, bad.warehouses, recovery, bad.ledger), "%s: save refused (returns false)" % label)
		_check(FileAccess.get_file_as_bytes(TEST_SAVE) == bytes, "%s: the existing valid save is byte-for-byte unchanged" % label)
		_check(not FileAccess.file_exists(tmp), "%s: no temp file was created" % label)
	# Without explicit warehouses the defaults (empty) are what must match.
	_check(not SaveStore.save(TEST_SAVE, base.wallet, base.inventory, base.market, base.location, null, recovery, base.ledger) and FileAccess.get_file_as_bytes(TEST_SAVE) == bytes, "Stored lots with no warehouses supplied: refused, file unchanged")
	# A refused save never creates a file where none existed.
	var fresh := "user://t05_refused_fresh.json"
	_delete(fresh)
	_delete(fresh + ".tmp")
	_check(not SaveStore.save(fresh, a.wallet, a.inventory, a.market, a.location, a.warehouses, recovery, a.ledger) and not FileAccess.file_exists(fresh) and not FileAccess.file_exists(fresh + ".tmp"), "A refused save creates no new file")
	# Still valid after the refusals: the untouched file loads, and matching state saves again.
	_check(SaveStore.load_session(TEST_SAVE)["cost_ledger"].get_snapshot() == base.ledger.get_snapshot(), "The untouched save still loads the last valid state")
	var ok := _clone(base)
	TradeService.buy("A", "test_good_03", 1, ok.wallet, ok.inventory, ok.market, ok.ledger)
	_check(SaveStore.save(TEST_SAVE, ok.wallet, ok.inventory, ok.market, ok.location, ok.warehouses, recovery, ok.ledger) and FileAccess.get_file_as_bytes(TEST_SAVE) != bytes, "A matching ledger still overwrites the save normally")
	_check(SaveStore.load_session(TEST_SAVE)["cost_ledger"].get_snapshot() == ok.ledger.get_snapshot(), "...and reloads exactly")

	# In the game: a good out of step elsewhere refuses the save after a trade
	# in another good (the M2-06 contract keeps that trade in memory).
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE, T0)
	await _walk_in(main, "A")
	main.buy_in_current_city("test_good_01", 1)
	var game_bytes := FileAccess.get_file_as_bytes(TEST_SAVE)
	_check(game_bytes.size() > 0, "The game saved the valid state")
	main.inventory.add("test_good_06", 1)
	var traded: Dictionary = main.buy_in_current_city("test_good_02", 1)
	_check(traded["success"] and main.inventory.get_quantity("test_good_02") == 1, "A trade in an unaffected good still completes (M2-06: kept in memory)")
	_check(FileAccess.get_file_as_bytes(TEST_SAVE) == game_bytes and not FileAccess.file_exists(tmp), "The game's save is refused: the last valid save file is byte-for-byte unchanged")
	_check(not main._persist(), "The game's persist reports the refusal")
	await _destroy(main)
	_delete(TEST_SAVE)
	_delete(fresh)
	_delete(fresh + ".tmp")
	_delete(tmp)
	_sections_done.append("save_write_invariant")


func _verify_save_validation() -> void:
	var s := _session()
	TradeService.buy("A", "test_good_01", 10, s.wallet, s.inventory, s.market, s.ledger)
	TradeService.buy("A", "test_good_01", 1, s.wallet, s.inventory, s.market, s.ledger)
	WarehouseService.deposit(s.location, s.inventory, s.warehouses, "A", "test_good_01", 2, "", Callable(), s.ledger)
	var good := SaveStore.serialize(s.wallet, s.inventory, s.market, s.location, s.warehouses, MarketRecovery.new(), s.ledger)
	_check(not SaveStore.validate(good).is_empty(), "The reference v7 payload is valid")
	var c1: int = s.ledger.get_lots(BP, "test_good_01")[0]["unit_cost"]
	var c2: int = s.ledger.get_lots(BP, "test_good_01")[1]["unit_cost"]
	var b1 := {"seq": 1, "quantity": 8, "unit_cost": c1}
	var b2 := {"seq": 2, "quantity": 1, "unit_cost": c2}
	var w1 := {"seq": 1, "quantity": 2, "unit_cost": c1}
	_check(good["cost_ledger"] == {"next_seq": 3, "backpack": {"test_good_01": [b1, b2]}, "warehouses": {"A": {"test_good_01": [w1]}, "B": {}}}, "The saved shape: next_seq plus seq-ordered lots per container (%s)" % str(good["cost_ledger"]))
	var bad := {
		"ledger null": null,
		"ledger array": [],
		"missing backpack": _without(good["cost_ledger"], "backpack"),
		"missing warehouses": _without(good["cost_ledger"], "warehouses"),
		"missing next_seq": _without(good["cost_ledger"], "next_seq"),
		"extra key": _merge(good["cost_ledger"], {"profit": 1}),
		"backpack array": _merge(good["cost_ledger"], {"backpack": []}),
		"lots not array": _bp(good, {"test_good_01": b1}),
		"empty lot list": _bp(good, {"test_good_01": []}),
		"unknown good": _bp(good, {"test_good_01": [b1, b2], "test_good_07": [{"seq": 3, "quantity": 1, "unit_cost": 5}]}),
		"quantity 0": _bp(good, {"test_good_01": [_with(b1, {"quantity": 0}), _with(b2, {"quantity": 9})]}),
		"negative quantity": _bp(good, {"test_good_01": [_with(b1, {"quantity": -8}), _with(b2, {"quantity": 17})]}),
		"fraction quantity": _bp(good, {"test_good_01": [_with(b1, {"quantity": 7.5}), _with(b2, {"quantity": 1.5})]}),
		"string quantity": _bp(good, {"test_good_01": [_with(b1, {"quantity": "8"}), b2]}),
		"negative cost": _bp(good, {"test_good_01": [_with(b1, {"unit_cost": -c1}), b2]}),
		"zero cost": _bp(good, {"test_good_01": [b1, _with(b2, {"unit_cost": 0})]}),
		"fraction cost": _bp(good, {"test_good_01": [b1, _with(b2, {"unit_cost": 84.5})]}),
		"null cost": _bp(good, {"test_good_01": [b1, _with(b2, {"unit_cost": null})]}),
		"huge cost": _bp(good, {"test_good_01": [b1, _with(b2, {"unit_cost": 1e300})]}),
		"unknown false": _bp(good, {"test_good_01": [b1, {"seq": 2, "quantity": 1, "unknown": false}]}),
		"unknown and cost": _bp(good, {"test_good_01": [b1, {"seq": 2, "quantity": 1, "unknown": true, "unit_cost": c2}]}),
		"extra lot key": _bp(good, {"test_good_01": [b1, _with(b2, {"city": "A"})]}),
		"missing seq": _bp(good, {"test_good_01": [b1, _without(b2, "seq")]}),
		"seq 0": _bp(good, {"test_good_01": [_with(b1, {"seq": 0}), b2]}),
		"negative seq": _bp(good, {"test_good_01": [b1, _with(b2, {"seq": -2})]}),
		"fraction seq": _bp(good, {"test_good_01": [b1, _with(b2, {"seq": 1.5})]}),
		"string seq": _bp(good, {"test_good_01": [b1, _with(b2, {"seq": "2"})]}),
		"duplicate seq in one container": _bp(good, {"test_good_01": [b1, _with(b2, {"seq": 1, "unit_cost": c1})]}),
		"seqs out of order": _bp(good, {"test_good_01": [b2, b1]}),
		"one seq with two costs": _wh(good, "A", {"test_good_01": [_with(w1, {"unit_cost": c1 + 1})]}),
		"one seq known and unknown": _wh(good, "A", {"test_good_01": [{"seq": 1, "quantity": 2, "unknown": true}]}),
		"one seq for two goods": _merge(_bp(good, {"test_good_01": [b1, b2], "test_good_02": [{"seq": 2, "quantity": 1, "unit_cost": c2}]}), {}),
		"next_seq not above every seq": _merge(good["cost_ledger"], {"next_seq": 2}),
		"next_seq 0": _merge(good["cost_ledger"], {"next_seq": 0}),
		"next_seq fraction": _merge(good["cost_ledger"], {"next_seq": 3.5}),
		"inventory mismatch (more lots)": _bp(good, {"test_good_01": [_with(b1, {"quantity": 9}), b2]}),
		"inventory mismatch (fewer lots)": _bp(good, {"test_good_01": [_with(b1, {"quantity": 7}), b2]}),
		"inventory mismatch (missing good)": _bp(good, {}),
		"warehouse mismatch": _wh(good, "A", {"test_good_01": [_with(w1, {"quantity": 3})]}),
		"warehouse missing lots": _wh(good, "A", {}),
		"warehouse lots for empty city": _wh(good, "B", {"test_good_01": [{"seq": 2, "quantity": 1, "unit_cost": c2}]}),
		"missing city B": _merge(good["cost_ledger"], {"warehouses": {"A": good["cost_ledger"]["warehouses"]["A"]}}),
		"extra city C": _merge(good["cost_ledger"], {"warehouses": _merge(good["cost_ledger"]["warehouses"], {"C": {}})}),
	}
	for label in bad:
		var payload := good.duplicate(true)
		payload["cost_ledger"] = bad[label]
		_check(SaveStore.validate(payload).is_empty(), "Malformed v7 ledger (%s) rejects the whole save" % label)
	# The inventory-mismatch case with an extra good: add a real unit to the goods
	# but no lot for it.
	var extra := good.duplicate(true)
	extra["character"]["inventory"]["items"]["test_good_02"] = {"quantity": 1}
	_check(SaveStore.validate(extra).is_empty(), "Goods without lots reject the save")
	# Valid variations are accepted: a split lot in two containers, larger next_seq.
	var roomy := good.duplicate(true)
	roomy["cost_ledger"]["next_seq"] = 50
	var roomy_loaded := SaveStore.validate(roomy)
	_check(not roomy_loaded.is_empty() and roomy_loaded["cost_ledger"].get_next_seq() == 50, "A larger next_seq is valid and kept")
	var missing := good.duplicate(true)
	missing.erase("cost_ledger")
	_check(SaveStore.validate(missing).is_empty(), "A v7 save without cost_ledger is rejected")
	var v6_with := good.duplicate(true)
	v6_with["version"] = 6
	_check(SaveStore.validate(v6_with).is_empty(), "A v6 save cannot carry v7 data")
	var v8 := good.duplicate(true)
	v8["version"] = 13  # P05: v12 is current; 13 is the unknown future
	_check(SaveStore.validate(v8).is_empty(), "An unknown future version is rejected")
	var broken := good.duplicate(true)
	broken["cost_ledger"]["backpack"]["test_good_01"][0]["unit_cost"] = -1
	_write_json(broken)
	_check(SaveStore.load_session(TEST_SAVE).is_empty(), "A negative cost in the file rejects the save")
	_sections_done.append("save_validation")


# --- Multi-city model ---------------------------------------------------------------------------

func _verify_multi_city_model() -> void:
	# A -> B -> C -> D with arbitrary city labels: the backpack ledger has no
	# city parameter, so cost does not depend on origin or destination.
	var ledger := TradeCostLedger.new()
	var fifo := {}  # independent model: good -> Array of unit costs
	var realized := []
	var route := [
		["A", "buy", "test_good_03", 10, 400], ["B", "sell", "test_good_03", 1, 520], ["B", "buy", "test_good_04", 10, 900],
		["C", "sell", "test_good_03", 9, 480], ["C", "sell", "test_good_04", 1, 1100], ["D", "sell", "test_good_04", 9, 850],
		["E", "buy", "test_good_03", 1, 410], ["F", "buy", "test_good_03", 10, 395], ["G", "sell", "test_good_03", 10, 430],
		["H", "sell", "test_good_03", 1, 300],
	]
	var ok := true
	for step in route:
		var good_id: String = step[2]
		var quantity: int = step[3]
		var price: int = step[4]
		if step[1] == "buy":
			ledger.add_purchase(BP, good_id, quantity, price)
			if not fifo.has(good_id):
				fifo[good_id] = []
			for i in range(quantity):
				fifo[good_id].append(price)
		else:
			var result := ledger.consume_fifo(BP, good_id, quantity)
			var model_cost := 0
			for i in range(quantity):
				model_cost += fifo[good_id].pop_front()
			if not result["cost_known"] or result["acquisition_cost"] != model_cost:
				ok = false
			realized.append(price * quantity - model_cost)
	_check(ok, "Every sale on an 8-city route matches the independent FIFO model")
	# 400x1 -> 520 | 400x9 -> 480x9 | 900 -> 1100 | 900x9 -> 850x9 | 410 + 395x9 -> 430x10 | 395 -> 300
	_check(realized == [120, 720, 200, -450, 335, -95], "Per-sale realized P/L: %s" % str(realized))
	_check(ledger.get_all_lots() == {}, "Everything sold: nothing left, nothing reset in between")
	# Same lots sold in different cities: identical cost.
	var a := _session()
	a.wallet.add(100000)
	TradeService.buy("A", "test_good_02", 10, a.wallet, a.inventory, a.market, a.ledger)
	var snapshot := a.ledger.get_snapshot()
	var in_a := TradeService.preview_sell("A", "test_good_02", 10, a.inventory, a.market, a.ledger)
	var in_b := TradeService.preview_sell("B", "test_good_02", 10, a.inventory, a.market, a.ledger)
	_check(in_a["acquisition_cost"] == in_b["acquisition_cost"] and in_a["revenue"] != in_b["revenue"], "Cost does not depend on the destination city (only revenue does)")
	var b := _session()
	b.market = _market_with({"A": {}, "B": {"test_good_02": 100}})
	b.market._markets["B"]["test_good_02"]["reference_price"] = 180
	TradeService.buy("B", "test_good_02", 10, b.wallet, b.inventory, b.market, b.ledger)
	_check(b.ledger.get_snapshot() == snapshot, "The same purchase price in another city gives the same lot (origin is not part of cost)")
	_sections_done.append("multi_city_model")


# --- Game ---------------------------------------------------------------------------------------

func _verify_game_flow() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE, T0)
	await _walk_in(main, "A")
	var hub := main.get_node("CityHub") as CityHub
	var p1: int = main.market.get_quote("A", "test_good_02")["buy_price"]
	hub.get_market_button("test_good_02", "buy10").pressed.emit()
	var p2: int = main.market.get_quote("A", "test_good_02")["buy_price"]
	hub.get_market_button("test_good_02", "buy10").pressed.emit()
	_check(hub.get_feedback_text() == "已買入 10 件測試商品二，支付 %d" % (p2 * 10), "Buy feedback unchanged (payment shown once)")
	_check(hub.get_market_row_texts("test_good_02")["held"] == "持有 20" and _lots(main.cost_ledger, BP, "test_good_02").size() == 2, "UI shows one combined 20; accounting keeps two lots")
	var saved := _read_json()
	_check(saved["cost_ledger"]["backpack"]["test_good_02"].size() == 2, "Each trade saves the lots")
	# Travel A -> B, sell 10 (first lot), then 10 (second lot).
	_check(main.request_transport("B", "t05-ride")["success"], "Ride to B")
	var fare_money: int = main.wallet.get_balance()
	main.time_source.advance_ms(90000)
	await process_frame
	_check(main.current_city_id == "B", "Arrived in B")
	var bb: int = main.market.get_quote("B", "test_good_02")["buyback_price"]
	hub.get_market_button("test_good_02", "sell10").pressed.emit()
	_check(main.wallet.get_balance() - fare_money == bb * 10, "Revenue paid in full")
	_check(hub.get_feedback_text() == "已賣出 10 件測試商品二，收入 %d，成本 %d，盈利 +%d" % [bb * 10, p1 * 10, bb * 10 - p1 * 10], "A -> B sale shows revenue, first-lot cost and merchandise profit (%s)" % hub.get_feedback_text())
	var bb2: int = main.market.get_quote("B", "test_good_02")["buyback_price"]
	hub.get_market_button("test_good_02", "sell10").pressed.emit()
	_check(hub.get_feedback_text() == "已賣出 10 件測試商品二，收入 %d，成本 %d，盈利 +%d" % [bb2 * 10, p2 * 10, bb2 * 10 - p2 * 10], "The next 10 use the second lot's cost")
	_check(fare_money == main.wallet.get_balance() - bb * 10 - bb2 * 10 and bb2 * 10 - p2 * 10 == int(hub.get_feedback_text().get_slice("盈利 +", 1)), "The 300 fare is charged separately; merchandise P/L is revenue - FIFO cost only")
	# B -> A -> keep trading, nothing resets.
	hub.get_market_button("test_good_01", "buy10").pressed.emit()
	var b_cost: int = _lots(main.cost_ledger, BP, "test_good_01")[0]["unit_cost"]
	_check(main.request_transport("A", "t05-back")["success"], "Ride back to A")
	main.time_source.advance_ms(90000)
	await process_frame
	var ab: int = main.market.get_quote("A", "test_good_01")["buyback_price"]
	hub.get_market_button("test_good_01", "sell").pressed.emit()
	var loss := ab - b_cost
	_check(hub.get_feedback_text() == "已賣出 1 件測試商品一，收入 %d，成本 %d，%s" % [ab, b_cost, ("盈利 +%d" % loss) if loss > 0 else (("虧損 %d" % loss) if loss < 0 else "盈虧 0")], "A -> B -> A: goods bought in B are costed in A without any reset")
	_check(main.cost_ledger.matches(main.inventory.get_items(), main.warehouses), "Invariant after the whole journey")
	# Reload keeps the remaining lot.
	var lots: Dictionary = main.cost_ledger.get_snapshot()
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0 + 180000)
	_check(main.cost_ledger.get_snapshot() == lots, "Reload restores the remaining lots")
	await _destroy(main)
	_sections_done.append("game_flow")


func _verify_game_save_failure() -> void:
	# The approved M2-06 contract: a failed save does not undo a completed trade;
	# all four parts keep the post-trade state together.
	var main := await _new_main("", T0)
	await _walk_in(main, "A")
	main.save_path = UNWRITABLE_SAVE
	var price: int = main.market.get_quote("A", "test_good_01")["buy_price"]
	var money: int = main.wallet.get_balance()
	var bought: Dictionary = main.buy_in_current_city("test_good_01", 10)
	_check(bought["success"] and main.wallet.get_balance() == money - price * 10 and main.inventory.get_quantity("test_good_01") == 10 and main.market.get_quote("A", "test_good_01")["stock"] == 90, "Buy + save failure: the completed trade stands")
	_check(_lots(main.cost_ledger, BP, "test_good_01") == [{"quantity": 10, "unit_cost": price}] and main.cost_ledger.matches(main.inventory.get_items(), main.warehouses), "Buy + save failure: the lot exists and matches")
	_check(not FileAccess.file_exists(UNWRITABLE_SAVE), "Nothing was written")
	var bb: int = main.market.get_quote("A", "test_good_01")["buyback_price"]
	var sold: Dictionary = main.sell_in_current_city("test_good_01", 10)
	_check(sold["success"] and sold["acquisition_cost"] == price * 10 and main.inventory.get_quantity("test_good_01") == 0 and main.market.get_quote("A", "test_good_01")["stock"] == 100 and main.wallet.get_balance() == money - price * 10 + bb * 10, "Sell + save failure: the completed sale stands")
	_check(main.cost_ledger.get_all_lots() == {} and main.cost_ledger.matches(main.inventory.get_items(), main.warehouses), "Sell + save failure: lots consumed and consistent")
	await _destroy(main)
	_sections_done.append("game_save_failure")


func _verify_recovery_interplay() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE, T0)
	await _walk_in(main, "A")
	var hub := main.get_node("CityHub") as CityHub
	var price: int = main.market.get_quote("A", "test_good_01")["buy_price"]
	hub.get_market_button("test_good_01", "buy10").pressed.emit()
	var lots: Dictionary = main.cost_ledger.get_snapshot()
	main.time_source.set_now_ms(T0 + 5 * 12000)
	await process_frame
	_check(main.market.get_quote("A", "test_good_01")["stock"] == 95, "T04 recovery runs (90 -> 95)")
	_check(main.cost_ledger.get_snapshot() == lots, "Recovery never changes acquisition cost lots")
	var preview_before: Dictionary = main.get_sale_previews("test_good_01")[10]
	# Recovery due before the trade: the executed sale uses the fresh quote.
	main.time_source.set_now_ms(T0 + 10 * 12000)
	var expected_bb := DynamicPriceModel.buyback(80, RecoveryModel.recovered_stock(95, 100, 5))
	var sold: Dictionary = main.sell_in_current_city("test_good_01", 10)
	_check(sold["unit_price"] == expected_bb and sold["acquisition_cost"] == price * 10 and sold["realized_profit"] == expected_bb * 10 - price * 10, "T04 recovery before trade: the sale uses the recovered quote, cost from the lot")
	_check(preview_before["acquisition_cost"] == sold["acquisition_cost"] and preview_before["revenue"] != sold["revenue"], "A preview's cost matches; its price may move with recovery before execution")
	# Buying after recovery records the recovered price.
	main.time_source.set_now_ms(T0 + 20 * 12000)
	var q: Dictionary = main.market.get_quote("A", "test_good_02")
	main.buy_in_current_city("test_good_02", 1)
	_check(_lots(main.cost_ledger, BP, "test_good_02") == [{"quantity": 1, "unit_cost": q["buy_price"]}], "A purchase lot records the locked price at execution")
	await _destroy(main)
	_sections_done.append("recovery_interplay")


func _verify_ui_and_layout() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE, T0)
	main.wallet.add(1000000)
	await _walk_in(main, "A")
	var hub := main.get_node("CityHub") as CityHub
	_check(hub.get_market_preview_text("test_good_01") == "", "Nothing held: no preview")
	hub.get_market_button("test_good_01", "buy").pressed.emit()
	var p: Dictionary = main.get_sale_previews("test_good_01")
	_check(p.keys() == [1] and hub.get_market_preview_text("test_good_01") == "預計：賣1 %d" % p[1]["realized_profit"], "Only sellable sizes are previewed (%s)" % hub.get_market_preview_text("test_good_01"))
	hub.get_market_button("test_good_01", "buy10").pressed.emit()
	p = main.get_sale_previews("test_good_01")
	_check(p.keys() == [1, 10] and hub.get_market_preview_text("test_good_01") == "預計：賣1 %s / 賣10 %s" % [_signed(p[1]["realized_profit"]), _signed(p[10]["realized_profit"])], "Held >= 10: both sizes previewed (%s)" % hub.get_market_preview_text("test_good_01"))
	var preview: Dictionary = p[10]
	hub.get_market_button("test_good_01", "sell10").pressed.emit()
	_check(hub.get_feedback_text().ends_with("，成本 %d，虧損 %d" % [preview["acquisition_cost"], preview["realized_profit"]]), "The executed sale shows exactly the previewed cost and loss (%s)" % hub.get_feedback_text())
	# Unknown cost: preview and feedback never show a number.
	main.inventory.add("test_good_03", 10)
	main.cost_ledger.add_unknown(BP, "test_good_03", 10)
	main._refresh_hub_summary()
	_check(hub.get_market_preview_text("test_good_03") == "預計：資料不足", "Unknown cost preview: 預計：資料不足")
	# Mixed: 1 known unit first, then 9 unknown: Sell 1 known, Sell 10 unknown.
	hub.get_market_button("test_good_04", "buy").pressed.emit()
	main.inventory.add("test_good_04", 9)
	main.cost_ledger.add_unknown(BP, "test_good_04", 9)
	main._refresh_hub_summary()
	var mixed: Dictionary = main.get_sale_previews("test_good_04")
	_check(hub.get_market_preview_text("test_good_04") == "預計：賣1 %s / 賣10 資料不足" % _signed(mixed[1]["realized_profit"]), "Mixed preview: known size shows P/L, unknown size shows 資料不足")
	hub.get_market_button("test_good_03", "sell10").pressed.emit()
	var bb: int = main.market.get_quote("A", "test_good_03")["buyback_price"]
	_check(hub.get_feedback_text().begins_with("已賣出 10 件測試商品三，收入 ") and hub.get_feedback_text().ends_with("，成本：資料不足") and not hub.get_feedback_text().contains("盈利") and not hub.get_feedback_text().contains("虧損"), "Unknown-cost sale: revenue shown, 成本：資料不足, no invented P/L (%s)" % hub.get_feedback_text())
	_check(bb > 0, "Market still quotes")
	_check(_approved_chinese(hub.get_feedback_text()) and _approved_chinese(hub.get_market_preview_text("test_good_04")), "P/L text is Traditional Chinese")
	# Zero-profit wording.
	var zero_bb: int = main.market.get_quote("A", "test_good_05")["buyback_price"]
	main.inventory.add("test_good_05", 1)
	main.cost_ledger.add_purchase(BP, "test_good_05", 1, zero_bb)
	main._refresh_hub_summary()
	_check(hub.get_market_preview_text("test_good_05") == "預計：賣1 0", "Zero preview: 0")
	hub.get_market_button("test_good_05", "sell").pressed.emit()
	_check(hub.get_feedback_text().ends_with("，成本 %d，盈虧 0" % zero_bb), "Zero-profit sale wording")
	# Profit wording.
	main.inventory.add("test_good_06", 1)
	main.cost_ledger.add_purchase(BP, "test_good_06", 1, 100)
	main._refresh_hub_summary()
	var gain: int = main.market.get_quote("A", "test_good_06")["buyback_price"] - 100
	_check(hub.get_market_preview_text("test_good_06") == "預計：賣1 +%d" % gain, "Profit preview has a + sign")
	# Layout: 720 x 1280 with a preview in every row, nothing overlaps, touch targets unchanged.
	main.character_stats.set_strength(CharacterStats.MAX_STRENGTH)
	for good_id in IDS:
		if main.inventory.get_quantity(good_id) < 10:
			var add: int = 10 - main.inventory.get_quantity(good_id)
			_check(main.inventory.add(good_id, add) and main.cost_ledger.add_unknown(BP, good_id, add), "Layout fixture: %s x %d" % [good_id, add])
	main._refresh_hub_summary()
	await process_frame
	var inside := true
	var sized := true
	var previous_bottom := -1.0
	var rows_ok := true
	for good_id in IDS:
		for action in ["buy", "buy10", "sell", "sell10"]:
			var rect := hub.get_market_button(good_id, action).get_global_rect()
			if not PORTRAIT.encloses(rect):
				inside = false
			if rect.size.x < 104.0 or rect.size.y < 88.0:
				sized = false
		var row := (hub.get_market_button(good_id, "buy").get_parent() as Control).get_global_rect()
		if row.position.y < previous_bottom or row.end.x > 712.0:
			rows_ok = false
		previous_bottom = row.end.y
		var label := hub.get_market_button(good_id, "buy").get_parent().find_child("PreviewLabel", true, false) as Label
		var info := label.get_parent() as Control
		if not info.get_global_rect().encloses(label.get_global_rect()) or info.get_global_rect().size.x > 264.5 or label.get_theme_font_size("font_size") < 16 or label.text == "":
			rows_ok = false
	_check(inside and sized, "Every market button stays on screen at 104 x 88")
	_check(rows_ok, "Rows never overlap or widen (info column still 264 px as in T03); every preview is shown at >= 16px inside its column")
	var leave := (hub.get_node("Center/Content/LeaveButton") as Control).get_global_rect()
	_check(PORTRAIT.encloses(leave) and leave.position.y >= previous_bottom, "Leave City below the market, on screen")
	var enter := (main.get_node("EnterControls/EnterCityButton") as Control).get_global_rect()
	_check(not leave.intersects(enter), "Leave City does not overlap the world Enter City area (%s vs %s)" % [leave, enter])
	_check(not (hub.get_node("Center/Content/TitleLabel") as Control).visible, "The market view drops the prototype title")
	hub.show_facility("transport")
	_check((hub.get_node("Center/Content/TitleLabel") as Control).visible, "Other views keep the title")
	hub.show_facility("market")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("ui_and_layout")


# --- Stress -------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var s := _session()
	s.wallet.add(5000000)
	s.inventory.add("test_good_02", 4)
	s.ledger.add_unknown(BP, "test_good_02", 4)
	var recovery := MarketRecovery.from_dict({"anchor_ms": T0})
	# Independent acquisition-order model: each unit is [seq, cost or "U"].
	var model := {BP: {"test_good_02": [[1, U], [1, U], [1, U], [1, U]]}, "A": {}, "B": {}}
	var model_next := 2
	var rng := RandomNumberGenerator.new()
	rng.seed = 505
	var counts := {"buy1": 0, "buy10": 0, "sell1": 0, "sell10": 0, "deposit": 0, "withdraw": 0, "reload": 0, "move": 0, "rejected": 0}
	var drift := 0
	var cost_breaks := 0
	var city := "A"
	var goods := ["test_good_01", "test_good_02", "test_good_03"]
	for step in range(700):
		var action := rng.randi_range(0, 9)
		var good_id: String = goods[rng.randi_range(0, goods.size() - 1)]
		var quantity: int = [1, 10][rng.randi_range(0, 1)]
		if action <= 2:
			var price: int = s.market.get_quote(city, good_id)["buy_price"]
			var r := TradeService.buy(city, good_id, quantity, s.wallet, s.inventory, s.market, s.ledger)
			if r["success"]:
				_model_add(model[BP], good_id, quantity, model_next, price)
				model_next += 1
				counts["buy%d" % quantity] += 1
			else:
				counts["rejected"] += 1
		elif action <= 5:
			var r := TradeService.sell(city, good_id, quantity, s.wallet, s.inventory, s.market, s.ledger)
			if r["success"]:
				var taken := _model_take(model[BP], good_id, quantity)
				var expected_known := true
				var expected_cost := 0
				for unit in taken:
					if unit[1] is String:
						expected_known = false
					else:
						expected_cost += unit[1]
				if r["cost_known"] != expected_known or (expected_known and r["acquisition_cost"] != expected_cost) or (expected_known and r["realized_profit"] != r["revenue"] - expected_cost) or (not expected_known and (r["acquisition_cost"] != null or r["realized_profit"] != null)):
					cost_breaks += 1
				counts["sell%d" % quantity] += 1
			else:
				counts["rejected"] += 1
		elif action == 6 or action == 7:
			var deposit := action == 6
			var q := rng.randi_range(1, 3)
			var r := WarehouseService.deposit(s.location, s.inventory, s.warehouses, city, good_id, q, "", Callable(), s.ledger) if deposit \
				else WarehouseService.withdraw(s.location, s.inventory, s.warehouses, city, good_id, q, "", Callable(), s.ledger)
			if r["success"]:
				if deposit:
					for unit in _model_take(model[BP], good_id, q):
						_model_add(model[city], good_id, 1, unit[0], unit[1])
				else:
					for unit in _model_take(model[city], good_id, q):
						_model_add(model[BP], good_id, 1, unit[0], unit[1])
				counts["deposit" if deposit else "withdraw"] += 1
			else:
				counts["rejected"] += 1
		elif action == 8:
			city = "B" if city == "A" else "A"
			s.location.leave_city()
			s.location.enter_city(city)
			recovery.advance(s.market, T0 + step * 7000)
			counts["move"] += 1
		else:
			_check(SaveStore.save(TEST_SAVE, s.wallet, s.inventory, s.market, s.location, s.warehouses, recovery, s.ledger), "Stress save")
			var loaded := SaveStore.load_session(TEST_SAVE)
			s.wallet = loaded["wallet"]
			s.inventory = loaded["inventory"]
			s.market = loaded["market"]
			s.location = loaded["location"]
			s.warehouses = loaded["warehouses"]
			s.ledger = loaded["cost_ledger"]
			counts["reload"] += 1
		# Invariant after every step, and exact agreement with the model.
		if not s.ledger.matches(s.inventory.get_items(), s.warehouses):
			drift += 1
		for container in [BP, "A", "B"]:
			var ledger_id: String = BP if container == BP else TradeCostLedger.warehouse(container)
			for id in goods:
				if _model_lots(model[container], id) != s.ledger.get_lots(ledger_id, id):
					drift += 1
		if s.ledger.get_next_seq() != model_next:
			drift += 1
	_check(drift == 0, "Stress: ledger == inventory / warehouse quantities and == the acquisition-order FIFO model (seq, quantity, cost) after every step (%d drifts)" % drift)
	_check(cost_breaks == 0, "Stress: every sale's cost_known / cost / P/L matches the model (%d breaks)" % cost_breaks)
	_check(counts["buy1"] >= 20 and counts["buy10"] >= 20 and counts["sell1"] >= 20 and counts["sell10"] >= 10 and counts["deposit"] >= 20 and counts["withdraw"] >= 20 and counts["reload"] >= 30 and counts["move"] >= 30, "Stress mixes every operation %s" % str(counts))
	print("T05 stress counts: ", counts)
	_delete(TEST_SAVE)
	_sections_done.append("stress")


# --- Helpers ------------------------------------------------------------------------------------

class Session:
	var wallet: Wallet
	var inventory: CharacterInventory
	var market: MarketState
	var ledger: TradeCostLedger
	var warehouses: WarehouseState
	var location: PlayerLocation


func _session(ledger: TradeCostLedger = null, market: MarketState = null) -> Session:
	var s := Session.new()
	s.wallet = Wallet.new()
	s.inventory = CharacterInventory.new()
	s.market = market if market != null else MarketState.create_default()
	if market != null:
		market._markets = MarketState.create_default().get_snapshot()
	s.ledger = ledger if ledger != null else TradeCostLedger.new()
	s.warehouses = WarehouseState.create_default()
	s.location = PlayerLocation.new()
	s.location.enter_city("A")
	return s


## Adds carried goods with one purchase lot at an exact test cost.
func _stock_lot(s: Session, good_id: String, quantity: int, cost: int) -> void:
	_check(s.inventory.add(good_id, quantity) and s.ledger.add_purchase(BP, good_id, quantity, cost), "Fixture: %d x %s @ %d" % [quantity, good_id, cost])


func _deposit(s: Session, city: String, good_id: String, quantity: int) -> bool:
	return WarehouseService.deposit(s.location, s.inventory, s.warehouses, city, good_id, quantity, "", Callable(), s.ledger)["success"]


func _withdraw(s: Session, city: String, good_id: String, quantity: int) -> bool:
	return WarehouseService.withdraw(s.location, s.inventory, s.warehouses, city, good_id, quantity, "", Callable(), s.ledger)["success"]


func _move_to(s: Session, city: String) -> void:
	s.location.leave_city()
	s.location.enter_city(city)


## An independent deep copy of a session (via the save format's own objects).
func _clone(s: Session) -> Session:
	var c := Session.new()
	c.wallet = Wallet.new()
	var diff: int = s.wallet.get_balance() - c.wallet.get_balance()
	if diff > 0:
		c.wallet.add(diff)
	elif diff < 0:
		c.wallet.spend(-diff)
	c.inventory = CharacterInventory.new()
	c.inventory.restore_items(s.inventory.get_items())
	c.market = MarketState.from_snapshot(s.market.get_snapshot())
	c.ledger = TradeCostLedger.new()
	c.ledger.restore_snapshot(s.ledger.get_snapshot())
	c.warehouses = WarehouseState.from_snapshot(s.warehouses.get_snapshot())
	c.location = PlayerLocation.from_dict(s.location.to_dict())
	return c


## Everything a trade or transfer may change.
func _state(s: Session) -> Dictionary:
	return {"money": s.wallet.get_balance(), "items": s.inventory.get_items(), "market": s.market.get_snapshot(), "lots": s.ledger.get_snapshot(), "warehouses": s.warehouses.get_snapshot()}


func _model_add(container: Dictionary, good_id: String, quantity: int, seq: int, cost: Variant) -> void:
	if not container.has(good_id):
		container[good_id] = []
	for i in range(quantity):
		container[good_id].append([seq, cost])


## Takes the `quantity` units with the lowest acquisition seq (stable order).
func _model_take(container: Dictionary, good_id: String, quantity: int) -> Array:
	var units: Array = container[good_id]
	units.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var taken := units.slice(0, quantity)
	container[good_id] = units.slice(quantity)
	return taken


## The model's units as ledger lots: one lot per seq, ascending.
func _model_lots(container: Dictionary, good_id: String) -> Array:
	var by_seq := {}
	for unit in container.get(good_id, []):
		if not by_seq.has(unit[0]):
			by_seq[unit[0]] = {"seq": unit[0], "quantity": 0}
			if unit[1] is String:
				by_seq[unit[0]]["unknown"] = true
			else:
				by_seq[unit[0]]["unit_cost"] = unit[1]
		by_seq[unit[0]]["quantity"] += 1
	var seqs := by_seq.keys()
	seqs.sort()
	var lots := []
	for seq in seqs:
		lots.append(by_seq[seq])
	return lots


func _bp(good: Dictionary, backpack: Dictionary) -> Dictionary:
	var ledger: Dictionary = good["cost_ledger"].duplicate(true)
	ledger["backpack"] = backpack
	return ledger


func _wh(good: Dictionary, city: String, lots: Dictionary) -> Dictionary:
	var ledger: Dictionary = good["cost_ledger"].duplicate(true)
	ledger["warehouses"][city] = lots
	return ledger


func _with(base: Dictionary, changes: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	result.merge(changes, true)
	return result


func _without(base: Dictionary, key: String) -> Dictionary:
	var result := base.duplicate(true)
	result.erase(key)
	return result


## Lots without their seq, for cost / quantity comparisons.
func _lots(ledger: TradeCostLedger, container: String, good_id: String) -> Array:
	var plain := []
	for lot in ledger.get_lots(container, good_id):
		var copy: Dictionary = lot.duplicate()
		copy.erase("seq")
		plain.append(copy)
	return plain


func _merge(base: Dictionary, extra: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	result.merge(extra, true)
	return result


func _signed(value: int) -> String:
	return "+%d" % value if value > 0 else "%d" % value


func _approved_chinese(text: String) -> bool:
	var latin := RegEx.new()
	latin.compile("[A-Za-z]")
	return latin.search(text) == null


func _market_with(stocks: Dictionary) -> MarketState:
	var snapshot := MarketState.create_default().get_snapshot()
	for city in stocks:
		for good_id in stocks[city]:
			snapshot[city][good_id]["current_stock"] = stocks[city][good_id]
	return MarketState.from_snapshot(snapshot)


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


func _walk_in(main: Node, city: String) -> void:
	var player := main.get_node("Actors/Player") as Player
	player.global_position = WorldLayout.CITY_ANCHORS[city]
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == city, "Must enter City %s" % city)


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
