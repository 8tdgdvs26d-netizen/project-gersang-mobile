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
static func dismiss(roster: MercenaryRoster, id: Variant, persist: Callable = Callable()) -> Dictionary:
	if roster == null:
		return _result(false, ERR_INVALID_STATE, id)
	if roster.get_mercenary(id) == null:
		return _result(false, ERR_UNKNOWN_MERCENARY, id)
	if roster.is_deployed(id):
		return _result(false, ERR_DEPLOYED, id)
	var snapshot := roster.get_snapshot()
	if not roster.remove(id):
		roster.restore_snapshot(snapshot)
		return _result(false, ERR_CHANGE_FAILED, id)
	if persist.is_valid() and not persist.call():
		roster.restore_snapshot(snapshot)
		return _result(false, ERR_SAVE_FAILED, id)
	return _result(true, "", id)


static func _result(success: bool, reason: String, id: Variant) -> Dictionary:
	return {"success": success, "reason": reason, "mercenary_id": id if typeof(id) == TYPE_STRING else ""}
