extends SceneTree

## Stage 9 P01: Equipment Foundation + Character Carrying Foundation.
##   catalog      EquipmentCatalog: the four approved Prototype test items
##                (Weapon STR / INT, Armor Physical / Magic Defense), slots,
##                weights, fixed bonuses, definition validation
##   state        CharacterEquipment via CharacterCarrying: equip (empty /
##                occupied = swap), unequip, Hero, several Mercenaries (same
##                type, separate ids), no duplicated ownership, refused
##                operations change nothing
##   stats        the Equipment layer once (on / off), STR -> Capacity, INT ->
##                Magic Attack / Max MP / Magic Defense, armor -> the derived
##                defenses only, nothing equipped = Stage 7 exactly
##   capacity     goods + carried + equipped load, STR gear raises Capacity,
##                removing it may leave a legal over-capacity state (nothing
##                deleted, new load refused), no caller-supplied weight
##   mercenary    stable instance identity, deploy / undeploy, progression
##                unchanged, pending never holds, Stage 8 dismissal refused
##                while holding anything (ERR_HAS_ITEMS), atomic
##   save         Save v13: round trips, v1-v12 -> v13 (everything kept,
##                carrying empty), malformed carrying rejected, future v14
##                unreadable, failed saves leave the old file intact, real
##                main restart
##   combat       no equipment: combat profiles unchanged
##   stress       FULL: randomized equip / unequip / transfer / add / remove /
##                goods / save / reload / migration lifecycles

const TEST_SAVE := "user://s9_p01_equipment_test.json"
const BAD_SAVE := "user://s9_p01_missing_dir/save.json"
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
	_verify_catalog()
	_verify_state()
	_verify_stats()
	_verify_capacity()
	_verify_mercenary()
	_verify_save()
	await _verify_game()
	_verify_combat()
	_verify_scope()
	await _verify_stress()
	_check(_sections_done.size() == 10, "Every test section must run to completion (%s)" % str(_sections_done))
	_clean()
	if _failures == 0:
		print("S9 P01 equipment foundation verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Catalog ----------------------------------------------------------------------------------------------

func _verify_catalog() -> void:
	_check(EquipmentCatalog.get_ids() == ALL, "Four Prototype test items (%s)" % str(EquipmentCatalog.get_ids()))
	_check(EquipmentCatalog.SLOTS == ["WEAPON", "ARMOR"], "Only the WEAPON and ARMOR slots")
	_check(EquipmentCatalog.get_item(W1) == {"id": W1, "display_name": "測試武器一", "slot": "WEAPON", "capacity_cost": 3, "bonuses": {"str": 2}}, "測試武器一: WEAPON, weight 3, STR +2")
	_check(EquipmentCatalog.get_item(W2) == {"id": W2, "display_name": "測試武器二", "slot": "WEAPON", "capacity_cost": 2, "bonuses": {"int": 2}}, "測試武器二: WEAPON, weight 2, INT +2")
	_check(EquipmentCatalog.get_item(A1) == {"id": A1, "display_name": "測試防具一", "slot": "ARMOR", "capacity_cost": 4, "bonuses": {"physical_defense": 2}}, "測試防具一: ARMOR, weight 4, Physical Defense +2")
	_check(EquipmentCatalog.get_item(A2) == {"id": A2, "display_name": "測試防具二", "slot": "ARMOR", "capacity_cost": 3, "bonuses": {"magic_defense": 2}}, "測試防具二: ARMOR, weight 3, Magic Defense +2")
	_check(EquipmentCatalog.is_valid_catalog(), "The whole catalog is valid (unique ids)")
	var code := FileAccess.get_file_as_string("res://scripts/equipment_catalog.gd")
	_check(code.contains("PROTOTYPE TEST VALUE") and code.contains("not final balance"), "Marked as Prototype test values, not final balance")
	for item_id in ALL:
		_check(not GoodsCatalog.has_good(item_id) and EquipmentCatalog.get_capacity_cost(item_id) > 0, "%s is not a trade good; authoritative weight %d" % [item_id, EquipmentCatalog.get_capacity_cost(item_id)])
	_check(not EquipmentCatalog.has_item("test_good_01") and not EquipmentCatalog.has_item("") and not EquipmentCatalog.has_item(null) and not EquipmentCatalog.has_item(7) and not EquipmentCatalog.has_item("test_helmet_01"), "Invalid items: a good, empty, null, a number, an unknown id")
	_check(EquipmentCatalog.get_slot("nope") == "" and EquipmentCatalog.get_capacity_cost("nope") == 0 and EquipmentCatalog.get_bonuses("nope") == {}, "Unknown item: no slot, no weight, no bonus")
	_check(not EquipmentCatalog.is_slot("HELMET") and not EquipmentCatalog.is_slot("weapon") and not EquipmentCatalog.is_slot(null), "Invalid slots: HELMET, lower case, null")
	# Definition validation (fixed bonuses, authoritative weight).
	var good: Dictionary = EquipmentCatalog.get_item(W1)
	var bad := {
		"helmet slot": _with(good, {"slot": "HELMET"}),
		"zero weight": _with(good, {"capacity_cost": 0}),
		"float weight": _with(good, {"capacity_cost": 3.0}),
		"no bonus": _with(good, {"bonuses": {}}),
		"negative bonus": _with(good, {"bonuses": {"str": -2}}),
		"zero bonus": _with(good, {"bonuses": {"str": 0}}),
		"unknown stat": _with(good, {"bonuses": {"luck": 2}}),
		"random affix field": _with(good, {"affix": "random"}),
		"goods id": _with(good, {"id": "test_good_01"}),
		"empty id": _with(good, {"id": ""}),
		"armor with STR": _with(EquipmentCatalog.get_item(A1), {"bonuses": {"str": 2}}),
		"armor with HP": _with(EquipmentCatalog.get_item(A1), {"bonuses": {"hp": 30}}),
		"float bonus": _with(good, {"bonuses": {"str": 2.0}}),
	}
	for label in bad:
		_check(not EquipmentCatalog.is_valid_definition(bad[label]), "Invalid definition refused: %s" % label)
	_check(not EquipmentCatalog.is_valid_catalog([good, good]) and not EquipmentCatalog.is_valid_catalog([]), "Duplicate ids / an empty catalog refused")
	_check(EquipmentCatalog.ITEMS.all(func(i: Dictionary) -> bool: return i["slot"] != "ARMOR" or (i["bonuses"] as Dictionary).keys().all(func(s: String) -> bool: return EquipmentCatalog.DERIVED_BONUS_STATS.has(s))), "Armor affects only the defenses (Canonical)")
	_sections_done.append("catalog")


# --- Equipment state --------------------------------------------------------------------------------------

func _verify_state() -> void:
	var party := _party(["GUARDIAN", "GUARDIAN", "MAGE"])
	var carrying: CharacterCarrying = party["carrying"]
	var hero: CharacterEquipment = carrying.get_equipment("hero")
	_check(hero != null and hero.is_empty() and hero.get_equipped("WEAPON") == "" and hero.get_equipped("ARMOR") == "", "The Hero starts with nothing")
	_check(carrying.add_equipment("hero", W1, 1) and carrying.add_equipment("hero", W2, 1) and carrying.add_equipment("hero", A1, 1), "Hero gets 測試武器一 / 二 and 測試防具一 (carried)")
	_check(hero.get_carried() == {W1: 1, W2: 1, A1: 1} and hero.get_equipped_items() == {}, "Carried, not equipped")
	_check(carrying.equip("hero", W1) and hero.get_equipped("WEAPON") == W1 and hero.get_carried() == {W2: 1, A1: 1}, "Equip into the empty Weapon slot")
	_check(carrying.equip("hero", W2) and hero.get_equipped("WEAPON") == W2 and hero.get_carried() == {W1: 1, A1: 1}, "Occupied slot: 測試武器二 swaps with 測試武器一 (back to carried)")
	_check(carrying.equip("hero", A1) and hero.get_equipped_items() == {"WEAPON": W2, "ARMOR": A1} and hero.get_carried() == {W1: 1}, "Armor slot independent")
	_check(carrying.unequip("hero", "WEAPON") and hero.get_equipped("WEAPON") == "" and hero.get_carried() == {W1: 1, W2: 1}, "Unequip: back to carried")
	_check(not carrying.unequip("hero", "WEAPON") and not carrying.unequip("hero", "HELMET") and not carrying.unequip("hero", null), "Unequip an empty / invalid slot: refused")
	# Several Mercenaries, two of the same type, separate ids.
	var roster: MercenaryRoster = party["roster"]
	var ids: Array = roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id())
	_check(ids == ["merc_1", "merc_2", "merc_3"] and roster.get_mercenary("merc_1").get_type() == roster.get_mercenary("merc_2").get_type(), "Two GUARDIAN instances merc_1 / merc_2 and a MAGE")
	_check(carrying.add_equipment("merc_1", W1, 1) and carrying.equip("merc_1", W1), "merc_1 equips 測試武器一")
	_check(carrying.get_equipment("merc_2").is_empty() and carrying.get_equipment("merc_1").get_equipped("WEAPON") == W1, "merc_2 (same type) stays empty: keyed by instance id, not type")
	_check(carrying.get_stats("merc_1").get_effective("str") == carrying.get_stats("merc_2").get_effective("str") + 2, "Only merc_1 gets the STR bonus")
	# Ownership never duplicated: transfer moves, the total is kept.
	var before := _totals(carrying, ["hero"] + ids)
	_check(carrying.transfer_equipment("hero", "merc_2", W1, 1) and carrying.get_equipment("hero").get_carried_quantity(W1) == 0 and carrying.get_equipment("merc_2").get_carried_quantity(W1) == 1, "Transfer moves 測試武器一 Hero -> merc_2")
	_check(_totals(carrying, ["hero"] + ids) == before, "Total of every item unchanged by the transfer (no duplicate, no loss)")
	_check(not carrying.transfer_equipment("hero", "merc_2", W1, 1), "Transferring an item no longer held: refused")
	_check(not carrying.transfer_equipment("merc_1", "hero", W1, 1), "An equipped item cannot be transferred (only carried ones)")
	# Rejected operations change nothing.
	var snapshot := _state_text(carrying, ["hero"] + ids)
	var refused := [
		carrying.equip("hero", A2), carrying.equip("hero", "nope"), carrying.equip("nobody", W2), carrying.equip("merc_9", W2),
		carrying.add_equipment("hero", "test_good_01", 1), carrying.add_equipment("hero", "nope", 1), carrying.add_equipment("hero", W1, 0), carrying.add_equipment("hero", W1, -1), carrying.add_equipment("hero", W1, 1.0), carrying.add_equipment("merc_9", W1, 1),
		carrying.remove_equipment("hero", W2, 2), carrying.remove_equipment("hero", A1, 1), carrying.remove_equipment("hero", W2, 0),
		carrying.transfer_equipment("hero", "hero", W2, 1), carrying.transfer_equipment("hero", "merc_9", W2, 1), carrying.transfer_equipment("merc_9", "hero", W2, 1), carrying.transfer_equipment("hero", "merc_1", W2, 0),
	]
	_check(refused.all(func(r: bool) -> bool: return not r), "Invalid character / item / slot / quantity: every operation refused")
	_check(_state_text(carrying, ["hero"] + ids) == snapshot, "Refused operations left every character exactly as before")
	_check(carrying.get_equipment("nobody") == null and carrying.get_inventory("nobody") == null and carrying.get_stats("nobody") == null and carrying.get_load("nobody") == -1, "No state for a non-character")
	_check(carrying.remove_equipment("hero", W2, 1) and carrying.get_equipment("hero").get_carried_quantity(W2) == 0, "remove_equipment takes carried items out")
	_sections_done.append("state")


# --- Stats ------------------------------------------------------------------------------------------------

func _verify_stats() -> void:
	var party := _party(["MAGE"])
	var carrying: CharacterCarrying = party["carrying"]
	var stats: CharacterStats = carrying.get_stats("hero")
	var plain := CharacterStats.new()
	_check(_profile(stats) == _profile(plain) and stats.get_equipment_bonuses() == {}, "Nothing equipped: exactly the Stage 7 Hero")
	carrying.add_equipment("hero", W1, 1)
	_check(_profile(stats) == _profile(plain), "Carried (not equipped) gear gives no bonus")
	carrying.equip("hero", W1)
	_check(stats.get_equipment_bonus("str") == 2 and stats.get_effective("str") == 12 and stats.get_max_capacity() == 10 + 12 * 9, "STR +2 once: Effective STR 12, Capacity 118")
	_check(stats.get_physical_attack() == plain.get_physical_attack() + 2 and stats.get_physical_defense() == 1, "STR flows through the Stage 7 formulas (Physical Attack +2, Physical Defense floor(2 x 0.5) = 1)")
	carrying.unequip("hero", "WEAPON")
	carrying.equip("hero", W1)
	carrying.unequip("hero", "WEAPON")
	_check(_profile(stats) == _profile(plain) and stats.get_equipment_bonuses() == {}, "Equip / unequip twice: the bonus removed exactly (no leftover, no double)")
	carrying.equip("hero", W1)
	carrying.add_equipment("hero", W2, 1)
	carrying.equip("hero", W2)
	_check(stats.get_equipment_bonuses() == {"int": 2} and stats.get_effective("str") == 10, "Swapping weapons: only the new weapon's bonus (no STR left)")
	_check(stats.get_effective("int") == 12 and stats.get_magic_attack() == 4 and stats.get_max_mp() == plain.get_max_mp() + 10 and stats.get_magic_defense() == 1, "INT +2: Magic Attack 4, Max MP +10, Magic Defense 1 (Stage 7 formulas)")
	carrying.unequip("hero", "WEAPON")
	carrying.add_equipment("hero", A1, 1)
	carrying.equip("hero", A1)
	_check(stats.get_physical_defense() == 2 and stats.get_magic_defense() == 0 and stats.get_effective("str") == 10 and stats.get_physical_attack() == plain.get_physical_attack() and stats.get_max_capacity() == plain.get_max_capacity(), "測試防具一: Physical Defense +2 only (no STR, attack or Capacity change)")
	carrying.add_equipment("hero", A2, 1)
	carrying.equip("hero", A2)
	_check(stats.get_magic_defense() == 2 and stats.get_physical_defense() == 0 and stats.get_effective("int") == 10 and stats.get_max_mp() == plain.get_max_mp() and stats.get_magic_attack() == 0, "測試防具二: Magic Defense +2 only (no INT, MP or Magic Attack change)")
	carrying.equip("hero", W1)
	_check(stats.get_physical_defense() == 1 and stats.get_magic_defense() == 2 and stats.get_equipment_bonuses() == {"str": 2, "magic_defense": 2}, "Weapon + armor together: each bonus once")
	var copy := stats.duplicate_stats()
	_check(copy.get_magic_defense() == 2 and copy.get_effective("str") == 12, "duplicate_stats keeps the equipment layers (previews)")
	_check(not stats.apply_equipment_bonuses({"luck": 1}) and not stats.apply_equipment_bonuses({"str": -1}) and stats.get_equipment_bonuses() == {"str": 2, "magic_defense": 2}, "Invalid bonus sets refused as a whole")
	# A Mercenary: its own stats + its equipment, rebuilt every time.
	var mage := carrying.get_stats("merc_1")
	var base_mage := CharacterStats.for_mercenary((party["roster"] as MercenaryRoster).get_mercenary("merc_1"))
	_check(_profile(mage) == _profile(base_mage), "A Mercenary with nothing: exactly CharacterStats.for_mercenary")
	carrying.add_equipment("merc_1", W2, 1)
	carrying.equip("merc_1", W2)
	_check(carrying.get_stats("merc_1").get_magic_attack() == base_mage.get_magic_attack() + 4 and carrying.get_stats("merc_1").get_effective("int") == base_mage.get_effective("int") + 2, "Mercenary INT +2: Magic Attack +4 on its own stats")
	_check(_profile(CharacterStats.for_mercenary((party["roster"] as MercenaryRoster).get_mercenary("merc_1"))) == _profile(base_mage), "for_mercenary itself stays equipment-free (Stage 8 unchanged)")
	_sections_done.append("stats")


# --- Capacity ---------------------------------------------------------------------------------------------

func _verify_capacity() -> void:
	var party := _party([])
	var carrying: CharacterCarrying = party["carrying"]
	var backpack: CharacterInventory = party["inventory"]
	_check(backpack.get_max_capacity() == 100 and backpack.get_used_capacity() == 0, "Hero: Capacity 100, empty")
	carrying.add_equipment("hero", W1, 1)
	_check(backpack.get_used_capacity() == 3 and carrying.get_load("hero") == 3, "Carried gear counts (weight 3)")
	carrying.equip("hero", W1)
	_check(backpack.get_used_capacity() == 3 and backpack.get_max_capacity() == 118, "Equipped gear counts too (still 3); STR +2 raises Capacity to 118")
	_check(backpack.add("test_good_06", 28), "Goods: 28 x weight 4 = 112")
	_check(backpack.get_goods_load() == 112 and backpack.get_extra_load() == 3 and backpack.get_used_capacity() == 115 and backpack.get_remaining_capacity() == 3, "Load = goods 112 + equipment 3 = 115 of 118")
	_check(not backpack.add("test_good_06", 1) and not carrying.add_equipment("hero", A1, 1), "Beyond Capacity: goods / equipment refused (equipment counted)")
	_check(carrying.add_equipment("hero", W1, 1) and backpack.get_used_capacity() == 118, "Exactly full: allowed")
	# Removing the STR gear: legal over capacity, nothing deleted.
	var goods := backpack.get_items()
	var gear := carrying.get_equipment("hero").get_carried()
	_check(carrying.unequip("hero", "WEAPON"), "Unequipping STR gear is allowed even though it lowers Capacity")
	_check(backpack.get_max_capacity() == 100 and backpack.get_used_capacity() == 118 and backpack.is_over_capacity() and carrying.is_over_capacity("hero"), "Legal over capacity: 118 / 100")
	_check(backpack.get_items() == goods and carrying.get_equipment("hero").get_carried() == {W1: 2} and gear == {W1: 1}, "Nothing deleted, nothing moved away")
	_check(not backpack.add("test_good_01", 1) and not carrying.add_equipment("hero", W2, 1), "Over capacity: any new load refused (goods and equipment)")
	_check(carrying.equip("hero", W1) and backpack.get_max_capacity() == 118 and not backpack.is_over_capacity(), "Equip again (load-neutral, allowed while over): back within Capacity")
	_check(carrying.unequip("hero", "WEAPON") and backpack.is_over_capacity() and backpack.remove("test_good_06", 5) and not backpack.is_over_capacity() and backpack.add("test_good_01", 1), "Selling / dropping goods ends the over-capacity; adding works again")
	# Over-capacity destination refuses transfers; the source keeps its item.
	var over := _party(["GUARDIAN"])
	var oc: CharacterCarrying = over["carrying"]
	oc.add_equipment("hero", W1, 1)
	oc.equip("hero", W1)
	(over["inventory"] as CharacterInventory).add("test_good_06", 28)
	oc.unequip("hero", "WEAPON")
	oc.add_equipment("merc_1", W2, 1)
	_check(oc.is_over_capacity("hero") and not oc.transfer_equipment("merc_1", "hero", W2, 1) and oc.get_equipment("merc_1").get_carried_quantity(W2) == 1, "Transfer into an over-capacity character refused; the source keeps it")
	_check(oc.transfer_equipment("hero", "merc_1", W1, 1) and oc.get_equipment("merc_1").get_carried_quantity(W1) == 1, "An over-capacity character may give items away")
	# Mercenary capacity: its own stats.
	var mc: CharacterCarrying = _party(["GUARDIAN"])["carrying"]
	var cap := mc.get_capacity("merc_1")
	_check(cap == 10 + mc.get_stats("merc_1").get_effective("str") * 9 and cap == 100, "Mercenary Capacity from its own Effective STR (100)")
	_check(mc.add_equipment("merc_1", A1, 25) and mc.get_load("merc_1") == 100 and not mc.add_equipment("merc_1", A2, 1), "Mercenary: 25 x 測試防具一 = 100 fills it; more refused")
	_check(mc.get_inventory("merc_1").get_extra_load() == 100 and not mc.get_inventory("merc_1").add("test_good_01", 1), "The Mercenary's goods inventory sees the same load")
	# No caller-supplied weight anywhere.
	var fake := CharacterInventory.new("hero", CharacterStats.new())
	_check(not fake.restore_stacks({"test_good_06": {"quantity": 1, "capacity_cost": 1}}), "Snapshots cannot inject a fake weight")
	_check(CharacterCarrying.new().get_script().get_script_method_list().filter(func(m: Dictionary) -> bool: return m["name"] == "add_equipment")[0]["args"].size() == 3, "add_equipment takes no weight argument (character, item, quantity)")
	_sections_done.append("capacity")


# --- Mercenary --------------------------------------------------------------------------------------------

func _verify_mercenary() -> void:
	var party := _party(["MAGE", "MAGE"])
	var roster: MercenaryRoster = party["roster"]
	var carrying: CharacterCarrying = party["carrying"]
	carrying.add_equipment("merc_2", W2, 1)
	carrying.equip("merc_2", W2)
	var before := JSON.stringify(roster.to_dict())
	_check(roster.set_deployment(["merc_2"]) and carrying.get_equipment("merc_2").get_equipped("WEAPON") == W2, "Deploy: merc_2 keeps its gear")
	_check(roster.set_deployment([]) and carrying.get_equipment("merc_2").get_equipped("WEAPON") == W2 and carrying.get_equipment("merc_1").is_empty(), "Undeploy: ownership unchanged")
	_check(JSON.stringify(roster.to_dict()) == before, "Mercenary id / type / Level / EXP / allocation untouched by equipment")
	var merc := roster.get_mercenary("merc_2")
	_check(merc.add_exp(150) and carrying.get_stats("merc_2").get_effective("int") == CharacterStats.for_mercenary(merc).get_effective("int") + 2, "A Level Up keeps the gear bonus on the new Level (stats rebuilt)")
	# Pending legacy Mercenaries hold nothing.
	roster.pend_legacy(Mercenary.create("merc_a", "GUARDIAN"))
	_check(not carrying.is_character("merc_a") and carrying.get_equipment("merc_a") == null and not carrying.add_equipment("merc_a", W1, 1) and not carrying.transfer_equipment("hero", "merc_a", W1, 1), "A pending Mercenary cannot hold or receive anything")
	# Dismissal refused while holding anything (each kind), allowed empty.
	for kind in ["weapon", "armor", "carried", "goods"]:
		var p := _party(["GUARDIAN", "GUARDIAN"])
		var c: CharacterCarrying = p["carrying"]
		var r: MercenaryRoster = p["roster"]
		match kind:
			"weapon":
				c.add_equipment("merc_1", W1, 1)
				c.equip("merc_1", W1)
			"armor":
				c.add_equipment("merc_1", A1, 1)
				c.equip("merc_1", A1)
			"carried":
				c.add_equipment("merc_1", A2, 2)
			"goods":
				c.get_inventory("merc_1").add("test_good_01", 1)
		var held := _state_text(c, ["hero", "merc_1"])
		var result := PartyService.dismiss(r, "merc_1", Callable(), c)
		_check(not result["success"] and result["reason"] == PartyService.ERR_HAS_ITEMS and r.get_mercenary("merc_1") != null and _state_text(c, ["hero", "merc_1"]) == held, "Holding %s: dismissal refused (ERR_HAS_ITEMS), nothing deleted or moved" % kind)
	var empty_party := _party(["GUARDIAN", "GUARDIAN"])
	var ec: CharacterCarrying = empty_party["carrying"]
	ec.add_equipment("merc_2", W1, 1)
	_check(PartyService.dismiss(empty_party["roster"], "merc_1", Callable(), ec)["success"] and not ec.is_character("merc_1") and ec.get_equipment("merc_2").get_carried_quantity(W1) == 1, "Empty merc_1 dismissed; merc_2's gear untouched")
	# A dismissal whose save fails restores roster and carrying.
	var failing := _party(["GUARDIAN"])
	var fc: CharacterCarrying = failing["carrying"]
	var fr: MercenaryRoster = failing["roster"]
	var roster_text := JSON.stringify(fr.to_dict())
	var res := PartyService.dismiss(fr, "merc_1", func() -> bool: return false, fc)
	_check(not res["success"] and res["reason"] == PartyService.ERR_SAVE_FAILED and JSON.stringify(fr.to_dict()) == roster_text and fc.is_character("merc_1") and fc.add_equipment("merc_1", W1, 1), "Save failure: dismissal undone, the Mercenary and its carrying back")
	_check(not fc.forget("merc_1") and not fc.forget("hero"), "A holding character / the Hero is never forgotten")
	_check(CityHub.PARTY_FAILURE_MESSAGES.get("ERR_HAS_ITEMS", "") == "請先清空此傭兵攜帶的物品及裝備，再解僱", "Player text for the refusal (Traditional Chinese)")
	_sections_done.append("mercenary")


# --- Save v13 ---------------------------------------------------------------------------------------------

func _verify_save() -> void:
	_check(SaveStore.VERSION == 13 and SaveStore.INVENTORY_VERSIONS == [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13] and SaveStore.V13_KEYS == SaveStore.V12_KEYS + ["carrying"], "Save v13 = v12 + carrying")
	# Clean / empty round trip.
	var empty := _party(["GUARDIAN"])
	var data := _serialize(empty)
	_check(data["carrying"] == _json({"hero": {"equipped": {"weapon": null, "armor": null}, "carried_equipment": {}}, "merc_1": {"equipped": {"weapon": null, "armor": null}, "carried_equipment": {}, "goods": {}}}), "Empty carrying written for the Hero and every owned Mercenary")
	var text := JSON.stringify(data).to_lower()
	for word in ["bonus", "effective", "capacity\"", "max_hp", "physical_defense", "magic_defense", "frozen"]:
		_check(not text.contains(word), "Nothing derived saved: no %s" % word)
	var reloaded := _load(data)
	_check(not reloaded.is_empty() and JSON.stringify(_serialize_loaded(reloaded)) == JSON.stringify(data), "Empty v13 round trip: identical")
	# Hero + Mercenary equipment round trip.
	var full := _party(["GUARDIAN", "MAGE"])
	var c: CharacterCarrying = full["carrying"]
	c.add_equipment("hero", W1, 2)
	c.equip("hero", W1)
	c.add_equipment("hero", A2, 1)
	c.equip("hero", A2)
	c.add_equipment("merc_2", W2, 1)
	c.equip("merc_2", W2)
	c.add_equipment("merc_2", A1, 3)
	c.add_equipment("merc_1", A1, 1)
	c.equip("merc_1", A1)
	(full["roster"] as MercenaryRoster).set_deployment(["merc_2"])
	data = _serialize(full)
	_check(data["carrying"]["hero"] == _json({"equipped": {"weapon": W1, "armor": A2}, "carried_equipment": {W1: 1}}), "Hero saved: weapon + armor + 1 carried")
	_check(data["carrying"]["merc_2"] == _json({"equipped": {"weapon": W2, "armor": null}, "carried_equipment": {A1: 3}, "goods": {}}) and data["carrying"]["merc_1"]["equipped"]["armor"] == A1, "Mercenaries saved by id")
	reloaded = _load(data)
	var rc: CharacterCarrying = reloaded["carrying"]
	_check(not reloaded.is_empty() and _state_text(rc, ["hero", "merc_1", "merc_2"]) == _state_text(c, ["hero", "merc_1", "merc_2"]), "Equipment round trip: every character identical")
	_check((reloaded["character_stats"] as CharacterStats).get_effective("str") == 12 and (reloaded["character_stats"] as CharacterStats).get_magic_defense() == 2 and rc.get_load("hero") == 3 + 3 + 3, "Reload: Hero bonuses re-applied from the equipped items; load 9")
	_check(rc.get_stats("merc_2").get_effective("int") == c.get_stats("merc_2").get_effective("int") and (reloaded["mercenaries"] as MercenaryRoster).get_deployed_ids() == ["merc_2"], "Reload: Mercenary bonuses and deployment")
	_check(JSON.stringify(_serialize_loaded(reloaded)) == JSON.stringify(data), "Save -> load -> save: identical")
	# Legal over capacity survives a reload (nothing dropped).
	var oc := _party([])
	var occ: CharacterCarrying = oc["carrying"]
	occ.add_equipment("hero", W1, 1)
	occ.equip("hero", W1)
	(oc["inventory"] as CharacterInventory).add("test_good_06", 28)
	occ.unequip("hero", "WEAPON")
	var over := _load(_serialize(oc))
	_check(not over.is_empty() and (over["inventory"] as CharacterInventory).get_used_capacity() == 115 and (over["inventory"] as CharacterInventory).is_over_capacity() and (over["inventory"] as CharacterInventory).get_quantity("test_good_06") == 28, "An over-capacity save loads as it is (nothing dropped)")
	# Malformed carrying rejects the whole save.
	var good := _serialize(full)
	var c_good: Dictionary = good["carrying"]
	var broken := {
		"missing section": _without(good, "carrying"),
		"not a dict": _with(good, {"carrying": []}),
		"hero missing": _with(good, {"carrying": _without(c_good, "hero")}),
		"owned merc missing": _with(good, {"carrying": _without(c_good, "merc_1")}),
		"unknown id": _with(good, {"carrying": _with(c_good, {"merc_9": c_good["merc_1"]})}),
		"wrong slot": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"equipped": {"weapon": A1, "armor": null}})})}),
		"unknown item": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"carried_equipment": {"test_sword_99": 1}})})}),
		"goods as equipment": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"carried_equipment": {"test_good_01": 1}})})}),
		"zero quantity": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"carried_equipment": {W1: 0}})})}),
		"negative quantity": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"carried_equipment": {W1: -1}})})}),
		"fractional quantity": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"carried_equipment": {W1: 1.5}})})}),
		"slot missing": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"equipped": {"weapon": W1}})})}),
		"extra slot": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"equipped": {"weapon": W1, "armor": null, "helmet": null}})})}),
		"derived bonus saved": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"bonus": {"str": 2}})})}),
		"hero with goods key": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"goods": {}})})}),
		"merc goods missing": _with(good, {"carrying": _with(c_good, {"merc_1": _without(c_good["merc_1"], "goods")})}),
		"merc goods not empty (P01 gap)": _with(good, {"carrying": _with(c_good, {"merc_1": _with(c_good["merc_1"], {"goods": {"test_good_01": {"quantity": 1}}})})}),
		"pending merc entry": _with(_with(good, {"pending_legacy_mercenaries": [{"id": "merc_a", "type": "GUARDIAN", "level": 1, "exp": 0, "allocation": {"hp": 0, "str": 0, "agi": 0, "int": 0}}]}), {"carrying": _with(c_good, {"merc_a": c_good["merc_1"]})}),
		"id as number": _with(good, {"carrying": _with(c_good, {"hero": _with(c_good["hero"], {"equipped": {"weapon": 7, "armor": null}})})}),
	}
	for label in broken:
		_check(SaveStore.validate(_json(broken[label])).is_empty(), "Malformed carrying rejected: %s" % label)
	_check(not SaveStore.validate(_json(good)).is_empty(), "(the unbroken save validates)")
	# Older legal saves -> v13: everything kept, carrying empty.
	var levels := {"hero": [3, 40], "merc_a": [4, 10], "merc_b": [2, 5]}
	var points := {"hero": _pts(1, 2, 1, 0), "merc_a": _pts(3, 0, 0, 0), "merc_b": _pts(0, 0, 1, 2)}
	var versions := _all_versions(levels, points)
	for version in versions:
		var old: Dictionary = versions[version]
		var loaded := _load(old)
		if loaded.is_empty():
			_check(false, "v%d loads" % version)
			continue
		var lc: CharacterCarrying = loaded["carrying"]
		var lr: MercenaryRoster = loaded["mercenaries"]
		var owned_ids: Array = lr.get_owned().map(func(m: Mercenary) -> String: return m.get_id())
		_check(int((loaded["wallet"] as Wallet).get_balance()) == 4321 and (loaded["inventory"] as CharacterInventory).get_items() == {"test_good_03": 4}, "v%d -> v13: money and Hero goods kept" % version)
		_check((["hero"] + owned_ids).all(func(id: String) -> bool: return lc.get_equipment(id).is_empty() and (id == "hero" or lc.get_inventory(id).is_empty())), "v%d -> v13: equipment empty for the Hero and %s, Mercenary goods empty" % [version, str(owned_ids)])
		var rewritten := _serialize_loaded(loaded)
		_check(int(rewritten["version"]) == 13 and rewritten.keys().size() == 13 and (rewritten["carrying"] as Dictionary).size() == 1 + owned_ids.size(), "v%d -> rewritten as v13" % version)
		if version >= 3:
			_check(rewritten["market"] == old["market"], "v%d -> v13: market kept" % version)
		if version >= 5:
			_check(rewritten["warehouses"] == old["warehouses"], "v%d -> v13: warehouses kept" % version)
		if version >= 7:
			_check(rewritten["cost_ledger"] == old["cost_ledger"], "v%d -> v13: cost ledger kept" % version)
		if version >= 8:
			_check(rewritten["location"] == old["location"], "v%d -> v13: world location kept" % version)
		if version >= 9:
			_check(int((loaded["progression"] as ProgressionState).get_level("hero")) == 3 and int((loaded["progression"] as ProgressionState).get_exp("hero")) == 40, "v%d -> v13: Hero progression kept" % version)
		if version >= 10:
			_check(_ints(loaded["allocation"]["hero"]) == points["hero"], "v%d -> v13: Hero allocation kept" % version)
		if version == 12:
			_check(rewritten["mercenaries"] == old["mercenaries"] and rewritten["pending_legacy_mercenaries"] == old["pending_legacy_mercenaries"] and lr.get_deployed_ids() == ["merc_1"], "v12 -> v13: roster (ids, types, Levels, EXP, allocation), deployment and pending list kept")
			_check(lr.get_pending().map(func(m: Mercenary) -> String: return m.get_id()) == ["merc_b"] and not lc.is_character("merc_b"), "v12 -> v13: pending merc_b still pending, holds nothing")
		if version in [9, 10, 11]:
			var a := lr.get_mercenary("merc_a")
			_check(a != null and a.get_level() == 4 and a.get_exp() == 10 and (version < 10 or a.get_allocation_points() == points["merc_a"]), "v%d -> v13: legacy merc_a migrated with its Level / EXP / allocation (P05) and empty carrying" % version)
		var again := _load(rewritten)
		_check(not again.is_empty() and JSON.stringify(_serialize_loaded(again)) == JSON.stringify(rewritten), "v%d -> v13 -> reload: stable" % version)
	# Future version.
	var future := _with(_serialize(full), {"version": 14})
	_write_text(TEST_SAVE, JSON.stringify(future))
	var inspected := SaveStore.inspect(TEST_SAVE)
	_check(inspected["status"] == SaveStore.STATUS_UNREADABLE and inspected["reason"] == SaveStore.REASON_FUTURE, "A future v14 save is unreadable (future), never loaded")
	# Failed saves leave the existing file intact.
	_clean()
	var saved_ok := _save(full, TEST_SAVE)
	var file_before := FileAccess.get_file_as_string(TEST_SAVE)
	_check(saved_ok and not _save(full, BAD_SAVE), "A save to a missing directory fails")
	(full["carrying"] as CharacterCarrying).add_equipment("merc_1", W2, 1)
	(full["roster"] as MercenaryRoster).set_deployment([])
	(full["roster"] as MercenaryRoster).remove("merc_1")
	_check(not _save(full, TEST_SAVE) and FileAccess.get_file_as_string(TEST_SAVE) == file_before, "A save that would lose a removed Mercenary's items is refused; the old file is untouched")
	_sections_done.append("save")


# --- Real game --------------------------------------------------------------------------------------------

func _verify_game() -> void:
	_clean()
	var main := await _new_main()
	var carrying: CharacterCarrying = main.carrying
	_check(carrying != null and carrying.get_inventory("hero") == main.inventory and carrying.get_stats("hero") == main.character_stats, "main: the Hero's carrying is its backpack and stats")
	(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
	await _settle()
	main.try_enter_city()
	await _settle()
	main.recruit_mercenary("GUARDIAN")
	main.recruit_mercenary("GUARDIAN")
	_check(carrying.add_equipment("hero", W1, 1) and carrying.equip("hero", W1) and carrying.add_equipment("merc_1", A1, 1) and carrying.equip("merc_1", A1) and carrying.add_equipment("merc_2", W2, 2), "Hero / merc_1 / merc_2 given gear (model API)")
	_check(main.inventory.get_max_capacity() == 118 and main.character_stats.get_effective("str") == 12, "main: Hero Capacity 118 with STR gear")
	var entries: Array = main.get_character_entries()
	_check((entries[1]["stats"] as CharacterStats).get_physical_defense() == CharacterStats.for_mercenary(main.mercenary_roster.get_mercenary("merc_1")).get_physical_defense() + 2, "Character entries use the Mercenary's equipped stats")
	var result: Dictionary = main.dismiss_mercenary("merc_2")
	_check(not result["success"] and result["reason"] == "ERR_HAS_ITEMS" and main.mercenary_roster.get_mercenary("merc_2") != null, "main: dismissing merc_2 (carrying gear) refused")
	_check(main._persist(), "Saved")
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(raw["version"]) == 13 and raw["carrying"]["merc_2"]["carried_equipment"] == {W2: 2.0} or raw["carrying"]["merc_2"]["carried_equipment"] == {W2: 2}, "The file is v13 with merc_2's 2 x 測試武器二")
	var state := _state_text(carrying, ["hero", "merc_1", "merc_2"])
	await _destroy(main)
	main = await _new_main()
	var after: CharacterCarrying = main.carrying
	_check(_state_text(after, ["hero", "merc_1", "merc_2"]) == state and main.character_stats.get_effective("str") == 12 and main.inventory.get_max_capacity() == 118 and main.inventory.get_used_capacity() == 3, "Restart: every character's gear back, Hero bonus + Capacity rebuilt")
	_check(after.get_stats("merc_1").get_physical_defense() == 2 and main.progression.get_level("hero") == 1, "Restart: Mercenary bonus rebuilt; progression intact")
	# Emptied, merc_2 can be dismissed (in a city).
	if not main.is_in_city():
		(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
		await _settle()
		main.try_enter_city()
		await _settle()
	_check(after.transfer_equipment("merc_2", "merc_1", W2, 2) and main.dismiss_mercenary("merc_2")["success"] and after.get_equipment("merc_1").get_carried_quantity(W2) == 2, "Emptied (gear given to merc_1), merc_2 is dismissed; the gear stays with merc_1")
	await _destroy(main)
	_clean()
	_sections_done.append("game")


# --- Combat -----------------------------------------------------------------------------------------------

func _verify_combat() -> void:
	var party := _party(["GUARDIAN", "MAGE", "STRATEGIST"])
	var roster: MercenaryRoster = party["roster"]
	roster.set_deployment(["merc_1", "merc_2", "merc_3"])
	var plain := CombatBattle.create_party(10, CharacterStats.new(), roster.get_deployed())
	var with_carrying := CombatBattle.create_party(10, (party["carrying"] as CharacterCarrying).get_stats("hero"), roster.get_deployed())
	var same := true
	for index in range(plain.get_friends().size()):
		var a := plain.get_friends()[index]
		var b := with_carrying.get_friends()[index]
		same = same and a.max_hp == b.max_hp and a.attack_damage == b.attack_damage and a.attack_interval_ms == b.attack_interval_ms and a.magic_attack == b.magic_attack and a.physical_defense == b.physical_defense and a.magic_defense == b.magic_defense and a.max_mp == b.max_mp
	_check(same, "No equipment: every battle unit identical to Stage 8 (Hero + 3)")
	_check(_profile(CharacterStats.new()) == _profile((party["carrying"] as CharacterCarrying).get_stats("hero")), "No equipment: the Hero's combat profile unchanged")
	_sections_done.append("combat")


func _verify_scope() -> void:
	var code := ""
	for path in ["res://scripts/equipment_catalog.gd", "res://scripts/character_equipment.gd", "res://scripts/character_carrying.gd"]:
		code += _code_only(path).to_lower()
	for word in ["affix", "rarity", "durability", "enhance", "socket", "set_bonus", "craft", "price", "shop", "helmet", "gloves", "shoes", "charm", "class_restriction"]:
		_check(not code.contains(word), "No %s in the equipment foundation" % word)
	_check(not _code_only("res://scripts/trade_cost_ledger.gd").to_lower().contains("equipment") and not _code_only("res://scripts/market_state.gd").to_lower().contains("equipment"), "The cost ledger and market know nothing about equipment")
	_check(MercenaryRoster.MAX_OWNED == 5 and MercenaryRoster.MAX_DEPLOYED == 3 and RecruitmentService.PRICE == 1000, "Stage 8 limits and price unchanged")
	_check(CharacterConfig.BASE_CAPACITY == 10 and CharacterConfig.CAPACITY_PER_STR == 9, "Capacity = 10 + Effective STR x 9 unchanged")
	_sections_done.append("scope")


# --- Stress (FULL) ----------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9013
	var drift := 0
	var failed_changed := 0
	var reload_drift := 0
	var bonus_drift := 0
	var capacity_drift := 0
	var operations := 0
	var refused := 0
	var over_seen := 0
	for run in range(60):
		var types := []
		for i in range(rng.randi_range(0, 5)):
			types.append(["GUARDIAN", "MAGE", "STRATEGIST"][rng.randi_range(0, 2)])
		var party := _party(types)
		var carrying: CharacterCarrying = party["carrying"]
		var roster: MercenaryRoster = party["roster"]
		var ids: Array = ["hero"] + roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id())
		var expected := {}
		for item_id in ALL:
			expected[item_id] = 0
		for step in range(150):
			var id: String = ids[rng.randi_range(0, ids.size() - 1)]
			var other: String = ids[rng.randi_range(0, ids.size() - 1)]
			var item_id: String = ALL[rng.randi_range(0, 3)]
			var quantity := rng.randi_range(-1, 4)
			var before := _state_text(carrying, ids)
			var ok := false
			match rng.randi_range(0, 8):
				0, 1:
					ok = carrying.add_equipment(id, item_id, quantity)
					if ok:
						expected[item_id] += quantity
				2:
					ok = carrying.remove_equipment(id, item_id, quantity)
					if ok:
						expected[item_id] -= quantity
				3, 4:
					ok = carrying.equip(id, item_id)
				5:
					ok = carrying.unequip(id, ["WEAPON", "ARMOR", "HELMET"][rng.randi_range(0, 2)])
				6:
					ok = carrying.transfer_equipment(id, other, item_id, quantity)
				7:
					if id == "hero":
						var good: String = GoodsCatalog.get_ids()[rng.randi_range(0, 5)]
						ok = (party["inventory"] as CharacterInventory).add(good, rng.randi_range(1, 8)) if rng.randi_range(0, 1) == 0 else (party["inventory"] as CharacterInventory).remove(good, rng.randi_range(1, 3))
				8:
					ok = carrying.add_equipment("nobody", item_id, 1) or carrying.equip("merc_99", item_id)
			operations += 1
			if not ok:
				refused += 1
				if _state_text(carrying, ids) != before:
					failed_changed += 1
			if _totals(carrying, ids) != expected:
				drift += 1
			for character in ids:
				var stats := carrying.get_stats(character)
				var bonuses := carrying.get_equipment(character).get_bonuses()
				if stats.get_equipment_bonuses() != bonuses:
					bonus_drift += 1
				var load := 0
				for each in ALL:
					load += carrying.get_equipment(character).get_total_quantity(each) * EquipmentCatalog.get_capacity_cost(each)
				load += carrying.get_inventory(character).get_goods_load()
				if carrying.get_load(character) != load or carrying.get_capacity(character) != 10 + stats.get_effective("str") * 9:
					capacity_drift += 1
				if carrying.is_over_capacity(character):
					over_seen += 1
			if step % 25 == 24:
				var reloaded := _load(_serialize(party))
				if reloaded.is_empty() or _state_text(reloaded["carrying"], ids) != _state_text(carrying, ids) or JSON.stringify(_serialize_loaded(reloaded)) != JSON.stringify(_serialize(party)):
					reload_drift += 1
				else:
					# Continue on the reloaded objects (save / reload in the loop).
					party = {"carrying": reloaded["carrying"], "roster": reloaded["mercenaries"], "inventory": reloaded["inventory"], "stats": reloaded["character_stats"], "wallet": reloaded["wallet"]}
					carrying = party["carrying"]
					roster = party["roster"]
	_check(operations == 9000 and refused > 1000 and over_seen > 0, "Stress: %d operations, %d refused, over capacity seen %d times" % [operations, refused, over_seen])
	_check(drift == 0, "Stress: no duplication or loss (item totals always match) (%d)" % drift)
	_check(failed_changed == 0, "Stress: every refused operation changed nothing (%d)" % failed_changed)
	_check(bonus_drift == 0, "Stress: stats bonuses always equal the equipped items (%d)" % bonus_drift)
	_check(capacity_drift == 0, "Stress: load and Capacity always exact (%d)" % capacity_drift)
	_check(reload_drift == 0, "Stress: every save / reload identical (%d)" % reload_drift)
	# Migration stress: random legacy fixtures of every version.
	var migrate_bad := 0
	for run in range(40):
		var levels := {"hero": [rng.randi_range(1, 5), 0], "merc_a": [rng.randi_range(1, 5), 0], "merc_b": [rng.randi_range(1, 5), 0]}
		var points := {"hero": _pts(0, 0, 0, 0), "merc_a": _pts(0, 0, 0, 0), "merc_b": _pts(0, 0, 0, 0)}
		var versions := _all_versions(levels, points)
		for version in versions:
			var loaded := _load(versions[version])
			if loaded.is_empty():
				migrate_bad += 1
				continue
			var rewritten := _serialize_loaded(loaded)
			var again := _load(rewritten)
			if again.is_empty() or JSON.stringify(_serialize_loaded(again)) != JSON.stringify(rewritten) or int(rewritten["version"]) != 13:
				migrate_bad += 1
	_check(migrate_bad == 0, "Stress: 40 x 12 legacy versions -> v13 -> reload, all stable (%d)" % migrate_bad)
	# Real main: repeated restart cycles with gear.
	_clean()
	var main := await _new_main()
	(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
	await _settle()
	main.try_enter_city()
	await _settle()
	main.recruit_mercenary("MAGE")
	main.recruit_mercenary("MAGE")
	var game_bad := 0
	for cycle in range(8):
		var c: CharacterCarrying = main.carrying
		c.add_equipment("merc_%d" % (cycle % 2 + 1), ALL[cycle % 4], 1)
		c.equip("merc_%d" % (cycle % 2 + 1), ALL[cycle % 4])
		c.add_equipment("hero", ALL[(cycle + 1) % 4], 1)
		c.equip("hero", ALL[(cycle + 1) % 4])
		main._persist()
		var state := _state_text(c, ["hero", "merc_1", "merc_2"])
		var hero_profile := _profile(main.character_stats)
		await _destroy(main)
		main = await _new_main()
		if _state_text(main.carrying, ["hero", "merc_1", "merc_2"]) != state or _profile(main.character_stats) != hero_profile:
			game_bad += 1
		if not main.is_in_city():
			(main.get_node("Actors/Player") as Player).global_position = WorldLayout.CITY_A
			await _settle()
			main.try_enter_city()
			await _settle()
	_check(game_bad == 0, "Stress: 8 real game save / restart cycles, gear and Hero stats identical (%d)" % game_bad)
	await _destroy(main)
	_clean()
	_sections_done.append("stress")


# --- Helpers ----------------------------------------------------------------------------------------------

## A fresh party: the Hero backpack + stats, a roster of `types` (merc_1..),
## and their CharacterCarrying.
func _party(types: Array) -> Dictionary:
	var stats := CharacterStats.new()
	var inventory := CharacterInventory.new("player", stats)
	var roster := MercenaryRoster.new()
	for type in types:
		roster.create_mercenary(type)
	var carrying := CharacterCarrying.new(inventory, func() -> MercenaryRoster: return roster)
	var wallet := Wallet.new()
	wallet.spend(wallet.get_balance() - 4321)
	return {"carrying": carrying, "roster": roster, "inventory": inventory, "stats": stats, "wallet": wallet}


func _serialize(party: Dictionary) -> Dictionary:
	return _json(SaveStore.serialize(party["wallet"], party["inventory"], MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.new(), {"hero": party["stats"]}, party["roster"], party["carrying"]))


func _save(party: Dictionary, path: String) -> bool:
	return SaveStore.save(path, party["wallet"], party["inventory"], MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.new(), {"hero": party["stats"]}, party["roster"], party["carrying"])


func _load(data: Dictionary) -> Dictionary:
	var payload := SaveStore.validate(_json(data))
	return {} if payload.is_empty() else SaveStore._rebuild(payload)


## The save the game would write after loading `loaded`.
func _serialize_loaded(loaded: Dictionary) -> Dictionary:
	var stats: CharacterStats = loaded["character_stats"]
	stats.apply_level((loaded["progression"] as ProgressionState).get_level("hero"))
	stats.restore_allocation(loaded["allocation"]["hero"])
	return _json(SaveStore.serialize(loaded["wallet"], loaded["inventory"], loaded["market"], loaded["location"], loaded["warehouses"], loaded["market_recovery"], loaded["cost_ledger"], loaded["progression"], {"hero": stats}, loaded["mercenaries"], loaded["carrying"]))


## Fixtures of every version 1..12 (the legacy three slots at `levels` /
## `points`; a v12 roster with merc_1 deployed and merc_b pending).
func _all_versions(levels: Dictionary, points: Dictionary) -> Dictionary:
	var hero := CharacterStats.new()
	hero.apply_level(levels["hero"][0])
	hero.restore_allocation(points["hero"])
	var inventory := CharacterInventory.new("player", hero)
	inventory.add("test_good_03", 4)
	var wallet := Wallet.new()
	wallet.spend(wallet.get_balance() - 4321)
	var roster := MercenaryRoster.build([Mercenary.create("merc_1", "MAGE", 2, 10, _pts(1, 0, 0, 2))], ["merc_1"])
	roster.pend_legacy(Mercenary.create("merc_b", "MAGE", 2, 5, _pts(0, 0, 3, 0)))
	var warehouses := WarehouseState.create_default()
	var current: Dictionary = _json(SaveStore.serialize(wallet, inventory, MarketState.create_default(), PlayerLocation.new(), warehouses, null, null, ProgressionState.from_hero(levels["hero"][0], levels["hero"][1]), {"hero": hero}, roster))
	var v12: Dictionary = current.duplicate(true)
	v12.erase("carrying")
	v12["version"] = 12
	var v11: Dictionary = v12.duplicate(true)
	v11.erase("pending_legacy_mercenaries")
	v11["mercenaries"] = _json(MercenaryRoster.new().to_dict())
	v11["version"] = 11
	var progression := {}
	for slot in ProgressionState.LEGACY_SLOTS:
		progression[slot] = {"level": levels[slot][0], "exp": levels[slot][1]}
	v11["progression"] = progression
	v11["allocation"] = _json(points)
	var v10: Dictionary = v11.duplicate(true)
	v10.erase("mercenaries")
	v10["version"] = 10
	var v9: Dictionary = v10.duplicate(true)
	v9.erase("allocation")
	v9["version"] = 9
	var v8: Dictionary = v9.duplicate(true)
	v8.erase("progression")
	v8["version"] = 8
	var v7: Dictionary = v8.duplicate(true)
	(v7["location"] as Dictionary).erase("world_position")
	v7["version"] = 7
	var v6: Dictionary = v7.duplicate(true)
	v6.erase("cost_ledger")
	v6["version"] = 6
	var v5: Dictionary = v6.duplicate(true)
	v5.erase("market_recovery")
	v5["version"] = 5
	var v4: Dictionary = v5.duplicate(true)
	v4.erase("warehouses")
	v4["version"] = 4
	var v3: Dictionary = v4.duplicate(true)
	v3.erase("location")
	v3["version"] = 3
	var v2 := {"version": 2, "money": 4321, "cargo": {"test_good_03": 4}, "market": v12["market"]}
	var v1 := {"version": 1, "money": 4321, "cargo": {"test_good_03": 4}}
	return {1: v1, 2: v2, 3: v3, 4: v4, 5: v5, 6: v6, 7: v7, 8: v8, 9: v9, 10: v10, 11: v11, 12: v12}


## Every character's equipment + goods as text (for equality).
func _state_text(carrying: CharacterCarrying, ids: Array) -> String:
	var parts := []
	for id in ids:
		var equipment := carrying.get_equipment(id)
		var inventory := carrying.get_inventory(id)
		parts.append([id, equipment.get_equipped_items() if equipment != null else null, equipment.get_carried() if equipment != null else null, inventory.get_items() if inventory != null else null])
	return JSON.stringify(parts)


## {item id: total held by `ids` (carried + equipped)}.
func _totals(carrying: CharacterCarrying, ids: Array) -> Dictionary:
	var totals := {}
	for item_id in ALL:
		totals[item_id] = 0
		for id in ids:
			totals[item_id] += carrying.get_equipment(id).get_total_quantity(item_id)
	return totals


func _profile(stats: CharacterStats) -> Dictionary:
	var profile := stats.get_combat_profile()
	profile["max_mp"] = stats.get_max_mp()
	profile["capacity"] = stats.get_max_capacity()
	for stat in CharacterConfig.STATS:
		profile[stat] = stats.get_effective(stat)
	return profile


func _pts(hp: int, strength: int, agi: int, intelligence: int) -> Dictionary:
	return {"hp": hp, "str": strength, "agi": agi, "int": intelligence}


func _ints(points: Dictionary) -> Dictionary:
	var result := {}
	for key in points:
		result[key] = int(points[key])
	return result


func _with(data: Dictionary, changes: Dictionary) -> Dictionary:
	var copy := data.duplicate(true)
	for key in changes:
		copy[key] = changes[key]
	return copy


func _without(data: Dictionary, key: String) -> Dictionary:
	var copy := data.duplicate(true)
	copy.erase(key)
	return copy


func _json(data: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(data))


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _clean() -> void:
	for p in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	for n in range(1, 6):
		var backup := TEST_SAVE + SaveStore.BACKUP_SUFFIX + str(n)
		if FileAccess.file_exists(backup):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(backup))


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
