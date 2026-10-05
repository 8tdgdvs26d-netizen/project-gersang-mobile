extends SceneTree

## Combat C01: minimum playable battle. A LOCKED encounter opens a 5 x 60
## grid battle with 10 / 15 / 20 enemies (1 / 2 / 3 World Enemy Groups), a
## fixed 3 s preparation (enemies frozen, the Hero limited to the left 5 x 3
## cells), then real-time fighting (select / move / target, automatic approach
## and Basic Attack, enemy pursuit) until VICTORY (every enemy dead) or DEFEAT
## (the Hero dead). Rules run through CombatBattle.advance(ms) with exact
## milliseconds; the LOCKED -> Combat -> exit path runs in the real main scene.

const TEST_SAVE := "user://c01_combat_test_save.json"
const T0 := 1800000000000
const IDS := ["prototype_monster_01", "prototype_monster_02", "prototype_monster_03"]
const HOMES := [Vector2(800.0, 700.0), Vector2(1100.0, 700.0), Vector2(950.0, 930.0)]
## E03 spots: only passive group 3 / groups 3 + 1 / all three groups.
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const WITH_GROUP_1 := Vector2(800.0, 900.0)
const MIDDLE := Vector2(950.0, 800.0)
const HERO_CELL := Vector2i(1, 2)

var _checks := 0
var _failures := 0
var _sections_done := []
var _phases := []
var _hits := []
var _deaths := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	_verify_entry()
	_verify_preparation()
	_verify_transition()
	_verify_target_and_attack()
	_verify_death()
	_verify_enemy_ai()
	_verify_occupancy()
	_verify_results()
	await _verify_locked_to_combat()
	await _verify_group_counts_in_game()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 11, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("C01 combat verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(CombatConfig.ROWS == 5 and CombatConfig.COLUMNS == 61, "Battlefield is 5 rows x 61 columns (C05)")
	_check(CombatConfig.PREPARATION_MS == 3000 and CombatConfig.PREPARATION_COLUMNS == 3, "Preparation: 3000 ms, first 3 columns")
	_check(CombatConfig.HERO == {"max_hp": 300, "attack_damage": 20, "attack_range": 1, "attack_interval_ms": 1000, "move_speed": 4.0}, "Hero Prototype stats as approved")
	_check(CombatConfig.ENEMY == {"max_hp": 40, "attack_damage": 4, "attack_range": 1, "attack_interval_ms": 1500, "move_speed": 2.0}, "Enemy Prototype stats as approved (one archetype)")
	_check(EncounterContext.PLANNED_COMBAT_ENEMIES == {1: 10, 2: 15, 3: 20} and EncounterHandoff.MAX_GROUPS == 3, "1 / 2 / 3 groups -> 10 / 15 / 20 enemies, at most 3 groups")
	_check(SaveStore.VERSION == 12 and not _code_only("res://scripts/save_store.gd").to_lower().contains("combat"), "Save version 12 (P05); the save knows nothing about Combat")
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_config.gd", "res://scripts/combat_view.gd"]:
		var code := _code_only(path).to_lower()
		# C03 brought the fixed Prototype Mercenaries into scope ("merc" left the list).
		# C04 brought Retreat into scope ("retreat" left the list).
		# C05 brought EXP rewards into scope ("reward" and "exp" left the list).
		# C06 brought Normal Skills into scope ("skill" left the list).
		for word in ["loot", "mana", "crit", "dodge", "randf", "randi", "time.get_", "time_source", "save_store"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	_check(main.combat_enabled == true, "Combat is enabled by default (the flag is a test seam only)")
	main.free()
	_sections_done.append("static")


# --- Entry ---------------------------------------------------------------------------------------

func _verify_entry() -> void:
	for groups in [1, 2, 3]:
		var context := EncounterContext.new()
		context.encounter_id = "encounter_%d" % groups
		for index in range(groups):
			context.group_monster_ids.append(IDS[index])
		var battle := CombatBattle.from_encounter(context)
		var expected: int = {1: 10, 2: 15, 3: 20}[groups]
		_check(battle != null and battle.get_enemies().size() == expected and battle.get_alive_enemy_count() == expected, "%d group(s) -> %d enemies" % [groups, expected])
		_check(battle.encounter_id == context.encounter_id and battle.group_monster_ids == context.group_monster_ids, "The battle keeps its encounter id and groups (%d)" % groups)
		var cells := {}
		var valid := true
		for enemy in battle.get_enemies():
			valid = valid and enemy.alive and enemy.hp == 40 and enemy.team == CombatUnit.Team.ENEMY and enemy.cell.x >= 57 and enemy.cell.x <= 60 and CombatBattle.is_in_grid(enemy.cell)
			cells[enemy.cell] = true
		_check(valid and cells.size() == expected, "Enemies on distinct cells in columns 57–60 (C05) (%d)" % groups)
	var empty := EncounterContext.new()
	_check(CombatBattle.from_encounter(empty) == null and CombatBattle.from_encounter(null) == null, "No battle without a valid locked encounter")
	var battle := CombatBattle.create(10, CombatBattle.PartyFixture.HERO_ONLY)
	var hero := battle.get_hero()
	_check(battle.get_friends().size() == 1 and hero.is_hero and hero.cell == HERO_CELL and hero.hp == 300, "Hero only, at (1, 2) with full HP")
	_check(battle.get_selected() == hero, "The Hero starts selected")
	_check(battle.get_phase() == CombatBattle.Phase.PREPARATION and battle.get_preparation_remaining_ms() == 3000, "The battle opens in PREPARATION with 3000 ms")
	_sections_done.append("entry")


# --- Preparation ---------------------------------------------------------------------------------

func _verify_preparation() -> void:
	var battle := _battle(10)
	var hero := battle.get_hero()
	# An enemy right next to the Hero during the whole preparation.
	var close := battle.get_enemies()[0]
	_place(close, Vector2i(2, 2))
	var start := _cells(battle.get_enemies())
	_check(battle.select_unit(hero), "The Hero can be selected during PREPARATION")
	_check(battle.command_move(Vector2i(1, 0)), "Move inside the 5 x 3 area (C05: columns 1-3) is accepted")
	battle.advance(1000)
	_check(hero.cell == Vector2i(1, 0), "The Hero walked to (1, 0)")
	var legal := 0
	for column in range(CombatConfig.COLUMNS):
		for row in range(CombatConfig.ROWS):
			if battle.is_cell_allowed(hero, Vector2i(column, row)):
				legal += 1
	_check(legal == 15, "Exactly 15 legal preparation cells (%d)" % legal)
	_check(not battle.command_move(Vector2i(4, 0)) and not battle.command_move(Vector2i(4, 4)) and not battle.command_move(Vector2i(30, 2)) and not battle.command_move(Vector2i(0, 2)), "C05: column 0 and columns 4+ are refused")
	_check(not battle.tap(Vector2i(5, 2)) and hero.goal == Vector2i(1, 0), "A tap beyond the area is refused, the last command kept")
	_check(not battle.command_target(close) and not battle.tap(close.cell) and hero.target == null, "No targeting before FIGHTING")
	_check(battle.command_move(Vector2i(2, 4)), "Move to the area's last column is accepted")
	battle.advance(1000)
	_check(hero.cell == Vector2i(2, 4), "The Hero reached (2, 4)")
	battle.advance(999)
	var max_x := 0
	for friend in battle.get_friends():
		max_x = maxi(max_x, maxi(friend.cell.x, friend.next_cell.x))
	_check(battle.get_phase() == CombatBattle.Phase.PREPARATION and battle.get_elapsed_ms() == 2999, "Still PREPARATION at 2999 ms")
	var min_x := 60
	for friend in battle.get_friends():
		min_x = mini(min_x, mini(friend.cell.x, friend.next_cell.x))
	_check(max_x <= 3 and min_x >= 1, "The Hero never left columns 1-3 (C05)")
	_check(_cells(battle.get_enemies()) == start, "No enemy moved during PREPARATION")
	var ready := true
	for enemy in battle.get_enemies():
		ready = ready and enemy.attack_cooldown_ms == 0 and enemy.target == null and not enemy.is_moving()
	_check(ready and _hits.is_empty(), "No enemy attacked during PREPARATION")
	_check(hero.hp == 300 and battle.resolve_damage(close, hero, 4) == 0 and hero.hp == 300, "No damage is possible during PREPARATION")
	_sections_done.append("preparation")


# --- Preparation -> Fighting -------------------------------------------------------------------

func _verify_transition() -> void:
	var battle := _battle(10)
	var hero := battle.get_hero()
	var start := _cells(battle.get_enemies())
	battle.advance(2900)
	_check(battle.command_move(Vector2i(2, 2)), "A move ordered at 2900 ms")
	battle.advance(99)
	_check(battle.get_phase() == CombatBattle.Phase.PREPARATION and _phases.is_empty(), "2999 ms: PREPARATION, no transition yet")
	_check(_cells(battle.get_enemies()) == start, "2999 ms: enemies still in place")
	battle.advance(1)
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and _phases == [CombatBattle.Phase.FIGHTING], "3000 ms: FIGHTING, the transition happened once")
	var visual := hero.visual_cell()
	_check(hero.cell == HERO_CELL and hero.next_cell == Vector2i(2, 2) and visual.x > 1.0 and visual.x < 2.0, "The Hero is mid-step at the transition (no teleport: %s)" % str(visual))
	battle.advance(1)
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and _phases.size() == 1 and battle.get_elapsed_ms() == 3001, "3001 ms: still FIGHTING, no second transition")
	battle.advance(200)
	_check(hero.cell == Vector2i(2, 2) and not hero.has_goal, "The pre-transition move completed normally")
	_check(battle.is_cell_allowed(hero, Vector2i(30, 0)) and battle.command_move(Vector2i(4, 2)), "The preparation limit is gone")
	battle.advance(500)
	_check(hero.cell == Vector2i(4, 2), "The Hero walks past column 3")
	_check(_cells(battle.get_enemies()) != start, "Enemies move once FIGHTING")
	# One advance across the boundary: FIGHTING only gets the part after 3000 ms.
	var jump := _battle(10)
	var enemy := jump.get_enemies()[0]
	jump.advance(3499)
	_check(jump.get_phase() == CombatBattle.Phase.FIGHTING and _phases.size() == 1 and enemy.cell == Vector2i(59, 0) and enemy.is_moving(), "3499 ms in one go: the enemy has been active only 499 ms")
	jump.advance(1)
	_check(enemy.cell == Vector2i(58, 1), "Its first step lands exactly 500 ms after the transition")
	# A move issued during preparation is still carried out afterwards.
	var carried := _battle(10)
	carried.advance(2500)
	_check(carried.command_move(Vector2i(3, 4)), "Move ordered at 2500 ms")
	carried.advance(1000)
	_check(carried.get_hero().cell == Vector2i(3, 4) and not carried.get_hero().has_goal, "Not stuck: the move ends at (3, 4) after the transition")
	_sections_done.append("transition")


# --- Target / Basic Attack -----------------------------------------------------------------------

func _verify_target_and_attack() -> void:
	# In range from the start: exact Basic Attack cadence, 100% hit.
	var battle := _battle(1)
	var hero := battle.get_hero()
	var enemy := battle.get_enemies()[0]
	enemy.max_hp = 100
	enemy.hp = 100
	_place(enemy, Vector2i(2, 2))
	battle.advance(3000)
	_check(battle.tap(enemy.cell) and hero.target == enemy, "Tapping an enemy targets it")
	for step in range(42):
		battle.advance(100)
	var hero_hits := _hits_by(hero)
	_check(hero_hits.size() == 5 and enemy.hp == 0 and not enemy.alive, "Five 20-damage hits kill a 100 HP enemy (%d)" % hero_hits.size())
	_check(hero_hits.map(func(hit: Array) -> int: return hit[3]) == [3000, 4000, 5000, 6000, 7000], "Hero attacks every 1000 ms (%s)" % str(hero_hits.map(func(hit: Array) -> int: return hit[3])))
	_check(hero_hits.all(func(hit: Array) -> bool: return hit[2] == 20), "Every attack hits for 20 (100% hit)")
	var enemy_hits := _hits_by(enemy)
	_check(enemy_hits.map(func(hit: Array) -> int: return hit[3]) == [3000, 4500, 6000] and hero.hp == 288, "The enemy attacks every 1500 ms (hero %d HP)" % hero.hp)
	_check(hero.cell == HERO_CELL, "An in-range target is attacked without moving")
	# Out of range: approach, stop in range, then attack.
	var far := _battle(1)
	var far_hero := far.get_hero()
	var target := far.get_enemies()[0]
	far.advance(3000)
	_check(far.command_target(target) and not far_hero.has_goal, "Target an enemy 58 columns away (C05)")
	far.advance(250)
	_check(far_hero.cell.x == 2, "The Hero approaches (%s)" % str(far_hero.cell))
	var frames := 0
	while _hits_by(far_hero).is_empty() and frames < 400:
		far.advance(50)
		frames += 1
	var first := _hits_by(far_hero)
	_check(first.size() == 1 and CombatUnit.grid_distance(far_hero.cell, target.cell) <= 1 and not far_hero.is_moving(), "In range it stops and attacks automatically")
	var cell := far_hero.cell
	far.advance(900)
	_check(far_hero.cell == cell and _hits_by(far_hero).size() == 1, "It stays put and waits for the interval")
	# Move command drops the target.
	far.command_move(Vector2i(0, 0))
	_check(far_hero.target == null and far_hero.has_goal, "A move command drops the target")
	_sections_done.append("target_attack")


# --- HP / Death ----------------------------------------------------------------------------------

func _verify_death() -> void:
	var battle := _battle(2)
	var hero := battle.get_hero()
	var first := battle.get_enemies()[0]
	var second := battle.get_enemies()[1]
	_place(first, Vector2i(2, 2))
	_place(second, Vector2i(2, 1))
	battle.advance(3000)
	_check(battle.resolve_damage(hero, first, 15) == 15 and first.hp == 25 and first.alive, "Damage lowers HP (40 -> 25)")
	_check(battle.resolve_damage(hero, first, 30) == 25 and first.hp == 0 and not first.alive, "HP <= 0 -> Dead (never below 0)")
	_check(_deaths == [first], "One death reported")
	_check(battle.resolve_damage(hero, first, 10) == 0 and battle.resolve_damage(first, hero, 10) == 0 and hero.hp == 300, "A dead unit takes and deals no damage")
	_check(not battle.command_target(first) and battle.unit_at(first.cell) == null, "A dead unit is no valid target")
	var distant := _battle(3)
	var far_enemy := distant.get_enemies()[2]
	distant.advance(3000)
	distant.resolve_damage(distant.get_hero(), far_enemy, 1000)
	var far_cell := far_enemy.cell
	for step in range(20):
		distant.advance(100)
	_check(not far_enemy.alive and far_enemy.cell == far_cell and not far_enemy.is_moving() and far_enemy.claim == CombatUnit.NO_CELL, "A dead enemy far from the Hero stops pursuing (%s)" % str(far_enemy.cell))
	_check(distant.get_enemies()[0].cell != Vector2i(10, 0), "While the living ones keep pursuing")
	var dead_cell := first.cell
	battle.command_target(second)
	for step in range(30):
		battle.advance(100)
	_check(first.cell == dead_cell and not first.is_moving() and _hits_by(first).is_empty(), "The dead unit never moves or attacks")
	_check(not second.alive and hero.target == null, "Target killed -> the Hero's target is cleared")
	var hits := _hits_by(hero).size()
	battle.advance(3000)
	_check(_hits_by(hero).size() == hits, "No attack on a dead target (no invalid loop)")
	# Target dies while others remain: the Hero waits for a new command.
	var wait := _battle(2)
	var wait_hero := wait.get_hero()
	var a := wait.get_enemies()[0]
	var b := wait.get_enemies()[1]
	_place(a, Vector2i(2, 2))
	_place(b, Vector2i(2, 1))
	wait.advance(3000)
	wait.command_target(a)
	while a.alive:
		wait.advance(100)
	var after := _hits_by(wait_hero).size()
	var cell := wait_hero.cell
	for step in range(30):
		wait.advance(100)
	_check(wait_hero.target == null and _hits_by(wait_hero).size() == after and wait_hero.cell == cell and b.alive, "No automatic retarget: the Hero waits")
	_check(_hits_by(b).size() >= 2 and wait.get_phase() == CombatBattle.Phase.FIGHTING, "The other enemy keeps attacking")
	_check(wait.tap(b.cell) and wait_hero.target == b, "A new tap targets the next enemy")
	_sections_done.append("death")


# --- Enemy AI --------------------------------------------------------------------------------------

func _verify_enemy_ai() -> void:
	var battle := _battle(1)
	var hero := battle.get_hero()
	hero.max_hp = 100000
	hero.hp = 100000
	var enemy := battle.get_enemies()[0]
	enemy.max_hp = 100000
	enemy.hp = 100000
	battle.advance(3000)
	var distance := CombatUnit.grid_distance(enemy.cell, hero.cell)
	battle.advance(1000)
	_check(CombatUnit.grid_distance(enemy.cell, hero.cell) == distance - 2, "The enemy approaches the Hero (2 cells / s)")
	var frames := 0
	while _hits_by(enemy).is_empty() and frames < 800:
		battle.advance(50)
		frames += 1
	_check(not _hits_by(enemy).is_empty() and CombatUnit.grid_distance(enemy.cell, hero.cell) <= 1 and hero.hp == 100000 - 4, "In range it attacks the Hero")
	battle.command_move(Vector2i(20, 4))
	frames = 0
	while (hero.cell != Vector2i(20, 4) or CombatUnit.grid_distance(enemy.cell, hero.cell) > 1) and frames < 400:
		battle.advance(50)
		frames += 1
	_check(hero.cell == Vector2i(20, 4) and CombatUnit.grid_distance(enemy.cell, hero.cell) <= 1, "It pursues the moving Hero (%s)" % str(enemy.cell))
	var before := _hits_by(enemy).size()
	battle.advance(1600)
	_check(_hits_by(enemy).size() > before, "And attacks again after catching up")
	_sections_done.append("enemy_ai")


# --- Grid occupancy ------------------------------------------------------------------------------

func _verify_occupancy() -> void:
	var battle := _battle(20)
	var hero := battle.get_hero()
	hero.max_hp = 1000000
	hero.hp = 1000000
	battle.advance(3000)
	var shared := false
	var outside := false
	for step in range(800):
		battle.advance(50)
		var taken := {}
		for unit in battle.get_friends() + battle.get_enemies():
			outside = outside or not CombatBattle.is_in_grid(unit.cell) or not CombatBattle.is_in_grid(unit.next_cell)
			if unit.alive and not unit.is_moving():
				shared = shared or taken.has(unit.cell)
				taken[unit.cell] = true
	_check(not shared, "No two standing units ever share a cell (20 enemies, 40 s)")
	_check(not outside, "Every unit stays on the 5 x 60 grid")
	var adjacent := 0
	for enemy in battle.get_enemies():
		if CombatUnit.grid_distance(enemy.cell, hero.cell) <= 1 and not enemy.is_moving():
			adjacent += 1
	_check(adjacent == 8, "The 8 cells around the Hero at (1, 2) are all taken (%d)" % adjacent)
	var cells := _cells(battle.get_enemies())
	battle.advance(3000)
	_check(_cells(battle.get_enemies()) == cells, "Waiting enemies stay put (no jitter)")
	_sections_done.append("occupancy")


# --- Victory / Defeat ----------------------------------------------------------------------------

func _verify_results() -> void:
	# Victory by play: the player targets the nearest enemy whenever idle.
	var battle := _battle(10)
	var hero := battle.get_hero()
	battle.advance(3000)
	while not battle.is_over() and battle.get_elapsed_ms() < 120000:
		if hero.target == null:
			battle.command_target(_nearest_enemy(battle))
		battle.advance(50)
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY and battle.get_alive_enemy_count() == 0 and hero.alive, "All 10 enemies dead -> VICTORY (hero %d HP, %d ms)" % [hero.hp, battle.get_elapsed_ms()])
	_check(_phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.VICTORY], "VICTORY reached once")
	_check_frozen(battle, "VICTORY")
	# Defeat: an idle Hero dies.
	var lost := _battle(10)
	lost.advance(3000)
	while not lost.is_over() and lost.get_elapsed_ms() < 120000:
		lost.advance(50)
	_check(lost.get_phase() == CombatBattle.Phase.DEFEAT and not lost.get_hero().alive and lost.get_hero().hp == 0, "Hero dead -> C01 DEFEAT")
	_check(_phases == [CombatBattle.Phase.FIGHTING, CombatBattle.Phase.DEFEAT] and lost.get_selected() == null, "DEFEAT reached once; nothing stays selected")
	_check_frozen(lost, "DEFEAT")
	_sections_done.append("results")


func _check_frozen(battle: CombatBattle, label: String) -> void:
	var cells := _cells(battle.get_friends() + battle.get_enemies())
	var hits := _hits.size()
	var hp := []
	for unit in battle.get_friends() + battle.get_enemies():
		hp.append(unit.hp)
	var elapsed := battle.get_elapsed_ms()
	for step in range(40):
		battle.advance(100)
	var hp_after := []
	for unit in battle.get_friends() + battle.get_enemies():
		hp_after.append(unit.hp)
	_check(_cells(battle.get_friends() + battle.get_enemies()) == cells and _hits.size() == hits and hp_after == hp and battle.get_elapsed_ms() == elapsed, "%s: nothing moves, attacks or takes damage afterwards" % label)
	var alive := battle.get_enemies().filter(func(unit: CombatUnit) -> bool: return unit.alive)
	var some_enemy: CombatUnit = alive[0] if not alive.is_empty() else battle.get_enemies()[0]
	_check(not battle.command_move(Vector2i(5, 2)) and not battle.command_target(some_enemy) and battle.resolve_damage(some_enemy, battle.get_hero(), 5) == 0, "%s: commands and damage are refused" % label)


# --- The real LOCKED -> Combat path ----------------------------------------------------------------

func _verify_locked_to_combat() -> void:
	var main := await _new_main(TEST_SAVE)
	var player := main.get_node("Actors/Player") as Player
	var session := main.get_node("EncounterSession") as EncounterSession
	var handoff := main.get_node("EncounterHandoff") as EncounterHandoff
	var view := main.get_node("CombatView") as CombatView
	var money: int = main.wallet.get_balance()
	player.global_position = PASSIVE_ONLY
	await _settle()
	_check(session.challenge() and session.get_phase() == EncounterSession.Phase.JOINING, "Challenge -> JOINING")
	_check(main.get_combat() == null and not view.visible, "No battle during JOINING")
	main.time_source.advance_ms(4999)
	await _process_frames(2)
	_check(main.get_combat() == null, "No battle at 4999 ms")
	main.time_source.advance_ms(1)
	await _process_frames(2)
	var battle: CombatBattle = main.get_combat()
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and battle != null and view.visible and view.is_open(), "LOCKED -> the battlefield opens")
	_check(battle.encounter_id == session.get_context().encounter_id and battle.group_monster_ids == [IDS[2]] and battle.get_enemies().size() == 10, "1 group -> 10 enemies, linked to its encounter")
	_check(player.movement_locked and handoff.has_pending_encounter() and main.location.is_in_world(), "The world stays LOCKED under the battle")
	_check(not (main.get_node("TouchControls/Joystick") as Node).is_processing_input(), "The world joystick is off during Combat")
	var status := view.get_node("StatusLabel") as Label
	var exit := view.get_node("ExitButton") as Button
	_check(status.text == "備戰 3" and not exit.visible, "Countdown shows 備戰 3; no exit button")
	# Taps through the view's screen mapping.
	var hero := battle.get_hero()
	_check(view.cell_at(view.cell_center(Vector2(hero.cell))) == hero.cell and view.tap_at(view.cell_center(Vector2(hero.cell))), "Tap on the Hero selects it")
	_check(not view.tap_at(view.cell_center(Vector2(8, 2))), "Tap beyond the preparation area is refused")
	_check(view.tap_at(view.cell_center(Vector2(2, 1))) and hero.goal == Vector2i(2, 1), "Tap inside the area moves the Hero")
	# Physics time drives the battle: 3 s = 180 physics frames.
	await _frames(170)
	_check(battle.get_phase() == CombatBattle.Phase.PREPARATION and status.text in ["備戰 1", "備戰 2"], "Still preparing after 170 physics frames (%s)" % status.text)
	await _frames(20)
	await process_frame
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and status.text == "戰鬥", "FIGHTING after 3 s of physics time")
	var enemy := battle.get_enemies()[0]
	_check(view.tap_at(view.cell_center(Vector2(enemy.cell))) and hero.target == enemy, "Tap on an enemy targets it")
	# Finish the battle through the damage path, then leave.
	for unit in battle.get_enemies():
		battle.resolve_damage(hero, unit, 1000)
	await _process_frames(2)
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY and status.text == "勝利" and exit.visible and exit.text == "返回世界", "VICTORY: 勝利 and 返回世界 (C02 lifecycle)")
	_check(main.save_world_position() and not FileAccess.get_file_as_string(TEST_SAVE).to_lower().contains("combat") and int(JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))["version"]) == 12, "Saving during Combat: version 9, nothing about Combat")
	exit.pressed.emit()
	# C02 replaced the C01 bridge: VICTORY removes the participating group 3
	# (verify_c02_world_lifecycle covers the lifecycle); groups 1 and 2 stay.
	var monsters := []
	for name in ["Actors/PrototypeMonster", "Actors/PrototypeMonster2"]:
		monsters.append(main.get_node(name) as WorldMonster)
	_check(not main.has_node("Actors/PrototypeMonster3") and monsters.all(func(m: WorldMonster) -> bool: return is_instance_valid(m) and m.is_threat_active() and not m.is_held()), "VICTORY: participating group 3 left the world, groups 1 and 2 untouched")
	await _settle()
	_check(main.get_combat() == null and not view.visible and session.get_phase() == EncounterSession.Phase.NONE, "Exit closes the battle and ends the encounter")
	_check(not player.movement_locked and not handoff.has_pending_encounter() and session.is_protection_active(), "Player free, E02 recovery protection on")
	_check(main.wallet.get_balance() == money, "No reward")
	_check((main.get_node("TouchControls/Joystick") as Node).is_processing_input(), "World joystick back on")
	await _destroy(main)
	# DEFEAT also leaves through the same Prototype exit.
	main = await _new_main("")
	session = main.get_node("EncounterSession") as EncounterSession
	view = main.get_node("CombatView") as CombatView
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	session.challenge()
	main.time_source.advance_ms(5000)
	await _process_frames(2)
	battle = main.get_combat()
	await _frames(200)
	# C03: the game's party is Hero + 2 Mercenaries; DEFEAT needs a Full Party Wipe.
	for friend in battle.get_friends():
		battle.resolve_damage(battle.get_enemies()[0], friend, 1000)
	await _process_frames(2)
	_check(battle.get_phase() == CombatBattle.Phase.DEFEAT and (view.get_node("StatusLabel") as Label).text == "戰敗" and (view.get_node("ExitButton") as Button).visible, "DEFEAT: 戰敗 and the Prototype exit")
	(view.get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(main.get_combat() == null and session.get_phase() == EncounterSession.Phase.NONE and not (main.get_node("Actors/Player") as Player).movement_locked, "DEFEAT exit returns to the world")
	await _destroy(main)
	# The exit is refused while the battle is still running; leaving WORLD closes it.
	main = await _new_main("")
	session = main.get_node("EncounterSession") as EncounterSession
	view = main.get_node("CombatView") as CombatView
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	session.challenge()
	main.time_source.advance_ms(5000)
	await _process_frames(2)
	view.exit_requested.emit()
	await _process_frames(1)
	_check(main.get_combat() != null and session.get_phase() == EncounterSession.Phase.LOCKED, "No exit before a result")
	session.cancel_for_world_exit()
	await _process_frames(1)
	_check(main.get_combat() == null and not view.visible, "Encounter cancelled -> the battle closes")
	await _destroy(main)
	# Test seam off: LOCKED stays bare (E01–E03 behaviour).
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.combat_enabled = false
	main.save_path = ""
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	await _settle()
	session = main.get_node("EncounterSession") as EncounterSession
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	session.challenge()
	main.time_source.advance_ms(5000)
	await _process_frames(2)
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and main.get_combat() == null, "With the test seam off, LOCKED opens no battle")
	await _destroy(main)
	_sections_done.append("locked_to_combat")


func _verify_group_counts_in_game() -> void:
	for spot in [[WITH_GROUP_1, 2, 15], [MIDDLE, 3, 20]]:
		var main := await _new_main("")
		var session := main.get_node("EncounterSession") as EncounterSession
		(main.get_node("Actors/Player") as Player).global_position = spot[0]
		await _settle()
		session.challenge()
		var frames := 0
		while session.get_context().get_group_count() < spot[1] and frames < 120:
			await physics_frame
			frames += 1
		main.time_source.advance_ms(5000)
		await _process_frames(2)
		var battle: CombatBattle = main.get_combat()
		_check(battle != null and battle.group_monster_ids.size() == spot[1] and battle.get_enemies().size() == spot[2], "%d groups in game -> %d enemies" % [spot[1], spot[2]])
		await _destroy(main)
	_sections_done.append("group_counts")


# --- Helpers --------------------------------------------------------------------------------------

## A new battle whose signals feed _phases / _hits / _deaths.
func _battle(enemies: int) -> CombatBattle:
	_phases.clear()
	_hits.clear()
	_deaths.clear()
	# C03: the C01 rule tests keep their single-friendly setting through the
	# HERO_ONLY test fixture (the game always builds Hero + Merc A + Merc B).
	var battle := CombatBattle.create(enemies, CombatBattle.PartyFixture.HERO_ONLY)
	battle.phase_changed.connect(func(phase: int) -> void: _phases.append(phase))
	battle.damage_dealt.connect(func(attacker: CombatUnit, target: CombatUnit, amount: int) -> void: _hits.append([attacker, target, amount, battle.get_elapsed_ms()]))
	battle.unit_died.connect(func(unit: CombatUnit) -> void: _deaths.append(unit))
	return battle


## Test setup: puts a unit on a cell (standing, not stepping).
func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


## Hits by `attacker` as [attacker, target, amount, time]; the time is the
## start of the tick in which the hit landed.
func _hits_by(attacker: CombatUnit) -> Array:
	return _hits.filter(func(hit: Array) -> bool: return hit[0] == attacker)


func _cells(units: Array) -> Array:
	return units.map(func(unit: CombatUnit) -> Array: return [unit.cell, unit.next_cell])


func _nearest_enemy(battle: CombatBattle) -> CombatUnit:
	var hero := battle.get_hero()
	var best: CombatUnit
	for enemy in battle.get_enemies():
		if enemy.alive and (best == null or CombatUnit.grid_distance(hero.cell, enemy.cell) < CombatUnit.grid_distance(hero.cell, best.cell)):
			best = enemy
	return best


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


func _frames(count: int) -> void:
	for frame in range(count):
		await physics_frame


func _process_frames(count: int) -> void:
	for frame in range(count):
		await process_frame


func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#") and not line.strip_edges().begins_with("##"):
			lines.append(line)
	return "\n".join(lines)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
