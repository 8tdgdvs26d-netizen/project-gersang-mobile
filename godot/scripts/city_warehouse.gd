class_name CityWarehouse
extends RefCounted

## One city's item warehouse. It stores items only (never money) and is a
## separate container from any CharacterInventory. Capacity uses the same
## units as carrying capacity: quantity x the item's authoritative capacity
## cost from GoodsCatalog; callers can never supply a cost.
##
## A warehouse may end up over capacity if its configured capacity is later
## lowered: stored items are kept, withdrawals stay possible and deposits are
## rejected (the same rule as an over-capacity CharacterInventory).

## Upper bound per stored item; keeps capacity sums far from integer overflow.
const MAX_ITEM_QUANTITY := 1000000000

var city_id: String
var _capacity: int
## item_id -> positive quantity
var _items := {}


func _init(owner_city_id: String = "", capacity: int = 0) -> void:
	city_id = owner_city_id
	_capacity = maxi(capacity, 0)


func get_max_capacity() -> int:
	return _capacity


func get_quantity(item_id: Variant) -> int:
	return _items.get(item_id, 0) if typeof(item_id) == TYPE_STRING else 0


## item_id -> quantity (a copy).
func get_items() -> Dictionary:
	return _items.duplicate()


func get_used_capacity() -> int:
	var used := 0
	for item_id in _items:
		used += _items[item_id] * GoodsCatalog.get_capacity_cost(item_id)
	return used


func get_remaining_capacity() -> int:
	return maxi(_capacity - get_used_capacity(), 0)


func is_over_capacity() -> bool:
	return get_used_capacity() > _capacity


func can_add(item_id: Variant, quantity: Variant) -> bool:
	var cost := GoodsCatalog.get_capacity_cost(item_id)
	if cost <= 0 or not _is_positive_int(quantity) or is_over_capacity():
		return false
	if quantity > MAX_ITEM_QUANTITY - get_quantity(item_id):
		return false
	return quantity <= get_remaining_capacity() / cost


func add(item_id: Variant, quantity: Variant) -> bool:
	if not can_add(item_id, quantity):
		return false
	_items[item_id] = get_quantity(item_id) + quantity
	return true


func can_remove(item_id: Variant, quantity: Variant) -> bool:
	return typeof(item_id) == TYPE_STRING and _is_positive_int(quantity) and quantity <= get_quantity(item_id)


func remove(item_id: Variant, quantity: Variant) -> bool:
	if not can_remove(item_id, quantity):
		return false
	var left: int = get_quantity(item_id) - quantity
	if left == 0:
		_items.erase(item_id)
	else:
		_items[item_id] = left
	return true


## Replaces the contents with validated quantities (load and rollback only).
## Known goods with positive quantities only; capacity is not checked, so a
## valid over-capacity state is preserved without deleting items.
func restore_items(quantities: Variant) -> bool:
	if typeof(quantities) != TYPE_DICTIONARY:
		return false
	var restored := {}
	for item_id in quantities:
		var quantity: Variant = quantities[item_id]
		if not GoodsCatalog.has_good(item_id) or not _is_positive_int(quantity) or quantity > MAX_ITEM_QUANTITY:
			return false
		restored[item_id] = quantity
	_items = restored
	return true


func _is_positive_int(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and value > 0
