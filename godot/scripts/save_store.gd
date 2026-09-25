class_name SaveStore
extends RefCounted

## Prototype local persistence for the player's money and cargo only.
## The runtime Wallet and Cargo stay the authoritative state; the save file is
## just their serialized form. Loading validates the whole payload first and
## rebuilds fresh Wallet/Cargo objects through their normal APIs, so an invalid
## save never partially restores anything.

const DEFAULT_PATH := "user://myrial_save.json"
const VERSION := 1
## JSON stores numbers as doubles, so only integers up to 2^53 round-trip exactly.
const MAX_SAVED_MONEY := 9007199254740992
const ALLOWED_KEYS := ["version", "money", "cargo"]


static func serialize(wallet: Wallet, cargo: Cargo) -> Dictionary:
	return {"version": VERSION, "money": wallet.get_balance(), "cargo": cargo.get_items()}


## Writes the save through a temporary file and a rename, so an interrupted
## write cannot leave a half-written save. Returns false if the write failed.
static func save(path: String, wallet: Wallet, cargo: Cargo) -> bool:
	if path == "" or wallet == null or cargo == null:
		return false
	var temp_path := path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(serialize(wallet, cargo)))
	file.close()
	var error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path), ProjectSettings.globalize_path(path))
	return error == OK


## Returns {"wallet": Wallet, "cargo": Cargo} rebuilt from a valid save, or an
## empty Dictionary when there is no save or it is invalid in any way.
static func load_session(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK:
		return {}
	var payload := validate(parser.data)
	if payload.is_empty():
		return {}
	return _rebuild(payload["money"], payload["cargo"])


## Checks the whole parsed payload. Returns {"money": int, "cargo": {id: int}}
## when every field is valid, otherwise an empty Dictionary.
static func validate(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	for key in data:
		if not key in ALLOWED_KEYS:
			return {}
	if data.has("version") and _to_int(data["version"]) != VERSION:
		return {}
	if not data.has("money") or not data.has("cargo"):
		return {}
	var money := _to_int(data["money"])
	if money < 0 or money > MAX_SAVED_MONEY:
		return {}
	if typeof(data["cargo"]) != TYPE_DICTIONARY:
		return {}
	var cargo := {}
	var used := 0
	for good_id in data["cargo"]:
		if not GoodsCatalog.has_good(good_id):
			return {}
		var quantity := _to_int(data["cargo"][good_id])
		if quantity <= 0 or quantity > Cargo.CARGO_CAPACITY:
			return {}
		used += quantity * GoodsCatalog.get_unit_size(good_id)
		cargo[good_id] = quantity
	if used > Cargo.CARGO_CAPACITY:
		return {}
	return {"money": money, "cargo": cargo}


static func _rebuild(money: int, items: Dictionary) -> Dictionary:
	var wallet := Wallet.new()
	var difference := money - wallet.get_balance()
	if difference > 0 and not wallet.add(difference):
		return {}
	if difference < 0 and not wallet.spend(-difference):
		return {}
	var cargo := Cargo.new()
	for good_id in items:
		if not cargo.add(good_id, items[good_id]):
			return {}
	if wallet.get_balance() != money or cargo.get_items() != items:
		return {}
	return {"wallet": wallet, "cargo": cargo}


## Accepts a JSON whole number (parsed as float) or an int; returns -1 for
## anything else, which every caller treats as invalid.
static func _to_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) \
			and value >= 0.0 and value <= float(MAX_SAVED_MONEY):
		return int(value)
	return -1
