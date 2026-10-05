class_name EquipmentCatalog
extends RefCounted

## Stage 9 P01: the single data source for equipment definitions (fixed data,
## like GoodsCatalog). Every value below is a PROTOTYPE TEST VALUE approved for
## Stage 9 P01 (Charlie / GPT Brain), not final balance. Display names are
## Traditional Chinese placeholders (測試武器一 …).
##
## An item has an id, a slot (WEAPON / ARMOR — the only two slots), an
## authoritative capacity cost (its weight, counted like any carried item) and
## fixed bonuses: core stats (hp / mp / str / agi / int, CharacterConfig.STATS)
## or the two derived defenses (physical_defense / magic_defense). Armor
## affects only the defenses (Canonical: 防具只影響防禦). Same id = same item:
## no random affix, rarity, durability, enhancement, socket or set.

const SLOT_WEAPON := "WEAPON"
const SLOT_ARMOR := "ARMOR"
const SLOTS := [SLOT_WEAPON, SLOT_ARMOR]
## Bonuses an item may carry: the core stat layers, then the derived defenses.
const CORE_BONUS_STATS := CharacterConfig.STATS
const DERIVED_BONUS_STATS := ["physical_defense", "magic_defense"]
const KEYS := ["id", "display_name", "slot", "capacity_cost", "bonuses"]

const ITEMS := [
	{"id": "test_weapon_01", "display_name": "測試武器一", "slot": SLOT_WEAPON, "capacity_cost": 3, "bonuses": {"str": 2}},
	{"id": "test_weapon_02", "display_name": "測試武器二", "slot": SLOT_WEAPON, "capacity_cost": 2, "bonuses": {"int": 2}},
	{"id": "test_armor_01", "display_name": "測試防具一", "slot": SLOT_ARMOR, "capacity_cost": 4, "bonuses": {"physical_defense": 2}},
	{"id": "test_armor_02", "display_name": "測試防具二", "slot": SLOT_ARMOR, "capacity_cost": 3, "bonuses": {"magic_defense": 2}},
]


static func get_ids() -> Array:
	var ids := []
	for item in ITEMS:
		ids.append(item["id"])
	return ids


static func has_item(item_id: Variant) -> bool:
	return not get_item(item_id).is_empty()


## A deep copy of the item's definition, or {} for an unknown id.
static func get_item(item_id: Variant) -> Dictionary:
	if typeof(item_id) != TYPE_STRING:
		return {}
	for item in ITEMS:
		if item["id"] == item_id:
			return item.duplicate(true)
	return {}


## "" for an unknown item.
static func get_slot(item_id: Variant) -> String:
	return get_item(item_id).get("slot", "")


## The authoritative weight (capacity cost per item), 0 for an unknown item.
static func get_capacity_cost(item_id: Variant) -> int:
	return get_item(item_id).get("capacity_cost", 0)


## {bonus stat: amount} ({} for an unknown item).
static func get_bonuses(item_id: Variant) -> Dictionary:
	return get_item(item_id).get("bonuses", {})


static func is_slot(slot: Variant) -> bool:
	return typeof(slot) == TYPE_STRING and SLOTS.has(slot)


## Whether `item` is a well-formed definition: exactly KEYS, a non-empty id
## that is not a trade good, a known slot, a whole positive cost, at least one
## bonus, every bonus a known stat with a whole amount 1..MAX_STAT; an armor
## carries only the derived defenses.
static func is_valid_definition(item: Variant) -> bool:
	if typeof(item) != TYPE_DICTIONARY or item.size() != KEYS.size() or not item.has_all(KEYS):
		return false
	if typeof(item["id"]) != TYPE_STRING or item["id"] == "" or GoodsCatalog.has_good(item["id"]):
		return false
	if typeof(item["display_name"]) != TYPE_STRING or item["display_name"] == "" or not is_slot(item["slot"]):
		return false
	if typeof(item["capacity_cost"]) != TYPE_INT or item["capacity_cost"] <= 0:
		return false
	var bonuses: Variant = item["bonuses"]
	if typeof(bonuses) != TYPE_DICTIONARY or bonuses.is_empty():
		return false
	for stat in bonuses:
		if not (CORE_BONUS_STATS.has(stat) or DERIVED_BONUS_STATS.has(stat)):
			return false
		if item["slot"] == SLOT_ARMOR and not DERIVED_BONUS_STATS.has(stat):
			return false
		if typeof(bonuses[stat]) != TYPE_INT or bonuses[stat] <= 0 or bonuses[stat] > CharacterConfig.MAX_STAT:
			return false
	return true


## Whether the whole catalog is valid (every definition, unique ids).
static func is_valid_catalog(items: Array = ITEMS) -> bool:
	var seen := {}
	for item in items:
		if not is_valid_definition(item) or seen.has(item["id"]):
			return false
		seen[item["id"]] = true
	return not items.is_empty()
