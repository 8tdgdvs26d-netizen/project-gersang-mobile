extends SceneTree

## Combat C07: Minimum Gesture Skill. The Hero (200 MP, shared with its
## Normal Skill) opens a Gesture Window during FIGHTING, draws ⚡ over a faint
## guide in one stroke and lifts the finger. A deterministic geometric matcher
## scores it 0-100: exactly 100 Perfect (120 damage), 80-99 Success (100),
## 60-79 Partial (50), below 60 Fail (0). Up to 10 random alive enemies are
## hit (seedable). Perfect / Success / Partial cost 50 MP, Fail or the 10 s
## window timeout 25 MP; either way a separate 15 s Gesture cooldown starts.
## While the window is open the battlefield is paused but the Combat Clock
## runs. The Combat Clock starts at 0 with FIGHTING; at 05:00 the C04 retreat
## is forced (not cancellable; an open window closes with no cost), and the
## time limit wins over a Gesture timeout at the same moment.

const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const T0 := 1800000000000
const LIMIT := CombatConfig.COMBAT_TIME_LIMIT_MS

var _checks := 0
var _failures := 0
var _sections_done := []
var _hits := []


func _initialize() -> void:
	_verify_static()
	_verify_matcher()
	_verify_mp_and_availability()
	_verify_normal_skill_interplay()
	_verify_pause()
	_verify_window_timeout()
	_verify_grades_and_damage()
	_verify_targets()
	_verify_cooldowns()
	_verify_combat_clock()
	_verify_time_up()
	_verify_time_up_during_gesture()
	await _verify_in_game()
	_check(_sections_done.size() == 13, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("C07 gesture skill verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(CombatConfig.HERO_MAX_MP == 200 and CombatConfig.MAX_MP == 100 and CombatConfig.SKILL_MP_COST == 25, "Hero 200 MP, Mercenaries 100, Normal Skill 25")
	_check(CombatConfig.GESTURE_MP_COST == 50 and CombatConfig.GESTURE_FAIL_MP_COST == 25 and CombatConfig.GESTURE_COOLDOWN_MS == 15000 and CombatConfig.GESTURE_WINDOW_MS == 10000, "Gesture 50 MP (Fail 25), cooldown 15 s, window 10 s")
	_check(CombatConfig.GESTURE_BASE_DAMAGE == 100 and CombatConfig.GESTURE_DAMAGE_PERCENT == [120, 100, 50, 0] and CombatConfig.GESTURE_MAX_TARGETS == 10, "Damage 120 / 100 / 50 / 0, at most 10 targets")
	_check(CombatConfig.COMBAT_TIME_LIMIT_MS == 300000 and CombatConfig.PREPARATION_MS == 3000, "Combat Clock limit 05:00, preparation 3 s")
	_check(CombatConfig.SKILL_COOLDOWN_MS == 8000 and CombatConfig.SKILL_CAST_MS == 1000 and CombatConfig.MERC_B_SKILL == {"kind": "aoe", "range": 5, "target": "ground"}, "C06 values unchanged (Stage 8: the AoE is ground-targeted)")
	_check(SaveStore.VERSION == 12 and SaveStore.V9_KEYS.size() == 9, "Save v12 (P05) (S05 adds only the allocation)")
	for path in ["res://scripts/save_store.gd", "res://scripts/progression_state.gd", "res://scripts/main.gd", "res://scripts/battle_result.gd"]:
		var code := _code_only(path).to_lower()
		_check(not code.contains("gesture") and not code.contains("clock_ms") and not code.contains("time_limit"), "%s knows nothing about the Gesture / Combat Clock" % path.get_file())
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_view.gd"]:
		var code := _code_only(path).to_lower()
		_check(not code.contains("randi") and not code.contains("randf"), "%s has no random calls (randomness only in GestureTargets)" % path.get_file())
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_config.gd", "res://scripts/combat_view.gd", "res://scripts/gesture_matcher.gd", "res://scripts/gesture_targets.gd"]:
		var code := _code_only(path).to_lower()
		# C08 brought Select All (全體) into scope ("select_all" left the list).
		for word in ["ultimate", "combo", "skill_tree", "mana", "neural", "tensorflow", "regen", "potion", "equipment", "time_scale", "engine.time"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	_sections_done.append("static")


# --- Matcher -----------------------------------------------------------------------------------

func _verify_matcher() -> void:
	var ideal := _ideal()
	_check(GestureMatcher.score(ideal) == 100 and GestureMatcher.grade_for(100) == GestureMatcher.Grade.PERFECT, "Ideal ⚡: 100 Perfect")
	_check(GestureMatcher.score(PackedVector2Array(GestureMatcher.GUIDE)) == 100, "The guide's own 4 points: 100")
	_check(GestureMatcher.score(_wobble(ideal, 0.04)) == 100, "Acceptable variation (±0.04 wobble): still 100")
	var success := GestureMatcher.score(_shift(ideal, Vector2(0.06, 0.0)))
	var partial := GestureMatcher.score(_shift(ideal, Vector2(0.09, 0.0)))
	_check(success == 89 and GestureMatcher.grade_for(success) == GestureMatcher.Grade.SUCCESS, "Shifted 0.06: 89 Success (%d)" % success)
	_check(partial == 72 and GestureMatcher.grade_for(partial) == GestureMatcher.Grade.PARTIAL, "Shifted 0.09: 72 Partial (%d)" % partial)
	var reversed := ideal.duplicate()
	reversed.reverse()
	_check(GestureMatcher.score(reversed) == 0, "Reversed route: 0")
	_check(GestureMatcher.score(_dense([GestureMatcher.GUIDE[0], GestureMatcher.GUIDE[1], Vector2(0.49, 0.5)])) < 60, "Half drawn: Fail")
	_check(GestureMatcher.score(_dense([GestureMatcher.GUIDE[0], GestureMatcher.GUIDE[1], GestureMatcher.GUIDE[2], Vector2(0.52, 0.71)])) < 60, "Three quarters drawn: Fail")
	_check(GestureMatcher.score(_dense([Vector2(0.65, 0.08), Vector2(0.35, 0.92)])) < 60, "Straight line (no turns): Fail")
	_check(GestureMatcher.score(_dense([Vector2(0.35, 0.08), Vector2(0.70, 0.50), Vector2(0.32, 0.50), Vector2(0.65, 0.92)])) < 60, "Mirrored ⚡: Fail")
	_check(GestureMatcher.score(_dense([Vector2(0.2, 0.1), Vector2(0.8, 0.1), Vector2(0.2, 0.9), Vector2(0.8, 0.9)])) == 0, "Z shape: 0")
	_check(GestureMatcher.score(_dense([GestureMatcher.GUIDE[0], Vector2(0.55, 0.2)])) == 0, "Too short (< 30% of the guide): 0")
	_check(GestureMatcher.score(PackedVector2Array([Vector2(0.5, 0.5)])) == 0 and not GestureMatcher.is_submittable(PackedVector2Array([Vector2(0.5, 0.5)])), "Single point: 0, not submittable")
	_check(not GestureMatcher.is_submittable(_dense([Vector2(0.5, 0.5), Vector2(0.52, 0.5)])) and GestureMatcher.is_submittable(_dense([Vector2(0.5, 0.5), Vector2(0.56, 0.5)])), "A touch shorter than 0.05 is not an attempt")
	# A stroke that misses a key turn is capped at 59.
	var no_turn := _dense([Vector2(0.65, 0.08), Vector2(0.42, 0.5), Vector2(0.68, 0.50), Vector2(0.35, 0.92)])
	_check(GestureMatcher.score(no_turn) <= GestureMatcher.MISSED_TURN_CAP, "Missing the left turn: capped below 60 (%d)" % GestureMatcher.score(no_turn))
	_check(GestureMatcher.score(_shift(ideal, Vector2(0.06, 0.0))) == success and GestureMatcher.score(ideal) == 100, "Deterministic: same stroke, same score")
	_check(GestureMatcher.grade_for(99) == GestureMatcher.Grade.SUCCESS and GestureMatcher.grade_for(80) == GestureMatcher.Grade.SUCCESS and GestureMatcher.grade_for(79) == GestureMatcher.Grade.PARTIAL and GestureMatcher.grade_for(60) == GestureMatcher.Grade.PARTIAL and GestureMatcher.grade_for(59) == GestureMatcher.Grade.FAIL and GestureMatcher.grade_for(0) == GestureMatcher.Grade.FAIL, "Grades: 100 / 80-99 / 60-79 / <60")
	_sections_done.append("matcher")


# --- MP & availability -------------------------------------------------------------------------

func _verify_mp_and_availability() -> void:
	var battle := CombatBattle.create(10)
	var hero := battle.get_hero()
	var friends := battle.get_friends()
	_check(hero.mp == 200 and hero.max_mp == 200 and friends[1].mp == 100 and friends[1].max_mp == 100 and friends[2].mp == 100 and friends[2].max_mp == 100, "Hero 200 / 200, Merc A / B 100 / 100")
	_check(battle.get_gesture_readiness() == CombatBattle.GestureReadiness.UNAVAILABLE and not battle.open_gesture() and not battle.is_gesture_open(), "PREPARATION: no Gesture")
	battle.advance(CombatConfig.PREPARATION_MS)
	_check(battle.get_gesture_readiness() == CombatBattle.GestureReadiness.READY, "FIGHTING: Gesture ready")
	# Hero-only: the Gesture is the Hero's whatever is selected; the mercenaries have none.
	battle.select_unit(friends[1])
	_check(friends[1].skill == CombatConfig.MERC_A_SKILL and friends[2].skill == CombatConfig.MERC_B_SKILL and battle.get_hero() == hero, "Mercenaries keep only their Normal Skill (the Gesture is the Hero's)")
	battle.select_unit(hero)
	hero.mp = 49
	_check(battle.get_gesture_readiness() == CombatBattle.GestureReadiness.NO_MP and not battle.open_gesture(), "49 MP: cannot open")
	hero.mp = 50
	_check(battle.open_gesture() and battle.is_gesture_open() and hero.mp == 50, "50 MP: opens, nothing paid yet")
	_check(battle.get_gesture_readiness() == CombatBattle.GestureReadiness.OPEN and not battle.open_gesture(), "Already open: not again")
	battle.submit_gesture(_ideal())
	_check(hero.mp == 0 and not battle.is_gesture_open(), "Resolved: 50 paid at resolution")
	# Normal Skill still costs the Hero 25 from the same pool.
	var skill := _fight(10, 2)
	var skill_hero := skill.get_hero()
	_place(skill_hero, Vector2i(10, 2))
	_place(skill.get_enemies()[0], Vector2i(12, 2))
	skill.command_skill(skill.get_enemies()[0])
	skill.advance(10)
	_check(skill_hero.skill_state == CombatUnit.SkillState.CASTING and skill_hero.mp == 175, "Slow: 200 -> 175 (shared pool)")
	# Retreating / dead Hero / result.
	var other := _fight(10, 3)
	other.start_retreat()
	_check(other.get_gesture_readiness() == CombatBattle.GestureReadiness.UNAVAILABLE and not other.open_gesture(), "Retreating: no Gesture")
	other.cancel_retreat()
	other.resolve_damage(other.get_enemies()[0], other.get_hero(), 1000)
	_check(other.get_gesture_readiness() == CombatBattle.GestureReadiness.UNAVAILABLE and not other.open_gesture(), "Dead Hero: no Gesture")
	_sections_done.append("mp_and_availability")


## D3: casting Hero must wait; a pending Normal Skill is replaced.
func _verify_normal_skill_interplay() -> void:
	var battle := _fight(10, 3)
	var hero := battle.get_hero()
	var near := battle.get_enemies()[0]
	_place(hero, Vector2i(10, 2))
	_place(near, Vector2i(12, 2))
	battle.command_skill(near)
	battle.advance(10)
	_check(hero.skill_state == CombatUnit.SkillState.CASTING and battle.get_gesture_readiness() == CombatBattle.GestureReadiness.CASTING and not battle.open_gesture() and not battle.is_gesture_open(), "Hero casting Slow: Gesture refused")
	battle.advance(1000)
	_check(hero.skill_state == CombatUnit.SkillState.NONE and battle.get_gesture_readiness() == CombatBattle.GestureReadiness.READY, "Cast done: Gesture ready")
	# Stage 8 iPhone L3 corrective: the Hero's Slow needs no target, so it
	# never waits (no pending Slow for the Gesture to replace): even with
	# every enemy far away it casts at once and the Gesture waits for it.
	var pending := _fight(10, 3)
	var pending_hero := pending.get_hero()
	var far := pending.get_enemies()[0]
	var attacked := pending.get_enemies()[1]
	pending.command_target(attacked)
	pending.command_skill(far)
	_check(pending_hero.skill_state == CombatUnit.SkillState.CASTING and pending_hero.mp == 175 and pending_hero.target == null, "Far enemies: the Slow casts at once (never pending)")
	_check(not pending.open_gesture() and not pending.is_gesture_open(), "Gesture refused while that Slow casts")
	pending.advance(1000)
	_check(pending_hero.skill_state == CombatUnit.SkillState.NONE and pending.get_slow_remaining(far) > 0 and pending.get_skill_cooldown_remaining(pending_hero) == 8000, "Resolved: every enemy slowed (also the far one), cooldown started")
	_check(pending_hero.target == attacked, "The order before the Slow comes back")
	_check(pending.open_gesture() and pending.is_gesture_open(), "Cast done: the Gesture opens")
	_sections_done.append("normal_skill_interplay")


# --- Pause ---------------------------------------------------------------------------------------

func _verify_pause() -> void:
	var battle := _fight(10)
	var friends := battle.get_friends()
	var hero := friends[0]
	var warrior := friends[1]
	var enemies := battle.get_enemies()
	# Something running everywhere: a Slow, a Guard cast mid-step, cooldowns, moving enemies.
	_place(hero, Vector2i(10, 2))
	_place(enemies[0], Vector2i(12, 2))
	battle.command_skill(enemies[0])
	battle.advance(10)
	battle.advance(1000)
	battle.select_unit(warrior)
	battle.command_move(Vector2i(8, 1))
	battle.advance(100)
	battle.command_skill()
	battle.advance(300)
	battle.select_unit(hero)
	_check(warrior.skill_state == CombatUnit.SkillState.CASTING and warrior.is_moving() and battle.get_slow_remaining(enemies[0]) > 0 and battle.get_skill_cooldown_remaining(hero) > 0, "Setup: Guard casting mid-step, Slow running, cooldowns running")
	var before := _snapshot(battle)
	var clock := battle.get_combat_clock_ms()
	_hits.clear()
	battle.damage_dealt.connect(_on_damage)
	_check(battle.open_gesture(), "Gesture Window open")
	for step in range(40):
		battle.advance(100)
	_check(_snapshot(battle) == before, "4 s with the window open: every unit, cast, cooldown, Slow, Guard, step and HP unchanged")
	_check(battle.get_elapsed_ms() == before["elapsed"], "Battle time stood still")
	_check(battle.get_combat_clock_ms() == clock + 4000 and battle.get_gesture_remaining_ms() == 6000, "The Combat Clock ran 4 s; the window has 6 s left")
	_check(_hits.is_empty(), "No damage while paused")
	var enemy_cell := enemies[1].cell
	_check(not battle.tap(enemy_cell) and not battle.command_target(enemies[1]) and not battle.command_move(Vector2i(3, 3)) and not battle.command_skill(enemies[1]) and not battle.start_skill_aim() and not battle.select_unit(warrior) and not battle.start_retreat(), "Every battlefield command refused while open")
	_check(battle.get_skill_readiness(friends[2]) == CombatBattle.SkillReadiness.UNAVAILABLE, "Normal Skills unavailable while open")
	_check(_occupancy_ok(battle), "Occupancy valid while paused")
	battle.submit_gesture(_dense([Vector2(0.2, 0.1), Vector2(0.8, 0.1), Vector2(0.2, 0.9), Vector2(0.8, 0.9)]))
	var resumed_at := battle.get_elapsed_ms()
	battle.advance(100)
	_check(not battle.is_gesture_open() and battle.get_elapsed_ms() == resumed_at + 100, "Closed: the battlefield runs again")
	_check(warrior.skill_state == CombatUnit.SkillState.CASTING and battle.get_cast_remaining(warrior) == before["units"][1][8] - 100, "The Guard cast continues where it paused")
	_sections_done.append("pause")


func _verify_window_timeout() -> void:
	var battle := _fight(10)
	var hero := battle.get_hero()
	var opened := battle.get_combat_clock_ms()
	var elapsed := battle.get_elapsed_ms()
	battle.open_gesture()
	battle.advance(9999)
	_check(battle.is_gesture_open() and battle.get_gesture_remaining_ms() == 1 and hero.mp == 200, "9.999 s: still open, nothing paid")
	_hits.clear()
	battle.damage_dealt.connect(_on_damage)
	battle.advance(1)
	var result := battle.get_last_gesture()
	_check(not battle.is_gesture_open() and result["timeout"] and result["grade"] == GestureMatcher.Grade.FAIL and result["targets"].is_empty(), "10 s: closed as a Fail")
	_check(hero.mp == 175 and battle.get_gesture_cooldown_remaining() == 15000 and _hits.is_empty(), "Timeout: 25 MP, 15 s cooldown, no damage")
	_check(battle.get_combat_clock_ms() == opened + 10000 and battle.get_elapsed_ms() == elapsed, "The clock ran 10 s, the battlefield none")
	battle.advance(50)
	_check(battle.get_elapsed_ms() == elapsed + 50, "The battlefield resumes")
	_sections_done.append("window_timeout")


# --- Grades & damage ---------------------------------------------------------------------------

func _verify_grades_and_damage() -> void:
	var cases := [
		[_ideal(), GestureMatcher.Grade.PERFECT, 120, 50],
		[_shift(_ideal(), Vector2(0.06, 0.0)), GestureMatcher.Grade.SUCCESS, 100, 50],
		[_shift(_ideal(), Vector2(0.09, 0.0)), GestureMatcher.Grade.PARTIAL, 50, 50],
		[_dense([Vector2(0.65, 0.08), Vector2(0.35, 0.92)]), GestureMatcher.Grade.FAIL, 0, 25],
	]
	for entry in cases:
		var battle := _fight(10, 6)
		for enemy in battle.get_enemies():
			enemy.max_hp = 500
			enemy.hp = 500
		var hero := battle.get_hero()
		battle.open_gesture()
		var result := battle.submit_gesture(entry[0])
		var grade_name: String = GestureMatcher.Grade.keys()[entry[1]]
		var damage: int = entry[2]
		var hit := battle.get_enemies().filter(func(e: CombatUnit) -> bool: return e.alive and e.hp < 500)
		_check(result["grade"] == entry[1] and result["damage"] == damage, "%s: %d damage (score %d)" % [grade_name, damage, result["score"]])
		if damage > 0:
			_check(hit.size() == 6 and hit.all(func(e: CombatUnit) -> bool: return e.hp == 500 - damage), "%s: each of the 6 alive enemies took %d" % [grade_name, damage])
		else:
			_check(hit.is_empty() and result["targets"].is_empty(), "Fail: no target, no damage")
		_check(hero.mp == 200 - entry[3] and battle.get_gesture_cooldown_remaining() == 15000, "%s: %d MP, 15 s cooldown" % [grade_name, entry[3]])
	# Kills count in the C05 EXP pool and the settlement (last kill by the Gesture).
	var last := _fight(10, 4)
	last.open_gesture()
	last.submit_gesture(_ideal())
	_check(last.get_phase() == CombatBattle.Phase.VICTORY and last.get_result().exp_pool == 100 and not last.is_gesture_open(), "Gesture kills the last 4: VICTORY, EXP pool 100, window closed")
	_sections_done.append("grades_and_damage")


# --- Targets -----------------------------------------------------------------------------------

func _verify_targets() -> void:
	var few := _fight(10, 7)
	few.open_gesture()
	var few_result := few.submit_gesture(_shift(_ideal(), Vector2(0.06, 0.0)))
	_check(few_result["targets"].size() == 7 and few.get_enemies().slice(0, 7).all(func(e: CombatUnit) -> bool: return few_result["targets"].has(e)), "7 alive: all 7 hit")
	# 20 enemies, 5 dead: exactly 10 different alive ones.
	var picks := []
	for rng_seed in [7, 7, 8]:
		var battle := CombatBattle.create(20)
		battle.advance(CombatConfig.PREPARATION_MS)
		for index in [0, 4, 9, 13, 19]:
			battle.resolve_damage(battle.get_hero(), battle.get_enemies()[index], 1000)
		for enemy in battle.get_enemies():
			enemy.max_hp = 500
			enemy.hp = 500 if enemy.alive else 0
		battle.gesture_rng.seed = rng_seed
		battle.open_gesture()
		var result := battle.submit_gesture(_ideal())
		var ids := []
		for enemy: CombatUnit in result["targets"]:
			ids.append(enemy.id)
		var unique := {}
		for id in ids:
			unique[id] = true
		_check(ids.size() == 10 and unique.size() == 10, "Seed %d: exactly 10 unique targets" % rng_seed)
		_check(not ids.has("enemy_01") and not ids.has("enemy_05") and not ids.has("enemy_10") and not ids.has("enemy_14") and not ids.has("enemy_20"), "Seed %d: no dead enemy picked" % rng_seed)
		_check(battle.get_enemies().filter(func(e: CombatUnit) -> bool: return e.alive and e.hp == 380).size() == 10, "Seed %d: the 10 picked took 120 each, the other 5 nothing" % rng_seed)
		picks.append(ids)
	_check(picks[0] == picks[1], "Same seed: same pick (%s)" % str(picks[0]))
	_check(picks[0] != picks[2], "Another seed: another pick")
	# GestureTargets on its own.
	var source := CombatBattle.create(20)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var pick := GestureTargets.pick(source.get_enemies(), 10, rng)
	_check(pick.size() == 10 and GestureTargets.pick(source.get_enemies().slice(0, 4), 10, rng).size() == 4, "pick: 10 of 20, all of 4")
	_sections_done.append("targets")


# --- Cooldowns ---------------------------------------------------------------------------------

func _verify_cooldowns() -> void:
	var battle := _fight(10, 3)
	_toughen(battle.get_enemies())
	var hero := battle.get_hero()
	var enemy := battle.get_enemies()[0]
	battle.open_gesture()
	battle.submit_gesture(_ideal())
	_check(battle.get_gesture_cooldown_remaining() == 15000 and battle.get_skill_cooldown_remaining(hero) == 0 and battle.get_skill_readiness(hero) == CombatBattle.SkillReadiness.READY, "After the Gesture: Gesture cooling, Normal Skill ready")
	_place(hero, Vector2i(10, 2))
	_place(enemy, Vector2i(12, 2))
	battle.command_skill(enemy)
	battle.advance(10)
	battle.advance(1000)
	_check(battle.get_skill_cooldown_remaining(hero) == 8000 and battle.get_gesture_cooldown_remaining() == 15000 - 1010, "Normal Skill 8 s and Gesture cooldowns run separately")
	battle.advance(8000)
	_check(battle.get_skill_readiness(hero) == CombatBattle.SkillReadiness.READY and battle.get_gesture_readiness() == CombatBattle.GestureReadiness.COOLDOWN, "Normal Skill ready again, Gesture still cooling")
	battle.advance(15000 - 9010 - 1)
	_check(battle.get_gesture_readiness() == CombatBattle.GestureReadiness.COOLDOWN and battle.get_gesture_cooldown_remaining() == 1, "14.999 s: Gesture still cooling")
	battle.advance(1)
	_check(battle.get_gesture_readiness() == CombatBattle.GestureReadiness.READY, "15 s: Gesture ready")
	_sections_done.append("cooldowns")


# --- Combat Clock ------------------------------------------------------------------------------

func _verify_combat_clock() -> void:
	var battle := CombatBattle.create(10)
	battle.advance(2999)
	_check(battle.get_combat_clock_ms() == 0, "PREPARATION does not count")
	battle.advance(1)
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and battle.get_combat_clock_ms() == 0, "FIGHTING begins at 00:00")
	battle.advance(1500)
	_check(battle.get_combat_clock_ms() == 1500, "Runs with FIGHTING")
	var split := CombatBattle.create(10)
	split.advance(4000)
	_check(split.get_combat_clock_ms() == 1000, "One advance across the start: only the FIGHTING part counts")
	_sections_done.append("combat_clock")


func _verify_time_up() -> void:
	var battle := _sturdy_fight(3)
	battle.advance(LIMIT - battle.get_combat_clock_ms() - 1)
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and not battle.is_retreating() and not battle.is_time_up(), "04:59.999: still fighting")
	battle.advance(1)
	_check(battle.is_time_up() and battle.is_forced_retreat() and battle.is_retreating() and battle.get_phase() == CombatBattle.Phase.FIGHTING, "05:00: forced retreat (not DEFEAT, not a result yet)")
	_check(not battle.cancel_retreat() and battle.is_retreating(), "Forced retreat cannot be cancelled")
	_check(battle.get_gesture_readiness() == CombatBattle.GestureReadiness.UNAVAILABLE and battle.get_skill_readiness(battle.get_hero()) == CombatBattle.SkillReadiness.UNAVAILABLE, "No Skill / Gesture during the forced retreat")
	battle.advance(1000)
	_check(battle.get_combat_clock_ms() == LIMIT, "The clock stops at 05:00 (handled once)")
	var occupancy := true
	for step in range(200):
		if battle.is_over():
			break
		battle.advance(50)
		occupancy = occupancy and _occupancy_ok(battle)
	_check(occupancy, "No shared cell during the forced retreat")
	var result := battle.get_result()
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT and result != null and result.is_retreat() and result.exp_pool == 70 and result.survivor_ids.size() == 3, "C04 retreat success: RETREAT result, the 7 kills' 70 EXP kept for C05")
	# The manual retreat stays cancellable.
	var manual := _fight(10, 3)
	_check(manual.start_retreat() and manual.cancel_retreat() and not manual.is_forced_retreat(), "Manual retreat: still cancellable")
	# A manual retreat running at 05:00 becomes forced.
	var running := _sturdy_fight(3)
	running.advance(LIMIT - 1000)
	# Far from the Retreat Zone, so the manual retreat is still running at 05:00.
	for index in range(3):
		_place(running.get_friends()[index], Vector2i(40, index))
	running.start_retreat()
	running.advance(1000)
	_check(running.is_forced_retreat() and not running.cancel_retreat(), "Manual retreat at 05:00: becomes forced")
	# Full Party Wipe during the forced retreat: DEFEAT.
	var wiped := _sturdy_fight(3)
	wiped.advance(LIMIT)
	for friend in wiped.get_friends():
		wiped.resolve_damage(wiped.get_enemies()[0], friend, 1000000)
	_check(wiped.get_phase() == CombatBattle.Phase.DEFEAT and wiped.get_result().outcome == BattleResult.Outcome.DEFEAT, "Party wiped during the forced retreat: DEFEAT")
	_sections_done.append("time_up")


func _verify_time_up_during_gesture() -> void:
	var battle := _sturdy_fight(3)
	var hero := battle.get_hero()
	battle.advance(LIMIT - 5000)
	battle.open_gesture()
	var elapsed := battle.get_elapsed_ms()
	battle.advance(4999)
	_check(battle.is_gesture_open() and not battle.is_time_up(), "Window open at 04:59.999")
	battle.advance(1)
	_check(not battle.is_gesture_open() and battle.is_time_up() and battle.is_forced_retreat(), "05:00: window closed, retreat forced")
	_check(hero.mp == 200 and battle.get_gesture_cooldown_remaining() == 0 and battle.get_last_gesture().is_empty(), "No effect, no MP, no cooldown, not a Fail")
	battle.advance(100)
	_check(battle.get_elapsed_ms() == elapsed + 100, "The battlefield resumes (retreating)")
	# Both limits at the same moment: the Combat time-up wins.
	var tie := _sturdy_fight(3)
	tie.advance(LIMIT - CombatConfig.GESTURE_WINDOW_MS)
	tie.open_gesture()
	tie.advance(CombatConfig.GESTURE_WINDOW_MS + 500)
	_check(tie.is_time_up() and tie.get_hero().mp == 200 and tie.get_last_gesture().is_empty() and tie.get_gesture_cooldown_remaining() == 0, "Same moment: Combat time-up wins (no Fail, no MP, no cooldown)")
	_sections_done.append("time_up_during_gesture")


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
	var session := main.get_node("EncounterSession") as EncounterSession
	session.challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	var battle: CombatBattle = main.get_combat()
	_toughen(battle.get_enemies())
	var view := main.get_node("CombatView") as CombatView
	# C08: the 閃電 button became the Hero's entry in the skill bar.
	var clock := view.get_node("ClockLabel") as Label
	var overlay := view.get_node("GestureOverlay") as Control
	await process_frame
	var entry := _lightning(view)
	_check(not entry.is_empty() and entry["disabled"] and entry["state"] == "戰鬥開始後可用" and not clock.visible, "PREPARATION: 閃電 shown disabled, no clock")
	var texts := [entry["text"]]
	battle.advance(CombatConfig.PREPARATION_MS)
	await process_frame
	entry = _lightning(view)
	_check(not entry["disabled"] and entry["title"] == "特殊技能：閃電　魔力 50" and entry["state"] == "可用", "FIGHTING: 特殊技能：閃電　魔力 50 (%s)" % entry["text"])
	_check(clock.visible and clock.text.begins_with("戰鬥時間 00:0") and clock.text.ends_with(" / 05:00"), "Combat Clock shown (%s)" % clock.text)
	_check(view.get_info_text(battle.get_hero()).contains("魔力 200 / 200"), "Hero MP 200 shown")
	texts.append_array([entry["text"], clock.text])
	view.tap_at(view.cell_center(Vector2(battle.get_friends()[1].cell)))
	await process_frame
	_check(_lightning(view).is_empty(), "Merc A selected: no 閃電")
	view.tap_at(view.cell_center(Vector2(battle.get_hero().cell)))
	await process_frame
	view.press_skill_entry(_lightning(view))
	await process_frame
	_check(battle.is_gesture_open() and overlay.visible and overlay.mouse_filter == Control.MOUSE_FILTER_STOP and overlay.get_index() > view.get_node("Field").get_index(), "Pressed: the Gesture Window covers the battle and takes input")
	var countdown := (overlay.get_node("GestureCountdown") as Label).text
	var overlay_clock := (overlay.get_node("GestureClock") as Label).text
	_check(countdown == "剩餘 10 秒" and overlay_clock.ends_with("（繼續計時）") and _lightning(view)["state"] == "畫符中…", "Window: 剩餘 10 秒, the clock keeps running (%s / %s)" % [countdown, overlay_clock])
	texts.append_array([countdown, overlay_clock, _lightning(view)["text"], (overlay.get_node("GestureTitle") as Label).text])
	_check(not view.tap_at(view.cell_center(Vector2(battle.get_enemies()[0].cell))), "A battlefield tap does nothing while open")
	# An accidental touch is not submitted.
	_press(overlay, Vector2(300, 600), true)
	_press(overlay, Vector2(300, 600), false)
	_check(battle.is_gesture_open() and battle.get_last_gesture().is_empty(), "A tap without a stroke: not submitted, still open")
	# The ideal stroke through real input events on the overlay.
	var area := CombatView.GESTURE_AREA
	var points := _ideal()
	_press(overlay, area.position + points[0] * area.size.x, true)
	for index in range(1, points.size()):
		var motion := InputEventMouseMotion.new()
		motion.position = area.position + points[index] * area.size.x
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		overlay._gui_input(motion)
	_press(overlay, area.position + points[-1] * area.size.x, false)
	await process_frame
	var result := battle.get_last_gesture()
	_check(not battle.is_gesture_open() and not overlay.visible and result["grade"] == GestureMatcher.Grade.PERFECT, "Lift the finger: submitted, Perfect, window closed (score %s)" % str(result.get("score")))
	var feedback := (view.get_node("GestureResultLabel") as Label)
	_check(feedback.visible and feedback.text == "閃電 完美！100 分　120 傷害 × 10", "Result shown (%s)" % feedback.text)
	entry = _lightning(view)
	_check(entry["state"].begins_with("冷卻 ") and entry["disabled"] and battle.get_hero().mp == 150, "Cooling down, 150 MP (%s)" % entry["text"])
	texts.append_array([feedback.text, entry["text"]])
	# The result is UI-only: real seconds, not battle or clock time.
	var elapsed := battle.get_elapsed_ms()
	var combat_clock := battle.get_combat_clock_ms()
	view._process(1.6)
	_check(view.get_gesture_result_text() == "" and battle.get_elapsed_ms() == elapsed and battle.get_combat_clock_ms() == combat_clock, "Feedback gone after 1.5 s of UI time; no battle time involved")
	await process_frame
	_check(not feedback.visible, "Feedback hidden")
	# Forced retreat presentation.
	for friend in battle.get_friends():
		friend.max_hp = 1000000
		friend.hp = 1000000
	battle.advance(LIMIT - battle.get_combat_clock_ms())
	await process_frame
	var retreat := view.get_node("RetreatButton") as Button
	_check(battle.is_forced_retreat() and clock.text == "時間到　強制撤退" and retreat.text == "強制撤退中" and retreat.disabled and _lightning(view).is_empty(), "05:00 shown: 時間到　強制撤退, 強制撤退中 disabled")
	retreat.pressed.emit()
	_check(battle.is_retreating(), "Pressing it does not cancel")
	texts.append_array([clock.text, retreat.text])
	for frame in range(600):
		if battle.is_over():
			break
		battle.advance(50)
	await process_frame
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT, "The forced retreat ends as RETREAT")
	(view.get_node("ExitButton") as Button).pressed.emit()
	await process_frame
	_check(main.get_combat() == null and session.get_phase() == EncounterSession.Phase.NONE and session.is_protection_active(), "C02 / C04 lifecycle: battle closed, encounter ended, recovery protection")
	var approved := RegEx.new()
	approved.compile("(?<![A-Za-z])[ABE](?![A-Za-z])")
	var latin := RegEx.new()
	latin.compile("[A-Za-z]")
	var with_latin := texts.filter(func(t: String) -> bool: return latin.search(approved.sub(t, "", true)) != null)
	_check(with_latin.is_empty(), "All C07 texts are Traditional Chinese (%s)" % str(with_latin))
	root.remove_child(main)
	main.free()
	await process_frame
	_sections_done.append("in_game")


# --- Helpers -----------------------------------------------------------------------------------

## C08: the Hero's 閃電 skill bar entry ({} when not shown).
func _lightning(view: CombatView) -> Dictionary:
	for entry in view.get_skill_bar_entries():
		if entry["kind"] == "lightning":
			return entry
	return {}


func _press(overlay: Control, position: Vector2, pressed: bool) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = pressed
	click.position = position
	overlay._gui_input(click)


## A battle in FIGHTING with only the first `alive` enemies left alive.
func _fight(enemies: int, alive: int = -1) -> CombatBattle:
	var battle := CombatBattle.create(enemies)
	battle.advance(CombatConfig.PREPARATION_MS)
	if alive >= 0:
		for index in range(alive, enemies):
			battle.resolve_damage(battle.get_hero(), battle.get_enemies()[index], 1000)
	return battle


## A FIGHTING battle the idle party survives for 5 minutes (huge HP).
func _sturdy_fight(alive: int) -> CombatBattle:
	var battle := _fight(10, alive)
	for friend in battle.get_friends():
		friend.max_hp = 1000000
		friend.hp = 1000000
	return battle


## Enemies that survive a Perfect Gesture (500 HP).
func _toughen(enemies: Array[CombatUnit]) -> void:
	for enemy in enemies:
		if enemy.alive:
			enemy.max_hp = 500
			enemy.hp = 500


func _snapshot(battle: CombatBattle) -> Dictionary:
	var units := []
	for unit in battle.get_friends() + battle.get_enemies():
		units.append([unit.cell, unit.next_cell, unit.step_progress_ms, unit.claim, unit.hp, unit.mp, unit.attack_cooldown_ms, unit.skill_state, battle.get_cast_remaining(unit), battle.get_skill_cooldown_remaining(unit), battle.get_slow_remaining(unit), battle.get_guard_remaining(unit), unit.target, unit.has_goal])
	return {"elapsed": battle.get_elapsed_ms(), "units": units, "phase": battle.get_phase(), "exp": battle.get_exp_pool()}


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


func _ideal() -> PackedVector2Array:
	return _dense(GestureMatcher.GUIDE)


func _dense(points: Array, per: int = 10) -> PackedVector2Array:
	var out := PackedVector2Array()
	for index in range(points.size() - 1):
		for k in range(per):
			out.append((points[index] as Vector2).lerp(points[index + 1], float(k) / per))
	out.append(points[-1])
	return out


func _shift(points: PackedVector2Array, offset: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point in points:
		out.append(point + offset)
	return out


func _wobble(points: PackedVector2Array, amount: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for index in range(points.size()):
		out.append(points[index] + Vector2(sin(index * 1.7), cos(index * 2.3)) * amount)
	return out


func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


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
