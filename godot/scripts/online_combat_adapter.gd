class_name OnlineCombatAdapter
extends RefCounted

## VS-01 WP01-E (isolated Online TEST, Hero only): the Godot side of the E1
## server contract (vs01e_encounter_begin / _claim / _abandon /
## vs01e_progression_get). It never computes or shows EXP itself: the Hero
## Level / EXP it exposes come only from server answers (receipts or reads),
## and a newer server revision always wins.
##
## Pending (WP01-H E2; the WP01-E RAM-only pending of S6 is REPLACED): a
## battle result becomes ONE pending claim {key, ticket_id, outcome, kills,
## hero_alive} of the signed-in account, written to the client's Pending
## Store BEFORE the first claim RPC (a failed write sends nothing). It is
## resent only with the SAME key and payload. The same holds for an explicit
## abandon. One pending command per account: a pending claim is NEVER
## replaced by a new abandon or by another ticket's claim (B-4A).
##
## Answers: a receipt clears it only if it is, field for field, the E1
## server receipt (contract myrial.vs01.wp01e.receipt v1, 22 fields) of this
## kind / key / ticket / account / claim and request hash (FIX-03). The
## server's final "no" (ticket_expired, ticket_abandoned,
## ticket_already_claimed, ticket_not_found) clears it. A conflict or trust
## error (claim_locked, idempotency_key_reused, wp01e_* not trusted /
## inconsistent, invalid_claim, a mismatching receipt) QUARANTINES it; if
## that mark cannot be written the account is put on HOLD (FIX-04). Anything
## else keeps it (fail closed). Superseded keeps it until the session is
## taken back (policy A).
##
## Fresh process (FIX-02): a pending command loaded from the store is
## UNVERIFIED and is never resent before recover() has read the server's
## recorded intent and checked the ORIGINAL ticket / key / claim:
## - "recorded" intent: must equal the local claim exactly (adopted, written
##   first, when there is no local command); a difference -> quarantine;
## - no intent: the local command is resent only when the server's open
##   ticket is its ticket (C-A1) or the server shows no open ticket (the
##   original key can then only replay its receipt or be refused finally);
## - "inconsistent", a malformed intent or a ticket mismatch -> NEEDS CHECK;
##   with no local command a claim-less TICKET HOLD is written (FIX-05: no
##   key or claim is ever invented; no abandon is sent);
## - a server without recorded_intent (old E1), a failed or untrusted read,
##   superseded: nothing is resent, nothing is cleared.
## EXP is never computed or granted locally.

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

## WP01-H.
const CONFLICT := "conflict"        # kept, quarantined: no automatic retry / clearing
const BLOCKED := "blocked"          # refused locally, nothing sent
const STORE_FINAL_REASONS := ["ticket_expired", "ticket_abandoned", "ticket_already_claimed", "ticket_not_found"]
const STORE_CONFLICT_REASONS := ["claim_locked", "idempotency_key_reused", "wp01e_intent_inconsistent", "wp01e_object_not_trusted",
	"wp01e_open_ticket_missing", "server_object_not_trusted", "progress_corrupt", "invalid_claim"]
const PENDING_COMBAT_UNRESOLVED := "pending_combat_unresolved"
const PENDING_CLAIM_UNRESOLVED := "pending_claim_unresolved"
const PENDING_NEEDS_CHECK := "pending_combat_needs_check"
const INTENT_MISMATCH := "recorded_intent_mismatch"
const INTENT_INCONSISTENT := "recorded_intent_inconsistent"
const PENDING_UNVERIFIED := "pending_combat_unverified"
const RECOVERY_UNSUPPORTED := "recovery_capability_missing"
const TICKET_HOLD := "ticket_hold"
const RECEIPT_CONTRACT := "myrial.vs01.wp01e.receipt"
const RECEIPT_KEYS := ["contract", "contract_version", "kind", "idempotency_key", "request_hash", "user_id",
	"gameplay_session_id", "ticket_id", "status", "outcome", "kills_claimed", "kills_accepted", "hero_alive",
	"exp_awarded", "level_before", "exp_before", "level_after", "exp_after", "progression_revision",
	"cooldown_groups", "intent_first_seen_at_ms", "server_time_ms"]

var _client: OnlineProgressClient
## The last server-confirmed {level, exp, exp_to_next, revision}, or {}.
var _progression := {}
## The last known unresolved ticket view (server), or {}.
var _unresolved := {}
## The ticket this device began and has not settled (begin answer), or {}.
var _ticket := {}
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
	return _client.get_combat_pending()


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


## Files the finished battle as this account's pending claim (written to
## the store first; once per ticket: the first payload is kept) and sends
## it. Returns the answer with "handling" (CONFIRMED / KEEP / ...).
func submit_battle(battle: CombatBattle) -> Dictionary:
	var claim := claim_from_battle(battle)
	if claim.is_empty() or _ticket.is_empty():
		return {"status": OnlineProgressClient.REJECTED, "reason": "no_ticket", "handling": FINAL}
	return await _submit_durable(claim)


## Resends the pending claim / abandon with its original key and payload
## (only once it is verified in this process, FIX-02).
func resend_pending() -> Dictionary:
	var pending := get_pending()
	if pending.is_empty():
		return {"status": OnlineProgressClient.REJECTED, "reason": "nothing_pending", "handling": FINAL}
	return await _resend_durable(pending)


## Explicit, player-confirmed abandon of `ticket_id` (approved R-2 / MC-2).
## Never replaces a pending claim or a ticket hold (WP01-H, B-4A).
func abandon(ticket_id: String) -> Dictionary:
	return await _abandon_durable(ticket_id)


## FIX-02: recovery after a restart / takeover. Reads progression FIRST and
## checks the ORIGINAL ticket / key / claim before anything is resent.
## {"status", "reason", "handling"}.
func recover() -> Dictionary:
	var block := _client.store_block_reason()
	if not block.is_empty():
		return _blocked(block)
	var read := await refresh()
	if read["status"] != OnlineProgressClient.OK:
		# Trust error / no answer / superseded: nothing is guessed, resent or cleared.
		return {"status": read["status"], "reason": read.get("reason", ""), "handling": KEEP}
	var data: Dictionary = read["data"]
	var local := get_pending()
	var server_ticket := String(_unresolved.get("ticket_id", ""))
	if not data.has("recorded_intent"):
		# Old server: the original claim cannot be checked -> fail closed.
		if local.is_empty():
			return {"status": OnlineProgressClient.OK, "reason": "nothing_pending", "handling": CONFIRMED}
		return _blocked(RECOVERY_UNSUPPORTED)
	var intent: Variant = data["recorded_intent"]
	if not local.is_empty() and local["kind"] == TICKET_HOLD:
		return _blocked(PENDING_NEEDS_CHECK)  # never released automatically
	if intent == null:
		if local.is_empty():
			return {"status": OnlineProgressClient.OK, "reason": "nothing_pending", "handling": CONFIRMED}
		if local.get("state") != OnlinePendingStore.STATE_PENDING:
			return _blocked(PENDING_NEEDS_CHECK)
		# C-A1: the server holds no intent. The original command may only be
		# resent for the server's open ticket, or when the server shows no open
		# ticket (the original key then replays or is refused finally).
		if server_ticket != "" and server_ticket != local["ticket_id"]:
			return _mark_local(local, local["ticket_id"], OnlinePendingStore.STATE_NEEDS_CHECK, INTENT_INCONSISTENT)
		_client.mark_combat_pending_verified()
		return await _resend_durable(get_pending())
	if typeof(intent) != TYPE_DICTIONARY or intent.get("status") != "recorded" or intent.get("ticket_id") != server_ticket \
			or server_ticket == "" or not _intent_shape_ok(intent):
		var ticket_id := String(intent.get("ticket_id", "")) if typeof(intent) == TYPE_DICTIONARY else ""
		if not local.is_empty():
			return _mark_local(local, local["ticket_id"], OnlinePendingStore.STATE_NEEDS_CHECK, INTENT_INCONSISTENT)
		return _hold_ticket(server_ticket if server_ticket != "" else ticket_id, INTENT_INCONSISTENT)
	var from_server := {"kind": "claim", "key": intent["idempotency_key"], "ticket_id": server_ticket,
		"payload": {"ticket_id": server_ticket, "outcome": intent["claim"]["outcome"], "kills": int(intent["claim"]["kills"]), "hero_alive": intent["claim"]["hero_alive"]},
		"state": OnlinePendingStore.STATE_PENDING, "reason": ""}
	if local.is_empty():
		if not _client.set_combat_pending(from_server):
			return _blocked(OnlineProgressClient.STORE_WRITE_FAILED)
	elif local["kind"] != "claim" or local["ticket_id"] != server_ticket or local["key"] != from_server["key"] or local["payload"] != from_server["payload"]:
		return _mark_local(local, local["ticket_id"], OnlinePendingStore.STATE_QUARANTINED, INTENT_MISMATCH)
	elif local.get("state") != OnlinePendingStore.STATE_PENDING:
		return _blocked(PENDING_NEEDS_CHECK)
	_client.mark_combat_pending_verified()
	return await _resend_durable(get_pending())


func _intent_shape_ok(intent: Dictionary) -> bool:
	var c: Variant = intent.get("claim")
	if typeof(c) != TYPE_DICTIONARY or not OnlinePendingStore._keys_exactly(intent, ["status", "ticket_id", "idempotency_key", "claim", "first_seen_at_ms"]):
		return false
	if not OnlinePendingStore._keys_exactly(c, ["outcome", "kills", "hero_alive"]):
		return false
	var entry := {"kind": "claim", "key": intent.get("idempotency_key"), "ticket_id": intent.get("ticket_id"),
		"payload": {"ticket_id": intent.get("ticket_id"), "outcome": c.get("outcome"), "kills": c.get("kills"), "hero_alive": c.get("hero_alive")},
		"state": OnlinePendingStore.STATE_PENDING, "reason": ""}
	return OnlinePendingStore.new().valid_combat_entry(entry)


## Marks the local command (kept as evidence). FIX-04: if the mark cannot be
## written, the account is put on HOLD (or blocked for this process).
func _mark_local(local: Dictionary, ticket_id: String, state: String, reason: String) -> Dictionary:
	if not local.is_empty() and local["ticket_id"] == ticket_id:
		var marked := local.duplicate(true)
		marked["state"] = state
		marked["reason"] = reason
		_client.mark_combat(marked)  # journal + live file; HOLD if both fail (FIX-04)
	return {"status": OnlineProgressClient.REJECTED, "reason": reason, "handling": CONFLICT, "ticket_id": ticket_id}


## FIX-05: a ticket blocked for review with NO local command: a claim-less
## hold is written (no key, no claim, no abandon). If it cannot be written,
## or the ticket id is not usable, the account is held instead.
func _hold_ticket(ticket_id: String, reason: String) -> Dictionary:
	var entry := {"kind": TICKET_HOLD, "ticket_id": ticket_id, "state": OnlinePendingStore.STATE_NEEDS_CHECK, "reason": reason}
	if OnlinePendingStore.new().valid_combat_entry(entry):
		_client.mark_combat(entry)  # journal + live file; HOLD if both fail
	else:
		_client.hold_account(reason)  # no usable ticket id: hold the account
	return {"status": OnlineProgressClient.REJECTED, "reason": reason, "handling": CONFLICT, "ticket_id": ticket_id}


func _submit_durable(claim: Dictionary) -> Dictionary:
	var block := _client.store_block_reason()
	if not block.is_empty():
		return _blocked(block)
	var pending := get_pending()
	var ticket_id: String = _ticket["ticket_id"]
	if not pending.is_empty():
		if pending["ticket_id"] != ticket_id or pending["kind"] != "claim":
			return _blocked(PENDING_COMBAT_UNRESOLVED)  # never replaced (B-4A)
		return await _resend_durable(pending)  # same ticket: the FIRST payload is kept
	var payload := claim.duplicate()
	payload["ticket_id"] = ticket_id
	var entry := {"kind": "claim", "key": OnlineProgressClient.new_idempotency_key(), "ticket_id": ticket_id, "payload": payload,
		"state": OnlinePendingStore.STATE_PENDING, "reason": ""}
	if not _client.set_combat_pending(entry):
		return _blocked(OnlineProgressClient.STORE_WRITE_FAILED)  # PR-04: nothing sent
	return await _resend_durable(entry)


func _abandon_durable(ticket_id: String) -> Dictionary:
	var block := _client.store_block_reason()
	if not block.is_empty():
		return _blocked(block)
	var pending := get_pending()
	if not pending.is_empty():
		if pending["kind"] == "abandon" and pending["ticket_id"] == ticket_id:
			return await _resend_durable(pending)
		# A pending claim / ticket hold is never overwritten by an abandon.
		return _blocked(PENDING_CLAIM_UNRESOLVED if pending["kind"] == "claim" else PENDING_COMBAT_UNRESOLVED)
	var entry := {"kind": "abandon", "key": OnlineProgressClient.new_idempotency_key(), "ticket_id": ticket_id,
		"payload": {"ticket_id": ticket_id, "confirm": true}, "state": OnlinePendingStore.STATE_PENDING, "reason": ""}
	if not _client.set_combat_pending(entry):
		return _blocked(OnlineProgressClient.STORE_WRITE_FAILED)
	return await _resend_durable(entry)


func _resend_durable(pending: Dictionary) -> Dictionary:
	var block := _client.store_block_reason()
	if not block.is_empty():
		return _blocked(block)
	if pending.get("kind") == TICKET_HOLD or pending.get("state") != OnlinePendingStore.STATE_PENDING:
		return _blocked(PENDING_NEEDS_CHECK)  # no automatic retry
	if not _client.is_combat_pending_verified():
		return _blocked(PENDING_UNVERIFIED)  # FIX-02: recover() first
	var user := _client.get_user_id()
	var payload: Dictionary = (pending["payload"] as Dictionary).duplicate(true)
	payload["idempotency_key"] = pending["key"]
	var rpc := RPC_CLAIM if pending["kind"] == "claim" else RPC_ABANDON
	var result := await _client.gameplay_rpc(rpc, payload)
	if result.get("stale", false) or user != _client.get_user_id():
		result["handling"] = KEEP
		return result
	var reason := String(result.get("reason", ""))
	if result["status"] == OnlineProgressClient.OK:
		var receipt: Variant = result["data"].get("receipt")
		if not _receipt_matches(receipt, pending, user):
			_mark_local(pending, pending["ticket_id"], OnlinePendingStore.STATE_QUARANTINED, OnlineProgressClient.RECEIPT_MISMATCH_REASON)
			result["status"] = OnlineProgressClient.REJECTED
			result["reason"] = OnlineProgressClient.RECEIPT_MISMATCH_REASON
			result["handling"] = CONFLICT
			return result
		result["handling"] = CONFIRMED
		_offer(result["data"].get("progression"))
		result["receipt"] = receipt
		result["replayed"] = result["data"]["replayed"]
		_clear_pending_for(pending["ticket_id"])
		return result
	if reason in STORE_CONFLICT_REASONS:
		_mark_local(pending, pending["ticket_id"], OnlinePendingStore.STATE_QUARANTINED, reason)
		result["handling"] = CONFLICT
		return result
	if result["status"] == OnlineProgressClient.REJECTED and reason in STORE_FINAL_REASONS:
		result["handling"] = FINAL
		_clear_pending_for(pending["ticket_id"])
		return result
	result["handling"] = SUPERSEDED if reason == OnlineProgressClient.SUPERSEDED_REASON else KEEP
	return result


static func _w(v: Variant, minimum: int) -> bool:
	return OnlinePendingStore._is_whole_any(v, minimum)


## FIX-03: the E1 encounter receipt, field for field (wp01e.ts E_RECEIPT_KEYS,
## contract v1), of THIS kind / key / ticket / account, with the request hash
## the server computes and the claim (or abandon) it was sent with.
static func _receipt_matches(receipt: Variant, pending: Dictionary, user: String) -> bool:
	if typeof(receipt) != TYPE_DICTIONARY:
		return false
	var r: Dictionary = receipt
	if not OnlinePendingStore._keys_exactly(r, RECEIPT_KEYS):
		return false
	if r["contract"] != RECEIPT_CONTRACT or not _w(r["contract_version"], 1) or int(r["contract_version"]) != 1:
		return false
	if r["kind"] != pending["kind"] or r["idempotency_key"] != pending["key"] or r["ticket_id"] != pending["ticket_id"] \
			or r["user_id"] != user or r["status"] != "applied" or typeof(r["gameplay_session_id"]) != TYPE_STRING:
		return false
	for f in ["exp_awarded", "exp_before", "exp_after", "progression_revision", "server_time_ms"]:
		if not _w(r[f], 0):
			return false
	if not _w(r["level_before"], 1) or not _w(r["level_after"], 1) or int(r["level_after"]) < int(r["level_before"]):
		return false
	if typeof(r["cooldown_groups"]) != TYPE_ARRAY or not _w(r["intent_first_seen_at_ms"], -1):
		return false
	var p: Dictionary = pending["payload"]
	if pending["kind"] == "abandon":
		return r["request_hash"] == "abandon|" + pending["ticket_id"] and r["outcome"] == null and r["kills_claimed"] == null \
			and r["kills_accepted"] == null and r["hero_alive"] == null and int(r["exp_awarded"]) == 0 \
			and int(r["level_after"]) == int(r["level_before"]) and int(r["exp_after"]) == int(r["exp_before"])
	var kills := int(p["kills"])
	var hash := "claim|%s|%s|%d|%s" % [pending["ticket_id"], p["outcome"], kills, "1" if p["hero_alive"] else "0"]
	return r["request_hash"] == hash and r["outcome"] == p["outcome"] and r["hero_alive"] == p["hero_alive"] \
		and _w(r["kills_claimed"], 0) and int(r["kills_claimed"]) == kills and _w(r["kills_accepted"], 0) and int(r["kills_accepted"]) == kills


static func _blocked(reason: String) -> Dictionary:
	return {"status": OnlineProgressClient.REJECTED, "reason": reason, "handling": BLOCKED, "local": true}


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


func _clear_pending_for(ticket_id: String) -> void:
	_client.clear_combat_pending(ticket_id)  # a failed write keeps it (replays later)
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
