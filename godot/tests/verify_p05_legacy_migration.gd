extends SceneTree

## Stage 8 P05: Legacy Mercenary Migration & Final Integration (Save v12).
##   schema       v12 = v11 + pending_legacy_mercenaries; progression /
##                allocation hold the Hero only; nothing derived
##   versions     v1-v11 each migrate Merc A / Merc B (merc_a GUARDIAN, merc_b
##                MAGE, exact Level / EXP / allocation, waiting); v12 loads as
##                it is; v13+ / corrupt / invalid are unreadable
##   capacity     v11 roster 0-5 x legacy growth: owned never above 5, the
##                rest pending; next_serial untouched; consistent / conflicting
##                merc_a / merc_b already owned
##   idempotence  v<=11 -> v12 -> v12 never converts twice
##   v12 rules    old three-slot sections and every malformed pending list
##                reject the whole save
##   claim        1 / 2 places, full, twice, save failure rollback, restart,
##                claimed then dismissed never comes back
##   game         notice, 暫存傳承傭兵 section, 領取 (disabled when full),
##                Character UI (Hero + 0-5, scrolling tabs, Mercenary
##                allocation transaction), legacy tabs gone
##   protection   corrupt / invalid / future save: kept byte for byte, backed
##                up (never over another backup), saving locked, warning
##   + scope, seeded stress
## Real SaveStore files, the real main scene with a fixed TimeSource.

const TEST_SAVE := "user://p05_legacy_migration_test.json"
const BAD_SAVE := "user://p05_missing_dir/save.json"
const T0 := 1800000000000
const LEGACY := ["merc_a", "merc_b"]

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_clean()
	_verify_schema()
	_verify_versions()
	_verify_capacity()
	_verify_existing_legacy()
	_verify_idempotence()
	_verify_v12_rules()
	_verify_claim_service()
	await _verify_game_notice_and_claim()
	await _verify_character_ui()
	await _verify_protection()
	_verify_scope()
	_verify_stress()
	_clean()
	_check(_sections_done.size() == 12, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("P05 legacy migration verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Schema ---------------------------------------------------------------------------------------------

func _verify_schema() -> void:
	_check(SaveStore.VERSION == 14 and SaveStore.INVENTORY_VERSIONS == [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14], "AC01 Save v12 (Stage 9 P01: v13 is current)")
	_check(SaveStore.V12_KEYS == SaveStore.V11_KEYS + ["pending_legacy_mercenaries"], "v12 = v11 + pending_legacy_mercenaries")
	_check(ProgressionState.SLOTS == ["hero"] and ProgressionState.LEGACY_SLOTS == ["hero", "merc_a", "merc_b"], "Runtime progression: the Hero only; the three slots are legacy (read only)")
	var roster := MercenaryRoster.build([Mercenary.create("merc_1", "MAGE", 3, 20, _pts(1, 0, 0, 2))], ["merc_1"])
	roster.pend_legacy(Mercenary.create("merc_b", "MAGE", 2, 5, _pts(0, 0, 3, 0)))
	var data := _v12(roster, [4, 30], _pts(2, 3, 1, 3))
	_check(int(data["version"]) == 12 and data.keys().size() == 12, "A v12 save has 12 sections (Stage 9 P01: v13 adds carrying)")
	_check(data["progression"] == _json({"hero": {"level": 4, "exp": 30}}) and _ints(data["allocation"]["hero"]) == _pts(2, 3, 1, 3) and data["allocation"].keys() == ["hero"], "AC02 progression / allocation: the Hero only")
	_check(data["pending_legacy_mercenaries"] == _json([{"id": "merc_b", "type": "MAGE", "level": 2, "exp": 5, "allocation": _pts(0, 0, 3, 0)}]), "Pending: complete Mercenary data, nothing derived")
	_check((data["mercenaries"] as Dictionary).keys().size() == 3, "The roster section unchanged (owned / deployed / next_serial)")
	var text := JSON.stringify(data)
	for word in ["max_hp", "attack", "defense", "growth", "effective", "capacity", "unspent", "merc_stats"]:
		_check(not text.contains(word), "Nothing derived saved: no %s" % word)
	_sections_done.append("schema")


# --- Versions -------------------------------------------------------------------------------------------------

func _verify_versions() -> void:
	var levels := {"hero": [4, 30], "merc_a": [3, 40], "merc_b": [2, 7]}
	var points := {"hero": _pts(2, 3, 1, 3), "merc_a": _pts(4, 0, 0, 2), "merc_b": _pts(0, 0, 3, 0)}
	var saves := _all_versions(levels, points, MercenaryRoster.new())
	# Expected legacy data per version (v1-v8 Lv1; v9 Level / EXP; v10+ all).
	for version in range(1, 12):
		var loaded := _load(saves[version])
		_check(not loaded.is_empty(), "AC03 v%d loads" % version)
		if loaded.is_empty():
			continue
		var roster: MercenaryRoster = loaded["mercenaries"]
		var a := roster.get_mercenary("merc_a")
		var b := roster.get_mercenary("merc_b")
		var expected_a := [1, 0, _pts(0, 0, 0, 0)] if version <= 8 else ([3, 40, _pts(0, 0, 0, 0)] if version == 9 else [3, 40, points["merc_a"]])
		var expected_b := [1, 0, _pts(0, 0, 0, 0)] if version <= 8 else ([2, 7, _pts(0, 0, 0, 0)] if version == 9 else [2, 7, points["merc_b"]])
		_check(a != null and a.get_type() == "GUARDIAN" and [a.get_level(), a.get_exp(), a.get_allocation_points()] == expected_a, "AC03 v%d: merc_a -> GUARDIAN %s" % [version, str(expected_a)])
		_check(b != null and b.get_type() == "MAGE" and [b.get_level(), b.get_exp(), b.get_allocation_points()] == expected_b, "AC03 v%d: merc_b -> MAGE %s" % [version, str(expected_b)])
		_check(roster.get_owned().map(func(m: Mercenary) -> String: return m.get_id()) == ["merc_a", "merc_b"] and roster.get_deployed_ids().is_empty() and roster.get_pending().is_empty() and roster.get_next_serial() == 1, "AC04 v%d: A then B owned, waiting, nothing pending, next_serial 1" % version)
		_check(loaded["migration"] == {"owned": ["merc_a", "merc_b"], "pending": []}, "v%d: the migration report" % version)
		var hero: ProgressionState = loaded["progression"]
		var hero_level := 1 if version <= 8 else 4
		_check(hero.to_dict() == {"hero": {"level": hero_level, "exp": 0 if version <= 8 else 30}} and loaded["allocation"].keys() == ["hero"], "v%d: the Hero's progression only (Lv%d)" % [version, hero_level])
		_check(loaded["wallet"].get_balance() == 4321 and loaded["inventory"].get_quantity("test_good_03") == 4, "v%d: money and items preserved" % version)
		_check(roster.create_mercenary("MAGE").get_id() == "merc_1", "AC04 v%d: the next recruit is still merc_1 (legacy ids use no serial)" % version)
	# v12 loads as it is (never migrated).
	var v12 := _load(saves[12])
	_check(not v12.is_empty() and (v12["mercenaries"] as MercenaryRoster).get_owned_count() == 0 and v12["migration"] == {"owned": [], "pending": []}, "AC05 v12 loads as it is: no conversion")
	# v13 / future, corrupt, invalid.
	var future: Dictionary = saves[12].duplicate(true)
	future["version"] = 15  # Stage 10 P00: v14 is current
	_check(SaveStore.validate(_json(future)).is_empty(), "AC06 v13 is refused")
	_sections_done.append("versions")


# --- Capacity --------------------------------------------------------------------------------------------

func _verify_capacity() -> void:
	var growths := {
		"both Lv1": {"merc_a": [1, 0], "merc_b": [1, 0]},
		"A grown": {"merc_a": [5, 90], "merc_b": [1, 0]},
		"B grown": {"merc_a": [1, 0], "merc_b": [7, 3]},
		"both grown": {"merc_a": [4, 12], "merc_b": [6, 0]},
	}
	var allocations := {
		"both Lv1": {"merc_a": _pts(0, 0, 0, 0), "merc_b": _pts(0, 0, 0, 0)},
		"A grown": {"merc_a": _pts(3, 4, 2, 1), "merc_b": _pts(0, 0, 0, 0)},
		"B grown": {"merc_a": _pts(0, 0, 0, 0), "merc_b": _pts(0, 1, 5, 12)},
		"both grown": {"merc_a": _pts(0, 9, 0, 0), "merc_b": _pts(1, 1, 1, 1)},
	}
	for size in range(6):
		for growth in growths:
			var roster := _recruited(size)
			var serial := roster.get_next_serial()
			var levels := {"hero": [2, 0], "merc_a": growths[growth]["merc_a"], "merc_b": growths[growth]["merc_b"]}
			var points := {"hero": _pts(0, 0, 0, 0), "merc_a": allocations[growth]["merc_a"], "merc_b": allocations[growth]["merc_b"]}
			var loaded := _load(_all_versions(levels, points, roster)[11])
			var name := "v11 roster %d, %s" % [size, growth]
			_check(not loaded.is_empty(), "%s loads" % name)
			if loaded.is_empty():
				continue
			var result: MercenaryRoster = loaded["mercenaries"]
			var owned_ids := result.get_owned().map(func(m: Mercenary) -> String: return m.get_id())
			var pending_ids := result.get_pending().map(func(m: Mercenary) -> String: return m.get_id())
			var expected_owned := LEGACY.slice(0, maxi(0, mini(2, 5 - size)))
			var expected_pending := LEGACY.slice(expected_owned.size())
			_check(result.get_owned_count() == mini(5, size + 2) and result.get_owned_count() <= MercenaryRoster.MAX_OWNED, "AC07 %s: %d owned (never above 5)" % [name, result.get_owned_count()])
			_check(owned_ids.slice(size) == expected_owned and pending_ids == expected_pending, "AC07 %s: owned +%s, pending %s" % [name, str(expected_owned), str(expected_pending)])
			_check(owned_ids.slice(0, size) == _recruited(size).get_owned().map(func(m: Mercenary) -> String: return m.get_id()), "%s: the existing roster kept, in order" % name)
			var all_ids := owned_ids + pending_ids
			var unique := {}
			for id in all_ids:
				unique[id] = true
			_check(unique.size() == all_ids.size() and all_ids.size() == size + 2, "AC08 %s: every id once (%d)" % [name, all_ids.size()])
			for id in LEGACY:
				var mercenary := result.get_mercenary(id) if result.get_mercenary(id) != null else result.get_pending_mercenary(id)
				_check(mercenary != null and [mercenary.get_level(), mercenary.get_exp(), mercenary.get_allocation_points()] == [growths[growth][id][0], growths[growth][id][1], allocations[growth][id]], "AC09 %s: %s Level / EXP / allocation exact" % [name, id])
			_check(result.get_next_serial() == serial and result.get_deployed_ids() == ([] as Array[String]) and not LEGACY.any(func(id: String) -> bool: return result.is_deployed(id)), "AC10 %s: next_serial %d unchanged, nothing deployed" % [name, serial])
	# A deployed v11 roster keeps its deployment.
	var deployed := _recruited(3)
	deployed.set_deployment(["merc_2", "merc_3"])
	var kept := _load(_all_versions(_levels([1, 0], [2, 0], [2, 0]), _points(), deployed)[11])
	_check((kept["mercenaries"] as MercenaryRoster).get_deployed_ids() == ["merc_2", "merc_3"], "The existing deployment kept; A / B waiting")
	_sections_done.append("capacity")


# --- merc_a / merc_b already owned in a v11 roster ---------------------------------------------------

func _verify_existing_legacy() -> void:
	var levels := _levels([1, 0], [3, 40], [2, 7])
	var points := {"hero": _pts(0, 0, 0, 0), "merc_a": _pts(4, 0, 0, 2), "merc_b": _pts(0, 0, 3, 0)}
	for id in LEGACY:
		var type: String = MercenaryRoster.LEGACY_TYPES[id]
		var same := Mercenary.create(id, type, levels[id][0], levels[id][1], points[id])
		var roster := MercenaryRoster.build([Mercenary.create("merc_1", "MAGE"), same])
		var loaded := _load(_all_versions(levels, points, roster)[11])
		var other: String = "merc_b" if id == "merc_a" else "merc_a"
		_check(not loaded.is_empty() and (loaded["mercenaries"] as MercenaryRoster).get_owned().map(func(m: Mercenary) -> String: return m.get_id()) == ["merc_1", id, other] and loaded["migration"]["owned"] == [other], "AC11 Consistent %s already owned: kept once, only %s added" % [id, other])
		var conflicts := {
			"Level": Mercenary.create(id, type, levels[id][0] + 1, 0, points[id]),
			"EXP": Mercenary.create(id, type, levels[id][0], levels[id][1] + 1, points[id]),
			"allocation": Mercenary.create(id, type, levels[id][0], levels[id][1], _pts(0, 0, 0, 0)),
			"type": Mercenary.create(id, "STRATEGIST", levels[id][0], levels[id][1], points[id]),
		}
		for what in conflicts:
			var conflicting := MercenaryRoster.build([conflicts[what]])
			_check(conflicting != null and _load(_all_versions(levels, points, conflicting)[11]).is_empty(), "AC12 Conflicting %s (%s differs): the whole save is refused" % [id, what])
	_sections_done.append("existing_legacy")


# --- Idempotence ----------------------------------------------------------------------------------------

func _verify_idempotence() -> void:
	for size in [0, 3, 4, 5]:
		var source: Dictionary = _all_versions(_levels([3, 0], [4, 10], [2, 20]), _points(), _recruited(size))[11]
		var first := _load(source)
		var again := _load(source)
		_check(_state(first) == _state(again), "AC13 v11 roster %d: the same fixed result every load" % size)
		var v12 := _rewrite(first)
		var reloaded := _load(v12)
		_check(int(v12["version"]) == 14 and _state(reloaded) == _state(first) and reloaded["migration"] == {"owned": [], "pending": []}, "AC13 roster %d: v12 reload = the migrated state, nothing converted again" % size)
		var v12_again := _rewrite(reloaded)
		_check(JSON.stringify(v12_again) == JSON.stringify(v12) and _state(_load(v12_again)) == _state(first), "AC13 roster %d: save / load / save is stable" % size)
		var count: int = (reloaded["mercenaries"] as MercenaryRoster).get_owned_count() + (reloaded["mercenaries"] as MercenaryRoster).get_pending().size()
		_check(count == size + 2, "AC13 roster %d: A / B exist exactly once (%d)" % [size, count])
	_sections_done.append("idempotence")


# --- v12 rules ------------------------------------------------------------------------------------------

func _verify_v12_rules() -> void:
	var roster := _recruited(5)
	roster.pend_legacy(Mercenary.create("merc_a", "GUARDIAN", 3, 0, _pts(1, 1, 0, 0)))
	var good := _v12(roster, [2, 0], _pts(1, 0, 0, 0))
	_check(not _load(good).is_empty(), "A valid v12 loads")
	var a := {"id": "merc_a", "type": "GUARDIAN", "level": 1, "exp": 0, "allocation": _pts(0, 0, 0, 0)}
	var b := {"id": "merc_b", "type": "MAGE", "level": 1, "exp": 0, "allocation": _pts(0, 0, 0, 0)}
	var three_progression := {"hero": {"level": 2, "exp": 0}, "merc_a": {"level": 1, "exp": 0}, "merc_b": {"level": 1, "exp": 0}}
	var three_allocation := {"hero": _pts(1, 0, 0, 0), "merc_a": _pts(0, 0, 0, 0), "merc_b": _pts(0, 0, 0, 0)}
	var bad := {
		"three-slot progression": _with(good, {"progression": three_progression}),
		"three-slot allocation": _with(good, {"allocation": three_allocation}),
		"no Hero progression": _with(good, {"progression": {}}),
		"pending missing": _without(good, "pending_legacy_mercenaries"),
		"pending not a list": _with(good, {"pending_legacy_mercenaries": {}}),
		"pending numeric id": _with(good, {"pending_legacy_mercenaries": [{"id": "merc_9", "type": "MAGE", "level": 1, "exp": 0, "allocation": _pts(0, 0, 0, 0)}]}),
		"pending wrong type": _with(good, {"pending_legacy_mercenaries": [{"id": "merc_a", "type": "MAGE", "level": 1, "exp": 0, "allocation": _pts(0, 0, 0, 0)}]}),
		"pending twice": _with(good, {"pending_legacy_mercenaries": [a, a]}),
		"pending three": _with(good, {"pending_legacy_mercenaries": [a, b, a]}),
		"pending malformed": _with(good, {"pending_legacy_mercenaries": [{"id": "merc_a", "type": "GUARDIAN", "level": 1}]}),
		"pending overspent": _with(good, {"pending_legacy_mercenaries": [{"id": "merc_a", "type": "GUARDIAN", "level": 1, "exp": 0, "allocation": _pts(1, 0, 0, 0)}]}),
		"pending derived field": _with(good, {"pending_legacy_mercenaries": [{"id": "merc_a", "type": "GUARDIAN", "level": 1, "exp": 0, "allocation": _pts(0, 0, 0, 0), "max_hp": 200}]}),
		"pending also owned": _with(_v12(MercenaryRoster.build([Mercenary.create("merc_a", "GUARDIAN")]), [1, 0], _pts(0, 0, 0, 0)), {"pending_legacy_mercenaries": [a]}),
		"pending also deployed": _with(_v12(MercenaryRoster.build([Mercenary.create("merc_a", "GUARDIAN")], ["merc_a"]), [1, 0], _pts(0, 0, 0, 0)), {"pending_legacy_mercenaries": [a]}),
		"extra section": _with(good, {"legacy": []}),
	}
	for name in bad:
		_check(_load(bad[name]).is_empty(), "AC14 v12 %s: the whole save is refused" % name)
	_check(not MercenaryRoster.new().pend_legacy(Mercenary.create("merc_1", "MAGE")) and not MercenaryRoster.new().pend_legacy(null), "Only legacy ids can be pending")
	var full := _recruited(5)
	full.pend_legacy(_legacy("merc_a", 2))
	_check(not full.claim_pending("merc_a") and full.get_owned_count() == 5 and full.get_pending_mercenary("merc_a") != null, "The roster itself refuses a claim while full (never 6 owned)")
	_sections_done.append("v12_rules")


# --- Claim (service) ------------------------------------------------------------------------------------

func _verify_claim_service() -> void:
	for free in [1, 2]:
		var roster := _recruited(5 - free)
		_check(roster.pend_legacy(_legacy("merc_a", 4)) and roster.pend_legacy(_legacy("merc_b", 6)), "Two pending")
		var serial := roster.get_next_serial()
		var saves := [0]
		var persist := func() -> bool:
			saves[0] += 1
			return true
		var first := PartyService.claim_pending(roster, "merc_a", persist)
		var claimed := roster.get_mercenary("merc_a")
		_check(first["success"] and claimed != null and roster.get_pending_mercenary("merc_a") == null and claimed.get_level() == 4 and claimed.get_allocation_points() == _pts(1, 2, 3, 3) and not roster.is_deployed("merc_a") and saves[0] == 1, "AC15 %d free: 守衛（傳承） claimed — moved, data kept, waiting, saved" % free)
		var second := PartyService.claim_pending(roster, "merc_b", persist)
		if free == 2:
			_check(second["success"] and roster.get_owned_count() == 5 and roster.get_pending().is_empty(), "AC15 2 free: both claimed (5 owned)")
		else:
			_check(not second["success"] and second["reason"] == PartyService.ERR_ROSTER_FULL and roster.get_pending_mercenary("merc_b") != null and roster.get_owned_count() == 5 and saves[0] == 1, "AC16 Full: claim refused, 傭兵人數已達上限, nothing saved")
		_check(not PartyService.claim_pending(roster, "merc_a", persist)["success"] and roster.get_owned().filter(func(m: Mercenary) -> bool: return m.get_id() == "merc_a").size() == 1, "AC17 Claimed once only")
		_check(roster.get_next_serial() == serial, "next_serial unchanged by claims")
	# Save failure: everything restored.
	var failing := _recruited(3)
	failing.set_deployment(["merc_1"])
	failing.pend_legacy(_legacy("merc_a", 2))
	failing.pend_legacy(_legacy("merc_b", 3))
	var removed := failing.create_mercenary("MAGE")
	failing.remove(removed.get_id())
	var before := JSON.stringify(failing.get_snapshot())
	var failed := PartyService.claim_pending(failing, "merc_b", func() -> bool: return false)
	_check(not failed["success"] and failed["reason"] == PartyService.ERR_SAVE_FAILED and JSON.stringify(failing.get_snapshot()) == before, "AC18 Save failure: pending, owned, deployed, next_serial and retired ids restored")
	_check(failing.create_mercenary("MAGE").get_id() == "merc_5" and failing.get_pending_mercenary("merc_b") != null, "Retired merc_4 stays retired after the rollback")
	for id in [null, "", "merc_1", "merc_9", "hero"]:
		_check(not PartyService.claim_pending(failing, id)["success"], "Unknown pending id %s refused" % str(id))
	# A pending one is not owned: no deployment, dismissal, points or battle.
	var waiting := JSON.stringify(failing.get_snapshot())
	_check(not PartyService.set_deployed(failing, "merc_a", true)["success"] and not PartyService.dismiss(failing, "merc_a")["success"] and not PartyService.allocate(failing, "merc_a", {"hp": 1})["success"] and not failing.set_deployment(["merc_a"]) and JSON.stringify(failing.get_snapshot()) == waiting, "AC17 Pending: cannot be deployed, dismissed or given points; nothing changes")
	_check(CombatBattle.create_party(10, null, failing.get_deployed()).get_friends().all(func(u: CombatUnit) -> bool: return u.id != "merc_a" and u.id != "merc_b") and failing.get_owned_count() == 4, "AC17 Pending never fights and takes no owned place")
	# Claimed then dismissed: never back, also after save / load.
	var gone := _recruited(1)
	gone.pend_legacy(_legacy("merc_a", 2))
	PartyService.claim_pending(gone, "merc_a")
	PartyService.dismiss(gone, "merc_a")
	_check(gone.get_mercenary("merc_a") == null and gone.get_pending_mercenary("merc_a") == null and not gone.pend_legacy(_legacy("merc_a", 2)) and not gone.add(_legacy("merc_a", 2)), "AC19 Claimed then dismissed: retired in the session")
	var reloaded: MercenaryRoster = _load(_v12(gone, [1, 0], _pts(0, 0, 0, 0)))["mercenaries"]
	_check(reloaded.get_mercenary("merc_a") == null and reloaded.get_pending().is_empty(), "AC19 ... and after save / reload (v12 never migrates again)")
	# Mercenary allocation transaction.
	var build := MercenaryRoster.build([Mercenary.create("merc_a", "GUARDIAN", 3, 0)])
	var snapshot := JSON.stringify(build.get_snapshot())
	_check(not PartyService.allocate(build, "merc_a", {"str": 2}, func() -> bool: return false)["success"] and JSON.stringify(build.get_snapshot()) == snapshot, "AC20 Allocation save failure: restored")
	_check(PartyService.allocate(build, "merc_a", {"str": 2, "hp": 1}, func() -> bool: return true)["success"] and build.get_mercenary("merc_a").get_allocation_points() == _pts(1, 2, 0, 0), "AC20 Allocation saved")
	_check(not PartyService.allocate(build, "merc_a", {"str": 9})["success"] and not PartyService.allocate(build, "merc_9", {"str": 1})["success"], "Overspend / unknown refused")
	_sections_done.append("claim_service")


# --- Game: notice, pending section, claim ---------------------------------------------------------------

func _verify_game_notice_and_claim() -> void:
	_clean()
	_write_json(_all_versions(_levels([2, 0], [3, 40], [2, 7]), {"hero": _pts(0, 0, 0, 0), "merc_a": _pts(4, 0, 0, 2), "merc_b": _pts(0, 0, 3, 0)}, _recruited(4))[11])
	var original := FileAccess.get_file_as_bytes(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	var notice: NoticeModal = main.get_load_notice_modal()
	_check(notice.is_showing() and notice.get_title() == "傭兵資料已整理", "AC21 The migration notice shows")
	var lines: PackedStringArray = notice.get_lines()
	_check(Array(lines) == ["守衛（傳承）　Lv.3 已加入傭兵中心（待命）", "法師（傳承）　Lv.2 已暫存：傭兵人數已達上限，空出名額後可於傭兵中心領取", "以上變更會在下次儲存遊戲時保存。"], "AC21 Notice lines say exactly what happened, not yet saved (%s)" % str(lines))
	_check(FileAccess.get_file_as_bytes(TEST_SAVE) == original, "Loading alone does not rewrite the v11 file")
	(notice.get_node("Dim/NoticePanel/OkButton") as Button).pressed.emit()
	_check(not notice.is_showing(), "知道了 closes it")
	var hub := main.get_node("CityHub") as CityHub
	await _enter_city(main)
	_check(int(JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))["version"]) == 14, "The next normal save writes v12")
	hub.show_facility(CityHub.FACILITY_MERCENARY)
	hub.show_mercenary_view(CityHub.MERCENARY_VIEW_ROSTER)
	await process_frame
	var texts := hub.get_pending_texts()
	_check(texts["title"] == "暫存傳承傭兵" and texts["rows"] == {"merc_b": "法師（傳承）　Lv.2"} and texts["hint"] == "傭兵人數已達上限，請先解僱一名傭兵" and hub.get_claim_button("merc_b").disabled, "AC22 Full roster: 暫存傳承傭兵 法師（傳承） Lv.2, 領取 disabled, hint")
	var canvas := Rect2(0.0, 0.0, 720.0, 1280.0)
	_check(canvas.encloses((hub.get_node("Center/Content") as Control).get_global_rect()) and canvas.encloses(hub.get_claim_button("merc_b").get_global_rect()), "AC22 5 owned + the pending section fit 720 x 1280 (the list scrolls) (%s)" % str((hub.get_node("Center/Content") as Control).get_global_rect()))
	_check(hub.get_roster_ids().has("merc_a") and hub.get_roster_row_texts("merc_a")["TitleLabel"].begins_with("守衛（傳承）　Lv.3") and not hub.get_roster_ids().has("merc_b"), "守衛（傳承） in 我的傭兵; the pending one is not a roster row")
	hub.get_claim_button("merc_b").pressed.emit()
	_check(main.mercenary_roster.get_pending_mercenary("merc_b") != null, "A disabled 領取 claims nothing")
	_check(main.dismiss_mercenary("merc_1")["success"], "Dismiss one (a place frees)")
	await process_frame
	_check(not hub.get_claim_button("merc_b").disabled and hub.get_pending_texts()["hint"] == "", "AC22 A free place: 領取 enabled")
	# Save failure: rolled back, message.
	main.save_path = BAD_SAVE
	hub.get_claim_button("merc_b").pressed.emit()
	await process_frame
	_check(main.mercenary_roster.get_pending_mercenary("merc_b") != null and main.mercenary_roster.get_mercenary("merc_b") == null and hub.get_feedback_text() == "無法儲存，領取已取消", "AC23 Claim save failure: rolled back, 無法儲存，領取已取消")
	main.save_path = TEST_SAVE
	var button := hub.get_claim_button("merc_b")
	button.pressed.emit()
	button.pressed.emit()
	button.pressed.emit()
	await process_frame
	_check(main.mercenary_roster.get_mercenary("merc_b") != null and main.mercenary_roster.get_pending().is_empty() and main.mercenary_roster.get_owned_count() == 5 and hub.get_feedback_text() == "已領取法師（傳承）" and hub.get_pending_ids().is_empty(), "AC24 Three taps claim once; 已領取法師（傳承）")
	_check(not main.mercenary_roster.is_deployed("merc_b") and main.mercenary_roster.get_mercenary("merc_b").get_level() == 2 and main.mercenary_roster.get_mercenary("merc_b").get_allocation_points() == _pts(0, 0, 3, 0), "Claimed waiting with its data")
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(main.mercenary_roster.get_mercenary("merc_b") != null and main.mercenary_roster.get_pending().is_empty() and not main.get_load_notice_modal().is_showing(), "AC25 Restart: claimed kept, no notice (v12)")
	await _enter_city(main)
	_check(main.dismiss_mercenary("merc_b")["success"], "Dismiss the claimed one")
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(main.mercenary_roster.get_mercenary("merc_b") == null and main.mercenary_roster.get_pending_mercenary("merc_b") == null, "AC25 Claimed then dismissed: never back after a restart")
	await _destroy(main)
	# A new game gets no Mercenary.
	_clean()
	main = await _new_main(TEST_SAVE)
	_check(main.mercenary_roster.get_owned_count() == 0 and main.mercenary_roster.get_pending().is_empty() and not main.get_load_notice_modal().is_showing(), "AC26 A new game: no free Mercenary, no notice")
	await _destroy(main)
	_sections_done.append("game_notice_claim")


# --- Character UI ---------------------------------------------------------------------------------------

func _verify_character_ui() -> void:
	for size in range(6):
		_clean()
		var main := await _new_main(TEST_SAVE)
		main.mercenary_roster = _recruited(size)
		main.mercenary_roster.pend_legacy(_legacy("merc_a", 2))
		var panel := main.get_node("CharacterPanel") as CharacterPanel
		_check(panel.open(), "Open with %d Mercenaries" % size)
		await process_frame
		var ids := panel.get_tab_ids()
		var expected := ["hero"]
		for m in main.mercenary_roster.get_owned():
			expected.append(m.get_id())
		_check(ids == expected and not ids.has("merc_a") and panel.get_tab("merc_b") == null, "AC27 Hero + %d: tabs %s (pending / legacy fixed tabs absent)" % [size, str(ids)])
		var canvas := Rect2(0.0, 0.0, 720.0, 1280.0)
		var strip := panel.get_node("Panel/TabStrip") as Control
		_check(canvas.encloses(strip.get_global_rect()), "Tab strip inside 720 x 1280")
		for id in ids:
			panel.select_character(id)
			await process_frame
			var tab := panel.get_tab(id)
			_check(panel.get_selected() == id and tab.disabled and strip.get_global_rect().encloses(tab.get_global_rect()), "AC28 %s selectable, its tab scrolled into view" % id)
		await _destroy(main)
	# Values and the allocation transaction.
	_clean()
	var main := await _new_main(TEST_SAVE)
	main.mercenary_roster = MercenaryRoster.build([Mercenary.create("merc_a", "GUARDIAN", 3, 40, _pts(1, 0, 0, 0)), Mercenary.create("merc_1", "MAGE", 2, 0)])
	main._save_session()
	var panel := main.get_node("CharacterPanel") as CharacterPanel
	await process_frame
	await process_frame
	_check((panel.get_node("OpenButton") as Button).text == "角色（屬性點 8）", "AC29 角色 shows Hero 0 + 守衛（傳承） 5 + 法師 #1 3 = 8 points (%s)" % (panel.get_node("OpenButton") as Button).text)
	panel.open()
	panel.select_character("merc_a")
	var lines := panel.get_lines()
	_check(lines[0] == "守衛（傳承）" and lines[1] == "等級 3　經驗 40 / 200" and lines[2] == "未分配屬性點 5" and lines[3] == "血量 260" and lines[4] == "力量 14", "AC29 守衛（傳承）: name, Level / EXP, points, real stats (%s)" % str(lines.slice(0, 5)))
	panel.press_plus("str")
	panel.press_plus("str")
	_check(panel.get_lines()[4] == "力量 14 → 16" and main.mercenary_roster.get_mercenary("merc_a").get_allocation_points()["str"] == 0, "AC30 Preview only: before -> after")
	panel.select_character("merc_1")
	panel.select_character("merc_a")
	_check(panel.get_pending().is_empty() and panel.get_lines()[4] == "力量 14", "AC30 Switching discards the preview")
	panel.press_plus("str")
	main.save_path = BAD_SAVE
	_check(not panel.confirm() and panel.get_feedback_text() == "無法儲存，分配已取消" and main.mercenary_roster.get_mercenary("merc_a").get_allocation_points() == _pts(1, 0, 0, 0) and panel.get_lines()[2] == "未分配屬性點 5", "AC31 Save failure: allocation rolled back, 無法儲存，分配已取消")
	main.save_path = TEST_SAVE
	panel.press_plus("str")
	panel.press_plus("hp")
	_check(panel.confirm() and main.mercenary_roster.get_mercenary("merc_a").get_allocation_points() == _pts(2, 1, 0, 0) and panel.get_feedback_text() == "" and panel.get_lines()[2] == "未分配屬性點 3", "AC31 Confirmed: STR +1, HP +1, saved")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	_check(int(saved["mercenaries"]["owned"][0]["allocation"]["str"]) == 1 and int(saved["mercenaries"]["owned"][0]["allocation"]["hp"]) == 2, "AC31 The file holds the new allocation")
	# The Hero path unchanged (S04 / S05).
	main.progression = ProgressionState.from_hero(2, 0)
	main._apply_level_growth()
	# The right Mercenary: 法師 #1 (second in the roster) gets the points.
	panel.select_character("merc_1")
	panel.press_plus("agi")
	_check(panel.confirm() and main.mercenary_roster.get_mercenary("merc_1").get_allocation_points() == _pts(0, 0, 1, 0) and main.mercenary_roster.get_mercenary("merc_a").get_allocation_points() == _pts(2, 1, 0, 0), "AC31 法師 #1's allocation lands on 法師 #1 only")
	panel.select_character("hero")
	panel.press_plus("int")
	_check(panel.confirm() and main.character_stats.get_allocated_points("int") == 1, "The Hero's allocation unchanged")
	panel.close()
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(main.mercenary_roster.get_mercenary("merc_a").get_allocation_points() == _pts(2, 1, 0, 0) and main.character_stats.get_allocated_points("int") == 1, "Restart keeps both")
	await _destroy(main)
	_sections_done.append("character_ui")


# --- Unreadable / future save protection --------------------------------------------------------------

func _verify_protection() -> void:
	var valid := JSON.stringify(_v12(_recruited(2), [3, 0], _pts(0, 0, 0, 0)))
	var future: Dictionary = JSON.parse_string(valid)
	future["version"] = 15  # Stage 10 P00: v14 is current
	var invalid: Dictionary = JSON.parse_string(valid)
	invalid["money"] = -5
	var cases := {"corrupt": "{ not json", "invalid": JSON.stringify(invalid), "future": JSON.stringify(future)}
	for reason in cases:
		_clean()
		_write_text(TEST_SAVE, cases[reason])
		var original := FileAccess.get_file_as_bytes(TEST_SAVE)
		_check(SaveStore.inspect(TEST_SAVE)["status"] == SaveStore.STATUS_UNREADABLE and SaveStore.inspect(TEST_SAVE)["reason"] == reason, "AC32 %s save: unreadable (%s)" % [reason, reason])
		var main := await _new_main(TEST_SAVE)
		_check(main.save_locked and main.load_status["reason"] == reason and main.unreadable_backup_path == TEST_SAVE + ".unreadable-1", "AC33 %s: saving locked, backup made" % reason)
		_check(FileAccess.get_file_as_bytes(main.unreadable_backup_path) == original, "AC33 %s: the backup is a byte-for-byte copy" % reason)
		var notice: NoticeModal = main.get_load_notice_modal()
		var expected_reason: String = {"corrupt": "存檔內容已損壞，無法讀取。", "invalid": "存檔內容不正確，無法讀取。", "future": "存檔來自較新版本的遊戲，無法讀取。"}[reason]
		_check(notice.is_showing() and notice.get_title() == "存檔未能載入" and Array(notice.get_lines()) == [expected_reason, "原存檔已保留，並已另存一份備份。", "今次遊戲進度不會儲存。"], "AC34 %s warning (%s)" % [reason, str(notice.get_lines())])
		# Play: every save path refuses; the original never changes.
		_check(not main._persist() and not main.save_world_position(), "AC35 %s: _persist() fails" % reason)
		await _enter_city(main)
		main.wallet.add(500)
		main._save_session()
		main.leave_city()
		await _settle()
		_check(FileAccess.get_file_as_bytes(TEST_SAVE) == original and not FileAccess.file_exists(TEST_SAVE + ".tmp"), "AC35 %s: after city entry / exit / saves the original is untouched" % reason)
		await _destroy(main)
		# A second launch: a new backup, the first one never overwritten.
		var first_backup := FileAccess.get_file_as_bytes(TEST_SAVE + ".unreadable-1")
		main = await _new_main(TEST_SAVE)
		_check(main.unreadable_backup_path == TEST_SAVE + ".unreadable-2" and FileAccess.get_file_as_bytes(TEST_SAVE + ".unreadable-1") == first_backup and FileAccess.get_file_as_bytes(TEST_SAVE + ".unreadable-2") == original, "AC36 %s: the next backup is .unreadable-2, .unreadable-1 untouched" % reason)
		await _destroy(main)
	# Backup failure: still locked, never overwritten, said so.
	_clean()
	_write_text(TEST_SAVE, "{ broken")
	var bytes := FileAccess.get_file_as_bytes(TEST_SAVE)
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(TEST_SAVE + ".unreadable-1"))
	_check(SaveStore.backup_unreadable(TEST_SAVE) == "", "AC37 A backup that cannot be written returns \"\"")
	var main := await _new_main(TEST_SAVE)
	_check(main.save_locked and main.unreadable_backup_path == "" and Array(main.get_load_notice_modal().get_lines())[1] == "原存檔已保留，但未能建立備份。", "AC37 Backup failed: still locked, the warning says so")
	main._save_session()
	_check(FileAccess.get_file_as_bytes(TEST_SAVE) == bytes, "AC37 The original still untouched")
	await _destroy(main)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE + ".unreadable-1"))
	# Missing save = a new game (not locked); a valid save never locks.
	_clean()
	main = await _new_main(TEST_SAVE)
	_check(not main.save_locked and main.load_status["status"] == SaveStore.STATUS_MISSING and main._persist() and int(JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))["version"]) == 14, "A missing save: a new game that saves v12")
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(not main.save_locked and main.load_status["status"] == SaveStore.STATUS_LOADED and not FileAccess.file_exists(TEST_SAVE + ".unreadable-1"), "A valid save: loaded, no backup, not locked")
	await _destroy(main)
	_sections_done.append("protection")


# --- Scope ----------------------------------------------------------------------------------------------

func _verify_scope() -> void:
	var main_code := _code_only("res://scripts/main.gd")
	_check(not main_code.contains("merc_stats") and not main_code.contains("\"merc_a\"") and not main_code.contains("\"merc_b\""), "AC38 main.gd holds no legacy Merc A / Merc B")
	var panel_code := _code_only("res://scripts/character_panel.gd")
	_check(not panel_code.contains("merc_a") and not panel_code.contains("ORDER") and not panel_code.contains("shown_ids"), "AC38 The Character UI has no fixed / hidden legacy tabs")
	for path in ["res://scripts/save_store.gd", "res://scripts/legacy_mercenary_migration.gd", "res://scripts/mercenary_roster.gd", "res://scripts/party_service.gd"]:
		var code := _code_only(path).to_lower()
		# (Stage 9 P01 approved Save v13 equipment in save_store.gd: it still
		# never saves a derived equipment bonus.)
		for word in ["backpack", "equipment_bonus" if path.ends_with("save_store.gd") else "equipment", "transfer", "max_hp", "attack_damage"]:
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	_check(MercenaryRoster.MAX_OWNED == 5 and MercenaryRoster.MAX_DEPLOYED == 3 and RecruitmentService.PRICE == 1000, "Limits and price unchanged")
	_check(CharacterConfig.MERCENARY_PROFILE == {"GUARDIAN": "merc_a", "MAGE": "merc_b", "STRATEGIST": "merc_b"} and CombatConfig.SKILL_MP_COST == 25, "Combat values unchanged")
	_check(RecruitmentService.LEGACY_LABELS == {"merc_a": "守衛（傳承）", "merc_b": "法師（傳承）"}, "Q5 names")
	_sections_done.append("scope")


# --- Stress ---------------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5050
	var bad := 0
	for round in range(250):
		var version := rng.randi_range(1, 11)
		var size := rng.randi_range(0, 5)
		var roster := _recruited(size)
		var levels := {"hero": [rng.randi_range(1, 9), 0]}
		var points := {"hero": _pts(0, 0, 0, 0)}
		for id in LEGACY:
			var level := rng.randi_range(1, 12)
			levels[id] = [level, rng.randi_range(0, ProgressionState.required_exp(level) - 1)]
			var earned := CharacterStats.earned_points_for(level)
			var split := [rng.randi_range(0, earned)]
			split.append(rng.randi_range(0, earned - split[0]))
			points[id] = _pts(split[0], split[1], 0, 0)
		var loaded := _load(_all_versions(levels, points, roster)[version])
		if loaded.is_empty():
			bad += 1
			continue
		var state: MercenaryRoster = loaded["mercenaries"]
		var serial := state.get_next_serial()
		for step in range(6):
			var action := rng.randi_range(0, 3)
			var fail := rng.randf() < 0.3
			var persist := func() -> bool: return not fail
			var before := JSON.stringify(state.get_snapshot())
			var result := {}
			if action == 0 and not state.get_pending().is_empty():
				result = PartyService.claim_pending(state, state.get_pending()[rng.randi_range(0, state.get_pending().size() - 1)].get_id(), persist)
			elif action == 1 and state.get_owned_count() > 0:
				var victim := state.get_owned()[rng.randi_range(0, state.get_owned_count() - 1)]
				result = PartyService.dismiss(state, victim.get_id(), persist)
			elif action == 2 and not state.is_full():
				result = PartyService.claim_pending(state, "merc_x", persist)
			else:
				# Save / restart.
				state = _load(_v12(state, [1, 0], _pts(0, 0, 0, 0)))["mercenaries"]
			if result.has("success") and not result["success"] and JSON.stringify(state.get_snapshot()) != before:
				bad += 1
			if state.get_owned_count() > MercenaryRoster.MAX_OWNED or state.get_next_serial() != serial:
				bad += 1
			var ids := state.get_owned().map(func(m: Mercenary) -> String: return m.get_id()) + state.get_pending().map(func(m: Mercenary) -> String: return m.get_id())
			var seen := {}
			for id in ids:
				if seen.has(id):
					bad += 1
				seen[id] = true
			for id in LEGACY:
				var m := state.get_mercenary(id) if state.get_mercenary(id) != null else state.get_pending_mercenary(id)
				var expected_level: int = levels[id][0] if version >= 9 else 1
				if m != null and m.get_level() != expected_level:
					bad += 1
	_check(bad == 0, "AC39 250 seeded runs (random v1-v11, roster 0-5, Level / EXP / allocation, claims, dismissals, save failures, reloads): capacity, unique ids, exact data, no double conversion (%d bad)" % bad)
	_sections_done.append("stress")


# --- Helpers --------------------------------------------------------------------------------------------

func _pts(hp: int, strength: int, agi: int, intelligence: int) -> Dictionary:
	return {"hp": hp, "str": strength, "agi": agi, "int": intelligence}


func _ints(points: Dictionary) -> Dictionary:
	var result := {}
	for key in points:
		result[key] = int(points[key])
	return result


func _levels(hero: Array, a: Array, b: Array) -> Dictionary:
	return {"hero": hero, "merc_a": a, "merc_b": b}


func _points() -> Dictionary:
	return {"hero": _pts(0, 0, 0, 0), "merc_a": _pts(0, 0, 0, 0), "merc_b": _pts(0, 0, 0, 0)}


func _legacy(id: String, level: int) -> Mercenary:
	return Mercenary.create(id, MercenaryRoster.LEGACY_TYPES[id], level, 0, _legacy_points(CharacterStats.earned_points_for(level)))


func _legacy_points(earned: int) -> Dictionary:
	# Deterministic, valid split of `earned` points (for Lv4: 1 / 2 / 3 / 3 = 9).
	var hp := mini(1, earned)
	var strength := mini(2, earned - hp)
	var agi := mini(3, earned - hp - strength)
	return _pts(hp, strength, agi, earned - hp - strength - agi)


## A roster with `size` recruited instances merc_1..merc_size (mixed types).
func _recruited(size: int) -> MercenaryRoster:
	var roster := MercenaryRoster.new()
	var types := ["MAGE", "GUARDIAN", "STRATEGIST"]
	for index in range(size):
		roster.create_mercenary(types[index % 3])
	return roster


## A JSON v12 save: the Hero at `hero` [level, exp] with `points`, `roster`.
func _v12(roster: MercenaryRoster, hero: Array, points: Dictionary) -> Dictionary:
	var stats := CharacterStats.new()
	stats.apply_level(hero[0])
	stats.restore_allocation(points)
	var inventory := CharacterInventory.new("player", stats)
	inventory.add("test_good_03", 4)
	var wallet := Wallet.new()
	wallet.spend(wallet.get_balance() - 4321)
	# Stage 9 P01: the current save is v13; a v12 save is it without `carrying`.
	var data: Dictionary = _json(SaveStore.serialize(wallet, inventory, MarketState.create_default(), PlayerLocation.new(), null, null, null, ProgressionState.from_hero(hero[0], hero[1]), {"hero": stats}, roster))
	data.erase("carrying")
	data.erase("condition")  # Stage 10 P00 (v14)
	data["version"] = 12
	return data


## Fixtures of every version {1..12} with the legacy three slots at
## `levels` {slot: [level, exp]} / `points`, and `roster` (v11 / v12).
func _all_versions(levels: Dictionary, points: Dictionary, roster: MercenaryRoster) -> Dictionary:
	var v12 := _v12(roster, levels["hero"], points["hero"])
	var v11: Dictionary = v12.duplicate(true)
	v11.erase("pending_legacy_mercenaries")
	v11["version"] = 11
	var progression := {}
	for slot in ProgressionState.LEGACY_SLOTS:
		progression[slot] = {"level": levels[slot][0], "exp": levels[slot][1]}
	v11["progression"] = progression
	v11["allocation"] = points.duplicate(true)
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


func _load(data: Dictionary) -> Dictionary:
	var payload := SaveStore.validate(_json(data))
	return {} if payload.is_empty() else SaveStore._rebuild(payload)


## The v12 save the game would write after loading `loaded`.
func _rewrite(loaded: Dictionary) -> Dictionary:
	var stats: CharacterStats = loaded["character_stats"]
	stats.apply_level((loaded["progression"] as ProgressionState).get_level("hero"))
	stats.restore_allocation(loaded["allocation"]["hero"])
	return _json(SaveStore.serialize(loaded["wallet"], loaded["inventory"], loaded["market"], loaded["location"], loaded["warehouses"], loaded["market_recovery"], loaded["cost_ledger"], loaded["progression"], {"hero": stats}, loaded["mercenaries"]))


## Roster + pending + Hero progression as text (for equality).
func _state(loaded: Dictionary) -> String:
	var roster: MercenaryRoster = loaded["mercenaries"]
	return JSON.stringify([roster.to_dict(), roster.pending_to_list(), (loaded["progression"] as ProgressionState).to_dict(), loaded["allocation"]])


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


func _write_json(data: Dictionary) -> void:
	_write_text(TEST_SAVE, JSON.stringify(data))


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
