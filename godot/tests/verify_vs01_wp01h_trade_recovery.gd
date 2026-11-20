extends SceneTree

## VS-01 WP01-H E2 — Trade write-ahead and Resolve-only recovery in
## OnlineProgressClient / OnlineTradeAdapter with a Pending Store (Blueprint
## v0.1r3 §6, PR-02, PR-04, B-4A). Offline: a scripted client stands in for
## the server; isolated user://, synthetic accounts. Normal Godot regression.
##   E2-AC01 the order is on disk BEFORE vs01_trade is sent
##   E2-AC04 pending write failure -> no RPC (PR-04)
##   E2-AC05 restart (fresh client) recovers ONLY through vs01_trade_resolve
##           with the original key + command; applied / rejected / voided
##   E2-AC06 quarantine / needs check / unknown gRPC 13 / old server
##   E2-AC07 multiple pending, account switch, stale reply, takeover
##   E2-AC08 clear-write failure keeps the entry; replays later
## E2 Targeted Revision v0.1:
##   FIX-01 no store-less path: a client never given a store still persists;
##          import refused; recovery never vs01_trade
##   FIX-03 malicious / damaged / inconsistent receipts never clear an order
##   FIX-04 quarantine mark write failures: journal, hold, in-process block

const U1 := "11111111-1111-1111-1111-111111111111"
const U2 := "22222222-2222-2222-2222-222222222222"
const GSID := "00000000-0000-0000-0000-0000000000a1"
const BUY := {"action": "buy", "city_id": "A", "good_id": "test_good_01", "quantity": 10}
const SELL := {"action": "sell", "city_id": "B", "good_id": "test_good_01", "quantity": 1}

var _checks := 0
var _failures := 0


## Scripted server. Records every RPC and whether the order's key was already
## durable in the store at the moment it was sent.
class ScriptedClient extends OnlineProgressClient:
	var answers: Array = []
	var sent: Array = []
	var hold := false

	func is_signed_in() -> bool:
		return _session != null

	func _rpc(id: String, payload: Dictionary) -> Dictionary:
		var on_disk := false
		if _store != null and payload.has("idempotency_key"):
			on_disk = _store.load_account(get_user_id())["trade"].has(payload["idempotency_key"])
		sent.append({"id": id, "payload": payload.duplicate(true), "on_disk": on_disk})
		while hold:
			await Engine.get_main_loop().process_frame
		if answers.is_empty():
			return {"status": OnlineProgressClient.UNCERTAIN, "reason": "no scripted answer"}
		var a: Variant = answers.pop_front()
		return a.call(payload) if typeof(a) == TYPE_CALLABLE else a


func _initialize() -> void:
	await process_frame
	print("Isolated user:// for this run: %s" % OS.get_user_data_dir())
	var save_existed := FileAccess.file_exists(SaveStore.DEFAULT_PATH)
	await _case_write_ahead_and_initial_outcomes()
	await _case_write_failure_sends_nothing()
	await _case_restart_resolve_only()
	await _case_quarantine_and_needs_check()
	await _case_unknown_and_old_server_keep()
	await _case_takeover_and_rate_limits()
	await _case_account_switch_and_stale_reply()
	await _case_clear_write_failure()
	await _case_untrusted_store_blocks_account()
	await _case_fix01_no_storeless_path()
	await _case_fix03_strict_receipts()
	await _case_fix04_mark_write_failures()
	await _case_fsf_unmatched_mark_blocks_client()
	await _case_test_mode_prompts()
	_check(FileAccess.file_exists(SaveStore.DEFAULT_PATH) == save_existed and not save_existed, "no gameplay save exists or was created")
	if _failures == 0:
		print("VS-01 WP01-H trade recovery verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Cases -----------------------------------------------------------------------

func _case_write_ahead_and_initial_outcomes() -> void:
	_wipe("user://online_pending")
	var c := _client(U1)
	c.answers = [_receipt_answer(BUY, "applied")]
	var r := await c.buy("A", "test_good_01", 10)
	_check(c.sent.size() == 1 and c.sent[0]["id"] == OnlineProgressClient.RPC_TRADE, "AC01: the first send is vs01_trade")
	_check(c.sent[0]["on_disk"], "AC01/PR-04: the order was durable BEFORE vs01_trade was sent")
	_check(r["status"] == OnlineProgressClient.OK and r["outcome"] == "applied" and not r["pending"], "AC01: applied receipt resolves it")
	_check(_disk(U1).is_empty(), "AC01: the entry is cleared on disk after the matching receipt")
	c.answers = [_receipt_answer(SELL, "rejected", {"reason": "insufficient_cargo"})]
	r = await c.sell("B", "test_good_01", 1)
	_check(r["outcome"] == "rejected" and not r["pending"] and _disk(U1).is_empty(), "AC01: a rejected receipt also resolves and clears it")
	c.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"}]
	r = await c.buy("A", "test_good_01", 10)
	_check(r["status"] == OnlineProgressClient.UNCERTAIN and r["pending"] and _disk(U1).has(r["idempotency_key"]), "AC01: no answer -> kept pending on disk")
	c.answers = [_refusal(8, "rate_limited")]
	var blocked := await c.buy("A", "test_good_01", 1)
	_check(blocked["reason"] == OnlineProgressClient.TRADE_UNRESOLVED and blocked["local"] and c.sent.size() == 3, "B-4A: an unresolved order blocks new trades locally (nothing sent)")
	c.queue_free()


func _case_write_failure_sends_nothing() -> void:
	_wipe("user://online_pending")
	var c := _client(U1)
	DirAccess.make_dir_recursive_absolute(OnlinePendingStore.new().path_for(U1) + ".tmp")
	c.answers = [_receipt_answer(BUY, "applied")]
	var r := await c.buy("A", "test_good_01", 10)
	_check(r["reason"] == OnlineProgressClient.STORE_WRITE_FAILED and c.sent.is_empty(), "AC04/PR-04: pending write failure -> NO RPC")
	_check(c.get_pending_commands().is_empty() and not r["pending"], "AC04: nothing is left pending in memory either")
	DirAccess.remove_absolute(OnlinePendingStore.new().path_for(U1) + ".tmp")
	c.queue_free()


func _case_restart_resolve_only() -> void:
	for outcome in ["voided", "applied", "rejected"]:
		_wipe("user://online_pending")
		var before := _client(U1)
		before.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"}]
		var lost := await before.buy("A", "test_good_01", 10)
		var key: String = lost["idempotency_key"]
		before.queue_free()  # app killed: RAM gone, only the store remains
		var after := _client(U1)
		_check(after.get_pending_commands() == {key: BUY}, "AC05 %s: a fresh client restores the order from the store" % outcome)
		after.answers = [_receipt_answer(BUY, outcome, {"idempotency_key": key}, true)]
		var rec := await after.recover_pending()
		_check(after.sent.size() == 1 and after.sent[0]["id"] == OnlineProgressClient.RPC_TRADE_RESOLVE, "AC05 %s: recovery sends vs01_trade_resolve" % outcome)
		var p: Dictionary = after.sent[0]["payload"]
		_check(p["idempotency_key"] == key and p["action"] == "buy" and p["city_id"] == "A" and p["good_id"] == "test_good_01" and int(p["quantity"]) == 10, "AC05 %s: with the ORIGINAL key and command" % outcome)
		_check(_sent_ids(after).count(OnlineProgressClient.RPC_TRADE) == 0, "AC05/AC-17 %s: never vs01_trade on recovery" % outcome)
		_check(rec.size() == 1 and rec[0]["outcome"] == outcome and not rec[0]["pending"] and _disk(U1).is_empty(), "AC05 %s: matching receipt resolves and clears" % outcome)
		var adapter := OnlineTradeAdapter.new(after)
		var shaped := adapter._to_trade_result(rec[0])
		_check(shaped["success"] == (outcome == "applied") and shaped["voided"] == (outcome == "voided"), "AC05 %s: adapter success only for applied; voided told apart" % outcome)
		after.queue_free()


func _case_quarantine_and_needs_check() -> void:
	var cases := [
		["receipt_unrecognized", _refusal(13, "receipt_unrecognized"), OnlinePendingStore.STATE_QUARANTINED],
		["receipt_not_trusted", _refusal(13, "receipt_not_trusted"), OnlinePendingStore.STATE_QUARANTINED],
		["idempotency_key_reused", _refusal(3, "idempotency_key_reused"), OnlinePendingStore.STATE_QUARANTINED],
		["resolve_command_invalid", _refusal(3, "resolve_command_invalid"), OnlinePendingStore.STATE_NEEDS_CHECK],
		["receipt for another key", "other_key", OnlinePendingStore.STATE_QUARANTINED],
		["receipt of another account", "other_user", OnlinePendingStore.STATE_QUARANTINED],
		["receipt for another command", "other_command", OnlinePendingStore.STATE_QUARANTINED],
		["voided with a wrong contract", "bad_v2", OnlinePendingStore.STATE_QUARANTINED],
		["applied carrying a contract field", "v1_with_contract", OnlinePendingStore.STATE_QUARANTINED],
	]
	for case in cases:
		var name: String = case[0]
		_wipe("user://online_pending")
		var key := await _restored_order(U1)
		var c := _client(U1)
		c.answers = [_bad_receipt(case[1], key) if typeof(case[1]) == TYPE_STRING else case[1]]
		var rec := await c.recover_pending()
		var st: Dictionary = c.get_pending_states().get(key, {})
		_check(st.get("state") == case[2] and c.get_pending_commands().has(key), "AC06 %s -> %s, kept (%s)" % [name, case[2], str(st)])
		var reloaded := OnlinePendingStore.new().load_account(U1)
		_check(reloaded["trade"].get(key, {}).get("state") == case[2], "AC06 %s: state is durable" % name)
		var again := await c.recover_pending()
		_check(again.is_empty() and c.sent.size() == 1, "AC06 %s: no automatic retry" % name)
		var refused := await c.buy("A", "test_good_01", 1)
		_check(refused["reason"] == OnlineProgressClient.TRADE_NEEDS_CHECK and c.sent.size() == 1, "AC06/B-4A %s: new trades paused" % name)
		_check(not rec[0].get("outcome", "") in ["applied", "voided"], "AC06 %s: never reported as a result" % name)
		c.queue_free()


func _case_unknown_and_old_server_keep() -> void:
	var cases := [
		["unidentified gRPC 13", _refusal(13, "some internal error"), OnlineProgressClient.UNCERTAIN],
		["old server without vs01_trade_resolve", _refusal(5, "RPC function not found"), OnlineProgressClient.REJECTED],
		["unknown refusal", _refusal(9, "something_new"), OnlineProgressClient.REJECTED],
		["storage_unavailable", _refusal(14, "storage_unavailable"), OnlineProgressClient.UNCERTAIN],
		["no answer", {"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"}, OnlineProgressClient.UNCERTAIN],
		["unreadable reply", {"status": OnlineProgressClient.UNCERTAIN, "reason": "unreadable_response"}, OnlineProgressClient.UNCERTAIN],
	]
	for case in cases:
		_wipe("user://online_pending")
		var key := await _restored_order(U1)
		var c := _client(U1)
		c.answers = [case[1], case[1]]
		var rec := await c.recover_pending()
		_check(rec[0]["status"] == case[2] and rec[0]["pending"], "AC06/AC-18 %s: kept pending (%s)" % [case[0], str(rec[0])])
		_check(c.get_pending_states()[key]["state"] == OnlinePendingStore.STATE_PENDING, "AC06 %s: still PENDING (may be resolved later)" % case[0])
		await c.recover_pending()
		_check(_sent_ids(c) == [OnlineProgressClient.RPC_TRADE_RESOLVE, OnlineProgressClient.RPC_TRADE_RESOLVE], "AC-18 %s: retried only as resolve, never a fallback to vs01_trade" % case[0])
		c.queue_free()


func _case_takeover_and_rate_limits() -> void:
	_wipe("user://online_pending")
	var key := await _restored_order(U1)
	var c := _client(U1)
	c.answers = [_refusal(10, "gameplay_session_superseded")]
	var rec := await c.recover_pending()
	_check(rec[0]["pending"] and c.is_gameplay_session_superseded(), "AC07: superseded resolve keeps the order; session marked")
	var local := await c.recover_pending()
	_check(local.size() == 1 and local[0]["local"] and c.sent.size() == 1, "AC07: while superseded nothing is sent")
	c._superseded = false  # the player took the character back
	c.answers = [_receipt_answer(BUY, "voided", {"idempotency_key": key}, true)]
	rec = await c.recover_pending()
	_check(rec[0]["outcome"] == "voided" and _disk(U1).is_empty(), "AC07: after reclaim the order resolves")
	c.queue_free()


func _case_account_switch_and_stale_reply() -> void:
	_wipe("user://online_pending")
	var k1 := await _restored_order(U1)
	var c := _client(U1)
	var u1_file := FileAccess.get_file_as_string(OnlinePendingStore.new().path_for(U1))
	# U1's resolve is in flight; the player switches to U2 before it answers.
	c.hold = true
	c.answers = [_receipt_answer(BUY, "voided", {"idempotency_key": k1}, true)]
	var done := []
	_start_recover(c, done)
	await process_frame
	c._accept_session(NakamaSession.new(_token(U2), false))
	c._gameplay_session_id = GSID
	c.hold = false
	while done.is_empty():
		await process_frame
	_check(done[0][0].get("stale", false), "AC07: U1's late answer is stale for U2")
	_check(FileAccess.get_file_as_string(OnlinePendingStore.new().path_for(U1)) == u1_file, "AC07: the stale answer did not touch U1's store")
	_check(c.get_pending_commands().is_empty() and c.trade_block_reason() == "", "AC07: U2 sees no order of U1 and is not blocked")
	c.answers = [_receipt_answer(SELL, "applied", {"user_id": U2})]
	var r := await c.sell("B", "test_good_01", 1)
	_check(r["outcome"] == "applied", "AC07: U2 trades normally (%s)" % str(r))
	_check(OnlinePendingStore.new().load_account(U1)["trade"].has(k1), "AC07: U1's order is still on disk for U1")
	c._accept_session(NakamaSession.new(_token(U1), false))
	c._gameplay_session_id = GSID
	_check(c.get_pending_commands().has(k1), "AC07: back on U1, its order is restored")
	c.queue_free()
	# Several pending orders survive together and each resolves alone.
	_wipe("user://online_pending")
	var keys := []
	var m := _client(U1)
	for i in range(3):
		m._pending["k%031d" % i] = BUY.duplicate()
		m._pending_state["k%031d" % i] = {"state": "pending", "reason": ""}
		keys.append("k%031d" % i)
	_check(m._persist(), "AC07: three orders persisted")
	m.queue_free()
	var n := _client(U1)
	n.answers = [_receipt_answer(BUY, "voided", {"idempotency_key": keys[0]}, true), {"status": OnlineProgressClient.UNCERTAIN, "reason": "x"}, _receipt_answer(BUY, "applied", {"idempotency_key": keys[2]}, true)]
	await n.recover_pending()
	_check(n.get_pending_commands().keys() == [keys[1]] and _disk(U1).keys() == [keys[1]], "AC07: only the decided ones are cleared; the unknown one stays")
	n.queue_free()


func _case_clear_write_failure() -> void:
	_wipe("user://online_pending")
	var key := await _restored_order(U1)
	var c := _client(U1)
	DirAccess.make_dir_recursive_absolute(OnlinePendingStore.new().path_for(U1) + ".tmp")
	c.answers = [_receipt_answer(BUY, "applied", {"idempotency_key": key}, true)]
	var rec := await c.recover_pending()
	_check(rec[0]["status"] == OnlineProgressClient.OK and rec[0]["pending"], "AC08: receipt known but the clear could not be written -> still pending")
	_check(_disk(U1).has(key) and c.get_pending_commands().has(key), "AC08: memory and disk agree (entry kept)")
	DirAccess.remove_absolute(OnlinePendingStore.new().path_for(U1) + ".tmp")
	c.answers = [_receipt_answer(BUY, "applied", {"idempotency_key": key}, true)]
	rec = await c.recover_pending()
	_check(rec[0]["replayed"] and not rec[0]["pending"] and _disk(U1).is_empty(), "AC08: the next resolve replays the same receipt and clears")
	c.queue_free()


func _case_untrusted_store_blocks_account() -> void:
	_wipe("user://online_pending")
	await _restored_order(U1)
	var path := OnlinePendingStore.new().path_for(U1)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{broken")
	f.close()
	var c := _client(U1)
	_check(c.store_block_reason() == "pending_store_quarantined", "AC06/B-4A: damaged store -> account blocked (%s)" % c.store_block_reason())
	var r := await c.buy("A", "test_good_01", 1)
	_check(r["reason"] == "pending_store_quarantined" and c.sent.is_empty(), "AC06/B-4A: no trade is sent")
	_check(not c.set_combat_pending({"kind": "abandon", "key": "a".repeat(32), "ticket_id": "0".repeat(32), "payload": {"ticket_id": "0".repeat(32), "confirm": true}, "state": "pending", "reason": ""}), "AC06/B-4A: no combat write either")
	c.answers = [{"status": OnlineProgressClient.OK, "reason": "", "data": {"progress": {"money": 1, "revision": 3}}}]
	var read := await c.refresh_progress()
	_check(read["status"] == OnlineProgressClient.OK, "B-4A: reading confirmed progress still works")
	c.queue_free()


func _case_fix01_no_storeless_path() -> void:
	_wipe("user://online_pending")
	var c := ScriptedClient.new()  # never given a store explicitly
	root.add_child(c)
	c._accept_session(NakamaSession.new(_token(U1), false))
	c._gameplay_session_id = GSID
	_check(c.has_pending_store(), "FIX-01: every client owns a Pending Store")
	c.enable_pending_store(null)
	_check(c.has_pending_store(), "FIX-01: the store cannot be removed (null refused)")
	c.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "x"}]
	var r := await c.buy("A", "test_good_01", 10)
	_check(c.sent[0]["on_disk"] and _disk(U1).has(r["idempotency_key"]), "FIX-01: even the default client writes the order BEFORE vs01_trade")
	_check(not c.import_pending_commands({"a".repeat(32): BUY}) and not c.import_pending_commands({"a".repeat(32): BUY}, U1), "FIX-01: import is always refused")
	c.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "x"}, {"status": OnlineProgressClient.UNCERTAIN, "reason": "x"}]
	await c.recover_pending()
	await c.buy("A", "test_good_01", 10)  # refused locally (B-4A), never a resend
	_check(_sent_ids(c) == [OnlineProgressClient.RPC_TRADE, OnlineProgressClient.RPC_TRADE_RESOLVE], "FIX-01: after the first send only vs01_trade_resolve is ever used (%s)" % str(_sent_ids(c)))
	c.queue_free()
	# Untrusted store: no new trade RPC at all.
	_wipe("user://online_pending")
	var bad := _client(U1)
	bad.hold_account("test_hold")
	bad.answers = [_receipt_answer(BUY, "applied")]
	var refused := await bad.buy("A", "test_good_01", 10)
	_check(refused["local"] and bad.sent.is_empty(), "FIX-01: an unusable / untrusted store forbids any new trade RPC (%s)" % refused["reason"])
	bad.queue_free()


func _case_fix03_strict_receipts() -> void:
	var cases := {
		"request hash differs": {"request_hash": "buy|A|test_good_01|1"},
		"extra field": {"price": 84.0},
		"missing field": "-server_time_ms",
		"money delta does not match total": {"money_after": 9000.0},
		"cargo delta does not match quantity": {"carried_after": 9.0},
		"total != unit x quantity": {"total": 800.0},
		"applied with a reason": {"reason": "insufficient_money"},
		"applied with a zero unit price": {"unit_price": 0.0, "total": 0.0, "money_after": 10000.0},
		"session field not a string": {"gameplay_session_id": 7.0},
		"negative money": {"money_before": -1.0},
		"non-whole quantity": {"quantity": 10.5},
		"status unknown": {"status": "done"},
	}
	for name in cases:
		await _strict_case(name, BUY, "applied", cases[name])
	var v2_cases := {
		"v2 money moved": {"money_after": 9000.0},
		"v2 cargo moved": {"carried_after": 5.0},
		"v2 with a price": {"unit_price": 84.0},
		"v2 wrong reason": {"reason": "voided"},
		"v2 carrying the v1 session field": {"gameplay_session_id": GSID},
		"v2 missing resolved_by_session_id": "-resolved_by_session_id",
		"v2 hash differs": {"request_hash": "x"},
	}
	for name in v2_cases:
		await _strict_case(name, BUY, "voided", v2_cases[name])
	var rejected_cases := {
		"rejected that moved money": {"money_after": 9160.0},
		"rejected with a unit price": {"unit_price": 84.0},
		"rejected without a reason": {"reason": ""},
	}
	for name in rejected_cases:
		await _strict_case(name, BUY, "rejected", rejected_cases[name])


func _strict_case(name: String, cmd: Dictionary, status: String, change: Variant) -> void:
	_wipe("user://online_pending")
	var key := await _restored_order(U1)
	var c := _client(U1)
	var good: Callable = _receipt_answer(cmd, status, {}, true)
	c.answers = [func(p: Dictionary) -> Dictionary:
		var a: Dictionary = good.call(p)
		var r: Dictionary = a["data"]["receipt"]
		if typeof(change) == TYPE_STRING:
			r.erase(String(change).trim_prefix("-"))
		else:
			r.merge(change, true)
		return a]
	var rec := await c.recover_pending()
	var st: Dictionary = c.get_pending_states().get(key, {})
	_check(st.get("state", "") == OnlinePendingStore.STATE_QUARANTINED and _disk(U1).has(key), "FIX-03 %s: not trusted, order kept and quarantined (%s)" % [name, str(st)])
	_check(rec[0].get("outcome", "") == "" and not rec[0].get("receipt", {}).has("status"), "FIX-03 %s: never reported as a result" % name)
	c.queue_free()


func _case_fix04_mark_write_failures() -> void:
	var path := OnlinePendingStore.new().path_for(U1)
	var marks := OnlinePendingStore.new().marks_path_for(U1)
	# (a) the live write fails, the journal holds the mark.
	_wipe("user://online_pending")
	var key := await _restored_order(U1)
	var c := _client(U1)
	var live_before := FileAccess.get_file_as_string(path)
	DirAccess.make_dir_recursive_absolute(path + ".tmp")
	c.answers = [_refusal(13, "receipt_unrecognized")]
	await c.recover_pending()
	_check(c.get_pending_states()[key]["state"] == OnlinePendingStore.STATE_QUARANTINED, "FIX-04a: quarantined in memory at once (no retry here)")
	_check(FileAccess.get_file_as_string(path) == live_before, "FIX-04a: the live file could not be written (unchanged: original pending evidence)")
	_check((await c.recover_pending()).is_empty() and c.sent.size() == 1, "FIX-04a: no retry in this process")
	c.queue_free()
	DirAccess.remove_absolute(path + ".tmp")
	var fresh := _client(U1)
	_check(fresh.get_pending_states().get(key, {}).get("state") == OnlinePendingStore.STATE_QUARANTINED, "FIX-04a: a fresh process reads it back as QUARANTINED (journal), not pending")
	_check((await fresh.recover_pending()).is_empty() and fresh.sent.is_empty(), "FIX-04a: a fresh process does not retry it")
	fresh.queue_free()
	# (b) journal AND live write fail -> durable HOLD; original entry kept.
	_wipe("user://online_pending")
	key = await _restored_order(U1)
	c = _client(U1)
	DirAccess.make_dir_recursive_absolute(path + ".tmp")
	DirAccess.make_dir_recursive_absolute(marks + ".tmp")
	c.answers = [_refusal(3, "resolve_command_invalid")]
	await c.recover_pending()
	_check(c.store_block_reason() == OnlinePendingStore.HELD_REASON, "FIX-04b: both writes failed -> account HELD (%s)" % c.store_block_reason())
	c.queue_free()
	DirAccess.remove_absolute(path + ".tmp")
	DirAccess.remove_absolute(marks + ".tmp")
	fresh = _client(U1)
	_check(fresh.store_block_reason() == OnlinePendingStore.HELD_REASON and fresh.sent.is_empty(), "FIX-04b: a fresh process is still held")
	var r := await fresh.buy("A", "test_good_01", 1)
	_check(r["local"] and fresh.sent.is_empty(), "FIX-04b: held: no trade sent")
	var raw: Dictionary = JSON.parse_string(JSON.parse_string(FileAccess.get_file_as_string(path))["body"])
	_check(raw["trade"].has(key), "FIX-04b: the original pending entry is still on disk (evidence, never cleared)")
	fresh.queue_free()
	# (c) journal, live AND hold fail -> blocked for this process.
	_wipe("user://online_pending")
	key = await _restored_order(U1)
	c = _client(U1)
	DirAccess.make_dir_recursive_absolute(path + ".tmp")
	DirAccess.make_dir_recursive_absolute(marks + ".tmp")
	var qf := FileAccess.open(OnlinePendingStore.QUARANTINE_DIR, FileAccess.WRITE)  # a FILE where the quarantine dir would be
	qf.store_string("x")
	qf.close()
	c.answers = [_refusal(13, "receipt_not_trusted")]
	await c.recover_pending()
	_check(c.store_block_reason() == OnlineProgressClient.STORE_HOLD_FAILED, "FIX-04c: nothing durable possible -> blocked for this process (%s)" % c.store_block_reason())
	var refused := await c.buy("A", "test_good_01", 1)
	_check(refused["local"] and (await c.recover_pending()).is_empty() and c.sent.size() == 1, "FIX-04c: no trade, no retry sent")
	c.queue_free()
	DirAccess.remove_absolute(path + ".tmp")
	DirAccess.remove_absolute(marks + ".tmp")
	DirAccess.remove_absolute(OnlinePendingStore.QUARANTINE_DIR)


## Final Safety Fix, client view: a journal mark without its live entry.
func _case_fsf_unmatched_mark_blocks_client() -> void:
	for variant in ["no live file", "entry missing"]:
		_wipe("user://online_pending")
		var st := OnlinePendingStore.new()
		if variant == "entry missing":
			st.save_account(U1, {"b".repeat(32): {"action": "sell", "city_id": "A", "good_id": "test_good_01", "quantity": 1, "state": "pending", "reason": ""}}, {})
		st.record_marks(U1, {"a".repeat(32): {"state": "quarantined", "reason": "receipt_mismatch"}}, {})
		var c := _client(U1)
		_check(c.store_block_reason() == "pending_store_untrusted" and c.get_pending_states().is_empty(), "FSF %s: fresh client is BLOCKED, nothing loaded as READY (%s)" % [variant, c.store_block_reason()])
		var rec := await c.recover_pending()
		var r := await c.buy("A", "test_good_01", 1)
		_check(rec.is_empty() and r.get("local", false) and c.sent.is_empty(), "FSF %s: no resolve, no vs01_trade, no rebuilt order sent" % variant)
		c.answers = [{"status": OnlineProgressClient.OK, "reason": "", "data": {"progress": {"money": 1, "revision": 3}}}]
		var read := await c.refresh_progress()
		_check(read["status"] == OnlineProgressClient.OK and _sent_ids(c) == [OnlineProgressClient.RPC_PROGRESS_GET], "FSF %s: safe read still works (only the read sent)" % variant)
		c.queue_free()
		_check(OnlinePendingStore.new().load_account(U1)["status"] == OnlinePendingStore.BLOCKED, "FSF %s: still BLOCKED after a restart" % variant)


func _case_test_mode_prompts() -> void:
	_wipe("user://online_pending")
	var c := ScriptedClient.new()
	var mode: OnlineTradeTestMode = load("res://scenes/online_trade_test_mode.tscn").instantiate()
	mode.client_override = c
	root.add_child(mode)
	_check(mode.client.has_pending_store(), "test mode: the store is enabled")
	var answer: Dictionary = _receipt_answer(BUY, "voided", {}, true).call({"idempotency_key": "a".repeat(32)})
	var shaped := mode.adapter._to_trade_result({"status": OnlineProgressClient.OK, "reason": "", "receipt": answer["data"]["receipt"], "replayed": true})
	mode._show_result("buy", 10, shaped)
	_check(mode.get_status_text() == OnlineTradeTestMode.VOIDED_TEXT and not shaped["success"], "test mode: voided is shown as NOT executed (never success)")
	mode._show_result("buy", 1, mode.adapter._to_trade_result({"status": OnlineProgressClient.REJECTED, "reason": OnlineProgressClient.TRADE_UNRESOLVED, "local": true}))
	_check(mode.get_status_text() == OnlineTradeTestMode.TRADE_UNRESOLVED_TEXT, "test mode: unresolved order -> 核實中 prompt")
	mode._show_result("buy", 1, mode.adapter._to_trade_result({"status": OnlineProgressClient.REJECTED, "reason": "pending_store_quarantined", "local": true}))
	_check(mode.get_status_text() == OnlineTradeTestMode.TRADE_NEEDS_CHECK_TEXT, "test mode: untrusted store -> 需核對 prompt")
	mode._show_result("buy", 1, mode.adapter._to_trade_result({"status": OnlineProgressClient.REJECTED, "reason": OnlineProgressClient.STORE_WRITE_FAILED, "local": true}))
	_check(mode.get_status_text() == OnlineTradeTestMode.STORE_WRITE_FAILED_TEXT, "test mode: write failure -> not sent prompt")
	mode.queue_free()
	await process_frame


# --- helpers -----------------------------------------------------------------------

func _client(user: String) -> ScriptedClient:
	var c := ScriptedClient.new()
	root.add_child(c)
	c.enable_pending_store(OnlinePendingStore.new())
	c._accept_session(NakamaSession.new(_token(user), false))
	c._gameplay_session_id = GSID
	return c


## Leaves one uncertain BUY of `user` on disk, as an app kill would; returns its key.
func _restored_order(user: String) -> String:
	var c := _client(user)
	c.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"}]
	var r := await c.buy("A", "test_good_01", 10)
	c.queue_free()
	return r["idempotency_key"]


## The exact receipt the E1 server writes for the request (FIX-03 format):
## Legacy v1 applied / rejected (rpcTrade) or Voided v2 (resolve).
func _receipt_answer(cmd: Dictionary, status: String, over := {}, replayed := false) -> Callable:
	return func(payload: Dictionary) -> Dictionary:
		var qty := int(cmd["quantity"])
		var buy: bool = cmd["action"] == "buy"
		var applied := status == "applied"
		var unit := 84.0 if applied else 0.0
		var total := unit * qty
		var m0 := 10000.0
		var c0 := 0.0 if buy else float(qty)
		var r := {"idempotency_key": payload["idempotency_key"], "request_hash": "%s|%s|%s|%d" % [cmd["action"], cmd["city_id"], cmd["good_id"], qty],
			"user_id": U1, "action": cmd["action"], "city_id": cmd["city_id"], "good_id": cmd["good_id"], "quantity": float(qty),
			"status": status, "reason": "" if applied else ("insufficient_cargo" if status == "rejected" else "recovery_voided"),
			"unit_price": unit, "total": total, "money_before": m0,
			"money_after": (m0 - total if buy else m0 + total) if applied else m0,
			"carried_before": c0, "carried_after": (c0 + qty if buy else c0 - qty) if applied else c0,
			"progress_revision": 2.0, "server_time_ms": 1.0}
		if status == "voided":
			r.merge({"contract": "myrial.vs01.wp01.trade_receipt", "contract_version": 2.0, "resolved_by_session_id": GSID}, true)
		else:
			r["gameplay_session_id"] = GSID
		r.merge(over, true)
		return {"status": OnlineProgressClient.OK, "reason": "", "data": {"replayed": replayed, "receipt": r, "progress": {"money": r["money_after"], "revision": 2.0}}}


func _bad_receipt(kind: String, key: String) -> Callable:
	match kind:
		"other_key": return _receipt_answer(BUY, "applied", {"idempotency_key": "z".repeat(32)}, true)
		"other_user": return _receipt_answer(BUY, "applied", {"user_id": U2}, true)
		"other_command": return _receipt_answer(BUY, "applied", {"quantity": 1.0}, true)
		"bad_v2": return _receipt_answer(BUY, "voided", {"contract_version": 3.0}, true)
		"v1_with_contract": return _receipt_answer(BUY, "applied", {"contract": "myrial.vs01.wp01.trade_receipt"}, true)
		_: return _receipt_answer(BUY, "applied", {"contract": "myrial.vs01.wp01.trade_receipt"}, true)


static func _refusal(grpc: int, reason: String) -> Dictionary:
	return {"status": OnlineProgressClient.REJECTED, "reason": reason, "grpc_status": grpc}


func _disk(user: String) -> Dictionary:
	return OnlinePendingStore.new().load_account(user)["trade"]


static func _sent_ids(c: ScriptedClient) -> Array:
	return c.sent.map(func(s: Dictionary) -> String: return s["id"])


func _start_recover(c: ScriptedClient, done: Array) -> void:
	done.append(await c.recover_pending())


func _token(user_id: String) -> String:
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


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
		print("FAILED: " + message)
