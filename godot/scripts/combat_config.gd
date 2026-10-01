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
## C05: enemies start in the rightmost columns, every row of a column filled:
## 10 / 15 / 20 enemies fill columns 59-60 / 58-60 / 57-60.

## C05 Prototype reward placeholders (not the future Monster EXP design and not
## the final EXP curve): every enemy actually killed adds EXP_PER_KILL to the
## battle's EXP pool.
const EXP_PER_KILL := 10

## Prototype stats. attack_range is in cells (8-direction / Chebyshev
## distance), attack_interval_ms in milliseconds, move_speed in cells per
## second.
const HERO := {
	"max_hp": 300,
	"attack_damage": 20,
	"attack_range": 1,
	"attack_interval_ms": 1000,
	"move_speed": 4.0,
}
## C03: fixed Prototype Mercenaries (test data only: not recruitable, not
## saved, not balance). Merc A fights in melee, Merc B from 3 cells.
const MERC_A := {
	"max_hp": 200,
	"attack_damage": 15,
	"attack_range": 1,
	"attack_interval_ms": 1000,
	"move_speed": 4.0,
}
const MERC_B := {
	"max_hp": 150,
	"attack_damage": 12,
	"attack_range": 3,
	"attack_interval_ms": 1200,
	"move_speed": 4.0,
}
## The single C01 Prototype enemy archetype.
const ENEMY := {
	"max_hp": 40,
	"attack_damage": 4,
	"attack_range": 1,
	"attack_interval_ms": 1500,
	"move_speed": 2.0,
}
