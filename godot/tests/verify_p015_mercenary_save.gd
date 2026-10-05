extends SceneTree

## Stage 8 P01.5: Mercenary roster persistence (Save v11).
##   A migration    v1-v10 -> v11 with an empty roster; the fixed Stage 7
##                  merc_a / merc_b progression and allocation untouched
##   B round trip   0 / 1 / 5 owned, same / mixed types, independent Level /
##                  EXP / allocation, 0 / 1 / 3 deployed, the id high-water mark
##   C ids          a removed id is never issued again after a restart
##   D invalid      every malformed roster rejects the whole save (no repair)
##   E game         main saves and restores its roster; a refused save is never
##                  reported as saved; P02-style rollback via to_dict/from_dict
##   + stress       seeded create / remove / allocate / save / reload cycles,
##                  repeated migrations
## Real SaveStore files, the real main scene with a fixed TimeSource.

const TEST_SAVE := "user://p015_mercenary_save_test.json"
const T0 := 1800000000000
const SLOTS := ["hero", "merc_a", "merc_b"]
const TYPES := ["GUARDIAN", "MAGE", "STRATEGIST"]

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_schema()
	_verify_migration()
	_verify_round_trip()
	_verify_ids()
	_verify_invalid()
	await _verify_game()
	_verify_rollback()
	_verify_serial_boundary()
	_verify_stress()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 9, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("P01.5 mercenary save verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Schema ------------------------------------------------------------------------------------

func _verify_schema() -> void:
	_check(SaveStore.VERSION == 13 and SaveStore.INVENTORY_VERSIONS == [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13], "AC01 Save v11 (from v10; Stage 9 P01: v13 is current)")
	_check(SaveStore.V11_KEYS == SaveStore.V10_KEYS + ["mercenaries"] and SaveStore.V10_KEYS.size() == 10, "v11 = v10 + mercenaries only")
	var data := _v11(MercenaryRoster.new())
	_check(int(data["version"]) == 11 and data["mercenaries"].keys().size() == 3 and data["mercenaries"]["owned"] == [] and data["mercenaries"]["deployed"] == [] and int(data["mercenaries"]["next_serial"]) == 1, "An empty roster: {owned: [], deployed: [], next_serial: 1}")
	var roster := _sample_roster()
	var saved: Dictionary = _v11(roster)["mercenaries"]
	_check(saved.keys().size() == 3 and (saved["owned"] as Array).size() == 4, "Only owned / deployed / next_serial are saved")
	for entry in saved["owned"]:
		_check((entry as Dictionary).keys().size() == 5 and entry.has_all(["id", "type", "level", "exp", "allocation"]) and (entry["allocation"] as Dictionary).keys().size() == 4, "An instance saves id, type, Level, EXP and the four counts only (no derived stats)")
	_sections_done.append("schema")


# --- A. Migration ------------------------------------------------------------------------------

func _verify_migration() -> void:
	var levels := {"hero": 4, "merc_a": 3, "merc_b": 2}
	var points := {"hero": {"str": 2, "agi": 1}, "merc_a": {"hp": 4}, "merc_b": {"int": 3}}
	var v11 := _v11(MercenaryRoster.new(), levels, points)
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
	var v2 := {"version": 2, "money": 4321, "cargo": {"test_good_03": 4}, "market": v11["market"]}
	var v1 := {"version": 1, "money": 4321, "cargo": {"test_good_03": 4}}
	var old := {"v10": v10, "v9": v9, "v8": v8, "v7": v7, "v6": v6, "v5": v5, "v4": v4, "v3": v3, "v2": v2, "v1": v1}
	for name in old:
		var loaded := _load(old[name])
		_check(not loaded.is_empty(), "AC02 %s loads" % name)
		if loaded.is_empty():
			continue
		var roster: MercenaryRoster = loaded["mercenaries"]
		# Stage 8 P05 (approved Q3) supersedes "an empty roster": every v1-v10
		# save now brings exactly the migrated merc_a / merc_b (waiting).
		_check(roster != null and roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id()) == ["merc_a", "merc_b"] and roster.get_deployed_ids().is_empty() and roster.get_next_serial() == 1, "AC03 %s: the roster holds only merc_a / merc_b (P05), next_serial 1" % name)
		_check(roster.create_mercenary("MAGE").get_id() == "merc_1", "AC03 %s: the first new instance is merc_1" % name)
		_check(loaded["wallet"].get_balance() == 4321 and loaded["inventory"].get_quantity("test_good_03") == 4, "%s: money and items preserved" % name)
	# AC04: the fixed merc_a / merc_b data survive exactly (P05: on their roster
	# instances; the Hero keeps his slot).
	var from_v10 := _load(v10)
	var progression: ProgressionState = from_v10["progression"]
	var migrated: MercenaryRoster = from_v10["mercenaries"]
	_check(migrated.get_mercenary("merc_a").get_level() == 3 and migrated.get_mercenary("merc_b").get_level() == 2 and progression.get_level("hero") == 4, "AC04 Fixed merc_a / merc_b / Hero Levels preserved")
	_check(migrated.get_mercenary("merc_a").get_allocation_points() == {"hp": 4, "str": 0, "agi": 0, "int": 0} and migrated.get_mercenary("merc_b").get_allocation_points() == {"hp": 0, "str": 0, "agi": 0, "int": 3} and from_v10["allocation"]["hero"] == {"hp": 0, "str": 2, "agi": 1, "int": 0}, "AC04 Fixed merc_a / merc_b / Hero allocations preserved")
	# The v10 -> v12 rewrite keeps every other section byte for byte.
	var rewritten := _rewrite(from_v10)
	var expected := v10.duplicate(true)
	expected["version"] = 12
	expected["progression"] = {"hero": v10["progression"]["hero"]}
	expected["allocation"] = {"hero": v10["allocation"]["hero"]}
	expected["mercenaries"] = {"owned": [{"id": "merc_a", "type": "GUARDIAN", "level": 3, "exp": 0, "allocation": {"hp": 4, "str": 0, "agi": 0, "int": 0}}, {"id": "merc_b", "type": "MAGE", "level": 2, "exp": 0, "allocation": {"hp": 0, "str": 0, "agi": 0, "int": 3}}], "deployed": [], "next_serial": 1}
	expected["pending_legacy_mercenaries"] = []
	# Stage 9 P01 (v13): empty carrying for the Hero and both migrated ones.
	expected["version"] = 13
	var empty := {"equipped": {"weapon": null, "armor": null}, "carried_equipment": {}}
	expected["carrying"] = {"hero": empty, "merc_a": {"equipped": {"weapon": null, "armor": null}, "carried_equipment": {}, "goods": {}}, "merc_b": {"equipped": {"weapon": null, "armor": null}, "carried_equipment": {}, "goods": {}}}
	expected = _json(expected)
	_check(JSON.stringify(rewritten, "", true) == JSON.stringify(expected, "", true), "AC04 v10 rewritten as v13: every other v10 section unchanged, merc_a / merc_b in the roster (P05), empty carrying (Stage 9 P01)")
	_check(JSON.stringify(rewritten["mercenaries"]).count("merc_a") == 1 and JSON.stringify(rewritten["mercenaries"]).count("merc_b") == 1, "AC04 merc_a / merc_b are converted into the roster exactly once (P05 Q3)")
	_sections_done.append("migration")


# --- B. Round trip -------------------------------------------------------------------------------

func _verify_round_trip() -> void:
	var cases := {
		"0 owned": MercenaryRoster.new(),
		"1 owned": _roster_of(["MAGE"], []),
		"5 owned, mixed, 3 deployed": _roster_of(["GUARDIAN", "MAGE", "STRATEGIST", "MAGE", "GUARDIAN"], [4, 0, 2]),
		"5 same type, 3 deployed": _roster_of(["MAGE", "MAGE", "MAGE", "MAGE", "MAGE"], [0, 1, 2]),
		"duplicate types, 1 deployed": _roster_of(["STRATEGIST", "STRATEGIST"], [1]),
		"sample (progression, holes in ids)": _sample_roster(),
	}
	for name in cases:
		var roster: MercenaryRoster = cases[name]
		var loaded := _file_round_trip(roster)
		_check(loaded != null, "AC19 %s: saved and loaded" % name)
		if loaded == null:
			continue
		_check(loaded.to_dict() == _json(roster.to_dict()) or JSON.stringify(loaded.to_dict()) == JSON.stringify(roster.to_dict()), "AC05-AC10 %s: identical roster after load" % name)
		_check(loaded.get_owned_count() == roster.get_owned_count() and loaded.get_deployed_ids() == roster.get_deployed_ids() and loaded.get_next_serial() == roster.get_next_serial(), "%s: count, deployment, next_serial" % name)
		for mercenary in roster.get_owned():
			var back := loaded.get_mercenary(mercenary.get_id())
			_check(back != null and back.get_type() == mercenary.get_type() and back.get_level() == mercenary.get_level() and back.get_exp() == mercenary.get_exp() and back.get_allocation_points() == mercenary.get_allocation_points(), "%s: %s keeps type, Level, EXP, allocation" % [name, mercenary.get_id()])
			_check(back.get_earned_points() == mercenary.get_earned_points() and back.get_unspent_points() == mercenary.get_unspent_points(), "%s: %s recomputes the same earned / unspent points" % [name, mercenary.get_id()])
		_check(loaded.get_owned().map(func(m: Mercenary) -> String: return m.get_id()) == roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id()), "%s: owned order kept" % name)
	# Independent progression of same-type instances survives.
	var sample := _file_round_trip(_sample_roster())
	_check(sample.get_mercenary("merc_1").to_dict() == {"id": "merc_1", "type": "MAGE", "level": 5, "exp": 40, "allocation": {"hp": 4, "str": 0, "agi": 4, "int": 4}}, "Same-type merc_1: Lv5, 40 EXP, its own points")
	_check(sample.get_mercenary("merc_3").to_dict() == {"id": "merc_3", "type": "MAGE", "level": 2, "exp": 149, "allocation": {"hp": 0, "str": 0, "agi": 0, "int": 0}}, "Same-type merc_3: Lv2, 149 EXP, nothing spent")
	_check(sample.get_deployed_ids() == ["merc_3", "merc_1"] and sample.get_next_serial() == 6, "Deployment order and the high-water mark (6)")
	_sections_done.append("round_trip")


# --- C. Persistent ids -----------------------------------------------------------------------------

func _verify_ids() -> void:
	var roster := MercenaryRoster.new()
	var one := roster.create_mercenary("GUARDIAN")
	var two := roster.create_mercenary("MAGE")
	_check(one.get_id() == "merc_1" and two.get_id() == "merc_2" and roster.remove("merc_2"), "merc_1, merc_2 created; merc_2 removed")
	var loaded := _file_round_trip(roster)
	var fresh := loaded.create_mercenary("MAGE")
	_check(fresh.get_id() != "merc_2" and fresh.get_id() == "merc_3", "AC11 After save / load the next id is merc_3, never merc_2 (%s)" % fresh.get_id())
	_check(not loaded.add(Mercenary.create("merc_1", "MAGE")), "The owned merc_1 is still refused as a duplicate")
	# Codex review: a removed issued id is refused after a reload as before it
	# (every merc_<n> below next_serial is retired).
	var retired := MercenaryRoster.new()
	retired.create_mercenary("MAGE")
	retired.remove("merc_1")
	_check(not retired.add(Mercenary.create("merc_1", "MAGE")), "Same session: the removed merc_1 is refused")
	var retired_back := _file_round_trip(retired)
	_check(not retired_back.add(Mercenary.create("merc_1", "MAGE")) and retired_back.get_owned_count() == 0 and retired_back.get_next_serial() == 2, "After save / load: merc_1 is still refused, nothing changes")
	var snapshot := MercenaryRoster.from_dict(retired.to_dict())
	_check(not snapshot.add(Mercenary.create("merc_1", "GUARDIAN")) and snapshot.create_mercenary("MAGE").get_id() == "merc_2", "from_dict(to_dict()) behaves as the original (merc_1 refused, next is merc_2)")
	var below := MercenaryRoster.from_dict(_json({"owned": [], "deployed": [], "next_serial": 10}))
	var refused := true
	for n in range(1, 10):
		refused = refused and not below.add(Mercenary.create("merc_%d" % n, "MAGE"))
	_check(refused and below.get_owned_count() == 0 and below.add(Mercenary.create("merc_10", "MAGE")) and below.add(Mercenary.create("merc_a", "MAGE")), "Every merc_1..merc_9 below next_serial 10 is refused; merc_10 and non-issued ids are accepted")
	# Owned ids below the mark (any order) still load.
	var unordered := MercenaryRoster.from_dict(_json({"owned": [_m("merc_4", "MAGE"), _m("merc_1", "GUARDIAN"), _m("merc_3", "MAGE")], "deployed": ["merc_1", "merc_4"], "next_serial": 7}))
	_check(unordered != null and unordered.get_owned().map(func(m: Mercenary) -> String: return m.get_id()) == ["merc_4", "merc_1", "merc_3"] and unordered.get_deployed_ids() == ["merc_1", "merc_4"] and unordered.get_next_serial() == 7, "Owned merc_4, merc_1, merc_3 below next_serial 7 load in their order")
	_check(not unordered.add(Mercenary.create("merc_2", "MAGE")) and not unordered.add(Mercenary.create("merc_6", "MAGE")) and unordered.create_mercenary("MAGE").get_id() == "merc_7", "Retired merc_2 / merc_6 refused; the issuer continues at merc_7")
	# Removing everything still keeps the mark.
	var empty := MercenaryRoster.new()
	for index in range(5):
		empty.create_mercenary(TYPES[index % 3])
	for index in range(5):
		empty.remove("merc_%d" % (index + 1))
	var reloaded := _file_round_trip(empty)
	_check(reloaded.get_owned_count() == 0 and reloaded.get_next_serial() == 6 and reloaded.create_mercenary("MAGE").get_id() == "merc_6", "AC11 An emptied roster keeps next_serial 6 across a restart")
	# A longer create / remove / restart sequence: no id is ever issued twice.
	var issued := {}
	var current := MercenaryRoster.new()
	var duplicate_issue := false
	for round in range(40):
		var created := current.create_mercenary(TYPES[round % 3])
		if created != null:
			duplicate_issue = duplicate_issue or issued.has(created.get_id())
			issued[created.get_id()] = true
		if round % 2 == 1 and current.get_owned_count() > 0:
			current.remove(current.get_owned()[round % current.get_owned_count()].get_id())
		if round % 4 == 3:
			current = _file_round_trip(current)
	_check(not duplicate_issue and issued.size() >= 20, "40 rounds with restarts: %d ids issued, none twice" % issued.size())
	_sections_done.append("ids")


# --- D. Invalid saves ------------------------------------------------------------------------------

func _verify_invalid() -> void:
	var good := _v11(_sample_roster())
	_check(not SaveStore.validate(good).is_empty(), "The sample v11 save is valid")
	var cases := {
		"AC12 6 owned": _roster_data(_mercs(6), [], 7),
		"AC13 4 deployed": _roster_data(_mercs(5), ["merc_1", "merc_2", "merc_3", "merc_4"], 6),
		"AC14 duplicate owned id": _roster_data([_m("merc_1", "MAGE"), _m("merc_1", "GUARDIAN")], [], 2),
		"AC14 duplicate deployed id": _roster_data(_mercs(3), ["merc_1", "merc_1"], 4),
		"AC15 unknown deployed id": _roster_data(_mercs(2), ["merc_1", "merc_9"], 3),
		"AC15 deployed Hero": _roster_data(_mercs(2), ["hero"], 3),
		"deployed not a string": _roster_data(_mercs(2), [1], 3),
		"AC16 invalid type": _roster_data([_m("merc_1", "WARRIOR")], [], 2),
		"AC16 lowercase type": _roster_data([_m("merc_1", "mage")], [], 2),
		"invalid id syntax": _roster_data([_m("Merc 1", "MAGE")], [], 2),
		"Hero id": _roster_data([_m("hero", "MAGE")], [], 2),
		"empty id": _roster_data([_m("", "MAGE")], [], 2),
		"AC17 Level 0": _roster_data([_m("merc_1", "MAGE", 0)], [], 2),
		"AC17 Level 101": _roster_data([_m("merc_1", "MAGE", 101)], [], 2),
		"AC17 Level 2.5": _roster_data([_m("merc_1", "MAGE", 2.5)], [], 2),
		"AC17 EXP at the requirement": _roster_data([_m("merc_1", "MAGE", 2, 150)], [], 2),
		"AC17 EXP negative": _roster_data([_m("merc_1", "MAGE", 2, -1)], [], 2),
		"AC17 EXP at Lv100": _roster_data([_m("merc_1", "MAGE", 100, 1)], [], 2),
		"AC17 negative allocation": _roster_data([_m("merc_1", "MAGE", 3, 0, {"hp": -1, "str": 0, "agi": 0, "int": 0})], [], 2),
		"AC17 allocation > earned": _roster_data([_m("merc_1", "MAGE", 3, 0, {"hp": 4, "str": 3, "agi": 0, "int": 0})], [], 2),
		"AC17 huge allocation": _roster_data([_m("merc_1", "MAGE", 3, 0, {"hp": 9007199254740992, "str": 0, "agi": 0, "int": 0})], [], 2),
		"AC17 allocation with MP": _roster_data([_m("merc_1", "MAGE", 3, 0, {"hp": 0, "str": 0, "agi": 0, "int": 0, "mp": 0})], [], 2),
		"AC17 allocation missing a stat": _roster_data([_m("merc_1", "MAGE", 3, 0, {"hp": 0, "str": 0, "agi": 0})], [], 2),
		"AC17 allocation text": _roster_data([_m("merc_1", "MAGE", 3, 0, {"hp": "1", "str": 0, "agi": 0, "int": 0})], [], 2),
		"AC18 next_serial 0": _roster_data([], [], 0),
		"AC18 next_serial negative": _roster_data([], [], -3),
		"AC18 next_serial fraction": _roster_data([], [], 2.5),
		"AC18 next_serial text": _roster_data([], [], "2"),
		"AC18 next_serial null": _roster_data([], [], null),
		"AC18 next_serial above 2^53": _roster_data([], [], 18014398509481984),
		"AC18 next_serial 1e18": _roster_data([], [], 1000000000000000000),
		"AC18 collision: owned merc_5, next_serial 5": _roster_data([_m("merc_5", "MAGE")], [], 5),
		"AC18 collision: owned merc_9, next_serial 2": _roster_data([_m("merc_1", "MAGE"), _m("merc_9", "MAGE")], [], 2),
		"malformed: mercenaries null": null,
		"malformed: mercenaries array": [],
		"malformed: missing next_serial": {"owned": [], "deployed": []},
		"malformed: extra key": {"owned": [], "deployed": [], "next_serial": 1, "used_ids": []},
		"malformed: owned not an array": {"owned": {}, "deployed": [], "next_serial": 1},
		"malformed: deployed not an array": {"owned": [], "deployed": "merc_1", "next_serial": 1},
		"malformed: owned entry not a dictionary": {"owned": ["merc_1"], "deployed": [], "next_serial": 2},
		"malformed: instance extra key": {"owned": [{"id": "merc_1", "type": "MAGE", "level": 1, "exp": 0, "allocation": CharacterStats.zero_allocation(), "name": "x"}], "deployed": [], "next_serial": 2},
		"malformed: instance missing type": {"owned": [{"id": "merc_1", "level": 1, "exp": 0, "allocation": CharacterStats.zero_allocation()}], "deployed": [], "next_serial": 2},
	}
	for name in cases:
		var data := good.duplicate(true)
		data["mercenaries"] = cases[name]
		_check(SaveStore.validate(_json(data)).is_empty(), "%s: the whole save is rejected" % name)
	# Direct (non-JSON) data, e.g. an in-memory snapshot: int bounds as well.
	_check(MercenaryRoster.from_dict({"owned": [], "deployed": [], "next_serial": MercenaryRoster.MAX_SERIAL + 1}) == null and MercenaryRoster.from_dict({"owned": [], "deployed": [], "next_serial": MercenaryRoster.MAX_SERIAL}) != null and MercenaryRoster.from_dict({"owned": [], "deployed": [], "next_serial": 0}) == null, "AC18 next_serial as an int: 1..2^53 only")
	var missing := good.duplicate(true)
	missing.erase("mercenaries")
	_check(SaveStore.validate(missing).is_empty(), "A v11 save without mercenaries is rejected")
	var extra := good.duplicate(true)
	extra["version"] = 10
	_check(SaveStore.validate(extra).is_empty(), "A v10 save carrying mercenaries is rejected (unknown key)")
	_check(SaveStore.validate(_with(good, {"version": 14})).is_empty(), "An unknown future v14 is rejected (Stage 9 P01: v13 is current)")
	# Edge values that stay valid.
	var edges := {
		"owned merc_5 under next_serial 6": _roster_data([_m("merc_5", "MAGE")], [], 6),
		"an external id (merc_a) any serial": _roster_data([_m("merc_a", "GUARDIAN")], [], 1),
		"non-issued form merc_05 at serial 1": _roster_data([_m("merc_05", "MAGE")], [], 1),
		"next_serial MAX": _roster_data([], [], MercenaryRoster.MAX_SERIAL),
		"Lv100 with all 297 points": _roster_data([_m("merc_1", "STRATEGIST", 100, 0, {"hp": 297, "str": 0, "agi": 0, "int": 0})], ["merc_1"], 2),
	}
	for name in edges:
		var data := good.duplicate(true)
		data["mercenaries"] = edges[name]
		_check(not SaveStore.validate(_json(data)).is_empty(), "Valid edge: %s" % name)
	# An issued-form id added from outside keeps the roster saveable.
	var external := MercenaryRoster.new()
	_check(external.add(Mercenary.create("merc_7", "MAGE")) and external.get_next_serial() == 8 and _file_round_trip(external) != null and external.create_mercenary("MAGE").get_id() == "merc_8", "add(merc_7) moves next_serial to 8: still saveable, the issuer continues at merc_8")
	_check(external.add(Mercenary.create("merc_a", "GUARDIAN")) and external.get_next_serial() == 9, "A non-issued-form id (merc_a) leaves next_serial alone")
	# A rejected file is left untouched (the existing policy: start fresh).
	var bad := good.duplicate(true)
	bad["mercenaries"] = _roster_data(_mercs(6), [], 7)
	var text := JSON.stringify(bad)
	_write(TEST_SAVE, text)
	_check(SaveStore.load_session(TEST_SAVE).is_empty() and FileAccess.get_file_as_string(TEST_SAVE) == text, "AC22 An invalid roster file loads as nothing and is not rewritten")
	_delete(TEST_SAVE)
	_sections_done.append("invalid")


# --- E. In game ----------------------------------------------------------------------------------

func _verify_game() -> void:
	# A v10 file in the real game: fixed mercs kept (P05: as roster merc_a / merc_b).
	var v10 := _v11(MercenaryRoster.new(), {"hero": 3, "merc_a": 2, "merc_b": 4}, {"merc_a": {"str": 3}, "merc_b": {"hp": 2, "int": 7}})
	v10.erase("mercenaries")
	v10["version"] = 10
	_write(TEST_SAVE, JSON.stringify(v10))
	var main := await _new_main()
	_check(main.mercenary_roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id()) == ["merc_a", "merc_b"] and main.mercenary_roster.get_next_serial() == 1, "AC03 The game loads a v10 save with only merc_a / merc_b in the roster (P05)")
	var legacy_a: Mercenary = main.mercenary_roster.get_mercenary("merc_a")
	var legacy_b: Mercenary = main.mercenary_roster.get_mercenary("merc_b")
	_check(legacy_a.get_level() == 2 and legacy_b.get_level() == 4 and legacy_a.get_allocation_points() == {"hp": 0, "str": 3, "agi": 0, "int": 0} and legacy_b.get_allocation_points() == {"hp": 2, "str": 0, "agi": 0, "int": 7}, "AC04/AC20 Fixed merc_a / merc_b progression and allocation applied as before (P05: on the instances)")
	_check(FileAccess.get_file_as_string(TEST_SAVE) == JSON.stringify(v10), "Loading does not rewrite the v10 file")
	# The game's roster is saved and restored.
	var roster: MercenaryRoster = main.mercenary_roster
	for type in ["MAGE", "MAGE", "GUARDIAN"]:
		roster.create_mercenary(type)
	roster.get_mercenary("merc_2").add_exp(400)
	roster.get_mercenary("merc_2").allocate({"agi": 2, "int": 1})
	roster.remove("merc_1")
	roster.set_deployment(["merc_3", "merc_2"])
	var before := roster.to_dict()
	_check(main.save_world_position(), "The game saves")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(saved["version"]) == 13 and (saved["mercenaries"]["owned"] as Array).size() == 4 and int(saved["mercenaries"]["next_serial"]) == 4, "Written as v12 with the roster (P05: merc_a, merc_b, merc_2, merc_3)")
	_check(saved["mercenaries"]["owned"][0]["level"] == 2.0 and saved["mercenaries"]["owned"][1]["allocation"]["int"] == 7.0 and saved["progression"].keys() == ["hero"], "The fixed mercs' data are written (P05: as roster instances)")
	await _destroy(main)
	main = await _new_main()
	_check(JSON.stringify(main.mercenary_roster.to_dict()) == JSON.stringify(before), "AC19 Restart: the roster is restored exactly")
	_check(main.mercenary_roster.create_mercenary("STRATEGIST").get_id() == "merc_4", "AC11 Restart: the next id is merc_4 (merc_1 was removed, never reused)")
	# AC23: a roster that cannot be written is refused, not reported saved.
	var text := FileAccess.get_file_as_string(TEST_SAVE)
	main.mercenary_roster._next_serial = 0
	_check(not main.save_world_position() and FileAccess.get_file_as_string(TEST_SAVE) == text, "AC23 An invalid roster refuses the save (false) and the file stays as it was")
	_check(not SaveStore.save(TEST_SAVE, main.wallet, main.inventory, main.market, main.location, main.warehouses, main.market_recovery, main.cost_ledger, main.progression, main.get_party_stats(), main.mercenary_roster), "AC23 SaveStore.save returns false for it")
	main.mercenary_roster._next_serial = 5
	_check(main.save_world_position(), "A valid roster saves again")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("game")


# --- Rollback support for P02 ----------------------------------------------------------------------

## P02 can roll back a roster change (e.g. a failed save) by restoring a
## snapshot: MercenaryRoster.from_dict(to_dict()) gives the exact earlier state.
func _verify_rollback() -> void:
	var roster := _sample_roster()
	var snapshot := roster.to_dict()
	var added := roster.create_mercenary("MAGE")
	_check(added != null and roster.get_owned_count() == 5, "A change after the snapshot")
	var restored := MercenaryRoster.from_dict(snapshot)
	_check(restored != null and JSON.stringify(restored.to_dict()) == JSON.stringify(snapshot) and restored.get_owned_count() == 4 and restored.get_mercenary(added.get_id()) == null, "from_dict(snapshot) restores the exact earlier roster")
	restored.get_mercenary("merc_1").add_exp(1000)
	_check(roster.get_mercenary("merc_1").get_level() == 5, "The restored roster shares no instance with the original")
	_sections_done.append("rollback")


# --- ID issuance boundary (GPT L1 corrective) -----------------------------------------------------

## next_serial may never pass MAX_SERIAL: the last issuable id is
## merc_<MAX_SERIAL - 1> (next_serial becomes MAX_SERIAL, still saveable);
## after that create_mercenary() refuses, changing nothing.
func _verify_serial_boundary() -> void:
	var max_serial := MercenaryRoster.MAX_SERIAL
	_check(max_serial == 9007199254740992, "MAX_SERIAL is 2^53")
	# Highest valid issuable state: next_serial MAX - 1 (loaded from a save).
	var roster := MercenaryRoster.from_dict(_json({"owned": [_m("merc_1", "MAGE")], "deployed": ["merc_1"], "next_serial": max_serial - 1}))
	_check(roster != null and roster.get_next_serial() == max_serial - 1, "A save at next_serial MAX - 1 loads")
	var last := roster.create_mercenary("GUARDIAN")
	_check(last != null and last.get_id() == "merc_%d" % (max_serial - 1) and roster.get_next_serial() == max_serial, "Create at the boundary: the last id merc_%d, next_serial becomes MAX" % (max_serial - 1))
	var saved := _file_round_trip(roster)
	_check(saved != null and saved.get_next_serial() == max_serial and saved.get_owned_count() == 2 and saved.get_mercenary(last.get_id()) != null, "The roster after the last id is still Save v11 serializable (saved and loaded)")
	# Exhaustion: no persistable serial remains.
	var before := JSON.stringify(roster.to_dict())
	_check(roster.create_mercenary("MAGE") == null, "Exhausted: create_mercenary() refuses")
	_check(JSON.stringify(roster.to_dict()) == before and roster.get_owned_count() == 2 and roster.get_next_serial() == max_serial, "A refused create changes nothing (no instance, next_serial still MAX)")
	_check(_file_round_trip(roster) != null and saved.create_mercenary("STRATEGIST") == null, "Still saveable; the reloaded roster refuses too")
	# A save already at MAX loads, refuses to create, and stays saveable.
	var at_max := MercenaryRoster.from_dict(_json({"owned": [], "deployed": [], "next_serial": max_serial}))
	_check(at_max != null and at_max.create_mercenary("MAGE") == null and at_max.get_owned_count() == 0 and at_max.get_next_serial() == max_serial and _file_round_trip(at_max) != null, "A save at next_serial MAX: loads, creates nothing, stays saveable")
	# Skipping a used id at the boundary: merc_<MAX-1> owned (from outside),
	# next_serial MAX - 1... add() already moved it to MAX, so nothing is left.
	var skip := MercenaryRoster.from_dict(_json({"owned": [], "deployed": [], "next_serial": max_serial - 2}))
	_check(skip.add(Mercenary.create("merc_%d" % (max_serial - 1), "MAGE")) and skip.get_next_serial() == max_serial, "add(merc_<MAX-1>) moves next_serial to MAX")
	_check(skip.create_mercenary("MAGE") == null and skip.get_next_serial() == max_serial and _file_round_trip(skip) != null, "Then create refuses (merc_<MAX-2> is below the mark and never issued); still saveable")
	# add() never pushes next_serial past MAX either.
	var outside := MercenaryRoster.new()
	var count_before := outside.get_owned_count()
	_check(not outside.add(Mercenary.create("merc_%d" % max_serial, "MAGE")) and outside.get_next_serial() == 1 and outside.get_owned_count() == count_before, "add(merc_<MAX>) is refused (it would need next_serial MAX + 1); nothing changes")
	_check(not outside.add(Mercenary.create("merc_9999999999999999", "MAGE")) and outside.get_next_serial() == 1, "add() of a larger issued-form id is refused too")
	_check(outside.add(Mercenary.create("merc_12345678901234567", "MAGE")) and outside.get_next_serial() == 1 and _file_round_trip(outside) != null, "A 17-digit id is not issued-form: accepted, next_serial unchanged, saveable")
	# A failed create (full roster) never moves next_serial.
	var full := MercenaryRoster.new()
	for index in range(5):
		full.create_mercenary(TYPES[index % 3])
	var serial := full.get_next_serial()
	_check(full.create_mercenary("MAGE") == null and full.get_next_serial() == serial, "A refused create (roster full) leaves next_serial unchanged")
	_sections_done.append("serial_boundary")


# --- Stress (seeded, deterministic) --------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261004
	var roster := MercenaryRoster.new()
	var issued := {}
	var ok := true
	var reloads := 0
	for step in range(1500):
		match rng.randi_range(0, 5):
			0, 1:
				var created := roster.create_mercenary(TYPES[rng.randi_range(0, 2)])
				if created != null:
					ok = ok and not issued.has(created.get_id())
					issued[created.get_id()] = true
			2:
				if roster.get_owned_count() > 0:
					roster.remove(roster.get_owned()[rng.randi_range(0, roster.get_owned_count() - 1)].get_id())
			3:
				if roster.get_owned_count() > 0:
					var target := roster.get_owned()[rng.randi_range(0, roster.get_owned_count() - 1)]
					target.add_exp(rng.randi_range(0, 3000))
					if target.get_unspent_points() > 0:
						target.allocate({CharacterConfig.ALLOCATABLE[rng.randi_range(0, 3)]: rng.randi_range(1, target.get_unspent_points())})
			4:
				var ids := roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id())
				ids.shuffle()
				roster.set_deployment(ids.slice(0, rng.randi_range(0, mini(3, ids.size()))))
			5:
				# Save / reload (in memory through JSON; every 10th through the file).
				var before := JSON.stringify(roster.to_dict())
				var reloaded: MercenaryRoster = _file_round_trip(roster) if reloads % 10 == 0 else SaveStore.validate(_json(_current(roster))).get("mercenaries")
				reloads += 1
				ok = ok and reloaded != null and JSON.stringify(reloaded.to_dict()) == before
				roster = reloaded if reloaded != null else roster
		if not ok:
			_check(false, "Stress broke at step %d" % step)
			break
	_check(ok and reloads > 150 and issued.size() > 200, "1500 seeded steps, %d reloads: every reload exact, %d ids issued, none twice" % [reloads, issued.size()])
	# Repeated migrations: v10 -> v12 -> save -> load, stable.
	var v10 := _v11(MercenaryRoster.new(), {"hero": 5, "merc_a": 4, "merc_b": 3}, {"merc_a": {"hp": 9}})
	v10.erase("mercenaries")
	v10["version"] = 10
	var stable := true
	var expected := ""
	for round in range(100):
		var rewritten := _rewrite(_load(v10))
		var text := JSON.stringify(rewritten, "", true)
		if round == 0:
			expected = text
		stable = stable and text == expected and int(rewritten["version"]) == 13 and _rewrite(_load(rewritten)).hash() == rewritten.hash()
	_check(stable, "100 repeated v10 -> v12 migrations give the same v12 save, which reloads unchanged")
	_sections_done.append("stress")


# --- Helpers ---------------------------------------------------------------------------------------

## A JSON-shaped v11 save with `roster`, the fixed party at `levels` with
## `points` (Stage 8 P05: built as the current v12 save, then given the v11
## shape — the three legacy slots, no pending list).
func _v11(roster: MercenaryRoster, levels: Dictionary = {}, points: Dictionary = {}) -> Dictionary:
	var data := _current(roster, int(levels.get("hero", 1)), points.get("hero", {}))
	data.erase("pending_legacy_mercenaries")
	data.erase("carrying")  # Stage 9 P01 (v13)
	data["version"] = 11
	var progression_data := {}
	var allocation := {}
	for slot in SLOTS:
		progression_data[slot] = {"level": int(levels.get(slot, 1)), "exp": 0}
		var full := CharacterStats.zero_allocation()
		for stat in points.get(slot, {}):
			full[stat] = points[slot][stat]
		allocation[slot] = full
	data["progression"] = progression_data
	data["allocation"] = allocation
	return _json(data)


## Stage 8 P05: the current (v12) save of `roster`, the Hero at `level` with
## `points`.
func _current(roster: MercenaryRoster, level: int = 1, points: Dictionary = {}) -> Dictionary:
	var hero := CharacterStats.new()
	hero.apply_level(level)
	if not points.is_empty():
		hero.confirm_allocation(points)
	var inventory := CharacterInventory.new("player", hero)
	inventory.add("test_good_03", 4)
	var wallet := Wallet.new()
	wallet.spend(wallet.get_balance() - 4321)
	return _json(SaveStore.serialize(wallet, inventory, MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.from_hero(level, 0), {"hero": hero}, roster))


## Loads `data` through validate + rebuild (as a file would).
func _load(data: Dictionary) -> Dictionary:
	var payload := SaveStore.validate(_json(data))
	return {} if payload.is_empty() else SaveStore._rebuild(payload)


## The v12 save the game would write after loading `loaded` (P05: the Hero's
## progression / allocation; the Mercenaries in the roster).
func _rewrite(loaded: Dictionary) -> Dictionary:
	var hero: CharacterStats = loaded["character_stats"]
	hero.apply_level((loaded["progression"] as ProgressionState).get_level("hero"))
	hero.restore_allocation(loaded["allocation"]["hero"])
	return _json(SaveStore.serialize(loaded["wallet"], loaded["inventory"], loaded["market"], loaded["location"], loaded["warehouses"], loaded["market_recovery"], loaded["cost_ledger"], loaded["progression"], {"hero": hero}, loaded["mercenaries"]))


## Saves `roster` to the test file and loads it back (null when refused).
func _file_round_trip(roster: MercenaryRoster) -> MercenaryRoster:
	var party := {"hero": CharacterStats.new()}
	var inventory := CharacterInventory.new("player", party["hero"])
	if not SaveStore.save(TEST_SAVE, Wallet.new(), inventory, MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.new(), party, roster):
		return null
	var loaded := SaveStore.load_session(TEST_SAVE)
	_delete(TEST_SAVE)
	return loaded.get("mercenaries") if not loaded.is_empty() else null


## merc_1, (merc_2 removed), merc_3 MAGE, merc_4 GUARDIAN, merc_5 STRATEGIST;
## merc_1 MAGE Lv5 / 40 EXP / 12 points; deployed merc_3, merc_1; next 6.
func _sample_roster() -> MercenaryRoster:
	var roster := MercenaryRoster.new()
	for type in ["MAGE", "GUARDIAN", "MAGE", "GUARDIAN", "STRATEGIST"]:
		roster.create_mercenary(type)
	roster.remove("merc_2")
	roster.get_mercenary("merc_1").add_exp(100 + 150 + 200 + 250 + 40)
	roster.get_mercenary("merc_1").allocate({"hp": 4, "agi": 4, "int": 4})
	roster.get_mercenary("merc_3").add_exp(100 + 149)
	roster.set_deployment(["merc_3", "merc_1"])
	return roster


func _roster_of(types: Array, deployed_indexes: Array) -> MercenaryRoster:
	var roster := MercenaryRoster.new()
	for index in range(types.size()):
		var mercenary := roster.create_mercenary(types[index])
		mercenary.add_exp(index * 137)
		if mercenary.get_unspent_points() > 0:
			mercenary.allocate({CharacterConfig.ALLOCATABLE[index % 4]: mercenary.get_unspent_points()})
	roster.set_deployment(deployed_indexes.map(func(i: int) -> String: return roster.get_owned()[i].get_id()))
	return roster


func _m(id: Variant, type: Variant, level: Variant = 1, held_exp: Variant = 0, allocation: Variant = null) -> Dictionary:
	return {"id": id, "type": type, "level": level, "exp": held_exp, "allocation": allocation if allocation != null else CharacterStats.zero_allocation()}


func _mercs(count: int) -> Array:
	var list := []
	for index in range(count):
		list.append(_m("merc_%d" % (index + 1), TYPES[index % 3]))
	return list


func _roster_data(owned: Array, deployed: Array, next_serial: Variant) -> Dictionary:
	return {"owned": owned, "deployed": deployed, "next_serial": next_serial}


func _with(data: Dictionary, changes: Dictionary) -> Dictionary:
	var copy := data.duplicate(true)
	for key in changes:
		copy[key] = changes[key]
	return copy


func _json(data: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(data))


func _new_main() -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	for frame in range(4):
		await physics_frame
	await process_frame
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _delete(path: String) -> void:
	for p in [path, path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
