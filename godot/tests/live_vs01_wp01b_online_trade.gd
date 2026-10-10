extends SceneTree

## VS-01 WP01-B — LIVE integration harness: Godot (OnlineTradeAdapter +
## OnlineProgressClient + Nakama Godot SDK v3.4.0) against the LOCAL Nakama
## server, for the ONE representative good. Not a verify_* script, because it
## needs the server, the lossy proxy and Docker: nakama/scripts/run_live_tests.sh
## runs it. Every scenario uses its own disposable local email test account.
##
##   godot --headless --path godot --script res://tests/live_vs01_wp01b_online_trade.gd -- \
##     <host> <api-port> <lossy-proxy-port> <nakama-compose-dir> <docker-binary> <real-home>
##
## <real-home> is the user's normal HOME, used ONLY to run docker (its config
## and compose plugin live there). Godot itself runs with an isolated HOME so
## user:// is a disposable folder.

const REP := OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID
const CLOSED_PORT := 1

var _checks := 0
var _failures := 0
var _host := "127.0.0.1"
var _api_port := 17350
var _proxy_port := 17370
var _compose_dir := ""
var _docker := "docker"
var _real_home := ""
var _run_id := ""
var _account_seq := 0


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.size() == 6:
		_host = args[0]
		_api_port = int(args[1])
		_proxy_port = int(args[2])
		_compose_dir = args[3]
		_docker = args[4]
		_real_home = args[5]
	_run_id = "%d%04d" % [Time.get_unix_time_from_system(), randi() % 10000]
	var dev_before := _dev_save_fingerprint()
	print("Isolated user:// for this run: %s" % OS.get_user_data_dir())
	print("Development Save fingerprint before: %s" % dev_before)
	await _scenario_basic_trade_and_mirror()
	await _scenario_concurrent_trades()
	await _scenario_response_lost_after_commit()
	await _scenario_network_down_before_server()
	await _scenario_session_takeover()
	await _scenario_server_restart()
	await _scenario_app_kill_limitation()
	await _scenario_rate_limit()
	var dev_after := _dev_save_fingerprint()
	print("Development Save fingerprint after: %s" % dev_after)
	_check(dev_after == dev_before, "Development Save is untouched")
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-B live online trade harness passed (%d checks, run %s)" % [_checks, _run_id])
	quit(1 if _failures > 0 else 0)


# --- Scenarios -------------------------------------------------------------------

func _scenario_basic_trade_and_mirror() -> void:
	print("== S1 basic buy / sell, server-confirmed mirror, scope guard")
	var acc := await _new_account("s1")
	var a: OnlineTradeAdapter = acc["adapter"]
	_check(not a.has_confirmed_state(), "S1 no mirror before the server confirms anything")
	_check((await a.begin())["status"] == OnlineProgressClient.OK and a.get_wallet().get_balance() == 10000, "S1 session begin: mirror = server 10000")
	var bought := await a.buy("A", 10)
	_check(bought["success"] and bought["total_value"] == 840 and bought["unit_price"] == 84, "S1 buy A x10 confirmed by the server at 84: %s" % str(bought["receipt"]))
	_check(a.get_wallet().get_balance() == 9160 and a.get_inventory().get_quantity(REP) == 10, "S1 mirror shows the confirmed buy")
	var sold := await a.sell("B", 10)
	_check(sold["success"] and sold["total_value"] == 1140 and sold["unit_price"] == 114, "S1 sell B x10 confirmed at 114")
	_check(a.get_wallet().get_balance() == 10300 and a.get_inventory().get_quantity(REP) == 0, "S1 mirror shows the confirmed sell")
	var broke := await a.buy("A", 10)
	_check(broke["success"] and a.get_inventory().get_quantity(REP) == 10, "S1 buy again")
	var too_many := await a.sell("B", 10)
	var none_left := await a.sell("B", 1)
	_check(too_many["success"] and not none_left["success"] and none_left["reason"] == "insufficient_cargo", "S1 server rule rejection keeps TradeService's reason code")
	var out_of_scope := await a.trade_good("buy", "A", "test_good_02", 1)
	_check(out_of_scope["reason"] == OnlineTradeAdapter.OUT_OF_SCOPE_REASON, "S1 other goods are refused locally (WP01-B scope)")
	await _assert_mirror_equals_server(a, "S1")
	await _free(acc)


func _scenario_concurrent_trades() -> void:
	print("== S2 concurrent trades from one Godot client")
	var acc := await _new_account("s2")
	var a: OnlineTradeAdapter = acc["adapter"]
	await a.begin()
	var results := await _run_concurrently(a, 12, "buy", "A", 1)
	var applied := results.filter(func(r): return r["success"])
	_check(applied.size() == 12, "S2 12 concurrent buys all decided and applied: %d" % applied.size())
	var keys := {}
	var spent := 0
	for r in results:
		keys[r["idempotency_key"]] = true
		spent += int(r["total_value"])
	_check(keys.size() == 12, "S2 each order had its own idempotency key")
	# PR #133 review: check BEFORE any refresh, which would hide a rollback.
	# Answers arrive in any order; the mirror must sit at the newest receipt.
	var newest: Dictionary = {}
	for r in results:
		if newest.is_empty() or int(r["receipt"]["progress_revision"]) > int(newest["progress_revision"]):
			newest = r["receipt"]
	_check(a.get_confirmed_revision() == int(newest["progress_revision"]), "S2 without refresh: mirror is at the newest receipt's revision %d (got %d)" % [int(newest["progress_revision"]), a.get_confirmed_revision()])
	_check(a.get_wallet().get_balance() == int(newest["money_after"]) and a.get_inventory().get_quantity(REP) == int(newest["carried_after"]), "S2 without refresh: mirror money / goods equal the newest receipt (%d / %d)" % [int(newest["money_after"]), int(newest["carried_after"])])
	await a.refresh()
	_check(a.get_inventory().get_quantity(REP) == 12 and a.get_wallet().get_balance() == 10000 - spent, "S2 server state = sum of the 12 receipts (none lost, none doubled)")
	await _assert_mirror_equals_server(a, "S2")
	await _free(acc)


func _scenario_response_lost_after_commit() -> void:
	print("== S3 response lost AFTER the server committed (lossy proxy) + SDK retries")
	var acc := await _new_account("s3")
	var a: OnlineTradeAdapter = acc["adapter"]
	await a.begin()
	var expected_money := 10000
	var expected_goods := 0
	# Prototype order sizes are 1 or 10 only (TradeService rule, unchanged).
	var orders := [["buy", "A", 10], ["sell", "B", 10], ["buy", "A", 1]]
	for order in orders:
		var stats_before := _proxy_stats()
		a.get_client().configure(_host, _proxy_port)
		var mirror_before := a.get_wallet().get_balance()
		var lost: Dictionary
		if order[0] == "buy":
			lost = await a.buy(order[1], order[2])
		else:
			lost = await a.sell(order[1], order[2])
		var sent := int(_proxy_stats().get("trade_requests", 0)) - int(stats_before.get("trade_requests", 0))
		_check(lost["online_status"] == OnlineProgressClient.UNCERTAIN and lost["pending"] and not lost["success"], "S3 %s: client sees no answer, order pending" % str(order))
		_check(a.get_wallet().get_balance() == mirror_before, "S3 %s: mirror unchanged while uncertain" % str(order))
		print("   evidence: %s reached the server %d time(s) through the SDK's own retries (same key)" % [str(order), sent])
		_check(sent >= 1, "S3 %s: the request reached the server" % str(order))
		a.get_client().configure(_host, _api_port)
		var recovered := await a.recover()
		_check(recovered.size() == 1 and recovered[0]["success"] and recovered[0]["replayed"], "S3 %s: recovery returns the ORIGINAL receipt (replayed)" % str(order))
		var total := int(recovered[0]["total_value"])
		expected_money += -total if order[0] == "buy" else total
		expected_goods += order[2] if order[0] == "buy" else -order[2]
		_check(a.get_wallet().get_balance() == expected_money and a.get_inventory().get_quantity(REP) == expected_goods, "S3 %s: money and goods moved exactly once" % str(order))
	_check(a.pending_count() == 0, "S3 nothing left pending")
	await _assert_mirror_equals_server(a, "S3")
	await _free(acc)


func _scenario_network_down_before_server() -> void:
	print("== S4 network down BEFORE the server (closed port)")
	var acc := await _new_account("s4")
	var a: OnlineTradeAdapter = acc["adapter"]
	await a.begin()
	a.get_client().configure(_host, CLOSED_PORT)
	a.get_client().timeout_sec = 2
	var lost := await a.buy("A", 10)
	_check(lost["online_status"] == OnlineProgressClient.UNCERTAIN and lost["pending"], "S4 unreachable server: uncertain, pending")
	_check(a.get_wallet().get_balance() == 10000, "S4 mirror unchanged")
	a.get_client().configure(_host, _api_port)
	var recovered := await a.recover()
	_check(recovered.size() == 1 and recovered[0]["success"] and not recovered[0]["replayed"], "S4 recovery applies the order for the first time")
	_check(a.get_wallet().get_balance() == 9160 and a.get_inventory().get_quantity(REP) == 10, "S4 applied exactly once")
	var again := await a.recover()
	_check(again.is_empty(), "S4 nothing pending afterwards")
	await _assert_mirror_equals_server(a, "S4")
	await _free(acc)


func _scenario_session_takeover() -> void:
	print("== S5 session takeover between two devices (policy A)")
	var dev_a := await _new_account("s5")
	var a: OnlineTradeAdapter = dev_a["adapter"]
	await a.begin()
	_check((await a.buy("A", 10))["success"], "S5 device A trades")
	# Device A has a command in flight whose answer is lost, then B takes over.
	a.get_client().configure(_host, _proxy_port)
	var in_flight := await a.buy("A", 1)
	a.get_client().configure(_host, _api_port)
	_check(in_flight["pending"], "S5 device A has an uncertain order")
	var dev_b := await _same_account(dev_a)
	var b: OnlineTradeAdapter = dev_b["adapter"]
	var prompts := [0]
	a.get_client().gameplay_session_superseded.connect(func(): prompts[0] += 1)
	_check((await b.begin())["status"] == OnlineProgressClient.OK, "S5 device B takes over")
	_check(b.get_inventory().get_quantity(REP) == 11, "S5 device B sees the server state, including A's lost-answer order (11)")
	var a_money := a.get_wallet().get_balance()
	var stale := await a.buy("A", 1)
	_check(not stale["success"] and stale["reason"] == "gameplay_session_superseded" and prompts[0] == 1, "S5 device A is refused and told (signal once)")
	_check((await a.refresh())["reason"] == "gameplay_session_superseded" and a.get_wallet().get_balance() == a_money, "S5 device A can no longer read; its mirror is unchanged")
	var a_recover := await a.recover()
	_check(a_recover.size() == 1 and not a_recover[0]["success"] and a.pending_count() == 1, "S5 device A cannot recover while superseded; the order stays pending")
	_check((await b.buy("A", 1))["success"], "S5 device B trades")
	_check((await a.begin())["status"] == OnlineProgressClient.OK, "S5 device A takes the character back")
	var back := await a.recover()
	_check(back.size() == 1 and back[0]["success"] and back[0]["replayed"], "S5 after taking back, A's pending order resolves to its original receipt")
	_check(a.get_inventory().get_quantity(REP) == 12, "S5 10 + 1 (lost answer) + 1 (device B) = 12: nothing doubled, nothing lost")
	_check((await b.refresh())["reason"] == "gameplay_session_superseded", "S5 device B is now the superseded one")
	await _assert_mirror_equals_server(a, "S5")
	await _free(dev_b)
	await _free(dev_a)


func _scenario_server_restart() -> void:
	print("== S6 server restart with an uncertain order")
	if _compose_dir.is_empty():
		_check(false, "S6 needs the compose dir, docker binary and real HOME arguments")
		return
	var acc := await _new_account("s6")
	var a: OnlineTradeAdapter = acc["adapter"]
	await a.begin()
	_check((await a.buy("A", 10))["success"], "S6 confirmed buy before the restart")
	a.get_client().configure(_host, _proxy_port)
	var lost := await a.buy("A", 1)
	a.get_client().configure(_host, _api_port)
	_check(lost["pending"], "S6 an order with a lost answer is pending")
	var restart_output := []
	var code := OS.execute("/usr/bin/env", ["HOME=" + _real_home, _docker, "compose", "-f", _compose_dir.path_join("docker-compose.yml"), "restart", "nakama"], restart_output, true)
	_check(code == 0, "S6 local Nakama container restarted")
	var t0 := Time.get_ticks_msec()
	var healthy := false
	for attempt in range(90):
		if OS.execute("curl", ["-sf", "-o", "/dev/null", "http://%s:%d/healthcheck" % [_host, _api_port]]) == 0:
			healthy = true
			break
		OS.delay_msec(1000)
	print("   restart: docker exit %d, healthy=%s after %d ms" % [code, healthy, Time.get_ticks_msec() - t0])
	_check(healthy, "S6 local Nakama healthy again after the restart")
	var after := await a.refresh()
	_check(after["status"] == OnlineProgressClient.OK and a.get_inventory().get_quantity(REP) == 11, "S6 after restart: same session, confirmed state kept (10 + 1): %s" % after["status"])
	var recovered := await a.recover()
	_check(recovered.size() == 1 and recovered[0]["replayed"] and a.get_inventory().get_quantity(REP) == 11, "S6 recovery after restart replays, applies nothing twice")
	await _assert_mirror_equals_server(a, "S6")
	await _free(acc)


## Pending commands live in RAM only (WP01-B limit, not changed here).
func _scenario_app_kill_limitation() -> void:
	print("== S7 app kill: documented LIMITATION (pending commands are RAM-only)")
	var first := await _new_account("s7")
	var a: OnlineTradeAdapter = first["adapter"]
	await a.begin()
	# Kill AFTER the server committed (answer lost).
	a.get_client().configure(_host, _proxy_port)
	var lost := await a.buy("A", 10)
	_check(lost["pending"], "S7 an order with a lost answer is pending in the running app")
	var lost_key: String = lost["idempotency_key"]
	await _free(first)  # app killed: its memory, including the pending list, is gone
	var restarted := await _same_account(first)
	var r: OnlineTradeAdapter = restarted["adapter"]
	await r.begin()
	_check(r.pending_count() == 0, "S7 LIMITATION: the restarted app has no pending command to recover")
	_check(r.get_inventory().get_quantity(REP) == 10 and r.get_wallet().get_balance() == 9160, "S7 server state is still correct after the kill (the order applied once; nothing lost)")
	_check((await r.recover()).is_empty(), "S7 LIMITATION: the killed order cannot be matched to its receipt by the new app")
	var reissued := await r.buy("A", 10)
	_check(reissued["success"] and not reissued["replayed"] and reissued["idempotency_key"] != lost_key, "S7 LIMITATION: a player re-issuing the order creates a SECOND, separate trade")
	_check(r.get_inventory().get_quantity(REP) == 20, "S7 the re-issued order applied as a new order (10 + 10)")
	# Kill BEFORE the order reached the server.
	r.get_client().configure(_host, CLOSED_PORT)
	r.get_client().timeout_sec = 2
	var never_sent := await r.buy("A", 1)
	_check(never_sent["pending"], "S7 an order that never reached the server is pending")
	await _free(restarted)
	var third := await _same_account(first)
	var t: OnlineTradeAdapter = third["adapter"]
	await t.begin()
	_check(t.get_inventory().get_quantity(REP) == 20 and t.pending_count() == 0, "S7 that order never applied; the server state is unchanged")
	await _free(third)


func _scenario_rate_limit() -> void:
	print("== S8 rate limit seen through the adapter")
	var acc := await _new_account("s8")
	var a: OnlineTradeAdapter = acc["adapter"]
	await a.begin()
	var results := await _run_concurrently(a, 36, "buy", "A", 1)
	var applied := results.filter(func(r): return r["success"]).size()
	var limited := results.filter(func(r): return r["reason"] == "rate_limited").size()
	print("   evidence: 36 concurrent buys -> applied %d, rate_limited %d" % [applied, limited])
	_check(applied <= 30 and limited >= 6 and applied + limited == 36, "S8 at most 30 per 10 s; refused orders are definite (applied %d, limited %d)" % [applied, limited])
	_check(a.pending_count() == 0, "S8 rate-limited new orders are not kept pending")
	await a.refresh()
	_check(a.get_inventory().get_quantity(REP) == applied, "S8 server state = accepted orders only")
	await _assert_mirror_equals_server(a, "S8")
	await _free(acc)


# --- Helpers ---------------------------------------------------------------------

func _new_account(label: String) -> Dictionary:
	_account_seq += 1
	var email := "wp01b-%s-%s-%d@myrial.test" % [label, _run_id, _account_seq]
	var device := await _device(email, true)
	_check(device["signed_in"], "%s disposable local test account signed in" % label)
	return device


func _same_account(other: Dictionary) -> Dictionary:
	return await _device(other["email"], false)


func _device(email: String, create: bool) -> Dictionary:
	var client := OnlineProgressClient.new()
	client.configure(_host, _api_port)
	root.add_child(client)
	var signed := await client.sign_in_email_test(email, "localtest-%s" % _run_id, create)
	if signed["status"] != OnlineProgressClient.OK:
		print("   sign-in result: %s" % str(signed))
	return {"client": client, "adapter": OnlineTradeAdapter.new(client), "email": email,
		"signed_in": signed["status"] == OnlineProgressClient.OK}


func _free(device: Dictionary) -> void:
	device["adapter"] = null
	(device["client"] as Node).queue_free()
	await process_frame


## Starts `count` orders without awaiting each, then waits for all of them.
func _run_concurrently(a: OnlineTradeAdapter, count: int, action: String, city: String, quantity: int) -> Array:
	var results := []
	for i in range(count):
		_one_order(a, action, city, quantity, results)
	while results.size() < count:
		await process_frame
	return results


func _one_order(a: OnlineTradeAdapter, action: String, city: String, quantity: int, results: Array) -> void:
	var r: Dictionary
	if action == "buy":
		r = await a.buy(city, quantity)
	else:
		r = await a.sell(city, quantity)
	results.append(r)


## The mirror must equal a fresh server read, field by field.
func _assert_mirror_equals_server(a: OnlineTradeAdapter, label: String) -> void:
	var mirror_money := a.get_wallet().get_balance()
	var mirror_goods := a.get_inventory().get_quantity(REP)
	var read := await a.get_client().refresh_progress()
	var server: Dictionary = read.get("data", {}).get("progress", {})
	_check(read["status"] == OnlineProgressClient.OK and int(server.get("money", -1)) == mirror_money and int(server.get("backpack", {}).get(REP, 0)) == mirror_goods, "%s mirror equals a fresh server read (money %d, goods %d)" % [label, mirror_money, mirror_goods])
	_check(a.is_mirror_consistent(), "%s mirror consistent with the domain types" % label)


func _proxy_stats() -> Dictionary:
	var out := []
	OS.execute("curl", ["-sf", "http://%s:%d/__lossy_proxy/stats" % [_host, _proxy_port]], out)
	var parsed: Variant = JSON.parse_string(out[0] if out.size() > 0 else "")
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


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
