class_name CombatBattle
extends RefCounted

## Combat C01: the rules and state of one minimum playable battle (runtime
## only, never saved; no rendering, no input device, no clock of its own).
## Time moves only through advance(ms): the CombatView feeds it physics
## delta, tests feed it exact milliseconds.
##
##   PREPARATION  the first CombatConfig.PREPARATION_MS: enemies stand still
##                (no movement, attack or damage); friendly units may move
##                only inside the first PREPARATION_COLUMNS columns
##   FIGHTING     real time: the Hero follows player commands (move / target,
##                automatic approach + Basic Attack); every enemy pursues and
##                attacks the nearest friendly unit
##   VICTORY      every enemy is dead
##   DEFEAT       every friendly unit is dead (C01 has the Hero only)
## VICTORY / DEFEAT are final: nothing moves, attacks or takes damage after.
##
## Every HP change goes through resolve_damage() (Basic Attacks now, later
## Skills). No reward, EXP, loot, retreat or world consequence exists here:
## a finished battle only produces its BattleResult (get_result()), which the
## world lifecycle consumes (C02).

signal phase_changed(phase: int)
signal damage_dealt(attacker: CombatUnit, target: CombatUnit, amount: int)
signal unit_died(unit: CombatUnit)

enum Phase { PREPARATION, FIGHTING, VICTORY, DEFEAT }

## The locked encounter this battle came from ("" when built directly).
var encounter_id := ""
var group_monster_ids: Array[String] = []

var _phase := Phase.PREPARATION
var _elapsed_ms := 0
var _friends: Array[CombatUnit] = []
var _enemies: Array[CombatUnit] = []
var _selected: CombatUnit
## C02: the battle's single result, set once on VICTORY / DEFEAT.
var _result: BattleResult


## A battle with the Hero and `enemy_count` Prototype enemies.
static func create(enemy_count: int) -> CombatBattle:
	var battle := CombatBattle.new()
	var hero := CombatUnit.create("hero", CombatUnit.Team.FRIEND, CombatConfig.HERO, CombatConfig.HERO_START_CELL)
	hero.is_hero = true
	battle._friends.append(hero)
	var cells := enemy_spawn_cells(enemy_count)
	for index in range(cells.size()):
		battle._enemies.append(CombatUnit.create("enemy_%02d" % (index + 1), CombatUnit.Team.ENEMY, CombatConfig.ENEMY, cells[index]))
	battle._selected = hero
	return battle


## The battle for a LOCKED encounter: 1 / 2 / 3 World Enemy Groups -> 10 / 15
## / 20 enemies (EncounterContext.PLANNED_COMBAT_ENEMIES). Null when the
## context has no valid group count.
static func from_encounter(context: EncounterContext) -> CombatBattle:
	if context == null or context.get_planned_combat_enemy_count() <= 0:
		return null
	var battle := create(context.get_planned_combat_enemy_count())
	battle.encounter_id = context.encounter_id
	battle.group_monster_ids = context.group_monster_ids.duplicate()
	return battle


## Enemy start cells, filled column by column (every row) from
## ENEMY_FIRST_COLUMN, never beyond ENEMY_LAST_COLUMN.
static func enemy_spawn_cells(count: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for column in range(CombatConfig.ENEMY_FIRST_COLUMN, CombatConfig.ENEMY_LAST_COLUMN + 1):
		for row in range(CombatConfig.ROWS):
			if cells.size() < count:
				cells.append(Vector2i(column, row))
	return cells


func get_phase() -> int:
	return _phase


func is_over() -> bool:
	return _phase == Phase.VICTORY or _phase == Phase.DEFEAT


func get_elapsed_ms() -> int:
	return _elapsed_ms


func get_preparation_remaining_ms() -> int:
	return maxi(CombatConfig.PREPARATION_MS - _elapsed_ms, 0) if _phase == Phase.PREPARATION else 0


func get_hero() -> CombatUnit:
	for unit in _friends:
		if unit.is_hero:
			return unit
	return null


func get_friends() -> Array[CombatUnit]:
	return _friends


func get_enemies() -> Array[CombatUnit]:
	return _enemies


func get_alive_enemy_count() -> int:
	var count := 0
	for unit in _enemies:
		if unit.alive:
			count += 1
	return count


## C02: the result of a finished battle (null until VICTORY / DEFEAT). Always
## the same object: the world lifecycle commits it once.
func get_result() -> BattleResult:
	return _result


func get_selected() -> CombatUnit:
	return _selected


static func is_in_grid(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < CombatConfig.COLUMNS and cell.y >= 0 and cell.y < CombatConfig.ROWS


## Whether `unit` may stand on / walk to `cell` now (the preparation area
## limit applies to friendly units during PREPARATION).
func is_cell_allowed(unit: CombatUnit, cell: Vector2i) -> bool:
	if not is_in_grid(cell):
		return false
	if _phase == Phase.PREPARATION and unit.team == CombatUnit.Team.FRIEND:
		return cell.x < CombatConfig.PREPARATION_COLUMNS
	return true


## The alive unit standing (not stepping away) on `cell`, or null.
func unit_at(cell: Vector2i) -> CombatUnit:
	for unit in _friends + _enemies:
		if unit.alive and unit.cell == cell:
			return unit
	return null


# --- Commands (touch / tap friendly) ---------------------------------------------------------

## Selects an alive friendly unit. Returns whether it is selected.
func select_unit(unit: CombatUnit) -> bool:
	if is_over() or unit == null or not unit.alive or unit.team != CombatUnit.Team.FRIEND:
		return false
	_selected = unit
	return true


## Moves the selected unit to `cell` (drops its target). Refused outside the
## grid, outside the preparation area during PREPARATION, or once over.
func command_move(cell: Vector2i) -> bool:
	if is_over() or _selected == null or not _selected.alive or not is_cell_allowed(_selected, cell):
		return false
	_selected.target = null
	_selected.has_goal = true
	_selected.goal = cell
	return true


## The selected unit attacks `enemy` (approaching it first when out of range;
## drops any move command). Only while FIGHTING, only an alive enemy.
func command_target(enemy: CombatUnit) -> bool:
	if _phase != Phase.FIGHTING or _selected == null or not _selected.alive:
		return false
	if enemy == null or not enemy.alive or enemy.team != CombatUnit.Team.ENEMY:
		return false
	_selected.has_goal = false
	_selected.target = enemy
	return true


## One tap on `cell`: a friendly unit there is selected, an enemy there is
## targeted, any other cell is a move destination.
func tap(cell: Vector2i) -> bool:
	var unit := unit_at(cell)
	if unit != null and unit.team == CombatUnit.Team.FRIEND:
		return select_unit(unit)
	if unit != null:
		return command_target(unit)
	return command_move(cell)


# --- Time ---------------------------------------------------------------------------------

## Runs the battle for `ms` milliseconds. PREPARATION ends exactly at
## PREPARATION_MS (once); what remains of `ms` is already FIGHTING.
func advance(ms: int) -> void:
	while ms > 0 and not is_over():
		if _phase == Phase.PREPARATION:
			var chunk := mini(ms, CombatConfig.PREPARATION_MS - _elapsed_ms)
			_tick(chunk)
			_elapsed_ms += chunk
			ms -= chunk
			if _elapsed_ms >= CombatConfig.PREPARATION_MS:
				_set_phase(Phase.FIGHTING)
		else:
			_tick(ms)
			_elapsed_ms += ms
			ms = 0


func _tick(ms: int) -> void:
	for unit in _friends:
		_update_unit(unit, ms)
	if _phase != Phase.FIGHTING:
		return
	for unit in _enemies:
		if is_over():
			return
		_update_unit(unit, ms)


func _update_unit(unit: CombatUnit, ms: int) -> void:
	if not unit.alive or is_over():
		return
	if _phase == Phase.FIGHTING:
		unit.attack_cooldown_ms = maxi(unit.attack_cooldown_ms - ms, 0)
	var budget := ms
	# A few decisions per tick at most (a large `ms` may cover several steps).
	for guard in range(64):
		if unit.is_moving():
			unit.step_progress_ms += budget
			budget = 0
			if unit.step_progress_ms < unit.step_ms():
				return
			budget = unit.step_progress_ms - unit.step_ms()
			unit.cell = unit.next_cell
			unit.step_progress_ms = 0
		var destination := _destination(unit)
		unit.claim = destination
		if destination == unit.cell:
			_act(unit)
			return
		unit.next_cell = unit.cell + Vector2i(signi(destination.x - unit.cell.x), signi(destination.y - unit.cell.y))
		unit.step_progress_ms = 0
		if budget <= 0:
			return


## Where the unit wants to stand now (its own cell: stay).
func _destination(unit: CombatUnit) -> Vector2i:
	var target := _target_of(unit)
	if target != null:
		if CombatUnit.grid_distance(unit.cell, target.cell) <= unit.attack_range and _is_free_for(unit, unit.cell):
			return unit.cell
		return _best_free_cell(unit, target.cell, unit.attack_range)
	if unit.has_goal:
		if unit.cell == unit.goal and _is_free_for(unit, unit.cell):
			unit.has_goal = false
			return unit.cell
		var goal := _best_free_cell(unit, unit.goal, 0)
		if goal == unit.cell:
			unit.has_goal = false
		return goal
	if _is_free_for(unit, unit.cell):
		return unit.cell
	return _best_free_cell(unit, unit.cell, 0)


## Standing still: Basic Attack the target when it is in range and ready.
func _act(unit: CombatUnit) -> void:
	if _phase != Phase.FIGHTING:
		return
	var target := _target_of(unit)
	if target == null or unit.attack_cooldown_ms > 0:
		return
	if CombatUnit.grid_distance(unit.cell, target.cell) > unit.attack_range:
		return
	unit.attack_cooldown_ms = unit.attack_interval_ms
	resolve_damage(unit, target, unit.attack_damage)


## The unit's current valid target: the player's choice for friendly units,
## the nearest alive friendly unit for enemies (enemies only act while
## FIGHTING, see _tick).
func _target_of(unit: CombatUnit) -> CombatUnit:
	if unit.team == CombatUnit.Team.FRIEND:
		if unit.target != null and not unit.target.alive:
			unit.target = null
		return unit.target if _phase == Phase.FIGHTING else null
	var best: CombatUnit
	for friend in _friends:
		if friend.alive and (best == null or CombatUnit.grid_distance(unit.cell, friend.cell) < CombatUnit.grid_distance(unit.cell, best.cell)):
			best = friend
	return best


## No other alive unit has claimed `cell` (a standing unit claims its own
## cell, a walking one its destination).
func _is_free_for(unit: CombatUnit, cell: Vector2i) -> bool:
	for others in [_friends, _enemies]:
		for other: CombatUnit in others:
			if other != unit and other.alive and other.claim == cell:
				return false
	return is_cell_allowed(unit, cell)


## The free allowed cell closest to within `reach` of `center`, then closest
## to the unit, then top-left first (deterministic). The unit's own cell when
## nothing better exists.
func _best_free_cell(unit: CombatUnit, center: Vector2i, reach: int) -> Vector2i:
	var best := unit.cell
	var best_score := Vector3i(1 << 20, 1 << 20, 1 << 20)
	# The best cell is never farther from `center` than the unit itself.
	var radius := CombatUnit.grid_distance(unit.cell, center) + 1
	for column in range(maxi(center.x - radius, 0), mini(center.x + radius, CombatConfig.COLUMNS - 1) + 1):
		for row in range(CombatConfig.ROWS):
			var cell := Vector2i(column, row)
			if not _is_free_for(unit, cell):
				continue
			var score := Vector3i(maxi(CombatUnit.grid_distance(cell, center) - reach, 0), CombatUnit.grid_distance(unit.cell, cell), row * CombatConfig.COLUMNS + column)
			if score < best_score:
				best_score = score
				best = cell
	return best


# --- Damage -------------------------------------------------------------------------------

## The one Combat damage path (Basic Attacks now; later Skills): 100% hit, no
## crit / dodge / element. Lowers HP, evaluates death and the battle result.
## Returns the damage dealt (0 when refused).
func resolve_damage(attacker: CombatUnit, target: CombatUnit, amount: int) -> int:
	if _phase != Phase.FIGHTING or attacker == null or target == null or not attacker.alive or not target.alive or amount <= 0:
		return 0
	var dealt := mini(amount, target.hp)
	target.hp -= dealt
	damage_dealt.emit(attacker, target, dealt)
	if target.hp <= 0:
		_kill(target)
	return dealt


func _kill(unit: CombatUnit) -> void:
	unit.hp = 0
	unit.alive = false
	unit.target = null
	unit.has_goal = false
	unit.next_cell = unit.cell
	unit.step_progress_ms = 0
	unit.claim = CombatUnit.NO_CELL
	if _selected == unit:
		_selected = null
	for friend in _friends:
		if friend.target == unit:
			friend.target = null
	print("Myrial: combat unit died ", unit.id)
	unit_died.emit(unit)
	if get_alive_enemy_count() == 0:
		_set_phase(Phase.VICTORY)
		return
	for friend in _friends:
		if friend.alive:
			return
	_set_phase(Phase.DEFEAT)


func _set_phase(phase: Phase) -> void:
	if phase == _phase:
		return
	_phase = phase
	if is_over():
		_result = BattleResult.create(encounter_id, BattleResult.Outcome.VICTORY if phase == Phase.VICTORY else BattleResult.Outcome.DEFEAT, group_monster_ids)
	print("Myrial: combat phase ", Phase.keys()[phase], " at ", _elapsed_ms, " ms")
	phase_changed.emit(phase)
