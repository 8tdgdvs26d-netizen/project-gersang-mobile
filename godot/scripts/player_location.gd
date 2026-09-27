class_name PlayerLocation
extends RefCounted

## Where the main character is: in the world, inside a city, or on a paid
## passenger journey. It owns its own save representation and validation.
##
## city_id meaning per mode:
## - WORLD: the city last left ("" = none); only context, the exact position
##   is `world_position`.
## - IN_CITY: the city whose hub is open.
## - TRAVELING: always "" (the journey holds origin and destination).
##
## world_position (T06): the exact world position, present only in WORLD mode
## (null while IN_CITY or TRAVELING, which have no world position). It must be
## finite and inside the playable world rect (where the player can stand);
## saved data outside it is rejected, never clamped. Leaving a city places the
## player at that city's approved return point.
##
## Only the main character has a location for now. A future party can travel
## alongside it without changing this journey record.

const MODE_WORLD := "WORLD"
const MODE_IN_CITY := "IN_CITY"
const MODE_TRAVELING := "TRAVELING"
const MODES := [MODE_WORLD, MODE_IN_CITY, MODE_TRAVELING]
const STATUS_NONE := "none"
const STATUS_TRAVELING := "traveling"
## Corruption guard: no legitimate prototype journey lasts longer than a day.
const MAX_JOURNEY_DURATION_MS := 86400000
const MAX_JOURNEY_ID_LENGTH := 64
const MAX_TIME_MS := 9007199254740992
const KEYS := ["mode", "city_id", "journey", "last_journey_id", "world_position"]
## Save versions 4-7 had no exact world position.
const LEGACY_KEYS := ["mode", "city_id", "journey", "last_journey_id"]
const POSITION_KEYS := ["x", "y"]
## Where a brand-new character (or a legacy WORLD save with no city context)
## stands: the approved initial world spawn of the main scene.
const DEFAULT_WORLD_SPAWN := Vector2(420.0, 500.0)
## The playable world rect: the same limits the player's movement is clamped to.
const PLAYABLE_MIN := WorldBoundary.BOUNDS.position + Player.BOUNDARY_MIN_OFFSET
const PLAYABLE_MAX := WorldBoundary.BOUNDS.end - Player.BOUNDARY_MAX_OFFSET
const JOURNEY_KEYS := ["journey_id", "status", "origin_city_id", "destination_city_id", "started_at_ms", "arrives_at_ms", "fare"]

var _mode := MODE_WORLD
var _city_id := ""
var _journey := {}
## Id of the most recently started journey, kept after arrival so the same
## request can never start (and charge) a second journey.
var _last_journey_id := ""
## Exact world position; only meaningful (and only non-null) in WORLD mode.
var _world_position: Variant = DEFAULT_WORLD_SPAWN


func get_mode() -> String:
	return _mode


func get_city_id() -> String:
	return _city_id


func is_in_world() -> bool:
	return _mode == MODE_WORLD


func is_in_city() -> bool:
	return _mode == MODE_IN_CITY


func is_traveling() -> bool:
	return _mode == MODE_TRAVELING


func get_journey_status() -> String:
	return STATUS_TRAVELING if is_traveling() else STATUS_NONE


func get_journey() -> Dictionary:
	return _journey.duplicate()


func get_last_journey_id() -> String:
	return _last_journey_id


## The exact world position (a Vector2) in WORLD mode, otherwise null.
func get_world_position() -> Variant:
	return _world_position if is_in_world() else null


## Records the player's current world position. Only in WORLD mode and only a
## valid position; anything else is refused and changes nothing.
func set_world_position(position: Variant) -> bool:
	if not is_in_world() or not is_valid_world_position(position):
		return false
	_world_position = position
	return true


## A finite Vector2 inside the playable world rect (edges included).
static func is_valid_world_position(position: Variant) -> bool:
	if typeof(position) != TYPE_VECTOR2 or not position.is_finite():
		return false
	return position.x >= PLAYABLE_MIN.x and position.x <= PLAYABLE_MAX.x \
		and position.y >= PLAYABLE_MIN.y and position.y <= PLAYABLE_MAX.y


func enter_city(city_id: Variant) -> bool:
	if not is_in_world() or not _is_active_city(city_id):
		return false
	_mode = MODE_IN_CITY
	_city_id = city_id
	_world_position = null
	return true


## Leaving places the player at the city's approved return point and keeps
## the city as the world context.
func leave_city() -> bool:
	if not is_in_city():
		return false
	_mode = MODE_WORLD
	_world_position = WorldLayout.CITY_RETURN_POINTS[_city_id]
	return true


func start_journey(journey: Dictionary) -> bool:
	if not is_in_city() or not is_valid_journey(journey) or journey["origin_city_id"] != _city_id:
		return false
	if journey["journey_id"] == _last_journey_id:
		return false
	_mode = MODE_TRAVELING
	_city_id = ""
	_world_position = null
	_journey = journey.duplicate()
	_last_journey_id = journey["journey_id"]
	return true


## Ends the current journey inside its destination city. Returns the city id,
## or "" when there is no journey (so a journey can only complete once).
func complete_journey() -> String:
	if not is_traveling() or _journey.is_empty():
		return ""
	var destination: String = _journey["destination_city_id"]
	_mode = MODE_IN_CITY
	_city_id = destination
	_journey = {}
	return destination


func to_dict() -> Dictionary:
	return {
		"mode": _mode,
		"city_id": _city_id,
		"journey": _journey.duplicate() if is_traveling() else null,
		"last_journey_id": _last_journey_id,
		"world_position": {"x": _world_position.x, "y": _world_position.y} if is_in_world() else null,
	}


## Replaces this location with a validated snapshot (used for rollback).
func restore(data: Variant) -> bool:
	var parsed := from_dict(data)
	if parsed == null:
		return false
	_mode = parsed._mode
	_city_id = parsed._city_id
	_journey = parsed._journey
	_last_journey_id = parsed._last_journey_id
	_world_position = parsed._world_position
	return true


## Builds a location from saved data (current shape), or returns null if
## anything is invalid: WORLD needs a valid world_position, IN_CITY and
## TRAVELING need world_position = null. JSON numbers arrive as floats; journey
## values must be exact non-negative integers.
static func from_dict(data: Variant) -> PlayerLocation:
	if typeof(data) != TYPE_DICTIONARY or not _has_exactly(data, KEYS):
		return null
	var location := _from_fields(data)
	if location == null:
		return null
	if location.is_in_world():
		var position: Variant = _parse_position(data["world_position"])
		if position == null:
			return null
		location._world_position = position
	elif data["world_position"] != null:
		return null
	else:
		location._world_position = null
	return location


## Migrates a location saved before T06 (save versions 4-7, no exact world
## position). Deterministic: WORLD with a city context -> that city's return
## point; WORLD without one -> the default world spawn; IN_CITY and TRAVELING
## keep their meaning. No historical exact position is invented.
static func from_legacy_dict(data: Variant) -> PlayerLocation:
	if typeof(data) != TYPE_DICTIONARY or not _has_exactly(data, LEGACY_KEYS):
		return null
	var location := _from_fields(data)
	if location == null:
		return null
	if location.is_in_world():
		location._world_position = WorldLayout.CITY_RETURN_POINTS.get(location._city_id, DEFAULT_WORLD_SPAWN)
	else:
		location._world_position = null
	return location


## Validates everything but the world position.
static func _from_fields(data: Dictionary) -> PlayerLocation:
	var mode: Variant = data["mode"]
	var city_id: Variant = data["city_id"]
	var last_id: Variant = data["last_journey_id"]
	if typeof(mode) != TYPE_STRING or not mode in MODES or typeof(city_id) != TYPE_STRING:
		return null
	if typeof(last_id) != TYPE_STRING or last_id.length() > MAX_JOURNEY_ID_LENGTH:
		return null
	var location := PlayerLocation.new()
	location._mode = mode
	location._city_id = city_id
	location._last_journey_id = last_id
	if mode == MODE_TRAVELING:
		var journey := _parse_journey(data["journey"])
		if journey.is_empty() or city_id != "" or journey["journey_id"] != last_id:
			return null
		location._journey = journey
		return location
	if data["journey"] != null:
		return null
	if mode == MODE_IN_CITY and not _is_active_city(city_id):
		return null
	if mode == MODE_WORLD and city_id != "" and not _is_active_city(city_id):
		return null
	return location


## {"x": float, "y": float} -> a valid Vector2, or null. Only real numbers are
## accepted (JSON has no NaN / infinity; strings, bools and nulls are refused).
static func _parse_position(data: Variant) -> Variant:
	if typeof(data) != TYPE_DICTIONARY or not _has_exactly(data, POSITION_KEYS):
		return null
	for key in POSITION_KEYS:
		if not typeof(data[key]) in [TYPE_FLOAT, TYPE_INT]:
			return null
	var position := Vector2(float(data["x"]), float(data["y"]))
	return position if is_valid_world_position(position) else null


static func is_valid_journey(journey: Variant) -> bool:
	return not _parse_journey(journey).is_empty()


static func _parse_journey(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY or not _has_exactly(data, JOURNEY_KEYS):
		return {}
	var journey_id: Variant = data["journey_id"]
	var origin: Variant = data["origin_city_id"]
	var destination: Variant = data["destination_city_id"]
	if typeof(journey_id) != TYPE_STRING or journey_id == "" or journey_id.length() > MAX_JOURNEY_ID_LENGTH:
		return {}
	if data["status"] != STATUS_TRAVELING or not _is_active_city(origin) or not _is_active_city(destination) or origin == destination:
		return {}
	var started := _exact_int(data["started_at_ms"])
	var arrives := _exact_int(data["arrives_at_ms"])
	var fare := _exact_int(data["fare"])
	if started < 0 or arrives <= started or arrives - started > MAX_JOURNEY_DURATION_MS or fare <= 0:
		return {}
	return {
		"journey_id": journey_id,
		"status": STATUS_TRAVELING,
		"origin_city_id": origin,
		"destination_city_id": destination,
		"started_at_ms": started,
		"arrives_at_ms": arrives,
		"fare": fare,
	}


static func _is_active_city(city_id: Variant) -> bool:
	return typeof(city_id) == TYPE_STRING and city_id in WorldLayout.ACTIVE_CITY_IDS


static func _has_exactly(data: Dictionary, keys: Array) -> bool:
	if data.size() != keys.size():
		return false
	for key in keys:
		if not data.has(key):
			return false
	return true


static func _exact_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return value if value >= 0 and value <= MAX_TIME_MS else -1
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) \
		and value >= 0.0 and value <= float(MAX_TIME_MS):
		return int(value)
	return -1
