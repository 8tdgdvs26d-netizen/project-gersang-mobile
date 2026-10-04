extends SceneTree

## Stage 8 P02: Mercenary Center & Recruitment (傭兵中心與招聘).
##   service   守衛 / 法師 / 軍師 at $1,000 each; exact deduction; new Lv1
##             instances with unique ids; duplicate types; 5 owned at most;
##             $999 / full / invalid type refused with nothing changed; a
##             failed roster add or save restores money, roster and
##             next_serial exactly (no id used up)
##   game      the City Hub's fourth facility; rows, price, held count and
##             owned list; immediate save; restart persistence; save failure,
##             $999, full and rapid presses through the real buttons
##   layout    four facility tabs and the center fit the 720 x 1280 layout
##   + scope   Save v11, no combat change; seeded stress
## Real main scene, fixed TimeSource.

const TEST_SAVE := "user://p02_recruitment_test_save.json"
const BAD_SAVE := "user://p02_missing_dir/save.json"
const T0 := 1800000000000
const TYPES := ["GUARDIAN", "MAGE", "STRATEGIST"]
const NAMES := {"GUARDIAN": "守衛", "MAGE": "法師", "STRATEGIST": "軍師"}

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_rules()
	_verify_service()
	_verify_failures()
	_verify_rollback()
	await _verify_game()
	await _verify_game_failures()
	await _verify_layout()
	_verify_scope()
	_verify_stress()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 9, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("P02 mercenary recruitment verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Rules -------------------------------------------------------------------------------------------

func _verify_rules() -> void:
	_check(RecruitmentService.PRICE == 1000, "AC03 Price $1,000")
	_check(RecruitmentService.TYPES == TYPES and RecruitmentService.TYPE_NAMES == NAMES, "AC02 守衛 / 法師 / 軍師 (GUARDIAN / MAGE / STRATEGIST)")
	_check(RecruitmentService.ROLE_TEXT == {"GUARDIAN": "近戰防守型", "MAGE": "遠程法術型", "STRATEGIST": "戰場控制型"}, "Short role lines")
	for type in TYPES:
		var hint: String = RecruitmentService.HINT_TEXT[type]
		var digits := RegEx.new()
		digits.compile("[0-9]")
		_check(digits.search(hint) == null and not hint.contains("冰") and not hint.contains("魔力"), "%s hint holds no numbers / skill details (%s)" % [type, hint])
	_check(not NAMES.values().has("守護"), "守衛, not the old 守護")
	_sections_done.append("rules")


# --- Service: success ---------------------------------------------------------------------------------

func _verify_service() -> void:
	var wallet := _wallet(5000)
	var roster := MercenaryRoster.new()
	var expected_ids := ["merc_1", "merc_2", "merc_3"]
	for index in range(3):
		var result := RecruitmentService.recruit(wallet, roster, TYPES[index], func() -> bool: return true)
		_check(result["success"] and result["reason"] == "" and result["mercenary_id"] == expected_ids[index] and result["type"] == TYPES[index] and result["price"] == 1000, "Recruit %s: success, id %s" % [NAMES[TYPES[index]], expected_ids[index]])
		_check(wallet.get_balance() == 5000 - 1000 * (index + 1), "AC04 Exactly $1,000 paid (%d left)" % wallet.get_balance())
		var mercenary := roster.get_mercenary(expected_ids[index])
		_check(mercenary != null and mercenary.get_type() == TYPES[index] and mercenary.get_level() == 1 and mercenary.get_exp() == 0 and mercenary.get_allocation_points() == CharacterStats.zero_allocation(), "AC05 A new Lv1 %s, 0 EXP, no points" % TYPES[index])
	_check(roster.get_owned_count() == 3 and roster.get_deployed_ids().is_empty(), "3 owned, nothing deployed (deployment is P03)")
	# Exactly $1,000.
	var exact := _wallet(1000)
	var exact_roster := MercenaryRoster.new()
	_check(RecruitmentService.recruit(exact, exact_roster, "STRATEGIST")["success"] and exact.get_balance() == 0 and exact_roster.get_owned_count() == 1, "Exactly $1,000: recruited, $0 left")
	# Duplicate types.
	var mages := MercenaryRoster.new()
	var mage_wallet := _wallet(10000)
	for index in range(3):
		RecruitmentService.recruit(mage_wallet, mages, "MAGE")
	var ids := mages.get_owned().map(func(m: Mercenary) -> String: return m.get_id())
	_check(mages.get_owned_count() == 3 and mages.get_owned().all(func(m: Mercenary) -> bool: return m.get_type() == "MAGE") and ids == ["merc_1", "merc_2", "merc_3"], "AC08/AC09 Mage + Mage + Mage: three instances, ids %s" % str(ids))
	# Up to 5.
	_check(RecruitmentService.recruit(mage_wallet, mages, "GUARDIAN")["success"] and RecruitmentService.recruit(mage_wallet, mages, "MAGE")["success"] and mages.get_owned_count() == 5 and mage_wallet.get_balance() == 5000, "AC10 4 -> 5 owned")
	_check(RecruitmentService.label(mages.get_mercenary("merc_2")) == "法師 #2" and RecruitmentService.label(Mercenary.create("merc_a", "GUARDIAN")) == "守衛 merc_a", "Labels: 法師 #2 (a legacy-style id is shown as is)")
	_sections_done.append("service")


# --- Service: refusals (nothing changes) ---------------------------------------------------------------

func _verify_failures() -> void:
	# $999.
	var poor := _wallet(999)
	var roster := MercenaryRoster.new()
	var before := _state(poor, roster)
	var result := RecruitmentService.recruit(poor, roster, "MAGE", func() -> bool: return true)
	_check(not result["success"] and result["reason"] == RecruitmentService.ERR_INSUFFICIENT_FUNDS and _state(poor, roster) == before, "AC12/AC13 $999: refused (金錢不足), money / roster / next_serial unchanged")
	# 5 / 5.
	var full_wallet := _wallet(9000)
	var full := MercenaryRoster.new()
	for index in range(5):
		RecruitmentService.recruit(full_wallet, full, TYPES[index % 3])
	before = _state(full_wallet, full)
	result = RecruitmentService.recruit(full_wallet, full, "GUARDIAN", func() -> bool: return true)
	_check(not result["success"] and result["reason"] == RecruitmentService.ERR_ROSTER_FULL and _state(full_wallet, full) == before and full_wallet.get_balance() == 4000, "AC11 5 / 5: refused (人數已達上限), money / roster / next_serial unchanged")
	# Invalid types.
	var wallet := _wallet(5000)
	var empty := MercenaryRoster.new()
	before = _state(wallet, empty)
	for bad in ["WARRIOR", "mage", "Mage", "", "HERO", "守衛", null, 3, ["MAGE"]]:
		var refused := RecruitmentService.recruit(wallet, empty, bad, func() -> bool: return true)
		_check(not refused["success"] and refused["reason"] == RecruitmentService.ERR_INVALID_TYPE and _state(wallet, empty) == before, "AC16 Invalid type %s refused, nothing changes" % str(bad))
	_check(RecruitmentService.recruit(null, empty, "MAGE")["reason"] == RecruitmentService.ERR_INVALID_STATE and RecruitmentService.recruit(wallet, null, "MAGE")["reason"] == RecruitmentService.ERR_INVALID_STATE and _state(wallet, empty) == before, "No wallet / roster: refused, no crash")
	# Order: invalid type before full before money.
	_check(RecruitmentService.recruit(_wallet(0), full, "X")["reason"] == RecruitmentService.ERR_INVALID_TYPE and RecruitmentService.recruit(_wallet(0), full, "MAGE")["reason"] == RecruitmentService.ERR_ROSTER_FULL, "Checks in order: type, capacity, money")
	_sections_done.append("failures")


# --- Service: rollback after the payment ------------------------------------------------------------------

func _verify_rollback() -> void:
	# AC15: $5,000, empty roster, recruit Mage, the save fails.
	var wallet := _wallet(5000)
	var roster := MercenaryRoster.new()
	var calls := []
	var result := RecruitmentService.recruit(wallet, roster, "MAGE", func() -> bool:
		calls.append([wallet.get_balance(), roster.get_owned_count()])
		return false)
	_check(calls == [[4000, 1]], "During the save: $4,000 paid and 1 owned (what would be written)")
	_check(not result["success"] and result["reason"] == RecruitmentService.ERR_SAVE_FAILED and result["mercenary_id"] == "", "Save failed: refused (無法儲存，招聘已取消)")
	_check(wallet.get_balance() == 5000 and roster.get_owned_count() == 0 and roster.get_next_serial() == 1, "AC15 Rolled back: $5,000, 0 owned, next_serial 1")
	var next := RecruitmentService.recruit(wallet, roster, "MAGE", func() -> bool: return true)
	_check(next["success"] and next["mercenary_id"] == "merc_1" and wallet.get_balance() == 4000, "AC14 The next recruit gets merc_1: the failed one used up no id")
	# A failed save with history: exact roster restored (instances, deployment,
	# next_serial, retired ids).
	var busy := MercenaryRoster.new()
	var busy_wallet := _wallet(10000)
	for type in ["GUARDIAN", "MAGE", "STRATEGIST"]:
		RecruitmentService.recruit(busy_wallet, busy, type)
	busy.remove("merc_2")
	busy.add(Mercenary.create("merc_a", "GUARDIAN"))
	busy.remove("merc_a")
	busy.get_mercenary("merc_1").add_exp(300)
	busy.get_mercenary("merc_1").allocate({"hp": 2})
	busy.set_deployment(["merc_3", "merc_1"])
	var snapshot := JSON.stringify(busy.to_dict())
	var money := busy_wallet.get_balance()
	_check(not RecruitmentService.recruit(busy_wallet, busy, "MAGE", func() -> bool: return false)["success"], "A failed save with an existing roster")
	_check(JSON.stringify(busy.to_dict()) == snapshot and busy_wallet.get_balance() == money, "The roster (progression, deployment, next_serial) and money are exactly as before")
	_check(not busy.add(Mercenary.create("merc_a", "GUARDIAN")) and not busy.add(Mercenary.create("merc_2", "MAGE")), "Retired ids stay retired after the rollback")
	_check(RecruitmentService.recruit(busy_wallet, busy, "MAGE")["mercenary_id"] == "merc_4", "The next recruit is merc_4 (the failed one's merc_4 was not used up)")
	# The roster refuses after the payment (no persistable id left): money back.
	var exhausted := MercenaryRoster.from_dict({"owned": [], "deployed": [], "next_serial": MercenaryRoster.MAX_SERIAL})
	var exhausted_wallet := _wallet(3000)
	var saves := []
	var refused := RecruitmentService.recruit(exhausted_wallet, exhausted, "MAGE", func() -> bool:
		saves.append(true)
		return true)
	_check(not refused["success"] and refused["reason"] == RecruitmentService.ERR_RECRUIT_FAILED and exhausted_wallet.get_balance() == 3000 and exhausted.get_owned_count() == 0 and exhausted.get_next_serial() == MercenaryRoster.MAX_SERIAL and saves.is_empty(), "AC13 The roster refuses after the payment: $3,000 back, nothing owned, nothing saved")
	# Snapshot helper refuses junk.
	var plain := MercenaryRoster.new()
	plain.create_mercenary("MAGE")
	var plain_state := JSON.stringify(plain.to_dict())
	_check(not plain.restore_snapshot({}) and not plain.restore_snapshot({"state": null, "used_ids": []}) and not plain.restore_snapshot({"state": plain.to_dict(), "used_ids": []}) and JSON.stringify(plain.to_dict()) == plain_state, "restore_snapshot refuses an invalid snapshot, changing nothing")
	_sections_done.append("rollback")


# --- In game ------------------------------------------------------------------------------------------

func _verify_game() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main()
	var hub := main.get_node("CityHub") as CityHub
	_check(main.recruit_mercenary("MAGE")["reason"] == "ERR_NOT_IN_CITY" and main.mercenary_roster.get_owned_count() == 0 and main.wallet.get_balance() == 10000, "Outside a city: no recruitment")
	await _enter_city(main)
	_check(hub.is_open() and hub.has_node("Center/Content/FacilityTabs/MercenaryTabButton"), "AC01 The City Hub has a 傭兵中心 tab")
	var tab := hub.get_node("Center/Content/FacilityTabs/MercenaryTabButton") as Button
	_check(tab.text == "傭兵中心", "Tab text 傭兵中心")
	tab.pressed.emit()
	await process_frame
	_check(hub.get_facility() == CityHub.FACILITY_MERCENARY and (hub.get_node("Center/Content/MercenaryPanel") as Control).visible and tab.disabled, "The Mercenary Center opens")
	for type in TYPES:
		var texts := hub.get_recruit_row_texts(type)
		_check(texts["name"] == "%s　%s" % [NAMES[type], RecruitmentService.ROLE_TEXT[type]] and texts["price"] == "招聘費用：$1,000" and texts["hint"] == RecruitmentService.HINT_TEXT[type], "AC02/AC03 Row %s: %s, $1,000" % [type, texts["name"]])
		_check(hub.get_recruit_button(type).text == "招聘" and hub.get_recruit_button(type).visible, "招聘 button for %s" % type)
	_check(hub.get_mercenary_count_text() == "持有傭兵：0 / 5" and hub.get_mercenary_owned_text() == "尚未持有傭兵" and hub.get_money_label_text() == "金錢：10000", "AC18 Shows 0 / 5, none owned, the money")
	# Recruit through the real button.
	_delete(TEST_SAVE)
	hub.get_recruit_button("MAGE").pressed.emit()
	_check(main.wallet.get_balance() == 9000 and main.mercenary_roster.get_owned_count() == 1 and main.mercenary_roster.get_mercenary("merc_1").get_type() == "MAGE", "AC04/AC05 Recruit 法師: $9,000 left, merc_1 owned")
	_check(hub.get_feedback_text() == "成功招聘法師" and hub.get_mercenary_count_text() == "持有傭兵：1 / 5" and hub.get_mercenary_owned_text() == "法師 #1" and hub.get_money_label_text() == "金錢：9000", "AC14/AC18/AC19 UI at once: 成功招聘法師, 1 / 5, 法師 #1, 金錢：9000")
	var saved: Variant = _read(TEST_SAVE)
	_check(saved != null and int(saved["version"]) == 11 and int(saved["money"]) == 9000 and (saved["mercenaries"]["owned"] as Array).size() == 1 and saved["mercenaries"]["owned"][0]["id"] == "merc_1" and int(saved["mercenaries"]["next_serial"]) == 2, "AC06 Saved at once: v11, $9,000, merc_1, next_serial 2")
	hub.get_recruit_button("MAGE").pressed.emit()
	hub.get_recruit_button("GUARDIAN").pressed.emit()
	_check(main.mercenary_roster.get_owned_count() == 3 and hub.get_mercenary_owned_text() == "法師 #1　法師 #2　守衛 #3" and hub.get_feedback_text() == "成功招聘守衛" and main.wallet.get_balance() == 7000, "AC08 Same type again: 法師 #1　法師 #2　守衛 #3, $7,000")
	# Restart.
	await _destroy(main)
	main = await _new_main()
	hub = main.get_node("CityHub") as CityHub
	_check(main.wallet.get_balance() == 7000 and main.mercenary_roster.get_owned_count() == 3 and main.mercenary_roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id()) == ["merc_1", "merc_2", "merc_3"] and main.mercenary_roster.get_next_serial() == 4, "AC07 Restart: $7,000, merc_1..3 restored, next_serial 4")
	if not hub.is_open():
		await _enter_city(main)
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	await process_frame
	_check(hub.get_mercenary_count_text() == "持有傭兵：3 / 5" and hub.get_mercenary_owned_text() == "法師 #1　法師 #2　守衛 #3", "Restart: the center shows 3 / 5 and the owned list")
	hub.get_recruit_button("STRATEGIST").pressed.emit()
	_check(main.mercenary_roster.get_mercenary("merc_4") != null and main.mercenary_roster.get_mercenary("merc_4").get_type() == "STRATEGIST", "Recruiting after a restart continues at merc_4 (軍師)")
	# Entering and leaving the center / the city.
	for round in range(5):
		hub.show_facility(CityHub.FACILITY_MARKET)
		await process_frame
		_check(not (hub.get_node("Center/Content/MercenaryPanel") as Control).visible and hub.get_facility() == CityHub.FACILITY_MARKET, "Round %d: market view hides the center" % round)
		hub.show_facility(CityHub.FACILITY_MERCENARY)
		await process_frame
		_check((hub.get_node("Center/Content/MercenaryPanel") as Control).visible and hub.get_mercenary_count_text() == "持有傭兵：4 / 5" and hub.get_feedback_text() == "", "Round %d: back in the center, 4 / 5, feedback cleared" % round)
	_check(main.leave_city() and not hub.is_open(), "Leave the city")
	await _settle()
	await _enter_city(main)
	_check(hub.is_open() and hub.get_facility() == CityHub.FACILITY_MARKET, "Re-entering opens on the market as before")
	await _destroy(main)
	_sections_done.append("game")


func _verify_game_failures() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main()
	var hub := main.get_node("CityHub") as CityHub
	await _enter_city(main)
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	await process_frame
	# Save failure through the button.
	var money: int = main.wallet.get_balance()
	main.save_path = BAD_SAVE
	hub.get_recruit_button("GUARDIAN").pressed.emit()
	_check(main.wallet.get_balance() == money and main.mercenary_roster.get_owned_count() == 0 and main.mercenary_roster.get_next_serial() == 1, "AC15 In game: a failed save restores the money and the roster")
	_check(hub.get_feedback_text() == "無法儲存，招聘已取消" and hub.get_mercenary_count_text() == "持有傭兵：0 / 5" and hub.get_money_label_text() == "金錢：%d" % money, "The player sees 無法儲存，招聘已取消; 0 / 5; money unchanged")
	main.save_path = TEST_SAVE
	hub.get_recruit_button("GUARDIAN").pressed.emit()
	_check(main.mercenary_roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id()) == ["merc_1"] and main.wallet.get_balance() == money - 1000, "AC14 The next recruit is merc_1 (no id used up)")
	# Insufficient money.
	main.wallet.spend(main.wallet.get_balance() - 999)
	_refresh(main)
	var before := JSON.stringify(main.mercenary_roster.to_dict())
	hub.get_recruit_button("MAGE").pressed.emit()
	_check(main.wallet.get_balance() == 999 and JSON.stringify(main.mercenary_roster.to_dict()) == before and hub.get_feedback_text() == "金錢不足", "AC12 $999 in game: 金錢不足, nothing changes")
	# Rapid input: 20 presses at once with plenty of money -> exactly 5 owned.
	main.wallet.add(100000 - main.wallet.get_balance())
	_delete(TEST_SAVE)
	for press in range(20):
		hub.get_recruit_button(TYPES[press % 3]).pressed.emit()
	var ids: Array = main.mercenary_roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id())
	var unique := {}
	for id in ids:
		unique[id] = true
	_check(main.mercenary_roster.get_owned_count() == 5 and unique.size() == 5 and main.wallet.get_balance() == 100000 - 4000, "AC17 20 rapid presses: exactly 4 more (5 owned), $4,000 charged once each, ids unique")
	_check(hub.get_feedback_text() == "傭兵人數已達上限" and hub.get_mercenary_count_text() == "持有傭兵：5 / 5", "AC11 5 / 5: 傭兵人數已達上限")
	var saved: Variant = _read(TEST_SAVE)
	_check(saved != null and int(saved["money"]) == 96000 and (saved["mercenaries"]["owned"] as Array).size() == 5 and int(saved["mercenaries"]["next_serial"]) == 6, "The save matches: $96,000, 5 owned, next_serial 6")
	await _destroy(main)
	main = await _new_main()
	_check(main.wallet.get_balance() == 96000 and main.mercenary_roster.get_owned_count() == 5, "Restart after the rapid presses: consistent")
	await _destroy(main)
	_sections_done.append("game_failures")


# --- Layout --------------------------------------------------------------------------------------------

func _verify_layout() -> void:
	var main := await _new_main()
	var hub := main.get_node("CityHub") as CityHub
	await _enter_city(main)
	var canvas := Rect2(0.0, 0.0, 720.0, 1280.0)
	var tabs := hub.get_node("Center/Content/FacilityTabs") as Control
	for facility in CityHub.FACILITIES:
		hub.show_facility(facility)
		await process_frame
		await process_frame
		var content := hub.get_node("Center/Content") as Control
		_check(canvas.encloses(content.get_global_rect()), "AC20 %s view fits 720 x 1280 (%s)" % [facility, str(content.get_global_rect())])
		_check(canvas.encloses(tabs.get_global_rect()), "AC20 Four tabs fit the width in the %s view (%s)" % [facility, str(tabs.get_global_rect())])
	for tab in tabs.get_children():
		var rect := (tab as Control).get_global_rect()
		_check(rect.size.x >= 150.0 and rect.size.y >= 64.0 and canvas.encloses(rect), "Tab %s: %s, a comfortable touch target" % [(tab as Button).text, str(rect.size)])
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	await process_frame
	for type in TYPES:
		var button := hub.get_recruit_button(type)
		var rect := button.get_global_rect()
		_check(rect.size.x >= 120.0 and rect.size.y >= 88.0 and canvas.encloses(rect), "招聘 %s: %s, inside the screen" % [type, str(rect.size)])
	for node_name in ["MoneyLabel", "FeedbackLabel", "LeaveButton"]:
		var node := hub.get_node("Center/Content/" + node_name) as Control
		_check(node.visible and canvas.encloses(node.get_global_rect()), "%s visible inside the screen in the center" % node_name)
	_check(not (hub.get_node("Center/Content/CargoLabel") as Control).visible, "The center trades the capacity line for its own rows")
	await _destroy(main)
	_sections_done.append("layout")


# --- Scope -----------------------------------------------------------------------------------------------

func _verify_scope() -> void:
	_check(SaveStore.VERSION == 11 and SaveStore.V11_KEYS.size() == 11, "AC21 Save v11 unchanged")
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_view.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_config.gd", "res://scripts/character_config.gd", "res://scripts/character_stats.gd", "res://scripts/save_store.gd"]:
		var code := _code_only(path).to_lower()
		_check(not code.contains("recruit") and not code.contains("mercenary_center"), "AC22 %s knows nothing about recruitment" % path.get_file())
	var service := _code_only("res://scripts/recruitment_service.gd")
	for word in ["CombatBattle", "set_deployment", "remove(", "dismiss", "SaveStore", "FileAccess"]:
		_check(not service.contains(word), "RecruitmentService has no %s" % word)
	var hub := _code_only("res://scripts/city_hub.gd")
	_check(not hub.contains("MercenaryRoster") and not hub.contains("Wallet") and not hub.contains("deploy") and not hub.contains("dismiss"), "The hub only displays and forwards presses")
	_sections_done.append("scope")


# --- Stress (seeded) -----------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261004
	var wallet := _wallet(3000)
	var roster := MercenaryRoster.new()
	var issued := {}
	var ok := true
	var outcomes := {}
	for step in range(3000):
		var type: Variant = TYPES[rng.randi_range(0, 2)] if rng.randi_range(0, 9) > 0 else "WARRIOR"
		var save_ok := rng.randi_range(0, 4) > 0
		if rng.randi_range(0, 9) == 0:
			wallet.add(rng.randi_range(1, 1500))
		if rng.randi_range(0, 7) == 0 and roster.get_owned_count() > 0:
			roster.remove(roster.get_owned()[rng.randi_range(0, roster.get_owned_count() - 1)].get_id())
		var before := _state(wallet, roster)
		var money := wallet.get_balance()
		var owned := roster.get_owned_count()
		var result := RecruitmentService.recruit(wallet, roster, type, func() -> bool: return save_ok)
		outcomes[result["reason"]] = int(outcomes.get(result["reason"], 0)) + 1
		if result["success"]:
			ok = ok and wallet.get_balance() == money - 1000 and roster.get_owned_count() == owned + 1 and not issued.has(result["mercenary_id"]) and roster.get_mercenary(result["mercenary_id"]).get_type() == type
			issued[result["mercenary_id"]] = true
		else:
			ok = ok and _state(wallet, roster) == before
		ok = ok and roster.get_owned_count() <= 5 and wallet.get_balance() >= 0
		if not ok:
			_check(false, "Stress broke at step %d (%s)" % [step, str(result)])
			break
	_check(ok, "3000 seeded recruits / refusals: each success charges $1,000 once with a new id; each refusal changes nothing")
	for reason in ["", RecruitmentService.ERR_SAVE_FAILED, RecruitmentService.ERR_ROSTER_FULL, RecruitmentService.ERR_INSUFFICIENT_FUNDS, RecruitmentService.ERR_INVALID_TYPE]:
		_check(int(outcomes.get(reason, 0)) > 20, "Outcome %s exercised (%d)" % [reason if reason != "" else "success", int(outcomes.get(reason, 0))])
	_sections_done.append("stress")


# --- Helpers -------------------------------------------------------------------------------------------

func _state(wallet: Wallet, roster: MercenaryRoster) -> String:
	return JSON.stringify([wallet.get_balance(), roster.get_snapshot()])


func _wallet(amount: int) -> Wallet:
	var wallet := Wallet.new()
	var difference := amount - wallet.get_balance()
	if difference > 0:
		wallet.add(difference)
	elif difference < 0:
		wallet.spend(-difference)
	return wallet


func _refresh(main: Node) -> void:
	main._refresh_hub_summary()


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


func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


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
