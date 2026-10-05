extends SceneTree

## Stage 8 P01: Party & Mercenary Data Foundation (runtime only).
##   A owned roster 0 / 1 / 5 valid, 6 refused
##   B unique identity: same type, different ids; duplicate / reused id refused
##   C deployment 0 / 1 / 3 valid, 4 refused; only owned ids, never twice
##   D three separate MAGE instances deployed together
##   E independent Stage 7 progression between same-type instances
##   F the Hero takes no owned / deployed slot
##   G Stage 7 compatibility: same curve / point rules; the fixed party, Save
##     v10, main and combat untouched
##   + validation of malformed state, targeted stress (seeded, deterministic)

const TYPES := ["GUARDIAN", "MAGE", "STRATEGIST"]

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_verify_owned()
	_verify_identity()
	_verify_deployment()
	_verify_same_type_party()
	_verify_progression()
	_verify_hero()
	_verify_validation()
	_verify_stage7()
	_verify_stress()
	_check(_sections_done.size() == 9, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("P01 party & mercenary verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- A. Owned roster --------------------------------------------------------------------------------

func _verify_owned() -> void:
	_check(MercenaryRoster.MAX_OWNED == 5 and MercenaryRoster.MAX_DEPLOYED == 3 and MercenaryRoster.MAX_PARTY == 4, "Limits: 5 owned, 3 deployed, party Hero + 3 = 4")
	var roster := MercenaryRoster.new()
	_check(roster.get_owned_count() == 0 and roster.get_owned().is_empty() and roster.get_deployed_ids().is_empty() and not roster.is_full(), "0 owned is valid")
	_check(MercenaryRoster.build([]) != null, "build: 0 owned is valid")
	var first := roster.create_mercenary("GUARDIAN")
	_check(first != null and roster.get_owned_count() == 1 and roster.get_mercenary(first.get_id()) == first, "1 owned")
	_check(MercenaryRoster.build([_merc("a1", "MAGE")]) != null, "build: 1 owned is valid")
	for index in range(4):
		_check(roster.create_mercenary(TYPES[index % 3]) != null, "Owned %d" % (index + 2))
	_check(roster.get_owned_count() == 5 and roster.is_full(), "5 owned is valid")
	var ids := _ids(roster)
	_check(roster.create_mercenary("MAGE") == null and not roster.add(_merc("extra", "MAGE")) and roster.get_owned_count() == 5 and _ids(roster) == ids, "A 6th is refused, nothing changes")
	_check(MercenaryRoster.build(_mercs(5, "MAGE")) != null and MercenaryRoster.build(_mercs(6, "MAGE")) == null, "build: 5 valid, 6 refused")
	_check(not roster.add(null), "null refused")
	_sections_done.append("owned")


# --- B. Unique identity -------------------------------------------------------------------------------

func _verify_identity() -> void:
	var roster := MercenaryRoster.new()
	var a := roster.create_mercenary("MAGE")
	var b := roster.create_mercenary("MAGE")
	_check(a != null and b != null and a.get_id() != b.get_id() and a.get_type() == b.get_type(), "Same type, different ids")
	_check(not a.get_id().contains("MAGE") and not a.get_id().to_lower().contains("mage"), "The id does not name the type (%s)" % a.get_id())
	_check(MercenaryRoster.build([_merc("x1", "GUARDIAN"), _merc("x2", "GUARDIAN")]) != null, "build: different ids, same type valid")
	_check(MercenaryRoster.build([_merc("x1", "GUARDIAN"), _merc("x1", "MAGE")]) == null, "build: duplicate owned id refused (even with another type)")
	_check(not roster.add(_merc(a.get_id(), "STRATEGIST")) and roster.get_owned_count() == 2, "add: an owned id is refused")
	# Stable: an id never follows a position.
	var c := roster.create_mercenary("GUARDIAN")
	var c_id := c.get_id()
	_check(roster.remove(a.get_id()) and roster.get_owned()[0] == b and b.get_id() != a.get_id() and c.get_id() == c_id and roster.get_mercenary(c_id) == c, "Removing one moves positions, not ids")
	# Never reused: neither issued again nor accepted again.
	var issued := {}
	for mercenary in roster.get_owned():
		issued[mercenary.get_id()] = true
	issued[a.get_id()] = true
	_check(not roster.add(_merc(a.get_id(), "MAGE")), "A removed id is never accepted again")
	var outside := MercenaryRoster.new()
	_check(outside.add(_merc("merc_a", "GUARDIAN")) and outside.remove("merc_a") and not outside.add(_merc("merc_a", "GUARDIAN")), "A removed non-issued id (merc_a) is never accepted again either")
	for round in range(20):
		var fresh := roster.create_mercenary(TYPES[round % 3])
		_check(fresh != null and not issued.has(fresh.get_id()), "Issued id %s is new" % (fresh.get_id() if fresh != null else "-"))
		issued[fresh.get_id()] = true
		roster.remove(fresh.get_id())
	# An externally given id (e.g. a future legacy id) is respected by the issuer.
	var legacy := MercenaryRoster.new()
	_check(legacy.add(_merc("merc_1", "GUARDIAN")) and legacy.create_mercenary("MAGE").get_id() != "merc_1", "The issuer skips an id already used")
	for bad in ["", "Hero", "hero", "MERC 1", "merc-1", "x".repeat(33), 7, null]:
		_check(Mercenary.create(bad, "MAGE") == null, "Invalid id refused: %s" % str(bad))
	_check(Mercenary.create("merc_a", "GUARDIAN") != null and Mercenary.create("merc_b", "MAGE") != null, "Legacy-style ids are valid ids (future migration)")
	_sections_done.append("identity")


# --- C. Deployment ---------------------------------------------------------------------------------

func _verify_deployment() -> void:
	var roster := MercenaryRoster.build(_mercs(5, "GUARDIAN"))
	var ids := _ids(roster)
	_check(roster.set_deployment([]) and roster.get_deployed_ids().is_empty(), "0 deployed valid")
	_check(roster.set_deployment([ids[2]]) and roster.get_deployed_ids() == [ids[2]] and roster.is_deployed(ids[2]), "1 deployed valid")
	_check(roster.set_deployment([ids[4], ids[0], ids[1]]) and roster.get_deployed_ids() == [ids[4], ids[0], ids[1]], "3 deployed valid, in order")
	_check(roster.get_deployed() == [roster.get_mercenary(ids[4]), roster.get_mercenary(ids[0]), roster.get_mercenary(ids[1])], "Deployed instances resolve by id")
	var before := roster.get_deployed_ids()
	_check(not roster.set_deployment([ids[0], ids[1], ids[2], ids[3]]) and roster.get_deployed_ids() == before, "4 deployed refused, nothing changes")
	_check(not roster.set_deployment(["merc_999"]) and not roster.set_deployment([ids[0], "nobody"]) and roster.get_deployed_ids() == before, "A deployed id must be owned")
	_check(not roster.set_deployment([ids[0], ids[0]]) and not roster.set_deployment([ids[1], ids[2], ids[1]]) and roster.get_deployed_ids() == before, "The same id twice refused")
	_check(not roster.set_deployment([Mercenary.HERO_ID]) and not roster.set_deployment([7]) and not roster.set_deployment([null]), "Hero / non-string ids refused")
	_check(MercenaryRoster.build(_mercs(3, "MAGE"), ["m1", "m2", "m3"]) != null and MercenaryRoster.build(_mercs(4, "MAGE"), ["m1", "m2", "m3", "m4"]) == null, "build: 3 deployed valid, 4 refused")
	_check(MercenaryRoster.build(_mercs(2, "MAGE"), ["m1", "m9"]) == null and MercenaryRoster.build(_mercs(2, "MAGE"), ["m1", "m1"]) == null, "build: unknown / duplicated deployment refused")
	# Removing a deployed one drops it from the deployment; the rest stay in order.
	_check(roster.remove(ids[0]) and roster.get_deployed_ids() == [ids[4], ids[1]] and not roster.is_deployed(ids[0]), "Removing a deployed Mercenary undeploys it")
	_check(not roster.remove(ids[0]) and not roster.remove("nobody") and not roster.remove(3), "Removing an unknown id is refused")
	_sections_done.append("deployment")


# --- D. Same-type party ----------------------------------------------------------------------------

func _verify_same_type_party() -> void:
	var roster := MercenaryRoster.new()
	var mages: Array[Mercenary] = []
	for index in range(3):
		mages.append(roster.create_mercenary("MAGE"))
	var ids := [mages[0].get_id(), mages[1].get_id(), mages[2].get_id()]
	_check(ids[0] != ids[1] and ids[1] != ids[2] and ids[0] != ids[2], "Three MAGE instances, three ids (%s)" % str(ids))
	_check(roster.set_deployment(ids) and roster.get_deployed().all(func(m: Mercenary) -> bool: return m.get_type() == "MAGE") and roster.get_deployed().size() == 3, "All three MAGEs deployed at once")
	_check(roster.get_party_ids() == ["hero", ids[0], ids[1], ids[2]], "Party: Hero + Mage + Mage + Mage")
	for type in TYPES:
		var same := MercenaryRoster.build([_merc("t1", type), _merc("t2", type), _merc("t3", type)], ["t1", "t2", "t3"])
		_check(same != null and same.get_deployed_ids().size() == 3, "3 deployed %s valid" % type)
	var mixed := MercenaryRoster.build([_merc("g1", "GUARDIAN"), _merc("g2", "GUARDIAN"), _merc("m1", "MAGE")], ["g1", "g2", "m1"])
	_check(mixed != null, "Guard + Guard + Mage valid")
	_sections_done.append("same_type_party")


# --- E. Independent progression ------------------------------------------------------------------------

func _verify_progression() -> void:
	var roster := MercenaryRoster.new()
	var one := roster.create_mercenary("MAGE")
	var two := roster.create_mercenary("MAGE")
	_check(one.get_level() == 1 and one.get_exp() == 0 and one.get_allocation_points() == CharacterStats.zero_allocation() and one.get_unspent_points() == 0, "A new instance starts at Lv1, 0 EXP, no points")
	_check(one.add_exp(130), "EXP to one")
	_check(one.get_level() == 2 and one.get_exp() == 30 and two.get_level() == 1 and two.get_exp() == 0, "Lv2 30 EXP vs Lv1 0 EXP")
	_check(two.add_exp(100 + 150 + 200 + 10), "EXP to the other")
	_check(two.get_level() == 4 and two.get_exp() == 10 and one.get_level() == 2 and one.get_exp() == 30, "Lv4 10 EXP vs Lv2 30 EXP (curve 100 / 150 / 200)")
	_check(one.get_unspent_points() == 3 and two.get_unspent_points() == 9, "Each earns its own points (3 vs 9)")
	_check(one.allocate({"hp": 2, "int": 1}) and two.allocate({"str": 5}), "Each allocates its own")
	_check(one.get_allocation_points() == {"hp": 2, "str": 0, "agi": 0, "int": 1} and two.get_allocation_points() == {"hp": 0, "str": 5, "agi": 0, "int": 0}, "Allocations stay apart")
	_check(one.get_unspent_points() == 0 and two.get_unspent_points() == 4, "Unspent apart (0 vs 4)")
	var copy := one.get_allocation_points()
	copy["hp"] = 99
	_check(one.get_allocation_points()["hp"] == 2, "get_allocation_points() is a copy")
	_check(not one.allocate({"agi": 1}) and not two.allocate({"agi": 5}) and not two.allocate({"mp": 1}) and not two.allocate({"str": -1}) and not two.allocate({"str": 1.0}) and not two.allocate({}), "Allocation rules: no more than unspent, no MP, whole points > 0")
	_check(two.get_allocation_points()["agi"] == 0 and two.get_unspent_points() == 4, "A refused allocation changes nothing")
	_check(not one.add_exp(-1) and not one.add_exp(1.5) and one.get_exp() == 30, "Bad EXP refused")
	# The same through build() / to_dict(): two same-type instances with different progression.
	var built := MercenaryRoster.build([Mercenary.create("p1", "GUARDIAN", 5, 40, {"hp": 4, "str": 4, "agi": 4, "int": 0}), Mercenary.create("p2", "GUARDIAN", 2, 0, CharacterStats.zero_allocation())], ["p1", "p2"])
	_check(built != null and built.get_mercenary("p1").get_level() == 5 and built.get_mercenary("p2").get_level() == 2 and built.get_mercenary("p2").get_unspent_points() == 3, "Same type, Lv5 (12 spent) and Lv2 (3 unspent)")
	built.get_mercenary("p2").add_exp(150)
	_check(built.get_mercenary("p1").to_dict() == {"id": "p1", "type": "GUARDIAN", "level": 5, "exp": 40, "allocation": {"hp": 4, "str": 4, "agi": 4, "int": 0}}, "p1 untouched by p2's EXP")
	var restored := Mercenary.from_dict(JSON.parse_string(JSON.stringify(built.get_mercenary("p1").to_dict())))
	_check(restored != null and restored.to_dict() == built.get_mercenary("p1").to_dict(), "to_dict / from_dict round trip (JSON numbers)")
	# Lv100 cap as Stage 7.
	var capped := Mercenary.create("cap", "STRATEGIST", 99, 0)
	_check(capped.add_exp(ProgressionState.required_exp(99) + 500) and capped.get_level() == 100 and capped.get_exp() == 0 and capped.get_earned_points() == 297, "Lv100 cap: no EXP kept, 297 points")
	_sections_done.append("progression")


# --- F. Hero separation ---------------------------------------------------------------------------

func _verify_hero() -> void:
	var roster := MercenaryRoster.build(_mercs(5, "MAGE"), ["m1", "m2", "m3"])
	_check(roster != null and roster.get_owned_count() == 5 and roster.get_deployed_ids().size() == 3, "5 owned + 3 deployed: the Hero takes neither slot")
	_check(roster.get_party_ids() == ["hero", "m1", "m2", "m3"] and roster.get_party_ids().size() == MercenaryRoster.MAX_PARTY, "Party: the Hero always first, + 3 = 4")
	_check(MercenaryRoster.new().get_party_ids() == ["hero"], "No Mercenary: the Hero alone")
	_check(Mercenary.create("hero", "MAGE") == null and not roster.add(Mercenary.new()), "The Hero cannot be a Mercenary")
	for mercenary in roster.get_owned():
		_check(mercenary.get_id() != "hero", "No owned Hero")
	_sections_done.append("hero")


# --- Validation: malformed / unsupported / corrupting state ---------------------------------------

func _verify_validation() -> void:
	for type in TYPES:
		_check(Mercenary.create("v", type) != null, "Type %s supported" % type)
	for bad in ["", "Mage", "mage", "HERO", "WARRIOR", "GUARD", "守衛", 1, null]:
		_check(Mercenary.create("v", bad) == null, "Unsupported type refused: %s" % str(bad))
	var roster := MercenaryRoster.new()
	_check(roster.create_mercenary("WARRIOR") == null and roster.create_mercenary(null) == null and roster.get_owned_count() == 0, "create_mercenary refuses a bad type, owns nothing")
	_check(roster.create_mercenary("MAGE").get_id() == "merc_1", "…and burns no id")
	# Progression that could corrupt Stage 7 rules.
	var zero := CharacterStats.zero_allocation()
	var cases := [
		["level 0", 0, 0, zero], ["level 101", 101, 0, zero], ["level 1.5", 1.5, 0, zero], ["level text", "2", 0, zero],
		["exp -1", 1, -1, zero], ["exp at requirement", 1, 100, zero], ["exp at Lv100", 100, 5, zero], ["exp 2.5", 2, 2.5, zero],
		["points over earned", 2, 0, {"hp": 4, "str": 0, "agi": 0, "int": 0}], ["points at Lv1", 1, 0, {"hp": 1, "str": 0, "agi": 0, "int": 0}],
		["negative points", 3, 0, {"hp": -1, "str": 0, "agi": 0, "int": 0}], ["MP points", 3, 0, {"hp": 0, "str": 0, "agi": 0, "int": 0, "mp": 1}],
		["missing stat", 3, 0, {"hp": 0, "str": 0, "agi": 0}], ["unknown stat", 3, 0, {"hp": 0, "str": 0, "agi": 0, "luck": 0}],
		["fraction points", 3, 0, {"hp": 0.5, "str": 0, "agi": 0, "int": 0}], ["allocation not a dictionary", 3, 0, [0, 0, 0, 0]],
	]
	for case in cases:
		_check(Mercenary.create("v", "MAGE", case[1], case[2], case[3]) == null, "Refused: %s" % case[0])
	_check(Mercenary.create("v", "MAGE", 3, 199, {"hp": 6, "str": 0, "agi": 0, "int": 0}) != null and Mercenary.create("v", "MAGE", 2.0, 149.0, {"hp": 3.0, "str": 0, "agi": 0, "int": 0}) != null, "Edge values (exp just below the requirement, all points spent, JSON whole floats) valid")
	for data in [null, {}, {"id": "v", "type": "MAGE", "level": 1, "exp": 0}, {"id": "v", "type": "MAGE", "level": 1, "exp": 0, "allocation": zero, "extra": 1}]:
		_check(Mercenary.from_dict(data) == null, "Malformed dictionary refused")
	_check(MercenaryRoster.build([_merc("a", "MAGE"), "b"]) == null and MercenaryRoster.build([null]) == null, "build: a non-Mercenary entry refused")
	# Codex review: overflow and anchoring.
	var huge := 9223372036854775807
	for bad in ["merc_1\n", "merc_1\n\n", "\nmerc_1", "merc_1 "]:
		_check(Mercenary.create(bad, "MAGE") == null, "An id with a trailing / leading newline or space is refused (%s)" % bad.c_escape())
	_check(Mercenary.create("v", "MAGE", 3, 0, {"hp": huge, "str": huge, "agi": huge, "int": huge}) == null and Mercenary.create("v", "MAGE", 3, 0, {"hp": huge, "str": huge, "agi": 2, "int": 0}) == null, "Huge allocation values refused (no overflow past the earned points)")
	var holder := Mercenary.create("v", "MAGE", 2, 100)
	_check(not holder.add_exp(huge) and not holder.add_exp(ProgressionState.MAX_EXP + 1) and holder.get_level() == 2 and holder.get_exp() == 100, "A huge EXP amount is refused, nothing changes")
	_check(holder.add_exp(ProgressionState.MAX_EXP) and holder.get_level() == 100 and holder.get_exp() == 0, "MAX_EXP itself is accepted (to the cap)")
	var spender := Mercenary.create("w", "MAGE", 2)
	_check(not spender.allocate({"hp": huge, "str": huge, "agi": 3}) and spender.get_allocation_points() == CharacterStats.zero_allocation() and spender.get_unspent_points() == 3, "Pending points that would wrap the total are refused")
	_check(not spender.allocate({"hp": 2, "str": 2}) and spender.get_unspent_points() == 3, "Each amount fits but the total (4) is over the unspent 3: refused")
	_check(Mercenary.create("v", "MAGE", 2, 0, {"hp": 2, "str": 2, "agi": 0, "int": 0}) == null, "Each value within the earned 3 but the sum (4) over it: refused")
	_sections_done.append("validation")


# --- G. Stage 7 compatibility / no wiring ---------------------------------------------------------------

func _verify_stage7() -> void:
	# The same curve and point rules as a Stage 7 character.
	for amount in [0, 99, 100, 249, 250, 451, 5000, 200000]:
		var mercenary := Mercenary.create("c", "GUARDIAN")
		mercenary.add_exp(amount)
		var state := ProgressionState.from_dict({"hero": {"level": 1, "exp": amount}})
		_check(mercenary.get_level() == state.get_level("hero") and mercenary.get_exp() == state.get_exp("hero"), "EXP %d: same Level / EXP as ProgressionState (Lv%d)" % [amount, mercenary.get_level()])
		var stats := CharacterStats.for_character("hero")
		stats.apply_level(mercenary.get_level())
		_check(mercenary.get_earned_points() == stats.get_earned_points() and mercenary.get_unspent_points() == stats.get_unspent_points(), "Same earned points as CharacterStats at Lv%d" % mercenary.get_level())
	_check(ProgressionState.advance(1, 0, 250) == [3, 0] and ProgressionState.advance(99, 0, ProgressionState.required_exp(99)) == [100, 0], "advance() is the Stage 7 curve")
	# The allocation shape is CharacterStats's (future restore_allocation).
	var merc_a := CharacterStats.for_character("merc_a")
	merc_a.apply_level(3)
	var guardian := Mercenary.create("g", "GUARDIAN", 3, 0, {"hp": 2, "str": 1, "agi": 0, "int": 0})
	_check(merc_a.restore_allocation(guardian.get_allocation_points()) and merc_a.get_allocation_points() == guardian.get_allocation_points(), "An instance's points fit CharacterStats.restore_allocation")
	# Stage 7 data untouched.
	# Stage 8 P05: the fixed slots are legacy save slots only (the Hero keeps
	# his); merc_a / merc_b stay the GUARDIAN / MAGE stat profiles.
	_check(ProgressionState.LEGACY_SLOTS == ["hero", "merc_a", "merc_b"] and ProgressionState.SLOTS == ["hero"] and CharacterConfig.PROTOTYPE_CHARACTERS == ["hero", "merc_a", "merc_b"], "The Stage 7 fixed party is unchanged (P05: legacy slots read only)")
	# P01.5 (Save v11) saves the roster: save_store.gd and main.gd now hold it
	# (verify_p015_mercenary_save); everything else stays unwired.
	_check(SaveStore.VERSION == 14 and SaveStore.V10_KEYS == ["version", "money", "character", "market", "location", "warehouses", "market_recovery", "cost_ledger", "progression", "allocation"] and SaveStore.V11_KEYS == SaveStore.V10_KEYS + ["mercenaries"] and SaveStore.V12_KEYS == SaveStore.V11_KEYS + ["pending_legacy_mercenaries"], "Save v10 sections unchanged; v11 adds only the roster (P01.5; P05 v12 only the pending list)")
	for path in ["res://scripts/combat_battle.gd", "res://scripts/combat_view.gd", "res://scripts/character_panel.gd", "res://scripts/progression_state.gd", "res://scripts/character_stats.gd"]:
		var code := _code_only(path)
		# Stage 8 P04 (approved) wired combat_battle / combat_view /
		# character_stats to the deployed instances (read only); there the check
		# narrows to "never creates or changes a roster".
		if path.get_file() in ["combat_battle.gd", "combat_view.gd", "character_stats.gd"]:
			_check(["roster.add(", "roster.remove(", "set_deployment(", "create_mercenary(", "restore_snapshot(", "MercenaryRoster.new(", "MercenaryRoster.build(", "MercenaryRoster.from_dict("].all(func(call: String) -> bool: return not code.contains(call)), "%s is not wired to the roster" % path.get_file())
			continue
		_check(not code.contains("MercenaryRoster") and not code.contains("Mercenary.") and not code.contains("roster"), "%s is not wired to the roster" % path.get_file())
	# Stage 8 P03: the City Hub shows a roster view (display data from main.gd)
	# but still never holds the roster model.
	var hub_code := _code_only("res://scripts/city_hub.gd")
	_check(not hub_code.contains("MercenaryRoster") and not hub_code.contains("Mercenary.") and not hub_code.contains("mercenary_roster"), "city_hub.gd is not wired to the roster model")
	for path in ["res://scripts/mercenary.gd", "res://scripts/mercenary_roster.gd"]:
		var code := _code_only(path)
		for word in ["SaveStore", "FileAccess", "CombatBattle", "CombatUnit", "Node", "Control", "randi", "randf", "Time.", "price", "money", "Wallet"]:
			_check(not code.contains(word), "%s has no %s (data only)" % [path.get_file(), word])
		# Stage 8 P05 (approved): the roster names the two legacy stable ids in
		# exactly one place, its LEGACY_TYPES table; nothing else names them.
		var legacy_free := _without_line(code, "const LEGACY_TYPES := {\"merc_a\": \"GUARDIAN\", \"merc_b\": \"MAGE\"}")
		for word in ["\"MERC_A\"", "\"merc_a\"", "\"merc_b\"", "ice", "skill"]:
			_check(not legacy_free.to_lower().contains(word.to_lower()), "%s holds no %s" % [path.get_file(), word])
	_sections_done.append("stage7")


# --- Targeted stress (seeded, deterministic) --------------------------------------------------------------

## Random add / remove / deploy / EXP / allocation operations, checking every
## invariant after each one: limits, unique ids, never-reused ids, the
## deployment only of owned ids, and each instance's progression changing only
## when it is the target.
func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261004
	var roster := MercenaryRoster.new()
	var ever := {}
	var snapshots := {}
	var ok := true
	var refused_full := 0
	var refused_deploy := 0
	var refused_duplicate := 0
	for step in range(4000):
		var owned := roster.get_owned()
		var op := rng.randi_range(0, 6)
		var target: Mercenary = owned[rng.randi_range(0, owned.size() - 1)] if not owned.is_empty() else null
		match op:
			0, 1:
				var created := roster.create_mercenary(TYPES[rng.randi_range(0, 2)])
				if owned.size() >= 5:
					ok = ok and created == null
					refused_full += 1
				else:
					ok = ok and created != null and not ever.has(created.get_id())
					if created != null:
						ever[created.get_id()] = true
			2:
				if target != null:
					ok = ok and roster.remove(target.get_id()) and roster.get_mercenary(target.get_id()) == null and not roster.add(_merc(target.get_id(), "MAGE"))
					snapshots.erase(target.get_id())
			3:
				var ids := []
				for count in range(rng.randi_range(0, 4)):
					ids.append(owned[rng.randi_range(0, owned.size() - 1)].get_id() if not owned.is_empty() else "nobody")
				var unique := {}
				for id in ids:
					unique[id] = true
				var valid := ids.size() <= 3 and unique.size() == ids.size() and not unique.has("nobody")
				var before := roster.get_deployed_ids()
				var done := roster.set_deployment(ids)
				ok = ok and done == valid and (roster.get_deployed_ids() == before if not done else roster.get_deployed_ids() == ids)
				if not done:
					refused_deploy += 1
			4:
				if target != null:
					ok = ok and not roster.add(_merc(target.get_id(), TYPES[rng.randi_range(0, 2)]))
					refused_duplicate += 1
			5:
				if target != null:
					target.add_exp(rng.randi_range(0, 400))
			6:
				if target != null and target.get_unspent_points() > 0:
					ok = ok and target.allocate({CharacterConfig.ALLOCATABLE[rng.randi_range(0, 3)]: 1})
		# Invariants.
		owned = roster.get_owned()
		var seen := {}
		for mercenary in owned:
			ok = ok and not seen.has(mercenary.get_id()) and ever.has(mercenary.get_id()) and mercenary.get_spent_points() <= mercenary.get_earned_points()
			seen[mercenary.get_id()] = true
			# Only the target's progression may have changed this step.
			if snapshots.has(mercenary.get_id()) and mercenary != target:
				ok = ok and snapshots[mercenary.get_id()] == mercenary.to_dict()
			snapshots[mercenary.get_id()] = mercenary.to_dict()
		var deployed := roster.get_deployed_ids()
		var deployed_seen := {}
		for id in deployed:
			ok = ok and seen.has(id) and not deployed_seen.has(id)
			deployed_seen[id] = true
		ok = ok and owned.size() <= 5 and deployed.size() <= 3 and roster.get_party_ids()[0] == "hero"
		if not ok:
			_check(false, "Stress invariant broken at step %d (op %d)" % [step, op])
			break
	_check(ok, "4000 seeded operations keep every invariant")
	_check(refused_full > 50 and refused_deploy > 50 and refused_duplicate > 50 and ever.size() > 100, "Boundaries exercised: %d full, %d deployment, %d duplicate refusals, %d ids issued" % [refused_full, refused_deploy, refused_duplicate, ever.size()])
	# Same-type isolation, repeated.
	for round in range(200):
		var same := MercenaryRoster.new()
		var a := same.create_mercenary("STRATEGIST")
		var b := same.create_mercenary("STRATEGIST")
		var b_before := b.to_dict()
		a.add_exp(100 + round)
		if a.get_unspent_points() > 0:
			a.allocate({"int": 1})
		ok = ok and b.to_dict() == b_before and a.get_id() != b.get_id()
	_check(ok, "200 same-type rounds: the other instance never changes")
	_sections_done.append("stress")


# --- Helpers ---------------------------------------------------------------------------------------

func _merc(id: String, type: String) -> Mercenary:
	return Mercenary.create(id, type)


## `count` instances of `type` with ids m1..mN.
func _mercs(count: int, type: String) -> Array:
	var list := []
	for index in range(count):
		list.append(_merc("m%d" % (index + 1), type))
	return list


func _ids(roster: MercenaryRoster) -> Array:
	return roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id())


func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


## `code` without the line that is exactly `line` (stripped).
func _without_line(code: String, line: String) -> String:
	var lines := []
	for each in code.split("\n"):
		if each.strip_edges() != line:
			lines.append(each)
	return "\n".join(lines)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
