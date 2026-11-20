extends SceneTree

## VS-01 WP01 — offline checks for the Nakama progress client and the server
## rules port. Needs no server: part of the normal Godot regression. The live
## server checks are tests/live_vs01_wp01_nakama.gd (nakama/scripts/run_live_tests.sh).
##
## - GDScript trade rules still produce the golden vectors the TypeScript
##   server port is tested against (drift on either side fails a test).
## - The client never applies trades locally, keeps an uncertain command
##   pending under ONE idempotency key, and recovers it with the same key.
##   WP01-H E2 (FIX-01): pending orders are durable in the per-account
##   Pending Store and recovered ONLY through vs01_trade_resolve; the WP01-B
##   export / import and vs01_trade resend are superseded and now refused.
## - Isolation: no gameplay script, scene, autoload or SaveStore uses the
##   online client yet; Save v14 and the Development Save are untouched.

const RulesVectors := preload("res://tests/vs01_wp01_rules_vectors.gd")
const CLOSED_PORT := 1


const SCRIPTED_UID := "00000000-0000-0000-0000-0000000000f1"


## Test double: answers trades from a script instead of the network. A
## Callable answer is built from the request (WP01-H: receipts must be the
## exact E1 receipt of the request's key and command). `sent` records ids.
class ScriptedClient extends OnlineProgressClient:
	var answers: Array = []
	var sent: Array = []

	func is_signed_in() -> bool:
		return true

	func _rpc(id: String, payload: Dictionary) -> Dictionary:
		sent.append(id)
		var a: Variant = answers.pop_front()
		return a.call(payload) if typeof(a) == TYPE_CALLABLE else a


static func _server_refusal(grpc: int, reason: String) -> Dictionary:
	return {"status": OnlineProgressClient.REJECTED, "reason": reason, "grpc_status": grpc}


## The exact Legacy v1 receipt rpcTrade writes for the request (WP01-H FIX-03).
static func _server_receipt(status: String) -> Callable:
	return func(p: Dictionary) -> Dictionary:
		var qty := int(p["quantity"])
		var applied := status == "applied"
		var unit := 84 if applied else 0
		var buy: bool = p["action"] == "buy"
		var receipt := {"idempotency_key": p["idempotency_key"], "request_hash": "%s|%s|%s|%d" % [p["action"], p["city_id"], p["good_id"], qty],
			"user_id": SCRIPTED_UID, "gameplay_session_id": p["gameplay_session_id"], "action": p["action"], "city_id": p["city_id"],
			"good_id": p["good_id"], "quantity": qty, "status": status, "reason": "" if applied else "insufficient_money",
			"unit_price": unit, "total": unit * qty, "money_before": 10000, "money_after": 10000 - (unit * qty if buy else -unit * qty) if applied else 10000,
			"carried_before": 0 if buy else qty, "carried_after": (qty if buy else 0) if applied else (0 if buy else qty),
			"progress_revision": 2, "server_time_ms": 1}
		return {"status": OnlineProgressClient.OK, "reason": "", "data": {"replayed": false, "receipt": receipt, "progress": {"money": 1}}}


static func _scripted(client: ScriptedClient, gsid: String) -> void:
	client._session = NakamaSession.new(_unsigned_token(SCRIPTED_UID), false)
	client._gameplay_session_id = gsid

var _checks := 0
var _failures := 0


func _initialize() -> void:
	# The root only enters the tree after the first frame; HTTP requests need it.
	await process_frame
	_wipe("user://online_pending")  # synthetic accounts only (isolated user://)
	var dev_before := _dev_save_fingerprint()
	_verify_rules_parity()
	_verify_isolation()
	_verify_idempotency_keys()
	await _verify_signed_out_and_local_only()
	await _verify_uncertain_command_stays_pending()
	await _verify_pending_resolution_rules()
	await _verify_superseded_session_policy()
	_check(_dev_save_fingerprint() == dev_before, "Development Save (%s) is untouched" % SaveStore.DEFAULT_PATH)
	await process_frame  # let the freed clients and their HTTP nodes go
	if _failures == 0:
		print("VS-01 WP01 online contract verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_rules_parity() -> void:
	var path := ProjectSettings.globalize_path("res://").path_join("../nakama/tests/fixtures/rules_vectors.json").simplify_path()
	var text := FileAccess.get_file_as_string(path)
	_check(not text.is_empty(), "Golden vectors exist at %s" % path)
	var stored: Variant = JSON.parse_string(text)
	var current := RulesVectors.build_vectors()
	_check(typeof(stored) == TYPE_DICTIONARY, "Golden vectors parse as JSON")
	if typeof(stored) != TYPE_DICTIONARY:
		return
	# Round-trip the fresh vectors through JSON so int / float typing matches.
	var fresh: Variant = JSON.parse_string(JSON.stringify(current))
	for section in fresh:
		_check(stored.has(section), "Golden vectors have section %s" % section)
		_check(JSON.stringify(stored.get(section)) == JSON.stringify(fresh[section]),
			"GDScript rules still produce the server golden vectors (%s); regenerate only for an approved rule change" % section)
	_check((stored["dynamic_reference"] as Array).size() > 1000, "Price vectors cover the parameter grid")


func _verify_isolation() -> void:
	var dir := DirAccess.open("res://scripts")
	for file in dir.get_files():
		# The online layer itself: the WP01 client, the WP01-B adapter, the
		# WP01-C Online TEST mode, the WP01-E combat adapter / TEST mode
		# (separate scenes, not the normal game) and the WP01-G C2-E2 bounded
		# read transport owned by the WP01 client.
		if file.ends_with(".gd") and not file in ["online_progress_client.gd", "online_trade_adapter.gd", "online_trade_test_mode.gd",
				"online_combat_adapter.gd", "online_combat_test_mode.gd", "online_progress_resume_test_mode.gd",
				"online_read_transport.gd"]:
			var source := FileAccess.get_file_as_string("res://scripts/" + file)
			_check(not source.contains("OnlineProgressClient") and not source.contains("OnlineTradeAdapter") and not source.contains("OnlineCombatAdapter") and not source.contains("Nakama"),
				"WP01 / WP01-B do not wire the online layer into gameplay yet (%s)" % file)
	var project := FileAccess.get_file_as_string("res://project.godot")
	_check(not project.contains("heroiclabs"), "Nakama SDK is not an autoload")
	_check(SaveStore.VERSION == 14, "Save schema stays v14 (D6: assess only)")
	_check(SaveStore.DEFAULT_PATH == "user://myrial_save.json", "Development Save path unchanged")
	var client_source := FileAccess.get_file_as_string("res://scripts/online_progress_client.gd")
	for forbidden in ["SaveStore", "user://", "FileAccess", "Wallet", "TradeService", "MarketState", "\"money\"", "\"price\""]:
		_check(not client_source.contains(forbidden), "Online client never touches local saves or sends client-side values (%s)" % forbidden)


func _verify_idempotency_keys() -> void:
	var seen := {}
	var regex := RegEx.create_from_string("^[A-Za-z0-9_-]{16,64}$")
	for i in range(2000):
		var key := OnlineProgressClient.new_idempotency_key()
		if regex.search(key) == null:
			_check(false, "Idempotency key matches the server format: %s" % key)
		seen[key] = true
	_check(seen.size() == 2000, "2000 idempotency keys are unique and match the server format")


func _verify_signed_out_and_local_only() -> void:
	var client := _new_client("127.0.0.1", CLOSED_PORT)
	_check((await client.buy("A", "test_good_01", 10))["status"] == OnlineProgressClient.NO_GAMEPLAY_SESSION, "No trade without a gameplay session")
	_check((await client.begin_gameplay_session())["status"] == OnlineProgressClient.NOT_SIGNED_IN, "No gameplay session without sign-in")
	_check((await client.refresh_progress())["status"] == OnlineProgressClient.NO_GAMEPLAY_SESSION, "No progress read without an active gameplay session (policy A)")
	_check((await client.sign_in_apple(""))["reason"] == "missing_identity_token", "Apple sign-in needs an identity token")
	client.configure("api.example.invalid", 443, "https")
	_check(not client.is_local_test_host(), "Remote host is not a local test host")
	var remote := await client.sign_in_email_test("a@myrial.test", "localtest-123")
	_check(remote["status"] == OnlineProgressClient.REJECTED and remote["reason"] == "email_test_auth_local_only", "Email test accounts are refused for non-local hosts (D1)")
	for local_host in ["127.0.0.1", "localhost"]:
		client.configure(local_host, CLOSED_PORT)
		_check(client.is_local_test_host(), "%s is a local test host" % local_host)
	client.queue_free()


## Server unreachable mid-command: the client must not guess. The command stays
## pending under its key, the cache is not changed, and recovery resends the
## SAME key (the server then answers once; see the live test).
func _verify_uncertain_command_stays_pending() -> void:
	var client := _new_client("127.0.0.1", CLOSED_PORT)
	client.timeout_sec = 1
	client._session = NakamaSession.new(_unsigned_token("00000000-0000-0000-0000-00000000000a"), false)
	client._gameplay_session_id = "00000000-0000-0000-0000-00000000000b"
	client._confirmed = {"money": 10000, "backpack": {}}
	_check(client.is_signed_in(), "Test session is accepted locally")
	client._get_client().auto_retry = false
	var result := await client.buy("A", "test_good_01", 10)
	_check(result["status"] == OnlineProgressClient.UNCERTAIN, "Unreachable server leaves the outcome uncertain: %s" % str(result))
	var pending := client.get_pending_commands()
	_check(pending.size() == 1 and pending.has(result["idempotency_key"]), "The uncertain command stays pending under its key")
	_check(pending[result["idempotency_key"]] == {"action": "buy", "city_id": "A", "good_id": "test_good_01", "quantity": 10}, "Pending command holds only the order, no client-side values")
	_check(client.get_confirmed_progress() == {"money": 10000, "backpack": {}}, "No local apply: the cache keeps the last server-confirmed state")
	var copy := client.get_confirmed_progress()
	copy["money"] = 999999
	_check(client.get_confirmed_progress()["money"] == 10000, "Callers cannot edit the confirmed cache")
	var recovered := await client.recover_pending()
	_check(recovered.size() == 1 and recovered[0]["idempotency_key"] == result["idempotency_key"] and recovered[0]["resolve"], "Recovery asks vs01_trade_resolve with the same idempotency key")
	_check(client.get_pending_commands().size() == 1, "Still uncertain while the server is unreachable")
	# WP01-H (supersedes the WP01-B export / import): a restarted app reads the
	# order back from the Pending Store with the original key; import is refused.
	var restarted := _new_client("127.0.0.1", CLOSED_PORT)
	_check(not restarted.import_pending_commands(client.get_pending_commands()), "Importing pending commands is refused (WP01-H FIX-01)")
	restarted._accept_session(NakamaSession.new(_unsigned_token("00000000-0000-0000-0000-00000000000a"), false))
	_check(restarted.get_pending_commands() == client.get_pending_commands(), "Pending commands survive a restart through the Pending Store")
	client.queue_free()
	restarted.queue_free()


## Only a receipt resolves a command. Ambiguous storage errors and refused
## RETRIES keep it pending; a NEW command refused before any decision is gone.
func _verify_pending_resolution_rules() -> void:
	var client := ScriptedClient.new()
	root.add_child(client)
	_scripted(client, "00000000-0000-0000-0000-00000000000c")
	for grpc in [2, 4, 13, 14]:
		client.answers = [_server_refusal(grpc, "storage_unavailable")]
		var ambiguous := await client.buy("A", "test_good_01", 1)
		_check(ambiguous["status"] == OnlineProgressClient.UNCERTAIN and ambiguous["pending"], "gRPC %d (commit unknown) keeps the command pending as uncertain" % grpc)
		client._pending.clear()
		client._pending_state.clear()
	for refusal in [[3, "unexpected_fields"], [7, "permission_denied"], [8, "rate_limited"], [9, "no_gameplay_session"], [10, "gameplay_session_superseded"]]:
		client.answers = [_server_refusal(refusal[0], refusal[1])]
		var fresh := await client.buy("A", "test_good_01", 1)
		_check(fresh["status"] == OnlineProgressClient.REJECTED and not fresh["pending"], "A new command refused with %s never applied and is not kept" % refusal[1])
	# The superseded refusal above also marked the session (policy A, checked
	# in _verify_superseded_session_policy); take it back for the next case.
	_check(client.is_gameplay_session_superseded(), "A superseded refusal marks the session")
	client._superseded = false
	# A command whose first attempt got no answer, then a refused retry
	# (superseded / rate limited): the original outcome is still unknown.
	client.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "no answer"}]
	var lost := await client.buy("A", "test_good_01", 1)
	var key: String = lost["idempotency_key"]
	_check(lost["pending"], "No answer keeps the new command pending")
	for refusal in [[10, "gameplay_session_superseded"], [8, "rate_limited"], [14, "storage_unavailable"]]:
		client.answers = [_server_refusal(refusal[0], refusal[1])]
		client._superseded = false  # each case starts from an active session
		client.sent.clear()
		var retried := await client.recover_pending()
		_check(retried.size() == 1 and retried[0]["idempotency_key"] == key and retried[0]["pending"], "A retry refused with %s keeps the command pending" % refusal[1])
		_check(client.sent == [OnlineProgressClient.RPC_TRADE_RESOLVE], "The retry is vs01_trade_resolve, never vs01_trade (%s)" % str(client.sent))
	client._superseded = false
	client.answers = [_server_receipt("applied")]
	var resolved := await client.recover_pending()
	_check(resolved.size() == 1 and resolved[0]["status"] == OnlineProgressClient.OK and not resolved[0]["pending"] and client.get_pending_commands().is_empty(), "A receipt resolves the pending command")
	client.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "no answer"}, _server_receipt("rejected")]
	await client.buy("A", "test_good_06", 10)
	await client.recover_pending()
	_check(client.get_pending_commands().is_empty(), "A business-rule rejection receipt also resolves it")
	client.queue_free()


## Session policy A on the client: the first "superseded" answer raises the
## signal once and blocks further reads / actions locally (nothing is sent);
## begin_gameplay_session() takes the character back and clears it.
func _verify_superseded_session_policy() -> void:
	var client := ScriptedClient.new()
	root.add_child(client)
	_wipe("user://online_pending")
	_scripted(client, "00000000-0000-0000-0000-00000000000d")
	var prompts := [0]
	client.gameplay_session_superseded.connect(func(): prompts[0] += 1)
	client.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "no answer"}]
	var lost := await client.buy("A", "test_good_01", 1)
	client.answers = [_server_refusal(10, "gameplay_session_superseded")]
	var refused_read := await client.refresh_progress()
	_check(refused_read["reason"] == "gameplay_session_superseded" and client.is_gameplay_session_superseded() and prompts[0] == 1, "A superseded answer marks the session and signals the player once")
	client.answers = []  # any network call would now fail the test (pop_front on empty)
	_check((await client.refresh_progress())["reason"] == "gameplay_session_superseded", "Superseded: reading is refused locally")
	var blocked := await client.buy("A", "test_good_01", 1)
	_check(blocked["reason"] == "gameplay_session_superseded" and not blocked["pending"], "Superseded: a new action is refused locally and not kept")
	var kept := await client.recover_pending()
	_check(kept.size() == 1 and kept[0]["pending"] and client.get_pending_commands().has(lost["idempotency_key"]), "Superseded: the uncertain command stays pending for later recovery")
	_check(prompts[0] == 1, "The prompt is raised once, not per call")
	client.answers = [{"status": OnlineProgressClient.OK, "reason": "", "data": {"gameplay_session_id": "00000000-0000-0000-0000-00000000000e", "progress": {"money": 5}}}]
	_check((await client.begin_gameplay_session())["status"] == OnlineProgressClient.OK and not client.is_gameplay_session_superseded(), "Taking the character back clears the superseded state")
	client.answers = [_server_receipt("applied")]
	var resolved := await client.recover_pending()
	_check(resolved.size() == 1 and resolved[0]["status"] == OnlineProgressClient.OK and client.get_pending_commands().is_empty(), "After taking back, the pending command resolves")
	client.queue_free()


func _new_client(host: String, port: int) -> OnlineProgressClient:
	var client := OnlineProgressClient.new()
	client.configure(host, port)
	root.add_child(client)
	return client


## A syntactically valid, UNSIGNED token far in the future. Only used against
## a closed port; no server ever sees it.
static func _unsigned_token(user_id: String) -> String:
	var header := Marshalls.utf8_to_base64(JSON.stringify({"alg": "none"}))
	var body := Marshalls.utf8_to_base64(JSON.stringify({"uid": user_id, "usn": "offline", "exp": 4102444800}))
	return "%s.%s.x" % [header.trim_suffix("=").trim_suffix("="), body.trim_suffix("=").trim_suffix("=")]


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		_wipe(dir + "/" + sub)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)
	DirAccess.remove_absolute(dir)


func _dev_save_fingerprint() -> String:
	if not FileAccess.file_exists(SaveStore.DEFAULT_PATH):
		return "absent"
	return FileAccess.get_sha256(SaveStore.DEFAULT_PATH)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
		print("FAILED: " + message)
