class_name WarehouseService
extends RefCounted

## UI-independent transfers between the character's inventory and the
## warehouse of the city the character is currently inside:
##
##   Market <-> CharacterInventory <-> Warehouse
##
## The market never touches a warehouse, and this service never touches the
## wallet, market or journey. Deposit and withdraw are free. Remote cities'
## warehouses cannot be changed. Every check runs before any state changes;
## a transfer either fully succeeds (and is saved) or changes nothing.

const ERR_INVALID_STATE := "ERR_INVALID_STATE"
const ERR_DUPLICATE_REQUEST := "ERR_DUPLICATE_REQUEST"
const ERR_NOT_IN_CITY := "ERR_NOT_IN_CITY"
const ERR_WRONG_CITY := "ERR_WRONG_CITY"
const ERR_INVALID_QUANTITY := "ERR_INVALID_QUANTITY"
const ERR_UNKNOWN_ITEM := "ERR_UNKNOWN_ITEM"
const ERR_INSUFFICIENT_CARRIED := "ERR_INSUFFICIENT_CARRIED"
const ERR_INSUFFICIENT_STORED := "ERR_INSUFFICIENT_STORED"
const ERR_WAREHOUSE_CAPACITY := "ERR_WAREHOUSE_CAPACITY"
const ERR_CARRY_CAPACITY := "ERR_CARRY_CAPACITY"
const ERR_TRANSFER_FAILED := "ERR_TRANSFER_FAILED"
const ERR_SAVE_FAILED := "ERR_SAVE_FAILED"


## Moves `quantity` of an item from the inventory into the current city's
## warehouse. `persist` saves the new state; if it fails, both sides roll back.
static func deposit(location: PlayerLocation, inventory: CharacterInventory, warehouses: WarehouseState, city_id: Variant, item_id: Variant, quantity: Variant, request_id: String = "", persist: Callable = Callable()) -> Dictionary:
	var reason := _common_error(location, inventory, warehouses, city_id, item_id, quantity, request_id)
	if reason != "":
		return _result(false, reason)
	var warehouse := warehouses._warehouse(city_id)
	if not inventory.can_remove(item_id, quantity):
		return _result(false, ERR_INSUFFICIENT_CARRIED)
	if not warehouse.can_add(item_id, quantity):
		return _result(false, ERR_WAREHOUSE_CAPACITY)
	var inventory_before := inventory.get_stacks()
	var warehouse_before := warehouse.get_items()
	if not inventory.remove(item_id, quantity) or not warehouse.add(item_id, quantity):
		_rollback(inventory, inventory_before, warehouse, warehouse_before)
		return _result(false, ERR_TRANSFER_FAILED)
	return _finish(inventory, inventory_before, warehouses, warehouse, warehouse_before, request_id, quantity, persist)


## Moves `quantity` of an item from the current city's warehouse into the
## inventory, subject to the inventory's own capacity rules (an over-capacity
## inventory accepts nothing).
static func withdraw(location: PlayerLocation, inventory: CharacterInventory, warehouses: WarehouseState, city_id: Variant, item_id: Variant, quantity: Variant, request_id: String = "", persist: Callable = Callable()) -> Dictionary:
	var reason := _common_error(location, inventory, warehouses, city_id, item_id, quantity, request_id)
	if reason != "":
		return _result(false, reason)
	var warehouse := warehouses._warehouse(city_id)
	if not warehouse.can_remove(item_id, quantity):
		return _result(false, ERR_INSUFFICIENT_STORED)
	if not inventory.can_add(item_id, quantity):
		return _result(false, ERR_CARRY_CAPACITY)
	var inventory_before := inventory.get_stacks()
	var warehouse_before := warehouse.get_items()
	if not warehouse.remove(item_id, quantity) or not inventory.add(item_id, quantity):
		_rollback(inventory, inventory_before, warehouse, warehouse_before)
		return _result(false, ERR_TRANSFER_FAILED)
	return _finish(inventory, inventory_before, warehouses, warehouse, warehouse_before, request_id, quantity, persist)


static func _common_error(location: PlayerLocation, inventory: CharacterInventory, warehouses: WarehouseState, city_id: Variant, item_id: Variant, quantity: Variant, request_id: String) -> String:
	if location == null or inventory == null or warehouses == null:
		return ERR_INVALID_STATE
	if request_id != "" and request_id == warehouses.last_request_id:
		return ERR_DUPLICATE_REQUEST
	if not location.is_in_city():
		return ERR_NOT_IN_CITY
	if typeof(city_id) != TYPE_STRING or city_id != location.get_city_id() or not warehouses.has_city(city_id):
		return ERR_WRONG_CITY
	if typeof(quantity) != TYPE_INT or quantity <= 0:
		return ERR_INVALID_QUANTITY
	if not GoodsCatalog.has_good(item_id):
		return ERR_UNKNOWN_ITEM
	return ""


static func _finish(inventory: CharacterInventory, inventory_before: Dictionary, warehouses: WarehouseState, warehouse: CityWarehouse, warehouse_before: Dictionary, request_id: String, quantity: int, persist: Callable) -> Dictionary:
	if persist.is_valid() and not persist.call():
		_rollback(inventory, inventory_before, warehouse, warehouse_before)
		return _result(false, ERR_SAVE_FAILED)
	if request_id != "":
		warehouses.last_request_id = request_id
	return _result(true, "", {"quantity": quantity})


static func _rollback(inventory: CharacterInventory, inventory_before: Dictionary, warehouse: CityWarehouse, warehouse_before: Dictionary) -> void:
	inventory.restore_stacks(inventory_before)
	warehouse.restore_items(warehouse_before)


static func _result(success: bool, reason: String, extra: Dictionary = {}) -> Dictionary:
	var result := {"success": success, "reason": reason}
	result.merge(extra)
	return result
