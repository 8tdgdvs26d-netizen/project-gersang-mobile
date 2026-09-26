class_name TransportService
extends RefCounted

## UI-independent intercity paid PASSENGER transport.
##
## Transport moves the main character between cities; it never moves items.
## This service must never receive or change CharacterInventory,
## CharacterStats, MarketState, Cargo or any warehouse: goods the character
## carries simply stay in their personal inventory, and the vehicle adds no
## capacity, storage or freight of any kind.
##
## PROTOTYPE LIMITATION: journeys currently have no world encounters.
## Transport risk / encounter interaction must be revisited when Stage 3 Encounter system is integrated.
## This is not a permanent "safe transport" design rule.
##
## Every check runs before any state changes. A journey is charged once,
## rolled back completely if it cannot be created or saved, and settles
## exactly once.

const ERR_INVALID_STATE := "ERR_INVALID_STATE"
const ERR_INVALID_REQUEST := "ERR_INVALID_REQUEST"
const ERR_DUPLICATE_REQUEST := "ERR_DUPLICATE_REQUEST"
const ERR_ALREADY_TRAVELING := "ERR_ALREADY_TRAVELING"
const ERR_NOT_IN_CITY := "ERR_NOT_IN_CITY"
const ERR_INVALID_DESTINATION := "ERR_INVALID_DESTINATION"
const ERR_ALREADY_THERE := "ERR_ALREADY_THERE"
const ERR_TRANSPORT_UNAVAILABLE := "ERR_TRANSPORT_UNAVAILABLE"
const ERR_INSUFFICIENT_FUNDS := "ERR_INSUFFICIENT_FUNDS"
const ERR_JOURNEY_FAILED := "ERR_JOURNEY_FAILED"
const ERR_SAVE_FAILED := "ERR_SAVE_FAILED"
const ERR_NOT_TRAVELING := "ERR_NOT_TRAVELING"
const ERR_NOT_ARRIVED := "ERR_NOT_ARRIVED"
const ERR_ARRIVAL_FAILED := "ERR_ARRIVAL_FAILED"


## Fare and duration for a route, independent of the player's state.
static func quote(origin_city_id: Variant, destination_city_id: Variant) -> Dictionary:
	var reason := _destination_error(origin_city_id, destination_city_id)
	if reason != "":
		return {"success": false, "reason": reason, "fare": 0, "duration_ms": 0}
	var route := TransportRoutes.get_route(origin_city_id, destination_city_id)
	return {"success": true, "reason": "", "fare": route["fare"], "duration_ms": route["duration_ms"]}


## Pays the fare and starts a journey from the current city. `persist` saves
## the new state and returns true; if it fails, money and location are rolled
## back and nothing is charged.
static func begin_journey(location: PlayerLocation, wallet: Wallet, destination_city_id: Variant, request_id: Variant, now_ms: Variant, persist: Callable = Callable()) -> Dictionary:
	if location == null or wallet == null:
		return _result(false, ERR_INVALID_STATE)
	if typeof(request_id) != TYPE_STRING or request_id == "" or request_id.length() > PlayerLocation.MAX_JOURNEY_ID_LENGTH:
		return _result(false, ERR_INVALID_REQUEST)
	if request_id == location.get_last_journey_id():
		return _result(false, ERR_DUPLICATE_REQUEST)
	if location.is_traveling():
		return _result(false, ERR_ALREADY_TRAVELING)
	if not location.is_in_city():
		return _result(false, ERR_NOT_IN_CITY)
	var origin := location.get_city_id()
	var offer := quote(origin, destination_city_id)
	if not offer["success"]:
		return _result(false, offer["reason"])
	if typeof(now_ms) != TYPE_INT or now_ms < 0 or now_ms > PlayerLocation.MAX_TIME_MS - offer["duration_ms"]:
		return _result(false, ERR_INVALID_STATE)
	var fare: int = offer["fare"]
	if not wallet.can_spend(fare):
		return _result(false, ERR_INSUFFICIENT_FUNDS, {"fare": fare})

	var location_before := location.to_dict()
	var journey := {
		"journey_id": request_id,
		"status": PlayerLocation.STATUS_TRAVELING,
		"origin_city_id": origin,
		"destination_city_id": destination_city_id,
		"started_at_ms": now_ms,
		"arrives_at_ms": now_ms + offer["duration_ms"],
		"fare": fare,
	}
	if not wallet.spend(fare):
		return _result(false, ERR_INVALID_STATE)
	if not location.start_journey(journey):
		_rollback(location, location_before, wallet, fare)
		return _result(false, ERR_JOURNEY_FAILED)
	if persist.is_valid() and not persist.call():
		_rollback(location, location_before, wallet, fare)
		return _result(false, ERR_SAVE_FAILED)
	return _result(true, "", {"journey": journey.duplicate(), "fare": fare})


## Completes the current journey once its arrival time has been reached. The
## character arrives inside the destination city only if the arrival is also
## saved: when `persist` fails, the journey is restored exactly, so runtime
## and save both still hold the same unfinished journey and the caller can
## retry. A journey therefore settles exactly once, and settling never
## charges or refunds money.
static func settle_arrival(location: PlayerLocation, now_ms: Variant, persist: Callable = Callable()) -> Dictionary:
	if location == null or typeof(now_ms) != TYPE_INT:
		return _result(false, ERR_INVALID_STATE)
	if not location.is_traveling():
		return _result(false, ERR_NOT_TRAVELING)
	var journey := location.get_journey()
	if now_ms < journey["arrives_at_ms"]:
		return _result(false, ERR_NOT_ARRIVED)
	var location_before := location.to_dict()
	var city_id := location.complete_journey()
	if city_id == "":
		return _result(false, ERR_ARRIVAL_FAILED)
	if persist.is_valid() and not persist.call():
		location.restore(location_before)
		return _result(false, ERR_SAVE_FAILED)
	return _result(true, "", {"city_id": city_id, "journey_id": journey["journey_id"]})


## Milliseconds left on the current journey (0 when none or already due).
static func remaining_ms(location: PlayerLocation, now_ms: int) -> int:
	if location == null or not location.is_traveling():
		return 0
	return maxi(location.get_journey()["arrives_at_ms"] - now_ms, 0)


static func _destination_error(origin_city_id: Variant, destination_city_id: Variant) -> String:
	if typeof(destination_city_id) != TYPE_STRING or not WorldLayout.CITY_ANCHORS.has(destination_city_id):
		return ERR_INVALID_DESTINATION
	if typeof(origin_city_id) != TYPE_STRING or not WorldLayout.CITY_ANCHORS.has(origin_city_id):
		return ERR_NOT_IN_CITY
	if destination_city_id == origin_city_id:
		return ERR_ALREADY_THERE
	if TransportRoutes.get_route(origin_city_id, destination_city_id).is_empty():
		return ERR_TRANSPORT_UNAVAILABLE
	return ""


static func _rollback(location: PlayerLocation, location_before: Dictionary, wallet: Wallet, fare: int) -> void:
	location.restore(location_before)
	wallet.add(fare)


static func _result(success: bool, reason: String, extra: Dictionary = {}) -> Dictionary:
	var result := {"success": success, "reason": reason}
	result.merge(extra)
	return result
