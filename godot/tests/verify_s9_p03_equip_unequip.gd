extends SceneTree

## Stage 9 P03: Equip / Unequip + Character Equipment UI.
##   service      EquipmentService.equip / unequip (EquipmentCatalog slot,
##                swap, stable ids, refusals, no transfer, saved, rollback)
##   stats        Effective / derived values once; preview = the real result
##   capacity     load unchanged by equip / unequip (also over capacity)
##   panel        the real Character UI: 屬性 / 裝備 views, slots, carried
##                rows, preview, 裝備 / 卸下, same-type Mercenaries, feedback,
##                save / restart, save failure, P02 purchase -> equip, layout
##   scope        Save v13, no combat / selling / transfer / new slot
##   stress       TARGETED: random equip / unequip / swap / refusals over
##                several characters with save failures and reloads

const TEST_SAVE := "user://s9_p03_equip_test.json"
const BAD_SAVE := "user://s9_p03_missing_dir/save.json"
const T0 := 1800000000000
const W1 := "test_weapon_01"
const W2 := "test_weapon_02"
const A1 := "test_armor_01"
const A2 := "test_armor_02"
const ALL := [W1, W2, A1, A2]

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_verify_service()
	_verify_stats()
	_verify_capacity()
	await _verify_panel()
	await _verify_game()
	_verify_scope()
	await _verify_stress()
	_check(_sections_done.size() == 7, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S9 P03 equip / unequip verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Service ----------------------------------------------------------------------------------------------

func _verify_service() -> void:
	var party := _party(["GUARDIAN", "GUARDIAN", "MAGE"])
	var c: CharacterCarrying = party["carrying"]
	for id in ["hero", "merc_1", "merc_2", "merc_3"]:
		for item_id in ALL:
			c.add_equipment(id, item_id, 1)
	var totals := _totals(c)
	# Hero weapon / armor.
	var r := EquipmentService.equip(c, "hero", W1)
	_check(r == {"success": true, "reason": "", "character_id": "hero", "item_id": W1, "slot": "WEAPON", "replaced": ""}, "AC06 Hero equips 測試武器一 into the Weapon slot (%s)" % str(r))
	_check(c.get_equipment("hero").get_equipped("WEAPON") == W1 and c.get_equipment("hero").get_carried_quantity(W1) == 0, "AC09 Carried -> equipped (carried 1 -> 0)")
	r = EquipmentService.equip(c, "hero", A1)
	_check(r["success"] and r["slot"] == "ARMOR" and c.get_equipment("hero").get_equipped("ARMOR") == A1, "AC07 Hero equips 測試防具一 into the Armor slot")
	# Swap.
	r = EquipmentService.equip(c, "hero", W2)
	_check(r["success"] and r["replaced"] == W1 and c.get_equipment("hero").get_equipped("WEAPON") == W2 and c.get_equipment("hero").get_carried_quantity(W1) == 1 and c.get_equipment("hero").get_carried_quantity(W2) == 0, "AC10 Replacing: 測試武器二 equipped, 測試武器一 back to carried")
	r = EquipmentService.equip(c, "hero", A2)
	_check(r["success"] and r["replaced"] == A1 and c.get_equipment("hero").get_carried_quantity(A1) == 1 and c.get_equipment("hero").get_equipped("ARMOR") == A2, "AC10 Armor swap: 測試防具二 in, 測試防具一 back")
	_check(_totals(c) == totals, "AC22 Swaps: every item counted once (no duplication / loss)")
	# Unequip.
	r = EquipmentService.unequip(c, "hero", "WEAPON")
	_check(r["success"] and r["item_id"] == W2 and c.get_equipment("hero").get_equipped("WEAPON") == "" and c.get_equipment("hero").get_carried_quantity(W2) == 1, "AC11 Weapon unequipped into the Hero's carried equipment")
	r = EquipmentService.unequip(c, "hero", "ARMOR")
	_check(r["success"] and r["item_id"] == A2 and c.get_equipment("hero").get_equipped_items() == {} and c.get_equipment("hero").get_carried() == {W1: 1, W2: 1, A1: 1, A2: 1}, "AC12 Armor unequipped; the Hero carries all four again")
	# Mercenaries by stable id; same-type independence; no transfer.
	r = EquipmentService.equip(c, "merc_2", W1)
	_check(r["success"] and c.get_equipment("merc_2").get_equipped("WEAPON") == W1 and c.get_equipment("merc_1").get_equipped_items() == {} and c.get_equipment("merc_1").get_carried_quantity(W1) == 1, "AC02 / AC03 merc_2 (GUARDIAN) equips; merc_1 (also GUARDIAN) untouched")
	_check(c.get_equipment("hero").get_carried() == {W1: 1, W2: 1, A1: 1, A2: 1} and c.get_equipment("merc_3").get_carried() == {W1: 1, W2: 1, A1: 1, A2: 1}, "AC13 Nothing moved to / from any other character")
	r = EquipmentService.unequip(c, "merc_2", "WEAPON")
	_check(r["success"] and c.get_equipment("merc_2").get_carried_quantity(W1) == 1 and c.get_equipment("hero").get_carried_quantity(W1) == 1, "AC13 Unequip stays with merc_2 (never to the Hero)")
	# Refusals: zero mutation.
	(party["roster"] as MercenaryRoster).pend_legacy(Mercenary.create("merc_a", "GUARDIAN"))
	var before := _state(party)
	var refusals := [
		["unknown item", EquipmentService.equip(c, "hero", "test_helmet_01"), EquipmentService.ERR_UNKNOWN_EQUIPMENT],
		["a trade good", EquipmentService.equip(c, "hero", "test_good_01"), EquipmentService.ERR_UNKNOWN_EQUIPMENT],
		["wrong slot (weapon -> ARMOR)", EquipmentService.equip(c, "hero", W1, Callable(), "ARMOR"), EquipmentService.ERR_WRONG_SLOT],
		["wrong slot (armor -> WEAPON)", EquipmentService.equip(c, "hero", A1, Callable(), "WEAPON"), EquipmentService.ERR_WRONG_SLOT],
		["unknown slot name", EquipmentService.equip(c, "hero", A1, Callable(), "HELMET"), EquipmentService.ERR_WRONG_SLOT],
		["not carried by merc_1 (merc_2 has one more)", _not_carried(c), EquipmentService.ERR_NOT_CARRIED],
		["unknown character", EquipmentService.equip(c, "merc_9", W1), EquipmentService.ERR_UNKNOWN_CHARACTER],
		["pending merc_a", EquipmentService.equip(c, "merc_a", W1), EquipmentService.ERR_UNKNOWN_CHARACTER],
		["type as id", EquipmentService.equip(c, "GUARDIAN", W1), EquipmentService.ERR_UNKNOWN_CHARACTER],
		["number id", EquipmentService.equip(c, 1, W1), EquipmentService.ERR_INVALID_REQUEST],
		["null item", EquipmentService.equip(c, "hero", null), EquipmentService.ERR_INVALID_REQUEST],
		["no carrying", EquipmentService.equip(null, "hero", W1), EquipmentService.ERR_INVALID_STATE],
		["unequip empty slot", EquipmentService.unequip(c, "hero", "WEAPON"), EquipmentService.ERR_SLOT_EMPTY],
		["unequip HELMET", EquipmentService.unequip(c, "hero", "HELMET"), EquipmentService.ERR_INVALID_SLOT],
		["unequip lower-case slot", EquipmentService.unequip(c, "hero", "weapon"), EquipmentService.ERR_INVALID_SLOT],
		["unequip unknown character", EquipmentService.unequip(c, "merc_9", "WEAPON"), EquipmentService.ERR_UNKNOWN_CHARACTER],
		["unequip pending", EquipmentService.unequip(c, "merc_a", "WEAPON"), EquipmentService.ERR_UNKNOWN_CHARACTER],
		["unequip null slot", EquipmentService.unequip(c, "hero", null), EquipmentService.ERR_INVALID_REQUEST],
	]
	for entry in refusals:
		var result: Dictionary = entry[1]
		_check(not result["success"] and result["reason"] == entry[2], "AC08 / AC14 %s: refused (%s)" % [entry[0], result["reason"]])
	_check(_state(party) == before, "AC08 / AC14 Every refusal left every character exactly as before (no fallback to the Hero)")
	# Dismissed Mercenary.
	var dismissed := _party(["GUARDIAN", "GUARDIAN"])
	(dismissed["roster"] as MercenaryRoster).remove("merc_1")
	(dismissed["carrying"] as CharacterCarrying).add_equipment("merc_2", W1, 1)
	var dismissed_state := _state(dismissed)
	r = EquipmentService.equip(dismissed["carrying"], "merc_1", W1)
	_check(not r["success"] and r["reason"] == EquipmentService.ERR_UNKNOWN_CHARACTER and _state(dismissed) == dismissed_state, "AC14 A dismissed Mercenary: refused; merc_2's item not redirected")
	# Save success / failure.
	var saved := _party(["MAGE"])
	var sc: CharacterCarrying = saved["carrying"]
	sc.add_equipment("merc_1", W2, 1)
	sc.add_equipment("merc_1", W1, 1)
	sc.equip("merc_1", W1)
	var seen := []
	r = EquipmentService.equip(sc, "merc_1", W2, func() -> bool:
		seen.append(_state(saved))
		return true)
	_check(r["success"] and seen.size() == 1 and seen[0] == _state(saved), "The save runs once, seeing the new equipped state")
	for op in ["equip", "swap", "unequip"]:
		var f := _party(["MAGE", "MAGE"])
		var fc: CharacterCarrying = f["carrying"]
		fc.add_equipment("merc_2", W1, 1)
		fc.add_equipment("merc_2", W2, 1)
		fc.add_equipment("merc_2", A1, 1)
		if op != "equip":
			fc.equip("merc_2", W1)
		var f_state := _state(f)
		var fail := func() -> bool: return false
		match op:
			"equip":
				r = EquipmentService.equip(fc, "merc_2", A1, fail)
			"swap":
				r = EquipmentService.equip(fc, "merc_2", W2, fail)
			"unequip":
				r = EquipmentService.unequip(fc, "merc_2", "WEAPON", fail)
		_check(not r["success"] and r["reason"] == EquipmentService.ERR_SAVE_FAILED and _state(f) == f_state, "AC21 Save failure on %s: the exact previous state (items, slots, stats)" % op)
	# Hero save failure restores the Hero's live stats bonuses too.
	var hf := _party([])
	var hc: CharacterCarrying = hf["carrying"]
	hc.add_equipment("hero", W1, 1)
	hc.add_equipment("hero", W2, 1)
	hc.equip("hero", W1)
	var profile := (hf["stats"] as CharacterStats).get_combat_profile()
	r = EquipmentService.equip(hc, "hero", W2, func() -> bool: return false)
	_check(not r["success"] and (hf["stats"] as CharacterStats).get_combat_profile() == profile and (hf["stats"] as CharacterStats).get_equipment_bonuses() == {"str": 2}, "AC21 Hero: failed swap restores the live bonuses (STR +2 kept, no INT)")
	_sections_done.append("service")


# --- Stats ------------------------------------------------------------------------------------------------

func _verify_stats() -> void:
	var party := _party(["MAGE"])
	var c: CharacterCarrying = party["carrying"]
	var hero: CharacterStats = party["stats"]
	var plain := CharacterStats.new()
	for item_id in ALL:
		c.add_equipment("hero", item_id, 1)
	EquipmentService.equip(c, "hero", W1)
	_check(hero.get_effective("str") == 12 and hero.get_physical_attack() == plain.get_physical_attack() + 2 and hero.get_physical_defense() == 1 and hero.get_max_capacity() == 118, "AC15 / AC16 STR +2 once: STR 12, Physical Attack +2, Physical Defense 1, Capacity 118")
	EquipmentService.unequip(c, "hero", "WEAPON")
	EquipmentService.equip(c, "hero", W1)
	_check(hero.get_effective("str") == 12 and hero.get_equipment_bonuses() == {"str": 2}, "AC15 Equip / unequip / equip: still once")
	EquipmentService.equip(c, "hero", W2)
	_check(hero.get_effective("str") == 10 and hero.get_effective("int") == 12 and hero.get_magic_attack() == 4 and hero.get_max_mp() == plain.get_max_mp() + 10 and hero.get_magic_defense() == 1, "AC16 INT +2: Magic Attack 4, Max MP +10, Magic Defense 1 (STR back to 10)")
	EquipmentService.equip(c, "hero", A1)
	_check(hero.get_physical_defense() == 2 and hero.get_effective("str") == 10, "AC16 測試防具一: Physical Defense +2 only")
	EquipmentService.equip(c, "hero", A2)
	_check(hero.get_magic_defense() == 1 + 2 and hero.get_physical_defense() == 0, "AC16 測試防具二 (swapped in): Magic Defense +2 on top of INT's 1")
	EquipmentService.unequip(c, "hero", "WEAPON")
	EquipmentService.unequip(c, "hero", "ARMOR")
	_check(hero.get_combat_profile() == plain.get_combat_profile() and hero.get_equipment_bonuses() == {}, "Everything off: exactly the Stage 7 Hero again")
	# Preview = the real result, without changing anything.
	for item_id in ALL:
		for equipped_first in ["", W1, A1]:
			var p := _party(["MAGE"])
			var pc: CharacterCarrying = p["carrying"]
			for each in ALL:
				pc.add_equipment("merc_1", each, 1)
			if equipped_first != "" and equipped_first != item_id:
				pc.equip("merc_1", equipped_first)
			var before := _state(p)
			var preview := pc.preview_equip("merc_1", item_id)
			var unchanged := _state(p) == before
			EquipmentService.equip(pc, "merc_1", item_id)
			_check(preview != null and unchanged and _profile(preview) == _profile(pc.get_stats("merc_1")), "AC17 Preview of %s (after %s) = the real result; nothing changed by the preview" % [item_id, equipped_first if equipped_first != "" else "nothing"])
	_check(c.preview_equip("hero", "nope") == null and c.preview_equip("merc_9", W1) == null and _party([])["carrying"].preview_equip("hero", W1) == null, "No preview for an unknown item / character or an item not carried")
	_sections_done.append("stats")


# --- Capacity ---------------------------------------------------------------------------------------------

func _verify_capacity() -> void:
	var party := _party(["GUARDIAN"])
	var c: CharacterCarrying = party["carrying"]
	for item_id in ALL:
		c.add_equipment("merc_1", item_id, 2)
	var load := c.get_load("merc_1")
	var steps := [["equip", W1], ["equip", A1], ["equip", W2], ["unequip", "ARMOR"], ["equip", A2], ["unequip", "WEAPON"]]
	var same := true
	for step in steps:
		if step[0] == "equip":
			EquipmentService.equip(c, "merc_1", step[1])
		else:
			EquipmentService.unequip(c, "merc_1", step[1])
		same = same and c.get_load("merc_1") == load and c.get_capacity("merc_1") == 10 + c.get_stats("merc_1").get_effective("str") * 9
	_check(same and load == 2 * (3 + 2 + 4 + 3), "AC18 Load stays %d through every equip / swap / unequip; Capacity = 10 + Effective STR x 9" % load)
	# Over capacity: equip / unequip still allowed (load-neutral), nothing deleted.
	var over := _party([])
	var oc: CharacterCarrying = over["carrying"]
	oc.add_equipment("hero", W1, 1)
	EquipmentService.equip(oc, "hero", W1)
	(over["inventory"] as CharacterInventory).add("test_good_06", 28)
	_check(EquipmentService.unequip(oc, "hero", "WEAPON")["success"] and oc.is_over_capacity("hero") and oc.get_load("hero") == 115, "AC18 Unequipping STR gear may leave a legal over-capacity state (115 / 100)")
	_check(EquipmentService.equip(oc, "hero", W1)["success"] and not oc.is_over_capacity("hero") and (over["inventory"] as CharacterInventory).get_quantity("test_good_06") == 28, "AC18 Re-equipping is allowed (load-neutral); nothing deleted")
	_sections_done.append("capacity")


# --- Character UI -----------------------------------------------------------------------------------------

func _verify_panel() -> void:
	_clean()
	var main := await _new_main("")
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "GUARDIAN"), Mercenary.create("merc_2", "GUARDIAN"), Mercenary.create("merc_3", "MAGE")])
	var c: CharacterCarrying = main.carrying
	c.add_equipment("hero", W1, 1)
	c.add_equipment("hero", A1, 2)
	c.add_equipment("merc_2", W2, 1)
	var panel := main.get_node("CharacterPanel") as CharacterPanel
	_check(panel.open() and panel.get_view() == CharacterPanel.VIEW_STATS and (panel.get_node("Panel/Row_str") as Control).visible and not (panel.get_node("Panel/EquipmentView") as Control).visible, "The panel opens on the 屬性 view (Stage 7 rows)")
	var view_button := panel.get_node("Panel/ViewButton") as Button
	_check(view_button.text == "裝備", "The 裝備 view button")
	view_button.pressed.emit()
	await process_frame
	_check(panel.get_view() == CharacterPanel.VIEW_EQUIPMENT and (panel.get_node("Panel/EquipmentView") as Control).visible and not (panel.get_node("Panel/Row_str") as Control).visible and not (panel.get_node("Panel/ConfirmButton") as Control).visible and (panel.get_node("Panel/EquipButton") as Control).visible and view_button.text == "屬性", "裝備 view: equipment shown, allocation hidden, 裝備 replaces 確認分配")
	var lines := panel.get_equipment_lines()
	_check(lines["slots"] == ["武器：無", "防具：無"], "AC01 / AC05 Hero: 武器：無 / 防具：無 (%s)" % str(lines["slots"]))
	_check(lines["rows"] == ["測試武器一 ×1　武器　力量 +2　重量 3", "測試防具一 ×2　防具　物理防禦 +2　重量 4"], "AC04 The Hero's own carried equipment, name / quantity / slot / effect / weight (%s)" % str(lines["rows"]))
	_check(lines["current"] == "目前：力量 10　智力 10　物理攻擊 20　魔法攻擊 0　物理防禦 0　魔法防禦 0　負重 11 / 100", "Current values and load (%s)" % lines["current"])
	_check(lines["preview"] == "選擇一件隨身裝備，查看裝備後的數值" and (panel.get_node("Panel/EquipButton") as Button).disabled, "Nothing chosen: a hint, 裝備 disabled")
	(panel.get_node("Panel/EquipmentView/Carried0") as Button).pressed.emit()
	await process_frame
	lines = panel.get_equipment_lines()
	_check(panel.get_selected_item() == W1 and (panel.get_node("Panel/EquipmentView/Carried0") as Button).disabled and not (panel.get_node("Panel/EquipButton") as Button).disabled, "Tapping the 測試武器一 row chooses it")
	_check(lines["preview"] == "裝備測試武器一後：\n力量 10 → 12　物理攻擊 20 → 22　物理防禦 0 → 1　負重容量 100 → 118", "AC17 Preview before equipping (%s)" % lines["preview"])
	(panel.get_node("Panel/EquipButton") as Button).pressed.emit()
	await process_frame
	lines = panel.get_equipment_lines()
	_check(c.get_equipment("hero").get_equipped("WEAPON") == W1 and lines["slots"][0] == "武器：測試武器一（力量 +2）" and lines["rows"] == ["測試防具一 ×2　防具　物理防禦 +2　重量 4"], "AC06 裝備: equipped, shown in the slot, gone from the rows")
	_check(lines["current"] == "目前：力量 12　智力 10　物理攻擊 22　魔法攻擊 0　物理防禦 1　魔法防禦 0　負重 11 / 118" and panel.get_feedback_text() == "已裝備測試武器一", "AC17 The resulting values and load shown at once; feedback (%s / %s)" % [lines["current"], panel.get_feedback_text()])
	view_button.pressed.emit()
	await process_frame
	_check(panel.get_lines()[4] == "力量 12" and panel.get_lines().has("物理攻擊 22"), "AC17 The 屬性 view shows the equipped stats too")
	view_button.pressed.emit()
	await process_frame
	panel.select_item(A1)
	(panel.get_node("Panel/EquipButton") as Button).pressed.emit()
	await process_frame
	_check(c.get_equipment("hero").get_equipped_items() == {"WEAPON": W1, "ARMOR": A1} and panel.get_equipment_lines()["rows"] == ["測試防具一 ×1　防具　物理防禦 +2　重量 4"], "AC07 Armor equipped; one 測試防具一 left (×1)")
	(panel.get_node("Panel/EquipmentView/Unequip_WEAPON") as Button).pressed.emit()
	await process_frame
	_check(c.get_equipment("hero").get_equipped("WEAPON") == "" and panel.get_equipment_lines()["slots"][0] == "武器：無" and panel.get_feedback_text() == "已卸下測試武器一" and (panel.get_node("Panel/EquipmentView/Unequip_WEAPON") as Button).disabled, "AC11 卸下: back to 無, feedback, 卸下 disabled")
	# Same-type Mercenaries: each its own view.
	panel.select_character("merc_1")
	await process_frame
	_check(panel.get_equipment_lines()["rows"].is_empty() and panel.get_equipment_lines()["carried_title"] == "沒有隨身裝備", "AC02 / AC03 merc_1 (GUARDIAN): nothing carried (merc_2's item not mixed in)")
	panel.select_character("merc_2")
	await process_frame
	_check(panel.get_equipment_lines()["rows"] == ["測試武器二 ×1　武器　智力 +2　重量 2"], "AC02 merc_2 (GUARDIAN): its own 測試武器二")
	_check(panel.select_item(W2) and not panel.select_item(W1), "Only the selected character's carried items can be chosen")
	(panel.get_node("Panel/EquipButton") as Button).pressed.emit()
	await process_frame
	_check(c.get_equipment("merc_2").get_equipped("WEAPON") == W2 and c.get_equipment("merc_1").is_empty() and c.get_equipment("hero").get_equipped("WEAPON") == "", "AC03 / AC13 merc_2 equipped; merc_1 and the Hero untouched")
	_check(panel.get_equipment_lines()["current"].contains("智力 12") and panel.get_equipment_lines()["current"].contains("魔法攻擊 4"), "AC17 merc_2's values updated (INT 12, Magic Attack 4)")
	# Layout: every 裝備 view control on screen, comfortable, not overlapping.
	var canvas := Rect2(0.0, 0.0, 720.0, 1280.0)
	var controls := []
	for path in ["EquipmentView/Unequip_WEAPON", "EquipmentView/Unequip_ARMOR", "EquipmentView/Carried0", "EquipmentView/Carried1", "EquipmentView/Carried2", "EquipmentView/Carried3", "ViewButton", "EquipButton", "CloseButton"]:
		controls.append(panel.get_node("Panel/" + path) as Control)
	var ok := true
	for i in range(controls.size()):
		var rect: Rect2 = (controls[i] as Control).get_global_rect()
		ok = ok and canvas.encloses(rect) and rect.size.y >= 80.0 and rect.size.x >= 160.0
		for j in range(i + 1, controls.size()):
			ok = ok and not rect.intersects((controls[j] as Control).get_global_rect())
	_check(ok, "Mobile layout: every 裝備 view button inside 720 x 1280, >= 160 x 80, none overlapping")
	var labels := ["EquipmentView/Slot_WEAPON", "EquipmentView/Slot_ARMOR", "EquipmentView/CurrentStats", "EquipmentView/CarriedTitle", "EquipmentView/Preview", "FeedbackLabel"]
	var inside := true
	for path in labels:
		inside = inside and canvas.encloses((panel.get_node("Panel/" + path) as Control).get_global_rect())
	_check(inside and (panel.get_node("Panel/EquipmentView/Preview") as Control).get_global_rect().end.y <= (panel.get_node("Panel/EquipButton") as Control).get_global_rect().position.y, "Labels on screen; the preview ends above the bottom buttons")
	# Close / reopen: back on 屬性, nothing pending.
	panel.close()
	_check(panel.open() and panel.get_view() == CharacterPanel.VIEW_STATS and panel.get_selected_item() == "", "Reopening starts on 屬性")
	panel.close()
	await _destroy(main)
	_sections_done.append("panel")


# --- Real game: P02 -> P03, save, restart, failure --------------------------------------------------------

func _verify_game() -> void:
	_clean()
	var main := await _new_main(TEST_SAVE)
	(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
	await _settle()
	main.try_enter_city()
	await _settle()
	main.wallet.add(5000)
	main.recruit_mercenary("MAGE")
	main.recruit_mercenary("MAGE")
	_check(main.buy_equipment("merc_2", A2)["success"] and main.buy_equipment("hero", W1)["success"], "P02 purchases: 測試防具二 for merc_2, 測試武器一 for the Hero")
	_check(main.leave_city(), "Back to the world")
	await _settle()
	var panel := main.get_node("CharacterPanel") as CharacterPanel
	_check(panel.open(), "AC23 The Character UI opens in the world")
	panel.show_view(CharacterPanel.VIEW_EQUIPMENT)
	panel.select_character("merc_2")
	_check(panel.get_equipment_lines()["rows"] == ["測試防具二 ×1　防具　魔法防禦 +2　重量 3"], "AC23 The P02 purchase is visible on merc_2")
	panel.select_item(A2)
	_check(panel.equip_selected() and main.carrying.get_equipment("merc_2").get_equipped("ARMOR") == A2, "AC23 ... and equippable")
	panel.select_character("hero")
	panel.select_item(W1)
	_check(panel.equip_selected() and main.character_stats.get_effective("str") == 12, "Hero equips the bought 測試武器一")
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(raw["version"]) == 14 and raw["carrying"]["merc_2"]["equipped"]["armor"] == A2 and raw["carrying"]["hero"]["equipped"]["weapon"] == W1 and (raw["carrying"]["hero"]["carried_equipment"] as Dictionary).is_empty(), "AC19 Saved at once (v13): equipped slots, carried emptied")
	var state := _main_state(main)
	panel.close()
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(_main_state(main) == state, "AC19 / AC20 Restart: every character's equipped / carried state and stats identical")
	_check(main.character_stats.get_effective("str") == 12 and main.carrying.get_stats("merc_2").get_magic_defense() >= 2 and main.carrying.get_equipment("merc_1").is_empty(), "AC20 Ownership exact after the restart (Hero STR 12, merc_2's armor, merc_1 empty)")
	panel = main.get_node("CharacterPanel") as CharacterPanel
	panel.open()
	panel.show_view(CharacterPanel.VIEW_EQUIPMENT)
	# Unequip saved; then a save failure on equip / unequip.
	_check(panel.unequip_slot("WEAPON") and (JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))["carrying"]["hero"]["equipped"]["weapon"]) == null, "Unequip saved at once")
	main.save_path = BAD_SAVE
	var before := _main_state(main)
	panel.select_item(W1)
	_check(not panel.equip_selected() and panel.get_feedback_text() == "無法儲存，裝備變更已取消" and _main_state(main) == before, "AC21 Save failure on 裝備: 無法儲存，裝備變更已取消, nothing changed")
	panel.select_character("merc_2")
	before = _main_state(main)
	_check(not panel.unequip_slot("ARMOR") and panel.get_feedback_text() == "無法儲存，裝備變更已取消" and _main_state(main) == before, "AC21 Save failure on 卸下: nothing changed")
	main.save_path = TEST_SAVE
	panel.close()
	# Stage 8 still: merc_2 holds gear -> no dismissal.
	(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
	await _settle()
	main.try_enter_city()
	await _settle()
	_check(main.dismiss_mercenary("merc_2")["reason"] == "ERR_HAS_ITEMS", "AC25 A Mercenary with equipped gear still cannot be dismissed")
	main.leave_city()
	await _settle()
	# During a battle no equipment may change (the battle reads the stats).
	(main.get_node("Actors/Player") as Player).global_position = Vector2(950.0, 1080.0)
	await _settle()
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	var in_battle := _main_state(main)
	var refused_equip: Dictionary = main.equip_character_item("hero", W1)
	var refused_unequip: Dictionary = main.unequip_character_slot("merc_2", "ARMOR")
	_check(main.get_combat() != null and refused_equip["reason"] == "ERR_IN_COMBAT" and refused_unequip["reason"] == "ERR_IN_COMBAT" and _main_state(main) == in_battle, "AC26 In a battle: equip / unequip refused (ERR_IN_COMBAT), nothing changes")
	await _destroy(main)
	_clean()
	_sections_done.append("game")


func _verify_scope() -> void:
	_check(SaveStore.VERSION == 14 and SaveStore.V14_KEYS == SaveStore.V13_KEYS + ["condition"], "Save schema still v13")
	var service := _code_only("res://scripts/equipment_service.gd").to_lower()
	for word in ["sell", "transfer", "price", "wallet", "warehouse", "combat", "helmet"]:
		_check(not service.contains(word), "EquipmentService has no %s" % word)
	var combat := ""
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_unit.gd", "res://scripts/combat_view.gd", "res://scripts/combat_config.gd"]:
		combat += _code_only(path).to_lower()
	_check(not combat.contains("equip") and not combat.contains("carrying"), "AC26 Combat code untouched by P03")
	_check(EquipmentCatalog.SLOTS == ["WEAPON", "ARMOR"], "Only the Weapon / Armor slots")
	_sections_done.append("scope")


# --- Stress (TARGETED) ------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9033
	var conservation := 0
	var identity := 0
	var bonus := 0
	var capacity := 0
	var refused_changed := 0
	var reload := 0
	var successes := 0
	var failures := 0
	for run in range(60):
		var types := []
		for i in range(rng.randi_range(1, 5)):
			types.append(["GUARDIAN", "MAGE", "STRATEGIST"][rng.randi_range(0, 2)])
		var party := _party(types)
		(party["roster"] as MercenaryRoster).pend_legacy(Mercenary.create("merc_a", "GUARDIAN"))
		var ids: Array = ["hero"] + (party["roster"] as MercenaryRoster).get_owned().map(func(m: Mercenary) -> String: return m.get_id())
		var owned := {}
		for id in ids:
			owned[id] = {}
			for item_id in ALL:
				var n := rng.randi_range(0, 2)
				if n > 0 and (party["carrying"] as CharacterCarrying).add_equipment(id, item_id, n):
					owned[id][item_id] = n
		if rng.randi_range(0, 2) == 0:
			(party["inventory"] as CharacterInventory).add("test_good_06", rng.randi_range(20, 25))
		for step in range(100):
			var c: CharacterCarrying = party["carrying"]
			var id: String = (ids + ["merc_a", "merc_9"])[rng.randi_range(0, ids.size() + 1)]
			var fail := rng.randi_range(0, 4) == 0
			var persist := func() -> bool: return not fail
			var before := _state(party)
			var loads := {}
			for each in ids:
				loads[each] = c.get_load(each)
			var r: Dictionary
			if rng.randi_range(0, 2) == 0:
				r = EquipmentService.unequip(c, id, ["WEAPON", "ARMOR", "HELMET"][rng.randi_range(0, 2)], persist)
			else:
				var slot: String = ["", "", "", "WEAPON", "ARMOR"][rng.randi_range(0, 4)]
				r = EquipmentService.equip(c, id, (ALL + ["test_good_01"])[rng.randi_range(0, 4)], persist, slot)
			if r["success"]:
				successes += 1
			else:
				failures += 1
				if _state(party) != before:
					refused_changed += 1
			for each in ids:
				var e := c.get_equipment(each)
				for item_id in ALL:
					if e.get_total_quantity(item_id) != int(owned[each].get(item_id, 0)):
						conservation += 1
				if c.get_load(each) != loads[each] or c.get_capacity(each) != 10 + c.get_stats(each).get_effective("str") * 9:
					capacity += 1
				if c.get_stats(each).get_equipment_bonuses() != e.get_bonuses():
					bonus += 1
			if c.get_equipment("merc_a") != null or c.get_equipment("merc_9") != null:
				identity += 1
			if step % 25 == 24:
				var reloaded := _load(_serialize(party))
				var next := {"carrying": reloaded.get("carrying"), "roster": reloaded.get("mercenaries"), "inventory": reloaded.get("inventory"), "stats": reloaded.get("character_stats"), "wallet": reloaded.get("wallet")}
				if reloaded.is_empty() or _state(next) != _state(party):
					reload += 1
				else:
					party = next
	_check(successes > 1000 and failures > 1000, "Stress: %d equip / unequip done, %d refused or failed" % [successes, failures])
	_check(conservation == 0, "Stress: every character always owns exactly its items (no duplication / loss / transfer) (%d)" % conservation)
	_check(identity == 0, "Stress: no state ever created for pending / unknown ids (%d)" % identity)
	_check(bonus == 0, "Stress: stats bonuses always equal the equipped items, counted once (%d)" % bonus)
	_check(capacity == 0, "Stress: load unchanged by every operation; Capacity exact (%d)" % capacity)
	_check(refused_changed == 0, "Stress: every refused / failed operation changed nothing (%d)" % refused_changed)
	_check(reload == 0, "Stress: save / reload identical (%d)" % reload)
	# Real game: equip / unequip / restart cycles.
	_clean()
	var main := await _new_main(TEST_SAVE)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_1", "MAGE"), Mercenary.create("merc_2", "MAGE")])
	for id in ["hero", "merc_1", "merc_2"]:
		for item_id in ALL:
			main.carrying.add_equipment(id, item_id, 1)
	main._persist()
	var game_bad := 0
	for cycle in range(8):
		var id: String = ["hero", "merc_1", "merc_2"][cycle % 3]
		var item_id: String = ALL[cycle % 4]
		main.save_path = BAD_SAVE
		var state := _main_state(main)
		if main.equip_character_item(id, item_id)["success"] or _main_state(main) != state:
			game_bad += 1
		main.save_path = TEST_SAVE
		if not main.equip_character_item(id, item_id)["success"]:
			game_bad += 1
		if cycle % 2 == 1 and not main.unequip_character_slot(id, EquipmentCatalog.get_slot(item_id))["success"]:
			game_bad += 1
		var saved_state := _main_state(main)
		await _destroy(main)
		main = await _new_main(TEST_SAVE)
		if _main_state(main) != saved_state:
			game_bad += 1
	_check(game_bad == 0, "Stress: 8 real-game cycles (failed save, equip, unequip, restart) exact (%d)" % game_bad)
	await _destroy(main)
	_clean()
	_sections_done.append("stress")


# --- Helpers ----------------------------------------------------------------------------------------------

## merc_1 equips its only 測試武器一, then tries to equip another one it does
## not carry (merc_2 / the Hero still do): refused, nothing moves. Leaves
## merc_1 as it was (unequipped again before returning).
func _not_carried(c: CharacterCarrying) -> Dictionary:
	c.equip("merc_1", W1)
	var result := EquipmentService.equip(c, "merc_1", W1)
	c.unequip("merc_1", "WEAPON")
	return result


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


func _serialize(party: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(SaveStore.serialize(party["wallet"], party["inventory"], MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.new(), {"hero": party["stats"]}, party["roster"], party["carrying"])))


func _load(data: Dictionary) -> Dictionary:
	var payload := SaveStore.validate(JSON.parse_string(JSON.stringify(data)))
	return {} if payload.is_empty() else SaveStore._rebuild(payload)


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
