class_name CombatBattle
extends RefCounted

## Combat C01: the rules and state of one minimum playable battle (runtime
## only, never saved; no rendering, no input device, no clock of its own).
## Time moves only through advance(ms): the CombatView feeds it physics
## delta, tests feed it exact milliseconds.
##
##   PREPARATION  the first CombatConfig.PREPARATION_MS: enemies stand still
##                (no movement, attack or damage); friendly units may move
##                only inside the preparation columns (C05: 1-3)
##   FIGHTING     real time: each friendly unit follows its own player
##                commands (move / target, automatic approach + Basic
##                Attack); every enemy pursues and attacks the nearest alive
##                friendly unit
##
## C04 Retreat (FIGHTING only): start_retreat() sends every alive friendly
## unit toward column 0 — targets and move orders dropped, no Basic Attack,
## no Move / Target commands (selection still works) — while enemies keep
## chasing and attacking. cancel_retreat() leaves the units where they are
## with no orders. The first alive friendly unit standing on a column 0 cell
## no other unit holds (one already there counts; walking through a taken
## zone cell does not) ends the battle as RETREAT. Friendly units act
## before enemies in every tick, so an escape resolves before that tick's
## enemy attacks; a finished battle never changes its result.
##
## C03: the friendly party is the Hero + two fixed Prototype Mercenaries.
## One friendly unit is selected at a time; commands go to it only and every
## other unit keeps its own move / target.
##   VICTORY      every enemy is dead
##   DEFEAT       every friendly unit is dead (C03: Full Party Wipe; the
##                Hero's death alone does not end the battle)
##   RETREAT      C04: during a whole-party retreat, an alive friendly unit
##                stood in the Retreat Zone (column 0, every row)
## VICTORY / DEFEAT are final: nothing moves, attacks or takes damage after.
##
## C06 Normal Skills (FIGHTING only, not while retreating): command_skill()
## replaces the selected unit's move / target order with its Skill. Slow /
## AoE approach the enemy until it is within the Skill range (no MP, no
## cooldown yet), Guard targets the unit itself and begins its cast at once
## (a unit in the middle of a step freezes there: it keeps its step progress
## and its claimed destination and finishes the step after the cast).
## Slow / AoE standing in range begin the cast: SKILL_MP_COST is paid and the target (AoE: its cell) is locked —
## range is not checked again. For SKILL_CAST_MS the unit neither moves nor
## Basic Attacks and ordinary commands are refused; then the Skill resolves,
## the cooldown starts and the replaced order resumes (a dead target is not
## replaced). Before the cast a new move / target command cancels the Skill
## for free, and the Skill target's death cancels it (no new target); a
## retreat cancels pending and casting Skills (MP spent on a cast is not
## refunded, no cooldown).
##
## C07 Gesture (Hero only, FIGHTING only, not while retreating or casting):
## open_gesture() opens the Gesture Window — a pending Normal Skill of the
## Hero is replaced; nothing is paid yet. While it is open the battlefield
## is paused: advance() moves only the Combat Clock and the window's own
## countdown (the battle time every C06 timer, step and Basic Attack runs on
## stands still) and every battlefield command is refused.
## submit_gesture() scores the stroke (GestureMatcher), pays the MP, starts
## the Gesture cooldown, hits up to GESTURE_MAX_TARGETS random alive enemies
## (GestureTargets, gesture_rng) and closes the window; GESTURE_WINDOW_MS
## without a submission is a Fail.
##
## C07 Combat Clock: from 0 when FIGHTING starts, running also while the
## window is open. At COMBAT_TIME_LIMIT_MS (once) an open window is closed
## without any effect or cost and the C04 retreat is forced (it cannot be
## cancelled); the Combat time-up wins over a Gesture timeout at the same
## moment.
##
## Every HP change goes through resolve_damage() (Basic Attacks, Skills and
## the Gesture; C06 Guard halves it). No reward, EXP, loot, retreat or world consequence exists here:
## a finished battle only produces its BattleResult (get_result()), which the
## world lifecycle consumes (C02).

signal phase_changed(phase: int)
signal damage_dealt(attacker: CombatUnit, target: CombatUnit, amount: int)
signal unit_died(unit: CombatUnit)
## C06: a Normal Skill resolved.
signal skill_resolved(unit: CombatUnit)
## C07: a Gesture resolved (see get_last_gesture()).
signal gesture_resolved(result: Dictionary)

enum Phase { PREPARATION, FIGHTING, VICTORY, DEFEAT, RETREAT }
## C06: whether a unit could be given its Skill now (PENDING counts as READY:
## a new Skill command replaces its target).
enum SkillReadiness { READY, UNAVAILABLE, CASTING, COOLDOWN, NO_MP }
## C07: whether the Gesture Window could be opened now.
enum GestureReadiness { READY, UNAVAILABLE, OPEN, CASTING, COOLDOWN, NO_MP }

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
## C04: the whole-party retreat is running.
var _retreating := false
## C05: EXP earned by enemies actually killed in this battle.
var _exp_pool := 0
## C06: the end of the tick being run (what happens in a tick happens at its
## end: cast start / resolution, effect start).
var _tick_end_ms := 0
## C06: the next tap picks the selected unit's Skill target.
var _aiming := false
## C06: the last AoE {"cells", "at_ms"} (presentation only).
var _last_aoe := {}
## C07: the Gesture's random target source (seed it to replay a pick).
var gesture_rng := RandomNumberGenerator.new()
## C07: Combat Clock (ms of FIGHTING, also while the Gesture Window is open).
var _combat_clock_ms := 0
var _time_up := false
## C07: the retreat forced by the Combat Clock (cannot be cancelled).
var _forced_retreat := false
var _gesture_open := false
## Combat Clock time at which the open window times out.
var _gesture_deadline_ms := 0
## Battle time from which the Gesture may be used again.
var _gesture_ready_at_ms := 0
## {"grade", "score", "damage", "targets", "mp_cost", "timeout"} of the last
## resolved Gesture (empty: none).
var _last_gesture := {}


## C03: which friendly party a battle gets. PROTOTYPE is the game's party
## (Hero + Merc A + Merc B; the only one the game ever builds). HERO_ONLY is
## a test fixture for the C01 single-friendly rule tests: never used by the
## game, never saved, not a player option.
enum PartyFixture { PROTOTYPE, HERO_ONLY }


## A battle with the friendly party and `enemy_count` Prototype enemies. The
## friendly order (Hero, Merc A, Merc B) also breaks enemy target ties. The
## Hero starts selected.
static func create(enemy_count: int, party: PartyFixture = PartyFixture.PROTOTYPE) -> CombatBattle:
	var battle := CombatBattle.new()
	var hero := CombatUnit.create("hero", CombatUnit.Team.FRIEND, CombatConfig.HERO, CombatConfig.HERO_START_CELL)
	hero.role = CombatUnit.Role.HERO
	_give_skill(hero, CombatConfig.HERO_SKILL, CombatConfig.HERO_MAX_MP)
	battle._friends.append(hero)
	if party == PartyFixture.PROTOTYPE:
		var merc_a := CombatUnit.create("merc_a", CombatUnit.Team.FRIEND, CombatConfig.MERC_A, CombatConfig.MERC_A_START_CELL)
		merc_a.role = CombatUnit.Role.MERC_A
		_give_skill(merc_a, CombatConfig.MERC_A_SKILL)
		battle._friends.append(merc_a)
		var merc_b := CombatUnit.create("merc_b", CombatUnit.Team.FRIEND, CombatConfig.MERC_B, CombatConfig.MERC_B_START_CELL)
		merc_b.role = CombatUnit.Role.MERC_B
		_give_skill(merc_b, CombatConfig.MERC_B_SKILL)
		battle._friends.append(merc_b)
	var cells := enemy_spawn_cells(enemy_count)
	for index in range(cells.size()):
		battle._enemies.append(CombatUnit.create("enemy_%02d" % (index + 1), CombatUnit.Team.ENEMY, CombatConfig.ENEMY, cells[index]))
	battle._selected = hero
	return battle


## C06: a friendly unit's Normal Skill and full MP (every battle starts full;
## nothing carries over). C07: the Hero's pool is HERO_MAX_MP.
static func _give_skill(unit: CombatUnit, skill: Dictionary, max_mp: int = CombatConfig.MAX_MP) -> void:
	unit.skill = skill
	unit.max_mp = max_mp
	unit.mp = max_mp


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


## C05: enemy start cells in the rightmost columns, column by column (every
## row): 10 / 15 / 20 enemies fill columns 59-60 / 58-60 / 57-60.
static func enemy_spawn_cells(count: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var first_column := CombatConfig.COLUMNS - ceili(float(count) / CombatConfig.ROWS)
	for column in range(maxi(first_column, 0), CombatConfig.COLUMNS):
		for row in range(CombatConfig.ROWS):
			if cells.size() < count:
				cells.append(Vector2i(column, row))
	return cells


func get_phase() -> int:
	return _phase


func is_over() -> bool:
	return _phase == Phase.VICTORY or _phase == Phase.DEFEAT or _phase == Phase.RETREAT


## C04: whether the whole-party retreat is running.
func is_retreating() -> bool:
	return _retreating and _phase == Phase.FIGHTING


## C04: starts the whole-party retreat (FIGHTING only; not while already
## retreating). Every alive friendly unit drops its target and move order.
func start_retreat() -> bool:
	if _phase != Phase.FIGHTING or _retreating or _gesture_open:
		return false
	_begin_retreat()
	return true


## C04 retreat start, shared by the 撤退 command and the C07 forced retreat.
func _begin_retreat() -> void:
	_retreating = true
	_aiming = false
	for unit in _friends:
		# C06: a pending or casting Skill is cancelled (no refund, no cooldown).
		if unit.skill_state != CombatUnit.SkillState.NONE:
			print("Myrial: combat skill of ", unit.id, " cancelled by the retreat")
			_end_skill(unit, false)
		if unit.alive:
			unit.target = null
			unit.has_goal = false
	print("Myrial: party retreat started at ", _elapsed_ms, " ms")


## C04: cancels the retreat. The units stay where they are with no orders
## (nothing from before the retreat comes back). C07: a forced retreat
## cannot be cancelled.
func cancel_retreat() -> bool:
	if not is_retreating() or _forced_retreat:
		return false
	_retreating = false
	for unit in _friends:
		unit.target = null
		unit.has_goal = false
	print("Myrial: party retreat cancelled at ", _elapsed_ms, " ms")
	return true


func get_elapsed_ms() -> int:
	return _elapsed_ms


## C07: the Combat Clock (0 until FIGHTING; stops at COMBAT_TIME_LIMIT_MS).
func get_combat_clock_ms() -> int:
	return _combat_clock_ms


## C07: whether the Combat Clock reached its limit (the retreat is forced).
func is_time_up() -> bool:
	return _time_up


func is_forced_retreat() -> bool:
	return _forced_retreat


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


## C05: EXP earned so far (every enemy killed adds CombatConfig.EXP_PER_KILL).
func get_exp_pool() -> int:
	return _exp_pool


func get_selected() -> CombatUnit:
	return _selected


## C06: whether `unit` could be given its Skill now.
func get_skill_readiness(unit: CombatUnit) -> SkillReadiness:
	if unit == null or unit.skill.is_empty() or not unit.alive or _phase != Phase.FIGHTING or _retreating or _gesture_open:
		return SkillReadiness.UNAVAILABLE
	if unit.skill_state == CombatUnit.SkillState.CASTING:
		return SkillReadiness.CASTING
	if unit.skill_ready_at_ms > _elapsed_ms:
		return SkillReadiness.COOLDOWN
	if unit.mp < CombatConfig.SKILL_MP_COST:
		return SkillReadiness.NO_MP
	return SkillReadiness.READY


## C06: milliseconds until `unit` may use its Skill again (0: no cooldown).
func get_skill_cooldown_remaining(unit: CombatUnit) -> int:
	return maxi(unit.skill_ready_at_ms - _elapsed_ms, 0)


## C06: milliseconds left of the running cast (0: not casting).
func get_cast_remaining(unit: CombatUnit) -> int:
	return maxi(unit.cast_end_ms - _elapsed_ms, 0) if unit.skill_state == CombatUnit.SkillState.CASTING else 0


## C06: milliseconds of Slow / Guard left on `unit` (0: none).
func get_slow_remaining(unit: CombatUnit) -> int:
	return maxi(unit.slow_until_ms - _elapsed_ms, 0) if unit.alive else 0


func get_guard_remaining(unit: CombatUnit) -> int:
	return maxi(unit.guard_until_ms - _elapsed_ms, 0) if unit.alive else 0


## C06: the last AoE ({"cells": Array[Vector2i], "at_ms": int}; empty: none).
func get_last_aoe() -> Dictionary:
	return _last_aoe


# --- Gesture (C07) -------------------------------------------------------------------------------

## Whether the Hero could open the Gesture Window now.
func get_gesture_readiness() -> GestureReadiness:
	var hero := get_hero()
	if hero == null or not hero.alive or _phase != Phase.FIGHTING or _retreating:
		return GestureReadiness.UNAVAILABLE
	if _gesture_open:
		return GestureReadiness.OPEN
	if hero.skill_state == CombatUnit.SkillState.CASTING:
		return GestureReadiness.CASTING
	if _gesture_ready_at_ms > _elapsed_ms:
		return GestureReadiness.COOLDOWN
	if hero.mp < CombatConfig.GESTURE_MP_COST:
		return GestureReadiness.NO_MP
	return GestureReadiness.READY


func is_gesture_open() -> bool:
	return _gesture_open


## Milliseconds left before the open window times out (0: closed).
func get_gesture_remaining_ms() -> int:
	return maxi(_gesture_deadline_ms - _combat_clock_ms, 0) if _gesture_open else 0


## Milliseconds of Gesture cooldown left (battle time: paused with the field).
func get_gesture_cooldown_remaining() -> int:
	return maxi(_gesture_ready_at_ms - _elapsed_ms, 0)


func get_last_gesture() -> Dictionary:
	return _last_gesture


## Opens the Gesture Window (no MP paid yet). A pending Normal Skill of the
## Hero is replaced (its earlier order comes back); a casting Hero must wait.
func open_gesture() -> bool:
	if get_gesture_readiness() != GestureReadiness.READY:
		return false
	var hero := get_hero()
	if hero.skill_state == CombatUnit.SkillState.PENDING:
		print("Myrial: combat skill of ", hero.id, " replaced by the Gesture")
		_end_skill(hero, true)
	_aiming = false
	_gesture_open = true
	_gesture_deadline_ms = _combat_clock_ms + CombatConfig.GESTURE_WINDOW_MS
	print("Myrial: combat gesture opened at clock ", _combat_clock_ms, " ms")
	return true


## Submits a finished stroke (drawing-area units, see GestureMatcher). A
## stroke too short to be an attempt is ignored (the window stays open) and
## an empty Dictionary is returned; otherwise the Gesture resolves.
func submit_gesture(stroke: PackedVector2Array) -> Dictionary:
	if not _gesture_open or not GestureMatcher.is_submittable(stroke):
		return {}
	var match_score := GestureMatcher.score(stroke)
	return _resolve_gesture(GestureMatcher.grade_for(match_score), match_score, false)


func _resolve_gesture(grade: GestureMatcher.Grade, match_score: int, timeout: bool) -> Dictionary:
	var hero := get_hero()
	_gesture_open = false
	var failed := grade == GestureMatcher.Grade.FAIL
	var cost := CombatConfig.GESTURE_FAIL_MP_COST if failed else CombatConfig.GESTURE_MP_COST
	hero.mp -= cost
	_gesture_ready_at_ms = _elapsed_ms + CombatConfig.GESTURE_COOLDOWN_MS
	var damage: int = CombatConfig.GESTURE_BASE_DAMAGE * CombatConfig.GESTURE_DAMAGE_PERCENT[grade] / 100
	var targets: Array[CombatUnit] = []
	if not failed:
		targets = GestureTargets.pick(_enemies, CombatConfig.GESTURE_MAX_TARGETS, gesture_rng)
	_last_gesture = {"grade": grade, "score": match_score, "damage": damage, "targets": targets, "mp_cost": cost, "timeout": timeout}
	print("Myrial: combat gesture ", GestureMatcher.Grade.keys()[grade], " (", match_score, ") at clock ", _combat_clock_ms, " ms: ", targets.size(), " x ", damage)
	for enemy in targets:
		resolve_damage(hero, enemy, damage)
	gesture_resolved.emit(_last_gesture)
	return _last_gesture


## The Combat Clock reached its limit: an open window closes with no effect,
## no MP and no cooldown; the C04 retreat is forced.
func _on_time_up() -> void:
	_time_up = true
	if _gesture_open:
		_gesture_open = false
		print("Myrial: combat gesture cancelled by the time limit")
	_forced_retreat = true
	if not _retreating:
		_begin_retreat()
	print("Myrial: combat time up at ", _combat_clock_ms, " ms: forced retreat")


## C06: the cells an AoE centred on `center` hits: the cell and its four
## orthogonal neighbours inside the grid.
static func aoe_cells(center: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for offset in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		if is_in_grid(center + offset):
			cells.append(center + offset)
	return cells


static func is_in_grid(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < CombatConfig.COLUMNS and cell.y >= 0 and cell.y < CombatConfig.ROWS


## Whether `unit` may stand on / walk to `cell` now (the preparation area
## limit applies to friendly units during PREPARATION).
func is_cell_allowed(unit: CombatUnit, cell: Vector2i) -> bool:
	if not is_in_grid(cell):
		return false
	if _phase == Phase.PREPARATION and unit.team == CombatUnit.Team.FRIEND:
		return cell.x >= CombatConfig.PREPARATION_FIRST_COLUMN and cell.x < CombatConfig.PREPARATION_FIRST_COLUMN + CombatConfig.PREPARATION_COLUMNS
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
	if is_over() or _gesture_open or unit == null or not unit.alive or unit.team != CombatUnit.Team.FRIEND:
		return false
	_selected = unit
	_aiming = false
	return true


## Moves the selected unit to `cell` (drops its target). Refused outside the
## grid, outside the preparation area during PREPARATION, or once over.
func command_move(cell: Vector2i) -> bool:
	if is_over() or is_retreating() or _gesture_open or _selected == null or not _selected.alive or not is_cell_allowed(_selected, cell):
		return false
	if not _ordinary_command_allowed(_selected):
		return false
	_selected.target = null
	_selected.has_goal = true
	_selected.goal = cell
	return true


## The selected unit attacks `enemy` (approaching it first when out of range;
## drops any move command). Only while FIGHTING, only an alive enemy.
func command_target(enemy: CombatUnit) -> bool:
	if _phase != Phase.FIGHTING or is_retreating() or _gesture_open or _selected == null or not _selected.alive:
		return false
	if enemy == null or not enemy.alive or enemy.team != CombatUnit.Team.ENEMY:
		return false
	if not _ordinary_command_allowed(_selected):
		return false
	_selected.has_goal = false
	_selected.target = enemy
	return true


## C06: an ordinary move / target command is refused while the unit casts;
## before the cast it cancels the pending Skill (no MP, no cooldown).
func _ordinary_command_allowed(unit: CombatUnit) -> bool:
	if unit.skill_state == CombatUnit.SkillState.CASTING:
		return false
	if unit.skill_state == CombatUnit.SkillState.PENDING:
		print("Myrial: combat skill of ", unit.id, " replaced by a new command")
		_end_skill(unit, false)
	return true


## C06: gives the selected unit its Skill (FIGHTING, not retreating, ready).
## Slow / AoE need an alive enemy; Guard ignores `enemy` (self). The unit's
## move / target order is set aside and resumes after the Skill.
func command_skill(enemy: CombatUnit = null) -> bool:
	_aiming = false
	var unit := _selected
	if get_skill_readiness(unit) != SkillReadiness.READY:
		return false
	var on_self: bool = unit.skill["range"] == 0
	if not on_self and (enemy == null or not enemy.alive or enemy.team != CombatUnit.Team.ENEMY):
		return false
	if unit.skill_state == CombatUnit.SkillState.NONE:
		unit.resume_target = unit.target
		unit.resume_has_goal = unit.has_goal
		unit.resume_goal = unit.goal
	unit.target = null
	unit.has_goal = false
	unit.skill_state = CombatUnit.SkillState.PENDING
	unit.skill_target = unit if on_self else enemy
	print("Myrial: combat skill ", unit.skill["kind"], " of ", unit.id, " ordered on ", unit.skill_target.id)
	# C06 fix: Guard needs no approach, so its cast begins now (mid-step too).
	if on_self:
		_begin_cast(unit, _elapsed_ms)
	return true


## C06: the Skill button. Guard is ordered at once; Slow / AoE wait for the
## next tap on an enemy (is_aiming()). Returns whether anything happened.
func start_skill_aim() -> bool:
	if get_skill_readiness(_selected) != SkillReadiness.READY:
		return false
	if _selected.skill["range"] == 0:
		return command_skill()
	_aiming = true
	return true


func cancel_skill_aim() -> void:
	_aiming = false


func is_aiming() -> bool:
	return _aiming and get_skill_readiness(_selected) == SkillReadiness.READY


## One tap on `cell`: a friendly unit there is selected, an enemy there is
## targeted, any other cell is a move destination.
func tap(cell: Vector2i) -> bool:
	if _gesture_open:
		return false
	var unit := unit_at(cell)
	# C06: while aiming, an enemy is the Skill target; any other tap cancels.
	if is_aiming():
		_aiming = false
		return unit != null and unit.team == CombatUnit.Team.ENEMY and command_skill(unit)
	_aiming = false
	if unit != null and unit.team == CombatUnit.Team.FRIEND:
		return select_unit(unit)
	if unit != null:
		return command_target(unit)
	return command_move(cell)


# --- Time ---------------------------------------------------------------------------------

## Runs the battle for `ms` milliseconds. PREPARATION ends exactly at
## PREPARATION_MS (once); what remains of `ms` is already FIGHTING.
## C07: FIGHTING time also runs the Combat Clock. While the Gesture Window is
## open only the clock (and the window's countdown) moves: no tick, and the
## battle time stays put. The time is split exactly at the Combat time limit
## and at the window's timeout; the time limit is handled first.
func advance(ms: int) -> void:
	while ms > 0 and not is_over():
		if _phase == Phase.PREPARATION:
			var chunk := mini(ms, CombatConfig.PREPARATION_MS - _elapsed_ms)
			_tick(chunk)
			_elapsed_ms += chunk
			ms -= chunk
			if _elapsed_ms >= CombatConfig.PREPARATION_MS:
				_set_phase(Phase.FIGHTING)
			continue
		var step := ms
		if not _time_up:
			step = mini(step, CombatConfig.COMBAT_TIME_LIMIT_MS - _combat_clock_ms)
		if _gesture_open:
			step = mini(step, _gesture_deadline_ms - _combat_clock_ms)
		if step > 0:
			if not _gesture_open:
				_tick(step)
				_elapsed_ms += step
			if not _time_up:
				_combat_clock_ms += step
			ms -= step
		if is_over():
			return
		if not _time_up and _combat_clock_ms >= CombatConfig.COMBAT_TIME_LIMIT_MS:
			_on_time_up()
		elif _gesture_open and _combat_clock_ms >= _gesture_deadline_ms:
			print("Myrial: combat gesture window timed out")
			_resolve_gesture(GestureMatcher.Grade.FAIL, 0, true)


func _tick(ms: int) -> void:
	_tick_end_ms = _elapsed_ms + ms
	for unit in _friends + _enemies:
		unit.slowed = unit.slow_until_ms > _elapsed_ms
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
	# C06: a casting unit stays where it is until the cast resolves.
	if unit.skill_state == CombatUnit.SkillState.CASTING:
		if _tick_end_ms >= unit.cast_end_ms:
			_resolve_skill(unit)
		return
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
		if _retreating and unit.team == CombatUnit.Team.FRIEND and unit.cell.x == 0 and _is_free_for(unit, unit.cell):
			_set_phase(Phase.RETREAT)
			return
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
	if _retreating and unit.team == CombatUnit.Team.FRIEND:
		return _retreat_cell(unit)
	# C06: a pending Skill approaches its target until within the Skill range.
	if unit.skill_state == CombatUnit.SkillState.PENDING:
		var reach: int = unit.skill["range"]
		if CombatUnit.grid_distance(unit.cell, unit.skill_target.cell) <= reach and _is_free_for(unit, unit.cell):
			return unit.cell
		return _best_free_cell(unit, unit.skill_target.cell, reach)
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


## C04: where a retreating unit heads: the nearest free column 0 cell (same
## row first). With every zone cell taken it waits on the free cell nearest
## to column 1 of its own row (re-checked every step) — never on a taken cell.
func _retreat_cell(unit: CombatUnit) -> Vector2i:
	var cell: Variant = _best_free_cell_in(unit, Vector2i(0, unit.cell.y), 0, 0, 0)
	if cell == null:
		cell = _best_free_cell_in(unit, Vector2i(1, unit.cell.y), 0, 1, CombatConfig.COLUMNS - 1)
	return cell if cell != null else unit.cell


## Standing still: Basic Attack the target when it is in range and ready.
func _act(unit: CombatUnit) -> void:
	if _phase != Phase.FIGHTING or (_retreating and unit.team == CombatUnit.Team.FRIEND):
		return
	if unit.skill_state == CombatUnit.SkillState.PENDING:
		_begin_cast(unit, _tick_end_ms)
		return
	var target := _target_of(unit)
	if target == null or unit.attack_cooldown_ms > 0:
		return
	if CombatUnit.grid_distance(unit.cell, target.cell) > unit.attack_range:
		return
	# C06: an interval started while slowed is SLOW_FACTOR times longer.
	unit.attack_cooldown_ms = unit.attack_interval_ms * (CombatConfig.SLOW_FACTOR if unit.slowed else 1)
	resolve_damage(unit, target, unit.attack_damage)


# --- Skills (C06) -----------------------------------------------------------------------------

## In range: pays the MP, locks the target (AoE: its cell) and starts the
## cast at `at_ms`. Not in range yet (no free cell closer): keeps waiting.
## A casting unit does not move (_update_unit); one caught mid-step keeps its
## step progress and claim and finishes the step after the cast.
func _begin_cast(unit: CombatUnit, at_ms: int) -> void:
	if CombatUnit.grid_distance(unit.cell, unit.skill_target.cell) > unit.skill["range"] or unit.mp < CombatConfig.SKILL_MP_COST:
		return
	unit.mp -= CombatConfig.SKILL_MP_COST
	unit.skill_state = CombatUnit.SkillState.CASTING
	unit.skill_cell = unit.skill_target.cell
	unit.cast_end_ms = at_ms + CombatConfig.SKILL_CAST_MS
	print("Myrial: combat skill ", unit.skill["kind"], " of ", unit.id, " cast at ", at_ms, " ms")


## The cast is over: the effect happens (a dead Slow target gets nothing; the
## AoE hits its locked cells), the cooldown starts, the replaced order resumes.
func _resolve_skill(unit: CombatUnit) -> void:
	var target := unit.skill_target
	var center := unit.skill_cell
	unit.skill_ready_at_ms = _tick_end_ms + CombatConfig.SKILL_COOLDOWN_MS
	print("Myrial: combat skill ", unit.skill["kind"], " of ", unit.id, " resolved at ", _tick_end_ms, " ms")
	match unit.skill["kind"]:
		"slow":
			if target.alive:
				target.slow_until_ms = _tick_end_ms + CombatConfig.SKILL_EFFECT_MS
				target.slowed = true
		"guard":
			unit.guard_until_ms = _tick_end_ms + CombatConfig.SKILL_EFFECT_MS
		"aoe":
			var cells := aoe_cells(center)
			_last_aoe = {"cells": cells, "at_ms": _tick_end_ms}
			var hits: Array[CombatUnit] = []
			for enemy in _enemies:
				if enemy.alive and cells.has(enemy.cell):
					hits.append(enemy)
			for enemy in hits:
				resolve_damage(unit, enemy, CombatConfig.AOE_DAMAGE)
	_end_skill(unit, true)
	skill_resolved.emit(unit)


## Clears the unit's Skill; `resume` gives back the order the Skill replaced
## when it still makes sense (a dead target is not replaced by another).
func _end_skill(unit: CombatUnit, resume: bool) -> void:
	unit.skill_state = CombatUnit.SkillState.NONE
	unit.skill_target = null
	unit.skill_cell = CombatUnit.NO_CELL
	if resume and unit.alive:
		if unit.resume_target != null and unit.resume_target.alive:
			unit.target = unit.resume_target
		elif unit.resume_target == null and unit.resume_has_goal:
			unit.has_goal = true
			unit.goal = unit.resume_goal
	unit.resume_target = null
	unit.resume_has_goal = false


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


## The cells claimed by every alive unit except `unit`.
func _claimed_by_others(unit: CombatUnit) -> Dictionary:
	var claimed := {}
	for others in [_friends, _enemies]:
		for other: CombatUnit in others:
			if other != unit and other.alive:
				claimed[other.claim] = true
	return claimed


## No other alive unit has claimed `cell` (a standing unit claims its own
## cell, a walking one its destination).
func _is_free_for(unit: CombatUnit, cell: Vector2i) -> bool:
	for others in [_friends, _enemies]:
		for other: CombatUnit in others:
			if other != unit and other.alive and other.claim == cell:
				return false
	return is_cell_allowed(unit, cell)


## The free allowed cell closest to within `reach` of `center`, then closest
## to the unit, then top-left first (deterministic). The unit's own cell only
## when no free allowed cell exists at all.
func _best_free_cell(unit: CombatUnit, center: Vector2i, reach: int) -> Vector2i:
	# A free cell is never farther from `center` than the unit itself when the
	# unit's own cell is free, so a window around `center` usually suffices.
	var radius := CombatUnit.grid_distance(unit.cell, center) + 1
	var best: Variant = _best_free_cell_in(unit, center, reach, maxi(center.x - radius, 0), mini(center.x + radius, CombatConfig.COLUMNS - 1))
	if best == null:
		# C03: a crowded window (its own cell taken too): search the whole
		# grid rather than stay on a cell another unit claimed.
		best = _best_free_cell_in(unit, center, reach, 0, CombatConfig.COLUMNS - 1)
	return best if best != null else unit.cell


func _best_free_cell_in(unit: CombatUnit, center: Vector2i, reach: int, first_column: int, last_column: int) -> Variant:
	var best: Variant = null
	var best_score := Vector3i(1 << 20, 1 << 20, 1 << 20)
	# C05: the other units' claims, collected once per search (same answer as
	# _is_free_for, without rescanning every unit for every cell — on the
	# 5 x 61 grid a search can cover the whole field).
	var claimed := _claimed_by_others(unit)
	for column in range(first_column, last_column + 1):
		for row in range(CombatConfig.ROWS):
			var cell := Vector2i(column, row)
			if claimed.has(cell) or not is_cell_allowed(unit, cell):
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
	# C06 Guard: floor(damage x 0.5).
	if target.guard_until_ms > _elapsed_ms:
		amount /= CombatConfig.GUARD_DIVISOR
		if amount <= 0:
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
		if friend.resume_target == unit:
			friend.resume_target = null
		# C06: a Skill whose target dies before the cast is cancelled (no MP,
		# no cooldown, no new target); once cast it still resolves.
		if friend.skill_state == CombatUnit.SkillState.PENDING and friend.skill_target == unit and friend != unit:
			print("Myrial: combat skill of ", friend.id, " cancelled: its target died")
			_end_skill(friend, true)
	# C06: a dying unit's own Skill ends with it.
	if unit.skill_state != CombatUnit.SkillState.NONE:
		_end_skill(unit, false)
	if unit.team == CombatUnit.Team.ENEMY:
		_exp_pool += CombatConfig.EXP_PER_KILL
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
		_aiming = false
		_gesture_open = false
		var outcome := {Phase.VICTORY: BattleResult.Outcome.VICTORY, Phase.DEFEAT: BattleResult.Outcome.DEFEAT, Phase.RETREAT: BattleResult.Outcome.RETREAT}[phase] as BattleResult.Outcome
		_result = BattleResult.create(encounter_id, outcome, group_monster_ids)
		# C05: the reward facts at settlement — the EXP pool and the friendly
		# units alive at this moment (where they stand does not matter).
		_result.exp_pool = _exp_pool
		for friend in _friends:
			if friend.alive:
				_result.survivor_ids.append(friend.id)
	print("Myrial: combat phase ", Phase.keys()[phase], " at ", _elapsed_ms, " ms")
	phase_changed.emit(phase)
