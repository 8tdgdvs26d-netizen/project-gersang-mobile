class_name CombatConfig
extends RefCounted

## Combat C01: Prototype battle parameters (data only). The 5 x 60 grid, the
## 3 s preparation and every stat below are Prototype decisions for C01, not
## Canonical balance; later work packages tune or replace them here.

## Battlefield: ROWS x COLUMNS discrete cells. A cell is Vector2i(column, row);
## column 0 is the far left (the friendly side; C04 Retreat Zone). C05: 5 x 61
## (columns 0-60).
const ROWS := 5
const COLUMNS := 61

## Fixed preparation before real-time fighting starts.
const PREPARATION_MS := 3000
## During preparation friendly units may only stand in PREPARATION_COLUMNS
## columns from PREPARATION_FIRST_COLUMN (all rows): C05 columns 1-3, 5 x 3 =
## 15 cells (column 0, the Retreat Zone, is not part of it).
const PREPARATION_FIRST_COLUMN := 1
const PREPARATION_COLUMNS := 3

## Where the Hero starts (inside the preparation area).
const HERO_START_CELL := Vector2i(1, 2)
## C03: the two fixed Prototype Mercenaries start above and below the Hero.
const MERC_A_START_CELL := Vector2i(1, 1)
const MERC_B_START_CELL := Vector2i(1, 3)
## Stage 8 P04: the deployed roster Mercenaries' start cells, in deployment
## order (the 3rd one in front of the Hero; all inside the preparation area).
const PARTY_START_CELLS: Array[Vector2i] = [MERC_A_START_CELL, MERC_B_START_CELL, Vector2i(2, 2)]
## C05: enemies start in the rightmost columns, every row of a column filled:
## 10 / 15 / 20 enemies fill columns 59-60 / 58-60 / 57-60.

## C05 Prototype reward placeholders (not the future Monster EXP design and not
## the final EXP curve): every enemy actually killed adds EXP_PER_KILL to the
## battle's EXP pool.
const EXP_PER_KILL := 10

## Prototype stats. attack_range is in cells (8-direction / Chebyshev
## distance), attack_interval_ms in milliseconds, move_speed in cells per
## second.
## Stage 7 S01: the friendly characters' stats now come from CharacterStats
## (authoritative values in CharacterConfig). HERO / MERC_A / MERC_B are
## LEGACY COMPATIBILITY NAMES built from CharacterConfig (one value, no
## second source); battles read CharacterStats, not these. Removal path: S02.
const HERO := {
	"max_hp": CharacterConfig.BASE["hero"]["hp"],
	"attack_damage": CharacterConfig.COMBAT_COMPAT["hero"]["physical_attack"],
	"attack_range": CharacterConfig.COMBAT_COMPAT["hero"]["attack_range"],
	"attack_interval_ms": CharacterConfig.COMBAT_COMPAT["hero"]["attack_interval_ms"],
	"move_speed": CharacterConfig.COMBAT_COMPAT["hero"]["move_speed"],
}
## C03: fixed Prototype Mercenaries (test data only: not recruitable, not
## saved, not balance). Merc A fights in melee, Merc B from 3 cells.
const MERC_A := {
	"max_hp": CharacterConfig.BASE["merc_a"]["hp"],
	"attack_damage": CharacterConfig.COMBAT_COMPAT["merc_a"]["physical_attack"],
	"attack_range": CharacterConfig.COMBAT_COMPAT["merc_a"]["attack_range"],
	"attack_interval_ms": CharacterConfig.COMBAT_COMPAT["merc_a"]["attack_interval_ms"],
	"move_speed": CharacterConfig.COMBAT_COMPAT["merc_a"]["move_speed"],
}
const MERC_B := {
	"max_hp": CharacterConfig.BASE["merc_b"]["hp"],
	"attack_damage": CharacterConfig.COMBAT_COMPAT["merc_b"]["physical_attack"],
	"attack_range": CharacterConfig.COMBAT_COMPAT["merc_b"]["attack_range"],
	"attack_interval_ms": CharacterConfig.COMBAT_COMPAT["merc_b"]["attack_interval_ms"],
	"move_speed": CharacterConfig.COMBAT_COMPAT["merc_b"]["move_speed"],
}
## The single C01 Prototype enemy archetype.
const ENEMY := {
	"max_hp": 40,
	"attack_damage": 4,
	"attack_range": 1,
	"attack_interval_ms": 1500,
	"move_speed": 2.0,
}

## C06 Normal Skills (Prototype values approved for C06, not final balance).
## Every friendly unit has one Normal Skill and MAX_MP MP (full at the start of
## every battle, no regeneration). A Skill costs SKILL_MP_COST when its cast
## begins, casts for SKILL_CAST_MS (no movement, no Basic Attack) and starts
## SKILL_COOLDOWN_MS of cooldown when it resolves. Buff / Debuff effects last
## SKILL_EFFECT_MS; re-applying one refreshes it (never stacks).
## S01: legacy compatibility name of the Mercenaries' Base MP
## (CharacterConfig.BASE; Max MP = Effective MP from CharacterStats).
const MAX_MP: int = CharacterConfig.BASE["merc_a"]["mp"]
const SKILL_MP_COST := 25
const SKILL_CAST_MS := 1000
const SKILL_COOLDOWN_MS := 8000
const SKILL_EFFECT_MS := 5000
## Slow: step time and new Basic Attack intervals x SLOW_FACTOR.
const SLOW_FACTOR := 2
## Guard: incoming damage floor(damage / GUARD_DIVISOR) (= floor(x 0.5)).
const GUARD_DIVISOR := 2
## AoE: the target cell and its four orthogonal neighbours, enemies only.
const AOE_DAMAGE := 40
## kind: "slow", "guard", "aoe" (the AoE cells), "ice_field" (the Ice Wall).
## range in cells (8-direction distance, like attack_range; 0 = self).
## Stage 8 iPhone L3 corrective — target: how the Skill is aimed.
##   "self"        Guard: the caster itself, cast at once.
##   "all_enemies" Hero Slow: no target; cast at once, every alive enemy.
##   "ground"      Mage AoE / Strategist Ice Wall: a battlefield cell; the
##                 caster approaches until the cell is within range.
## (Damage, MP, cast time, cooldown and effect time are unchanged.)
const HERO_SKILL := {"kind": "slow", "range": 3, "target": "all_enemies"}
const MERC_A_SKILL := {"kind": "guard", "range": 0, "target": "self"}
const MERC_B_SKILL := {"kind": "aoe", "range": 5, "target": "ground"}
## Stage 8 冰牆 Ice Wall (Strategist) — PROTOTYPE, not balance (the internal
## kind id "ice_field" is kept from P04). Ground-targeted: from the chosen
## cell's column, ICE_WALL_COLUMNS columns (shifted left at the grid's right
## edge) x every row. For SKILL_EFFECT_MS no enemy may step onto a wall cell
## (friends are not blocked); alive enemies already on a wall cell when it
## rises are Frozen for SKILL_EFFECT_MS (no movement, no step progress, no
## Basic Attack — not the Slow). No damage. It uses only existing
## C06 values: SKILL_MP_COST, SKILL_CAST_MS, SKILL_COOLDOWN_MS,
## SKILL_EFFECT_MS, SLOW_FACTOR and the AoE range 5.
const STRATEGIST_SKILL := {"kind": "ice_field", "range": 5, "target": "ground"}
const ICE_WALL_COLUMNS := 2
## Stage 8 P04: each roster Mercenary type's Normal Skill (GUARDIAN = Merc
## A's Guard, MAGE = Merc B's AoE, STRATEGIST = the Prototype 冰牆).
const MERCENARY_SKILLS := {"GUARDIAN": MERC_A_SKILL, "MAGE": MERC_B_SKILL, "STRATEGIST": STRATEGIST_SKILL}

## C07 Minimum Gesture Skill (Prototype values approved for C07, not final
## balance). Only the Hero has it (one symbol: Lightning). The Hero's MP pool
## is HERO_MAX_MP (shared with its Normal Skill); the Mercenaries keep MAX_MP.
## S01: legacy compatibility name of the Hero's Base MP (CharacterConfig).
const HERO_MAX_MP: int = CharacterConfig.BASE["hero"]["mp"]
## Opening the Gesture Window needs GESTURE_MP_COST MP; the MP is paid when
## the Gesture resolves: GESTURE_MP_COST for Perfect / Success / Partial,
## GESTURE_FAIL_MP_COST for Fail or the window timeout. Either way the
## Gesture cooldown (its own, not the Normal Skill's) starts.
const GESTURE_MP_COST := 50
const GESTURE_FAIL_MP_COST := 25
const GESTURE_COOLDOWN_MS := 15000
## The Gesture Window closes as a Fail after this long (Combat Clock time).
const GESTURE_WINDOW_MS := 10000
## Damage to each affected enemy = GESTURE_BASE_DAMAGE x percent of the grade
## (GestureMatcher.Grade order: Perfect, Success, Partial, Fail).
const GESTURE_BASE_DAMAGE := 100
const GESTURE_DAMAGE_PERCENT := [120, 100, 50, 0]
## At most this many alive enemies, picked at random, are affected.
const GESTURE_MAX_TARGETS := 10

## C07 Combat Clock: starts at 0 when FIGHTING begins (PREPARATION does not
## count) and keeps running while the Gesture Window pauses the battlefield.
## Reaching the limit forces the C04 Retreat (not cancellable).
const COMBAT_TIME_LIMIT_MS := 300000
