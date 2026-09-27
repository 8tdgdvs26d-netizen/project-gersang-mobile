class_name TradeCostLedger
extends RefCounted

## Trade cost accounting (T05): the acquisition-cost identity of every carried
## or stored trade good, kept apart from the quantity containers.
##
## Every purchase order becomes one lot with a stable acquisition sequence
## number `seq` (1, 2, 3, ... in purchase order, never reused or changed):
##   {"seq": s, "quantity": q, "unit_cost": c}   q units of purchase s at c each
##   {"seq": s, "quantity": q, "unknown": true}  q units whose cost is not known
##                                               (goods from pre-T05 saves)
## Unknown cost is never a number: it is never 0, a current price or a baseline.
##
## ACQUISITION-ORDER FIFO: each container (the backpack, or one city's
## warehouse) keeps, per good, its part of each lot ordered by `seq`. Selling
## consumes the backpack's lowest `seq` first. Moving goods between containers
## (warehouse deposit / withdraw) takes the source's lowest `seq` units and
## keeps their `seq`, quantity and cost; in the destination they rejoin the
## part of the same lot if it is there. Moving never changes FIFO priority:
## goods just withdrawn are still as old as when they were bought. There is no
## average cost; different purchases never merge.
##
## Invariant (checked by matches*): for every container and good, the lot
## quantities add up to exactly the container's item quantity. Profit / loss is
## never stored; it is derived from a sale.

const BACKPACK := "backpack"
const WAREHOUSE_PREFIX := "warehouse:"
const KNOWN_KEYS := ["seq", "quantity", "unit_cost"]
const UNKNOWN_KEYS := ["seq", "quantity", "unknown"]
const SAVE_KEYS := ["next_seq", "backpack", "warehouses"]
## Same bounds as the containers and saved money, so sums stay exact.
const MAX_LOT_QUANTITY := 1000000000
const MAX_UNIT_COST := 9007199254740992
const MAX_SEQ := 9007199254740992
const INT64_MAX := 9223372036854775807

## container_id -> good_id -> Array of lots, strictly ascending by seq, never
## empty. One seq appears at most once per container x good.
var _lots := {}
## The acquisition sequence number the next lot receives.
var _next_seq := 1


static func warehouse(city_id: String) -> String:
	return WAREHOUSE_PREFIX + city_id


# --- Read -----------------------------------------------------------------------------------------

## The lots of one container x good, oldest acquisition first (a deep copy).
func get_lots(container_id: Variant, good_id: Variant) -> Array:
	return _queue(container_id, good_id).duplicate(true)


## Every lot of every container (a deep copy, for inspection).
func get_all_lots() -> Dictionary:
	return _lots.duplicate(true)


func get_next_seq() -> int:
	return _next_seq


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


## The FIFO cost of the next `quantity` units of a container's good (lowest
## acquisition seq first), without changing anything. The single cost rule
## used both for previews and for sales: {"success", "cost_known",
## "acquisition_cost" (null when any unit is unknown), "known_quantity",
## "unknown_quantity"}.
func preview_fifo(container_id: Variant, good_id: Variant, quantity: Variant) -> Dictionary:
	if not _is_positive_int(quantity) or quantity > get_quantity(container_id, good_id):
		return _no_preview()
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
				return _no_preview()
			cost += take * lot["unit_cost"]
			known += take
	var cost_known := unknown == 0
	return {"success": true, "cost_known": cost_known, "acquisition_cost": cost if cost_known else null, "known_quantity": known, "unknown_quantity": unknown}


# --- Change ---------------------------------------------------------------------------------------

## Adds a purchase lot (one order at one locked unit price) with the next seq.
func add_purchase(container_id: Variant, good_id: Variant, quantity: Variant, unit_cost: Variant) -> bool:
	if not _is_positive_int(unit_cost) or unit_cost > MAX_UNIT_COST:
		return false
	return _add_new(container_id, good_id, {"quantity": quantity, "unit_cost": unit_cost})


## Adds units whose acquisition cost is not known, with the next seq (save
## migration only).
func add_unknown(container_id: Variant, good_id: Variant, quantity: Variant) -> bool:
	return _add_new(container_id, good_id, {"quantity": quantity, "unknown": true})


## Removes the oldest `quantity` units (a sale). Returns preview_fifo() of
## exactly what was removed, or success = false with nothing changed.
func consume_fifo(container_id: Variant, good_id: Variant, quantity: Variant) -> Dictionary:
	var result := preview_fifo(container_id, good_id, quantity)
	if result["success"]:
		_take(container_id, good_id, quantity)
	return result


## Moves the source's oldest `quantity` units to the destination (warehouse
## deposit / withdraw), keeping each unit's seq and cost.
func move_fifo(from_id: Variant, to_id: Variant, good_id: Variant, quantity: Variant) -> bool:
	if not _valid_container(to_id) or from_id == to_id or not _is_positive_int(quantity) \
		or quantity > get_quantity(from_id, good_id) or quantity > MAX_LOT_QUANTITY - get_quantity(to_id, good_id):
		return false
	for part in _take(from_id, good_id, quantity):
		_insert(to_id, good_id, part)
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

## Deep copy of the whole state (lots and the seq counter), for rollback.
func get_snapshot() -> Dictionary:
	return {"lots": _lots.duplicate(true), "next_seq": _next_seq}


func restore_snapshot(snapshot: Dictionary) -> void:
	_lots = snapshot["lots"].duplicate(true)
	_next_seq = snapshot["next_seq"]


## Save shape: {"next_seq": n, "backpack": {good: [lots]},
## "warehouses": {city: {good: [lots]}}}, lots ascending by seq.
func to_save(city_ids: Array) -> Dictionary:
	var warehouses := {}
	for city_id in city_ids:
		warehouses[city_id] = _lots.get(warehouse(city_id), {}).duplicate(true)
	return {"next_seq": _next_seq, "backpack": _lots.get(BACKPACK, {}).duplicate(true), "warehouses": warehouses}


## Rebuilds from a save, or returns null for any malformed data: exact keys,
## known goods, non-empty lot lists, positive integer seqs / quantities /
## costs (a cost can never be 0 or negative) or the unknown marker; within a
## container x good the seqs strictly ascend; one seq always means the same
## good and the same cost wherever its parts are stored; next_seq is above
## every seq. Quantity matching against the containers is checked by the
## caller.
static func from_save(data: Variant, city_ids: Array) -> TradeCostLedger:
	if typeof(data) != TYPE_DICTIONARY or data.size() != SAVE_KEYS.size() or not data.has_all(SAVE_KEYS):
		return null
	var ledger := TradeCostLedger.new()
	var identities := {}
	if not ledger._load_container(BACKPACK, data["backpack"], identities):
		return null
	var stored: Variant = data["warehouses"]
	if typeof(stored) != TYPE_DICTIONARY or stored.size() != city_ids.size():
		return null
	for city_id in city_ids:
		if not stored.has(city_id) or not ledger._load_container(warehouse(city_id), stored[city_id], identities):
			return null
	var next_seq := _exact_int(data["next_seq"], MAX_SEQ)
	for seq in identities:
		if seq >= next_seq:
			return null
	if next_seq < 1:
		return null
	ledger._next_seq = next_seq
	return ledger


## Migration for saves written before T05: every existing unit, carried or
## stored, gets an UNKNOWN cost. Quantities are preserved exactly; no price is
## invented. Deterministic acquisition order (documented rule): backpack
## first, then each warehouse in active-city order; within a container, goods
## in catalog order. So for one good the carried units count as older than
## warehouse A's, which count as older than warehouse B's.
static func unknown_for(backpack_items: Dictionary, warehouses: WarehouseState) -> TradeCostLedger:
	var ledger := TradeCostLedger.new()
	var containers := [[BACKPACK, backpack_items]]
	if warehouses != null:
		for city_id in WorldLayout.ACTIVE_CITY_IDS:
			if warehouses.has_city(city_id):
				containers.append([warehouse(city_id), warehouses.get_contents(city_id)])
	for entry in containers:
		var items: Dictionary = entry[1]
		for good_id in GoodsCatalog.get_ids():
			if items.has(good_id) and not ledger.add_unknown(entry[0], good_id, items[good_id]):
				return null
		for good_id in items:
			if not GoodsCatalog.has_good(good_id):
				return null
	return ledger


func _load_container(container_id: String, goods: Variant, identities: Dictionary) -> bool:
	if typeof(goods) != TYPE_DICTIONARY:
		return false
	for good_id in goods:
		var lots: Variant = goods[good_id]
		if not GoodsCatalog.has_good(good_id) or typeof(lots) != TYPE_ARRAY or lots.is_empty():
			return false
		var previous_seq := 0
		for lot in lots:
			var parsed: Variant = _parse_lot(lot)
			if parsed == null or parsed["seq"] <= previous_seq:
				return false
			previous_seq = parsed["seq"]
			# One seq is one purchase: the same good and cost everywhere.
			var identity := [good_id, parsed.get("unit_cost", -1)]
			if identities.has(parsed["seq"]) and identities[parsed["seq"]] != identity:
				return false
			identities[parsed["seq"]] = identity
			if not _insert(container_id, good_id, parsed):
				return false
	return true


static func _parse_lot(lot: Variant) -> Variant:
	if typeof(lot) != TYPE_DICTIONARY:
		return null
	var seq := _exact_int(lot.get("seq"), MAX_SEQ)
	var quantity := _exact_int(lot.get("quantity"), MAX_LOT_QUANTITY)
	if seq <= 0 or quantity <= 0:
		return null
	if lot.size() == UNKNOWN_KEYS.size() and lot.has("unknown"):
		return {"seq": seq, "quantity": quantity, "unknown": true} if typeof(lot["unknown"]) == TYPE_BOOL and lot["unknown"] else null
	if lot.size() == KNOWN_KEYS.size() and lot.has("unit_cost"):
		var cost := _exact_int(lot["unit_cost"], MAX_UNIT_COST)
		return {"seq": seq, "quantity": quantity, "unit_cost": cost} if cost > 0 else null
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


## A new acquisition: the next seq, which is newer than every existing lot.
func _add_new(container_id: Variant, good_id: Variant, lot: Dictionary) -> bool:
	if _next_seq >= MAX_SEQ:
		return false
	var numbered := lot.duplicate()
	numbered["seq"] = _next_seq
	if not _insert(container_id, good_id, numbered):
		return false
	_next_seq += 1
	return true


## Places a lot (or part of one) by seq; a part of a lot already in this
## container rejoins it. A seq's cost must match its existing part.
func _insert(container_id: Variant, good_id: Variant, lot: Dictionary) -> bool:
	if not _valid_container(container_id) or not GoodsCatalog.has_good(good_id) \
		or not _is_positive_int(lot.get("quantity")) or not _is_positive_int(lot.get("seq")) \
		or lot["quantity"] > MAX_LOT_QUANTITY - get_quantity(container_id, good_id):
		return false
	if not _lots.has(container_id):
		_lots[container_id] = {}
	var queue: Array = _lots[container_id].get(good_id, [])
	var index := 0
	while index < queue.size() and queue[index]["seq"] < lot["seq"]:
		index += 1
	if index < queue.size() and queue[index]["seq"] == lot["seq"]:
		if not _same_cost(queue[index], lot):
			return false
		queue[index]["quantity"] += lot["quantity"]
	else:
		queue.insert(index, lot.duplicate())
	_lots[container_id][good_id] = queue
	return true


## Removes and returns the oldest `quantity` units as lot parts (caller checked).
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


static func _no_preview() -> Dictionary:
	return {"success": false, "cost_known": false, "acquisition_cost": null, "known_quantity": 0, "unknown_quantity": 0}


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
