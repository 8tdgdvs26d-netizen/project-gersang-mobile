class_name CharacterCondition
extends RefCounted

## Stage 10 P00 (approved): every character's persistent condition — its
## current HP, current MP and whether it is dead — for the Hero ("hero") and
## each owned Mercenary, keyed by stable character id (never roster
## position, type or name). One record per character, the only one: a
## battle starts from it and writes its participants' final values back.
##
## Identity and the maxima are not kept here: CharacterCarrying is the
## authority (is_character: the Hero or an owned Mercenary, never a pending,
## dismissed or unknown id; get_stats: the Effective stats with Level,
## allocation and equipment, so Max HP / Max MP are the current effective
## ones).
##
## Approved rules (Charlie, Stage 10):
##   - actual values, never scaled: when a Max changes the current value
##     stays, clamped to the new Max (30 / 100 -> Max 120 -> 30 / 120;
##     100 / 120 -> Max 80 -> 80 / 80); no heal on Level-up, allocation or
##     equipment,
##   - nothing restores HP / MP outside an approved recovery (no passive
##     regeneration, no healing on victory, scene change or reload),
##   - dead <=> HP 0; a dead character stays dead (no silent revival).
## A character without a record yet (a new game, a v1-v13 save, a newly
## recruited or claimed Mercenary) gets one at its full current maxima,
## alive, the first time sync() runs — once; never again later.

const HERO_ID := Mercenary.HERO_ID
const SAVE_KEYS := ["hp", "mp", "dead"]
## The largest value a saved HP / MP may hold (far above any Max; keeps
## every value far from int overflow; a save beyond it is invalid).
const MAX_VALUE := 1000000

## Returns the CharacterCarrying that is the identity / stats authority
## (main's may be replaced on load).
var _carrying_provider: Callable
## character id -> {"hp": int, "mp": int, "dead": bool}
var _records := {}


func _init(carrying_provider: Callable = Callable()) -> void:
	_carrying_provider = carrying_provider


func set_carrying_provider(provider: Callable) -> void:
	_carrying_provider = provider


func get_carrying() -> CharacterCarrying:
	var carrying: Variant = _carrying_provider.call() if _carrying_provider.is_valid() else null
	return carrying if carrying is CharacterCarrying else null


## The Hero or an owned Mercenary (CharacterCarrying's identity rule).
func is_character(id: Variant) -> bool:
	var carrying := get_carrying()
	return carrying != null and carrying.is_character(id)


## Every character that exists now: the Hero, then the owned Mercenaries
## (roster order).
func get_character_ids() -> Array:
	var ids := [HERO_ID]
	var carrying := get_carrying()
	var roster := carrying.get_roster() if carrying != null else null
	if roster != null:
		for mercenary in roster.get_owned():
			ids.append(mercenary.get_id())
	return ids


## {"hp", "mp", "dead", "max_hp", "max_mp"} of a character (its record,
## created full / alive if it has none yet, clamped to the current maxima),
## or {} for anything that is not the Hero or an owned Mercenary.
func get_condition(id: Variant) -> Dictionary:
	if not _sync_one(id):
		return {}
	var stats := get_carrying().get_stats(id)
	var record: Dictionary = _records[id]
	return {"hp": record["hp"], "mp": record["mp"], "dead": record["dead"], "max_hp": stats.get_max_hp(), "max_mp": stats.get_max_mp()}


func get_hp(id: Variant) -> int:
	return int(get_condition(id).get("hp", -1))


func get_mp(id: Variant) -> int:
	return int(get_condition(id).get("mp", -1))


func is_dead(id: Variant) -> bool:
	return bool(get_condition(id).get("dead", false))


## Whether a record exists (for checks: sync() has seen the character).
func has_record(id: Variant) -> bool:
	return typeof(id) == TYPE_STRING and _records.has(id)


## Records the final condition of a character (a battle's participant):
## HP 0 = dead; HP / MP clamped to 0..current Max. Refused (false, nothing
## changes) for a non-character or a value that is not a whole number.
func set_condition(id: Variant, hp: Variant, mp: Variant) -> bool:
	if not is_character(id) or typeof(hp) != TYPE_INT or typeof(mp) != TYPE_INT:
		return false
	var stats := get_carrying().get_stats(id)
	if stats == null:
		return false
	var current_hp := clampi(hp, 0, stats.get_max_hp())
	_records[id] = {"hp": current_hp, "mp": clampi(mp, 0, stats.get_max_mp()), "dead": current_hp == 0}
	return true


## Gives every character without a record one at its full current maxima
## (alive), and clamps every record to the current maxima (the approved
## Max-change rule). Records of ids that are no longer characters are left
## alone (never saved). False when some character's stats are unavailable.
func sync() -> bool:
	var ok := true
	for id in get_character_ids():
		ok = _sync_one(id) and ok
	return ok


func _sync_one(id: Variant) -> bool:
	if not is_character(id):
		return false
	var stats := get_carrying().get_stats(id)
	if stats == null:
		return false
	var max_hp := stats.get_max_hp()
	var max_mp := stats.get_max_mp()
	if not _records.has(id):
		_records[id] = {"hp": max_hp, "mp": max_mp, "dead": false}
		return true
	var record: Dictionary = _records[id]
	record["hp"] = mini(int(record["hp"]), max_hp)
	record["mp"] = mini(int(record["mp"]), max_mp)
	return true


# --- Snapshot (rollback) ----------------------------------------------------

func get_snapshot() -> Dictionary:
	return _records.duplicate(true)


func restore_snapshot(snapshot: Dictionary) -> void:
	_records = snapshot.duplicate(true)


# --- Save v14 ---------------------------------------------------------------

## {"hero": {hp, mp, dead}, "<mercenary id>": {...}} for the Hero and every
## owned Mercenary (roster order), each synced first.
func to_save() -> Dictionary:
	sync()
	var data := {}
	for id in get_character_ids():
		if _records.has(id):
			data[id] = (_records[id] as Dictionary).duplicate()
	return data


## A validated {id: {"hp", "mp", "dead"}} from a saved `condition` section,
## or {} when anything is malformed: exactly the Hero + every owned
## Mercenary of `roster` (no pending, no unknown id), each entry exactly
## SAVE_KEYS, HP / MP whole numbers 0..MAX_VALUE (JSON whole floats
## accepted), `dead` a bool, dead exactly when HP is 0. Nothing is repaired
## (the maxima are applied by sync() once the stats exist).
static func parse_save(data: Variant, roster: MercenaryRoster) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY or roster == null:
		return {}
	var ids := [HERO_ID]
	for mercenary in roster.get_owned():
		ids.append(mercenary.get_id())
	if data.size() != ids.size():
		return {}
	var parsed := {}
	for id in ids:
		if not data.has(id) or typeof(data[id]) != TYPE_DICTIONARY:
			return {}
		var entry: Dictionary = data[id]
		if entry.size() != SAVE_KEYS.size() or not entry.has_all(SAVE_KEYS):
			return {}
		var hp := _whole(entry["hp"])
		var mp := _whole(entry["mp"])
		if hp < 0 or mp < 0 or typeof(entry["dead"]) != TYPE_BOOL or entry["dead"] != (hp == 0):
			return {}
		parsed[id] = {"hp": hp, "mp": mp, "dead": entry["dead"]}
	return parsed


## Replaces every record with a parse_save() result ({}: no records — a
## v1-v13 save; sync() then gives everyone full / alive).
func restore_save(parsed: Dictionary) -> void:
	_records = parsed.duplicate(true)


## A whole number 0..MAX_VALUE (int, or a whole JSON float), else -1.
static func _whole(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return value if value >= 0 and value <= MAX_VALUE else -1
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) and value >= 0.0 and value <= float(MAX_VALUE):
		return int(value)
	return -1
