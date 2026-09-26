class_name SaveStore
extends RefCounted

## Prototype local persistence. Version 3 stores a character-owned inventory
## and the Strength input used to derive max capacity. Item capacity costs are
## balance data and are deliberately NOT authoritative save data: current item
## definitions are applied when rebuilding the inventory. Legacy v1/v2 Cargo
## saves remain readable and migrate in memory without rewriting the source
## file. Loading validates the complete payload before returning any runtime
## object.

const DEFAULT_PATH := "user://myrial_save.json"
const VERSION := 3
const LEGACY_CARGO_VERSIONS := [1, 2]
const MAX_SAVED_MONEY := 9007199254740992
const V3_KEYS := ["version", "money", "character", "market"]
const LEGACY_KEYS := ["version", "money", "cargo", "market"]
const CHARACTER_KEYS := ["id", "stats", "inventory"]
const STATS_KEYS := ["strength"]
const INVENTORY_KEYS := ["items"]
const CURRENT_SAVED_STACK_KEYS := ["quantity"]
const EARLY_V3_STACK_KEYS := ["quantity", "capacity_cost"]


static func serialize(wallet: Wallet, inventory: CharacterInventory, market: MarketState) -> Dictionary:
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
	}


static func save(path: String, wallet: Wallet, inventory: CharacterInventory, market: MarketState) -> bool:
	if path == "" or wallet == null or inventory == null or market == null:
		return false
	var temp_path := path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(serialize(wallet, inventory, market)))
	file.close()
	var error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path), ProjectSettings.globalize_path(path))
	return error == OK


## Returns wallet/inventory/stats/market rebuilt from a valid save. "cargo" is
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
	if version == VERSION:
		return _validate_v3(data)
	if version in LEGACY_CARGO_VERSIONS:
		return _validate_legacy(data, version)
	return {}


static func _validate_v3(data: Dictionary) -> Dictionary:
	if not _has_only_keys(data, V3_KEYS) or not data.has_all(V3_KEYS):
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
	return {"money": money, "character_id": character["id"], "strength": strength, "items": items, "market": market}


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
	return {"money": money, "character_id": "player", "strength": CharacterStats.PROTOTYPE_DEFAULT_STRENGTH, "items": items, "market": market}


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
	if wallet.get_balance() != payload["money"] or payload["market"] == null:
		return {}
	return {"wallet": wallet, "inventory": inventory, "cargo": inventory, "character_stats": stats, "market": payload["market"]}


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
