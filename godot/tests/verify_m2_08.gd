extends SceneTree

const TEST_SAVE := "user://m2_08_inventory_save.json"

var _checks := 0
var _failures := 0


class FailingBuyMarket extends MarketState:
	func get_quote(_city_id: Variant, _good_id: Variant) -> Dictionary:
		return {"buy_price": 10, "buyback_price": 8}

	func can_remove_stock(_city_id: Variant, _good_id: Variant, _quantity: Variant) -> bool:
		return true

	func remove_stock(_city_id: Variant, _good_id: Variant, _quantity: Variant) -> bool:
		return false


class FailingSellMarket extends MarketState:
	func get_quote(_city_id: Variant, _good_id: Variant) -> Dictionary:
		return {"buy_price": 10, "buyback_price": 8}

	func can_add_stock(_city_id: Variant, _good_id: Variant, _quantity: Variant) -> bool:
		return true

	func add_stock(_city_id: Variant, _good_id: Variant, _quantity: Variant) -> bool:
		return false


func _initialize() -> void:
	_delete_save()
	_verify_stats_and_items()
	_verify_authoritative_costs()
	_verify_transfer()
	_verify_market_and_rollback()
	_verify_over_capacity()
	_verify_save_reload()
	_verify_saved_balance_decoupling()
	_verify_legacy_migration()
	_verify_corrupt_save_safety()
	_delete_save()
	if _failures == 0:
		print("M2-08 character inventory foundation verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_stats_and_items() -> void:
	var weak := CharacterStats.new(5)
	var strong := CharacterStats.new(15)
	_check(weak.get_max_capacity() == 15 and strong.get_max_capacity() == 25, "max capacity must come from the Strength interface")
	_check(CharacterStats.PROTOTYPE_BASE_CAPACITY == 10 and CharacterStats.PROTOTYPE_CAPACITY_PER_STRENGTH == 1, "prototype capacity formula must be explicit parameters")
	var inventory := CharacterInventory.new("hero", strong, Callable(self, "_general_test_cost"))
	_check(inventory.add("test_good_03", 3), "three cost-2 goods must fit")
	_check(inventory.get_quantity("test_good_03") == 3 and inventory.get_used_capacity() == 6, "stack display quantity must still cost quantity x capacity_cost")
	_check(inventory.add("equipped_test_blade", 1), "future equipped items must use the generic authoritative resolver")
	_check(inventory.get_used_capacity() == 13 and inventory.get_capacity_cost("equipped_test_blade") == 7, "equipped placeholder must count toward the same capacity")
	var default_inventory := CharacterInventory.new("hero", strong)
	_check(not default_inventory.add("unknown_without_cost", 1), "unknown items without an authoritative capacity-cost interface must be rejected")


func _verify_authoritative_costs() -> void:
	var source_text := FileAccess.get_file_as_string("res://scripts/character_inventory.gd")
	_check(not source_text.contains("capacity_cost: Variant = null"), "normal add/can_add must not expose a per-call capacity override")
	var inventory := CharacterInventory.new("hero", CharacterStats.new(20))
	_check(not inventory.restore_stacks({"test_good_06": {"quantity": 1, "capacity_cost": 1}}), "rollback restore must reject a fake lower capacity cost")
	_check(inventory.restore_stacks({"test_good_06": {"quantity": 1, "capacity_cost": 4}}), "rollback restore must accept the authoritative capacity cost")
	_check(inventory.get_used_capacity() == 4, "restored known good must use the authoritative catalog cost")


func _verify_transfer() -> void:
	var source := CharacterInventory.new("hero", CharacterStats.new(20))
	var destination := CharacterInventory.new("mercenary", CharacterStats.new(0))
	source.add("test_good_05", 2)
	_check(source.transfer_to(destination, "test_good_05", 1), "model-level transfer must succeed when source and destination are valid")
	_check(source.get_quantity("test_good_05") == 1 and destination.get_quantity("test_good_05") == 1, "successful transfer must update both inventories once")
	destination.add("test_good_01", 7)
	var source_before := source.get_stacks()
	var destination_before := destination.get_stacks()
	_check(not source.transfer_to(destination, "test_good_05", 1), "transfer must reject when destination lacks capacity")
	_check(source.get_stacks() == source_before and destination.get_stacks() == destination_before, "failed transfer must change neither inventory")

	var light_source := CharacterInventory.new("source", CharacterStats.new(0), Callable(self, "_source_transfer_cost"))
	var strict_destination := CharacterInventory.new("destination", CharacterStats.new(0), Callable(self, "_destination_transfer_cost"))
	_check(light_source.add("transfer_probe", 1), "source resolver must allow the transfer probe at source cost")
	_check(strict_destination.add("test_good_01", 7), "destination setup must leave only three capacity units")
	var light_before := light_source.get_items()
	var strict_before := strict_destination.get_items()
	_check(not light_source.transfer_to(strict_destination, "transfer_probe", 1), "destination must price transfer capacity with its own authoritative resolver")
	_check(light_source.get_items() == light_before and strict_destination.get_items() == strict_before, "authoritative-cost transfer rejection must be atomic")


func _verify_market_and_rollback() -> void:
	var wallet := Wallet.new()
	var inventory := CharacterInventory.new("hero", CharacterStats.new(0))
	var market := MarketState.create_default()
	var bought := TradeService.buy("A", "test_good_03", 5, wallet, inventory, market)
	_check(bought["success"] and inventory.get_used_capacity() == 10, "market buy must pass at exact character capacity")
	var wallet_before := wallet.get_balance()
	var stock_before := market.get_snapshot()
	var rejected := TradeService.buy("A", "test_good_01", 1, wallet, inventory, market)
	_check(not rejected["success"] and rejected["reason"] == "insufficient_cargo_space", "market buy must fail when character inventory is full")
	_check(wallet.get_balance() == wallet_before and market.get_snapshot() == stock_before, "capacity rejection must leave wallet and market unchanged")
	var sold := TradeService.sell("A", "test_good_03", 2, wallet, inventory, market)
	_check(sold["success"] and inventory.get_quantity("test_good_03") == 3, "market sell must remove from the character inventory")

	var rollback_wallet := Wallet.new()
	var rollback_inventory := CharacterInventory.new("hero", CharacterStats.new())
	var failed := TradeService.buy("A", "test_good_01", 2, rollback_wallet, rollback_inventory, FailingBuyMarket.new())
	_check(not failed["success"] and failed["reason"] == "invalid_state", "late market failure must reject the transaction")
	_check(rollback_wallet.get_balance() == Wallet.STARTING_MONEY and rollback_inventory.is_empty(), "late buy failure must roll back money and inventory")
	var sell_stats := CharacterStats.new(20)
	var sell_inventory := CharacterInventory.new("hero", sell_stats)
	sell_inventory.add("test_good_01", 25)
	sell_stats.set_strength(10)
	var sell_wallet := Wallet.new()
	var failed_sell := TradeService.sell("A", "test_good_01", 1, sell_wallet, sell_inventory, FailingSellMarket.new())
	_check(not failed_sell["success"] and sell_wallet.get_balance() == Wallet.STARTING_MONEY, "late sell failure must roll back money")
	_check(sell_inventory.get_quantity("test_good_01") == 25 and sell_inventory.is_over_capacity(), "late sell failure must restore an over-capacity inventory exactly")


func _verify_over_capacity() -> void:
	var stats := CharacterStats.new(20)
	var inventory := CharacterInventory.new("hero", stats)
	_check(inventory.add("test_good_01", 25), "items must fit before Strength falls")
	_check(stats.set_strength(10) and inventory.is_over_capacity(), "Strength change may create an over-capacity state")
	_check(inventory.get_used_capacity() == 25 and inventory.get_max_capacity() == 20 and inventory.get_quantity("test_good_01") == 25, "over-capacity must not delete or clamp items")
	_check(not inventory.can_add("test_good_01", 1) and not inventory.add("test_good_01", 1), "over-capacity inventory must reject additions")
	_check(inventory.remove("test_good_01", 5) and not inventory.is_over_capacity(), "removal must remain allowed so the player can return to legal capacity")


func _verify_save_reload() -> void:
	var stats := CharacterStats.new(20)
	var inventory := CharacterInventory.new("hero", stats)
	inventory.add("test_good_01", 25)
	stats.set_strength(10)
	var wallet := Wallet.new()
	var market := MarketState.create_default()
	_check(SaveStore.save(TEST_SAVE, wallet, inventory, market), "version 3 character inventory save must write")
	var raw := _read_json()
	var saved_stack: Dictionary = raw.get("character", {}).get("inventory", {}).get("items", {}).get("test_good_01", {})
	_check(saved_stack == {"quantity": 25}, "version 3 save must persist quantity without freezing capacity balance data")
	var loaded := SaveStore.load_session(TEST_SAVE)
	_check(not loaded.is_empty() and loaded["inventory"] is CharacterInventory, "version 3 save must rebuild a CharacterInventory")
	var restored: CharacterInventory = loaded["inventory"]
	_check(restored.character_id == "hero" and restored.get_stats().get_strength() == 10, "save/reload must preserve character owner and Strength")
	_check(restored.get_quantity("test_good_01") == 25 and restored.is_over_capacity(), "save/reload must preserve valid over-capacity items without deletion")
	_check(not restored.add("test_good_02", 1), "reloaded over-capacity inventory must still reject additions")


func _verify_saved_balance_decoupling() -> void:
	var early_v3 := {
		"version": 3,
		"money": 8765,
		"character": {
			"id": "hero",
			"stats": {"strength": 10},
			"inventory": {"items": {"test_good_01": {"quantity": 2, "capacity_cost": 99}}},
		},
		"market": MarketState.create_default().get_snapshot(),
	}
	_write_json(early_v3)
	var loaded := SaveStore.load_session(TEST_SAVE)
	_check(not loaded.is_empty(), "an otherwise-valid early v3 save must not become corrupt because saved balance cost differs")
	var restored: CharacterInventory = loaded.get("inventory")
	_check(restored != null and restored.get_quantity("test_good_01") == 2, "balance-decoupled load must preserve saved quantity")
	_check(restored != null and restored.get_capacity_cost("test_good_01") == GoodsCatalog.get_capacity_cost("test_good_01") and restored.get_used_capacity() == 2, "load must apply the current authoritative catalog capacity cost")


func _verify_legacy_migration() -> void:
	var legacy := {"version": 2, "money": 4321, "cargo": {"test_good_03": 4}, "market": MarketState.create_default().get_snapshot()}
	_write_json(legacy)
	var loaded := SaveStore.load_session(TEST_SAVE)
	_check(not loaded.is_empty() and loaded["wallet"].get_balance() == 4321, "legacy Cargo save must keep money")
	var migrated: CharacterInventory = loaded["inventory"]
	_check(migrated.character_id == "player" and migrated.get_quantity("test_good_03") == 4, "legacy Cargo must migrate into the player CharacterInventory")
	_check(migrated.get_used_capacity() == 8 and migrated.get_max_capacity() == 20, "legacy migration must preserve quantities and apply current placeholder costs with prototype Strength capacity")
	_check(int(_read_json().get("version", 0)) == 2, "loading legacy data must not rewrite the source save")


func _verify_corrupt_save_safety() -> void:
	var corrupt := {
		"version": 3,
		"money": 1,
		"character": {
			"id": "hero",
			"stats": {"strength": 10},
			"inventory": {"items": {"unknown_item": {"quantity": 2}}},
		},
		"market": MarketState.create_default().get_snapshot(),
	}
	_write_json(corrupt)
	_check(SaveStore.load_session(TEST_SAVE).is_empty(), "corrupt v3 payload with an unknown item must be rejected as a whole")
	_check(_read_json().get("money") == 1, "rejected corrupt save must not be overwritten")


func _general_test_cost(item_id: Variant) -> int:
	if item_id == "equipped_test_blade":
		return 7
	return GoodsCatalog.get_capacity_cost(item_id)


func _source_transfer_cost(item_id: Variant) -> int:
	if item_id == "transfer_probe":
		return 1
	return GoodsCatalog.get_capacity_cost(item_id)


func _destination_transfer_cost(item_id: Variant) -> int:
	if item_id == "transfer_probe":
		return 4
	return GoodsCatalog.get_capacity_cost(item_id)


func _write_json(data: Dictionary) -> void:
	_write_text(JSON.stringify(data))


func _write_text(text: String) -> void:
	var file := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _read_json() -> Dictionary:
	var parser := JSON.new()
	return parser.data if parser.parse(FileAccess.get_file_as_string(TEST_SAVE)) == OK else {}


func _delete_save() -> void:
	if FileAccess.file_exists(TEST_SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
