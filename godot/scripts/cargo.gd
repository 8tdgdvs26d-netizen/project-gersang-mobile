class_name Cargo
extends RefCounted

## Player cargo data model, independent of any UI. Capacity is measured in
## cargo units: quantity x unit_size, summed across all goods. The prototype
## capacity is a technical value, not a locked formal cargo size.

const CARGO_CAPACITY := 20

## good_id -> positive int quantity. Zero-quantity entries are never kept.
var _items := {}


func get_quantity(good_id: Variant) -> int:
	return _items.get(good_id, 0) if typeof(good_id) == TYPE_STRING else 0


func get_used_capacity() -> int:
	var used := 0
	for good_id in _items:
		used += _items[good_id] * GoodsCatalog.get_unit_size(good_id)
	return used


func get_remaining_capacity() -> int:
	return CARGO_CAPACITY - get_used_capacity()


func can_add(good_id: Variant, quantity: Variant) -> bool:
	if not (GoodsCatalog.has_good(good_id) and _is_positive_int(quantity)):
		return false
	# Checking quantity first also keeps quantity x unit_size from overflowing.
	if quantity > CARGO_CAPACITY:
		return false
	return quantity * GoodsCatalog.get_unit_size(good_id) <= get_remaining_capacity()


func add(good_id: Variant, quantity: Variant) -> bool:
	if not can_add(good_id, quantity):
		return false
	_items[good_id] = get_quantity(good_id) + quantity
	return true


func can_remove(good_id: Variant, quantity: Variant) -> bool:
	return GoodsCatalog.has_good(good_id) and _is_positive_int(quantity) \
		and quantity <= get_quantity(good_id)


func remove(good_id: Variant, quantity: Variant) -> bool:
	if not can_remove(good_id, quantity):
		return false
	var left := get_quantity(good_id) - int(quantity)
	if left == 0:
		_items.erase(good_id)
	else:
		_items[good_id] = left
	return true


func is_empty() -> bool:
	return _items.is_empty()


func clear() -> void:
	_items.clear()


## Returns a copy so callers cannot bypass validation.
func get_items() -> Dictionary:
	return _items.duplicate()


func _is_positive_int(quantity: Variant) -> bool:
	return typeof(quantity) == TYPE_INT and quantity > 0
