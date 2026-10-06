extends SceneTree

## Stage 10 P03: Defeat -> nearest Hospital city safe return.
##   destination  WorldLayout.nearest_hospital_city: straight-line distance
##                from the encounter's world position to CITY_ANCHORS, only
##                Hospital cities (A / B; never C / D), deterministic A on a
##                tie, not the last visited city
##   trigger      DEFEAT only (VICTORY / RETREAT keep their flow)
##   condition    nothing healed or revived by the return
##   safe state   combat closed, encounter ended, City Hub open on 醫院 with
##                the reason, no new encounter underneath, save coherent
##   all-dead     Hero + every Mercenary dead -> returned, free Hero
##                treatment, leave, fight again (no restart)
##   economy      $0, no EXP / Level / equipment / goods / allocation change
##   persistence  save / reload keeps the city and the post-defeat condition
##   lifecycle    no stale view / lock / commit / removal / respawn
##   stress       FULL lifecycle: world -> encounter -> combat -> defeat /
##                victory / retreat -> Hospital -> recover -> depart, with
##                origins near A / B / C / D / ties, wallets, reloads

const TEST_SAVE := "user://s10_p03_defeat_test.json"
const T0 := 1800000000000
const A1 := "test_armor_01"
const PASSIVE_ONLY := Vector2(950.0, 1080.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _seed := 10300


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			_seed = int(arg.substr(7))
	_verify_destination()
	await _verify_trigger()
	await _verify_defeat_return()
	await _verify_all_dead()
	await _verify_persistence()
	await _verify_stress()
	_check(_sections_done.size() == 6, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S10 P03 defeat return verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Destination (pure) ------------------------------------------------------------------------------------

func _verify_destination() -> void:
	var a: Vector2 = WorldLayout.CITY_ANCHORS["A"]
	var b: Vector2 = WorldLayout.CITY_ANCHORS["B"]
	var c: Vector2 = WorldLayout.CITY_ANCHORS["C"]
	var d: Vector2 = WorldLayout.CITY_ANCHORS["D"]
	_check(WorldLayout.nearest_hospital_city(a + Vector2(900, 700)) == "A" and WorldLayout.nearest_hospital_city(Vector2(19000, 5000)) == "A", "1 Closer to A -> A")
	_check(WorldLayout.nearest_hospital_city(b + Vector2(-900, 700)) == "B" and WorldLayout.nearest_hospital_city(Vector2(21000, 5000)) == "B", "2 Closer to B -> B")
	_check(WorldLayout.nearest_hospital_city(c) == "A" and WorldLayout.nearest_hospital_city(c + Vector2(500, -300)) == "A", "3 Right at City C (no Hospital): A, the nearest Hospital city")
	_check(WorldLayout.nearest_hospital_city(d) == "B" and WorldLayout.nearest_hospital_city(d + Vector2(-500, -300)) == "B", "4 Right at City D (no Hospital): B")
	var tie := Vector2((a.x + b.x) / 2.0, 30000.0)
	_check(is_equal_approx(tie.distance_to(a), tie.distance_to(b)) and WorldLayout.nearest_hospital_city(tie) == "A" and WorldLayout.nearest_hospital_city(tie) == WorldLayout.nearest_hospital_city(tie), "5 An exact A / B tie: A (the first Hospital city), every time")
	_check(WorldLayout.nearest_hospital_city(null) == "" and WorldLayout.nearest_hospital_city(Vector2(INF, 0)) == "" and WorldLayout.nearest_hospital_city("A") == "", "No finite position: \"\" (the caller keeps its safe default)")
	# Exhaustive grid: always A or B, always the nearer one (never C / D).
	var wrong := 0
	for x in range(0, 40001, 2000):
		for y in range(0, 40001, 2000):
			var p := Vector2(x, y)
			var got := WorldLayout.nearest_hospital_city(p)
			var expected := "A" if p.distance_squared_to(a) <= p.distance_squared_to(b) else "B"
			if got != expected or not WorldLayout.city_has_hospital(got):
				wrong += 1
	_check(wrong == 0, "8 Over the whole 40K world (441 points): always the nearest Hospital city, never C / D (%d)" % wrong)
	_sections_done.append("destination")


# --- Trigger: DEFEAT only ---------------------------------------------------------------------------------

func _verify_trigger() -> void:
	var main := await _game(["GUARDIAN"], 1000)
	# 10 VICTORY.
	var battle: CombatBattle = await _start_battle(main)
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000000)
	await _exit_battle(main)
	_check(main.location.is_in_world() and main.get_last_defeat_return_city() == "" and not (main.get_node("CityHub") as CityHub).visible, "10 VICTORY: back in the world as before, no Hospital return")
	# 11 RETREAT.
	await _respawn(main)
	battle = await _start_battle(main)
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.start_retreat()
	for step in range(600):
		if battle.is_over():
			break
		battle.advance(50)
	_check(battle.get_phase() == CombatBattle.Phase.RETREAT, "RETREAT")
	await _exit_battle(main)
	_check(main.location.is_in_world() and main.get_last_defeat_return_city() == "", "11 RETREAT: back in the world, no Hospital return")
	# 12 An unfinished battle: the exit button commits nothing.
	await _respawn(main)
	battle = await _start_battle(main)
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()
	_check(main.get_combat() == battle and not battle.is_over() and main.location.is_in_world(), "12 No result yet: no commit, no return")
	await _destroy(main)
	_clean()
	_sections_done.append("trigger")


# --- Defeat return --------------------------------------------------------------------------------------------

func _verify_defeat_return() -> void:
	var main := await _game(["GUARDIAN", "GUARDIAN", "MAGE"], 777)
	var c: CharacterCondition = main.condition
	main.mercenary_roster.set_deployment(["merc_1", "merc_2"])
	main.carrying.add_equipment("merc_1", A1, 1)
	EquipmentService.equip(main.carrying, "merc_1", A1)
	c.sync()
	var merc_3 := c.get_condition("merc_3")
	var other := _other_state(main)
	# Visit B first (the last city), then lose near A.
	main.location.enter_city("B")
	main.location.leave_city()
	main._show_world()
	await _settle()
	var battle: CombatBattle = await _start_battle(main)
	var context: EncounterContext = main.get_node("EncounterSession").get_context()
	var origin := context.player_world_position
	_check(origin.distance_to(WorldLayout.CITY_ANCHORS["A"]) < origin.distance_to(WorldLayout.CITY_ANCHORS["B"]), "The encounter caught the player near A (%s)" % str(origin))
	battle.advance(CombatConfig.PREPARATION_MS)
	# Hurt the Hero, kill 守衛 #1, leave 守衛 #2 hurt with spent MP, then lose.
	battle.resolve_damage(battle.get_enemies()[0], battle.get_hero(), 40)
	battle.get_hero().mp = 17
	battle.resolve_damage(battle.get_enemies()[0], _friend(battle, "merc_1"), 1000000)
	battle.resolve_damage(battle.get_enemies()[0], _friend(battle, "merc_2"), 33)
	_friend(battle, "merc_2").mp = 4
	var finals := {}
	for unit in battle.get_friends():
		finals[unit.id] = [unit.hp, unit.mp, unit.alive]
	# The last blows: everyone still standing falls (a DEFEAT).
	for unit in battle.get_friends():
		if unit.alive:
			battle.resolve_damage(battle.get_enemies()[0], unit, 1000000)
			finals[unit.id] = [0, unit.mp, false]
	_check(battle.get_phase() == CombatBattle.Phase.DEFEAT, "DEFEAT")
	var money: int = main.wallet.get_balance()
	var monsters: int = main._world_monsters.size()
	await _exit_battle(main)
	var hub := main.get_node("CityHub") as CityHub
	_check(main.get_last_defeat_return_city() == "A" and main.location.is_in_city() and main.current_city_id == "A", "1 / 7 / 9 / 23 DEFEAT near A -> City A (not the last visited B)")
	_check(main.get_combat() == null and not (main.get_node("CombatView") as CombatView).is_open(), "20 / 46 Combat closed, no stale view")
	_check((main.get_node("EncounterSession") as EncounterSession).get_phase() == EncounterSession.Phase.NONE and (main.get_node("EncounterSession") as EncounterSession).get_context() == null, "21 / 47 The encounter ended (no lock, no context)")
	_check(not (main.get_node("Actors/Player") as Player).is_physics_processing(), "22 The player no longer moves in the world")
	_check(hub.visible and hub.get_facility() == CityHub.FACILITY_HOSPITAL and hub.has_hospital() and main.can_use_hospital(), "24 / 25 The City Hub is open on 醫院")
	_check(hub.get_feedback_text() == "戰敗，已返回最近的醫院城市：A 城", "The reason is shown: %s" % hub.get_feedback_text())
	# 13-19 Nothing healed or revived.
	_check(c.get_hp("hero") == 0 and c.is_dead("hero") and c.get_mp("hero") == finals["hero"][1], "13 / 14 / 17 The Hero arrives as it fell (dead, MP %d)" % finals["hero"][1])
	_check(c.is_dead("merc_1") and c.is_dead("merc_2") and c.get_mp("merc_2") == 4, "15 / 16 / 17 守衛 #1 / #2 arrive dead with their MP; no revival")
	_check(c.get_condition("merc_3") == merc_3, "法師 #3 (not in the battle) unchanged")
	# 34-40 Economy.
	_check(main.wallet.get_balance() == money and money == 777, "34 / 35 The return cost $0")
	_check(_other_state(main) == other, "36-40 No EXP / Level / equipment / goods / allocation / roster change")
	# 48-50 Lifecycle.
	_check(not main.commit_battle_result(battle.get_result()) and main.current_city_id == "A", "48 A second commit is refused (still in A)")
	_check(main._world_monsters.size() == monsters and not main._group_respawn.is_scheduled(WorldLayout.PROTOTYPE_MONSTER_ID), "49 / 50 DEFEAT removes no group and schedules no respawn (unchanged rule)")
	# 26 No encounter under the hub.
	main.time_source.advance_ms(120000)
	for frame in range(30):
		await physics_frame
	_check(main.location.is_in_city() and (main.get_node("EncounterSession") as EncounterSession).get_phase() == EncounterSession.Phase.NONE and main.get_combat() == null, "26 Two minutes in the city: no encounter underneath")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(saved["version"]) == 14 and saved["location"]["mode"] == "IN_CITY" and saved["location"]["city_id"] == "A" and saved["condition"]["hero"]["dead"] == true, "Saved at once (v14): IN_CITY A, the Hero dead")
	await _destroy(main)
	# 2 Near B (the encounter's world position is B's side of the world).
	main = await _game(["GUARDIAN"], 500)
	main.mercenary_roster.set_deployment(["merc_1"])
	battle = await _start_battle(main)
	(main.get_node("EncounterSession") as EncounterSession).get_context().player_world_position = WorldLayout.CITY_ANCHORS["B"] + Vector2(-3000, 2500)
	await _lose(main, battle)
	_check(main.get_last_defeat_return_city() == "B" and main.current_city_id == "B" and (main.get_node("CityHub") as CityHub).get_feedback_text() == "戰敗，已返回最近的醫院城市：B 城", "2 DEFEAT near B -> City B")
	await _destroy(main)
	# 3 / 4 Nearer to C / D (no Hospital).
	for corner in [["C", "A"], ["D", "B"]]:
		main = await _game([], 0)
		battle = await _start_battle(main)
		(main.get_node("EncounterSession") as EncounterSession).get_context().player_world_position = WorldLayout.CITY_ANCHORS[corner[0]] + Vector2(300, -300) * (1 if corner[0] == "C" else -1)
		await _lose(main, battle)
		_check(main.current_city_id == corner[1], "3 / 4 DEFEAT beside City %s (no Hospital) -> %s" % corner)
		await _destroy(main)
	# 5 Tie.
	main = await _game([], 0)
	battle = await _start_battle(main)
	(main.get_node("EncounterSession") as EncounterSession).get_context().player_world_position = Vector2(20000.0, 25000.0)
	await _lose(main, battle)
	_check(main.current_city_id == "A", "5 An exact A / B tie -> A")
	await _destroy(main)
	# 32 / 33 Hero dead, Mercenary alive: the battle goes on; if lost -> same path.
	main = await _game(["GUARDIAN"], 0)
	main.mercenary_roster.set_deployment(["merc_1"])
	main.condition.sync()
	battle = await _start_battle(main)
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.resolve_damage(battle.get_enemies()[0], battle.get_hero(), 1000000)
	_check(battle.get_phase() == CombatBattle.Phase.FIGHTING, "32 The Hero's death alone does not end the battle")
	battle.resolve_damage(battle.get_enemies()[0], _friend(battle, "merc_1"), 1000000)
	await _exit_battle(main)
	_check(main.current_city_id == "A" and main.condition.is_dead("hero"), "32 ... the DEFEAT then takes the same safe return")
	var status: Dictionary = main.get_recovery_status()
	_check(status["hero"]["price"] == 0 and status["mercenaries"][0]["price"] == 100, "33 Hospital prices unchanged: Hero $0, Mercenary $100")
	await _destroy(main)
	_clean()
	_sections_done.append("defeat_return")


# --- All dead: the old soft-lock --------------------------------------------------------------------------------

func _verify_all_dead() -> void:
	var main := await _game(["GUARDIAN", "MAGE"], 0)
	main.mercenary_roster.set_deployment(["merc_1", "merc_2"])
	var c: CharacterCondition = main.condition
	c.sync()
	for id in ["hero", "merc_1", "merc_2"]:
		c.set_condition(id, 0, 0)
	# Every character dead: the next encounter is a DEFEAT at once (P00).
	var battle: CombatBattle = await _start_battle(main)
	_check(battle != null and battle.get_phase() == CombatBattle.Phase.DEFEAT, "27 Everyone dead: the encounter's battle is a DEFEAT at once")
	await _exit_battle(main)
	var hub := main.get_node("CityHub") as CityHub
	_check(main.current_city_id == "A" and hub.get_facility() == CityHub.FACILITY_HOSPITAL, "27 / 28 / 29 Returned to City A's 醫院 — no walking, no restart")
	_check(c.is_dead("hero") and c.is_dead("merc_1") and c.is_dead("merc_2"), "Nobody revived by the return")
	hub.get_hospital_hero_button().pressed.emit()
	await process_frame
	_check(not c.is_dead("hero") and c.get_hp("hero") == c.get_condition("hero")["max_hp"] and main.wallet.get_balance() == 0, "30 免費治療 at $0: the Hero is back")
	_check(main.leave_city(), "31 The player leaves the city as usual")
	await _settle()
	# The Mercenaries are still dead (unpaid): the Hero fights alone.
	await _respawn(main)
	battle = await _start_battle(main)
	_check(battle != null and battle.get_phase() == CombatBattle.Phase.PREPARATION and battle.get_hero().alive and battle.get_friends().size() == 1, "31 ... and fights again (the dead Mercenaries stay out)")
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000000)
	await _exit_battle(main)
	_check(main.location.is_in_world() and main.get_last_defeat_return_city() == "", "51 A victory afterwards keeps the normal flow")
	await _destroy(main)
	_clean()
	_sections_done.append("all_dead")


# --- Persistence ------------------------------------------------------------------------------------------------

func _verify_persistence() -> void:
	var main := await _game(["GUARDIAN"], 450)
	main.mercenary_roster.set_deployment(["merc_1"])
	main.condition.sync()
	var battle: CombatBattle = await _start_battle(main)
	battle.advance(CombatConfig.PREPARATION_MS)
	battle.get_hero().mp = 11
	await _lose(main, battle)
	var state := _condition_state(main)
	var other := _other_state(main)
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	var hub := main.get_node("CityHub") as CityHub
	_check(main.location.is_in_city() and main.current_city_id == "A" and hub.visible and hub.has_hospital(), "41 / 44 Reload: still in City A, the Hospital available")
	_check(_condition_state(main) == state and main.condition.is_dead("hero") and main.condition.get_mp("hero") == 11, "42 The post-defeat condition survives the reload")
	_check(main.wallet.get_balance() == 450 and _other_state(main) == other, "43 Money and everything else unchanged")
	hub.show_facility(CityHub.FACILITY_HOSPITAL)
	hub.get_hospital_hero_button().pressed.emit()
	await process_frame
	_check(not main.condition.is_dead("hero") and main.wallet.get_balance() == 450, "45 The Hero recovers for free after the reload")
	await _destroy(main)
	_clean()
	_sections_done.append("persistence")


# --- Stress (FULL lifecycle) ------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var wrong_city := 0
	var healed := 0
	var hero_charged := 0
	var transport_charged := 0
	var stale := 0
	var duplicate := 0
	var city_encounter := 0
	var identity := 0
	var other_bad := 0
	var save_bad := 0
	var stuck := 0
	var outcomes := {"VICTORY": 0, "DEFEAT": 0, "RETREAT": 0}
	var returns := {"A": 0, "B": 0}
	var origins := [Vector2(950.0, 1080.0), WorldLayout.CITY_ANCHORS["B"] + Vector2(-2000, 1500), WorldLayout.CITY_ANCHORS["C"] + Vector2(800, -800), WorldLayout.CITY_ANCHORS["D"] + Vector2(-800, -800), Vector2(20000.0, 20000.0), Vector2(19999.0, 3000.0), Vector2(20001.0, 3000.0)]
	var wallets := [0, 50, 100, 250, 1000]
	_clean()
	var main := await _game(["GUARDIAN", "GUARDIAN", "MAGE"], 1000)
	for cycle in range(90):
		var c: CharacterCondition = main.condition
		# In the world, a random deployment and money.
		if main.location.is_in_city():
			main.leave_city()
			await _settle()
		var owned := ["merc_1", "merc_2", "merc_3"]
		var deployed := []
		for id in owned:
			if rng.randi_range(0, 1) == 0:
				deployed.append(id)
		main.mercenary_roster.set_deployment(deployed)
		main.wallet.spend(main.wallet.get_balance())
		var amount: int = wallets[rng.randi_range(0, wallets.size() - 1)]
		if amount > 0:
			main.wallet.add(amount)
		await _respawn(main)
		var battle: CombatBattle = await _start_battle(main)
		if battle == null:
			stuck += 1
			continue
		var context: EncounterContext = (main.get_node("EncounterSession") as EncounterSession).get_context()
		var origin: Vector2 = origins[rng.randi_range(0, origins.size() - 1)]
		context.player_world_position = origin
		if not battle.is_over():
			battle.advance(CombatConfig.PREPARATION_MS)
			for hit in range(rng.randi_range(0, 4)):
				var living := battle.get_friends().filter(func(u: CombatUnit) -> bool: return u.alive)
				if living.is_empty() or battle.is_over():
					break
				battle.resolve_damage(battle.get_enemies()[0], living[rng.randi_range(0, living.size() - 1)], rng.randi_range(1, 400))
			match rng.randi_range(0, 3):
				0:
					for enemy in battle.get_enemies():
						var shooter := battle.get_friends().filter(func(u: CombatUnit) -> bool: return u.alive)
						if shooter.is_empty() or battle.is_over():
							break
						battle.resolve_damage(shooter[0], enemy, 1000000)
				1:
					battle.start_retreat()
					for tick in range(600):
						if battle.is_over():
							break
						battle.advance(50)
				_:
					for unit in battle.get_friends():
						if unit.alive and not battle.is_over():
							battle.resolve_damage(battle.get_enemies()[0], unit, 1000000)
		if not battle.is_over():
			# A retreat that could not finish: lose instead.
			for unit in battle.get_friends():
				if unit.alive and not battle.is_over():
					battle.resolve_damage(battle.get_enemies()[0], unit, 1000000)
		var outcome: String = CombatBattle.Phase.keys()[battle.get_phase()]
		outcomes[outcome] += 1
		var finals := {}
		for unit in battle.get_friends():
			finals[unit.id] = [unit.hp if unit.alive else 0, unit.mp]
		var untouched := {}
		for id in c.get_character_ids():
			if not finals.has(id):
				untouched[id] = c.get_condition(id)
		var money: int = main.wallet.get_balance()
		var other := _other_state_no_exp(main)
		await _exit_battle(main)
		if main.get_combat() != null or (main.get_node("EncounterSession") as EncounterSession).get_phase() != EncounterSession.Phase.NONE or (main.get_node("CombatView") as CombatView).is_open():
			stale += 1
		if not main.commit_battle_result(battle.get_result()) == false:
			duplicate += 1
		if outcome == "DEFEAT":
			var expected := WorldLayout.nearest_hospital_city(origin)
			if main.get_last_defeat_return_city() != expected or main.current_city_id != expected or not main.location.is_in_city() or not main.can_use_hospital():
				wrong_city += 1
			if expected != "":
				returns[expected] += 1
			if main.wallet.get_balance() != money:
				transport_charged += 1
		elif main.get_last_defeat_return_city() != "" or not main.location.is_in_world():
			wrong_city += 1
		for id in finals:
			if [c.get_hp(id), c.get_mp(id)] != finals[id]:
				healed += 1
		for id in untouched:
			if c.get_condition(id) != untouched[id]:
				identity += 1
		if outcome != "VICTORY" and _other_state_no_exp(main) != other:
			other_bad += 1
		# No encounter while in the city.
		if main.location.is_in_city():
			main.time_source.advance_ms(30000)
			for frame in range(6):
				await physics_frame
			if (main.get_node("EncounterSession") as EncounterSession).get_phase() != EncounterSession.Phase.NONE:
				city_encounter += 1
			# Hospital: Hero free, then some Mercenaries if affordable.
			var hub := main.get_node("CityHub") as CityHub
			hub.show_facility(CityHub.FACILITY_HOSPITAL)
			if rng.randi_range(0, 3) != 0 and RecoveryService.needs_recovery(c.get_condition("hero")):
				var before_money: int = main.wallet.get_balance()
				hub.get_hospital_hero_button().pressed.emit()
				await process_frame
				if main.wallet.get_balance() != before_money or c.is_dead("hero"):
					hero_charged += 1
			var chosen := []
			for id in ["merc_1", "merc_2", "merc_3"]:
				if RecoveryService.needs_recovery(c.get_condition(id)) and rng.randi_range(0, 1) == 0 and (chosen.size() + 1) * 100 <= main.wallet.get_balance():
					chosen.append(id)
			if not chosen.is_empty():
				main.hospital_recover(chosen)
		# Save -> reload now and then.
		if cycle % 6 == 5:
			main._save_session()
			var state := [_condition_state(main), main.location.to_dict(), main.wallet.get_balance()]
			await _destroy(main)
			main = await _new_main(TEST_SAVE)
			if [_condition_state(main), main.location.to_dict(), main.wallet.get_balance()] != state:
				save_bad += 1
		# A dead Hero must still get back into the loop: recover it if needed.
		if main.location.is_in_city() and main.condition.is_dead("hero"):
			main.hospital_recover_hero()
			if main.condition.is_dead("hero"):
				stuck += 1
	print("Stress summary (seed %d): outcomes %s, returns %s, wrong_city %d, healed %d, hero_charged %d, transport_charged %d, stale %d, duplicate %d, city_encounter %d, identity %d, other %d, save %d, stuck %d" % [_seed, str(outcomes), str(returns), wrong_city, healed, hero_charged, transport_charged, stale, duplicate, city_encounter, identity, other_bad, save_bad, stuck])
	_check(outcomes["DEFEAT"] > 20 and outcomes["VICTORY"] > 5 and outcomes["RETREAT"] > 10 and returns["A"] > 8 and returns["B"] > 5, "Stress coverage: %s, returns %s" % [str(outcomes), str(returns)])
	_check(wrong_city == 0, "Stress: DEFEAT -> always the nearest Hospital city; other results never return (%d)" % wrong_city)
	_check(healed == 0, "Stress: no automatic healing / revival by the return (%d)" % healed)
	_check(hero_charged == 0, "Stress: the Hero's Hospital treatment always free and effective (%d)" % hero_charged)
	_check(transport_charged == 0, "Stress: the return never costs money (%d)" % transport_charged)
	_check(stale == 0 and duplicate == 0, "Stress: no stale battle / lock / view, no second commit (%d / %d)" % [stale, duplicate])
	_check(city_encounter == 0, "Stress: no encounter while in the city (%d)" % city_encounter)
	_check(identity == 0, "Stress: characters outside the battle never changed (%d)" % identity)
	_check(other_bad == 0, "Stress: no equipment / goods / allocation / roster change by DEFEAT / RETREAT (%d)" % other_bad)
	_check(save_bad == 0, "Stress: save -> reload keeps the city, condition and money (%d)" % save_bad)
	_check(stuck == 0, "Stress: the player always gets back into the loop (%d)" % stuck)
	await _destroy(main)
	_clean()
	_sections_done.append("stress")


# --- Helpers ----------------------------------------------------------------------------------------------------

func _game(types: Array, money: int) -> Node2D:
	_clean()
	var main := await _new_main(TEST_SAVE)
	var mercs := []
	for i in range(types.size()):
		mercs.append(Mercenary.create("merc_%d" % (i + 1), types[i]))
	main.mercenary_roster = MercenaryRoster.build(mercs, [])
	main.condition.sync()
	main.wallet.spend(main.wallet.get_balance())
	if money > 0:
		main.wallet.add(money)
	return main


func _lose(main: Node, battle: CombatBattle) -> void:
	if not battle.is_over():
		battle.advance(CombatConfig.PREPARATION_MS)
		for unit in battle.get_friends():
			if unit.alive and not battle.is_over():
				battle.resolve_damage(battle.get_enemies()[0], unit, 1000000)
	await _exit_battle(main)


func _exit_battle(main: Node) -> void:
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()


func _start_battle(main: Node) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	return main.get_combat()


func _respawn(main: Node) -> void:
	main.time_source.advance_ms(60000)
	await _settle()
	main.time_source.advance_ms(60000)
	await _settle()


func _friend(battle: CombatBattle, id: String) -> CombatUnit:
	for unit in battle.get_friends():
		if unit.id == id:
			return unit
	return null


func _condition_state(main: Node) -> String:
	var parts := []
	for id in main.condition.get_character_ids():
		parts.append([id, main.condition.get_condition(id)])
	return JSON.stringify(parts)


func _other_state(main: Node) -> String:
	return JSON.stringify([main.progression.to_dict(), _other_state_no_exp(main)])


## Equipment, goods, allocation, roster ids / deployment, money-free state.
func _other_state_no_exp(main: Node) -> String:
	var roster := []
	for m in main.mercenary_roster.get_owned():
		roster.append([m.get_id(), m.get_type(), m.get_allocation_points()])
	var parts := [roster, main.mercenary_roster.get_deployed_ids(), main.character_stats.get_allocation_points(), main.inventory.get_items(), main.market.get_snapshot(), main.warehouses.get_snapshot()]
	for id in main.condition.get_character_ids():
		var equipment: CharacterEquipment = main.carrying.get_equipment(id)
		parts.append([id, equipment.get_equipped_items(), equipment.get_carried()])
	return JSON.stringify(parts)


func _clean() -> void:
	for p in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


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


func _settle() -> void:
	for frame in range(4):
		await physics_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
