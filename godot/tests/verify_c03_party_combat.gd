extends SceneTree

## Combat C03: Party & Mercenary Combat. The game's battle party is the Hero
## + two fixed Prototype Mercenaries (Merc A melee, Merc B 3-cell range).
## One friendly unit is selected at a time; move / target commands go to it
## only and every other unit keeps its own. Enemies attack the nearest alive
## friendly unit. DEFEAT only on a Full Party Wipe; VICTORY is still every
## enemy dead. Rules through CombatBattle.advance(ms); the LOCKED -> battle
## -> C02 lifecycle path in the real main scene.

const TEST_SAVE := "user://c03_party_test_save.json"
const T0 := 1800000000000
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const WITH_GROUP_1 := Vector2(800.0, 900.0)
## Stage 8 P04: the narrowed scope checks (calls that would recruit or change
## the roster).
const P04_NARROWED := {"recruit": ["recruit(", "recruitmentservice.price"], "roster": ["roster.add(", "roster.remove(", "set_deployment(", "create_mercenary(", "restore_snapshot("]}
const NODES := ["Actors/PrototypeMonster", "Actors/PrototypeMonster2", "Actors/PrototypeMonster3"]
const HOMES := [Vector2(800.0, 700.0), Vector2(1100.0, 700.0), Vector2(950.0, 930.0)]

var _checks := 0
var _failures := 0
var _sections_done := []
var _phases := []
var _hits := []
var _results := 0


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	_verify_party()
	_verify_selection()
	_verify_preparation()
	_verify_independent_commands()
	_verify_enemy_ai()
	_verify_friendly_death()
	_verify_defeat()
	_verify_victory()
	_verify_stress()
	await _verify_in_game()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 11, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("C03 party combat verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(CombatConfig.MERC_A == {"max_hp": 200, "attack_damage": 15, "attack_range": 1, "attack_interval_ms": 1000, "move_speed": 4.0}, "Merc A Prototype stats")
	_check(CombatConfig.MERC_B == {"max_hp": 150, "attack_damage": 12, "attack_range": 3, "attack_interval_ms": 1200, "move_speed": 4.0}, "Merc B Prototype stats")
	_check(CombatConfig.HERO == {"max_hp": 300, "attack_damage": 20, "attack_range": 1, "attack_interval_ms": 1000, "move_speed": 4.0}, "Hero stats unchanged")
	_check(CombatConfig.PREPARATION_MS == 3000 and CombatConfig.PREPARATION_COLUMNS == 3 and CombatConfig.PREPARATION_FIRST_COLUMN == 1 and CombatConfig.ROWS == 5 and CombatConfig.COLUMNS == 61, "3 s preparation, 5 x 3 area (C05: columns 1-3), 5 x 61 grid (C05)")
	_check(EncounterContext.PLANNED_COMBAT_ENEMIES == {1: 10, 2: 15, 3: 20}, "Encounter scaling unchanged")
	_check(SaveStore.VERSION == 12 and SaveStore.V8_KEYS == SaveStore.V7_KEYS, "Save version 12 (P05), unchanged sections")
	var save_code := _code_only("res://scripts/save_store.gd").to_lower()
	# P01.5 (Save v11) brought the Stage 8 Mercenary roster into the save; the
	# fixed combat Mercenaries, the party and Combat stay unknown to it.
	# P05 (Save v12) adds the pending legacy list and the legacy migration
	# (their names are roster names too).
	var roster_free := save_code.replace("mercenaryroster", "").replace("legacymercenarymigration", "").replace("mercenaries", "")
	_check(not roster_free.contains("merc") and not save_code.contains("party") and not save_code.contains("combat"), "The save knows nothing about Combat Mercenaries, party or Combat (only the P01.5 roster)")
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_config.gd", "res://scripts/combat_view.gd", "res://scripts/battle_result.gd"]:
		var code := _code_only(path).to_lower()
		# C04 brought Retreat into scope ("retreat" left the list).
		# C05 brought Level / EXP rewards into scope ("level" and "reward" left the list).
		# C06 brought Normal Skills into scope ("skill" and "skill_cooldown" left the list).
		# C08 brought Select All (全體) into scope ("select_all" left the list).
		for word in ["recruit", "roster", "hire", "equipment", "exp ", "loot", "revive", "heal", "mana", "formation", "taunt", "threat"]:
			# Stage 8 P04 (approved) brought the deployed roster Mercenaries into
			# combat_battle / combat_view (their label via RecruitmentService.label,
			# the view's roster for Level / EXP): there the check narrows to "no
			# recruiting and no roster change".
			if word in P04_NARROWED and path.get_file() in ["combat_battle.gd", "combat_view.gd"]:
				_check(P04_NARROWED[word].all(func(call: String) -> bool: return not code.contains(call)), "%s has no %s" % [path.get_file(), word])
				continue
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	_check(not _code_only("res://scripts/battle_result.gd").to_lower().contains("merc") and not _code_only("res://scripts/battle_result.gd").to_lower().contains("friend"), "BattleResult carries no party data")
	_sections_done.append("static")


# --- Party creation ------------------------------------------------------------------------------

func _verify_party() -> void:
	for groups in [1, 2, 3]:
		var context := EncounterContext.new()
		context.encounter_id = "encounter_%d" % groups
		for index in range(groups):
			context.group_monster_ids.append("prototype_monster_0%d" % (index + 1))
		var battle := CombatBattle.from_encounter(context)
		var friends := battle.get_friends()
		_check(battle.get_enemies().size() == {1: 10, 2: 15, 3: 20}[groups], "%d group(s) -> %d enemies" % [groups, {1: 10, 2: 15, 3: 20}[groups]])
		_check(friends.size() == 3 and friends.map(func(u: CombatUnit) -> int: return u.role) == [CombatUnit.Role.HERO, CombatUnit.Role.MERC_A, CombatUnit.Role.MERC_B], "Game party: Hero, Merc A, Merc B (%d group(s))" % groups)
	var battle := CombatBattle.create(20)
	var friends := battle.get_friends()
	var ids := {}
	var cells := {}
	var inside := true
	for unit in friends:
		ids[unit.id] = true
		cells[unit.cell] = true
		inside = inside and battle.is_cell_allowed(unit, unit.cell) and unit.cell.x >= 1 and unit.cell.x <= 3 and CombatBattle.is_in_grid(unit.cell) and unit.team == CombatUnit.Team.FRIEND and unit.alive
	_check(ids.size() == 3 and cells.size() == 3 and inside, "Three unique friendly units on unique cells inside the 5 x 3 area")
	_check(friends[0].cell == Vector2i(1, 2) and friends[1].cell == Vector2i(1, 1) and friends[2].cell == Vector2i(1, 3), "Spawn: Hero (1, 2), Merc A (1, 1), Merc B (1, 3)")
	_check(friends[0].is_hero and not friends[1].is_hero and not friends[2].is_hero and battle.get_hero() == friends[0], "Only the Hero is the Hero")
	_check(_stats(friends[1]) == [200, 200, 15, 1, 1000, 4.0] and _stats(friends[2]) == [150, 150, 12, 3, 1200, 4.0] and _stats(friends[0]) == [300, 300, 20, 1, 1000, 4.0], "Each friendly unit has its own stats")
	var enemy_cells := {}
	for enemy in battle.get_enemies():
		enemy_cells[enemy.cell] = true
	_check(enemy_cells.size() == 20 and not enemy_cells.has(friends[0].cell) and not enemy_cells.has(friends[1].cell) and not enemy_cells.has(friends[2].cell), "20 enemies, no cell shared with the party")
	_check(battle.get_selected() == friends[0], "The Hero starts selected")
	var fixture := CombatBattle.create(10, CombatBattle.PartyFixture.HERO_ONLY)
	_check(fixture.get_friends().size() == 1 and fixture.get_hero() != null, "HERO_ONLY test fixture still builds the C01 single-friendly battle")
	_sections_done.append("party")


# --- Selection -----------------------------------------------------------------------------------

func _verify_selection() -> void:
	var battle := _battle(10)
	var hero := battle.get_friends()[0]
	var merc_a := battle.get_friends()[1]
	var merc_b := battle.get_friends()[2]
	_check(battle.tap(merc_a.cell) and battle.get_selected() == merc_a, "Tap Merc A selects Merc A")
	_check(battle.tap(merc_b.cell) and battle.get_selected() == merc_b, "Tap Merc B selects Merc B (Merc A no longer selected)")
	_check(battle.tap(hero.cell) and battle.get_selected() == hero, "Tap the Hero selects the Hero")
	# Commands stay with the unit that got them.
	battle.select_unit(merc_a)
	_check(battle.command_move(Vector2i(1, 0)), "Merc A ordered to (1, 0)")
	battle.select_unit(merc_b)
	_check(battle.command_move(Vector2i(1, 4)), "Merc B ordered to (1, 4)")
	_check(merc_a.has_goal and merc_a.goal == Vector2i(1, 0) and merc_b.goal == Vector2i(1, 4) and not hero.has_goal, "Switching selection kept Merc A's order; the Hero has none")
	battle.advance(1000)
	_check(merc_a.cell == Vector2i(1, 0) and merc_b.cell == Vector2i(1, 4) and hero.cell == Vector2i(1, 2), "Both Mercs walked at the same time; the Hero stayed")
	battle.advance(2000)
	# The selected unit dies: nothing stays selected, commands are refused.
	battle.select_unit(merc_b)
	battle.resolve_damage(battle.get_enemies()[0], merc_b, 1000)
	_check(not merc_b.alive and battle.get_selected() == null, "The selected Merc B died: nothing selected")
	_check(not battle.command_move(Vector2i(5, 2)) and not battle.command_target(battle.get_enemies()[0]), "No selection: commands refused")
	_check(not battle.select_unit(merc_b) and not battle.tap(merc_b.cell) and battle.get_selected() == null, "A dead unit cannot be selected (tap or call)")
	_check(battle.tap(merc_a.cell) and battle.get_selected() == merc_a and battle.get_phase() == CombatBattle.Phase.FIGHTING, "Tap another alive unit to select it; the battle goes on")
	_check(not battle.select_unit(battle.get_enemies()[1]), "An enemy is never selected")
	_sections_done.append("selection")


# --- Preparation ---------------------------------------------------------------------------------

func _verify_preparation() -> void:
	var battle := _battle(10)
	var friends := battle.get_friends()
	var targets := [Vector2i(3, 0), Vector2i(2, 1), Vector2i(3, 4)]
	var all_limited := true
	var no_target := true
	for index in range(3):
		battle.select_unit(friends[index])
		all_limited = all_limited and not battle.command_move(Vector2i(4, index)) and not battle.command_move(Vector2i(0, index)) and not battle.command_move(Vector2i(20, 2))
		no_target = no_target and not battle.command_target(battle.get_enemies()[index]) and friends[index].target == null
		_check(battle.command_move(targets[index]), "%s may move inside the area during PREPARATION" % friends[index].id)
	_check(all_limited, "Every friendly unit is limited to the first 3 columns")
	_check(no_target, "No friendly unit may target during PREPARATION")
	battle.advance(2999)
	var cells := friends.map(func(u: CombatUnit) -> Vector2i: return u.cell)
	var max_x := 0
	for unit in friends:
		max_x = maxi(max_x, maxi(unit.cell.x, unit.next_cell.x))
	var min_x := 60
	for unit in friends:
		min_x = mini(min_x, mini(unit.cell.x, unit.next_cell.x))
	_check(cells == targets and max_x <= 3 and min_x >= 1, "All three moved at once, none left columns 1-3 (%s)" % str(cells))
	_check(battle.get_phase() == CombatBattle.Phase.PREPARATION and _phases.is_empty(), "2999 ms: still PREPARATION")
	battle.advance(1)
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and _phases == [CombatBattle.Phase.FIGHTING], "3000 ms: FIGHTING, once")
	var unlocked := true
	for index in range(3):
		battle.select_unit(friends[index])
		unlocked = unlocked and battle.is_cell_allowed(friends[index], Vector2i(30, 2)) and battle.command_target(battle.get_enemies()[index])
	_check(unlocked, "After 3 s every friendly unit may cross the area and target")
	_sections_done.append("preparation")


# --- Independent commands ------------------------------------------------------------------------

func _verify_independent_commands() -> void:
	var battle := _battle(3)
	var hero := battle.get_friends()[0]
	var merc_a := battle.get_friends()[1]
	var merc_b := battle.get_friends()[2]
	var enemies := battle.get_enemies()
	for enemy in enemies:
		enemy.max_hp = 100000
		enemy.hp = 100000
	_place(enemies[0], Vector2i(4, 1))
	_place(enemies[1], Vector2i(4, 3))
	_place(enemies[2], Vector2i(40, 0))
	enemies[2].move_speed = 0.001
	battle.advance(3000)
	battle.select_unit(hero)
	_check(battle.tap(enemies[0].cell) and hero.target == enemies[0], "The Hero targets enemy 1")
	battle.select_unit(merc_a)
	_check(battle.tap(enemies[0].cell) and merc_a.target == enemies[0], "Merc A targets the same enemy 1")
	battle.select_unit(merc_b)
	_check(battle.tap(enemies[1].cell) and merc_b.target == enemies[1], "Merc B targets enemy 2")
	_check(hero.target == enemies[0] and merc_a.target == enemies[0], "Switching selection kept the other targets")
	for step in range(40):
		battle.advance(100)
	var by_hero := _hits_by(hero)
	var by_a := _hits_by(merc_a)
	var by_b := _hits_by(merc_b)
	_check(not by_hero.is_empty() and by_hero.all(func(h: Array) -> bool: return h[1] == enemies[0] and h[2] == 20), "The Hero hits enemy 1 for 20")
	_check(not by_a.is_empty() and by_a.all(func(h: Array) -> bool: return h[1] == enemies[0] and h[2] == 15), "Merc A hits the same enemy 1 for 15")
	_check(not by_b.is_empty() and by_b.all(func(h: Array) -> bool: return h[1] == enemies[1] and h[2] == 12), "Merc B hits enemy 2 for 12")
	var b_times := by_b.map(func(h: Array) -> int: return h[3])
	_check(b_times.size() >= 2 and b_times[1] - b_times[0] == 1200, "Merc B attacks every 1200 ms (%s)" % str(b_times))
	_check(CombatUnit.grid_distance(merc_b.cell, enemies[1].cell) <= 3 and CombatUnit.grid_distance(merc_b.cell, enemies[1].cell) >= 2, "Merc B fights from range (%d cells)" % CombatUnit.grid_distance(merc_b.cell, enemies[1].cell))
	# Move one unit while the others keep attacking.
	battle.select_unit(hero)
	battle.command_move(Vector2i(10, 4))
	var a_before := _hits_by(merc_a).size()
	var b_before := _hits_by(merc_b).size()
	for step in range(30):
		battle.advance(100)
	_check(hero.cell == Vector2i(10, 4) and hero.target == null, "The Hero walked away (its own target dropped)")
	_check(_hits_by(merc_a).size() > a_before and _hits_by(merc_b).size() > b_before and merc_a.target == enemies[0] and merc_b.target == enemies[1], "Meanwhile Merc A and Merc B kept attacking")
	_sections_done.append("commands")


# --- Enemy AI --------------------------------------------------------------------------------------

func _verify_enemy_ai() -> void:
	# Nearest alive friendly unit: Merc B here.
	var battle := _battle(1)
	var friends := battle.get_friends()
	var enemy := battle.get_enemies()[0]
	enemy.max_hp = 100000
	enemy.hp = 100000
	_place(enemy, Vector2i(2, 4))
	battle.advance(3100)
	_check(_hits_by(enemy).size() == 1 and _hits_by(enemy)[0][1] == friends[2], "The enemy attacks the nearest friendly unit: Merc B")
	# Merc B dies: it retargets the next nearest alive unit.
	battle.resolve_damage(enemy, friends[2], 1000)
	_check(not friends[2].alive and battle.get_phase() == CombatBattle.Phase.FIGHTING, "Merc B dead, the battle goes on")
	var hits := _hits_by(enemy).size()
	for step in range(40):
		battle.advance(100)
	var later := _hits_by(enemy).slice(hits)
	_check(not later.is_empty() and later.all(func(h: Array) -> bool: return h[1] != friends[2] and h[1].alive), "It never attacks the dead Merc B, only alive units")
	_check(later[0][1] == friends[0], "It retargeted the nearest alive unit: the Hero (%s)" % later[0][1].id)
	# Nearest is the Hero from the other side; a tie goes to the Hero.
	var tie := _battle(1)
	var tie_enemy := tie.get_enemies()[0]
	_place(tie_enemy, Vector2i(2, 2))
	tie.advance(3100)
	_check(_hits_by(tie_enemy).size() == 1 and _hits_by(tie_enemy)[0][1] == tie.get_friends()[0], "Equal distance to the Hero and both Mercs: the Hero is attacked")
	# Enemies split naturally across the party.
	var split := _battle(20)
	for unit in split.get_friends():
		unit.max_hp = 1000000
		unit.hp = 1000000
	split.get_friends()[1].cell = Vector2i(1, 0)
	split.get_friends()[1].next_cell = Vector2i(1, 0)
	split.get_friends()[1].claim = Vector2i(1, 0)
	split.get_friends()[2].cell = Vector2i(1, 4)
	split.get_friends()[2].next_cell = Vector2i(1, 4)
	split.get_friends()[2].claim = Vector2i(1, 4)
	split.advance(45000)
	var victims := {}
	for hit in _hits:
		if hit[0].team == CombatUnit.Team.ENEMY:
			victims[hit[1].id] = true
	_check(victims.size() == 3, "20 enemies attack all three friendly units (%s)" % str(victims.keys()))
	_sections_done.append("enemy_ai")


# --- Friendly death ------------------------------------------------------------------------------

func _verify_friendly_death() -> void:
	var battle := _battle(2)
	var merc_a := battle.get_friends()[1]
	var enemies := battle.get_enemies()
	for enemy in enemies:
		enemy.max_hp = 100000
		enemy.hp = 100000
	battle.advance(3000)
	_place(enemies[0], Vector2i(4, 1))  # C05: enemies start at columns 57-60
	battle.select_unit(merc_a)
	battle.command_target(enemies[0])
	for step in range(30):
		battle.advance(100)
	_check(not _hits_by(merc_a).is_empty(), "Merc A was attacking")
	var cell := merc_a.cell
	battle.resolve_damage(enemies[1], merc_a, 1000)
	var hits := _hits_by(merc_a).size()
	for step in range(30):
		battle.advance(100)
	_check(not merc_a.alive and merc_a.hp == 0 and merc_a.target == null and not merc_a.has_goal, "Dead Merc A: HP 0, target and order cleared")
	_check(merc_a.cell == cell and not merc_a.is_moving() and _hits_by(merc_a).size() == hits, "It stopped moving and attacking")
	_check(battle.unit_at(cell) == null or battle.unit_at(cell) != merc_a, "It no longer stands on the grid for taps")
	_check(battle.resolve_damage(merc_a, enemies[0], 50) == 0, "It cannot deal damage")
	_check(battle.get_friends().size() == 3 and battle.get_friends()[1] == merc_a, "It stays in the party list (dead) for results and UI")
	_sections_done.append("friendly_death")


# --- Defeat ----------------------------------------------------------------------------------------

func _verify_defeat() -> void:
	# [death order, label]
	for order in [[0, 1, 2], [1, 0, 2], [2, 1, 0], [0, 2, 1]]:
		var battle := _battle(10)
		var friends := battle.get_friends()
		battle.advance(3000)
		var enemy := battle.get_enemies()[0]
		var names: Array = order.map(func(i: int) -> String: return friends[i].id)
		battle.resolve_damage(enemy, friends[order[0]], 1000)
		_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and battle.get_result() == null, "%s dead first: the battle goes on" % names[0])
		battle.resolve_damage(enemy, friends[order[1]], 1000)
		_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and battle.get_result() == null, "%s and %s dead, %s alive: the battle goes on" % names)
		battle.resolve_damage(enemy, friends[order[2]], 1000)
		_check(battle.get_phase() == CombatBattle.Phase.DEFEAT and _phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.DEFEAT], "Last friendly unit (%s) dead: DEFEAT exactly once" % names[2])
		_check(battle.get_result() != null and not battle.get_result().is_victory(), "DEFEAT result produced")
		battle.advance(3000)
		_check(_phases.size() == 2, "Nothing after DEFEAT")
	# Real fight: an idle party loses only when every unit is down.
	var idle := _battle(20)
	var hero_down_at := -1
	while not idle.is_over() and idle.get_elapsed_ms() < 300000:
		idle.advance(50)
		if hero_down_at < 0 and not idle.get_hero().alive:
			hero_down_at = idle.get_elapsed_ms()
			_check(idle.get_phase() == CombatBattle.Phase.FIGHTING or idle.get_friends().all(func(u: CombatUnit) -> bool: return not u.alive), "The Hero fell in the fight; the battle continued while a Merc lived")
	_check(idle.get_phase() == CombatBattle.Phase.DEFEAT and idle.get_friends().all(func(u: CombatUnit) -> bool: return not u.alive), "Idle party vs 20: DEFEAT only once all three are dead")
	_sections_done.append("defeat")


# --- Victory ---------------------------------------------------------------------------------------

func _verify_victory() -> void:
	var battle := _battle(10)
	var friends := battle.get_friends()
	battle.advance(3000)
	battle.resolve_damage(battle.get_enemies()[0], friends[0], 1000)
	_check(not friends[0].alive and battle.get_phase() == CombatBattle.Phase.FIGHTING, "Hero dead, Mercs fight on")
	for enemy in battle.get_enemies():
		enemy.max_hp = 1
		enemy.hp = mini(enemy.hp, 1)
	while not battle.is_over() and battle.get_elapsed_ms() < 120000:
		for merc in [friends[1], friends[2]]:
			if merc.alive and merc.target == null:
				battle.select_unit(merc)
				battle.command_target(_nearest_enemy(battle, merc))
		battle.advance(50)
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY and battle.get_alive_enemy_count() == 0 and not friends[0].alive, "The surviving Mercs win: VICTORY with the Hero dead")
	_check(battle.get_result() != null and battle.get_result().is_victory(), "VICTORY result produced")
	# Only Merc B left.
	var last := _battle(3)
	var lf := last.get_friends()
	last.advance(3000)
	last.resolve_damage(last.get_enemies()[0], lf[0], 1000)
	last.resolve_damage(last.get_enemies()[0], lf[1], 1000)
	for enemy in last.get_enemies():
		last.resolve_damage(lf[2], enemy, 1000)
	_check(last.get_phase() == CombatBattle.Phase.VICTORY and lf[2].alive and not lf[0].alive and not lf[1].alive, "Only Merc B alive kills the last enemy: VICTORY")
	# Playing it out with the whole party.
	var play := _battle(20)
	play.advance(3000)
	while not play.is_over() and play.get_elapsed_ms() < 300000:
		for unit in play.get_friends():
			if unit.alive and unit.target == null:
				play.select_unit(unit)
				play.command_target(_nearest_enemy(play, unit))
		play.advance(50)
	_check(play.get_phase() == CombatBattle.Phase.VICTORY, "Active party play beats 20 enemies (%d ms)" % play.get_elapsed_ms())
	_sections_done.append("victory")


# --- 3 vs 20 stress ----------------------------------------------------------------------------------

func _verify_stress() -> void:
	var worst := 0
	var shared := false
	var outside := false
	for round in range(3):
		var battle := _battle(20)
		battle.phase_changed.connect(_count_result)
		for unit in battle.get_friends():
			unit.max_hp = 2000
			unit.hp = 2000
		battle.advance(3000)
		var tick := 0
		while not battle.is_over() and battle.get_elapsed_ms() < 300000:
			if tick % (10 + round) == 0:
				for unit in battle.get_friends():
					if unit.alive and unit.target == null:
						battle.select_unit(unit)
						battle.command_target(_nearest_enemy(battle, unit))
			var start := Time.get_ticks_usec()
			battle.advance(16)
			worst = maxi(worst, Time.get_ticks_usec() - start)
			tick += 1
			var taken := {}
			for unit in battle.get_friends() + battle.get_enemies():
				outside = outside or not CombatBattle.is_in_grid(unit.cell) or not CombatBattle.is_in_grid(unit.next_cell)
				if unit.alive and not unit.is_moving():
					if taken.has(unit.cell) and not shared:
						print("C03 shared cell ", unit.cell, " by ", unit.id, " and ", taken[unit.cell], " at ", battle.get_elapsed_ms())
					shared = shared or taken.has(unit.cell)
					taken[unit.cell] = unit.id
		_check(battle.is_over(), "3 vs 20 round %d reached a result (%s at %d ms)" % [round + 1, CombatBattle.Phase.keys()[battle.get_phase()], battle.get_elapsed_ms()])
	_check(_results == 3, "Exactly one result per battle (%d)" % _results)
	_check(not shared and not outside, "No shared standing cell, nobody off the grid")
	print("C03 stress: worst 3 vs 20 tick %d us" % worst)
	_check(worst < 50000, "No tick above 50 ms (worst %d us)" % worst)
	_sections_done.append("stress")


# --- In game: LOCKED -> party battle -> C02 lifecycle -------------------------------------------------

func _verify_in_game() -> void:
	var main := await _new_main(TEST_SAVE)
	_deploy_fixture_party(main)
	var session := main.get_node("EncounterSession") as EncounterSession
	var view := main.get_node("CombatView") as CombatView
	var money: int = main.wallet.get_balance()
	var battle := await _locked_battle(main, PASSIVE_ONLY)
	var friends := battle.get_friends()
	_check(friends.size() == 3 and battle.get_enemies().size() == 10, "The game's battle: Hero + Merc A + Merc B vs 10 (Stage 8 P04: the deployed 守衛 + 法師)")
	await process_frame
	# C08: per-unit HP moved from the always-on HUD text to the portraits /
	# ⓘ info; the camera no longer follows the selected unit.
	_check(view.get_info_text(friends[0]).contains("血量 300 / 300") and view.get_info_text(friends[1]).contains("血量 200 / 200") and view.get_info_text(friends[2]).contains("血量 150 / 150") and view.get_portrait_unit(2) == friends[2], "Each friendly unit's HP is shown (portrait / info)")
	var scroll := view.get_scroll_x()
	_check(view.tap_at(view.cell_center(Vector2(friends[2].cell))) and battle.get_selected() == friends[2] and view.get_scroll_x() == scroll, "Tap Merc B on screen: selected, the camera does not move (C08)")
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_enemies()[0], friends[0], 1000)
	await process_frame
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and not (view.get_node("ExitButton") as Button).visible and view.get_portrait_state(0)["dead"] and view.get_info_text(friends[0]).contains("血量 0 / 300"), "Hero dead in game: portrait 陣亡, still fighting, no exit")
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and main.get_combat() == battle, "The encounter stays LOCKED")
	battle.resolve_damage(battle.get_enemies()[0], friends[1], 1000)
	battle.resolve_damage(battle.get_enemies()[0], friends[2], 1000)
	await process_frame
	_check(battle.get_phase() == CombatBattle.Phase.DEFEAT and view.get_scroll_x() == scroll, "Full Party Wipe: DEFEAT; the camera stays where it was (C08: no follow)")
	_delete(TEST_SAVE)
	(view.get_node("ExitButton") as Button).pressed.emit()
	var group_3 := main.get_node(NODES[2]) as WorldMonster
	_check(battle.get_result().is_committed() and session.get_phase() == EncounterSession.Phase.NONE and main.get_combat() == null, "C02 lifecycle: DEFEAT committed, encounter ended, battle closed")
	_check(group_3.global_position == HOMES[2] and not group_3.is_held() and session.get_protection_remaining_ms() == 5000, "C02 DEFEAT: group reset home, 5 s protection")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(saved != null and int(saved["version"]) == 12 and _only_progression_mentions_mercs(saved) and main.wallet.get_balance() == money, "Saved once: v11, no Mercenary battle data (C05: only their Level / EXP; S05: their allocation counts; P01.5 / P04: the roster's instances only), no money reward or penalty")
	await _destroy(main)
	# VICTORY with the Hero dead, through the C02 lifecycle.
	main = await _new_main("")
	_deploy_fixture_party(main)
	session = main.get_node("EncounterSession") as EncounterSession
	view = main.get_node("CombatView") as CombatView
	battle = await _locked_battle(main, WITH_GROUP_1)
	friends = battle.get_friends()
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_enemies()[0], friends[0], 1000)
	for enemy in battle.get_enemies():
		battle.resolve_damage(friends[1], enemy, 1000)
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY and battle.get_result().is_victory() and battle.get_result().group_monster_ids.size() == 2, "Hero dead, Merc A finishes: VICTORY for both groups")
	await process_frame
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(not main.has_node(NODES[0]) and not main.has_node(NODES[2]) and main.has_node(NODES[1]), "C02 VICTORY: participants removed for this session, group 2 stays")
	_check(session.get_phase() == EncounterSession.Phase.NONE and session.is_protection_active() and not (main.get_node("Actors/Player") as Player).movement_locked, "Encounter ended, protection on, player free")
	await _destroy(main)
	_sections_done.append("in_game")


# --- Helpers --------------------------------------------------------------------------------------

## A new game-party battle whose signals feed _phases / _hits.
func _battle(enemies: int) -> CombatBattle:
	_phases.clear()
	_hits.clear()
	var battle := CombatBattle.create(enemies)
	battle.phase_changed.connect(func(phase: int) -> void: _phases.append(phase))
	battle.damage_dealt.connect(func(attacker: CombatUnit, target: CombatUnit, amount: int) -> void: _hits.append([attacker, target, amount, battle.get_elapsed_ms()]))
	return battle


## C05: the save keeps the slots' Level / EXP (exactly {level, exp}) and
## nothing else about the Mercenaries; S05 (v10) adds exactly their four
## allocation point counts.
func _only_progression_mentions_mercs(saved: Dictionary) -> bool:
	var rest := saved.duplicate(true)
	var progression: Variant = rest.get("progression")
	rest.erase("progression")
	# P05 (Save v12): the Hero's only.
	if typeof(progression) != TYPE_DICTIONARY or progression.keys() != ["hero"]:
		return false
	for slot in progression:
		if progression[slot].keys().size() != 2 or not progression[slot].has_all(["level", "exp"]):
			return false
	var allocation: Variant = rest.get("allocation")
	rest.erase("allocation")
	# P01.5: the Stage 8 roster section. P04: exactly the two deployed fixture
	# instances, each only id / type / Level / EXP / allocation (no battle data).
	var roster: Variant = rest.get("mercenaries")
	if typeof(roster) != TYPE_DICTIONARY or roster.keys().size() != 3 or roster.get("deployed") != ["merc_1", "merc_2"] or int(roster.get("next_serial", 0)) != 3:
		return false
	var owned: Variant = roster.get("owned")
	if typeof(owned) != TYPE_ARRAY or owned.size() != 2 or not owned.all(func(m: Variant) -> bool: return typeof(m) == TYPE_DICTIONARY and m.keys().size() == Mercenary.KEYS.size() and m.has_all(Mercenary.KEYS)):
		return false
	rest.erase("mercenaries")
	if rest.get("pending_legacy_mercenaries") != []:
		return false
	rest.erase("pending_legacy_mercenaries")
	if typeof(allocation) != TYPE_DICTIONARY or allocation.keys() != ["hero"]:
		return false
	for slot in allocation:
		if allocation[slot].keys().size() != 4 or not allocation[slot].has_all(["hp", "str", "agi", "int"]):
			return false
	return not JSON.stringify(rest).to_lower().contains("merc")


func _count_result(phase: int) -> void:
	if phase == CombatBattle.Phase.VICTORY or phase == CombatBattle.Phase.DEFEAT:
		_results += 1


func _stats(unit: CombatUnit) -> Array:
	return [unit.max_hp, unit.hp, unit.attack_damage, unit.attack_range, unit.attack_interval_ms, unit.move_speed]


func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


func _hits_by(attacker: CombatUnit) -> Array:
	return _hits.filter(func(hit: Array) -> bool: return hit[0] == attacker)


func _nearest_enemy(battle: CombatBattle, from: CombatUnit) -> CombatUnit:
	var best: CombatUnit
	for enemy in battle.get_enemies():
		if enemy.alive and (best == null or CombatUnit.grid_distance(from.cell, enemy.cell) < CombatUnit.grid_distance(from.cell, best.cell)):
			best = enemy
	return best


func _locked_battle(main: Node, spot: Vector2) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = spot
	await _settle()
	var session := main.get_node("EncounterSession") as EncounterSession
	session.challenge()
	for frame in range(60):
		await physics_frame
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	return main.get_combat()


## Stage 8 P04: the game's battle is the Hero + the deployed roster
## Mercenaries. A deployed 守衛 + 法師 (Lv1, no points) reproduce the C03 party:
## Merc A / Merc B profiles, start cells and Skills.
func _deploy_fixture_party(main: Node) -> void:
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "MAGE")], ["merc_1", "merc_2"])


func _new_main(path: String) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
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
