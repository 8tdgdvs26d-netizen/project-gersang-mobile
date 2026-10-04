class_name MercenaryRoster
extends RefCounted

## Stage 8 P01: the player's owned Mercenaries and their deployment
## (runtime data foundation only: not saved, not wired to main, combat or any
## UI; the Stage 7 Merc A / Merc B party is untouched).
##
## Prototype rules (approved):
##   - owned: 0..MAX_OWNED (5) independent Mercenary instances, each id once
##   - deployed: 0..MAX_DEPLOYED (3) owned ids, each id once, in order
##   - the Hero always fights and is never owned nor deployed here (his id
##     is reserved), so a party is the Hero + up to 3 (MAX_PARTY = 4)
##   - any number of instances may share a type; 3 deployed MAGEs are fine
##     when their ids differ
## Ids: create_mercenary() issues "merc_" + a serial that only grows; an id
## that was ever owned here is never accepted or issued again, even after
## remove(). So an id is stable, unique and tied to neither type nor
## position. Every change is all-or-nothing: a refused call changes nothing.
## Stage 8 P01.5 (Save v11): to_dict() / from_dict() keep the owned instances,
## the deployment and the serial high-water mark (next_serial), so an issued id
## is never issued again after a restart: every "merc_<n>" ever issued has
## n < next_serial. from_dict() is strict (nothing repaired) and also refuses
## an owned "merc_<n>" at or above next_serial (a future id collision).
## Stage 8 P05 (Save v12): the Stage 7 Merc A / Merc B keep their legacy
## stable ids merc_a (GUARDIAN) / merc_b (MAGE). A converted one that found
## no free place waits in the pending list (pending_legacy_mercenaries): it
## is not owned (no MAX_OWNED place), cannot be deployed, dismissed, given
## points or fight, and leaves the list only by claim_pending() into a free
## place. Legacy ids are not issued-form ids, so they never move next_serial.

const MAX_OWNED := 5
const MAX_DEPLOYED := 3
const MAX_PARTY := 1 + MAX_DEPLOYED
const ID_PREFIX := "merc_"
const KEYS := ["owned", "deployed", "next_serial"]
## The ids create_mercenary() issues: merc_ + a serial without leading zeros.
const ISSUED_ID_PATTERN := "\\Amerc_([1-9][0-9]{0,15})\\z"
## Upper bound of a saved next_serial: 2^53, the largest exact JSON integer.
const MAX_SERIAL := 9007199254740992
## Stage 8 P05: the legacy stable ids and the type each converts to.
const LEGACY_TYPES := {"merc_a": "GUARDIAN", "merc_b": "MAGE"}

var _owned: Array[Mercenary] = []
var _deployed: Array[String] = []
## Every id ever owned here (never reused).
var _used_ids := {}
var _next_serial := 1
## Stage 8 P05: converted legacy Mercenaries waiting for a free place.
var _pending: Array[Mercenary] = []


## A roster holding `mercenaries` (in order) with `deployed` ids, or null
## when the whole state is not valid (see add() / set_deployment()).
static func build(mercenaries: Array, deployed: Array = []) -> MercenaryRoster:
	var roster := MercenaryRoster.new()
	for mercenary in mercenaries:
		if not (mercenary is Mercenary) or not roster.add(mercenary):
			return null
	if not roster.set_deployment(deployed):
		return null
	return roster


## A new Lv1 instance of `type` with a freshly issued id, owned at once;
## null when the roster is full, the type is not supported or no persistable
## serial is left (add() refuses merc_<n> with n >= MAX_SERIAL, since owning it
## would move next_serial past MAX_SERIAL). A refused call changes nothing,
## next_serial included (only add() moves it, after every check).
func create_mercenary(type: Variant) -> Mercenary:
	if is_full() or not Mercenary.is_valid_type(type):
		return null
	var mercenary := Mercenary.create(ID_PREFIX + str(_free_serial()), type)
	if mercenary == null or not add(mercenary):
		return null
	return mercenary


## Owns `mercenary`. Refused when the roster is full, its id is owned or
## was ever owned here, or it is an issued-form merc_<n> that is retired
## (n below next_serial: issued before, also across a restart) or n >=
## MAX_SERIAL (next_serial would have to pass MAX_SERIAL).
func add(mercenary: Mercenary) -> bool:
	if mercenary == null or is_full() or not Mercenary.is_valid_id(mercenary.get_id()) or _used_ids.has(mercenary.get_id()) or get_pending_mercenary(mercenary.get_id()) != null:
		return false
	var serial := issued_serial(mercenary.get_id())
	if serial >= MAX_SERIAL or (serial > 0 and serial < _next_serial):
		return false
	_append(mercenary)
	return true


## Owns a checked `mercenary` (add(), or from_dict() for saved ids below the
## saved next_serial).
func _append(mercenary: Mercenary) -> void:
	_owned.append(mercenary)
	_used_ids[mercenary.get_id()] = true
	# P01.5: an issued-form id given from outside moves the high-water mark
	# past it, so next_serial stays above every owned "merc_<n>" (the saved
	# roster always validates; the issuer never reaches it).
	_next_serial = maxi(_next_serial, issued_serial(mercenary.get_id()) + 1)


## Gives up the owned `id` (and its deployment). The id is never reused.
func remove(id: Variant) -> bool:
	var mercenary := get_mercenary(id)
	if mercenary == null:
		return false
	_owned.erase(mercenary)
	_deployed.erase(id)
	return true


## Replaces the deployment with `ids` (in order). Refused unless at most
## MAX_DEPLOYED ids, each an owned id, none twice.
func set_deployment(ids: Array) -> bool:
	if ids.size() > MAX_DEPLOYED:
		return false
	var seen := {}
	for id in ids:
		if get_mercenary(id) == null or seen.has(id):
			return false
		seen[id] = true
	_deployed.clear()
	for id in ids:
		_deployed.append(id)
	return true


func get_mercenary(id: Variant) -> Mercenary:
	if typeof(id) != TYPE_STRING:
		return null
	for mercenary in _owned:
		if mercenary.get_id() == id:
			return mercenary
	return null


## The owned instances, in the order they were added (a new array).
func get_owned() -> Array[Mercenary]:
	return _owned.duplicate()


func get_owned_count() -> int:
	return _owned.size()


func is_full() -> bool:
	return _owned.size() >= MAX_OWNED


func get_deployed_ids() -> Array[String]:
	return _deployed.duplicate()


func get_deployed() -> Array[Mercenary]:
	var deployed: Array[Mercenary] = []
	for id in _deployed:
		deployed.append(get_mercenary(id))
	return deployed


func is_deployed(id: Variant) -> bool:
	return typeof(id) == TYPE_STRING and _deployed.has(id)


## The party ids: the Hero first (always), then the deployed Mercenaries.
func get_party_ids() -> Array[String]:
	var ids: Array[String] = [Mercenary.HERO_ID]
	ids.append_array(_deployed)
	return ids


## The next serial create_mercenary() may issue (every issued one is below).
func get_next_serial() -> int:
	return _next_serial


## Stage 8 P05: the converted legacy Mercenaries waiting for a place (a new
## array, in the order they were added).
func get_pending() -> Array[Mercenary]:
	return _pending.duplicate()


func get_pending_mercenary(id: Variant) -> Mercenary:
	if typeof(id) != TYPE_STRING:
		return null
	for mercenary in _pending:
		if mercenary.get_id() == id:
			return mercenary
	return null


## Stage 8 P05: puts a converted legacy Mercenary in the pending list.
## Refused (nothing changes) unless its id is a legacy id with that id's type
## and the id is neither owned, pending nor ever used here.
func pend_legacy(mercenary: Mercenary) -> bool:
	if mercenary == null or not LEGACY_TYPES.has(mercenary.get_id()) or LEGACY_TYPES[mercenary.get_id()] != mercenary.get_type():
		return false
	if _used_ids.has(mercenary.get_id()) or get_pending_mercenary(mercenary.get_id()) != null:
		return false
	_pending.append(mercenary)
	return true


## Stage 8 P05: moves the pending `id` into a free owned place (waiting, not
## deployed; its id, type, Level, EXP and allocation unchanged). Refused
## (nothing changes) when it is not pending or the roster is full. Once
## claimed it is no longer pending, so it can never be claimed again.
func claim_pending(id: Variant) -> bool:
	var mercenary := get_pending_mercenary(id)
	if mercenary == null or is_full():
		return false
	_pending.erase(mercenary)
	_append(mercenary)
	return true


## Stage 8 P05: the pending list as saved data (Mercenary.to_dict each).
func pending_to_list() -> Array:
	var list := []
	for mercenary in _pending:
		list.append(mercenary.to_dict())
	return list


## Stage 8 P05: replaces the pending list with saved `data` (strict, nothing
## repaired): an array of at most LEGACY_TYPES.size() valid instances, each a
## legacy id with its type, none twice, none owned or ever used here. False
## (nothing changes) otherwise.
func restore_pending(data: Variant) -> bool:
	if typeof(data) != TYPE_ARRAY or data.size() > LEGACY_TYPES.size():
		return false
	var check := MercenaryRoster.new()
	check._used_ids = _used_ids.duplicate()
	for entry in data:
		if not check.pend_legacy(Mercenary.from_dict(entry)):
			return false
	_pending = check._pending
	return true


## The persistent state: {owned: [Mercenary.to_dict()], deployed: [ids],
## next_serial}. Nothing derived is included.
func to_dict() -> Dictionary:
	var owned := []
	for mercenary in _owned:
		owned.append(mercenary.to_dict())
	return {"owned": owned, "deployed": _deployed.duplicate(), "next_serial": _next_serial}


## A validated roster from to_dict() data (JSON numbers accepted), or null:
## exactly KEYS; owned 0..MAX_OWNED valid instances (Mercenary.from_dict),
## ids unique; deployed 0..MAX_DEPLOYED owned ids, none twice; next_serial a
## whole number from 1 to MAX_SERIAL above every owned issued-form id.
static func from_dict(data: Variant) -> MercenaryRoster:
	if typeof(data) != TYPE_DICTIONARY or data.size() != KEYS.size() or not data.has_all(KEYS):
		return null
	if typeof(data["owned"]) != TYPE_ARRAY or typeof(data["deployed"]) != TYPE_ARRAY:
		return null
	var serial: Variant = data["next_serial"]
	if typeof(serial) == TYPE_FLOAT and is_finite(serial) and serial == floorf(serial) and absf(serial) <= MAX_SERIAL:
		serial = int(serial)
	if typeof(serial) != TYPE_INT or serial < 1 or serial > MAX_SERIAL:
		return null
	# Owned ids sit below the saved next_serial (retired for add()), so they
	# are appended directly, with add()'s other checks.
	var roster := MercenaryRoster.new()
	for entry in data["owned"]:
		var mercenary := Mercenary.from_dict(entry)
		if mercenary == null or roster.is_full() or roster._used_ids.has(mercenary.get_id()) or issued_serial(mercenary.get_id()) >= serial:
			return null
		roster._append(mercenary)
	for id in data["deployed"]:
		if typeof(id) != TYPE_STRING:
			return null
	if not roster.set_deployment(data["deployed"]):
		return null
	roster._next_serial = serial
	return roster


## Stage 8 P02: an exact copy of the whole state for a rollback (owned
## instances, deployment, next_serial and every id ever owned this session;
## P05: and the pending legacy list).
func get_snapshot() -> Dictionary:
	return {"state": to_dict(), "used_ids": _used_ids.keys(), "pending": pending_to_list()}


## Stage 8 P02: puts back a get_snapshot() exactly (a refused transaction
## leaves no trace, next_serial included). False, changing nothing, for
## anything that is not a valid snapshot.
func restore_snapshot(snapshot: Dictionary) -> bool:
	if not snapshot.has("state") or typeof(snapshot.get("used_ids")) != TYPE_ARRAY:
		return false
	var restored := from_dict(snapshot["state"])
	if restored == null:
		return false
	var used := {}
	for id in snapshot["used_ids"]:
		used[id] = true
	if not used.has_all(restored._used_ids.keys()):
		return false
	# P05: the pending list too (a snapshot taken before P05 had none).
	restored._used_ids = used
	if not restored.restore_pending(snapshot.get("pending", [])):
		return false
	_pending = restored._pending
	_owned = restored._owned
	_deployed = restored._deployed
	_next_serial = restored._next_serial
	_used_ids = used
	return true


## The serial of an issued-form id ("merc_<n>"), or 0 for any other id.
static func issued_serial(id: String) -> int:
	var pattern := RegEx.new()
	pattern.compile(ISSUED_ID_PATTERN)
	var found := pattern.search(id)
	return int(found.get_string(1)) if found != null else 0


## The serial create_mercenary() would issue: the first from next_serial
## whose id is not used (nothing changes here; add() moves next_serial).
func _free_serial() -> int:
	var serial := _next_serial
	while _used_ids.has(ID_PREFIX + str(serial)):
		serial += 1
	return serial
