extends SceneTree

## Stage 10 P02: Hospital UI + player recovery flow (the real City Hub).
##   availability  City A / B have 醫院 (WorldLayout.HOSPITAL_CITY_IDS); C / D
##                 not; never in the world or a battle
##   hero          state, 免費恢復 (independent of money / Mercenaries / the
##                 selection), never a paid choice
##   mercenary     selectable only when it needs recovery (hurt, MP only,
##                 dead), same-type isolation, select / deselect / refresh
##   pricing       0-3 chosen -> $0-$300, the Hero never counts, affordable /
##                 not, 確認治療 disabled when short; no partial recovery
##   feedback      success texts, refreshed state, failures in plain words,
##                 save failure: restored state, no success text
##   identity      stale / dismissed / unknown ids recover nobody
##   boundaries    nothing else changes (Level, EXP, allocation, gear, goods,
##                 roster, deployment, market, warehouses)
##   layout        six tabs 112 x 64 in one row, the 醫院 view inside 720 x 1280
##                 with five Mercenaries, touch-sized controls, no clipping
##   stress        TARGETED: random parties / conditions / wallets, select /
##                 deselect, open / close, recover, save failures, reloads

const TEST_SAVE := "user://s10_p02_hospital_test.json"
const BAD_SAVE := "user://s10_p02_missing_dir/save.json"
const T0 := 1800000000000
const A1 := "test_armor_01"
const W2 := "test_weapon_02"
const PASSIVE_ONLY := Vector2(950.0, 1080.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _seed := 10200


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			_seed = int(arg.substr(7))
	await _verify_availability()
	await _verify_hero()
	await _verify_mercenaries()
	await _verify_pricing()
	await _verify_feedback()
	await _verify_identity()
	await _verify_layout()
	await _verify_stress()
	_check(_sections_done.size() == 8, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S10 P02 hospital UI verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Availability -------------------------------------------------------------------------------------------

func _verify_availability() -> void:
	_check(WorldLayout.HOSPITAL_CITY_IDS == ["A", "B"] and WorldLayout.city_has_hospital("A") and WorldLayout.city_has_hospital("B"), "1 / 2 City A and City B have a Hospital")
	_check(not WorldLayout.city_has_hospital("C") and not WorldLayout.city_has_hospital("D") and not WorldLayout.city_has_hospital("") and not WorldLayout.city_has_hospital(null), "5 Reserved C / D (and nothing else) have none")
	_clean()
	var main := await _new_main(TEST_SAVE)
	var hub := main.get_node("CityHub") as CityHub
	var tab := hub.get_node("Center/Content/FacilityTabs/HospitalTabButton") as Button
	_check(not hub.visible and not main.can_use_hospital(), "3 In the world: no City Hub, no Hospital")
	var refused: Dictionary = main.hospital_recover_hero()
	_check(not refused["success"] and refused["reason"] == "ERR_NO_HOSPITAL", "3 The Hospital entry refuses outside a city (ERR_NO_HOSPITAL)")
	await _enter_city(main, WorldLayout.CITY_A)
	_check(main.current_city_id == "A" and tab.visible and tab.text == "醫院" and main.can_use_hospital(), "1 City A: the 醫院 tab")
	tab.pressed.emit()
	await process_frame
	_check(hub.get_facility() == CityHub.FACILITY_HOSPITAL and (hub.get_node("Center/Content/HospitalPanel") as Control).visible and tab.disabled, "1 Tapping 醫院 opens the Hospital view")
	_check((hub.get_node("Center/Content/NoteLabel") as Label).text == "開發原型：主角治療免費；每名傭兵治療 $100（不論傷勢）", "The note states the prices (from RecoveryService)")
	main.leave_city()
	await _settle()
	await _enter_city(main, WorldLayout.CITY_B)
	_check(main.current_city_id == "B" and tab.visible and main.can_use_hospital(), "2 City B: the 醫院 tab")
	hub.show_facility(CityHub.FACILITY_HOSPITAL)
	_check(hub.get_facility() == CityHub.FACILITY_HOSPITAL, "2 City B: the Hospital view opens")
	# A city without a Hospital (C is reserved: simulated on the hub only).
	hub.open("C")
	_check(not tab.visible and not hub.has_hospital(), "5 A city not in the list shows no 醫院 tab")
	hub.show_facility(CityHub.FACILITY_HOSPITAL)
	_check(hub.get_facility() == CityHub.FACILITY_MARKET, "5 ... and cannot open the Hospital view")
	hub.open("B")
	main.leave_city()
	await _settle()
	# 4 In a battle: refused.
	main.condition.set_condition("hero", 10, 0)
	var battle: CombatBattle = await _start_battle(main)
	var before := _main_state(main)
	var r1: Dictionary = main.hospital_recover_hero()
	var r2: Dictionary = main.hospital_recover([])
	_check(battle != null and not r1["success"] and not r2["success"] and _main_state(main) == before and not main.can_use_hospital(), "4 During a battle no Hospital recovery runs")
	await _destroy(main)
	_clean()
	_sections_done.append("availability")


# --- Hero ---------------------------------------------------------------------------------------------------

func _verify_hero() -> void:
	var main := await _hospital_game(["GUARDIAN"], 0)
	var hub := main.get_node("CityHub") as CityHub
	var c: CharacterCondition = main.condition
	# 6 Injured; 8 FREE.
	c.set_condition("hero", 50, 10)
	await _refresh(main)
	var texts := hub.get_hospital_row_texts("hero")
	var max_hp: int = c.get_condition("hero")["max_hp"]
	var max_mp: int = c.get_condition("hero")["max_mp"]
	_check(texts["NameLabel"] == "主角" and texts["HpMpLabel"] == "血量 50 / %d　魔力 10 / %d" % [max_hp, max_mp] and texts["StateLabel"] == "【受傷】需要治療" and texts["PriceLabel"] == "治療費用：免費", "6 / 8 Injured Hero: HP / MP, 【受傷】需要治療, 治療費用：免費 (%s)" % str(texts))
	_check(texts["button"] == "免費恢復" and not hub.get_hospital_hero_button().disabled, "9 / 10 The Hero's own 免費恢復, enabled with $0")
	_check(not hub.get_hospital_ids().has("hero") and hub.get_hospital_select_button("hero") == null, "13 The Hero is never a paid selection")
	# 7 Dead.
	c.set_condition("hero", 0, 0)
	await _refresh(main)
	_check(hub.get_hospital_row_texts("hero")["StateLabel"] == "【陣亡】需要復活", "7 A dead Hero: 【陣亡】需要復活")
	# 10 / 11 / 12 Recover at $0, independent of a selection.
	c.set_condition("merc_1", 0, 0)
	await _refresh(main)
	hub.toggle_hospital_selection("merc_1")
	_check(hub.get_hospital_confirm_button().disabled and hub.get_hospital_summary_texts()["short"] == "持有金錢不足，請減少選擇的傭兵", "With $0 the paid choice cannot be confirmed")
	hub.get_hospital_hero_button().pressed.emit()
	await process_frame
	texts = hub.get_hospital_row_texts("hero")
	_check(main.wallet.get_balance() == 0 and not c.is_dead("hero") and texts["HpMpLabel"] == "血量 %d / %d　魔力 %d / %d" % [max_hp, max_hp, max_mp, max_mp] and texts["StateLabel"] == "【狀態良好】無需治療", "11 / 12 / 34 免費恢復 at $0: the Hero revived, full HP / MP shown at once")
	_check(hub.get_feedback_text() == "主角已完全恢復" and hub.get_hospital_hero_button().disabled and texts["PriceLabel"] == "治療費用：不需要", "主角已完全恢復; the button disabled once healthy")
	_check(c.is_dead("merc_1") and hub.get_hospital_selection() == ["merc_1"], "The Mercenary choice is untouched by the Hero's recovery")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(saved["condition"]["hero"]["dead"] == false and int(saved["money"]) == 0, "Saved at once (v14)")
	await _destroy(main)
	_clean()
	_sections_done.append("hero")


# --- Mercenaries ------------------------------------------------------------------------------------------------

func _verify_mercenaries() -> void:
	var main := await _hospital_game(["GUARDIAN", "GUARDIAN", "MAGE", "STRATEGIST"], 1000)
	var hub := main.get_node("CityHub") as CityHub
	var c: CharacterCondition = main.condition
	_hurt(c, "merc_1", 40, 20)
	var max_hp_2: int = c.get_condition("merc_2")["max_hp"]
	c.set_condition("merc_3", c.get_condition("merc_3")["max_hp"], 0)
	c.set_condition("merc_4", 0, 0)
	await _refresh(main)
	_check(hub.get_hospital_ids() == ["merc_1", "merc_2", "merc_3", "merc_4"], "Every owned Mercenary has a row (stable ids, roster order)")
	_check(hub.get_hospital_row_texts("merc_1")["NameLabel"] == "守衛 #1" and hub.get_hospital_row_texts("merc_2")["NameLabel"] == "守衛 #2", "Same-type rows named by their own labels")
	_check(not hub.get_hospital_select_button("merc_1").disabled and hub.get_hospital_row_texts("merc_1")["StateLabel"] == "【受傷】需要治療" and hub.get_hospital_row_texts("merc_1")["PriceLabel"] == "治療費用：$100", "14 Hurt 守衛 #1: selectable, $100")
	_check(not hub.get_hospital_select_button("merc_3").disabled and hub.get_hospital_row_texts("merc_3")["PriceLabel"] == "治療費用：$100", "15 MP-only 法師 #3: selectable, $100")
	_check(not hub.get_hospital_select_button("merc_4").disabled and hub.get_hospital_row_texts("merc_4")["StateLabel"] == "【陣亡】需要復活", "16 Dead 軍師 #4: selectable, 【陣亡】需要復活")
	_check(hub.get_hospital_select_button("merc_2").disabled and hub.get_hospital_row_texts("merc_2")["StateLabel"] == "【狀態良好】無需治療" and hub.get_hospital_row_texts("merc_2")["PriceLabel"] == "治療費用：不需要", "17 Healthy 守衛 #2: not selectable, no price")
	_check(not hub.toggle_hospital_selection("merc_2") and hub.get_hospital_selection() == [] and hub.get_hospital_total() == 0, "17 A healthy one cannot be chosen (no $100)")
	# 19 / 20 / 21 select one / several / deselect (the real buttons).
	hub.get_hospital_select_button("merc_1").pressed.emit()
	_check(hub.get_hospital_selection() == ["merc_1"] and hub.get_hospital_select_button("merc_1").button_pressed and hub.get_hospital_select_button("merc_1").text == "已選擇", "19 Select one (已選擇)")
	hub.get_hospital_select_button("merc_4").pressed.emit()
	hub.get_hospital_select_button("merc_3").pressed.emit()
	_check(hub.get_hospital_selection() == ["merc_1", "merc_4", "merc_3"] and hub.get_hospital_total() == 300, "20 Select several: $300")
	hub.get_hospital_select_button("merc_4").pressed.emit()
	_check(hub.get_hospital_selection() == ["merc_1", "merc_3"] and not hub.get_hospital_select_button("merc_4").button_pressed and hub.get_hospital_select_button("merc_4").text == "選擇", "21 Deselect")
	# 22 Ordinary refreshes keep the choice; same-type isolation.
	for frame in range(5):
		await process_frame
	_check(hub.get_hospital_selection() == ["merc_1", "merc_3"] and hub.get_hospital_select_button("merc_1").button_pressed and not hub.get_hospital_select_button("merc_2").button_pressed, "22 / 18 The choice survives refreshes; 守衛 #2 stays unchosen")
	# A chosen one healed elsewhere drops out deterministically.
	c.set_condition("merc_3", 9999, 9999)
	await _refresh(main)
	_check(hub.get_hospital_selection() == ["merc_1"] and hub.get_hospital_select_button("merc_3").disabled, "22 A chosen Mercenary that no longer needs recovery leaves the choice (no wrong id)")
	# 35 / 37 / 38 Recover 守衛 #1 only.
	var dead_4 := c.get_condition("merc_4")
	hub.get_hospital_confirm_button().pressed.emit()
	await process_frame
	_check(main.wallet.get_balance() == 900 and hub.get_feedback_text() == "已恢復 1 名傭兵，費用 $100", "35 / 36 確認治療: 已恢復 1 名傭兵，費用 $100; $1,000 -> $900")
	var row := hub.get_hospital_row_texts("merc_1")
	var max_hp_1: int = c.get_condition("merc_1")["max_hp"]
	var max_mp_1: int = c.get_condition("merc_1")["max_mp"]
	_check(row["HpMpLabel"] == "血量 %d / %d　魔力 %d / %d" % [max_hp_1, max_hp_1, max_mp_1, max_mp_1] and row["StateLabel"] == "【狀態良好】無需治療" and hub.get_hospital_select_button("merc_1").disabled, "35 / 37 守衛 #1 full, shown at once, no longer selectable")
	_check(c.get_condition("merc_4") == dead_4 and not hub.get_hospital_select_button("merc_4").disabled and hub.get_hospital_row_texts("merc_4")["StateLabel"] == "【陣亡】需要復活", "38 軍師 #4 unchanged and still selectable")
	_check(hub.get_hospital_selection() == [] and hub.get_hospital_total() == 0 and hub.get_hospital_confirm_button().disabled, "The choice is cleared after success")
	_check(int(JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))["money"]) == 900, "Saved at once")
	await _destroy(main)
	_clean()
	_sections_done.append("mercenary")


# --- Pricing / affordability --------------------------------------------------------------------------------------

func _verify_pricing() -> void:
	var main := await _hospital_game(["GUARDIAN", "MAGE", "STRATEGIST"], 250)
	var hub := main.get_node("CityHub") as CityHub
	var c: CharacterCondition = main.condition
	for id in ["hero", "merc_1", "merc_2", "merc_3"]:
		c.set_condition(id, 0, 0)
	await _refresh(main)
	var totals := []
	totals.append(hub.get_hospital_total())
	for id in ["merc_1", "merc_2", "merc_3"]:
		hub.toggle_hospital_selection(id)
		totals.append(hub.get_hospital_total())
	_check(totals == [0, 100, 200, 300], "23-27 Totals 0 / 1 / 2 / 3 chosen: $0 / $100 / $200 / $300 — the dead Hero never counts (%s)" % str(totals))
	var summary := hub.get_hospital_summary_texts()
	_check(summary["summary"] == "已選傭兵 3 名　合計 $300　持有金錢 $250" and summary["short"] == "持有金錢不足，請減少選擇的傭兵" and hub.get_hospital_confirm_button().disabled, "29 $250 with three chosen: shown as short, 確認治療 disabled (%s)" % str(summary))
	# 30 Even a forced request changes nothing.
	var before := _main_state(main)
	var r: Dictionary = main.hospital_recover(hub.get_hospital_selection())
	hub.show_hospital_feedback(r, false)
	_check(not r["success"] and _main_state(main) == before and hub.get_feedback_text() == "持有金錢不足，請減少選擇的傭兵" and hub.get_hospital_selection().size() == 3, "30 A forced unaffordable request: nothing recovered, nothing spent, the choice kept for the player to change")
	# 28 Deselect one: affordable.
	hub.toggle_hospital_selection("merc_3")
	summary = hub.get_hospital_summary_texts()
	_check(summary["summary"] == "已選傭兵 2 名　合計 $200　持有金錢 $250" and summary["short"] == "" and not hub.get_hospital_confirm_button().disabled and summary["confirm"] == "確認治療（$200）", "28 $250 with two chosen: affordable, 確認治療（$200）")
	hub.get_hospital_confirm_button().pressed.emit()
	await process_frame
	_check(main.wallet.get_balance() == 50 and not c.is_dead("hero") and not c.is_dead("merc_1") and not c.is_dead("merc_2") and c.is_dead("merc_3"), "28 Two recovered for $200 ($50 left), the Hero free, 軍師 #3 still dead")
	_check(hub.get_feedback_text() == "主角已完全恢復；已恢復 2 名傭兵，費用 $200", "Feedback names the Hero and the two (%s)" % hub.get_feedback_text())
	await _destroy(main)
	# 31 $100 / 32 $99.
	main = await _hospital_game(["GUARDIAN"], 100)
	hub = main.get_node("CityHub") as CityHub
	main.condition.set_condition("merc_1", 0, 0)
	await _refresh(main)
	hub.toggle_hospital_selection("merc_1")
	hub.get_hospital_confirm_button().pressed.emit()
	await process_frame
	_check(main.wallet.get_balance() == 0 and not main.condition.is_dead("merc_1"), "31 $100 + one: recovered, $0 left")
	await _destroy(main)
	main = await _hospital_game(["GUARDIAN"], 99)
	hub = main.get_node("CityHub") as CityHub
	main.condition.set_condition("merc_1", 0, 0)
	await _refresh(main)
	hub.toggle_hospital_selection("merc_1")
	_check(hub.get_hospital_confirm_button().disabled, "32 $99 + one: 確認治療 disabled")
	r = main.hospital_recover(["merc_1"])
	_check(not r["success"] and main.wallet.get_balance() == 99 and main.condition.is_dead("merc_1"), "32 / 33 Refused; $99 kept (never negative)")
	await _destroy(main)
	_clean()
	_sections_done.append("pricing")


# --- Feedback: save failure / errors -------------------------------------------------------------------------------

func _verify_feedback() -> void:
	var main := await _hospital_game(["GUARDIAN", "MAGE"], 300)
	var hub := main.get_node("CityHub") as CityHub
	var c: CharacterCondition = main.condition
	c.set_condition("hero", 0, 0)
	c.set_condition("merc_1", 0, 2)
	_hurt(c, "merc_2", 30, 5)
	await _refresh(main)
	hub.toggle_hospital_selection("merc_1")
	hub.toggle_hospital_selection("merc_2")
	var shown := _hospital_texts(hub)
	var before := _main_state(main)
	main.save_path = BAD_SAVE
	hub.get_hospital_confirm_button().pressed.emit()
	await process_frame
	_check(hub.get_feedback_text() == "無法儲存，治療已取消" and _main_state(main) == before and main.wallet.get_balance() == 300, "39 Save failure: 無法儲存，治療已取消; money and every condition restored")
	_check(_hospital_texts(hub) == shown and hub.get_hospital_selection() == ["merc_1", "merc_2"], "39 The refreshed view shows the restored state (no success shown), the choice kept for a retry")
	hub.get_hospital_hero_button().pressed.emit()
	await process_frame
	_check(hub.get_feedback_text() == "無法儲存，治療已取消" and c.is_dead("hero"), "39 免費恢復 save failure: the Hero still dead, no success")
	main.save_path = TEST_SAVE
	hub.get_hospital_confirm_button().pressed.emit()
	await process_frame
	_check(main.wallet.get_balance() == 100 and not c.is_dead("hero") and hub.get_feedback_text() == "主角已完全恢復；已恢復 2 名傭兵，費用 $200", "Retry after the failure succeeds")
	# Nothing to recover.
	hub.get_hospital_hero_button().pressed.emit()
	_check(hub.get_hospital_hero_button().disabled, "Healthy Hero: 免費恢復 disabled")
	hub.show_hospital_feedback(main.hospital_recover_hero(), true)
	_check(hub.get_feedback_text() == "沒有需要治療的角色", "沒有需要治療的角色 (no raw code)")
	# Every expected reason has player words (never a raw code).
	for reason in ["ERR_INSUFFICIENT_FUNDS", "ERR_NOTHING_TO_RECOVER", "ERR_NOT_NEEDED", "ERR_UNKNOWN_MERCENARY", "ERR_DUPLICATE", "ERR_HERO_SELECTED", "ERR_INVALID_REQUEST", "ERR_SAVE_FAILED", "ERR_IN_COMBAT", "ERR_NO_HOSPITAL", "ERR_SOMETHING_NEW"]:
		hub.show_hospital_feedback({"success": false, "reason": reason}, false)
		_check(hub.get_feedback_text() != "" and not hub.get_feedback_text().contains("ERR"), "%s -> %s" % [reason, hub.get_feedback_text()])
	await _destroy(main)
	_clean()
	_sections_done.append("feedback")


# --- Stable identity / boundaries ----------------------------------------------------------------------------------

func _verify_identity() -> void:
	var main := await _hospital_game(["GUARDIAN", "GUARDIAN", "MAGE"], 1000)
	var hub := main.get_node("CityHub") as CityHub
	var c: CharacterCondition = main.condition
	c.set_condition("merc_1", 0, 0)
	c.set_condition("merc_2", 0, 0)
	c.set_condition("merc_3", 0, 0)
	main.carrying.add_equipment("merc_1", A1, 1)
	EquipmentService.equip(main.carrying, "merc_1", A1)
	main.carrying.add_equipment("merc_2", W2, 1)
	main.mercenary_roster.set_deployment(["merc_3"])
	await _refresh(main)
	var other := _other_state(main)
	# 40 Same-type: choosing 守衛 #2 recovers 守衛 #2 only.
	hub.toggle_hospital_selection("merc_2")
	hub.get_hospital_confirm_button().pressed.emit()
	await process_frame
	_check(not c.is_dead("merc_2") and c.is_dead("merc_1") and c.is_dead("merc_3") and main.wallet.get_balance() == 900, "40 守衛 #2 recovered; 守衛 #1 (same type) and 法師 #3 untouched")
	_check(_other_state(main) == other, "Regression: no Level / EXP / allocation / equipment / carrying / goods / roster / deployment / market / warehouse change")
	# 42 Stale selection: 法師 #3 dismissed after it was chosen.
	hub.toggle_hospital_selection("merc_3")
	main.mercenary_roster.set_deployment([])
	main.mercenary_roster.remove("merc_3")
	var before := _main_state(main)
	hub.get_hospital_confirm_button().pressed.emit()
	await process_frame
	_check(_main_state(main) == before and main.wallet.get_balance() == 900 and hub.get_feedback_text() == "選擇已更新，請重新選擇" and hub.get_hospital_selection() == [] and not hub.get_hospital_ids().has("merc_3"), "42 A stale choice of a dismissed Mercenary: nothing recovered, no charge, the view rebuilt")
	# 41 An unknown id never recovers another character.
	var r: Dictionary = main.hospital_recover(["merc_9"])
	_check(not r["success"] and _main_state(main) == before, "41 An unknown id recovers nobody")
	_check(not hub.toggle_hospital_selection("merc_9") and not hub.toggle_hospital_selection("hero") and hub.get_hospital_selection() == [], "41 / 13 The view never selects an unknown id or the Hero")
	await _destroy(main)
	_clean()
	_sections_done.append("identity")


# --- Layout (720 x 1280) -------------------------------------------------------------------------------------------

func _verify_layout() -> void:
	var main := await _hospital_game(["GUARDIAN", "GUARDIAN", "MAGE", "STRATEGIST", "MAGE"], 99999)
	var hub := main.get_node("CityHub") as CityHub
	var c: CharacterCondition = main.condition
	c.set_condition("hero", 0, 0)
	for id in ["merc_1", "merc_2", "merc_3", "merc_4", "merc_5"]:
		c.set_condition(id, 0, 0)
	await _refresh(main)
	for id in ["merc_1", "merc_2", "merc_3"]:
		hub.toggle_hospital_selection(id)
	await process_frame
	await process_frame
	var canvas := Rect2(0.0, 0.0, 720.0, 1280.0)
	var tabs := hub.get_node("Center/Content/FacilityTabs") as HBoxContainer
	var ok := tabs.get_child_count() == 6
	var rects := []
	for tab in tabs.get_children():
		var rect := (tab as Control).get_global_rect()
		ok = ok and canvas.encloses(rect) and is_equal_approx(rect.size.x, 112.0) and is_equal_approx(rect.size.y, 64.0) and (tab as Button).get_minimum_size().x <= rect.size.x and (tab as Button).get_theme_font_size("font_size") == 24
		for other: Rect2 in rects:
			ok = ok and not other.intersects(rect) and is_equal_approx(other.position.y, rect.position.y)
		rects.append(rect)
	_check(ok, "Six tabs, 112 x 64, font 24, one row inside 720, labels whole, no overlap")
	var content := hub.get_node("Center/Content") as Control
	_check(canvas.encloses(content.get_global_rect()), "The 醫院 view (Hero + five Mercenaries) fits 720 x 1280 (%s)" % str(content.get_global_rect()))
	var scroll := hub.get_node("Center/Content/HospitalPanel/HospitalScroll") as ScrollContainer
	_check(scroll.custom_minimum_size.y <= CityHub.HOSPITAL_SCROLL_MAX_HEIGHT and (hub.get_node("Center/Content/HospitalPanel/HospitalScroll/MercenaryRows") as Control).get_combined_minimum_size().y >= scroll.custom_minimum_size.y, "The Mercenary list scrolls inside its height")
	var buttons := [hub.get_hospital_hero_button(), hub.get_hospital_confirm_button(), hub.get_node("Center/Content/LeaveButton")]
	for id in hub.get_hospital_ids():
		buttons.append(hub.get_hospital_select_button(id))
	var touch := true
	for button in buttons:
		var size := (button as Control).get_global_rect().size
		touch = touch and size.x >= 112.0 and size.y >= 64.0
	_check(touch, "Every Hospital button is touch-sized (>= 112 x 64)")
	var visible_rects := [hub.get_hospital_hero_button().get_global_rect(), hub.get_hospital_confirm_button().get_global_rect(), (hub.get_node("Center/Content/LeaveButton") as Control).get_global_rect(), (hub.get_node("Center/Content/HospitalPanel/SummaryLabel") as Control).get_global_rect()]
	var inside := true
	for rect: Rect2 in visible_rects:
		inside = inside and canvas.encloses(rect)
	_check(inside, "The Hero row, the summary, 確認治療 and 離開城市 stay on screen")
	# No text is cut: every row label's full text fits its width.
	var fits := true
	for id in ["hero"] + hub.get_hospital_ids():
		var row: Node = hub.get_node("Center/Content/HospitalPanel/HeroRow") if id == "hero" else hub.get_node("Center/Content/HospitalPanel/HospitalScroll/MercenaryRows/Merc_" + id)
		for name in ["NameLabel", "HpMpLabel", "StateLabel", "PriceLabel"]:
			var label := row.find_child(name, true, false) as Label
			var probe := Label.new()
			probe.text = label.text
			probe.add_theme_font_size_override("font_size", label.get_theme_font_size("font_size"))
			hub.add_child(probe)
			fits = fits and probe.get_minimum_size().x <= label.size.x
			probe.free()
	var summary := hub.get_node("Center/Content/HospitalPanel/SummaryLabel") as Label
	fits = fits and summary.get_minimum_size().x <= 720.0 and hub.get_hospital_confirm_button().get_minimum_size().x <= hub.get_hospital_confirm_button().size.x
	_check(fits, "No clipped text (rows, summary, 確認治療)")
	# The other five facilities still fit with the narrower tabs.
	for facility in ["market", "transport", "warehouse", "mercenary", "equipment"]:
		hub.show_facility(facility)
		await process_frame
		await process_frame
		_check(canvas.encloses(content.get_global_rect()), "%s view still fits 720 x 1280" % facility)
	await _destroy(main)
	_clean()
	_sections_done.append("layout")


# --- Stress (TARGETED) -------------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var wallets := [0, 99, 100, 199, 200, 250, 299, 300, 1000]
	var wrong_selection := 0
	var stale_total := 0
	var hero_charged := 0
	var negative := 0
	var false_success := 0
	var healthy_charged := 0
	var duplicated := 0
	var stale_dead := 0
	var reload_bad := 0
	var successes := 0
	var refusals := 0
	var save_failures := 0
	_clean()
	var main := await _hospital_game(["GUARDIAN", "GUARDIAN", "MAGE"], 1000)
	var hub := main.get_node("CityHub") as CityHub
	for step in range(240):
		var c: CharacterCondition = main.condition
		if step % 40 == 0:
			# A new party mix of 0-3 Mercenaries (duplicate types included).
			var mercs := []
			for i in range(rng.randi_range(0, 3)):
				mercs.append(Mercenary.create("merc_%d" % (i + 1), ["GUARDIAN", "GUARDIAN", "MAGE"][rng.randi_range(0, 2)]))
			main.mercenary_roster = MercenaryRoster.build(mercs, [])
			c.sync()
		main.wallet.spend(main.wallet.get_balance())
		var amount: int = wallets[rng.randi_range(0, wallets.size() - 1)]
		if amount > 0:
			main.wallet.add(amount)
		for id in c.get_character_ids():
			var state := c.get_condition(id)
			match rng.randi_range(0, 4):
				0:
					c.set_condition(id, 0, rng.randi_range(0, state["max_mp"]))
				1:
					c.set_condition(id, rng.randi_range(1, state["max_hp"]), rng.randi_range(0, state["max_mp"]))
				_:
					c.set_condition(id, state["max_hp"], state["max_mp"])
		await _refresh(main)
		var ids: Array = c.get_character_ids().slice(1)
		# Random select / deselect, sometimes closing / reopening the view.
		for k in range(rng.randi_range(0, 6)):
			if ids.is_empty():
				break
			hub.toggle_hospital_selection(ids[rng.randi_range(0, ids.size() - 1)])
		if rng.randi_range(0, 5) == 0:
			hub.show_facility(CityHub.FACILITY_MARKET)
			hub.show_facility(CityHub.FACILITY_HOSPITAL)
			if not hub.get_hospital_selection().is_empty():
				wrong_selection += 1
		var selection := hub.get_hospital_selection()
		var seen := {}
		for id in selection:
			if seen.has(id):
				duplicated += 1
			seen[id] = true
			if not ids.has(id) or not RecoveryService.needs_recovery(c.get_condition(id)):
				wrong_selection += 1
		if hub.get_hospital_total() != selection.size() * 100:
			stale_total += 1
		for id in ids:
			if not RecoveryService.needs_recovery(c.get_condition(id)) and not hub.get_hospital_select_button(id).disabled:
				healthy_charged += 1
		var before := _main_state(main)
		var balance: int = main.wallet.get_balance()
		var fail := rng.randi_range(0, 4) == 0
		main.save_path = BAD_SAVE if fail else TEST_SAVE
		var hero_first := rng.randi_range(0, 3) == 0
		var chosen := selection.duplicate()
		if hero_first:
			hub.get_hospital_hero_button().pressed.emit()
		elif not hub.get_hospital_confirm_button().disabled:
			hub.get_hospital_confirm_button().pressed.emit()
		else:
			hub.show_hospital_feedback(main.hospital_recover(chosen), false)
		await process_frame
		main.save_path = TEST_SAVE
		var feedback := hub.get_feedback_text()
		var changed := _main_state(main) != before
		if main.wallet.get_balance() < 0:
			negative += 1
		if feedback.begins_with("主角已完全恢復") or feedback.begins_with("已恢復"):
			successes += 1
			if fail or not changed:
				false_success += 1
			var spent: int = balance - main.wallet.get_balance()
			if hero_first and spent != 0:
				hero_charged += 1
			if not hero_first and spent != chosen.size() * 100:
				hero_charged += 1
		else:
			if fail and feedback == "無法儲存，治療已取消":
				save_failures += 1
			else:
				refusals += 1
			if changed:
				false_success += 1
		# The view shows the current truth.
		await _refresh(main)
		for id in c.get_character_ids():
			var texts := hub.get_hospital_row_texts(id)
			var dead := c.is_dead(id)
			if (texts["StateLabel"] == "【陣亡】需要復活") != dead:
				stale_dead += 1
		# Save -> reload -> reopen now and then.
		if step % 30 == 29:
			main._save_session()
			var state := _main_state(main)
			await _destroy(main)
			main = await _new_main(TEST_SAVE)
			await _enter_city(main, WorldLayout.CITY_A)
			hub = main.get_node("CityHub") as CityHub
			hub.show_facility(CityHub.FACILITY_HOSPITAL)
			await _refresh(main)
			if _main_state(main) != state or hub.get_hospital_selection() != []:
				reload_bad += 1
	print("Stress summary (seed %d): successes %d, refusals %d, save failures %d, wrong_selection %d, stale_total %d, hero_charged %d, negative %d, false_success %d, healthy_selectable %d, duplicated %d, stale_dead %d, reload %d" % [_seed, successes, refusals, save_failures, wrong_selection, stale_total, hero_charged, negative, false_success, healthy_charged, duplicated, stale_dead, reload_bad])
	_check(successes > 40 and refusals > 20 and save_failures > 10, "Stress coverage: %d successes, %d refusals, %d save failures" % [successes, refusals, save_failures])
	_check(wrong_selection == 0, "Stress: the choice only ever holds current ids that need recovery (%d)" % wrong_selection)
	_check(stale_total == 0, "Stress: the total always = chosen x $100 (%d)" % stale_total)
	_check(hero_charged == 0, "Stress: the Hero never charged; exactly $100 per recovered Mercenary (%d)" % hero_charged)
	_check(negative == 0, "Stress: never a negative wallet (%d)" % negative)
	_check(false_success == 0, "Stress: success shown only when committed; refusals / failures change nothing (%d)" % false_success)
	_check(healthy_charged == 0, "Stress: a healthy Mercenary is never selectable (%d)" % healthy_charged)
	_check(duplicated == 0, "Stress: never a duplicated choice (%d)" % duplicated)
	_check(stale_dead == 0, "Stress: the view never shows a stale dead state (%d)" % stale_dead)
	_check(reload_bad == 0, "Stress: recover -> save -> reload -> reopen exact (%d)" % reload_bad)
	await _destroy(main)
	_clean()
	_sections_done.append("stress")


# --- Helpers --------------------------------------------------------------------------------------------------

## The real game in City A with `types` owned Mercenaries and `money`, on
## the 醫院 view.
func _hospital_game(types: Array, money: int) -> Node2D:
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
	await _enter_city(main, WorldLayout.CITY_A)
	var hub := main.get_node("CityHub") as CityHub
	(hub.get_node("Center/Content/FacilityTabs/HospitalTabButton") as Button).pressed.emit()
	await _refresh(main)
	return main


## The game refreshes the hub after every event that can change it
## (entering the city, a trade, a recovery); tests that change the condition
## directly ask for the same refresh.
func _refresh(main: Node) -> void:
	main._refresh_hub_summary()
	await process_frame
	await process_frame


func _hurt(c: CharacterCondition, id: String, hp_loss: int, mp_loss: int) -> void:
	var state := c.get_condition(id)
	c.set_condition(id, state["hp"] - hp_loss, state["mp"] - mp_loss)


func _hospital_texts(hub: CityHub) -> String:
	var parts := [hub.get_hospital_summary_texts()]
	for id in ["hero"] + hub.get_hospital_ids():
		parts.append(hub.get_hospital_row_texts(id))
	return JSON.stringify(parts)


func _main_state(main: Node) -> String:
	var parts := [main.wallet.get_balance(), main.mercenary_roster.to_dict()]
	for id in main.condition.get_character_ids():
		parts.append([id, main.condition.get_condition(id)])
	return JSON.stringify(parts)


func _other_state(main: Node) -> String:
	var parts := [main.mercenary_roster.to_dict(), main.progression.to_dict(), main.character_stats.get_allocation_points(), main.inventory.get_items(), main.market.get_snapshot(), main.warehouses.get_snapshot()]
	for id in main.condition.get_character_ids():
		var equipment: CharacterEquipment = main.carrying.get_equipment(id)
		parts.append([id, equipment.get_equipped_items(), equipment.get_carried(), main.carrying.get_inventory(id).get_items()])
	return JSON.stringify(parts)


func _start_battle(main: Node) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	return main.get_combat()


func _enter_city(main: Node, at: Vector2) -> void:
	(main.get_node("Actors/Player") as Player).global_position = at
	await _settle()
	main.try_enter_city()
	await _settle()


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
