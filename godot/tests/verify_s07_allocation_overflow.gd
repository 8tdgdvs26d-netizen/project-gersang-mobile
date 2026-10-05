extends SceneTree

## Stage 7 corrective: CharacterStats allocation overflow validation.
## confirm_allocation() and restore_allocation() used to sum the amounts
## before comparing them with the unspent / earned points, so huge ints could
## wrap the sum (64-bit) into a small number and pass. Each amount is now
## bounded first (confirm: by the unspent points, restore: by the earned
## points), then the total is checked as before. A refused call changes
## nothing. Every normal (legal) result is unchanged.

const HUGE := 9223372036854775807

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_verify_confirm()
	_verify_restore()
	_verify_unchanged_rules()
	_verify_stress()
	_check(_sections_done.size() == 4, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("S07 allocation overflow verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- A. confirm_allocation ------------------------------------------------------------------------

func _verify_confirm() -> void:
	# Lv3 Hero: 6 earned; 2 already spent on STR -> 4 unspent.
	var stats := _at(3)
	_check(stats.confirm_allocation({"str": 2}) and stats.get_unspent_points() == 4, "A1 A normal allocation succeeds")
	var before := stats.get_allocation_points()
	var cases := [
		["A2 one value over unspent", {"hp": 5}],
		["A3 each value fits, total over unspent", {"hp": 3, "agi": 2}],
		["A3 each value fits, total over unspent (4 stats)", {"hp": 2, "str": 1, "agi": 1, "int": 1}],
		["A4 maximum int", {"hp": HUGE}],
		["A4 a large value", {"int": 1 << 40}],
		["A5 two maximum ints (sum wraps to -2)", {"hp": HUGE, "str": HUGE}],
		["A5 values wrapping the sum to 1", {"hp": HUGE, "str": HUGE, "agi": 3}],
		["A5 values wrapping the sum to the unspent 4", {"hp": HUGE, "str": HUGE, "agi": 3, "int": 3}],
		["A5 a minimum int with a positive (no wrap path)", {"hp": -HUGE - 1, "str": 1}],
		["A7 zero total", {"hp": 0}],
		["A7 empty", {}],
		["A8 invalid stat", {"mp": 1}],
		["A8 unknown stat", {"luck": 1}],
		["A9 negative", {"hp": -1}],
		["A9 negative hidden in a positive total", {"hp": 3, "str": -1}],
		["non-int (float)", {"hp": 1.0}],
		["non-int (string)", {"hp": "1"}],
	]
	for case in cases:
		var spent := stats.get_spent_points()
		_check(not stats.confirm_allocation(case[1]), "%s: refused" % case[0])
		_check(stats.get_allocation_points() == before and stats.get_spent_points() == spent and stats.get_unspent_points() == 4, "A6 %s: allocation unchanged" % case[0])
	_check(stats.get_max_hp() == _at(3).get_max_hp() and stats.get_effective("str") == _at(3).get_effective("str") + 2, "A6 Effective stats unchanged by every refusal")
	_check(stats.confirm_allocation({"hp": 1, "agi": 3}) and stats.get_unspent_points() == 0 and stats.get_allocation_points() == {"hp": 1, "str": 2, "agi": 3, "int": 0}, "A10 Using exactly all unspent points succeeds")
	_check(not stats.confirm_allocation({"hp": 1}) and not stats.confirm_allocation({"hp": HUGE}), "Nothing left: further points refused")
	var single := _at(2)
	_check(single.confirm_allocation({"int": 3}) and single.get_allocation_points()["int"] == 3, "A10 One stat taking all 3 unspent succeeds")
	_sections_done.append("confirm")


# --- B. restore_allocation ------------------------------------------------------------------------

func _verify_restore() -> void:
	# Lv3: 6 earned. Existing allocation: hp 1, str 2.
	var stats := _at(3)
	_check(stats.restore_allocation({"hp": 1, "str": 2, "agi": 0, "int": 0}) and stats.get_allocation_points() == {"hp": 1, "str": 2, "agi": 0, "int": 0}, "B1 A normal restore succeeds")
	var before := stats.get_allocation_points()
	var cases := [
		["B2 one value over earned", {"hp": 7, "str": 0, "agi": 0, "int": 0}],
		["B3 each value fits, sum over earned", {"hp": 4, "str": 3, "agi": 0, "int": 0}],
		["B3 each value fits, sum over earned (all four)", {"hp": 2, "str": 2, "agi": 2, "int": 1}],
		["B4 maximum int", {"hp": HUGE, "str": 0, "agi": 0, "int": 0}],
		["B4 four maximum ints", {"hp": HUGE, "str": HUGE, "agi": HUGE, "int": HUGE}],
		["B5 values wrapping the sum to 1", {"hp": HUGE, "str": HUGE, "agi": 3, "int": 0}],
		["B5 values wrapping the sum to the earned 6", {"hp": HUGE, "str": HUGE, "agi": 4, "int": 4}],
		["B7 missing key", {"hp": 1, "str": 2, "agi": 0}],
		["B8 extra key", {"hp": 1, "str": 2, "agi": 0, "int": 0, "mp": 0}],
		["B8 a key replaced", {"hp": 1, "str": 2, "agi": 0, "mp": 0}],
		["B9 negative", {"hp": -1, "str": 0, "agi": 0, "int": 0}],
		["B9 negative evening out a sum", {"hp": 7, "str": -1, "agi": 0, "int": 0}],
		["B9 non-int (float)", {"hp": 1.0, "str": 0, "agi": 0, "int": 0}],
		["B9 non-int (string)", {"hp": "1", "str": 0, "agi": 0, "int": 0}],
	]
	for case in cases:
		_check(not stats.restore_allocation(case[1]), "%s: refused" % case[0])
		_check(stats.get_allocation_points() == before and stats.get_unspent_points() == 3, "B6 %s: allocation unchanged" % case[0])
	_check(stats.restore_allocation({"hp": 6, "str": 0, "agi": 0, "int": 0}) and stats.get_unspent_points() == 0, "B10 One stat holding all earned points restores")
	_check(stats.restore_allocation({"hp": 3, "str": 1, "agi": 1, "int": 1}) and stats.get_allocation_points() == {"hp": 3, "str": 1, "agi": 1, "int": 1}, "B10 Exactly the earned points across four stats restores (and replaces)")
	_check(stats.restore_allocation(CharacterStats.zero_allocation()) and stats.get_spent_points() == 0, "B10 All zero restores")
	_check(_at(1).restore_allocation(CharacterStats.zero_allocation()) and not _at(1).restore_allocation({"hp": 1, "str": 0, "agi": 0, "int": 0}), "Lv1: 0 earned, only zeros")
	_sections_done.append("restore")


# --- Rules that must not change ----------------------------------------------------------------------

func _verify_unchanged_rules() -> void:
	_check(CharacterConfig.STAT_POINTS_PER_LEVEL == 3 and CharacterConfig.ALLOCATABLE == ["hp", "str", "agi", "int"] and CharacterConfig.ALLOCATION_VALUE == {"hp": 10, "str": 1, "agi": 1, "int": 1}, "+3 points per Level, HP / STR / AGI / INT, 1 HP point = +10 (config unchanged)")
	var stats := _at(4)
	var hp := stats.get_max_hp()
	var mp := stats.get_max_mp()
	_check(stats.confirm_allocation({"hp": 2, "int": 1}) and stats.get_max_hp() == hp + 20 and stats.get_max_mp() == mp + CharacterConfig.MP_PER_INT and stats.get_unspent_points() == 6, "Effects unchanged: +20 Max HP, INT feeds MP, 6 points kept unspent")
	_check(not stats.confirm_allocation({"mp": 1}), "MP still not allocatable")
	stats.apply_level(6)
	_check(stats.get_unspent_points() == 12 and stats.get_allocation_points() == {"hp": 2, "str": 0, "agi": 0, "int": 1}, "A later Level adds points; the spent ones stay")
	_check(SaveStore.VERSION == 12, "Save version 12 (P05)")
	var code := FileAccess.get_file_as_string("res://scripts/character_stats.gd").to_lower()
	_check(not code.contains("reset"), "No Stat Reset")
	_sections_done.append("rules")


# --- Targeted stress (seeded, deterministic) ------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261004
	var ok := true
	var accepted := 0
	var refused := 0
	var extremes := [HUGE, HUGE - 1, 1 << 62, 1 << 40, -HUGE - 1, -1]
	for round in range(3000):
		var level := rng.randi_range(1, 100)
		var stats := _at(level)
		var earned := stats.get_earned_points()
		# A random legal starting allocation through restore.
		var start := CharacterStats.zero_allocation()
		var budget := rng.randi_range(0, earned)
		for unit in range(budget):
			start[CharacterConfig.ALLOCATABLE[rng.randi_range(0, 3)]] += 1
		ok = ok and stats.restore_allocation(start) and stats.get_allocation_points() == start
		var before := stats.get_allocation_points()
		var unspent := stats.get_unspent_points()
		# A pending set: legal, oversized, or extreme.
		var pending := {}
		for stat in CharacterConfig.ALLOCATABLE:
			if rng.randi_range(0, 2) == 0:
				continue
			match rng.randi_range(0, 3):
				0: pending[stat] = rng.randi_range(0, 3)
				1: pending[stat] = rng.randi_range(0, unspent + 3)
				2: pending[stat] = extremes[rng.randi_range(0, extremes.size() - 1)]
				3: pending[stat] = rng.randi_range(0, maxi(unspent, 0))
		var legal := true
		var total := 0
		for stat in pending:
			if pending[stat] < 0 or pending[stat] > 1000000:
				legal = false
			else:
				total += pending[stat]
		legal = legal and total > 0 and total <= unspent
		var done := stats.confirm_allocation(pending)
		ok = ok and done == legal
		if done:
			accepted += 1
			for stat in CharacterConfig.ALLOCATABLE:
				ok = ok and stats.get_allocated_points(stat) == before[stat] + int(pending.get(stat, 0))
		else:
			refused += 1
			ok = ok and stats.get_allocation_points() == before
		ok = ok and stats.get_spent_points() <= earned and stats.get_spent_points() >= 0
		# A restore attempt: legal or extreme; refused ones change nothing.
		var restore := stats.get_allocation_points()
		var current := stats.get_allocation_points()
		var restore_legal := true
		if rng.randi_range(0, 1) == 0:
			restore[CharacterConfig.ALLOCATABLE[rng.randi_range(0, 3)]] = extremes[rng.randi_range(0, extremes.size() - 1)]
			restore_legal = false
		ok = ok and stats.restore_allocation(restore) == restore_legal
		ok = ok and stats.get_allocation_points() == (restore if restore_legal else current)
		if not ok:
			_check(false, "Stress broke at round %d (level %d, pending %s)" % [round, level, str(pending)])
			break
	_check(ok, "3000 seeded rounds: legal sets applied exactly, every other set refused with nothing changed")
	_check(accepted > 300 and refused > 300, "Both outcomes exercised (%d accepted, %d refused)" % [accepted, refused])
	_sections_done.append("stress")


func _at(level: int) -> CharacterStats:
	var stats := CharacterStats.for_character("hero")
	stats.apply_level(level)
	return stats


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
