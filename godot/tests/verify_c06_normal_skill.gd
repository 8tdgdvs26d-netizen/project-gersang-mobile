extends SceneTree

## Combat C06: Normal Skill. Every friendly unit has one Normal Skill and 100
## MP (full every battle, no regeneration). A Skill costs 25 MP when its cast
## begins, casts 1 s (no movement, no Basic Attack, ordinary commands refused,
## location locked) and starts an 8 s cooldown when it resolves.
## Stage 8 iPhone L3 corrective (approved behaviour change): Guard is on self;
## the Hero's Slow needs no target and lands on every alive enemy (cast at
## once); the AoE is aimed at a battlefield cell and approaches it until it
## is within the Skill range.
## Hero: Slow (every alive enemy, 5 s: step time and new Basic Attack
## intervals x2).
## Merc A: Guard (self, 5 s: incoming damage floor(x 0.5)). Merc B: AoE (5
## cells, 40 damage to enemies on the target cell + its 4 orthogonal
## neighbours, locked when the cast begins). Effects refresh, never stack.
## FIGHTING only; a retreat cancels pending / casting Skills.

const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const T0 := 1800000000000

var _checks := 0
var _failures := 0
var _sections_done := []
var _hits := []
var _resolved := []


func _initialize() -> void:
	_verify_static()
	_verify_availability()
	_verify_guard_cast_cooldown_mp()
	_verify_guard_while_moving()
	_verify_slow()
	_verify_approach()
	_verify_target_death()
	_verify_priority()
	_verify_retreat()
	_verify_aoe()
	_verify_settlement()
	_verify_stress()
	await _verify_in_game()
	_check(_sections_done.size() == 13, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("C06 normal skill verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(CombatConfig.MAX_MP == 100 and CombatConfig.SKILL_MP_COST == 25 and CombatConfig.SKILL_CAST_MS == 1000 and CombatConfig.SKILL_COOLDOWN_MS == 8000 and CombatConfig.SKILL_EFFECT_MS == 5000, "MP 100, cost 25, cast 1 s, cooldown 8 s, effects 5 s")
	_check(CombatConfig.SLOW_FACTOR == 2 and CombatConfig.GUARD_DIVISOR == 2 and CombatConfig.AOE_DAMAGE == 40, "Slow x2, Guard floor(x 0.5), AoE 40")
	_check(CombatConfig.HERO_SKILL == {"kind": "slow", "range": 3, "target": "all_enemies"} and CombatConfig.MERC_A_SKILL == {"kind": "guard", "range": 0, "target": "self"} and CombatConfig.MERC_B_SKILL == {"kind": "aoe", "range": 5, "target": "ground"}, "Hero Slow (every enemy), Merc A Guard (self), Merc B AoE (ground, 5)")
	_check(CombatConfig.HERO["attack_range"] == 1 and CombatConfig.MERC_B["attack_range"] == 3 and CombatConfig.ENEMY["move_speed"] == 2.0 and CombatConfig.ENEMY["attack_interval_ms"] == 1500, "Basic stats unchanged")
	var battle := CombatBattle.create(10)
	var friends := battle.get_friends()
	_check(friends.all(func(u: CombatUnit) -> bool: return u.mp == u.max_mp and u.max_mp == (200 if u.is_hero else 100) and u.skill_state == CombatUnit.SkillState.NONE), "Every friendly unit starts full: Hero 200 / 200 (C07), Mercenaries 100 / 100, no Skill running")
	_check(friends[0].skill == CombatConfig.HERO_SKILL and friends[1].skill == CombatConfig.MERC_A_SKILL and friends[2].skill == CombatConfig.MERC_B_SKILL, "One Normal Skill each")
	_check(battle.get_enemies().all(func(u: CombatUnit) -> bool: return u.skill.is_empty() and u.mp == 0 and battle.get_skill_readiness(u) == CombatBattle.SkillReadiness.UNAVAILABLE), "Enemies have no Skill and no MP")
	var again := CombatBattle.create(10)
	_check(again.get_friends()[1].mp == 100, "MP never carries over: a new battle starts full")
	_check(SaveStore.VERSION == 14 and SaveStore.V9_KEYS.size() == 9, "Save v13 (Stage 9 P01) (S05 adds only the allocation; nothing from this WP)")
	for path in ["res://scripts/save_store.gd", "res://scripts/progression_state.gd", "res://scripts/main.gd", "res://scripts/battle_result.gd"]:
		var code := _code_only(path).to_lower()
		_check(not code.contains("skill") and not code.contains("guard_") and not code.contains("slow"), "%s knows nothing about Skills" % path.get_file())
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_config.gd", "res://scripts/combat_view.gd"]:
		var code := _code_only(path).to_lower()
		# ("level" is C05's result text in the view; the rules files are pinned by C05.)
		# C08 brought Select All and the camera into scope ("select_all" and "camera" left the list).
		for word in ["regen", "potion", "crit", "element", "resist", "mana", "box_select", "equipment", "strength", "intelligence", "ultimate", "talent"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	_sections_done.append("static")


# --- Availability ------------------------------------------------------------------------------

func _verify_availability() -> void:
	var battle := CombatBattle.create(10)
	var hero := battle.get_hero()
	var enemy := battle.get_enemies()[0]
	_check(battle.get_friends().all(func(u: CombatUnit) -> bool: return battle.get_skill_readiness(u) == CombatBattle.SkillReadiness.UNAVAILABLE), "PREPARATION: no Skill available")
	_check(not battle.command_skill(enemy) and not battle.start_skill_aim() and not battle.is_aiming() and hero.skill_state == CombatUnit.SkillState.NONE, "PREPARATION: Skill command and aim refused")
	_check(battle.command_move(Vector2i(2, 2)), "PREPARATION: the approved preparation moves still work")
	battle.advance(CombatConfig.PREPARATION_MS)
	_check(battle.get_friends().all(func(u: CombatUnit) -> bool: return battle.get_skill_readiness(u) == CombatBattle.SkillReadiness.READY), "FIGHTING: every Skill ready")
	battle.start_retreat()
	_check(battle.get_skill_readiness(hero) == CombatBattle.SkillReadiness.UNAVAILABLE and not battle.command_skill(enemy) and not battle.start_skill_aim(), "Retreating: no Skill")
	battle.cancel_retreat()
	_check(battle.get_skill_readiness(hero) == CombatBattle.SkillReadiness.READY, "Retreat cancelled: available again")
	battle.resolve_damage(enemy, battle.get_friends()[1], 1000)
	_check(battle.get_skill_readiness(battle.get_friends()[1]) == CombatBattle.SkillReadiness.UNAVAILABLE, "A dead unit has no Skill")
	for each in battle.get_enemies():
		battle.resolve_damage(hero, each, 1000)
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY and battle.get_skill_readiness(hero) == CombatBattle.SkillReadiness.UNAVAILABLE and not battle.command_skill(enemy), "VICTORY: no Skill")
	_sections_done.append("availability")


# --- Guard, cast, cooldown, MP -----------------------------------------------------------------

func _verify_guard_cast_cooldown_mp() -> void:
	var battle := _fight(10)
	var warrior := battle.get_friends()[1]
	var enemy := battle.get_enemies()[0]
	var cell := warrior.cell
	battle.select_unit(warrior)
	var cast_at := battle.get_elapsed_ms()
	_check(battle.command_skill() and warrior.skill_state == CombatUnit.SkillState.CASTING and warrior.skill_target == warrior and warrior.mp == 75 and warrior.cast_end_ms == cast_at + 1000 and warrior.cell == cell, "Guard on self: the cast begins at the command (no approach, no wait), 25 MP paid")
	_check(battle.get_skill_cooldown_remaining(warrior) == 0 and battle.get_guard_remaining(warrior) == 0, "Casting: no cooldown, no Guard yet")
	_check(not battle.command_move(Vector2i(5, 1)) and not battle.command_target(enemy) and not battle.command_skill() and battle.get_skill_readiness(warrior) == CombatBattle.SkillReadiness.CASTING, "Casting: Move / Target / Skill commands refused")
	battle.advance(999)
	_check(warrior.skill_state == CombatUnit.SkillState.CASTING and battle.get_cast_remaining(warrior) == 1 and warrior.cell == cell and not warrior.is_moving() and not warrior.has_goal and warrior.target == null, "999 ms: still casting, not moved")
	battle.advance(1)
	var resolved_at := battle.get_elapsed_ms()
	_check(warrior.skill_state == CombatUnit.SkillState.NONE and battle.get_guard_remaining(warrior) == 5000 and battle.get_skill_cooldown_remaining(warrior) == 8000, "1000 ms: Guard 5 s, cooldown 8 s")
	_check(battle.get_skill_readiness(warrior) == CombatBattle.SkillReadiness.COOLDOWN and not battle.command_skill(), "Cooldown: Skill refused")
	var hp := warrior.hp
	_check(battle.resolve_damage(enemy, warrior, 4) == 2 and warrior.hp == hp - 2, "Guard: 4 -> 2")
	_check(battle.resolve_damage(enemy, warrior, 5) == 2 and warrior.hp == hp - 4, "Guard: odd 5 -> floor(2.5) = 2")
	_check(battle.resolve_damage(enemy, warrior, 1) == 0 and warrior.hp == hp - 4, "Guard: 1 -> floor(0.5) = 0")
	_check(battle.resolve_damage(enemy, battle.get_hero(), 4) == 4, "Guard protects only Merc A")
	battle.advance(3000)
	_check(battle.get_guard_remaining(warrior) == 2000, "Guard counts down (2 s left)")
	# Re-applied while active (cooldown forced; 8 s cooldown > 5 s Guard in play).
	var second := _cast(battle, warrior, null)
	_check(battle.get_guard_remaining(warrior) == 5000 and warrior.mp == 50, "Re-applied with 2 s left: refreshed to 5 s (not 7 s)")
	hp = warrior.hp
	_check(battle.resolve_damage(enemy, warrior, 8) == 4 and warrior.hp == hp - 4, "Not stacked: 8 -> 4 (not 2)")
	battle.advance(4999)
	_check(battle.get_guard_remaining(warrior) == 1 and battle.resolve_damage(enemy, warrior, 8) == 4, "4999 ms: still guarded")
	battle.advance(1)
	_check(battle.get_guard_remaining(warrior) == 0 and battle.resolve_damage(enemy, warrior, 8) == 8, "5000 ms: Guard over, full damage")
	_check(battle.get_elapsed_ms() - second == 5000 and battle.get_skill_cooldown_remaining(warrior) == 3000, "Cooldown measured from the resolution")
	battle.advance(2999)
	_check(battle.get_skill_readiness(warrior) == CombatBattle.SkillReadiness.COOLDOWN, "7999 ms after resolving: cooling down")
	battle.advance(1)
	_check(battle.get_skill_readiness(warrior) == CombatBattle.SkillReadiness.READY and resolved_at > 0, "8000 ms: ready again")
	_cast(battle, warrior, null)
	_cast(battle, warrior, null)
	_check(warrior.mp == 0, "Four casts: 100 -> 0 MP (no regeneration)")
	warrior.skill_ready_at_ms = battle.get_elapsed_ms()
	_check(battle.get_skill_readiness(warrior) == CombatBattle.SkillReadiness.NO_MP and not battle.command_skill() and not battle.start_skill_aim() and warrior.skill_state == CombatUnit.SkillState.NONE, "0 MP: Skill refused")
	warrior.mp = 24
	_check(battle.get_skill_readiness(warrior) == CombatBattle.SkillReadiness.NO_MP and not battle.command_skill(), "24 MP < 25: refused")
	warrior.mp = 25
	_check(battle.command_skill(), "25 MP: allowed")
	battle.advance(10)
	_check(warrior.mp == 0 and warrior.skill_state == CombatUnit.SkillState.CASTING, "25 MP: cast, 0 left")
	battle.advance(60000)
	_check(warrior.mp == 0 or not warrior.alive, "No MP regeneration over a minute")
	_sections_done.append("guard_cast_cooldown_mp")


# --- Guard priority while moving (C06 fix) ----------------------------------------------------

## Merc A in the middle of a step: Guard begins its cast at the command; the
## unit freezes where it is (step progress, next cell and claimed destination
## kept), resolves on time, then finishes the step and resumes its move.
func _verify_guard_while_moving() -> void:
	var battle := _fight(10)
	var warrior := battle.get_friends()[1]
	battle.select_unit(warrior)
	_check(battle.command_move(Vector2i(8, 1)), "Merc A ordered to (8, 1)")
	battle.advance(100)
	var cell := warrior.cell
	var next_cell := warrior.next_cell
	var progress := warrior.step_progress_ms
	var claim := warrior.claim
	var visual := warrior.visual_cell()
	_check(warrior.is_moving() and progress == 100 and progress < warrior.step_ms() and claim == Vector2i(8, 1), "Mid-step: 100 of %d ms toward %s, claiming (8, 1)" % [warrior.step_ms(), str(next_cell)])
	var ordered_at := battle.get_elapsed_ms()
	_check(battle.command_skill(), "Guard ordered mid-step")
	_check(warrior.skill_state == CombatUnit.SkillState.CASTING and warrior.mp == 75 and warrior.cast_end_ms == ordered_at + 1000, "The cast begins at once (not after the step), 25 MP paid")
	_check(not warrior.has_goal and warrior.resume_has_goal and warrior.resume_goal == Vector2i(8, 1), "The move order is set aside for the Skill")
	_check(_occupancy_ok(battle), "Occupancy valid at the cast start")
	battle.advance(500)
	_check(warrior.cell == cell and warrior.next_cell == next_cell and warrior.step_progress_ms == progress and warrior.claim == claim and warrior.visual_cell() == visual, "500 ms into the cast: frozen (no step progress, same claim)")
	_check(_occupancy_ok(battle), "Occupancy valid during the cast")
	battle.advance(499)
	_check(warrior.skill_state == CombatUnit.SkillState.CASTING and warrior.step_progress_ms == progress and warrior.cell == cell, "999 ms: still casting, still frozen")
	battle.advance(1)
	_check(warrior.skill_state == CombatUnit.SkillState.NONE and battle.get_guard_remaining(warrior) == 5000 and battle.get_skill_cooldown_remaining(warrior) == 8000 and warrior.mp == 75, "1000 ms: Guard 5 s, cooldown 8 s")
	_check(warrior.has_goal and warrior.goal == Vector2i(8, 1) and warrior.step_progress_ms == progress, "Resolved: the move order resumes")
	battle.advance(warrior.step_ms() - progress - 1)
	_check(warrior.cell == cell and warrior.is_moving(), "The interrupted step finishes from where it froze (1 ms left)")
	battle.advance(1)
	_check(warrior.cell == next_cell, "The step completes onto its next cell")
	_check(_occupancy_ok(battle), "Occupancy valid after the cast")
	battle.advance(3000)
	_check(warrior.cell == Vector2i(8, 1) and not warrior.has_goal and _occupancy_ok(battle), "Merc A arrives at (8, 1)")
	_sections_done.append("guard_while_moving")


## No two alive units claim one cell and no two standing alive units share a
## cell.
func _occupancy_ok(battle: CombatBattle) -> bool:
	var claims := {}
	var standing := {}
	for unit in battle.get_friends() + battle.get_enemies():
		if not unit.alive:
			continue
		if unit.claim != CombatUnit.NO_CELL:
			if claims.has(unit.claim):
				return false
			claims[unit.claim] = true
		if not unit.is_moving():
			if standing.has(unit.cell):
				return false
			standing[unit.cell] = true
	return true


# --- Hero Slow ---------------------------------------------------------------------------------

func _verify_slow() -> void:
	var battle := _fight(10, 2)
	var hero := battle.get_hero()
	var target := battle.get_enemies()[0]
	var other := battle.get_enemies()[1]
	_place(hero, Vector2i(10, 2))
	_place(target, Vector2i(13, 2))
	battle.select_unit(hero)
	_check(battle.command_skill(), "Slow ordered (no target needed)")
	_check(hero.skill_state == CombatUnit.SkillState.CASTING and hero.cell == Vector2i(10, 2) and hero.skill_target == null and hero.mp == 175 and hero.cast_end_ms == battle.get_elapsed_ms() + 1000, "No target: cast at once, no approach")
	# Enemies far away when it lands are slowed all the same.
	_place(target, Vector2i(30, 0))
	_place(other, Vector2i(50, 4))
	battle.advance(999)
	# An attack interval already running when the Slow lands is not stretched.
	target.attack_cooldown_ms = 700
	battle.advance(1)
	var resolved_at := battle.get_elapsed_ms()
	_check(hero.skill_state == CombatUnit.SkillState.NONE and battle.get_slow_remaining(target) == 5000 and battle.get_slow_remaining(other) == 5000, "Every alive enemy slowed 5 s, wherever it stands")
	_check(target.step_ms() == 1000 and other.step_ms() == 1000, "Step time x2 (500 -> 1000 ms)")
	battle.advance(100)
	_check(target.attack_cooldown_ms == 599, "Slow landing on a running interval: unchanged (700 -> 599, %d)" % target.attack_cooldown_ms)
	_place(target, Vector2i(40, 0))
	_place(other, Vector2i(40, 4))
	# An unslowed enemy in a battle without the Slow, for comparison.
	var control := _fight(10, 1)
	_place(control.get_enemies()[0], Vector2i(40, 4))
	control.advance(2000)
	battle.advance(2000)
	_check(target.cell.x == 38 and other.cell.x == 38 and control.get_enemies()[0].cell.x == 36, "2 s: slowed enemies 2 cells, an unslowed enemy 4 cells (%d / %d / %d)" % [target.cell.x, other.cell.x, control.get_enemies()[0].cell.x])
	# Basic Attack interval: one already running is unchanged, a new one is x2.
	# (The other enemy leaves so nobody else claims the cell next to the Hero.)
	battle.resolve_damage(hero, other, 1000)
	_place(target, Vector2i(11, 2))
	target.attack_cooldown_ms = 600
	battle.advance(100)
	_check(target.attack_cooldown_ms == 500, "A running attack interval is not stretched (600 -> 500)")
	battle.advance(500)
	_check(target.attack_cooldown_ms == 3000, "The next interval while slowed: 1500 x2 = 3000 (%d)" % target.attack_cooldown_ms)
	# Re-applied with 2 s left: refreshed, not stacked.
	var now := battle.get_elapsed_ms()
	battle.advance(resolved_at + 3000 - now)
	_check(battle.get_slow_remaining(target) == 2000, "Slow counts down (2 s left)")
	var again := _cast(battle, hero, target)
	_check(battle.get_slow_remaining(target) == 5000 and target.step_ms() == 1000 and hero.mp == 150, "Re-applied: back to 5 s, still x2 (not x4)")
	target.attack_cooldown_ms = 0
	battle.advance(10)
	_check(target.attack_cooldown_ms == 3000, "Still x2 after the refresh (not x4)")
	battle.advance(again + 4999 - battle.get_elapsed_ms())
	_check(battle.get_slow_remaining(target) == 1, "4999 ms: still slowed")
	battle.advance(1)
	_check(battle.get_slow_remaining(target) == 0, "5000 ms: Slow over")
	battle.advance(10)
	_check(target.step_ms() == 500 and not target.slowed, "After the Slow: normal step time")
	target.attack_cooldown_ms = 0
	_place(target, Vector2i(11, 2))
	_place(hero, Vector2i(10, 2))
	battle.advance(10)
	_check(target.attack_cooldown_ms == 1500, "After the Slow: a new interval is 1500 again (%d)" % target.attack_cooldown_ms)
	# No range limit: every enemy 40+ cells away is slowed, no approach.
	var far := _fight(10, 3)
	var far_hero := far.get_hero()
	_place(far_hero, Vector2i(10, 2))
	far.select_unit(far_hero)
	far.command_skill(far.get_enemies()[0])
	_check(far_hero.skill_state == CombatUnit.SkillState.CASTING and far_hero.mp == 175 and not far_hero.is_moving() and far_hero.skill_target == null, "Enemies far out: cast at once, no approach (an enemy given is ignored)")
	far.advance(1010)
	_check(far.get_enemies().slice(0, 3).all(func(e: CombatUnit) -> bool: return far.get_slow_remaining(e) > 4900) and far.get_enemies().slice(3).all(func(e: CombatUnit) -> bool: return far.get_slow_remaining(e) == 0), "Every alive enemy slowed; the dead get nothing")
	_sections_done.append("slow")


# --- Auto-approach -----------------------------------------------------------------------------

func _verify_approach() -> void:
	var battle := _fight(10, 2)
	var hero := battle.get_hero()
	var mage := battle.get_friends()[2]
	var slow_target := battle.get_enemies()[0]
	var aoe_target := battle.get_enemies()[1]
	battle.select_unit(mage)
	battle.command_skill(aoe_target)
	var locked := aoe_target.cell
	battle.select_unit(hero)
	battle.command_skill(slow_target)
	var start_x := mage.cell.x
	var paid_early := false
	var cooled_early := false
	var cast_distance := {}
	var hero_cast_end := hero.cast_end_ms
	for step in range(3000):
		battle.advance(10)
		for unit: CombatUnit in [hero, mage]:
			if unit.skill_state == CombatUnit.SkillState.PENDING:
				paid_early = paid_early or unit.mp != unit.max_mp
				cooled_early = cooled_early or battle.get_skill_cooldown_remaining(unit) > 0
			elif unit.skill_state == CombatUnit.SkillState.CASTING and not cast_distance.has(unit.id):
				cast_distance[unit.id] = [CombatUnit.grid_distance(unit.cell, unit.skill_cell), unit.mp, battle.get_skill_cooldown_remaining(unit), unit.is_moving(), unit.skill_cell]
		if cast_distance.size() == 2:
			break
	_check(not paid_early and not cooled_early, "Approaching: no MP paid, no cooldown")
	_check(cast_distance.has("merc_b") and cast_distance["merc_b"][0] <= 5 and cast_distance["merc_b"][0] > 1 and cast_distance["merc_b"][1] == 75 and cast_distance["merc_b"][2] == 0 and not cast_distance["merc_b"][3], "Mage cast once within 5 cells, standing, MP paid, no cooldown yet (%s)" % str(cast_distance.get("merc_b")))
	_check(cast_distance.has("merc_b") and cast_distance["merc_b"][4] == locked, "Mage cast on the location ordered, not where the enemy went (%s)" % str(cast_distance.get("merc_b")))
	_check(cast_distance.has("hero") and cast_distance["hero"][0] == 0 and cast_distance["hero"][1] == 175, "Hero Slow cast where the Hero stood, no approach, MP paid (%s)" % str(cast_distance.get("hero")))
	_check(mage.cell.x > start_x + 10, "The Mage walked toward its target (%d -> %d)" % [start_x, mage.cell.x])
	battle.advance(1000)
	_check(battle.get_skill_cooldown_remaining(mage) > 7000 and hero.skill_ready_at_ms == hero_cast_end + 8000, "Resolved: cooldowns started (the Hero's when its Slow resolved)")
	_sections_done.append("approach")


# --- Target death ------------------------------------------------------------------------------

func _verify_target_death() -> void:
	# Stage 8: a ground Skill has no target. An enemy dying on the chosen cell
	# before the cast cancels nothing: the Mage still goes there and casts.
	var battle := _fight(10, 3)
	var mage := battle.get_friends()[2]
	var warrior := battle.get_friends()[1]
	var on_cell := battle.get_enemies()[0]
	var attack_target := battle.get_enemies()[1]
	battle.select_unit(mage)
	battle.command_target(attack_target)
	battle.command_skill(on_cell)
	var spot := mage.skill_cell
	battle.advance(100)
	_check(mage.skill_state == CombatUnit.SkillState.PENDING and mage.target == null and mage.skill_target == null and spot == on_cell.cell, "Pending AoE on the enemy's cell (no target kept)")
	battle.resolve_damage(warrior, on_cell, 1000)
	_check(mage.skill_state == CombatUnit.SkillState.PENDING and mage.skill_cell == spot and mage.mp == 100 and battle.get_skill_cooldown_remaining(mage) == 0, "The enemy on the cell died: still pending on the same cell, nothing paid")
	for step in range(3000):
		battle.advance(10)
		if mage.skill_state != CombatUnit.SkillState.PENDING:
			break
	_check(mage.skill_state == CombatUnit.SkillState.CASTING and CombatUnit.grid_distance(mage.cell, spot) <= 5 and mage.mp == 75, "The Mage reached the range and cast on the cell")
	battle.advance(1000)
	_check(mage.skill_state == CombatUnit.SkillState.NONE and battle.get_last_aoe()["cells"] == CombatBattle.aoe_cells(spot) and mage.target == attack_target, "Resolved on the cell; the earlier target order resumes")
	# The Hero's Slow: an enemy dying during the cast gets nothing, the rest do.
	var after := _fight(10, 3)
	var after_hero := after.get_hero()
	var dying := after.get_enemies()[0]
	after.select_unit(after_hero)
	after.command_skill()
	after.advance(10)
	after.resolve_damage(after.get_friends()[1], dying, 1000)
	_check(after_hero.skill_state == CombatUnit.SkillState.CASTING and after_hero.mp == 175, "An enemy died during the cast: still casting")
	after.advance(1000)
	_check(after_hero.skill_state == CombatUnit.SkillState.NONE and after_hero.mp == 175 and after.get_skill_cooldown_remaining(after_hero) == 8000, "Resolved: MP spent, cooldown started")
	_check(after.get_slow_remaining(dying) == 0 and after.get_enemies().slice(1, 3).all(func(e: CombatUnit) -> bool: return after.get_slow_remaining(e) > 0) and after_hero.target == null, "The dead enemy gets no Slow, the living do, no new target")
	_sections_done.append("target_death")


# --- Command priority & resume -----------------------------------------------------------------

func _verify_priority() -> void:
	# (Stage 8: only ground Skills wait, so the Mage's AoE is the pending one.)
	var battle := _fight(10, 3)
	var mage := battle.get_friends()[2]
	var near := battle.get_enemies()[0]
	var far := battle.get_enemies()[1]
	_place(far, Vector2i(50, 0))
	battle.select_unit(mage)
	battle.command_target(far)
	_check(battle.command_skill(near) and mage.target == null and not mage.has_goal and mage.skill_state == CombatUnit.SkillState.PENDING, "Skill command replaces the target order at once")
	_check(battle.command_target(far) and mage.skill_state == CombatUnit.SkillState.NONE and mage.target == far and mage.mp == 100 and battle.get_skill_cooldown_remaining(mage) == 0, "Pending + new Target: Skill cancelled for free")
	battle.command_skill(near)
	_check(battle.command_move(Vector2i(5, 2)) and mage.skill_state == CombatUnit.SkillState.NONE and mage.has_goal and mage.goal == Vector2i(5, 2) and mage.mp == 100, "Pending + new Move: Skill cancelled for free")
	battle.command_skill(near)
	_check(battle.command_skill(far) and mage.skill_cell == Vector2i(50, 0) and mage.skill_state == CombatUnit.SkillState.PENDING, "A new Skill command re-aims the pending Skill")
	# Casting blocks Basic Attacks; afterwards the earlier target resumes.
	var fight := _fight(10, 3)
	var fight_hero := fight.get_hero()
	var adjacent := fight.get_enemies()[0]
	var slowed := fight.get_enemies()[1]
	_place(fight_hero, Vector2i(10, 2))
	_place(adjacent, Vector2i(11, 2))
	_place(slowed, Vector2i(13, 0))
	fight.select_unit(fight_hero)
	fight.command_target(adjacent)
	fight.advance(10)
	fight_hero.attack_cooldown_ms = 0
	_hits.clear()
	fight.damage_dealt.connect(_on_damage)
	fight.command_skill(slowed)
	fight.advance(10)
	_check(fight_hero.skill_state == CombatUnit.SkillState.CASTING, "Casting next to an enemy, attack ready")
	# (Stage 8: the Slow's cast begins at the command, so it ends 1000 ms on.)
	fight.advance(980)
	_check(_hits.filter(func(h: Array) -> bool: return h[0] == fight_hero).is_empty() and fight_hero.cell == Vector2i(10, 2), "No Basic Attack and no movement during the cast")
	fight.advance(10)
	_check(fight_hero.skill_state == CombatUnit.SkillState.NONE and fight_hero.target == adjacent, "Resolved: the earlier target resumes")
	fight.advance(100)
	_check(_hits.any(func(h: Array) -> bool: return h[0] == fight_hero and h[1] == adjacent), "Basic Attacks resume after the cast")
	# A move order resumes too.
	var warrior := fight.get_friends()[1]
	_place(warrior, Vector2i(3, 0))
	fight.select_unit(warrior)
	fight.command_move(Vector2i(8, 0))
	fight.command_skill()
	_check(not warrior.has_goal, "Guard sets the move order aside")
	fight.advance(10)
	fight.advance(1000)
	_check(warrior.skill_state == CombatUnit.SkillState.NONE and warrior.has_goal and warrior.goal == Vector2i(8, 0), "Resolved: the earlier move order resumes")
	_sections_done.append("priority")


# --- Retreat -----------------------------------------------------------------------------------

func _verify_retreat() -> void:
	# Before the cast: cancelled for free.
	var battle := _fight(10, 3)
	var pending := battle.get_friends()[2]
	battle.select_unit(pending)
	battle.command_skill(battle.get_enemies()[0])
	battle.advance(100)
	_check(pending.skill_state == CombatUnit.SkillState.PENDING, "Pending AoE")
	battle.start_retreat()
	_check(pending.skill_state == CombatUnit.SkillState.NONE and pending.mp == 100 and battle.get_skill_cooldown_remaining(pending) == 0 and pending.skill_target == null and pending.skill_cell == CombatUnit.NO_CELL, "Retreat before the cast: cancelled, no MP, no cooldown")
	battle.cancel_retreat()
	_check(battle.get_skill_readiness(pending) == CombatBattle.SkillReadiness.READY, "Retreat cancelled: ready")
	battle.start_retreat()
	battle.advance(3000)
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT, "Nobody stuck: the party escapes")
	# During the cast: cancelled, MP kept spent, no cooldown, no effect.
	var casting := _fight(10, 3)
	var warrior := casting.get_friends()[1]
	var casting_hero := casting.get_hero()
	var mage := casting.get_friends()[2]
	var slow_target := casting.get_enemies()[0]
	var aoe_target := casting.get_enemies()[1]
	_place(casting_hero, Vector2i(10, 2))
	_place(slow_target, Vector2i(12, 2))
	_place(mage, Vector2i(10, 4))
	_place(aoe_target, Vector2i(14, 4))
	for pair in [[warrior, null], [casting_hero, slow_target], [mage, aoe_target]]:
		casting.select_unit(pair[0])
		casting.command_skill(pair[1])
	casting.advance(10)
	_check([warrior, casting_hero, mage].all(func(u: CombatUnit) -> bool: return u.skill_state == CombatUnit.SkillState.CASTING and u.mp == u.max_mp - 25), "All three casting")
	casting.advance(500)
	var aoe_hp := aoe_target.hp
	_check(casting.start_retreat(), "Retreat during the casts")
	_check([warrior, casting_hero, mage].all(func(u: CombatUnit) -> bool: return u.skill_state == CombatUnit.SkillState.NONE and u.mp == u.max_mp - 25 and casting.get_skill_cooldown_remaining(u) == 0), "Cancelled: MP not refunded, no cooldown")
	casting.cancel_retreat()
	casting.advance(600)
	_check(casting.get_guard_remaining(warrior) == 0 and casting.get_enemies().all(func(e: CombatUnit) -> bool: return casting.get_slow_remaining(e) == 0) and aoe_target.hp == aoe_hp and casting.get_last_aoe().is_empty(), "No Guard, no Slow, no AoE after the cancelled casts")
	_check([warrior, casting_hero, mage].all(func(u: CombatUnit) -> bool: return casting.get_skill_readiness(u) == CombatBattle.SkillReadiness.READY), "Usable again at once (no cooldown)")
	_sections_done.append("retreat")


# --- Mage AoE ----------------------------------------------------------------------------------

func _verify_aoe() -> void:
	_check(CombatBattle.aoe_cells(Vector2i(30, 2)) == [Vector2i(30, 2), Vector2i(29, 2), Vector2i(31, 2), Vector2i(30, 1), Vector2i(30, 3)], "AoE: target cell + 4 orthogonal neighbours")
	_check(CombatBattle.aoe_cells(Vector2i(0, 0)).size() == 3 and CombatBattle.aoe_cells(Vector2i(60, 4)).size() == 3 and CombatBattle.aoe_cells(Vector2i(0, 2)).size() == 4 and CombatBattle.aoe_cells(Vector2i(60, 2)).size() == 4, "AoE clipped at the grid edges")
	var layout := {0: Vector2i(20, 2), 1: Vector2i(19, 2), 2: Vector2i(21, 2), 3: Vector2i(20, 1), 4: Vector2i(20, 3), 5: Vector2i(21, 3), 6: Vector2i(22, 2)}
	# Target moved away after the cast began; a friendly unit on the locked cell.
	var battle := _fight(10, 7)
	var mage := battle.get_friends()[2]
	var hero := battle.get_hero()
	var enemies := battle.get_enemies()
	for index in layout:
		enemies[index].max_hp = 100
		enemies[index].hp = 100
	_place(mage, Vector2i(15, 2))
	for index in layout:
		_place(enemies[index], layout[index])
	battle.select_unit(mage)
	battle.command_skill(enemies[0])
	battle.advance(10)
	_check(mage.skill_state == CombatUnit.SkillState.CASTING and mage.skill_cell == Vector2i(20, 2) and mage.cell == Vector2i(15, 2) and mage.mp == 75, "5 cells: cast at once, centre locked on the target's cell")
	battle.advance(999)
	for index in layout:
		_place(enemies[index], layout[index])
	_place(enemies[0], Vector2i(25, 0))
	_place(hero, Vector2i(20, 2))
	var hero_hp := hero.hp
	var merc_a_hp := battle.get_friends()[1].hp
	_hits.clear()
	battle.damage_dealt.connect(_on_damage)
	battle.advance(1)
	var mage_hits := _hits.filter(func(h: Array) -> bool: return h[0] == mage)
	_check(mage_hits.size() == 4 and mage_hits.all(func(h: Array) -> bool: return h[2] == 40), "Four enemies hit, 40 each (%d)" % mage_hits.size())
	_check([1, 2, 3, 4].all(func(i: int) -> bool: return enemies[i].hp == 60) and enemies[5].hp == 100 and enemies[6].hp == 100, "Neighbours hit; diagonal and 2 cells away untouched")
	_check(enemies[0].hp == 100, "The target moved off the locked cell: not hit (location locked, not the unit)")
	_check(not mage_hits.any(func(h: Array) -> bool: return h[1].team == CombatUnit.Team.FRIEND) and battle.get_friends()[1].hp == merc_a_hp and hero_hp - hero.hp == _hits.filter(func(h: Array) -> bool: return h[1] == hero and h[0].team == CombatUnit.Team.ENEMY).reduce(func(sum: int, h: Array) -> int: return sum + h[2], 0), "No Friendly Fire: the Hero on the locked cell loses only what enemies dealt")
	_check(battle.get_last_aoe()["cells"] == CombatBattle.aoe_cells(Vector2i(20, 2)) and battle.get_skill_cooldown_remaining(mage) == 8000 and mage.skill_state == CombatUnit.SkillState.NONE, "AoE recorded; cooldown started")
	# The target dies after the cast began: the AoE still lands on its cell.
	var dead := _fight(10, 7)
	var dead_mage := dead.get_friends()[2]
	var dead_enemies := dead.get_enemies()
	for index in layout:
		dead_enemies[index].max_hp = 100
		dead_enemies[index].hp = 100
	_place(dead_mage, Vector2i(16, 1))
	for index in layout:
		_place(dead_enemies[index], layout[index])
	dead.select_unit(dead_mage)
	dead.command_skill(dead_enemies[0])
	dead.advance(10)
	dead.resolve_damage(dead.get_hero(), dead_enemies[0], 1000)
	_check(dead_mage.skill_state == CombatUnit.SkillState.CASTING, "Target dead during the cast: still casting")
	dead.advance(999)
	for index in [1, 2, 3, 4]:
		_place(dead_enemies[index], layout[index])
	dead.advance(1)
	_check([1, 2, 3, 4].all(func(i: int) -> bool: return dead_enemies[i].hp == 60) and dead_mage.mp == 75 and dead.get_skill_cooldown_remaining(dead_mage) == 8000, "AoE resolved at the locked cell around the dead target")
	# Grid edge.
	var edge := _fight(10, 4)
	var edge_mage := edge.get_friends()[2]
	var edge_enemies := edge.get_enemies()
	var edge_layout := {0: Vector2i(60, 0), 1: Vector2i(59, 0), 2: Vector2i(60, 1), 3: Vector2i(58, 0)}
	_place(edge_mage, Vector2i(55, 0))
	for index in edge_layout:
		edge_enemies[index].max_hp = 100
		edge_enemies[index].hp = 100
		_place(edge_enemies[index], edge_layout[index])
	edge.select_unit(edge_mage)
	edge.command_skill(edge_enemies[0])
	edge.advance(10)
	edge.advance(999)
	for index in edge_layout:
		_place(edge_enemies[index], edge_layout[index])
	edge.advance(1)
	_check(edge_enemies[0].hp == 60 and edge_enemies[1].hp == 60 and edge_enemies[2].hp == 60 and edge_enemies[3].hp == 100 and edge.get_last_aoe()["cells"].size() == 3, "Corner (60, 0): 3 cells, no error")
	_sections_done.append("aoe")


# --- Settlement by Skill -----------------------------------------------------------------------

func _verify_settlement() -> void:
	var battle := _fight(10, 2)
	var mage := battle.get_friends()[2]
	var enemies := battle.get_enemies()
	_check(battle.get_exp_pool() == 80, "8 enemies killed: pool 80")
	_place(mage, Vector2i(15, 2))
	_place(enemies[0], Vector2i(20, 2))
	_place(enemies[1], Vector2i(21, 2))
	var results := []
	battle.phase_changed.connect(func(phase: int) -> void: results.append(phase))
	battle.select_unit(mage)
	battle.command_skill(enemies[0])
	battle.advance(10)
	battle.advance(999)
	_check(mage.skill_state == CombatUnit.SkillState.CASTING, "1 ms before the AoE: still casting")
	_place(enemies[0], Vector2i(20, 2))
	_place(enemies[1], Vector2i(21, 2))
	battle.advance(1)
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY and results == [CombatBattle.Phase.VICTORY] and not enemies[0].alive and not enemies[1].alive, "AoE kills the last two: one VICTORY")
	var result := battle.get_result()
	_check(result != null and result.exp_pool == 100 and battle.get_exp_pool() == 100 and result.survivor_ids.size() == 3, "Skill kills count in the C05 EXP pool (100), survivors as usual")
	_check(mage.skill_state == CombatUnit.SkillState.NONE and mage.mp == 75, "The Skill finished cleanly")
	battle.advance(5000)
	_check(battle.get_result() == result and result.exp_pool == 100, "Nothing changes after the result")
	# Stage 8 P05: the fixture's merc_a / merc_b settle as roster instances.
	var shares := PartyProgression.preview(result, ProgressionState.new(), MercenaryRoster.build([Mercenary.create("merc_a", "GUARDIAN"), Mercenary.create("merc_b", "MAGE")]))
	_check(shares.size() == 3 and shares["merc_b"]["exp"] == 33, "C05 shares: 100 / 3 = 33 each")
	_sections_done.append("settlement")


# --- Stress: every Skill used whenever ready, 20 enemies -----------------------------------------

func _verify_stress() -> void:
	var battle := CombatBattle.create(20)
	battle.advance(CombatConfig.PREPARATION_MS)
	_resolved.clear()
	_hits.clear()
	battle.skill_resolved.connect(func(unit: CombatUnit) -> void: _resolved.append([unit.id, battle.get_elapsed_ms()]))
	battle.damage_dealt.connect(_on_damage)
	var casts := {"hero": 0, "merc_a": 0, "merc_b": 0}
	var mp_ok := true
	var still_while_casting := true
	var cast_cells := {}
	var total_usec := 0
	var worst_usec := 0
	var ticks := 0
	while not battle.is_over() and ticks < 10000:
		# (MP before the commands: Guard pays at its command.)
		var before := {}
		for unit in battle.get_friends():
			before[unit.id] = unit.mp
		for unit in battle.get_friends():
			if not unit.alive:
				continue
			var nearest := _nearest_enemy(battle, unit)
			battle.select_unit(unit)
			if battle.get_skill_readiness(unit) == CombatBattle.SkillReadiness.READY and unit.skill_state == CombatUnit.SkillState.NONE:
				battle.command_skill(nearest)
			elif unit.skill_state == CombatUnit.SkillState.NONE and unit.target == null and nearest != null:
				battle.command_target(nearest)
		_note_cast_positions(battle, cast_cells)
		var started := Time.get_ticks_usec()
		battle.advance(16)
		var spent := Time.get_ticks_usec() - started
		total_usec += spent
		worst_usec = maxi(worst_usec, spent)
		ticks += 1
		for unit in battle.get_friends():
			if unit.mp < before[unit.id]:
				casts[unit.id] += 1
			mp_ok = mp_ok and unit.mp >= 0 and unit.mp == unit.max_mp - 25 * casts[unit.id]
		_note_cast_positions(battle, cast_cells)
		for unit in battle.get_friends():
			if unit.skill_state == CombatUnit.SkillState.CASTING:
				still_while_casting = still_while_casting and cast_cells[[unit.id, unit.cast_end_ms]] == [unit.cell, unit.next_cell, unit.step_progress_ms]
	_check(battle.is_over() and battle.get_result() != null, "20 enemies with Skills: the battle ends (%s after %d ticks)" % [CombatBattle.Phase.keys()[battle.get_phase()], ticks])
	_check(mp_ok and casts.values().all(func(n: int) -> bool: return n <= 4), "MP always full - 25 x casts, never below 0 (%s)" % str(casts))
	_check(still_while_casting and cast_cells.size() == casts.values().reduce(func(sum: int, n: int) -> int: return sum + n, 0), "No unit moved while casting (%d casts tracked)" % cast_cells.size())
	var gaps_ok := true
	var last := {}
	for entry in _resolved:
		if last.has(entry[0]):
			gaps_ok = gaps_ok and entry[1] - last[entry[0]] >= 8000
		last[entry[0]] = entry[1]
	_check(gaps_ok and _resolved.size() >= 3, "Resolutions of one unit at least 8 s apart (%d resolved)" % _resolved.size())
	var dead := battle.get_enemies().filter(func(e: CombatUnit) -> bool: return not e.alive).size()
	_check(battle.get_exp_pool() == dead * 10, "EXP pool = 10 x enemies killed (%d)" % dead)
	_check(not _hits.any(func(h: Array) -> bool: return h[0].team == CombatUnit.Team.FRIEND and h[1].team == CombatUnit.Team.FRIEND), "No friendly unit ever damaged a friendly unit")
	print("C06 stress: %s, %d ticks, avg %.3f ms, worst %.2f ms, casts %s" % [CombatBattle.Phase.keys()[battle.get_phase()], ticks, total_usec / 1000.0 / ticks, worst_usec / 1000.0, str(casts)])
	_sections_done.append("stress")


# --- In game -----------------------------------------------------------------------------------

func _verify_in_game() -> void:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = ""
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	# Stage 8 P04: the game's battle is the Hero + the deployed roster; a
	# deployed 守衛 #1 + 法師 #2 stand in for Merc A / Merc B.
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "MAGE")], ["merc_1", "merc_2"])
	for frame in range(4):
		await physics_frame
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	for frame in range(4):
		await physics_frame
	await process_frame
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	var battle: CombatBattle = main.get_combat()
	var view := main.get_node("CombatView") as CombatView
	var hint := view.get_node("HintLabel") as Label
	await process_frame
	# C08: the single Skill button / MP status line became the skill bar
	# (entries of the selected units), the portraits and the ⓘ info.
	var entry := _skill_entry(view, battle.get_hero(), "slow")
	_check(battle != null and battle.get_phase() == CombatBattle.Phase.PREPARATION and not entry.is_empty() and entry["disabled"] and entry["title"] == "普通技能：緩速　魔力 25" and entry["state"] == "戰鬥開始後可用", "PREPARATION: the Hero's Skill shown, disabled (%s)" % str(entry.get("text")))
	_check(view.get_info_text(battle.get_hero()).contains("魔力 200 / 200") and view.get_info_text(battle.get_friends()[1]).contains("魔力 100 / 100") and view.get_info_text(battle.get_friends()[2]).contains("魔力 100 / 100"), "PREPARATION: MP shown (info)")
	var prep_texts := [entry["text"], view.get_info_text(battle.get_hero())]
	for friend in battle.get_friends():
		_check(view.tap_at(view.cell_center(Vector2(friend.cell))) and battle.get_selected() == friend, "PREPARATION: tap %s selects it" % friend.id)
		await process_frame
		var skill_name: String = CombatView.SKILL_NAMES[friend.skill["kind"]]
		entry = _skill_entry(view, friend, friend.skill["kind"])
		_check(not entry.is_empty() and entry["disabled"] and entry["state"] == "戰鬥開始後可用" and entry["title"].contains(skill_name), "PREPARATION: %s shows %s, disabled (%s)" % [friend.id, skill_name, str(entry.get("text"))])
		prep_texts.append(entry["text"])
		view.press_skill_entry(entry)
		await process_frame
		_check(not battle.is_aiming() and friend.skill_state == CombatUnit.SkillState.NONE and friend.mp == friend.max_mp and friend.skill_ready_at_ms == 0 and battle.get_skill_cooldown_remaining(friend) == 0 and not friend.has_goal and friend.target == null, "PREPARATION: pressing %s changes nothing (no aim, pending, cast, MP or cooldown)" % skill_name)
	_check(battle.get_phase() == CombatBattle.Phase.PREPARATION, "Still PREPARATION after the presses")
	battle.select_unit(battle.get_hero())
	battle.advance(CombatConfig.PREPARATION_MS)
	await process_frame
	var hero := battle.get_hero()
	var warrior := battle.get_friends()[1]
	entry = _skill_entry(view, hero, "slow")
	_check(not entry["disabled"] and entry["state"] == "可用", "FIGHTING: 緩速 ready for the selected Hero (%s)" % entry["text"])
	_check(view.get_info_text(hero).contains("魔力 200 / 200") and view.get_info_text(warrior).contains("魔力 100 / 100"), "Every unit's MP shown (info)")
	var texts := [entry["text"], view.get_info_text(hero)]
	texts.append_array(prep_texts)
	view.press_skill_entry(entry)
	await process_frame
	entry = _skill_entry(view, hero, "slow")
	# Stage 8: the Hero's Slow needs no target: pressed, it casts at once.
	_check(not battle.is_aiming() and hero.skill_state == CombatUnit.SkillState.CASTING and hero.skill_target == null and hero.mp == 175 and not hint.visible, "Skill pressed: Slow cast at once, no aiming (%s)" % entry["text"])
	await process_frame
	entry = _skill_entry(view, hero, "slow")
	_check(entry["state"] == "施法中…" and view.get_info_text(hero).contains("魔力 175 / 200"), "Hero casting shown (%s)" % entry["text"])
	texts.append(entry["text"])
	# The Mage's AoE is aimed at a battlefield location.
	var mage := battle.get_friends()[2]
	_check(view.tap_at(view.cell_center(Vector2(mage.cell))) and battle.get_selected() == mage, "Tap the Mage: selected")
	view.press_skill_entry(_skill_entry(view, mage, "aoe"))
	await process_frame
	entry = _skill_entry(view, mage, "aoe")
	_check(battle.is_aiming() and entry["state"] == "選擇位置" and hint.visible and hint.text == "點戰場位置施放技能　再按技能取消", "Mage Skill pressed: aiming a location (%s / %s)" % [entry["text"], hint.text])
	texts.append_array([entry["text"], hint.text])
	view.press_skill_entry(entry)
	await process_frame
	_check(not battle.is_aiming() and not mage.has_goal and mage.skill_state == CombatUnit.SkillState.NONE and not hint.visible, "Skill pressed again: aim cancelled, no move; the prompt disappears")
	view.press_skill_entry(_skill_entry(view, mage, "aoe"))
	_check(view.tap_at(view.cell_center(Vector2(8, 0))) and mage.skill_state == CombatUnit.SkillState.PENDING and mage.skill_target == null and mage.skill_cell == Vector2i(8, 0), "Tap an empty cell: AoE ordered on that location")
	await process_frame
	entry = _skill_entry(view, mage, "aoe")
	_check(entry["state"] == "接近位置" and view.get_info_text(mage).contains("魔力 100 / 100"), "Approaching shown (%s)" % entry["text"])
	texts.append(entry["text"])
	_check(view.tap_at(view.cell_center(Vector2(warrior.cell))) and battle.get_selected() == warrior, "Tap Merc A: selected")
	await process_frame
	entry = _skill_entry(view, warrior, "guard")
	_check(entry["title"] == "普通技能：守護　魔力 25" and entry["state"] == "可用", "Merc A: 守護 ready (%s)" % entry["text"])
	view.press_skill_entry(entry)
	_check(warrior.skill_state == CombatUnit.SkillState.CASTING and warrior.mp == 75 and not battle.is_aiming(), "Guard: cast at once, no aiming")
	battle.advance(10)
	await process_frame
	entry = _skill_entry(view, warrior, "guard")
	_check(entry["state"] == "施法中…" and entry["disabled"] and view.get_info_text(warrior).contains("魔力 75 / 100"), "Casting shown (%s)" % entry["text"])
	texts.append(entry["text"])
	battle.advance(1000)
	await process_frame
	entry = _skill_entry(view, warrior, "guard")
	_check(entry["state"].begins_with("冷卻 ") and entry["state"].ends_with(" 秒") and view.get_info_text(warrior).contains("守護中 "), "Cooldown and Guard shown (%s / %s)" % [entry["text"], view.get_info_text(warrior)])
	texts.append_array([entry["text"], view.get_info_text(warrior)])
	warrior.skill_ready_at_ms = 0
	warrior.mp = 0
	await process_frame
	entry = _skill_entry(view, warrior, "guard")
	_check(entry["state"] == "魔力不足" and entry["disabled"], "No MP shown (%s)" % entry["text"])
	texts.append(entry["text"])
	# M2-07A rule: only the standalone A / B / E are approved Latin (傭兵A / 傭兵B).
	var latin := RegEx.new()
	latin.compile("[A-Za-z]")
	var approved := RegEx.new()
	approved.compile("(?<![A-Za-z])[ABE](?![A-Za-z])")
	var with_latin := texts.filter(func(t: String) -> bool: return latin.search(approved.sub(t, "", true)) != null)
	_check(with_latin.is_empty(), "All Skill texts are Traditional Chinese (%s)" % str(with_latin))
	(view.get_node("RetreatButton") as Button).pressed.emit()
	await process_frame
	_check(battle.is_retreating() and view.get_skill_bar_entries().is_empty(), "Retreating: no Skill bar")
	for frame in range(120):
		if battle.is_over():
			break
		await physics_frame
	await process_frame
	_check(battle.is_over() and view.get_skill_bar_entries().is_empty(), "Result: no Skill UI")
	root.remove_child(main)
	main.free()
	await process_frame
	_sections_done.append("in_game")


# --- Helpers -----------------------------------------------------------------------------------

## C08: the skill bar entry of `owner`'s `kind` Skill ({} when not shown).
func _skill_entry(view: CombatView, owner: CombatUnit, kind: String) -> Dictionary:
	for entry in view.get_skill_bar_entries():
		if entry["owner"] == owner and entry["kind"] == kind:
			return entry
	return {}

## A battle in FIGHTING with only the first `alive` enemies left alive.
func _fight(enemies: int, alive: int = -1) -> CombatBattle:
	var battle := CombatBattle.create(enemies)
	battle.advance(CombatConfig.PREPARATION_MS)
	if alive >= 0:
		for index in range(alive, enemies):
			battle.resolve_damage(battle.get_hero(), battle.get_enemies()[index], 1000)
	return battle


## Casts `unit`'s Skill now (cooldown forced to zero) on `target` already in
## range and returns the battle time it resolved.
func _cast(battle: CombatBattle, unit: CombatUnit, target: CombatUnit) -> int:
	unit.skill_ready_at_ms = battle.get_elapsed_ms()
	battle.select_unit(unit)
	if target != null:
		_place(target, unit.cell + Vector2i(2, 0))
	battle.command_skill(target)
	battle.advance(10)
	battle.advance(unit.cast_end_ms - battle.get_elapsed_ms())
	return battle.get_elapsed_ms()


## Records where each cast was when first seen (keyed by unit and cast end):
## a casting unit must stay exactly there (cell, next cell, step progress).
func _note_cast_positions(battle: CombatBattle, positions: Dictionary) -> void:
	for unit in battle.get_friends():
		if unit.skill_state == CombatUnit.SkillState.CASTING and not positions.has([unit.id, unit.cast_end_ms]):
			positions[[unit.id, unit.cast_end_ms]] = [unit.cell, unit.next_cell, unit.step_progress_ms]


func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


func _nearest_enemy(battle: CombatBattle, unit: CombatUnit) -> CombatUnit:
	var best: CombatUnit
	for enemy in battle.get_enemies():
		if enemy.alive and (best == null or CombatUnit.grid_distance(unit.cell, enemy.cell) < CombatUnit.grid_distance(unit.cell, best.cell)):
			best = enemy
	return best


func _on_damage(attacker: CombatUnit, target: CombatUnit, amount: int) -> void:
	_hits.append([attacker, target, amount])


func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
