extends SceneTree

## Combat C05: Reward & Progression Bridge. 5 x 61 battlefield (column 0 the
## Retreat Zone, preparation in columns 1-3, enemies from the right edge:
## 10 / 15 / 20 in columns 59-60 / 58-60 / 57-60). Every enemy actually killed
## adds 10 EXP to the battle pool; VICTORY and RETREAT share it equally
## (integer division, remainder discarded) among the friendly units alive at
## settlement; DEFEAT gives nothing. Lv1 -> Lv2 at 100 EXP, overflow kept.
## Stage 7 S03 replaced the C05 Lv2 ceiling with the 100 + 50 x (L - 1) curve
## up to Lv100 (see verify_s03_level_growth.gd); the checks below that encoded
## the ceiling now follow the S03 curve. Level / EXP of the three fixed slots
## persist (Save v9).

const TEST_SAVE := "user://c05_progression_test_save.json"
const BAD_SAVE := "user://c05_missing_dir/save.json"
const T0 := 1800000000000
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const SLOTS := ["hero", "merc_a", "merc_b"]

var _checks := 0
var _failures := 0
var _sections_done := []
var _phases := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	_verify_battlefield()
	_verify_exp_earning()
	_verify_distribution()
	_verify_battle_settlement()
	_verify_levels()
	_verify_persistence()
	await _verify_in_game()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 8, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("C05 reward progression verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(CombatConfig.ROWS == 5 and CombatConfig.COLUMNS == 61, "Battlefield 5 x 61")
	_check(CombatConfig.PREPARATION_FIRST_COLUMN == 1 and CombatConfig.PREPARATION_COLUMNS == 3 and CombatConfig.PREPARATION_MS == 3000, "Preparation: columns 1-3, 3000 ms")
	_check(CombatConfig.EXP_PER_KILL == 10, "1 enemy killed = 10 EXP")
	# S03: was MAX_LEVEL 2 / LEVEL_THRESHOLDS {1: 100} (the C05 Lv2 ceiling).
	_check(ProgressionState.SLOTS == SLOTS and ProgressionState.START_LEVEL == 1 and ProgressionState.MAX_LEVEL == 100 and ProgressionState.required_exp(1) == 100 and ProgressionState.required_exp(2) == 150, "Three fixed slots, Lv1 -> Lv2 at 100 (S03 curve, Lv100 cap)")
	_check(SaveStore.VERSION == 10 and SaveStore.V9_KEYS == SaveStore.V8_KEYS + ["progression"], "Save v9 = v8 + progression")
	_check(CombatConfig.HERO["max_hp"] == 300 and CombatConfig.HERO["attack_damage"] == 20 and CombatConfig.ENEMY["move_speed"] == 2.0 and CombatConfig.MERC_B["attack_range"] == 3, "Combat stats unchanged")
	var progression_code := _code_only("res://scripts/progression_state.gd").to_lower()
	for word in ["hp", "attack", "damage", "speed", "range", "strength", "capacity", "skill", "loot", "money", "wallet", "item", "rand", "talent", "point"]:
		_check(not progression_code.contains(word), "progression_state.gd has no %s" % word)
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_config.gd"]:
		var code := _code_only(path).to_lower()
		_check(not code.contains("progression") and not code.contains("level"), "%s never reads Level / progression (no stat growth)" % path.get_file())
	for path in ["res://scripts/combat_battle.gd", "res://scripts/battle_result.gd", "res://scripts/progression_state.gd", "res://scripts/main.gd", "res://scripts/combat_view.gd"]:
		var code := _code_only(path).to_lower()
		for word in ["loot", "drop", "chest", "rarity", "last_hit", "contribution", "bonus", "hospital", "revive", "penalty"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	_sections_done.append("static")


# --- Battlefield --------------------------------------------------------------------------------

func _verify_battlefield() -> void:
	_check(CombatBattle.is_in_grid(Vector2i(60, 4)) and CombatBattle.is_in_grid(Vector2i(0, 0)) and not CombatBattle.is_in_grid(Vector2i(61, 0)) and not CombatBattle.is_in_grid(Vector2i(-1, 0)), "Columns 0-60 valid, 61 not")
	var battle := _battle(10)
	var hero := battle.get_hero()
	var legal := []
	for column in range(CombatConfig.COLUMNS):
		for row in range(CombatConfig.ROWS):
			if battle.is_cell_allowed(hero, Vector2i(column, row)):
				legal.append(Vector2i(column, row))
	_check(legal.size() == 15 and legal.all(func(c: Vector2i) -> bool: return c.x >= 1 and c.x <= 3), "PREPARATION: exactly the 15 cells of columns 1-3")
	_check(not battle.command_move(Vector2i(0, 2)) and not battle.command_move(Vector2i(4, 2)) and battle.command_move(Vector2i(3, 2)) and battle.command_move(Vector2i(1, 0)), "PREPARATION: column 0 and column 4 refused, columns 1 and 3 accepted")
	_check(battle.get_friends().all(func(u: CombatUnit) -> bool: return battle.is_cell_allowed(u, u.cell)), "Friendly spawns are legal preparation cells")
	battle.advance(3000)
	_check(battle.is_cell_allowed(hero, Vector2i(0, 2)) and battle.is_cell_allowed(hero, Vector2i(60, 2)), "FIGHTING: the whole 5 x 61 grid")
	for formation in [[10, 59], [15, 58], [20, 57]]:
		var count: int = formation[0]
		var first: int = formation[1]
		var b := CombatBattle.create(count)
		var cells := {}
		var expected := {}
		for column in range(first, 61):
			for row in range(5):
				expected[Vector2i(column, row)] = true
		for enemy in b.get_enemies():
			cells[enemy.cell] = true
		_check(b.get_enemies().size() == count and cells.size() == count and cells == expected, "%d enemies fill columns %d-60, every row" % [count, first])
		var shared := false
		var taken := {}
		for unit in b.get_friends() + b.get_enemies():
			shared = shared or taken.has(unit.cell)
			taken[unit.cell] = true
		_check(not shared, "%d enemies + party: no shared cell" % count)
	var order: Array[Vector2i] = []
	for column in [59, 60]:
		for row in range(5):
			order.append(Vector2i(column, row))
	_check(CombatBattle.enemy_spawn_cells(10) == order, "Formation order: column by column from the left, top row first (enemy_01 at (59, 0))")
	_verify_free_cell_search()
	_sections_done.append("battlefield")


# --- EXP earning ----------------------------------------------------------------------------------

func _verify_exp_earning() -> void:
	var battle := _battle(10)
	var hero := battle.get_hero()
	var enemies := battle.get_enemies()
	battle.advance(3000)
	_check(battle.get_exp_pool() == 0, "The pool starts at 0")
	battle.resolve_damage(hero, enemies[0], 15)
	_check(battle.get_exp_pool() == 0, "Damage without a kill earns nothing")
	battle.resolve_damage(hero, enemies[0], 1000)
	_check(battle.get_exp_pool() == 10, "One kill = 10 EXP")
	_check(battle.resolve_damage(hero, enemies[0], 1000) == 0 and battle.get_exp_pool() == 10, "A dead enemy is never credited twice")
	battle.resolve_damage(battle.get_friends()[2], enemies[1], 1000)
	_check(battle.get_exp_pool() == 20, "Any friendly unit's kill feeds the same pool (no last-hit ownership)")
	battle.resolve_damage(enemies[2], battle.get_friends()[1], 1000)
	_check(battle.get_exp_pool() == 20, "A friendly death earns nothing")
	_sections_done.append("exp_earning")


# --- Distribution (ProgressionState) -----------------------------------------------------------------

func _verify_distribution() -> void:
	var cases := [
		["all three alive, 150", BattleResult.Outcome.VICTORY, 150, ["hero", "merc_a", "merc_b"], {"hero": 50, "merc_a": 50, "merc_b": 50}],
		["all three alive, 100 (1 discarded)", BattleResult.Outcome.VICTORY, 100, ["hero", "merc_a", "merc_b"], {"hero": 33, "merc_a": 33, "merc_b": 33}],
		["70 / 3 (1 discarded)", BattleResult.Outcome.VICTORY, 70, ["hero", "merc_a", "merc_b"], {"hero": 23, "merc_a": 23, "merc_b": 23}],
		["one dead", BattleResult.Outcome.VICTORY, 100, ["hero", "merc_b"], {"hero": 50, "merc_b": 50}],
		["two dead", BattleResult.Outcome.VICTORY, 100, ["merc_b"], {"merc_b": 100}],
		["retreat survivors", BattleResult.Outcome.RETREAT, 40, ["hero", "merc_a"], {"hero": 20, "merc_a": 20}],
		["defeat", BattleResult.Outcome.DEFEAT, 50, [], {}],
		["defeat with a stray survivor id", BattleResult.Outcome.DEFEAT, 50, ["hero"], {}],
		["nothing killed", BattleResult.Outcome.RETREAT, 0, ["hero", "merc_a", "merc_b"], {}],
		["1 EXP over 3", BattleResult.Outcome.VICTORY, 1, ["hero", "merc_a", "merc_b"], {}],
	]
	for case in cases:
		var progression := ProgressionState.new()
		var result := _result(case[1], case[2], case[3])
		var shares := progression.apply(result)
		var got := {}
		for slot in shares:
			got[slot] = shares[slot]["exp"]
		var exp_now := {}
		for slot in SLOTS:
			exp_now[slot] = progression.get_exp(slot) + (100 if progression.get_level(slot) == 2 else 0)
		var expected_now := {"hero": 0, "merc_a": 0, "merc_b": 0}
		for slot in case[4]:
			expected_now[slot] = case[4][slot]
		_check(got == case[4] and exp_now == expected_now, "%s: %s (got %s)" % [case[0], str(case[4]), str(got)])
	_sections_done.append("distribution")


# --- Settlement inside real battles -------------------------------------------------------------------

func _verify_battle_settlement() -> void:
	# VICTORY: Merc A died; the Hero and Merc B share 100.
	var won := _battle(10)
	var wf := won.get_friends()
	won.advance(3000)
	won.resolve_damage(won.get_enemies()[0], wf[1], 1000)
	for enemy in won.get_enemies():
		won.resolve_damage(wf[0], enemy, 1000)
	var result := won.get_result()
	_check(result.is_victory() and result.exp_pool == 100 and result.survivor_ids == ["hero", "merc_b"], "VICTORY: pool 100, survivors Hero and Merc B")
	var progression := ProgressionState.new()
	progression.apply(result)
	_check(progression.get_exp("hero") == 50 and progression.get_exp("merc_b") == 50 and progression.get_exp("merc_a") == 0, "Hero 50, Merc B 50, dead Merc A 0")
	# RETREAT: 4 kills; Merc B dead; the Hero escapes while Merc A is far away.
	var fled := _battle(10)
	var ff := fled.get_friends()
	fled.advance(3000)
	for index in range(4):
		fled.resolve_damage(ff[0], fled.get_enemies()[index], 1000)
	fled.resolve_damage(fled.get_enemies()[5], ff[2], 1000)
	_place(ff[1], Vector2i(30, 0))
	fled.start_retreat()
	fled.advance(250)
	result = fled.get_result()
	_check(fled.get_phase() == CombatBattle.Phase.RETREAT and ff[0].cell.x == 0 and ff[1].cell.x > 20, "RETREAT by the Hero while Merc A is still far from the zone")
	_check(result.is_retreat() and result.exp_pool == 40 and result.survivor_ids == ["hero", "merc_a"], "RETREAT: pool 40 (4 kills), survivors Hero and Merc A (alive, not in the zone)")
	progression = ProgressionState.new()
	progression.apply(result)
	_check(progression.get_exp("hero") == 20 and progression.get_exp("merc_a") == 20 and progression.get_exp("merc_b") == 0, "Hero 20, Merc A 20, dead Merc B 0")
	# DEFEAT: 5 kills, then a Full Party Wipe.
	var lost := _battle(10)
	var lf := lost.get_friends()
	lost.advance(3000)
	for index in range(5):
		lost.resolve_damage(lf[0], lost.get_enemies()[index], 1000)
	for friend in lf:
		lost.resolve_damage(lost.get_enemies()[9], friend, 1000)
	result = lost.get_result()
	progression = ProgressionState.new()
	var shares := progression.apply(result)
	_check(lost.get_phase() == CombatBattle.Phase.DEFEAT and result.exp_pool == 50 and result.survivor_ids.is_empty() and shares.is_empty() and SLOTS.all(func(s: String) -> bool: return progression.get_exp(s) == 0 and progression.get_level(s) == 1), "DEFEAT: 5 kills earned 50, but nothing is awarded")
	# The pool and survivors are frozen at settlement.
	var frozen := _battle(10)
	frozen.advance(3000)
	for enemy in frozen.get_enemies():
		frozen.resolve_damage(frozen.get_hero(), enemy, 1000)
	var final := frozen.get_result()
	frozen.resolve_damage(frozen.get_enemies()[0], frozen.get_hero(), 1000)
	_check(final.exp_pool == 100 and final.survivor_ids.size() == 3 and frozen.get_result() == final, "Nothing after the result changes the pool or the survivors")
	_sections_done.append("battle_settlement")


# --- Levels -----------------------------------------------------------------------------------------

func _verify_levels() -> void:
	var progression := ProgressionState.new()
	var shares := progression.apply(_result(BattleResult.Outcome.VICTORY, 100, ["hero"]))
	_check(progression.get_level("hero") == 2 and progression.get_exp("hero") == 0 and shares["hero"]["leveled"] and shares["hero"]["level"] == 2, "Lv1 + 100 -> Lv2")
	var p2 := ProgressionState.from_dict({"hero": {"level": 1, "exp": 80}, "merc_a": {"level": 1, "exp": 99}, "merc_b": {"level": 1, "exp": 0}})
	p2.apply(_result(BattleResult.Outcome.VICTORY, 50, ["hero"]))
	_check(p2.get_level("hero") == 2 and p2.get_exp("hero") == 30, "Lv1 80 + 50 -> Lv2 with 30 overflow")
	# S03: C05 kept 530 EXP at the Lv2 ceiling; the S03 curve passes Lv3 (150)
	# and Lv4 (200) and keeps 180.
	p2.apply(_result(BattleResult.Outcome.VICTORY, 500, ["hero"]))
	_check(p2.get_level("hero") == 4 and p2.get_exp("hero") == 180, "Lv2 30 + 500 -> Lv4 180 (S03 curve; was 530 at the C05 Lv2 ceiling)")
	# S03: C05 stopped at Lv2 with 999; now 1099 passes Lv1-Lv5 (100+150+200+250+300) and keeps 99.
	p2.apply(_result(BattleResult.Outcome.VICTORY, 1000, ["merc_a"]))
	_check(p2.get_level("merc_a") == 6 and p2.get_exp("merc_a") == 99, "Lv1 99 + 1000 -> Lv6 99 (S03 multi-Level; was Lv2 999)")
	var preview_only := ProgressionState.new()
	var preview := preview_only.preview(_result(BattleResult.Outcome.VICTORY, 100, ["merc_b"]))
	_check(preview["merc_b"]["leveled"] and preview_only.get_level("merc_b") == 1 and preview_only.get_exp("merc_b") == 0, "preview() changes nothing")
	# A Level changes no combat stat: a battle after Level Up is identical.
	var before := CombatBattle.create(10)
	var levelled := ProgressionState.new()
	levelled.apply(_result(BattleResult.Outcome.VICTORY, 300, ["hero", "merc_a", "merc_b"]))
	var after := CombatBattle.create(10)
	var same := true
	for index in range(3):
		var a := before.get_friends()[index]
		var b := after.get_friends()[index]
		same = same and [a.max_hp, a.attack_damage, a.attack_range, a.attack_interval_ms, a.move_speed] == [b.max_hp, b.attack_damage, b.attack_range, b.attack_interval_ms, b.move_speed]
	_check(same and SLOTS.all(func(s: String) -> bool: return levelled.get_level(s) == 2), "Every slot Lv2, combat stats identical")
	_sections_done.append("levels")


# --- Persistence (Save v9) ----------------------------------------------------------------------------

func _verify_persistence() -> void:
	var progression := ProgressionState.from_dict({"hero": {"level": 2, "exp": 30}, "merc_a": {"level": 1, "exp": 40}, "merc_b": {"level": 2, "exp": 0}})
	_check(SaveStore.save(TEST_SAVE, Wallet.new(), CharacterInventory.new(), MarketState.create_default(), PlayerLocation.new(), null, null, null, progression), "v9 save writes")
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(raw["version"]) == 10 and raw.keys().size() == 10 and raw["progression"] == {"hero": {"level": 2.0, "exp": 30.0}, "merc_a": {"level": 1.0, "exp": 40.0}, "merc_b": {"level": 2.0, "exp": 0.0}} or raw["progression"] == {"hero": {"level": 2, "exp": 30}, "merc_a": {"level": 1, "exp": 40}, "merc_b": {"level": 2, "exp": 0}}, "v10 progression holds exactly the three slots' {level, exp}")
	var loaded := SaveStore.load_session(TEST_SAVE)
	_check(not loaded.is_empty() and loaded["progression"].to_dict() == progression.to_dict(), "Level / EXP survive save -> load")
	# A v8 save (no progression) loads with the defaults; the file is untouched.
	var v8: Dictionary = raw.duplicate(true)
	v8.erase("progression")
	v8.erase("allocation")  # S05: nor the v10 allocation
	v8["version"] = 8
	_write_json(v8)
	var text := FileAccess.get_file_as_string(TEST_SAVE)
	loaded = SaveStore.load_session(TEST_SAVE)
	_check(not loaded.is_empty() and SLOTS.all(func(s: String) -> bool: return loaded["progression"].get_level(s) == 1 and loaded["progression"].get_exp(s) == 0), "v8 save: every slot Lv1, 0 EXP in memory")
	_check(FileAccess.get_file_as_string(TEST_SAVE) == text, "Loading a v8 save does not rewrite it")
	# Malformed progression rejects the whole save (existing convention).
	var good: Dictionary = raw.duplicate(true)
	var broken := {
		"v9 without progression": _without(good, "progression"),
		"v8 carrying progression": _with(good, {"version": 8}),
		"progression not dict": _with(good, {"progression": [1, 2]}),
		"missing slot": _with(good, {"progression": {"hero": {"level": 1, "exp": 0}, "merc_a": {"level": 1, "exp": 0}}}),
		"extra slot": _with(good, {"progression": {"hero": {"level": 1, "exp": 0}, "merc_a": {"level": 1, "exp": 0}, "merc_b": {"level": 1, "exp": 0}, "merc_c": {"level": 1, "exp": 0}}}),
		"extra field": _with(good, {"progression": {"hero": {"level": 1, "exp": 0, "hp": 999}, "merc_a": {"level": 1, "exp": 0}, "merc_b": {"level": 1, "exp": 0}}}),
		"missing exp": _with(good, {"progression": {"hero": {"level": 1}, "merc_a": {"level": 1, "exp": 0}, "merc_b": {"level": 1, "exp": 0}}}),
		"level 0": _with_progression_slot({"level": 0, "exp": 0}),
		# S03: Lv3 is valid now (was rejected above the C05 Lv2 ceiling).
		"level 101": _with_progression_slot({"level": 101, "exp": 0}),
		"negative exp": _with_progression_slot({"level": 1, "exp": -5}),
		"fractional exp": _with_progression_slot({"level": 1, "exp": 2.5}),
		"string level": _with_progression_slot({"level": "1", "exp": 0}),
		"huge exp": _with_progression_slot({"level": 2, "exp": 1e17}),
	}
	for label in broken:
		_write_json(broken[label])
		var before := FileAccess.get_file_as_string(TEST_SAVE)
		_check(SaveStore.load_session(TEST_SAVE).is_empty() and FileAccess.get_file_as_string(TEST_SAVE) == before, "Rejected as a whole, file untouched: %s" % label)
	_check(ProgressionState.from_dict({"hero": {"level": 2, "exp": 999999}, "merc_a": {"level": 1, "exp": 99}, "merc_b": {"level": 1, "exp": 0.0}}) != null, "Valid edge values load (Lv2 high EXP, Lv1 99, whole float 0.0)")
	# S03: EXP at the requirement (C05 rejected Lv1 at 100) is carried through the curve.
	var carried := ProgressionState.from_dict({"hero": {"level": 1, "exp": 100}, "merc_a": {"level": 1, "exp": 0}, "merc_b": {"level": 1, "exp": 0}})
	_check(carried != null and carried.get_level("hero") == 2 and carried.get_exp("hero") == 0, "Lv1 at the requirement loads as Lv2 0 (S03; C05 rejected it)")
	_delete(TEST_SAVE)
	_sections_done.append("persistence")


# --- In game: result screen, commit, save, reload ------------------------------------------------------

func _verify_in_game() -> void:
	var main := await _new_main(TEST_SAVE)
	var view := main.get_node("CombatView") as CombatView
	# Battle 1: Merc A dies, 10 kills -> Hero and Merc B get 50 each.
	var battle := await _locked_battle(main)
	await process_frame
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING and not (view.get_node("RewardLabel") as Label).visible, "FIGHTING: no reward text")
	var f := battle.get_friends()
	battle.resolve_damage(battle.get_enemies()[0], f[1], 1000)
	for enemy in battle.get_enemies():
		battle.resolve_damage(f[0], enemy, 1000)
	await process_frame
	var reward := (view.get_node("RewardLabel") as Label)
	_check(reward.visible and reward.text == "主角 經驗 +50　傭兵B 經驗 +50", "Result screen: 主角 經驗 +50　傭兵B 經驗 +50 (%s)" % reward.text)
	_check(main.progression.get_exp("hero") == 0, "Nothing applied before the commit")
	_delete(TEST_SAVE)
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(main.progression.get_exp("hero") == 50 and main.progression.get_exp("merc_b") == 50 and main.progression.get_exp("merc_a") == 0 and main.get_last_award().size() == 2, "Committed: Hero 50, Merc B 50, Merc A 0")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(saved["version"]) == 10 and int(saved["progression"]["hero"]["exp"]) == 50 and int(saved["progression"]["merc_a"]["exp"]) == 0, "Saved once with the commit: v9 progression")
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(main.progression.get_exp("hero") == 50, "A repeated commit adds nothing")
	# Battle 2 (relaunched, the group was defeated this session): the Hero
	# alone kills 10 -> +100 -> Lv2 with 50 overflow.
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(main.progression.get_exp("hero") == 50 and main.progression.get_exp("merc_b") == 50, "Relaunch restores the first award")
	view = main.get_node("CombatView") as CombatView
	reward = view.get_node("RewardLabel") as Label
	battle = await _locked_battle(main)
	f = battle.get_friends()
	battle.resolve_damage(battle.get_enemies()[0], f[1], 1000)
	battle.resolve_damage(battle.get_enemies()[0], f[2], 1000)
	for enemy in battle.get_enemies():
		battle.resolve_damage(f[0], enemy, 1000)
	await process_frame
	# S04: the Level Up line also states the Stat Points it brought (was "主角 升至 2 級").
	_check(reward.text == "主角 經驗 +100\n主角 升至 2 級（屬性點 +3）", "Result screen shows the Level Up and its Stat Points (%s)" % reward.text)
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(main.progression.get_level("hero") == 2 and main.progression.get_exp("hero") == 50, "Hero Lv2 with 50 overflow")
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(main.progression.get_level("hero") == 2 and main.progression.get_exp("hero") == 50 and main.progression.get_exp("merc_b") == 50 and main.progression.get_level("merc_a") == 1, "Relaunch restores every slot's Level / EXP")
	view = main.get_node("CombatView") as CombatView
	reward = view.get_node("RewardLabel") as Label
	# DEFEAT after kills: nothing awarded, said so.
	battle = await _locked_battle(main)
	for index in range(3):
		battle.resolve_damage(battle.get_friends()[0], battle.get_enemies()[index], 1000)
	for friend in battle.get_friends():
		battle.resolve_damage(battle.get_enemies()[9], friend, 1000)
	await process_frame
	_check(reward.text == "本場沒有獲得經驗", "DEFEAT: 本場沒有獲得經驗")
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(main.progression.get_exp("hero") == 50 and main.progression.get_level("hero") == 2 and main.get_last_award().is_empty(), "DEFEAT changed no progression")
	# RETREAT after 4 kills: everyone alive shares 40 (13 each, 1 discarded).
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	view = main.get_node("CombatView") as CombatView
	reward = view.get_node("RewardLabel") as Label
	battle = await _locked_battle(main)
	for index in range(4):
		battle.resolve_damage(battle.get_friends()[0], battle.get_enemies()[index], 1000)
	battle.start_retreat()
	battle.advance(500)
	await process_frame
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT and reward.text == "主角 經驗 +13　傭兵A 經驗 +13　傭兵B 經驗 +13", "RETREAT: 40 / 3 = 13 each (%s)" % reward.text)
	# Save failure after the commit: no rollback of the EXP.
	main.save_path = BAD_SAVE
	(view.get_node("ExitButton") as Button).pressed.emit()
	_check(main.progression.get_exp("hero") == 63 and main.progression.get_exp("merc_a") == 13 and main.progression.get_exp("merc_b") == 63 and not FileAccess.file_exists(BAD_SAVE), "Save failed after the commit: the EXP stays applied (no rollback)")
	await _destroy(main)
	_sections_done.append("in_game")


## The C05 claimed-cell search returns exactly what the C03 per-cell
## _is_free_for scan returned, for every alive unit, at several moments of a
## crowded 20-enemy battle.
func _verify_free_cell_search() -> void:
	var battle := _battle(20)
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_hero(), battle.get_enemies()[3], 1000)
	var compared := 0
	var same := true
	for moment in range(6):
		battle.advance(5000)
		if moment == 2:
			battle.resolve_damage(battle.get_enemies()[0], battle.get_friends()[2], 1000)
		for unit: CombatUnit in battle.get_friends() + battle.get_enemies():
			if not unit.alive:
				continue
			var searches := [[unit.cell, 0, 0, 60], [Vector2i(30, 2), 1, 20, 40], [Vector2i(0, unit.cell.y), 0, 0, 0], [Vector2i(58, 4), 2, 0, 60]]
			for search in searches:
				compared += 1
				var expected: Variant = _reference_free_cell(battle, unit, search[0], search[1], search[2], search[3])
				var actual: Variant = battle._best_free_cell_in(unit, search[0], search[1], search[2], search[3])
				if actual != expected:
					same = false
	_check(same and compared > 300, "Claimed-cell search == per-cell _is_free_for search (%d searches)" % compared)


## The pre-C05 search: every cell checked with _is_free_for.
func _reference_free_cell(battle: CombatBattle, unit: CombatUnit, center: Vector2i, reach: int, first_column: int, last_column: int) -> Variant:
	var best: Variant = null
	var best_score := Vector3i(1 << 20, 1 << 20, 1 << 20)
	for column in range(first_column, last_column + 1):
		for row in range(CombatConfig.ROWS):
			var cell := Vector2i(column, row)
			if not battle._is_free_for(unit, cell):
				continue
			var score := Vector3i(maxi(CombatUnit.grid_distance(cell, center) - reach, 0), CombatUnit.grid_distance(unit.cell, cell), row * CombatConfig.COLUMNS + column)
			if score < best_score:
				best_score = score
				best = cell
	return best


# --- Helpers --------------------------------------------------------------------------------------

func _battle(enemies: int) -> CombatBattle:
	_phases.clear()
	var battle := CombatBattle.create(enemies)
	battle.phase_changed.connect(func(phase: int) -> void: _phases.append(phase))
	return battle


func _result(outcome: BattleResult.Outcome, pool: int, survivors: Array) -> BattleResult:
	var result := BattleResult.create("encounter_test", outcome, [] as Array[String])
	result.exp_pool = pool
	for slot in survivors:
		result.survivor_ids.append(slot)
	return result


func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


func _locked_battle(main: Node) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	for frame in range(4):
		await physics_frame
	await process_frame
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	var battle: CombatBattle = main.get_combat()
	battle.advance(CombatConfig.PREPARATION_MS)
	return battle


func _new_main(path: String) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	for frame in range(4):
		await physics_frame
	await process_frame
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _with_progression_slot(entry: Dictionary) -> Dictionary:
	var raw: Dictionary = JSON.parse_string(JSON.stringify(SaveStore.serialize(Wallet.new(), CharacterInventory.new(), MarketState.create_default(), PlayerLocation.new())))
	raw["progression"]["hero"] = entry
	return raw


func _with(data: Dictionary, changes: Dictionary) -> Dictionary:
	var copy := data.duplicate(true)
	for key in changes:
		copy[key] = changes[key]
	return copy


func _without(data: Dictionary, key: String) -> Dictionary:
	var copy := data.duplicate(true)
	copy.erase(key)
	return copy


func _write_json(data: Dictionary) -> void:
	var file := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()


func _delete(path: String) -> void:
	for p in [path, path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


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
