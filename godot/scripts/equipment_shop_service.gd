class_name EquipmentShopService
extends RefCounted

## Stage 9 P02: UI-independent Equipment Shop (裝備商店) purchase — BUY ONLY.
## One purchase = one item (quantity fixed at 1) of an EquipmentCatalog item
## into the chosen character's carried equipment (never equipped, never
## replacing anything, never moved from another character). The receiving
## character is the Hero or an owned Mercenary by its stable id
## (CharacterCarrying.is_character: never pending, dismissed or unknown).
##
## EquipmentCatalog stays authoritative for the item (name, slot, weight,
## bonuses); this service owns only the purchase prices — PROTOTYPE TEST
## VALUES approved for Stage 9 P02, not final balance (no stock, no city or
## dynamic prices, no selling).
##
## A purchase is one transaction (as RecruitmentService): every check runs
## before any change (item, character, money, the character's capacity with
## the item's catalog weight — refused while over capacity); then the money
## is paid, the item added and `persist` saves. If anything after the payment
## fails, the money and every character's carrying are restored exactly: no
## money lost, no item created.

const PRICES := {"test_weapon_01": 300, "test_weapon_02": 300, "test_armor_01": 250, "test_armor_02": 250}
const QUANTITY := 1

const ERR_INVALID_STATE := "ERR_INVALID_STATE"
const ERR_INVALID_REQUEST := "ERR_INVALID_REQUEST"
const ERR_UNKNOWN_EQUIPMENT := "ERR_UNKNOWN_EQUIPMENT"
const ERR_UNKNOWN_CHARACTER := "ERR_UNKNOWN_CHARACTER"
const ERR_INSUFFICIENT_FUNDS := "ERR_INSUFFICIENT_FUNDS"
const ERR_INSUFFICIENT_CAPACITY := "ERR_INSUFFICIENT_CAPACITY"
const ERR_PURCHASE_FAILED := "ERR_PURCHASE_FAILED"
const ERR_SAVE_FAILED := "ERR_SAVE_FAILED"


## The items on sale, in EquipmentCatalog order (every one has a price).
static func get_item_ids() -> Array:
	return EquipmentCatalog.get_ids().filter(func(item_id: String) -> bool: return PRICES.has(item_id))


## The price of `item_id`, 0 when it is not on sale.
static func get_price(item_id: Variant) -> int:
	return int(PRICES.get(item_id, 0)) if typeof(item_id) == TYPE_STRING else 0


## Buys one `item_id` for `character_id`, paid from `wallet`; `persist` saves
## and returns true. {success, reason, character_id, item_id, price}.
static func buy(wallet: Wallet, carrying: CharacterCarrying, character_id: Variant, item_id: Variant, persist: Callable = Callable()) -> Dictionary:
	if wallet == null or carrying == null:
		return _result(false, ERR_INVALID_STATE, character_id, item_id)
	if typeof(character_id) != TYPE_STRING or typeof(item_id) != TYPE_STRING:
		return _result(false, ERR_INVALID_REQUEST, character_id, item_id)
	if not PRICES.has(item_id) or not EquipmentCatalog.has_item(item_id):
		return _result(false, ERR_UNKNOWN_EQUIPMENT, character_id, item_id)
	if not carrying.is_character(character_id):
		return _result(false, ERR_UNKNOWN_CHARACTER, character_id, item_id)
	var price := get_price(item_id)
	if not wallet.can_spend(price):
		return _result(false, ERR_INSUFFICIENT_FUNDS, character_id, item_id)
	if not carrying.can_add_equipment(character_id, item_id, QUANTITY):
		return _result(false, ERR_INSUFFICIENT_CAPACITY, character_id, item_id)
	var balance := wallet.get_balance()
	var snapshot := carrying.get_snapshot()
	if not wallet.spend(price):
		return _result(false, ERR_INVALID_STATE, character_id, item_id)
	if not carrying.add_equipment(character_id, item_id, QUANTITY):
		_rollback(wallet, balance, carrying, snapshot)
		return _result(false, ERR_PURCHASE_FAILED, character_id, item_id)
	if persist.is_valid() and not persist.call():
		_rollback(wallet, balance, carrying, snapshot)
		return _result(false, ERR_SAVE_FAILED, character_id, item_id)
	return _result(true, "", character_id, item_id)


static func _rollback(wallet: Wallet, balance: int, carrying: CharacterCarrying, snapshot: Dictionary) -> void:
	var difference := balance - wallet.get_balance()
	if difference > 0:
		wallet.add(difference)
	carrying.restore_snapshot(snapshot)


static func _result(success: bool, reason: String, character_id: Variant, item_id: Variant) -> Dictionary:
	return {
		"success": success,
		"reason": reason,
		"character_id": character_id if typeof(character_id) == TYPE_STRING else "",
		"item_id": item_id if typeof(item_id) == TYPE_STRING else "",
		"price": get_price(item_id),
	}
