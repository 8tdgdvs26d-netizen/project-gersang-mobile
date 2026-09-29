class_name EncounterHandoff
extends Node

## World Threat WT04: turns a valid world-threat contact into exactly one
## Encounter Trigger + EncounterContext, and holds it until the (future)
## Encounter System takes it. It starts no encounter, combat or UI, and
## changes no player / world state. Nothing here is saved.
##
## Valid contact: the watched monster reports contact with its own id, it is
## active, the player is in WORLD, outside every city safe buffer, and really
## overlaps the monster. Lifecycle:
##   valid contact -> context built, pending, monster held, encounter_triggered
##   while pending -> every further contact is ignored (no second trigger)
##   consume_pending_encounter() -> pending cleared, monster released
## Nothing clears a pending encounter by itself. After the consume a new
## trigger needs a new contact, i.e. the player and monster must separate and
## touch again.

signal encounter_triggered(context: EncounterContext)

var _monster: WorldMonster
var _player: Node2D
var _is_world := Callable()
var _time_source: TimeSource
var _pending: EncounterContext
var _sequence := 0


## Starts watching `monster` for contacts with `player`. `is_world` answers
## whether the player is in WORLD mode.
func watch(monster: WorldMonster, player: Node2D, is_world: Callable, time_source: TimeSource) -> void:
	_monster = monster
	_player = player
	_is_world = is_world
	_time_source = time_source
	_monster.player_contacted.connect(_on_player_contacted)


func has_pending_encounter() -> bool:
	return _pending != null


## The pending context (null when none). Reading it does not clear it.
func get_pending_encounter() -> EncounterContext:
	return _pending


## The Encounter System's hand-back: returns the pending context (null when
## none), clears it and releases the monster.
func consume_pending_encounter() -> EncounterContext:
	var context := _pending
	_pending = null
	if context != null:
		_monster.set_hold(false)
	return context


func _on_player_contacted(monster_id: String) -> void:
	if _pending != null:
		return
	if monster_id == "" or monster_id != _monster.monster_id:
		return
	if not _monster.is_threat_active() or not _is_world.call():
		return
	if WorldThreatZones.is_in_city_safe_buffer(_player.global_position):
		return
	if not (_player is PhysicsBody2D and _monster.overlaps_body(_player)):
		return
	_sequence += 1
	var context := EncounterContext.new()
	context.encounter_id = "encounter_%d" % _sequence
	context.monster_id = monster_id
	context.trigger_world_position = _monster.global_position
	context.player_world_position = _player.global_position
	context.threat_zone_id = WorldThreatZones.threat_zone_at(_player.global_position)
	context.triggered_at_ms = _time_source.now_ms()
	_pending = context
	_monster.set_hold(true)
	print("Myrial: encounter triggered ", context.encounter_id, " by ", monster_id, " in '", context.threat_zone_id, "'")
	encounter_triggered.emit(context)
