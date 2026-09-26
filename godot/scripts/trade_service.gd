class_name TradeService
extends RefCounted

## UI-independent buy/sell core. Prices and stock come from the city market's
## quote. Every check runs before any state changes, so a rejected trade leaves
## the wallet, the cargo and the market untouched. Cargo and stock are only
## changed through their own validated APIs.


## Player buys from the city at the quote's buy price; market stock goes down.
static func buy(city_id: Variant, good_id: Variant, quantity: Variant, wallet: Wallet, inventory: CharacterInventory, market: MarketState) -> Dictionary:
	if wallet == null or inventory == null or market == null:
		return _result(false, 0, "invalid_state")
	var quote := market.get_quote(city_id, good_id)
	if quote.is_empty() or quote["buy_price"] <= 0:
		return _result(false, 0, "invalid_city_or_good")
	if typeof(quantity) != TYPE_INT or quantity <= 0:
		return _result(false, 0, "invalid_quantity")
	if not market.can_remove_stock(city_id, good_id, quantity):
		return _result(false, 0, "insufficient_market_stock")
	# can_add bounds quantity by capacity, which also keeps price x quantity small.
	if not inventory.can_add(good_id, quantity):
		return _result(false, 0, "insufficient_cargo_space")
	var total: int = quote["buy_price"] * quantity
	if not wallet.can_spend(total):
		return _result(false, total, "insufficient_money")
	var inventory_before := inventory.get_stacks()
	if not wallet.spend(total):
		return _result(false, total, "invalid_state")
	if not inventory.add(good_id, quantity):
		wallet.add(total)
		inventory.restore_stacks(inventory_before)
		return _result(false, total, "invalid_state")
	if not market.remove_stock(city_id, good_id, quantity):
		inventory.restore_stacks(inventory_before)
		wallet.add(total)
		return _result(false, total, "invalid_state")
	return _result(true, total, "")


## Player sells to the city at the quote's buyback price; market stock goes up.
static func sell(city_id: Variant, good_id: Variant, quantity: Variant, wallet: Wallet, inventory: CharacterInventory, market: MarketState) -> Dictionary:
	if wallet == null or inventory == null or market == null:
		return _result(false, 0, "invalid_state")
	var quote := market.get_quote(city_id, good_id)
	if quote.is_empty() or quote["buyback_price"] <= 0:
		return _result(false, 0, "invalid_city_or_good")
	if typeof(quantity) != TYPE_INT or quantity <= 0:
		return _result(false, 0, "invalid_quantity")
	# can_remove bounds quantity by what is held, which keeps price x quantity small.
	if not inventory.can_remove(good_id, quantity):
		return _result(false, 0, "insufficient_cargo")
	var total: int = quote["buyback_price"] * quantity
	if not wallet.can_add(total) or not market.can_add_stock(city_id, good_id, quantity):
		return _result(false, total, "invalid_state")
	var inventory_before := inventory.get_stacks()
	if not inventory.remove(good_id, quantity):
		return _result(false, total, "invalid_state")
	if not wallet.add(total):
		inventory.restore_stacks(inventory_before)
		return _result(false, total, "invalid_state")
	if not market.add_stock(city_id, good_id, quantity):
		wallet.spend(total)
		inventory.restore_stacks(inventory_before)
		return _result(false, total, "invalid_state")
	return _result(true, total, "")


static func _result(success: bool, total_value: int, reason: String) -> Dictionary:
	return {"success": success, "total_value": total_value, "reason": reason}
