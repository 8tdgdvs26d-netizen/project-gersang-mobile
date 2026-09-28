class_name WorldMonster
extends Area2D

## World Threat WT01: one visible prototype monster with a contact area. It
## only reports contact; encounters and combat belong to later work packages.
##
## Contact is edge-triggered: one player_contacted event when the player
## enters the area, none while the player stays inside, and a new one only
## after the player has left and entered again. While inactive (the main scene
## activates it only in WORLD mode) it reports nothing.

signal player_contacted(monster_id: String)

var monster_id := WorldLayout.PROTOTYPE_MONSTER_ID

var _active := true
var _in_contact := false


func _ready() -> void:
	position = WorldLayout.PROTOTYPE_MONSTER_POSITION
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func is_threat_active() -> bool:
	return _active


## True between a reported contact and the player leaving the area.
func is_in_contact() -> bool:
	return _in_contact


## Only WORLD mode activates the threat. Deactivating clears the current
## contact, so no contact state carries over from before a city or a journey.
func set_threat_active(active: bool) -> void:
	_active = active
	if not active:
		_in_contact = false


func _on_body_entered(body: Node2D) -> void:
	if not body is Player or not _active or _in_contact:
		return
	_in_contact = true
	print("Myrial: world threat contact ", monster_id)
	player_contacted.emit(monster_id)


func _on_body_exited(body: Node2D) -> void:
	if body is Player:
		_in_contact = false
