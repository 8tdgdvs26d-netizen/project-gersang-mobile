class_name MarketState
extends RefCounted

## Runtime market of every active city: for each city x good it holds the
## reference price, current stock and target stock. It belongs to the world,
## not to the player. Prices come from MarketRules; stock only changes through
## validated calls. Reference prices do not move with trades (no dynamic
## pricing yet), and target stock is stored for future restocking only.

## Largest stock that still round-trips exactly through the JSON save.
const MAX_STOCK := 9007199254740992
const ENTRY_KEYS := ["reference_price", "current_stock", "target_stock"]

## city_id -> good_id -> {"reference_price", "current_stock", "target_stock"}
var _markets := {}


static func create_default() -> MarketState:
	var state := MarketState.new()
	for city in WorldLayout.ACTIVE_CITY_IDS:
		var goods := {}
		for good_id in GoodsCatalog.get_ids():
			goods[good_id] = {
				"reference_price": MarketPrices.get_price(city, good_id),
				"current_stock": MarketPrices.INITIAL_STOCK,
				"target_stock": MarketPrices.TARGET_STOCK,
			}
		state._markets[city] = goods
	return state


## Builds a market from a snapshot with int values. Every active city and good
## must be present exactly once with valid values; otherwise returns null.
static func from_snapshot(snapshot: Variant) -> MarketState:
	if typeof(snapshot) != TYPE_DICTIONARY or snapshot.size() != WorldLayout.ACTIVE_CITY_IDS.size():
		return null
	var state := MarketState.new()
	for city in WorldLayout.ACTIVE_CITY_IDS:
		var goods: Variant = snapshot.get(city)
		if typeof(goods) != TYPE_DICTIONARY or goods.size() != GoodsCatalog.get_ids().size():
			return null
		var restored := {}
		for good_id in GoodsCatalog.get_ids():
			var entry: Variant = goods.get(good_id)
			if not _valid_entry(entry):
				return null
			restored[good_id] = (entry as Dictionary).duplicate()
		state._markets[city] = restored
	return state


static func _valid_entry(entry: Variant) -> bool:
	if typeof(entry) != TYPE_DICTIONARY or entry.size() != ENTRY_KEYS.size():
		return false
	for key in ENTRY_KEYS:
		if typeof(entry.get(key)) != TYPE_INT:
			return false
	return entry["reference_price"] >= MarketRules.MIN_REFERENCE_PRICE and entry["reference_price"] <= MAX_STOCK \
		and entry["current_stock"] >= 0 and entry["current_stock"] <= MAX_STOCK \
		and entry["target_stock"] > 0 and entry["target_stock"] <= MAX_STOCK


## Deep copy of the whole market, for saving and inspection.
func get_snapshot() -> Dictionary:
	return _markets.duplicate(true)


## Returns reference_price, buy_price, buyback_price, stock and target_stock,
## or an empty Dictionary for an unknown or reserved city or unknown good.
func get_quote(city_id: Variant, good_id: Variant) -> Dictionary:
	var entry := _entry(city_id, good_id)
	if entry.is_empty():
		return {}
	var reference: int = entry["reference_price"]
	return {
		"reference_price": reference,
		"buy_price": MarketRules.buy_price(reference),
		"buyback_price": MarketRules.buyback_price(reference),
		"stock": entry["current_stock"],
		"target_stock": entry["target_stock"],
	}


func can_remove_stock(city_id: Variant, good_id: Variant, quantity: Variant) -> bool:
	var entry := _entry(city_id, good_id)
	return not entry.is_empty() and _is_positive_int(quantity) and quantity <= entry["current_stock"]


func remove_stock(city_id: Variant, good_id: Variant, quantity: Variant) -> bool:
	if not can_remove_stock(city_id, good_id, quantity):
		return false
	_markets[city_id][good_id]["current_stock"] -= quantity
	return true


## Stock may rise above the target stock; there is no upper limit besides
## keeping the number exact.
func can_add_stock(city_id: Variant, good_id: Variant, quantity: Variant) -> bool:
	var entry := _entry(city_id, good_id)
	return not entry.is_empty() and _is_positive_int(quantity) and quantity <= MAX_STOCK - entry["current_stock"]


func add_stock(city_id: Variant, good_id: Variant, quantity: Variant) -> bool:
	if not can_add_stock(city_id, good_id, quantity):
		return false
	_markets[city_id][good_id]["current_stock"] += quantity
	return true


func _entry(city_id: Variant, good_id: Variant) -> Dictionary:
	if typeof(city_id) != TYPE_STRING or typeof(good_id) != TYPE_STRING:
		return {}
	return _markets.get(city_id, {}).get(good_id, {})


func _is_positive_int(quantity: Variant) -> bool:
	return typeof(quantity) == TYPE_INT and quantity > 0
