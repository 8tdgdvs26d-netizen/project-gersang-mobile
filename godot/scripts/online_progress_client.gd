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
## PENDING and recover_pending() resends the SAME key, which returns the
## original receipt instead of trading twice. Pending commands are kept in
## memory and can be exported / imported by the caller; writing them to disk
## needs a separately approved local-storage decision (Save v14 untouched).

const NakamaHTTPAdapterScript := preload("res://addons/com.heroiclabs.nakama/client/NakamaHTTPAdapter.gd")

const RPC_SESSION_BEGIN := "vs01_session_begin"
const RPC_PROGRESS_GET := "vs01_progress_get"
const RPC_TRADE := "vs01_trade"
const RPC_COMBAT_REWARD_CLAIM := "vs01_combat_reward_claim"

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

var host := "127.0.0.1"
var port := 17350
var scheme := "http"
var server_key := "defaultkey"
var timeout_sec := 5

var _client: NakamaClient
var _adapter: Node
var _session: NakamaSession
var _gameplay_session_id := ""
## Last server-confirmed progress view, or {} when none. Read-only cache.
var _confirmed := {}
## idempotency_key -> {"action", "city_id", "good_id", "quantity"}
var _pending := {}


func configure(p_host: String, p_port: int, p_scheme: String = "http", p_server_key: String = "defaultkey") -> void:
	host = p_host
	port = p_port
	scheme = p_scheme
	server_key = p_server_key
	_client = null


func is_local_test_host() -> bool:
	return host in LOCAL_TEST_HOSTS


func is_signed_in() -> bool:
	return _session != null and not _session.is_expired()


func get_user_id() -> String:
	return _session.user_id if _session != null else ""


func get_gameplay_session_id() -> String:
	return _gameplay_session_id


## Deep copy, so callers cannot edit the cache.
func get_confirmed_progress() -> Dictionary:
	return _confirmed.duplicate(true)


func get_pending_commands() -> Dictionary:
	return _pending.duplicate(true)


func import_pending_commands(commands: Dictionary) -> void:
	for key in commands:
		if typeof(key) == TYPE_STRING and typeof(commands[key]) == TYPE_DICTIONARY:
			_pending[key] = (commands[key] as Dictionary).duplicate(true)


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
	_session = null
	_gameplay_session_id = ""
	_confirmed = {}


## D2: starts this device's gameplay session; any earlier one (other device or
## an older run) can no longer write.
func begin_gameplay_session() -> Dictionary:
	var result := await _rpc(RPC_SESSION_BEGIN, {})
	if result["status"] == OK:
		_gameplay_session_id = result["data"]["gameplay_session_id"]
		_confirmed = result["data"]["progress"]
	return result


func refresh_progress() -> Dictionary:
	var result := await _rpc(RPC_PROGRESS_GET, {})
	if result["status"] == OK:
		_confirmed = result["data"]["progress"]
	return result


func buy(city_id: String, good_id: String, quantity: int) -> Dictionary:
	return await _trade({"action": "buy", "city_id": city_id, "good_id": good_id, "quantity": quantity}, new_idempotency_key())


func sell(city_id: String, good_id: String, quantity: int) -> Dictionary:
	return await _trade({"action": "sell", "city_id": city_id, "good_id": good_id, "quantity": quantity}, new_idempotency_key())


## Resends every pending command with its original key. Each one resolves to
## its single recorded outcome (applied or rejected) or stays pending.
func recover_pending() -> Array:
	var outcomes := []
	for key in _pending.keys():
		outcomes.append(await _trade(_pending[key], key))
	return outcomes


## D4: always refused by the server until combat validation is approved.
func claim_combat_reward(claim: Dictionary) -> Dictionary:
	return await _rpc(RPC_COMBAT_REWARD_CLAIM, claim)


## 32 hex chars from the OS CSPRNG (server accepts [A-Za-z0-9_-]{16,64}).
static func new_idempotency_key() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


func _trade(command: Dictionary, key: String) -> Dictionary:
	if _gameplay_session_id.is_empty():
		return _outcome(NO_GAMEPLAY_SESSION, "no_gameplay_session")
	var is_retry := _pending.has(key)
	_pending[key] = command.duplicate(true)
	var payload := command.duplicate(true)
	payload["gameplay_session_id"] = _gameplay_session_id
	payload["idempotency_key"] = key
	var result := await _rpc(RPC_TRADE, payload)
	result["idempotency_key"] = key
	if result["status"] == REJECTED and result.get("grpc_status", 0) in AMBIGUOUS_GRPC_CODES:
		result["status"] = UNCERTAIN
	if result["status"] == OK:
		# Only a receipt (applied or rejected by the rules) resolves a command.
		_pending.erase(key)
		var data: Dictionary = result["data"]
		if data.get("progress") != null:
			_confirmed = data["progress"]
		result["receipt"] = data["receipt"]
		result["replayed"] = data["replayed"]
	elif result["status"] == REJECTED and not is_retry:
		# A NEW command refused before any decision (malformed, superseded
		# session, rate limited, ...) never applied: nothing to recover.
		_pending.erase(key)
	# Otherwise it stays pending: no answer, an ambiguous storage error, or a
	# refused RETRY, which says nothing about the original attempt. A
	# superseded client recovers by beginning a new gameplay session first.
	result["pending"] = _pending.has(key)
	return result


func _rpc(id: String, payload: Dictionary) -> Dictionary:
	if not is_signed_in():
		return _outcome(NOT_SIGNED_IN, "not_signed_in")
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
	_session = session
	_gameplay_session_id = ""
	return _outcome(OK, "")


func _get_client() -> NakamaClient:
	if _client == null:
		if _adapter == null:
			_adapter = NakamaHTTPAdapterScript.new()
			_adapter.name = "NakamaHTTPAdapter"
			add_child(_adapter)
		_adapter.timeout = timeout_sec
		_client = NakamaClient.new(_adapter, server_key, scheme, host, port, timeout_sec)
		# Retries are safe only because every trade is idempotent; keep the
		# SDK's own transient retry but never rely on it for correctness.
		_client.auto_retry = true
	return _client


static func _outcome(status: String, reason: String) -> Dictionary:
	return {"status": status, "reason": reason}
