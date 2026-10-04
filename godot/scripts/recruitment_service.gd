class_name RecruitmentService
extends RefCounted

## Stage 8 P02: UI-independent Mercenary recruitment at the Mercenary Center
## (傭兵中心). Prototype rules (approved): three types, every one PRICE ($1,000);
## any type may be recruited again (each recruit is a new instance with its
## own id); at most MercenaryRoster.MAX_OWNED owned.
##
## A recruitment is one transaction, as TransportService.begin_journey: every
## check runs before any change; then the money is paid, the instance created
## and owned, and `persist` saves. If anything after the payment fails (the
## roster refuses, the save fails) the money and the whole roster, next_serial
## included, are restored exactly: no money is lost, no instance stays, no id
## is used up. Nothing here touches combat or the deployment.

const PRICE := 1000
## Recruitable types (MercenaryRoster ids) in display order, with the player
## names and short Prototype role lines (no stats or skill numbers).
const TYPES := ["GUARDIAN", "MAGE", "STRATEGIST"]
const TYPE_NAMES := {"GUARDIAN": "守衛", "MAGE": "法師", "STRATEGIST": "軍師"}
const ROLE_TEXT := {"GUARDIAN": "近戰防守型", "MAGE": "遠程法術型", "STRATEGIST": "戰場控制型"}
const HINT_TEXT := {"GUARDIAN": "站在前線，保護隊友", "MAGE": "在後方以法術攻擊敵人", "STRATEGIST": "以戰術影響戰場局勢"}

const ERR_INVALID_STATE := "ERR_INVALID_STATE"
const ERR_INVALID_TYPE := "ERR_INVALID_TYPE"
const ERR_ROSTER_FULL := "ERR_ROSTER_FULL"
const ERR_INSUFFICIENT_FUNDS := "ERR_INSUFFICIENT_FUNDS"
const ERR_RECRUIT_FAILED := "ERR_RECRUIT_FAILED"
const ERR_SAVE_FAILED := "ERR_SAVE_FAILED"


## Recruits one `type` into `roster`, paid from `wallet`; `persist` saves the
## new state and returns true. {success, reason, mercenary_id, type, price}.
static func recruit(wallet: Wallet, roster: MercenaryRoster, type: Variant, persist: Callable = Callable()) -> Dictionary:
	if wallet == null or roster == null:
		return _result(false, ERR_INVALID_STATE, type)
	if typeof(type) != TYPE_STRING or not TYPES.has(type) or not Mercenary.is_valid_type(type):
		return _result(false, ERR_INVALID_TYPE, type)
	if roster.is_full():
		return _result(false, ERR_ROSTER_FULL, type)
	if not wallet.can_spend(PRICE):
		return _result(false, ERR_INSUFFICIENT_FUNDS, type)
	var snapshot := roster.get_snapshot()
	if not wallet.spend(PRICE):
		return _result(false, ERR_INVALID_STATE, type)
	var mercenary := roster.create_mercenary(type)
	if mercenary == null:
		_rollback(wallet, roster, snapshot)
		return _result(false, ERR_RECRUIT_FAILED, type)
	if persist.is_valid() and not persist.call():
		_rollback(wallet, roster, snapshot)
		return _result(false, ERR_SAVE_FAILED, type)
	return _result(true, "", type, mercenary.get_id())


## Stage 8 P05 (approved Q5): the legacy Mercenaries' player names.
const LEGACY_LABELS := {"merc_a": "守衛（傳承）", "merc_b": "法師（傳承）"}


## "守衛 #1" style label of an owned instance (the issued serial; P05: a
## legacy id its LEGACY_LABELS name; any other id is shown as it is). No
## naming system.
static func label(mercenary: Mercenary) -> String:
	if LEGACY_LABELS.has(mercenary.get_id()):
		return LEGACY_LABELS[mercenary.get_id()]
	var serial := MercenaryRoster.issued_serial(mercenary.get_id())
	var tag := "#%d" % serial if serial > 0 else mercenary.get_id()
	return "%s %s" % [TYPE_NAMES.get(mercenary.get_type(), mercenary.get_type()), tag]


static func _rollback(wallet: Wallet, roster: MercenaryRoster, snapshot: Dictionary) -> void:
	wallet.add(PRICE)
	roster.restore_snapshot(snapshot)


static func _result(success: bool, reason: String, type: Variant, mercenary_id: String = "") -> Dictionary:
	return {"success": success, "reason": reason, "mercenary_id": mercenary_id, "type": type if typeof(type) == TYPE_STRING else "", "price": PRICE}
