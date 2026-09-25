class_name Wallet
extends RefCounted

## Player money model, independent of any UI. Money is a non-negative int and
## only changes through validated spend/add calls. The starting balance is a
## TEST VALUE, not a locked formal starting fund.

const STARTING_MONEY := 10000
const MAX_BALANCE := 9223372036854775807

var _balance := STARTING_MONEY


func get_balance() -> int:
	return _balance


func can_spend(amount: Variant) -> bool:
	return _is_positive_int(amount) and amount <= _balance


func spend(amount: Variant) -> bool:
	if not can_spend(amount):
		return false
	_balance -= amount
	return true


func can_add(amount: Variant) -> bool:
	# Compare against the headroom first so the sum itself can never overflow.
	return _is_positive_int(amount) and amount <= MAX_BALANCE - _balance


func add(amount: Variant) -> bool:
	if not can_add(amount):
		return false
	_balance += amount
	return true


func _is_positive_int(amount: Variant) -> bool:
	return typeof(amount) == TYPE_INT and amount > 0
