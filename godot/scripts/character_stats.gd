class_name CharacterStats
extends RefCounted

## Minimal character-stat interface for M2-08. These values are PROTOTYPE
## PARAMETERS used to prove that inventory capacity comes from Strength; they
## are not the formal Strength or carrying-balance formula.
const PROTOTYPE_DEFAULT_STRENGTH := 10
const PROTOTYPE_BASE_CAPACITY := 10
const PROTOTYPE_CAPACITY_PER_STRENGTH := 1
const MAX_STRENGTH := 1000000

var _strength: int


func _init(strength: int = PROTOTYPE_DEFAULT_STRENGTH) -> void:
	_strength = strength if _is_valid_strength(strength) else PROTOTYPE_DEFAULT_STRENGTH


func get_strength() -> int:
	return _strength


func set_strength(strength: Variant) -> bool:
	if not _is_valid_strength(strength):
		return false
	_strength = strength
	return true


func get_max_capacity() -> int:
	return PROTOTYPE_BASE_CAPACITY + _strength * PROTOTYPE_CAPACITY_PER_STRENGTH


func _is_valid_strength(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and value >= 0 and value <= MAX_STRENGTH
