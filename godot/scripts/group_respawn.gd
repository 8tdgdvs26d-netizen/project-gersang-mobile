class_name GroupRespawn
extends RefCounted

## Stage 7 corrective: the minimum deterministic Prototype respawn of World
## Enemy Groups. A group removed by a committed VICTORY (EncounterHandoff
## group_removed, i.e. when the player returns to the world) is scheduled to
## come back WorldLayout.GROUP_RESPAWN_MS later (TimeSource time), as the same
## fixed Prototype group (WorldLayout.PROTOTYPE_GROUPS: id, home, patrol,
## disposition) in its default state at its home. One entry per group id: a
## group is never scheduled twice. main.gd spawns the due groups only while
## the player is in the world with no encounter running, so a group never
## comes back under a running battle or its result screen.
## Runtime / session state only: nothing here is saved; a relaunch rebuilds
## every Prototype group from main.tscn as before.

## monster_id -> {"group_index", "node_name", "due_ms"}, in removal order.
var _entries := {}


## Schedules `monster`'s group to come back GROUP_RESPAWN_MS after `now_ms`.
## Returns false (and changes nothing) when that group is already scheduled.
func schedule(monster: WorldMonster, now_ms: int) -> bool:
	if _entries.has(monster.monster_id):
		return false
	_entries[monster.monster_id] = {"group_index": monster.group_index, "node_name": String(monster.name), "due_ms": now_ms + WorldLayout.GROUP_RESPAWN_MS}
	return true


func is_scheduled(monster_id: String) -> bool:
	return _entries.has(monster_id)


## Milliseconds until `monster_id` is due (0 when due; -1 when not scheduled).
func get_remaining_ms(monster_id: String, now_ms: int) -> int:
	if not _entries.has(monster_id):
		return -1
	return maxi(int(_entries[monster_id]["due_ms"]) - now_ms, 0)


## Removes and returns every entry due at `now_ms` ({"monster_id",
## "group_index", "node_name"}), in removal order.
func take_due(now_ms: int) -> Array[Dictionary]:
	var due: Array[Dictionary] = []
	for monster_id in _entries.keys():
		var entry: Dictionary = _entries[monster_id]
		if now_ms >= int(entry["due_ms"]):
			due.append({"monster_id": monster_id, "group_index": entry["group_index"], "node_name": entry["node_name"]})
			_entries.erase(monster_id)
	return due
