extends SceneTree

const FixedCapacityStats := preload("res://tests/fixed_capacity_stats.gd")

## T01 City Warehouse Foundation.
## Uses its own save files so the player's real save is never touched, and a
## fixed TimeSource so journeys are deterministic.

const TEST_SAVE := "user://t01_warehouse_test_save.json"
const UNWRITABLE_SAVE := "user://t01_missing_dir/nested/save.json"
const T0 := 1800000000000
const CAPACITY := 200
const IDS := ["test_good_01", "test_good_02", "test_good_03", "test_good_04", "test_good_05", "test_good_06"]
const COSTS := {"test_good_01": 1, "test_good_02": 1, "test_good_03": 2, "test_good_04": 2, "test_good_05": 3, "test_good_06": 4}
const STRESS_STEPS := 400

var _checks := 0
var _failures := 0
var _sections_done := []
var _approved := RegEx.new()
var _latin := RegEx.new()


func _initialize() -> void:
	_latin.compile("[A-Za-z]")
	_approved.compile("(?<![A-Za-z])[ABE](?![A-Za-z])")
	_delete(TEST_SAVE)
	_verify_static()
	_verify_defaults()
	_verify_deposit_withdraw()
	_verify_city_independence()
	_verify_failures_change_nothing()
	_verify_capacity()
	_verify_city_rules()
	_verify_duplicates_and_save_failure()
	_verify_overflow_and_over_capacity()
	_verify_save_versions()
	await _verify_game_flow()
	await _verify_ui_save_failure()
	_verify_stress()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 13, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("T01 city warehouse verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Structure ---------------------------------------------------------------------------

func _verify_static() -> void:
	var service := _code_only("res://scripts/warehouse_service.gd")
	for forbidden in ["Wallet", "wallet", "MarketState", "market", "TradeService", "TransportService", "journey", "capacity_cost"]:
		_check(not service.contains(forbidden), "WarehouseService must not reference %s" % forbidden)
	var trade := _code_only("res://scripts/trade_service.gd")
	_check(not trade.to_lower().contains("warehouse"), "Market trades must never use a warehouse")
	var inventory := _code_only("res://scripts/character_inventory.gd")
	_check(not inventory.to_lower().contains("warehouse"), "CharacterInventory must not gain a warehouse mode")
	var warehouse := _code_only("res://scripts/city_warehouse.gd")
	_check(not warehouse.contains("extends CharacterInventory") and warehouse.contains("GoodsCatalog.get_capacity_cost"), "The warehouse is its own container using the authoritative item cost")
	var hub := _code_only("res://scripts/city_hub.gd")
	_check(not hub.contains("WarehouseService") and not hub.contains("WarehouseState") and not hub.contains("restore_items"), "The UI must not change warehouse state directly")
	_check(FileAccess.get_file_as_string("res://scripts/warehouse_state.gd").contains("PROTOTYPE PARAMETER"), "Warehouse capacity must be marked as a prototype parameter")
	_check(SaveStore.VERSION == 13, "Save version must be 9 (5 for warehouses, T04 added market recovery, T05 the cost ledger, T06 the exact world position, C05 progression)")
	_sections_done.append("static")


func _verify_defaults() -> void:
	var state := WarehouseState.create_default()
	_check(state.get_city_ids() == ["A", "B"], "Exactly one warehouse per active city")
	for city in ["A", "B"]:
		_check(state.get_contents(city).is_empty() and state.get_used_capacity(city) == 0 and state.get_max_capacity(city) == CAPACITY and state.get_remaining_capacity(city) == CAPACITY, "City %s warehouse starts empty with the prototype capacity" % city)
	for city in ["C", "D", "Z", "", 5, null]:
		_check(not state.has_city(city) and state.get_contents(city).is_empty() and state.get_max_capacity(city) == 0, "No warehouse for %s" % str(city))
	var copy := state.get_contents("A")
	copy["test_good_01"] = 5
	_check(state.get_contents("A").is_empty(), "Read access must return copies")
	_sections_done.append("defaults")


# --- Transfers -----------------------------------------------------------------------------

func _verify_deposit_withdraw() -> void:
	var s := _session("A", {"test_good_01": 7, "test_good_03": 2})
	var total_before := _total(s, "test_good_01")
	var result := _deposit(s, "A", "test_good_01", 4)
	_check(result["success"] and result["quantity"] == 4, "Deposit 4 must succeed")
	_check(s.inventory.get_quantity("test_good_01") == 3 and s.warehouses.get_quantity("A", "test_good_01") == 4, "Deposit must remove exactly 4 carried and add exactly 4 stored")
	_check(_total(s, "test_good_01") == total_before, "Deposit must conserve the total")
	result = _withdraw(s, "A", "test_good_01", 3)
	_check(result["success"] and s.inventory.get_quantity("test_good_01") == 6 and s.warehouses.get_quantity("A", "test_good_01") == 1, "Withdraw must move exactly 3 back")
	_check(_total(s, "test_good_01") == total_before, "Withdraw must conserve the total")
	_check(_deposit(s, "A", "test_good_03", 2)["success"] and not s.inventory.get_items().has("test_good_03") and s.warehouses.get_quantity("A", "test_good_03") == 2, "Depositing everything must empty the stack")
	_check(s.warehouses.get_used_capacity("A") == 1 * 1 + 2 * 2 and s.warehouses.get_remaining_capacity("A") == CAPACITY - 5, "Warehouse capacity must use the authoritative item costs")
	_check(_withdraw(s, "A", "test_good_01", 1)["success"] and not s.warehouses.get_contents("A").has("test_good_01"), "Withdrawing everything must remove the stored entry")
	_check(s.inventory.get_used_capacity() == 7 and s.inventory.get_max_capacity() == 20, "Inventory capacity must follow its own existing rules")
	_check(_unchanged_elsewhere(s), "Wallet, market and location must never change during warehouse transfers")
	_sections_done.append("deposit_withdraw")


func _verify_city_independence() -> void:
	var s := _session("A", {"test_good_02": 5})
	_deposit(s, "A", "test_good_02", 3)
	_check(s.warehouses.get_quantity("A", "test_good_02") == 3 and s.warehouses.get_contents("B").is_empty(), "A deposit must not leak into B")
	s.location.leave_city()
	s.location.enter_city("B")
	var in_b := _withdraw(s, "B", "test_good_02", 1)
	_check(not in_b["success"] and in_b["reason"] == "ERR_INSUFFICIENT_STORED", "City A goods must not be available from City B")
	_check(_deposit(s, "B", "test_good_02", 2)["success"] and s.warehouses.get_quantity("B", "test_good_02") == 2 and s.warehouses.get_quantity("A", "test_good_02") == 3, "B has its own warehouse and A is unchanged")
	_check(s.warehouses.get_used_capacity("A") == 3 and s.warehouses.get_used_capacity("B") == 2, "Capacity is per city")
	s.location.leave_city()
	s.location.enter_city("A")
	_check(_withdraw(s, "A", "test_good_02", 3)["success"] and s.inventory.get_quantity("test_good_02") == 3 and s.warehouses.get_quantity("B", "test_good_02") == 2, "Back in A, the A goods can be withdrawn and B is unchanged")
	_sections_done.append("independence")


func _verify_failures_change_nothing() -> void:
	var cases := [
		["deposit", "test_good_01", 0, "ERR_INVALID_QUANTITY"],
		["deposit", "test_good_01", -3, "ERR_INVALID_QUANTITY"],
		["deposit", "test_good_01", 1.5, "ERR_INVALID_QUANTITY"],
		["deposit", "test_good_01", "2", "ERR_INVALID_QUANTITY"],
		["deposit", "test_good_01", null, "ERR_INVALID_QUANTITY"],
		["withdraw", "test_good_01", 0, "ERR_INVALID_QUANTITY"],
		["withdraw", "test_good_01", -1, "ERR_INVALID_QUANTITY"],
		["deposit", "test_good_07", 1, "ERR_UNKNOWN_ITEM"],
		["deposit", "", 1, "ERR_UNKNOWN_ITEM"],
		["withdraw", 42, 1, "ERR_UNKNOWN_ITEM"],
		["deposit", "test_good_01", 6, "ERR_INSUFFICIENT_CARRIED"],
		["deposit", "test_good_04", 1, "ERR_INSUFFICIENT_CARRIED"],
		["withdraw", "test_good_02", 3, "ERR_INSUFFICIENT_STORED"],
		["withdraw", "test_good_05", 1, "ERR_INSUFFICIENT_STORED"],
	]
	for case in cases:
		var s := _session("A", {"test_good_01": 5})
		_deposit(s, "A", "test_good_02", 0)
		s.warehouses._warehouse("A").restore_items({"test_good_02": 2})
		var before := _snapshot(s)
		var result := _deposit(s, "A", case[1], case[2]) if case[0] == "deposit" else _withdraw(s, "A", case[1], case[2])
		_check(not result["success"] and result["reason"] == case[3], "%s %s x %s must fail with %s (got %s)" % [case[0], str(case[1]), str(case[2]), case[3], result["reason"]])
		_check(_snapshot(s) == before, "Failed %s (%s) must change neither side" % [case[0], case[3]])
	_sections_done.append("failures")


func _verify_capacity() -> void:
	# Warehouse capacity: 50 x cost-4 goods fill 200 exactly.
	var s := _session("A", {"test_good_06": 60})
	_check(s.inventory.is_over_capacity(), "Setup: an over-capacity inventory")
	var too_many := _deposit(s, "A", "test_good_06", 51)
	_check(not too_many["success"] and too_many["reason"] == "ERR_WAREHOUSE_CAPACITY" and s.inventory.get_quantity("test_good_06") == 60, "Depositing past warehouse capacity must fail atomically")
	_check(_deposit(s, "A", "test_good_06", 50)["success"] and s.warehouses.get_used_capacity("A") == CAPACITY and s.warehouses.get_remaining_capacity("A") == 0, "An over-capacity inventory may still deposit, up to the exact capacity")
	var before := _snapshot(s)
	var full := _deposit(s, "A", "test_good_06", 1)
	_check(not full["success"] and full["reason"] == "ERR_WAREHOUSE_CAPACITY" and _snapshot(s) == before, "A full warehouse must reject deposits")

	# Carrying capacity on withdraw: 19 / 20 carried.
	var c := _session("A", {"test_good_01": 19})
	c.warehouses._warehouse("A").restore_items({"test_good_03": 2, "test_good_01": 3})
	before = _snapshot(c)
	var heavy := _withdraw(c, "A", "test_good_03", 1)
	_check(not heavy["success"] and heavy["reason"] == "ERR_CARRY_CAPACITY" and _snapshot(c) == before, "Withdraw must respect carrying capacity (cost 2 into 1 free)")
	_check(_withdraw(c, "A", "test_good_01", 1)["success"] and c.inventory.get_used_capacity() == 20, "A cost-1 withdraw fits exactly")
	var over := _withdraw(c, "A", "test_good_01", 1)
	_check(not over["success"] and over["reason"] == "ERR_CARRY_CAPACITY", "A full inventory must reject withdraws")

	# Over-capacity inventory accepts nothing (existing M2-08 rule).
	var o := _session("A", {"test_good_05": 8})
	o.warehouses._warehouse("A").restore_items({"test_good_01": 1})
	_check(o.inventory.is_over_capacity(), "Setup: over capacity")
	before = _snapshot(o)
	var blocked := _withdraw(o, "A", "test_good_01", 1)
	_check(not blocked["success"] and blocked["reason"] == "ERR_CARRY_CAPACITY" and _snapshot(o) == before, "An over-capacity inventory must reject withdraws")
	_check(_deposit(o, "A", "test_good_05", 2)["success"] and not o.inventory.is_over_capacity(), "Depositing lets an over-capacity character return to legal capacity")
	_sections_done.append("capacity")


func _verify_city_rules() -> void:
	var s := _session("A", {"test_good_01": 5})
	s.warehouses._warehouse("B").restore_items({"test_good_01": 4})
	var before := _snapshot(s)
	for target in ["B", "C", "D", "", "a", 5, null]:
		var d := _deposit(s, target, "test_good_01", 1)
		var w := _withdraw(s, target, "test_good_01", 1)
		_check(not d["success"] and d["reason"] == "ERR_WRONG_CITY" and not w["success"] and w["reason"] == "ERR_WRONG_CITY", "Remote/invalid city %s must be rejected" % str(target))
	_check(_snapshot(s) == before, "Remote attempts must change nothing, including City B's warehouse")
	s.location.leave_city()
	before = _snapshot(s)
	for target in ["A", "B"]:
		_check(_deposit(s, target, "test_good_01", 1)["reason"] == "ERR_NOT_IN_CITY" and _withdraw(s, target, "test_good_01", 1)["reason"] == "ERR_NOT_IN_CITY", "Outside a city nothing may move (%s)" % target)
	_check(_snapshot(s) == before, "World-state attempts must change nothing")
	var traveling := _session("A", {"test_good_01": 5})
	var wallet := Wallet.new()
	TransportService.begin_journey(traveling.location, wallet, "B", "trip", T0)
	var journey := traveling.location.get_journey()
	before = _snapshot(traveling)
	_check(_deposit(traveling, "A", "test_good_01", 1)["reason"] == "ERR_NOT_IN_CITY" and _withdraw(traveling, "B", "test_good_01", 1)["reason"] == "ERR_NOT_IN_CITY", "Traveling characters cannot use any warehouse")
	_check(_snapshot(traveling) == before and traveling.location.get_journey() == journey and wallet.get_balance() == 10000 - 300, "Journey and wallet must be untouched by warehouse attempts")
	_check(WarehouseService.deposit(null, s.inventory, s.warehouses, "A", "test_good_01", 1)["reason"] == "ERR_INVALID_STATE", "Missing state must be rejected")
	_sections_done.append("city_rules")


func _verify_duplicates_and_save_failure() -> void:
	var s := _session("A", {"test_good_01": 5})
	_check(_deposit(s, "A", "test_good_01", 1, "tap-1")["success"], "First request succeeds")
	var again := _deposit(s, "A", "test_good_01", 1, "tap-1")
	_check(not again["success"] and again["reason"] == "ERR_DUPLICATE_REQUEST" and s.inventory.get_quantity("test_good_01") == 4 and s.warehouses.get_quantity("A", "test_good_01") == 1, "The same request delivered twice applies once")
	_check(_withdraw(s, "A", "test_good_01", 1, "tap-1")["reason"] == "ERR_DUPLICATE_REQUEST", "A used request id cannot be reused for a withdraw")
	_check(_deposit(s, "A", "test_good_01", 1, "tap-2")["success"] and _deposit(s, "A", "test_good_01", 1)["success"] and _deposit(s, "A", "test_good_01", 1)["success"], "New ids and id-less calls are separate operations")
	_check(s.warehouses.get_quantity("A", "test_good_01") == 4, "Four separate deposits stored four units")

	var f := _session("A", {"test_good_01": 5})
	var before := _snapshot(f)
	var seen := []
	var failing := func() -> bool:
		seen.append([f.inventory.get_quantity("test_good_01"), f.warehouses.get_quantity("A", "test_good_01")])
		return false
	var d := WarehouseService.deposit(f.location, f.inventory, f.warehouses, "A", "test_good_01", 2, "save-1", failing)
	_check(not d["success"] and d["reason"] == "ERR_SAVE_FAILED" and seen == [[3, 2]] and _snapshot(f) == before, "A failed save must roll the deposit back on both sides")
	_check(f.warehouses.last_request_id != "save-1", "A rolled-back request id must not be consumed")
	f.warehouses._warehouse("A").restore_items({"test_good_01": 2})
	before = _snapshot(f)
	var w := WarehouseService.withdraw(f.location, f.inventory, f.warehouses, "A", "test_good_01", 2, "save-2", func() -> bool: return false)
	_check(not w["success"] and w["reason"] == "ERR_SAVE_FAILED" and _snapshot(f) == before, "A failed save must roll the withdraw back on both sides")
	_check(WarehouseService.withdraw(f.location, f.inventory, f.warehouses, "A", "test_good_01", 2, "save-2", func() -> bool: return true)["success"], "The same request may be retried after a rolled-back failure")
	_sections_done.append("duplicates_save_failure")


func _verify_overflow_and_over_capacity() -> void:
	var s := _session("A", {"test_good_01": 3})
	var huge := 4611686018427387904
	_check(_deposit(s, "A", "test_good_01", huge)["reason"] == "ERR_INSUFFICIENT_CARRIED" and _withdraw(s, "A", "test_good_01", huge)["reason"] == "ERR_INSUFFICIENT_STORED", "Huge quantities must be rejected safely")
	var big := CityWarehouse.new("A", 9223372036854775807)
	_check(big.restore_items({"test_good_01": CityWarehouse.MAX_ITEM_QUANTITY}) and not big.can_add("test_good_01", 1) and not big.add("test_good_01", 1), "A stack at the quantity limit cannot grow")
	_check(not big.restore_items({"test_good_01": CityWarehouse.MAX_ITEM_QUANTITY + 1}) and not big.restore_items({"test_good_01": huge}), "Stored quantities above the limit must be rejected")
	# Over-capacity warehouse (capacity lowered after items were stored).
	var small := CityWarehouse.new("A", 10)
	_check(small.restore_items({"test_good_06": 5}) and small.is_over_capacity() and small.get_used_capacity() == 20, "A valid over-capacity warehouse keeps its items")
	_check(not small.can_add("test_good_01", 1) and small.can_remove("test_good_06", 5), "An over-capacity warehouse rejects deposits but allows withdraws")
	_check(small.get_remaining_capacity() == 0, "Remaining capacity never goes negative")
	_sections_done.append("overflow")


# --- Save ----------------------------------------------------------------------------------------

func _verify_save_versions() -> void:
	var market := MarketState.create_default().get_snapshot()
	var character := {"id": "player", "stats": {"strength": 10}, "inventory": {"items": {"test_good_02": {"quantity": 3}}}}
	var location := {"mode": "IN_CITY", "city_id": "A", "journey": null, "last_journey_id": ""}
	var legacy := {
		"v1": {"version": 1, "money": 7777, "cargo": {"test_good_02": 3}},
		"v2": {"version": 2, "money": 7777, "cargo": {"test_good_02": 3}, "market": market},
		"v3": {"version": 3, "money": 7777, "character": character, "market": market},
		"v4": {"version": 4, "money": 7777, "character": character, "market": market, "location": location},
	}
	for label in legacy:
		_write_json(legacy[label])
		var text := _read(TEST_SAVE)
		var loaded := SaveStore.load_session(TEST_SAVE)
		var state: WarehouseState = loaded.get("warehouses")
		_check(not loaded.is_empty() and loaded["wallet"].get_balance() == 7777 and loaded["inventory"].get_quantity("test_good_02") == 3, "%s save must still load" % label)
		_check(state != null and state.get_snapshot() == {"A": {"items": {}}, "B": {"items": {}}} and state.get_max_capacity("A") == CAPACITY, "%s save must get valid empty warehouses" % label)
		_check(_read(TEST_SAVE) == text, "Loading a %s save must not rewrite it" % label)

	# Current-version (v6) round trip.
	var warehouses := WarehouseState.create_default()
	warehouses._warehouse("A").restore_items({"test_good_01": 4, "test_good_06": 2})
	warehouses._warehouse("B").restore_items({"test_good_03": 7})
	_check(SaveStore.save(TEST_SAVE, Wallet.new(), CharacterInventory.new(), MarketState.create_default(), PlayerLocation.from_legacy_dict(location), warehouses), "v5 save must write")
	var raw := _read_json()
	_check(int(raw["version"]) == 13 and raw.keys().size() == 13 and raw.has("market_recovery") and raw.has("cost_ledger") and raw.has("progression") and raw["warehouses"].keys().size() == 2, "The current (v8) save must hold the warehouses")
	_check(not JSON.stringify(raw["warehouses"]).contains("capacity"), "Warehouse capacity (balance data) must not be saved")
	var loaded := SaveStore.load_session(TEST_SAVE)
	_check(not loaded.is_empty() and loaded["warehouses"].get_snapshot() == warehouses.get_snapshot(), "Reload must restore each city's warehouse exactly")
	_check(loaded["warehouses"].get_quantity("A", "test_good_06") == 2 and loaded["warehouses"].get_quantity("B", "test_good_03") == 7 and loaded["warehouses"].get_used_capacity("B") == 14, "Reloaded quantities and capacity must match")

	# A valid over-capacity warehouse (capacity lowered later) loads without losing items.
	var v5 := raw.duplicate(true)
	v5["warehouses"]["A"]["items"] = {"test_good_06": 60}
	# T05: a v7 save's cost lots must account for the stored units exactly.
	# (seq 2 is the migrated unknown lot of A's test_good_06: backpack, then A in catalog order.)
	v5["cost_ledger"]["warehouses"]["A"] = {"test_good_06": [{"seq": 2, "quantity": 60, "unknown": true}]}
	_write_json(v5)
	var over := SaveStore.load_session(TEST_SAVE)
	_check(not over.is_empty() and over["warehouses"].get_quantity("A", "test_good_06") == 60 and over["warehouses"].get_used_capacity("A") > over["warehouses"].get_max_capacity("A"), "An over-capacity warehouse save keeps its items")

	# Malformed warehouse data rejects the whole save (existing convention).
	var broken := {
		"missing warehouses": _without(v5, "warehouses"),
		"null warehouses": _with(v5, {"warehouses": null}),
		"array warehouses": _with(v5, {"warehouses": [1, 2]}),
		"missing city B": _with(v5, {"warehouses": {"A": {"items": {}}}}),
		"extra city C": _with(v5, {"warehouses": {"A": {"items": {}}, "B": {"items": {}}, "C": {"items": {}}}}),
		"city not dict": _with(v5, {"warehouses": {"A": [], "B": {"items": {}}}}),
		"missing items": _with(v5, {"warehouses": {"A": {}, "B": {"items": {}}}}),
		"extra city field": _with(v5, {"warehouses": {"A": {"items": {}, "capacity": 999}, "B": {"items": {}}}}),
		"items not dict": _with(v5, {"warehouses": {"A": {"items": [1]}, "B": {"items": {}}}}),
		"unknown good": _with(v5, {"warehouses": {"A": {"items": {"test_good_07": 1}}, "B": {"items": {}}}}),
		"zero quantity": _with(v5, {"warehouses": {"A": {"items": {"test_good_01": 0}}, "B": {"items": {}}}}),
		"negative quantity": _with(v5, {"warehouses": {"A": {"items": {"test_good_01": -2}}, "B": {"items": {}}}}),
		"fractional quantity": _with(v5, {"warehouses": {"A": {"items": {"test_good_01": 1.5}}, "B": {"items": {}}}}),
		"string quantity": _with(v5, {"warehouses": {"A": {"items": {"test_good_01": "3"}}, "B": {"items": {}}}}),
		"huge quantity": _with(v5, {"warehouses": {"A": {"items": {"test_good_01": 1e15}}, "B": {"items": {}}}}),
		"v4 with warehouses": _with(legacy["v4"], {"warehouses": {"A": {"items": {}}, "B": {"items": {}}}}),
		# S05: v10 is the current version now; the unknown future one is 11.
		"v14": _with(v5, {"version": 14}),  # Stage 9 P01: v13 is current
	}
	for label in broken:
		_write_json(broken[label])
		var text := _read(TEST_SAVE)
		_check(SaveStore.load_session(TEST_SAVE).is_empty(), "Malformed save (%s) must be rejected as a whole" % label)
		_check(_read(TEST_SAVE) == text, "Malformed save (%s) must not be overwritten on load" % label)
	_delete(TEST_SAVE)
	_sections_done.append("save_versions")


# --- In-game flow --------------------------------------------------------------------------------

func _verify_game_flow() -> void:
	_delete(TEST_SAVE)
	var main := await _new_main(TEST_SAVE)
	await _walk_in(main, "A")
	var hub := main.get_node("CityHub") as CityHub
	for press in range(5):
		hub.get_market_button("test_good_01", "buy").pressed.emit()
	hub.get_market_button("test_good_03", "buy").pressed.emit()
	var money: int = main.wallet.get_balance()
	var market: Dictionary = main.market.get_snapshot()
	var location: Dictionary = main.location.to_dict()

	# Scenario A: deposit part of the goods.
	hub.show_facility("warehouse")
	await process_frame
	_check(hub.get_facility() == "warehouse" and hub.get_warehouse_button("test_good_01", "deposit").is_visible_in_tree() and not hub.get_market_button("test_good_01", "buy").is_visible_in_tree(), "The warehouse is its own facility view")
	_check(hub.get_warehouse_summary_text() == "背包容量：7 / 100　倉庫容量：0 / 200", "Warehouse view must show both capacities (%s)" % hub.get_warehouse_summary_text())
	_check(hub.get_warehouse_row_texts("test_good_01") == {"name": "測試商品一", "carried": "背包：5", "stored": "倉庫：0"}, "Rows must show carried and stored counts")
	_check(hub.get_warehouse_button("test_good_01", "deposit").text == "存入 1" and hub.get_warehouse_button("test_good_01", "withdraw").text == "取出 1", "Buttons must read 存入 1 / 取出 1")
	for press in range(3):
		hub.get_warehouse_button("test_good_01", "deposit").pressed.emit()
	_check(main.inventory.get_quantity("test_good_01") == 2 and main.warehouses.get_quantity("A", "test_good_01") == 3, "Three presses must deposit three")
	_check(hub.get_warehouse_row_texts("test_good_01") == {"name": "測試商品一", "carried": "背包：2", "stored": "倉庫：3"} and hub.get_feedback_text() == "已存入 1 件測試商品一", "UI must refresh after deposits")
	_check(hub.get_warehouse_summary_text() == "背包容量：4 / 100　倉庫容量：3 / 200", "Capacities must refresh")
	_check(_read_json()["warehouses"]["A"]["items"].has("test_good_01") and int(_read_json()["warehouses"]["A"]["items"]["test_good_01"]) == 3, "A successful deposit must be saved")
	_check(main.wallet.get_balance() == money and main.market.get_snapshot() == market and main.location.to_dict() == location, "Warehouse use must not change wallet, market or location")
	var id: String = hub.get_warehouse_request_id()
	_check(main.deposit_to_warehouse("test_good_01", 1, id)["success"] and main.deposit_to_warehouse("test_good_01", 1, id)["reason"] == "ERR_DUPLICATE_REQUEST", "A repeated delivery of one press must apply once")
	hub.show_facility("market")
	hub.show_facility("warehouse")
	_check(hub.get_warehouse_request_id() != id, "Showing the warehouse again issues a fresh request id")
	hub.get_warehouse_button("test_good_02", "withdraw").pressed.emit()
	_check(hub.get_feedback_text() == "數量不足", "Failure feedback must be Chinese")
	_check(_chinese(hub), "Warehouse text must be Traditional Chinese")
	_check(_layout_ok(main), "Warehouse view must fit the portrait layout without covering Enter City")

	# Market still only uses the inventory.
	hub.show_facility("market")
	_check(main.inventory.get_quantity("test_good_01") == 1 and main.sell_in_current_city("test_good_01", 1)["success"] and main.inventory.get_quantity("test_good_01") == 0, "Selling uses carried goods only")
	var stored_only: Dictionary = main.sell_in_current_city("test_good_01", 1)
	_check(not stored_only["success"] and stored_only["reason"] == "insufficient_cargo" and main.warehouses.get_quantity("A", "test_good_01") == 4, "Goods in the warehouse cannot be sold directly")
	_check(main.buy_in_current_city("test_good_02", 1)["success"] and main.inventory.get_quantity("test_good_02") == 1 and main.warehouses.get_quantity("A", "test_good_02") == 0, "Purchases go into the inventory, never the warehouse")

	# Leave and reopen the warehouse facility.
	hub.show_facility("warehouse")
	_check(hub.get_warehouse_row_texts("test_good_01")["stored"] == "倉庫：4", "Reopening the warehouse shows the same state")

	# Scenario B: City B does not have City A's goods.
	main.leave_city()
	_check(main.deposit_to_warehouse("test_good_02", 1)["reason"] == "ERR_NOT_IN_CITY", "Outside a city nothing may move")
	await _walk_in(main, "B")
	hub.show_facility("warehouse")
	_check(hub.get_warehouse_row_texts("test_good_01")["stored"] == "倉庫：0" and hub.get_warehouse_summary_text().ends_with("倉庫容量：0 / 200"), "City B's warehouse must not show City A's goods")
	hub.get_warehouse_button("test_good_01", "withdraw").pressed.emit()
	_check(hub.get_feedback_text() == "數量不足" and main.warehouses.get_quantity("A", "test_good_01") == 4, "City A goods cannot be withdrawn in City B")

	# Scenario C: reopen restores the warehouses; transport still works.
	var snapshot: Dictionary = main.warehouses.get_snapshot()
	await _destroy(main)
	main = await _new_main(TEST_SAVE)
	_check(main.warehouses.get_snapshot() == snapshot and main.current_city_id == "B", "Reopen must restore every warehouse exactly")
	_check(main.request_transport("A", "ride-a")["success"], "Transport still works")
	_check(main.deposit_to_warehouse("test_good_02", 1)["reason"] == "ERR_NOT_IN_CITY" and main.is_traveling(), "No warehouse use while traveling")
	main.time_source.advance_ms(90000)
	await process_frame
	_check(main.current_city_id == "A" and main.warehouses.get_snapshot() == snapshot, "Arrival must not change warehouses")
	hub = main.get_node("CityHub") as CityHub
	hub.show_facility("warehouse")
	hub.get_warehouse_button("test_good_01", "withdraw").pressed.emit()
	_check(main.inventory.get_quantity("test_good_01") == 1 and main.warehouses.get_quantity("A", "test_good_01") == 3, "Back in City A the stored goods can be withdrawn")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("game_flow")


func _verify_ui_save_failure() -> void:
	var main := await _new_main("")
	await _walk_in(main, "A")
	main.inventory.add("test_good_01", 2)
	# T05: goods placed by the test also need their (unknown-cost) lots.
	main.cost_ledger.add_unknown(TradeCostLedger.BACKPACK, "test_good_01", 2)
	main.save_path = UNWRITABLE_SAVE
	var hub := main.get_node("CityHub") as CityHub
	hub.show_facility("warehouse")
	hub.get_warehouse_button("test_good_01", "deposit").pressed.emit()
	_check(main.inventory.get_quantity("test_good_01") == 2 and main.warehouses.get_quantity("A", "test_good_01") == 0, "A failed save must cancel the deposit")
	_check(hub.get_feedback_text() == "無法儲存，操作已取消" and hub.get_warehouse_row_texts("test_good_01")["carried"] == "背包：2", "The cancel must be explained in Chinese and the UI must stay accurate")
	_check(not FileAccess.file_exists(UNWRITABLE_SAVE), "The unwritable save must not exist")
	await _destroy(main)
	_sections_done.append("ui_save_failure")


# --- Stress -----------------------------------------------------------------------------------------

## Random deposits, withdraws, invalid requests, city moves and save/reload
## cycles against an independent model; totals must always be conserved.
func _verify_stress() -> void:
	_delete(TEST_SAVE)
	var s := _session("A", {"test_good_01": 6, "test_good_03": 3, "test_good_05": 2})
	var model_carried := s.inventory.get_items()
	var model_stored := {"A": {}, "B": {}}
	var totals := {}
	for good_id in IDS:
		totals[good_id] = model_carried.get(good_id, 0)
	var city := "A"
	var seed := 20260927
	var counts := {"deposit": 0, "withdraw": 0, "rejected": 0, "move": 0, "reload": 0}
	var drift := 0
	for step in range(STRESS_STEPS):
		seed = (seed * 1103515245 + 12345) % 2147483648
		var action := (seed >> 8) % 12
		var good_id: String = IDS[(seed >> 12) % IDS.size()]
		var quantity: int = [1, 1, 1, 2, 3, 0, -1, 40][(seed >> 16) % 8]
		# Mostly pick a good the source container actually holds.
		var source: Dictionary = model_carried if action < 5 else model_stored[city]
		if not source.is_empty() and (seed >> 24) % 4 != 0:
			var held := source.keys()
			held.sort()
			good_id = held[(seed >> 13) % held.size()]
		var target: String = city if (seed >> 20) % 6 != 0 else ("B" if city == "A" else "A")
		if action < 9:
			var deposit := action < 5
			var result := _deposit(s, target, good_id, quantity) if deposit else _withdraw(s, target, good_id, quantity)
			var expected := _model_allows(deposit, target == city, good_id, quantity, model_carried, model_stored[city])
			if result["success"] != expected:
				drift += 1
			if result["success"]:
				_move(model_carried, model_stored[city], good_id, quantity, deposit)
				counts["deposit" if deposit else "withdraw"] += 1
			else:
				counts["rejected"] += 1
		elif action == 9:
			city = "B" if city == "A" else "A"
			s.location.leave_city()
			s.location.enter_city(city)
			counts["move"] += 1
		else:
			_check(SaveStore.save(TEST_SAVE, s.wallet, s.inventory, s.market, s.location, s.warehouses), "Stress save")
			var loaded := SaveStore.load_session(TEST_SAVE)
			# Reload rebuilds real stats; keep the capacity-20 rule fixture.
			s.inventory = _fixture_inventory(loaded["inventory"].get_items())
			s.warehouses = loaded["warehouses"]
			s.location = loaded["location"]
			counts["reload"] += 1
		if s.inventory.get_items() != model_carried or s.warehouses.get_contents("A") != model_stored["A"] or s.warehouses.get_contents("B") != model_stored["B"]:
			drift += 1
		for id in IDS:
			if s.inventory.get_quantity(id) + s.warehouses.get_quantity("A", id) + s.warehouses.get_quantity("B", id) != totals[id]:
				drift += 1
		if s.warehouses.get_used_capacity("A") > CAPACITY or s.warehouses.get_used_capacity("B") > CAPACITY or s.wallet.get_balance() != 10000:
			drift += 1
	_check(drift == 0, "Stress: state must match the model and conserve every item (%d drifts)" % drift)
	_check(counts["deposit"] >= 40 and counts["withdraw"] >= 40 and counts["rejected"] >= 40 and counts["move"] >= 15 and counts["reload"] >= 15, "Stress must mix every operation %s" % str(counts))
	print("T01 stress counts: ", counts)
	_delete(TEST_SAVE)
	_sections_done.append("stress")


func _model_allows(deposit: bool, local: bool, good_id: String, quantity: int, carried: Dictionary, stored: Dictionary) -> bool:
	if not local or quantity <= 0:
		return false
	var cost: int = COSTS[good_id]
	if deposit:
		return carried.get(good_id, 0) >= quantity and _used(stored) + quantity * cost <= CAPACITY
	return stored.get(good_id, 0) >= quantity and _used(carried) + quantity * cost <= 20


func _move(carried: Dictionary, stored: Dictionary, good_id: String, quantity: int, deposit: bool) -> void:
	var from := carried if deposit else stored
	var to := stored if deposit else carried
	from[good_id] -= quantity
	if from[good_id] == 0:
		from.erase(good_id)
	to[good_id] = to.get(good_id, 0) + quantity


func _used(items: Dictionary) -> int:
	var used := 0
	for good_id in items:
		used += items[good_id] * COSTS[good_id]
	return used


# --- Helpers ------------------------------------------------------------------------------------------

## A plain object bundling one session's state for model-level tests.
class Session:
	var location := PlayerLocation.new()
	## Model-level warehouse rules use a fixed capacity-20 backpack fixture (their
	## original size); the T02 prototype balance (100) is covered in-game.
	var inventory := CharacterInventory.new("player", FixedCapacityStats.new(20))
	var warehouses := WarehouseState.create_default()
	var wallet := Wallet.new()
	var market := MarketState.create_default()


func _fixture_inventory(items: Dictionary) -> CharacterInventory:
	var inventory := CharacterInventory.new("player", FixedCapacityStats.new(20))
	inventory.restore_items(items)
	return inventory


func _session(city: String, items: Dictionary) -> Session:
	var s := Session.new()
	s.location.enter_city(city)
	s.inventory.restore_items(items)
	return s


func _deposit(s: Session, city: Variant, item: Variant, quantity: Variant, request_id: String = "") -> Dictionary:
	return WarehouseService.deposit(s.location, s.inventory, s.warehouses, city, item, quantity, request_id)


func _withdraw(s: Session, city: Variant, item: Variant, quantity: Variant, request_id: String = "") -> Dictionary:
	return WarehouseService.withdraw(s.location, s.inventory, s.warehouses, city, item, quantity, request_id)


func _total(s: Session, item: String) -> int:
	return s.inventory.get_quantity(item) + s.warehouses.get_quantity("A", item) + s.warehouses.get_quantity("B", item)


func _snapshot(s: Session) -> Dictionary:
	return {"inventory": s.inventory.get_stacks(), "warehouses": s.warehouses.get_snapshot(), "wallet": s.wallet.get_balance(), "market": s.market.get_snapshot(), "location": s.location.to_dict()}


func _unchanged_elsewhere(s: Session) -> bool:
	return s.wallet.get_balance() == 10000 and s.market.get_snapshot() == MarketState.create_default().get_snapshot() and s.location.is_in_city() and s.location.get_city_id() == "A"


func _chinese(hub: CityHub) -> bool:
	var ok := true
	for control in hub.find_children("*", "Label", true, false) + hub.find_children("*", "Button", true, false):
		var text: String = (control as Control).get("text")
		if _latin.search(_approved.sub(text, "", true)) != null:
			push_error("English player text: %s" % text)
			ok = false
	return ok


func _layout_ok(main: Node) -> bool:
	var hub := main.get_node("CityHub") as CityHub
	var portrait := Rect2(Vector2.ZERO, Vector2(720, 1280))
	var enter_area := (main.get_node("EnterControls/EnterCityButton") as Control).get_global_rect()
	var leave := (hub.get_node("Center/Content/LeaveButton") as Control).get_global_rect()
	if not portrait.encloses(leave) or leave.intersects(enter_area):
		return false
	for good_id in IDS:
		for action in ["deposit", "withdraw"]:
			var rect := hub.get_warehouse_button(good_id, action).get_global_rect()
			if not portrait.encloses(rect) or rect.intersects(enter_area) or rect.size.y < 88.0:
				return false
	return true


func _with(data: Dictionary, changes: Dictionary) -> Dictionary:
	var copy := data.duplicate(true)
	copy.merge(changes, true)
	return copy


func _without(data: Dictionary, key: String) -> Dictionary:
	var copy := data.duplicate(true)
	copy.erase(key)
	return copy


## Source code without comment lines, for structural scans.
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
