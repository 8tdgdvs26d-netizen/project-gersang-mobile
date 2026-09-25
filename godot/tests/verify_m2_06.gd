extends SceneTree

## Uses its own save file so the player's real save is never touched.
const TEST_SAVE := "user://m2_06_test_save.json"
const UNWRITABLE_SAVE := "user://m2_06_missing_dir/nested/save.json"
const SPAWN := Vector2(420.0, 500.0)
const APPROVED_PRICES := {
	"A": {"test_good_01": 80, "test_good_02": 180, "test_good_03": 420, "test_good_04": 900, "test_good_05": 2100, "test_good_06": 3600},
	"B": {"test_good_01": 120, "test_good_02": 300, "test_good_03": 650, "test_good_04": 1250, "test_good_05": 1700, "test_good_06": 4300},
}
## M2-07 supersedes the M2-06 same-price trades: players buy at
## ceil(reference x 1.05) and sell at floor(reference x 0.95).
const BUY_PRICES := {
	"A": {"test_good_01": 84, "test_good_02": 189, "test_good_03": 441, "test_good_04": 945, "test_good_05": 2205, "test_good_06": 3780},
	"B": {"test_good_01": 126, "test_good_02": 315, "test_good_03": 683, "test_good_04": 1313, "test_good_05": 1785, "test_good_06": 4515},
}
const BUYBACK_PRICES := {
	"A": {"test_good_01": 76, "test_good_02": 171, "test_good_03": 399, "test_good_04": 855, "test_good_05": 1995, "test_good_06": 3420},
	"B": {"test_good_01": 114, "test_good_02": 285, "test_good_03": 617, "test_good_04": 1187, "test_good_05": 1615, "test_good_06": 4085},
}
const APPROVED_SIZES := {"test_good_01": 1, "test_good_02": 1, "test_good_03": 2, "test_good_04": 2, "test_good_05": 3, "test_good_06": 4}
const STRESS_STEPS := 320

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	await _verify_fresh_defaults()
	await _verify_valid_saves()
	await _verify_trade_triggers()
	await _verify_full_journey()
	await _verify_invalid_saves()
	await _verify_write_failure()
	await _verify_stress()
	_delete(TEST_SAVE)

	if _failures == 0:
		print("M2-06 money and cargo persistence verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static / regression ----------------------------------------------------------

func _verify_static() -> void:
	_check(SaveStore.DEFAULT_PATH == "user://myrial_save.json", "Default save path must be user://myrial_save.json")
	_check(TEST_SAVE != SaveStore.DEFAULT_PATH, "Tests must use an isolated save path")
	var source := FileAccess.get_file_as_string("res://scripts/save_store.gd")
	for forbidden in ["._items", "._balance", "TradeService", "position", "city_id"]:
		_check(not source.contains(forbidden), "Save store must not bypass APIs or save extra state (%s)" % forbidden)
	for city_id in APPROVED_PRICES:
		for good_id in APPROVED_PRICES[city_id]:
			_check(MarketPrices.get_price(city_id, good_id) == APPROVED_PRICES[city_id][good_id], "Price %s %s must be unchanged" % [city_id, good_id])
	_check(GoodsCatalog.get_ids().size() == 6 and Cargo.CARGO_CAPACITY == 20 and Wallet.STARTING_MONEY == 10000, "Goods, capacity and starting money must be unchanged")


# --- Loading ------------------------------------------------------------------------

func _verify_fresh_defaults() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	_check(main.wallet.get_balance() == 10000, "No save must start with 10000 money")
	_check(main.cargo.is_empty(), "No save must start with empty cargo")
	_check(not FileAccess.file_exists(TEST_SAVE), "Starting without a save must not create one")
	await _destroy(main)


func _verify_valid_saves() -> void:
	var cases := [
		['{"version": 1, "money": 7777, "cargo": {}}', 7777, {}, "money with empty cargo"],
		['{"money": 500, "cargo": {"test_good_03": 4}}', 500, {"test_good_03": 4}, "one good without version"],
		['{"version": 1, "money": 0, "cargo": {"test_good_01": 2, "test_good_05": 3}}', 0, {"test_good_01": 2, "test_good_05": 3}, "multiple goods and zero money"],
		['{"version": 1, "money": 123456, "cargo": {"test_good_01": 1, "test_good_02": 1, "test_good_03": 1, "test_good_04": 1, "test_good_05": 1, "test_good_06": 1}}', 123456, {"test_good_01": 1, "test_good_02": 1, "test_good_03": 1, "test_good_04": 1, "test_good_05": 1, "test_good_06": 1}, "all six goods"],
		['{"version": 1, "money": 10, "cargo": {"test_good_06": 5}}', 10, {"test_good_06": 5}, "exactly full cargo by unit size"],
	]
	for case in cases:
		_write(TEST_SAVE, case[0])
		var main := await _new_main(TEST_SAVE)
		_check(main.wallet.get_balance() == case[1], "Valid save (%s) must restore money" % case[3])
		_check(main.cargo.get_items() == case[2], "Valid save (%s) must restore cargo" % case[3])
		await _destroy(main)
	_write(TEST_SAVE, '{"money": 10, "cargo": {"test_good_06": 5}}')
	var full := await _new_main(TEST_SAVE)
	_check(full.cargo.get_used_capacity() == 20 and full.cargo.get_remaining_capacity() == 0, "Loaded cargo must use unit sizes (5 x size 4 = 20)")
	await _destroy(full)
	_write(TEST_SAVE, '{"money": 10, "cargo": {"test_good_05": 6}}')
	var sized := await _new_main(TEST_SAVE)
	_check(sized.cargo.get_used_capacity() == 18, "Loaded cargo must count 6 x size 3 as 18 units")
	await _destroy(sized)


# --- Save triggers ----------------------------------------------------------------------

func _verify_trade_triggers() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	await _enter(main, "A")

	var rejected: Dictionary = main.buy_in_current_city("test_good_06", 3)
	_check(not rejected["success"] and not FileAccess.file_exists(TEST_SAVE), "A failed first buy must not create a save")
	_check(not main.sell_in_current_city("test_good_01", 1)["success"] and not FileAccess.file_exists(TEST_SAVE), "A failed first sell must not create a save")

	_check(main.buy_in_current_city("test_good_02", 2)["success"], "Buy must succeed")
	_check(_saved() == {"money": 9622, "cargo": {"test_good_02": 2}}, "Successful buy must write money and cargo")

	var before := _read(TEST_SAVE)
	for attempt in [["test_good_06", 3], ["bad_good", 1], ["test_good_01", 0], ["test_good_01", -2], ["test_good_01", 1.5], ["test_good_01", 25]]:
		main.buy_in_current_city(attempt[0], attempt[1])
		_check(_read(TEST_SAVE) == before, "Failed buy %s must not change the save" % str(attempt))
	for attempt in [["test_good_02", 3], ["test_good_05", 1], ["bad_good", 1], ["test_good_02", 0], ["test_good_02", -1]]:
		main.sell_in_current_city(attempt[0], attempt[1])
		_check(_read(TEST_SAVE) == before, "Failed sell %s must not change the save" % str(attempt))
	_check(main.wallet.get_balance() == 9622 and main.cargo.get_items() == {"test_good_02": 2}, "Failed trades must not change runtime state")

	_check(main.sell_in_current_city("test_good_02", 2)["success"], "Sell must succeed")
	_check(_saved() == {"money": 9964, "cargo": {}}, "Successful sell must write money and cargo; the same-city round trip loses the spread")
	await _destroy(main)


# --- Full journey -----------------------------------------------------------------------

func _verify_full_journey() -> void:
	_delete(TEST_SAVE)
	var first := await _new_main(TEST_SAVE)
	_check(first.wallet.get_balance() == 10000 and first.cargo.get_used_capacity() == 0, "Journey: fresh state must be 10000 / empty")
	await _enter(first, "A")
	var hub := first.get_node("CityHub") as CityHub
	for press in range(10):
		hub.get_market_button("test_good_01", "buy").pressed.emit()
	_check(first.wallet.get_balance() == 9160 and first.cargo.get_quantity("test_good_01") == 10 and first.cargo.get_used_capacity() == 10, "Journey: A buy must reach 9160 / 10 units")
	var first_wallet: Wallet = first.wallet
	var first_cargo: Cargo = first.cargo
	await _destroy(first)

	var second := await _new_main(TEST_SAVE)
	_check(second.wallet != first_wallet and second.cargo != first_cargo, "Journey: restart must create new wallet and cargo objects")
	_check(second.wallet.get_balance() == 9160, "Journey restart #1: money must be restored to 9160")
	_check(second.cargo.get_quantity("test_good_01") == 10 and second.cargo.get_used_capacity() == 10, "Journey restart #1: cargo must be restored to 10")
	_check((second.get_node("Actors/Player") as Player).global_position == SPAWN, "Restart must use the normal world spawn, not a saved position")
	_check(second.current_city_id == "" and not (second.get_node("CityHub") as CityHub).is_open(), "Restart must not restore the city or hub state")
	await _enter(second, "B")
	var hub_b := second.get_node("CityHub") as CityHub
	_check(hub_b.get_money_label_text() == "金錢：9160", "Market must show restored money")
	_check(hub_b.get_cargo_label_text() == "貨物容量：10 / 20", "Market must show restored cargo capacity")
	_check(hub_b.get_market_row_texts("test_good_01")["held"] == "持有 10", "Market must show restored held quantity")
	for press in range(10):
		hub_b.get_market_button("test_good_01", "sell").pressed.emit()
	_check(second.wallet.get_balance() == 10300 and second.cargo.is_empty(), "Journey: B sell must reach 10300 / 0")
	await _destroy(second)

	var third := await _new_main(TEST_SAVE)
	_check(third.wallet.get_balance() == 10300, "Journey restart #2: money must be restored to 10300")
	_check(third.cargo.is_empty() and third.cargo.get_used_capacity() == 0, "Journey restart #2: cargo must be restored empty")
	_check(third.wallet.get_balance() - Wallet.STARTING_MONEY == 300, "Journey: saved profit must be +300")
	await _destroy(third)


# --- Invalid saves -------------------------------------------------------------------------

func _verify_invalid_saves() -> void:
	var cases := [
		["{not json", "A malformed JSON"],
		["", "A2 empty file"],
		['{"money": 9200, "cargo": {', "A3 truncated JSON"],
		['[9200, {"test_good_01": 1}]', "B root array"],
		['"9200"', "B2 root string"],
		['{"cargo": {"test_good_01": 1}}', "C missing money"],
		['{"money": "9200", "cargo": {}}', "D money string"],
		['{"money": -1, "cargo": {}}', "E money negative"],
		['{"money": 12.5, "cargo": {}}', "E2 money not integer"],
		['{"money": 1e300, "cargo": {}}', "E3 money out of range"],
		['{"money": 9200, "cargo": [1, 2]}', "F cargo array"],
		['{"money": 9200, "cargo": null}', "F2 cargo null"],
		['{"money": 9200}', "F3 missing cargo"],
		['{"money": 9200, "cargo": {"test_good_07": 1}}', "G unknown good"],
		['{"money": 9200, "cargo": {"test_good_01": "3"}}', "H quantity string"],
		['{"money": 9200, "cargo": {"test_good_01": 0}}', "I quantity zero"],
		['{"money": 9200, "cargo": {"test_good_01": -2}}', "J quantity negative"],
		['{"money": 9200, "cargo": {"test_good_01": 1.5}}', "K quantity non-integer"],
		['{"money": 9200, "cargo": {"test_good_06": 6}}', "L over capacity (24 units)"],
		['{"money": 9200, "cargo": {"test_good_01": 10, "test_good_05": 4}}', "L2 over capacity mixed (22 units)"],
		['{"money": 9200, "cargo": {"test_good_01": 3, "unknown": 1}}', "M valid money + invalid cargo"],
		['{"version": 3, "money": 9200, "cargo": {}}', "N incompatible version"],
		['{"money": 9200, "cargo": {}, "position": [1, 2]}', "O unexpected field"],
	]
	for case in cases:
		_write(TEST_SAVE, case[0])
		var main := await _new_main(TEST_SAVE)
		_check(main.wallet.get_balance() == 10000, "Invalid save (%s) must fall back to 10000 money, no partial restore" % case[1])
		_check(main.cargo.is_empty(), "Invalid save (%s) must fall back to empty cargo" % case[1])
		_check(_read(TEST_SAVE) == case[0], "Invalid save (%s) must not be overwritten on load" % case[1])
		await _destroy(main)

	# The next successful trade replaces the invalid file with a valid save.
	_write(TEST_SAVE, '{"money": 9200, "cargo": {"test_good_01": 3, "unknown": 1}}')
	var main := await _new_main(TEST_SAVE)
	await _enter(main, "A")
	_check(main.buy_in_current_city("test_good_01", 1)["success"], "Trading must work after an invalid save")
	_check(_saved() == {"money": 9916, "cargo": {"test_good_01": 1}}, "A successful trade must write a fresh valid save over the invalid one")
	await _destroy(main)


func _verify_write_failure() -> void:
	var main := await _new_main(UNWRITABLE_SAVE)
	await _enter(main, "A")
	var result: Dictionary = main.buy_in_current_city("test_good_01", 2)
	_check(result["success"] and main.wallet.get_balance() == 9832 and main.cargo.get_quantity("test_good_01") == 2, "A failed save write must not roll back a successful trade")
	_check(not FileAccess.file_exists(UNWRITABLE_SAVE), "The unwritable save must not exist")
	_check(main.sell_in_current_city("test_good_01", 2)["success"] and main.wallet.get_balance() == 9984, "Trading must keep working after a failed write")
	await _destroy(main)


# --- Stress -----------------------------------------------------------------------------

## Deterministic mix of buys, sells, rejects, saves and full recreate/load cycles,
## checked against an independent reference model after every step.
func _verify_stress() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	var city_id := "A"
	await _enter(main, city_id)
	var model_money := 10000
	var model_cargo := {}
	var saved_money := 10000
	var saved_cargo := {}
	var goods := GoodsCatalog.get_ids() + ["bad_good"]
	var quantities := [1, 1, 1, 2, 3, 0, -1, 25]
	var seed := 60606
	var drift := 0
	var file_breaks := 0
	var reload_breaks := 0
	var invariant_breaks := 0
	var counts := {"buy_ok": 0, "buy_rejected": 0, "sell_ok": 0, "sell_rejected": 0, "recreate": 0, "switch": 0}
	for step in range(STRESS_STEPS):
		seed = (seed * 1103515245 + 12345) % 2147483648
		var bits := seed >> 8
		var action := bits % 12
		if step > 0 and step % 40 == 0:
			city_id = "B" if city_id == "A" else "A"
			main.leave_city()
			await _enter(main, city_id)
			counts["switch"] += 1
		if action == 11:
			await _destroy(main)
			main = await _new_main(TEST_SAVE)
			if main.wallet.get_balance() != saved_money or main.cargo.get_items() != saved_cargo:
				reload_breaks += 1
			model_money = saved_money
			model_cargo = saved_cargo.duplicate()
			await _enter(main, city_id)
			counts["recreate"] += 1
		else:
			var good_id: String = goods[(bits >> 4) % goods.size()]
			var quantity: int = quantities[(bits >> 7) % quantities.size()]
			var is_buy := action < 6
			if not is_buy and not model_cargo.is_empty() and (bits >> 10) % 4 != 0:
				var held := model_cargo.keys()
				held.sort()
				good_id = held[(bits >> 12) % held.size()]
			var price: int = (BUY_PRICES if is_buy else BUYBACK_PRICES)[city_id].get(good_id, 0)
			var file_before := _read(TEST_SAVE)
			var expected := false
			if is_buy:
				expected = price > 0 and quantity > 0 and _model_used(model_cargo) + quantity * APPROVED_SIZES.get(good_id, 99) <= 20 and price * quantity <= model_money
				if expected:
					model_money -= price * quantity
					model_cargo[good_id] = model_cargo.get(good_id, 0) + quantity
			else:
				expected = price > 0 and quantity > 0 and model_cargo.get(good_id, 0) >= quantity
				if expected:
					model_money += price * quantity
					model_cargo[good_id] -= quantity
					if model_cargo[good_id] == 0:
						model_cargo.erase(good_id)
			var result: Dictionary = main.buy_in_current_city(good_id, quantity) if is_buy else main.sell_in_current_city(good_id, quantity)
			counts[("buy_" if is_buy else "sell_") + ("ok" if result["success"] else "rejected")] += 1
			if result["success"] != expected:
				drift += 1
			if expected:
				saved_money = model_money
				saved_cargo = model_cargo.duplicate()
				if _saved() != {"money": saved_money, "cargo": saved_cargo}:
					file_breaks += 1
			elif _read(TEST_SAVE) != file_before:
				file_breaks += 1
		if main.wallet.get_balance() != model_money or main.cargo.get_items() != model_cargo:
			drift += 1
		if main.wallet.get_balance() < 0 or main.cargo.get_used_capacity() > 20 or main.cargo.get_used_capacity() != _model_used(main.cargo.get_items()):
			invariant_breaks += 1
	_check(drift == 0, "Stress: runtime state must match the reference model (%d drifts)" % drift)
	_check(file_breaks == 0, "Stress: the save must change only on successful trades and match the model (%d breaks)" % file_breaks)
	_check(reload_breaks == 0, "Stress: every recreate must load the last saved state (%d breaks)" % reload_breaks)
	_check(invariant_breaks == 0, "Stress: invariants must hold on every step (%d breaks)" % invariant_breaks)
	_check(counts["buy_ok"] >= 30 and counts["sell_ok"] >= 30 and counts["buy_rejected"] >= 30 and counts["sell_rejected"] >= 30 and counts["recreate"] >= 15, "Stress: must mix trades, rejects and recreates %s" % str(counts))
	print("M2-06 stress counts: ", counts)
	await _destroy(main)


func _model_used(model: Dictionary) -> int:
	var used := 0
	for good_id in model:
		used += model[good_id] * APPROVED_SIZES.get(good_id, 99)
	return used


# --- Helpers ------------------------------------------------------------------------------

func _new_main(path: String) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	root.add_child(main)
	await _settle()
	return main


## Fully removes a game instance so the next one starts from new objects.
func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _enter(main: Node, city_id: String) -> void:
	var player := main.get_node("Actors/Player") as Player
	player.global_position = WorldLayout.CITY_ANCHORS[city_id]
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == city_id, "Must enter City %s" % city_id)


## Reads the test save with an independent JSON parse (not through SaveStore).
func _saved() -> Dictionary:
	var parser := JSON.new()
	if parser.parse(_read(TEST_SAVE)) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return {"invalid": true}
	var cargo := {}
	for good_id in parser.data.get("cargo", {}):
		cargo[good_id] = int(parser.data["cargo"][good_id])
	return {"money": int(parser.data.get("money", -1)), "cargo": cargo}


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else "<missing>"


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


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
