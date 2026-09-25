class_name TradeService
extends RefCounted

## UI-independent buy/sell core. Every check runs before any state changes,
## so a rejected trade leaves both the wallet and the cargo untouched.
## Cargo is only changed through its own validated API.


static func buy(city_id: Variant, good_id: Variant, quantity: Variant, wallet: Wallet, cargo: Cargo) -> Dictionary:
	var price := MarketPrices.get_price(city_id, good_id)
	if wallet == null or cargo == null:
		return _result(false, 0, "invalid_state")
	if price <= 0:
		return _result(false, 0, "invalid_city_or_good")
	if typeof(quantity) != TYPE_INT or quantity <= 0:
		return _result(false, 0, "invalid_quantity")
	# can_add bounds quantity by capacity, which also keeps price x quantity small.
	if not cargo.can_add(good_id, quantity):
		return _result(false, 0, "insufficient_cargo_space")
	var total: int = price * quantity
	if not wallet.can_spend(total):
		return _result(false, total, "insufficient_money")
	if not wallet.spend(total):
		return _result(false, total, "invalid_state")
	if not cargo.add(good_id, quantity):
		wallet.add(total)
		return _result(false, total, "invalid_state")
	return _result(true, total, "")


static func sell(city_id: Variant, good_id: Variant, quantity: Variant, wallet: Wallet, cargo: Cargo) -> Dictionary:
	var price := MarketPrices.get_price(city_id, good_id)
	if wallet == null or cargo == null:
		return _result(false, 0, "invalid_state")
	if price <= 0:
		return _result(false, 0, "invalid_city_or_good")
	if typeof(quantity) != TYPE_INT or quantity <= 0:
		return _result(false, 0, "invalid_quantity")
	# can_remove bounds quantity by what is held, which keeps price x quantity small.
	if not cargo.can_remove(good_id, quantity):
		return _result(false, 0, "insufficient_cargo")
	var total: int = price * quantity
	if not wallet.can_add(total):
		return _result(false, total, "invalid_state")
	if not cargo.remove(good_id, quantity):
		return _result(false, total, "invalid_state")
	if not wallet.add(total):
		cargo.add(good_id, quantity)
		return _result(false, total, "invalid_state")
	return _result(true, total, "")


static func _result(success: bool, total_value: int, reason: String) -> Dictionary:
	return {"success": success, "total_value": total_value, "reason": reason}
