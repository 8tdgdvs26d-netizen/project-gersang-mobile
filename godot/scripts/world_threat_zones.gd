class_name WorldThreatZones
extends RefCounted

## World Threat WT03: the spatial rules of world danger, as fixed layout data
## (never random, never saved; membership is always derived from a position).
##
##   CITY SAFE BUFFER  a circle around every active city: covers the entry
##                     trigger and the return point, so leaving a city starts
##                     safe. The world threat never aggroes, keeps chasing or
##                     reports contact in here.
##   THREAT ZONE       one prototype low-level threat area (the future outer
##                     Level 1–4 areas; spatial intent only, no enemy levels).
##                     It holds the prototype monster's home.
##
## Only these two concepts exist: no zone framework, no other levels or bosses.

## Prototype radius of every city safe buffer, around the city anchor. The
## entry trigger reaches 240 px and the return point sits 340 px out, so the
## player has 80 px of safe ground past the return point.
const CITY_SAFE_BUFFER_RADIUS := 420.0

const LOW_THREAT_ZONE_01_ID := "low_threat_zone_01"
## South-east of City A: x 560–1240, y 450–1030 (E02: grown east and south
## from x 560–1000, y 450–850 to hold the three prototype groups; the
## top-left corner, nearest City A, is unchanged). It holds group 1's home
## (760, 650) and its whole 200 px aggro circle, every group's home and patrol
## loop, and stays clear of City A's safe buffer.
const LOW_THREAT_ZONE_01 := Rect2(560.0, 450.0, 680.0, 580.0)


## Id of the active city whose safe buffer contains `position` ("" if none).
static func safe_buffer_city_at(position: Vector2) -> String:
	for city_id in WorldLayout.ACTIVE_CITY_IDS:
		if position.distance_to(WorldLayout.CITY_ANCHORS[city_id]) <= CITY_SAFE_BUFFER_RADIUS:
			return city_id
	return ""


static func is_in_city_safe_buffer(position: Vector2) -> bool:
	return safe_buffer_city_at(position) != ""


## Id of the threat zone containing `position` ("" if none).
static func threat_zone_at(position: Vector2) -> String:
	if LOW_THREAT_ZONE_01.has_point(position):
		return LOW_THREAT_ZONE_01_ID
	return ""
