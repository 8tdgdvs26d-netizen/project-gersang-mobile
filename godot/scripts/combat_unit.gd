class_name CombatUnit
extends RefCounted

## Combat C01: one unit on the battle grid (runtime only, never saved). It
## holds the unit's stats and grid / command state; CombatBattle owns every
## rule that changes it (movement, attacks, damage, death).
##
## Grid movement: a unit stands on `cell`. A step to a neighbouring cell
## (8 directions) takes step_ms(); while stepping, next_cell is the cell it is
## walking to and the unit occupies no cell (units may pass through each
## other), but it only ever stops on a cell no other unit stands on or has
## claimed.

enum Team { FRIEND, ENEMY }
## C03: who the unit is (the game's party is Hero + Merc A + Merc B).
enum Role { HERO, MERC_A, MERC_B, ENEMY }

const NO_CELL := Vector2i(-1, -1)

var id := ""
var team: Team = Team.ENEMY
var role: Role = Role.ENEMY
var is_hero: bool:
	get:
		return role == Role.HERO
var max_hp := 1
var hp := 1
var attack_damage := 0
## Cells, 8-direction (Chebyshev) distance.
var attack_range := 1
var attack_interval_ms := 1000
## Cells per second.
var move_speed := 1.0

var alive := true
## The cell the unit stands on (while stepping: the cell it left).
var cell := Vector2i.ZERO
## The cell it is stepping to (== cell when not stepping).
var next_cell := Vector2i.ZERO
var step_progress_ms := 0
## The cell this unit is heading to / standing on as its destination; no other
## unit picks it (NO_CELL: none). Keeps two units from racing to one cell.
var claim := NO_CELL
## Player move command destination (friendly units only).
var has_goal := false
var goal := Vector2i.ZERO
## Current attack target (null: none).
var target: CombatUnit
## Time left before the next Basic Attack may land (0: ready).
var attack_cooldown_ms := 0

## C06 Normal Skill (friendly units; enemies have none). CombatBattle owns
## every rule; times are absolute battle milliseconds.
enum SkillState { NONE, PENDING, CASTING }
## {"kind", "range"} (CombatConfig.*_SKILL); empty: no Skill.
var skill := {}
var max_mp := 0
var mp := 0
## PENDING: approaching skill_target until in range; CASTING: until cast_end_ms.
var skill_state: SkillState = SkillState.NONE
var skill_target: CombatUnit
## The target's cell locked when the cast began (AoE centre).
var skill_cell := NO_CELL
var cast_end_ms := 0
## The Skill may be used again from this battle time on.
var skill_ready_at_ms := 0
## Slow / Guard are active while the battle time is below these.
var slow_until_ms := 0
var guard_until_ms := 0
## Whether Slow applies to this unit's steps / new Basic Attack intervals
## (kept current by CombatBattle).
var slowed := false
## The move / target order the Skill command replaced, resumed afterwards.
var resume_target: CombatUnit
var resume_has_goal := false
var resume_goal := Vector2i.ZERO
## C08 全體進攻: the unit keeps attacking — when its target is gone it takes
## the nearest alive enemy — until another Move / Target order, the retreat,
## its death or the end of the fighting (runtime only, never saved).
var attack_all_intent := false


static func create(unit_id: String, unit_team: Team, stats: Dictionary, start_cell: Vector2i) -> CombatUnit:
	var unit := CombatUnit.new()
	unit.id = unit_id
	unit.team = unit_team
	unit.max_hp = int(stats["max_hp"])
	unit.hp = unit.max_hp
	unit.attack_damage = int(stats["attack_damage"])
	unit.attack_range = int(stats["attack_range"])
	unit.attack_interval_ms = int(stats["attack_interval_ms"])
	unit.move_speed = float(stats["move_speed"])
	unit.cell = start_cell
	unit.next_cell = start_cell
	unit.claim = start_cell
	return unit


func is_moving() -> bool:
	return next_cell != cell


## Time one cell step takes (C06: x SLOW_FACTOR while slowed; a step in
## progress keeps its progress).
func step_ms() -> int:
	var ms := maxi(1, roundi(1000.0 / move_speed))
	return ms * CombatConfig.SLOW_FACTOR if slowed else ms


## Grid position for drawing: between cell and next_cell while stepping.
func visual_cell() -> Vector2:
	if not is_moving():
		return Vector2(cell)
	return Vector2(cell).lerp(Vector2(next_cell), clampf(float(step_progress_ms) / step_ms(), 0.0, 1.0))


static func grid_distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))
