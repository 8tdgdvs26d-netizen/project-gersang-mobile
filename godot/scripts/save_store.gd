class_name SaveStore
extends RefCounted

## Version 14 (Stage 10 P00) adds `condition`: every character's persistent
## current HP, current MP and dead state, per stable character id (the Hero
## and every owned Mercenary, exactly those). CharacterCondition.parse_save
## owns and validates it strictly (whole numbers, dead exactly when HP is 0,
## no pending / unknown id); anything else rejects the whole save. The maxima
## are not saved: once the stats are rebuilt, a value above its current Max
## is clamped to it (the approved Max-change rule). v1-v13 saves had no
## condition: they load with every character at its full current maxima,
## alive (nothing was stored to preserve); the file becomes v14 at the next
## save.
## Version 13 (Stage 9 P01) adds `carrying`: what every character carries
## beyond the Hero's backpack goods (still in `character`, with the cost
## ledger) — per stable character id (the Hero and every owned Mercenary,
## exactly those): its equipped Weapon / Armor and carried equipment
## (CharacterEquipment) and, for a Mercenary, its goods (P01: must be empty;
## implementation gap, the cost ledger does not cover Mercenary goods yet).
## CharacterCarrying.parse_save owns and validates it strictly (no pending /
## unknown id, slot-correct known items, whole quantities); anything else
## rejects the whole save. Equipment bonuses, Effective stats and Capacity are
## rebuilt, never saved; over capacity is legal and loads as it is. v1-v12
## saves load with empty carrying for the Hero and every owned Mercenary
## (after the P05 legacy migration); the file becomes v13 at the next save.
## Version 12 (Stage 8 P05) makes the roster the only Mercenary source:
## `progression` and `allocation` hold only the Hero ({"hero": ...}; the old
## three-slot sections are refused in a v12 save) and
## `pending_legacy_mercenaries` lists converted legacy Mercenaries waiting for
## a free place (MercenaryRoster.restore_pending: merc_a GUARDIAN / merc_b
## MAGE, each at most once, never owned at the same time). Every valid v1-v11
## save is migrated in memory while loading (LegacyMercenaryMigration: the
## Stage 7 Merc A / Merc B become roster Mercenaries merc_a / merc_b with
## their saved Level, EXP and allocation, owned when there is room, else
## pending; never deployed); the file becomes v12 at the next normal save and
## a v12 save never migrates again. A conflicting v11 roster (merc_a / merc_b
## owned with other data) rejects the whole save. Nothing derived is saved.
## P05 also tells a missing save from an unreadable one (inspect()): a
## corrupt, invalid or future-version file is never overwritten (main.gd
## locks saving) and backup_unreadable() copies its exact bytes aside.
## Version 11 (Stage 8 P01.5) adds `mercenaries`: the owned Mercenary roster
## (MercenaryRoster.to_dict: each instance's id, type, Level, EXP and allocation
## counts; the deployed ids; next_serial, the id high-water mark, so no issued
## id is issued again after a restart). MercenaryRoster.from_dict owns and
## validates the shape strictly; a malformed section rejects the whole save.
## v1-v10 saves load with an empty roster (the fixed Stage 7 merc_a / merc_b
## progression and allocation stay where they are, untouched).
## Version 10 (Stage 7 S05) adds `allocation`: the confirmed Stat Point
## counts per stat (hp / str / agi / int) of the three fixed combat
## characters. Only point counts are saved; Growth, Effective and derived
## stats, Capacity and the unspent / earned points are rebuilt from Level and
## these counts. A v10 save is valid only when every character has exactly the
## four counts, each a whole number >= 0, together no more than the points its
## (normalised) Level has earned ((Level - 1) x 3); anything else rejects the
## whole save (never clamped or repaired). v1-v9 saves load with every
## allocation 0 (no history is invented); the next normal save writes v10.
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
const VERSION := 14
const INVENTORY_VERSIONS := [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
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
## S05: v9 + the allocation section.
const V10_KEYS := ["version", "money", "character", "market", "location", "warehouses", "market_recovery", "cost_ledger", "progression", "allocation"]
## P01.5: v10 + the Mercenary roster.
const V11_KEYS := ["version", "money", "character", "market", "location", "warehouses", "market_recovery", "cost_ledger", "progression", "allocation", "mercenaries"]
## Stage 8 P05: v11 + the pending legacy Mercenaries (progression / allocation
## now hold only the Hero).
const V12_KEYS := ["version", "money", "character", "market", "location", "warehouses", "market_recovery", "cost_ledger", "progression", "allocation", "mercenaries", "pending_legacy_mercenaries"]
## Stage 9 P01: v12 + every character's carrying (equipment; Mercenary goods).
const V13_KEYS := ["version", "money", "character", "market", "location", "warehouses", "market_recovery", "cost_ledger", "progression", "allocation", "mercenaries", "pending_legacy_mercenaries", "carrying"]
## Stage 10 P00: v13 + every character's persistent condition.
const V14_KEYS := ["version", "money", "character", "market", "location", "warehouses", "market_recovery", "cost_ledger", "progression", "allocation", "mercenaries", "pending_legacy_mercenaries", "carrying", "condition"]
## Stage 8 P05: inspect() results.
const STATUS_MISSING := "missing"
const STATUS_LOADED := "loaded"
const STATUS_UNREADABLE := "unreadable"
## Why a save is unreadable.
const REASON_CORRUPT := "corrupt"
const REASON_INVALID := "invalid"
const REASON_FUTURE := "future"
## backup_unreadable(): "<path>.unreadable-<n>", the first n not in use.
const BACKUP_SUFFIX := ".unreadable-"
const MAX_BACKUPS := 1000
const LEGACY_KEYS := ["version", "money", "cargo", "market"]
const CHARACTER_KEYS := ["id", "stats", "inventory"]
const STATS_KEYS := ["strength"]
const INVENTORY_KEYS := ["items"]
const CURRENT_SAVED_STACK_KEYS := ["quantity"]
const EARLY_V3_STACK_KEYS := ["quantity", "capacity_cost"]


## `location`, `warehouses`, `recovery` and `ledger` are optional only for
## historical callers; the game always passes its own. Without them the
## defaults are written (an unanchored recovery, unknown-cost lots).
## S05: `characters` (character id -> CharacterStats) gives the confirmed
## allocation; a missing character (or none given) is written with 0 points.
## P01.5: `roster` is written as `mercenaries` (none given: an empty roster).
## P05: progression / allocation of the Hero only; the roster's pending
## legacy list as `pending_legacy_mercenaries`. Stage 9 P01: `carrying` is
## written as `carrying` (none given: empty for the Hero and every owned
## Mercenary). Stage 10 P00: `condition` is written as `condition` (none
## given: every character full / alive at its current maxima).
static func serialize(wallet: Wallet, inventory: CharacterInventory, market: MarketState, location: PlayerLocation = null, warehouses: WarehouseState = null, recovery: MarketRecovery = null, ledger: TradeCostLedger = null, progression: ProgressionState = null, characters: Dictionary = {}, roster: MercenaryRoster = null, carrying: CharacterCarrying = null, condition: CharacterCondition = null) -> Dictionary:
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
		"allocation": _allocation_snapshot(characters),
		"mercenaries": (roster if roster != null else MercenaryRoster.new()).to_dict(),
		"pending_legacy_mercenaries": (roster if roster != null else MercenaryRoster.new()).pending_to_list(),
		"carrying": carrying.to_save() if carrying != null else _empty_carrying(roster),
		"condition": condition.to_save() if condition != null else _full_condition(inventory, roster, carrying),
	}


## Stage 10 P00: every character full / alive at its current maxima (a save
## written without a condition: historical callers).
static func _full_condition(inventory: CharacterInventory, roster: MercenaryRoster, carrying: CharacterCarrying) -> Dictionary:
	var source := carrying
	if source == null:
		source = CharacterCarrying.new(inventory, func() -> MercenaryRoster: return roster)
	return CharacterCondition.new(func() -> CharacterCarrying: return source).to_save()


## Stage 9 P01: empty carrying for the Hero and every owned Mercenary.
static func _empty_carrying(roster: MercenaryRoster) -> Dictionary:
	var empty := CharacterEquipment.new().to_save()
	var data := {CharacterCarrying.HERO_ID: empty.duplicate(true)}
	if roster != null:
		for member in roster.get_owned():
			var entry := empty.duplicate(true)
			entry["goods"] = {}
			data[member.get_id()] = entry
	return data


## S05: {character id: {hp, str, agi, int}} confirmed point counts.
static func _allocation_snapshot(characters: Dictionary) -> Dictionary:
	var snapshot := {}
	for slot in ProgressionState.SLOTS:
		var stats: CharacterStats = characters.get(slot)
		snapshot[slot] = stats.get_allocation_points() if stats != null else CharacterStats.zero_allocation()
	return snapshot


static func save(path: String, wallet: Wallet, inventory: CharacterInventory, market: MarketState, location: PlayerLocation = null, warehouses: WarehouseState = null, recovery: MarketRecovery = null, ledger: TradeCostLedger = null, progression: ProgressionState = null, characters: Dictionary = {}, roster: MercenaryRoster = null, carrying: CharacterCarrying = null, condition: CharacterCondition = null) -> bool:
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
	# P01.5: never write a roster that would not load back (P05: with its
	# pending legacy list).
	if roster != null:
		var reloaded := MercenaryRoster.from_dict(JSON.parse_string(JSON.stringify(roster.to_dict())))
		if reloaded == null or not reloaded.restore_pending(JSON.parse_string(JSON.stringify(roster.pending_to_list()))):
			return false
	# Stage 9 P01: never write carrying that would not load back, or lose the
	# state of a character that is no longer owned.
	if carrying != null:
		if carrying.has_orphans():
			return false
		var saved_roster := roster if roster != null else MercenaryRoster.new()
		if CharacterCarrying.parse_save(JSON.parse_string(JSON.stringify(carrying.to_save())), saved_roster).is_empty():
			return false
	# Stage 10 P00: never write a condition that would not load back.
	if condition != null and CharacterCondition.parse_save(JSON.parse_string(JSON.stringify(condition.to_save())), roster if roster != null else MercenaryRoster.new()).is_empty():
		return false
	var temp_path := path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(serialize(wallet, inventory, market, location, warehouses, recovery, ledger, progression, characters, roster, carrying, condition), "", true, true))
	file.close()
	var error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path), ProjectSettings.globalize_path(path))
	return error == OK


## Returns wallet/inventory/stats/market/location/warehouses/market_recovery/
## cost_ledger rebuilt from a valid save. "cargo" is
## a temporary code-compatibility alias to the same inventory object.
static func load_session(path: String) -> Dictionary:
	var inspected := inspect(path)
	return inspected["session"] if inspected["status"] == STATUS_LOADED else {}


## Stage 8 P05: {"status": STATUS_MISSING / STATUS_LOADED / STATUS_UNREADABLE,
## "reason": REASON_* for an unreadable file ("" otherwise), "session": the
## load_session() result when loaded}. A file that exists but cannot be
## loaded (not JSON, an invalid payload, a future version) is unreadable —
## never treated as "no save".
static func inspect(path: String) -> Dictionary:
	var result := {"status": STATUS_MISSING, "reason": "", "session": {}}
	if path == "" or not FileAccess.file_exists(path):
		return result
	result["status"] = STATUS_UNREADABLE
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK:
		result["reason"] = REASON_CORRUPT
		return result
	var data: Variant = parser.data
	if typeof(data) == TYPE_DICTIONARY and typeof(data.get("version")) in [TYPE_INT, TYPE_FLOAT] and float(data["version"]) > VERSION:
		result["reason"] = REASON_FUTURE
		return result
	var payload := validate(data)
	var session := _rebuild(payload) if not payload.is_empty() else {}
	if session.is_empty():
		result["reason"] = REASON_INVALID
		return result
	result["status"] = STATUS_LOADED
	result["session"] = session
	return result


## Stage 8 P05: copies the exact bytes of the file at `path` to the first
## free "<path>.unreadable-<n>" (n from 1; an existing file is never
## overwritten) and checks the copy. Returns the backup path, or "" when it
## could not be made (the original is never touched either way).
static func backup_unreadable(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty() and FileAccess.get_open_error() != OK:
		return ""
	for n in range(1, MAX_BACKUPS + 1):
		var target := path + BACKUP_SUFFIX + str(n)
		if FileAccess.file_exists(target):
			continue
		var file := FileAccess.open(target, FileAccess.WRITE)
		if file == null:
			return ""
		var stored := file.store_buffer(bytes)
		file.close()
		if not stored or FileAccess.get_file_as_bytes(target) != bytes:
			return ""
		return target
	return ""


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
	var keys: Array = {3: V3_KEYS, 4: V4_KEYS, 5: V5_KEYS, 6: V6_KEYS, 7: V7_KEYS, 8: V8_KEYS, 9: V9_KEYS, 10: V10_KEYS, 11: V11_KEYS, 12: V12_KEYS, 13: V13_KEYS, 14: V14_KEYS}[version]
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
	# P05: v12 holds the Hero only; v9-v11 the three legacy slots.
	var levels := _default_levels(ProgressionState.LEGACY_SLOTS)
	if version >= 12:
		levels = ProgressionState.parse(data["progression"])
	elif version >= 9:
		levels = ProgressionState.parse_legacy(data["progression"])
	if levels.is_empty():
		return {}
	# S05: validated against the normalised Levels above.
	var slots: Array = ProgressionState.SLOTS if version >= 12 else ProgressionState.LEGACY_SLOTS
	var allocation := _zero_allocation(slots)
	if version >= 10:
		allocation = _valid_allocation(data["allocation"], slots, levels)
		if allocation.is_empty():
			return {}
	# P01.5: the Mercenary roster (empty before v11).
	var roster := MercenaryRoster.new()
	if version >= 11:
		roster = MercenaryRoster.from_dict(data["mercenaries"])
		if roster == null:
			return {}
	# P05: v12 carries the pending legacy list; v1-v11 migrate Merc A / B.
	var migration := {"owned": [], "pending": []}
	if version >= 12:
		if not roster.restore_pending(data["pending_legacy_mercenaries"]):
			return {}
	else:
		migration = LegacyMercenaryMigration.migrate(levels, allocation, roster)
		if migration.is_empty():
			return {}
	# Stage 9 P01: v13 carries every character's carrying (validated against
	# the final owned roster); v1-v12 start empty.
	var carrying := CharacterCarrying.parse_save(_empty_carrying(roster), roster)
	if version >= 13:
		carrying = CharacterCarrying.parse_save(data["carrying"], roster)
	if carrying.is_empty():
		return {}
	# Stage 10 P00: v14 carries every character's condition (validated
	# against the final owned roster); v1-v13 have none ({}: full / alive).
	var condition := {}
	if version >= 14:
		condition = CharacterCondition.parse_save(data["condition"], roster)
		if condition.is_empty():
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
	return {"money": money, "character_id": character["id"], "strength": strength, "items": items, "market": market, "location": location, "warehouses": warehouses, "market_recovery": recovery, "cost_ledger": ledger, "progression": ProgressionState.from_hero(levels["hero"][0], levels["hero"][1]), "allocation": {"hero": allocation["hero"]}, "mercenaries": roster, "migration": migration, "carrying": carrying, "condition": condition}


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
	# P05: a legacy Cargo save also had the Stage 7 Merc A / Merc B (Lv1).
	var roster := MercenaryRoster.new()
	var migration := LegacyMercenaryMigration.migrate(_default_levels(ProgressionState.LEGACY_SLOTS), _zero_allocation(ProgressionState.LEGACY_SLOTS), roster)
	if migration.is_empty():
		return {}
	var carrying := CharacterCarrying.parse_save(_empty_carrying(roster), roster)
	if carrying.is_empty():
		return {}
	return {"condition": {}, "carrying": carrying, "money": money, "character_id": "player", "strength": CharacterStats.PROTOTYPE_DEFAULT_STRENGTH, "items": items, "market": market, "location": PlayerLocation.new(), "warehouses": WarehouseState.create_default(), "market_recovery": MarketRecovery.new(), "cost_ledger": TradeCostLedger.unknown_for(items, null), "progression": ProgressionState.new(), "allocation": {"hero": CharacterStats.zero_allocation()}, "mercenaries": roster, "migration": migration}


## P05: {slot: [START_LEVEL, 0]} (saves without progression).
static func _default_levels(slots: Array) -> Dictionary:
	var levels := {}
	for slot in slots:
		levels[slot] = [ProgressionState.START_LEVEL, 0]
	return levels


## S05: every character with 0 points (v1-v9 saves had no allocation).
static func _zero_allocation(slots: Array) -> Dictionary:
	var allocation := {}
	for slot in slots:
		allocation[slot] = CharacterStats.zero_allocation()
	return allocation


## S05: a validated {character id: {stat: points}}, or {} when the section is
## not exactly `slots` x the four allocatable stats, a count is not a whole
## number >= 0 (JSON whole floats accepted), or a character has spent more
## points than its Level (`levels`: {slot: [level, exp]}) earned. Nothing is
## clamped or repaired. P05: `slots` is the Hero (v12) or the three legacy
## slots (v10 / v11).
static func _valid_allocation(data: Variant, slots: Array, levels: Dictionary) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY or data.size() != slots.size():
		return {}
	var allocation := {}
	for slot in slots:
		if not data.has(slot) or typeof(data[slot]) != TYPE_DICTIONARY:
			return {}
		var entry: Dictionary = data[slot]
		if entry.size() != CharacterConfig.ALLOCATABLE.size() or not entry.has_all(CharacterConfig.ALLOCATABLE):
			return {}
		var points := {}
		var spent := 0
		for stat in CharacterConfig.ALLOCATABLE:
			var value := _to_int(entry[stat])
			if value < 0 or value > CharacterConfig.MAX_STAT:
				return {}
			points[stat] = value
			spent += value
		if spent > CharacterStats.earned_points_for(levels[slot][0]):
			return {}
		allocation[slot] = points
	return allocation


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
	if wallet.get_balance() != payload["money"] or payload["market"] == null or payload["location"] == null or payload["warehouses"] == null or payload["market_recovery"] == null or payload["cost_ledger"] == null or payload["progression"] == null or payload["allocation"] == null or payload["mercenaries"] == null or payload["carrying"] == null or (payload["carrying"] as Dictionary).is_empty():
		return {}
	# Stage 9 P01: the characters' carrying on the loaded roster and backpack.
	var roster: MercenaryRoster = payload["mercenaries"]
	var carrying := CharacterCarrying.new(inventory, func() -> MercenaryRoster: return roster)
	carrying.restore_save(payload["carrying"])
	return {"condition": (payload["condition"] as Dictionary).duplicate(true), "carrying": carrying, "wallet": wallet, "inventory": inventory, "cargo": inventory, "character_stats": stats, "market": payload["market"], "location": payload["location"], "warehouses": payload["warehouses"], "market_recovery": payload["market_recovery"], "cost_ledger": payload["cost_ledger"], "progression": payload["progression"], "allocation": payload["allocation"], "mercenaries": payload["mercenaries"], "migration": payload["migration"]}


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
