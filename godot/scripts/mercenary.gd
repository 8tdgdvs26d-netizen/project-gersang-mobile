class_name Mercenary
extends RefCounted

## Stage 8 P01: one owned Mercenary instance (runtime data foundation only:
## not saved, not in combat, no UI). Identity is its stable unique id, never
## its type or its place in a roster: several instances may share a type and
## each carries its own Stage 7 progression — Level, EXP (the S03 curve,
## ProgressionState) and Stat Point allocation (S04 rules: (Level - 1) x 3
## points, HP / STR / AGI / INT, whole points, never beyond the earned ones).
## The type is a reference only: no stats, growth or skills are defined here.
##
## Prototype types (internal ids; player names 守衛 / 法師 / 軍師 come with
## the Mercenary Center WP): GUARDIAN, MAGE, STRATEGIST. The Stage 7 Merc A /
## Merc B are NOT converted (approved: a later Save v11 WP maps merc_a ->
## GUARDIAN and merc_b -> MAGE, keeping their ids and progression).

const TYPES := ["GUARDIAN", "MAGE", "STRATEGIST"]
## Reserved: the Hero is never a Mercenary.
const HERO_ID := "hero"
## Ids: lowercase letters, digits and _, 1-32 characters.
const ID_PATTERN := "^[a-z0-9_]{1,32}$"
const KEYS := ["id", "type", "level", "exp", "allocation"]

var _id := ""
var _type := ""
var _level := ProgressionState.START_LEVEL
var _exp := 0
var _allocation := CharacterStats.zero_allocation()


## A new instance, or null when any part is invalid (nothing is repaired):
## a valid id and type, START_LEVEL <= level <= MAX_LEVEL, 0 <= exp below the
## Level's requirement (0 at the cap), allocation exactly {hp, str, agi, int}
## whole points >= 0 within the Level's earned points.
static func create(id: Variant, type: Variant, level: Variant = ProgressionState.START_LEVEL, held_exp: Variant = 0, allocation: Variant = CharacterStats.zero_allocation()) -> Mercenary:
	if not is_valid_id(id) or not is_valid_type(type):
		return null
	var whole_level: Variant = _whole(level)
	var whole_exp: Variant = _whole(held_exp)
	if whole_level == null or whole_exp == null or whole_level < ProgressionState.START_LEVEL or whole_level > ProgressionState.MAX_LEVEL:
		return null
	if whole_exp < 0 or (whole_level >= ProgressionState.MAX_LEVEL and whole_exp != 0) \
			or (whole_level < ProgressionState.MAX_LEVEL and whole_exp >= ProgressionState.required_exp(whole_level)):
		return null
	var points := _valid_allocation(allocation, whole_level)
	if points.is_empty():
		return null
	var mercenary := Mercenary.new()
	mercenary._id = id
	mercenary._type = type
	mercenary._level = whole_level
	mercenary._exp = whole_exp
	mercenary._allocation = points
	return mercenary


static func is_valid_type(type: Variant) -> bool:
	return typeof(type) == TYPE_STRING and TYPES.has(type)


static func is_valid_id(id: Variant) -> bool:
	if typeof(id) != TYPE_STRING or id == HERO_ID:
		return false
	var pattern := RegEx.new()
	pattern.compile(ID_PATTERN)
	return pattern.search(id) != null


func get_id() -> String:
	return _id


func get_type() -> String:
	return _type


func get_level() -> int:
	return _level


func get_exp() -> int:
	return _exp


## {hp, str, agi, int} confirmed points (a copy).
func get_allocation_points() -> Dictionary:
	return _allocation.duplicate()


func get_earned_points() -> int:
	return CharacterStats.earned_points_for(_level)


func get_spent_points() -> int:
	var spent := 0
	for stat in CharacterConfig.ALLOCATABLE:
		spent += int(_allocation[stat])
	return spent


func get_unspent_points() -> int:
	return maxi(get_earned_points() - get_spent_points(), 0)


## Gains `amount` EXP on the Stage 7 curve (several Levels at once, nothing
## kept at the cap). Refused for anything but a whole amount >= 0.
func add_exp(amount: Variant) -> bool:
	if typeof(amount) != TYPE_INT or amount < 0:
		return false
	var after := ProgressionState.advance(_level, _exp, amount)
	_level = after[0]
	_exp = after[1]
	return true


## Confirms {stat: points} at once, as CharacterStats.confirm_allocation:
## refused as a whole unless every stat is allocatable, every amount a whole
## number >= 0, at least one point and no more than the unspent points.
func allocate(pending: Dictionary) -> bool:
	var total := 0
	for stat in pending:
		var points: Variant = pending[stat]
		if not CharacterConfig.ALLOCATABLE.has(stat) or typeof(points) != TYPE_INT or points < 0:
			return false
		total += points
	if total <= 0 or total > get_unspent_points():
		return false
	for stat in pending:
		_allocation[stat] = int(_allocation[stat]) + int(pending[stat])
	return true


func to_dict() -> Dictionary:
	return {"id": _id, "type": _type, "level": _level, "exp": _exp, "allocation": _allocation.duplicate()}


## A validated instance from to_dict() data (exactly KEYS), or null.
static func from_dict(data: Variant) -> Mercenary:
	if typeof(data) != TYPE_DICTIONARY or data.size() != KEYS.size() or not data.has_all(KEYS):
		return null
	return create(data["id"], data["type"], data["level"], data["exp"], data["allocation"])


## The allocation as int points, or {} when invalid for `level`.
static func _valid_allocation(points: Variant, level: int) -> Dictionary:
	if typeof(points) != TYPE_DICTIONARY or points.size() != CharacterConfig.ALLOCATABLE.size() or not points.has_all(CharacterConfig.ALLOCATABLE):
		return {}
	var result := {}
	var spent := 0
	for stat in CharacterConfig.ALLOCATABLE:
		var value: Variant = _whole(points[stat])
		if value == null or value < 0:
			return {}
		result[stat] = value
		spent += value
	if spent > CharacterStats.earned_points_for(level):
		return {}
	return result


## An integer (ints and whole floats), else null.
static func _whole(value: Variant) -> Variant:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) and absf(value) <= ProgressionState.MAX_EXP:
		return int(value)
	return null
