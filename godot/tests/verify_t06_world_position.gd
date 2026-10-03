extends SceneTree

## T06 World Exploration v0.1: the exact WORLD position is validated,
## persistent state. Uses its own save files and a fixed TimeSource.

const TEST_SAVE := "user://t06_world_position_test_save.json"
const T0 := 1800000000000
const DURATION := 90000
const SPAWN := Vector2(420.0, 500.0)
const RETURN_A := Vector2(540.0, 200.0)
const RETURN_B := Vector2(39460.0, 200.0)
const MIN := Vector2(16.0, 48.0)
const MAX := Vector2(39984.0, 40000.0)
## A position with a fractional part that a 32-bit float holds exactly.
const ODD := Vector2(12345.6787109375, 23456.7890625)

var _checks := 0
var _failures := 0
var _sections_done := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	_verify_location_rules()
	_verify_location_validation()
	_verify_save_and_migration()
	await _verify_refused_saves()
	await _verify_city_flows()
	await _verify_autosave()
	await _verify_travel()
	await _verify_stability()
	await _verify_stress()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 10, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("T06 world position verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(SaveStore.VERSION == 10 and SaveStore.V8_KEYS == SaveStore.V7_KEYS, "Save version 8: same sections, the location gains the world position (C05 made the current version 9)")
	_check(PlayerLocation.KEYS.has("world_position") and not PlayerLocation.LEGACY_KEYS.has("world_position"), "Current and legacy location shapes")
	_check(PlayerLocation.PLAYABLE_MIN == MIN and PlayerLocation.PLAYABLE_MAX == MAX, "Playable rect = the player's movement clamp (%s - %s)" % [PlayerLocation.PLAYABLE_MIN, PlayerLocation.PLAYABLE_MAX])
	_check(PlayerLocation.PLAYABLE_MIN == WorldBoundary.BOUNDS.position + Player.BOUNDARY_MIN_OFFSET and PlayerLocation.PLAYABLE_MAX == WorldBoundary.BOUNDS.end - Player.BOUNDARY_MAX_OFFSET, "Bounds come from the same constants the player uses")
	var scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_check(scene.contains("[node name=\"Player\" parent=\"Actors\"") and scene.contains("position = Vector2(420, 500)") and PlayerLocation.DEFAULT_WORLD_SPAWN == SPAWN, "Default world spawn = the approved scene spawn (420, 500)")
	_check(WorldLayout.CITY_RETURN_POINTS == {"A": RETURN_A, "B": RETURN_B}, "Approved return points unchanged")
	for city in WorldLayout.CITY_RETURN_POINTS:
		_check(PlayerLocation.is_valid_world_position(WorldLayout.CITY_RETURN_POINTS[city]), "Return point %s is a valid world position" % city)
	_check(PlayerLocation.is_valid_world_position(SPAWN), "The default spawn is valid")
	var save := _code_only("res://scripts/save_store.gd")
	_check(not save.contains("Vector2") and not save.contains("global_position"), "SaveStore never handles coordinates itself")
	var transport := _code_only("res://scripts/transport_service.gd")
	_check(not transport.contains("world_position") and not transport.contains("Vector2"), "TransportService is unchanged by T06")
	_check(_code_only("res://scripts/main.gd").contains("WORLD_AUTOSAVE_INTERVAL_MS := 5000"), "Approved autosave interval: 5 s")
	_sections_done.append("static")


# --- PlayerLocation rules --------------------------------------------------------------------

func _verify_location_rules() -> void:
	var location := PlayerLocation.new()
	_check(location.is_in_world() and location.get_world_position() == SPAWN, "A new character stands at the default spawn")
	_check(location.set_world_position(ODD) and location.get_world_position() == ODD, "An exact world position is kept")
	_check(location.set_world_position(MIN) and location.set_world_position(MAX), "The playable rect edges are valid")
	var bad := [Vector2(NAN, 500), Vector2(500, NAN), Vector2(INF, 500), Vector2(500, -INF), Vector2(15.999, 500), Vector2(500, 47.999), Vector2(39984.01, 500), Vector2(500, 40000.01), Vector2(-1, -1), Vector2(40000, 40000), "500,500", [500, 500], null, 500, Vector2i(500, 500)]
	location.set_world_position(ODD)
	for value in bad:
		_check(not location.set_world_position(value) and location.get_world_position() == ODD, "Invalid position %s refused, nothing changed" % str(value))
	_check(location.enter_city("A") and location.get_world_position() == null and location.to_dict()["world_position"] == null, "IN_CITY has no world position")
	_check(not location.set_world_position(ODD) and location.get_world_position() == null, "No world position can be set while IN_CITY")
	_check(location.leave_city() and location.get_world_position() == RETURN_A and location.get_city_id() == "A", "Leaving A places the player at A's return point")
	location.set_world_position(ODD)
	location.enter_city("A")
	var journey := {"journey_id": "j1", "status": "traveling", "origin_city_id": "A", "destination_city_id": "B", "started_at_ms": T0, "arrives_at_ms": T0 + DURATION, "fare": 300}
	_check(location.start_journey(journey) and location.get_world_position() == null and location.to_dict()["world_position"] == null, "TRAVELING has no world position")
	_check(not location.set_world_position(ODD), "No world position can be set while TRAVELING")
	_check(location.complete_journey() == "B" and location.is_in_city() and location.get_world_position() == null, "Arrival ends IN_CITY at the destination, no world position")
	_check(location.leave_city() and location.get_world_position() == RETURN_B, "Leaving the destination places the player at its return point")
	# Round trip of the current shape.
	location.set_world_position(ODD)
	var copy := PlayerLocation.from_dict(location.to_dict())
	_check(copy != null and copy.to_dict() == location.to_dict() and copy.get_world_position() == ODD, "to_dict / from_dict round-trips the exact position")
	var target := PlayerLocation.new()
	_check(target.restore(location.to_dict()) and target.get_world_position() == ODD, "restore() keeps the exact position")
	_sections_done.append("location_rules")


func _verify_location_validation() -> void:
	var world := {"mode": "WORLD", "city_id": "A", "journey": null, "last_journey_id": "", "world_position": {"x": 600.0, "y": 700.0}}
	var city := {"mode": "IN_CITY", "city_id": "B", "journey": null, "last_journey_id": "", "world_position": null}
	_check(PlayerLocation.from_dict(world) != null and PlayerLocation.from_dict(city) != null, "Valid v8 locations load")
	_check(PlayerLocation.from_dict(_merge(world, {"world_position": {"x": 600, "y": 700}})).get_world_position() == Vector2(600, 700), "Integer JSON coordinates are accepted")
	var bad := {
		"WORLD without position": _merge(world, {"world_position": null}),
		"missing world_position key": _without(world, "world_position"),
		"position not a dictionary": _merge(world, {"world_position": [600, 700]}),
		"position string": _merge(world, {"world_position": "600,700"}),
		"missing y": _merge(world, {"world_position": {"x": 600.0}}),
		"extra key": _merge(world, {"world_position": {"x": 600.0, "y": 700.0, "z": 0.0}}),
		"x string": _merge(world, {"world_position": {"x": "600", "y": 700.0}}),
		"y bool": _merge(world, {"world_position": {"x": 600.0, "y": true}}),
		"x null": _merge(world, {"world_position": {"x": null, "y": 700.0}}),
		"x NaN": _merge(world, {"world_position": {"x": NAN, "y": 700.0}}),
		"y infinity": _merge(world, {"world_position": {"x": 600.0, "y": INF}}),
		"x -infinity": _merge(world, {"world_position": {"x": -INF, "y": 700.0}}),
		"x below bounds": _merge(world, {"world_position": {"x": 15.5, "y": 700.0}}),
		"y below bounds": _merge(world, {"world_position": {"x": 600.0, "y": 47.5}}),
		"x above bounds": _merge(world, {"world_position": {"x": 39984.5, "y": 700.0}}),
		"y above bounds": _merge(world, {"world_position": {"x": 600.0, "y": 40000.5}}),
		"negative": _merge(world, {"world_position": {"x": -600.0, "y": -700.0}}),
		"huge": _merge(world, {"world_position": {"x": 1e300, "y": 700.0}}),
		"IN_CITY with position": _merge(city, {"world_position": {"x": 600.0, "y": 700.0}}),
		"legacy 4-key shape": _without(world, "world_position"),
	}
	var journey := {"journey_id": "j1", "status": "traveling", "origin_city_id": "A", "destination_city_id": "B", "started_at_ms": T0, "arrives_at_ms": T0 + DURATION, "fare": 300}
	bad["TRAVELING with position"] = {"mode": "TRAVELING", "city_id": "", "journey": journey, "last_journey_id": "j1", "world_position": {"x": 600.0, "y": 700.0}}
	for label in bad:
		_check(PlayerLocation.from_dict(bad[label]) == null, "v8 location rejected: %s" % label)
	_check(PlayerLocation.from_dict({"mode": "TRAVELING", "city_id": "", "journey": journey, "last_journey_id": "j1", "world_position": null}) != null, "TRAVELING with null position loads")
	# Legacy (v4-v7) migration rules.
	var legacy_world_a := {"mode": "WORLD", "city_id": "A", "journey": null, "last_journey_id": ""}
	_check(PlayerLocation.from_legacy_dict(legacy_world_a).get_world_position() == RETURN_A, "Legacy WORLD with city A -> A's return point")
	_check(PlayerLocation.from_legacy_dict(_merge(legacy_world_a, {"city_id": "B"})).get_world_position() == RETURN_B, "Legacy WORLD with city B -> B's return point")
	_check(PlayerLocation.from_legacy_dict(_merge(legacy_world_a, {"city_id": ""})).get_world_position() == SPAWN, "Legacy WORLD without a city -> default spawn")
	var legacy_city := PlayerLocation.from_legacy_dict({"mode": "IN_CITY", "city_id": "B", "journey": null, "last_journey_id": "x"})
	_check(legacy_city.is_in_city() and legacy_city.get_city_id() == "B" and legacy_city.get_world_position() == null and legacy_city.get_last_journey_id() == "x", "Legacy IN_CITY keeps its meaning")
	var legacy_travel := PlayerLocation.from_legacy_dict({"mode": "TRAVELING", "city_id": "", "journey": journey, "last_journey_id": "j1"})
	_check(legacy_travel.is_traveling() and legacy_travel.get_journey() == journey and legacy_travel.get_world_position() == null, "Legacy TRAVELING keeps its journey")
	_check(PlayerLocation.from_legacy_dict(world) == null, "The legacy path rejects the v8 shape")
	_check(PlayerLocation.from_legacy_dict(_merge(legacy_world_a, {"city_id": "C"})) == null, "Legacy validation still applies")
	_sections_done.append("location_validation")


# --- Save / migration --------------------------------------------------------------------------

func _verify_save_and_migration() -> void:
	var location := PlayerLocation.new()
	location.set_world_position(ODD)
	_check(SaveStore.save(TEST_SAVE, Wallet.new(), CharacterInventory.new(), MarketState.create_default(), location), "v8 save writes")
	var raw := _read_json()
	_check(int(raw["version"]) == 10 and raw["location"]["world_position"] == {"x": float(ODD.x), "y": float(ODD.y)}, "The exact position is saved (%s)" % str(raw["location"]))
	var loaded := SaveStore.load_session(TEST_SAVE)
	_check(not loaded.is_empty() and loaded["location"].get_world_position() == ODD, "Reload restores the exact position")
	for corner in [MIN, MAX, Vector2(MIN.x, MAX.y), Vector2(MAX.x, MIN.y), Vector2(0.5, 0.5) + MIN]:
		location.set_world_position(corner)
		SaveStore.save(TEST_SAVE, Wallet.new(), CharacterInventory.new(), MarketState.create_default(), location)
		_check(SaveStore.load_session(TEST_SAVE)["location"].get_world_position() == corner, "Round trip at %s" % str(corner))
	# Malformed coordinates in the save file reject the whole save.
	location.set_world_position(ODD)
	var good := SaveStore.serialize(Wallet.new(), CharacterInventory.new(), MarketState.create_default(), location)
	_check(not SaveStore.validate(good).is_empty(), "Reference v8 payload is valid")
	var cases := {"x NaN": {"x": NAN, "y": 700.0}, "y inf": {"x": 600.0, "y": INF}, "below": {"x": 0.0, "y": 0.0}, "above": {"x": 40000.0, "y": 40001.0}, "string": {"x": "600", "y": "700"}, "missing": {"x": 600.0}, "null": null}
	for label in cases:
		var payload := good.duplicate(true)
		payload["location"]["world_position"] = cases[label]
		_check(SaveStore.validate(payload).is_empty(), "Save with world position %s is rejected (not clamped)" % label)
	# Text-level corruption in the file itself.
	var plain := PlayerLocation.new()
	plain.set_world_position(Vector2(600, 700))
	var plain_text := JSON.stringify(SaveStore.serialize(Wallet.new(), CharacterInventory.new(), MarketState.create_default(), plain))
	_check(plain_text.contains('"x":600.0'), "Fixture text holds the x coordinate")
	_write_text(plain_text)
	_check(not SaveStore.load_session(TEST_SAVE).is_empty(), "The unmodified fixture file loads")
	for text in ['"x":NaN', '"x":1e999', '"x":-5.0', '"x":"12"', '"x":null', '"x":15.9']:
		_write_text(plain_text.replace('"x":600.0', text))
		_check(SaveStore.load_session(TEST_SAVE).is_empty(), "A save file with %s is rejected" % text)
	var v7_with := good.duplicate(true)
	v7_with["version"] = 7
	_check(SaveStore.validate(v7_with).is_empty(), "A v7 save cannot carry a v8 location")
	var v8_without := good.duplicate(true)
	v8_without["location"].erase("world_position")
	_check(SaveStore.validate(v8_without).is_empty(), "A v8 save without world_position is rejected")
	# Legacy saves migrate deterministically; loading never rewrites them.
	var market := MarketState.create_default().get_snapshot()
	var character := {"id": "player", "stats": {"strength": 10}, "inventory": {"items": {}}}
	var ledger := {"next_seq": 1, "backpack": {}, "warehouses": {"A": {}, "B": {}}}
	var stored := {"A": {"items": {}}, "B": {"items": {}}}
	var journey := {"journey_id": "j7", "status": "traveling", "origin_city_id": "B", "destination_city_id": "A", "started_at_ms": T0, "arrives_at_ms": T0 + DURATION, "fare": 300}
	var legacy_locations := {
		"WORLD A": [{"mode": "WORLD", "city_id": "A", "journey": null, "last_journey_id": ""}, RETURN_A],
		"WORLD B": [{"mode": "WORLD", "city_id": "B", "journey": null, "last_journey_id": "t"}, RETURN_B],
		"WORLD none": [{"mode": "WORLD", "city_id": "", "journey": null, "last_journey_id": ""}, SPAWN],
		"IN_CITY B": [{"mode": "IN_CITY", "city_id": "B", "journey": null, "last_journey_id": ""}, null],
		"TRAVELING": [{"mode": "TRAVELING", "city_id": "", "journey": journey, "last_journey_id": "j7"}, null],
	}
	for version in [4, 5, 6, 7]:
		for label in legacy_locations:
			var data := {"version": version, "money": 777, "character": character, "market": market, "location": legacy_locations[label][0]}
			if version >= 5:
				data["warehouses"] = stored
			if version >= 6:
				data["market_recovery"] = {"anchor_ms": T0}
			if version >= 7:
				data["cost_ledger"] = ledger
			_write_json(data)
			var text := _read(TEST_SAVE)
			var migrated := SaveStore.load_session(TEST_SAVE)
			_check(not migrated.is_empty() and migrated["wallet"].get_balance() == 777, "v%d %s loads" % [version, label])
			if migrated.is_empty():
				continue
			var loc: PlayerLocation = migrated["location"]
			_check(loc.get_mode() == legacy_locations[label][0]["mode"] and loc.get_city_id() == legacy_locations[label][0]["city_id"] and loc.get_world_position() == legacy_locations[label][1], "v%d %s migrates to %s" % [version, label, str(legacy_locations[label][1])])
			_check(label != "TRAVELING" or loc.get_journey() == journey, "v%d TRAVELING keeps its journey" % version)
			_check(_read(TEST_SAVE) == text, "v%d %s: loading does not rewrite the save" % [version, label])
	for version in [1, 2, 3]:
		var data := {"version": version, "money": 777, "cargo": {}} if version < 3 else {"version": 3, "money": 777, "character": character, "market": market}
		if version == 2:
			data["market"] = market
		_write_json(data)
		var migrated := SaveStore.load_session(TEST_SAVE)
		_check(not migrated.is_empty() and migrated["location"].is_in_world() and migrated["location"].get_world_position() == SPAWN, "v%d (no location) migrates to the default spawn" % version)
	_delete(TEST_SAVE)
	_sections_done.append("save_and_migration")


func _verify_refused_saves() -> void:
	var location := PlayerLocation.new()
	location.set_world_position(ODD)
	_check(SaveStore.save(TEST_SAVE, Wallet.new(), CharacterInventory.new(), MarketState.create_default(), location), "A valid save exists")
	var bytes := FileAccess.get_file_as_bytes(TEST_SAVE)
	for invalid in [Vector2(NAN, 500), Vector2(INF, 500), Vector2(5, 5), Vector2(50000, 500)]:
		var broken := PlayerLocation.new()
		broken._world_position = invalid  # bypasses the API on purpose
		_check(not SaveStore.save(TEST_SAVE, Wallet.new(), CharacterInventory.new(), MarketState.create_default(), broken), "An invalid location %s refuses the save" % str(invalid))
		_check(FileAccess.get_file_as_bytes(TEST_SAVE) == bytes and not FileAccess.file_exists(TEST_SAVE + ".tmp"), "Refused %s: the existing save is byte-for-byte unchanged" % str(invalid))
	# In the game: an out-of-bounds player position is never written.
	var main := await _new_main(TEST_SAVE, T0)
	var player := main.get_node("Actors/Player") as Player
	_check(main.get_world_position() == ODD, "The game starts at the saved exact position")
	player.global_position = Vector2(-300, -300)
	_check(not main.save_world_position() and FileAccess.get_file_as_bytes(TEST_SAVE) == bytes, "A game save with an out-of-bounds player is refused; the file is unchanged")
	_check(main.location.get_world_position() == ODD, "The location keeps its last valid position")
	player.global_position = Vector2(NAN, 900)
	_check(not main.save_world_position() and FileAccess.get_file_as_bytes(TEST_SAVE) == bytes, "A NaN player position is refused too")
	await _destroy(main)
	_check(SaveStore.load_session(TEST_SAVE)["location"].get_world_position() == ODD, "The untouched save still loads the last valid position")
	_delete(TEST_SAVE)
	_sections_done.append("refused_saves")


# --- Game flows --------------------------------------------------------------------------------

func _verify_city_flows() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var player := main.get_node("Actors/Player") as Player
	_check(main.location.is_in_world() and player.global_position == SPAWN and main.get_world_position() == SPAWN, "A new game starts at the default spawn")
	for city in ["A", "B"]:
		var ret: Vector2 = WorldLayout.CITY_RETURN_POINTS[city]
		await _walk_in(main, city)
		var saved := _read_json()
		_check(saved["location"]["mode"] == "IN_CITY" and saved["location"]["world_position"] == null, "Entering %s saves IN_CITY with no world position" % city)
		_check(main.leave_city() and player.global_position == ret and main.location.get_world_position() == ret, "Leaving %s places the player at its return point" % city)
		_check(_position_of(_read_json()) == ret, "Leaving %s saves the return point" % city)
		var moved := ret + Vector2(-123.5, 456.25) if city == "B" else ret + Vector2(123.5, 456.25)
		player.global_position = moved
		_check(main.save_world_position() and _position_of(_read_json()) == moved, "Moving away from %s and saving stores the moved position" % city)
		await _destroy(main)
		main = await _new_main(TEST_SAVE, T0)
		player = main.get_node("Actors/Player") as Player
		_check(main.location.is_in_world() and player.global_position == moved and main.get_world_position() == moved, "Reload after moving away from %s restores the moved position, not the return point" % city)
		_check(main.location.get_city_id() == city, "The last-city context is kept (%s)" % city)
	# Enter / leave cycles.
	for cycle in range(3):
		await _walk_in(main, "A")
		_check(main.leave_city() and player.global_position == RETURN_A, "Cycle %d: leave A -> return point" % cycle)
		player.global_position = RETURN_A + Vector2(10 * (cycle + 1), 5)
		main.save_world_position()
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0)
	_check(main.get_world_position() == RETURN_A + Vector2(30, 5), "After enter / leave cycles the last saved world position is restored")
	# Entering still uses the approved rule: only from inside the city trigger.
	(main.get_node("Actors/Player") as Player).global_position = Vector2(20000, 20000)
	await _settle()
	_check(not main.try_enter_city() and main.location.is_in_world(), "No city entry away from a city")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("city_flows")


func _verify_autosave() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var player := main.get_node("Actors/Player") as Player
	main.save_world_position()
	var bytes := FileAccess.get_file_as_bytes(TEST_SAVE)
	player.global_position = Vector2(3000, 4000)
	await process_frame
	_check(FileAccess.get_file_as_bytes(TEST_SAVE) == bytes, "No autosave before 5 s")
	main.time_source.advance_ms(4999)
	await process_frame
	_check(FileAccess.get_file_as_bytes(TEST_SAVE) == bytes, "No autosave at 4.999 s")
	main.time_source.advance_ms(1)
	await process_frame
	_check(_position_of(_read_json()) == Vector2(3000, 4000), "Autosave after 5 s stores the moved position")
	bytes = FileAccess.get_file_as_bytes(TEST_SAVE)
	main.time_source.advance_ms(60000)
	await process_frame
	_check(FileAccess.get_file_as_bytes(TEST_SAVE) == bytes, "Standing still never rewrites the save")
	player.global_position = Vector2(3100, 4100)
	main.time_source.advance_ms(1000)
	await process_frame
	_check(_position_of(_read_json()) == Vector2(3100, 4100), "The next move after a long pause saves again")
	player.global_position = Vector2(3200, 4200)
	main.time_source.advance_ms(1000)
	await process_frame
	_check(_position_of(_read_json()) == Vector2(3100, 4100), "At most one autosave per 5 s")
	# Going to the background / closing saves at once.
	main.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_check(_position_of(_read_json()) == Vector2(3200, 4200), "App pause saves the exact position immediately")
	player.global_position = Vector2(3300, 4300)
	main.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_check(_position_of(_read_json()) == Vector2(3300, 4300), "Close request saves the exact position")
	player.global_position = Vector2(3400, 4400)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(_position_of(_read_json()) == Vector2(3400, 4400), "Focus out saves the exact position")
	bytes = FileAccess.get_file_as_bytes(TEST_SAVE)
	main.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_check(FileAccess.get_file_as_bytes(TEST_SAVE) == bytes, "Pausing without moving writes nothing")
	# No world autosave while in a city.
	await _walk_in(main, "A")
	bytes = FileAccess.get_file_as_bytes(TEST_SAVE)
	main.time_source.advance_ms(20000)
	await process_frame
	main.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_check(FileAccess.get_file_as_bytes(TEST_SAVE) == bytes and _read_json()["location"]["world_position"] == null, "No world-position save while IN_CITY")
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0 + 20000)
	_check(main.location.is_in_city() and main.current_city_id == "A", "Reload keeps IN_CITY")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("autosave")


func _verify_travel() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	await _walk_in(main, "A")
	_check(main.request_transport("B", "t06-ride")["success"], "A -> B journey starts (fare paid)")
	var saved := _read_json()
	_check(saved["location"]["mode"] == "TRAVELING" and saved["location"]["world_position"] == null and main.location.get_world_position() == null and main.get_world_position() == null, "A journey has no fake world position")
	main.time_source.advance_ms(30000)
	await process_frame
	_check(_read_json()["location"]["world_position"] == null, "No world autosave while traveling")
	await _destroy(main)
	var text := _read(TEST_SAVE)
	main = await _new_main(TEST_SAVE, T0 + 45000)
	_check(main.is_traveling() and main.location.get_world_position() == null and _read(TEST_SAVE) == text, "Reload mid-journey: still traveling, no world position, save untouched")
	main.time_source.set_now_ms(T0 + DURATION)
	await process_frame
	_check(main.current_city_id == "B" and main.location.is_in_city() and _read_json()["location"]["world_position"] == null, "Arrival ends IN_CITY at B, no world position")
	var player := main.get_node("Actors/Player") as Player
	_check(main.leave_city() and player.global_position == RETURN_B and _position_of(_read_json()) == RETURN_B, "Leaving the destination places and saves B's return point")
	player.global_position = RETURN_B + Vector2(-200, 300)
	main.save_world_position()
	await _destroy(main)
	main = await _new_main(TEST_SAVE, T0 + DURATION)
	_check(main.get_world_position() == RETURN_B + Vector2(-200, 300), "After travel, reload restores the moved world position")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("travel")


func _verify_stability() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	(main.get_node("Actors/Player") as Player).global_position = ODD
	main.save_world_position()
	var text := _read(TEST_SAVE)
	await _destroy(main)
	# Same clock each time, so T04 market recovery (time-based) cannot change the bytes.
	for i in range(4):
		main = await _new_main(TEST_SAVE, T0)
		_check(main.get_world_position() == ODD and _read(TEST_SAVE) == text, "Reload #%d: exact position, save untouched" % i)
		_check(main.save_world_position() and _read(TEST_SAVE) == text, "Save #%d without moving writes identical bytes" % i)
		await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("stability")


# --- Stress ------------------------------------------------------------------------------------

func _verify_stress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 606
	var now := T0
	var main := await _new_main(TEST_SAVE, now)
	var counts := {"move": 0, "enter": 0, "leave": 0, "ride": 0, "arrive": 0, "reload": 0, "autosave": 0}
	var breaks := 0
	var expected_world: Variant = SPAWN
	for step in range(90):
		var player := main.get_node("Actors/Player") as Player
		var action := rng.randi_range(0, 5)
		if main.location.is_in_world():
			if action <= 1:
				var target := Vector2(rng.randf_range(MIN.x, MAX.x), rng.randf_range(MIN.y, MAX.y))
				player.global_position = target
				expected_world = player.global_position
				if action == 0:
					now += 5000
					main.time_source.set_now_ms(now)
					await process_frame
					counts["autosave"] += 1
				else:
					main.save_world_position()
				counts["move"] += 1
			elif action <= 3:
				var city: String = ["A", "B"][rng.randi_range(0, 1)]
				await _walk_in(main, city)
				expected_world = null
				counts["enter"] += 1
			else:
				counts["reload"] += 1
		elif main.location.is_in_city():
			if action <= 2:
				var city: String = main.current_city_id
				main.leave_city()
				expected_world = WorldLayout.CITY_RETURN_POINTS[city]
				counts["leave"] += 1
			elif action <= 4:
				var destination := "B" if main.current_city_id == "A" else "A"
				if main.request_transport(destination, "ride-%d" % step)["success"]:
					counts["ride"] += 1
				main.wallet.add(300)
			else:
				counts["reload"] += 1
		else:
			now += DURATION
			main.time_source.set_now_ms(now)
			await process_frame
			counts["arrive"] += 1
		# Invariants after every step.
		var saved := _read_json()
		var saved_location: Variant = PlayerLocation.from_dict(saved.get("location"))
		if saved_location == null or not SaveStore.validate(saved).size() > 0:
			breaks += 1
		if main.location.is_in_world() != (main.location.get_world_position() != null):
			breaks += 1
		if main.location.is_in_world() and main.location.get_world_position() != expected_world:
			breaks += 1
		if not main.location.is_in_world() and saved["location"]["world_position"] != null:
			breaks += 1
		if main.location.is_in_world() and saved_location != null and saved_location.get_world_position() != expected_world:
			breaks += 1
		# Reload every few steps and compare.
		if step % 6 == 5:
			var mode: String = main.location.get_mode()
			await _destroy(main)
			main = await _new_main(TEST_SAVE, now)
			if main.location.get_mode() != mode:
				breaks += 1
			if main.location.is_in_world() and ((main.get_node("Actors/Player") as Player).global_position != expected_world or main.get_world_position() != expected_world):
				breaks += 1
			counts["reload"] += 1
	await _destroy(main)
	_check(breaks == 0, "Stress: saved / runtime world position and mode stay consistent through WORLD / IN_CITY / TRAVELING transitions and reloads (%d breaks)" % breaks)
	_check(counts["move"] >= 10 and counts["enter"] >= 10 and counts["leave"] >= 8 and counts["ride"] >= 3 and counts["arrive"] >= 3 and counts["reload"] >= 15, "Stress mixes every transition %s" % str(counts))
	print("T06 stress counts: ", counts)
	_delete(TEST_SAVE)
	_sections_done.append("stress")


# --- Helpers ------------------------------------------------------------------------------------

func _position_of(saved: Dictionary) -> Variant:
	var data: Variant = saved.get("location", {}).get("world_position")
	return Vector2(data["x"], data["y"]) if typeof(data) == TYPE_DICTIONARY else null


func _merge(base: Dictionary, extra: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	result.merge(extra, true)
	return result


func _without(base: Dictionary, key: String) -> Dictionary:
	var result := base.duplicate(true)
	result.erase(key)
	return result


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


func _walk_in(main: Node, city: String) -> void:
	var player := main.get_node("Actors/Player") as Player
	player.global_position = WorldLayout.CITY_ANCHORS[city]
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == city, "Must enter City %s" % city)


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


func _read_json() -> Dictionary:
	var parsed: Variant = JSON.parse_string(_read(TEST_SAVE))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _write_json(data: Variant) -> void:
	_write_text(JSON.stringify(data))


func _write_text(text: String) -> void:
	var file := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _delete(path: String) -> void:
	for p in [path, path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _settle() -> void:
	for frame in range(4):
		await physics_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
