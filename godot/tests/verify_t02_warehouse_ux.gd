extends SceneTree

## T02 Warehouse UX + Remote View, and the backpack (背包容量) baseline.
## Uses its own save file so the player's real save is never touched, and a
## fixed TimeSource so journeys are deterministic.

const TEST_SAVE := "user://t02_warehouse_ux_test_save.json"
const T0 := 1800000000000
const BACKPACK := 100
const WAREHOUSE := 200
const IDS := ["test_good_01", "test_good_02", "test_good_03", "test_good_04", "test_good_05", "test_good_06"]

var _checks := 0
var _failures := 0
var _sections_done := []
var _approved := RegEx.new()
var _latin := RegEx.new()


func _initialize() -> void:
	_latin.compile("[A-Za-z]")
	_approved.compile("(?<![A-Za-z])[ABE](?![A-Za-z])")
	_delete(TEST_SAVE)
	_verify_backpack_baseline()
	_verify_terminology_sources()
	await _verify_local_and_remote()
	await _verify_travel_swap_and_reload()
	await _verify_traveling_and_market_boundary()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 5, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("T02 warehouse UX and remote view verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Backpack baseline ------------------------------------------------------------------

func _verify_backpack_baseline() -> void:
	_check(CharacterStats.PROTOTYPE_DEFAULT_STRENGTH == 10 and CharacterStats.new().get_max_capacity() == BACKPACK, "Default Strength 10 must give backpack capacity 100")
	_check(CharacterInventory.new().get_max_capacity() == BACKPACK, "A default character inventory holds 100")
	# Capacity still scales with Strength (prototype formula 10 + 9 x Strength).
	var formula := {0: 10, 1: 19, 5: 55, 10: 100, 11: 109, 20: 190}
	for strength in formula:
		_check(CharacterStats.new(strength).get_max_capacity() == formula[strength], "Strength %d must give capacity %d" % [strength, formula[strength]])
	var stats := CharacterStats.new()
	var inventory := CharacterInventory.new("player", stats)
	_check(stats.set_strength(12) and inventory.get_max_capacity() == 118, "Raising Strength must raise the backpack capacity")
	# Not a fixed 100 hard cap in either direction.
	var strong := CharacterInventory.new("player", CharacterStats.new(20))
	_check(strong.add("test_good_01", 150) and strong.get_used_capacity() == 150, "A stronger character can carry more than 100")
	var weak := CharacterInventory.new("player", CharacterStats.new(1))
	_check(not weak.add("test_good_01", 20) and weak.add("test_good_01", 19), "A weaker character carries less than 100")
	var source := _code_only("res://scripts/character_inventory.gd") + _code_only("res://scripts/character_stats.gd")
	var hundred := RegEx.new()
	hundred.compile("(?<![0-9])100(?![0-9])")
	_check(hundred.search(source) == null, "No hard-coded 100 cap in inventory or stats code")
	_check(WarehouseState.PROTOTYPE_CAPACITY == WAREHOUSE and WarehouseState.create_default().get_max_capacity("A") == WAREHOUSE and WarehouseState.create_default().get_max_capacity("B") == WAREHOUSE, "Warehouse capacity must stay 200 per city")
	_sections_done.append("backpack")


func _verify_terminology_sources() -> void:
	var literal := RegEx.new()
	literal.compile("\"([^\"]*)\"")
	var old_terms := 0
	for dir in ["res://scripts", "res://scenes"]:
		for file_name in DirAccess.get_files_at(dir):
			if not (file_name.ends_with(".gd") or file_name.ends_with(".tscn")):
				continue
			for found in literal.search_all(_code_only(dir + "/" + file_name)):
				var text := found.get_string(1)
				if text.contains("貨物容量") or text.contains("攜帶容量"):
					push_error("Old capacity wording in %s: %s" % [file_name, text])
					old_terms += 1
	_check(old_terms == 0, "No player-facing text may still say 貨物容量 / 攜帶容量 for the backpack")
	_check(CityHub.FAILURE_MESSAGES["insufficient_cargo_space"] == "背包容量不足" and CityHub.WAREHOUSE_FAILURE_MESSAGES["ERR_CARRY_CAPACITY"] == "背包容量不足", "Capacity failures must say 背包容量不足")
	_sections_done.append("terminology")


# --- Local and remote warehouses ---------------------------------------------------------

func _verify_local_and_remote() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	var hub := main.get_node("CityHub") as CityHub
	# Stock City B's warehouse first, in person.
	await _walk_in(main, "B")
	for press in range(4):
		hub.get_market_button("test_good_02", "buy").pressed.emit()
	hub.show_facility("warehouse")
	for press in range(4):
		hub.get_warehouse_button("test_good_02", "deposit").pressed.emit()
	_check(main.warehouses.get_quantity("B", "test_good_02") == 4, "Setup: 4 x good 2 stored in B")
	main.leave_city()

	# City A: market shows the backpack baseline.
	await _walk_in(main, "A")
	_check(hub.get_cargo_label_text() == "背包容量：0 / 100", "Market must show 背包容量 with the 100 baseline (%s)" % hub.get_cargo_label_text())
	for press in range(5):
		hub.get_market_button("test_good_01", "buy").pressed.emit()
	_check(hub.get_cargo_label_text() == "背包容量：5 / 100", "Backpack usage must update after buying")

	# Local warehouse A.
	hub.show_facility("warehouse")
	await process_frame
	_check(hub.get_warehouse_view_city() == "A" and hub.is_warehouse_view_local(), "The warehouse opens on the local city")
	_check(hub.get_warehouse_status_text() == "A 城倉庫・本地倉庫（每次存入或取出 1 件）", "Local status must be clear (%s)" % hub.get_warehouse_status_text())
	_check(hub.get_warehouse_summary_text() == "背包容量：5 / 100　倉庫容量：0 / 200", "Local summary must show both capacities (%s)" % hub.get_warehouse_summary_text())
	_check(hub.get_warehouse_row_texts("test_good_01") == {"name": "測試商品一", "carried": "背包：5", "stored": "倉庫：0"}, "Local rows show backpack and stored counts")
	_check(hub.get_warehouse_button("test_good_01", "deposit").is_visible_in_tree() and hub.get_warehouse_button("test_good_01", "withdraw").is_visible_in_tree(), "Local controls must be available")
	for press in range(3):
		hub.get_warehouse_button("test_good_01", "deposit").pressed.emit()
	hub.get_warehouse_button("test_good_01", "withdraw").pressed.emit()
	_check(main.inventory.get_quantity("test_good_01") == 3 and main.warehouses.get_quantity("A", "test_good_01") == 2, "Local deposit and withdraw must work")
	_check(hub.get_warehouse_row_texts("test_good_01") == {"name": "測試商品一", "carried": "背包：3", "stored": "倉庫：2"} and hub.get_warehouse_summary_text() == "背包容量：3 / 100　倉庫容量：2 / 200", "The view must refresh after transfers")
	_check(_chinese(main) and _layout_ok(main, true), "Local warehouse view must be Chinese and fit the portrait layout")

	# Switch to remote B: read-only.
	var before := _state(main)
	var file_before := _read(TEST_SAVE)
	hub.get_warehouse_city_button("B").pressed.emit()
	await process_frame
	_check(hub.get_warehouse_view_city() == "B" and not hub.is_warehouse_view_local(), "City B's warehouse must be remote from A")
	_check(hub.get_warehouse_status_text() == "B 城倉庫・遠端查看：只可在所在城市存取倉庫物品", "Remote status must explain the rule (%s)" % hub.get_warehouse_status_text())
	_check(hub.get_warehouse_summary_text() == "背包容量：3 / 100　倉庫容量：4 / 200", "Remote capacity must be visible (%s)" % hub.get_warehouse_summary_text())
	_check(hub.get_warehouse_row_texts("test_good_02")["stored"] == "倉庫：4" and hub.get_warehouse_row_texts("test_good_01")["stored"] == "倉庫：0", "Remote contents must be visible and separate from A")
	var hidden := true
	for good_id in IDS:
		for action in ["deposit", "withdraw"]:
			if hub.get_warehouse_button(good_id, action).is_visible_in_tree():
				hidden = false
	_check(hidden, "Remote warehouses must show no transfer controls")
	_check(not (hub.get_warehouse_row_texts("test_good_02").is_empty()) and not hub.get_node("Center/Content/WarehouseRows/test_good_02/Info/CountLine/CarriedLabel").is_visible_in_tree(), "Remote rows show only the stored count")
	_check(hub.get_warehouse_city_button("B").disabled and not hub.get_warehouse_city_button("A").disabled, "The viewed city's selector is the active one")
	# Nothing can move remotely: hidden buttons, raw signals and direct calls.
	hub.get_warehouse_button("test_good_02", "withdraw").pressed.emit()
	hub.get_warehouse_button("test_good_01", "deposit").pressed.emit()
	hub.withdraw_requested.emit("B", "test_good_02", "forged-1")
	hub.deposit_requested.emit("B", "test_good_01", "forged-2")
	_check(hub.get_feedback_text() == "只可使用所在城市的倉庫", "A forced remote request must be refused in Chinese")
	var remote_withdraw: Dictionary = main.withdraw_from_warehouse("test_good_02", 1, "", "B")
	var remote_deposit: Dictionary = main.deposit_to_warehouse("test_good_01", 1, "", "B")
	_check(remote_withdraw["reason"] == "ERR_WRONG_CITY" and remote_deposit["reason"] == "ERR_WRONG_CITY", "WarehouseService must reject remote transfers")
	_check(_state(main) == before and _read(TEST_SAVE) == file_before, "Remote attempts and view switching must change nothing (items, wallet, market, location, save)")
	var view: Dictionary = main.get_warehouse_view("B")
	view["contents"]["test_good_02"] = 99
	_check(main.warehouses.get_quantity("B", "test_good_02") == 4, "Remote view data is a read-only copy")
	_check(_chinese(main) and _layout_ok(main, false), "Remote warehouse view must be Chinese and fit the portrait layout")

	# Switch back and forth: nothing moves.
	for flip in range(5):
		hub.show_warehouse_city("A" if flip % 2 == 0 else "B")
	hub.show_warehouse_city("A")
	_check(_state(main) == before and hub.is_warehouse_view_local() and hub.get_warehouse_row_texts("test_good_01")["stored"] == "倉庫：2", "Switching views must never move items or change state")
	# Other facility views still use the backpack wording.
	hub.show_facility("market")
	_check(hub.get_cargo_label_text() == "背包容量：3 / 100" and _chinese(main), "Market view keeps 背包容量")
	hub.show_facility("transport")
	_check(_chinese(main), "Transport view stays Chinese")
	await _destroy(main)
	_sections_done.append("local_remote")


# --- Travel, swap and reload -------------------------------------------------------------

func _verify_travel_swap_and_reload() -> void:
	# Continues from the save written above: A holds 2 x good 1, B holds 4 x good 2.
	var main := await _new_main(TEST_SAVE)
	var hub := main.get_node("CityHub") as CityHub
	_check(main.current_city_id == "A" and main.inventory.get_max_capacity() == BACKPACK, "Reload restores the city and the 100 backpack from character stats")
	var saved := _read_json()
	_check(not JSON.stringify(saved).contains("max_capacity") and not saved["character"].has("capacity") and int(saved["character"]["stats"]["strength"]) == 10, "Backpack capacity is derived from Strength, never saved")
	_check(main.warehouses.get_snapshot() == {"A": {"items": {"test_good_01": 2}}, "B": {"items": {"test_good_02": 4}}}, "Reload restores both warehouses exactly")
	hub.show_facility("warehouse")
	_check(hub.get_warehouse_view_city() == "A" and hub.is_warehouse_view_local() and hub.get_warehouse_summary_text() == "背包容量：3 / 100　倉庫容量：2 / 200", "Reloaded warehouse view is correct")

	# Travel A -> B by passenger transport.
	_check(main.request_transport("B", "t02-ride")["success"], "Passenger transport still works")
	main.time_source.advance_ms(90000)
	await process_frame
	_check(main.current_city_id == "B", "Arrived in B")
	hub.show_facility("warehouse")
	_check(hub.get_warehouse_view_city() == "B" and hub.is_warehouse_view_local() and hub.get_warehouse_status_text().begins_with("B 城倉庫・本地倉庫"), "B is now the local warehouse")
	_check(hub.get_warehouse_button("test_good_02", "withdraw").is_visible_in_tree(), "B controls are now available")
	hub.get_warehouse_button("test_good_02", "withdraw").pressed.emit()
	_check(main.inventory.get_quantity("test_good_02") == 1 and main.warehouses.get_quantity("B", "test_good_02") == 3, "Withdraw works in B")
	hub.show_warehouse_city("A")
	_check(not hub.is_warehouse_view_local() and hub.get_warehouse_status_text().begins_with("A 城倉庫・遠端查看") and not hub.get_warehouse_button("test_good_01", "withdraw").is_visible_in_tree(), "A is now remote and read-only")
	_check(hub.get_warehouse_row_texts("test_good_01")["stored"] == "倉庫：2", "A's contents are visible remotely")
	_check(main.withdraw_from_warehouse("test_good_01", 1, "", "A")["reason"] == "ERR_WRONG_CITY" and main.warehouses.get_quantity("A", "test_good_01") == 2, "A cannot be changed from B")

	# Reload again from B.
	var snapshot: Dictionary = main.warehouses.get_snapshot()
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	hub = main.get_node("CityHub") as CityHub
	_check(main.current_city_id == "B" and main.warehouses.get_snapshot() == snapshot and main.inventory.get_max_capacity() == BACKPACK, "Second reload restores warehouses and the 100 backpack")
	hub.show_facility("warehouse")
	_check(hub.get_warehouse_view_city() == "B" and hub.is_warehouse_view_local(), "After reload the local city is shown first")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("travel_reload")


# --- Traveling and market boundary -----------------------------------------------------------

func _verify_traveling_and_market_boundary() -> void:
	var main := await _new_main("")
	var hub := main.get_node("CityHub") as CityHub
	await _walk_in(main, "A")
	hub.get_market_button("test_good_01", "buy").pressed.emit()
	_check(main.inventory.get_quantity("test_good_01") == 1 and main.warehouses.get_quantity("A", "test_good_01") == 0, "Purchases go into the backpack")
	hub.show_facility("warehouse")
	hub.get_warehouse_button("test_good_01", "deposit").pressed.emit()
	var sell: Dictionary = main.sell_in_current_city("test_good_01", 1)
	_check(not sell["success"] and sell["reason"] == "insufficient_cargo" and main.warehouses.get_quantity("A", "test_good_01") == 1, "Warehouse-only goods cannot be sold")
	_check(main.request_transport("B", "t02-trip")["success"], "Start a journey")
	_check(main.deposit_to_warehouse("test_good_01", 1)["reason"] == "ERR_NOT_IN_CITY" and main.withdraw_from_warehouse("test_good_01", 1, "", "A")["reason"] == "ERR_NOT_IN_CITY", "No warehouse use while traveling")
	_check(hub.get_facility() == "traveling" and not hub.get_node("Center/Content/WarehouseRows").is_visible_in_tree() and not hub.get_node("Center/Content/WarehouseCityTabs").is_visible_in_tree(), "The journey view hides the warehouse")
	_check(_chinese(main), "Traveling view stays Chinese")
	await _destroy(main)
	_sections_done.append("traveling_market")


# --- Helpers ------------------------------------------------------------------------------------

func _state(main: Node) -> Dictionary:
	return {"inventory": main.inventory.get_stacks(), "warehouses": main.warehouses.get_snapshot(), "wallet": main.wallet.get_balance(), "market": main.market.get_snapshot(), "location": main.location.to_dict()}


func _chinese(main: Node) -> bool:
	var ok := true
	for control in main.find_children("*", "Label", true, false) + main.find_children("*", "Button", true, false):
		var text: String = (control as Control).get("text")
		if text.contains("貨物容量") or text.contains("攜帶容量") or _latin.search(_approved.sub(text, "", true)) != null:
			push_error("Unapproved player text: %s" % text)
			ok = false
	return ok


func _layout_ok(main: Node, local: bool) -> bool:
	var hub := main.get_node("CityHub") as CityHub
	var portrait := Rect2(Vector2.ZERO, Vector2(720, 1280))
	var enter_area := (main.get_node("EnterControls/EnterCityButton") as Control).get_global_rect()
	var controls: Array = [hub.get_node("Center/Content/LeaveButton"), hub.get_warehouse_city_button("A"), hub.get_warehouse_city_button("B")]
	for tab in hub.get_node("Center/Content/FacilityTabs").get_children():
		controls.append(tab)
	if local:
		for good_id in IDS:
			controls.append(hub.get_warehouse_button(good_id, "deposit"))
			controls.append(hub.get_warehouse_button(good_id, "withdraw"))
	for control in controls:
		var rect := (control as Control).get_global_rect()
		if not portrait.encloses(rect) or rect.intersects(enter_area) or rect.size.y < 64.0:
			push_error("Layout problem: %s %s" % [control.name, str(rect)])
			return false
	return portrait.encloses((hub.get_node("Center/Content") as Control).get_global_rect())


func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


func _new_main(path: String) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	await _settle()
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _walk_in(main: Node, city: String) -> void:
	var player := main.get_node("Actors/Player") as Player
	player.global_position = WorldLayout.CITY_ANCHORS[city]
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == city, "Must enter City %s" % city)


func _read_json() -> Dictionary:
	var parser := JSON.new()
	if parser.parse(_read(TEST_SAVE)) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return {}
	return parser.data


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else "<missing>"


func _delete(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _settle() -> void:
	# Area2D overlaps update a few physics frames after a teleport.
	for frame in range(4):
		await physics_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
