extends SceneTree

## Stage 8 iPhone L3 Corrective (Charlie's iPhone 15 Pro test of the P05
## candidate). Six corrections, each with its regression checks:
##   world_text    AC01 the World Map text block 《萬行誌：白手》 / 開發原型：基本市場
##                 / 走到 A 城或 B 城… is gone; entering a city still works
##   tabs          AC02 the Character tab strip takes a natural finger swipe
##                 (anywhere on the tabs); a still tap selects; a swipe selects
##                 nothing and never allocates; Hero + 5 all reachable
##   mage          AC03 法師 AoE is ground-targeted: aim -> any battlefield
##                 cell (no enemy needed) -> approach within 5 -> resolves on
##                 the locked cell; damage / MP / cooldown unchanged
##   hero          AC04 主角 Slow: no target, cast at once, every alive enemy;
##                 values unchanged
##   ice_wall      AC05 軍師 冰牆: ground-targeted, 2 columns x 5 rows (not a
##                 cross), enemies cannot step onto it while it stands (several
##                 enemies), enemies inside get the existing Slow, friends pass,
##                 melts after SKILL_EFFECT_MS, then enemies pass again
##   invalid       aim cancel, off-grid / wrong-skill / not-ready refusals
##   countdown     AC06 dismissal: 確定解僱（5）…（1） disabled, then 確定解僱;
##                 取消 always; reopen restarts at 5; deployed refused first;
##                 permanent, no refund, saved
##   lifecycle     the real game: World -> Encounter -> Combat (all three new
##                 Skills) -> Victory -> EXP -> World, saved v12, reload
##   scope         no Save schema change, no new number, no new system
##   stress        TARGETED: repeated skills / walls / blocking / aim / cancel,
##                 countdown open / cancel / reopen, tab swipes vs taps

const TEST_SAVE := "user://s8_l3_corrective_test.json"
const T0 := 1800000000000
const PASSIVE_ONLY := Vector2(950.0, 1080.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _hits := []


func _initialize() -> void:
	await _verify_world_text()
	await _verify_tabs()
	_verify_mage()
	_verify_hero()
	_verify_ice_wall()
	_verify_invalid()
	await _verify_countdown()
	await _verify_lifecycle()
	_verify_scope()
	await _verify_stress()
	_check(_sections_done.size() == 10, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S8 iPhone L3 corrective verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- AC01 World Map text ----------------------------------------------------------------------------

func _verify_world_text() -> void:
	_clean()
	var main := await _new_main()
	_check(not main.has_node("Interface/Content/Status"), "AC01 The world text block (Status) is gone")
	var texts := []
	for node in main.find_children("*", "Label", true, false):
		var label := node as Label
		if label.is_visible_in_tree():
			texts.append(label.text)
	var blocking := texts.filter(func(t: String) -> bool: return t.contains("萬行誌") or t.contains("開發原型") or t.contains("走到 A 城"))
	_check(blocking.is_empty(), "AC01 No visible world label shows the title / prototype / instruction text (%s)" % str(blocking))
	var scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_check(not scene.contains("開發原型：基本市場") and not scene.contains("走到 A 城或 B 城"), "AC01 main.tscn no longer holds those texts")
	# Entering a city still works without the instruction text.
	await _enter_city(main)
	_check((main.get_node("CityHub") as CityHub).is_open(), "AC01 Entering city A still works")
	_check(main.leave_city(), "Leaving the city still works")
	await _destroy(main)
	_sections_done.append("world_text")


# --- AC02 Character tab strip swipe -----------------------------------------------------------------

func _verify_tabs() -> void:
	_clean()
	var main := await _new_main()
	var roster := MercenaryRoster.new()
	for type in ["MAGE", "GUARDIAN", "STRATEGIST", "MAGE", "GUARDIAN"]:
		roster.create_mercenary(type)
	main.mercenary_roster = roster
	var panel := main.get_node("CharacterPanel") as CharacterPanel
	_check(panel.open(), "AC02 Character UI opens with Hero + 5")
	await process_frame
	await process_frame
	var ids := panel.get_tab_ids()
	_check(ids.size() == 6 and ids[0] == "hero", "AC02 Hero + 5 tabs (%s)" % str(ids))
	var touch_area := panel.get_node("Panel/TabTouch") as Control
	var strip := panel.get_node("Panel/TabStrip") as ScrollContainer
	_check(touch_area.get_global_rect().is_equal_approx(strip.get_global_rect()) and touch_area.mouse_filter == Control.MOUSE_FILTER_STOP, "AC02 The swipe area covers the whole tab strip")
	_check(ids.all(func(id: String) -> bool: return panel.get_tab(id).mouse_filter == Control.MOUSE_FILTER_IGNORE), "AC02 Tabs leave touches to the swipe area (a press on a tab can still become a swipe)")
	var origin := touch_area.get_global_rect().position
	var y := 36.0
	var snapshot := JSON.stringify(main.mercenary_roster.get_snapshot())
	var hero_points: Dictionary = (main.character_stats as CharacterStats).get_allocation_points().duplicate()
	_check(panel.get_tab_scroll() == 0 and panel.get_selected() == "hero", "Start: scrolled to the left, Hero selected")
	# A finger swipe right-to-left over the tabs scrolls with the finger.
	await _swipe(0, origin + Vector2(600.0, y), origin + Vector2(100.0, y))
	_check(panel.get_tab_scroll() == 500, "AC02 A 500 px finger swipe scrolls the strip 500 px (%d)" % panel.get_tab_scroll())
	_check(panel.get_selected() == "hero" and panel.get_pending().is_empty(), "AC02 The swipe selected nothing and allocated nothing")
	# A still tap selects the tab under the finger (here the 6th, the last Mercenary).
	var last_x := 5 * (CharacterPanel.TAB_SIZE.x + 12.0) - 500.0 + 60.0
	_check(panel.tab_at(Vector2(last_x, y)) == ids[5], "tab_at finds the 6th tab after the scroll")
	await _tap(0, origin + Vector2(last_x, y))
	_check(panel.get_selected() == ids[5] and panel.get_tab(ids[5]).disabled, "AC02 A tap after the swipe selects the 6th tab (%s)" % panel.get_selected())
	# Swipe back left-to-right, then an 8 px wobble is still a tap.
	# (Selecting the 6th tab scrolled it fully into view, so swipe a full width.)
	await _swipe(1, origin + Vector2(20.0, y), origin + Vector2(670.0, y))
	_check(panel.get_tab_scroll() == 0 and panel.get_selected() == ids[5], "AC02 Swiping back reaches the start; the selection stays")
	await _touch(1, origin + Vector2(330.0, y), true)
	await _drag(1, origin + Vector2(338.0, y))
	await _touch(1, origin + Vector2(338.0, y), false)
	_check(panel.get_selected() == ids[1] and panel.get_tab_scroll() == 0, "AC02 An 8 px wobble is a tap: the 2nd tab (%s)" % panel.get_selected())
	# A swipe that starts on one tab and ends on another selects neither.
	await _swipe(2, origin + Vector2(110.0, y), origin + Vector2(10.0, y))
	_check(panel.get_selected() == ids[1] and panel.get_tab_scroll() == 100, "AC02 Swipe from tab 1 to nothing: no selection change (%s, %d)" % [panel.get_selected(), panel.get_tab_scroll()])
	# Emulated mouse (the touch's own copy on a phone) is ignored.
	await _emulated_click(origin + Vector2(110.0, y), true)
	await _emulated_click(origin + Vector2(110.0, y), false)
	_check(panel.get_selected() == ids[1], "Emulated mouse events do nothing (the touch is handled once)")
	# Desktop mouse: drag scrolls, click selects.
	await _mouse(origin + Vector2(400.0, y), true)
	await _mouse_drag(origin + Vector2(200.0, y))
	await _mouse(origin + Vector2(200.0, y), false)
	_check(panel.get_tab_scroll() == 300 and panel.get_selected() == ids[1], "Mouse drag scrolls (desktop), selects nothing (%d)" % panel.get_tab_scroll())
	await _mouse(origin + Vector2(250.0, y), true)
	await _mouse(origin + Vector2(250.0, y), false)
	_check(panel.get_selected() == panel.tab_at(Vector2(250.0, y)) or panel.get_selected() == ids[2], "Mouse click selects the tab under it (%s)" % panel.get_selected())
	# Every tab can be reached and selected by finger alone.
	for index in range(ids.size()):
		# Swipe fully to the right end for the later tabs, to the left start for the first ones.
		if index >= 3:
			await _swipe(3, origin + Vector2(650.0, y), origin + Vector2(20.0, y))
			await _swipe(3, origin + Vector2(650.0, y), origin + Vector2(20.0, y))
		else:
			await _swipe(3, origin + Vector2(20.0, y), origin + Vector2(650.0, y))
			await _swipe(3, origin + Vector2(20.0, y), origin + Vector2(650.0, y))
		var tab := panel.get_tab(ids[index])
		var center := tab.get_global_rect().get_center()
		center.x = clampf(center.x, origin.x + 20.0, origin.x + 650.0)
		await _tap(3, center)
		_check(panel.get_selected() == ids[index], "AC02 Finger only: tab %d (%s) reached and selected" % [index + 1, ids[index]])
	_check(JSON.stringify(main.mercenary_roster.get_snapshot()) == snapshot and panel.get_pending().is_empty(), "AC02 After all the swipes and taps: no allocation, the roster unchanged")
	_check((main.character_stats as CharacterStats).get_allocation_points() == hero_points, "The Hero's points unchanged")
	# The allocation buttons still work on the selected character (regression).
	panel.select_character("hero")
	_check(panel.get_selected() == "hero", "select_character still works")
	await _destroy(main)
	_sections_done.append("tabs")


# --- AC03 Mage ground target --------------------------------------------------------------------------

func _verify_mage() -> void:
	var battle := _party_fight(["MAGE"], 10, 7)
	var mage := battle.get_friends()[1]
	var enemies := battle.get_enemies()
	var layout := [Vector2i(30, 2), Vector2i(29, 2), Vector2i(31, 2), Vector2i(30, 1), Vector2i(30, 3), Vector2i(31, 3), Vector2i(32, 2)]
	for index in range(layout.size()):
		enemies[index].max_hp = 200
		enemies[index].hp = 200
		enemies[index].move_speed = 0.001
		_place(enemies[index], layout[index])
	_place(mage, Vector2i(10, 2))
	_check(CombatBattle.skill_target_type(mage.skill) == "ground" and mage.skill["kind"] == "aoe", "AC03 法師 skill is ground-targeted")
	battle.select_unit(mage)
	_check(battle.start_skill_aim() and battle.is_aiming() and mage.skill_state == CombatUnit.SkillState.NONE, "AC03 Activate: aiming a location, nothing ordered yet")
	# The location is an empty cell next to the enemies (no enemy there).
	var spot := Vector2i(30, 0)
	_check(battle.unit_at(spot) == null, "The chosen cell is empty")
	_check(battle.tap(spot) and mage.skill_state == CombatUnit.SkillState.PENDING and mage.skill_target == null and mage.skill_cell == spot and not battle.is_aiming(), "AC03 Tap an empty battlefield cell: AoE ordered there, no enemy target")
	_check(mage.mp == mage.max_mp and battle.get_skill_cooldown_remaining(mage) == 0, "Approaching: no MP, no cooldown yet")
	var cast_at := Vector2i(-1, -1)
	for step in range(2000):
		battle.advance(10)
		if mage.skill_state == CombatUnit.SkillState.CASTING:
			cast_at = mage.cell
			break
	_check(cast_at != Vector2i(-1, -1) and CombatUnit.grid_distance(cast_at, spot) <= 5 and CombatUnit.grid_distance(cast_at, spot) >= 4 and mage.mp == mage.max_mp - 25, "AC03 Walked until the cell was within 5, cast there, 25 MP (%s)" % str(cast_at))
	var hp := enemies.map(func(e: CombatUnit) -> int: return e.hp)
	_hits.clear()
	battle.damage_dealt.connect(_on_damage)
	battle.advance(CombatConfig.SKILL_CAST_MS)
	var damage := CombatConfig.AOE_DAMAGE + mage.magic_attack
	var mage_hits := _hits.filter(func(h: Array) -> bool: return h[0] == mage)
	_check(mage_hits.size() == 1 and mage_hits[0][1] == enemies[3] and mage_hits[0][2] == damage, "AC03 Resolved on the location: only the enemy at (30,1) (in the cross of (30,0)) hit, %d (= 40 + Magic Attack) (%s)" % [damage, str(mage_hits.map(func(h: Array) -> int: return h[2]))])
	_check([0, 1, 2, 4, 5, 6].all(func(i: int) -> bool: return enemies[i].hp == hp[i]), "AC03 Enemies off the cross untouched (no enemy-target behaviour)")
	_check(battle.get_last_aoe()["cells"] == CombatBattle.aoe_cells(spot) and battle.get_skill_cooldown_remaining(mage) == CombatConfig.SKILL_COOLDOWN_MS and mage.skill_state == CombatUnit.SkillState.NONE, "AC03 AoE cells = the existing cross on the location; 8 s cooldown")
	# Within range at once: casts without moving; the location is locked.
	var near := _party_fight(["MAGE"], 10, 1)
	var near_mage := near.get_friends()[1]
	var runner := near.get_enemies()[0]
	_place(near_mage, Vector2i(20, 2))
	_place(runner, Vector2i(24, 2))
	near.select_unit(near_mage)
	_check(near.command_skill(runner) and near_mage.skill_cell == Vector2i(24, 2), "Given an enemy (shortcut): the enemy's cell is the location")
	near.advance(10)
	_check(near_mage.skill_state == CombatUnit.SkillState.CASTING and near_mage.cell == Vector2i(20, 2), "In range: cast at once, no movement")
	_place(runner, Vector2i(40, 0))
	near.advance(CombatConfig.SKILL_CAST_MS)
	_check(runner.hp == runner.max_hp and near.get_last_aoe()["cells"] == CombatBattle.aoe_cells(Vector2i(24, 2)), "AC03 The enemy left: the AoE still lands on the locked location, the enemy is not hit")
	# Values unchanged.
	_check(CombatConfig.MERC_B_SKILL["range"] == 5 and CombatConfig.AOE_DAMAGE == 40 and CombatConfig.SKILL_MP_COST == 25 and CombatConfig.SKILL_COOLDOWN_MS == 8000, "AC03 Range 5, damage 40 + Magic Attack, MP 25, cooldown 8 s unchanged")
	_sections_done.append("mage")


# --- AC04 Hero Slow: all enemies ----------------------------------------------------------------------

func _verify_hero() -> void:
	var battle := _party_fight([], 10, 8)
	var hero := battle.get_hero()
	var enemies := battle.get_enemies()
	_check(CombatBattle.skill_target_type(hero.skill) == "all_enemies" and hero.skill["kind"] == "slow", "AC04 主角 skill needs no target (all enemies)")
	battle.select_unit(hero)
	var hp := enemies.map(func(e: CombatUnit) -> int: return e.hp)
	_check(battle.start_skill_aim() and not battle.is_aiming() and hero.skill_state == CombatUnit.SkillState.CASTING and hero.skill_target == null and hero.mp == hero.max_mp - 25, "AC04 Activate: no target selection, cast at once, 25 MP")
	_check(not hero.is_moving() and hero.cell == CombatConfig.HERO_START_CELL, "AC04 No approach (the Hero stays)")
	battle.advance(CombatConfig.SKILL_CAST_MS)
	var alive := enemies.filter(func(e: CombatUnit) -> bool: return e.alive)
	_check(alive.size() == 8 and alive.all(func(e: CombatUnit) -> bool: return battle.get_slow_remaining(e) == CombatConfig.SKILL_EFFECT_MS), "AC04 All 8 alive enemies slowed for 5 s, wherever they are")
	_check(enemies.filter(func(e: CombatUnit) -> bool: return not e.alive).all(func(e: CombatUnit) -> bool: return battle.get_slow_remaining(e) == 0), "AC04 The dead get nothing")
	_check(alive.all(func(e: CombatUnit) -> bool: return e.step_ms() == roundi(1000.0 / e.move_speed) * CombatConfig.SLOW_FACTOR), "AC04 The existing Slow (x2 steps)")
	_check(enemies.all(func(e: CombatUnit) -> bool: return not e.alive or e.hp == hp[enemies.find(e)]), "AC04 No damage (formula unchanged: Slow only)")
	_check(battle.get_skill_cooldown_remaining(hero) == CombatConfig.SKILL_COOLDOWN_MS and battle.get_skill_readiness(hero) == CombatBattle.SkillReadiness.COOLDOWN, "AC04 8 s cooldown")
	_check(not battle.start_skill_aim() and hero.mp == hero.max_mp - 25, "On cooldown: refused, no MP")
	_sections_done.append("hero")


# --- AC05 Strategist Ice Wall -------------------------------------------------------------------------

func _verify_ice_wall() -> void:
	# Shape: 2 columns x 5 rows, not a cross.
	var cells := CombatBattle.ice_wall_cells(Vector2i(20, 2))
	var expected: Array[Vector2i] = []
	for column in [20, 21]:
		for row in range(5):
			expected.append(Vector2i(column, row))
	_check(cells == expected, "AC05 Wall from (20,2): columns 20-21, rows 0-4 (%s)" % str(cells))
	_check(cells.size() == 10 and not cells.has(Vector2i(19, 2)) and cells.has(Vector2i(20, 0)) and cells.has(Vector2i(21, 4)), "AC05 Vertical full height, not the cross (19,2 out; corners in)")
	_check(CombatBattle.ice_wall_cells(Vector2i(20, 4)) == expected and CombatBattle.ice_wall_cells(Vector2i(20, 0)) == expected, "AC05 Any row of the column gives the same full-height wall")
	_check(CombatBattle.ice_wall_cells(Vector2i(60, 1)).all(func(c: Vector2i) -> bool: return c.x == 59 or c.x == 60) and CombatBattle.ice_wall_cells(Vector2i(60, 1)).size() == 10, "AC05 Right edge: columns 59-60 (still 2 x 5)")
	_check(CombatBattle.ice_wall_cells(Vector2i(0, 3)).all(func(c: Vector2i) -> bool: return c.x == 0 or c.x == 1), "AC05 Left edge: columns 0-1")
	# Cast: ground-targeted, approach, 25 MP, cooldown; wall stands 5 s.
	var battle := _party_fight(["STRATEGIST"], 10)
	var strategist := battle.get_friends()[1]
	var hero := battle.get_hero()
	var enemies := battle.get_enemies()
	for friend in battle.get_friends():
		friend.max_hp = 1000000
		friend.hp = 1000000
	for index in range(enemies.size()):
		_place(enemies[index], Vector2i(30 + index / 5, index % 5))
		enemies[index].attack_damage = 0
	_place(hero, Vector2i(12, 2))
	_place(strategist, Vector2i(10, 0))
	battle.select_unit(strategist)
	_check(CombatBattle.skill_target_type(strategist.skill) == "ground", "AC05 軍師 skill is ground-targeted")
	_check(battle.start_skill_aim() and battle.is_aiming(), "AC05 Activate: aiming a location")
	_check(battle.tap(Vector2i(20, 2)) and strategist.skill_state == CombatUnit.SkillState.PENDING and strategist.skill_cell == Vector2i(20, 2) and strategist.skill_target == null, "AC05 Tap (20,2): the wall ordered there")
	var resolved := []
	battle.skill_resolved.connect(func(unit: CombatUnit) -> void: resolved.append(unit))
	for step in range(400):
		battle.advance(10)
		if not resolved.is_empty():
			break
	var walls := battle.get_ice_walls()
	_check(resolved == [strategist] and walls.size() == 1 and walls[0]["cells"] == expected, "AC05 Resolved: one wall on columns 20-21")
	_check(int(walls[0]["until_ms"]) == battle.get_elapsed_ms() + CombatConfig.SKILL_EFFECT_MS, "AC05 It stands for SKILL_EFFECT_MS (5 s)")
	_check(strategist.mp == strategist.max_mp - 25 and battle.get_skill_cooldown_remaining(strategist) == CombatConfig.SKILL_COOLDOWN_MS, "AC05 25 MP, 8 s cooldown (existing values)")
	_check(cells.all(func(c: Vector2i) -> bool: return battle.is_ice_wall_cell(c)) and not battle.is_ice_wall_cell(Vector2i(19, 2)) and not battle.is_ice_wall_cell(Vector2i(22, 2)), "is_ice_wall_cell: the 10 cells only")
	# 10 enemies march left: none may step onto the wall while it stands.
	var entered := false
	var crossed := false
	var min_x := 99
	while battle.get_elapsed_ms() < int(walls[0]["until_ms"]) - 10:
		battle.advance(10)
		for enemy in enemies:
			if enemy.alive:
				entered = entered or expected.has(enemy.cell) or expected.has(enemy.next_cell)
				crossed = crossed or enemy.cell.x < 20
				min_x = mini(min_x, enemy.cell.x)
	_check(not entered and not crossed, "AC05 While it stands: none of the 10 enemies entered a wall cell or passed it")
	_check(min_x == 22, "AC05 The enemies stopped right at the wall (column 22: %d)" % min_x)
	var spots := {}
	for enemy in enemies:
		spots[enemy.cell] = true
	_check(spots.size() == enemies.size(), "AC05 The held enemies queue one per cell (no stacking: %s)" % str(enemies.map(func(u: CombatUnit) -> Vector2i: return u.cell)))
	_check(enemies.filter(func(e: CombatUnit) -> bool: return e.cell.x == 22).size() == 5, "AC05 Five enemies hold along the whole wall face (every row blocked)")
	_check(enemies.all(func(e: CombatUnit) -> bool: return not e.is_moving() and e.claim == e.cell), "AC05 The held enemies stand still (no back-and-forth at the wall)")
	_check(not battle.is_over() and hero.alive and strategist.alive, "The battle goes on")
	# Melts: walls gone, the enemies pass again.
	battle.advance(20)
	_check(battle.get_ice_walls().is_empty() and not battle.is_ice_wall_cell(Vector2i(20, 2)), "AC05 After 5 s the wall is removed")
	battle.advance(3000)
	_check(enemies.any(func(e: CombatUnit) -> bool: return e.cell.x <= 21), "AC05 After it melts the enemies walk through again")
	# Enemies inside when it rises: the existing Slow; one mid-step stops.
	var inside := _party_fight(["STRATEGIST"], 10, 5)
	var inside_caster := inside.get_friends()[1]
	var e := inside.get_enemies()
	_place(e[0], Vector2i(20, 0))
	_place(e[1], Vector2i(21, 4))
	_place(e[2], Vector2i(22, 1))
	_place(e[3], Vector2i(19, 3))
	_place(e[4], Vector2i(22, 2))
	e[4].next_cell = Vector2i(21, 2)
	e[4].step_progress_ms = 200
	var hp := e.map(func(u: CombatUnit) -> int: return u.hp)
	inside._raise_ice_wall(inside_caster, Vector2i(20, 1))
	_check(inside.get_slow_remaining(e[0]) == CombatConfig.SKILL_EFFECT_MS and inside.get_slow_remaining(e[1]) == CombatConfig.SKILL_EFFECT_MS, "AC05 Enemies inside the wall cells at creation: the existing Slow (freeze), 5 s")
	_check(inside.get_slow_remaining(e[2]) == 0 and inside.get_slow_remaining(e[3]) == 0 and inside.get_slow_remaining(e[4]) == 0, "AC05 Enemies outside: not slowed")
	_check(e[4].next_cell == Vector2i(22, 2) and e[4].step_progress_ms == 0 and e[4].cell == Vector2i(22, 2), "AC05 An enemy stepping into the wall at creation stops on its own cell")
	_check(e.all(func(u: CombatUnit) -> bool: return u.hp == hp[e.find(u)]), "AC05 The wall deals no damage")
	_check(inside.get_last_aoe()["kind"] == "ice_field" and inside.get_last_aoe()["damage"] == 0 and inside.get_last_aoe()["cells"] == expected, "The wall is marked (presentation)")
	inside.advance(2000)
	_check(e[1].cell.x >= 21 and not (e[2].cell.x < 22 and expected.has(e[2].cell)), "AC05 An enemy inside cannot move further into the wall; outside ones cannot enter")
	# Friends are not blocked: the Hero walks through the wall.
	var walk := _party_fight(["STRATEGIST"], 10)
	var walker := walk.get_hero()
	_place(walker, Vector2i(10, 2))
	walk._raise_ice_wall(walk.get_friends()[1], Vector2i(20, 2))
	walk.select_unit(walker)
	walk.command_move(Vector2i(28, 2))
	var on_wall := false
	for step in range(1000):
		walk.advance(10)
		on_wall = on_wall or walk.is_ice_wall_cell(walker.cell)
	_check(on_wall and walker.cell == Vector2i(28, 2), "AC05 Friendly units are not blocked (the Hero walked through to (28,2))")
	# Two walls (two 軍師) at once; each melts on its own.
	var two := _party_fight(["STRATEGIST", "STRATEGIST"], 10)
	two._raise_ice_wall(two.get_friends()[1], Vector2i(20, 2))
	two.advance(1000)
	two._raise_ice_wall(two.get_friends()[2], Vector2i(30, 2))
	_check(two.get_ice_walls().size() == 2 and two.is_ice_wall_cell(Vector2i(21, 0)) and two.is_ice_wall_cell(Vector2i(31, 4)), "Two walls stand together")
	two.advance(4010)
	_check(two.get_ice_walls().size() == 1 and not two.is_ice_wall_cell(Vector2i(21, 0)) and two.is_ice_wall_cell(Vector2i(31, 4)), "The first melts first; the second still stands")
	# Retreat: friends pass the wall to column 0.
	var retreat := _party_fight(["STRATEGIST"], 10)
	for friend in retreat.get_friends():
		_place(friend, Vector2i(25, retreat.get_friends().find(friend)))
	retreat._raise_ice_wall(retreat.get_friends()[1], Vector2i(20, 2))
	retreat.start_retreat()
	retreat.advance(8000)
	_check(retreat.get_phase() == CombatBattle.Phase.RETREAT, "A retreat through a wall still reaches the Retreat Zone")
	_sections_done.append("ice_wall")


# --- Invalid targets, cancel -------------------------------------------------------------------------

func _verify_invalid() -> void:
	var battle := _party_fight(["MAGE", "STRATEGIST", "GUARDIAN"], 10)
	var mage := battle.get_friends()[1]
	var strategist := battle.get_friends()[2]
	var guardian := battle.get_friends()[3]
	battle.select_unit(mage)
	for cell in [Vector2i(-1, 2), Vector2i(61, 0), Vector2i(5, 5), Vector2i(5, -1)]:
		_check(not battle.command_skill_at(cell) and mage.skill_state == CombatUnit.SkillState.NONE and mage.mp == mage.max_mp, "Off-grid %s: refused, nothing ordered" % str(cell))
	_check(not battle.command_skill(null) and mage.skill_state == CombatUnit.SkillState.NONE, "Ground Skill without a location: refused")
	battle.select_unit(battle.get_hero())
	_check(not battle.command_skill_at(Vector2i(10, 2)) and battle.get_hero().skill_state == CombatUnit.SkillState.NONE, "The Hero's Slow cannot be given a location")
	battle.select_unit(guardian)
	_check(not battle.command_skill_at(Vector2i(10, 2)) and guardian.skill_state == CombatUnit.SkillState.NONE, "Guard cannot be given a location")
	# Aim then cancel (skill button again / off-grid tap in the view).
	var main := Node.new()
	var view := CombatView.new()
	root.add_child(main)
	main.add_child(view)
	view.open(battle)
	battle.select_unit(strategist)
	_check(view.press_skill() and battle.is_aiming(), "View: Skill pressed, aiming")
	_check(view.get_node("HintLabel").visible and (view.get_node("HintLabel") as Label).text == "點戰場位置施放技能　再按技能取消", "View: the ground prompt")
	view.press_skill()
	_check(not battle.is_aiming() and strategist.skill_state == CombatUnit.SkillState.NONE and strategist.mp == strategist.max_mp, "Skill pressed again: aim cancelled, nothing paid")
	view.press_skill()
	_check(not view.tap_at(Vector2(360.0, CombatView.FIELD_TOP - 40.0)) and not battle.is_aiming() and strategist.skill_state == CombatUnit.SkillState.NONE, "Off-field tap while aiming: cancelled, nothing ordered")
	view.press_skill()
	var tapped := view.cell_at(Vector2(200.0, CombatView.FIELD_TOP + 50.0))
	_check(view.tap_at(Vector2(200.0, CombatView.FIELD_TOP + 50.0)) and strategist.skill_cell == tapped and strategist.skill_state == CombatUnit.SkillState.PENDING, "On-field tap while aiming: the wall ordered at %s" % str(tapped))
	var entry: Dictionary = view.get_skill_bar_entries().filter(func(e: Dictionary) -> bool: return e["owner"] == strategist)[0]
	_check(entry["title"] == "普通技能：冰牆　魔力 25" and entry["state"] == "接近位置", "View: 冰牆 approaching its location (%s)" % entry["text"])
	_check(battle.command_move(Vector2i(3, 0)) and strategist.skill_state == CombatUnit.SkillState.NONE and strategist.skill_cell == CombatUnit.NO_CELL and strategist.mp == strategist.max_mp, "A move cancels the pending wall for free")
	view.close()
	main.free()
	# Preparation: refused.
	var prep := CombatBattle.create_party(10, null, [Mercenary.create("merc_1", "MAGE")])
	prep.select_unit(prep.get_friends()[1])
	_check(not prep.start_skill_aim() and not prep.command_skill_at(Vector2i(10, 2)), "PREPARATION: ground Skills refused")
	# The caster dies while pending: cleared.
	var dies := _party_fight(["MAGE"], 10)
	var dying := dies.get_friends()[1]
	dies.select_unit(dying)
	dies.command_skill_at(Vector2i(40, 2))
	dies.resolve_damage(dies.get_enemies()[0], dying, 1000000)
	_check(dying.skill_state == CombatUnit.SkillState.NONE and dying.skill_cell == CombatUnit.NO_CELL and not dies.is_aiming(), "The caster dies while pending: the Skill ends with it")
	_sections_done.append("invalid")


# --- AC06 Dismissal countdown ---------------------------------------------------------------------------

func _verify_countdown() -> void:
	_clean()
	var main := await _new_main()
	var hub := main.get_node("CityHub") as CityHub
	await _enter_city(main)
	for type in ["MAGE", "GUARDIAN", "STRATEGIST"]:
		main.recruit_mercenary(type)
	main.set_mercenary_deployed("merc_1", true)
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	hub.show_mercenary_view(CityHub.MERCENARY_VIEW_ROSTER)
	await process_frame
	var money: int = main.wallet.get_balance()
	hub.get_dismiss_button("merc_1").pressed.emit()
	_check(not hub.is_dismiss_confirm_open() and hub.get_feedback_text() == "請先取消出戰，再解僱傭兵", "AC06 Deployed: refused before any countdown (must undeploy first)")
	var before := JSON.stringify(main.mercenary_roster.get_snapshot())
	hub.get_dismiss_button("merc_2").pressed.emit()
	var confirm := hub.get_dismiss_confirm_button()
	var cancel := hub.get_dismiss_cancel_button()
	_check(hub.is_dismiss_confirm_open() and confirm.text == "確定解僱（5）" and confirm.disabled and not cancel.disabled, "AC06 Opens at 確定解僱（5）, disabled; 取消 enabled")
	var shown := [confirm.text]
	for second in range(1, 5):
		hub.advance_dismiss_countdown(0.5)
		_check(confirm.text == "確定解僱（%d）" % (6 - second) and confirm.disabled, "AC06 %.1f s: still （%d）" % [second - 0.5, 6 - second])
		hub.advance_dismiss_countdown(0.5)
		shown.append(confirm.text)
		_check(confirm.text == "確定解僱（%d）" % (5 - second) and confirm.disabled and not cancel.disabled, "AC06 %d s: 確定解僱（%d）, disabled, 取消 enabled" % [second, 5 - second])
		confirm.pressed.emit()
		_check(main.mercenary_roster.get_mercenary("merc_2") != null and hub.is_dismiss_confirm_open(), "AC06 A press during the countdown dismisses nothing")
	hub.advance_dismiss_countdown(0.99)
	_check(confirm.text == "確定解僱（1）" and confirm.disabled and hub.get_dismiss_countdown() > 0.0, "AC06 4.99 s: still （1）")
	hub.advance_dismiss_countdown(0.01)
	shown.append(confirm.text)
	_check(confirm.text == "確定解僱" and not confirm.disabled and is_zero_approx(hub.get_dismiss_countdown()), "AC06 5 s: 確定解僱, enabled")
	_check(shown == ["確定解僱（5）", "確定解僱（4）", "確定解僱（3）", "確定解僱（2）", "確定解僱（1）", "確定解僱"], "AC06 The sequence （5）…（1） then 確定解僱 (%s)" % str(shown))
	# 取消 after the countdown; reopen restarts at 5.
	cancel.pressed.emit()
	_check(not hub.is_dismiss_confirm_open() and JSON.stringify(main.mercenary_roster.get_snapshot()) == before and main.wallet.get_balance() == money, "AC06 取消: closed, nothing changed")
	hub.get_dismiss_button("merc_2").pressed.emit()
	_check(confirm.text == "確定解僱（5）" and confirm.disabled and is_equal_approx(hub.get_dismiss_countdown(), 5.0), "AC06 Reopened: the countdown restarts at 5")
	# 取消 in the middle of the countdown.
	hub.advance_dismiss_countdown(2.2)
	_check(confirm.text == "確定解僱（3）", "2.2 s: （3）")
	cancel.pressed.emit()
	_check(not hub.is_dismiss_confirm_open() and main.mercenary_roster.get_mercenary("merc_2") != null, "AC06 取消 mid-countdown: closed, nothing changed")
	hub.advance_dismiss_countdown(10.0)
	hub.get_dismiss_button("merc_3").pressed.emit()
	_check(confirm.text == "確定解僱（5）" and hub.get_dismiss_confirm()["id"] == "merc_3", "AC06 Another Mercenary: its own fresh countdown (time while closed does not count)")
	cancel.pressed.emit()
	# The real frame clock drives it (_process).
	hub.get_dismiss_button("merc_2").pressed.emit()
	for frame in range(5):
		hub._process(1.0)
	_check(confirm.text == "確定解僱" and not confirm.disabled, "AC06 _process (frame time) runs the countdown: 5 x 1 s -> enabled")
	_delete_save()
	confirm.pressed.emit()
	confirm.pressed.emit()
	_check(main.mercenary_roster.get_mercenary("merc_2") == null and main.mercenary_roster.get_owned_count() == 2 and not hub.is_dismiss_confirm_open(), "AC06 確定解僱 after the countdown: dismissed once")
	_check(main.wallet.get_balance() == money and hub.get_feedback_text() == "已解僱守衛 #2", "AC06 No refund; 已解僱守衛 #2")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE)) if FileAccess.file_exists(TEST_SAVE) else null
	_check(saved != null and int(saved["version"]) == 12 and (saved["mercenaries"]["owned"] as Array).size() == 2, "AC06 Saved at once (v12, 2 owned)")
	await _destroy(main)
	main = await _new_main()
	_check(main.mercenary_roster.get_mercenary("merc_2") == null and main.mercenary_roster.get_owned_count() == 2 and main.mercenary_roster.is_deployed("merc_1"), "AC06 Permanent: still gone after a restart")
	await _destroy(main)
	_sections_done.append("countdown")


# --- Lifecycle in the real game -------------------------------------------------------------------------

func _verify_lifecycle() -> void:
	_clean()
	var main := await _new_main()
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "MAGE"), Mercenary.create("merc_2", "STRATEGIST")], ["merc_1", "merc_2"])
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	var hero_exp: int = main.progression.get_exp("hero")
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	var battle: CombatBattle = main.get_combat()
	var view := main.get_node("CombatView") as CombatView
	_check(battle != null and battle.get_friends().size() == 3, "World -> Encounter -> Combat: Hero + 法師 + 軍師")
	battle.advance(CombatConfig.PREPARATION_MS)
	var hero := battle.get_hero()
	var mage := battle.get_friends()[1]
	var strategist := battle.get_friends()[2]
	battle.select_unit(hero)
	_check(view.press_skill() and hero.skill_state == CombatUnit.SkillState.CASTING, "In game: 緩速 cast at once")
	battle.select_unit(mage)
	view.press_skill()
	_check(battle.is_aiming() and battle.tap(Vector2i(8, 2)) and mage.skill_cell == Vector2i(8, 2), "In game: 範圍攻擊 on a location")
	battle.select_unit(strategist)
	view.press_skill()
	_check(battle.is_aiming() and battle.tap(Vector2i(6, 0)) and strategist.skill_cell == Vector2i(6, 0), "In game: 冰牆 on a location")
	for step in range(150):
		battle.advance(10)
	await process_frame
	_check(battle.get_ice_walls().size() == 1 and battle.get_enemies().filter(func(e: CombatUnit) -> bool: return e.alive).all(func(e: CombatUnit) -> bool: return battle.get_slow_remaining(e) > 0 or not e.alive), "In game: the wall stands, the enemies slowed")
	# Basic regression: Select All + Move, Basic Attack target.
	_check(battle.select_all() and battle.command_move_selection(Vector2i(4, 2)), "Select All + Move still work")
	battle.select_unit(hero)
	_check(battle.command_target(battle.get_enemies()[0]) and hero.target == battle.get_enemies()[0], "Basic Attack target still works")
	for enemy in battle.get_enemies():
		battle.resolve_damage(hero, enemy, 1000000)
	_check(battle.get_phase() == CombatBattle.Phase.VICTORY, "Victory")
	await process_frame
	var exit := view.get_node("ExitButton") as Button
	_check(exit.visible, "Result: 返回世界")
	exit.pressed.emit()
	await _settle()
	_check(main.get_combat() == null and not view.visible, "Combat -> World")
	_check(main.progression.get_exp("hero") > hero_exp or main.progression.get_level("hero") > 1, "EXP settled for the Hero")
	_check(main.mercenary_roster.get_mercenary("merc_1").get_exp() > 0 and main.mercenary_roster.get_mercenary("merc_2").get_exp() > 0, "EXP settled for both Mercenaries")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE)) if FileAccess.file_exists(TEST_SAVE) else null
	_check(saved != null and int(saved["version"]) == 12, "Saved as v12")
	var snapshot := JSON.stringify(main.mercenary_roster.get_snapshot())
	await _destroy(main)
	main = await _new_main()
	_check(JSON.stringify(main.mercenary_roster.get_snapshot()) == snapshot, "Reload: the roster (EXP, deployment) is the same")
	await _destroy(main)
	_sections_done.append("lifecycle")


# --- Scope -------------------------------------------------------------------------------------------------

func _verify_scope() -> void:
	_check(SaveStore.VERSION == 12, "Save schema: still v12 (no version bump)")
	for path in ["res://scripts/save_store.gd", "res://scripts/main.gd", "res://scripts/mercenary_roster.gd", "res://scripts/mercenary.gd", "res://scripts/progression_state.gd"]:
		var code := _code_only(path).to_lower()
		_check(not code.contains("ice_wall") and not code.contains("countdown") and not code.contains("skill_at") and not code.contains("tab_touch"), "%s: nothing from this corrective (no save change)" % path.get_file())
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_config.gd", "res://scripts/combat_view.gd"]:
		var code := _code_only(path).to_lower()
		for word in ["terrain", "element", "pathfind", "astar", "navigation"]:
			_check(not code.contains(word), "%s has no %s system" % [path.get_file(), word])
	_check(CombatConfig.SKILL_MP_COST == 25 and CombatConfig.SKILL_CAST_MS == 1000 and CombatConfig.SKILL_COOLDOWN_MS == 8000 and CombatConfig.SKILL_EFFECT_MS == 5000 and CombatConfig.SLOW_FACTOR == 2 and CombatConfig.AOE_DAMAGE == 40, "No skill number changed")
	_check(CombatConfig.HERO_SKILL["range"] == 3 and CombatConfig.MERC_A_SKILL["range"] == 0 and CombatConfig.MERC_B_SKILL["range"] == 5 and CombatConfig.STRATEGIST_SKILL["range"] == 5 and CombatConfig.ICE_WALL_COLUMNS == 2, "Ranges unchanged; the wall is 2 columns")
	_check(RecruitmentService.PRICE == 1000, "Recruitment price untouched (1000)")
	_sections_done.append("scope")


# --- Stress (TARGETED) -------------------------------------------------------------------------------------

func _verify_stress() -> void:
	# 30 seeded battles: every Skill used whenever ready with random ground
	# cells (some off-grid), random aim / cancel; walls never entered while
	# standing, never left over after they melt, MP never below 0.
	var rng := RandomNumberGenerator.new()
	rng.seed = 8031
	var entered := 0
	var leftover := 0
	var negative := 0
	var walls_raised := 0
	var errors := 0
	for run in range(30):
		var battle := _party_fight(["MAGE", "STRATEGIST", "STRATEGIST"], 20)
		for friend in battle.get_friends():
			friend.max_hp = 100000
			friend.hp = 100000
		var raised := {}
		for tick in range(600):
			if battle.is_over():
				break
			if tick % 7 == 0:
				var unit: CombatUnit = battle.get_friends()[rng.randi_range(0, 3)]
				if unit.alive and battle.select_unit(unit):
					match rng.randi_range(0, 4):
						0:
							battle.start_skill_aim()
							battle.tap(Vector2i(rng.randi_range(-2, 62), rng.randi_range(-1, 5)))
						1:
							battle.start_skill_aim()
							battle.cancel_skill_aim()
						2:
							battle.command_skill_at(Vector2i(rng.randi_range(0, 60), rng.randi_range(0, 4)))
						3:
							battle.command_move(Vector2i(rng.randi_range(0, 60), rng.randi_range(0, 4)))
						4:
							battle.command_skill(battle.nearest_enemy(unit))
			battle.advance(50)
			for wall in battle.get_ice_walls():
				raised[wall["until_ms"]] = true
			for enemy in battle.get_enemies():
				if enemy.alive and enemy.next_cell != enemy.cell and battle.is_ice_wall_cell(enemy.next_cell):
					entered += 1
			for wall in battle.get_ice_walls():
				if int(wall["until_ms"]) <= battle.get_elapsed_ms():
					leftover += 1
			for friend in battle.get_friends():
				if friend.mp < 0:
					negative += 1
				if friend.skill_state == CombatUnit.SkillState.PENDING and friend.skill_target == null and friend.skill_cell == CombatUnit.NO_CELL:
					errors += 1
		walls_raised += raised.size()
	_check(walls_raised > 30, "Stress: walls were raised (%d)" % walls_raised)
	_check(entered == 0, "Stress: no enemy ever stepped onto a standing wall (%d)" % entered)
	_check(leftover == 0 and negative == 0 and errors == 0, "Stress: no expired wall left, no negative MP, no pending Skill without a place (%d / %d / %d)" % [leftover, negative, errors])
	# Countdown: 40 random open / wait / cancel / reopen rounds.
	_clean()
	var main := await _new_main()
	var hub := main.get_node("CityHub") as CityHub
	await _enter_city(main)
	main.recruit_mercenary("MAGE")
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	hub.show_mercenary_view(CityHub.MERCENARY_VIEW_ROSTER)
	await process_frame
	var bad := 0
	var current := "merc_1"
	for round in range(40):
		hub.get_dismiss_button(current).pressed.emit()
		if hub.get_dismiss_confirm_button().text != "確定解僱（5）" or not hub.get_dismiss_confirm_button().disabled:
			bad += 1
		var waited := 0.0
		for step in range(rng.randi_range(0, 8)):
			var dt := rng.randf_range(0.0, 1.2)
			waited += dt
			hub.advance_dismiss_countdown(dt)
			hub.get_dismiss_confirm_button().pressed.emit()
			var ready := waited >= CityHub.DISMISS_COUNTDOWN_SECONDS
			if hub.get_dismiss_confirm_button().disabled == ready:
				bad += 1
			if main.mercenary_roster.get_mercenary(current) == null:
				break
		if main.mercenary_roster.get_mercenary(current) == null:
			if waited < CityHub.DISMISS_COUNTDOWN_SECONDS:
				bad += 1
			main.wallet.add(RecruitmentService.PRICE)
			var recruited: Dictionary = main.recruit_mercenary("MAGE")
			if not recruited.get("success", false):
				bad += 1
				break
			current = recruited["mercenary_id"]
			hub.show_mercenary_view(CityHub.MERCENARY_VIEW_ROSTER)
			await process_frame
		elif hub.is_dismiss_confirm_open():
			hub.get_dismiss_cancel_button().pressed.emit()
	_check(bad == 0, "Stress: 40 countdown rounds: never enabled early, never dismissed early, always restarts at 5 (%d bad)" % bad)
	await _destroy(main)
	# Tabs: 40 random swipes / taps on Hero + 5.
	_clean()
	main = await _new_main()
	var roster := MercenaryRoster.new()
	for type in ["MAGE", "GUARDIAN", "STRATEGIST", "MAGE", "GUARDIAN"]:
		roster.create_mercenary(type)
	main.mercenary_roster = roster
	var panel := main.get_node("CharacterPanel") as CharacterPanel
	panel.open()
	await process_frame
	var origin := (panel.get_node("Panel/TabTouch") as Control).get_global_rect().position
	var snapshot := JSON.stringify(main.mercenary_roster.get_snapshot())
	var wrong := 0
	for round in range(40):
		var from := Vector2(rng.randf_range(20.0, 650.0), 36.0)
		if rng.randi_range(0, 1) == 0:
			var selected := panel.get_selected()
			var to := Vector2(clampf(from.x + rng.randf_range(-600.0, 600.0), 0.0, 670.0), 36.0)
			await _swipe(5, origin + from, origin + to)
			# (A move within TAB_DRAG_THRESHOLD is a tap by design.)
			if absf(to.x - from.x) > CharacterPanel.TAB_DRAG_THRESHOLD and panel.get_selected() != selected:
				print("STRESS swipe selected: ", from, " -> ", to, " ", selected, " -> ", panel.get_selected())
				wrong += 1
		else:
			var expected := panel.tab_at(from)
			await _tap(5, origin + from)
			if expected != "" and panel.get_selected() != expected:
				print("STRESS tap: ", from, " expected ", expected, " got ", panel.get_selected(), " scroll ", panel.get_tab_scroll())
				wrong += 1
	_check(wrong == 0 and JSON.stringify(main.mercenary_roster.get_snapshot()) == snapshot and panel.get_pending().is_empty(), "Stress: 40 swipes / taps: swipes never select, taps select the tab under the finger, nothing allocated (%d wrong)" % wrong)
	await _destroy(main)
	_sections_done.append("stress")


# --- Helpers -----------------------------------------------------------------------------------------------

## A battle of the Hero + the given Mercenary types in FIGHTING with only the
## first `alive` enemies alive.
func _party_fight(types: Array, enemies: int, alive: int = -1) -> CombatBattle:
	var mercenaries := []
	for index in range(types.size()):
		mercenaries.append(Mercenary.create("merc_%d" % (index + 1), types[index]))
	var battle := CombatBattle.create_party(enemies, null, mercenaries)
	battle.advance(CombatConfig.PREPARATION_MS)
	if alive >= 0:
		for index in range(alive, enemies):
			battle.resolve_damage(battle.get_hero(), battle.get_enemies()[index], 1000000)
	return battle


func _place(unit: CombatUnit, cell: Vector2i) -> void:
	unit.cell = cell
	unit.next_cell = cell
	unit.claim = cell
	unit.step_progress_ms = 0


func _on_damage(attacker: CombatUnit, target: CombatUnit, amount: int) -> void:
	_hits.append([attacker, target, amount])


func _touch(index: int, at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = root.get_final_transform() * at
	event.pressed = pressed
	root.push_input(event)
	await process_frame


func _drag(index: int, at: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = root.get_final_transform() * at
	root.push_input(event)
	await process_frame


## A finger swipe in 10 moves from `from` to `to`.
func _swipe(index: int, from: Vector2, to: Vector2) -> void:
	await _touch(index, from, true)
	for step in range(1, 11):
		await _drag(index, from.lerp(to, step / 10.0))
	await _touch(index, to, false)


func _tap(index: int, at: Vector2) -> void:
	await _touch(index, at, true)
	await _touch(index, at, false)


func _mouse(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = root.get_final_transform() * at
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(event)
	await process_frame


func _mouse_drag(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = root.get_final_transform() * at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(event)
	await process_frame


func _emulated_click(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.device = InputEvent.DEVICE_ID_EMULATION
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = root.get_final_transform() * at
	event.pressed = pressed
	root.push_input(event)
	await process_frame


func _clean() -> void:
	_delete_save()
	for n in range(1, 6):
		var backup := TEST_SAVE + SaveStore.BACKUP_SUFFIX + str(n)
		if FileAccess.file_exists(backup):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(backup))


func _delete_save() -> void:
	for p in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _enter_city(main: Node) -> void:
	(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
	await _settle()
	main.try_enter_city()
	await _settle()


func _new_main() -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	await _settle()
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


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
