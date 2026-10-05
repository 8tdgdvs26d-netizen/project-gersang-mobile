class_name EquipmentService
extends RefCounted

## Stage 9 P03: UI-independent Equip / Unequip for one character (the Hero
## or an owned Mercenary by stable id; never pending, dismissed or unknown,
## never a fallback to the Hero). Both move one item inside the SAME
## character's load (CharacterCarrying.equip / unequip, the P01 semantics):
##   equip    carried item -> its EquipmentCatalog slot; an item already
##            there goes back to the carried equipment (a swap)
##   unequip  equipped item -> carried equipment
## Never between characters, never sold, deleted or stored elsewhere; the
## load is unchanged (allowed over capacity, P01).
##
## One transaction each (as EquipmentShopService): every check first, then
## the change and `persist`; a refused or failed change (save failure
## included) restores every character's carrying exactly (bonuses too).

const ERR_INVALID_STATE := "ERR_INVALID_STATE"
const ERR_INVALID_REQUEST := "ERR_INVALID_REQUEST"
const ERR_UNKNOWN_CHARACTER := "ERR_UNKNOWN_CHARACTER"
const ERR_UNKNOWN_EQUIPMENT := "ERR_UNKNOWN_EQUIPMENT"
const ERR_WRONG_SLOT := "ERR_WRONG_SLOT"
const ERR_NOT_CARRIED := "ERR_NOT_CARRIED"
const ERR_INVALID_SLOT := "ERR_INVALID_SLOT"
const ERR_SLOT_EMPTY := "ERR_SLOT_EMPTY"
const ERR_CHANGE_FAILED := "ERR_CHANGE_FAILED"
const ERR_SAVE_FAILED := "ERR_SAVE_FAILED"


## Equips one carried `item_id` of `character_id` (into its catalog slot;
## `slot`, when given, must be that slot). {success, reason, character_id,
## item_id, slot, replaced} (`replaced`: the item swapped back, or "").
static func equip(carrying: CharacterCarrying, character_id: Variant, item_id: Variant, persist: Callable = Callable(), slot: Variant = "") -> Dictionary:
	if carrying == null:
		return _result(false, ERR_INVALID_STATE, character_id, item_id, "", "")
	if typeof(character_id) != TYPE_STRING or typeof(item_id) != TYPE_STRING or typeof(slot) != TYPE_STRING:
		return _result(false, ERR_INVALID_REQUEST, character_id, item_id, "", "")
	if not carrying.is_character(character_id):
		return _result(false, ERR_UNKNOWN_CHARACTER, character_id, item_id, "", "")
	if not EquipmentCatalog.has_item(item_id):
		return _result(false, ERR_UNKNOWN_EQUIPMENT, character_id, item_id, "", "")
	var item_slot := EquipmentCatalog.get_slot(item_id)
	if slot != "" and slot != item_slot:
		return _result(false, ERR_WRONG_SLOT, character_id, item_id, slot, "")
	var equipment := carrying.get_equipment(character_id)
	if equipment.get_carried_quantity(item_id) <= 0:
		return _result(false, ERR_NOT_CARRIED, character_id, item_id, item_slot, "")
	var replaced := equipment.get_equipped(item_slot)
	var snapshot := carrying.get_snapshot()
	if not carrying.equip(character_id, item_id):
		carrying.restore_snapshot(snapshot)
		return _result(false, ERR_CHANGE_FAILED, character_id, item_id, item_slot, "")
	if persist.is_valid() and not persist.call():
		carrying.restore_snapshot(snapshot)
		return _result(false, ERR_SAVE_FAILED, character_id, item_id, item_slot, "")
	return _result(true, "", character_id, item_id, item_slot, replaced)


## Unequips `slot` of `character_id` into its carried equipment.
## {success, reason, character_id, item_id, slot, replaced: ""}.
static func unequip(carrying: CharacterCarrying, character_id: Variant, slot: Variant, persist: Callable = Callable()) -> Dictionary:
	if carrying == null:
		return _result(false, ERR_INVALID_STATE, character_id, "", "", "")
	if typeof(character_id) != TYPE_STRING or typeof(slot) != TYPE_STRING:
		return _result(false, ERR_INVALID_REQUEST, character_id, "", "", "")
	if not carrying.is_character(character_id):
		return _result(false, ERR_UNKNOWN_CHARACTER, character_id, "", slot, "")
	if not EquipmentCatalog.is_slot(slot):
		return _result(false, ERR_INVALID_SLOT, character_id, "", slot, "")
	var item_id := carrying.get_equipment(character_id).get_equipped(slot)
	if item_id == "":
		return _result(false, ERR_SLOT_EMPTY, character_id, "", slot, "")
	var snapshot := carrying.get_snapshot()
	if not carrying.unequip(character_id, slot):
		carrying.restore_snapshot(snapshot)
		return _result(false, ERR_CHANGE_FAILED, character_id, item_id, slot, "")
	if persist.is_valid() and not persist.call():
		carrying.restore_snapshot(snapshot)
		return _result(false, ERR_SAVE_FAILED, character_id, item_id, slot, "")
	return _result(true, "", character_id, item_id, slot, "")


static func _result(success: bool, reason: String, character_id: Variant, item_id: Variant, slot: Variant, replaced: String) -> Dictionary:
	return {
		"success": success,
		"reason": reason,
		"character_id": character_id if typeof(character_id) == TYPE_STRING else "",
		"item_id": item_id if typeof(item_id) == TYPE_STRING else "",
		"slot": slot if typeof(slot) == TYPE_STRING else "",
		"replaced": replaced,
	}
