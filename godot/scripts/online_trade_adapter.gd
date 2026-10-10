class_name OnlineTradeAdapter
extends RefCounted

## VS-01 WP01-B — Godot <-> Nakama online trade integration adapter.
##
## Bridges the existing OnlineProgressClient (PR #132; no second account or
## trade system) to the existing Godot domain types for ONE representative
## good. Nakama decides every buy / sell; this adapter never prices, checks
## or applies a trade itself. Its Wallet / CharacterInventory are a MIRROR
## rebuilt only from server-confirmed progress, as fresh objects that belong
## to nobody else: never the game scene's, never the local save's, never saved.
##
## Results use TradeService's shape and reason codes ("success",
## "total_value", "reason", "unit_price") so a later, separately approved UI
## WP can show them; the online-only fields say how sure the outcome is.
##
## WP01-B limits:
## - Not wired into the main scene script, scenes, buttons or saves.
## - Pending commands live in the client's memory only. An app kill loses
##   them: the server state stays correct, but the killed app's uncertain
##   command can no longer be matched to its receipt (see the WP01-B doc).

## The one good WP01-B integrates (Prototype test good, capacity cost 1).
const REPRESENTATIVE_GOOD_ID := "test_good_01"
const OUT_OF_SCOPE_REASON := "not_in_wp01b_scope"

## Emitted after the mirror was rebuilt from a server-confirmed view.
signal confirmed_state_changed(revision: int)

var _client: OnlineProgressClient
var _wallet: Wallet
var _inventory: CharacterInventory
var _revision := -1
var _mirror_consistent := true


func _init(client: OnlineProgressClient) -> void:
	_client = client
	_rebuild_mirror()


func get_client() -> OnlineProgressClient:
	return _client


## True once a server-confirmed view exists. Before that the mirror is
## null, so a default Wallet can never be mistaken for server data.
func has_confirmed_state() -> bool:
	return _wallet != null


## Mirror of the server-confirmed money, or null before any confirmation. A
## fresh Wallet; editing it changes nothing on the server and is replaced at
## the next confirmation.
func get_wallet() -> Wallet:
	return _wallet


## Mirror of the server-confirmed backpack goods (fresh CharacterInventory),
## or null before any confirmation.
func get_inventory() -> CharacterInventory:
	return _inventory


func get_confirmed_revision() -> int:
	return _revision


## False if a server view could not be represented by the domain types
## (for example more goods than the Prototype capacity). Never repaired.
func is_mirror_consistent() -> bool:
	return _mirror_consistent


## The server's current quote for the representative good in a city, or {}.
func get_quote(city_id: String) -> Dictionary:
	var quotes: Variant = _client.get_confirmed_progress().get("quotes", {})
	if typeof(quotes) != TYPE_DICTIONARY or typeof(quotes.get(city_id)) != TYPE_DICTIONARY:
		return {}
	var quote: Variant = quotes[city_id].get(REPRESENTATIVE_GOOD_ID)
	return (quote as Dictionary).duplicate() if typeof(quote) == TYPE_DICTIONARY else {}


func begin() -> Dictionary:
	var result := await _client.begin_gameplay_session()
	_rebuild_mirror()
	return result


func refresh() -> Dictionary:
	var result := await _client.refresh_progress()
	_rebuild_mirror()
	return result


func buy(city_id: String, quantity: int) -> Dictionary:
	return await _trade("buy", city_id, REPRESENTATIVE_GOOD_ID, quantity)


func sell(city_id: String, quantity: int) -> Dictionary:
	return await _trade("sell", city_id, REPRESENTATIVE_GOOD_ID, quantity)


## Same as buy / sell for any good id, so the scope guard can be tested:
## anything but the representative good is refused locally, never sent.
func trade_good(action: String, city_id: String, good_id: String, quantity: int) -> Dictionary:
	return await _trade(action, city_id, good_id, quantity)


## Resends every pending command with its original idempotency key.
func recover() -> Array:
	var results := []
	for raw in await _client.recover_pending():
		results.append(_to_trade_result(raw))
	_rebuild_mirror()
	return results


func pending_count() -> int:
	return _client.get_pending_commands().size()


func _trade(action: String, city_id: String, good_id: String, quantity: int) -> Dictionary:
	if good_id != REPRESENTATIVE_GOOD_ID or not action in ["buy", "sell"]:
		var refused := {"success": false, "total_value": 0, "reason": OUT_OF_SCOPE_REASON, "unit_price": 0,
			"online_status": OnlineProgressClient.REJECTED, "pending": false, "replayed": false, "idempotency_key": ""}
		return refused
	var raw: Dictionary
	if action == "buy":
		raw = await _client.buy(city_id, good_id, quantity)
	else:
		raw = await _client.sell(city_id, good_id, quantity)
	var result := _to_trade_result(raw)
	_rebuild_mirror()
	return result


## Client outcome -> TradeService-shaped result. "success" is true ONLY for a
## server receipt that applied the order.
func _to_trade_result(raw: Dictionary) -> Dictionary:
	var receipt: Dictionary = raw.get("receipt", {})
	var applied: bool = raw.get("status") == OnlineProgressClient.OK and receipt.get("status") == "applied"
	var reason: String = receipt.get("reason", "") if raw.get("status") == OnlineProgressClient.OK else String(raw.get("reason", ""))
	return {
		"success": applied,
		"total_value": int(receipt.get("total", 0)),
		"reason": reason,
		"unit_price": int(receipt.get("unit_price", 0)),
		"online_status": raw.get("status"),
		"pending": bool(raw.get("pending", false)),
		"replayed": bool(raw.get("replayed", false)),
		"idempotency_key": String(raw.get("idempotency_key", "")),
		"receipt": receipt.duplicate(true),
	}


## Rebuilds the mirror from the client's server-confirmed view only.
func _rebuild_mirror() -> void:
	var view := _client.get_confirmed_progress()
	if view.is_empty():
		_wallet = null
		_inventory = null
		_mirror_consistent = true
		_revision = -1
		return
	var wallet := Wallet.new()
	var inventory := CharacterInventory.new("online_mirror", CharacterStats.new())
	var consistent := true
	var money := int(view.get("money", 0))
	var delta := money - wallet.get_balance()
	if delta < 0:
		consistent = wallet.spend(-delta) and consistent
	elif delta > 0:
		consistent = wallet.add(delta) and consistent
	var backpack: Variant = view.get("backpack", {})
	if typeof(backpack) == TYPE_DICTIONARY:
		for good_id in backpack:
			consistent = inventory.add(good_id, int(backpack[good_id])) and consistent
	else:
		consistent = false
	_wallet = wallet
	_inventory = inventory
	_mirror_consistent = consistent
	var revision := int(view.get("revision", -1))
	if revision != _revision:
		_revision = revision
		confirmed_state_changed.emit(revision)
