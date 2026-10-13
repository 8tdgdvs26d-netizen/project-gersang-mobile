class_name OnlineCombatAdapter
extends RefCounted

## VS-01 WP01-E (isolated Online TEST, Hero only): the Godot side of the E1
## server contract (vs01e_encounter_begin / _claim / _abandon /
## vs01e_progression_get). It never computes or shows EXP itself: the Hero
## Level / EXP it exposes come only from server answers (receipts or reads),
## and a newer server revision always wins.
##
## Pending (approved S6: RAM only): a battle result becomes ONE pending claim
## {key, ticket_id, outcome, kills, hero_alive} for the signed-in account. It
## is resent with the SAME key and payload until the server answers with a
## receipt (applied or replayed) or a final refusal. Transient or uncertain
## answers (too_early, rate_limited, conflict_retry_exhausted, no answer,
## storage_unavailable, a reply after sign-out) keep it. A superseded device
## keeps it too; it is resent after the player takes the session back
## (policy A, approved S5). The same rules hold for an explicit abandon.
## Pending claims of an account that signs out stay filed under that account.

const RPC_BEGIN := "vs01e_encounter_begin"
const RPC_CLAIM := "vs01e_encounter_claim"
const RPC_ABANDON := "vs01e_encounter_abandon"
const RPC_PROGRESSION := "vs01e_progression_get"

## Server table ids (WorldLayout.PROTOTYPE_GROUPS).
const GROUP_IDS := ["prototype_monster_01", "prototype_monster_02", "prototype_monster_03"]

## How a claim / abandon answer is handled.
const CONFIRMED := "confirmed"      # a receipt: the server state is known
const KEEP := "keep"                # transient / uncertain: resend the same key later
const SUPERSEDED := "superseded"    # keep; resend after taking the session back
const FINAL := "final"              # refused for good: drop the pending command

## Server refusals that say "not now", never "no".
const TRANSIENT_REASONS := ["too_early", "rate_limited", "rate_limit_contention", "conflict_retry_exhausted"]

var _client: OnlineProgressClient
## The last server-confirmed {level, exp, exp_to_next, revision}, or {}.
var _progression := {}
## The last known unresolved ticket view (server), or {}.
var _unresolved := {}
## The ticket this device began and has not settled (begin answer), or {}.
var _ticket := {}
## user_id -> pending claim / abandon {"kind", "key", "ticket_id", "payload"}.
var _pending_by_user := {}
## The last server time seen (progression read), 0 if none.
var _server_time_ms := 0


func _init(client: OnlineProgressClient) -> void:
	_client = client


func get_client() -> OnlineProgressClient:
	return _client


## The Hero's server-confirmed progression ({} before the first answer).
func get_confirmed_progression() -> Dictionary:
	return _progression.duplicate(true)


func get_unresolved_ticket() -> Dictionary:
	return _unresolved.duplicate(true)


func get_ticket() -> Dictionary:
	return _ticket.duplicate(true)


## The signed-in account's pending claim / abandon ({} when none).
func get_pending() -> Dictionary:
	return (_pending_by_user.get(_client.get_user_id(), {}) as Dictionary).duplicate(true)


func has_pending() -> bool:
	return not get_pending().is_empty()


## Hero Base + Growth stats at the server Level (approved S8: no allocation).
func hero_stats() -> CharacterStats:
	var stats := CharacterStats.for_character("hero")
	stats.apply_level(int(_progression.get("level", ProgressionState.START_LEVEL)))
	return stats


## Reads the server progression and the unresolved ticket.
func refresh() -> Dictionary:
	var result := await _client.gameplay_rpc(RPC_PROGRESSION, {})
	if result["status"] == OnlineProgressClient.OK:
		var data: Dictionary = result["data"]
		_offer(data.get("progression"))
		_unresolved = (data.get("unresolved_ticket") as Dictionary).duplicate(true) if typeof(data.get("unresolved_ticket")) == TYPE_DICTIONARY else {}
		_server_time_ms = int(data.get("server_time_ms", 0))
	return result


## Asks the server for an encounter ticket for `group_ids` (1-3 groups).
func begin_encounter(group_ids: Array) -> Dictionary:
	var result := await _client.gameplay_rpc(RPC_BEGIN, {"group_ids": group_ids.duplicate()})
	if result["status"] == OnlineProgressClient.OK:
		_ticket = (result["data"]["ticket"] as Dictionary).duplicate(true)
		_unresolved = _ticket.duplicate(true)
		_offer(result["data"].get("progression"))
	return result


## Files the finished battle as this account's pending claim (once per
## ticket: a second call for the same ticket keeps the first payload) and
## sends it. Returns the answer with "handling" (CONFIRMED / KEEP / ...).
func submit_battle(battle: CombatBattle) -> Dictionary:
	var claim := claim_from_battle(battle)
	if claim.is_empty() or _ticket.is_empty():
		return {"status": OnlineProgressClient.REJECTED, "reason": "no_ticket", "handling": FINAL}
	var pending := get_pending()
	if pending.is_empty() or pending["ticket_id"] != _ticket["ticket_id"]:
		var payload := claim.duplicate()
		payload["ticket_id"] = _ticket["ticket_id"]
		_set_pending({"kind": "claim", "key": OnlineProgressClient.new_idempotency_key(), "ticket_id": _ticket["ticket_id"], "payload": payload})
	return await resend_pending()


## Resends the pending claim / abandon with its original key and payload.
func resend_pending() -> Dictionary:
	var pending := get_pending()
	if pending.is_empty():
		return {"status": OnlineProgressClient.REJECTED, "reason": "nothing_pending", "handling": FINAL}
	var user := _client.get_user_id()
	var payload: Dictionary = (pending["payload"] as Dictionary).duplicate(true)
	payload["idempotency_key"] = pending["key"]
	var rpc := RPC_CLAIM if pending["kind"] == "claim" else RPC_ABANDON
	var result := await _client.gameplay_rpc(rpc, payload)
	result["handling"] = classify(result)
	# The answer belongs to the account that sent it (S01): never file it
	# under another account that signed in meanwhile.
	if result.get("stale", false) or user != _client.get_user_id():
		result["handling"] = KEEP
		return result
	if result["handling"] == CONFIRMED:
		_offer(result["data"].get("progression"))
		result["receipt"] = result["data"]["receipt"]
		result["replayed"] = result["data"]["replayed"]
		_clear_pending_for(pending["ticket_id"])
	elif result["handling"] == FINAL:
		_clear_pending_for(pending["ticket_id"])
	return result


## Explicit, player-confirmed abandon of `ticket_id` (approved R-2 / MC-2).
## A pending claim for that ticket is replaced: the player chose to give it up.
func abandon(ticket_id: String) -> Dictionary:
	var pending := get_pending()
	if pending.is_empty() or pending["kind"] != "abandon" or pending["ticket_id"] != ticket_id:
		_set_pending({"kind": "abandon", "key": OnlineProgressClient.new_idempotency_key(), "ticket_id": ticket_id,
			"payload": {"ticket_id": ticket_id, "confirm": true}})
	return await resend_pending()


## How an answer is handled (see the header).
static func classify(result: Dictionary) -> String:
	match result.get("status"):
		OnlineProgressClient.OK:
			return CONFIRMED
		OnlineProgressClient.UNCERTAIN:
			return KEEP
		OnlineProgressClient.NOT_SIGNED_IN, OnlineProgressClient.NO_GAMEPLAY_SESSION:
			return KEEP
	var reason := String(result.get("reason", ""))
	if reason == OnlineProgressClient.SUPERSEDED_REASON:
		return SUPERSEDED
	if reason in TRANSIENT_REASONS:
		return KEEP
	return FINAL


## {outcome, kills, hero_alive} of a finished Hero-only battle, or {}.
static func claim_from_battle(battle: CombatBattle) -> Dictionary:
	if battle == null or not battle.is_over() or battle.get_result() == null:
		return {}
	var outcome := {BattleResult.Outcome.VICTORY: "victory", BattleResult.Outcome.RETREAT: "retreat", BattleResult.Outcome.DEFEAT: "defeat"}[battle.get_result().outcome] as String
	var kills := battle.get_enemies().filter(func(enemy: CombatUnit) -> bool: return not enemy.alive).size()
	var hero := battle.get_hero()
	return {"outcome": outcome, "kills": kills, "hero_alive": hero != null and hero.alive}


## Drops everything of the signed-out device view except the pending claims
## filed per account (they are resent when that account signs in again).
func forget_view() -> void:
	_progression = {}
	_unresolved = {}
	_ticket = {}


func _set_pending(command: Dictionary) -> void:
	_pending_by_user[_client.get_user_id()] = command


func _clear_pending_for(ticket_id: String) -> void:
	var user := _client.get_user_id()
	if _pending_by_user.has(user) and _pending_by_user[user]["ticket_id"] == ticket_id:
		_pending_by_user.erase(user)
	if _ticket.get("ticket_id", "") == ticket_id:
		_ticket = {}
	if _unresolved.get("ticket_id", "") == ticket_id:
		_unresolved = {}


## Accepts a server progression view only if it is not older than the one held.
func _offer(view: Variant) -> void:
	if typeof(view) != TYPE_DICTIONARY:
		return
	if not _progression.is_empty() and int(view.get("revision", -1)) < int(_progression.get("revision", -1)):
		return
	_progression = {"level": int(view["level"]), "exp": int(view["exp"]), "exp_to_next": int(view["exp_to_next"]), "revision": int(view["revision"])}
