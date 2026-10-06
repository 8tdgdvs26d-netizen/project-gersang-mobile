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
## C03: the friendly party is the Hero + two fixed Prototype Mercenaries
## (the C01-C08 fixture, create()). Stage 8 P04: the game builds the Hero + the
## 0-3 deployed roster Mercenaries instead (create_party() / from_party()).
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
## replaces the selected unit's move / target order with its Skill.
## Stage 8 iPhone L3 corrective (CombatConfig skill "target"): Guard targets
## the unit itself and the Hero's Slow needs no target (every alive enemy);
## both begin their cast at once (a unit in the middle of a step freezes
## there: it keeps its step progress and its claimed destination and
## finishes the step after the cast). The AoE and the Ice Wall are aimed at a
## battlefield cell (command_skill_at(), locked when ordered) and approach it
## until it is within the Skill range (no MP, no cooldown yet); standing in
## range they begin the cast: SKILL_MP_COST is paid — range is not checked
## again. For SKILL_CAST_MS the unit neither moves nor
## Basic Attacks and ordinary commands are refused; then the Skill resolves,
## the cooldown starts and the replaced order resumes (a dead target is not
## replaced). Before the cast a new move / target command cancels the Skill
## for free (a ground Skill has no target to die); a
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
## C08 control: the player selects one or several friendly units (a
## selection; its Active Caster is get_selected(), the unit Skills and the
## single-unit commands act on). A tap on a unit already in a multi-selection
## only makes it the Active Caster. Move / Target taps go to every selected
## unit (each with its own rules: the existing nearest-free-cell occupancy,
## its own attack range, C06 cast / pending priority). Two temporary battle
## groups (membership of this battle only, never saved) select their alive
## members; select_all() selects every alive friendly unit. A group / 全體
## command is a one-time order to each member: tapping one unit (portrait or
## battlefield) selects it alone, and its next order replaces only its own.
## attack_all() gives every alive friendly unit its nearest alive enemy (ties:
## enemy order) through the same target command and keeps it attacking: when
## that enemy is gone it takes the next nearest (attack_all_intent) until
## another Move / Target order for it, the retreat, its death or the end of
## the fighting. The aggregate HP ratios use the sides' total max HP recorded
## when the battle is built.
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
## S02: which defense a hit meets. Basic Attacks are PHYSICAL; the AoE and
## Lightning are MAGIC (both hit enemies only, whose defenses are 0).
enum DamageKind { PHYSICAL, MAGIC }

## The locked encounter this battle came from ("" when built directly).
var encounter_id := ""
var group_monster_ids: Array[String] = []

var _phase := Phase.PREPARATION
var _elapsed_ms := 0
var _friends: Array[CombatUnit] = []
var _enemies: Array[CombatUnit] = []
var _selected: CombatUnit
## C08: every selected friendly unit (the Active Caster _selected among them).
var _selection: Array[CombatUnit] = []
## C08: the two temporary battle groups (members of this battle only).
var _groups: Array = [[], []]
## C08: each side's total max HP when the battle was built (fixed).
var _friend_hp_total := 0
var _enemy_hp_total := 0
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
## Stage 8 Ice Walls standing now: {"cells", "until_ms", "caster"} (enemies
## may not step onto their cells; pruned once expired).
var _ice_walls: Array[Dictionary] = []
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


## C03: which friendly party a battle gets. PROTOTYPE is the fixed C01-C08
## party (Hero + Merc A + Merc B; Stage 8 P04: the game builds create_party()
## instead, so it is a test fixture now too). HERO_ONLY is
## a test fixture for the C01 single-friendly rule tests: never used by the
## game, never saved, not a player option.
enum PartyFixture { PROTOTYPE, HERO_ONLY }


## A battle with the friendly party and `enemy_count` Prototype enemies. The
## friendly order (Hero, Merc A, Merc B) also breaks enemy target ties. The
## Hero starts selected.
## Stage 7 S01: each friendly unit starts from its character's stats
## (`party_stats`: character id -> CharacterStats; a missing id gets the
## Prototype stats): Max HP / Max MP and the Basic Attack profile. Current HP /
## MP are this battle's runtime state, full at the start.
static func create(enemy_count: int, party: PartyFixture = PartyFixture.PROTOTYPE, party_stats: Dictionary = {}) -> CombatBattle:
	var battle := CombatBattle.new()
	var hero := _friend("hero", CombatUnit.Role.HERO, CombatConfig.HERO_START_CELL, CombatConfig.HERO_SKILL, party_stats)
	battle._friends.append(hero)
	if party == PartyFixture.PROTOTYPE:
		battle._friends.append(_friend("merc_a", CombatUnit.Role.MERC_A, CombatConfig.MERC_A_START_CELL, CombatConfig.MERC_A_SKILL, party_stats))
		battle._friends.append(_friend("merc_b", CombatUnit.Role.MERC_B, CombatConfig.MERC_B_START_CELL, CombatConfig.MERC_B_SKILL, party_stats))
	battle._populate(enemy_count)
	return battle


## Stage 8 P04: the game's battle party — the Hero (`hero_stats`; null: the
## Prototype Hero) + the deployed roster Mercenaries in deployment order (0-3,
## MercenaryRoster.get_deployed()). Each Mercenary is its own unit: id = its
## instance id, stats from its own Level / allocation
## (CharacterStats.for_mercenary), its type's role and Skill
## (CombatConfig.MERCENARY_SKILLS), its own label, start cell
## PARTY_START_CELLS[i]. Null when the list is not 0-3 valid instances
## with distinct ids.
## Stage 9 P04: `mercenary_stats` (instance id -> CharacterStats) gives a
## Mercenary's authoritative stats — the game passes CharacterCarrying's
## (Base + Growth + Allocation + its own Equipment, by stable id); an id not
## given falls back to CharacterStats.for_mercenary (no equipment: test
## fixtures). The battle copies each profile once, at creation.
## Stage 10 P00 (approved): `conditions` (character id -> {"hp", "mp",
## "dead"}, the persistent CharacterCondition) gives each character's
## current HP / MP — the unit starts there, not full (an id not given starts
## full: test fixtures). A dead Mercenary does not take part (no unit; the
## living ones keep the deployment order). A dead Hero is in the battle as a
## dead unit (no revival here); with no living friendly unit the battle is
## a DEFEAT at once (C03: every friendly unit is dead).
static func create_party(enemy_count: int, hero_stats: CharacterStats, mercenaries: Array, mercenary_stats: Dictionary = {}, conditions: Dictionary = {}) -> CombatBattle:
	if mercenaries.size() > CombatConfig.PARTY_START_CELLS.size():
		return null
	var battle := CombatBattle.new()
	var hero := _friend("hero", CombatUnit.Role.HERO, CombatConfig.HERO_START_CELL, CombatConfig.HERO_SKILL, {"hero": hero_stats} if hero_stats != null else {})
	_apply_condition(hero, conditions.get("hero"))
	battle._friends.append(hero)
	var ids := {}
	var cell_index := 0
	for index in range(mercenaries.size()):
		if not mercenaries[index] is Mercenary:
			return null
		var mercenary: Mercenary = mercenaries[index]
		var stats: CharacterStats = null
		if mercenary_stats.has(mercenary.get_id()):
			stats = mercenary_stats[mercenary.get_id()] as CharacterStats
		else:
			stats = CharacterStats.for_mercenary(mercenary)
		if stats == null or ids.has(mercenary.get_id()) or not CombatConfig.MERCENARY_SKILLS.has(mercenary.get_type()):
			return null
		ids[mercenary.get_id()] = true
		var state: Variant = conditions.get(mercenary.get_id())
		if typeof(state) == TYPE_DICTIONARY and bool(state.get("dead", false)):
			continue
		var unit := CombatUnit.create(mercenary.get_id(), CombatUnit.Team.FRIEND, stats.get_combat_profile(), CombatConfig.PARTY_START_CELLS[cell_index])
		cell_index += 1
		unit.role = CombatUnit.ROLE_BY_TYPE[mercenary.get_type()]
		unit.label = RecruitmentService.label(mercenary)
		_give_skill(unit, CombatConfig.MERCENARY_SKILLS[mercenary.get_type()], stats.get_max_mp())
		_apply_condition(unit, state)
		battle._friends.append(unit)
	battle._populate(enemy_count)
	battle._start_without_living_friends()
	return battle


## Stage 10 P00: a friendly unit starts from its persistent condition
## ({"hp", "mp", "dead"}; null: full): HP / MP at most its Max; dead -> a
## dead unit (HP 0, never selected).
static func _apply_condition(unit: CombatUnit, state: Variant) -> void:
	if typeof(state) != TYPE_DICTIONARY:
		return
	unit.mp = clampi(int(state.get("mp", unit.max_mp)), 0, unit.max_mp)
	if bool(state.get("dead", false)) or int(state.get("hp", unit.max_hp)) <= 0:
		unit.hp = 0
		unit.alive = false
		unit.claim = CombatUnit.NO_CELL
		return
	unit.hp = clampi(int(state.get("hp", unit.max_hp)), 1, unit.max_hp)


## Stage 10 P00: the starting selection is the first living friendly unit;
## none alive -> DEFEAT at once (nothing can act; C03 Full Party Wipe).
func _start_without_living_friends() -> void:
	var living := _friends.filter(func(unit: CombatUnit) -> bool: return unit.alive)
	if living.size() == _friends.size():
		return
	if living.is_empty():
		_selected = null
		_selection = []
		_set_phase(Phase.DEFEAT)
		return
	_selected = living[0]
	_selection = [living[0]]


## The enemies, the starting selection (the Hero) and the HP totals.
func _populate(enemy_count: int) -> void:
	var cells := enemy_spawn_cells(enemy_count)
	for index in range(cells.size()):
		_enemies.append(CombatUnit.create("enemy_%02d" % (index + 1), CombatUnit.Team.ENEMY, CombatConfig.ENEMY, cells[index]))
	_selected = _friends[0]
	_selection = [_friends[0]]
	for unit in _friends:
		_friend_hp_total += unit.max_hp
	for unit in _enemies:
		_enemy_hp_total += unit.max_hp


## S01: one friendly unit built from its character's stats.
static func _friend(id: String, role: CombatUnit.Role, cell: Vector2i, skill: Dictionary, party_stats: Dictionary) -> CombatUnit:
	var stats: CharacterStats = party_stats.get(id)
	if stats == null:
		stats = CharacterStats.for_character(id)
	var unit := CombatUnit.create(id, CombatUnit.Team.FRIEND, stats.get_combat_profile(), cell)
	unit.role = role
	_give_skill(unit, skill, stats.get_max_mp())
	return unit


## C06: a friendly unit's Normal Skill and full MP. C07: the Hero's pool is
## HERO_MAX_MP. S01: Max MP is the character's Effective MP. Stage 10 P00:
## the game's party then starts from its persistent condition
## (_apply_condition); fixtures start full.
static func _give_skill(unit: CombatUnit, skill: Dictionary, max_mp: int = CombatConfig.MAX_MP) -> void:
	unit.skill = skill
	unit.max_mp = max_mp
	unit.mp = max_mp


## The battle for a LOCKED encounter: 1 / 2 / 3 World Enemy Groups -> 10 / 15
## / 20 enemies (EncounterContext.PLANNED_COMBAT_ENEMIES). Null when the
## context has no valid group count.
static func from_encounter(context: EncounterContext, party_stats: Dictionary = {}) -> CombatBattle:
	if context == null or context.get_planned_combat_enemy_count() <= 0:
		return null
	var battle := create(context.get_planned_combat_enemy_count(), PartyFixture.PROTOTYPE, party_stats)
	battle.encounter_id = context.encounter_id
	battle.group_monster_ids = context.group_monster_ids.duplicate()
	return battle


## Stage 8 P04: the game's battle for a LOCKED encounter (as from_encounter)
## with the Hero + the deployed roster Mercenaries (create_party). Null when
## the context or the party is invalid.
static func from_party(context: EncounterContext, hero_stats: CharacterStats, mercenaries: Array, mercenary_stats: Dictionary = {}, conditions: Dictionary = {}) -> CombatBattle:
	if context == null or context.get_planned_combat_enemy_count() <= 0:
		return null
	var battle := create_party(context.get_planned_combat_enemy_count(), hero_stats, mercenaries, mercenary_stats, conditions)
	if battle == null:
		return null
	battle.encounter_id = context.encounter_id
	battle.group_monster_ids = context.group_monster_ids.duplicate()
	# Stage 10 P00: a battle already lost at creation (no living friendly
	# unit) carries this encounter in its result.
	if battle.is_over():
		battle._make_result(battle._phase)
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
		unit.attack_all_intent = false
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


## C08: the alive selected friendly units, in party order.
func get_selection() -> Array[CombatUnit]:
	var units: Array[CombatUnit] = []
	for unit in _friends:
		if unit.alive and _selection.has(unit):
			units.append(unit)
	return units


## C08: the current HP of a side over its fixed battle-start total max HP
## (0..1). The two ratios are independent.
func get_friend_hp_ratio() -> float:
	return _hp_ratio(_friends, _friend_hp_total)


func get_enemy_hp_ratio() -> float:
	return _hp_ratio(_enemies, _enemy_hp_total)


func _hp_ratio(units: Array[CombatUnit], total: int) -> float:
	if total <= 0:
		return 0.0
	var current := 0
	for unit in units:
		if unit.alive:
			current += unit.hp
	return clampf(float(current) / total, 0.0, 1.0)


## C08: the members of temporary group `index` (0 or 1), dead ones included.
func get_group(index: int) -> Array[CombatUnit]:
	var members: Array[CombatUnit] = []
	for unit in _friends:
		if (_groups[index] as Array).has(unit):
			members.append(unit)
	return members


## C08: adds `unit` to group `index` or removes it. Returns whether it is a
## member afterwards. Only friendly units of this battle, until it ends.
func toggle_group_member(index: int, unit: CombatUnit) -> bool:
	if is_over() or unit == null or not _friends.has(unit):
		return false
	var members: Array = _groups[index]
	if members.has(unit):
		members.erase(unit)
		return false
	members.append(unit)
	return true


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


## Stage 8: how long the unit stays Frozen (冰牆; 0 when not frozen or dead).
func get_frozen_remaining(unit: CombatUnit) -> int:
	return maxi(unit.frozen_until_ms - _elapsed_ms, 0) if unit.alive else 0


func get_guard_remaining(unit: CombatUnit) -> int:
	return maxi(unit.guard_until_ms - _elapsed_ms, 0) if unit.alive else 0


## C06: the last AoE ({"cells": Array[Vector2i], "at_ms": int}; empty: none).
func get_last_aoe() -> Dictionary:
	return _last_aoe


## Stage 8: the Ice Walls standing now (copies: {"cells", "until_ms",
## "caster"}).
func get_ice_walls() -> Array[Dictionary]:
	var walls: Array[Dictionary] = []
	for wall in _ice_walls:
		if int(wall["until_ms"]) > _elapsed_ms:
			walls.append(wall.duplicate(true))
	return walls


## Stage 8: whether an Ice Wall standing now covers `cell`.
func is_ice_wall_cell(cell: Vector2i) -> bool:
	for wall in _ice_walls:
		if int(wall["until_ms"]) > _elapsed_ms and (wall["cells"] as Array).has(cell):
			return true
	return false


## Stage 8: how a Skill is aimed ("self", "all_enemies" or "ground"; "" for
## no Skill).
static func skill_target_type(skill: Dictionary) -> String:
	return String(skill.get("target", ""))


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
	# S02: (100 + the Hero's Magic Attack) x the grade's percent.
	var damage := CharacterStats.gesture_damage(hero.magic_attack, CombatConfig.GESTURE_DAMAGE_PERCENT[grade])
	var targets: Array[CombatUnit] = []
	if not failed:
		targets = GestureTargets.pick(_enemies, CombatConfig.GESTURE_MAX_TARGETS, gesture_rng)
	_last_gesture = {"grade": grade, "score": match_score, "damage": damage, "targets": targets, "mp_cost": cost, "timeout": timeout}
	print("Myrial: combat gesture ", GestureMatcher.Grade.keys()[grade], " (", match_score, ") at clock ", _combat_clock_ms, " ms: ", targets.size(), " x ", damage)
	for enemy in targets:
		resolve_damage(hero, enemy, damage, DamageKind.MAGIC)
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


## Stage 8 Ice Wall: ICE_WALL_COLUMNS columns from `center`'s column (moved
## left at the grid's right edge) x every row — a vertical wall, not a cross.
static func ice_wall_cells(center: Vector2i) -> Array[Vector2i]:
	var first := clampi(center.x, 0, CombatConfig.COLUMNS - CombatConfig.ICE_WALL_COLUMNS)
	var cells: Array[Vector2i] = []
	for column in range(first, first + CombatConfig.ICE_WALL_COLUMNS):
		for row in range(CombatConfig.ROWS):
			cells.append(Vector2i(column, row))
	return cells


static func is_in_grid(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < CombatConfig.COLUMNS and cell.y >= 0 and cell.y < CombatConfig.ROWS


## Whether `unit` may stand on / walk to `cell` now (the preparation area
## limit applies to friendly units during PREPARATION). Stage 8: an enemy may
## not step onto an Ice Wall cell (staying on its own cell is allowed).
func is_cell_allowed(unit: CombatUnit, cell: Vector2i) -> bool:
	if not is_in_grid(cell):
		return false
	if unit.team == CombatUnit.Team.ENEMY and cell != unit.cell and is_ice_wall_cell(cell):
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

## Selects an alive friendly unit (alone: a single selection). Returns
## whether it is selected.
func select_unit(unit: CombatUnit) -> bool:
	if is_over() or _gesture_open or unit == null or not unit.alive or unit.team != CombatUnit.Team.FRIEND:
		return false
	_selected = unit
	_selection = [unit]
	_aiming = false
	return true


## C08: selects the alive friendly units among `units` (party order). The
## Active Caster stays if it is among them, else it is the first. Returns
## whether anything is selected (nothing changes otherwise).
func select_units(units: Array) -> bool:
	if is_over() or _gesture_open:
		return false
	var chosen: Array[CombatUnit] = []
	for unit in _friends:
		if unit.alive and units.has(unit):
			chosen.append(unit)
	if chosen.is_empty():
		return false
	_selection = chosen
	if not chosen.has(_selected):
		_selected = chosen[0]
	_aiming = false
	return true


func select_group(index: int) -> bool:
	return select_units(_groups[index])


func select_all() -> bool:
	return select_units(_friends)


## C08: makes `unit` (already selected) the Active Caster; the selection stays.
func set_active_caster(unit: CombatUnit) -> bool:
	if is_over() or _gesture_open or unit == null or not get_selection().has(unit):
		return false
	_selected = unit
	_aiming = false
	return true


## Moves the selected unit to `cell` (drops its target). Refused outside the
## grid, outside the preparation area during PREPARATION, or once over.
func command_move(cell: Vector2i) -> bool:
	return _command_move_unit(_selected, cell)


func _command_move_unit(unit: CombatUnit, cell: Vector2i) -> bool:
	if is_over() or is_retreating() or _gesture_open or unit == null or not unit.alive or not is_cell_allowed(unit, cell):
		return false
	if not _ordinary_command_allowed(unit):
		return false
	unit.target = null
	unit.has_goal = true
	unit.goal = cell
	unit.attack_all_intent = false
	return true


## C08: every selected unit heads for `cell` (the existing nearest-free-cell
## rule spreads them over nearby legal cells). Returns whether any accepted.
func command_move_selection(cell: Vector2i) -> bool:
	var accepted := false
	for unit in get_selection():
		accepted = _command_move_unit(unit, cell) or accepted
	return accepted


## The selected unit attacks `enemy` (approaching it first when out of range;
## drops any move command). Only while FIGHTING, only an alive enemy.
func command_target(enemy: CombatUnit) -> bool:
	return _command_target_unit(_selected, enemy)


func _command_target_unit(unit: CombatUnit, enemy: CombatUnit) -> bool:
	if _phase != Phase.FIGHTING or is_retreating() or _gesture_open or unit == null or not unit.alive:
		return false
	if enemy == null or not enemy.alive or enemy.team != CombatUnit.Team.ENEMY:
		return false
	if not _ordinary_command_allowed(unit):
		return false
	unit.has_goal = false
	unit.target = enemy
	unit.attack_all_intent = false
	return true


## C08: every selected unit attacks `enemy` (each approaches to its own
## range). Returns whether any accepted.
func command_target_selection(enemy: CombatUnit) -> bool:
	var accepted := false
	for unit in get_selection():
		accepted = _command_target_unit(unit, enemy) or accepted
	return accepted


## C08 全體進攻: every alive friendly unit targets its nearest alive enemy
## (grid distance; ties: enemy order) with the normal target command
## (casting units keep casting, a pending Skill is replaced; a Skill aim is
## cancelled) and keeps attacking: each unit that accepted gets
## attack_all_intent (see _target_of). FIGHTING only, not while retreating.
## Returns whether any accepted.
func attack_all() -> bool:
	var accepted := false
	for unit in _friends:
		if unit.alive and _command_target_unit(unit, nearest_enemy(unit)):
			unit.attack_all_intent = true
			accepted = true
	if accepted:
		_aiming = false
	return accepted


## The alive enemy nearest to `unit` (ties: enemy order); null when none.
func nearest_enemy(unit: CombatUnit) -> CombatUnit:
	var best: CombatUnit
	for enemy in _enemies:
		if enemy.alive and (best == null or CombatUnit.grid_distance(unit.cell, enemy.cell) < CombatUnit.grid_distance(unit.cell, best.cell)):
			best = enemy
	return best


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
## Guard (self) and the Hero's Slow (every enemy) ignore `enemy` and begin
## their cast at once. Stage 8: a ground Skill (AoE / Ice Wall) given an
## alive enemy is aimed at that enemy's cell (command_skill_at()). The unit's
## move / target order is set aside and resumes after the Skill.
func command_skill(enemy: CombatUnit = null) -> bool:
	_aiming = false
	var unit := _selected
	if get_skill_readiness(unit) != SkillReadiness.READY:
		return false
	var target_type := skill_target_type(unit.skill)
	if target_type == "ground":
		if enemy == null or not enemy.alive or enemy.team != CombatUnit.Team.ENEMY:
			return false
		return command_skill_at(enemy.cell)
	if target_type != "self" and target_type != "all_enemies":
		return false
	_order_skill(unit, unit if target_type == "self" else null, CombatUnit.NO_CELL)
	# C06 fix: no approach needed, so the cast begins now (mid-step too).
	_begin_cast(unit, _elapsed_ms)
	return true


## Stage 8: orders the selected unit's ground Skill (AoE / Ice Wall) on the
## battlefield cell `cell` (any grid cell; no enemy needed). The cell is
## locked now; the unit approaches until it is within the Skill range.
func command_skill_at(cell: Vector2i) -> bool:
	_aiming = false
	var unit := _selected
	if get_skill_readiness(unit) != SkillReadiness.READY or skill_target_type(unit.skill) != "ground" or not is_in_grid(cell):
		return false
	_order_skill(unit, null, cell)
	return true


func _order_skill(unit: CombatUnit, target: CombatUnit, cell: Vector2i) -> void:
	if unit.skill_state == CombatUnit.SkillState.NONE:
		unit.resume_target = unit.target
		unit.resume_has_goal = unit.has_goal
		unit.resume_goal = unit.goal
	unit.target = null
	unit.has_goal = false
	unit.skill_state = CombatUnit.SkillState.PENDING
	unit.skill_target = target
	unit.skill_cell = cell
	print("Myrial: combat skill ", unit.skill["kind"], " of ", unit.id, " ordered on ", target.id if target != null else ("all enemies" if cell == CombatUnit.NO_CELL else str(cell)))


## C06: the Skill button. Guard and the Hero's Slow are ordered at once;
## Stage 8: a ground Skill waits for the next tap on a battlefield cell
## (is_aiming()). Returns whether anything happened.
func start_skill_aim() -> bool:
	if get_skill_readiness(_selected) != SkillReadiness.READY:
		return false
	if skill_target_type(_selected.skill) != "ground":
		return command_skill()
	_aiming = true
	return true


func cancel_skill_aim() -> void:
	_aiming = false


func is_aiming() -> bool:
	return _aiming and get_skill_readiness(_selected) == SkillReadiness.READY


## One tap on `cell`: a friendly unit there is selected, an enemy there is
## targeted, any other cell is a move destination (while aiming a ground
## Skill: the Skill's location).
func tap(cell: Vector2i) -> bool:
	if _gesture_open:
		return false
	var unit := unit_at(cell)
	# Stage 8: while aiming, the tapped battlefield cell is the Skill's
	# location (whatever stands there); a cell off the grid cancels.
	if is_aiming():
		_aiming = false
		return command_skill_at(cell)
	_aiming = false
	if unit != null and unit.team == CombatUnit.Team.FRIEND:
		return select_unit(unit)
	if unit != null:
		return command_target_selection(unit)
	return command_move_selection(cell)


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
	for index in range(_ice_walls.size() - 1, -1, -1):
		if int(_ice_walls[index]["until_ms"]) <= _elapsed_ms:
			print("Myrial: combat ice wall of ", _ice_walls[index]["caster"], " melted at ", _elapsed_ms, " ms")
			_ice_walls.remove_at(index)
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
	# Stage 8 Frozen: no movement, no step progress, no Basic Attack and no
	# attack cooldown progress while frozen; a tick the freeze ends in runs
	# only its thawed part (timing resumes exactly where it stopped).
	if unit.frozen_until_ms > _elapsed_ms:
		unit.claim = unit.cell
		if unit.frozen_until_ms >= _tick_end_ms:
			return
		ms = _tick_end_ms - unit.frozen_until_ms
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
		# Stage 8: an enemy cannot get past an Ice Wall: it heads for the free
		# cell on its own side nearest to where it was going instead.
		if unit.team == CombatUnit.Team.ENEMY and not _ice_walls.is_empty():
			destination = _ice_wall_detour(unit, destination)
		unit.claim = destination
		if destination == unit.cell:
			_act(unit)
			return
		var step := unit.cell + Vector2i(signi(destination.x - unit.cell.x), signi(destination.y - unit.cell.y))
		# Stage 8: the next step would enter an Ice Wall: hold here.
		if not is_cell_allowed(unit, step):
			unit.claim = unit.cell
			_act(unit)
			return
		unit.next_cell = step
		unit.step_progress_ms = 0
		if budget <= 0:
			return


## Where the unit wants to stand now (its own cell: stay).
func _destination(unit: CombatUnit) -> Vector2i:
	if _retreating and unit.team == CombatUnit.Team.FRIEND:
		return _retreat_cell(unit)
	# C06: a pending Skill approaches its location until within the range.
	if unit.skill_state == CombatUnit.SkillState.PENDING:
		var reach: int = unit.skill["range"]
		var aim := _skill_aim_cell(unit)
		if CombatUnit.grid_distance(unit.cell, aim) <= reach and _is_free_for(unit, unit.cell):
			return unit.cell
		return _best_free_cell(unit, aim, reach)
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

## Where a pending Skill is aimed: its ground cell, else its target's cell
## (Guard: the unit itself); the Hero's Slow needs no place (its own cell).
func _skill_aim_cell(unit: CombatUnit) -> Vector2i:
	if unit.skill_target != null:
		return unit.skill_target.cell
	if unit.skill_cell != CombatUnit.NO_CELL:
		return unit.skill_cell
	return unit.cell


## In range: pays the MP, locks the location and starts the cast at `at_ms`.
## Not in range yet (no free cell closer): keeps waiting.
## A casting unit does not move (_update_unit); one caught mid-step keeps its
## step progress and claim and finishes the step after the cast.
func _begin_cast(unit: CombatUnit, at_ms: int) -> void:
	var aim := _skill_aim_cell(unit)
	if CombatUnit.grid_distance(unit.cell, aim) > unit.skill["range"] or unit.mp < CombatConfig.SKILL_MP_COST:
		return
	unit.mp -= CombatConfig.SKILL_MP_COST
	unit.skill_state = CombatUnit.SkillState.CASTING
	unit.skill_cell = aim
	unit.cast_end_ms = at_ms + CombatConfig.SKILL_CAST_MS
	print("Myrial: combat skill ", unit.skill["kind"], " of ", unit.id, " cast at ", at_ms, " ms")


## The cast is over: the effect happens (the Slow on every alive enemy; the
## AoE hits its locked cells; the Ice Wall rises on its locked cell), the
## cooldown starts, the replaced order resumes.
func _resolve_skill(unit: CombatUnit) -> void:
	var center := unit.skill_cell
	unit.skill_ready_at_ms = _tick_end_ms + CombatConfig.SKILL_COOLDOWN_MS
	print("Myrial: combat skill ", unit.skill["kind"], " of ", unit.id, " resolved at ", _tick_end_ms, " ms")
	match unit.skill["kind"]:
		"slow":
			# Stage 8: no target — the same Slow on every alive enemy.
			for enemy in _enemies:
				if enemy.alive:
					enemy.slow_until_ms = _tick_end_ms + CombatConfig.SKILL_EFFECT_MS
					enemy.slowed = true
		"guard":
			unit.guard_until_ms = _tick_end_ms + CombatConfig.SKILL_EFFECT_MS
		"aoe":
			var cells := aoe_cells(center)
			# S02: AoE damage = AOE_DAMAGE + the caster's Magic Attack.
			var damage := CombatConfig.AOE_DAMAGE + unit.magic_attack
			_last_aoe = {"cells": cells, "at_ms": _tick_end_ms, "damage": damage}
			var hits: Array[CombatUnit] = []
			for enemy in _enemies:
				if enemy.alive and cells.has(enemy.cell):
					hits.append(enemy)
			for enemy in hits:
				resolve_damage(unit, enemy, damage, DamageKind.MAGIC)
		"ice_field":
			_raise_ice_wall(unit, center)
	_end_skill(unit, true)
	skill_resolved.emit(unit)


## Stage 8: where an enemy goes when a standing Ice Wall lies between it and
## `destination`: the free allowed cell nearest to `destination` on its own
## side of that wall (one unit per cell, like any destination; its own cell
## when nothing is free). Otherwise `destination` itself.
func _ice_wall_detour(unit: CombatUnit, destination: Vector2i) -> Vector2i:
	for wall in _ice_walls:
		if int(wall["until_ms"]) <= _elapsed_ms:
			continue
		var cells: Array = wall["cells"]
		var first: int = (cells[0] as Vector2i).x
		var last: int = (cells[cells.size() - 1] as Vector2i).x
		var found: Variant = destination
		if unit.cell.x > last and destination.x <= last:
			found = _best_free_cell_in(unit, destination, 0, last + 1, CombatConfig.COLUMNS - 1)
		elif unit.cell.x < first and destination.x >= first:
			found = _best_free_cell_in(unit, destination, 0, 0, first - 1)
		if found == null:
			return unit.cell
		destination = found
	return destination


## Stage 8 冰牆 Ice Wall (Prototype): the wall's cells stand for
## SKILL_EFFECT_MS; alive enemies already on them are Frozen for
## SKILL_EFFECT_MS (no move, no step, no Basic Attack; refreshed, never
## stacked); an enemy stepping onto one stops where it was. No damage.
func _raise_ice_wall(unit: CombatUnit, center: Vector2i) -> void:
	var cells := ice_wall_cells(center)
	_ice_walls.append({"cells": cells, "until_ms": _tick_end_ms + CombatConfig.SKILL_EFFECT_MS, "caster": unit.id})
	_last_aoe = {"cells": cells, "at_ms": _tick_end_ms, "damage": 0, "kind": "ice_field"}
	for enemy in _enemies:
		if not enemy.alive:
			continue
		if cells.has(enemy.cell):
			# Frozen (not the Slow): an unfinished step is dropped so the
			# unit stays exactly on its cell; re-freezing refreshes, never
			# stacks.
			enemy.frozen_until_ms = _tick_end_ms + CombatConfig.SKILL_EFFECT_MS
			enemy.next_cell = enemy.cell
			enemy.step_progress_ms = 0
			enemy.claim = enemy.cell
		elif enemy.is_moving() and cells.has(enemy.next_cell):
			enemy.next_cell = enemy.cell
			enemy.step_progress_ms = 0
			enemy.claim = enemy.cell
	print("Myrial: combat ice wall of ", unit.id, " at columns ", cells[0].x, "-", cells[cells.size() - 1].x)


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
		# C08 全體進攻: the next nearest alive enemy once the target is gone
		# (none left: the intent ends). Never during a Skill or the retreat.
		if unit.target == null and unit.attack_all_intent and _phase == Phase.FIGHTING and not _retreating and unit.skill_state == CombatUnit.SkillState.NONE:
			unit.target = nearest_enemy(unit)
			unit.attack_all_intent = unit.target != null
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
func resolve_damage(attacker: CombatUnit, target: CombatUnit, amount: int, kind: DamageKind = DamageKind.PHYSICAL) -> int:
	if _phase != Phase.FIGHTING or attacker == null or target == null or not attacker.alive or not target.alive or amount <= 0:
		return 0
	# S02: the target's Physical / Magic Defense first (every damaging hit
	# still deals >= 1; CharacterStats.mitigate), then the C06 Guard.
	amount = CharacterStats.mitigate(amount, target.magic_defense if kind == DamageKind.MAGIC else target.physical_defense)
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
	# C08: a dead unit leaves the selection (it stays in its groups); the
	# Active Caster passes to the next selected unit, else nothing (its
	# Skill aim ends with it).
	_selection.erase(unit)
	unit.attack_all_intent = false
	if _selected == unit:
		_aiming = false
		_selected = get_selection()[0] if not get_selection().is_empty() else null
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


## The battle's single result for a final `phase`.
func _make_result(phase: Phase) -> void:
	var outcome := {Phase.VICTORY: BattleResult.Outcome.VICTORY, Phase.DEFEAT: BattleResult.Outcome.DEFEAT, Phase.RETREAT: BattleResult.Outcome.RETREAT}[phase] as BattleResult.Outcome
	_result = BattleResult.create(encounter_id, outcome, group_monster_ids)
	# C05: the reward facts at settlement — the EXP pool and the friendly
	# units alive at this moment (where they stand does not matter).
	_result.exp_pool = _exp_pool
	for friend in _friends:
		if friend.alive:
			_result.survivor_ids.append(friend.id)


func _set_phase(phase: Phase) -> void:
	if phase == _phase:
		return
	_phase = phase
	# C08 全體進攻: the continuous attack ends with the fighting.
	if phase != Phase.FIGHTING:
		for friend in _friends:
			friend.attack_all_intent = false
	if is_over():
		_aiming = false
		_gesture_open = false
		_make_result(phase)
	print("Myrial: combat phase ", Phase.keys()[phase], " at ", _elapsed_ms, " ms")
	phase_changed.emit(phase)
