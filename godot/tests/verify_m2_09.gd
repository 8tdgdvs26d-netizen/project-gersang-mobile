extends SceneTree

## M2-09 intercity paid passenger transport.
## Uses its own save files so the player's real save is never touched, and a
## fixed TimeSource so every ETA check is deterministic.

const TEST_SAVE := "user://m2_09_test_save.json"
const UNWRITABLE_SAVE := "user://m2_09_missing_dir/nested/save.json"
const T0 := 1800000000000
const FARE := 300
const DURATION := 90000
const SPAWN := Vector2(420.0, 500.0)
const STRESS_STEPS := 200

var _checks := 0
var _failures := 0
## A script error silently aborts the running function, so every section
## records that it reached its end and the run fails if any section did not.
var _sections_done := []
var _approved := RegEx.new()
var _latin := RegEx.new()


## A location whose journey creation always fails after the fare is charged.
class FailingStartLocation extends PlayerLocation:
	func start_journey(_journey: Dictionary) -> bool:
		return false


func _initialize() -> void:
	_latin.compile("[A-Za-z]")
	_approved.compile("(?<![A-Za-z])[ABE](?![A-Za-z])")
	_delete(TEST_SAVE)
	_verify_static()
	_verify_time_source()
	_verify_routes_and_quotes()
	_verify_journey_model()
	_verify_rejections()
	_verify_duplicates()
	_verify_rollback()
	_verify_location_validation()
	_verify_save_versions()
	await _verify_game_flow()
	await _verify_reopen_after_eta()
	await _verify_return_point()
	await _verify_over_capacity_and_goods()
	await _verify_ui_failures()
	await _verify_arrival_save_failure()
	await _verify_stress()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 16, "Every test section must run to completion (%s)" % str(_sections_done))

	if _failures == 0:
		print("M2-09 passenger transport verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static structure ----------------------------------------------------------------

func _verify_static() -> void:
	var service := _code_only("res://scripts/transport_service.gd")
	for forbidden in ["CharacterInventory", "CharacterStats", "MarketState", "Cargo", "inventory", "market", "warehouse", "Warehouse", "capacity", "TradeService"]:
		_check(not service.contains(forbidden), "TransportService code must not reference %s (passenger-only)" % forbidden)
	var routes := _code_only("res://scripts/transport_routes.gd")
	for forbidden in ["capacity", "cargo", "storage", "freight", "slots"]:
		_check(not routes.to_lower().contains(forbidden), "Route data must not carry %s" % forbidden)
	var service_source := FileAccess.get_file_as_string("res://scripts/transport_service.gd")
	_check(service_source.contains("PROTOTYPE LIMITATION") and service_source.contains("Transport risk / encounter interaction must be revisited when Stage 3 Encounter system is integrated"), "The no-encounter journey must be marked as a prototype limitation")
	_check(not service_source.to_lower().contains("transport is permanently safe"), "Transport must not be declared permanently safe")
	_check(FileAccess.get_file_as_string("res://scripts/transport_routes.gd").contains("PROTOTYPE PARAMETERS"), "Fares and durations must be marked as prototype parameters")
	# Raw clock calls live only in TimeSource.
	for file_name in DirAccess.get_files_at("res://scripts"):
		if not file_name.ends_with(".gd") or file_name == "time_source.gd":
			continue
		var code := _code_only("res://scripts/" + file_name)
		for clock in ["Time.get_", "OS.get_unix", "get_ticks"]:
			_check(not code.contains(clock), "%s must read time through TimeSource, not %s" % [file_name, clock])
	# Numbers come from the route table, not from magic numbers in the service or main.
	for path in ["res://scripts/transport_service.gd", "res://scripts/main.gd", "res://scripts/city_hub.gd"]:
		var code := _code_only(path)
		_check(not code.contains("90000") and not code.contains("300"), "%s must not hard-code fares or durations" % path)
	_check(SaveStore.VERSION == 4, "Save version must be bumped to 4")
	_sections_done.append("_verify_static")


# --- Time source ------------------------------------------------------------------------

func _verify_time_source() -> void:
	var clock := TimeSource.fixed(T0)
	_check(clock.is_fixed() and clock.now_ms() == T0, "A fixed clock must return its time")
	_check(clock.now_ms() == T0, "A fixed clock must not move by itself")
	clock.advance_ms(1500)
	_check(clock.now_ms() == T0 + 1500, "advance_ms must move a fixed clock exactly")
	clock.set_now_ms(42)
	_check(clock.now_ms() == 42, "set_now_ms must set a fixed clock exactly")
	var system := TimeSource.new()
	var system_now := system.now_ms()
	_check(not system.is_fixed() and system_now > 1600000000000 and abs(system_now - int(Time.get_unix_time_from_system() * 1000.0)) < 5000, "The default clock must be local system time in milliseconds")
	_sections_done.append("_verify_time_source")


# --- Routes and quotes -------------------------------------------------------------------

func _verify_routes_and_quotes() -> void:
	for pair in [["A", "B"], ["B", "A"]]:
		var route := TransportRoutes.get_route(pair[0], pair[1])
		_check(route == {"fare": FARE, "duration_ms": DURATION}, "%s->%s route must be the prototype fare and duration" % pair)
		var offer := TransportService.quote(pair[0], pair[1])
		_check(offer["success"] and offer["fare"] == FARE and offer["duration_ms"] == DURATION, "%s->%s quote must come from the route data" % pair)
	_check(TransportRoutes.get_destinations("A") == ["B"] and TransportRoutes.get_destinations("B") == ["A"], "A and B must only reach each other")
	_check(TransportRoutes.get_destinations("C").is_empty() and TransportRoutes.get_destinations(5).is_empty(), "Reserved or invalid cities must have no routes")
	var copy := TransportRoutes.get_route("A", "B")
	copy["fare"] = 1
	_check(TransportRoutes.get_route("A", "B")["fare"] == FARE, "Route lookups must return copies")
	_check(TransportRoutes.ROUTES.keys().size() == 2 and not TransportRoutes.ROUTES.has("C") and not TransportRoutes.ROUTES.has("D"), "Only the two active cities may have routes")
	_sections_done.append("_verify_routes_and_quotes")


# --- Journey model (service level) ----------------------------------------------------------

func _verify_journey_model() -> void:
	for pair in [["A", "B"], ["B", "A"]]:
		var origin: String = pair[0]
		var destination: String = pair[1]
		var location := _location_in(origin)
		var wallet := Wallet.new()
		var persisted := []
		var persist := func() -> bool:
			persisted.append({"money": wallet.get_balance(), "mode": location.get_mode()})
			return true
		var result := TransportService.begin_journey(location, wallet, destination, "ride-" + origin, T0, persist)
		_check(result["success"] and result["reason"] == "", "%s->%s must start" % pair)
		_check(wallet.get_balance() == 10000 - FARE, "%s->%s must charge exactly the fare" % pair)
		_check(persisted == [{"money": 10000 - FARE, "mode": "TRAVELING"}], "The new journey must be saved once, after the charge")
		var journey := location.get_journey()
		_check(journey == {"journey_id": "ride-" + origin, "status": "traveling", "origin_city_id": origin, "destination_city_id": destination, "started_at_ms": T0, "arrives_at_ms": T0 + DURATION, "fare": FARE}, "%s->%s journey record (%s)" % [origin, destination, str(journey)])
		_check(location.is_traveling() and location.get_journey_status() == "traveling" and location.get_city_id() == "", "Location must be traveling")
		_check(TransportService.remaining_ms(location, T0) == DURATION and TransportService.remaining_ms(location, T0 + 30000) == DURATION - 30000, "Remaining time must count down from the ETA")
		var early := TransportService.settle_arrival(location, T0 + DURATION - 1, persist)
		_check(not early["success"] and early["reason"] == "ERR_NOT_ARRIVED" and location.is_traveling(), "Arrival must wait for the ETA")
		var arrived := TransportService.settle_arrival(location, T0 + DURATION, persist)
		_check(arrived["success"] and arrived["city_id"] == destination and arrived["journey_id"] == "ride-" + origin, "%s->%s must arrive at the ETA" % pair)
		_check(location.is_in_city() and location.get_city_id() == destination and location.get_journey().is_empty() and location.get_journey_status() == "none", "Arrival must put the character inside %s and clear the journey" % destination)
		var again := TransportService.settle_arrival(location, T0 + DURATION * 5, persist)
		_check(not again["success"] and again["reason"] == "ERR_NOT_TRAVELING" and location.get_city_id() == destination, "A journey must settle only once")
		_check(wallet.get_balance() == 10000 - FARE and persisted.size() == 2, "Arrival must not change money and must save once")

	# Exact fare leaves exactly zero.
	var exact := Wallet.new()
	exact.spend(10000 - FARE)
	var location := _location_in("A")
	_check(TransportService.begin_journey(location, exact, "B", "exact", T0)["success"] and exact.get_balance() == 0, "Exactly the fare must succeed and leave 0")

	# A failed arrival save must leave the journey exactly as it was saved.
	var traveling := location.to_dict()
	var attempts := []
	var failing := func() -> bool:
		attempts.append(location.get_mode())
		return false
	var failed := TransportService.settle_arrival(location, T0 + DURATION, failing)
	_check(not failed["success"] and failed["reason"] == "ERR_SAVE_FAILED", "A failed arrival save must reject the arrival")
	_check(attempts == ["IN_CITY"], "The arrival save must have been attempted with the arrived state")
	_check(location.to_dict() == traveling and location.is_traveling() and location.get_city_id() == "", "A failed arrival save must restore the unfinished journey exactly")
	_check(exact.get_balance() == 0, "A failed arrival must not change money")
	var retried := TransportService.settle_arrival(location, T0 + DURATION + 5, func() -> bool: return true)
	_check(retried["success"] and retried["city_id"] == "B" and location.get_city_id() == "B", "Retrying after a failed arrival save must arrive once")
	_check(not TransportService.settle_arrival(location, T0 + DURATION + 10)["success"] and exact.get_balance() == 0, "The retried journey must not settle again")
	_sections_done.append("_verify_journey_model")


# --- Rejections ---------------------------------------------------------------------------------

func _verify_rejections() -> void:
	var cases := [
		["A", 10000, "B", "ok-control", "", true],
		["A", FARE - 1, "B", "poor", "ERR_INSUFFICIENT_FUNDS", false],
		["A", 10000, "A", "same", "ERR_ALREADY_THERE", false],
		["B", 10000, "B", "same-b", "ERR_ALREADY_THERE", false],
		["A", 10000, "Z", "unknown", "ERR_INVALID_DESTINATION", false],
		["A", 10000, "", "empty", "ERR_INVALID_DESTINATION", false],
		["A", 10000, "b", "lower", "ERR_INVALID_DESTINATION", false],
		["A", 10000, 7, "number", "ERR_INVALID_DESTINATION", false],
		["A", 10000, null, "null", "ERR_INVALID_DESTINATION", false],
		["A", 10000, "C", "reserved-c", "ERR_TRANSPORT_UNAVAILABLE", false],
		["B", 10000, "D", "reserved-d", "ERR_TRANSPORT_UNAVAILABLE", false],
		["A", 10000, "B", "", "ERR_INVALID_REQUEST", false],
		["A", 10000, "B", 12, "ERR_INVALID_REQUEST", false],
		["A", 10000, "B", "x".repeat(65), "ERR_INVALID_REQUEST", false],
	]
	for case in cases:
		var location := _location_in(case[0])
		var wallet := _wallet_with(case[1])
		var before := location.to_dict()
		var result := TransportService.begin_journey(location, wallet, case[2], case[3], T0)
		_check(result["success"] == case[5] and result["reason"] == case[4], "%s -> %s: expected %s, got %s" % [case[0], str(case[2]), case[4], result["reason"]])
		if not case[5]:
			_check(wallet.get_balance() == case[1] and location.to_dict() == before, "Rejected %s must change nothing" % case[4])
	# Not inside a city: world (fresh or after leaving) and invalid state.
	var world := PlayerLocation.new()
	var wallet := Wallet.new()
	_check(TransportService.begin_journey(world, wallet, "B", "w1", T0)["reason"] == "ERR_NOT_IN_CITY" and wallet.get_balance() == 10000 and world.is_in_world(), "Boarding from the world must be rejected")
	var left := _location_in("A")
	left.leave_city()
	_check(TransportService.begin_journey(left, wallet, "B", "w2", T0)["reason"] == "ERR_NOT_IN_CITY" and wallet.get_balance() == 10000, "Boarding after leaving the city must be rejected")
	_check(TransportService.begin_journey(null, wallet, "B", "w3", T0)["reason"] == "ERR_INVALID_STATE", "A missing location must be rejected")
	_check(TransportService.begin_journey(_location_in("A"), null, "B", "w4", T0)["reason"] == "ERR_INVALID_STATE", "A missing wallet must be rejected")
	for bad_time in [-1, 1.5, "now", null]:
		var location := _location_in("A")
		_check(TransportService.begin_journey(location, wallet, "B", "t", bad_time)["reason"] == "ERR_INVALID_STATE" and wallet.get_balance() == 10000 and location.is_in_city(), "Invalid time %s must be rejected" % str(bad_time))
	# Quotes for invalid pairs.
	_check(TransportService.quote("A", "C")["reason"] == "ERR_TRANSPORT_UNAVAILABLE" and TransportService.quote("A", "A")["reason"] == "ERR_ALREADY_THERE" and TransportService.quote("A", "Q")["reason"] == "ERR_INVALID_DESTINATION", "Quotes must reject invalid routes deterministically")
	_sections_done.append("_verify_rejections")


# --- Duplicates ---------------------------------------------------------------------------------

func _verify_duplicates() -> void:
	var location := _location_in("A")
	var wallet := Wallet.new()
	_check(TransportService.begin_journey(location, wallet, "B", "tap", T0)["success"], "First press must start the journey")
	var second := TransportService.begin_journey(location, wallet, "B", "tap", T0)
	_check(not second["success"] and second["reason"] == "ERR_DUPLICATE_REQUEST" and wallet.get_balance() == 10000 - FARE, "A repeated press must not charge twice")
	var other := TransportService.begin_journey(location, wallet, "A", "another", T0 + 10)
	_check(not other["success"] and other["reason"] == "ERR_ALREADY_TRAVELING" and wallet.get_balance() == 10000 - FARE, "A second journey while traveling must be rejected")
	_check(location.get_journey()["journey_id"] == "tap" and location.get_journey()["started_at_ms"] == T0, "The first journey must be unchanged")
	TransportService.settle_arrival(location, T0 + DURATION)
	var late_tap := TransportService.begin_journey(location, wallet, "A", "tap", T0 + DURATION + 1)
	_check(not late_tap["success"] and late_tap["reason"] == "ERR_DUPLICATE_REQUEST" and location.get_city_id() == "B" and wallet.get_balance() == 10000 - FARE, "The same press arriving after A->B must not start B->A")
	_check(TransportService.begin_journey(location, wallet, "A", "new-tap", T0 + DURATION + 2)["success"] and wallet.get_balance() == 10000 - 2 * FARE, "A new request must start a new journey")
	_sections_done.append("_verify_duplicates")


# --- Rollback -----------------------------------------------------------------------------------

func _verify_rollback() -> void:
	# Save failure after the charge.
	var location := _location_in("A")
	var wallet := Wallet.new()
	var before := location.to_dict()
	var seen := []
	var failing_save := func() -> bool:
		seen.append(wallet.get_balance())
		return false
	var result := TransportService.begin_journey(location, wallet, "B", "save-fails", T0, failing_save)
	_check(not result["success"] and result["reason"] == "ERR_SAVE_FAILED", "A failed save must reject the journey")
	_check(seen == [10000 - FARE], "The save must have been attempted after the charge")
	_check(wallet.get_balance() == 10000 and location.to_dict() == before, "A failed save must roll back money and location completely")
	_check(TransportService.begin_journey(location, wallet, "B", "save-fails", T0)["success"], "After a rolled-back save failure the same request may be retried")

	# Journey creation failure after the charge.
	var failing := FailingStartLocation.new()
	failing.enter_city("A")
	var failing_before := failing.to_dict()
	var wallet2 := Wallet.new()
	var created := TransportService.begin_journey(failing, wallet2, "B", "create-fails", T0)
	_check(not created["success"] and created["reason"] == "ERR_JOURNEY_FAILED", "A failed journey creation must be rejected")
	_check(wallet2.get_balance() == 10000 and failing.to_dict() == failing_before, "A failed journey creation must roll back money and location")
	_sections_done.append("_verify_rollback")


# --- Location validation --------------------------------------------------------------------------

func _verify_location_validation() -> void:
	var journey := {"journey_id": "j1", "status": "traveling", "origin_city_id": "A", "destination_city_id": "B", "started_at_ms": T0, "arrives_at_ms": T0 + DURATION, "fare": FARE}
	var valid := [
		{"mode": "WORLD", "city_id": "", "journey": null, "last_journey_id": ""},
		{"mode": "WORLD", "city_id": "B", "journey": null, "last_journey_id": "old"},
		{"mode": "IN_CITY", "city_id": "A", "journey": null, "last_journey_id": ""},
		{"mode": "TRAVELING", "city_id": "", "journey": journey, "last_journey_id": "j1"},
		{"mode": "TRAVELING", "city_id": "", "journey": _with(journey, {"started_at_ms": float(T0), "arrives_at_ms": float(T0 + DURATION), "fare": 300.0}), "last_journey_id": "j1"},
	]
	for data in valid:
		_check(PlayerLocation.from_dict(data) != null, "Valid location must load: %s" % str(data))
	var corrupt := {
		"not a dictionary": [1, 2],
		"missing key": {"mode": "WORLD", "city_id": "", "journey": null},
		"extra key": {"mode": "WORLD", "city_id": "", "journey": null, "last_journey_id": "", "position": [1, 2]},
		"unknown mode": {"mode": "FLYING", "city_id": "", "journey": null, "last_journey_id": ""},
		"mode not string": {"mode": 1, "city_id": "", "journey": null, "last_journey_id": ""},
		"in city C": {"mode": "IN_CITY", "city_id": "C", "journey": null, "last_journey_id": ""},
		"in city empty": {"mode": "IN_CITY", "city_id": "", "journey": null, "last_journey_id": ""},
		"world unknown city": {"mode": "WORLD", "city_id": "Z", "journey": null, "last_journey_id": ""},
		"city with journey": {"mode": "IN_CITY", "city_id": "A", "journey": journey, "last_journey_id": "j1"},
		"traveling without journey": {"mode": "TRAVELING", "city_id": "", "journey": null, "last_journey_id": "j1"},
		"traveling with city": {"mode": "TRAVELING", "city_id": "A", "journey": journey, "last_journey_id": "j1"},
		"journey id mismatch": {"mode": "TRAVELING", "city_id": "", "journey": journey, "last_journey_id": "other"},
		"last id not string": {"mode": "WORLD", "city_id": "", "journey": null, "last_journey_id": 5},
	}
	var bad_journeys := {
		"journey missing field": _without(journey, "fare"),
		"journey extra field": _with(journey, {"cargo_slots": 4}),
		"journey status": _with(journey, {"status": "none"}),
		"journey same city": _with(journey, {"destination_city_id": "A"}),
		"journey reserved city": _with(journey, {"destination_city_id": "C"}),
		"journey unknown origin": _with(journey, {"origin_city_id": "Z"}),
		"journey arrives before start": _with(journey, {"arrives_at_ms": T0 - 1}),
		"journey zero duration": _with(journey, {"arrives_at_ms": T0}),
		"journey too long": _with(journey, {"arrives_at_ms": T0 + PlayerLocation.MAX_JOURNEY_DURATION_MS + 1}),
		"journey zero fare": _with(journey, {"fare": 0}),
		"journey negative fare": _with(journey, {"fare": -300}),
		"journey fractional fare": _with(journey, {"fare": 300.5}),
		"journey string time": _with(journey, {"started_at_ms": "1800000000000"}),
		"journey negative time": _with(journey, {"started_at_ms": -5}),
		"journey empty id": _with(journey, {"journey_id": ""}),
		"journey not dictionary": "A->B",
	}
	for label in bad_journeys:
		var bad_journey: Variant = bad_journeys[label]
		var last_id: String = bad_journey.get("journey_id", "j1") if typeof(bad_journey) == TYPE_DICTIONARY and typeof(bad_journey.get("journey_id")) == TYPE_STRING else "j1"
		corrupt[label] = {"mode": "TRAVELING", "city_id": "", "journey": bad_journey, "last_journey_id": last_id}
	for label in corrupt:
		_check(PlayerLocation.from_dict(corrupt[label]) == null, "Corrupt location must be rejected (%s)" % label)
	# Transitions.
	var location := PlayerLocation.new()
	_check(location.is_in_world() and location.get_journey_status() == "none", "A new location is in the world")
	_check(not location.leave_city() and not location.enter_city("C") and not location.enter_city("Z"), "Invalid transitions must be rejected")
	_check(location.enter_city("A") and not location.enter_city("B"), "Entering a city from inside another must be rejected")
	_check(location.complete_journey() == "" and location.get_city_id() == "A", "Completing without a journey must do nothing")
	_check(not location.start_journey(_with(journey, {"origin_city_id": "B", "destination_city_id": "A"})), "A journey must start from the current city")
	_sections_done.append("_verify_location_validation")


# --- Save versions --------------------------------------------------------------------------------

func _verify_save_versions() -> void:
	var market := MarketState.create_default().get_snapshot()
	var character := {"id": "player", "stats": {"strength": 10}, "inventory": {"items": {"test_good_02": {"quantity": 3}}}}
	var legacy := {
		"v1": {"version": 1, "money": 7777, "cargo": {"test_good_02": 3}},
		"v1 unversioned": {"money": 7777, "cargo": {"test_good_02": 3}},
		"v2": {"version": 2, "money": 7777, "cargo": {"test_good_02": 3}, "market": market},
		"v3": {"version": 3, "money": 7777, "character": character, "market": market},
	}
	for label in legacy:
		_write_json(legacy[label])
		var text := _read(TEST_SAVE)
		var loaded := SaveStore.load_session(TEST_SAVE)
		_check(not loaded.is_empty() and loaded["wallet"].get_balance() == 7777 and loaded["inventory"].get_quantity("test_good_02") == 3, "%s save must load money and goods" % label)
		var location: PlayerLocation = loaded.get("location")
		_check(location != null and location.to_dict() == {"mode": "WORLD", "city_id": "", "journey": null, "last_journey_id": ""}, "%s save without a location must use the safe world default" % label)
		_check(_read(TEST_SAVE) == text, "Loading a %s save must not rewrite it" % label)

	# v4 round trips for every mode.
	var journey := {"journey_id": "j9", "status": "traveling", "origin_city_id": "B", "destination_city_id": "A", "started_at_ms": T0, "arrives_at_ms": T0 + DURATION, "fare": FARE}
	for data in [
		{"mode": "WORLD", "city_id": "A", "journey": null, "last_journey_id": "j0"},
		{"mode": "IN_CITY", "city_id": "B", "journey": null, "last_journey_id": ""},
		{"mode": "TRAVELING", "city_id": "", "journey": journey, "last_journey_id": "j9"},
	]:
		var location := PlayerLocation.from_dict(data)
		_check(SaveStore.save(TEST_SAVE, _wallet_with(5000), CharacterInventory.new(), MarketState.create_default(), location), "v4 save must write (%s)" % data["mode"])
		var raw := _read_json()
		_check(int(raw.get("version", 0)) == 4 and raw.has("location") and raw.keys().size() == 5, "v4 save must hold version, money, character, market and location")
		var loaded := SaveStore.load_session(TEST_SAVE)
		_check(not loaded.is_empty() and loaded["location"].to_dict() == data and loaded["wallet"].get_balance() == 5000, "v4 %s location must round-trip exactly" % data["mode"])

	# Corrupt or incompatible new data rejects the whole save.
	var v4 := {"version": 4, "money": 4321, "character": character, "market": market, "location": {"mode": "IN_CITY", "city_id": "A", "journey": null, "last_journey_id": ""}}
	_write_json(v4)
	_check(not SaveStore.load_session(TEST_SAVE).is_empty(), "A valid hand-written v4 save must load")
	var broken := {
		"v4 missing location": _without(v4, "location"),
		"v4 location null": _with(v4, {"location": null}),
		"v4 bad mode": _with(v4, {"location": {"mode": "SAILING", "city_id": "A", "journey": null, "last_journey_id": ""}}),
		"v4 bad journey": _with(v4, {"location": {"mode": "TRAVELING", "city_id": "", "journey": _with(journey, {"fare": -1}), "last_journey_id": "j9"}}),
		"v4 reserved city": _with(v4, {"location": {"mode": "IN_CITY", "city_id": "D", "journey": null, "last_journey_id": ""}}),
		"v3 with location": _with(legacy["v3"], {"location": v4["location"]}),
		"v5": _with(v4, {"version": 5}),
	}
	for label in broken:
		_write_json(broken[label])
		var text := _read(TEST_SAVE)
		_check(SaveStore.load_session(TEST_SAVE).is_empty(), "%s must reject the whole save" % label)
		_check(_read(TEST_SAVE) == text, "%s must not be overwritten on load" % label)
	_delete(TEST_SAVE)
	_sections_done.append("_verify_save_versions")


# --- In-game flow -------------------------------------------------------------------------------

func _verify_game_flow() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE, T0)
	await _walk_in(main, "A")
	_check(int(_read_json()["version"]) == 4 and _read_json()["location"]["mode"] == "IN_CITY" and _read_json()["location"]["city_id"] == "A", "Entering City A must save the location")
	var hub := main.get_node("CityHub") as CityHub
	for press in range(3):
		hub.get_market_button("test_good_03", "buy").pressed.emit()
	var money_before: int = main.wallet.get_balance()
	var stacks_before: Dictionary = main.inventory.get_stacks()
	var used_before: int = main.inventory.get_used_capacity()
	var max_before: int = main.inventory.get_max_capacity()
	var market_before: Dictionary = main.market.get_snapshot()

	# Transport facility.
	_check(hub.get_facility() == "market", "The hub must open on the market")
	hub.show_facility("transport")
	await process_frame
	_check(hub.get_facility() == "transport", "The transport facility must open")
	_check(hub.get_transport_destinations() == ["B"], "City A transport must offer only B")
	_check(hub.get_transport_row_texts("B") == {"destination": "目的地：B 城", "fare": "車費：300", "duration": "預計時間：90 秒"}, "Transport offer must show destination, fare and time (%s)" % str(hub.get_transport_row_texts("B")))
	_check(hub.get_transport_button("B").text == "乘搭", "The ride button must read 乘搭")
	_check(not hub.get_market_button("test_good_01", "buy").is_visible_in_tree() and hub.get_transport_button("B").is_visible_in_tree(), "Transport and market must be separate facility views")
	_check(_chinese(hub), "Transport facility text must be Traditional Chinese")
	var layout_ok := true
	for control in [hub.get_transport_button("B"), hub.get_node("Center/Content/LeaveButton"), hub.get_node("Center/Content/FacilityTabs/TransportTabButton")]:
		if not Rect2(Vector2.ZERO, Vector2(720, 1280)).encloses((control as Control).get_global_rect()):
			layout_ok = false
	_check(layout_ok, "Transport controls must fit the 720 x 1280 portrait layout")

	# Double tap charges once.
	var ride := hub.get_transport_button("B")
	ride.pressed.emit()
	ride.pressed.emit()
	_check(main.wallet.get_balance() == money_before - FARE, "A double tap must charge exactly one fare")
	_check(main.is_traveling() and main.current_city_id == "" and hub.get_facility() == "traveling", "The journey must start and show the traveling view")
	_check(hub.get_travel_texts() == {"title": "旅途中", "destination": "前往 B 城", "remaining": "預計抵達：90 秒"}, "Traveling view must show destination and ETA (%s)" % str(hub.get_travel_texts()))
	_check(not hub.is_leave_available() and not hub.get_node("Center/Content/FacilityTabs").visible, "No leaving or facilities during the journey")
	_check(_chinese(hub), "Traveling view text must be Traditional Chinese")
	_check(_movement_locked(main), "World movement must be locked while traveling")
	var saved := _read_json()
	_check(saved["location"]["mode"] == "TRAVELING" and saved["location"]["journey"]["origin_city_id"] == "A" and saved["location"]["journey"]["destination_city_id"] == "B" and int(saved["location"]["journey"]["started_at_ms"]) == T0 and int(saved["location"]["journey"]["arrives_at_ms"]) == T0 + DURATION and int(saved["location"]["journey"]["fare"]) == FARE and int(saved["money"]) == money_before - FARE, "The journey must be saved with origin, destination, times and fare")
	_check(not main.enter_city("A") and not main.try_enter_city() and not main.leave_city(), "City entry/exit must be locked while traveling")
	_check(main.buy_in_current_city("test_good_01", 1)["reason"] == "not_in_city", "Trading must be locked while traveling")
	_check(main.request_transport("A", "fresh-id")["reason"] == "ERR_ALREADY_TRAVELING" and main.wallet.get_balance() == money_before - FARE, "A second journey must be rejected without charge")
	(main.get_node("EnterControls/EnterCityButton") as Button).pressed.emit()
	_check(main.is_traveling(), "The touch Enter City button must not interrupt a journey")
	_check(_goods_unchanged(main, stacks_before, used_before, max_before) and main.market.get_snapshot() == market_before, "Boarding must not change goods, capacity or market")

	# Countdown.
	main.time_source.advance_ms(30000)
	await process_frame
	_check(main.is_traveling() and hub.get_travel_texts()["remaining"] == "預計抵達：60 秒", "Countdown must follow the clock")

	# Case 1: reopen before the ETA.
	await _destroy(main)
	var file_before := _read(TEST_SAVE)
	main = await _new_main(TEST_SAVE, T0 + 45000)
	hub = main.get_node("CityHub") as CityHub
	_check(main.is_traveling() and hub.get_facility() == "traveling" and hub.get_travel_texts()["remaining"] == "預計抵達：45 秒", "Reopening before the ETA must restore the journey and countdown")
	_check(main.wallet.get_balance() == money_before - FARE and _read(TEST_SAVE) == file_before, "Reopening mid-journey must not charge or rewrite the save")
	_check(_movement_locked(main), "Movement must stay locked after reopening mid-journey")
	_check(_goods_unchanged(main, stacks_before, used_before, max_before) and main.market.get_snapshot() == market_before, "Reloaded journey must keep goods and market")

	# Arrival while running.
	main.time_source.set_now_ms(T0 + DURATION - 1)
	await process_frame
	_check(main.is_traveling(), "No arrival one millisecond before the ETA")
	main.time_source.set_now_ms(T0 + DURATION)
	await process_frame
	_check(main.current_city_id == "B" and not main.is_traveling() and hub.is_open() and hub.get_facility() == "market" and hub.get_city_label_text() == "【B 城】", "Arrival must open the City B hub directly")
	_check(_movement_locked(main), "Movement and joystick must stay disabled inside the destination hub")
	_check(main.wallet.get_balance() == money_before - FARE, "Arrival must not change money")
	_check(_goods_unchanged(main, stacks_before, used_before, max_before) and main.market.get_snapshot() == market_before, "Arrival must not change goods, capacity or market")
	saved = _read_json()
	_check(saved["location"] == {"mode": "IN_CITY", "city_id": "B", "journey": null, "last_journey_id": saved["location"]["last_journey_id"]} and saved["location"]["last_journey_id"] != "", "Arrival must be saved as inside City B with no journey")
	_check(main.update_journey() == false and main.current_city_id == "B", "A settled journey must not settle again")
	_check(main.request_transport("A", saved["location"]["last_journey_id"])["reason"] == "ERR_DUPLICATE_REQUEST" and main.current_city_id == "B", "The finished journey's request must not start B->A")
	hub.show_facility("transport")
	_check(hub.get_transport_destinations() == ["A"] and hub.get_transport_row_texts("A")["destination"] == "目的地：A 城", "City B transport must offer A")

	# Case 3: reopen an already settled save.
	await _destroy(main)
	file_before = _read(TEST_SAVE)
	main = await _new_main(TEST_SAVE, T0 + DURATION * 3)
	_check(main.current_city_id == "B" and (main.get_node("CityHub") as CityHub).is_open() and main.wallet.get_balance() == money_before - FARE, "Reopening a settled save must restore City B once, with no extra charge")
	_check(_read(TEST_SAVE) == file_before, "Reopening a settled save must not rewrite it")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("_verify_game_flow")


## Case 2: the ETA passed while the game was closed.
func _verify_reopen_after_eta() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE, T0)
	await _walk_in(main, "B")
	_check(main.request_transport("A", "closed-ride")["success"], "B->A must start")
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0 + DURATION + 3600000)
	_check(main.current_city_id == "A" and not main.is_traveling() and (main.get_node("CityHub") as CityHub).get_city_label_text() == "【A 城】", "Reopening after the ETA must arrive in City A")
	_check(main.wallet.get_balance() == 10000 - FARE, "Arrival on reopen must not charge again")
	var saved := _read_json()
	_check(saved["location"]["mode"] == "IN_CITY" and saved["location"]["city_id"] == "A" and saved["location"]["journey"] == null, "Arrival on reopen must be saved")
	await _destroy(main)
	for repeat in range(3):
		main = await _new_main(TEST_SAVE, T0 + DURATION * (10 + repeat))
		_check(main.current_city_id == "A" and main.wallet.get_balance() == 10000 - FARE and not main.is_traveling(), "Repeated reopen #%d must not settle or charge again" % repeat)
		await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("_verify_reopen_after_eta")


func _verify_return_point() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE, T0)
	await _walk_in(main, "A")
	main.request_transport("B", "to-b")
	main.time_source.advance_ms(DURATION)
	await process_frame
	_check(main.current_city_id == "B", "Must arrive in B")
	_check(main.leave_city(), "Must leave the destination city")
	var player := main.get_node("Actors/Player") as Player
	_check(player.global_position == WorldLayout.CITY_RETURN_POINTS["B"], "Leaving B must use the B return point")
	_check(player.is_physics_processing() and (main.get_node("TouchControls/Joystick") as TouchJoystick).is_processing_input(), "Movement must resume in the world")
	_check(_read_json()["location"] == {"mode": "WORLD", "city_id": "B", "journey": null, "last_journey_id": "to-b"}, "Leaving must save the world location with the B return context")
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0 + DURATION * 2)
	player = main.get_node("Actors/Player") as Player
	_check(main.location.is_in_world() and player.global_position == WorldLayout.CITY_RETURN_POINTS["B"] and player.global_position != SPAWN, "Reopening in the world after riding to B must not jump back to A")
	_check(player.is_physics_processing() and not (main.get_node("CityHub") as CityHub).is_open(), "Reopening in the world must allow movement")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("_verify_return_point")


func _verify_over_capacity_and_goods() -> void:
	var main := await _new_main("", T0)
	await _walk_in(main, "A")
	main.inventory.restore_items({"test_good_05": 5, "test_good_01": 4})
	main.character_stats.set_strength(0)
	_check(main.inventory.is_over_capacity(), "Setup: the character must be over capacity")
	var stacks: Dictionary = main.inventory.get_stacks()
	var used: int = main.inventory.get_used_capacity()
	var max_capacity: int = main.inventory.get_max_capacity()
	var strength: int = main.character_stats.get_strength()
	_check(main.request_transport("B", "heavy")["success"], "An over-capacity character may still ride (no new rule)")
	_check(_goods_unchanged(main, stacks, used, max_capacity) and main.inventory.is_over_capacity() and main.character_stats.get_strength() == strength, "Riding must not change goods, capacity, Strength or the over-capacity state")
	main.time_source.advance_ms(DURATION)
	await process_frame
	_check(main.current_city_id == "B" and _goods_unchanged(main, stacks, used, max_capacity) and main.inventory.is_over_capacity(), "Arrival must keep the exact same goods and capacity")
	_check(main.inventory.get_max_capacity() == CharacterStats.new(0).get_max_capacity(), "Transport must add no carrying capacity")
	await _destroy(main)
	_sections_done.append("_verify_over_capacity_and_goods")


func _verify_ui_failures() -> void:
	# Insufficient money through the button.
	var main := await _new_main("", T0)
	await _walk_in(main, "A")
	main.wallet.spend(10000 - (FARE - 1))
	var hub := main.get_node("CityHub") as CityHub
	hub.show_facility("transport")
	hub.get_transport_button("B").pressed.emit()
	_check(main.wallet.get_balance() == FARE - 1 and main.current_city_id == "A" and hub.get_feedback_text() == "金錢不足", "Too little money must show 金錢不足 and change nothing")
	_check(hub.get_facility() == "transport" and _chinese(hub), "Failure must keep the Chinese transport view")
	for reason in CityHub.TRANSPORT_FAILURE_MESSAGES:
		hub.show_transport_feedback({"success": false, "reason": reason})
		_check(_is_player_chinese(hub.get_feedback_text()), "Failure text for %s must be Chinese" % reason)
	hub.show_transport_feedback({"success": false, "reason": "SOMETHING_NEW"})
	_check(hub.get_feedback_text() == "無法乘搭", "Unknown failures must show 無法乘搭")
	await _destroy(main)

	# Save failure through the button rolls back.
	main = await _new_main(UNWRITABLE_SAVE, T0)
	await _walk_in(main, "A")
	hub = main.get_node("CityHub") as CityHub
	hub.show_facility("transport")
	hub.get_transport_button("B").pressed.emit()
	_check(main.wallet.get_balance() == 10000 and main.current_city_id == "A" and not main.is_traveling(), "A failed save must roll the journey back")
	_check(hub.get_feedback_text() == "無法儲存，乘搭已取消", "A failed save must be explained in Chinese")
	_check(not FileAccess.file_exists(UNWRITABLE_SAVE), "The unwritable save must not exist")
	await _destroy(main)
	_sections_done.append("_verify_ui_failures")

## PR #77 blocker: an arrival whose save fails must not leave "arrived at
## runtime, still traveling on disk". Runtime and save must stay the same
## unfinished journey, and the journey must settle exactly once.
func _verify_arrival_save_failure() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE, T0)
	await _walk_in(main, "A")
	var arrivals := []
	main.journey_arrived.connect(func(journey_id: String, city_id: String) -> void: arrivals.append([journey_id, city_id]))
	_check(main.request_transport("B", "fragile")["success"], "Setup: A->B must start")
	var traveling_save := _read(TEST_SAVE)
	var goods: Dictionary = main.inventory.get_stacks()
	var market: Dictionary = main.market.get_snapshot()
	_check(_read_json()["location"]["mode"] == "TRAVELING", "Setup: the journey must be saved")

	# ETA reached while saving is broken.
	main.save_path = UNWRITABLE_SAVE
	main.time_source.set_now_ms(T0 + DURATION)
	await process_frame
	var hub := main.get_node("CityHub") as CityHub
	_check(main.is_traveling() and main.current_city_id == "" and main.location.get_journey()["journey_id"] == "fragile", "A failed arrival save must keep the runtime journey unfinished")
	_check(hub.get_facility() == "traveling" and hub.get_feedback_text() == "無法儲存，正在重試抵達" and hub.get_travel_texts()["remaining"] == "預計抵達：0 秒", "The traveling view must explain the retry in Chinese")
	_check(_movement_locked(main) and not main.leave_city() and main.buy_in_current_city("test_good_01", 1)["reason"] == "not_in_city", "Nothing city-side may happen before the arrival is saved")
	_check(arrivals.is_empty(), "A failed arrival save must produce no arrival side effect")
	_check(_read(TEST_SAVE) == traveling_save, "The persisted journey must be exactly the unfinished journey")
	_check(main.wallet.get_balance() == 10000 - FARE, "A failed arrival must not change money")
	_check(main.inventory.get_stacks() == goods and main.market.get_snapshot() == market, "A failed arrival must not change goods or market")
	# Retries are throttled while saving keeps failing, and stay consistent.
	main.time_source.advance_ms(200)
	await process_frame
	main.time_source.advance_ms(2000)
	await process_frame
	_check(main.is_traveling() and arrivals.is_empty() and _read(TEST_SAVE) == traveling_save, "Repeated failed retries must keep runtime and save consistent")

	# Reopen from the persisted state: the journey settles exactly once.
	await _destroy(main)
	arrivals.clear()
	main = await _new_main(TEST_SAVE, T0 + DURATION + 60000)
	_check(main.current_city_id == "B" and not main.is_traveling() and (main.get_node("CityHub") as CityHub).get_city_label_text() == "【B 城】", "Reopening must settle the saved journey into City B")
	_check(main.wallet.get_balance() == 10000 - FARE, "Settling on reopen must not charge again")
	var settled := _read_json()
	_check(settled["location"] == {"mode": "IN_CITY", "city_id": "B", "journey": null, "last_journey_id": "fragile"}, "The single settlement must be saved")
	_check(main.request_transport("A", "fragile")["reason"] == "ERR_DUPLICATE_REQUEST" and main.wallet.get_balance() == 10000 - FARE, "The settled journey's request must not start another journey")
	await _destroy(main)
	var settled_text := _read(TEST_SAVE)
	for repeat in range(3):
		main = await _new_main(TEST_SAVE, T0 + DURATION * (5 + repeat))
		main.journey_arrived.connect(func(journey_id: String, city_id: String) -> void: arrivals.append([journey_id, city_id]))
		await process_frame
		_check(main.current_city_id == "B" and not main.is_traveling() and main.wallet.get_balance() == 10000 - FARE, "Reopen #%d after settlement: no double settlement or charge" % repeat)
		_check(_read(TEST_SAVE) == settled_text, "Reopen #%d after settlement must not rewrite the save" % repeat)
		await _destroy(main)
	_check(arrivals.is_empty(), "No reopen after settlement may emit another arrival")

	# Recovery in the same session: once saving works again, arrive once.
	_delete(TEST_SAVE)
	main = await _new_main(TEST_SAVE, T0)
	await _walk_in(main, "B")
	arrivals.clear()
	main.journey_arrived.connect(func(journey_id: String, city_id: String) -> void: arrivals.append([journey_id, city_id]))
	_check(main.request_transport("A", "recover")["success"], "Setup: B->A must start")
	main.save_path = UNWRITABLE_SAVE
	main.time_source.set_now_ms(T0 + DURATION)
	await process_frame
	_check(main.is_traveling() and arrivals.is_empty(), "The first arrival save fails")
	main.save_path = TEST_SAVE
	await process_frame
	_check(main.is_traveling() and arrivals.is_empty(), "The retry waits for its retry time")
	main.time_source.advance_ms(main.ARRIVAL_RETRY_MS)
	await process_frame
	_check(main.current_city_id == "A" and arrivals == [["recover", "A"]], "Once saving works the journey arrives exactly once")
	_check(_read_json()["location"] == {"mode": "IN_CITY", "city_id": "A", "journey": null, "last_journey_id": "recover"} and int(_read_json()["money"]) == 10000 - FARE, "The recovered arrival must be saved with one fare charged")
	for extra in range(3):
		main.time_source.advance_ms(main.ARRIVAL_RETRY_MS)
		await process_frame
	_check(arrivals.size() == 1 and main.wallet.get_balance() == 10000 - FARE, "No further arrival or charge after recovery")
	_check((main.get_node("CityHub") as CityHub).get_feedback_text() == "", "The retry message must clear on arrival")
	await _destroy(main)
	_check(not FileAccess.file_exists(UNWRITABLE_SAVE), "The unwritable save must never exist")
	_delete(TEST_SAVE)
	_sections_done.append("_verify_arrival_save_failure")


# --- Stress -----------------------------------------------------------------------------------------

## Deterministic mix of rides, repeated presses, invalid requests, time jumps
## and full reopen cycles, checked against an independent model every step.
func _verify_stress() -> void:
	_delete(TEST_SAVE)
	var now := T0
	var main := await _new_main(TEST_SAVE, now)
	await _walk_in(main, "A")
	var goods_before: Dictionary = main.inventory.get_stacks()
	var market_before: Dictionary = main.market.get_snapshot()
	var model_money := 10000
	var model_city := "A"
	var model_eta := -1
	var model_destination := ""
	var last_request := ""
	var seed := 90909
	var counts := {"ride": 0, "duplicate": 0, "rejected": 0, "arrive": 0, "reopen": 0, "wait": 0}
	var drift := 0
	for step in range(STRESS_STEPS):
		seed = (seed * 1103515245 + 12345) % 2147483648
		var action := (seed >> 8) % 10
		if action <= 3:
			# Mostly the other active city, sometimes same, reserved or unknown.
			var choice := (seed >> 12) % 8
			var destination: String = ("A" if model_city == "B" else "B") if choice < 5 else ["A", "C", "Z"][choice - 5]
			var request := "s%d" % step
			var result: Dictionary = main.request_transport(destination, request)
			var expected := model_eta < 0 and model_city != "" and destination in ["A", "B"] and destination != model_city and model_money >= FARE
			if result["success"] != expected:
				drift += 1
			if result["success"]:
				model_money -= FARE
				model_eta = now + DURATION
				model_destination = destination
				model_city = ""
				last_request = request
				counts["ride"] += 1
			else:
				counts["rejected"] += 1
		elif action == 4 and last_request != "":
			if main.request_transport("A" if model_city == "B" else "B", last_request)["reason"] != "ERR_DUPLICATE_REQUEST":
				drift += 1
			counts["duplicate"] += 1
		elif action <= 7:
			now += [10000, 45000, 90000, 200000][(seed >> 14) % 4]
			main.time_source.set_now_ms(now)
			main.update_journey()
			counts["wait"] += 1
		else:
			await _destroy(main)
			main = await _new_main(TEST_SAVE, now)
			counts["reopen"] += 1
		if model_eta >= 0 and now >= model_eta:
			model_city = model_destination
			model_eta = -1
			counts["arrive"] += 1
		if main.wallet.get_balance() != model_money or main.current_city_id != model_city or main.is_traveling() != (model_eta >= 0):
			drift += 1
		if main.wallet.get_balance() < 0 or main.inventory.get_stacks() != goods_before or main.market.get_snapshot() != market_before:
			drift += 1
		var saved := _read_json()
		if int(saved.get("money", -1)) != model_money or saved.get("location", {}).get("mode") != ("TRAVELING" if model_eta >= 0 else "IN_CITY"):
			drift += 1
	_check(drift == 0, "Stress: runtime, save and model must always agree (%d drifts)" % drift)
	_check(counts["ride"] >= 15 and counts["duplicate"] >= 5 and counts["rejected"] >= 15 and counts["arrive"] >= 10 and counts["reopen"] >= 15, "Stress must mix rides, duplicates, rejections, arrivals and reopens %s" % str(counts))
	print("M2-09 stress counts: ", counts)
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("_verify_stress")


# --- Helpers ------------------------------------------------------------------------------------------

func _location_in(city: String) -> PlayerLocation:
	var location := PlayerLocation.new()
	location.enter_city(city)
	return location


func _wallet_with(balance: int) -> Wallet:
	var wallet := Wallet.new()
	if balance < wallet.get_balance():
		wallet.spend(wallet.get_balance() - balance)
	elif balance > wallet.get_balance():
		wallet.add(balance - wallet.get_balance())
	return wallet


func _with(data: Dictionary, changes: Dictionary) -> Dictionary:
	var copy := data.duplicate(true)
	copy.merge(changes, true)
	return copy


func _without(data: Dictionary, key: String) -> Dictionary:
	var copy := data.duplicate(true)
	copy.erase(key)
	return copy


func _goods_unchanged(main: Node, stacks: Dictionary, used: int, max_capacity: int) -> bool:
	return main.inventory.get_stacks() == stacks and main.inventory.get_used_capacity() == used and main.inventory.get_max_capacity() == max_capacity


func _movement_locked(main: Node) -> bool:
	var player := main.get_node("Actors/Player") as Player
	var joystick := main.get_node("TouchControls/Joystick") as TouchJoystick
	var enter_button := main.get_node("EnterControls/EnterCityButton") as Button
	return not player.is_physics_processing() and not joystick.is_processing_input() and not enter_button.visible


func _chinese(hub: CityHub) -> bool:
	var ok := true
	for control in hub.find_children("*", "Label", true, false) + hub.find_children("*", "Button", true, false):
		var text: String = (control as Control).get("text")
		if not _is_player_chinese(text):
			push_error("English player text: %s" % text)
			ok = false
	return ok


func _is_player_chinese(text: String) -> bool:
	return _latin.search(_approved.sub(text, "", true)) == null


## Source code without comment lines, for structural scans.
func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


func _new_main(path: String, now: int) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = path
	main.time_source = TimeSource.fixed(now)
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


func _write_json(data: Dictionary) -> void:
	var file := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()


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
