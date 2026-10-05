class_name EquipmentTransferService
extends RefCounted

## Stage 9 P05 (approved, iPhone acceptance): moves ONE unequipped carried
## equipment item from one character to another — the Hero <-> an owned
## Mercenary, or Mercenary <-> Mercenary — by stable id (never a pending,
## dismissed or unknown id, never a fallback to the Hero). It is the P01
## move CharacterCarrying.transfer_equipment, the one equipment model:
##   - only a carried (unequipped) item moves; an equipped one must be
##     unequipped first (EquipmentService.unequip),
##   - the destination must take its authoritative weight under its own
##     Capacity (CharacterCarrying.can_add_equipment, the existing rules),
##   - the item arrives carried, never equipped; bonuses stay with whoever
##     has the item equipped.
## Equipment only: goods / cargo never move here.
##
## One transaction (as EquipmentService): every check first, then the move
## and `persist`; a refused or failed transfer (save failure included)
## restores every character's carrying exactly.

const ERR_INVALID_STATE := "ERR_INVALID_STATE"
const ERR_INVALID_REQUEST := "ERR_INVALID_REQUEST"
const ERR_UNKNOWN_CHARACTER := "ERR_UNKNOWN_CHARACTER"
const ERR_UNKNOWN_DESTINATION := "ERR_UNKNOWN_DESTINATION"
const ERR_SAME_CHARACTER := "ERR_SAME_CHARACTER"
const ERR_UNKNOWN_EQUIPMENT := "ERR_UNKNOWN_EQUIPMENT"
const ERR_EQUIPPED := "ERR_EQUIPPED"
const ERR_NOT_CARRIED := "ERR_NOT_CARRIED"
const ERR_OVER_CAPACITY := "ERR_OVER_CAPACITY"
const ERR_CHANGE_FAILED := "ERR_CHANGE_FAILED"
const ERR_SAVE_FAILED := "ERR_SAVE_FAILED"


## Moves one carried `item_id` of `from_id` into `to_id`'s carried
## equipment, then saves. {success, reason, from_id, to_id, item_id}.
static func transfer(carrying: CharacterCarrying, from_id: Variant, to_id: Variant, item_id: Variant, persist: Callable = Callable()) -> Dictionary:
	if carrying == null:
		return _result(false, ERR_INVALID_STATE, from_id, to_id, item_id)
	if typeof(from_id) != TYPE_STRING or typeof(to_id) != TYPE_STRING or typeof(item_id) != TYPE_STRING:
		return _result(false, ERR_INVALID_REQUEST, from_id, to_id, item_id)
	if not carrying.is_character(from_id):
		return _result(false, ERR_UNKNOWN_CHARACTER, from_id, to_id, item_id)
	if not carrying.is_character(to_id):
		return _result(false, ERR_UNKNOWN_DESTINATION, from_id, to_id, item_id)
	if from_id == to_id:
		return _result(false, ERR_SAME_CHARACTER, from_id, to_id, item_id)
	if not EquipmentCatalog.has_item(item_id):
		return _result(false, ERR_UNKNOWN_EQUIPMENT, from_id, to_id, item_id)
	var source := carrying.get_equipment(from_id)
	if source.get_carried_quantity(item_id) <= 0:
		var equipped := source.get_total_quantity(item_id) > 0
		return _result(false, ERR_EQUIPPED if equipped else ERR_NOT_CARRIED, from_id, to_id, item_id)
	if not carrying.can_add_equipment(to_id, item_id, 1):
		return _result(false, ERR_OVER_CAPACITY, from_id, to_id, item_id)
	var snapshot := carrying.get_snapshot()
	if not carrying.transfer_equipment(from_id, to_id, item_id, 1):
		carrying.restore_snapshot(snapshot)
		return _result(false, ERR_CHANGE_FAILED, from_id, to_id, item_id)
	if persist.is_valid() and not persist.call():
		carrying.restore_snapshot(snapshot)
		return _result(false, ERR_SAVE_FAILED, from_id, to_id, item_id)
	return _result(true, "", from_id, to_id, item_id)


static func _result(success: bool, reason: String, from_id: Variant, to_id: Variant, item_id: Variant) -> Dictionary:
	return {
		"success": success,
		"reason": reason,
		"from_id": from_id if typeof(from_id) == TYPE_STRING else "",
		"to_id": to_id if typeof(to_id) == TYPE_STRING else "",
		"item_id": item_id if typeof(item_id) == TYPE_STRING else "",
	}
