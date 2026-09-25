extends SceneTree

const APPROVED_PRICES := {
	"A": {"test_good_01": 80, "test_good_02": 180, "test_good_03": 420, "test_good_04": 900, "test_good_05": 2100, "test_good_06": 3600},
	"B": {"test_good_01": 120, "test_good_02": 300, "test_good_03": 650, "test_good_04": 1250, "test_good_05": 1700, "test_good_06": 4300},
}
const APPROVED_SIZES := {"test_good_01": 1, "test_good_02": 1, "test_good_03": 2, "test_good_04": 2, "test_good_05": 3, "test_good_06": 4}
const PORTRAIT_RECT := Rect2(0.0, 0.0, 720.0, 1280.0)
const STRESS_PRESSES := 300
const STRESS_CITY_SWITCH_EVERY := 30

var _checks := 0
var _failures := 0
var _main: Node2D
var _player: Player
var _hub: CityHub


func _initialize() -> void:
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	_main.save_path = ""  # M2-06: keep this test away from the player's real save file
	root.add_child(_main)
	await _settle()
	_player = _main.get_node("Actors/Player") as Player
	_hub = _main.get_node("CityHub") as CityHub

	_verify_regression_baseline()
	_verify_architecture()
	await _enter("A")
	_verify_display("A")
	_verify_layout()
	await _verify_buy_and_sell_ui()
	await _verify_failures()
	await _verify_a_to_b_loop()
	await _verify_stress()
	await _verify_leave_and_movement()

	if _failures == 0:
		print("M2-05 minimal player market verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Baseline and architecture -----------------------------------------------

func _verify_regression_baseline() -> void:
	_check(Cargo.CARGO_CAPACITY == 20, "Cargo capacity must stay 20")
	_check(GoodsCatalog.get_ids().size() == 6 and GoodsCatalog.get_unit_size("test_good_06") == 4 and GoodsCatalog.get_good("test_good_03")["base_value"] == 500, "Six goods must be unchanged")
	_check(Wallet.STARTING_MONEY == 10000 and _main.wallet.get_balance() == 10000, "Starting money must stay 10000")
	_check(WorldLayout.WORLD_SIZE == Vector2(40000.0, 40000.0), "World must stay 40K")
	_check(WorldLayout.CITY_A == Vector2(200.0, 200.0) and WorldLayout.CITY_B == Vector2(39800.0, 200.0), "City anchors must be unchanged")
	_check(_player.move_speed == 220.0, "Speed must stay 220")
	for city_id in APPROVED_PRICES:
		for good_id in APPROVED_PRICES[city_id]:
			_check(MarketPrices.get_price(city_id, good_id) == APPROVED_PRICES[city_id][good_id], "M2-04 price %s %s must be unchanged" % [city_id, good_id])


func _verify_architecture() -> void:
	var hub_source := FileAccess.get_file_as_string("res://scripts/city_hub.gd")
	for forbidden in ["Wallet", "wallet", ".spend(", ".remove(", "Cargo.new", "TradeService", "_items", "_balance"]:
		_check(not hub_source.contains(forbidden), "Market UI must not touch trade state directly (%s)" % forbidden)
	for literal in ["test_good_0", "PRICES", "2100", "3600", "4300", "1700", "1250", "650"]:
		_check(not hub_source.contains(literal), "Market UI must not hold its own goods or price data (%s)" % literal)
	_check(hub_source.contains("GoodsCatalog.get_ids()") and hub_source.contains("MarketPrices.get_price("), "Market UI must read GoodsCatalog and MarketPrices")

	var main_source := FileAccess.get_file_as_string("res://scripts/main.gd")
	_check(main_source.contains("TradeService.buy(") and main_source.contains("TradeService.sell("), "TradeService must remain the transaction authority")
	_check(main_source.contains("buy_in_current_city(good_id, MARKET_TRADE_QUANTITY)") and main_source.contains("sell_in_current_city(good_id, MARKET_TRADE_QUANTITY)"), "Market presses must go through the existing trade path")
	_check(_main.MARKET_TRADE_QUANTITY == 1, "Market buttons must trade exactly 1")
	_check(_hub.buy_requested.get_connections().size() == 1 and _hub.sell_requested.get_connections().size() == 1, "Market signals must be connected exactly once")
	_check(_main.wallet is Wallet and _main.cargo is Cargo, "Wallet and cargo must stay owned by the session controller")


# --- Display -----------------------------------------------------------------

func _verify_display(city_id: String) -> void:
	var ids := _hub.get_market_good_ids()
	_check(ids.size() == 6 and ids == GoodsCatalog.get_ids(), "Market must render the six catalog goods in order")
	for good_id in GoodsCatalog.get_ids():
		var texts := _hub.get_market_row_texts(good_id)
		_check(texts.get("name") == GoodsCatalog.get_good(good_id)["display_name"], "%s row must show its display name" % good_id)
		_check(_hub.get_market_button(good_id, "buy") != null and _hub.get_market_button(good_id, "buy").text == "Buy 1", "%s row must have Buy 1" % good_id)
		_check(_hub.get_market_button(good_id, "sell") != null and _hub.get_market_button(good_id, "sell").text == "Sell 1", "%s row must have Sell 1" % good_id)
	_check(_ui_matches_model(), "City %s market must match prices, holdings, money and cargo" % city_id)
	_check(_hub.get_city_label_text() == "[ City %s ]" % city_id, "Market must show the current city %s" % city_id)


func _verify_layout() -> void:
	var content := _hub.get_node("Center/Content") as Control
	_check(PORTRAIT_RECT.encloses(content.get_global_rect()), "Market must fit the 720 x 1280 portrait reference")
	var previous_bottom := -1.0
	for good_id in GoodsCatalog.get_ids():
		for action in ["buy", "sell"]:
			var rect := _hub.get_market_button(good_id, action).get_global_rect()
			_check(PORTRAIT_RECT.encloses(rect), "%s %s button must be on screen" % [good_id, action])
			_check(rect.size.x >= 120.0 and rect.size.y >= 88.0, "%s %s button must be touch-sized" % [good_id, action])
		var row_rect := (_hub.get_market_button(good_id, "buy").get_parent() as Control).get_global_rect()
		_check(row_rect.position.y >= previous_bottom, "%s row must not overlap the row above" % good_id)
		previous_bottom = row_rect.end.y
	var leave_rect := (_hub.get_node("Center/Content/LeaveButton") as Control).get_global_rect()
	_check(PORTRAIT_RECT.encloses(leave_rect) and leave_rect.position.y >= previous_bottom, "Leave City must be on screen below the market")


# --- Buy / sell UI -----------------------------------------------------------

func _verify_buy_and_sell_ui() -> void:
	await _reset_session_in("A")
	for good_id in GoodsCatalog.get_ids():
		var before_money: int = _main.wallet.get_balance()
		var before_items: Dictionary = _main.cargo.get_items()
		await _click(_hub.get_market_button(good_id, "buy"), false)
		var price: int = APPROVED_PRICES["A"][good_id]
		_check(_main.wallet.get_balance() == before_money - price, "One Buy 1 press on %s must cost exactly one A price" % good_id)
		var expected_items := before_items.duplicate()
		expected_items[good_id] = before_items.get(good_id, 0) + 1
		_check(_main.cargo.get_items() == expected_items, "Buy 1 on %s must add exactly one of that good only" % good_id)
		_check(_ui_matches_model(), "Money, cargo and held must refresh after buying %s" % good_id)
		_check(_hub.get_feedback_text() == "Bought 1 %s for %d" % [GoodsCatalog.get_good(good_id)["display_name"], price], "Buy feedback for %s" % good_id)

	for good_id in GoodsCatalog.get_ids():
		var before_money: int = _main.wallet.get_balance()
		var before_held: int = _main.cargo.get_quantity(good_id)
		await _click(_hub.get_market_button(good_id, "sell"), true)
		var price: int = APPROVED_PRICES["A"][good_id]
		_check(_main.wallet.get_balance() == before_money + price, "One Sell 1 touch on %s must earn exactly one A price" % good_id)
		_check(_main.cargo.get_quantity(good_id) == before_held - 1, "Sell 1 on %s must remove exactly one" % good_id)
		_check(_ui_matches_model(), "Money, cargo and held must refresh after selling %s" % good_id)
		_check(_hub.get_feedback_text() == "Sold 1 %s for %d" % [GoodsCatalog.get_good(good_id)["display_name"], price], "Sell feedback for %s" % good_id)
	_check(_main.wallet.get_balance() == 10000 and _main.cargo.is_empty(), "Buying and selling each good once in A must round-trip")


func _verify_failures() -> void:
	# Not enough goods.
	await _reset_session_in("A")
	var snapshot := _snapshot()
	await _click(_hub.get_market_button("test_good_02", "sell"), false)
	_check(_hub.get_feedback_text() == "Not enough goods", "Selling an unheld good must say Not enough goods")
	_check(_snapshot() == snapshot and _ui_matches_model(), "Failed sell must leave model and UI unchanged")

	# Not enough cargo space: fill with 10 x good 3 (20 units, 4200 money).
	for press in range(10):
		await _click(_hub.get_market_button("test_good_03", "buy"), false)
	_check(_main.cargo.get_used_capacity() == 20 and _main.wallet.get_balance() == 5800, "Ten good 3 buys must fill the cargo")
	snapshot = _snapshot()
	await _click(_hub.get_market_button("test_good_01", "buy"), false)
	_check(_hub.get_feedback_text() == "Not enough cargo space", "Buying into a full cargo must say Not enough cargo space")
	_check(_snapshot() == snapshot and _ui_matches_model(), "Failed full-cargo buy must leave model and UI unchanged")

	# Not enough money: sell down, then spend to below the good 5 price.
	await _reset_session_in("A")
	for press in range(4):
		await _click(_hub.get_market_button("test_good_05", "buy"), false)
	_check(_main.wallet.get_balance() == 10000 - 8400, "Four good 5 buys must leave 1600")
	snapshot = _snapshot()
	await _click(_hub.get_market_button("test_good_05", "buy"), false)
	_check(_hub.get_feedback_text() == "Not enough money", "Buying without enough money must say Not enough money")
	_check(_snapshot() == snapshot and _ui_matches_model(), "Failed money buy must leave model and UI unchanged")

	# The market stays usable after failures.
	await _click(_hub.get_market_button("test_good_01", "buy"), false)
	_check(_hub.get_feedback_text() == "Bought 1 Test Good 1 for 80" and _main.cargo.get_quantity("test_good_01") == 1, "Player must be able to keep trading after a failure")
	_check(_ui_matches_model(), "UI must stay consistent after recovering from failures")


func _verify_a_to_b_loop() -> void:
	await _reset_session_in("A")
	_check(_hub.get_money_label_text() == "Money: 10000" and _hub.get_cargo_label_text() == "Cargo: 0 / 20", "A must start at 10000 money and 0 / 20 cargo")
	_check(_hub.get_market_row_texts("test_good_01")["price"] == "Price 80", "A must show Good 1 at 80")
	_check(_hub.get_market_row_texts("test_good_05")["price"] == "Price 2100", "A must show Good 5 at 2100")
	var single_steps := true
	for press in range(10):
		await _click(_hub.get_market_button("test_good_01", "buy"), false)
		if _main.wallet.get_balance() != 10000 - 80 * (press + 1) or _main.cargo.get_quantity("test_good_01") != press + 1:
			single_steps = false
	_check(single_steps, "Every Buy 1 click in A must move exactly 80 money and 1 good")
	_check(_hub.get_money_label_text() == "Money: 9200" and _main.wallet.get_balance() == 9200, "Ten Buy 1 clicks in A must show 9200")
	_check(_hub.get_cargo_label_text() == "Cargo: 10 / 20", "Ten buys must show Cargo 10 / 20")
	_check(_hub.get_market_row_texts("test_good_01")["held"] == "Held 10", "Ten buys must show Held 10")

	_check(_main.leave_city(), "Must leave A")
	await _settle()
	_check(_main.wallet.get_balance() == 9200 and _main.cargo.get_quantity("test_good_01") == 10, "A purchases must survive leaving")
	_check(_hub.get_market_row_texts("test_good_01")["price"] == "", "Closed hub must not keep stale prices")

	await _enter("B")
	_check(_hub.get_money_label_text() == "Money: 9200", "B market must show carried money")
	_check(_hub.get_cargo_label_text() == "Cargo: 10 / 20", "B market must show carried cargo")
	_check(_hub.get_market_row_texts("test_good_01")["held"] == "Held 10", "B market must show carried holdings")
	_check(_hub.get_market_row_texts("test_good_01")["price"] == "Price 120", "B must show Good 1 at 120")
	_check(_hub.get_market_row_texts("test_good_05")["price"] == "Price 1700", "B must show Good 5 at 1700")
	var stale := false
	for good_id in GoodsCatalog.get_ids():
		if _hub.get_market_row_texts(good_id)["price"] != "Price %d" % APPROVED_PRICES["B"][good_id]:
			stale = true
	_check(not stale, "Entering B must replace every A price")
	single_steps = true
	for press in range(10):
		await _click(_hub.get_market_button("test_good_01", "sell"), true)
		if _main.wallet.get_balance() != 9200 + 120 * (press + 1) or _main.cargo.get_quantity("test_good_01") != 9 - press \
				or _hub.get_market_row_texts("test_good_01")["held"] != "Held %d" % (9 - press):
			single_steps = false
	_check(single_steps, "Every Sell 1 touch in B must move exactly 120 money and 1 good, and refresh Held")
	_check(_hub.get_money_label_text() == "Money: 10400" and _main.wallet.get_balance() == 10400, "Ten Sell 1 touches in B must show 10400")
	_check(_hub.get_cargo_label_text() == "Cargo: 0 / 20" and _hub.get_market_row_texts("test_good_01")["held"] == "Held 0", "Selling all must show Cargo 0 / 20 and Held 0")
	_check(_main.wallet.get_balance() - Wallet.STARTING_MONEY == 400, "A to B Good 1 loop must profit +400")


# --- Stress ------------------------------------------------------------------

## Deterministic UI stress: presses real market buttons and checks the UI and
## the session state against an independent reference model on every step.
func _verify_stress() -> void:
	await _reset_session_in("A")
	var model_money := Wallet.STARTING_MONEY
	var model_cargo := {}
	var city_id := "A"
	var ids := GoodsCatalog.get_ids()
	var seed := 5050
	var model_breaks := 0
	var ui_breaks := 0
	var double_exec := 0
	var feedback_breaks := 0
	var counts := {"buy_ok": 0, "buy_rejected": 0, "sell_ok": 0, "sell_rejected": 0, "A": 0, "B": 0}
	for press in range(STRESS_PRESSES):
		if press > 0 and press % STRESS_CITY_SWITCH_EVERY == 0:
			city_id = "B" if city_id == "A" else "A"
			_main.leave_city()
			await _settle()
			await _enter(city_id)
		seed = (seed * 1103515245 + 12345) % 2147483648
		var bits := seed >> 8
		var good_id: String = ids[bits % ids.size()]
		var is_buy := (bits >> 4) % 2 == 0
		var price: int = APPROVED_PRICES[city_id][good_id]
		var money_before: int = _main.wallet.get_balance()
		var expected_reason := ""
		if is_buy:
			if _model_used(model_cargo) + APPROVED_SIZES[good_id] > 20:
				expected_reason = "Not enough cargo space"
			elif price > model_money:
				expected_reason = "Not enough money"
			else:
				model_money -= price
				model_cargo[good_id] = model_cargo.get(good_id, 0) + 1
		else:
			if model_cargo.get(good_id, 0) < 1:
				expected_reason = "Not enough goods"
			else:
				model_money += price
				model_cargo[good_id] -= 1
				if model_cargo[good_id] == 0:
					model_cargo.erase(good_id)
		_hub.get_market_button(good_id, "buy" if is_buy else "sell").pressed.emit()

		var ok := expected_reason == ""
		counts[("buy_" if is_buy else "sell_") + ("ok" if ok else "rejected")] += 1
		counts[city_id] += 1
		var expected_delta := 0 if not ok else (-price if is_buy else price)
		if _main.wallet.get_balance() - money_before != expected_delta:
			double_exec += 1
		if _main.wallet.get_balance() != model_money or _main.cargo.get_items() != model_cargo:
			model_breaks += 1
		if not _ui_matches_model():
			ui_breaks += 1
		var name: String = GoodsCatalog.get_good(good_id)["display_name"]
		var expected_feedback := expected_reason if not ok else "%s 1 %s for %d" % ["Bought" if is_buy else "Sold", name, price]
		if _hub.get_feedback_text() != expected_feedback:
			feedback_breaks += 1
	_check(model_breaks == 0, "Stress: session state must match the reference model on all %d presses (%d breaks)" % [STRESS_PRESSES, model_breaks])
	_check(ui_breaks == 0, "Stress: UI must match wallet, cargo and current-city prices on every press (%d breaks)" % ui_breaks)
	_check(double_exec == 0, "Stress: every press must execute at most once (%d double executions)" % double_exec)
	_check(feedback_breaks == 0, "Stress: feedback must describe every press correctly (%d breaks)" % feedback_breaks)
	_check(counts["buy_ok"] >= 30 and counts["sell_ok"] >= 30 and counts["buy_rejected"] >= 20 and counts["sell_rejected"] >= 20, "Stress: must mix valid and invalid buys and sells %s" % str(counts))
	_check(counts["A"] >= 100 and counts["B"] >= 100, "Stress: must press buttons in both A and B %s" % str(counts))
	print("M2-05 stress counts: ", counts)


# --- Leave and movement --------------------------------------------------------

func _verify_leave_and_movement() -> void:
	var money: int = _main.wallet.get_balance()
	var items: Dictionary = _main.cargo.get_items()
	var city_id: String = _main.current_city_id
	await _click(_hub.get_node("Center/Content/LeaveButton") as Button, false)
	await _settle()
	_check(not _main.is_in_city() and not _hub.is_open(), "Leave City button must still close the hub")
	_check(_player.global_position == WorldLayout.CITY_RETURN_POINTS[city_id], "Leave must still use the city return point")
	_check(_main.wallet.get_balance() == money and _main.cargo.get_items() == items, "Leaving must preserve money and cargo")
	var joystick := _main.get_node("TouchControls/Joystick") as TouchJoystick
	_check(_player._touch_joystick == joystick and joystick.is_processing_input(), "Joystick wiring must survive the market")
	var before := _player.global_position
	Input.action_press("move_down")
	for frame in range(10):
		await physics_frame
	Input.action_release("move_down")
	_check(_player.global_position.y > before.y, "WASD movement must work after using the market")


# --- Helpers -------------------------------------------------------------------

func _ui_matches_model() -> bool:
	var city_id: String = _main.current_city_id
	if _hub.get_money_label_text() != "Money: %d" % _main.wallet.get_balance():
		return false
	if _hub.get_cargo_label_text() != "Cargo: %d / 20" % _main.cargo.get_used_capacity():
		return false
	for good_id in GoodsCatalog.get_ids():
		var texts := _hub.get_market_row_texts(good_id)
		if texts.get("price") != "Price %d" % MarketPrices.get_price(city_id, good_id):
			return false
		if texts.get("price") != "Price %d" % APPROVED_PRICES[city_id][good_id]:
			return false
		if texts.get("held") != "Held %d" % _main.cargo.get_quantity(good_id):
			return false
	return true


func _snapshot() -> Dictionary:
	return {
		"money": _main.wallet.get_balance(),
		"cargo": _main.cargo.get_items(),
		"money_text": _hub.get_money_label_text(),
		"cargo_text": _hub.get_cargo_label_text(),
	}


func _model_used(model: Dictionary) -> int:
	var used := 0
	for good_id in model:
		used += model[good_id] * APPROVED_SIZES[good_id]
	return used


## Clicks a button through the real input pipeline, as a mouse click or as a
## touch (converted to a click by Godot's emulate-mouse-from-touch default).
func _click(button: Button, as_touch: bool) -> void:
	# Let the containers finish laying out, as they would before a real tap.
	await process_frame
	var position: Vector2 = root.get_final_transform() * button.get_global_rect().get_center()
	for pressed in [true, false]:
		if as_touch:
			var touch := InputEventScreenTouch.new()
			touch.index = 0
			touch.pressed = pressed
			touch.position = position
			Input.parse_input_event(touch)
		else:
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = pressed
			click.position = position
			click.global_position = position
			Input.parse_input_event(click)
		await process_frame
		await process_frame


func _enter(city_id: String) -> void:
	_player.global_position = WorldLayout.CITY_ANCHORS[city_id]
	await _settle()
	var entered: bool = _main.try_enter_city()
	_check(entered and _main.current_city_id == city_id, "Must enter City %s" % city_id)
	await process_frame
	await process_frame


## Re-enters a city with a fresh wallet and cargo so each section starts clean.
func _reset_session_in(city_id: String) -> void:
	if _main.is_in_city():
		_main.leave_city()
		await _settle()
	_main.wallet = Wallet.new()
	_main.cargo = Cargo.new()
	await _enter(city_id)


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
