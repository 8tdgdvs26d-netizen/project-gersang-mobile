extends SceneTree

## Stage 7 S05: Save Migration + Full Integration. Save v10 adds
## `allocation`: the confirmed Stat Point counts {hp, str, agi, int} of hero /
## merc_a / merc_b. Nothing derived is saved (Growth, Effective, derived stats,
## Capacity, unspent / earned points): load = Level / EXP -> apply_level ->
## restore the counts -> everything else recalculated. v1-v9 migrate with every
## allocation 0. A malformed or overspent allocation rejects the whole save
## (never clamped or repaired). Unconfirmed previews are never saved.
## Stage 8 P05 (Save v12): the Hero's progression / allocation stay in their
## sections; Merc A / Merc B became roster instances merc_a / merc_b (the same
## Level / EXP / counts, now saved on the instance). The v10 rules below still
## validate every v10 / v11 file before it migrates.

const TEST_SAVE := "user://s05_save_migration_test_save.json"
const T0 := 1800000000000
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const SLOTS := ["hero", "merc_a", "merc_b"]
const ZERO := {"hp": 0, "str": 0, "agi": 0, "int": 0}

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_verify_schema()
	await _verify_migration()
	_verify_validation()
	await _verify_round_trip()
	await _verify_preview_exclusion()
	_check(_sections_done.size() == 5, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("S05 save migration verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- A / B / C: schema, serialization, deserialization ---------------------------

## The Hero's CharacterStats at `levels["hero"]` with `points["hero"]`.
func _hero(levels: Dictionary, points: Dictionary) -> CharacterStats:
	var stats := CharacterStats.new()
	stats.apply_level(int(levels.get("hero", 1)))
	if points.has("hero"):
		stats.confirm_allocation(points["hero"])
	return stats


## P05: Merc A / Merc B as the roster instances merc_a (GUARDIAN) / merc_b
## (MAGE) at `levels` with `points` (waiting).
func _legacy_roster(levels: Dictionary, points: Dictionary) -> MercenaryRoster:
	var owned := []
	for slot in ["merc_a", "merc_b"]:
		var full := ZERO.duplicate()
		for stat in points.get(slot, {}):
			full[stat] = points[slot][stat]
		owned.append(Mercenary.create(slot, MercenaryRoster.LEGACY_TYPES[slot], int(levels.get(slot, 1)), 0, full))
	return MercenaryRoster.build(owned)


## The current (v12) save JSON: the Hero, Merc A / Merc B in the roster.
func _v12(levels: Dictionary, points: Dictionary, strength: int = 10) -> Dictionary:
	var hero := _hero(levels, points)
	hero.set_strength(strength)
	var inventory := CharacterInventory.new("player", hero)
	inventory.add("test_good_03", 4)
	var raw := SaveStore.serialize(_wallet(4321), inventory, MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.from_hero(int(levels.get("hero", 1)), 0), {"hero": hero}, _legacy_roster(levels, points))
	return JSON.parse_string(JSON.stringify(raw))


## A v10 save JSON (the three-slot progression / allocation sections).
func _v10(levels: Dictionary, points: Dictionary, strength: int = 10) -> Dictionary:
	var data := _v12(levels, points, strength)
	data.erase("mercenaries")
	data.erase("pending_legacy_mercenaries")
	data["version"] = 10
	var progression := {}
	var allocation := {}
	for slot in SLOTS:
		progression[slot] = {"level": int(levels.get(slot, 1)), "exp": 0}
		var full := ZERO.duplicate()
		for stat in points.get(slot, {}):
			full[stat] = points[slot][stat]
		allocation[slot] = full
	data["progression"] = progression
	data["allocation"] = allocation
	return JSON.parse_string(JSON.stringify(data))


## P05: a character's stats in the game: the Hero's, or a roster instance's.
func _stats_of(main: Node, slot: String) -> CharacterStats:
	if slot == "hero":
		return main.character_stats
	var mercenary: Mercenary = main.mercenary_roster.get_mercenary(slot)
	return CharacterStats.for_mercenary(mercenary) if mercenary != null else null


## Every saved allocation count: the Hero's + merc_a's + merc_b's (P05).
func _saved_allocations(data: Dictionary) -> Array:
	return SLOTS.map(func(slot: String) -> Dictionary: return _saved_points(data, slot))


func _level_of(main: Node, slot: String) -> int:
	return main.progression.get_level(slot) if slot == "hero" else main.mercenary_roster.get_mercenary(slot).get_level()


func _exp_of(main: Node, slot: String) -> int:
	return main.progression.get_exp(slot) if slot == "hero" else main.mercenary_roster.get_mercenary(slot).get_exp()


## A save JSON's saved counts of `slot` (P05: Merc A / B in the roster).
func _saved_points(data: Dictionary, slot: String) -> Dictionary:
	if slot == "hero":
		return _ints(data["allocation"]["hero"])
	for entry in data["mercenaries"]["owned"]:
		if entry["id"] == slot:
			return _ints(entry["allocation"])
	return {}


func _verify_schema() -> void:
	_check(SaveStore.VERSION == 12, "AC01 SaveStore.VERSION = 10 (P05: 12)")
	_check(SaveStore.V10_KEYS == SaveStore.V9_KEYS + ["allocation"] and SaveStore.INVENTORY_VERSIONS.has(10), "v10 = v9 + allocation")
	var levels := {"hero": 4, "merc_a": 3, "merc_b": 5}
	var points := {"hero": {"hp": 2, "str": 3, "agi": 1, "int": 2}, "merc_a": {"hp": 2, "str": 4}, "merc_b": {"agi": 2, "int": 4}}
	var data := _v12(levels, points)
	_check(int(data["version"]) == 12 and data.has("allocation"), "AC02 A new save is v10 with allocation (P05: v12)")
	var allocation: Dictionary = data["allocation"]
	_check(allocation.keys() == ["hero"] and SLOTS.all(func(s: String) -> bool: return _saved_points(data, s).keys().size() == 4 and _saved_points(data, s).has_all(["hp", "str", "agi", "int"])), "AC02 Exactly hero / merc_a / merc_b x hp / str / agi / int (P05: Merc A / B on their roster instances)")
	_check(_ints(allocation["hero"]) == {"hp": 2, "str": 3, "agi": 1, "int": 2}, "AC03 Hero counts saved (HP 2 points, not +20)")
	_check(_saved_points(data, "merc_a") == {"hp": 2, "str": 4, "agi": 0, "int": 0} and _saved_points(data, "merc_b") == {"hp": 0, "str": 0, "agi": 2, "int": 4}, "AC03 Merc A / Merc B counts saved")
	_check(not (allocation["hero"] as Dictionary).has("mp"), "AC04 No MP allocation stored")
	var text := JSON.stringify(data).to_lower()
	for word in ["unspent", "earned", "growth", "effective", "capacity", "physical", "magic", "attack", "defense", "interval", "speed", "max_hp", "max_mp", "equipment"]:
		_check(not text.contains(word), "AC05-AC09 Nothing derived saved: no %s" % word)
	_check(data["character"]["stats"].keys() == ["strength"] and int(data["character"]["stats"]["strength"]) == 10, "Base STR still the only character stat")
	_check(_ints(data["progression"]["hero"]) == {"level": 4, "exp": 0}, "progression still {level, exp}")
	# C: deserialization.
	# restore_allocation replaces, never adds (repeated loads into one object).
	var twice := CharacterStats.new()
	twice.apply_level(4)
	var counts := {"hp": 1, "str": 2, "agi": 0, "int": 3}
	_check(twice.restore_allocation(counts) and twice.restore_allocation(counts) and twice.get_allocation_points() == counts and twice.get_unspent_points() == 3, "AC23 Restoring the same counts twice gives them once (6 spent, 3 left)")
	_check(not twice.restore_allocation({"hp": 0, "str": 10, "agi": 0, "int": 0}) and twice.get_allocation_points() == counts, "Restoring more than earned is refused; nothing changes")
	_check(not twice.restore_allocation({"hp": 0, "str": 1, "agi": 0}) and not twice.restore_allocation({"hp": 0, "str": -1, "agi": 0, "int": 0}), "Restore needs exactly the four counts, none negative")
	var payload := SaveStore.validate(_v10(levels, points))
	_check(not payload.is_empty() and (payload["mercenaries"] as MercenaryRoster).get_mercenary("merc_b").get_allocation_points() == {"hp": 0, "str": 0, "agi": 2, "int": 4}, "AC14 A valid v10 allocation validates exactly (P05: onto merc_b)")
	_sections_done.append("schema")


# --- D / L: v1-v9 migration, old banked EXP ----------------------------------------

func _verify_migration() -> void:
	var v10 := _v10({"hero": 4, "merc_a": 2, "merc_b": 1}, {}, 13)
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
	var v2 := {"version": 2, "money": 4321, "cargo": {"test_good_03": 4}, "market": v10["market"]}
	var v1 := {"version": 1, "money": 4321, "cargo": {"test_good_03": 4}}
	var old := {"v9": v9, "v8": v8, "v7": v7, "v6": v6, "v5": v5, "v4": v4, "v3": v3, "v2": v2, "v1": v1}
	for label in old:
		_write_json(old[label])
		var text := _read()
		var main := await _new_main()
		_check(main.wallet.get_balance() == 4321 and main.inventory.get_quantity("test_good_03") == 4, "AC10/AC32 %s: money and items preserved" % label)
		_check(SLOTS.all(func(s: String) -> bool: return _stats_of(main, s).get_allocation_points() == ZERO), "AC11 %s: every allocation 0" % label)
		var hero: CharacterStats = main.character_stats
		var expected_str := 13 if label not in ["v1", "v2"] else 10
		_check(hero.get_base_strength() == expected_str and hero.get_allocated_points("str") == 0, "R1 %s: saved strength stays Base STR %d, never allocated STR" % [label, expected_str])
		var hero_level := 4 if label == "v9" else 1
		_check(main.progression.get_level("hero") == hero_level and hero.get_unspent_points() == (hero_level - 1) * 3, "AC12 %s: Hero Lv%d, %d unspent points" % [label, hero_level, (hero_level - 1) * 3])
		_check(_read() == text, "%s: loading does not rewrite the old save" % label)
		_check(main.save_world_position() and int(JSON.parse_string(_read())["version"]) == 12, "%s: the next save writes v10 (P05: v12)" % label)
		var written: Dictionary = JSON.parse_string(_read())
		_check(SLOTS.all(func(s: String) -> bool: return _saved_points(written, s) == ZERO) and int(written["money"]) == 4321, "%s: the v10 save holds 0 allocation, the same money" % label)
		await _destroy(main)
	# L: C05 banked EXP still normalises, and the Level it reaches is the budget.
	var banked: Dictionary = v9.duplicate(true)
	banked["progression"]["hero"] = {"level": 2, "exp": 400}
	_write_json(banked)
	var main := await _new_main()
	_check(main.progression.get_level("hero") == 4 and main.progression.get_exp("hero") == 50 and main.character_stats.get_unspent_points() == 9, "AC13 v9 Lv2 + 400 banked EXP -> Lv4 50, 9 points")
	await _destroy(main)
	var banked10: Dictionary = v10.duplicate(true)
	banked10["progression"]["hero"] = {"level": 2, "exp": 400}
	banked10["allocation"]["hero"] = {"hp": 0, "str": 9, "agi": 0, "int": 0}
	_check(not SaveStore.validate(banked10).is_empty(), "R6 v10 with banked EXP: 9 points fit the normalised Lv4")
	banked10["allocation"]["hero"]["str"] = 10
	_check(SaveStore.validate(banked10).is_empty(), "R6 10 points exceed the normalised Lv4 budget")
	_delete()
	_sections_done.append("migration")


# --- E: validation ------------------------------------------------------------------

func _verify_validation() -> void:
	var good := _v10({"hero": 4, "merc_a": 2, "merc_b": 3}, {"hero": {"hp": 2, "str": 3, "agi": 1, "int": 2}})
	_check(not SaveStore.validate(good).is_empty(), "Lv4 HP 2 / STR 3 / AGI 1 / INT 2 (8 of 9): valid")
	var exact: Dictionary = good.duplicate(true)
	exact["allocation"]["hero"]["agi"] = 2
	_check(not SaveStore.validate(exact).is_empty(), "Exactly all 9 points spent: valid")
	var broken := {
		"AC26 negative": _with_entry(good, "hero", "str", -1),
		"AC27 fractional": _with_entry(good, "hero", "str", 2.5),
		"AC27 string": _with_entry(good, "hero", "str", "3"),
		"AC27 null": _with_entry(good, "hero", "str", null),
		"AC28 overspent Lv2 STR 99": _with_entry(good, "merc_a", "str", 99),
		"AC28 overspent by one": _with_entry(exact, "hero", "int", 3),
		"AC28 Lv1 with a point": _with_entry(_v10({}, {}), "merc_b", "hp", 1),
		"AC29 unknown stat": _with_extra(good, "hero", "luck", 0),
		"AC29 mp stat": _with_extra(good, "hero", "mp", 0),
		"AC30 missing stat": _without_entry(good, "hero", "int"),
		"AC30 missing character": _without_slot(good, "merc_b"),
		"AC30 extra character": _with_slot(good, "merc_c", ZERO),
		"AC30 entry not a dictionary": _with_slot(good, "hero", [0, 0, 0, 0]),
		"AC30 allocation not a dictionary": _with(good, {"allocation": []}),
		"AC30 v10 without allocation": _without(good, "allocation"),
		"v9 carrying allocation": _with(good, {"version": 9}),
		"unknown future v13": _with(good, {"version": 13}),  # P05: v12 is current
	}
	for label in broken:
		_check(SaveStore.validate(broken[label]).is_empty(), "%s: the whole save is rejected" % label)
	# AC31: nothing clamped or repaired - an invalid file is left as it is and the game starts fresh.
	_write_json(broken["AC28 overspent Lv2 STR 99"])
	var text := _read()
	_check(SaveStore.load_session(TEST_SAVE).is_empty() and _read() == text, "AC31 Overspent v10 save: refused, file untouched (no clamping)")
	var whole: Dictionary = good.duplicate(true)
	whole["allocation"]["hero"]["str"] = 3.0
	_check(_ints(SaveStore.validate(whole)["allocation"]["hero"]) == {"hp": 2, "str": 3, "agi": 1, "int": 2}, "A JSON whole number (3.0) is an integer")
	_delete()
	_sections_done.append("validation")


# --- F / G / H / I / J: three characters, round trip, repeated, combat, Capacity ----

func _verify_round_trip() -> void:
	_delete()
	var main := await _new_main()
	# P05: Merc A / Merc B are the roster's merc_a / merc_b (deployed, so the
	# battle below takes them: P04).
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_a", "GUARDIAN"), Mercenary.create("merc_b", "MAGE")], ["merc_a", "merc_b"])
	_level(main, {"hero": 4, "merc_a": 3, "merc_b": 5})
	_check(main.character_stats.confirm_allocation({"hp": 1, "str": 3, "int": 2}) and PartyService.allocate(main.mercenary_roster, "merc_a", {"hp": 2, "str": 4})["success"] and PartyService.allocate(main.mercenary_roster, "merc_b", {"agi": 2, "int": 4})["success"], "F Hero / Merc A / Merc B confirm their own Builds")
	var before := _snapshot(main)
	_check(main.save_world_position(), "Saved")
	var file_1 := _read()
	await _destroy(main)
	main = await _new_main()
	var after := _snapshot(main)
	for slot in SLOTS:
		for key in ["level", "exp", "alloc", "growth", "effective", "derived", "unspent"]:
			_check(after[slot][key] == before[slot][key], "G %s %s equal after restart (%s)" % [slot, key, str(after[slot][key])])
	_check(after["backpack"] == before["backpack"] and after["backpack"] == 10 + (10 + 3 + 3) * 9, "AC20 Capacity after restart: 154 through Effective STR 16")
	_check((main.get_party_stats()["hero"] as CharacterStats) == main.character_stats and main.inventory.get_stats() == main.character_stats and main.get_party_stats().keys() == ["hero"], "The restored Hero is the backpack's stats")
	# I: the restored Build fights.
	var battle := await _locked_battle(main)
	var units := battle.get_friends()
	var fights := true
	for index in range(3):
		var stats: CharacterStats = _stats_of(main, SLOTS[index])
		var unit: CombatUnit = units[index]
		fights = fights and unit.max_hp == stats.get_max_hp() and unit.max_mp == stats.get_max_mp() and unit.attack_damage == stats.get_physical_attack() and unit.physical_defense == stats.get_physical_defense() and unit.magic_attack == stats.get_magic_attack() and unit.attack_interval_ms == stats.get_attack_interval_ms() and unit.move_speed == stats.get_move_speed()
	_check(fights, "AC21 The next battle uses the restored Builds")
	_check(units[1].id == "merc_a" and units[2].id == "merc_b", "P04 The Mercenary units are the restored roster instances (P05: merc_a / merc_b)")
	_check(units[0].attack_damage == 20 + 3 + 3 and units[1].max_hp == 200 + 50 + 20 and units[2].magic_attack == (8 + 4) * 2, "AC21 Hero ATK 26, Merc A Max HP 270, Merc B MATK 24")
	for enemy in battle.get_enemies():
		battle.resolve_damage(units[0], enemy, 1000)
	((main.get_node("CombatView") as CombatView).get_node("ExitButton") as Button).pressed.emit()
	await process_frame
	_check(_snapshot(main)["hero"]["alloc"] == before["hero"]["alloc"], "The settlement keeps the restored allocation")
	# H: repeated save / load.
	var reference := _snapshot(main)
	var files := []
	for round in range(3):
		main.save_world_position()
		files.append(_read())
		await _destroy(main)
		main = await _new_main()
		var again := _snapshot(main)
		var same := true
		for slot in SLOTS:
			for key in ["alloc", "growth", "effective", "derived", "unspent", "level", "exp"]:
				same = same and again[slot][key] == reference[slot][key]
		_check(same and again["backpack"] == reference["backpack"], "AC23-AC25 Round %d: no duplicated allocation, regenerated points, stacked Growth or Capacity" % (round + 1))
	var allocations := files.map(func(f: String) -> Variant: return _saved_allocations(JSON.parse_string(f)))
	_check(allocations[0] == allocations[1] and allocations[1] == allocations[2], "AC23 The saved allocation is identical every round")
	_check(_saved_allocations(JSON.parse_string(file_1)) == allocations[0], "The first save already held the same allocation")
	await _destroy(main)
	_delete()
	_sections_done.append("round_trip")


# --- K: an unconfirmed preview is never saved ---------------------------------------

func _verify_preview_exclusion() -> void:
	_delete()
	var main := await _new_main()
	_level(main, {"hero": 3})
	var panel := main.get_node("CharacterPanel") as CharacterPanel
	_check(panel.open(), "Character UI open")
	panel.press_plus("str")
	panel.press_plus("str")
	_check(panel.confirm(), "STR +2 confirmed")
	# Codex review on #110: the confirmation itself is saved (no move, no other save).
	var confirmed_save: Variant = JSON.parse_string(_read())
	_check(confirmed_save != null and _ints(confirmed_save["allocation"]["hero"]) == {"hp": 0, "str": 2, "agi": 0, "int": 0}, "Confirming saves at once (STR 2 on disk before any other save)")
	panel.press_plus("int")
	_check(panel.get_pending() == {"int": 1}, "INT +1 still a preview")
	_check(main.save_world_position(), "A save happens during the preview")
	var saved: Dictionary = JSON.parse_string(_read())
	_check(_ints(saved["allocation"]["hero"]) == {"hp": 0, "str": 2, "agi": 0, "int": 0}, "AC22 The save holds STR 2 and no INT")
	await _destroy(main)
	main = await _new_main()
	var hero: CharacterStats = main.character_stats
	_check(hero.get_allocated_points("str") == 2 and hero.get_allocated_points("int") == 0 and hero.get_unspent_points() == 4, "AC22 After restart: STR +2, no INT +1, 4 points left")
	var reopened := main.get_node("CharacterPanel") as CharacterPanel
	reopened.open()
	_check(reopened.get_pending().is_empty() and " | ".join(reopened.get_lines()).contains("力量 14") and " | ".join(reopened.get_lines()).contains("未分配屬性點 4"), "AC33 The Character UI shows the restored Build, no preview")
	await _destroy(main)
	_delete()
	_sections_done.append("preview")


# --- helpers ------------------------------------------------------------------------

func _level(main: Node, levels: Dictionary) -> void:
	for slot in levels:
		var total := 0
		for level in range(1, int(levels[slot])):
			total += ProgressionState.required_exp(level)
		var result := BattleResult.create("s05", BattleResult.Outcome.VICTORY, [] as Array[String])
		result.exp_pool = total
		result.survivor_ids.append(slot)
		# P05: the Hero's slot or the roster instance (PartyProgression).
		PartyProgression.apply(result, main.progression, main.mercenary_roster)
	main._apply_level_growth()


func _snapshot(main: Node) -> Dictionary:
	var out := {}
	for slot in SLOTS:
		var s: CharacterStats = _stats_of(main, slot)
		var growth := []
		var effective := []
		for stat in CharacterConfig.STATS:
			growth.append(s.get_growth(stat))
			effective.append(s.get_effective(stat))
		out[slot] = {
			"level": _level_of(main, slot),
			"exp": _exp_of(main, slot),
			"alloc": s.get_allocation_points(),
			"growth": growth,
			"effective": effective,
			"derived": [s.get_max_hp(), s.get_max_mp(), s.get_physical_attack(), s.get_magic_attack(), s.get_physical_defense(), s.get_magic_defense(), s.get_attack_interval_ms(), s.get_move_speed(), s.get_max_capacity()],
			"unspent": s.get_unspent_points(),
		}
	out["backpack"] = main.inventory.get_max_capacity()
	return out


func _ints(data: Variant) -> Dictionary:
	var out := {}
	if typeof(data) != TYPE_DICTIONARY:
		return out
	for key in data:
		out[key] = int(data[key])
	return out


func _with(data: Dictionary, changes: Dictionary) -> Dictionary:
	var copy := data.duplicate(true)
	for key in changes:
		copy[key] = changes[key]
	return copy


func _without(data: Dictionary, key: String) -> Dictionary:
	var copy := data.duplicate(true)
	copy.erase(key)
	return copy


func _with_entry(data: Dictionary, slot: String, stat: String, value: Variant) -> Dictionary:
	var copy := data.duplicate(true)
	copy["allocation"][slot][stat] = value
	return copy


func _with_extra(data: Dictionary, slot: String, stat: String, value: Variant) -> Dictionary:
	return _with_entry(data, slot, stat, value)


func _without_entry(data: Dictionary, slot: String, stat: String) -> Dictionary:
	var copy := data.duplicate(true)
	(copy["allocation"][slot] as Dictionary).erase(stat)
	return copy


func _without_slot(data: Dictionary, slot: String) -> Dictionary:
	var copy := data.duplicate(true)
	(copy["allocation"] as Dictionary).erase(slot)
	return copy


func _with_slot(data: Dictionary, slot: String, value: Variant) -> Dictionary:
	var copy := data.duplicate(true)
	copy["allocation"][slot] = value
	return copy


func _wallet(amount: int) -> Wallet:
	var wallet := Wallet.new()
	var difference := amount - wallet.get_balance()
	if difference > 0:
		wallet.add(difference)
	elif difference < 0:
		wallet.spend(-difference)
	return wallet


func _locked_battle(main: Node) -> CombatBattle:
	(main.get_node("Actors/Player") as Player).global_position = PASSIVE_ONLY
	for frame in range(4):
		await physics_frame
	await process_frame
	(main.get_node("EncounterSession") as EncounterSession).challenge()
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	var battle: CombatBattle = main.get_combat()
	battle.advance(CombatConfig.PREPARATION_MS)
	return battle


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


func _write_json(data: Dictionary) -> void:
	var file := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()


func _read() -> String:
	return FileAccess.get_file_as_string(TEST_SAVE)


func _delete() -> void:
	if FileAccess.file_exists(TEST_SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
