class_name OnlineProgressClient
extends Node

## VS-01 WP01 — Godot side of the Nakama progress authority (approved D1–D5).
##
## Isolated adapter: no scene, UI, local save or gameplay service references
## it yet, so the existing offline Core Loop is unchanged. The server decides
## every money / goods / market change; this client only sends commands and
## caches the last server-confirmed view (A5: local data is cache only). It
## never sends money, prices, stock or capacity, and never applies a trade
## locally.
##
## Command recovery: every trade carries a client-generated idempotency key.
## If no server answer arrives (network loss, app kill), the command stays
## PENDING. Since WP01-H it is never resent with vs01_trade (FIX-01): the
## WP01-B RAM-only resend path has been REMOVED.
##
## WP01-H (E2) durable recovery. EVERY client owns a Pending Store (a default
## OnlinePendingStore is created on construction; enable_pending_store() can
## only replace it, e.g. in tests). There is no store-less path:
## - a new trade is written to the per-account OnlinePendingStore BEFORE
##   vs01_trade is sent; if that write fails nothing is sent (PR-04);
## - an unknown outcome is never resent with vs01_trade: recover_pending()
##   asks vs01_trade_resolve with the ORIGINAL key and command, which
##   replays the one recorded receipt or voids the key (Blueprint §6);
## - only a receipt that matches the key, the account and the command clears
##   the entry; applied / rejected / voided are told apart;
## - receipt_unrecognized / receipt_not_trusted / idempotency_key_reused or a
##   mismatching receipt -> the entry is QUARANTINED (kept, no automatic
##   retry); resolve_command_invalid -> NEEDS CHECK (kept); any other refusal,
##   an unidentified gRPC 13, no answer or a server without Resolve -> kept
##   pending (fail closed, never a fallback to vs01_trade);
## - B-4A: while the account has any pending / needs-check / quarantined
##   trade, new trades are refused locally; an untrusted store blocks all new
##   trade and combat writes of that account;
## - the store is the only source after a restart; import_pending_commands()
##   is always refused (RAM import was the unsafe WP01-B path);
## - a quarantine / needs-check mark that cannot be written puts a durable
##   HOLD on the account (OnlinePendingStore.hold_account); if even that fails
##   the account is blocked for the rest of this process (FIX-04);
## - only receipts in an exactly known server format are trusted: Legacy v1
##   (18 fields, request hash, rule-consistent money / cargo deltas) or
##   Voided v2 (20 fields, contract version 2, nothing moved) (FIX-03).
##
## Consistency of the confirmed cache (WP01-B-S01). Answers can arrive late or
## in any order, so the cache only moves FORWARD:
## - a view is accepted only if its server revision is newer than the cached
##   one, or, at the same revision (same money and goods by definition; only
##   time-dependent quotes can differ), if it answers a LATER-issued request;
## - an answer to a request sent before a sign-out, an account switch or a
##   sign-in of the same account again (an older "account epoch") never
##   touches the current state; it is reported as uncertain and its command
##   stays pending for its own account;
## - pending commands belong to the account that sent them; another account
##   never sees or resends them;
## - a "superseded" answer counts only for the gameplay session it was sent
##   under (session policy A is unchanged); a late answer for an older local
##   session cannot mark the current one, and the session id only moves to
##   the newest begun session.

## Session policy A (Charlie, 2026-10-10): another device took over this
## character. This client can no longer act on it or read its latest
## progress until begin_gameplay_session() takes it back. A later UI WP shows
## the prompt; WP01 only provides the signal and state.
signal gameplay_session_superseded

const SUPERSEDED_REASON := "gameplay_session_superseded"

const NakamaHTTPAdapterScript := preload("res://addons/com.heroiclabs.nakama/client/NakamaHTTPAdapter.gd")
const OnlineReadTransportScript := preload("res://scripts/online_read_transport.gd")

## WP01-G Phase C1: requests use the SDK's NON-threaded HTTP mode. In threaded
## mode, when a server accepts the connection but never answers, the request
## timeout waits for the request thread (Godot 4.7.2 HTTPRequest) and the whole
## game stops (WP01-G Phase B run 40077605107: threaded 2/2 hang, non-threaded
## 2/2 return). Non-threaded requests are handled once per frame. Timeout,
## retry, payloads and every outcome rule below are unchanged.
const HTTP_USE_THREADS := false

const RPC_SESSION_BEGIN := "vs01_session_begin"
const RPC_PROGRESS_GET := "vs01_progress_get"
const RPC_TRADE := "vs01_trade"
const RPC_TRADE_RESOLVE := "vs01_trade_resolve"
const RPC_COMBAT_REWARD_CLAIM := "vs01_combat_reward_claim"
const BOUNDED_READ_RPC_IDS := [RPC_PROGRESS_GET, "vs01e_progression_get"]

## Hosts where D1 local email TEST accounts may be used. Anything else must
## use Sign in with Apple.
const LOCAL_TEST_HOSTS := ["127.0.0.1", "localhost", "::1"]

## Outcome kinds returned by every call.
const OK := "ok"
const REJECTED := "rejected"        # server refused (malformed, superseded, rate limited, ...)
const UNCERTAIN := "uncertain"      # no server answer; the command may or may not have applied
const NOT_SIGNED_IN := "not_signed_in"
const NO_GAMEPLAY_SESSION := "no_gameplay_session"

## gRPC codes where the server could not tell whether a write committed
## (UNKNOWN, DEADLINE_EXCEEDED, INTERNAL, UNAVAILABLE): treated like no answer.
const AMBIGUOUS_GRPC_CODES := [2, 4, 13, 14]

## WP01-H: server answers identified by their EXACT message (never by the
## status code alone: gRPC 13 also means "commit unknown").
const QUARANTINE_REASONS := ["receipt_unrecognized", "receipt_not_trusted", "idempotency_key_reused"]
const NEEDS_CHECK_REASON := "resolve_command_invalid"
const RECEIPT_MISMATCH_REASON := "receipt_mismatch"
const VOIDED_RECEIPT_CONTRACT := "myrial.vs01.wp01.trade_receipt"
## Local refusals (nothing sent).
const STORE_WRITE_FAILED := "pending_store_write_failed"
const STORE_HOLD_FAILED := "pending_store_hold_failed"
const LEGACY_V1_KEYS := ["idempotency_key", "request_hash", "user_id", "gameplay_session_id", "action", "city_id", "good_id",
	"quantity", "status", "reason", "unit_price", "total", "money_before", "money_after", "carried_before", "carried_after",
	"progress_revision", "server_time_ms"]
const VOIDED_V2_KEYS := ["contract", "contract_version", "idempotency_key", "request_hash", "user_id", "resolved_by_session_id",
	"action", "city_id", "good_id", "quantity", "status", "reason", "unit_price", "total", "money_before", "money_after",
	"carried_before", "carried_after", "progress_revision", "server_time_ms"]
const TRADE_UNRESOLVED := "pending_trade_unresolved"
const TRADE_NEEDS_CHECK := "pending_trade_needs_check"

var host := "127.0.0.1"
var port := 17350
var scheme := "http"
var server_key := "defaultkey"
var timeout_sec := 5

var _client: NakamaClient
var _adapter: Node
var _session: NakamaSession
var _gameplay_session_id := ""
var _superseded := false
## Last server-confirmed progress view, or {} when none. Read-only cache.
var _confirmed := {}
## Revision of _confirmed and issue number of the request that brought it.
var _confirmed_revision := -1
var _confirmed_seq := -1
## Revision of the view that set _gameplay_session_id (newest begun session).
var _session_revision := -1
## Local request counter (issue order) and the account epoch: +1 on every
## sign-out and every switch to a different account.
var _issued := 0
var _auth_epoch := 0
## The CURRENT account's pending commands:
## idempotency_key -> {"action", "city_id", "good_id", "quantity"}
var _pending := {}
## Pending commands of accounts that are not signed in right now (user_id -> dict).
var _pending_by_user := {}
## C2-E2 is opt-in so existing isolated modes and their scripted clients keep
## their exact behavior. The Resume mode enables it for its two approved reads.
var _bounded_reads_enabled := false
var _read_transport: OnlineReadTransport
## WP01-H: the durable Pending Store (always present, FIX-01).
var _store: OnlinePendingStore = OnlinePendingStore.new()
## Non-empty when the signed-in account's store is not usable (B-4A).
var _store_block := ""
## Current account's trade entry states: key -> {"state", "reason"}.
var _pending_state := {}
var _pending_state_by_user := {}
## Current account's pending combat command (store mode), {} when none.
var _combat_pending := {}
var _combat_pending_by_user := {}
## FIX-02: true only for a combat command created, adopted or checked against
## the server's recorded intent IN THIS PROCESS / sign-in. A command loaded
## from the store is unverified and is never resent before recover().
var _combat_verified := false
## Keys with a resolve in flight (never two at once for one key).
var _resolving := {}


func configure(p_host: String, p_port: int, p_scheme: String = "http", p_server_key: String = "defaultkey") -> void:
	_cancel_bounded_reads()
	host = p_host
	port = p_port
	scheme = p_scheme
	server_key = p_server_key
	_client = null


func enable_bounded_reads() -> void:
	_bounded_reads_enabled = true
	_get_read_transport()


func cancel_bounded_reads() -> void:
	_cancel_bounded_reads()


func is_local_test_host() -> bool:
	return host in LOCAL_TEST_HOSTS


func is_signed_in() -> bool:
	return _session != null and not _session.is_expired()


func get_user_id() -> String:
	return _session.user_id if _session != null else ""


func get_gameplay_session_id() -> String:
	return _gameplay_session_id


func is_gameplay_session_superseded() -> bool:
	return _superseded


## Deep copy, so callers cannot edit the cache.
func get_confirmed_progress() -> Dictionary:
	return _confirmed.duplicate(true)


func get_pending_commands() -> Dictionary:
	return _pending.duplicate(true)


## WP01-H FIX-01: always refused. The RAM import was the WP01-B path that
## could re-send orders of unknown origin; the Pending Store of the signed-in
## account is the only source of pending orders.
func import_pending_commands(_commands: Dictionary, _for_user_id: String = "") -> bool:
	return false


## WP01-H: replaces the Pending Store (tests / process-kill phases). Never
## null. If an account is signed in, its metadata is reloaded from the new
## store (the store wins over RAM).
func enable_pending_store(store: OnlinePendingStore) -> void:
	if store == null:
		return
	_store = store
	if is_signed_in():
		_load_store(get_user_id())


func has_pending_store() -> bool:
	return _store != null


## "" when the signed-in account's store is usable, else why it is blocked.
func store_block_reason() -> String:
	return _store_block


## key -> {"state", "reason"} of the signed-in account (store mode).
func get_pending_states() -> Dictionary:
	return _pending_state.duplicate(true)


## Why a NEW trade is refused locally right now ("" = allowed). B-4A.
func trade_block_reason() -> String:
	if not _store_block.is_empty():
		return _store_block
	for key in _pending_state:
		if _pending_state[key]["state"] != OnlinePendingStore.STATE_PENDING:
			return TRADE_NEEDS_CHECK
	return TRADE_UNRESOLVED if not _pending.is_empty() else ""


## Store mode: the signed-in account's pending combat command ({} if none).
func get_combat_pending() -> Dictionary:
	return _combat_pending.duplicate(true)


## Makes `entry` the account's pending combat command, durably. False (and
## nothing changed) if it could not be written. `verified`: whether this
## process may resend it without a recover() check (new / adopted command).
func set_combat_pending(entry: Dictionary, verified: bool = true) -> bool:
	if not _store_block.is_empty():
		return false
	var before := _combat_pending
	_combat_pending = entry.duplicate(true)
	if _persist():
		_combat_verified = verified
		return true
	_combat_pending = before
	return false


func is_combat_pending_verified() -> bool:
	return _combat_verified and not _combat_pending.is_empty()


## Called by OnlineCombatAdapter.recover() once the server's recorded intent
## (or its absence for the open ticket) matched the ORIGINAL command.
func mark_combat_pending_verified() -> void:
	_combat_verified = not _combat_pending.is_empty()


## Store mode: clears the pending combat command of `ticket_id` durably.
## If the write fails the entry stays (it then replays harmlessly later).
func clear_combat_pending(ticket_id: String) -> bool:
	if _combat_pending.get("ticket_id", "") != ticket_id:
		return false
	var before := _combat_pending
	_combat_pending = {}
	if _persist():
		return true
	_combat_pending = before
	return false


## D1 formal method. `identity_token` comes from the iOS Sign in with Apple
## flow (native plugin, outside WP01); Nakama verifies it against Apple.
func sign_in_apple(identity_token: String) -> Dictionary:
	if identity_token.is_empty():
		return _outcome(REJECTED, "missing_identity_token")
	return _accept_session(await _get_client().authenticate_apple_async(identity_token, null, true))


## D1 local test accounts only. Refused for any non-local host here, and the
## server refuses email sign-in unless its local test flag is set.
func sign_in_email_test(email: String, password: String, create: bool = true) -> Dictionary:
	if not is_local_test_host():
		return _outcome(REJECTED, "email_test_auth_local_only")
	return _accept_session(await _get_client().authenticate_email_async(email, password, null, create))


func sign_out_local() -> void:
	_cancel_bounded_reads()
	_park_pending(get_user_id())
	_session = null
	_gameplay_session_id = ""
	_superseded = false
	_reset_confirmed()
	_auth_epoch += 1


## D2: starts this device's gameplay session; any earlier one (other device or
## an older run) can no longer write.
func begin_gameplay_session() -> Dictionary:
	var epoch := _auth_epoch
	var seq := _next_seq()
	var result := await _rpc(RPC_SESSION_BEGIN, {})
	if epoch != _auth_epoch:
		return _stale(result)
	if result["status"] == OK:
		var view: Dictionary = result["data"]["progress"]
		# Each begin raises the server revision, so the newest begun session
		# is the one with the highest view revision (two begins never share
		# one); an older begin answering late must not bring back its
		# (already superseded) session id.
		if int(view.get("revision", -1)) >= _session_revision:
			_cancel_bounded_reads()
			_session_revision = int(view.get("revision", -1))
			_gameplay_session_id = result["data"]["gameplay_session_id"]
			_superseded = false
		_offer(view, seq)
	return result


## Policy A: only the active gameplay session may read the latest progress.
func refresh_progress() -> Dictionary:
	if _gameplay_session_id.is_empty():
		return _outcome(NO_GAMEPLAY_SESSION, "no_gameplay_session")
	if _superseded:
		return _outcome(REJECTED, SUPERSEDED_REASON)
	var epoch := _auth_epoch
	var seq := _next_seq()
	var sent_session := _gameplay_session_id
	var result := await _rpc(RPC_PROGRESS_GET, {"gameplay_session_id": sent_session})
	if epoch != _auth_epoch:
		return _stale(result)
	if result["status"] == OK:
		_offer(result["data"]["progress"], seq)
	_note_superseded(result, sent_session)
	return result


func buy(city_id: String, good_id: String, quantity: int) -> Dictionary:
	return await _trade({"action": "buy", "city_id": city_id, "good_id": good_id, "quantity": quantity}, new_idempotency_key())


func sell(city_id: String, good_id: String, quantity: int) -> Dictionary:
	return await _trade({"action": "sell", "city_id": city_id, "good_id": good_id, "quantity": quantity}, new_idempotency_key())


## Asks vs01_trade_resolve, with the ORIGINAL key and command, for every
## PENDING order of the signed-in account (needs-check / quarantined ones are
## never retried). Each resolves to its single recorded server outcome
## (applied / rejected / voided) or stays pending. Never vs01_trade (FIX-01).
func recover_pending() -> Array:
	return await _recover_durable()


## VS-01 WP01-E (isolated Online TEST): one command under the ACTIVE gameplay
## session, with the same policy A, account-epoch and ambiguity handling as a
## trade. The caller (OnlineCombatAdapter) owns its own pending command and
## its key; nothing here is retried or filed as pending.
func gameplay_rpc(id: String, payload: Dictionary) -> Dictionary:
	if _gameplay_session_id.is_empty():
		return _outcome(NO_GAMEPLAY_SESSION, "no_gameplay_session")
	if _superseded:
		return _outcome(REJECTED, SUPERSEDED_REASON)
	var epoch := _auth_epoch
	var sent_session := _gameplay_session_id
	var body := payload.duplicate(true)
	body["gameplay_session_id"] = sent_session
	var result := await _rpc(id, body)
	if epoch != _auth_epoch:
		return _stale(result)
	_note_superseded(result, sent_session)
	if result["status"] == REJECTED and result.get("grpc_status", 0) in AMBIGUOUS_GRPC_CODES:
		result["status"] = UNCERTAIN
	return result


## D4: always refused by the server until combat validation is approved.
func claim_combat_reward(claim: Dictionary) -> Dictionary:
	return await _rpc(RPC_COMBAT_REWARD_CLAIM, claim)


## 32 hex chars from the OS CSPRNG (server accepts [A-Za-z0-9_-]{16,64}).
static func new_idempotency_key() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


func _trade(command: Dictionary, key: String) -> Dictionary:
	if _gameplay_session_id.is_empty():
		return _outcome(NO_GAMEPLAY_SESSION, "no_gameplay_session")
	return await _trade_durable(command, key)


## Policy A: marks THIS session as taken over, but only if the refused
## request was sent under the gameplay session that is current now.
func _note_superseded(result: Dictionary, sent_session: String) -> void:
	if sent_session != _gameplay_session_id:
		return
	if result["status"] == REJECTED and result["reason"] == SUPERSEDED_REASON and not _superseded:
		_superseded = true
		gameplay_session_superseded.emit()


func _next_seq() -> int:
	_issued += 1
	return _issued - 1


## Accepts a server-confirmed view only if it is newer (see the header).
func _offer(view: Variant, seq: int) -> void:
	if typeof(view) != TYPE_DICTIONARY:
		return
	var revision := int((view as Dictionary).get("revision", -1))
	if revision < _confirmed_revision or (revision == _confirmed_revision and seq < _confirmed_seq):
		return
	_confirmed = (view as Dictionary).duplicate(true)
	_confirmed_revision = revision
	_confirmed_seq = seq


func _reset_confirmed() -> void:
	_confirmed = {}
	_confirmed_revision = -1
	_confirmed_seq = -1
	_session_revision = -1


## Keeps an account's pending commands aside while it is not signed in.
func _park_pending(user_id: String) -> void:
	if not _pending.is_empty():
		_pending_by_user[user_id] = _pending
		_pending_state_by_user[user_id] = _pending_state
	if not _combat_pending.is_empty():
		_combat_pending_by_user[user_id] = _combat_pending
	_pending = {}
	_pending_state = {}
	_combat_pending = {}


## An answer to a request sent under an older account epoch: never applied to
## the current state; its outcome is unknown to the current account.
static func _stale(result: Dictionary) -> Dictionary:
	var stale := _outcome(UNCERTAIN, "answer_after_sign_out_or_account_change")
	stale["stale"] = true
	stale["original_status"] = result.get("status")
	return stale


func _rpc(id: String, payload: Dictionary) -> Dictionary:
	if not is_signed_in():
		return _outcome(NOT_SIGNED_IN, "not_signed_in")
	if _bounded_reads_enabled and id in BOUNDED_READ_RPC_IDS:
		return await _get_read_transport().read_rpc(self, id, payload)
	var response = await _get_client().rpc_async(_session, id, JSON.stringify(payload))
	if response.is_exception():
		var error: NakamaException = response.get_exception()
		# A gRPC status means the server answered and decided; anything else
		# (no connection, timeout) leaves the outcome unknown.
		if error.grpc_status_code > 0:
			var rejected := _outcome(REJECTED, error.message)
			rejected["grpc_status"] = error.grpc_status_code
			return rejected
		return _outcome(UNCERTAIN, error.message)
	var data: Variant = JSON.parse_string(response.payload)
	if typeof(data) != TYPE_DICTIONARY:
		return _outcome(UNCERTAIN, "unreadable_response")
	var ok := _outcome(OK, "")
	ok["data"] = data
	return ok


func _accept_session(session: NakamaSession) -> Dictionary:
	if session == null or session.is_exception():
		var error: NakamaException = session.get_exception() if session != null else null
		var rejected := _outcome(REJECTED if error != null and error.grpc_status_code > 0 else UNCERTAIN, error.message if error != null else "no_session")
		if error != null:
			rejected["grpc_status"] = error.grpc_status_code
		return rejected
	_cancel_bounded_reads()
	var previous_user := get_user_id()
	if _session == null or session.user_id != previous_user:
		# Signed out before, or a different account: nothing of the previous
		# state may leak in, and late answers to its requests are ignored.
		if _session != null:
			_park_pending(previous_user)
		_pending = _pending_by_user.get(session.user_id, {})
		_pending_by_user.erase(session.user_id)
		_pending_state = _pending_state_by_user.get(session.user_id, {})
		_pending_state_by_user.erase(session.user_id)
		_combat_pending = _combat_pending_by_user.get(session.user_id, {})
		_combat_pending_by_user.erase(session.user_id)
		if _store != null:
			_load_store(session.user_id)
		_reset_confirmed()
		_superseded = false
		_auth_epoch += 1
	else:
		# The SAME account signed in again (for example a new token). Its cache
		# and pending orders (idempotency keys) stay, but it is still an auth
		# boundary (PR #135 review): requests sent before it must not change
		# the cache, the superseded flag or the session id when they answer.
		_auth_epoch += 1
	_session = session
	_gameplay_session_id = ""
	return _outcome(OK, "")


# --- WP01-H durable trade recovery (store mode only) --------------------------------

## The store is the only source: the account's entries are replaced by what
## the store holds; an untrusted store blocks the account (B-4A).
func _load_store(user_id: String) -> void:
	var loaded := _store.load_account(user_id)
	_pending = {}
	_pending_state = {}
	_combat_pending = {}
	_combat_verified = false  # FIX-02: loaded = unverified
	_store_block = ""
	if loaded["status"] != OnlinePendingStore.READY:
		_store_block = String(loaded["reason"])
		return
	for key in loaded["trade"]:
		var e: Dictionary = loaded["trade"][key]
		_pending[key] = {"action": e["action"], "city_id": e["city_id"], "good_id": e["good_id"], "quantity": int(e["quantity"])}
		_pending_state[key] = {"state": e["state"], "reason": e["reason"]}
	_combat_pending = loaded["combat"]


## Writes the signed-in account's whole metadata. False: nothing new is durable.
func _persist() -> bool:
	if _store == null or not _store_block.is_empty() or not is_signed_in():
		return false
	var trade := {}
	for key in _pending:
		var e: Dictionary = (_pending[key] as Dictionary).duplicate(true)
		var st: Dictionary = _pending_state.get(key, {"state": OnlinePendingStore.STATE_PENDING, "reason": ""})
		e["state"] = st["state"]
		e["reason"] = st["reason"]
		trade[key] = e
	return _store.save_account(get_user_id(), trade, _combat_pending)


## Removes a decided entry durably; if the write fails it stays (memory and
## disk agree) and a later resolve replays the same receipt.
func _clear_trade(key: String) -> bool:
	var command: Variant = _pending.get(key)
	var state: Variant = _pending_state.get(key)
	_pending.erase(key)
	_pending_state.erase(key)
	if _persist():
		return true
	if command != null:
		_pending[key] = command
	if state != null:
		_pending_state[key] = state
	return false


## FIX-04: a quarantine / needs-check decision must never come back as a
## normal pending order after a restart. Order: memory first (no retry in
## this process), then the store's MARK JOURNAL, then the live file. If both
## writes fail a durable HOLD is put on the account; if that fails too, the
## account is blocked for the rest of this process. The original entry is
## never cleared (evidence).
func _mark_trade(key: String, state: String, reason: String) -> void:
	_pending_state[key] = {"state": state, "reason": reason}
	var journaled := _store.record_marks(get_user_id(), {key: {"state": state, "reason": reason}}, {})
	var written := _persist()
	if not journaled and not written:
		hold_account(reason)


## FIX-04 / FIX-05 for the combat slot: `marked` is the account's command
## (or a claim-less ticket hold) with its new state; same order as above.
func mark_combat(marked: Dictionary) -> void:
	_combat_pending = marked.duplicate(true)
	_combat_verified = false
	var journaled := _store.record_marks(get_user_id(), {}, {"ticket_id": marked["ticket_id"], "state": marked["state"], "reason": marked["reason"]})
	var written := _persist()
	if not journaled and not written:
		hold_account(String(marked["reason"]))


## Puts the signed-in account on hold after a failed mark (see _mark_trade).
## Returns true if the hold is durable.
func hold_account(reason: String) -> bool:
	if _store.hold_account(get_user_id(), reason):
		_store_block = OnlinePendingStore.HELD_REASON
		return true
	_store_block = STORE_HOLD_FAILED
	return false


static func _whole(v: Variant, minimum: int) -> bool:
	return OnlinePendingStore._is_whole_any(v, minimum)


## FIX-03: a receipt resolves the entry only if it is, field for field, a
## receipt the E1 server writes for THIS key, account and command: Legacy v1
## (rpcTrade) or Voided v2 (vs01_trade_resolve), with the request hash the
## server computes and money / cargo deltas consistent with the outcome.
## Anything else is never trusted to clear an order.
func _receipt_matches(receipt: Variant, key: String, command: Dictionary) -> bool:
	if typeof(receipt) != TYPE_DICTIONARY:
		return false
	var r: Dictionary = receipt
	var v2: bool = r.get("status") == "voided"
	if not OnlinePendingStore._keys_exactly(r, VOIDED_V2_KEYS if v2 else LEGACY_V1_KEYS):
		return false
	var qty := int(command["quantity"])
	if r["idempotency_key"] != key or r["user_id"] != get_user_id():
		return false
	if r["action"] != command["action"] or r["city_id"] != command["city_id"] or r["good_id"] != command["good_id"]:
		return false
	if not _whole(r["quantity"], 0) or int(r["quantity"]) != qty:
		return false
	if r["request_hash"] != "%s|%s|%s|%d" % [command["action"], command["city_id"], command["good_id"], qty]:
		return false
	for f in ["unit_price", "total", "money_before", "money_after", "carried_before", "carried_after", "progress_revision", "server_time_ms"]:
		if not _whole(r[f], 0):
			return false
	if typeof(r["reason"]) != TYPE_STRING:
		return false
	var unit := int(r["unit_price"])
	var total := int(r["total"])
	var m0 := int(r["money_before"])
	var m1 := int(r["money_after"])
	var c0 := int(r["carried_before"])
	var c1 := int(r["carried_after"])
	if v2:
		return r["contract"] == VOIDED_RECEIPT_CONTRACT and _whole(r["contract_version"], 2) and int(r["contract_version"]) == 2 \
			and typeof(r["resolved_by_session_id"]) == TYPE_STRING and r["reason"] == "recovery_voided" \
			and unit == 0 and total == 0 and m1 == m0 and c1 == c0
	if typeof(r["gameplay_session_id"]) != TYPE_STRING:
		return false
	match r["status"]:
		"applied":
			if r["reason"] != "" or unit <= 0 or total != unit * qty:
				return false
			if command["action"] == "buy":
				return m1 == m0 - total and c1 == c0 + qty
			return m1 == m0 + total and c1 == c0 - qty
		"rejected":
			return r["reason"] != "" and unit == 0 and m1 == m0 and c1 == c0
	return false


func _trade_durable(command: Dictionary, key: String) -> Dictionary:
	if _pending.has(key):
		return await _resolve(key)  # an unknown outcome is only ever resolved
	if _superseded:
		return _local_refusal(SUPERSEDED_REASON, key)  # policy A first
	var block := trade_block_reason()
	if not block.is_empty():
		return _local_refusal(block, key)
	var pending := _pending
	pending[key] = command.duplicate(true)
	_pending_state[key] = {"state": OnlinePendingStore.STATE_PENDING, "reason": ""}
	if not _persist():
		# PR-04: not durable -> nothing is sent.
		pending.erase(key)
		_pending_state.erase(key)
		return _local_refusal(STORE_WRITE_FAILED, key)
	var epoch := _auth_epoch
	var seq := _next_seq()
	var sent_session := _gameplay_session_id
	var payload := command.duplicate(true)
	payload["gameplay_session_id"] = sent_session
	payload["idempotency_key"] = key
	var result := await _rpc(RPC_TRADE, payload)
	return _file_answer(result, key, command, epoch, seq, sent_session, false)


func _recover_durable() -> Array:
	var epoch := _auth_epoch
	var outcomes := []
	for key in _pending.keys():
		if epoch != _auth_epoch:
			break
		if _pending.has(key) and _pending_state.get(key, {}).get("state") == OnlinePendingStore.STATE_PENDING:
			outcomes.append(await _resolve(key))
	return outcomes


## vs01_trade_resolve with the ORIGINAL key and command (never vs01_trade).
func _resolve(key: String) -> Dictionary:
	if _pending_state.get(key, {}).get("state") != OnlinePendingStore.STATE_PENDING:
		return _local_refusal(TRADE_NEEDS_CHECK, key)
	if _superseded:
		return _local_refusal(SUPERSEDED_REASON, key)
	if not _store_block.is_empty():
		return _local_refusal(_store_block, key)
	if _resolving.has(key):
		return _local_refusal("resolve_in_flight", key)
	_resolving[key] = true
	var command: Dictionary = (_pending[key] as Dictionary).duplicate(true)
	var epoch := _auth_epoch
	var seq := _next_seq()
	var sent_session := _gameplay_session_id
	var payload := command.duplicate(true)
	payload["gameplay_session_id"] = sent_session
	payload["idempotency_key"] = key
	var result := await _rpc(RPC_TRADE_RESOLVE, payload)
	_resolving.erase(key)
	return _file_answer(result, key, command, epoch, seq, sent_session, true)


## Files one vs01_trade / vs01_trade_resolve answer for `key`.
func _file_answer(result: Dictionary, key: String, command: Dictionary, epoch: int, seq: int, sent_session: String, is_resolve: bool) -> Dictionary:
	result["idempotency_key"] = key
	result["resolve"] = is_resolve
	if epoch != _auth_epoch:
		# Answer for an older sign-in: its entry stays in its own account's store.
		var stale := _stale(result)
		stale["idempotency_key"] = key
		stale["pending"] = true
		return stale
	_note_superseded(result, sent_session)
	var reason := String(result.get("reason", ""))
	if result["status"] == OK:
		var data: Dictionary = result["data"]
		if not _receipt_matches(data.get("receipt"), key, command):
			_mark_trade(key, OnlinePendingStore.STATE_QUARANTINED, RECEIPT_MISMATCH_REASON)
			var mismatch := _outcome(REJECTED, RECEIPT_MISMATCH_REASON)
			mismatch["quarantined"] = true
			return _filed(mismatch, key, true)
		if typeof(data.get("progress")) == TYPE_DICTIONARY:
			_offer(data["progress"], seq)
		result["receipt"] = data["receipt"]
		result["replayed"] = data.get("replayed", false)
		result["outcome"] = data["receipt"]["status"]
		_clear_trade(key)
	elif result["status"] == REJECTED and reason in QUARANTINE_REASONS:
		_mark_trade(key, OnlinePendingStore.STATE_QUARANTINED, reason)
		result["quarantined"] = true
	elif result["status"] == REJECTED and is_resolve and reason == NEEDS_CHECK_REASON:
		_mark_trade(key, OnlinePendingStore.STATE_NEEDS_CHECK, reason)
		result["needs_check"] = true
	elif result["status"] == REJECTED and result.get("grpc_status", 0) in AMBIGUOUS_GRPC_CODES:
		result["status"] = UNCERTAIN  # unidentified: outcome unknown, keep
	elif result["status"] == REJECTED and not is_resolve:
		# The FIRST send refused before any decision (malformed, superseded,
		# rate limited, no session): rpcTrade writes nothing then.
		_clear_trade(key)
	# Everything else stays pending: no answer, superseded, rate limited or
	# any refusal of a resolve (including a server without vs01_trade_resolve).
	return _filed(result, key, _pending.has(key))


func _filed(result: Dictionary, key: String, pending: bool) -> Dictionary:
	result["idempotency_key"] = key
	result["pending"] = pending
	if _pending_state.has(key):
		result["entry_state"] = _pending_state[key]["state"]
	return result


func _local_refusal(reason: String, key: String) -> Dictionary:
	var refused := _outcome(REJECTED, reason)
	refused["local"] = true
	return _filed(refused, key, _pending.has(key))


func _get_client() -> NakamaClient:
	if _client == null:
		if _adapter == null:
			_adapter = NakamaHTTPAdapterScript.new()
			_adapter.name = "NakamaHTTPAdapter"
			_adapter.use_threads = HTTP_USE_THREADS
			add_child(_adapter)
		_adapter.timeout = timeout_sec
		_client = NakamaClient.new(_adapter, server_key, scheme, host, port, timeout_sec)
		# Retries are safe only because every trade is idempotent; keep the
		# SDK's own transient retry but never rely on it for correctness.
		_client.auto_retry = true
	return _client


func _get_read_transport() -> OnlineReadTransport:
	if _read_transport == null:
		_read_transport = OnlineReadTransportScript.new()
		_read_transport.name = "OnlineReadTransport"
		add_child(_read_transport)
	return _read_transport


func _cancel_bounded_reads() -> void:
	if _read_transport != null:
		_read_transport.cancel_all()


static func _outcome(status: String, reason: String) -> Dictionary:
	return {"status": status, "reason": reason}
