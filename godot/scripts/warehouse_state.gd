class_name WarehouseState
extends RefCounted

## One independent CityWarehouse per active city. Only item quantities are
## saved; capacity is balance data resolved from the constants below on every
## load, so it can be re-tuned without migrating saves.
##
## Read access is by city id and always returns copies. Only WarehouseService
## changes warehouse contents.

## PROTOTYPE PARAMETER — warehouse capacity per city in carrying-capacity
## units (the prototype character carries 20). Not a formal balance value.
const PROTOTYPE_CAPACITY := 200
const CITY_CAPACITIES := {"A": PROTOTYPE_CAPACITY, "B": PROTOTYPE_CAPACITY}
const SAVED_CITY_KEYS := ["items"]

## Runtime-only id of the last applied warehouse request, so the same request
## delivered twice (a double tap) is applied once.
var last_request_id := ""
var _warehouses := {}


static func create_default() -> WarehouseState:
	var state := WarehouseState.new()
	for city_id in WorldLayout.ACTIVE_CITY_IDS:
		state._warehouses[city_id] = CityWarehouse.new(city_id, CITY_CAPACITIES.get(city_id, PROTOTYPE_CAPACITY))
	return state


func has_city(city_id: Variant) -> bool:
	return typeof(city_id) == TYPE_STRING and _warehouses.has(city_id)


func get_city_ids() -> Array:
	return _warehouses.keys()


## item_id -> quantity stored in that city (a copy; {} for unknown cities).
func get_contents(city_id: Variant) -> Dictionary:
	return _warehouses[city_id].get_items() if has_city(city_id) else {}


func get_quantity(city_id: Variant, item_id: Variant) -> int:
	return _warehouses[city_id].get_quantity(item_id) if has_city(city_id) else 0


func get_used_capacity(city_id: Variant) -> int:
	return _warehouses[city_id].get_used_capacity() if has_city(city_id) else 0


func get_max_capacity(city_id: Variant) -> int:
	return _warehouses[city_id].get_max_capacity() if has_city(city_id) else 0


func get_remaining_capacity(city_id: Variant) -> int:
	return _warehouses[city_id].get_remaining_capacity() if has_city(city_id) else 0


## Save shape: city_id -> {"items": {item_id: quantity}}.
func get_snapshot() -> Dictionary:
	var snapshot := {}
	for city_id in _warehouses:
		snapshot[city_id] = {"items": _warehouses[city_id].get_items()}
	return snapshot


## Builds warehouses from saved data, or returns null if anything is invalid:
## every active city exactly once, only known goods, positive integer
## quantities. JSON floats are accepted only when they are exact integers.
static func from_snapshot(data: Variant) -> WarehouseState:
	if typeof(data) != TYPE_DICTIONARY or data.size() != WorldLayout.ACTIVE_CITY_IDS.size():
		return null
	var state := create_default()
	for city_id in WorldLayout.ACTIVE_CITY_IDS:
		var entry: Variant = data.get(city_id)
		if typeof(entry) != TYPE_DICTIONARY or entry.size() != SAVED_CITY_KEYS.size() or not entry.has("items"):
			return null
		if typeof(entry["items"]) != TYPE_DICTIONARY:
			return null
		var quantities := {}
		for item_id in entry["items"]:
			var quantity := _exact_int(entry["items"][item_id])
			if quantity <= 0:
				return null
			quantities[item_id] = quantity
		if not state._warehouses[city_id].restore_items(quantities):
			return null
	return state


## For WarehouseService only: the mutable warehouse of a city.
func _warehouse(city_id: String) -> CityWarehouse:
	return _warehouses.get(city_id)


static func _exact_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) \
		and value >= 0.0 and value <= float(CityWarehouse.MAX_ITEM_QUANTITY):
		return int(value)
	return -1
