extends CharacterStats

## Test-only CharacterStats with a fixed maximum capacity. Older rule tests
## (fill exactly, then reject one more unit) were written for a capacity of
## 20; they use this fixture so they keep verifying the capacity rules at that
## size, independent of the current prototype backpack balance (Strength 10
## gives 100 from T02). The real balance is verified separately.


var _fixed_capacity: int


func _init(capacity: int = 20) -> void:
	super(PROTOTYPE_DEFAULT_STRENGTH)
	_fixed_capacity = capacity


func get_max_capacity() -> int:
	return _fixed_capacity
