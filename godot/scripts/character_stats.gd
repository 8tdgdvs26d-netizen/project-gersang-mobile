class_name CharacterStats
extends RefCounted

## Stage 7 S01: one character's stats — the single authoritative stat source
## for the backpack (capacity) and for combat (the battle's starting Max HP /
## Max MP and Basic Attack profile).
##
## Layers per stat (HP, MP, STR, AGI, INT; CharacterConfig.STATS):
##   Base       the character's foundation (CharacterConfig.BASE; the Hero's
##              STR comes from Save v9 character.stats.strength)
##   Allocated  future player-assigned growth (S03 / S04); 0 in S01, runtime
##              only, never saved; MP is not allocatable
##   Equipment  future equipment bonuses (Stage 9); 0 in S01, runtime only
##   Effective  Base + Allocated + Equipment — what every consumer reads
## Derived: Carrying Capacity = 10 + Effective STR x 9; Max HP / Max MP are
## Effective HP / MP. Attack / defense / speed are the S01 compatibility
## values (CharacterConfig.COMBAT_COMPAT) until S02 defines the formulas.
##
## M2-08 API kept: CharacterStats.new(strength) is the Hero / player
## character; get_strength() is Effective STR, set_strength() sets Base STR.
const PROTOTYPE_DEFAULT_STRENGTH := 10
const PROTOTYPE_BASE_CAPACITY := CharacterConfig.BASE_CAPACITY
const PROTOTYPE_CAPACITY_PER_STRENGTH := CharacterConfig.CAPACITY_PER_STR
const MAX_STRENGTH := CharacterConfig.MAX_STAT

var character_id := ""
var _base := {}
var _allocated := {}
var _equipment := {}


func _init(strength: int = PROTOTYPE_DEFAULT_STRENGTH, id: String = "hero") -> void:
	character_id = id if CharacterConfig.BASE.has(id) else "hero"
	_base = (CharacterConfig.BASE[character_id] as Dictionary).duplicate()
	for stat in CharacterConfig.STATS:
		_allocated[stat] = 0
		_equipment[stat] = 0
	_base["str"] = strength if _is_valid(strength) else PROTOTYPE_DEFAULT_STRENGTH


## The Prototype stats of one of the fixed combat characters (null for any
## other id).
static func for_character(id: String) -> CharacterStats:
	if not CharacterConfig.BASE.has(id):
		return null
	return CharacterStats.new(int(CharacterConfig.BASE[id]["str"]), id)


func get_base(stat: String) -> int:
	return int(_base.get(stat, 0))


func get_allocated(stat: String) -> int:
	return int(_allocated.get(stat, 0))


func get_equipment_bonus(stat: String) -> int:
	return int(_equipment.get(stat, 0))


func get_effective(stat: String) -> int:
	return get_base(stat) + get_allocated(stat) + get_equipment_bonus(stat)


## Future allocation hook (S03 / S04; no gameplay calls it in S01). Only
## CharacterConfig.ALLOCATABLE stats (not MP).
func set_allocated(stat: String, value: Variant) -> bool:
	if not CharacterConfig.ALLOCATABLE.has(stat) or not _is_valid(value):
		return false
	_allocated[stat] = value
	return true


## Future equipment hook (Stage 9; no gameplay calls it in S01, every bonus
## stays 0).
func set_equipment_bonus(stat: String, value: Variant) -> bool:
	if not CharacterConfig.STATS.has(stat) or not _is_valid(value):
		return false
	_equipment[stat] = value
	return true


## Effective STR (capacity and every STR consumer read this).
func get_strength() -> int:
	return get_effective("str")


func get_base_strength() -> int:
	return get_base("str")


## Sets Base STR (M2-08 API; Save v9 character.stats.strength).
func set_strength(strength: Variant) -> bool:
	if not _is_valid(strength):
		return false
	_base["str"] = strength
	return true


func get_max_capacity() -> int:
	return PROTOTYPE_BASE_CAPACITY + get_strength() * PROTOTYPE_CAPACITY_PER_STRENGTH


func get_max_hp() -> int:
	return get_effective("hp")


func get_max_mp() -> int:
	return get_effective("mp")


# --- Derived stats (S01 compatibility values; S02 defines the formulas) ---

func get_physical_attack() -> int:
	return int(_compat()["physical_attack"])


## No magic attack / defenses exist in combat yet (S02): 0, read by nothing.
func get_magic_attack() -> int:
	return 0


func get_physical_defense() -> int:
	return 0


func get_magic_defense() -> int:
	return 0


func get_attack_interval_ms() -> int:
	return int(_compat()["attack_interval_ms"])


func get_move_speed() -> float:
	return float(_compat()["move_speed"])


func get_attack_range() -> int:
	return int(_compat()["attack_range"])


## What a battle builds this character's CombatUnit from (CombatUnit.create
## keys): Max HP plus the Basic Attack profile.
func get_combat_profile() -> Dictionary:
	return {
		"max_hp": get_max_hp(),
		"attack_damage": get_physical_attack(),
		"attack_range": get_attack_range(),
		"attack_interval_ms": get_attack_interval_ms(),
		"move_speed": get_move_speed(),
	}


func _compat() -> Dictionary:
	return CharacterConfig.COMBAT_COMPAT[character_id]


func _is_valid(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and value >= 0 and value <= CharacterConfig.MAX_STAT
