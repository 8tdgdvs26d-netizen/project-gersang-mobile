extends SceneTree

const PORTRAIT_RECT := Rect2(0.0, 0.0, 720.0, 1280.0)
const JOYSTICK_AREA_RIGHT_EDGE := 360.0
const OUTSIDE_POINTS := [Vector2(420.0, 500.0), Vector2(20000.0, 20000.0), Vector2(1200.0, 300.0), Vector2(38800.0, 300.0)]
const STRESS_ATTEMPTS := 120

var _checks := 0
var _failures := 0
var _main: Node2D
var _player: Player
var _hub: CityHub
var _button: Button
var _joystick: TouchJoystick


func _initialize() -> void:
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	_main.save_path = ""  # M2-06: keep this test away from the player's real save file
	root.add_child(_main)
	await _settle()
	_player = _main.get_node("Actors/Player") as Player
	_hub = _main.get_node("CityHub") as CityHub
	_button = _main.get_node_or_null("EnterControls/EnterCityButton") as Button
	_joystick = _main.get_node("TouchControls/Joystick") as TouchJoystick

	_verify_regression_baseline()
	_verify_architecture()
	await _verify_outside_range()
	await _verify_visibility_follows_range()
	await _verify_touch_enter_a_with_market()
	await _verify_touch_enter_b()
	await _verify_keyboard_e()
	await _verify_layout()
	await _verify_stress()
	await _verify_movement_still_works()

	if _failures == 0:
		print("M2-05A touch enter city verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Baseline ------------------------------------------------------------------

func _verify_regression_baseline() -> void:
	_check(_player.move_speed == 220.0, "Speed must stay 220")
	_check(WorldLayout.CITY_A == Vector2(200.0, 200.0) and WorldLayout.CITY_B == Vector2(39800.0, 200.0), "City anchors must be unchanged")
	_check(WorldLayout.WORLD_SIZE == Vector2(40000.0, 40000.0), "World must stay 40K")
	_check(Wallet.STARTING_MONEY == 10000 and _main.wallet.get_balance() == 10000, "Wallet must be unchanged")
	_check(Cargo.CARGO_CAPACITY == 20 and _main.cargo.is_empty(), "Cargo must be unchanged")
	_check(MarketPrices.get_price("A", "test_good_01") == 80 and MarketPrices.get_price("B", "test_good_05") == 1700 and MarketPrices.PRICES["A"].size() == 6, "Market prices must be unchanged")
	_check(GoodsCatalog.get_ids().size() == 6 and GoodsCatalog.get_unit_size("test_good_06") == 4, "Six goods must be unchanged")
	_check(_player._touch_joystick == _joystick, "Joystick must stay wired to the player")


func _verify_architecture() -> void:
	_check(_button != null and _button.text == "Enter City", "Main scene must contain the Enter City touch button")
	_check(InputMap.has_action("interact"), "Keyboard interact (E) action must still exist")
	_check(_button.pressed.get_connections().size() == 1, "Enter City button must be connected exactly once")
	_check(_hub.leave_requested.get_connections().size() == 1 and _hub.buy_requested.get_connections().size() == 1 and _hub.sell_requested.get_connections().size() == 1, "Hub signals must stay connected once")
	var source := FileAccess.get_file_as_string("res://scripts/main.gd")
	var handler := source.substr(source.find("func _on_enter_city_button_pressed"))
	handler = handler.substr(0, handler.find("\n\n\n"))
	_check(handler.count("try_enter_city()") == 1, "Touch button must request the existing try_enter_city path exactly once")
	for forbidden in ["current_city_id", "_city_hub", "global_position", "open("]:
		_check(not handler.contains(forbidden), "Touch button handler must not bypass the entry path (%s)" % forbidden)
	_check(_button.focus_mode == Control.FOCUS_NONE, "Enter City button must not take keyboard focus")


# --- Visibility and entry --------------------------------------------------------

func _verify_outside_range() -> void:
	for point in OUTSIDE_POINTS:
		await _place(point)
		_check(not _button.visible, "Button must be hidden outside city range at %s" % str(point))
	await _place(OUTSIDE_POINTS[0])
	await _touch(_button_center())
	_check(not _main.is_in_city() and not _hub.is_open(), "Touching where the hidden button sits must not enter a city")
	_main._on_enter_city_button_pressed()
	_check(not _main.is_in_city(), "The touch handler itself must not enter a city outside range")
	_check(_player.is_physics_processing(), "Outside touches must leave the world active")


func _verify_visibility_follows_range() -> void:
	await _place(WorldLayout.CITY_A)
	_check(_button.visible, "Button must appear inside City A range")
	await _place(WorldLayout.CITY_A + Vector2(700.0, 300.0))
	_check(not _button.visible, "Button must hide after leaving City A range")
	await _place(WorldLayout.CITY_B)
	_check(_button.visible, "Button must appear inside City B range")
	await _place(WorldLayout.CITY_B - Vector2(700.0, -300.0))
	_check(not _button.visible, "Button must hide after leaving City B range")

	# Visible button must not force entry: the player can still walk away.
	await _place(WorldLayout.CITY_A)
	var before := _player.global_position
	Input.action_press("move_down")
	for frame in range(10):
		await physics_frame
	Input.action_release("move_down")
	_check(not _main.is_in_city() and _player.global_position.y > before.y, "Player must be able to keep moving while the button is visible")


func _verify_touch_enter_a_with_market() -> void:
	await _place(WorldLayout.CITY_A)
	_check(_button.visible, "Button must be visible before touching in A")
	await _touch(_button_center())
	_check(_main.current_city_id == "A", "Touch Enter in A must enter City A")
	_check(_hub.is_open() and _hub.get_city_label_text() == "[ City A ]", "City A Hub must open")
	_check(not _button.visible, "Button must hide once inside the city")
	_check(not _player.is_physics_processing() and not _joystick.is_processing_input(), "World controls must pause inside the city")
	_check(_hub.get_market_row_texts("test_good_01").get("price") == "Price 80" and _hub.get_market_good_ids().size() == 6, "Market must be available after touch entry")

	# A second touch on the same spot must not enter again or trigger anything.
	var money: int = _main.wallet.get_balance()
	await _touch(_button_center())
	_check(_main.current_city_id == "A" and _hub.is_open() and _main.wallet.get_balance() == money and _main.cargo.is_empty(), "Repeated touch must not duplicate entry or press hub controls")

	# M2-05 Buy still works after touch entry.
	await _touch(_control_center(_hub.get_market_button("test_good_01", "buy")))
	_check(_main.wallet.get_balance() == 9920 and _main.cargo.get_quantity("test_good_01") == 1, "Touch Buy 1 must still work after touch entry")
	_check(_hub.get_money_label_text() == "Money: 9920" and _hub.get_cargo_label_text() == "Cargo: 1 / 20", "Market must refresh after touch buy")

	await _touch(_control_center(_hub.get_node("Center/Content/LeaveButton") as Control))
	_check(not _main.is_in_city() and not _hub.is_open(), "Leave City must return to the world")
	_check(_player.global_position == WorldLayout.CITY_RETURN_POINTS["A"], "Leave must use the City A return point")
	_check(not _button.visible, "Button must stay hidden right after leaving")
	await _settle()
	_check(not _button.visible, "Button must stay hidden at the safe return point")
	_check(_main.wallet.get_balance() == 9920 and _main.cargo.get_quantity("test_good_01") == 1, "Leaving must keep money and cargo")


func _verify_touch_enter_b() -> void:
	await _place(WorldLayout.CITY_B)
	await _touch(_button_center())
	_check(_main.current_city_id == "B" and _hub.get_city_label_text() == "[ City B ]", "Touch Enter in B must enter City B")
	_check(not _button.visible, "Button must hide inside City B")
	_check(_hub.get_market_row_texts("test_good_01").get("price") == "Price 120", "City B market must show B prices")
	await _touch(_control_center(_hub.get_market_button("test_good_01", "sell")))
	_check(_main.wallet.get_balance() == 9920 + 120 and _main.cargo.is_empty(), "Touch Sell 1 must still work in B")
	_check(_main.leave_city() and _player.global_position == WorldLayout.CITY_RETURN_POINTS["B"], "Leave B must use the City B return point")
	await _settle()
	_check(not _button.visible, "Button must stay hidden at the City B return point")


func _verify_keyboard_e() -> void:
	for city_id in ["A", "B"]:
		await _place(WorldLayout.CITY_ANCHORS[city_id])
		await _press_e()
		_check(_main.current_city_id == city_id, "Keyboard E must still enter City %s" % city_id)
		_check(not _button.visible, "Button must hide after keyboard entry into %s" % city_id)
		_main.leave_city()
		await _settle()


func _verify_layout() -> void:
	await _place(WorldLayout.CITY_A)
	var rect := _button.get_global_rect()
	_check(PORTRAIT_RECT.encloses(rect), "Button must fit the 720 x 1280 reference")
	_check(rect.size.x >= 200.0 and rect.size.y >= 88.0, "Button must be touch-sized (%s)" % str(rect.size))
	_check(rect.position.x > JOYSTICK_AREA_RIGHT_EDGE, "Button must stay out of the left joystick area")
	_check(rect.position.y >= PORTRAIT_RECT.size.y / 2.0, "Button must sit in the lower half")
	# Opening the hub right after a double tap must not land on a hub control.
	await _touch(_button_center())
	await process_frame
	var hub_controls: Array = [_hub.get_node("Center/Content/LeaveButton")]
	for good_id in GoodsCatalog.get_ids():
		hub_controls.append(_hub.get_market_button(good_id, "buy"))
		hub_controls.append(_hub.get_market_button(good_id, "sell"))
	var overlaps := false
	for control in hub_controls:
		if (control as Control).get_global_rect().intersects(rect):
			overlaps = true
	_check(not overlaps, "Enter City button area must not overlap any City Hub button")
	_main.leave_city()
	await _settle()


# --- Stress --------------------------------------------------------------------

## Deterministic mix of touches inside and outside city range, releases, range
## changes and enter/leave, checking visibility and entry on every step.
func _verify_stress() -> void:
	var places := [OUTSIDE_POINTS[0], WorldLayout.CITY_A, WorldLayout.CITY_B, OUTSIDE_POINTS[1], WorldLayout.CITY_A + Vector2(60.0, 40.0), WorldLayout.CITY_B + Vector2(-50.0, 30.0)]
	var seed := 777
	var wrong_visibility := 0
	var wrong_entry := 0
	var wrong_city := 0
	var counts := {"entered": 0, "rejected": 0, "left": 0, "moves": 0, "releases": 0}
	for attempt in range(STRESS_ATTEMPTS):
		seed = (seed * 1103515245 + 12345) % 2147483648
		var bits := seed >> 8
		var action := bits % 4
		if _main.is_in_city() and action != 3:
			_main.leave_city()
			counts["left"] += 1
			await _settle()
		# 0 = move only, 1 = move then touch, 2 = touch in place, 3 = bare release.
		if action == 0 or action == 1:
			await _place(places[(bits >> 3) % places.size()])
			counts["moves"] += 1
		elif action == 3:
			# A bare touch release on the button spot must never do anything.
			await _touch_event(_button_center(), false)
			counts["releases"] += 1
		var expected_city := _expected_enterable_city()
		if _button.visible != (expected_city != ""):
			wrong_visibility += 1
		if action == 1 or action == 2:
			var was_in_city: bool = _main.is_in_city()
			await _touch(_button_center())
			if was_in_city or expected_city == "":
				if _main.is_in_city() != was_in_city:
					wrong_entry += 1
				counts["rejected"] += 1
			else:
				if _main.current_city_id != expected_city:
					wrong_city += 1
				if _button.visible or not _hub.is_open():
					wrong_visibility += 1
				counts["entered"] += 1
	_check(wrong_visibility == 0, "Stress: button visibility must always match city range (%d wrong)" % wrong_visibility)
	_check(wrong_entry == 0, "Stress: touches out of range or inside a city must not change entry (%d wrong)" % wrong_entry)
	_check(wrong_city == 0, "Stress: touch entry must always open the correct city (%d wrong)" % wrong_city)
	_check(counts["entered"] >= 15 and counts["rejected"] >= 15 and counts["moves"] >= 15 and counts["releases"] >= 15, "Stress: must mix entries, rejected touches, moves and releases %s" % str(counts))
	_check(_button.pressed.get_connections().size() == 1 and _hub.leave_requested.get_connections().size() == 1, "Stress: no duplicate signal connections")
	_check(_count_nodes(root, "CityHub") == 1 and _count_nodes(root, "Player") == 1, "Stress: no duplicate hub or player")
	print("M2-05A stress counts: ", counts)
	if _main.is_in_city():
		_main.leave_city()
		await _settle()


func _expected_enterable_city() -> String:
	if _main.is_in_city():
		return ""
	for city_id in ["A", "B"]:
		var anchor: Vector2 = WorldLayout.CITY_ANCHORS[city_id]
		var body := Rect2(_player.global_position + Vector2(-16.0, -48.0), Vector2(32.0, 48.0))
		if anchor.clamp(body.position, body.end).distance_to(anchor) <= 240.0:
			return city_id
	return ""


func _verify_movement_still_works() -> void:
	await _place(OUTSIDE_POINTS[0])
	var before := _player.global_position
	Input.action_press("move_right")
	for frame in range(10):
		await physics_frame
	Input.action_release("move_right")
	_check(_player.global_position.x > before.x, "Player movement must still work")
	_check(_joystick.is_processing_input(), "Joystick must accept touches in the world")


# --- Helpers ---------------------------------------------------------------------

func _button_center() -> Vector2:
	return _control_center(_button)


func _control_center(control: Control) -> Vector2:
	return control.get_global_rect().get_center()


## Sends a real touch press and release at a 720 x 1280 reference position.
func _touch(position: Vector2) -> void:
	await process_frame
	await _touch_event(position, true)
	await _touch_event(position, false)


func _touch_event(position: Vector2, pressed: bool) -> void:
	var touch := InputEventScreenTouch.new()
	touch.index = 0
	touch.pressed = pressed
	touch.position = root.get_final_transform() * position
	Input.parse_input_event(touch)
	await process_frame
	await process_frame


func _press_e() -> void:
	for pressed in [true, false]:
		var key := InputEventKey.new()
		key.physical_keycode = KEY_E
		key.keycode = KEY_E
		key.pressed = pressed
		Input.parse_input_event(key)
		await process_frame
		await process_frame


func _place(position: Vector2) -> void:
	_player.global_position = position
	await _settle()


func _settle() -> void:
	# Area2D overlaps update a few physics frames after a teleport.
	for frame in range(4):
		await physics_frame
	await process_frame


func _count_nodes(node: Node, kind: String) -> int:
	var total := 0
	if (kind == "CityHub" and node is CityHub) or (kind == "Player" and node is Player):
		total = 1
	for child in node.get_children():
		total += _count_nodes(child, kind)
	return total


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
