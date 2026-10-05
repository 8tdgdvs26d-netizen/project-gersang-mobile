class_name PartyService
extends RefCounted

## Stage 8 P03: UI-independent party management at the Mercenary Center:
## deploy / undeploy an owned Mercenary (at most MercenaryRoster.MAX_DEPLOYED,
## the Hero always fights and takes no slot) and dismiss one. Approved rules:
## deployment only decides WHO fights (no positions or formation); dismissal is
## permanent, gives no refund, and a deployed Mercenary must be undeployed
## first (never both in one action). Its id is retired for good.
##
## Each change is one transaction, as RecruitmentService: every check runs
## before any change; the roster is changed, then `persist` saves; if the save
## fails the whole roster is restored from its snapshot (instances, deployment,
## next_serial, retired ids). Money is never touched here.

const ERR_INVALID_STATE := "ERR_INVALID_STATE"
const ERR_UNKNOWN_MERCENARY := "ERR_UNKNOWN_MERCENARY"
const ERR_ALREADY_DEPLOYED := "ERR_ALREADY_DEPLOYED"
const ERR_NOT_DEPLOYED := "ERR_NOT_DEPLOYED"
const ERR_DEPLOY_FULL := "ERR_DEPLOY_FULL"
const ERR_DEPLOYED := "ERR_DEPLOYED"
const ERR_CHANGE_FAILED := "ERR_CHANGE_FAILED"
const ERR_SAVE_FAILED := "ERR_SAVE_FAILED"
## Stage 8 P05: claiming a pending legacy Mercenary needs a free place.
const ERR_ROSTER_FULL := "ERR_ROSTER_FULL"
## Stage 9 P01: the Mercenary still holds goods or equipment (carried or
## equipped): nothing may be deleted, moved away or lost by a dismissal.
const ERR_HAS_ITEMS := "ERR_HAS_ITEMS"


## Deploys (`deployed` true) or undeploys the owned `id`; saved at once.
## {success, reason, mercenary_id}.
static func set_deployed(roster: MercenaryRoster, id: Variant, deployed: bool, persist: Callable = Callable()) -> Dictionary:
	if roster == null:
		return _result(false, ERR_INVALID_STATE, id)
	if roster.get_mercenary(id) == null:
		return _result(false, ERR_UNKNOWN_MERCENARY, id)
	var ids := roster.get_deployed_ids()
	if deployed:
		if ids.has(id):
			return _result(false, ERR_ALREADY_DEPLOYED, id)
		if ids.size() >= MercenaryRoster.MAX_DEPLOYED:
			return _result(false, ERR_DEPLOY_FULL, id)
		ids.append(id)
	else:
		if not ids.has(id):
			return _result(false, ERR_NOT_DEPLOYED, id)
		ids.erase(id)
	var snapshot := roster.get_snapshot()
	if not roster.set_deployment(ids):
		roster.restore_snapshot(snapshot)
		return _result(false, ERR_CHANGE_FAILED, id)
	if persist.is_valid() and not persist.call():
		roster.restore_snapshot(snapshot)
		return _result(false, ERR_SAVE_FAILED, id)
	return _result(true, "", id)


## Dismisses the owned, not deployed `id` for good (no refund); saved at once.
## Stage 9 P01: refused while it holds anything (`carrying`: goods, carried or
## equipped equipment) — the player empties it first; nothing is deleted or
## moved by a dismissal. Its (empty) carrying is forgotten with it.
static func dismiss(roster: MercenaryRoster, id: Variant, persist: Callable = Callable(), carrying: CharacterCarrying = null) -> Dictionary:
	if roster == null:
		return _result(false, ERR_INVALID_STATE, id)
	if roster.get_mercenary(id) == null:
		return _result(false, ERR_UNKNOWN_MERCENARY, id)
	if roster.is_deployed(id):
		return _result(false, ERR_DEPLOYED, id)
	if carrying != null and carrying.has_any_items(id):
		return _result(false, ERR_HAS_ITEMS, id)
	var snapshot := roster.get_snapshot()
	var carried := carrying.get_snapshot() if carrying != null else {}
	if not roster.remove(id):
		roster.restore_snapshot(snapshot)
		return _result(false, ERR_CHANGE_FAILED, id)
	if carrying != null and not carrying.forget(id):
		roster.restore_snapshot(snapshot)
		carrying.restore_snapshot(carried)
		return _result(false, ERR_CHANGE_FAILED, id)
	if persist.is_valid() and not persist.call():
		roster.restore_snapshot(snapshot)
		if carrying != null:
			carrying.restore_snapshot(carried)
		return _result(false, ERR_SAVE_FAILED, id)
	return _result(true, "", id)


## Stage 8 P05: claims the pending legacy `id` into a free place (waiting,
## its data unchanged); saved at once. Refused while the roster is full.
static func claim_pending(roster: MercenaryRoster, id: Variant, persist: Callable = Callable()) -> Dictionary:
	if roster == null:
		return _result(false, ERR_INVALID_STATE, id)
	if roster.get_pending_mercenary(id) == null:
		return _result(false, ERR_UNKNOWN_MERCENARY, id)
	if roster.is_full():
		return _result(false, ERR_ROSTER_FULL, id)
	var snapshot := roster.get_snapshot()
	if not roster.claim_pending(id):
		roster.restore_snapshot(snapshot)
		return _result(false, ERR_CHANGE_FAILED, id)
	if persist.is_valid() and not persist.call():
		roster.restore_snapshot(snapshot)
		return _result(false, ERR_SAVE_FAILED, id)
	return _result(true, "", id)


## Stage 8 P05: confirms the Stat Point allocation {stat: points} of the
## owned `id` (Mercenary.allocate rules); saved at once, the whole roster
## restored when the save fails.
static func allocate(roster: MercenaryRoster, id: Variant, pending: Dictionary, persist: Callable = Callable()) -> Dictionary:
	if roster == null:
		return _result(false, ERR_INVALID_STATE, id)
	var mercenary := roster.get_mercenary(id)
	if mercenary == null:
		return _result(false, ERR_UNKNOWN_MERCENARY, id)
	var snapshot := roster.get_snapshot()
	if not mercenary.allocate(pending):
		roster.restore_snapshot(snapshot)
		return _result(false, ERR_CHANGE_FAILED, id)
	if persist.is_valid() and not persist.call():
		roster.restore_snapshot(snapshot)
		return _result(false, ERR_SAVE_FAILED, id)
	return _result(true, "", id)


static func _result(success: bool, reason: String, id: Variant) -> Dictionary:
	return {"success": success, "reason": reason, "mercenary_id": id if typeof(id) == TYPE_STRING else ""}
