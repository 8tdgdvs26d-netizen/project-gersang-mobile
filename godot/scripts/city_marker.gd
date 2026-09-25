class_name CityMarker
extends Area2D

## Prototype city landmark with a minimal entry trigger. It only reports
## whether the player is inside; city content belongs to a later package.

signal player_entered_city(city_id: String)
signal player_exited_city(city_id: String)

@export var city_id := "A"

var _player_inside := false


func _ready() -> void:
	position = WorldLayout.CITY_ANCHORS[city_id]
	($NameLabel as Label).text = "City %s (prototype)" % city_id
	($EnterLabel as Label).visible = false
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func is_player_inside() -> bool:
	return _player_inside


## Direct geometric check of a body rectangle against the trigger circle.
## The Area2D overlap only updates a few physics frames after a teleport,
## so entry also checks where the player actually is right now.
func trigger_overlaps(rect: Rect2) -> bool:
	var radius := (($TriggerShape as CollisionShape2D).shape as CircleShape2D).radius
	var closest := global_position.clamp(rect.position, rect.end)
	return closest.distance_to(global_position) <= radius


func _on_body_entered(body: Node2D) -> void:
	if body is Player:
		_player_inside = true
		($EnterLabel as Label).visible = true
		player_entered_city.emit(city_id)


func _on_body_exited(body: Node2D) -> void:
	if body is Player:
		_player_inside = false
		($EnterLabel as Label).visible = false
		player_exited_city.emit(city_id)
