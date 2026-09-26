class_name TransportRoutes
extends RefCounted

## Authoritative intercity passenger route data.
##
## PROTOTYPE PARAMETERS — the fares and travel durations below are test values
## for the two active Stage 2 cities. They are NOT formal balance and must be
## re-tuned from playtest evidence. They are deliberately not derived from the
## old Phaser bus formula. (Walking A↔B is about 180 seconds.)
##
## Routes carry passengers only; they have no cargo, storage or capacity data.

const ROUTES := {
	"A": {"B": {"fare": 300, "duration_ms": 90000}},
	"B": {"A": {"fare": 300, "duration_ms": 90000}},
}


## Returns {"fare", "duration_ms"} for an active route, or {} if none exists.
static func get_route(origin_city_id: Variant, destination_city_id: Variant) -> Dictionary:
	if typeof(origin_city_id) != TYPE_STRING or typeof(destination_city_id) != TYPE_STRING:
		return {}
	var from: Dictionary = ROUTES.get(origin_city_id, {})
	var route: Dictionary = from.get(destination_city_id, {})
	return route.duplicate()


## Destination city ids reachable from a city, in a stable order.
static func get_destinations(origin_city_id: Variant) -> Array:
	if typeof(origin_city_id) != TYPE_STRING or not ROUTES.has(origin_city_id):
		return []
	var destinations: Array = ROUTES[origin_city_id].keys()
	destinations.sort()
	return destinations
