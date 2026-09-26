class_name TimeSource
extends RefCounted

## The single clock gameplay code reads (milliseconds since the Unix epoch).
## The prototype uses local system time; tests switch an instance to a fixed,
## manually advanced time, and a future server-authoritative clock can replace
## this object without touching gameplay code. Gameplay scripts must not call
## Time / OS clock functions directly.

var _fixed_ms := -1


## A clock frozen at `ms` that only moves through set_now_ms / advance_ms.
static func fixed(ms: int) -> TimeSource:
	var source := TimeSource.new()
	source.set_now_ms(ms)
	return source


func now_ms() -> int:
	if _fixed_ms >= 0:
		return _fixed_ms
	return int(Time.get_unix_time_from_system() * 1000.0)


func is_fixed() -> bool:
	return _fixed_ms >= 0


func set_now_ms(ms: int) -> void:
	_fixed_ms = maxi(ms, 0)


func advance_ms(delta_ms: int) -> void:
	set_now_ms(now_ms() + delta_ms)
