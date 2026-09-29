class_name ThreatZoneOverlay
extends Node2D

## World Threat WT03: prototype / debug-quality ground markings for the city
## safe buffers (faint green) and the low-level threat zone (faint red), each
## with a small Traditional Chinese label. Drawn under the cities and actors,
## straight from WorldThreatZones; it holds no state and changes no rules.

const SAFE_TEXT := "安全區"
const THREAT_TEXT := "低級威脅區"
const SAFE_FILL := Color(0.4, 0.8, 0.55, 0.06)
const SAFE_LINE := Color(0.4, 0.8, 0.55, 0.35)
const THREAT_FILL := Color(0.85, 0.3, 0.25, 0.07)
const THREAT_LINE := Color(0.85, 0.3, 0.25, 0.35)
const LINE_WIDTH := 3.0
## The safe-area label sits this far below each city anchor (inside the buffer,
## clear of the city's own labels).
const SAFE_LABEL_OFFSET := Vector2(0.0, 300.0)


func _ready() -> void:
	for city_id in WorldLayout.ACTIVE_CITY_IDS:
		_add_label("SafeLabel%s" % city_id, SAFE_TEXT, WorldLayout.CITY_ANCHORS[city_id] + SAFE_LABEL_OFFSET, SAFE_LINE)
	var zone := WorldThreatZones.LOW_THREAT_ZONE_01
	_add_label("ThreatLabel", THREAT_TEXT, Vector2(zone.get_center().x, zone.position.y + 22.0), THREAT_LINE)


func _draw() -> void:
	for city_id in WorldLayout.ACTIVE_CITY_IDS:
		var center: Vector2 = WorldLayout.CITY_ANCHORS[city_id]
		draw_circle(center, WorldThreatZones.CITY_SAFE_BUFFER_RADIUS, SAFE_FILL)
		draw_arc(center, WorldThreatZones.CITY_SAFE_BUFFER_RADIUS, 0.0, TAU, 96, SAFE_LINE, LINE_WIDTH)
	var zone := WorldThreatZones.LOW_THREAT_ZONE_01
	draw_rect(zone, THREAT_FILL)
	draw_rect(zone, THREAT_LINE, false, LINE_WIDTH)


func _add_label(node_name: String, text: String, center: Vector2, color: Color) -> void:
	var label := Label.new()
	label.name = node_name
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(color, 0.8))
	label.size = Vector2(240.0, 30.0)
	label.position = center - label.size / 2.0
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
