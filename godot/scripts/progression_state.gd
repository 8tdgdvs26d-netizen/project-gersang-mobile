class_name ProgressionState
extends RefCounted

## Combat C05: the minimum persistent progression of the three fixed Prototype
## combat slots (the Hero and the two test Mercenaries): a Level and EXP each.
## Saved (Save v9 "progression"), nothing else about the slots is. It is not a
## Mercenary roster.
##
## Prototype rules:
##   - a battle's EXP pool is shared equally (integer division, remainder
##     discarded) by the slots alive at settlement; DEFEAT awards nothing
##     (C05)
##   - Stage 7 S03 curve: leaving Level L needs 100 + 50 x (L - 1) EXP
##     (Lv1 100, Lv2 150, Lv3 200, ...); one award may pass several Levels,
##     each consuming its own requirement; the rest carries over
##   - Lv100 cap: no Level beyond it, no EXP kept at it
##   - the Level's growth (stats, Stat Points) is applied by the session to the
##     characters' CharacterStats (CharacterStats.apply_level); this class
##     holds only Level and EXP
## Each slot's "exp" is the EXP held towards the next Level (0 at the cap).

const SLOTS := ["hero", "merc_a", "merc_b"]
const START_LEVEL := 1
const MAX_LEVEL := 100
## EXP to leave Level L = EXP_BASE + EXP_STEP x (L - 1).
const EXP_BASE := 100
const EXP_STEP := 50
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


## EXP needed to leave `level` (0 at the cap: no further Level).
static func required_exp(level: int) -> int:
	if level >= MAX_LEVEL:
		return 0
	return EXP_BASE + EXP_STEP * (maxi(level, START_LEVEL) - 1)


## [level, exp] after gaining `amount` EXP at `level` with `exp`: Level by
## Level, each consuming its own requirement; nothing is kept at the cap.
static func _gain(level: int, held: int, amount: int) -> Array:
	held = mini(held + amount, MAX_EXP)
	while level < MAX_LEVEL and held >= required_exp(level):
		held -= required_exp(level)
		level += 1
	if level >= MAX_LEVEL:
		held = 0
	return [level, held]


func to_dict() -> Dictionary:
	var data := {}
	for slot in SLOTS:
		data[slot] = {"level": _slots[slot]["level"], "exp": _slots[slot]["exp"]}
	return data


## A validated copy of saved progression, or null: exactly the three slots,
## each exactly {level, exp} as integers, 1 <= level <= MAX_LEVEL,
## 0 <= exp <= MAX_EXP. S03: EXP at or above the Level's requirement (C05
## saves banked EXP at the old Lv2 ceiling) is carried through the S03 curve
## on load, Level by Level, so no valid v9 save is refused.
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
		var settled := _gain(level, held, 0)
		state._slots[slot] = {"level": settled[0], "exp": settled[1]}
	return state


## An integer from JSON (ints and whole floats), else null.
static func _whole(value: Variant) -> Variant:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) and absf(value) <= MAX_EXP:
		return int(value)
	return null
