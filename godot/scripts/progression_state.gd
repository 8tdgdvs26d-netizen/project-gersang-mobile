class_name ProgressionState
extends RefCounted

## Combat C05: the minimum persistent progression of the three fixed Prototype
## combat slots (the Hero and the two test Mercenaries): a Level and EXP each.
## Saved (Save v9 "progression"), nothing else about the slots is. It is not a
## Mercenary roster.
##
## Prototype rules (placeholders, not the final curve):
##   - a battle's EXP pool is shared equally (integer division, remainder
##     discarded) by the slots alive at settlement; DEFEAT awards nothing
##   - Lv1 -> Lv2 at 100 EXP; EXP beyond the threshold carries over
##   - Lv2 is the C05 ceiling: EXP keeps accumulating there, no Lv3
##   - a Level changes no combat stat (Combat never reads it)
## Each slot's "exp" is the EXP held towards the next Level (all EXP at the
## ceiling).

const SLOTS := ["hero", "merc_a", "merc_b"]
const START_LEVEL := 1
const MAX_LEVEL := 2
## EXP needed to leave a Level (only Lv1 -> Lv2 exists in C05).
const LEVEL_THRESHOLDS := {1: 100}
## Upper bound for saved EXP (exact JSON integers).
const MAX_EXP := 9007199254740992
const SLOT_KEYS := ["level", "exp"]

var _slots := {}


func _init() -> void:
	for slot in SLOTS:
		_slots[slot] = {"level": START_LEVEL, "exp": 0}


func get_level(slot: String) -> int:
	return int(_slots[slot]["level"]) if _slots.has(slot) else 0


func get_exp(slot: String) -> int:
	return int(_slots[slot]["exp"]) if _slots.has(slot) else 0


## The EXP each survivor gets from `result` and the Level it ends on, without
## changing anything: {slot: {"exp": n, "level": l, "leveled": bool}}. Empty for
## DEFEAT, no survivor or an empty pool.
func preview(result: BattleResult) -> Dictionary:
	var shares := {}
	if result == null or result.outcome == BattleResult.Outcome.DEFEAT or result.exp_pool <= 0:
		return shares
	var survivors := result.survivor_ids.filter(func(slot: String) -> bool: return _slots.has(slot))
	if survivors.is_empty():
		return shares
	var share := result.exp_pool / survivors.size()
	if share <= 0:
		return shares
	for slot in survivors:
		var after := _gain(get_level(slot), get_exp(slot), share)
		shares[slot] = {"exp": share, "level": after[0], "leveled": after[0] > get_level(slot)}
	return shares


## Applies `result`'s EXP (see preview()). Returns the same shares.
func apply(result: BattleResult) -> Dictionary:
	var shares := preview(result)
	for slot in shares:
		var after := _gain(get_level(slot), get_exp(slot), shares[slot]["exp"])
		_slots[slot] = {"level": after[0], "exp": after[1]}
	return shares


## [level, exp] after gaining `amount` EXP at `level` with `exp`.
static func _gain(level: int, held: int, amount: int) -> Array:
	held = mini(held + amount, MAX_EXP)
	while level < MAX_LEVEL and held >= LEVEL_THRESHOLDS[level]:
		held -= LEVEL_THRESHOLDS[level]
		level += 1
	return [level, held]


func to_dict() -> Dictionary:
	var data := {}
	for slot in SLOTS:
		data[slot] = {"level": _slots[slot]["level"], "exp": _slots[slot]["exp"]}
	return data


## A validated copy of saved progression, or null: exactly the three slots,
## each exactly {level, exp} as integers, 1 <= level <= MAX_LEVEL,
## 0 <= exp <= MAX_EXP, and below the threshold while under the ceiling.
static func from_dict(data: Variant) -> ProgressionState:
	if typeof(data) != TYPE_DICTIONARY or data.size() != SLOTS.size():
		return null
	var state := ProgressionState.new()
	for slot in SLOTS:
		if not data.has(slot):
			return null
		var entry: Variant = data[slot]
		if typeof(entry) != TYPE_DICTIONARY or entry.size() != SLOT_KEYS.size() or not entry.has_all(SLOT_KEYS):
			return null
		var level: Variant = _whole(entry["level"])
		var held: Variant = _whole(entry["exp"])
		if level == null or held == null or level < START_LEVEL or level > MAX_LEVEL or held < 0 or held > MAX_EXP:
			return null
		if level < MAX_LEVEL and held >= LEVEL_THRESHOLDS[level]:
			return null
		state._slots[slot] = {"level": level, "exp": held}
	return state


## An integer from JSON (ints and whole floats), else null.
static func _whole(value: Variant) -> Variant:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) and absf(value) <= MAX_EXP:
		return int(value)
	return null
