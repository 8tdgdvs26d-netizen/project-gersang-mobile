extends SceneTree

## VS-01 WP01 — LIVE probe: the real Nakama Godot SDK (v3.4.0) through
## OnlineProgressClient against the LOCAL Nakama server. Not a verify_* script,
## because it needs the server: run it with nakama/scripts/run_live_tests.sh.
##
##   godot --headless --path godot --script res://tests/live_vs01_wp01_nakama.gd -- 127.0.0.1 17350
##
## Uses fresh local email TEST accounts (D1) on disposable server data.

var _checks := 0
var _failures := 0
var _host := "127.0.0.1"
var _port := 17350
var _run_id := ""


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.size() == 2:
		_host = args[0]
		_port = int(args[1])
	_run_id = "%d%04d" % [Time.get_unix_time_from_system(), randi() % 10000]
	var dev_before := _dev_save_fingerprint()
	await _run()
	_check(_dev_save_fingerprint() == dev_before, "Development Save is untouched")
	await process_frame
	if _failures == 0:
		print("VS-01 WP01 live Nakama probe passed (%d checks, run %s)" % [_checks, _run_id])
	quit(1 if _failures > 0 else 0)


func _run() -> void:
	var email1 := "p1-%s@myrial.test" % _run_id
	var email2 := "p2-%s@myrial.test" % _run_id
	var password := "localtest-%s" % _run_id

	# 1. Two separate test accounts through the SDK (D1 local email).
	var p1a := _new_client()
	var p2 := _new_client()
	_check((await p1a.sign_in_email_test(email1, password))["status"] == OnlineProgressClient.OK, "Player 1 signs in with a local email test account")
	_check((await p2.sign_in_email_test(email2, password))["status"] == OnlineProgressClient.OK, "Player 2 signs in with a local email test account")
	_check(p1a.get_user_id() != "" and p1a.get_user_id() != p2.get_user_id(), "Two different accounts")

	# 2. Guest-style identities are refused (A3 / D1).
	var device: NakamaSession = await p1a._get_client().authenticate_device_async("myrial-guest-device-%s" % _run_id, null, true)
	_check(device.is_exception() and device.get_exception().grpc_status_code == 7, "Device (guest) sign-in is refused")
	var custom: NakamaSession = await p1a._get_client().authenticate_custom_async("myrial-custom-%s" % _run_id, null, true)
	_check(custom.is_exception() and custom.get_exception().grpc_status_code == 7, "Custom-id sign-in is refused")

	# 3. Server-authoritative buy / sell with server prices.
	_check((await p1a.begin_gameplay_session())["status"] == OnlineProgressClient.OK, "Player 1 starts a gameplay session")
	_check(p1a.get_confirmed_progress()["money"] == 10000, "Fresh server progress starts at 10000")
	var bought := await p1a.buy("A", "test_good_01", 10)
	_check(bought["status"] == OnlineProgressClient.OK and bought["receipt"]["status"] == "applied", "Buy is applied by the server: %s" % str(bought.get("receipt", bought)))
	_check(bought["receipt"]["total"] == 840 and p1a.get_confirmed_progress()["money"] == 9160, "Buy uses the server price (10 x 84)")
	var sold := await p1a.sell("B", "test_good_01", 10)
	_check(sold["status"] == OnlineProgressClient.OK and sold["receipt"]["total"] == 1140, "Sell uses the server buyback price (10 x 114)")
	_check(p1a.get_confirmed_progress()["money"] == 10300 and p1a.get_confirmed_progress()["backpack"].is_empty(), "Cache shows the server-confirmed result")
	var too_much := await p1a.buy("A", "test_good_06", 10)
	_check(too_much["receipt"]["status"] == "rejected" and too_much["receipt"]["reason"] == "insufficient_money", "Unaffordable order is rejected by the server")

	# 4. D2: a new gameplay session (second device) takes over.
	var p1b := _new_client()
	_check((await p1b.sign_in_email_test(email1, password, false))["status"] == OnlineProgressClient.OK, "Player 1 signs in on a second device")
	_check(p1b.get_user_id() == p1a.get_user_id(), "Same account on both devices")
	_check((await p1b.begin_gameplay_session())["status"] == OnlineProgressClient.OK, "Second device starts a gameplay session")
	_check(p1b.get_confirmed_progress()["money"] == 10300, "Second device reads the same server progress")
	var stale := await p1a.buy("A", "test_good_01", 1)
	_check(stale["status"] == OnlineProgressClient.REJECTED and stale["reason"] == "gameplay_session_superseded", "Old session can no longer write: %s" % str(stale))
	_check((await p1b.buy("A", "test_good_01", 1))["receipt"]["status"] == "applied", "New session can write")
	var money_after_takeover: int = p1b.get_confirmed_progress()["money"]

	# 5. Network loss mid-command: uncertain, then deterministic recovery.
	p1b.configure(_host, 1)
	p1b.timeout_sec = 1
	var lost := await p1b.buy("A", "test_good_02", 1)
	_check(lost["status"] == OnlineProgressClient.UNCERTAIN, "No server answer leaves the order uncertain")
	_check(p1b.get_confirmed_progress()["money"] == money_after_takeover, "Nothing applied locally while uncertain")
	p1b.configure(_host, _port)
	var recovered := await p1b.recover_pending()
	_check(recovered.size() == 1 and recovered[0]["status"] == OnlineProgressClient.OK and recovered[0]["replayed"] == false, "Recovery applies the order exactly once")
	_check(p1b.get_pending_commands().is_empty(), "Nothing left pending")
	var money_after_recovery: int = p1b.get_confirmed_progress()["money"]
	_check(money_after_recovery == money_after_takeover - recovered[0]["receipt"]["total"], "Money moved once")

	# 6. Response lost after the server applied it, then app restart: the same
	#    key from a NEW session returns the original receipt, nothing twice.
	var key := OnlineProgressClient.new_idempotency_key()
	var command := {"action": "buy", "city_id": "B", "good_id": "test_good_02", "quantity": 1}
	var original := await p1b._trade(command, key)
	_check(original["receipt"]["status"] == "applied", "Command applied before the 'lost' response")
	var restarted := _new_client()
	await restarted.sign_in_email_test(email1, password, false)
	await restarted.begin_gameplay_session()
	restarted.import_pending_commands({key: command})
	var replay := await restarted.recover_pending()
	_check(replay.size() == 1 and replay[0]["replayed"] == true, "Restarted app gets the original receipt back")
	_check(replay[0]["receipt"] == original["receipt"], "Replay receipt is identical")
	_check(restarted.get_confirmed_progress()["money"] == original["receipt"]["money_after"], "Retry did not charge again")

	# 7. Account isolation and API lock-down.
	var nk2: NakamaClient = p2._get_client()
	var read_other = await nk2.read_storage_objects_async(p2._session, [NakamaStorageObjectId.new("vs01_wp01_progress", "trade", p1a.get_user_id())])
	_check(not read_other.is_exception() and read_other.objects.is_empty(), "Player 2 cannot read Player 1's progress")
	var forged := NakamaWriteStorageObject.new("vs01_wp01_progress", "trade", 1, 1, JSON.stringify({"money": 99999999}), "")
	var write_own = await nk2.write_storage_objects_async(p2._session, [forged])
	_check(write_own.is_exception() and write_own.get_exception().grpc_status_code == 7, "Client storage writes are refused (no self-made progress)")
	var forged_rpc = await nk2.rpc_async(p2._session, "vs01_trade", JSON.stringify({"gameplay_session_id": "00000000-0000-0000-0000-000000000000", "idempotency_key": key, "action": "buy", "city_id": "A", "good_id": "test_good_01", "quantity": 1, "price": 1}))
	_check(forged_rpc.is_exception() and forged_rpc.get_exception().grpc_status_code == 3, "Client-supplied price is refused")
	var reward := await restarted.claim_combat_reward({"money": 50000, "exp": 999})
	_check(reward["status"] == OnlineProgressClient.REJECTED and reward["reason"] == "combat_reward_requires_server_validation", "Unverified combat reward is refused (D4)")
	_check((await restarted.refresh_progress())["data"]["progress"]["money"] == original["receipt"]["money_after"], "Reward attempt changed nothing")
	_check((await p2.begin_gameplay_session())["data"]["progress"]["money"] == 10000, "Player 2's progress is untouched by Player 1")

	for client in [p1a, p1b, p2, restarted]:
		client.queue_free()


func _new_client() -> OnlineProgressClient:
	var client := OnlineProgressClient.new()
	client.configure(_host, _port)
	root.add_child(client)
	return client


func _dev_save_fingerprint() -> String:
	if not FileAccess.file_exists(SaveStore.DEFAULT_PATH):
		return "absent"
	return FileAccess.get_sha256(SaveStore.DEFAULT_PATH)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("ok   - " + message)
	else:
		_failures += 1
		push_error("FAILED: " + message)
		print("FAILED: " + message)
