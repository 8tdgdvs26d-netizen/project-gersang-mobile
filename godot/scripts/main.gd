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
## T06: while walking in the world the exact position is saved at most this
## often, and only when it changed. It is also saved when the app goes to the
## background or closes.
const WORLD_AUTOSAVE_INTERVAL_MS := 5000

## Emitted once per journey, after its arrival has been saved.
signal journey_arrived(journey_id: String, city_id: String)
## C02: emitted once per committed battle result, after its save attempt
## (`saved`: whether that save succeeded; a failed save never undoes it).
signal battle_result_committed(result: BattleResult, saved: bool)

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
			_apply_level_growth()
## Stage 7 S01: the two Prototype Mercenaries' stats for battles (the Hero's
## are character_stats). A minimal runtime holder only, not saved (fixed
## Prototype values) and not the Party / Mercenary model, which Stage 8
## replaces it with.
var merc_stats := {"merc_a": CharacterStats.for_character("merc_a"), "merc_b": CharacterStats.for_character("merc_b")}
## C05: Level / EXP of the three fixed Prototype combat slots (saved, v9).
var progression := ProgressionState.new()
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
## The world position in the last successful save (null: none while in world).
var _saved_world_position: Variant = null
var _last_world_autosave_ms := 0

@onready var _player := $Actors/Player as Player
@onready var _joystick := $TouchControls/Joystick as TouchJoystick
@onready var _city_hub := $CityHub as CityHub
@onready var _enter_city_button := $EnterControls/EnterCityButton as Button
## World Threat: the prototype monsters (WT01 contact, WT02 aggro / chase /
## disengage), one per World Enemy Group (E02: three, group 1 first). Active in
## WORLD mode only; never saved.
var _world_monsters: Array[WorldMonster] = []
## World Threat WT04: turns the monster's valid contact into one pending
## Encounter Trigger + context for the future Encounter System.
@onready var _encounter_handoff := $EncounterHandoff as EncounterHandoff
## Encounter E01: the 5 s join window (player locked) and LOCKED phase that
## follow each trigger.
@onready var _encounter_session := $EncounterSession as EncounterSession
## Combat C01: a LOCKED encounter starts its battle here (runtime only).
var _combat_view: CombatView
## S04: the Character UI (Stat Point allocation).
var _character_panel: CharacterPanel
## Combat C01 TEST SEAM ONLY (never saved, no player setting, no gameplay
## path): the E01–E03 encounter tests, written before Combat existed, turn it
## off to keep observing the bare LOCKED phase. Always true in the game.
var combat_enabled := true
var _last_award := {}
## Stage 7 corrective: groups removed by a VICTORY come back GROUP_RESPAWN_MS
## after the commit (runtime only, never saved).
const WORLD_MONSTER_SCENE := preload("res://scenes/world_monster.tscn")
var _group_respawn := GroupRespawn.new()


func _ready() -> void:
	_load_saved_session()
	_apply_level_growth()
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
	for child in $Actors.get_children():
		if child is WorldMonster:
			_world_monsters.append(child)
			child.set_chase_target(_player)
	_encounter_handoff.watch(_world_monsters, _player, func() -> bool: return location.is_in_world(), time_source)
	_encounter_session.watch(_encounter_handoff, _player, time_source)
	_encounter_session.phase_changed.connect(_on_encounter_phase_changed)
	# C02: with Combat on, a LOCKED encounter ends only through its battle result.
	_encounter_session.prototype_end_enabled = not combat_enabled
	_encounter_handoff.group_removed.connect(_on_group_removed)
	_combat_view = CombatView.new()
	_combat_view.name = "CombatView"
	_combat_view.progression = progression
	add_child(_combat_view)
	_combat_view.exit_requested.connect(_on_combat_exit_requested)
	# S04: the Character UI (Stat Point allocation), from the world only.
	_character_panel = CharacterPanel.new()
	_character_panel.name = "CharacterPanel"
	_character_panel.party_provider = get_party_stats
	_character_panel.progression = progression
	_character_panel.can_open = _can_open_character_panel
	add_child(_character_panel)
	_character_panel.opened.connect(_on_character_panel_opened)
	_character_panel.closed.connect(_on_character_panel_closed)
	_character_panel.allocation_confirmed.connect(_on_allocation_confirmed)
	# Offline recovery (capped by MarketRecovery). Loading never rewrites the
	# save: the saved anchor + stock rebuild the same result on every reload.
	update_market_recovery(false)
	_restore_location()
	_saved_world_position = location.get_world_position()
	_last_world_autosave_ms = time_source.now_ms()
	_update_enter_city_button()
	print("Myrial: Unwritten ", BOOTSTRAP_VERSION, " passenger transport ready")


func _process(_delta: float) -> void:
	update_market_recovery()
	if location.is_traveling():
		update_journey()
	elif location.is_in_world():
		_autosave_world_position()
		_respawn_due_groups()
	_update_enter_city_button()


func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_CLOSE_REQUEST]:
		if is_node_ready() and location.is_in_world() and _player.global_position != _saved_world_position:
			save_world_position()


## Saves the player's exact world position now (WORLD mode only). A failed or
## refused save leaves the previous save file untouched.
func save_world_position() -> bool:
	if not location.is_in_world():
		return false
	var saved := _persist()
	if not saved:
		push_warning("Myrial: could not write save file %s" % save_path)
	return saved


## The player's current exact world position (null outside WORLD mode).
func get_world_position() -> Variant:
	return _player.global_position if location.is_in_world() else null


func _autosave_world_position() -> void:
	if _player.global_position == _saved_world_position:
		return
	var now := time_source.now_ms()
	if now - _last_world_autosave_ms < WORLD_AUTOSAVE_INTERVAL_MS:
		return
	_last_world_autosave_ms = now
	save_world_position()


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
		progression = loaded["progression"]
		# S05: Level growth first, then the saved confirmed allocation
		# (replaced, never added to).
		_apply_level_growth()
		var party := get_party_stats()
		for slot in ProgressionState.SLOTS:
			(party[slot] as CharacterStats).restore_allocation(loaded["allocation"][slot])


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
## In WORLD mode the player's exact position is recorded first; an invalid
## position refuses the save instead of overwriting a valid one.
func _persist() -> bool:
	if location.is_in_world() and is_node_ready() and not location.set_world_position(_player.global_position):
		return false
	var saved := save_path == "" or SaveStore.save(save_path, wallet, inventory, market, location, warehouses, market_recovery, cost_ledger, progression, get_party_stats())
	if saved:
		_saved_world_position = location.get_world_position()
	return saved


func _show_city(city_id: String) -> void:
	_set_world_active(false)
	_city_hub.open(city_id)
	_refresh_hub_summary()
	_update_enter_city_button()


## Places the player at the location's exact world position (the return
## point right after leaving a city, or the restored saved position).
func _show_world() -> void:
	_player.global_position = location.get_world_position()
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
	if not active:
		# WT04 recovery: leaving WORLD (city or travel) cancels an encounter
		# no Encounter System has taken yet (E01: its join window / lock too).
		_encounter_session.cancel_for_world_exit()
	for monster in _world_monsters:
		monster.set_threat_active(active)


## C05: the EXP shares of the last committed battle ({slot: {exp, level,
## leveled}}; empty when it awarded none).
func get_last_award() -> Dictionary:
	return _last_award


## The running battle (null when none).
func get_combat() -> CombatBattle:
	return _combat_view.get_battle() if _combat_view != null else null


func _on_encounter_phase_changed(phase: int) -> void:
	if phase == EncounterSession.Phase.LOCKED and combat_enabled:
		_start_combat()
	elif phase == EncounterSession.Phase.NONE and _combat_view.is_open():
		_close_combat()


## S03: each character's stats follow its Level (Growth and unspent Stat
## Points); run after loading, after every settlement and when the Hero's
## stats object is replaced.
func _apply_level_growth() -> void:
	if progression == null:
		return
	var party := get_party_stats()
	for slot in ProgressionState.SLOTS:
		(party[slot] as CharacterStats).apply_level(progression.get_level(slot))


## S04: the Character UI may open in the world while no encounter runs.
func _can_open_character_panel() -> bool:
	return location.is_in_world() and not _combat_view.is_open() and _encounter_session.get_phase() == EncounterSession.Phase.NONE


## S04: no walking while the Character UI is open — neither the joystick
## (it reads every touch) nor the keyboard (the player's movement is locked);
## back when it closes. An encounter that starts meanwhile closes the panel
## and keeps its own lock (EncounterSession owns it then).
func _on_character_panel_opened() -> void:
	_joystick.release()
	_joystick.set_process_input(false)
	_player.movement_locked = true
	_player.velocity = Vector2.ZERO


## S05: a confirmed allocation is saved at once (like a committed trade: a
## failed save does not undo it), so quitting right after keeps it.
func _on_allocation_confirmed(_character_id: String) -> void:
	_save_session()


func _on_character_panel_closed() -> void:
	_joystick.set_process_input(location.is_in_world() and not _combat_view.is_open())
	if _encounter_session.get_phase() == EncounterSession.Phase.NONE:
		_player.movement_locked = false


## S01: character id -> CharacterStats of the fixed combat party (the Hero is
## the backpack's character_stats).
func get_party_stats() -> Dictionary:
	return {"hero": character_stats, "merc_a": merc_stats["merc_a"], "merc_b": merc_stats["merc_b"]}


## Combat C01: LOCKED -> battlefield. The world stays exactly as LOCKED left
## it (player locked, groups held, nothing new can trigger) under the battle.
func _start_combat() -> void:
	var battle := CombatBattle.from_encounter(_encounter_session.get_context(), get_party_stats())
	if battle == null or _combat_view.is_open():
		return
	print("Myrial: combat started for ", battle.encounter_id, " with ", battle.get_enemies().size(), " enemies")
	_joystick.release()
	_joystick.set_process_input(false)
	_combat_view.open(battle)


func _close_combat() -> void:
	_combat_view.close()
	_joystick.set_process_input(location.is_in_world())


## The result screen's 「返回世界」: asks the world lifecycle to commit the
## running battle's result. The button is never the source of the outcome.
func _on_combat_exit_requested() -> void:
	var battle := get_combat()
	if battle != null:
		commit_battle_result(battle.get_result())


## C02: the single world lifecycle of a battle result (the only way a Combat
## encounter ends). Commits `result` exactly once, only for the running
## battle's own result of the current LOCKED encounter; anything else (a
## repeat, a stale or foreign result, no battle) is refused and changes
## nothing. Order:
##   1. validate, 2. claim the single commit,
##   3. recovery protection on (before any group is released, so nothing can
##      re-aggro), 4. groups: VICTORY removes the participants from this
##      session's world, DEFEAT and C04 RETREAT reset them home
##      (EncounterHandoff),
##   5. end the encounter (player unlocked where the encounter caught the player),
##   6. C05: EXP to the slots alive at settlement (ProgressionState; none on
##      DEFEAT), close the battle, world input back, 7. save once.
## A failed save does not undo the committed result. No reward, EXP, loot,
## penalty or hospital happens here; a removed group's later return is
## scheduled by _on_group_removed (Stage 7 corrective).
func commit_battle_result(result: BattleResult) -> bool:
	var battle := get_combat()
	if result == null or battle == null or battle.get_result() != result or result.is_committed():
		return false
	var context := _encounter_session.get_context()
	var pending := _encounter_handoff.get_pending_encounter()
	if _encounter_session.get_phase() != EncounterSession.Phase.LOCKED or context == null or pending != context \
			or context.encounter_id != result.encounter_id:
		return false
	if not result.claim_commit():
		return false
	_encounter_session.start_recovery_protection()
	_encounter_handoff.resolve_encounter(result.encounter_id, result.is_victory())
	_encounter_session.end_resolved_encounter(result.encounter_id)
	# C05: the battle's EXP goes to the slots alive at settlement (none on
	# DEFEAT); part of the committed result, saved with it below.
	_last_award = progression.apply(result)
	_apply_level_growth()
	_close_combat()
	var saved := save_world_position()
	print("Myrial: battle result ", BattleResult.Outcome.keys()[result.outcome], " of ", result.encounter_id, " committed (saved: ", saved, ")")
	battle_result_committed.emit(result, saved)
	return true


## C02: a group removed by a VICTORY leaves the world list, so no world
## transition reactivates it. Stage 7 corrective: it is scheduled to come
## back GROUP_RESPAWN_MS from now (the player is returning to the world).
func _on_group_removed(monster: WorldMonster) -> void:
	_world_monsters.erase(monster)
	_group_respawn.schedule(monster, time_source.now_ms())


## Stage 7 corrective: brings back every due group (GroupRespawn) as a fresh
## instance of its fixed Prototype group at its home, IDLE, watched again
## under the current protection. Only in the world with no encounter or
## battle running (a due group otherwise waits); never while the result
## screen is up.
func _respawn_due_groups() -> void:
	if not location.is_in_world() or _combat_view.is_open() or _encounter_session.get_phase() != EncounterSession.Phase.NONE:
		return
	for entry in _group_respawn.take_due(time_source.now_ms()):
		var monster := WORLD_MONSTER_SCENE.instantiate() as WorldMonster
		monster.group_index = entry["group_index"]
		monster.name = entry["node_name"]
		$Actors.add_child(monster)
		$Actors.move_child(monster, _player.get_index())
		monster.set_chase_target(_player)
		if not _encounter_handoff.watch_monster(monster):
			monster.queue_free()
			continue
		_world_monsters.append(monster)
		print("Myrial: group ", monster.monster_id, " respawned at its home")


## Stage 7 corrective (tests / diagnostics): the respawn schedule.
func get_group_respawn() -> GroupRespawn:
	return _group_respawn
