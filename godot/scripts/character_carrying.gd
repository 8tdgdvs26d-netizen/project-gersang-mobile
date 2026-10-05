class_name CharacterCarrying
extends RefCounted

## Stage 9 P01: what every character carries — the Hero and each owned
## Mercenary, keyed by stable character id ("hero" or the instance id; never
## roster position, type or display order). Per character:
##   - its own CharacterInventory (goods; the Hero's is the existing backpack
##     with the trade cost ledger; a Mercenary's is created here, bound to its
##     id, on its own stats),
##   - its CharacterEquipment (equipped Weapon / Armor + carried equipment).
## One Capacity per character (10 + Effective STR x 9, its own stats with its
## equipment bonuses) covers goods + carried + equipped equipment.
##
## Every operation is all-or-nothing: on any refusal nothing changes (no
## duplicate, no loss, no partial bonus or capacity). Over capacity is a legal
## state — nothing is ever deleted or moved away — but it refuses any new
## load until the character is back within its Capacity. Equip / unequip move
## an item between the character's own bag and slot: its load is unchanged,
## so they work over capacity too (unequipping STR gear may lower Capacity
## below the load: legal).
##
## Implementation gap (P01, not a design rule): no flow puts goods into a
## Mercenary's inventory yet (no Mercenary goods transfer, market or
## warehouse flow), and a Mercenary's goods are saved but must be empty —
## their acquisition costs would need the trade cost ledger, which P01 does
## not change. Mercenaries can still carry goods by design.

const HERO_ID := Mercenary.HERO_ID
## Save v13 `carrying` entry keys: the Hero's goods stay in `character`
## (with the cost ledger); a Mercenary's entry adds its goods.
const HERO_SAVE_KEYS := CharacterEquipment.SAVE_KEYS
const MERCENARY_SAVE_KEYS := ["equipped", "carried_equipment", "goods"]

var _hero_inventory: CharacterInventory
var _hero_stats: CharacterStats
## Returns the current MercenaryRoster (main's may be replaced).
var _roster_provider: Callable
## character id -> CharacterEquipment
var _equipment := {}
## Mercenary id -> CharacterInventory
var _mercenary_inventories := {}


func _init(hero_inventory: CharacterInventory = null, roster_provider: Callable = Callable()) -> void:
	_roster_provider = roster_provider
	bind_hero(hero_inventory if hero_inventory != null else CharacterInventory.new(HERO_ID))


## Uses `inventory` (and its stats) as the Hero's backpack; the Hero's
## equipment load and bonuses are applied to them at once.
func bind_hero(inventory: CharacterInventory) -> void:
	_hero_inventory = inventory
	_hero_stats = inventory.get_stats()
	_hero_inventory.set_extra_load_provider(_equipment_load.bind(HERO_ID))
	_apply_hero_bonuses()


func set_roster_provider(provider: Callable) -> void:
	_roster_provider = provider


func get_roster() -> MercenaryRoster:
	var roster: Variant = _roster_provider.call() if _roster_provider.is_valid() else null
	return roster if roster is MercenaryRoster else null


## The Hero or an owned Mercenary (never a pending or unknown one).
func is_character(id: Variant) -> bool:
	if typeof(id) != TYPE_STRING:
		return false
	if id == HERO_ID:
		return true
	var roster := get_roster()
	return roster != null and roster.get_mercenary(id) != null


## The character's equipment (created empty on first use), or null for
## anything that is not the Hero or an owned Mercenary.
func get_equipment(id: Variant) -> CharacterEquipment:
	if not is_character(id):
		return null
	if not _equipment.has(id):
		_equipment[id] = CharacterEquipment.new(id)
	return _equipment[id]


## The character's goods inventory on its current stats, or null.
func get_inventory(id: Variant) -> CharacterInventory:
	if not is_character(id):
		return null
	if id == HERO_ID:
		return _hero_inventory
	if not _mercenary_inventories.has(id):
		var inventory := CharacterInventory.new(id, get_stats(id))
		inventory.set_extra_load_provider(_equipment_load.bind(id))
		_mercenary_inventories[id] = inventory
	var mercenary_inventory: CharacterInventory = _mercenary_inventories[id]
	mercenary_inventory.set_stats(get_stats(id))
	return mercenary_inventory


## The character's stats with its equipment bonuses: the Hero's own
## (bonuses kept applied); a Mercenary's rebuilt from its instance (Level,
## allocation) on every call, plus its equipment. Null for a non-character.
func get_stats(id: Variant) -> CharacterStats:
	if not is_character(id):
		return null
	if id == HERO_ID:
		return _hero_stats
	var stats := CharacterStats.for_mercenary(get_roster().get_mercenary(id))
	if stats == null or not stats.apply_equipment_bonuses(get_equipment(id).get_bonuses()):
		return null
	return stats


## Goods + carried + equipped equipment (-1 for a non-character).
func get_load(id: Variant) -> int:
	var inventory := get_inventory(id)
	return inventory.get_used_capacity() if inventory != null else -1


func get_capacity(id: Variant) -> int:
	var stats := get_stats(id)
	return stats.get_max_capacity() if stats != null else -1


func is_over_capacity(id: Variant) -> bool:
	return is_character(id) and get_load(id) > get_capacity(id)


## Whether the character holds anything at all (goods, carried or equipped
## equipment) — a Mercenary holding anything cannot be dismissed.
func has_any_items(id: Variant) -> bool:
	if not is_character(id):
		return false
	return not get_equipment(id).is_empty() or not get_inventory(id).is_empty()


# --- Operations (all-or-nothing) -------------------------------------------

## Adds `quantity` x `item_id` to the character's carried equipment. Refused
## for an unknown character / item, a quantity that is not a whole number
## 1..MAX_QUANTITY (in all), an over-capacity character or a load beyond its
## Capacity (the item's authoritative weight; callers never give one).
func add_equipment(id: Variant, item_id: Variant, quantity: Variant) -> bool:
	if not _can_take(id, item_id, quantity):
		return false
	get_equipment(id)._add_carried(item_id, quantity)
	return true


## Removes `quantity` x `item_id` from the character's carried (not equipped)
## equipment. Refused when it does not carry that many.
func remove_equipment(id: Variant, item_id: Variant, quantity: Variant) -> bool:
	var equipment := get_equipment(id)
	if equipment == null or typeof(item_id) != TYPE_STRING or not _is_positive_int(quantity) or quantity > equipment.get_carried_quantity(item_id):
		return false
	equipment._remove_carried(item_id, quantity)
	return true


## Equips one carried `item_id` in its slot; an item already there goes back
## to the carried equipment (a swap). Load unchanged: allowed over capacity.
func equip(id: Variant, item_id: Variant) -> bool:
	var equipment := get_equipment(id)
	if equipment == null or typeof(item_id) != TYPE_STRING or equipment.get_carried_quantity(item_id) <= 0:
		return false
	var slot := EquipmentCatalog.get_slot(item_id)
	if not EquipmentCatalog.is_slot(slot):
		return false
	var snapshot := equipment.get_snapshot()
	var previous := equipment.get_equipped(slot)
	equipment._remove_carried(item_id, 1)
	if previous != "":
		equipment._add_carried(previous, 1)
	equipment._set_equipped(slot, item_id)
	if not _apply_bonuses(id):
		equipment.restore_snapshot(snapshot)
		_apply_bonuses(id)
		return false
	return true


## Takes the item out of `slot` into the carried equipment. Load unchanged:
## allowed over capacity (and may leave the character over capacity).
func unequip(id: Variant, slot: Variant) -> bool:
	var equipment := get_equipment(id)
	if equipment == null or not EquipmentCatalog.is_slot(slot) or equipment.get_equipped(slot) == "":
		return false
	var snapshot := equipment.get_snapshot()
	equipment._add_carried(equipment.get_equipped(slot), 1)
	equipment._set_equipped(slot, "")
	if not _apply_bonuses(id):
		equipment.restore_snapshot(snapshot)
		_apply_bonuses(id)
		return false
	return true


## Moves `quantity` carried `item_id` from one character to another. Refused
## when the source does not carry that many, or the destination may not take
## them (over capacity, beyond its Capacity) — then nothing moves.
func transfer_equipment(from_id: Variant, to_id: Variant, item_id: Variant, quantity: Variant) -> bool:
	if from_id == to_id:
		return false
	var source := get_equipment(from_id)
	if source == null or typeof(item_id) != TYPE_STRING or not _is_positive_int(quantity) or quantity > source.get_carried_quantity(item_id):
		return false
	if not _can_take(to_id, item_id, quantity):
		return false
	source._remove_carried(item_id, quantity)
	get_equipment(to_id)._add_carried(item_id, quantity)
	return true


## Stage 8 dismissal: forgets a character that no longer exists (only when
## it held nothing; refused otherwise).
func forget(id: Variant) -> bool:
	if typeof(id) != TYPE_STRING or id == HERO_ID:
		return false
	if _equipment.has(id) and not (_equipment[id] as CharacterEquipment).is_empty():
		return false
	if _mercenary_inventories.has(id) and not (_mercenary_inventories[id] as CharacterInventory).is_empty():
		return false
	_equipment.erase(id)
	_mercenary_inventories.erase(id)
	return true


## Whether some state belongs to a character that is not the Hero or an
## owned Mercenary (it would be lost by a save: saving refuses it).
func has_orphans() -> bool:
	for id in _equipment:
		if not is_character(id) and not (_equipment[id] as CharacterEquipment).is_empty():
			return true
	for id in _mercenary_inventories:
		if not is_character(id) and not (_mercenary_inventories[id] as CharacterInventory).is_empty():
			return true
	return false


# --- Snapshot (rollback) ----------------------------------------------------

func get_snapshot() -> Dictionary:
	var equipment := {}
	for id in _equipment:
		equipment[id] = (_equipment[id] as CharacterEquipment).get_snapshot()
	var goods := {}
	for id in _mercenary_inventories:
		goods[id] = (_mercenary_inventories[id] as CharacterInventory).get_stacks()
	return {"equipment": equipment, "goods": goods}


func restore_snapshot(snapshot: Dictionary) -> void:
	_equipment.clear()
	for id in snapshot["equipment"]:
		var equipment := CharacterEquipment.new(id)
		equipment.restore_snapshot(snapshot["equipment"][id])
		_equipment[id] = equipment
	for id in _mercenary_inventories.keys():
		if not snapshot["goods"].has(id):
			_mercenary_inventories.erase(id)
	for id in snapshot["goods"]:
		if _mercenary_inventories.has(id):
			(_mercenary_inventories[id] as CharacterInventory).restore_stacks(snapshot["goods"][id])
	_apply_hero_bonuses()


# --- Save v13 ---------------------------------------------------------------

## {"hero": {equipped, carried_equipment}, "<mercenary id>": {equipped,
## carried_equipment, goods}} for the Hero and every owned Mercenary (in
## roster order); the Hero's goods are saved in `character` as before.
func to_save() -> Dictionary:
	var data := {HERO_ID: get_equipment(HERO_ID).to_save()}
	var roster := get_roster()
	if roster != null:
		for mercenary in roster.get_owned():
			var entry := get_equipment(mercenary.get_id()).to_save()
			var goods := {}
			var inventory := get_inventory(mercenary.get_id())
			for item_id in inventory.get_items():
				goods[item_id] = {"quantity": inventory.get_quantity(item_id)}
			entry["goods"] = goods
			data[mercenary.get_id()] = entry
	return data


## A validated {id: {"equipment": CharacterEquipment, "goods": {}}} from a
## saved `carrying` section, or {} when anything is malformed: exactly the
## Hero + every owned Mercenary of `roster` (no pending, no unknown id), each
## entry valid (CharacterEquipment.from_save), a Mercenary's goods {} (P01
## implementation gap: the cost ledger does not cover Mercenary goods yet).
## Nothing is repaired.
static func parse_save(data: Variant, roster: MercenaryRoster) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY or roster == null:
		return {}
	var ids := [HERO_ID]
	for mercenary in roster.get_owned():
		ids.append(mercenary.get_id())
	if data.size() != ids.size():
		return {}
	var parsed := {}
	for id in ids:
		if not data.has(id) or typeof(data[id]) != TYPE_DICTIONARY:
			return {}
		var entry: Dictionary = data[id]
		var keys: Array = HERO_SAVE_KEYS if id == HERO_ID else MERCENARY_SAVE_KEYS
		if entry.size() != keys.size() or not entry.has_all(keys):
			return {}
		var part := {}
		for key in HERO_SAVE_KEYS:
			part[key] = entry[key]
		var equipment := CharacterEquipment.from_save(id, part)
		if equipment == null:
			return {}
		if id != HERO_ID and (typeof(entry["goods"]) != TYPE_DICTIONARY or not (entry["goods"] as Dictionary).is_empty()):
			return {}
		parsed[id] = {"equipment": equipment}
	return parsed


## Replaces every character's equipment with a parse_save() result.
func restore_save(parsed: Dictionary) -> void:
	_equipment.clear()
	_mercenary_inventories.clear()
	for id in parsed:
		_equipment[id] = parsed[id]["equipment"]
	_apply_hero_bonuses()


# --- Internals --------------------------------------------------------------

func _can_take(id: Variant, item_id: Variant, quantity: Variant) -> bool:
	var equipment := get_equipment(id)
	if equipment == null or not EquipmentCatalog.has_item(item_id) or not _is_positive_int(quantity):
		return false
	if quantity > CharacterEquipment.MAX_QUANTITY - equipment.get_total_quantity(item_id):
		return false
	var inventory := get_inventory(id)
	if inventory.is_over_capacity():
		return false
	return quantity <= inventory.get_remaining_capacity() / EquipmentCatalog.get_capacity_cost(item_id)


func _equipment_load(id: String) -> int:
	return (_equipment[id] as CharacterEquipment).get_load() if _equipment.has(id) else 0


## The Hero's bonuses live on its stats object; a Mercenary's are rebuilt
## on every get_stats(), so only their validity is checked.
func _apply_bonuses(id: String) -> bool:
	if id == HERO_ID:
		return _apply_hero_bonuses()
	return get_stats(id) != null


func _apply_hero_bonuses() -> bool:
	var bonuses: Dictionary = (_equipment[HERO_ID] as CharacterEquipment).get_bonuses() if _equipment.has(HERO_ID) else {}
	return _hero_stats.apply_equipment_bonuses(bonuses)


func _is_positive_int(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and value > 0
