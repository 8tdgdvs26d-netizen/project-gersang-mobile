extends SceneTree

## Stage 9 P02: Equipment Shop (裝備商店) — buy only, acquisition only.
##   catalog      the four P01 items at the approved Prototype prices (300 /
##                300 / 250 / 250); weight / slot / bonus only from
##                EquipmentCatalog
##   service      EquipmentShopService.buy: Hero / every owned Mercenary by
##                stable id, exact money, exactly 1 carried item (never
##                equipped), insufficient money / capacity / over capacity,
##                unknown item / character, pending / dismissed, same-type
##                identity, repeated purchases, save success / failure
##                rollback (money + every character), no duplication / loss
##   layout       five facility tabs in one row (128 x 64, 8 px), inside 720,
##                not overlapping, labels readable, Leave City still clear of
##                the world Enter City button in every view
##   game         the real City Hub: 裝備商店 rows, recipient picker by
##                stable id, purchase, feedback, save, restart, save failure
##   scope        no schema change (v13), no selling / equip flow / combat
##   stress       TARGETED: random purchases over recipients / items with
##                save failures and reloads

const TEST_SAVE := "user://s9_p02_equipment_shop_test.json"
const BAD_SAVE := "user://s9_p02_missing_dir/save.json"
const T0 := 1800000000000
const W1 := "test_weapon_01"
const W2 := "test_weapon_02"
const A1 := "test_armor_01"
const A2 := "test_armor_02"
const ALL := [W1, W2, A1, A2]
const PRICES := {W1: 300, W2: 300, A1: 250, A2: 250}

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_verify_catalog()
	_verify_service()
	await _verify_layout()
	await _verify_game()
	_verify_scope()
	await _verify_stress()
	_check(_sections_done.size() == 6, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S9 P02 equipment shop verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Catalogue --------------------------------------------------------------------------------------------

func _verify_catalog() -> void:
	_check(EquipmentShopService.get_item_ids() == ALL, "AC02 The four P01 items are on sale, in catalog order")
	for item_id in ALL:
		_check(EquipmentShopService.get_price(item_id) == PRICES[item_id], "AC04 %s costs $%d" % [item_id, PRICES[item_id]])
	_check(EquipmentShopService.PRICES == PRICES, "AC04 Exactly the approved prices (no other item, no city / dynamic price)")
	_check(EquipmentShopService.get_price("test_good_01") == 0 and EquipmentShopService.get_price("nope") == 0 and EquipmentShopService.get_price(null) == 0, "Not on sale: no price")
	var code := _code_only("res://scripts/equipment_shop_service.gd")
	_check(not code.contains("capacity_cost") and not code.contains("bonuses") and not code.contains("\"slot\"") and not code.contains("display_name"), "AC03 / AC16 The shop holds no weight, slot, bonus or name: EquipmentCatalog stays authoritative")
	var full := FileAccess.get_file_as_string("res://scripts/equipment_shop_service.gd")
	_check(full.contains("PROTOTYPE TEST") and full.contains("not final balance"), "Prices marked as Prototype test values")
	_sections_done.append("catalog")


# --- Service ----------------------------------------------------------------------------------------------

func _verify_service() -> void:
	# AC05 / AC07-AC10: the Hero buys each item.
	var party := _party(["GUARDIAN"], 5000)
	var carrying: CharacterCarrying = party["carrying"]
	var wallet: Wallet = party["wallet"]
	var spent := 0
	for item_id in ALL:
		var before := wallet.get_balance()
		var load := carrying.get_load("hero")
		var result := EquipmentShopService.buy(wallet, carrying, "hero", item_id)
		spent += PRICES[item_id]
		_check(result == {"success": true, "reason": "", "character_id": "hero", "item_id": item_id, "price": PRICES[item_id]}, "AC07 Hero buys %s (%s)" % [item_id, str(result)])
		_check(wallet.get_balance() == before - PRICES[item_id], "AC08 Exactly $%d deducted" % PRICES[item_id])
		_check(carrying.get_equipment("hero").get_carried_quantity(item_id) == 1 and carrying.get_load("hero") == load + EquipmentCatalog.get_capacity_cost(item_id), "AC09 / AC16 Exactly 1 carried, load + its catalog weight %d" % EquipmentCatalog.get_capacity_cost(item_id))
	_check(carrying.get_equipment("hero").get_equipped_items() == {} and (party["stats"] as CharacterStats).get_equipment_bonuses() == {}, "AC10 Nothing auto-equipped; no bonus")
	_check(wallet.get_balance() == 5000 - spent and carrying.get_equipment("merc_1").is_empty(), "Total $%d; the Mercenary untouched" % spent)
	# AC06 / AC19: Mercenaries by stable id, same type kept apart.
	var mercs := _party(["MAGE", "MAGE", "GUARDIAN"], 5000)
	var mc: CharacterCarrying = mercs["carrying"]
	var mw: Wallet = mercs["wallet"]
	_check(EquipmentShopService.buy(mw, mc, "merc_2", W2)["success"] and mc.get_equipment("merc_2").get_carried() == {W2: 1}, "AC06 merc_2 (MAGE) receives 測試武器二")
	_check(mc.get_equipment("merc_1").is_empty() and mc.get_equipment("merc_3").is_empty() and mc.get_equipment("hero").is_empty(), "AC19 merc_1 (also MAGE), merc_3 and the Hero receive nothing")
	_check(EquipmentShopService.buy(mw, mc, "merc_1", A2)["success"] and mc.get_equipment("merc_1").get_carried() == {A2: 1} and mc.get_equipment("merc_2").get_carried() == {W2: 1}, "AC19 merc_1 buys its own; each keeps exactly its own")
	_check(EquipmentShopService.buy(mw, mc, "merc_3", A1)["success"] and mw.get_balance() == 5000 - 300 - 250 - 250, "AC06 merc_3 too; money exact")
	# Repeated purchases of the same item.
	var repeat := _party([], 2000)
	for n in range(5):
		EquipmentShopService.buy(repeat["wallet"], repeat["carrying"], "hero", A1)
	_check((repeat["carrying"] as CharacterCarrying).get_equipment("hero").get_carried_quantity(A1) == 5 and (repeat["wallet"] as Wallet).get_balance() == 2000 - 5 * 250, "Five purchases: 5 carried, $1,250 paid")
	# AC11 insufficient money (exact boundary).
	var poor := _party([], 299)
	var poor_state := _state(poor)
	var r := EquipmentShopService.buy(poor["wallet"], poor["carrying"], "hero", W1)
	_check(not r["success"] and r["reason"] == EquipmentShopService.ERR_INSUFFICIENT_FUNDS and _state(poor) == poor_state, "AC11 $299 for a $300 weapon: refused, zero mutation")
	var exact := _party([], 300)
	_check(EquipmentShopService.buy(exact["wallet"], exact["carrying"], "hero", W1)["success"] and (exact["wallet"] as Wallet).get_balance() == 0, "Exactly $300: bought, $0 left")
	# AC12 capacity: exact boundary and one beyond (Hero Capacity 100).
	var full := _party([], 100000)
	(full["inventory"] as CharacterInventory).add("test_good_06", 24)
	(full["inventory"] as CharacterInventory).add("test_good_01", 1)
	_check((full["carrying"] as CharacterCarrying).get_load("hero") == 97, "Fixture: load 97 / 100")
	_check(EquipmentShopService.buy(full["wallet"], full["carrying"], "hero", A2)["success"] and (full["carrying"] as CharacterCarrying).get_load("hero") == 100, "Exact boundary: 97 + 3 = 100 bought")
	var full_state := _state(full)
	r = EquipmentShopService.buy(full["wallet"], full["carrying"], "hero", W2)
	_check(not r["success"] and r["reason"] == EquipmentShopService.ERR_INSUFFICIENT_CAPACITY and _state(full) == full_state, "AC12 One point beyond (100 + 2): refused, zero mutation")
	var near := _party([], 100000)
	(near["inventory"] as CharacterInventory).add("test_good_06", 24)
	(near["inventory"] as CharacterInventory).add("test_good_01", 2)
	var near_state := _state(near)
	r = EquipmentShopService.buy(near["wallet"], near["carrying"], "hero", A1)
	_check(not r["success"] and r["reason"] == EquipmentShopService.ERR_INSUFFICIENT_CAPACITY and _state(near) == near_state, "AC12 98 + 4 = 102: refused (weight from the catalog), zero mutation")
	_check(EquipmentShopService.buy(near["wallet"], near["carrying"], "hero", W2)["success"], "98 + 2 = 100: the lighter item fits")
	# AC13 already over capacity (legal P01 state).
	var over := _party([], 100000)
	var oc: CharacterCarrying = over["carrying"]
	oc.add_equipment("hero", W1, 1)
	oc.equip("hero", W1)
	(over["inventory"] as CharacterInventory).add("test_good_06", 28)
	oc.unequip("hero", "WEAPON")
	_check(oc.is_over_capacity("hero"), "Fixture: the Hero is over capacity (118 / 100)")
	var over_state := _state(over)
	for item_id in ALL:
		r = EquipmentShopService.buy(over["wallet"], oc, "hero", item_id)
		_check(not r["success"] and r["reason"] == EquipmentShopService.ERR_INSUFFICIENT_CAPACITY and _state(over) == over_state, "AC13 Over capacity: %s refused, zero mutation" % item_id)
	# A Mercenary's own capacity.
	var mfull := _party(["GUARDIAN"], 100000)
	(mfull["carrying"] as CharacterCarrying).add_equipment("merc_1", A1, 24)
	(mfull["carrying"] as CharacterCarrying).add_equipment("merc_1", W2, 1)
	var mstate := _state(mfull)
	r = EquipmentShopService.buy(mfull["wallet"], mfull["carrying"], "merc_1", A1)
	_check(not r["success"] and r["reason"] == EquipmentShopService.ERR_INSUFFICIENT_CAPACITY and _state(mfull) == mstate, "A Mercenary at 98 / 100 cannot take a weight-4 item (its own Capacity); no fallback to the Hero")
	_check(EquipmentShopService.buy(mfull["wallet"], mfull["carrying"], "hero", A1)["success"], "The Hero (own Capacity) still can")
	# AC14 / AC15 invalid characters and items.
	var bad := _party(["GUARDIAN", "MAGE"], 5000)
	(bad["roster"] as MercenaryRoster).pend_legacy(Mercenary.create("merc_a", "GUARDIAN"))
	(bad["roster"] as MercenaryRoster).remove("merc_2")
	var bad_state := _state(bad)
	var refusals := {
		"unknown id": ["merc_9", W1, EquipmentShopService.ERR_UNKNOWN_CHARACTER],
		"pending merc_a": ["merc_a", W1, EquipmentShopService.ERR_UNKNOWN_CHARACTER],
		"dismissed merc_2": ["merc_2", W1, EquipmentShopService.ERR_UNKNOWN_CHARACTER],
		"empty id": ["", W1, EquipmentShopService.ERR_UNKNOWN_CHARACTER],
		"type as id": ["GUARDIAN", W1, EquipmentShopService.ERR_UNKNOWN_CHARACTER],
		"number id": [1, W1, EquipmentShopService.ERR_INVALID_REQUEST],
		"null id": [null, W1, EquipmentShopService.ERR_INVALID_REQUEST],
		"unknown item": ["hero", "test_helmet_01", EquipmentShopService.ERR_UNKNOWN_EQUIPMENT],
		"a trade good": ["hero", "test_good_01", EquipmentShopService.ERR_UNKNOWN_EQUIPMENT],
		"empty item": ["hero", "", EquipmentShopService.ERR_UNKNOWN_EQUIPMENT],
		"null item": ["hero", null, EquipmentShopService.ERR_INVALID_REQUEST],
	}
	for label in refusals:
		var request: Array = refusals[label]
		r = EquipmentShopService.buy(bad["wallet"], bad["carrying"], request[0], request[1])
		_check(not r["success"] and r["reason"] == request[2] and _state(bad) == bad_state, "AC14 / AC15 %s: %s, zero mutation" % [label, r["reason"]])
	_check(EquipmentShopService.buy(null, bad["carrying"], "hero", W1)["reason"] == EquipmentShopService.ERR_INVALID_STATE and EquipmentShopService.buy(bad["wallet"], null, "hero", W1)["reason"] == EquipmentShopService.ERR_INVALID_STATE and _state(bad) == bad_state, "No wallet / carrying: invalid state")
	# AC17 save success / AC18 save failure rollback.
	var saved := _party(["MAGE"], 1000)
	var calls := []
	r = EquipmentShopService.buy(saved["wallet"], saved["carrying"], "merc_1", W2, func() -> bool:
		calls.append(_state(saved))
		return true)
	_check(r["success"] and calls.size() == 1 and calls[0] == _state(saved) and (saved["wallet"] as Wallet).get_balance() == 700 and (saved["carrying"] as CharacterCarrying).get_equipment("merc_1").get_carried() == {W2: 1}, "The save runs once, seeing the paid money and the new item")
	var failing := _party(["MAGE", "MAGE"], 1000)
	(failing["carrying"] as CharacterCarrying).add_equipment("merc_2", A1, 1)
	(failing["carrying"] as CharacterCarrying).equip("merc_2", A1)
	(failing["carrying"] as CharacterCarrying).add_equipment("hero", W1, 1)
	var failing_state := _state(failing)
	var hero_profile := (failing["stats"] as CharacterStats).get_combat_profile()
	for item_id in ALL:
		for id in ["hero", "merc_1", "merc_2"]:
			r = EquipmentShopService.buy(failing["wallet"], failing["carrying"], id, item_id, func() -> bool: return false)
			_check(not r["success"] and r["reason"] == EquipmentShopService.ERR_SAVE_FAILED and _state(failing) == failing_state, "AC18 Save failure (%s for %s): money and every character restored exactly" % [item_id, id])
	_check((failing["stats"] as CharacterStats).get_combat_profile() == hero_profile and (failing["carrying"] as CharacterCarrying).get_equipment("merc_2").get_equipped("ARMOR") == A1, "AC18 Equipped gear and bonuses untouched by the rollback")
	_sections_done.append("service")


# --- Layout -----------------------------------------------------------------------------------------------

func _verify_layout() -> void:
	_clean()
	var main := await _new_main("")
	await _enter_city(main)
	var hub := main.get_node("CityHub") as CityHub
	var canvas := Rect2(0.0, 0.0, 720.0, 1280.0)
	var tabs := hub.get_node("Center/Content/FacilityTabs") as Container
	var buttons: Array = tabs.get_children()
	_check(CityHub.FACILITIES == ["market", "transport", "warehouse", "mercenary", "equipment"] and buttons.size() == 5, "AC01 Five facilities, five tabs (裝備商店 the fifth)")
	_check(tabs is HBoxContainer and tabs.get_theme_constant("separation") == 8, "One tab row (HBoxContainer), 8 px apart (no second row)")
	_check((hub.get_node("Center/Content/FacilityTabs/EquipmentTabButton") as Button).text == "裝備商店", "AC01 The 裝備商店 tab")
	var enter := (main.get_node("EnterControls/EnterCityButton") as Control).get_global_rect()
	for facility in CityHub.FACILITIES:
		hub.show_facility(facility)
		await process_frame
		await process_frame
		var rects := []
		var row_y := -1.0
		var ok := true
		for tab in buttons:
			var button := tab as Button
			var rect := button.get_global_rect()
			ok = ok and canvas.encloses(rect) and is_equal_approx(rect.size.x, 128.0) and is_equal_approx(rect.size.y, 64.0)
			ok = ok and button.get_minimum_size().x <= rect.size.x and not button.clip_text and button.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING
			if row_y < 0.0:
				row_y = rect.position.y
			ok = ok and is_equal_approx(rect.position.y, row_y)
			for other: Rect2 in rects:
				ok = ok and not other.intersects(rect)
			rects.append(rect)
		_check(ok, "%s view: 5 tabs 128 x 64 in one row inside 720, no overlap, every label fully shown" % facility)
		var tabs_rect := tabs.get_global_rect()
		var others := ["LeaveButton", "CityLabel", "NoteLabel", "MoneyLabel", "FeedbackLabel"]
		var clear := true
		for name in others:
			var control := hub.get_node("Center/Content/" + name) as Control
			if control.visible:
				clear = clear and not control.get_global_rect().intersects(tabs_rect)
		_check(clear, "%s view: the tab row overlaps no other main control" % facility)
		var leave := (hub.get_node("Center/Content/LeaveButton") as Control).get_global_rect()
		_check(canvas.encloses((hub.get_node("Center/Content") as Control).get_global_rect()) and not leave.intersects(enter), "%s view: fits 720 x 1280; 離開城市 clear of the world 進入城市 (%s vs %s)" % [facility, str(leave), str(enter)])
	# The 裝備商店 view's own controls.
	hub.show_facility(CityHub.FACILITY_EQUIPMENT)
	await process_frame
	await process_frame
	var controls: Array = [hub.get_node("Center/Content/EquipmentPanel/RecipientPicker/PreviousRecipientButton"), hub.get_node("Center/Content/EquipmentPanel/RecipientPicker/NextRecipientButton")]
	for item_id in ALL:
		controls.append(hub.get_equipment_buy_button(item_id))
	var inside := true
	for control in controls:
		var rect := (control as Control).get_global_rect()
		inside = inside and canvas.encloses(rect) and rect.size.y >= 88.0 and rect.size.x >= 128.0
	_check(inside, "裝備商店 buttons on screen, >= 128 x 88")
	await _destroy(main)
	_sections_done.append("layout")


# --- Real game --------------------------------------------------------------------------------------------

func _verify_game() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	var hub := main.get_node("CityHub") as CityHub
	_check(main.buy_equipment("hero", W1)["reason"] == "ERR_NOT_IN_CITY" and main.carrying.get_equipment("hero").is_empty(), "Outside a city: refused, nothing changes")
	await _enter_city(main)
	main.wallet.add(5000)
	main.recruit_mercenary("GUARDIAN")
	main.recruit_mercenary("GUARDIAN")
	hub.show_facility(CityHub.FACILITY_EQUIPMENT)
	await process_frame
	_check(hub.get_facility() == "equipment" and (hub.get_node("Center/Content/EquipmentPanel") as Control).visible and not (hub.get_node("Center/Content/MarketRows") as Control).visible, "AC01 The 裝備商店 view opens like any facility")
	_check((hub.get_node("Center/Content/NoteLabel") as Label).text == "開發原型：每次購買 1 件，放入所選角色的背包（不會自動裝備）", "The shop note (Traditional Chinese)")
	var expected_rows := {
		W1: {"name": "測試武器一　武器", "bonus": "力量 +2", "detail": "重量 3　價格 $300"},
		W2: {"name": "測試武器二　武器", "bonus": "智力 +2", "detail": "重量 2　價格 $300"},
		A1: {"name": "測試防具一　防具", "bonus": "物理防禦 +2", "detail": "重量 4　價格 $250"},
		A2: {"name": "測試防具二　防具", "bonus": "魔法防禦 +2", "detail": "重量 3　價格 $250"},
	}
	for item_id in ALL:
		_check(hub.get_equipment_row_texts(item_id) == expected_rows[item_id], "AC02 / AC03 %s row: %s" % [item_id, str(hub.get_equipment_row_texts(item_id))])
		_check(hub.get_equipment_buy_button(item_id).text == "購買", "%s: 購買 button" % item_id)
	# Recipient picker: by stable id, Hero first.
	_check(hub.get_equipment_recipient_id() == "hero" and hub.get_equipment_recipient_texts() == {"name": "收件角色：主角", "load": "背包容量：0 / 100"}, "AC05 The Hero is the default recipient (its own capacity shown)")
	(hub.get_node("Center/Content/EquipmentPanel/RecipientPicker/NextRecipientButton") as Button).pressed.emit()
	_check(hub.get_equipment_recipient_id() == "merc_1" and hub.get_equipment_recipient_texts()["name"] == "收件角色：守衛 #1", "AC06 下一位: 守衛 #1 (merc_1)")
	(hub.get_node("Center/Content/EquipmentPanel/RecipientPicker/NextRecipientButton") as Button).pressed.emit()
	_check(hub.get_equipment_recipient_id() == "merc_2" and hub.get_equipment_recipient_texts()["name"] == "收件角色：守衛 #2", "AC06 / AC19 下一位: 守衛 #2 (merc_2, same type, its own id)")
	var money: int = main.wallet.get_balance()
	hub.get_equipment_buy_button(A1).pressed.emit()
	await process_frame
	_check(main.carrying.get_equipment("merc_2").get_carried() == {A1: 1} and main.carrying.get_equipment("merc_1").is_empty() and main.carrying.get_equipment("hero").is_empty(), "AC19 The press buys for merc_2 only")
	_check(main.wallet.get_balance() == money - 250 and hub.get_feedback_text() == "已購買測試防具一，放入守衛 #2的背包", "AC08 $250 paid; feedback (%s)" % hub.get_feedback_text())
	_check(hub.get_equipment_recipient_id() == "merc_2" and hub.get_equipment_recipient_texts()["load"] == "背包容量：4 / 100", "The choice stays on merc_2; its load now 4 / 100")
	(hub.get_node("Center/Content/EquipmentPanel/RecipientPicker/NextRecipientButton") as Button).pressed.emit()
	_check(hub.get_equipment_recipient_id() == "hero", "下一位 wraps back to the Hero")
	(hub.get_node("Center/Content/EquipmentPanel/RecipientPicker/PreviousRecipientButton") as Button).pressed.emit()
	_check(hub.get_equipment_recipient_id() == "merc_2", "上一位 goes back to merc_2")
	_check(hub.select_equipment_recipient("hero") and not hub.select_equipment_recipient("merc_9") and hub.get_equipment_recipient_id() == "hero", "Only offered ids can be chosen")
	hub.get_equipment_buy_button(W1).pressed.emit()
	await process_frame
	_check(main.carrying.get_equipment("hero").get_carried() == {W1: 1} and main.carrying.get_equipment("hero").get_equipped_items() == {} and main.character_stats.get_equipment_bonuses() == {}, "AC10 Hero bought 測試武器一: carried, not equipped, no bonus")
	# AC17: the file holds it; a restart keeps money and ownership.
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(raw["version"]) == 13 and int(raw["money"]) == main.wallet.get_balance() and int(raw["carrying"]["merc_2"]["carried_equipment"][A1]) == 1 and int(raw["carrying"]["hero"]["carried_equipment"][W1]) == 1, "AC17 / AC22 Saved at once (v13, money, both items)")
	var after_money: int = main.wallet.get_balance()
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(main.wallet.get_balance() == after_money and main.carrying.get_equipment("merc_2").get_carried() == {A1: 1} and main.carrying.get_equipment("hero").get_carried() == {W1: 1} and main.carrying.get_equipment("merc_1").is_empty(), "AC17 Restart: money and each item on its own stable character")
	hub = main.get_node("CityHub") as CityHub
	if not main.is_in_city():
		await _enter_city(main)
	# Insufficient money / capacity feedback in the game.
	var poor: int = main.wallet.get_balance()
	main.wallet.spend(poor - 100)
	hub.show_facility(CityHub.FACILITY_EQUIPMENT)
	var poor_state := _main_state(main)
	hub.get_equipment_buy_button(A1).pressed.emit()
	_check(hub.get_feedback_text() == "金錢不足" and _main_state(main) == poor_state, "AC11 $100: 金錢不足, nothing changes")
	main.wallet.add(100000)
	# (Model fixture: 23 x 測試防具一 + 測試武器二 next to the bought 測試武器一 = 97.)
	main.carrying.add_equipment("hero", A1, 23)
	main.carrying.add_equipment("hero", W2, 1)
	hub.select_equipment_recipient("hero")
	var full_state := _main_state(main)
	hub.get_equipment_buy_button(A1).pressed.emit()
	_check(main.carrying.get_load("hero") == 97 and hub.get_feedback_text() == "主角的背包容量不足" and _main_state(main) == full_state, "AC12 Hero 97 / 100 + 4: 主角的背包容量不足, nothing changes (%s)" % hub.get_feedback_text())
	# AC18: save failure in the game.
	main.save_path = BAD_SAVE
	hub.select_equipment_recipient("merc_1")
	var fail_state := _main_state(main)
	hub.get_equipment_buy_button(W2).pressed.emit()
	_check(hub.get_feedback_text() == "無法儲存，購買已取消" and _main_state(main) == fail_state, "AC18 Save failure: 無法儲存，購買已取消, money and items restored")
	main.save_path = TEST_SAVE
	# P01 rule stays: the Mercenary holding the purchase cannot be dismissed.
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	_check(main.dismiss_mercenary("merc_2")["reason"] == "ERR_HAS_ITEMS" and main.mercenary_roster.get_mercenary("merc_2") != null, "Purchased gear keeps merc_2 from being dismissed (P01 rule)")
	await _destroy(main)
	_clean()
	_sections_done.append("game")


# --- Scope ------------------------------------------------------------------------------------------------

func _verify_scope() -> void:
	_check(SaveStore.VERSION == 13 and SaveStore.V13_KEYS.size() == 13, "AC22 Save schema still v13 (no new section)")
	var code := _code_only("res://scripts/equipment_shop_service.gd").to_lower()
	for word in ["sell", "buyback", "resale", "stock", "equip(", "unequip", "transfer", "warehouse", "combat", "ledger", "random"]:
		_check(not code.contains(word), "The shop has no %s" % word)
	var save_code := _code_only("res://scripts/save_store.gd").to_lower()
	_check(not save_code.contains("shop") and not save_code.contains("price"), "Nothing about the shop is saved")
	var combat_code := ""
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_view.gd"]:
		combat_code += _code_only(path).to_lower()
	_check(not combat_code.contains("equipment") and not combat_code.contains("shop"), "AC21 Combat untouched by P02")
	_check(RecruitmentService.PRICE == 1000 and MercenaryRoster.MAX_OWNED == 5 and CharacterConfig.BASE_CAPACITY == 10 and CharacterConfig.CAPACITY_PER_STR == 9, "Recruitment price, roster limit and the Capacity formula unchanged")
	_sections_done.append("scope")


# --- Stress (TARGETED) ------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9022
	var money_drift := 0
	var duplication := 0
	var identity_drift := 0
	var capacity_drift := 0
	var reload_drift := 0
	var zero_mutation_broken := 0
	var bought := 0
	var refused := 0
	var save_failures := 0
	for run in range(60):
		var types := []
		for i in range(rng.randi_range(0, 5)):
			types.append(["GUARDIAN", "MAGE", "STRATEGIST"][rng.randi_range(0, 2)])
		var party := _party(types, rng.randi_range(0, 6000))
		(party["roster"] as MercenaryRoster).pend_legacy(Mercenary.create("merc_a", "GUARDIAN"))
		if rng.randi_range(0, 2) == 0:
			(party["inventory"] as CharacterInventory).add("test_good_06", rng.randi_range(15, 25))
		var ids: Array = ["hero"] + (party["roster"] as MercenaryRoster).get_owned().map(func(m: Mercenary) -> String: return m.get_id())
		var expected_money: int = (party["wallet"] as Wallet).get_balance()
		var expected := {}
		for id in ids:
			expected[id] = {}
		for step in range(80):
			var carrying: CharacterCarrying = party["carrying"]
			var wallet: Wallet = party["wallet"]
			var id: String = (ids + ["merc_a", "merc_9"])[rng.randi_range(0, ids.size() + 1)]
			var item_id: String = (ALL + ["test_good_01"])[rng.randi_range(0, 4)]
			var fail_save := rng.randi_range(0, 5) == 0
			var before := _state(party)
			var could := carrying.is_character(id) and EquipmentShopService.PRICES.has(item_id) and wallet.can_spend(EquipmentShopService.get_price(item_id)) and carrying.can_add_equipment(id, item_id, 1)
			var r := EquipmentShopService.buy(wallet, carrying, id, item_id, func() -> bool: return not fail_save)
			if r["success"]:
				bought += 1
				expected_money -= PRICES[item_id]
				expected[id][item_id] = int(expected[id].get(item_id, 0)) + 1
				if not could or fail_save:
					zero_mutation_broken += 1
			else:
				refused += 1
				if fail_save and could:
					save_failures += 1
				if _state(party) != before:
					zero_mutation_broken += 1
			if wallet.get_balance() != expected_money:
				money_drift += 1
			for character in ids:
				if carrying.get_equipment(character).get_carried() != expected[character] or not carrying.get_equipment(character).get_equipped_items().is_empty():
					identity_drift += 1
				var load := carrying.get_inventory(character).get_goods_load()
				for each in ALL:
					load += carrying.get_equipment(character).get_total_quantity(each) * EquipmentCatalog.get_capacity_cost(each)
				if carrying.get_load(character) != load or carrying.get_capacity(character) != 10 + carrying.get_stats(character).get_effective("str") * 9:
					capacity_drift += 1
			var total := 0
			var expected_total := 0
			for character in ids:
				for each in ALL:
					total += carrying.get_equipment(character).get_total_quantity(each)
					expected_total += int(expected[character].get(each, 0))
			if total != expected_total:
				duplication += 1
			if carrying.get_equipment("merc_a") != null:
				identity_drift += 1
			if step % 20 == 19:
				var reloaded := _load(_serialize(party))
				if reloaded.is_empty() or _state({"wallet": reloaded["wallet"], "carrying": reloaded["carrying"], "roster": reloaded["mercenaries"]}) != _state(party):
					reload_drift += 1
				else:
					party = {"wallet": reloaded["wallet"], "carrying": reloaded["carrying"], "roster": reloaded["mercenaries"], "inventory": reloaded["inventory"], "stats": reloaded["character_stats"]}
	_check(bought > 300 and refused > 300 and save_failures > 30, "Stress: %d bought, %d refused (%d save failures)" % [bought, refused, save_failures])
	_check(money_drift == 0, "Stress: money drift 0 (%d)" % money_drift)
	_check(duplication == 0, "Stress: no duplication / loss (%d)" % duplication)
	_check(identity_drift == 0, "Stress: every item on the stable character that bought it; pending never receives (%d)" % identity_drift)
	_check(capacity_drift == 0, "Stress: load / Capacity exact (%d)" % capacity_drift)
	_check(zero_mutation_broken == 0, "Stress: refused / failed purchases changed nothing; only valid ones succeeded (%d)" % zero_mutation_broken)
	_check(reload_drift == 0, "Stress: save / reload identical (%d)" % reload_drift)
	# Real game: repeated purchases with save failures and restarts.
	_clean()
	var main := await _new_main(TEST_SAVE)
	await _enter_city(main)
	main.wallet.add(20000)
	main.recruit_mercenary("MAGE")
	main.recruit_mercenary("MAGE")
	var game_bad := 0
	for cycle in range(6):
		var id: String = ["hero", "merc_1", "merc_2"][cycle % 3]
		var item_id: String = ALL[cycle % 4]
		main.save_path = BAD_SAVE
		var state := _main_state(main)
		if main.buy_equipment(id, item_id)["success"] or _main_state(main) != state:
			game_bad += 1
		main.save_path = TEST_SAVE
		if not main.buy_equipment(id, item_id)["success"]:
			game_bad += 1
		var saved_state := _main_state(main)
		await _destroy(main)
		main = await _new_main(TEST_SAVE)
		if _main_state(main) != saved_state:
			game_bad += 1
		if not main.is_in_city():
			await _enter_city(main)
	_check(game_bad == 0, "Stress: 6 real-game cycles (failed save, purchase, restart) all exact (%d)" % game_bad)
	await _destroy(main)
	_clean()
	_sections_done.append("stress")


# --- Helpers ----------------------------------------------------------------------------------------------

func _party(types: Array, money: int) -> Dictionary:
	var stats := CharacterStats.new()
	var inventory := CharacterInventory.new("player", stats)
	var roster := MercenaryRoster.new()
	for type in types:
		roster.create_mercenary(type)
	var carrying := CharacterCarrying.new(inventory, func() -> MercenaryRoster: return roster)
	var wallet := Wallet.new()
	if wallet.get_balance() > money:
		wallet.spend(wallet.get_balance() - money)
	elif money > wallet.get_balance():
		wallet.add(money - wallet.get_balance())
	return {"carrying": carrying, "roster": roster, "inventory": inventory, "stats": stats, "wallet": wallet}


## Money + every character's equipment / goods + the roster as text.
func _state(party: Dictionary) -> String:
	var carrying: CharacterCarrying = party["carrying"]
	var roster: MercenaryRoster = party["roster"]
	var parts := [(party["wallet"] as Wallet).get_balance(), roster.to_dict(), roster.pending_to_list()]
	var ids := ["hero"]
	for m in roster.get_owned():
		ids.append(m.get_id())
	for id in ids:
		parts.append([id, carrying.get_equipment(id).get_equipped_items(), carrying.get_equipment(id).get_carried(), carrying.get_inventory(id).get_items(), carrying.get_stats(id).get_combat_profile()])
	return JSON.stringify(parts)


func _main_state(main: Node) -> String:
	return _state({"wallet": main.wallet, "carrying": main.carrying, "roster": main.mercenary_roster})


func _serialize(party: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(SaveStore.serialize(party["wallet"], party["inventory"], MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.new(), {"hero": party["stats"]}, party["roster"], party["carrying"])))


func _load(data: Dictionary) -> Dictionary:
	var payload := SaveStore.validate(JSON.parse_string(JSON.stringify(data)))
	return {} if payload.is_empty() else SaveStore._rebuild(payload)


func _clean() -> void:
	for p in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _enter_city(main: Node) -> void:
	(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
	await _settle()
	main.try_enter_city()
	await _settle()


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
