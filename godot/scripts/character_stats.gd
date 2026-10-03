class_name CharacterStats
extends RefCounted

## Stage 7 S01: one character's stats — the single authoritative stat source
## for the backpack (capacity) and for combat (the battle's starting profile).
##
## Layers per stat (HP, MP, STR, AGI, INT; CharacterConfig.STATS):
##   Base       the character's foundation (CharacterConfig.BASE; the Hero's
##              STR comes from Save v9 character.stats.strength)
##   Growth     future character growth (S03; S02 prerequisite correction); 0,
##              runtime only, never saved, nothing grants it yet
##   Allocated  future player-assigned points (S03 / S04); 0, runtime only,
##              never saved; MP is not allocatable
##   Equipment  future equipment bonuses (Stage 9); 0, runtime only
##   Effective  Base + Growth + Allocated + Equipment — what every consumer
##              reads (each layer counted once)
## Derived (S02 formulas, CharacterConfig constants; every rounding rule is
## here and nowhere else):
##   Capacity          10 + STR x 9
##   Max HP            Effective HP
##   Max MP            Effective MP + (INT - 10) x 5
##   Physical Attack   base + (STR - 10) x 1
##   Magic Attack      (INT - 10) x 2
##   Physical Defense  floor((STR - 10) x 0.5); Magic Defense the same on INT
##   Attack Interval   AGI diminishing curve, never below 300 ms (ms, rounded)
##   Move Speed        AGI diminishing curve, never above 7.0
## (STR / AGI / INT: Effective values; "- 10" never below 0.)
##
## M2-08 API kept: CharacterStats.new(strength) is the Hero / player
## character; get_strength() is Effective STR, set_strength() sets Base STR.
const PROTOTYPE_DEFAULT_STRENGTH := 10
const PROTOTYPE_BASE_CAPACITY := CharacterConfig.BASE_CAPACITY
const PROTOTYPE_CAPACITY_PER_STRENGTH := CharacterConfig.CAPACITY_PER_STR
const MAX_STRENGTH := CharacterConfig.MAX_STAT

var character_id := ""
var _base := {}
var _growth := {}
var _allocated := {}
var _equipment := {}


func _init(strength: int = PROTOTYPE_DEFAULT_STRENGTH, id: String = "hero") -> void:
	character_id = id if CharacterConfig.BASE.has(id) else "hero"
	_base = (CharacterConfig.BASE[character_id] as Dictionary).duplicate()
	for stat in CharacterConfig.STATS:
		_growth[stat] = 0
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


func get_growth(stat: String) -> int:
	return int(_growth.get(stat, 0))


func get_allocated(stat: String) -> int:
	return int(_allocated.get(stat, 0))


func get_equipment_bonus(stat: String) -> int:
	return int(_equipment.get(stat, 0))


func get_effective(stat: String) -> int:
	return get_base(stat) + get_growth(stat) + get_allocated(stat) + get_equipment_bonus(stat)


## Future growth hook (S03; no gameplay calls it, nothing is saved).
func set_growth(stat: String, value: Variant) -> bool:
	if not CharacterConfig.STATS.has(stat) or not _is_valid(value):
		return false
	_growth[stat] = value
	return true


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
	return get_effective("mp") + _above_baseline("int") * CharacterConfig.MP_PER_INT


# --- Derived stats (S02 formulas) ---

func get_physical_attack() -> int:
	return int(_compat()["physical_attack"]) + _above_baseline("str") * CharacterConfig.PHYSICAL_ATTACK_PER_STR


func get_magic_attack() -> int:
	return _above_baseline("int") * CharacterConfig.MAGIC_ATTACK_PER_INT


func get_physical_defense() -> int:
	return defense_for(_above_baseline("str"))


func get_magic_defense() -> int:
	return defense_for(_above_baseline("int"))


func get_attack_interval_ms() -> int:
	return attack_interval_for(int(_compat()["attack_interval_ms"]), _above_baseline("agi"))


func get_move_speed() -> float:
	return move_speed_for(float(_compat()["move_speed"]), _above_baseline("agi"))


## Defense from the stat points above 10: floor(points x 0.5) (integer).
static func defense_for(points: int) -> int:
	return maxi(points, 0) * CharacterConfig.DEFENSE_PER_STAT_NUM / CharacterConfig.DEFENSE_PER_STAT_DEN


## Damage a hit deals through `defense`: nothing for a non-damaging hit,
## otherwise max(1, incoming - defense) (every damaging hit deals >= 1).
static func mitigate(incoming: int, defense: int) -> int:
	if incoming <= 0:
		return 0
	return maxi(1, incoming - maxi(defense, 0))


## Basic Attack interval (ms, rounded to the nearest ms) for `agi_points`
## above 10: diminishing returns, never below MIN_ATTACK_INTERVAL_MS.
static func attack_interval_for(base_ms: int, agi_points: int) -> int:
	if agi_points <= 0:
		return base_ms
	var floor_factor := CharacterConfig.ATTACK_INTERVAL_FLOOR_FACTOR
	var half := CharacterConfig.ATTACK_INTERVAL_AGI_HALF
	var factor := floor_factor + (1.0 - floor_factor) * half / (half + agi_points)
	return maxi(CharacterConfig.MIN_ATTACK_INTERVAL_MS, roundi(base_ms * factor))


## Move speed (cells / s) for `agi_points` above 10: diminishing returns,
## never above MAX_MOVE_SPEED.
static func move_speed_for(base_speed: float, agi_points: int) -> float:
	if agi_points <= 0:
		return minf(base_speed, CharacterConfig.MAX_MOVE_SPEED)
	var half := CharacterConfig.MOVE_SPEED_AGI_HALF
	var speed := base_speed * (1.0 + CharacterConfig.MOVE_SPEED_MAX_BONUS * agi_points / (agi_points + half))
	return minf(speed, CharacterConfig.MAX_MOVE_SPEED)


## Lightning damage of one Gesture grade: (GESTURE_BASE_DAMAGE + Magic
## Attack) x the grade's percent, rounded down (integer).
static func gesture_damage(magic_attack: int, percent: int) -> int:
	return (CombatConfig.GESTURE_BASE_DAMAGE + maxi(magic_attack, 0)) * percent / CharacterConfig.PERCENT_DIVISOR


## Effective `stat` above the baseline 10 (never below 0).
func _above_baseline(stat: String) -> int:
	return maxi(get_effective(stat) - CharacterConfig.STAT_BASELINE, 0)


func get_attack_range() -> int:
	return int(_compat()["attack_range"])


## What a battle builds this character's CombatUnit from (CombatUnit.create
## keys): Max HP, the Basic Attack profile, Magic Attack and the defenses.
func get_combat_profile() -> Dictionary:
	return {
		"max_hp": get_max_hp(),
		"attack_damage": get_physical_attack(),
		"attack_range": get_attack_range(),
		"attack_interval_ms": get_attack_interval_ms(),
		"move_speed": get_move_speed(),
		"magic_attack": get_magic_attack(),
		"physical_defense": get_physical_defense(),
		"magic_defense": get_magic_defense(),
	}


func _compat() -> Dictionary:
	return CharacterConfig.COMBAT_COMPAT[character_id]


func _is_valid(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and value >= 0 and value <= CharacterConfig.MAX_STAT
