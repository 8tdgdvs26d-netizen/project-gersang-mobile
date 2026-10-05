class_name RecoveryService
extends RefCounted

## Stage 10 P01 (approved): the Hospital recovery rules, UI-independent.
## It orchestrates the existing authorities and holds no state of its own:
## CharacterCondition (current HP / MP / dead, by stable id; identity and
## the effective maxima through CharacterCarrying) and Wallet (money); the
## caller's `persist` saves (the game: Save v14).
##
## Approved rules (Charlie, Stage 10):
##   - the Hero's recovery is always free ($0), never needs a paid choice,
##     works with $0 and whatever the Mercenaries' state is,
##   - each Mercenary the player chooses costs MERCENARY_PRICE ($100),
##     whatever is missing (1 HP, MP only, dead) and whatever its Level,
##     stats or equipment; nothing is recovered automatically,
##   - a recovered character: HP = current Max HP, MP = current Max MP,
##     dead -> alive. Nothing else changes (no penalty of any kind).
## A character needs recovery when HP < Max HP, MP < Max MP or it is dead.
##
## Two transactions, each all-or-nothing (every check first, then the
## change and one `persist`; a refused or failed one — save failure
## included — restores the wallet and every condition exactly):
##   recover_hero         the Hero alone, free; refused only when it needs
##                        nothing (or the save fails). The anti-soft-lock
##                        path: it never depends on money or Mercenaries.
##   recover              the Hero (free, when it needs it) + the chosen
##                        Mercenaries (paid), saved once. The whole request
##                        is refused when the choice is invalid or
##                        unaffordable — then nothing changes (the Hero
##                        included); recover_hero stays available.

const MERCENARY_PRICE := 100
const HERO_PRICE := 0
const HERO_ID := Mercenary.HERO_ID

const ERR_INVALID_STATE := "ERR_INVALID_STATE"
const ERR_INVALID_REQUEST := "ERR_INVALID_REQUEST"
const ERR_HERO_SELECTED := "ERR_HERO_SELECTED"
const ERR_DUPLICATE := "ERR_DUPLICATE"
const ERR_UNKNOWN_MERCENARY := "ERR_UNKNOWN_MERCENARY"
const ERR_NOT_NEEDED := "ERR_NOT_NEEDED"
const ERR_NOTHING_TO_RECOVER := "ERR_NOTHING_TO_RECOVER"
const ERR_INSUFFICIENT_FUNDS := "ERR_INSUFFICIENT_FUNDS"
const ERR_CHANGE_FAILED := "ERR_CHANGE_FAILED"
const ERR_SAVE_FAILED := "ERR_SAVE_FAILED"


## Whether `state` (CharacterCondition.get_condition) needs recovery.
static func needs_recovery(state: Dictionary) -> bool:
	if state.is_empty():
		return false
	return bool(state["dead"]) or int(state["hp"]) < int(state["max_hp"]) or int(state["mp"]) < int(state["max_mp"])


## One character's recovery entry: {id, hero, needs_recovery, hp, max_hp,
## mp, max_mp, dead, price} — price is HERO_PRICE for the Hero, else
## MERCENARY_PRICE when it needs recovery and 0 when it does not. {} for
## anything that is not the Hero or an owned Mercenary.
static func get_entry(condition: CharacterCondition, id: Variant) -> Dictionary:
	if condition == null:
		return {}
	var state := condition.get_condition(id)
	if state.is_empty():
		return {}
	var needed := needs_recovery(state)
	var hero: bool = id == HERO_ID
	return {
		"id": id,
		"hero": hero,
		"needs_recovery": needed,
		"hp": state["hp"],
		"max_hp": state["max_hp"],
		"mp": state["mp"],
		"max_mp": state["max_mp"],
		"dead": state["dead"],
		"price": HERO_PRICE if hero else (MERCENARY_PRICE if needed else 0),
	}


## What a Hospital shows: {"hero": entry, "mercenaries": [entry, ...]
## (owned roster order), "balance": wallet balance, "mercenary_price"}.
## Reads only; nothing changes.
static func get_status(condition: CharacterCondition, wallet: Wallet) -> Dictionary:
	if condition == null or wallet == null:
		return {}
	var mercenaries := []
	for id in condition.get_character_ids():
		if id != HERO_ID:
			mercenaries.append(get_entry(condition, id))
	return {"hero": get_entry(condition, HERO_ID), "mercenaries": mercenaries, "balance": wallet.get_balance(), "mercenary_price": MERCENARY_PRICE}


## The quote of a request (reads only): {success, reason, mercenary_ids,
## total, affordable, hero_recovered (whether the Hero would be recovered),
## balance}. `success` false with the refusal reason when the request would
## be refused (an unaffordable one: ERR_INSUFFICIENT_FUNDS, `affordable`
## false, `total` still the price of the choice).
static func quote(condition: CharacterCondition, wallet: Wallet, mercenary_ids: Variant) -> Dictionary:
	if condition == null or wallet == null:
		return _result(false, ERR_INVALID_STATE, [], 0, false, false, 0)
	var balance := wallet.get_balance()
	if typeof(mercenary_ids) != TYPE_ARRAY:
		return _result(false, ERR_INVALID_REQUEST, [], 0, false, false, balance)
	var ids: Array = mercenary_ids
	var seen := {}
	for id in ids:
		if typeof(id) != TYPE_STRING:
			return _result(false, ERR_INVALID_REQUEST, ids, 0, false, false, balance)
		if id == HERO_ID:
			return _result(false, ERR_HERO_SELECTED, ids, 0, false, false, balance)
		if seen.has(id):
			return _result(false, ERR_DUPLICATE, ids, 0, false, false, balance)
		seen[id] = true
		var state := condition.get_condition(id)
		if state.is_empty():
			return _result(false, ERR_UNKNOWN_MERCENARY, ids, 0, false, false, balance)
		if not needs_recovery(state):
			return _result(false, ERR_NOT_NEEDED, ids, 0, false, false, balance)
	var total := ids.size() * MERCENARY_PRICE
	var hero := needs_recovery(condition.get_condition(HERO_ID))
	var affordable := total == 0 or wallet.can_spend(total)
	if not affordable:
		return _result(false, ERR_INSUFFICIENT_FUNDS, ids, total, false, hero, balance)
	if ids.is_empty() and not hero:
		return _result(false, ERR_NOTHING_TO_RECOVER, ids, 0, true, false, balance)
	return _result(true, "", ids, total, true, hero, balance)


## The Hero's free recovery alone (never charged, never depends on money or
## Mercenaries). Refused only when it needs nothing or the save fails.
static func recover_hero(condition: CharacterCondition, wallet: Wallet, persist: Callable = Callable()) -> Dictionary:
	if condition == null or wallet == null:
		return _result(false, ERR_INVALID_STATE, [], 0, false, false, 0)
	var balance := wallet.get_balance()
	if not needs_recovery(condition.get_condition(HERO_ID)):
		return _result(false, ERR_NOTHING_TO_RECOVER, [], 0, true, false, balance)
	var snapshot := condition.get_snapshot()
	if not _restore_full(condition, HERO_ID):
		condition.restore_snapshot(snapshot)
		return _result(false, ERR_CHANGE_FAILED, [], 0, true, false, balance)
	if persist.is_valid() and not persist.call():
		condition.restore_snapshot(snapshot)
		_restore_balance(wallet, balance)
		return _result(false, ERR_SAVE_FAILED, [], 0, true, false, balance)
	return _result(true, "", [], 0, true, true, wallet.get_balance())


## The Hero (free, when it needs it) + the chosen Mercenaries (stable ids,
## MERCENARY_PRICE each), as one transaction saved once. Refused as a whole
## (nothing changes) for an invalid / duplicate / healthy / unaffordable
## choice or when nothing needs recovery. {success, reason, mercenary_ids,
## total, affordable, hero_recovered, balance (after)}.
static func recover(condition: CharacterCondition, wallet: Wallet, mercenary_ids: Variant, persist: Callable = Callable()) -> Dictionary:
	var request := quote(condition, wallet, mercenary_ids)
	if not request["success"]:
		return request
	var ids: Array = request["mercenary_ids"]
	var total: int = request["total"]
	var hero: bool = request["hero_recovered"]
	var balance := wallet.get_balance()
	var snapshot := condition.get_snapshot()
	if total > 0 and not wallet.spend(total):
		return _result(false, ERR_INVALID_STATE, ids, total, false, hero, balance)
	var targets := ids.duplicate()
	if hero:
		targets.push_front(HERO_ID)
	for id in targets:
		if not _restore_full(condition, id):
			condition.restore_snapshot(snapshot)
			_restore_balance(wallet, balance)
			return _result(false, ERR_CHANGE_FAILED, ids, total, true, hero, balance)
	if persist.is_valid() and not persist.call():
		condition.restore_snapshot(snapshot)
		_restore_balance(wallet, balance)
		return _result(false, ERR_SAVE_FAILED, ids, total, true, hero, balance)
	return _result(true, "", ids, total, true, hero, wallet.get_balance())


## HP / MP to the current maxima, alive (CharacterCondition clamps to them).
static func _restore_full(condition: CharacterCondition, id: String) -> bool:
	var state := condition.get_condition(id)
	if state.is_empty():
		return false
	return condition.set_condition(id, int(state["max_hp"]), int(state["max_mp"])) and not condition.is_dead(id)


static func _restore_balance(wallet: Wallet, balance: int) -> void:
	var difference := balance - wallet.get_balance()
	if difference > 0:
		wallet.add(difference)


static func _result(success: bool, reason: String, ids: Array, total: int, affordable: bool, hero: bool, balance: int) -> Dictionary:
	return {
		"success": success,
		"reason": reason,
		"mercenary_ids": ids.duplicate(),
		"total": total,
		"affordable": affordable,
		"hero_recovered": hero,
		"balance": balance,
	}
