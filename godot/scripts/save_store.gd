class_name SaveStore
extends RefCounted

## Prototype local persistence. Version 4 adds the main character's location
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
const VERSION := 4
const INVENTORY_VERSIONS := [3, 4]
const LEGACY_CARGO_VERSIONS := [1, 2]
const MAX_SAVED_MONEY := 9007199254740992
const V3_KEYS := ["version", "money", "character", "market"]
const V4_KEYS := ["version", "money", "character", "market", "location"]
const LEGACY_KEYS := ["version", "money", "cargo", "market"]
const CHARACTER_KEYS := ["id", "stats", "inventory"]
const STATS_KEYS := ["strength"]
const INVENTORY_KEYS := ["items"]
const CURRENT_SAVED_STACK_KEYS := ["quantity"]
const EARLY_V3_STACK_KEYS := ["quantity", "capacity_cost"]


## `location` is optional only for historical callers; the game always passes
## its own. Without one the default world location is written.
static func serialize(wallet: Wallet, inventory: CharacterInventory, market: MarketState, location: PlayerLocation = null) -> Dictionary:
	var saved_items := {}
	for item_id in inventory.get_items():
		saved_items[item_id] = {"quantity": inventory.get_quantity(item_id)}
	return {
		"version": VERSION,
		"money": wallet.get_balance(),
		"character": {
			"id": inventory.character_id,
			"stats": {"strength": inventory.get_stats().get_strength()},
			"inventory": {"items": saved_items},
		},
		"market": market.get_snapshot(),
		"location": (location if location != null else PlayerLocation.new()).to_dict(),
	}


static func save(path: String, wallet: Wallet, inventory: CharacterInventory, market: MarketState, location: PlayerLocation = null) -> bool:
	if path == "" or wallet == null or inventory == null or market == null:
		return false
	var temp_path := path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(serialize(wallet, inventory, market, location)))
	file.close()
	var error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path), ProjectSettings.globalize_path(path))
	return error == OK


## Returns wallet/inventory/stats/market/location rebuilt from a valid save. "cargo" is
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


## Version 3 and 4 share the character inventory shape; version 4 must also
## carry a valid location, version 3 gets the default world location.
static func _validate_inventory_save(data: Dictionary, version: int) -> Dictionary:
	var keys := V4_KEYS if version == 4 else V3_KEYS
	if not _has_only_keys(data, keys) or not data.has_all(keys):
		return {}
	var location := PlayerLocation.new()
	if version == 4:
		location = PlayerLocation.from_dict(data["location"])
		if location == null:
			return {}
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
	return {"money": money, "character_id": character["id"], "strength": strength, "items": items, "market": market, "location": location}


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
	if used > Cargo.CARGO_CAPACITY:
		return {}
	return {"money": money, "character_id": "player", "strength": CharacterStats.PROTOTYPE_DEFAULT_STRENGTH, "items": items, "market": market, "location": PlayerLocation.new()}


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
	if wallet.get_balance() != payload["money"] or payload["market"] == null or payload["location"] == null:
		return {}
	return {"wallet": wallet, "inventory": inventory, "cargo": inventory, "character_stats": stats, "market": payload["market"], "location": payload["location"]}


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
