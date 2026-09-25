extends Node2D

## Minimal world/city state controller. The world scene stays loaded; entering
## a city pauses world movement and shows the shared City Hub overlay.

const BOOTSTRAP_VERSION := "M2-05"
## Each market button press trades exactly one unit.
const MARKET_TRADE_QUANTITY := 1

var current_city_id := ""
## Session-owned player cargo. World/city transitions never reset it;
## it only resets when the game restarts (no disk save yet).
var cargo := Cargo.new()
## Session-owned player money, with the same lifetime as the cargo.
var wallet := Wallet.new()
var _city_markers := {}

@onready var _player := $Actors/Player as Player
@onready var _joystick := $TouchControls/Joystick as TouchJoystick
@onready var _city_hub := $CityHub as CityHub


func _ready() -> void:
	for child in $Cities.get_children():
		if child is CityMarker and child.city_id in WorldLayout.ACTIVE_CITY_IDS:
			_city_markers[child.city_id] = child
	_city_hub.leave_requested.connect(leave_city)
	_city_hub.buy_requested.connect(_on_market_buy_requested)
	_city_hub.sell_requested.connect(_on_market_sell_requested)
	print("Myrial: Unwritten ", BOOTSTRAP_VERSION, " minimal player market ready")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact") and not is_in_city():
		if try_enter_city():
			get_viewport().set_input_as_handled()


func is_in_city() -> bool:
	return current_city_id != ""


## Enters whichever active city trigger the player is standing in.
func try_enter_city() -> bool:
	for city_id in _city_markers:
		if enter_city(city_id):
			return true
	return false


func enter_city(city_id: String) -> bool:
	if is_in_city() or not _city_markers.has(city_id):
		return false
	var marker := _city_markers[city_id] as CityMarker
	if not (marker.is_player_inside() and marker.trigger_overlaps(_player_body_rect())):
		return false
	current_city_id = city_id
	_set_world_active(false)
	_city_hub.open(city_id)
	_refresh_hub_summary()
	return true


func leave_city() -> bool:
	if not is_in_city():
		return false
	var city_id := current_city_id
	current_city_id = ""
	_city_hub.close()
	_player.global_position = WorldLayout.CITY_RETURN_POINTS[city_id]
	_set_world_active(true)
	return true


## Buys in the city the player is currently in; the trade itself lives in
## TradeService so it stays independent of any UI.
func buy_in_current_city(good_id: Variant, quantity: Variant) -> Dictionary:
	if not is_in_city():
		return {"success": false, "total_value": 0, "reason": "not_in_city"}
	var result := TradeService.buy(current_city_id, good_id, quantity, wallet, cargo)
	_refresh_hub_summary()
	return result


func sell_in_current_city(good_id: Variant, quantity: Variant) -> Dictionary:
	if not is_in_city():
		return {"success": false, "total_value": 0, "reason": "not_in_city"}
	var result := TradeService.sell(current_city_id, good_id, quantity, wallet, cargo)
	_refresh_hub_summary()
	return result


func _refresh_hub_summary() -> void:
	_city_hub.show_money(wallet.get_balance())
	_city_hub.show_cargo_summary(cargo.get_used_capacity(), Cargo.CARGO_CAPACITY)
	_city_hub.show_market(cargo.get_items())


func _on_market_buy_requested(good_id: String) -> void:
	var result := buy_in_current_city(good_id, MARKET_TRADE_QUANTITY)
	_city_hub.show_trade_feedback("buy", good_id, MARKET_TRADE_QUANTITY, result)


func _on_market_sell_requested(good_id: String) -> void:
	var result := sell_in_current_city(good_id, MARKET_TRADE_QUANTITY)
	_city_hub.show_trade_feedback("sell", good_id, MARKET_TRADE_QUANTITY, result)


func _player_body_rect() -> Rect2:
	var shape := _player.get_node("CollisionShape") as CollisionShape2D
	var size := (shape.shape as RectangleShape2D).size
	return Rect2(shape.global_position - size / 2.0, size)


func _set_world_active(active: bool) -> void:
	_joystick.release()
	_joystick.set_process_input(active)
	_player.velocity = Vector2.ZERO
	_player.set_physics_process(active)
