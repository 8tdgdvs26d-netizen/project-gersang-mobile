class_name EncounterHandoff
extends Node

## World Threat WT04: turns a valid world-threat contact into exactly one
## Encounter Trigger + EncounterContext, and holds it until the (future)
## Encounter System takes it. It starts no encounter, combat or UI, and
## changes no player / world state. Nothing here is saved.
##
## Valid contact: a watched monster reports contact with its own id, it is
## active, the player is in WORLD, outside every city safe buffer, and really
## overlaps the monster. Lifecycle:
##   valid contact -> context built, pending, monster held, encounter_triggered
##   while pending -> every further contact is ignored (no second trigger)
##   consume_pending_encounter() -> pending cleared, every group released
##   cancel_pending_encounter()  -> recovery when the player leaves WORLD (city
##                                  or travel): pending dropped, every group
##                                  released and back at home, IDLE
## Nothing else clears a pending encounter: it never times out, and it stays
## pending while the player remains in WORLD (safe buffers included). After a
## consume a new trigger needs a new contact, i.e. the player and monster must
## separate and touch again.
##
## E02: every prototype World Enemy Group (monster) is watched; the one that
## catches the player is the primary group. join_groups_in_range() (called by
## the EncounterSession during its join window only) adds other groups whose
## aggro radius holds the player, up to MAX_GROUPS, without a new trigger,
## id or timestamp. Joined groups are held like the primary group.
##
## E02 fix pass: set_protected(true) is a runtime-only player protection
## (used by the prototype recovery; meant for later reuse by Combat retreat):
## every group stops aggroing (they keep patrolling, a chase turns back) and no
## contact becomes an encounter until set_protected(false).
## Corrective (post-victory re-engagement): contact is edge-triggered (a
## monster reports it once, when the overlap begins), so a contact ignored
## during protection would otherwise stay unanswered for as long as the
## overlap lasts. When protection ends, every group still in contact is
## checked again through the normal contact rules (_on_player_contacted).

## E03: dispositions. Only an AGGRESSIVE group's contact starts an encounter
## and only AGGRESSIVE groups auto-join. A PASSIVE group starts one only when
## the player challenges it (challenge(): in WORLD, outside safety, within
## CHALLENGE_RANGE, nothing pending); it then is the primary group of a normal
## encounter (same context, id, timestamp and join window). Protection never
## blocks a challenge (the EncounterSession ends it first).

signal encounter_triggered(context: EncounterContext)
signal group_joined(context: EncounterContext, monster_id: String)
## C02: a defeated group left the current world instance (session only).
signal group_removed(monster: WorldMonster)

## At most this many World Enemy Groups take part in one encounter.
const MAX_GROUPS := 3
## E03: how close the player must be to challenge a PASSIVE group.
const CHALLENGE_RANGE := 200.0

var _monsters := {}
var _player: Node2D
var _is_world := Callable()
var _time_source: TimeSource
var _pending: EncounterContext
var _sequence := 0
var _protected := false


## Starts watching `monsters` (the World Enemy Groups) for contacts with
## `player`. `is_world` answers whether the player is in WORLD mode.
func watch(monsters: Array, player: Node2D, is_world: Callable, time_source: TimeSource) -> void:
	_player = player
	_is_world = is_world
	_time_source = time_source
	for monster in monsters:
		_monsters[(monster as WorldMonster).monster_id] = monster
		monster.player_contacted.connect(_on_player_contacted)


## Stage 7 corrective: watches one more group (a respawned one; see
## GroupRespawn), under the current protection. Refused (false) while a group
## with the same id is still watched.
func watch_monster(monster: WorldMonster) -> bool:
	if _monsters.has(monster.monster_id) and is_instance_valid(_monsters[monster.monster_id]):
		return false
	_monsters[monster.monster_id] = monster
	monster.player_contacted.connect(_on_player_contacted)
	monster.set_aggro_suppressed(_protected)
	return true


func is_protected() -> bool:
	return _protected


## Starts (true) or ends (false) the player protection for every group.
func set_protected(protected: bool) -> void:
	var ended := _protected and not protected
	_protected = protected
	for monster_id in _monsters:
		if is_instance_valid(_monsters[monster_id]):
			(_monsters[monster_id] as WorldMonster).set_aggro_suppressed(protected)
	if ended:
		_recheck_contacts()


## Protection just ended: a contact still held (reported while it was being
## ignored) gets the normal encounter check now — at most one encounter
## starts, and every existing rule (pending, active, WORLD, PASSIVE, safe
## buffer, real overlap) still applies.
func _recheck_contacts() -> void:
	for monster_id in _monsters.keys():
		if _pending != null:
			return
		if is_instance_valid(_monsters[monster_id]) and (_monsters[monster_id] as WorldMonster).is_in_contact():
			_on_player_contacted(monster_id)


func has_pending_encounter() -> bool:
	return _pending != null


## The pending context (null when none). Reading it does not clear it.
func get_pending_encounter() -> EncounterContext:
	return _pending


## The Encounter System's hand-back: returns the pending context (null when
## none), clears it and releases every group taking part.
func consume_pending_encounter() -> EncounterContext:
	var context := _pending
	_pending = null
	if context != null:
		for monster in _participants(context):
			monster.set_hold(false)
	return context


## Recovery path, not a hand-back: the player left WORLD before any Encounter
## System took the pending encounter. Drops it (no signal), releases every
## group taking part and puts each back at home, IDLE. Safe no-op when nothing
## is pending. Returns whether an encounter was cancelled.
func cancel_pending_encounter() -> bool:
	if _pending == null:
		return false
	print("Myrial: encounter cancelled ", _pending.encounter_id, " (left WORLD)")
	var participants := _participants(_pending)
	_pending = null
	for monster in participants:
		monster.set_hold(false)
		monster.reset_to_home()
	return true


## C02: the world side of a finished encounter, called by the world
## lifecycle once its outcome is committed. Only for the pending encounter
## (`encounter_id`; otherwise nothing changes and it returns false). The
## pending encounter is cleared, then:
##   groups_defeated  every participating group leaves the current world
##                    instance (unwatched, removed from the tree, freed; never
##                    reset home). Stage 7 corrective: main.gd brings the
##                    group back later (GroupRespawn); a relaunch rebuilds
##                    the fixed Prototype groups from main.tscn
##   otherwise        every participating group is released and reset home
## Groups that did not take part are untouched.
func resolve_encounter(encounter_id: String, groups_defeated: bool) -> bool:
	if _pending == null or _pending.encounter_id != encounter_id:
		return false
	var participants := _participants(_pending)
	_pending = null
	for monster in participants:
		monster.set_hold(false)
		if groups_defeated:
			_remove_group(monster)
		else:
			monster.reset_to_home()
	print("Myrial: encounter ", encounter_id, " resolved (groups defeated: ", groups_defeated, ")")
	return true


func _remove_group(monster: WorldMonster) -> void:
	_monsters.erase(monster.monster_id)
	if monster.player_contacted.is_connected(_on_player_contacted):
		monster.player_contacted.disconnect(_on_player_contacted)
	# Out of the tree it stops processing at once; it is never reset home.
	if monster.get_parent() != null:
		monster.get_parent().remove_child(monster)
	print("Myrial: group ", monster.monster_id, " removed from the world (this session)")
	group_removed.emit(monster)
	monster.queue_free()


## E02: adds every other group whose aggro radius holds the player (active,
## player in WORLD and outside every safe buffer), in the order they qualify,
## until MAX_GROUPS take part. Returns how many joined now.
func join_groups_in_range() -> int:
	if _pending == null or not _is_world.call():
		return 0
	if WorldThreatZones.is_in_city_safe_buffer(_player.global_position):
		return 0
	var joined := 0
	for monster_id in _monsters:
		if _pending.group_monster_ids.size() >= MAX_GROUPS:
			break
		if not is_instance_valid(_monsters[monster_id]):
			continue
		var monster := _monsters[monster_id] as WorldMonster
		if monster_id in _pending.group_monster_ids or not monster.is_threat_active() or monster.is_passive():
			continue
		if monster.global_position.distance_to(_player.global_position) > WorldMonster.AGGRO_RADIUS:
			continue
		_pending.group_monster_ids.append(monster_id)
		monster.set_hold(true)
		joined += 1
		print("Myrial: group ", monster_id, " joined ", _pending.encounter_id, " (", _pending.group_monster_ids.size(), " groups)")
		group_joined.emit(_pending, monster_id)
	return joined


func _participants(context: EncounterContext) -> Array:
	var monsters := []
	for monster_id in context.group_monster_ids:
		if _monsters.has(monster_id) and is_instance_valid(_monsters[monster_id]):
			monsters.append(_monsters[monster_id])
	return monsters


## E03: the PASSIVE group the player may challenge now (null when none):
## nothing pending, player in WORLD and outside every safe buffer, the group
## active and within CHALLENGE_RANGE. Recovery protection does not matter.
func get_challengeable_group() -> WorldMonster:
	if _pending != null or not _is_world.call():
		return null
	if WorldThreatZones.is_in_city_safe_buffer(_player.global_position):
		return null
	for monster_id in _monsters:
		if not is_instance_valid(_monsters[monster_id]):
			continue
		var monster := _monsters[monster_id] as WorldMonster
		if monster.is_passive() and monster.is_threat_active() \
				and monster.global_position.distance_to(_player.global_position) <= CHALLENGE_RANGE:
			return monster
	return null


## E03: the player challenges `monster_id` (a PASSIVE group): starts a normal
## encounter with it as the primary group. Returns the context, or null when
## the challenge is not allowed right now.
func challenge(monster_id: String) -> EncounterContext:
	var target := get_challengeable_group()
	if target == null or target.monster_id != monster_id:
		return null
	print("Myrial: challenge ", monster_id)
	return _start_encounter(target)


func _on_player_contacted(monster_id: String) -> void:
	if _pending != null or _protected:
		return
	if monster_id == "" or not _monsters.has(monster_id):
		return
	var monster := _monsters[monster_id] as WorldMonster
	if not monster.is_threat_active() or not _is_world.call() or monster.is_passive():
		return
	if WorldThreatZones.is_in_city_safe_buffer(_player.global_position):
		return
	if not (_player is PhysicsBody2D and monster.overlaps_body(_player)):
		return
	_start_encounter(monster)


## The one way an encounter starts (catch or challenge): builds the context
## with `monster` as the primary group, holds it and announces the trigger.
func _start_encounter(monster: WorldMonster) -> EncounterContext:
	var monster_id := monster.monster_id
	_sequence += 1
	var context := EncounterContext.new()
	context.encounter_id = "encounter_%d" % _sequence
	context.monster_id = monster_id
	context.group_monster_ids.append(monster_id)
	context.trigger_world_position = monster.global_position
	context.player_world_position = _player.global_position
	context.threat_zone_id = WorldThreatZones.threat_zone_at(_player.global_position)
	context.triggered_at_ms = _time_source.now_ms()
	_pending = context
	monster.set_hold(true)
	print("Myrial: encounter triggered ", context.encounter_id, " by ", monster_id, " in '", context.threat_zone_id, "'")
	encounter_triggered.emit(context)
	return context
