class_name TradeService
extends RefCounted

## UI-independent buy/sell core. Prices and stock come from the city market's
## quote. Every check runs before any state changes, so a rejected trade leaves
## the wallet, inventory and market untouched. Inventory and stock are only
## changed through their own validated APIs.
##
## ORDER-LOCKED PRICING (T03): one order = one price. The unit price is read
## from the quote once, before the order, and every unit of that order uses it
## (total = unit price x quantity). Only after the whole order succeeds does
## the stock change, so the NEXT order sees the new dynamic price. An order is
## one atomic transaction, never split into per-unit trades.

const INT64_MAX := 9223372036854775807
## PROTOTYPE RULE (T03): the only allowed order sizes, enforced here in the
## domain (not only in the UI), so no order can be large enough to buy at a
## low pre-trade price and immediately sell at a much higher post-trade price.
const ALLOWED_ORDER_QUANTITIES := [1, 10]


static func is_allowed_quantity(quantity: Variant) -> bool:
	return typeof(quantity) == TYPE_INT and quantity in ALLOWED_ORDER_QUANTITIES


## Player buys from the city at the quote's buy price; market stock goes down.
## With a cost ledger (T05) the order also becomes one backpack cost lot of
## `quantity` units at the locked unit price. Wallet, inventory, market and
## ledger change together or not at all.
static func buy(city_id: Variant, good_id: Variant, quantity: Variant, wallet: Wallet, inventory: CharacterInventory, market: MarketState, ledger: TradeCostLedger = null) -> Dictionary:
	if wallet == null or inventory == null or market == null:
		return _result(false, 0, "invalid_state")
	var quote := market.get_quote(city_id, good_id)
	if quote.is_empty() or quote["buy_price"] <= 0:
		return _result(false, 0, "invalid_city_or_good")
	if not is_allowed_quantity(quantity):
		return _result(false, 0, "invalid_quantity")
	if not market.can_remove_stock(city_id, good_id, quantity):
		return _result(false, 0, "insufficient_market_stock")
	if not inventory.can_add(good_id, quantity):
		return _result(false, 0, "insufficient_cargo_space")
	var unit_price: int = quote["buy_price"]  # locked for the whole order
	if quantity > INT64_MAX / unit_price:
		return _result(false, 0, "invalid_quantity")
	var total: int = unit_price * quantity
	if not wallet.can_spend(total):
		return _result(false, total, "insufficient_money")
	if ledger != null and not _ledger_in_step(ledger, inventory, good_id):
		return _result(false, total, "invalid_state")
	var inventory_before := inventory.get_stacks()
	var ledger_before := ledger.get_snapshot() if ledger != null else {}
	if not wallet.spend(total):
		return _result(false, total, "invalid_state")
	if not inventory.add(good_id, quantity) \
		or (ledger != null and not ledger.add_purchase(TradeCostLedger.BACKPACK, good_id, quantity, unit_price)) \
		or not market.remove_stock(city_id, good_id, quantity):
		_rollback(wallet, -total, inventory, inventory_before, ledger, ledger_before)
		return _result(false, total, "invalid_state")
	var result := _result(true, total, "")
	result["unit_price"] = unit_price
	return result


## Player sells to the city at the quote's buyback price; market stock goes up.
## With a cost ledger (T05) the sold units' oldest (FIFO) cost lots are
## consumed and the result carries the realized merchandise profit / loss:
## revenue, cost_known, acquisition_cost and realized_profit (both null when
## any sold unit has an unknown cost; the sale itself still pays in full).
static func sell(city_id: Variant, good_id: Variant, quantity: Variant, wallet: Wallet, inventory: CharacterInventory, market: MarketState, ledger: TradeCostLedger = null) -> Dictionary:
	if wallet == null:
		return _result(false, 0, "invalid_state")
	var terms := _sale_terms(city_id, good_id, quantity, wallet, inventory, market, ledger)
	if not terms["success"]:
		return terms
	var total: int = terms["total_value"]
	var inventory_before := inventory.get_stacks()
	var ledger_before := ledger.get_snapshot() if ledger != null else {}
	if not inventory.remove(good_id, quantity):
		return _result(false, total, "invalid_state")
	var consumed := ledger.consume_fifo(TradeCostLedger.BACKPACK, good_id, quantity) if ledger != null else {"success": true}
	if not consumed["success"] or consumed.get("acquisition_cost") != terms["acquisition_cost"] or not wallet.add(total):
		_rollback(wallet, 0, inventory, inventory_before, ledger, ledger_before)
		return _result(false, total, "invalid_state")
	if not market.add_stock(city_id, good_id, quantity):
		_rollback(wallet, total, inventory, inventory_before, ledger, ledger_before)
		return _result(false, total, "invalid_state")
	return terms


## What selling `quantity` would pay and realize right now, with exactly the
## rules sell() uses (same locked quote, same ledger FIFO preview). Changes
## nothing. The executed sale uses the quote at execution time.
static func preview_sell(city_id: Variant, good_id: Variant, quantity: Variant, inventory: CharacterInventory, market: MarketState, ledger: TradeCostLedger) -> Dictionary:
	return _sale_terms(city_id, good_id, quantity, null, inventory, market, ledger)


## Shared by sell() and preview_sell(). `wallet` is null for a preview.
static func _sale_terms(city_id: Variant, good_id: Variant, quantity: Variant, wallet: Wallet, inventory: CharacterInventory, market: MarketState, ledger: TradeCostLedger) -> Dictionary:
	var preview := wallet == null
	if inventory == null or market == null or (preview and ledger == null):
		return _result(false, 0, "invalid_state")
	var quote := market.get_quote(city_id, good_id)
	if quote.is_empty() or quote["buyback_price"] <= 0:
		return _result(false, 0, "invalid_city_or_good")
	if not is_allowed_quantity(quantity):
		return _result(false, 0, "invalid_quantity")
	if not inventory.can_remove(good_id, quantity):
		return _result(false, 0, "insufficient_cargo")
	var unit_price: int = quote["buyback_price"]  # locked for the whole order
	if quantity > INT64_MAX / unit_price:
		return _result(false, 0, "invalid_quantity")
	var total: int = unit_price * quantity
	if not market.can_add_stock(city_id, good_id, quantity) or (not preview and not wallet.can_add(total)):
		return _result(false, total, "invalid_state")
	var result := _result(true, total, "")
	result["unit_price"] = unit_price
	result["revenue"] = total
	result["cost_known"] = false
	result["acquisition_cost"] = null
	result["realized_profit"] = null
	if ledger != null:
		if not _ledger_in_step(ledger, inventory, good_id):
			return _result(false, total, "invalid_state")
		var cost := ledger.preview_fifo(TradeCostLedger.BACKPACK, good_id, quantity)
		if not cost["success"]:
			return _result(false, total, "invalid_state")
		result["cost_known"] = cost["cost_known"]
		result["acquisition_cost"] = cost["acquisition_cost"]
		if cost["cost_known"]:
			result["realized_profit"] = total - int(cost["acquisition_cost"])
	return result


## The backpack's ledger must account for exactly the carried quantity.
static func _ledger_in_step(ledger: TradeCostLedger, inventory: CharacterInventory, good_id: Variant) -> bool:
	return ledger.get_quantity(TradeCostLedger.BACKPACK, good_id) == inventory.get_quantity(good_id)


## Undoes a partly applied order: `money_delta` is what the wallet already
## changed by (negative for a purchase).
static func _rollback(wallet: Wallet, money_delta: int, inventory: CharacterInventory, inventory_before: Dictionary, ledger: TradeCostLedger, ledger_before: Dictionary) -> void:
	if money_delta < 0:
		wallet.add(-money_delta)
	elif money_delta > 0:
		wallet.spend(money_delta)
	inventory.restore_stacks(inventory_before)
	if ledger != null:
		ledger.restore_snapshot(ledger_before)


static func _result(success: bool, total_value: int, reason: String) -> Dictionary:
	return {"success": success, "total_value": total_value, "reason": reason}
