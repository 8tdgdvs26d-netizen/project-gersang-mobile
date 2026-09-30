class_name CombatConfig
extends RefCounted

## Combat C01: Prototype battle parameters (data only). The 5 x 60 grid, the
## 3 s preparation and every stat below are Prototype decisions for C01, not
## Canonical balance; later work packages tune or replace them here.

## Battlefield: ROWS x COLUMNS discrete cells. A cell is Vector2i(column, row);
## column 0 is the far left (the friendly side).
const ROWS := 5
const COLUMNS := 60

## Fixed preparation before real-time fighting starts.
const PREPARATION_MS := 3000
## During preparation friendly units may only stand in the first
## PREPARATION_COLUMNS columns (all rows): 5 x 3 = 15 cells.
const PREPARATION_COLUMNS := 3

## Where the Hero starts (inside the preparation area).
const HERO_START_CELL := Vector2i(1, 2)
## Enemies are placed column by column (all rows) from this column on, so 10 /
## 15 / 20 enemies fill columns 10–11 / 10–12 / 10–13 (at most up to 15).
const ENEMY_FIRST_COLUMN := 10
const ENEMY_LAST_COLUMN := 15

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
## The single C01 Prototype enemy archetype.
const ENEMY := {
	"max_hp": 40,
	"attack_damage": 4,
	"attack_range": 1,
	"attack_interval_ms": 1500,
	"move_speed": 2.0,
}
