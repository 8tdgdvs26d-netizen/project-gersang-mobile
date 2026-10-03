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

## Each character's base combat profile: the values at STR / AGI / INT 10
## (the C01-C08 Basic Attack values). S02: the formulas below start from
## these (base Physical Attack, range, base Attack Interval, base Move Speed).
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

## Stage 7 S02 combat formulas — PROTOTYPE TUNABLE PARAMETERS, not final
## balance. Every formula counts only the stat above STAT_BASELINE (10), so a
## character at STR / AGI / INT 10 keeps its base profile; nothing below 10
## penalises. All rounding lives in CharacterStats (see there).
const STAT_BASELINE := 10
## Physical Attack = base + (STR - 10) x 1.
const PHYSICAL_ATTACK_PER_STR := 1
## Physical / Magic Defense = floor((STR / INT - 10) x 0.5), as
## DEFENSE_PER_STAT_NUM / DEFENSE_PER_STAT_DEN (integer, floor).
const DEFENSE_PER_STAT_NUM := 1
const DEFENSE_PER_STAT_DEN := 2
## Magic Attack = (INT - 10) x 2; Max MP = Effective MP + (INT - 10) x 5.
const MAGIC_ATTACK_PER_INT := 2
const MP_PER_INT := 5
## Attack Interval = max(MIN_ATTACK_INTERVAL_MS, round(base x f)), with
## f = FLOOR + (1 - FLOOR) x HALF / (HALF + (AGI - 10)): 1 at AGI 10,
## diminishing towards FLOOR (base 1.0 s: AGI 20 0.80 s, 40 0.62 s, 100 0.45 s).
const ATTACK_INTERVAL_FLOOR_FACTOR := 0.30
const ATTACK_INTERVAL_AGI_HALF := 25.0
const MIN_ATTACK_INTERVAL_MS := 300
## Move Speed = min(MAX_MOVE_SPEED, base x (1 + BONUS x a / (a + HALF))),
## a = AGI - 10 (base 4.0: AGI 20 4.8, 40 5.6, 100 6.4; the cap from AGI 460).
const MOVE_SPEED_MAX_BONUS := 0.8
const MOVE_SPEED_AGI_HALF := 30.0
const MAX_MOVE_SPEED := 7.0
## Percent values (Gesture grade multipliers) are divided by this.
const PERCENT_DIVISOR := 100

## Stage 7 S03 Base Growth per Level gained (approved Prototype values): Max
## HP / Max MP and Growth STR / AGI / INT. Every Level gained also grants
## STAT_POINTS_PER_LEVEL unspent Stat Points (spent in S04).
const GROWTH_PER_LEVEL := {
	"hero": {"hp": 20, "mp": 5, "str": 1, "agi": 1, "int": 1},
	"merc_a": {"hp": 25, "mp": 0, "str": 2, "agi": 1, "int": 0},
	"merc_b": {"hp": 15, "mp": 10, "str": 0, "agi": 1, "int": 2},
}
const STAT_POINTS_PER_LEVEL := 3
