extends SceneTree

## Combat C04: Retreat. During FIGHTING the player may send the whole party
## toward the Retreat Zone (column 0, every row): targets / move orders
## dropped, no Basic Attack, no Move / Target commands, enemies keep chasing
## and attacking. It can be cancelled (nothing comes back) and started again.
## The first alive friendly unit in column 0 (one already standing there
## counts, C04-D04) ends the battle as RETREAT; a Full Party Wipe first is
## DEFEAT, every enemy dead first is VICTORY — exactly one result. The world
## commits RETREAT once through the C02 lifecycle: participating groups reset
## home, 5 s protection, one save (v8), no loot, EXP or penalty.

const TEST_SAVE := "user://c04_retreat_test_save.json"
const BAD_SAVE := "user://c04_missing_dir/save.json"
const T0 := 1800000000000
const WITH_GROUP_1 := Vector2(800.0, 900.0)
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const NODES := ["Actors/PrototypeMonster", "Actors/PrototypeMonster2", "Actors/PrototypeMonster3"]
const HOMES := [Vector2(800.0, 700.0), Vector2(1100.0, 700.0), Vector2(950.0, 930.0)]

var _checks := 0
var _failures := 0
var _sections_done := []
var _phases := []
var _hits := []
var _results := 0
var _commits := []
var _ticks_us := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	_verify_availability()
	_verify_activation()
	_verify_movement()
	_verify_already_in_zone()
	_verify_enemy_pressure()
	_verify_cancel()
	_verify_casualties()
	_verify_result_races()
	_verify_stress()
	await _verify_world_lifecycle()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 11, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("C04 retreat verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(BattleResult.Outcome.VICTORY == 0 and BattleResult.Outcome.DEFEAT == 1 and BattleResult.Outcome.RETREAT == 2, "BattleResult outcomes: VICTORY 0 and DEFEAT 1 kept, RETREAT added")
	_check(CombatBattle.Phase.VICTORY == 2 and CombatBattle.Phase.DEFEAT == 3 and CombatBattle.Phase.RETREAT == 4, "Battle phases: RETREAT added after the others")
	_check(CombatConfig.PREPARATION_MS == 3000 and CombatConfig.MERC_A_START_CELL.x == 1 and CombatConfig.HERO_START_CELL.x == 1 and CombatConfig.HERO["move_speed"] == 4.0 and CombatConfig.ENEMY["move_speed"] == 2.0, "Spawns, speeds and preparation unchanged")
	_check(SaveStore.VERSION == 10 and SaveStore.V8_KEYS == SaveStore.V7_KEYS and not _code_only("res://scripts/save_store.gd").to_lower().contains("retreat"), "Save version 10; the save knows nothing about Retreat")
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_view.gd", "res://scripts/battle_result.gd", "res://scripts/main.gd"]:
		var code := _code_only(path).to_lower()
		# C05 brought EXP rewards into scope ("reward" left the list; C05's own test pins Retreat's EXP).
		for word in ["loot", "exp ", "experience", "penalty", "hospital", "injury", "morale", "stamina", "chance", "cast_time", "retreat_cooldown", "speed_bonus", "invulnerab"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	# main.gd's journey request ids use randi() (M2-09); the Combat rules must not.
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_view.gd", "res://scripts/battle_result.gd"]:
		for word in ["randf", "randi"]:
			_check(not _code_only(path).to_lower().contains(word), "%s has no %s" % [path.get_file(), word])
	_sections_done.append("static")


# --- Availability ------------------------------------------------------------------------------

func _verify_availability() -> void:
	var battle := _battle(10)
	_check(not battle.start_retreat() and not battle.is_retreating(), "PREPARATION refuses Retreat")
	battle.advance(2999)
	_check(not battle.start_retreat(), "Still refused at 2999 ms")
	battle.advance(1)
	_check(battle.start_retreat() and battle.is_retreating(), "FIGHTING accepts Retreat")
	_check(not battle.start_retreat(), "A second start while retreating is refused")
	_check(battle.cancel_retreat() and not battle.is_retreating() and not battle.cancel_retreat(), "Cancel works once; nothing to cancel afterwards")
	for outcome in ["VICTORY", "DEFEAT", "RETREAT"]:
		var done := _battle(3)
		done.advance(3000)
		if outcome == "VICTORY":
			for enemy in done.get_enemies():
				done.resolve_damage(done.get_hero(), enemy, 1000)
		elif outcome == "DEFEAT":
			for friend in done.get_friends():
				done.resolve_damage(done.get_enemies()[0], friend, 1000)
		else:
			done.start_retreat()
			done.advance(300)
		_check(done.is_over() and CombatBattle.Phase.keys()[done.get_phase()] == outcome, "Reached %s" % outcome)
		_check(not done.start_retreat() and not done.cancel_retreat() and not done.is_retreating(), "After %s: no Retreat, no Cancel" % outcome)
	_sections_done.append("availability")


# --- Activation --------------------------------------------------------------------------------

func _verify_activation() -> void:
	var battle := _battle(3)
	var friends := battle.get_friends()
	var enemies := battle.get_enemies()
	for enemy in enemies:
		enemy.max_hp = 100000
		enemy.hp = 100000
	battle.advance(3000)
	for index in range(3):
		_place(friends[index], Vector2i(20, index + 1))
	_place(enemies[0], Vector2i(21, 1))
	_place(enemies[1], Vector2i(21, 4))
	battle.select_unit(friends[0])
	battle.command_target(enemies[0])
	battle.select_unit(friends[2])
	battle.command_target(enemies[1])
	battle.select_unit(friends[1])
	battle.command_move(Vector2i(9, 1))
	battle.resolve_damage(enemies[2], friends[2], 1000)
	_check(not friends[2].alive and friends[0].target == enemies[0] and friends[1].has_goal, "Setup: Hero targeting, Merc A moving, Merc B dead")
	_check(battle.start_retreat(), "Retreat started")
	_check(friends[0].target == null and not friends[1].has_goal and friends[1].target == null, "Targets and move orders dropped")
	_check(not friends[2].alive and friends[2].target == null and friends[2].claim == CombatUnit.NO_CELL, "The dead Merc B is not affected")
	var hits := _friend_hits()
	battle.advance(1500)
	_check(battle.is_retreating() and _friend_hits() == hits, "No friendly Basic Attack while retreating (enemies right next to the party)")
	# White-box: even a target forced onto a retreating unit is never attacked.
	var guard := _battle(1)
	var guard_hero := guard.get_hero()
	guard.advance(3000)
	_place(guard_hero, Vector2i(20, 2))
	_place(guard.get_enemies()[0], Vector2i(21, 2))
	guard.get_enemies()[0].max_hp = 100000
	guard.get_enemies()[0].hp = 100000
	guard.start_retreat()
	guard_hero.target = guard.get_enemies()[0]
	guard.advance(100)
	_check(_friend_hits() == 0, "A retreating unit never Basic Attacks, even with a target")
	_check(battle.select_unit(friends[1]) and battle.get_selected() == friends[1], "Selection still works while retreating")
	_check(not battle.command_move(Vector2i(5, 2)) and not battle.command_target(enemies[0]) and not battle.tap(enemies[0].cell) and friends[1].target == null and not friends[1].has_goal, "Move / Target commands refused while retreating")
	_sections_done.append("activation")


# --- Movement ----------------------------------------------------------------------------------

func _verify_movement() -> void:
	var battle := _battle(1)
	var friends := battle.get_friends()
	_place(battle.get_enemies()[0], Vector2i(55, 0))
	battle.get_enemies()[0].move_speed = 0.01
	battle.advance(3000)
	_place(friends[0], Vector2i(6, 2))
	_place(friends[1], Vector2i(9, 1))
	_place(friends[2], Vector2i(12, 3))
	_check(battle.start_retreat(), "Retreat from columns 6 / 9 / 12")
	var previous := friends.map(func(u: CombatUnit) -> Vector2: return u.visual_cell())
	var monotonic := true
	var smooth := true
	for step in range(29):
		battle.advance(50)
		var now := friends.map(func(u: CombatUnit) -> Vector2: return u.visual_cell())
		for index in range(3):
			monotonic = monotonic and now[index].x <= previous[index].x
			smooth = smooth and now[index].distance_to(previous[index]) <= 0.21 * sqrt(2.0) + 0.001
		previous = now
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and battle.get_result() == null and friends[0].cell.x == 1, "1450 ms: nobody in the zone yet, no result (Hero at column %d)" % friends[0].cell.x)
	_check(monotonic and smooth, "Every unit moved left one step at a time (no teleport)")
	battle.advance(50)
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT and friends[0].cell.x == 0, "1500 ms: the Hero steps into column 0 -> RETREAT")
	_check(friends[1].cell.x > 0 and friends[2].cell.x > 0 and friends[1].alive and friends[2].alive, "The Mercs did not need to reach the zone")
	_check(_phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.RETREAT] and battle.get_result().outcome == BattleResult.Outcome.RETREAT, "One RETREAT result")
	var in_grid := friends.all(func(u: CombatUnit) -> bool: return CombatBattle.is_in_grid(u.cell) and CombatBattle.is_in_grid(u.next_cell))
	_check(in_grid, "Everyone stayed on the grid")
	# A full zone: every column 0 cell held by an alive enemy (they stand and
	# "attack" from range 5 for 0 damage, so they never step away).
	var crowded := _battle(5)
	var cf := crowded.get_friends()
	var ce := crowded.get_enemies()
	crowded.advance(3000)
	for index in range(5):
		_place(ce[index], Vector2i(0, index))
		ce[index].attack_damage = 0
		ce[index].attack_range = 5
	_place(cf[0], Vector2i(4, 2))
	crowded.resolve_damage(ce[0], cf[1], 1000)
	crowded.resolve_damage(ce[0], cf[2], 1000)
	crowded.start_retreat()
	var blocked_ok := true
	for step in range(40):
		crowded.advance(50)
		blocked_ok = blocked_ok and not _shares_cell(crowded) and _all_on_grid(crowded) and cf[0].cell.x >= 1 and cf[0].next_cell.x >= 1
	_check(blocked_ok, "Full zone: the Hero never steps onto a taken zone cell, shares no cell, stays on the grid")
	_check(crowded.get_phase() == CombatBattle.Phase.FIGHTING and crowded.get_result() == null and crowded.is_retreating(), "Full zone: no RETREAT, still retreating (2 s)")
	_check(cf[0].cell == Vector2i(1, 2) and not cf[0].is_moving(), "It waits on the nearest free cell outside the zone (%s)" % str(cf[0].cell))
	crowded.resolve_damage(cf[0], ce[3], 1000)
	var freed_ok := true
	for step in range(20):
		if crowded.is_over():
			break
		crowded.advance(50)
		freed_ok = freed_ok and not _shares_cell(crowded) and _all_on_grid(crowded)
	_check(crowded.get_phase() == CombatBattle.Phase.RETREAT and cf[0].cell == Vector2i(0, 3) and _phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.RETREAT], "Zone cell (0, 3) freed: the Hero enters it -> RETREAT, once")
	_check(freed_ok and not _shares_cell(crowded), "No shared standing cell, including the RETREAT frame")
	# Walking diagonally through a taken zone cell does not count; the free one does.
	var through := _battle(4)
	var tf := through.get_friends()
	var te := through.get_enemies()
	through.advance(3000)
	for index in range(4):
		_place(te[index], Vector2i(0, index))
		te[index].attack_damage = 0
		te[index].attack_range = 5
	_place(tf[0], Vector2i(1, 1))
	through.resolve_damage(te[0], tf[1], 1000)
	through.resolve_damage(te[0], tf[2], 1000)
	through.start_retreat()
	var through_ok := true
	var entered_taken := false
	for step in range(40):
		if through.is_over():
			break
		through.advance(50)
		through_ok = through_ok and not _shares_cell(through)
		entered_taken = entered_taken or (tf[0].cell.x == 0 and tf[0].cell.y < 4 and through.get_phase() == CombatBattle.Phase.RETREAT)
	_check(through.get_phase() == CombatBattle.Phase.RETREAT and tf[0].cell == Vector2i(0, 4) and not entered_taken, "Only the free zone cell (0, 4) counts: RETREAT there, not on a taken cell passed on the way")
	_check(through_ok, "No shared standing cell on the way or in the RETREAT frame")
	_sections_done.append("movement")


# --- C04-D04: already in the zone ----------------------------------------------------------------

func _verify_already_in_zone() -> void:
	var battle := _battle(3)
	var friends := battle.get_friends()
	battle.advance(3000)
	battle.select_unit(friends[1])
	battle.command_move(Vector2i(0, 1))
	battle.advance(250)
	_check(friends[1].cell == Vector2i(0, 1) and not friends[1].is_moving() and battle.get_phase() == CombatBattle.Phase.FIGHTING, "Merc A stands in column 0 while fighting (no Retreat yet: no result)")
	battle.advance(2000)
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING, "Standing in column 0 without Retreat changes nothing")
	_check(battle.start_retreat() and battle.get_phase() == CombatBattle.Phase.FIGHTING, "Retreat starts; the result comes with the next tick")
	battle.advance(1)
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT and friends[1].cell == Vector2i(0, 1) and not friends[1].is_moving(), "Next tick: RETREAT; Merc A never left the zone")
	var hp := friends.map(func(u: CombatUnit) -> int: return u.hp)
	_check(battle.resolve_damage(battle.get_enemies()[0], friends[1], 1000) == 0, "Later enemy damage is refused")
	battle.advance(5000)
	_check(friends.map(func(u: CombatUnit) -> int: return u.hp) == hp and _phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.RETREAT] and battle.get_result().is_retreat(), "RETREAT exactly once, never overwritten")
	_sections_done.append("already_in_zone")


# --- Enemy pressure ------------------------------------------------------------------------------

func _verify_enemy_pressure() -> void:
	var battle := _battle(4)
	var friends := battle.get_friends()
	var enemies := battle.get_enemies()
	battle.advance(3000)
	_place(friends[0], Vector2i(20, 2))
	_place(friends[1], Vector2i(20, 1))
	_place(friends[2], Vector2i(20, 3))
	_place(enemies[0], Vector2i(21, 2))
	_place(enemies[1], Vector2i(21, 0))
	_place(enemies[2], Vector2i(25, 4))
	_place(enemies[3], Vector2i(40, 0))
	friends[1].hp = 4
	var start := enemies.map(func(u: CombatUnit) -> Vector2i: return u.cell)
	battle.start_retreat()
	battle.advance(1)
	_check(friends[0].hp < 300 and not friends[1].alive, "Retreating units are hit: the Hero takes damage, Merc A (4 HP) dies")
	_check(battle.is_retreating() and battle.get_phase() == CombatBattle.Phase.FIGHTING, "One death does not stop the Retreat")
	for step in range(20):
		battle.advance(100)
	var moved := 0
	for index in range(4):
		if enemies[index].cell != start[index]:
			moved += 1
	_check(moved >= 3, "Enemies keep chasing (%d moved)" % moved)
	_check(friends[0].cell.x < 20 and friends[2].cell.x < 20, "The survivors keep running left")
	var enemy_hits := _hits.filter(func(h: Array) -> bool: return h[0].team == CombatUnit.Team.ENEMY)
	_check(enemy_hits.size() >= 2, "Enemy Basic Attacks landed during the Retreat (%d)" % enemy_hits.size())
	_sections_done.append("enemy_pressure")


# --- Cancel ----------------------------------------------------------------------------------------

func _verify_cancel() -> void:
	var battle := _battle(3)
	var friends := battle.get_friends()
	var enemies := battle.get_enemies()
	for enemy in enemies:
		enemy.max_hp = 100000
		enemy.hp = 100000
	_place(enemies[0], Vector2i(30, 0))
	_place(enemies[1], Vector2i(30, 2))
	_place(enemies[2], Vector2i(30, 4))
	for enemy in enemies:
		enemy.move_speed = 0.01
	battle.advance(3000)
	for index in range(3):
		_place(friends[index], Vector2i(10, index + 1))
	battle.select_unit(friends[0])
	battle.command_target(enemies[1])
	battle.select_unit(friends[1])
	battle.command_move(Vector2i(20, 0))
	battle.start_retreat()
	battle.advance(600)
	_check(battle.cancel_retreat() and not battle.is_retreating() and battle.get_phase() == CombatBattle.Phase.FIGHTING, "Retreat cancelled mid-way")
	_check(friends[0].target == null and not friends[1].has_goal and friends[1].target == null, "The old target and move order are not restored")
	battle.advance(300)
	var stopped := friends.map(func(u: CombatUnit) -> Vector2i: return u.cell)
	battle.advance(2000)
	_check(friends.map(func(u: CombatUnit) -> Vector2i: return u.cell) == stopped and friends.all(func(u: CombatUnit) -> bool: return not u.is_moving()), "The party stays where the cancel left it (%s)" % str(stopped))
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and battle.get_result() == null, "No result from the cancelled Retreat")
	battle.select_unit(friends[2])
	_check(battle.command_move(Vector2i(12, 4)), "Move works again")
	battle.select_unit(friends[0])
	_check(battle.command_target(enemies[1]) and friends[0].target == enemies[1], "Target works again")
	battle.advance(2500)
	_check(friends[2].cell == Vector2i(12, 4), "The new move is carried out")
	_check(battle.start_retreat() and friends[0].target == null, "Retreat can be started again")
	battle.advance(4000)
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT and _phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.RETREAT], "The second Retreat succeeds, once")
	_sections_done.append("cancel")


# --- Casualties ----------------------------------------------------------------------------------

func _verify_casualties() -> void:
	# [dead before the escape, expected survivors]
	for dead in [[0], [1], [0, 1], [0, 2], [1, 2]]:
		var battle := _battle(3)
		var friends := battle.get_friends()
		battle.advance(3000)
		for index in range(3):
			_place(friends[index], Vector2i(8, index + 1))
		battle.start_retreat()
		battle.advance(300)
		for index in dead:
			battle.resolve_damage(battle.get_enemies()[0], friends[index], 1000)
		_check(battle.is_retreating() and battle.get_phase() == CombatBattle.Phase.FIGHTING, "%s dead during the Retreat: it goes on" % str(dead.map(func(i: int) -> String: return friends[i].id)))
		battle.advance(3000)
		var escaped := friends.filter(func(u: CombatUnit) -> bool: return u.alive and u.cell.x == 0)
		_check(battle.get_phase() == CombatBattle.Phase.RETREAT and escaped.size() >= 1 and dead.all(func(i: int) -> bool: return not friends[i].alive), "…a survivor escapes: RETREAT (%s)" % str(escaped.map(func(u: CombatUnit) -> String: return u.id)))
	# The last unit dies before the zone: DEFEAT, not RETREAT.
	var lost := _battle(3)
	var lf := lost.get_friends()
	lost.advance(3000)
	for index in range(3):
		_place(lf[index], Vector2i(30, index + 1))
		lf[index].hp = 4
		_place(lost.get_enemies()[index], Vector2i(31, index + 1))
	lost.start_retreat()
	lost.advance(1)
	_check(lost.get_phase() == CombatBattle.Phase.DEFEAT and lost.get_result() != null and not lost.get_result().is_retreat() and _phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.DEFEAT], "Full Party Wipe before the zone: DEFEAT, once")
	_sections_done.append("casualties")


# --- Result races ----------------------------------------------------------------------------------

func _verify_result_races() -> void:
	# Escape and a lethal enemy attack in the same step: friends act first.
	var battle := _battle(1)
	var friends := battle.get_friends()
	var enemy := battle.get_enemies()[0]
	battle.advance(3000)
	battle.resolve_damage(enemy, friends[1], 1000)
	battle.resolve_damage(enemy, friends[2], 1000)
	_place(friends[0], Vector2i(1, 2))
	friends[0].hp = 1
	_place(enemy, Vector2i(2, 2))
	enemy.attack_cooldown_ms = 0
	battle.start_retreat()
	battle.advance(250)
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT and friends[0].alive and friends[0].hp == 1, "Hero (1 HP) reaches the zone in the same step the enemy could kill it: RETREAT")
	battle.advance(3000)
	_check(_phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.RETREAT] and friends[0].alive and battle.get_result().is_retreat(), "RETREAT is never overwritten by later damage")
	# The last friendly dies first: DEFEAT stays DEFEAT.
	var lost := _battle(1)
	var lf := lost.get_friends()
	lost.advance(3000)
	lost.resolve_damage(lost.get_enemies()[0], lf[1], 1000)
	lost.resolve_damage(lost.get_enemies()[0], lf[2], 1000)
	_place(lf[0], Vector2i(3, 2))
	lost.start_retreat()
	lost.resolve_damage(lost.get_enemies()[0], lf[0], 1000)
	lost.advance(2000)
	_check(lost.get_phase() == CombatBattle.Phase.DEFEAT and _phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.DEFEAT] and not lost.get_result().is_retreat(), "Last friendly dead before escaping: DEFEAT stays DEFEAT")
	# Every enemy dies while retreating, before anyone reaches the zone: VICTORY.
	var won := _battle(2)
	var wf := won.get_friends()
	won.advance(3000)
	for index in range(3):
		_place(wf[index], Vector2i(10, index + 1))
	won.start_retreat()
	won.advance(200)
	for enemy_unit in won.get_enemies():
		won.resolve_damage(wf[0], enemy_unit, 1000)
	won.advance(3000)
	_check(won.get_phase() == CombatBattle.Phase.VICTORY and _phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.VICTORY] and won.get_result().is_victory() and wf.all(func(u: CombatUnit) -> bool: return u.cell.x > 0), "Every enemy dead before the escape: VICTORY stays VICTORY")
	_sections_done.append("races")


# --- 3 vs 20 stress ----------------------------------------------------------------------------------

func _verify_stress() -> void:
	var all_ok := true
	var shared := false
	var outside := false
	var outcomes := {}
	for scenario in ["A", "B", "C", "D", "E"]:
		for round in range(3):
			_results = 0
			var battle := _battle(20)
			battle.phase_changed.connect(_count_result)
			var friends := battle.get_friends()
			battle.advance(3000)
			var plan_ms: int = {"A": 0, "B": 2000 + round * 700, "C": 1500 + round * 500, "D": 1000 + round * 800, "E": 800 + round * 400}[scenario]
			if scenario == "D":
				battle.resolve_damage(battle.get_enemies()[0], friends[0], 1000)
			if scenario == "E":
				battle.resolve_damage(battle.get_enemies()[0], friends[0], 1000)
				battle.resolve_damage(battle.get_enemies()[0], friends[1], 1000)
			var retreated := 0
			var cancelled := false
			var tick := 0
			while not battle.is_over() and battle.get_elapsed_ms() < 300000:
				var fighting_ms := battle.get_elapsed_ms() - 3000
				if not battle.is_retreating():
					for unit in friends:
						if unit.alive and unit.target == null:
							battle.select_unit(unit)
							battle.command_target(_nearest_enemy(battle, unit))
				if retreated == 0 and fighting_ms >= plan_ms:
					battle.start_retreat()
					retreated = 1
				elif scenario == "C" and retreated == 1 and not cancelled and fighting_ms >= plan_ms + 400:
					battle.cancel_retreat()
					cancelled = true
				elif scenario == "C" and cancelled and retreated == 1 and fighting_ms >= plan_ms + 2400:
					battle.start_retreat()
					retreated = 2
				var start := Time.get_ticks_usec()
				battle.advance(16)
				_ticks_us.append(Time.get_ticks_usec() - start)
				tick += 1
				# Every tick, the final result frame included.
				shared = shared or _shares_cell(battle)
				outside = outside or not _all_on_grid(battle)
			var outcome: String = CombatBattle.Phase.keys()[battle.get_phase()]
			outcomes[scenario + str(round)] = outcome
			all_ok = all_ok and battle.is_over() and _results == 1 and battle.get_result() != null
			if scenario == "E" and outcome == "RETREAT":
				all_ok = all_ok and friends[2].alive and friends[2].cell.x == 0
	_check(all_ok, "Every 3 vs 20 Retreat scenario resolved with exactly one result (%s)" % str(outcomes))
	_check(outcomes["A0"] == "RETREAT" and outcomes["A1"] == "RETREAT" and outcomes["A2"] == "RETREAT", "Scenario A (immediate Retreat) escapes")
	_check(not shared and not outside, "No shared standing cell, nobody off the grid")
	var total := 0
	var worst := 0
	for us in _ticks_us:
		total += us
		worst = maxi(worst, us)
	print("C04 stress: %d ticks, average %d us, worst %d us, outcomes %s" % [_ticks_us.size(), total / maxi(_ticks_us.size(), 1), worst, str(outcomes)])
	_check(worst < 50000, "No tick above 50 ms (worst %d us)" % worst)
	_sections_done.append("stress")


# --- World lifecycle (C02) -----------------------------------------------------------------------------

func _verify_world_lifecycle() -> void:
	var main := await _new_main(TEST_SAVE)
	var session := main.get_node("EncounterSession") as EncounterSession
	var handoff := main.get_node("EncounterHandoff") as EncounterHandoff
	var view := main.get_node("CombatView") as CombatView
	var player := main.get_node("Actors/Player") as Player
	var money: int = main.wallet.get_balance()
	var battle := await _locked_battle(main, WITH_GROUP_1, 2)
	var retreat_button := view.get_node("RetreatButton") as Button
	var status := view.get_node("StatusLabel") as Label
	await process_frame
	_check(battle.get_phase() == CombatBattle.Phase.PREPARATION and not retreat_button.visible, "PREPARATION: no 撤退 button")
	battle.advance(CombatConfig.PREPARATION_MS)
	await process_frame
	_check(retreat_button.visible and retreat_button.text == "全體撤退" and status.text == "戰鬥", "FIGHTING: 全體撤退 button (C08 label)")
	retreat_button.pressed.emit()
	await process_frame
	_check(battle.is_retreating() and retreat_button.text == "取消撤退" and status.text == "撤退中", "Pressed: 撤退中, button 取消撤退")
	retreat_button.pressed.emit()
	await process_frame
	_check(not battle.is_retreating() and retreat_button.text == "全體撤退" and status.text == "戰鬥", "Pressed again: cancelled")
	retreat_button.pressed.emit()
	var spot := player.global_position
	var group_2 := main.get_node(NODES[1]) as WorldMonster
	var groups := [main.get_node(NODES[0]) as WorldMonster, main.get_node(NODES[2]) as WorldMonster]
	groups[1].global_position = Vector2(990.0, 960.0)
	battle.advance(2000)
	await process_frame
	var exit := view.get_node("ExitButton") as Button
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT and status.text == "撤退成功" and exit.visible and not retreat_button.visible, "RETREAT: 撤退成功, exit shown, 撤退 gone")
	var result := battle.get_result()
	_check(result.is_retreat() and not result.is_victory() and result.encounter_id == session.get_context().encounter_id and result.group_monster_ids.size() == 2, "RETREAT BattleResult for this encounter and both groups")
	var group_2_position := group_2.global_position
	_delete(TEST_SAVE)
	exit.pressed.emit()
	_check(result.is_committed() and _commits.size() == 1 and _commits[0][1] == true, "Committed once, saved")
	_check(groups.all(func(m: WorldMonster) -> bool: return is_instance_valid(m) and m.is_inside_tree() and not m.is_held() and m.is_threat_active()) and groups[0].global_position == HOMES[0] and groups[1].global_position == HOMES[2], "Participating groups 1 and 3 reset home (not removed)")
	_check(group_2.global_position == group_2_position and main._world_monsters.size() == 3, "Group 2 untouched; all three groups remain")
	_check(session.get_phase() == EncounterSession.Phase.NONE and not handoff.has_pending_encounter() and main.get_combat() == null and not view.visible, "Encounter ended, battle closed")
	_check(not player.movement_locked and player.global_position == spot and main.location.is_in_world() and (main.get_node("TouchControls/Joystick") as Node).is_processing_input(), "Player free at the encounter position, world input back")
	_check(session.is_protection_active() and session.get_protection_remaining_ms() == 5000, "5 s recovery protection")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(saved != null and int(saved["version"]) == 10 and not FileAccess.get_file_as_string(TEST_SAVE).to_lower().contains("retreat") and main.wallet.get_balance() == money, "Saved once: v9, nothing about Retreat, money unchanged (no loot, no penalty)")
	_delete(TEST_SAVE)
	main.time_source.advance_ms(1000)
	exit.pressed.emit()
	_check(not main.commit_battle_result(result) and _commits.size() == 1 and not FileAccess.file_exists(TEST_SAVE) and session.get_protection_remaining_ms() == 4000, "Repeats refused: no second commit, save or protection restart")
	await _destroy(main)
	# Save failure after the commit: no rollback.
	main = await _new_main("")
	session = main.get_node("EncounterSession") as EncounterSession
	battle = await _locked_battle(main, PASSIVE_ONLY, 1)
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.start_retreat()
	battle.advance(1000)
	main.save_path = BAD_SAVE
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT and main.commit_battle_result(battle.get_result()), "RETREAT committed although the save will fail")
	_check(_commits.size() == 1 and _commits[0][1] == false and session.get_phase() == EncounterSession.Phase.NONE and session.is_protection_active() and main.has_node(NODES[2]) and (main.get_node(NODES[2]) as WorldMonster).global_position == HOMES[2], "Save failed, no rollback: encounter ended, protected, group reset")
	_check(not main.commit_battle_result(battle.get_result()) and _commits.size() == 1, "No second attempt")
	await _destroy(main)
	_sections_done.append("world_lifecycle")


# --- Helpers --------------------------------------------------------------------------------------

func _battle(enemies: int) -> CombatBattle:
	_phases.clear()
	_hits.clear()
	var battle := CombatBattle.create(enemies)
	battle.phase_changed.connect(func(phase: int) -> void: _phases.append(phase))
	battle.damage_dealt.connect(func(attacker: CombatUnit, target: CombatUnit, amount: int) -> void: _hits.append([attacker, target, amount, battle.get_elapsed_ms()]))
	return battle


func _count_result(phase: int) -> void:
	if phase >= CombatBattle.Phase.VICTORY:
		_results += 1


## Whether two alive, standing units share a cell.
func _shares_cell(battle: CombatBattle) -> bool:
	var taken := {}
	for unit in battle.get_friends() + battle.get_enemies():
		if unit.alive and not unit.is_moving():
			if taken.has(unit.cell):
				return true
			taken[unit.cell] = true
	return false


func _all_on_grid(battle: CombatBattle) -> bool:
	for unit in battle.get_friends() + battle.get_enemies():
		if not CombatBattle.is_in_grid(unit.cell) or not CombatBattle.is_in_grid(unit.next_cell):
			return false
	return true


func _friend_hits() -> int:
	return _hits.filter(func(h: Array) -> bool: return h[0].team == CombatUnit.Team.FRIEND).size()


func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


func _nearest_enemy(battle: CombatBattle, from: CombatUnit) -> CombatUnit:
	var best: CombatUnit
	for enemy in battle.get_enemies():
		if enemy.alive and (best == null or CombatUnit.grid_distance(from.cell, enemy.cell) < CombatUnit.grid_distance(from.cell, best.cell)):
			best = enemy
	return best


func _locked_battle(main: Node, spot: Vector2, groups: int) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = spot
	await _settle()
	var session := main.get_node("EncounterSession") as EncounterSession
	session.challenge()
	var frames := 0
	while session.get_context() != null and session.get_context().get_group_count() < groups and frames < 120:
		await physics_frame
		frames += 1
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	return main.get_combat()


func _new_main(path: String) -> Node2D:
	_commits.clear()
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	main.battle_result_committed.connect(func(result: BattleResult, saved: bool) -> void: _commits.append([result, saved]))
	await _settle()
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _delete(path: String) -> void:
	for p in [path, path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _settle() -> void:
	for frame in range(4):
		await physics_frame
	await process_frame


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
