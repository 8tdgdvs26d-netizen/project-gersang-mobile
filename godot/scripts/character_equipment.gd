class_name CharacterEquipment
extends RefCounted

## Stage 9 P01: one character's equipment — what it has equipped (0 or 1
## Weapon, 0 or 1 Armor) and the equipment it carries unequipped (item id ->
## quantity; same id = same fixed item, so no per-item instance id). Owned
## by a stable character id (the Hero "hero" or a Mercenary's instance id),
## never by roster position, type or display order.
##
## This object only holds and validates the state; every change that needs a
## capacity or stat decision goes through CharacterCarrying, which keeps the
## operations all-or-nothing.

const SAVE_KEYS := ["equipped", "carried_equipment"]
## Save keys of the two slots (lower case in the file).
const SLOT_SAVE_KEYS := {EquipmentCatalog.SLOT_WEAPON: "weapon", EquipmentCatalog.SLOT_ARMOR: "armor"}
## The most of one item a character may hold (keeps every sum far from int
## overflow; a save beyond it is invalid).
const MAX_QUANTITY := 1000000

var character_id := ""
## slot -> item id ("" = empty).
var _equipped := {EquipmentCatalog.SLOT_WEAPON: "", EquipmentCatalog.SLOT_ARMOR: ""}
## item id -> quantity (> 0).
var _carried := {}


func _init(id: String = "") -> void:
	character_id = id


## The item in `slot` ("" for none or an unknown slot).
func get_equipped(slot: String) -> String:
	return _equipped.get(slot, "")


## {slot: item id} of the occupied slots.
func get_equipped_items() -> Dictionary:
	var items := {}
	for slot in _equipped:
		if _equipped[slot] != "":
			items[slot] = _equipped[slot]
	return items


func get_carried() -> Dictionary:
	return _carried.duplicate()


func get_carried_quantity(item_id: Variant) -> int:
	return int(_carried.get(item_id, 0)) if typeof(item_id) == TYPE_STRING else 0


## How many of `item_id` the character holds in all (carried + equipped).
func get_total_quantity(item_id: Variant) -> int:
	var total := get_carried_quantity(item_id)
	for slot in _equipped:
		if _equipped[slot] == item_id:
			total += 1
	return total


## The weight of every carried and equipped item (EquipmentCatalog costs).
func get_load() -> int:
	var load := 0
	for item_id in _carried:
		load += int(_carried[item_id]) * EquipmentCatalog.get_capacity_cost(item_id)
	for slot in _equipped:
		if _equipped[slot] != "":
			load += EquipmentCatalog.get_capacity_cost(_equipped[slot])
	return load


## The summed bonuses of the equipped items only ({stat: amount}).
func get_bonuses() -> Dictionary:
	var bonuses := {}
	for slot in EquipmentCatalog.SLOTS:
		var item_id: String = _equipped[slot]
		if item_id == "":
			continue
		var item_bonuses := EquipmentCatalog.get_bonuses(item_id)
		for stat in item_bonuses:
			bonuses[stat] = int(bonuses.get(stat, 0)) + int(item_bonuses[stat])
	return bonuses


func is_empty() -> bool:
	return _carried.is_empty() and get_equipped_items().is_empty()


## A deep copy of the whole state (for all-or-nothing rollbacks).
func get_snapshot() -> Dictionary:
	return {"equipped": _equipped.duplicate(), "carried": _carried.duplicate()}


func restore_snapshot(snapshot: Dictionary) -> void:
	_equipped = (snapshot["equipped"] as Dictionary).duplicate()
	_carried = (snapshot["carried"] as Dictionary).duplicate()


# --- Raw changes (CharacterCarrying checks capacity, stats and atomicity) ---

func _add_carried(item_id: String, quantity: int) -> void:
	_carried[item_id] = get_carried_quantity(item_id) + quantity


func _remove_carried(item_id: String, quantity: int) -> void:
	var left := get_carried_quantity(item_id) - quantity
	if left <= 0:
		_carried.erase(item_id)
	else:
		_carried[item_id] = left


func _set_equipped(slot: String, item_id: String) -> void:
	_equipped[slot] = item_id


# --- Save v13 ---------------------------------------------------------------

## {"equipped": {"weapon": id or null, "armor": id or null},
##  "carried_equipment": {id: quantity}}
func to_save() -> Dictionary:
	var equipped := {}
	for slot in EquipmentCatalog.SLOTS:
		equipped[SLOT_SAVE_KEYS[slot]] = _equipped[slot] if _equipped[slot] != "" else null
	return {"equipped": equipped, "carried_equipment": _carried.duplicate()}


## A character's equipment from its saved entry (the SAVE_KEYS part), or null
## when anything is malformed: exactly the keys, both slots present, each
## null or a known item of that slot, every carried id known with a whole
## quantity 1..MAX_QUANTITY (JSON whole floats accepted). Nothing is repaired.
static func from_save(id: String, data: Variant) -> CharacterEquipment:
	if typeof(data) != TYPE_DICTIONARY or data.size() != SAVE_KEYS.size() or not data.has_all(SAVE_KEYS):
		return null
	var equipped: Variant = data["equipped"]
	var carried: Variant = data["carried_equipment"]
	if typeof(equipped) != TYPE_DICTIONARY or equipped.size() != SLOT_SAVE_KEYS.size() or typeof(carried) != TYPE_DICTIONARY:
		return null
	var equipment := CharacterEquipment.new(id)
	for slot in EquipmentCatalog.SLOTS:
		var key: String = SLOT_SAVE_KEYS[slot]
		if not equipped.has(key):
			return null
		var item_id: Variant = equipped[key]
		if item_id == null:
			continue
		if typeof(item_id) != TYPE_STRING or EquipmentCatalog.get_slot(item_id) != slot:
			return null
		equipment._equipped[slot] = item_id
	for item_id in carried:
		if typeof(item_id) != TYPE_STRING or not EquipmentCatalog.has_item(item_id):
			return null
		var quantity := _whole(carried[item_id])
		if quantity <= 0 or quantity > MAX_QUANTITY:
			return null
		equipment._carried[item_id] = quantity
	return equipment


## A whole number >= 0 (int, or a whole JSON float), else -1.
static func _whole(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return value if value >= 0 else -1
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) and value >= 0.0 and value <= float(MAX_QUANTITY):
		return int(value)
	return -1
