class_name EncounterContext
extends RefCounted

## World Threat WT04: what the future Encounter System receives when a world
## threat catches the player. Built once per trigger by EncounterHandoff and
## never saved. Holds no combat, reward or map data.

## Runtime identity of this encounter opportunity ("encounter_1", "encounter_2"
## ... in trigger order; unique within a session, restarts on relaunch).
var encounter_id := ""
## The group that caught the player (the primary group).
var monster_id := ""
## E02: every World Enemy Group taking part, in join order; the primary group
## first. At most EncounterHandoff.MAX_GROUPS, never a duplicate.
var group_monster_ids: Array[String] = []
## Where the monster touched the player (the monster's position).
var trigger_world_position := Vector2.ZERO
## Where the player stood; the Encounter System can return the player here.
var player_world_position := Vector2.ZERO
## Threat zone at the player's position ("" when outside every zone).
var threat_zone_id := ""
## TimeSource milliseconds at the trigger.
var triggered_at_ms := 0


## E02: planned Combat size per number of World Enemy Groups (planning data
## only; no Combat enemies exist yet).
const PLANNED_COMBAT_ENEMIES := {1: 10, 2: 15, 3: 20}


func get_group_count() -> int:
	return group_monster_ids.size()


func get_planned_combat_enemy_count() -> int:
	return PLANNED_COMBAT_ENEMIES.get(get_group_count(), 0)
