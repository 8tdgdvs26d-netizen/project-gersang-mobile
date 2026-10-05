extends SceneTree

## Stage 9 P05: Final iPhone acceptance fixes.
##   transfer     EquipmentTransferService (CharacterCarrying.transfer_equipment):
##                Hero <-> Mercenary, Mercenary <-> Mercenary by stable id,
##                one unequipped item, capacity, refusals, no auto-equip,
##                bonuses stay with the equipper, saved, rollback
##   panel        the real Character UI: 轉移 beside the chosen carried row,
##                the destination picker, 確定轉移, feedback, save / restart,
##                save failure, capacity refusal, layout
##   combat       transfer refused in a battle; transfer -> next battle;
##                ⓘ info shows 物理防禦 / 魔法防禦 = the CombatUnit values,
##                mitigation unchanged, readable
##   dismissal    the 無法解僱 modal (equipment / goods), no inline warning,
##                確定 closes, nothing changes, never stacked
##   scope        Save v13, equipment only (no goods move), no new formula
##   stress       TARGETED: random equip / unequip / transfer sequences with
##                capacity edges, save failures, reloads, battles, modal

const TEST_SAVE := "user://s9_p05_fixes_test.json"
const BAD_SAVE := "user://s9_p05_missing_dir/save.json"
const T0 := 1800000000000
const W1 := "test_weapon_01"
const W2 := "test_weapon_02"
const A1 := "test_armor_01"
const A2 := "test_armor_02"
const ALL := [W1, W2, A1, A2]
const PASSIVE_ONLY := Vector2(950.0, 1080.0)

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_verify_transfer()
	await _verify_panel()
	await _verify_combat()
	await _verify_dismissal()
	_verify_scope()
	await _verify_stress()
	_check(_sections_done.size() == 6, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S9 P05 final iPhone fixes verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Transfer (service) -----------------------------------------------------------------------------------

func _verify_transfer() -> void:
	var party := _party(["GUARDIAN", "GUARDIAN", "MAGE"])
	var c: CharacterCarrying = party["carrying"]
	c.add_equipment("hero", W1, 2)
	c.add_equipment("hero", A1, 1)
	var totals := _totals(c)
	# AC01 Hero -> Mercenary.
	var r := EquipmentTransferService.transfer(c, "hero", "merc_1", W1)
	_check(r["success"] and r["from_id"] == "hero" and r["to_id"] == "merc_1" and r["item_id"] == W1, "AC01 Hero -> merc_1: transferred")
	_check(c.get_equipment("hero").get_carried_quantity(W1) == 1 and c.get_equipment("merc_1").get_carried_quantity(W1) == 1, "AC05 Exactly one left the Hero and arrived at merc_1")
	_check(c.get_equipment("merc_1").get_equipped_items() == {} and c.get_stats("merc_1").get_equipment_bonuses() == {}, "AC07 Not equipped on arrival (no bonus)")
	# AC02 Mercenary -> Hero.
	r = EquipmentTransferService.transfer(c, "merc_1", "hero", W1)
	_check(r["success"] and c.get_equipment("hero").get_carried_quantity(W1) == 2 and c.get_equipment("merc_1").is_empty(), "AC02 merc_1 -> Hero: transferred back")
	# AC03 / AC04 Mercenary A -> Mercenary B (same type, stable ids).
	EquipmentTransferService.transfer(c, "hero", "merc_1", A1)
	r = EquipmentTransferService.transfer(c, "merc_1", "merc_2", A1)
	_check(r["success"] and c.get_equipment("merc_2").get_carried() == {A1: 1} and c.get_equipment("merc_1").is_empty() and c.get_equipment("merc_3").is_empty(), "AC03 / AC04 merc_1 -> merc_2 (both GUARDIAN): only merc_2 receives it")
	_check(_totals(c) == totals, "AC06 Every item counted once (no duplication / loss) %s" % str(_totals(c)))
	# AC08 Equipped: refused; unequip first.
	EquipmentService.equip(c, "merc_2", A1)
	var before := _state(party)
	r = EquipmentTransferService.transfer(c, "merc_2", "hero", A1)
	_check(not r["success"] and r["reason"] == EquipmentTransferService.ERR_EQUIPPED and _state(party) == before, "AC08 An equipped item cannot transfer (ERR_EQUIPPED), nothing changed")
	_check(EquipmentService.unequip(c, "merc_2", "ARMOR")["success"] and EquipmentTransferService.transfer(c, "merc_2", "hero", A1)["success"] and c.get_equipment("hero").get_carried_quantity(A1) == 1, "AC08 After unequipping it transfers")
	# AC16 Bonuses stay with whoever has the item equipped.
	c.add_equipment("merc_3", W2, 1)
	EquipmentService.equip(c, "merc_3", W2)
	c.add_equipment("merc_3", W2, 1)
	var merc3 := _profile(c.get_stats("merc_3"))
	r = EquipmentTransferService.transfer(c, "merc_3", "merc_1", W2)
	_check(r["success"] and _profile(c.get_stats("merc_3")) == merc3 and c.get_stats("merc_3").get_equipment_bonuses() == {"int": 2}, "AC16 merc_3 keeps its equipped INT bonus after giving away a carried copy")
	_check(c.get_stats("merc_1").get_equipment_bonuses() == {} and _profile(c.get_stats("merc_1")) == _profile(CharacterStats.for_mercenary((party["roster"] as MercenaryRoster).get_mercenary("merc_1"))), "AC16 merc_1 (carrying, not equipping) gets no bonus")
	_check(EquipmentService.equip(c, "merc_1", W2)["success"] and c.get_stats("merc_1").get_equipment_bonuses() == {"int": 2} and c.get_stats("merc_3").get_equipment_bonuses() == {"int": 2} and c.get_stats("hero").get_equipment_bonuses() == {}, "AC16 Once merc_1 equips it, merc_1 has the bonus; nobody else changes")
	# Refusals: nothing changes.
	var roster: MercenaryRoster = party["roster"]
	roster.pend_legacy(Mercenary.create("merc_a", MercenaryRoster.LEGACY_TYPES["merc_a"]))
	c.add_equipment("hero", W2, 1)
	before = _state(party)
	var refusals := [
		["unknown destination", EquipmentTransferService.transfer(c, "hero", "merc_9", W2), EquipmentTransferService.ERR_UNKNOWN_DESTINATION],
		["pending destination", EquipmentTransferService.transfer(c, "hero", "merc_a", W2), EquipmentTransferService.ERR_UNKNOWN_DESTINATION],
		["role-name destination", EquipmentTransferService.transfer(c, "hero", "GUARDIAN", W2), EquipmentTransferService.ERR_UNKNOWN_DESTINATION],
		["empty destination", EquipmentTransferService.transfer(c, "hero", "", W2), EquipmentTransferService.ERR_UNKNOWN_DESTINATION],
		["unknown source", EquipmentTransferService.transfer(c, "merc_9", "hero", W2), EquipmentTransferService.ERR_UNKNOWN_CHARACTER],
		["pending source", EquipmentTransferService.transfer(c, "merc_a", "hero", W2), EquipmentTransferService.ERR_UNKNOWN_CHARACTER],
		["same character", EquipmentTransferService.transfer(c, "hero", "hero", W2), EquipmentTransferService.ERR_SAME_CHARACTER],
		["unknown item", EquipmentTransferService.transfer(c, "hero", "merc_1", "test_weapon_99"), EquipmentTransferService.ERR_UNKNOWN_EQUIPMENT],
		["a trade good", EquipmentTransferService.transfer(c, "hero", "merc_1", "test_good_01"), EquipmentTransferService.ERR_UNKNOWN_EQUIPMENT],
		["not carried", EquipmentTransferService.transfer(c, "merc_2", "hero", W1), EquipmentTransferService.ERR_NOT_CARRIED],
		["non-string id", EquipmentTransferService.transfer(c, 1, "hero", W2), EquipmentTransferService.ERR_INVALID_REQUEST],
		["no carrying", EquipmentTransferService.transfer(null, "hero", "merc_1", W2), EquipmentTransferService.ERR_INVALID_STATE],
	]
	for refusal in refusals:
		_check(not refusal[1]["success"] and refusal[1]["reason"] == refusal[2] and _state(party) == before, "AC11 Refused: %s (%s), nothing changed" % [refusal[0], refusal[1]["reason"]])
	_check(c.get_equipment("merc_a") == null and c.get_equipment("merc_9") == null, "AC11 No state created for pending / unknown ids; no Hero fallback")
	# Dismissed Mercenary: a former id is invalid.
	var dp := _party(["GUARDIAN", "MAGE"])
	var dc: CharacterCarrying = dp["carrying"]
	_check(PartyService.dismiss(dp["roster"], "merc_2", Callable(), dc)["success"], "merc_2 dismissed (empty)")
	dc.add_equipment("hero", W1, 1)
	before = _state(dp)
	r = EquipmentTransferService.transfer(dc, "hero", "merc_2", W1)
	_check(not r["success"] and r["reason"] == EquipmentTransferService.ERR_UNKNOWN_DESTINATION and _state(dp) == before and dc.get_equipment("hero").get_carried_quantity(W1) == 1, "AC11 A dismissed Mercenary cannot receive equipment")
	# AC09 / AC10 Capacity (the existing rules: 10 + Effective STR x 9, weights).
	var cp := _party(["MAGE", "GUARDIAN"])
	var cc: CharacterCarrying = cp["carrying"]
	while cc.can_add_equipment("merc_1", W2, 1):
		cc.add_equipment("merc_1", W2, 1)
	cc.remove_equipment("merc_1", W2, 1)
	var room := cc.get_capacity("merc_1") - cc.get_load("merc_1")
	cc.add_equipment("hero", A1, 1)
	cc.add_equipment("hero", W2, 1)
	_check(room >= 2 and room < 4, "Capacity edge set: merc_1 has %d of room" % room)
	before = _state(cp)
	r = EquipmentTransferService.transfer(cc, "hero", "merc_1", A1)
	_check(not r["success"] and r["reason"] == EquipmentTransferService.ERR_OVER_CAPACITY and _state(cp) == before, "AC10 Weight 4 into %d of room: refused (ERR_OVER_CAPACITY), nothing changed" % room)
	r = EquipmentTransferService.transfer(cc, "hero", "merc_1", W2)
	_check(r["success"] and cc.get_load("merc_1") <= cc.get_capacity("merc_1") and cc.get_load("merc_1") == cc.get_capacity("merc_1") - room + 2, "AC09 Weight 2 into %d of room: accepted, the authoritative weight counted" % room)
	# An over-capacity destination takes nothing (P01 rule), the Hero too.
	var op := _party(["GUARDIAN"])
	var oc: CharacterCarrying = op["carrying"]
	while oc.can_add_equipment("hero", A1, 1):
		oc.add_equipment("hero", A1, 1)
	oc.add_equipment("merc_1", W2, 1)
	var hero_room := oc.get_capacity("hero") - oc.get_load("hero")
	before = _state(op)
	r = EquipmentTransferService.transfer(oc, "merc_1", "hero", W2)
	if hero_room >= 2:
		_check(r["success"] and oc.get_load("hero") <= oc.get_capacity("hero"), "Hero (destination) with %d of room takes weight 2" % hero_room)
	else:
		_check(r["reason"] == EquipmentTransferService.ERR_OVER_CAPACITY and _state(op) == before, "AC10 Hero (destination) with %d of room: weight 2 refused, nothing changed" % hero_room)
	(op["inventory"] as CharacterInventory).add("test_good_06", 1000)
	oc.add_equipment("merc_1", W2, 1)
	while (op["inventory"] as CharacterInventory).add("test_good_01", 1):
		pass
	before = _state(op)
	r = EquipmentTransferService.transfer(oc, "merc_1", "hero", W2)
	_check(oc.get_capacity("hero") - oc.get_load("hero") < 2 and r["reason"] == EquipmentTransferService.ERR_OVER_CAPACITY and _state(op) == before, "AC10 Hero filled (goods count too): refused, nothing changed")
	# AC15 Save failure: everything restored exactly (Hero bonuses too).
	var fp := _party(["GUARDIAN", "GUARDIAN"])
	var fc: CharacterCarrying = fp["carrying"]
	fc.add_equipment("hero", W1, 1)
	EquipmentService.equip(fc, "hero", W1)
	fc.add_equipment("hero", A1, 1)
	fc.add_equipment("merc_1", A2, 1)
	before = _state(fp)
	var calls := [0]
	var fail := func() -> bool:
		calls[0] += 1
		return false
	for move in [["hero", "merc_1", A1], ["merc_1", "merc_2", A2], ["merc_1", "hero", A2]]:
		r = EquipmentTransferService.transfer(fc, move[0], move[1], move[2], fail)
		_check(not r["success"] and r["reason"] == EquipmentTransferService.ERR_SAVE_FAILED and _state(fp) == before, "AC15 Save failure on %s -> %s: source and destination restored exactly" % [move[0], move[1]])
	_check(calls[0] == 3 and (fp["stats"] as CharacterStats).get_equipment_bonuses() == {"str": 2}, "AC15 The save was tried each time; the Hero's live bonus kept")
	# AC13 / AC14 Saved: the save sees the new owner; save -> reload keeps it.
	var seen := []
	var sp := _party(["GUARDIAN", "MAGE"])
	var sc: CharacterCarrying = sp["carrying"]
	sc.add_equipment("hero", A2, 1)
	var save := func() -> bool:
		seen.append(_serialize(sp))
		return true
	r = EquipmentTransferService.transfer(sc, "hero", "merc_2", A2, save)
	_check(r["success"] and seen.size() == 1 and seen[0]["carrying"]["merc_2"]["carried_equipment"] == {A2: 1.0} and (seen[0]["carrying"]["hero"]["carried_equipment"] as Dictionary).is_empty(), "AC13 Saved once, with the new owner")
	var loaded := _load(seen[0])
	_check(not loaded.is_empty() and (loaded["carrying"] as CharacterCarrying).get_equipment("merc_2").get_carried() == {A2: 1} and (loaded["carrying"] as CharacterCarrying).get_equipment("hero").is_empty() and (loaded["carrying"] as CharacterCarrying).get_equipment("merc_1").is_empty(), "AC14 Reloaded: merc_2 owns it, nobody else")
	_check(int(seen[0]["version"]) == 13, "AC39 Saved as v13")
	_sections_done.append("transfer")


# --- Panel (the real Character UI) -----------------------------------------------------------------------

func _verify_panel() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	await _enter_city(main)
	main.wallet.add(5000)
	main.recruit_mercenary("GUARDIAN")
	main.recruit_mercenary("GUARDIAN")
	_check(main.buy_equipment("hero", W1)["success"] and main.buy_equipment("merc_1", A1)["success"], "P02 purchases: 測試武器一 for the Hero, 測試防具一 for merc_1")
	main.leave_city()
	await _settle()
	var panel := main.get_node("CharacterPanel") as CharacterPanel
	var transfer := panel.get_node("Panel/EquipmentView/TransferButton") as Button
	_check(panel.open(), "The Character UI opens")
	panel.show_view(CharacterPanel.VIEW_EQUIPMENT)
	_check(not transfer.visible, "Nothing chosen: no 轉移")
	panel.select_item(W1)
	_check(transfer.visible and not transfer.disabled and transfer.text == "轉移" and transfer.get_global_rect().position.y == (panel.get_node("Panel/EquipmentView/Carried0") as Control).get_global_rect().position.y, "AC01 Choosing a carried item shows 轉移 beside its row")
	_check(transfer.pressed.get_connections().size() == 1, "轉移 is wired")
	transfer.pressed.emit()
	var state := panel.get_transfer_state()
	_check(state["open"] and state["title"] == "將測試武器一轉移給：" and panel.get_transfer_destination_ids() == ["merc_1", "merc_2"], "The picker lists the other owned characters, the current one excluded (%s)" % str(panel.get_transfer_destination_ids()))
	_check(state["rows"] == ["守衛 #1　負重 4 / %d" % main.carrying.get_capacity("merc_1"), "守衛 #2　負重 0 / %d" % main.carrying.get_capacity("merc_2")] and state["confirm_disabled"], "Rows name each character with its load; 確定轉移 waits for a choice (%s)" % str(state["rows"]))
	var before := _main_state(main)
	(panel.get_node("Panel/TransferModal/TransferPanel/TransferCancel") as Button).pressed.emit()
	_check(not panel.is_transfer_open() and _main_state(main) == before, "取消: closed, nothing changed")
	panel.select_item(W1)
	panel.open_transfer()
	(panel.get_node("Panel/TransferModal/TransferPanel/Destination1") as Button).pressed.emit()
	_check(panel.get_transfer_state()["destination"] == "merc_2" and not panel.get_transfer_state()["confirm_disabled"] and (panel.get_node("Panel/TransferModal/TransferPanel/Destination1") as Button).disabled, "Tapping 守衛 #2 chooses it")
	(panel.get_node("Panel/TransferModal/TransferPanel/TransferConfirm") as Button).pressed.emit()
	_check(not panel.is_transfer_open() and panel.get_feedback_text() == "已將測試武器一轉移給守衛 #2", "AC01 確定轉移: 已將測試武器一轉移給守衛 #2 (%s)" % panel.get_feedback_text())
	_check(main.carrying.get_equipment("hero").is_empty() and main.carrying.get_equipment("merc_2").get_carried() == {W1: 1} and main.carrying.get_equipment("merc_1").get_carried() == {A1: 1}, "AC01 / AC04 Only 守衛 #2 received it (not 守衛 #1)")
	_check(panel.get_equipment_lines()["rows"] == [] and panel.get_selected_item() == "", "The UI refreshed at once (the Hero carries nothing)")
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(raw["version"]) == 13 and raw["carrying"]["merc_2"]["carried_equipment"] == {W1: 1.0} and (raw["carrying"]["hero"]["carried_equipment"] as Dictionary).is_empty(), "AC13 Saved at once (v13)")
	# AC03 merc_1 -> merc_2 and AC02 merc_2 -> Hero through the UI.
	panel.select_character("merc_1")
	panel.select_item(A1)
	panel.open_transfer()
	_check(panel.get_transfer_destination_ids() == ["hero", "merc_2"], "From merc_1: the Hero and merc_2")
	panel.choose_destination("merc_2")
	_check(panel.confirm_transfer() and main.carrying.get_equipment("merc_2").get_carried() == {W1: 1, A1: 1} and main.carrying.get_equipment("merc_1").is_empty(), "AC03 merc_1 -> merc_2 through the UI")
	panel.select_character("merc_2")
	panel.select_item(W1)
	_check(transfer.get_global_rect().position.y == (panel.get_node("Panel/EquipmentView/Carried0") as Control).get_global_rect().position.y, "轉移 beside the chosen row 0")
	panel.select_item(A1)
	_check(transfer.get_global_rect().position.y == (panel.get_node("Panel/EquipmentView/Carried1") as Control).get_global_rect().position.y, "... and beside row 1")
	panel.select_item(W1)
	panel.open_transfer()
	panel.choose_destination("hero")
	_check(panel.confirm_transfer() and main.carrying.get_equipment("hero").get_carried() == {W1: 1} and main.carrying.get_equipment("hero").get_equipped_items() == {} and main.character_stats.get_effective("str") == 10, "AC02 / AC07 merc_2 -> Hero; carried, not equipped (STR still 10)")
	# AC08 An equipped item is not in the carried rows: no 轉移 for it.
	panel.select_character("hero")
	panel.select_item(W1)
	panel.equip_selected()
	_check(panel.get_carried_ids() == [] and not transfer.visible and not panel.open_transfer(), "AC08 Equipped: not listed, cannot be chosen for 轉移")
	panel.unequip_slot("WEAPON")
	_check(panel.select_item(W1) and transfer.visible, "AC08 After 卸下 it can be transferred")
	# Save / restart keeps the owners.
	var owners := _gear_state(main)
	panel.close()
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(_gear_state(main) == owners, "AC14 Restart: every owner exact (%s)" % owners)
	panel = main.get_node("CharacterPanel") as CharacterPanel
	transfer = panel.get_node("Panel/EquipmentView/TransferButton") as Button
	panel.open()
	panel.show_view(CharacterPanel.VIEW_EQUIPMENT)
	# AC15 Save failure through the UI.
	main.save_path = BAD_SAVE
	before = _main_state(main)
	panel.select_item(W1)
	panel.open_transfer()
	panel.choose_destination("merc_1")
	_check(not panel.confirm_transfer() and panel.get_feedback_text() == "無法儲存，轉移已取消" and _main_state(main) == before, "AC15 Save failure: 無法儲存，轉移已取消, nothing changed")
	main.save_path = TEST_SAVE
	# AC10 Over capacity through the UI: says so, nothing changes.
	var c: CharacterCarrying = main.carrying
	while c.can_add_equipment("merc_1", A1, 1):
		c.add_equipment("merc_1", A1, 1)
	while c.can_add_equipment("merc_1", W2, 1):
		c.add_equipment("merc_1", W2, 1)
	panel.select_character("hero")
	panel.select_item(W1)
	panel.open_transfer()
	panel.choose_destination("merc_1")
	before = _main_state(main)
	_check(not panel.confirm_transfer() and panel.get_feedback_text() == "守衛 #1負重不足，無法轉移" and _main_state(main) == before, "AC10 Over capacity: 守衛 #1負重不足，無法轉移, nothing changed (%s)" % panel.get_feedback_text())
	# Layout (720 x 1280): 轉移 / picker on screen, touch-sized, no overlap.
	panel.select_character("merc_1")
	_check(panel.select_item(panel.get_carried_ids()[0]), "merc_1: a carried item chosen")
	var canvas := Rect2(0.0, 0.0, 720.0, 1280.0)
	var ok := true
	var controls := []
	for path in ["EquipmentView/Carried0", "EquipmentView/Carried1", "EquipmentView/Carried2", "EquipmentView/Carried3", "EquipmentView/TransferButton", "EquipmentView/Unequip_WEAPON", "EquipmentView/Unequip_ARMOR", "ViewButton", "EquipButton", "CloseButton"]:
		var control := panel.get_node("Panel/" + path) as Control
		if control.visible:
			controls.append(control)
	for i in range(controls.size()):
		var rect: Rect2 = (controls[i] as Control).get_global_rect()
		ok = ok and canvas.encloses(rect) and rect.size.y >= 80.0 and rect.size.x >= 160.0
		for j in range(i + 1, controls.size()):
			ok = ok and not rect.intersects((controls[j] as Control).get_global_rect())
	_check(ok and controls.size() >= 7 and controls.has(panel.get_node("Panel/EquipmentView/TransferButton")), "AC (iPhone) 轉移 and the 裝備 view: on screen, at least 160 x 80, no overlap")
	var rows_fit := true
	for item_id in ALL:
		var row := Button.new()
		row.add_theme_font_size_override("font_size", 22)
		var item := EquipmentCatalog.get_item(item_id)
		row.text = CharacterPanel.CARRIED_ROW_TEXT % [item["display_name"], 99, EquipmentCatalog.slot_name(item["slot"]), EquipmentCatalog.describe_bonuses(item_id), int(item["capacity_cost"])]
		panel.add_child(row)
		rows_fit = rows_fit and row.get_minimum_size().x <= CharacterPanel.CARRIED_ROW_WIDTH
		row.free()
	_check(rows_fit, "Every carried row text fits the narrower row (×99)")
	panel.open_transfer()
	var picker := []
	_check(CharacterPanel.TRANSFER_ROWS == MercenaryRoster.MAX_OWNED, "The picker has a row for every other character (Hero + 5 owned - self)")
	for index in range(CharacterPanel.TRANSFER_ROWS):
		picker.append(panel.get_node("Panel/TransferModal/TransferPanel/Destination%d" % index))
	picker.append_array([panel.get_node("Panel/TransferModal/TransferPanel/TransferCancel"), panel.get_node("Panel/TransferModal/TransferPanel/TransferConfirm")])
	ok = true
	for i in range(picker.size()):
		var rect: Rect2 = (picker[i] as Control).get_global_rect()
		ok = ok and canvas.encloses(rect) and rect.size.y >= 80.0 and rect.size.x >= 160.0
		for j in range(i + 1, picker.size()):
			ok = ok and not rect.intersects((picker[j] as Control).get_global_rect())
	_check(ok and (panel.get_node("Panel/TransferModal") as Control).mouse_filter == Control.MOUSE_FILTER_STOP, "The picker (5 rows + 2 buttons): on screen, touch-sized, no overlap, takes every touch")
	panel.close()
	_check(not panel.is_transfer_open(), "Closing the panel closes the picker")
	await _destroy(main)
	_clean()
	_sections_done.append("panel")


# --- Combat -----------------------------------------------------------------------------------------------

func _verify_combat() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "GUARDIAN")], ["merc_1", "merc_2"])
	var c: CharacterCarrying = main.carrying
	c.add_equipment("hero", A1, 1)
	c.add_equipment("hero", A2, 1)
	# Transfer -> equip -> battle: the receiver's unit has the bonus.
	_check(main.transfer_character_item("hero", "merc_2", A1)["success"] and main.equip_character_item("merc_2", A1)["success"] and main.equip_character_item("hero", A2)["success"], "Transfer 測試防具一 to merc_2, equipped; the Hero equips 測試防具二")
	var battle: CombatBattle = await _start_battle(main)
	var view := main.get_node("CombatView") as CombatView
	var hero := battle.get_hero()
	var m1 := _friend(battle, "merc_1")
	var m2 := _friend(battle, "merc_2")
	var plain := CharacterStats.for_mercenary(Mercenary.create("x", "GUARDIAN"))
	_check(m2.physical_defense == plain.get_physical_defense() + 2 and m1.physical_defense == plain.get_physical_defense() and hero.magic_defense == 2, "AC16 The battle: merc_2 (receiver, equipped) +2, merc_1 nothing, the Hero its own armor")
	# AC12 No transfer mid-battle.
	c.add_equipment("hero", W1, 1)
	var state := _main_state(main)
	var refused: Dictionary = main.transfer_character_item("hero", "merc_1", W1)
	_check(refused["reason"] == "ERR_IN_COMBAT" and _main_state(main) == state, "AC12 In a battle: transfer refused (ERR_IN_COMBAT), nothing changed")
	# AC17 - AC22 ⓘ info: both defenses = the CombatUnit values.
	for unit in [hero, m1, m2]:
		var text := view.get_info_text(unit)
		_check(text.contains("物理防禦 %d　魔法防禦 %d" % [unit.physical_defense, unit.magic_defense]), "AC17 - AC21 %s info: 物理防禦 %d　魔法防禦 %d (the CombatUnit's)" % [CombatView.unit_label(unit), unit.physical_defense, unit.magic_defense])
	_check(view.get_info_text(hero).contains("物理防禦 %d　魔法防禦 2" % hero.physical_defense), "AC18 / AC22 Hero: 測試防具二 shown as 魔法防禦 2")
	_check(view.get_info_text(m2).contains("物理防禦 %d　" % (plain.get_physical_defense() + 2)) and view.get_info_text(m1).contains("物理防禦 %d　" % plain.get_physical_defense()), "AC19 / AC22 merc_2's armor shown (+2); merc_1 without")
	# The text follows the unit itself (no second calculation).
	var saved_pd := m1.physical_defense
	m1.physical_defense = 37
	m1.magic_defense = 41
	_check(view.get_info_text(m1).contains("物理防禦 37　魔法防禦 41"), "AC21 The shown values are read from the CombatUnit")
	m1.physical_defense = saved_pd
	m1.magic_defense = 0
	var enemy := battle.get_enemies()[0]
	enemy.label = "敵"
	_check(not view.get_info_text(enemy).contains("防禦"), "Enemies: unchanged info (friendly characters only)")
	enemy.label = ""
	# AC23 Mitigation unchanged (P04 numbers): 10 MAGIC on the Hero (魔防 2) -> 8.
	battle.advance(CombatConfig.PREPARATION_MS)
	_check(battle.resolve_damage(battle.get_enemies()[0], hero, 10, CombatBattle.DamageKind.MAGIC) == 8 and battle.resolve_damage(battle.get_enemies()[0], m2, 10, CombatBattle.DamageKind.PHYSICAL) == 10 - (plain.get_physical_defense() + 2), "AC23 Damage mitigation unchanged (CharacterStats.mitigate)")
	# AC24 Readable: the panel text fits above 關閉 for each friend (the most lines).
	var fits := true
	for unit in battle.get_friends():
		view.open_info(unit)
		await process_frame
		var label := view.get_node("InfoPanel/InfoText") as Label
		var close := view.get_node("InfoPanel/InfoClose") as Control
		fits = fits and label.get_minimum_size().y <= label.size.y and label.position.y + label.get_minimum_size().y <= close.position.y and label.get_minimum_size().x <= label.size.x
	view.close_info()
	_check(fits, "AC24 The info text (with the defenses) fits its panel above 關閉 for every friend")
	await _end_battle(main, battle)
	await _destroy(main)
	_clean()
	_sections_done.append("combat")


# --- Dismissal modal --------------------------------------------------------------------------------------

func _verify_dismissal() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	var hub := main.get_node("CityHub") as CityHub
	await _enter_city(main)
	main.wallet.add(5000)
	for type in ["GUARDIAN", "MAGE", "STRATEGIST"]:
		main.recruit_mercenary(type)
	_check(main.buy_equipment("merc_1", W1)["success"], "merc_1 holds 測試武器一")
	main.carrying.get_inventory("merc_2").add("test_good_01", 1)
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	hub.show_mercenary_view(CityHub.MERCENARY_VIEW_ROSTER)
	await process_frame
	var feedback: String = hub.get_feedback_text()
	var before := _world(main)
	var raw := FileAccess.get_file_as_string(TEST_SAVE)
	hub.get_dismiss_button("merc_1").pressed.emit()
	_check(hub.is_dismiss_blocked_open() and not hub.is_dismiss_confirm_open(), "AC25 Equipment: 解僱 opens the 無法解僱 modal (no countdown confirmation)")
	var text := hub.get_dismiss_blocked_text()
	_check(text["title"] == "無法解僱" and text["lines"] == ["此傭兵仍攜帶物品或裝備。", "請先清空後再解僱。"] and hub.get_dismiss_blocked_ok_button().text == "確定", "AC28 無法解僱 / 此傭兵仍攜帶物品或裝備。/ 請先清空後再解僱。/ 確定")
	_check(hub.get_feedback_text() == feedback and not hub.get_feedback_text().contains("清空"), "AC27 No warning inserted into the page")
	var modal := hub.get_node("DismissBlockedModal") as Control
	var panel := modal.get_node("DismissBlockedPanel") as Control
	var canvas := Rect2(0.0, 0.0, 720.0, 1280.0)
	var ok_rect := hub.get_dismiss_blocked_ok_button().get_global_rect()
	var body_fits := true
	for index in range(2):
		var line := modal.find_child("BodyLine%d" % index, true, false) as Label
		body_fits = body_fits and line.get_minimum_size().x <= line.size.x and line.get_minimum_size().y <= line.size.y and panel.get_global_rect().encloses(line.get_global_rect())
	_check(modal.mouse_filter == Control.MOUSE_FILTER_STOP and canvas.encloses(panel.get_global_rect()) and panel.get_global_rect().encloses(ok_rect) and ok_rect.size.x >= 160.0 and ok_rect.size.y >= 80.0 and body_fits, "AC25 / AC28 A full-screen modal over the Mercenary Center: on screen, readable, one touch-sized 確定")
	_check(modal.get_index() > (hub.get_node("Center") as Node).get_index(), "AC25 Drawn above the Mercenary Center content")
	hub.get_dismiss_blocked_ok_button().pressed.emit()
	_check(not hub.is_dismiss_blocked_open() and hub.get_facility() == CityHub.FACILITY_MERCENARY and hub.get_dismiss_button("merc_1") != null, "AC29 確定 closes it; back on the Mercenary Center roster")
	_check(_world(main) == before and FileAccess.get_file_as_string(TEST_SAVE) == raw, "AC30 / AC31 Nothing changed (roster, deployment, items, equipment, wallet, save file)")
	# AC26 Goods (the same ERR_HAS_ITEMS rule).
	hub.get_dismiss_button("merc_2").pressed.emit()
	_check(hub.is_dismiss_blocked_open() and not hub.is_dismiss_confirm_open() and main.mercenary_roster.get_mercenary("merc_2") != null, "AC26 Goods: the same 無法解僱 modal")
	# AC32 Repeated attempts: one modal, never stacked.
	var modal_count := _count_named(hub, "DismissBlockedModal")
	var children := _node_count(hub)
	for attempt in range(5):
		hub.get_dismiss_button("merc_1").pressed.emit()
		hub.get_dismiss_button("merc_2").pressed.emit()
	_check(_count_named(hub, "DismissBlockedModal") == 1 and modal_count == 1 and _node_count(hub) == children and hub.is_dismiss_blocked_open(), "AC32 Repeated attempts: still one modal")
	hub.get_dismiss_blocked_ok_button().pressed.emit()
	_check(not hub.is_dismiss_blocked_open() and _world(main) == before, "AC32 One 確定 closes it; nothing changed")
	# (P01 implementation gap: a Mercenary's goods cannot be saved yet, so
	# they are taken back before anything saves.)
	main.carrying.get_inventory("merc_2").remove("test_good_01", 1)
	await process_frame
	# The service refusal itself (state changed after the page was drawn):
	# 確定解僱 -> ERR_HAS_ITEMS -> the same modal, no inline text.
	hub.get_dismiss_button("merc_3").pressed.emit()
	_check(hub.is_dismiss_confirm_open(), "merc_3 (empty): the normal 5 s confirmation (Stage 8 unchanged)")
	main.carrying.add_equipment("merc_3", A2, 1)
	before = _world(main)
	hub.advance_dismiss_countdown(5.0)
	hub.get_dismiss_confirm_button().pressed.emit()
	_check(hub.is_dismiss_blocked_open() and not hub.is_dismiss_confirm_open() and main.mercenary_roster.get_mercenary("merc_3") != null and _world(main) == before and not hub.get_feedback_text().contains("清空"), "AC25 / AC27 Refused at 確定解僱 (ERR_HAS_ITEMS): the modal, nothing changed")
	hub.get_dismiss_blocked_ok_button().pressed.emit()
	# Deployed: unchanged Stage 8 text (not this modal).
	_check(main.set_mercenary_deployed("merc_1", true)["success"], "merc_1 deployed")
	await process_frame
	hub.get_dismiss_button("merc_1").pressed.emit()
	_check(not hub.is_dismiss_blocked_open() and hub.get_feedback_text() == "請先取消出戰，再解僱傭兵", "AC37 Deployed: the Stage 8 rule and text unchanged")
	main.set_mercenary_deployed("merc_1", false)
	# Emptied -> dismissal works as before (rule unchanged).
	await process_frame
	hub.get_dismiss_button("merc_2").pressed.emit()
	_check(hub.is_dismiss_confirm_open() and not hub.is_dismiss_blocked_open(), "AC37 Emptied: the normal confirmation")
	hub.advance_dismiss_countdown(5.0)
	hub.get_dismiss_confirm_button().pressed.emit()
	_check(main.mercenary_roster.get_mercenary("merc_2") == null and hub.get_feedback_text() == "已解僱法師 #2", "AC37 ... and the dismissal goes through (%s)" % hub.get_feedback_text())
	# Leaving the facility / the city closes the modal.
	hub.get_dismiss_button("merc_1").pressed.emit()
	hub.show_facility(CityHub.FACILITY_MARKET)
	_check(not hub.is_dismiss_blocked_open(), "Another facility closes it")
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	hub.show_mercenary_view(CityHub.MERCENARY_VIEW_ROSTER)
	await process_frame
	hub.get_dismiss_button("merc_1").pressed.emit()
	main.leave_city()
	await _settle()
	_check(not hub.is_dismiss_blocked_open(), "Leaving the city closes it")
	await _destroy(main)
	_clean()
	_sections_done.append("dismissal")


# --- Scope ------------------------------------------------------------------------------------------------

func _verify_scope() -> void:
	_check(SaveStore.VERSION == 13 and SaveStore.V13_KEYS.size() == 13, "AC39 Save v13, no new section, no migration")
	var service := _code_only("res://scripts/equipment_transfer_service.gd").to_lower()
	for word in ["get_inventory", "goods", "cargo", "warehouse", "wallet", "price", "sell", "equip(", "_set_equipped"]:
		_check(not service.contains(word), "EquipmentTransferService touches no %s (equipment only, never equips)" % word)
	_check(service.contains("carrying.transfer_equipment(") and service.contains("carrying.can_add_equipment("), "One equipment model: CharacterCarrying's P01 move and capacity check")
	var combat := ""
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_view.gd", "res://scripts/combat_config.gd"]:
		combat += _code_only(path).to_lower()
	for word in ["equipment", "carrying", "bonus", "get_effective(", "mitigate(stats"]:
		_check(not combat.contains(word), "AC40 Combat code computes no %s" % word)
	var view := _code_only("res://scripts/combat_view.gd")
	_check(view.contains("unit.physical_defense, unit.magic_defense"), "AC21 The info reads the CombatUnit's own defenses")
	_check(CityHub.PARTY_FAILURE_MESSAGES.has("ERR_HAS_ITEMS") and PartyService.ERR_HAS_ITEMS == "ERR_HAS_ITEMS", "AC37 The dismissal rule (PartyService ERR_HAS_ITEMS) is unchanged")
	_check(EquipmentCatalog.SLOTS == ["WEAPON", "ARMOR"] and EquipmentCatalog.ITEMS.size() == 4, "No new equipment / slot")
	_sections_done.append("scope")


# --- Stress (TARGETED) ------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9055
	var conservation := 0
	var identity := 0
	var bonus := 0
	var capacity := 0
	var refused_changed := 0
	var reload := 0
	var battle_bad := 0
	var transfers := 0
	var refusals := 0
	var save_failures := 0
	var capacity_refusals := 0
	var edge_bad := 0
	for run in range(60):
		var types := []
		for i in range(rng.randi_range(2, 5)):
			types.append(["GUARDIAN", "MAGE", "STRATEGIST", "GUARDIAN"][rng.randi_range(0, 3)])
		var party := _party(types)
		var c: CharacterCarrying = party["carrying"]
		var roster: MercenaryRoster = party["roster"]
		var ids := ["hero"]
		for m in roster.get_owned():
			ids.append(m.get_id())
		for i in range(rng.randi_range(8, 24)):
			c.add_equipment(ids[rng.randi_range(0, ids.size() - 1)], ALL[rng.randi_range(0, 3)], 1)
		# Capacity edges: the Hero's backpack filled with goods to 0..5 of room.
		if run % 2 == 0:
			var backpack: CharacterInventory = party["inventory"]
			while backpack.get_remaining_capacity() > rng.randi_range(0, 5) and backpack.add("test_good_01", 1):
				pass
		var totals := _totals(c)
		for step in range(60):
			var from: String = (ids + ["merc_9"])[rng.randi_range(0, ids.size())]
			var to: String = (ids + ["merc_9", "merc_a"])[rng.randi_range(0, ids.size() + 1)]
			var item: String = ALL[rng.randi_range(0, 3)]
			var fail := rng.randi_range(0, 4) == 0
			var persist := func() -> bool: return not fail
			var before := _state(party)
			var r: Dictionary
			match rng.randi_range(0, 5):
				0:
					r = EquipmentService.equip(c, from, item, persist)
				1:
					r = EquipmentService.unequip(c, from, EquipmentCatalog.SLOTS[rng.randi_range(0, 1)], persist)
				_:
					r = EquipmentTransferService.transfer(c, from, to, item, persist)
					if r["success"]:
						transfers += 1
					elif r["reason"] == EquipmentTransferService.ERR_OVER_CAPACITY:
						capacity_refusals += 1
					elif r["reason"] == EquipmentTransferService.ERR_SAVE_FAILED:
						save_failures += 1
			if not r["success"]:
				refusals += 1
				if _state(party) != before:
					refused_changed += 1
			if _totals(c) != totals:
				conservation += 1
			if c.get_equipment("merc_9") != null or c.get_equipment("merc_a") != null:
				identity += 1
			for id in ids:
				var expected := c.get_equipment(id).get_bonuses()
				if c.get_stats(id).get_equipment_bonuses() != expected:
					bonus += 1
				if c.get_load(id) != c.get_equipment(id).get_load() + c.get_inventory(id).get_goods_load():
					capacity += 1
			if r["success"] and r.has("to_id") and c.get_load(r["to_id"]) > c.get_capacity(r["to_id"]):
				capacity += 1
			# Save -> reload between transfers.
			if step % 10 == 9:
				var loaded := _load(_serialize(party))
				if loaded.is_empty():
					reload += 1
				else:
					var next := {"carrying": loaded["carrying"], "roster": loaded["roster"], "inventory": loaded["inventory"], "stats": loaded["stats"], "wallet": loaded["wallet"]}
					if _state(next) != _state(party):
						reload += 1
					else:
						party = next
						c = party["carrying"]
						roster = party["roster"]
		# Capacity boundary: every carried Mercenary item offered to the
		# (nearly full) Hero — accepted exactly when its weight fits.
		if run % 2 == 0:
			for id in ids.slice(1):
				for item in c.get_equipment(id).get_carried().keys():
					var room := c.get_capacity("hero") - c.get_load("hero")
					var before := _state(party)
					var r := EquipmentTransferService.transfer(c, id, "hero", item)
					var fits := room >= EquipmentCatalog.get_capacity_cost(item)
					if r["success"] != fits or (not fits and (r["reason"] != EquipmentTransferService.ERR_OVER_CAPACITY or _state(party) != before)) or (r["success"] and c.get_load("hero") > c.get_capacity("hero")):
						edge_bad += 1
					if not fits:
						capacity_refusals += 1
		# Transfer -> the P04 battle: every unit = its authoritative stats.
		roster.set_deployment(ids.slice(1, mini(ids.size(), 1 + MercenaryRoster.MAX_DEPLOYED)))
		var deployed := {}
		for m in roster.get_deployed():
			deployed[m.get_id()] = c.get_stats(m.get_id())
		var battle := CombatBattle.create_party(10, party["stats"], roster.get_deployed(), deployed)
		if battle == null:
			battle_bad += 1
		else:
			for id in deployed:
				var unit := _friend(battle, id)
				var profile := (deployed[id] as CharacterStats).get_combat_profile()
				if unit == null or unit.physical_defense != profile["physical_defense"] or unit.magic_defense != profile["magic_defense"] or unit.attack_damage != profile["attack_damage"]:
					battle_bad += 1
			if battle.get_hero().magic_defense != (party["stats"] as CharacterStats).get_magic_defense():
				battle_bad += 1
	print("Stress summary: transfers %d, refusals %d, save failures %d, capacity refusals %d, conservation %d, identity %d, bonus %d, capacity %d, refused_changed %d, reload %d, battle %d, edge %d" % [transfers, refusals, save_failures, capacity_refusals, conservation, identity, bonus, capacity, refused_changed, reload, battle_bad, edge_bad])
	_check(transfers > 300 and refusals > 300 and save_failures > 30 and capacity_refusals > 50, "Stress: %d transfers, %d refusals (%d save failures, %d capacity)" % [transfers, refusals, save_failures, capacity_refusals])
	_check(edge_bad == 0, "Stress: capacity boundary exact (fits <=> accepted; refused changes nothing) (%d)" % edge_bad)
	_check(conservation == 0, "Stress: quantity conserved (no duplication / loss) (%d)" % conservation)
	_check(identity == 0, "Stress: no state for pending / unknown ids (%d)" % identity)
	_check(bonus == 0, "Stress: bonuses = the equipped items only, no leakage (%d)" % bonus)
	_check(capacity == 0, "Stress: load exact, no transfer beyond the destination's Capacity (%d)" % capacity)
	_check(refused_changed == 0, "Stress: every refused / failed operation changed nothing (%d)" % refused_changed)
	_check(reload == 0, "Stress: save -> reload between transfers exact (%d)" % reload)
	_check(battle_bad == 0, "Stress: transfer -> P04 battle units exact (%d)" % battle_bad)
	# Real game: transfer cycles with a failed save and restarts, and the
	# blocked-dismissal modal opened / closed repeatedly.
	_clean()
	var main := await _new_main(TEST_SAVE)
	await _enter_city(main)
	main.wallet.add(10000)
	main.recruit_mercenary("GUARDIAN")
	main.recruit_mercenary("GUARDIAN")
	main.buy_equipment("hero", W1)
	main.buy_equipment("hero", A1)
	var game_bad := 0
	var modal_bad := 0
	var hub := main.get_node("CityHub") as CityHub
	for cycle in range(8):
		var from: String = ["hero", "merc_1", "merc_2"][cycle % 3]
		var to: String = ["merc_1", "merc_2", "hero"][cycle % 3]
		var carried: Dictionary = main.carrying.get_equipment(from).get_carried()
		var item: String = carried.keys()[0] if not carried.is_empty() else ""
		if item == "":
			continue
		main.save_path = BAD_SAVE
		var before := _main_state(main)
		if main.transfer_character_item(from, to, item)["success"] or _main_state(main) != before:
			game_bad += 1
		main.save_path = TEST_SAVE
		if not main.transfer_character_item(from, to, item)["success"]:
			game_bad += 1
		var gear := _gear_state(main)
		await _destroy(main)
		main = await _new_main(TEST_SAVE)
		hub = main.get_node("CityHub") as CityHub
		if _gear_state(main) != gear:
			game_bad += 1
		hub.show_facility(CityHub.FACILITY_MERCENARY)
		hub.show_mercenary_view(CityHub.MERCENARY_VIEW_ROSTER)
		await process_frame
		var hub_children := hub.get_child_count()
		for id in ["merc_1", "merc_2"]:
			var world := _world(main)
			if hub.get_dismiss_button(id) == null:
				continue
			hub.get_dismiss_button(id).pressed.emit()
			var holds: bool = main.carrying.has_any_items(id)
			hub.get_dismiss_button(id).pressed.emit()
			if hub.is_dismiss_blocked_open() != holds or _count_named(hub, "DismissBlockedModal") != 1 or hub.get_child_count() != hub_children:
				modal_bad += 1
			hub.close_dismiss_confirm()
			hub.get_dismiss_blocked_ok_button().pressed.emit()
			if hub.is_dismiss_blocked_open() or _world(main) != world:
				modal_bad += 1
	_check(game_bad == 0, "Stress: 8 real-game cycles (failed save, transfer, restart) exact (%d)" % game_bad)
	_check(modal_bad == 0, "Stress: the 無法解僱 modal opened / closed repeatedly, never stacked, nothing changed (%d)" % modal_bad)
	await _destroy(main)
	_clean()
	_sections_done.append("stress")


# --- Helpers ----------------------------------------------------------------------------------------------

func _party(types: Array) -> Dictionary:
	var stats := CharacterStats.new()
	var inventory := CharacterInventory.new("player", stats)
	var roster := MercenaryRoster.new()
	for type in types:
		roster.create_mercenary(type)
	var carrying := CharacterCarrying.new(inventory, func() -> MercenaryRoster: return roster)
	return {"carrying": carrying, "roster": roster, "inventory": inventory, "stats": stats, "wallet": Wallet.new()}


func _state(party: Dictionary) -> String:
	var carrying: CharacterCarrying = party["carrying"]
	var roster: MercenaryRoster = party["roster"]
	var parts := [roster.to_dict(), roster.pending_to_list()]
	var ids := ["hero"]
	for m in roster.get_owned():
		ids.append(m.get_id())
	for id in ids:
		parts.append([id, carrying.get_equipment(id).get_equipped_items(), carrying.get_equipment(id).get_carried(), carrying.get_inventory(id).get_items(), carrying.get_stats(id).get_combat_profile(), carrying.get_stats(id).get_max_mp(), carrying.get_capacity(id)])
	return JSON.stringify(parts)


func _main_state(main: Node) -> String:
	return _state({"carrying": main.carrying, "roster": main.mercenary_roster})


## Roster, deployment, every character's items / equipment and the wallet.
func _world(main: Node) -> String:
	return JSON.stringify([_main_state(main), main.mercenary_roster.get_deployed_ids(), main.wallet.get_balance(), main.inventory.get_items()])


func _gear_state(main: Node) -> String:
	var parts := []
	for id in ["hero"] + main.mercenary_roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id()):
		parts.append([id, main.carrying.get_equipment(id).get_equipped_items(), main.carrying.get_equipment(id).get_carried()])
	return JSON.stringify(parts)


func _totals(carrying: CharacterCarrying) -> Dictionary:
	var totals := {}
	for item_id in ALL:
		totals[item_id] = 0
		for id in ["hero"] + carrying.get_roster().get_owned().map(func(m: Mercenary) -> String: return m.get_id()):
			totals[item_id] += carrying.get_equipment(id).get_total_quantity(item_id)
	return totals


func _profile(stats: CharacterStats) -> Dictionary:
	var profile := stats.get_combat_profile()
	profile["max_mp"] = stats.get_max_mp()
	profile["capacity"] = stats.get_max_capacity()
	for stat in CharacterConfig.STATS:
		profile[stat] = stats.get_effective(stat)
	return profile


func _friend(battle: CombatBattle, id: String) -> CombatUnit:
	for unit in battle.get_friends():
		if unit.id == id:
			return unit
	return null


func _count_named(node: Node, node_name: String) -> int:
	return node.find_children(node_name, "", true, false).size()


## Every node under `node` (a second modal would add some).
func _node_count(node: Node) -> int:
	return node.find_children("*", "", true, false).size()


func _serialize(party: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(SaveStore.serialize(party["wallet"], party["inventory"], MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.new(), {"hero": party["stats"]}, party["roster"], party["carrying"])))


func _load(data: Dictionary) -> Dictionary:
	var payload := SaveStore.validate(JSON.parse_string(JSON.stringify(data)))
	if payload.is_empty():
		return {}
	var rebuilt := SaveStore._rebuild(payload)
	if rebuilt.is_empty() or not rebuilt.has("carrying"):
		return {}
	return {"carrying": rebuilt["carrying"], "roster": rebuilt["mercenaries"], "inventory": rebuilt["inventory"], "stats": rebuilt["character_stats"], "wallet": rebuilt["wallet"]}


func _start_battle(main: Node) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	await _settle()
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	return main.get_combat()


func _end_battle(main: Node, battle: CombatBattle) -> void:
	if battle == null:
		return
	battle.advance(CombatConfig.PREPARATION_MS + 2000)
	battle.start_retreat()
	for step in range(400):
		if battle.is_over():
			break
		battle.advance(50)
	await process_frame
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _settle()


func _enter_city(main: Node) -> void:
	(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
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
