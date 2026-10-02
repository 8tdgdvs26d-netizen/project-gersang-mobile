extends SceneTree

## Combat C08: Mobile Combat Controls & Integration. One or several friendly
## units are selected (the Active Caster is get_selected()); a tap on a unit
## already in a multi-selection only makes it the Active Caster. Move / Target
## go to every selected unit (existing occupancy, own range, C06 priority).
## Two temporary battle groups and 全體 select alive members; 全體進攻 gives
## each alive friendly unit its nearest alive enemy. Aggregate HP: two
## independent ratios over fixed battle-start totals. The HUD: 全體撤退 /
## clock / 全體進攻, HP bars, groups, portraits (ⓘ info), skill bar (full for
## one unit, compact for several), a camera that follows nobody (battlefield
## drag, bottom navigator; taps resolve on release, drags issue no command).
## Nothing of it is saved (Save v9).

const T0 := 1800000000000
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const TEST_SAVE := "user://c08_mobile_combat_test_save.json"

var _checks := 0
var _failures := 0
var _sections_done := []
var _hits := []


func _initialize() -> void:
	await process_frame
	_verify_static()
	_verify_selection()
	_verify_multi_move()
	_verify_multi_target()
	_verify_attack_all()
	_verify_skill_bar()
	_verify_aggregate_hp()
	_verify_camera()
	_verify_lifecycle_rules()
	await _verify_in_game()
	_check(_sections_done.size() == 10, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("C08 mobile combat verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(SaveStore.VERSION == 9 and SaveStore.V9_KEYS.size() == 9, "Save stays v9")
	for path in ["res://scripts/save_store.gd", "res://scripts/progression_state.gd", "res://scripts/main.gd"]:
		var code := _code_only(path).to_lower()
		_check(not code.contains("group(") and not code.contains("selection") and not code.contains("camera"), "%s knows nothing about groups / selection / camera" % path.get_file())
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_view.gd", "res://scripts/combat_camera.gd"]:
		var code := _code_only(path).to_lower()
		for word in ["box_select", "pinch", "zoom", "minimap", "formation", "recruit", "auto_battle", "save_store", "randi", "randf"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	_check(CombatView.MAX_PORTRAITS == 4 and CombatView.DRAG_THRESHOLD == 12.0, "Room for 4 portraits (party of 3 now); 12 px drag threshold")
	_check(CombatConfig.HERO["move_speed"] == 4.0 and CombatConfig.ENEMY["attack_damage"] == 4 and CombatConfig.SKILL_MP_COST == 25 and CombatConfig.GESTURE_MP_COST == 50, "Combat values unchanged")
	_sections_done.append("static")


# --- Selection & groups ------------------------------------------------------------------------

func _verify_selection() -> void:
	var battle := CombatBattle.create(10)
	var friends := battle.get_friends()
	var hero := friends[0]
	var merc_a := friends[1]
	var merc_b := friends[2]
	_check(battle.get_selection() == [hero] and battle.get_selected() == hero, "Start: the Hero alone, Active Caster")
	_check(battle.select_unit(merc_a) and battle.get_selection() == [merc_a] and battle.get_selected() == merc_a, "Single selection")
	_check(battle.get_group(0).is_empty() and battle.get_group(1).is_empty() and not battle.select_group(0) and battle.get_selection() == [merc_a], "Empty groups select nothing (selection unchanged)")
	battle.toggle_group_member(0, hero)
	battle.toggle_group_member(0, merc_a)
	battle.toggle_group_member(1, merc_a)
	battle.toggle_group_member(1, merc_b)
	_check(battle.get_group(0) == [hero, merc_a] and battle.get_group(1) == [merc_a, merc_b], "Group ① = Hero + A, Group ② = A + B (A in both)")
	_check(battle.select_group(0) and battle.get_selection() == [hero, merc_a] and battle.get_selected() == merc_a, "Group ①: Hero + A selected; the Active Caster (A) stays")
	_check(battle.select_group(1) and battle.get_selection() == [merc_a, merc_b] and battle.get_selected() == merc_a, "Group ②: A + B (overlapping member A)")
	_check(not battle.toggle_group_member(1, merc_b) and battle.get_group(1) == [merc_a] and battle.toggle_group_member(1, merc_b), "Toggle removes / re-adds a member")
	_check(battle.select_all() and battle.get_selection() == [hero, merc_a, merc_b], "全體: every alive friendly unit")
	# Active Caster inside a multi-selection.
	battle.select_group(0)
	_check(battle.select_or_activate(hero) and battle.get_selection() == [hero, merc_a] and battle.get_selected() == hero, "Tap a member of the multi-selection: it becomes the Active Caster, the group stays")
	_check(battle.tap(hero.cell) and battle.get_selection() == [hero, merc_a], "Battlefield tap on a member: same rule")
	_check(battle.select_or_activate(merc_b) and battle.get_selection() == [merc_b] and battle.get_selected() == merc_b, "Tap a unit outside the selection: single selection")
	_check(battle.select_unit(merc_a) and battle.select_or_activate(merc_a) and battle.get_selection() == [merc_a], "Single selection tapped again: still single")
	# Dead members are ignored for selection, kept as members.
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.select_all()
	battle.set_active_caster(merc_b)
	battle.resolve_damage(battle.get_enemies()[0], merc_b, 100000)
	_check(battle.get_selection() == [hero, merc_a] and battle.get_selected() == hero, "A dead caster leaves the selection; the next selected unit is the Active Caster")
	_check(battle.select_group(1) and battle.get_selection() == [merc_a] and battle.get_group(1) == [merc_a, merc_b], "Group ② with B dead: only A selected; B still a member")
	_check(battle.select_all() and battle.get_selection() == [hero, merc_a], "全體 ignores the dead")
	_check(not battle.set_active_caster(merc_b) and not battle.select_or_activate(merc_b), "A dead unit cannot be selected or made caster")
	# Gesture window and result block selection; a new battle has no groups.
	battle.open_gesture()
	_check(not battle.select_all() and not battle.select_group(0) and not battle.select_or_activate(merc_a), "Gesture Window open: no selection change")
	var next := CombatBattle.create(10)
	_check(next.get_group(0).is_empty() and next.get_group(1).is_empty() and next.get_selection() == [next.get_hero()], "Groups exist for one battle only")
	_sections_done.append("selection")


# --- Multi-character move ----------------------------------------------------------------------

func _verify_multi_move() -> void:
	# Preparation: a destination outside the area is refused for everyone.
	var prep := CombatBattle.create(10)
	prep.select_all()
	_check(not prep.command_move_selection(Vector2i(10, 2)) and prep.get_friends().all(func(u: CombatUnit) -> bool: return not u.has_goal), "PREPARATION: an illegal destination is refused for every selected unit")
	_check(prep.tap(Vector2i(3, 2)) and prep.get_friends().all(func(u: CombatUnit) -> bool: return u.has_goal and u.goal == Vector2i(3, 2)), "PREPARATION: a legal tap moves every selected unit")
	var ok := true
	for step in range(60):
		prep.advance(50)
		ok = ok and _occupancy_ok(prep)
	var cells := {}
	for unit in prep.get_friends():
		cells[unit.cell] = true
	_check(ok and cells.size() == 3 and prep.get_friends().all(func(u: CombatUnit) -> bool: return u.cell.x >= 1 and u.cell.x <= 3), "Three units, three distinct legal preparation cells, no shared cell on the way")
	# FIGHTING: all three to one cell -> nearby distinct cells, deterministic.
	var results := []
	for run in range(2):
		var battle := _fight(10, 1)
		_place(battle.get_enemies()[0], Vector2i(60, 0))
		battle.select_all()
		_check(battle.command_move_selection(Vector2i(12, 2)), "Run %d: move ordered for the selection" % run)
		ok = true
		for step in range(80):
			battle.advance(50)
			ok = ok and _occupancy_ok(battle)
		var spots := []
		for unit in battle.get_friends():
			spots.append(unit.cell)
		var unique := {}
		for spot in spots:
			unique[spot] = true
		_check(ok and unique.size() == 3 and spots.has(Vector2i(12, 2)) and spots.all(func(c: Vector2i) -> bool: return CombatUnit.grid_distance(c, Vector2i(12, 2)) <= 1), "Run %d: one unit on the cell, the others on distinct neighbours (%s)" % [run, str(spots)])
		results.append(spots)
	_check(results[0] == results[1], "Deterministic allocation")
	# A selected unit that is casting keeps casting (C06); the others move.
	var cast := _fight(10, 1)
	_place(cast.get_enemies()[0], Vector2i(60, 0))
	cast.select_unit(cast.get_friends()[1])
	cast.command_skill()
	cast.select_all()
	_check(cast.command_move_selection(Vector2i(8, 1)) and cast.get_friends()[1].skill_state == CombatUnit.SkillState.CASTING and not cast.get_friends()[1].has_goal and cast.get_hero().has_goal, "Casting member refused (C06), the others move")
	_sections_done.append("multi_move")


# --- Multi-character target --------------------------------------------------------------------

func _verify_multi_target() -> void:
	var battle := _fight(10, 1)
	var enemy := battle.get_enemies()[0]
	var hero := battle.get_hero()
	var mage := battle.get_friends()[2]
	_place(enemy, Vector2i(20, 2))
	enemy.attack_damage = 0
	enemy.move_speed = 0.001
	battle.toggle_group_member(0, hero)
	battle.toggle_group_member(0, mage)
	battle.select_group(0)
	_hits.clear()
	battle.damage_dealt.connect(_on_damage)
	_check(battle.tap(enemy.cell) and hero.target == enemy and mage.target == enemy and battle.get_friends()[1].target == null, "Tap an enemy: every selected unit targets it, the others do not")
	var first := {}
	for step in range(400):
		battle.advance(25)
		for hit in _hits:
			if not first.has(hit[0].id):
				first[hit[0].id] = CombatUnit.grid_distance(hit[0].cell, hit[1].cell)
		if first.size() == 2:
			break
	_check(first.get("hero", 99) <= 1 and first.get("merc_b", 99) <= 3 and first.get("merc_b", 0) > 1, "Each attacks from its own range (Hero %s, Merc B %s)" % [str(first.get("hero")), str(first.get("merc_b"))])
	_sections_done.append("multi_target")


# --- 全體進攻 ------------------------------------------------------------------------------------

func _verify_attack_all() -> void:
	var prep := CombatBattle.create(10)
	_check(not prep.attack_all() and prep.get_friends().all(func(u: CombatUnit) -> bool: return u.target == null), "PREPARATION: 全體進攻 refused")
	var battle := _fight(10, 3)
	var friends := battle.get_friends()
	var enemies := battle.get_enemies()
	_place(friends[0], Vector2i(5, 2))
	_place(friends[1], Vector2i(5, 0))
	_place(friends[2], Vector2i(5, 4))
	_place(enemies[0], Vector2i(7, 0))
	_place(enemies[1], Vector2i(7, 4))
	_place(enemies[2], Vector2i(30, 2))
	# Hero: e1 and e2 both 2 cells away -> enemy order (e1); A: e1; B: e2.
	_check(battle.nearest_enemy(friends[0]) == enemies[0] and battle.nearest_enemy(friends[1]) == enemies[0] and battle.nearest_enemy(friends[2]) == enemies[1], "Nearest alive enemy, ties by enemy order")
	battle.select_unit(friends[0])
	_check(battle.attack_all() and friends[0].target == enemies[0] and friends[1].target == enemies[0] and friends[2].target == enemies[1], "全體進攻: each targets its own nearest enemy")
	_check(battle.get_selection() == [friends[0]], "全體進攻 leaves the selection alone")
	battle.select_unit(friends[2])
	_check(battle.start_skill_aim() and battle.is_aiming() and battle.attack_all() and not battle.is_aiming(), "全體進攻 while aiming a Skill cancels the aim")
	battle.select_unit(friends[0])
	# Dead friends are skipped; a dead nearest enemy is not chosen.
	battle.resolve_damage(friends[0], enemies[0], 100000)
	battle.resolve_damage(enemies[1], friends[1], 100000)
	battle.attack_all()
	_check(friends[0].target == enemies[1] and friends[1].target == null and friends[2].target == enemies[1], "Dead skipped; the next nearest alive enemy")
	# C06 priority: a casting unit keeps casting; a pending Skill is replaced (no MP).
	var skills := _fight(10, 3)
	var sf := skills.get_friends()
	skills.select_unit(sf[1])
	skills.command_skill()
	skills.select_unit(sf[2])
	skills.command_skill(skills.get_enemies()[2])
	_check(sf[1].skill_state == CombatUnit.SkillState.CASTING and sf[2].skill_state == CombatUnit.SkillState.PENDING, "Setup: A casting Guard, B approaching for AoE")
	skills.attack_all()
	_check(sf[1].skill_state == CombatUnit.SkillState.CASTING and sf[1].target == null, "Casting unit: attack refused, cast continues")
	_check(sf[2].skill_state == CombatUnit.SkillState.NONE and sf[2].target != null and sf[2].mp == 100, "Pending Skill replaced, no MP spent")
	skills.start_retreat()
	_check(not skills.attack_all(), "Retreating: 全體進攻 refused")
	_sections_done.append("attack_all")


# --- Skill bar ---------------------------------------------------------------------------------

func _verify_skill_bar() -> void:
	var main := Node.new()
	var view := CombatView.new()
	root.add_child(main)
	main.add_child(view)
	var battle := _fight(10, 3)
	_toughen(battle.get_enemies())
	view.open(battle)
	var hero := battle.get_hero()
	var merc_a := battle.get_friends()[1]
	var entries := view.get_skill_bar_entries()
	_check(entries.size() == 2 and not entries[0]["compact"] and entries[0]["kind"] == "slow" and entries[0]["title"] == "普通技能：緩速　魔力 25" and entries[1]["kind"] == "lightning" and entries[1]["title"] == "特殊技能：閃電　魔力 50", "Single Hero: expanded 緩速 + 閃電")
	battle.select_unit(merc_a)
	entries = view.get_skill_bar_entries()
	_check(entries.size() == 1 and entries[0]["kind"] == "guard" and entries[0]["title"] == "普通技能：守護　魔力 25", "Single Merc A: expanded 守護, no 閃電 (Hero only)")
	battle.toggle_group_member(0, hero)
	battle.toggle_group_member(0, merc_a)
	battle.select_group(0)
	battle.set_active_caster(hero)
	entries = view.get_skill_bar_entries()
	_check(entries.size() == 3 and entries.all(func(e: Dictionary) -> bool: return e["compact"]) and entries.map(func(e: Dictionary) -> String: return e["kind"]) == ["slow", "lightning", "guard"], "Hero + A: compact 緩速, 閃電, 守護")
	_check(entries[0]["text"].begins_with("主角") and entries[2]["text"].begins_with("傭兵A"), "Compact entries show their owner")
	# 守護 (A's) while the Hero is the caster: A becomes caster, group stays.
	_check(view.press_skill_entry(entries[2]) and battle.get_selected() == merc_a and merc_a.skill_state == CombatUnit.SkillState.CASTING and battle.get_selection() == [hero, merc_a], "守護 tapped: A Active Caster, Guard cast, Hero + A still selected")
	# 緩速 (Hero's): caster Hero, aim, tap an enemy: pending, group stays.
	view.press_skill_entry(view.get_skill_bar_entries()[0])
	var enemy := battle.get_enemies()[0]
	_check(battle.get_selected() == hero and battle.is_aiming() and battle.tap(enemy.cell) and hero.skill_state == CombatUnit.SkillState.PENDING and battle.get_selection() == [hero, merc_a], "緩速 tapped: Hero caster, targeted, still Hero + A")
	# 閃電: the Gesture Window; the selection survives its resolution.
	battle.select_group(0)
	battle.set_active_caster(merc_a)
	var lightning: Dictionary = view.get_skill_bar_entries().filter(func(e: Dictionary) -> bool: return e["kind"] == "lightning")[0]
	_check(view.press_skill_entry(lightning) and battle.is_gesture_open() and battle.get_selected() == hero, "閃電 tapped: Hero caster, Gesture Window open")
	battle.submit_gesture(_ideal())
	_check(not battle.is_gesture_open() and battle.get_selection() == [hero, merc_a] and battle.get_last_gesture()["grade"] == GestureMatcher.Grade.PERFECT, "Gesture resolved (C07 Perfect); Hero + A still selected")
	battle.select_units([merc_a, battle.get_friends()[2]])
	_check(view.get_skill_bar_entries().all(func(e: Dictionary) -> bool: return e["kind"] != "lightning"), "No Hero selected: no 閃電")
	view.close()
	main.queue_free()
	_sections_done.append("skill_bar")


# --- Aggregate HP ------------------------------------------------------------------------------

func _verify_aggregate_hp() -> void:
	var battle := _fight(10)
	var friends := battle.get_friends()
	var enemies := battle.get_enemies()
	_check(battle.get_friend_hp_ratio() == 1.0 and battle.get_enemy_hp_ratio() == 1.0 and CombatView._percent(1.0) == 100, "Start: 100 / 100")
	battle.resolve_damage(enemies[0], friends[0], 65)
	_check(is_equal_approx(battle.get_friend_hp_ratio(), 585.0 / 650.0) and battle.get_enemy_hp_ratio() == 1.0 and CombatView._percent(battle.get_friend_hp_ratio()) == 90, "Friendly damage: 90%; enemy still 100%")
	battle.resolve_damage(friends[0], enemies[0], 100000)
	_check(is_equal_approx(battle.get_enemy_hp_ratio(), 360.0 / 400.0) and is_equal_approx(battle.get_friend_hp_ratio(), 585.0 / 650.0), "One enemy dead: enemy 90%; friendly unchanged (independent)")
	battle.resolve_damage(enemies[1], friends[2], 100000)
	_check(is_equal_approx(battle.get_friend_hp_ratio(), 435.0 / 650.0), "Dead Merc B: 0 HP, its 150 max HP stays in the 650 denominator")
	friends[0].max_hp = 5000
	_check(is_equal_approx(battle.get_friend_hp_ratio(), 435.0 / 650.0), "The denominator is the battle-start total (fixed)")
	for enemy in enemies:
		battle.resolve_damage(friends[0], enemy, 100000)
	_check(battle.get_enemy_hp_ratio() == 0.0 and is_equal_approx(battle.get_friend_hp_ratio(), 435.0 / 650.0) and CombatView._percent(0.0) == 0, "Enemy side at 0: friendly unchanged")
	_check(CombatView._percent(0.998) == 99 and CombatView._percent(0.002) == 1 and CombatView._percent(0.7) == 70, "Percent never 100 while damaged nor 0 while alive")
	_sections_done.append("aggregate_hp")


# --- Camera ------------------------------------------------------------------------------------

func _verify_camera() -> void:
	var camera := CombatCamera.new()
	camera.setup(Vector2(61 * CombatView.CELL_SIZE.x, 5 * CombatView.CELL_SIZE.y), Vector2(720.0, CombatView.FIELD_HEIGHT))
	_check(camera.offset == Vector2.ZERO and camera.max_offset() == Vector2(61 * 56.0 - 720.0, 0.0), "Field 3416 x 540 in a 720 x 540 view: horizontal range only")
	camera.drag(Vector2(-300.0, -80.0))
	_check(camera.offset == Vector2(300.0, 0.0), "Drag left 300: the view moves right 300; no vertical pan (fits)")
	camera.drag(Vector2(-100000.0, 0.0))
	_check(camera.offset.x == camera.max_offset().x, "Bounded at the right edge")
	camera.drag(Vector2(100000.0, 0.0))
	_check(camera.offset.x == 0.0, "Bounded at the left edge")
	camera.center_on_ratio(0.5)
	var range_mid := camera.get_view_range()
	_check(is_equal_approx(camera.offset.x, 3416.0 / 2.0 - 360.0) and is_equal_approx(range_mid.x, camera.offset.x / 3416.0) and is_equal_approx(range_mid.y, (camera.offset.x + 720.0) / 3416.0), "Navigator centre: the view range matches")
	var tall := CombatCamera.new()
	tall.setup(Vector2(1000.0, 700.0), Vector2(720.0, 540.0))
	tall.drag(Vector2(0.0, -500.0))
	_check(tall.offset == Vector2(0.0, 160.0), "Taller content: vertical pan bounded to 160")
	_sections_done.append("camera")


# --- Lifecycle rules with groups / multi-selection --------------------------------------------

func _verify_lifecycle_rules() -> void:
	var victory := _fight(10, 2)
	victory.select_all()
	victory.toggle_group_member(0, victory.get_hero())
	for enemy in victory.get_enemies():
		victory.resolve_damage(victory.get_hero(), enemy, 100000)
	_check(victory.get_phase() == CombatBattle.Phase.VICTORY and victory.get_result().exp_pool == 100 and not victory.select_all() and not victory.attack_all(), "VICTORY with a multi-selection: normal result (EXP 100), no commands after")
	var defeat := _fight(10)
	defeat.select_all()
	for friend in defeat.get_friends():
		defeat.resolve_damage(defeat.get_enemies()[0], friend, 100000)
	_check(defeat.get_phase() == CombatBattle.Phase.DEFEAT and defeat.get_selection().is_empty() and defeat.get_selected() == null, "DEFEAT: nothing left selected")
	# The aiming Active Caster dies: the next selected unit takes over, the aim ends.
	var aim := _fight(10, 3)
	aim.select_all()
	_check(aim.get_selected() == aim.get_hero() and aim.start_skill_aim() and aim.is_aiming(), "Setup: Hero aims Slow in a multi-selection")
	aim.resolve_damage(aim.get_enemies()[0], aim.get_hero(), 100000)
	var merc_a := aim.get_friends()[1]
	_check(aim.get_selected() == merc_a and not aim.is_aiming() and aim.tap(aim.get_enemies()[0].cell) and merc_a.target == aim.get_enemies()[0] and merc_a.skill_state == CombatUnit.SkillState.NONE and merc_a.mp == merc_a.max_mp, "Aiming caster dies: A takes over, aim cleared, the next enemy tap is a target, no Guard cast")
	var retreat := _fight(10, 3)
	retreat.select_all()
	_check(retreat.start_retreat() and not retreat.command_move_selection(Vector2i(5, 2)) and not retreat.attack_all() and retreat.cancel_retreat(), "Manual retreat: group commands refused, still cancellable")
	var forced := _fight(10, 3)
	for friend in forced.get_friends():
		friend.max_hp = 1000000
		friend.hp = 1000000
	forced.select_all()
	forced.advance(CombatConfig.COMBAT_TIME_LIMIT_MS)
	_check(forced.is_forced_retreat() and not forced.cancel_retreat() and not forced.attack_all(), "05:00 forced retreat: not cancellable, 全體進攻 refused")
	_sections_done.append("lifecycle_rules")


# --- In game -----------------------------------------------------------------------------------

func _verify_in_game() -> void:
	_delete(TEST_SAVE)
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
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
	var view := main.get_node("CombatView") as CombatView
	view.set_physics_process(false)
	_toughen(battle.get_enemies())
	var hero := battle.get_hero()
	var merc_a := battle.get_friends()[1]
	var merc_b := battle.get_friends()[2]
	await process_frame
	# HUD layout.
	var retreat := view.get_node("RetreatButton") as Button
	var attack := view.get_node("AttackAllButton") as Button
	var clock := view.get_node("ClockLabel") as Label
	_check(attack.position.x > 400.0 and retreat.position.x < 100.0 and view.has_node("HpBars") and view.has_node("GroupButton1") and view.has_node("GroupButton2") and view.has_node("AllButton") and view.has_node("CameraNavigator"), "HUD: 全體撤退 left, 全體進攻 right, HP bars, ①②全體, navigator")
	_check(not view.has_node("InfoLabel") and not view.has_node("SkillLabel") and not view.has_node("SkillButton") and not view.has_node("GestureButton") and not (view.get_node("HintLabel") as Label).visible, "No permanent debug HP / MP text, no permanent instructions")
	_check((view.get_node("Portrait0") as Control).visible and (view.get_node("Portrait2") as Control).visible and not (view.get_node("Portrait3") as Control).visible and view.get_portrait_unit(1) == merc_a, "Three portraits (a fourth slot exists, hidden)")
	_check(attack.visible and attack.disabled and view.get_friend_hp_percent() == 100 and view.get_enemy_hp_percent() == 100, "PREPARATION: 全體進攻 disabled; HP 100 / 100")
	battle.advance(CombatConfig.PREPARATION_MS)
	await process_frame
	_check(retreat.visible and retreat.text == "全體撤退" and not attack.disabled and clock.visible, "FIGHTING: 全體撤退, 全體進攻 enabled, clock")
	# Camera: no follow; drag pans and issues no command; a short wobble is a tap.
	var scroll := view.get_scroll_x()
	view.tap_at(view.cell_center(Vector2(merc_b.cell)))
	battle.command_move(Vector2i(20, 3))
	battle.advance(3000)
	await process_frame
	_check(battle.get_selected() == merc_b and merc_b.cell.x > 8 and view.get_scroll_x() == scroll, "Selected unit walks off: the camera stays")
	var start := Vector2(360.0, CombatView.FIELD_TOP + 200.0)
	var selection := battle.get_selection()
	view.field_press(start)
	view.field_drag(start + Vector2(-6.0, 0.0))
	view.field_drag(start + Vector2(-200.0, 0.0))
	_check(not view.field_release(start + Vector2(-200.0, 0.0)) and view.get_scroll_x() == scroll + 200.0, "Drag 200 px: camera +200, no command")
	_check(battle.get_selection() == selection and hero.target == null and not hero.has_goal and merc_a.target == null, "The drag issued no move / target / selection")
	var range_after_drag := view.get_camera().get_view_range()
	_check(is_equal_approx(range_after_drag.x, view.get_scroll_x() / (61 * 56.0)), "Navigator range follows the drag")
	var cell := Vector2(view.cell_at(start))
	view.field_press(start)
	view.field_drag(start + Vector2(8.0, 0.0))
	_check(view.field_release(start + Vector2(8.0, 0.0)) and merc_b.has_goal and Vector2(merc_b.goal) == cell, "An 8 px wobble is still a tap (move)")
	var navigator := view.get_node("CameraNavigator") as Control
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(navigator.size.x, 10.0)
	navigator._gui_input(click)
	_check(view.get_scroll_x() == view.get_camera().max_offset().x and view.get_camera().get_view_range().y == 1.0, "Navigator press at the right end: the view shows the right edge")
	click.position = Vector2(0.0, 10.0)
	navigator._gui_input(click)
	_check(view.get_scroll_x() == 0.0, "Navigator at the left end")
	# Groups through the HUD.
	var hint := view.get_node("GroupHint") as Label
	var texts := []
	_check(view.press_group(0) and view.get_editing_group() == 0 and (view.get_node("GroupButton1") as Button).text == "完成①", "Empty ①: editing (完成①)")
	await process_frame
	texts.append(hint.text)
	view.press_portrait(hero)
	view.press_portrait(merc_a)
	_check(battle.get_group(0) == [hero, merc_a] and view.get_portrait_state(0)["groups"] == ["①"] and view.get_portrait_state(1)["editing"], "Portrait taps add members (① marks)")
	view.press_group(0)
	await process_frame
	_check(view.get_editing_group() == -1 and battle.get_selection() == [hero, merc_a] and hint.text == "再按群組①可編輯成員", "完成①: Hero + A selected (%s)" % hint.text)
	texts.append(hint.text)
	_check(view.press_portrait(merc_a) and battle.get_selected() == merc_a and battle.get_selection() == [hero, merc_a] and view.get_portrait_state(1)["caster"] and view.get_portrait_state(0)["selected"], "Portrait A in the group: A Active Caster, Hero + A stay")
	view.press_group(0)
	_check(view.get_editing_group() == 0, "Pressing the selected ① again: editing again")
	view.press_portrait(merc_a)
	view.press_group(0)
	_check(battle.get_group(0) == [hero] and battle.get_selection() == [hero], "A removed; ① = Hero")
	view.press_group(1)
	view.press_portrait(merc_a)
	view.press_portrait(merc_b)
	view.press_group(1)
	view.press_all()
	_check(battle.get_selection() == [hero, merc_a, merc_b] and view.get_portrait_state(1)["groups"] == ["②"] and view.get_editing_group() == -1, "② = A + B; 全體 selects all")
	view.press_portrait(merc_b)
	_check(battle.get_selection() == [hero, merc_a, merc_b] and battle.get_selected() == merc_b, "Portrait B in 全體: caster B, all stay selected")
	# Character info.
	(view.get_node("InfoButton1") as Button).pressed.emit()
	await process_frame
	var info := (view.get_node("InfoPanel/InfoText") as Label).text
	_check((view.get_node("InfoPanel") as Control).visible and info.contains("傭兵A") and info.contains("生命 200 / 200") and info.contains("魔力 100 / 100") and info.contains("等級 1") and info.contains("經驗 0") and info.contains("攻擊 15") and info.contains("攻擊距離 1 格") and info.contains("守護"), "ⓘ: name, HP, MP, Level, EXP, combat values, Skill (%s)" % info)
	_check(battle.get_selection() == [hero, merc_a, merc_b], "ⓘ does not change the selection")
	texts.append(info)
	(view.get_node("InfoPanel/InfoClose") as Button).pressed.emit()
	await process_frame
	_check(not (view.get_node("InfoPanel") as Control).visible, "Info closed")
	# 全體進攻 through the HUD.
	attack.pressed.emit()
	_check(battle.get_friends().all(func(u: CombatUnit) -> bool: return u.target == battle.nearest_enemy(u)), "全體進攻: every friendly unit on its nearest enemy")
	# Skill bar (compact while all are selected).
	var slots := []
	for index in range(8):
		var slot := view.get_node("SkillSlot%d" % index) as Button
		if slot.visible:
			slots.append(slot)
	_check(slots.size() == 4, "Compact skill bar: 緩速, 閃電, 守護, 範圍攻擊")
	for entry in view.get_skill_bar_entries():
		texts.append(entry["text"])
	# Retreat labels.
	retreat.pressed.emit()
	await process_frame
	_check(battle.is_retreating() and retreat.text == "取消撤退", "全體撤退 pressed: 取消撤退")
	retreat.pressed.emit()
	await process_frame
	_check(not battle.is_retreating() and retreat.text == "全體撤退", "Cancelled")
	texts.append_array([retreat.text, attack.text, "取消撤退", (view.get_node("GroupButton1") as Button).text, (view.get_node("AllButton") as Button).text])
	# HP bars and victory with the multi-selection; nothing of it is saved.
	battle.resolve_damage(battle.get_enemies()[0], hero, 65)
	await process_frame
	_check(view.get_friend_hp_percent() == 90 and view.get_enemy_hp_percent() == 100, "HUD HP: 90% | 100%")
	for enemy in battle.get_enemies():
		battle.resolve_damage(hero, enemy, 100000)
	await process_frame
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY and view.get_enemy_hp_percent() == 0 and view.get_skill_bar_entries().is_empty() and not (view.get_node("GroupButton1") as Button).visible, "VICTORY: enemy 0%, battle controls gone")
	(view.get_node("ExitButton") as Button).pressed.emit()
	await process_frame
	var saved := FileAccess.get_file_as_string(TEST_SAVE)
	_check(main.get_combat() == null and session.is_protection_active() and int(JSON.parse_string(saved)["version"]) == 9 and not saved.to_lower().contains("group") and not saved.to_lower().contains("selection") and main.progression.get_exp("hero") > 0, "Committed: C02 lifecycle, protection (#104 recheck path), C05 EXP, Save v9 without groups / selection")
	var approved := RegEx.new()
	approved.compile("(?<![A-Za-z])[ABE](?![A-Za-z])")
	var latin := RegEx.new()
	latin.compile("[A-Za-z]")
	var with_latin := texts.filter(func(t: String) -> bool: return latin.search(approved.sub(t, "", true)) != null)
	_check(with_latin.is_empty(), "All C08 texts are Traditional Chinese (%s)" % str(with_latin))
	root.remove_child(main)
	main.free()
	_delete(TEST_SAVE)
	await process_frame
	_sections_done.append("in_game")


# --- Helpers -----------------------------------------------------------------------------------

func _fight(enemies: int, alive: int = -1) -> CombatBattle:
	var battle := CombatBattle.create(enemies)
	battle.advance(CombatConfig.PREPARATION_MS)
	if alive >= 0:
		for index in range(alive, enemies):
			battle.resolve_damage(battle.get_hero(), battle.get_enemies()[index], 1000)
	return battle


func _toughen(enemies: Array[CombatUnit]) -> void:
	for enemy in enemies:
		if enemy.alive:
			enemy.max_hp = 500
			enemy.hp = 500


func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


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
	var out := PackedVector2Array()
	var guide: Array = GestureMatcher.GUIDE
	for index in range(guide.size() - 1):
		for k in range(10):
			out.append((guide[index] as Vector2).lerp(guide[index + 1], k / 10.0))
	out.append(guide[-1])
	return out


func _on_damage(attacker: CombatUnit, target: CombatUnit, amount: int) -> void:
	_hits.append([attacker, target, amount])


func _delete(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


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
