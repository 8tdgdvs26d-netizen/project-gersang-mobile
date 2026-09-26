class_name PlayerLocation
extends RefCounted

## Where the main character is: in the world, inside a city, or on a paid
## passenger journey. It owns its own save representation and validation.
##
## city_id meaning per mode:
## - WORLD: the city last left, whose return point is used after a reopen
##   ("" = the normal world spawn). Exact world coordinates are not stored.
## - IN_CITY: the city whose hub is open.
## - TRAVELING: always "" (the journey holds origin and destination).
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
const KEYS := ["mode", "city_id", "journey", "last_journey_id"]
const JOURNEY_KEYS := ["journey_id", "status", "origin_city_id", "destination_city_id", "started_at_ms", "arrives_at_ms", "fare"]

var _mode := MODE_WORLD
var _city_id := ""
var _journey := {}
## Id of the most recently started journey, kept after arrival so the same
## request can never start (and charge) a second journey.
var _last_journey_id := ""


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


func enter_city(city_id: Variant) -> bool:
	if not is_in_world() or not _is_active_city(city_id):
		return false
	_mode = MODE_IN_CITY
	_city_id = city_id
	return true


## Leaving keeps the city as the world return context.
func leave_city() -> bool:
	if not is_in_city():
		return false
	_mode = MODE_WORLD
	return true


func start_journey(journey: Dictionary) -> bool:
	if not is_in_city() or not is_valid_journey(journey) or journey["origin_city_id"] != _city_id:
		return false
	if journey["journey_id"] == _last_journey_id:
		return false
	_mode = MODE_TRAVELING
	_city_id = ""
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
	return true


## Builds a location from saved data, or returns null if anything is invalid.
## JSON numbers arrive as floats; only exact non-negative integers are accepted.
static func from_dict(data: Variant) -> PlayerLocation:
	if typeof(data) != TYPE_DICTIONARY or not _has_exactly(data, KEYS):
		return null
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
