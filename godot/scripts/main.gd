extends Node2D

## Minimal world/city state controller. The world scene stays loaded; entering
## a city pauses world movement and shows the shared City Hub overlay. A paid
## passenger journey keeps the world paused and shows the traveling view until
## the journey arrives inside the destination city.

const BOOTSTRAP_VERSION := "M2-09"
## Each warehouse button press moves exactly one unit.
const WAREHOUSE_TRANSFER_QUANTITY := 1
## After a failed arrival save the journey stays unfinished; retry this often.
const ARRIVAL_RETRY_MS := 1000

## Emitted once per journey, after its arrival has been saved.
signal journey_arrived(journey_id: String, city_id: String)

## World / city / journey state of the main character (saved from M2-09).
var location := PlayerLocation.new()
## The only clock gameplay reads. Tests replace it before the node is ready.
var time_source := TimeSource.new()
## Id of the city whose hub is open ("" in the world or while traveling).
var current_city_id: String:
	get:
		return location.get_city_id() if location.is_in_city() else ""
## Session-owned player character data. World/city transitions never reset it;
## valid local saves restore it on startup.
var character_stats := CharacterStats.new()
var inventory := CharacterInventory.new("player", character_stats)
## Temporary code-compatibility alias for pre-M2-08 callers and historical
## regression scripts. Runtime trades and persistence use inventory directly.
var cargo: CharacterInventory:
	get:
		return inventory
	set(value):
		inventory = value
		if value != null:
			character_stats = value.get_stats()
## Session-owned player money, with the same lifetime as the cargo.
var wallet := Wallet.new()
## City market state (reference price, stock and target stock per city x good).
## It belongs to the world, not the player; the session controller only holds it.
var market := MarketState.create_default()
## One item warehouse per active city (T01). Only WarehouseService changes it.
var warehouses := WarehouseState.create_default()
## The market's own recovery timeline (T04). Only update_market_recovery()
## advances it; trades never touch it.
var market_recovery := MarketRecovery.new()
## Acquisition-cost lots of every carried and stored trade good (T05). Only
## TradeService (buy / sell) and WarehouseService (deposit / withdraw) change it.
var cost_ledger := TradeCostLedger.new()
## Local save file for money, cargo and market. An empty path turns persistence off
## (used by tests so they never touch the player's real save).
var save_path := SaveStore.DEFAULT_PATH
var _city_markers := {}
var _request_counter := 0
var _next_arrival_attempt_ms := 0

@onready var _player := $Actors/Player as Player
@onready var _joystick := $TouchControls/Joystick as TouchJoystick
@onready var _city_hub := $CityHub as CityHub
@onready var _enter_city_button := $EnterControls/EnterCityButton as Button


func _ready() -> void:
	_load_saved_session()
	for child in $Cities.get_children():
		if child is CityMarker and child.city_id in WorldLayout.ACTIVE_CITY_IDS:
			_city_markers[child.city_id] = child
	_city_hub.leave_requested.connect(leave_city)
	_city_hub.buy_requested.connect(_on_market_buy_requested)
	_city_hub.sell_requested.connect(_on_market_sell_requested)
	_city_hub.transport_requested.connect(_on_transport_requested)
	_city_hub.deposit_requested.connect(_on_deposit_requested)
	_city_hub.withdraw_requested.connect(_on_withdraw_requested)
	_city_hub.warehouse_city_selected.connect(_on_warehouse_city_selected)
	_city_hub.facility_changed.connect(_on_hub_facility_changed)
	_enter_city_button.pressed.connect(_on_enter_city_button_pressed)
	# Offline recovery (capped by MarketRecovery). Loading never rewrites the
	# save: the saved anchor + stock rebuild the same result on every reload.
	update_market_recovery(false)
	_restore_location()
	_update_enter_city_button()
	print("Myrial: Unwritten ", BOOTSTRAP_VERSION, " passenger transport ready")


func _process(_delta: float) -> void:
	update_market_recovery()
	if location.is_traveling():
		update_journey()
	_update_enter_city_button()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact") and location.is_in_world():
		if try_enter_city():
			get_viewport().set_input_as_handled()


func is_in_city() -> bool:
	return location.is_in_city()


func is_traveling() -> bool:
	return location.is_traveling()


## Enters whichever active city trigger the player is standing in.
func try_enter_city() -> bool:
	for city_id in _city_markers:
		if enter_city(city_id):
			return true
	return false


## The single entry rule shared by the E key, the touch button and its visibility.
func can_enter_city(city_id: String) -> bool:
	if not location.is_in_world() or not _city_markers.has(city_id):
		return false
	var marker := _city_markers[city_id] as CityMarker
	return marker.is_player_inside() and marker.trigger_overlaps(_player_body_rect())


func enter_city(city_id: String) -> bool:
	if not can_enter_city(city_id) or not location.enter_city(city_id):
		return false
	_show_city(city_id)
	_save_session()
	return true


func leave_city() -> bool:
	if not location.leave_city():
		return false
	_city_hub.close()
	_show_world()
	_save_session()
	return true


## Pays for a passenger journey from the current city. Request ids make a
## repeated press of the same offer a no-op instead of a second charge.
func request_transport(destination_city_id: Variant, request_id: Variant) -> Dictionary:
	var result := TransportService.begin_journey(location, wallet, destination_city_id, request_id, time_source.now_ms(), _persist)
	if result["success"]:
		_show_traveling()
	return result


## Settles the journey once its arrival time is reached; returns true on arrival.
func update_journey() -> bool:
	if not location.is_traveling():
		return false
	var now := time_source.now_ms()
	if TransportService.remaining_ms(location, now) > 0:
		_city_hub.show_travel_remaining(TransportService.remaining_ms(location, now))
		return false
	_city_hub.show_travel_remaining(0)
	if now < _next_arrival_attempt_ms:
		return false
	var result := TransportService.settle_arrival(location, now, _persist)
	if not result["success"]:
		if result["reason"] == TransportService.ERR_SAVE_FAILED:
			# Nothing changed: runtime and save still hold the same journey.
			push_warning("Myrial: could not write save file %s" % save_path)
			_next_arrival_attempt_ms = now + ARRIVAL_RETRY_MS
			_city_hub.show_arrival_retry()
		return false
	_next_arrival_attempt_ms = 0
	_show_city(result["city_id"])
	journey_arrived.emit(result["journey_id"], result["city_id"])
	return true


## Moves items from the inventory into a warehouse (default: the current
## city's). Free; never touches the wallet, market or journey. WarehouseService
## rejects any city that is not the character's current city.
func deposit_to_warehouse(item_id: Variant, quantity: Variant, request_id: String = "", city_id: Variant = null) -> Dictionary:
	var target: Variant = current_city_id if city_id == null else city_id
	return WarehouseService.deposit(location, inventory, warehouses, target, item_id, quantity, request_id, _persist, cost_ledger)


## Moves items from a warehouse (default: the current city's) into the inventory.
func withdraw_from_warehouse(item_id: Variant, quantity: Variant, request_id: String = "", city_id: Variant = null) -> Dictionary:
	var target: Variant = current_city_id if city_id == null else city_id
	return WarehouseService.withdraw(location, inventory, warehouses, target, item_id, quantity, request_id, _persist, cost_ledger)


## Read-only view of any active city's warehouse (copies only); `local` is
## true only for the character's current city, the only one that can change.
func get_warehouse_view(city_id: Variant) -> Dictionary:
	if not warehouses.has_city(city_id):
		return {}
	return {
		"city_id": city_id,
		"local": location.is_in_city() and city_id == location.get_city_id(),
		"contents": warehouses.get_contents(city_id),
		"used": warehouses.get_used_capacity(city_id),
		"max": warehouses.get_max_capacity(city_id),
	}


## Applies every market recovery step due by now (elapsed time, not frame
## count, so dropped or delayed frames lose nothing). When stock changed it is
## saved (if `save`) and an open market shows the new stock and prices.
## Returns the number of recovery steps applied.
func update_market_recovery(save: bool = true) -> int:
	var result := market_recovery.advance(market, time_source.now_ms())
	if result["changed"]:
		if save:
			_save_session()
		if is_in_city():
			_refresh_market_view()
	return result["steps"]


func get_transport_quotes() -> Array:
	var quotes := []
	for destination in TransportRoutes.get_destinations(current_city_id):
		var offer := TransportService.quote(current_city_id, destination)
		if offer["success"]:
			quotes.append({"destination": destination, "fare": offer["fare"], "duration_ms": offer["duration_ms"]})
	return quotes


## Buys in the city the player is currently in; the trade itself lives in
## TradeService so it stays independent of any UI.
func buy_in_current_city(good_id: Variant, quantity: Variant) -> Dictionary:
	if not is_in_city():
		return {"success": false, "total_value": 0, "reason": "not_in_city"}
	update_market_recovery()
	var result := TradeService.buy(current_city_id, good_id, quantity, wallet, inventory, market, cost_ledger)
	if result["success"]:
		_save_session()
	_refresh_hub_summary()
	return result


func sell_in_current_city(good_id: Variant, quantity: Variant) -> Dictionary:
	if not is_in_city():
		return {"success": false, "total_value": 0, "reason": "not_in_city"}
	update_market_recovery()
	var result := TradeService.sell(current_city_id, good_id, quantity, wallet, inventory, market, cost_ledger)
	if result["success"]:
		_save_session()
	_refresh_hub_summary()
	return result


## Restores money, cargo, market and location from a valid save, or keeps the
## fresh defaults. Exact world coordinates are not saved.
func _load_saved_session() -> void:
	var loaded := SaveStore.load_session(save_path)
	if not loaded.is_empty():
		wallet = loaded["wallet"]
		inventory = loaded["inventory"]
		character_stats = loaded["character_stats"]
		market = loaded["market"]
		location = loaded["location"]
		warehouses = loaded["warehouses"]
		market_recovery = loaded["market_recovery"]
		cost_ledger = loaded["cost_ledger"]


## Puts the scene into the loaded location: the world (at the last city's
## return point), an open city hub, or a journey (arriving now if it is due).
func _restore_location() -> void:
	if location.is_in_city() and _city_markers.has(location.get_city_id()):
		_show_city(location.get_city_id())
	elif location.is_traveling():
		_show_traveling()
		update_journey()
	elif location.is_in_world():
		_show_world()


## Saves after a successful trade, city entry/exit or journey change. A failed
## write keeps the valid runtime state; it is only reported as a warning.
func _save_session() -> void:
	if not _persist():
		push_warning("Myrial: could not write save file %s" % save_path)


## Writes the whole session; true when saved or when persistence is off.
func _persist() -> bool:
	return save_path == "" or SaveStore.save(save_path, wallet, inventory, market, location, warehouses, market_recovery, cost_ledger)


func _show_city(city_id: String) -> void:
	_set_world_active(false)
	_city_hub.open(city_id)
	_refresh_hub_summary()
	_update_enter_city_button()


func _show_world() -> void:
	var city_id := location.get_city_id()
	if WorldLayout.CITY_RETURN_POINTS.has(city_id):
		_player.global_position = WorldLayout.CITY_RETURN_POINTS[city_id]
	_set_world_active(true)
	_update_enter_city_button()


func _show_traveling() -> void:
	var journey := location.get_journey()
	_set_world_active(false)
	_city_hub.open_traveling(journey["destination_city_id"], TransportService.remaining_ms(location, time_source.now_ms()))
	_city_hub.show_money(wallet.get_balance())
	_city_hub.show_cargo_summary(inventory.get_used_capacity(), inventory.get_max_capacity())
	_update_enter_city_button()


## Touch Enter City is only another way to request the normal entry path.
func _on_enter_city_button_pressed() -> void:
	try_enter_city()


## Shows the touch Enter City button only in the world and only while an
## active city can actually be entered from where the player stands.
func _update_enter_city_button() -> void:
	var enterable := false
	for city_id in _city_markers:
		if can_enter_city(city_id):
			enterable = true
	_enter_city_button.visible = enterable


func _refresh_hub_summary() -> void:
	_city_hub.show_money(wallet.get_balance())
	_city_hub.show_cargo_summary(inventory.get_used_capacity(), inventory.get_max_capacity())
	_refresh_market_view()
	_city_hub.show_transport_routes(get_transport_quotes(), _next_request_id())
	var view_city := _city_hub.get_warehouse_view_city()
	if not warehouses.has_city(view_city):
		view_city = current_city_id
	_city_hub.show_warehouse(get_warehouse_view(view_city), inventory.get_items(), inventory.get_used_capacity(), inventory.get_max_capacity(), _next_request_id())


func _refresh_market_view() -> void:
	var quotes := {}
	var previews := {}
	for good_id in GoodsCatalog.get_ids():
		quotes[good_id] = market.get_quote(current_city_id, good_id)
		previews[good_id] = get_sale_previews(good_id)
	_city_hub.show_market(quotes, inventory.get_items(), previews)


## Expected merchandise result of selling 1 and 10 of a good here now, from
## the same TradeService rules the sale uses. Only sizes the player can sell.
func get_sale_previews(good_id: Variant) -> Dictionary:
	var previews := {}
	if not is_in_city():
		return previews
	for quantity in TradeService.ALLOWED_ORDER_QUANTITIES:
		var terms := TradeService.preview_sell(current_city_id, good_id, quantity, inventory, market, cost_ledger)
		if terms["success"]:
			previews[quantity] = terms
	return previews


## Market buttons send orders of 1 or 10; TradeService validates the size and
## locks one unit price for the whole order.
func _on_market_buy_requested(good_id: String, quantity: int) -> void:
	var result := buy_in_current_city(good_id, quantity)
	_city_hub.show_trade_feedback("buy", good_id, quantity, result)


func _on_market_sell_requested(good_id: String, quantity: int) -> void:
	var result := sell_in_current_city(good_id, quantity)
	_city_hub.show_trade_feedback("sell", good_id, quantity, result)


func _on_deposit_requested(city_id: String, item_id: String, request_id: String) -> void:
	var result := deposit_to_warehouse(item_id, WAREHOUSE_TRANSFER_QUANTITY, request_id, city_id)
	_refresh_hub_summary()
	_city_hub.show_warehouse_feedback("deposit", item_id, result)


func _on_withdraw_requested(city_id: String, item_id: String, request_id: String) -> void:
	var result := withdraw_from_warehouse(item_id, WAREHOUSE_TRANSFER_QUANTITY, request_id, city_id)
	_refresh_hub_summary()
	_city_hub.show_warehouse_feedback("withdraw", item_id, result)


## Viewing another city's warehouse only changes what is shown.
func _on_warehouse_city_selected(_city_id: String) -> void:
	if location.is_in_city():
		_refresh_hub_summary()


func _on_transport_requested(destination_city_id: String, request_id: String) -> void:
	var result := request_transport(destination_city_id, request_id)
	if not result["success"] and location.is_in_city():
		_refresh_hub_summary()
		_city_hub.show_transport_feedback(result)


## Each time the transport offers are shown they get a fresh request id, so
## only a deliberate new press can start another journey.
func _on_hub_facility_changed(_facility: String) -> void:
	if location.is_in_city():
		_refresh_hub_summary()


func _next_request_id() -> String:
	_request_counter += 1
	return "j%d-%d-%d" % [time_source.now_ms(), _request_counter, randi() % 1000000]


func _player_body_rect() -> Rect2:
	var shape := _player.get_node("CollisionShape") as CollisionShape2D
	var size := (shape.shape as RectangleShape2D).size
	return Rect2(shape.global_position - size / 2.0, size)


func _set_world_active(active: bool) -> void:
	_joystick.release()
	_joystick.set_process_input(active)
	_player.velocity = Vector2.ZERO
	_player.set_physics_process(active)
