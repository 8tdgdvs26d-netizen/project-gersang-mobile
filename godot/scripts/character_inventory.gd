class_name CharacterInventory
extends RefCounted

## Per-character inventory model. Every carried item uses the same capacity
## rule, including items that a future Equipment system marks as equipped.
## Capacity cost is authoritative item-definition data: normal callers cannot
## inject a cheaper cost per add/transfer. M2-08 supplies the six test goods
## through GoodsCatalog; the optional resolver is the extension point for
## equipment/material catalogs later.

var character_id: String
var _stats: CharacterStats
var _capacity_cost_resolver: Callable
## item_id -> {"quantity": positive int, "capacity_cost": positive int}
## capacity_cost is captured only from the authoritative resolver/catalog.
var _items := {}


func _init(owner_character_id: String = "player", stats: CharacterStats = null, capacity_cost_resolver: Callable = Callable()) -> void:
	character_id = owner_character_id
	_stats = stats if stats != null else CharacterStats.new()
	_capacity_cost_resolver = capacity_cost_resolver


func get_stats() -> CharacterStats:
	return _stats


func get_quantity(item_id: Variant) -> int:
	return _items.get(item_id, {}).get("quantity", 0) if typeof(item_id) == TYPE_STRING else 0


func get_capacity_cost(item_id: Variant) -> int:
	return _items.get(item_id, {}).get("capacity_cost", _resolve_capacity_cost(item_id)) if typeof(item_id) == TYPE_STRING else 0


func get_used_capacity() -> int:
	var used := 0
	for stack in _items.values():
		used += stack["quantity"] * stack["capacity_cost"]
	return used


func get_max_capacity() -> int:
	return _stats.get_max_capacity()


func get_remaining_capacity() -> int:
	return get_max_capacity() - get_used_capacity()


func is_over_capacity() -> bool:
	return get_used_capacity() > get_max_capacity()


func can_add(item_id: Variant, quantity: Variant) -> bool:
	var cost := _resolve_capacity_cost(item_id)
	if cost <= 0 or not _is_positive_int(quantity) or is_over_capacity():
		return false
	if _items.has(item_id) and _items[item_id]["capacity_cost"] != cost:
		return false
	return quantity <= get_remaining_capacity() / cost


func add(item_id: Variant, quantity: Variant) -> bool:
	var cost := _resolve_capacity_cost(item_id)
	if not can_add(item_id, quantity):
		return false
	_items[item_id] = {"quantity": get_quantity(item_id) + quantity, "capacity_cost": cost}
	return true


func can_remove(item_id: Variant, quantity: Variant) -> bool:
	return typeof(item_id) == TYPE_STRING and _is_positive_int(quantity) and quantity <= get_quantity(item_id)


func remove(item_id: Variant, quantity: Variant) -> bool:
	if not can_remove(item_id, quantity):
		return false
	var left := get_quantity(item_id) - int(quantity)
	if left == 0:
		_items.erase(item_id)
	else:
		_items[item_id]["quantity"] = left
	return true


## Atomic model-level transfer. The destination resolves its own authoritative
## capacity cost; the source/caller cannot smuggle a cheaper cost across.
func transfer_to(destination: CharacterInventory, item_id: Variant, quantity: Variant) -> bool:
	if destination == null or destination == self or not can_remove(item_id, quantity):
		return false
	if not destination.can_add(item_id, quantity):
		return false
	var source_cost := get_capacity_cost(item_id)
	if not remove(item_id, quantity):
		return false
	if destination.add(item_id, quantity):
		return true
	# Defensive rollback for a future destination implementation that changes
	# between can_add and add. This cannot fail because removal freed the space.
	_restore_stack(item_id, quantity, source_cost)
	return false


func is_empty() -> bool:
	return _items.is_empty()


func clear() -> void:
	_items.clear()


## Compatibility view used by the M2-07 market/UI: item_id -> quantity.
func get_items() -> Dictionary:
	var quantities := {}
	for item_id in _items:
		quantities[item_id] = _items[item_id]["quantity"]
	return quantities


func get_stacks() -> Dictionary:
	return _items.duplicate(true)


## Rollback-only snapshot restore. Any supplied capacity cost must still match
## the authoritative resolver/catalog, so this path cannot inject fake weight.
## It preserves a valid over-capacity state without deleting items.
func restore_stacks(stacks: Dictionary) -> bool:
	var restored := {}
	for item_id in stacks:
		if typeof(item_id) != TYPE_STRING or typeof(stacks[item_id]) != TYPE_DICTIONARY:
			return false
		var quantity: Variant = stacks[item_id].get("quantity")
		var supplied_cost: Variant = stacks[item_id].get("capacity_cost")
		var authoritative_cost := _resolve_capacity_cost(item_id)
		if not _is_positive_int(quantity) or not _is_positive_int(supplied_cost) or authoritative_cost <= 0 \
			or int(supplied_cost) != authoritative_cost:
			return false
		restored[item_id] = {"quantity": quantity, "capacity_cost": authoritative_cost}
	_items = restored
	return true


## Persistence-only restore path. Save files store quantities, not balance
## values. Current authoritative item definitions are applied on load. Capacity
## may end up over the current maximum; normal add() then remains blocked.
func restore_items(quantities: Dictionary) -> bool:
	var restored := {}
	for item_id in quantities:
		if typeof(item_id) != TYPE_STRING or item_id == "" or not _is_positive_int(quantities[item_id]):
			return false
		var cost := _resolve_capacity_cost(item_id)
		if cost <= 0:
			return false
		restored[item_id] = {"quantity": quantities[item_id], "capacity_cost": cost}
	_items = restored
	return true


func _resolve_capacity_cost(item_id: Variant) -> int:
	if typeof(item_id) != TYPE_STRING or item_id == "":
		return 0
	if _capacity_cost_resolver.is_valid():
		var value: Variant = _capacity_cost_resolver.call(item_id)
		return value if _is_positive_int(value) else 0
	return GoodsCatalog.get_capacity_cost(item_id)


func _restore_stack(item_id: String, quantity: int, cost: int) -> void:
	_items[item_id] = {"quantity": get_quantity(item_id) + quantity, "capacity_cost": cost}


func _is_positive_int(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and value > 0
