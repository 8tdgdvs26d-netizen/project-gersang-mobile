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

const MAX_OWNED := 5
const MAX_DEPLOYED := 3
const MAX_PARTY := 1 + MAX_DEPLOYED
const ID_PREFIX := "merc_"

var _owned: Array[Mercenary] = []
var _deployed: Array[String] = []
## Every id ever owned here (never reused).
var _used_ids := {}
var _next_serial := 1


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
## null when the roster is full or the type is not supported.
func create_mercenary(type: Variant) -> Mercenary:
	if is_full() or not Mercenary.is_valid_type(type):
		return null
	var id := _issue_id()
	var mercenary := Mercenary.create(id, type)
	if mercenary == null or not add(mercenary):
		return null
	return mercenary


## Owns `mercenary`. Refused when the roster is full, or its id is owned or
## was ever owned here.
func add(mercenary: Mercenary) -> bool:
	if mercenary == null or is_full() or not Mercenary.is_valid_id(mercenary.get_id()) or _used_ids.has(mercenary.get_id()):
		return false
	_owned.append(mercenary)
	_used_ids[mercenary.get_id()] = true
	return true


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


func _issue_id() -> String:
	var id := ID_PREFIX + str(_next_serial)
	while _used_ids.has(id):
		_next_serial += 1
		id = ID_PREFIX + str(_next_serial)
	_next_serial += 1
	return id
