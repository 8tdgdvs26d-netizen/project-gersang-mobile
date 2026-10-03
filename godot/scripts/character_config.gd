class_name CharacterConfig
extends RefCounted

## Stage 7 S01: Character Stat Foundation — PROTOTYPE PLACEHOLDER CONFIG.
## Every number here is a Prototype placeholder approved for S01, not
## Canonical balance; S02 (combat formulas) and S03 (growth) replace them.
##
## Stats: HP (生命值, maximum), MP (魔力值, maximum), STR (力量), AGI (敏捷),
## INT (智力). Current HP / MP are battle-runtime state on CombatUnit (full at
## every battle start, never saved).

const STATS := ["hp", "mp", "str", "agi", "int"]
## Stats the player may later put points into (S03 / S04). MP is not
## player-allocatable (approved Stage 7 design).
const ALLOCATABLE := ["hp", "str", "agi", "int"]
## The fixed Prototype combat party (no fourth character; Stage 8 brings the
## held / deployed Mercenary model).
const PROTOTYPE_CHARACTERS := ["hero", "merc_a", "merc_b"]

## Base Stats. HP / MP are the C01-C08 values (unchanged); STR / AGI / INT
## are the approved S01 placeholders (10 each; STR 10 is the existing
## T02 / M2-08 backpack default).
const BASE := {
	"hero": {"hp": 300, "mp": 200, "str": 10, "agi": 10, "int": 10},
	"merc_a": {"hp": 200, "mp": 100, "str": 10, "agi": 10, "int": 10},
	"merc_b": {"hp": 150, "mp": 100, "str": 10, "agi": 10, "int": 10},
}

## S01 combat compatibility table (until S02 integrates the Stage 7
## formulas): the C01-C08 Basic Attack values of each character, unchanged.
## They do not depend on STR / AGI / INT yet.
const COMBAT_COMPAT := {
	"hero": {"physical_attack": 20, "attack_range": 1, "attack_interval_ms": 1000, "move_speed": 4.0},
	"merc_a": {"physical_attack": 15, "attack_range": 1, "attack_interval_ms": 1000, "move_speed": 4.0},
	"merc_b": {"physical_attack": 12, "attack_range": 3, "attack_interval_ms": 1200, "move_speed": 4.0},
}

## Carrying Capacity = BASE_CAPACITY + Effective STR x CAPACITY_PER_STR
## (approved Prototype formula; every Effective STR counts, equipment STR
## included once equipment exists).
const BASE_CAPACITY := 10
const CAPACITY_PER_STR := 9
## Upper bound of any single stat layer value.
const MAX_STAT := 1000000
