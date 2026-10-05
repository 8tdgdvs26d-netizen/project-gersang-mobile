extends SceneTree

## Stage 8 P03: Roster, Deployment & Dismissal (傭兵名單、出戰編隊與解僱).
##   service      deploy 0 -> 3, 4th refused, duplicate types, no duplicate
##                instance, undeploy; dismiss a waiting one (no refund, id
##                retired), a deployed one refused; every save failure restores
##                the whole roster; unknown / stale ids refused
##   game         我的傭兵 rows (type, #id, Lv, role, status, EXP, points,
##                「能力值、裝備：尚未開放」), 出戰傭兵 X / 3, the buttons, the
##                confirmation (cancel / confirm / repeated taps), feedback,
##                immediate saves, save failures, restart persistence
##   layout       5 rows and the confirmation fit 720 x 1280
##   + scope      Save v11, combat untouched; seeded stress
## Real main scene, fixed TimeSource.

const TEST_SAVE := "user://p03_roster_test_save.json"
const BAD_SAVE := "user://p03_missing_dir/save.json"
const T0 := 1800000000000

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_deployment()
	_verify_dismissal()
	_verify_rollback()
	await _verify_game_roster()
	await _verify_game_deployment()
	await _verify_game_dismissal()
	await _verify_layout()
	_verify_scope()
	_verify_stress()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 9, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("P03 roster deployment verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Service: deployment -------------------------------------------------------------------------------

func _verify_deployment() -> void:
	var roster := _roster(["MAGE", "MAGE", "MAGE", "GUARDIAN", "STRATEGIST"])
	var saves := [0]
	var persist := func() -> bool:
		saves[0] += 1
		return true
	_check(roster.get_deployed_ids().is_empty(), "AC05 0 deployed is valid")
	for count in range(1, 4):
		var id := "merc_%d" % count
		var result := PartyService.set_deployed(roster, id, true, persist)
		_check(result["success"] and roster.get_deployed_ids().size() == count and roster.is_deployed(id) and saves[0] == count, "AC05/AC11 %d -> %d deployed (%s), saved" % [count - 1, count, id])
	_check(roster.get_deployed().all(func(m: Mercenary) -> bool: return m.get_type() == "MAGE") and roster.get_party_ids() == ["hero", "merc_1", "merc_2", "merc_3"], "AC06/AC07 Hero + 法師 #1 + 法師 #2 + 法師 #3 (Hero takes no slot)")
	var full := PartyService.set_deployed(roster, "merc_4", true, persist)
	_check(not full["success"] and full["reason"] == PartyService.ERR_DEPLOY_FULL and roster.get_deployed_ids() == ["merc_1", "merc_2", "merc_3"] and saves[0] == 3, "AC09 A 4th is refused (出戰傭兵已達上限), nothing kicked out, no save")
	var again := PartyService.set_deployed(roster, "merc_2", true, persist)
	_check(not again["success"] and again["reason"] == PartyService.ERR_ALREADY_DEPLOYED and roster.get_deployed_ids().size() == 3, "AC08 The same instance cannot be deployed twice")
	var undeploy := PartyService.set_deployed(roster, "merc_2", false, persist)
	_check(undeploy["success"] and roster.get_deployed_ids() == ["merc_1", "merc_3"] and saves[0] == 4, "AC10 Undeploy merc_2, saved")
	_check(not PartyService.set_deployed(roster, "merc_2", false, persist)["success"], "Undeploying a waiting one is refused")
	_check(PartyService.set_deployed(roster, "merc_4", true, persist)["success"] and roster.get_deployed_ids() == ["merc_1", "merc_3", "merc_4"], "Swap: merc_4 joins after merc_2 left")
	for id in [null, "", "merc_9", "hero", 3]:
		var before := JSON.stringify(roster.get_snapshot())
		var refused := PartyService.set_deployed(roster, id, true, persist)
		_check(not refused["success"] and refused["reason"] == PartyService.ERR_UNKNOWN_MERCENARY and JSON.stringify(roster.get_snapshot()) == before, "Unknown id %s refused, nothing changes" % str(id))
	# Repeated toggling.
	var toggling := _roster(["GUARDIAN"])
	for round in range(20):
		_check(PartyService.set_deployed(toggling, "merc_1", round % 2 == 0)["success"], "Toggle round %d" % round)
	_check(toggling.get_deployed_ids().is_empty(), "20 toggles end waiting")
	_check(PartyService.set_deployed(null, "merc_1", true)["reason"] == PartyService.ERR_INVALID_STATE, "No roster: refused, no crash")
	_sections_done.append("deployment")


# --- Service: dismissal --------------------------------------------------------------------------------

func _verify_dismissal() -> void:
	var roster := _roster(["MAGE", "GUARDIAN", "STRATEGIST"])
	roster.set_deployment(["merc_1"])
	var deployed := PartyService.dismiss(roster, "merc_1", func() -> bool: return true)
	_check(not deployed["success"] and deployed["reason"] == PartyService.ERR_DEPLOYED and roster.get_mercenary("merc_1") != null and roster.is_deployed("merc_1"), "AC14 A deployed one is refused (請先取消出戰), nothing changes")
	var saves := [0]
	var result := PartyService.dismiss(roster, "merc_2", func() -> bool:
		saves[0] += 1
		return true)
	_check(result["success"] and roster.get_mercenary("merc_2") == null and roster.get_owned_count() == 2 and saves[0] == 1, "AC13/AC17/AC20 A waiting one is dismissed for good, saved")
	_check(not roster.add(Mercenary.create("merc_2", "GUARDIAN")) and roster.create_mercenary("MAGE").get_id() == "merc_4", "AC19 merc_2 is retired: refused if added again; the next id is merc_4")
	var stale := PartyService.dismiss(roster, "merc_2", func() -> bool: return true)
	_check(not stale["success"] and stale["reason"] == PartyService.ERR_UNKNOWN_MERCENARY, "A repeated / stale dismissal is refused")
	_check(PartyService.dismiss(null, "merc_1")["reason"] == PartyService.ERR_INVALID_STATE, "No roster: refused, no crash")
	_check(not "wallet" in _code_only("res://scripts/party_service.gd").to_lower() and not "money" in _code_only("res://scripts/party_service.gd").to_lower(), "AC18 Dismissal never touches money (no refund)")
	_sections_done.append("dismissal")


# --- Service: save failure rollback -----------------------------------------------------------------------

func _verify_rollback() -> void:
	var roster := _roster(["MAGE", "MAGE", "GUARDIAN", "STRATEGIST"])
	roster.get_mercenary("merc_2").add_exp(400)
	roster.get_mercenary("merc_2").allocate({"agi": 2})
	roster.set_deployment(["merc_2", "merc_3"])
	roster.remove("merc_4")
	var before := JSON.stringify(roster.get_snapshot())
	var fail := func() -> bool: return false
	var deploy := PartyService.set_deployed(roster, "merc_1", true, fail)
	_check(not deploy["success"] and deploy["reason"] == PartyService.ERR_SAVE_FAILED and JSON.stringify(roster.get_snapshot()) == before, "AC12 Deploy + failed save: the roster is exactly as before")
	var undeploy := PartyService.set_deployed(roster, "merc_3", false, fail)
	_check(not undeploy["success"] and JSON.stringify(roster.get_snapshot()) == before and roster.is_deployed("merc_3"), "AC12 Undeploy + failed save: merc_3 still deployed")
	var dismiss := PartyService.dismiss(roster, "merc_1", fail)
	_check(not dismiss["success"] and dismiss["reason"] == PartyService.ERR_SAVE_FAILED and JSON.stringify(roster.get_snapshot()) == before and roster.get_mercenary("merc_1") != null, "AC21 Dismiss + failed save: merc_1 back, deployment and ids as before")
	_check(not roster.add(Mercenary.create("merc_4", "STRATEGIST")) and roster.create_mercenary("MAGE").get_id() == "merc_5", "After the rollbacks: merc_4 still retired, next id merc_5")
	# What the save sees: the changed roster.
	var seen := []
	var watched := _roster(["MAGE"])
	PartyService.set_deployed(watched, "merc_1", true, func() -> bool:
		seen.append(watched.get_deployed_ids())
		return false)
	_check(seen == [["merc_1"]] and watched.get_deployed_ids().is_empty(), "The save is asked with the change applied; the rollback removes it")
	_sections_done.append("rollback")


# --- Game: roster view -------------------------------------------------------------------------------------

func _verify_game_roster() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main()
	var hub := main.get_node("CityHub") as CityHub
	await _enter_city(main)
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	await process_frame
	_check(hub.get_mercenary_view() == CityHub.MERCENARY_VIEW_RECRUIT and hub.get_deployed_count_text() == "出戰傭兵：0 / 3", "The center opens on 招聘 with 出戰傭兵：0 / 3")
	(hub.get_node("Center/Content/MercenaryPanel/MercenaryViews/RosterViewButton") as Button).pressed.emit()
	await process_frame
	_check(hub.get_mercenary_view() == CityHub.MERCENARY_VIEW_ROSTER and hub.get_roster_ids().is_empty() and (hub.get_node("Center/Content/MercenaryPanel/RosterScroll/RosterBox/RosterEmptyLabel") as Label).visible, "我的傭兵 with 0 owned: 尚未持有傭兵")
	for type in ["MAGE", "MAGE", "GUARDIAN", "STRATEGIST", "MAGE"]:
		main.recruit_mercenary(type)
	main.mercenary_roster.get_mercenary("merc_2").add_exp(100 + 150 + 50)
	main.mercenary_roster.get_mercenary("merc_2").allocate({"hp": 2, "int": 3})
	main._refresh_hub_summary()
	await process_frame
	_check(hub.get_roster_ids() == ["merc_1", "merc_2", "merc_3", "merc_4", "merc_5"] and not (hub.get_node("Center/Content/MercenaryPanel/RosterScroll/RosterBox/RosterEmptyLabel") as Label).visible, "AC01 All 5 owned shown, in order")
	var texts := hub.get_roster_row_texts("merc_2")
	_check(texts["TitleLabel"] == "法師 #2　Lv.3　遠程法術型　【待命】", "AC02 Type, identity, Level, role, status (%s)" % texts["TitleLabel"])
	_check(texts["HintLabel"] == "在後方以法術攻擊敵人" and texts["ProgressLabel"] == "經驗 50 / 200　未分配屬性點 1" and texts["AllocationLabel"] == "已分配：血量 2　力量 0　敏捷 0　智力 3", "AC03 Real data: ability line, EXP, unspent and allocated points (%s / %s)" % [texts["ProgressLabel"], texts["AllocationLabel"]])
	# Stage 8 P04 (P03 AC03, approved): the stats are real now (verify_p04);
	# equipment stays not open.
	_check(texts["PendingLabel"] == "裝備：尚未開放", "AC04 Stats / equipment shown as not open yet (no fake numbers)")
	_check(hub.get_roster_row_texts("merc_4")["TitleLabel"] == "軍師 #4　Lv.1　戰場控制型　【待命】" and hub.get_roster_row_texts("merc_3")["TitleLabel"] == "守衛 #3　Lv.1　近戰防守型　【待命】", "Duplicate / mixed types each on their own row")
	for id in hub.get_roster_ids():
		_check(hub.get_deploy_button(id).text == "設為出戰" and hub.get_dismiss_button(id).text == "解僱", "%s: 設為出戰 / 解僱" % id)
	await _destroy(main)
	_sections_done.append("game_roster")


# --- Game: deployment ----------------------------------------------------------------------------------------

func _verify_game_deployment() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main()
	var hub := main.get_node("CityHub") as CityHub
	await _enter_city(main)
	for type in ["MAGE", "MAGE", "MAGE", "GUARDIAN"]:
		main.recruit_mercenary(type)
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	hub.show_mercenary_view(CityHub.MERCENARY_VIEW_ROSTER)
	await process_frame
	var money: int = main.wallet.get_balance()
	for id in ["merc_1", "merc_2", "merc_3"]:
		_delete(TEST_SAVE)
		hub.get_deploy_button(id).pressed.emit()
		var saved: Variant = _read(TEST_SAVE)
		_check(main.mercenary_roster.is_deployed(id) and saved != null and (saved["mercenaries"]["deployed"] as Array).has(id), "AC11 %s deployed and saved at once" % id)
		_check(hub.get_feedback_text() == "法師 #%s已設為出戰" % id.substr(5) and hub.get_roster_row_texts(id)["TitleLabel"].ends_with("【出戰中】") and hub.get_deploy_button(id).text == "取消出戰", "%s: feedback, 【出戰中】, 取消出戰" % id)
	_check(hub.get_deployed_count_text() == "出戰傭兵：3 / 3" and main.mercenary_roster.get_party_ids() == ["hero", "merc_1", "merc_2", "merc_3"], "AC07 3 / 3: three Mages deployed with the Hero")
	_delete(TEST_SAVE)
	hub.get_deploy_button("merc_4").pressed.emit()
	_check(hub.get_feedback_text() == "出戰傭兵已達上限" and not main.mercenary_roster.is_deployed("merc_4") and main.mercenary_roster.get_deployed_ids().size() == 3 and not FileAccess.file_exists(TEST_SAVE), "AC09 4th: 出戰傭兵已達上限, nothing kicked out, nothing saved")
	# Undeploy, then a save failure on deploy.
	hub.get_deploy_button("merc_2").pressed.emit()
	_check(hub.get_feedback_text() == "法師 #2已取消出戰" and hub.get_deployed_count_text() == "出戰傭兵：2 / 3" and hub.get_deploy_button("merc_2").text == "設為出戰", "AC10 取消出戰: 2 / 3")
	main.save_path = BAD_SAVE
	var before := JSON.stringify(main.mercenary_roster.get_snapshot())
	hub.get_deploy_button("merc_4").pressed.emit()
	_check(hub.get_feedback_text() == "無法儲存，隊伍變更已取消" and JSON.stringify(main.mercenary_roster.get_snapshot()) == before and hub.get_deployed_count_text() == "出戰傭兵：2 / 3" and hub.get_deploy_button("merc_4").text == "設為出戰", "AC12 Save failure: 無法儲存，隊伍變更已取消, nothing changed")
	main.save_path = TEST_SAVE
	hub.get_deploy_button("merc_4").pressed.emit()
	_check(main.mercenary_roster.get_deployed_ids() == ["merc_1", "merc_3", "merc_4"] and main.wallet.get_balance() == money, "Deploy merc_4 now; money untouched by deployment")
	# Rapid toggling through the button.
	for press in range(11):
		hub.get_deploy_button("merc_2").pressed.emit()
	_check(main.mercenary_roster.get_deployed_ids().size() == 3 and not main.mercenary_roster.is_deployed("merc_2"), "11 rapid presses at 3 / 3: merc_2 never becomes a 4th")
	hub.get_deploy_button("merc_4").pressed.emit()
	for press in range(11):
		hub.get_deploy_button("merc_2").pressed.emit()
	_check(main.mercenary_roster.is_deployed("merc_2") and main.mercenary_roster.get_deployed_ids().size() == 3, "11 rapid toggles from waiting end deployed (odd count), still 3")
	# Restart.
	var deployed: Array = main.mercenary_roster.get_deployed_ids()
	await _destroy(main)
	main = await _new_main()
	hub = main.get_node("CityHub") as CityHub
	_check(main.mercenary_roster.get_deployed_ids() == deployed and main.mercenary_roster.get_owned_count() == 4, "AC22 Restart: the deployment %s is kept" % str(deployed))
	if not hub.is_open():
		await _enter_city(main)
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	hub.show_mercenary_view(CityHub.MERCENARY_VIEW_ROSTER)
	await process_frame
	_check(hub.get_deployed_count_text() == "出戰傭兵：3 / 3" and hub.get_deploy_button(deployed[0]).text == "取消出戰", "Restart: the view shows 3 / 3")
	_check(main.set_mercenary_deployed("merc_1", false)["success"] and main.leave_city() and main.set_mercenary_deployed("merc_1", true)["reason"] == "ERR_NOT_IN_CITY", "Outside a city: no party change")
	await _destroy(main)
	_sections_done.append("game_deployment")


# --- Game: dismissal --------------------------------------------------------------------------------------

func _verify_game_dismissal() -> void:
	_delete(TEST_SAVE)
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
	# A deployed one: no confirmation, a clear refusal.
	hub.get_dismiss_button("merc_1").pressed.emit()
	_check(not hub.is_dismiss_confirm_open() and hub.get_feedback_text() == "請先取消出戰，再解僱傭兵" and main.mercenary_roster.get_mercenary("merc_1") != null and main.mercenary_roster.is_deployed("merc_1"), "AC14 Deployed: 請先取消出戰，再解僱傭兵, no confirmation, nothing changes")
	_check(main.dismiss_mercenary("merc_1")["reason"] == PartyService.ERR_DEPLOYED, "AC14 The rule holds in main / the service too")
	# The confirmation; cancel changes nothing.
	var before := JSON.stringify(main.mercenary_roster.get_snapshot())
	hub.get_dismiss_button("merc_2").pressed.emit()
	await process_frame
	_check(hub.is_dismiss_confirm_open() and hub.get_dismiss_confirm() == {"id": "merc_2", "title": "確定解僱守衛 #2？"} and (hub.get_node("DismissModal") as Control).mouse_filter == Control.MOUSE_FILTER_STOP, "AC15 解僱 opens the confirmation: 確定解僱守衛 #2？ (it takes every touch)")
	_check((hub.get_node("DismissModal").find_child("NoteLabel", true, false) as Label).text == "解僱後無法復原，亦不會退還招聘費用。" and hub.get_dismiss_cancel_button().text == "取消" and hub.get_dismiss_confirm_button().text == "確定解僱（5）", "The warning and 取消 / 確定解僱 (Stage 8 L3 corrective: a 5 s countdown first, 確定解僱（5）)")
	hub.get_dismiss_cancel_button().pressed.emit()
	_check(not hub.is_dismiss_confirm_open() and JSON.stringify(main.mercenary_roster.get_snapshot()) == before and main.wallet.get_balance() == money, "AC16 取消: nothing changes")
	# Confirm (with repeated taps).
	_delete(TEST_SAVE)
	hub.get_dismiss_button("merc_2").pressed.emit()
	# Stage 8 L3 corrective: the 5 s safety countdown runs out first.
	hub.advance_dismiss_countdown(CityHub.DISMISS_COUNTDOWN_SECONDS)
	var confirm := hub.get_dismiss_confirm_button()
	confirm.pressed.emit()
	confirm.pressed.emit()
	confirm.pressed.emit()
	_check(main.mercenary_roster.get_mercenary("merc_2") == null and main.mercenary_roster.get_owned_count() == 2 and not hub.is_dismiss_confirm_open(), "AC17 確定解僱 (three taps): merc_2 dismissed once")
	_check(main.wallet.get_balance() == money and hub.get_feedback_text() == "已解僱守衛 #2" and hub.get_mercenary_count_text() == "持有傭兵：2 / 5" and not hub.get_roster_ids().has("merc_2"), "AC18 No refund; 已解僱守衛 #2; 2 / 5; the row is gone")
	var saved: Variant = _read(TEST_SAVE)
	_check(saved != null and (saved["mercenaries"]["owned"] as Array).size() == 2 and int(saved["mercenaries"]["next_serial"]) == 4 and int(saved["money"]) == money, "AC20 Saved at once: 2 owned, next_serial 4, money unchanged")
	# A save failure on dismissal.
	main.save_path = BAD_SAVE
	before = JSON.stringify(main.mercenary_roster.get_snapshot())
	hub.get_dismiss_button("merc_3").pressed.emit()
	hub.advance_dismiss_countdown(CityHub.DISMISS_COUNTDOWN_SECONDS)
	hub.get_dismiss_confirm_button().pressed.emit()
	_check(hub.get_feedback_text() == "無法儲存，解僱已取消" and JSON.stringify(main.mercenary_roster.get_snapshot()) == before and main.mercenary_roster.get_mercenary("merc_3") != null and hub.get_roster_ids().has("merc_3") and main.wallet.get_balance() == money, "AC21 Save failure: 無法儲存，解僱已取消, merc_3 back, money unchanged")
	main.save_path = TEST_SAVE
	hub.get_dismiss_confirm_button().pressed.emit()
	_check(main.mercenary_roster.get_mercenary("merc_3") != null and not hub.is_dismiss_confirm_open(), "A stray second tap after the failed (closed) confirmation dismisses nothing")
	# Stale confirmation: the row vanishes while it is open.
	hub.get_dismiss_button("merc_3").pressed.emit()
	main.set_mercenary_deployed("merc_3", true)
	_check(hub.is_dismiss_confirm_open(), "The confirmation is still open while merc_3 got deployed elsewhere")
	hub.advance_dismiss_countdown(CityHub.DISMISS_COUNTDOWN_SECONDS)
	hub.get_dismiss_confirm_button().pressed.emit()
	_check(main.mercenary_roster.get_mercenary("merc_3") != null and hub.get_feedback_text() == "請先取消出戰，再解僱傭兵", "A stale confirmation is refused by the service (deployed now)")
	main.set_mercenary_deployed("merc_3", false)
	# Restart: dismissed stays gone, its id is never reused.
	await _destroy(main)
	main = await _new_main()
	_check(main.mercenary_roster.get_mercenary("merc_2") == null and main.mercenary_roster.get_owned_count() == 2 and main.mercenary_roster.is_deployed("merc_1"), "AC22 Restart: merc_2 still gone, merc_1 still deployed")
	if not (main.get_node("CityHub") as CityHub).is_open():
		await _enter_city(main)
	_check(main.recruit_mercenary("GUARDIAN")["mercenary_id"] == "merc_4" and not main.mercenary_roster.add(Mercenary.create("merc_2", "GUARDIAN")), "AC19 Restart: the next recruit is merc_4; merc_2 is never reused")
	await _destroy(main)
	_sections_done.append("game_dismissal")


# --- Layout ----------------------------------------------------------------------------------------------

func _verify_layout() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main()
	var hub := main.get_node("CityHub") as CityHub
	await _enter_city(main)
	for type in ["MAGE", "MAGE", "GUARDIAN", "STRATEGIST", "MAGE"]:
		main.recruit_mercenary(type)
	for id in ["merc_1", "merc_2", "merc_3"]:
		main.set_mercenary_deployed(id, true)
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	var canvas := Rect2(0.0, 0.0, 720.0, 1280.0)
	for view in [CityHub.MERCENARY_VIEW_RECRUIT, CityHub.MERCENARY_VIEW_ROSTER]:
		hub.show_mercenary_view(view)
		await process_frame
		await process_frame
		_check(canvas.encloses((hub.get_node("Center/Content") as Control).get_global_rect()), "AC25 The %s view with 5 owned fits 720 x 1280 (%s)" % [view, str((hub.get_node("Center/Content") as Control).get_global_rect())])
	for id in hub.get_roster_ids():
		for button in [hub.get_deploy_button(id), hub.get_dismiss_button(id)]:
			var rect: Rect2 = button.get_global_rect()
			_check(rect.size.x >= 100.0 and rect.size.y >= 88.0 and canvas.encloses(rect), "%s %s: %s, inside the screen" % [id, button.text, str(rect.size)])
		var title := hub._roster_rows[id].find_child("TitleLabel", true, false) as Label
		_check(title.get_global_rect().end.x <= hub.get_deploy_button(id).get_global_rect().position.x, "%s: the title does not run under the buttons" % id)
	for node_name in ["MoneyLabel", "FeedbackLabel", "LeaveButton"]:
		_check(canvas.encloses((hub.get_node("Center/Content/" + node_name) as Control).get_global_rect()), "%s inside the screen" % node_name)
	hub.get_dismiss_button("merc_4").pressed.emit()
	await process_frame
	var panel := hub.get_node("DismissModal/DismissPanel") as Control
	_check(canvas.encloses(panel.get_global_rect()) and canvas.encloses(hub.get_dismiss_confirm_button().get_global_rect()) and hub.get_dismiss_confirm_button().get_global_rect().size.y >= 88.0, "The confirmation and its buttons fit the screen")
	hub.show_facility(CityHub.FACILITY_MARKET)
	_check(not hub.is_dismiss_confirm_open(), "Leaving the center closes an open confirmation")
	await _destroy(main)
	_sections_done.append("layout")


# --- Scope -----------------------------------------------------------------------------------------------

func _verify_scope() -> void:
	_check(SaveStore.VERSION == 13, "AC23 Save v11")
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_view.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_config.gd", "res://scripts/character_config.gd", "res://scripts/save_store.gd"]:
		var code := _code_only(path).to_lower()
		_check(not code.contains("deploy") and not code.contains("dismiss") and not code.contains("partyservice"), "AC24 %s knows nothing about deployment / dismissal" % path.get_file())
	var main_code := _code_only("res://scripts/main.gd")
	var start := main_code.find("func _start_combat()")
	var start_body := main_code.substr(start, main_code.find("\nfunc ", start + 1) - start)
	# Stage 8 P04 (approved): combat starts from the Hero + the deployed roster
	# (read only: it never deploys / dismisses).
	# Stage 9 P04 (approved): plus each deployed Mercenary's authoritative
	# stats (CharacterCarrying, by stable id).
	_check(start > 0 and start_body.contains("CombatBattle.from_party(_encounter_session.get_context(), character_stats, mercenary_roster.get_deployed(), get_deployed_combat_stats())") and not start_body.contains("set_deployed") and not start_body.contains("dismiss") and not start_body.contains("PartyService"), "AC24 Combat starts from the Hero + the roster deployment (P04), read only")
	var party_start := main_code.find("func get_party_stats()")
	_check(party_start > 0 and not main_code.substr(party_start, main_code.find("\nfunc ", party_start + 1) - party_start).contains("mercenary_roster"), "get_party_stats() is still the fixed Hero / merc_a / merc_b")
	var party := _code_only("res://scripts/party_service.gd")
	for word in ["position", "formation", "row", "CombatBattle", "SaveStore", "equipment", "backpack", "inventory"]:
		_check(not party.to_lower().contains(word.to_lower()), "PartyService has no %s" % word)
	_sections_done.append("scope")


# --- Stress (seeded) -----------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261004
	var roster := MercenaryRoster.new()
	var issued := {}
	var ok := true
	var outcomes := {}
	for step in range(4000):
		var save_ok := rng.randi_range(0, 4) > 0
		var owned := roster.get_owned()
		var id: Variant = owned[rng.randi_range(0, owned.size() - 1)].get_id() if not owned.is_empty() else "merc_1"
		if rng.randi_range(0, 9) == 0:
			id = "merc_%d" % rng.randi_range(1, 60)
		var before := JSON.stringify(roster.get_snapshot())
		var result: Dictionary
		match rng.randi_range(0, 4):
			0:
				var created := roster.create_mercenary(["GUARDIAN", "MAGE", "STRATEGIST"][rng.randi_range(0, 2)])
				if created != null:
					ok = ok and not issued.has(created.get_id())
					issued[created.get_id()] = true
				continue
			1, 2:
				result = PartyService.set_deployed(roster, id, rng.randi_range(0, 2) > 0, func() -> bool: return save_ok)
			_:
				result = PartyService.dismiss(roster, id, func() -> bool: return save_ok)
		outcomes[result["reason"]] = int(outcomes.get(result["reason"], 0)) + 1
		if not result["success"]:
			ok = ok and JSON.stringify(roster.get_snapshot()) == before
		var deployed := roster.get_deployed_ids()
		var unique := {}
		for d in deployed:
			ok = ok and roster.get_mercenary(d) != null and not unique.has(d)
			unique[d] = true
		ok = ok and deployed.size() <= 3 and roster.get_owned_count() <= 5
		# Every few steps, a save / reload keeps everything.
		if step % 25 == 0:
			var reloaded := MercenaryRoster.from_dict(JSON.parse_string(JSON.stringify(roster.to_dict())))
			ok = ok and reloaded != null and JSON.stringify(reloaded.to_dict()) == JSON.stringify(roster.to_dict())
			for retired in issued:
				if roster.get_mercenary(retired) == null:
					ok = ok and not reloaded.add(Mercenary.create(retired, "MAGE"))
			roster.restore_snapshot({"state": reloaded.to_dict(), "used_ids": roster.get_snapshot()["used_ids"]})
		if not ok:
			_check(false, "Stress broke at step %d (%s)" % [step, str(result)])
			break
	_check(ok, "4000 seeded deploy / undeploy / dismiss / save-failure steps: refusals change nothing, ≤ 3 deployed, owned, unique; reloads exact; retired ids never come back")
	for reason in ["", PartyService.ERR_SAVE_FAILED, PartyService.ERR_DEPLOY_FULL, PartyService.ERR_DEPLOYED, PartyService.ERR_UNKNOWN_MERCENARY, PartyService.ERR_ALREADY_DEPLOYED, PartyService.ERR_NOT_DEPLOYED]:
		_check(int(outcomes.get(reason, 0)) > 20, "Outcome %s exercised (%d)" % [reason if reason != "" else "success", int(outcomes.get(reason, 0))])
	_sections_done.append("stress")


# --- Helpers -----------------------------------------------------------------------------------------------

func _roster(types: Array) -> MercenaryRoster:
	var roster := MercenaryRoster.new()
	for type in types:
		roster.create_mercenary(type)
	return roster


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
