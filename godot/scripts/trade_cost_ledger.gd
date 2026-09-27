class_name TradeCostLedger
extends RefCounted

## Trade cost accounting (T05): the acquisition-cost identity of every carried
## or stored trade good, kept apart from the quantity containers.
##
## For each container (the backpack, or one city's warehouse) and each good it
## holds an ordered queue of cost lots, oldest first:
##   {"quantity": q, "unit_cost": c}   q units bought at c each (one order)
##   {"quantity": q, "unknown": true}  q units whose cost is not known
##                                     (goods carried over from pre-T05 saves)
## Unknown cost is never a number: it is never 0, a current price or a baseline.
##
## Selling consumes lots FIFO (first in, first out). There is no average cost:
## lots with different costs stay separate. Only ADJACENT lots with the same
## cost (or two adjacent unknown lots) merge, which cannot change any FIFO
## result. Moving goods between containers takes the source's oldest lots and
## appends them, unchanged, as the destination's newest lots.
##
## Invariant (checked by matches_*): for every container and good, the lot
## quantities add up to exactly the container's item quantity. Profit / loss is
## never stored; it is derived from a sale.

const BACKPACK := "backpack"
const WAREHOUSE_PREFIX := "warehouse:"
const KNOWN_KEYS := ["quantity", "unit_cost"]
const UNKNOWN_KEYS := ["quantity", "unknown"]
## Same bounds as the containers and saved money, so sums stay exact.
const MAX_LOT_QUANTITY := 1000000000
const MAX_UNIT_COST := 9007199254740992
const INT64_MAX := 9223372036854775807

## container_id -> good_id -> Array of lots (oldest first, never empty)
var _lots := {}


static func warehouse(city_id: String) -> String:
	return WAREHOUSE_PREFIX + city_id


# --- Read -----------------------------------------------------------------------------------------

## The lots of one container x good, oldest first (a deep copy).
func get_lots(container_id: Variant, good_id: Variant) -> Array:
	return _queue(container_id, good_id).duplicate(true)


func get_quantity(container_id: Variant, good_id: Variant) -> int:
	var total := 0
	for lot in _queue(container_id, good_id):
		total += lot["quantity"]
	return total


## good_id -> quantity for one container.
func get_quantities(container_id: Variant) -> Dictionary:
	var quantities := {}
	if typeof(container_id) == TYPE_STRING and _lots.has(container_id):
		for good_id in _lots[container_id]:
			quantities[good_id] = get_quantity(container_id, good_id)
	return quantities


## The FIFO cost of the next `quantity` units of a container's good, without
## changing anything. The single cost rule used both for previews and for
## sales: {"success", "cost_known", "acquisition_cost" (null when any unit is
## unknown), "known_quantity", "unknown_quantity"}.
func preview_fifo(container_id: Variant, good_id: Variant, quantity: Variant) -> Dictionary:
	if not _is_positive_int(quantity) or quantity > get_quantity(container_id, good_id):
		return {"success": false, "cost_known": false, "acquisition_cost": null, "known_quantity": 0, "unknown_quantity": 0}
	var left: int = quantity
	var cost := 0
	var known := 0
	var unknown := 0
	for lot in _queue(container_id, good_id):
		if left == 0:
			break
		var take: int = mini(left, lot["quantity"])
		left -= take
		if lot.has("unknown"):
			unknown += take
		else:
			if take > (INT64_MAX - cost) / lot["unit_cost"]:
				return {"success": false, "cost_known": false, "acquisition_cost": null, "known_quantity": 0, "unknown_quantity": 0}
			cost += take * lot["unit_cost"]
			known += take
	var cost_known := unknown == 0
	return {"success": true, "cost_known": cost_known, "acquisition_cost": cost if cost_known else null, "known_quantity": known, "unknown_quantity": unknown}


# --- Change ---------------------------------------------------------------------------------------

## Appends a purchase lot (one order at one locked unit price).
func add_purchase(container_id: Variant, good_id: Variant, quantity: Variant, unit_cost: Variant) -> bool:
	if not _is_positive_int(unit_cost) or unit_cost > MAX_UNIT_COST:
		return false
	return _append(container_id, good_id, {"quantity": quantity, "unit_cost": unit_cost})


## Appends units whose acquisition cost is not known (save migration only).
func add_unknown(container_id: Variant, good_id: Variant, quantity: Variant) -> bool:
	return _append(container_id, good_id, {"quantity": quantity, "unknown": true})


## Removes the oldest `quantity` units (a sale). Returns preview_fifo() of
## exactly what was removed, or success = false with nothing changed.
func consume_fifo(container_id: Variant, good_id: Variant, quantity: Variant) -> Dictionary:
	var result := preview_fifo(container_id, good_id, quantity)
	if result["success"]:
		_take(container_id, good_id, quantity)
	return result


## Moves the source's oldest `quantity` units, with their exact costs, to the
## end of the destination's queue (warehouse deposit / withdraw).
func move_fifo(from_id: Variant, to_id: Variant, good_id: Variant, quantity: Variant) -> bool:
	if not _valid_container(to_id) or from_id == to_id or not _is_positive_int(quantity) \
		or quantity > get_quantity(from_id, good_id) or quantity > MAX_LOT_QUANTITY - get_quantity(to_id, good_id):
		return false
	for lot in _take(from_id, good_id, quantity):
		_append(to_id, good_id, lot)
	return true


# --- Invariant ------------------------------------------------------------------------------------

## True when the container's lot totals equal `quantities` (good_id -> int)
## exactly: no unaccounted units and no lots without units.
func matches_quantities(container_id: Variant, quantities: Dictionary) -> bool:
	return get_quantities(container_id) == _positive_only(quantities)


## The full invariant for a backpack (item_id -> quantity) and warehouses.
func matches(backpack_items: Dictionary, warehouses: WarehouseState) -> bool:
	if not matches_quantities(BACKPACK, backpack_items):
		return false
	var expected_containers := [BACKPACK]
	if warehouses != null:
		for city_id in warehouses.get_city_ids():
			expected_containers.append(warehouse(city_id))
			if not matches_quantities(warehouse(city_id), warehouses.get_contents(city_id)):
				return false
	for container_id in _lots:
		if not container_id in expected_containers:
			return false
	return true


# --- Snapshot / save ------------------------------------------------------------------------------

## Deep copy of every lot (rollback and inspection).
func get_snapshot() -> Dictionary:
	return _lots.duplicate(true)


func restore_snapshot(snapshot: Dictionary) -> void:
	_lots = snapshot.duplicate(true)


## Save shape: {"backpack": {good: [lots]}, "warehouses": {city: {good: [lots]}}}.
func to_save(city_ids: Array) -> Dictionary:
	var warehouses := {}
	for city_id in city_ids:
		warehouses[city_id] = _lots.get(warehouse(city_id), {}).duplicate(true)
	return {"backpack": _lots.get(BACKPACK, {}).duplicate(true), "warehouses": warehouses}


## Rebuilds from a save, or returns null for any malformed data: exact keys,
## known goods, non-empty lot lists, positive integer quantities, positive
## integer costs (a cost can never be 0 or negative) or the unknown marker.
## Quantity matching against the containers is checked by the caller.
static func from_save(data: Variant, city_ids: Array) -> TradeCostLedger:
	if typeof(data) != TYPE_DICTIONARY or data.size() != 2 or not data.has("backpack") or not data.has("warehouses"):
		return null
	var ledger := TradeCostLedger.new()
	if not ledger._load_container(BACKPACK, data["backpack"]):
		return null
	var stored: Variant = data["warehouses"]
	if typeof(stored) != TYPE_DICTIONARY or stored.size() != city_ids.size():
		return null
	for city_id in city_ids:
		if not stored.has(city_id) or not ledger._load_container(warehouse(city_id), stored[city_id]):
			return null
	return ledger


## Migration for saves written before T05: every existing unit, carried or
## stored, gets an UNKNOWN cost. Quantities are preserved exactly; no price is
## invented.
static func unknown_for(backpack_items: Dictionary, warehouses: WarehouseState) -> TradeCostLedger:
	var ledger := TradeCostLedger.new()
	for good_id in backpack_items:
		if not ledger.add_unknown(BACKPACK, good_id, backpack_items[good_id]):
			return null
	if warehouses != null:
		for city_id in warehouses.get_city_ids():
			var contents := warehouses.get_contents(city_id)
			for good_id in contents:
				if not ledger.add_unknown(warehouse(city_id), good_id, contents[good_id]):
					return null
	return ledger


func _load_container(container_id: String, goods: Variant) -> bool:
	if typeof(goods) != TYPE_DICTIONARY:
		return false
	for good_id in goods:
		var lots: Variant = goods[good_id]
		if not GoodsCatalog.has_good(good_id) or typeof(lots) != TYPE_ARRAY or lots.is_empty():
			return false
		for lot in lots:
			var parsed: Variant = _parse_lot(lot)
			if parsed == null or not _append(container_id, good_id, parsed):
				return false
		if _queue(container_id, good_id).size() != lots.size():
			# Adjacent equal-cost lots are always merged when written, so a
			# save that splits them was not written by this ledger.
			return false
	return true


static func _parse_lot(lot: Variant) -> Variant:
	if typeof(lot) != TYPE_DICTIONARY:
		return null
	var quantity := _exact_int(lot.get("quantity"), MAX_LOT_QUANTITY)
	if quantity <= 0:
		return null
	if lot.size() == UNKNOWN_KEYS.size() and lot.has("unknown"):
		return {"quantity": quantity, "unknown": true} if typeof(lot["unknown"]) == TYPE_BOOL and lot["unknown"] else null
	if lot.size() == KNOWN_KEYS.size() and lot.has("unit_cost"):
		var cost := _exact_int(lot["unit_cost"], MAX_UNIT_COST)
		return {"quantity": quantity, "unit_cost": cost} if cost > 0 else null
	return null


static func _exact_int(value: Variant, maximum: int) -> int:
	if typeof(value) == TYPE_INT:
		return value if value >= 0 and value <= maximum else -1
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) \
		and value >= 0.0 and value <= float(maximum):
		return int(value)
	return -1


# --- Internals ------------------------------------------------------------------------------------

func _queue(container_id: Variant, good_id: Variant) -> Array:
	if typeof(container_id) != TYPE_STRING or typeof(good_id) != TYPE_STRING:
		return []
	return _lots.get(container_id, {}).get(good_id, [])


func _append(container_id: Variant, good_id: Variant, lot: Dictionary) -> bool:
	if not _valid_container(container_id) or not GoodsCatalog.has_good(good_id) \
		or not _is_positive_int(lot.get("quantity")) \
		or lot["quantity"] > MAX_LOT_QUANTITY - get_quantity(container_id, good_id):
		return false
	if not _lots.has(container_id):
		_lots[container_id] = {}
	var queue: Array = _lots[container_id].get(good_id, [])
	if not queue.is_empty() and _same_cost(queue.back(), lot):
		queue.back()["quantity"] += lot["quantity"]
	else:
		queue.append(lot.duplicate())
	_lots[container_id][good_id] = queue
	return true


## Removes and returns the oldest `quantity` units as lots (caller checked).
func _take(container_id: String, good_id: String, quantity: int) -> Array:
	var queue: Array = _lots[container_id][good_id]
	var taken := []
	var left := quantity
	while left > 0:
		var lot: Dictionary = queue.front()
		var take: int = mini(left, lot["quantity"])
		var part := lot.duplicate()
		part["quantity"] = take
		taken.append(part)
		left -= take
		if take == lot["quantity"]:
			queue.pop_front()
		else:
			lot["quantity"] -= take
	if queue.is_empty():
		_lots[container_id].erase(good_id)
		if _lots[container_id].is_empty():
			_lots.erase(container_id)
	return taken


static func _same_cost(a: Dictionary, b: Dictionary) -> bool:
	if a.has("unknown") or b.has("unknown"):
		return a.has("unknown") and b.has("unknown")
	return a["unit_cost"] == b["unit_cost"]


static func _valid_container(container_id: Variant) -> bool:
	if typeof(container_id) != TYPE_STRING:
		return false
	if container_id == BACKPACK:
		return true
	return container_id.begins_with(WAREHOUSE_PREFIX) and container_id.trim_prefix(WAREHOUSE_PREFIX) in WorldLayout.ACTIVE_CITY_IDS


static func _positive_only(quantities: Dictionary) -> Dictionary:
	var result := {}
	for key in quantities:
		if typeof(quantities[key]) != TYPE_INT or quantities[key] != 0:
			result[key] = quantities[key]
	return result


static func _is_positive_int(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and value > 0
