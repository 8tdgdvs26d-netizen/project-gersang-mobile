class_name SaveStore
extends RefCounted

## Version 9 (C05) adds `progression`: the Level / EXP of the three fixed
## Prototype combat slots, owned and validated by ProgressionState (strict;
## a malformed section rejects the whole save). v1-v8 saves load with the
## default progression (every slot Lv1, 0 EXP) in memory only; the source
## file is not rewritten until the next normal save, which writes v9.
## Prototype local persistence. Version 8 (T06) stores the exact WORLD
## coordinates inside `location` (PlayerLocation owns and validates the shape;
## non-finite or out-of-bounds coordinates reject the whole save, never
## clamped). v4-v7 locations migrate through PlayerLocation.from_legacy_dict:
## WORLD -> the last city's return point, or the default world spawn without a
## city; IN_CITY / TRAVELING unchanged. Saves are written with full float
## precision so exact coordinates round-trip.
## Version 7 adds the trade cost ledger (T05)
## through TradeCostLedger: ordered FIFO cost lots for the backpack and every
## city warehouse. Its lot totals must match the saved item quantities exactly
## or the whole save is rejected. v1-v6 saves get an UNKNOWN-cost lot for every
## carried and stored unit (quantities kept, no price invented).
## Version 6 adds the market recovery anchor
## (T04) through MarketRecovery, which owns and validates its own saved shape;
## a malformed anchor value loads as "no anchor" (no recovery is invented).
## v1-v5 saves load with no anchor: their stock is kept unchanged and the
## anchor starts when the game first advances the market after loading.
## Version 5 adds one item warehouse per active
## city through WarehouseState (item quantities only; warehouse capacity is
## balance data and is never saved). v1-v4 saves load with empty warehouses.
## Version 4 adds the main character's location
## (world / inside a city / on a passenger journey) through PlayerLocation,
## which owns and validates its own saved shape. Version 3 stores a
## character-owned inventory
## and the Strength input used to derive max capacity. Item capacity costs are
## balance data and are deliberately NOT authoritative save data: current item
## definitions are applied when rebuilding the inventory. Legacy v1/v2 Cargo
## saves remain readable and migrate in memory without rewriting the source
## file. v1/v2/v3 saves have no location and load at the normal world spawn
## (the pre-M2-09 behaviour). Loading validates the complete payload before
## returning any runtime object.

const DEFAULT_PATH := "user://myrial_save.json"
const VERSION := 9
const INVENTORY_VERSIONS := [3, 4, 5, 6, 7, 8, 9]
const LEGACY_CARGO_VERSIONS := [1, 2]
const MAX_SAVED_MONEY := 9007199254740992
## The fixed capacity legacy v1/v2 Cargo had when those saves were written.
## Historical data, independent of today's prototype backpack balance.
const LEGACY_CARGO_CAPACITY := 20
const V3_KEYS := ["version", "money", "character", "market"]
const V4_KEYS := ["version", "money", "character", "market", "location"]
const V5_KEYS := ["version", "money", "character", "market", "location", "warehouses"]
const V6_KEYS := ["version", "money", "character", "market", "location", "warehouses", "market_recovery"]
const V7_KEYS := ["version", "money", "character", "market", "location", "warehouses", "market_recovery", "cost_ledger"]
## Same sections as v7; only the location gains exact world coordinates.
const V8_KEYS := V7_KEYS
## C05: v8 + the progression section.
const V9_KEYS := ["version", "money", "character", "market", "location", "warehouses", "market_recovery", "cost_ledger", "progression"]
const LEGACY_KEYS := ["version", "money", "cargo", "market"]
const CHARACTER_KEYS := ["id", "stats", "inventory"]
const STATS_KEYS := ["strength"]
const INVENTORY_KEYS := ["items"]
const CURRENT_SAVED_STACK_KEYS := ["quantity"]
const EARLY_V3_STACK_KEYS := ["quantity", "capacity_cost"]


## `location`, `warehouses`, `recovery` and `ledger` are optional only for
## historical callers; the game always passes its own. Without them the
## defaults are written (an unanchored recovery, unknown-cost lots).
static func serialize(wallet: Wallet, inventory: CharacterInventory, market: MarketState, location: PlayerLocation = null, warehouses: WarehouseState = null, recovery: MarketRecovery = null, ledger: TradeCostLedger = null, progression: ProgressionState = null) -> Dictionary:
	var stored := warehouses if warehouses != null else WarehouseState.create_default()
	var lots := ledger if ledger != null else TradeCostLedger.unknown_for(inventory.get_items(), stored)
	var saved_items := {}
	for item_id in inventory.get_items():
		saved_items[item_id] = {"quantity": inventory.get_quantity(item_id)}
	return {
		"version": VERSION,
		"money": wallet.get_balance(),
		"character": {
			"id": inventory.character_id,
			# S01: the Hero's Base STR (Allocated / Equipment are not saved).
			"stats": {"strength": inventory.get_stats().get_base_strength()},
			"inventory": {"items": saved_items},
		},
		"market": market.get_snapshot(),
		"location": (location if location != null else PlayerLocation.new()).to_dict(),
		"warehouses": stored.get_snapshot(),
		"market_recovery": (recovery if recovery != null else MarketRecovery.new()).to_dict(),
		"cost_ledger": lots.to_save(WorldLayout.ACTIVE_CITY_IDS),
		"progression": (progression if progression != null else ProgressionState.new()).to_dict(),
	}


static func save(path: String, wallet: Wallet, inventory: CharacterInventory, market: MarketState, location: PlayerLocation = null, warehouses: WarehouseState = null, recovery: MarketRecovery = null, ledger: TradeCostLedger = null, progression: ProgressionState = null) -> bool:
	if path == "" or wallet == null or inventory == null or market == null:
		return false
	# T06: never write an invalid location (e.g. world coordinates outside the
	# playable rect); checked before any file is created.
	if location != null and PlayerLocation.from_dict(location.to_dict()) == null:
		return false
	# T05: never write a cost ledger that does not account for exactly every
	# carried and stored unit. Checked before any file is created, so a refused
	# save leaves the existing save file untouched.
	if ledger != null and not ledger.matches(inventory.get_items(), warehouses if warehouses != null else WarehouseState.create_default()):
		return false
	var temp_path := path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(serialize(wallet, inventory, market, location, warehouses, recovery, ledger, progression), "", true, true))
	file.close()
	var error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path), ProjectSettings.globalize_path(path))
	return error == OK


## Returns wallet/inventory/stats/market/location/warehouses/market_recovery/
## cost_ledger rebuilt from a valid save. "cargo" is
## a temporary code-compatibility alias to the same inventory object.
static func load_session(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK:
		return {}
	var payload := validate(parser.data)
	if payload.is_empty():
		return {}
	return _rebuild(payload)


static func validate(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	var version := _to_int(data.get("version", 1))
	if version in INVENTORY_VERSIONS:
		return _validate_inventory_save(data, version)
	if version in LEGACY_CARGO_VERSIONS:
		return _validate_legacy(data, version)
	return {}


## Versions 3-6 share the character inventory shape. Version 4+ must also
## carry a valid location, version 5+ valid warehouses and version 6 a
## market_recovery entry and version 7 a cost_ledger matching the carried and
## stored quantities; older versions get the default world location, empty
## warehouses, no recovery anchor and unknown-cost lots.
static func _validate_inventory_save(data: Dictionary, version: int) -> Dictionary:
	var keys: Array = {3: V3_KEYS, 4: V4_KEYS, 5: V5_KEYS, 6: V6_KEYS, 7: V7_KEYS, 8: V8_KEYS, 9: V9_KEYS}[version]
	if not _has_only_keys(data, keys) or not data.has_all(keys):
		return {}
	var location := PlayerLocation.new()
	if version >= 8:
		location = PlayerLocation.from_dict(data["location"])
		if location == null:
			return {}
	elif version >= 4:
		location = PlayerLocation.from_legacy_dict(data["location"])
		if location == null:
			return {}
	var warehouses := WarehouseState.create_default()
	if version >= 5:
		warehouses = WarehouseState.from_snapshot(data["warehouses"])
		if warehouses == null:
			return {}
	var progression := ProgressionState.new()
	if version >= 9:
		progression = ProgressionState.from_dict(data["progression"])
		if progression == null:
			return {}
	var recovery := MarketRecovery.new()
	if version >= 6:
		recovery = MarketRecovery.from_dict(data["market_recovery"])
	var money := _valid_money(data["money"])
	var market := _valid_market(data["market"])
	var character: Variant = data["character"]
	if money < 0 or market == null or typeof(character) != TYPE_DICTIONARY \
		or not _has_only_keys(character, CHARACTER_KEYS) or not character.has_all(CHARACTER_KEYS):
		return {}
	if typeof(character["id"]) != TYPE_STRING or character["id"] == "":
		return {}
	var stats: Variant = character["stats"]
	var inventory: Variant = character["inventory"]
	if typeof(stats) != TYPE_DICTIONARY or not _has_only_keys(stats, STATS_KEYS) or not stats.has("strength"):
		return {}
	if typeof(inventory) != TYPE_DICTIONARY or not _has_only_keys(inventory, INVENTORY_KEYS) or not inventory.has("items"):
		return {}
	var strength := _to_int(stats["strength"])
	if strength < 0 or strength > CharacterStats.MAX_STRENGTH:
		return {}
	var items: Variant = _valid_saved_items(inventory["items"])
	if items == null:
		return {}
	var ledger := TradeCostLedger.unknown_for(items, warehouses)
	if version >= 7:
		ledger = TradeCostLedger.from_save(data["cost_ledger"], WorldLayout.ACTIVE_CITY_IDS)
		if ledger == null or not ledger.matches(items, warehouses):
			return {}
	if ledger == null:
		return {}
	return {"money": money, "character_id": character["id"], "strength": strength, "items": items, "market": market, "location": location, "warehouses": warehouses, "market_recovery": recovery, "cost_ledger": ledger, "progression": progression}


static func _validate_legacy(data: Dictionary, version: int) -> Dictionary:
	if not _has_only_keys(data, LEGACY_KEYS) or not data.has("money") or not data.has("cargo"):
		return {}
	if version == 2 and not data.has("market"):
		return {}
	var money := _valid_money(data["money"])
	if money < 0 or typeof(data["cargo"]) != TYPE_DICTIONARY:
		return {}
	var market := MarketState.create_default()
	if data.has("market"):
		market = _valid_market(data["market"])
		if market == null:
			return {}
	var items := {}
	var used := 0
	for item_id in data["cargo"]:
		if not GoodsCatalog.has_good(item_id):
			return {}
		var quantity := _to_int(data["cargo"][item_id])
		var cost := GoodsCatalog.get_capacity_cost(item_id)
		if quantity <= 0:
			return {}
		used += quantity * cost
		items[item_id] = quantity
	# Preserve the original corrupt-save safety: legacy Cargo never legally held
	# more than its fixed capacity, so an over-capacity legacy payload is invalid.
	if used > LEGACY_CARGO_CAPACITY:
		return {}
	return {"money": money, "character_id": "player", "strength": CharacterStats.PROTOTYPE_DEFAULT_STRENGTH, "items": items, "market": market, "location": PlayerLocation.new(), "warehouses": WarehouseState.create_default(), "market_recovery": MarketRecovery.new(), "cost_ledger": TradeCostLedger.unknown_for(items, null), "progression": ProgressionState.new()}


## Version 3 currently writes item_id -> {quantity}. Early unmerged M2-08 builds
## briefly also wrote capacity_cost. Accept that shape for developer-save
## compatibility, but ignore the saved cost completely. Capacity is balance
## data and is resolved from the current authoritative item definition on load.
static func _valid_saved_items(data: Variant) -> Variant:
	if typeof(data) != TYPE_DICTIONARY:
		return null
	var items := {}
	for item_id in data:
		if typeof(item_id) != TYPE_STRING or item_id == "" or not GoodsCatalog.has_good(item_id):
			return null
		var stack: Variant = data[item_id]
		if typeof(stack) != TYPE_DICTIONARY:
			return null
		var allowed_keys := CURRENT_SAVED_STACK_KEYS
		if stack.has("capacity_cost"):
			allowed_keys = EARLY_V3_STACK_KEYS
		if not _has_only_keys(stack, allowed_keys) or not stack.has("quantity"):
			return null
		var quantity := _to_int(stack["quantity"])
		if quantity <= 0:
			return null
		if stack.has("capacity_cost") and _to_int(stack["capacity_cost"]) <= 0:
			return null
		items[item_id] = quantity
	return items


static func _valid_market(data: Variant) -> MarketState:
	return MarketState.from_snapshot(_market_ints(data))


static func _market_ints(data: Variant) -> Variant:
	if typeof(data) != TYPE_DICTIONARY:
		return null
	var cities := {}
	for city in data:
		if typeof(data[city]) != TYPE_DICTIONARY:
			return null
		var goods := {}
		for good_id in data[city]:
			var entry: Variant = data[city][good_id]
			if typeof(entry) != TYPE_DICTIONARY:
				return null
			var values := {}
			for key in entry:
				values[key] = _to_int(entry[key])
			goods[good_id] = values
		cities[city] = goods
	return cities


static func _rebuild(payload: Dictionary) -> Dictionary:
	var wallet := Wallet.new()
	var difference: int = payload["money"] - wallet.get_balance()
	if difference > 0 and not wallet.add(difference):
		return {}
	if difference < 0 and not wallet.spend(-difference):
		return {}
	var stats := CharacterStats.new(payload["strength"])
	var inventory := CharacterInventory.new(payload["character_id"], stats)
	if not inventory.restore_items(payload["items"]):
		return {}
	if wallet.get_balance() != payload["money"] or payload["market"] == null or payload["location"] == null or payload["warehouses"] == null or payload["market_recovery"] == null or payload["cost_ledger"] == null or payload["progression"] == null:
		return {}
	return {"wallet": wallet, "inventory": inventory, "cargo": inventory, "character_stats": stats, "market": payload["market"], "location": payload["location"], "warehouses": payload["warehouses"], "market_recovery": payload["market_recovery"], "cost_ledger": payload["cost_ledger"], "progression": payload["progression"]}


static func _valid_money(value: Variant) -> int:
	var money := _to_int(value)
	return money if money >= 0 and money <= MAX_SAVED_MONEY else -1


static func _has_only_keys(data: Dictionary, allowed: Array) -> bool:
	for key in data:
		if not key in allowed:
			return false
	return true


static func _to_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) \
		and value >= 0.0 and value <= float(MAX_SAVED_MONEY):
		return int(value)
	return -1
