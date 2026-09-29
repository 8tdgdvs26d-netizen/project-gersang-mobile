class_name EncounterContext
extends RefCounted

## World Threat WT04: what the future Encounter System receives when a world
## threat catches the player. Built once per trigger by EncounterHandoff and
## never saved. Holds no combat, reward or map data.

## Runtime identity of this encounter opportunity ("encounter_1", "encounter_2"
## ... in trigger order; unique within a session, restarts on relaunch).
var encounter_id := ""
var monster_id := ""
## Where the monster touched the player (the monster's position).
var trigger_world_position := Vector2.ZERO
## Where the player stood; the Encounter System can return the player here.
var player_world_position := Vector2.ZERO
## Threat zone at the player's position ("" when outside every zone).
var threat_zone_id := ""
## TimeSource milliseconds at the trigger.
var triggered_at_ms := 0
