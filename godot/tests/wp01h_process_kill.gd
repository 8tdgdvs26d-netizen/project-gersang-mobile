extends SceneTree

## VS-01 WP01-H E2 — PROCESS KILL phases (E2-AC05, E2-AC08; FS-K1 offline
## part). Not a verify_* script: driven by tests/run_wp01h_kill_tests.sh,
## which runs phase A (the process kills ITSELF with OS.kill at a named
## point of a store write) and then phase B in a FRESH process sharing the
## same isolated user://. Scripted server answers; synthetic account only.
##
## Pairs (A then B):
##   trade_after_rename  / trade_recover       killed after the order is durable, before vs01_trade
##   trade_second_tmp    / trade_second_check  killed mid-write of a 2nd order: 1st kept, 2nd never sent
##   trade_clear_tmp     / trade_clear_check   killed mid-clear after a receipt: entry kept, replays
##   combat_after_rename / combat_recover      killed after the claim is durable, before the claim RPC
## E2 Targeted Revision (FIX-04 / FIX-05):
##   trade_mark_journal  / trade_mark_check    killed right after the quarantine mark reached the journal
##   trade_mark_live_tmp / trade_mark_check    killed mid-write of the live file after the journal
##   combat_hold_journal / combat_hold_check   killed right after a claim-less ticket hold reached the journal
## Final Safety Fix (FSF-05):
##   trade_mark_journal  / trade_orphan_check  killed between the journal mark and the live update;
##                                             the fresh process then finds the live metadata gone
##                                             (moved aside, kept) -> BLOCKED, never READY

const U1 := "11111111-1111-1111-1111-111111111111"
const GSID := "00000000-0000-0000-0000-0000000000d1"
const T1 := "0123456789abcdef0123456789abcdef"

var _checks := 0
var _failures := 0


class KillStore extends OnlinePendingStore:
	var kill_at := ""
	var kill_on_write := 1
	var kill_after_marks := false
	var _writes := 0

	func record_marks(user_id: String, trade_marks: Dictionary, combat_mark: Dictionary) -> bool:
		var ok := super(user_id, trade_marks, combat_mark)
		if kill_after_marks:
			print("KILL-POINT marks_recorded=%s; killing pid %d" % [ok, OS.get_process_id()])
			OS.kill(OS.get_process_id())
			OS.delay_msec(5000)
		return ok

	func _crash_point(name: String) -> void:
		if name == "tmp_written":
			_writes += 1
		if name == kill_at and _writes >= kill_on_write:
			print("KILL-POINT %s reached; killing pid %d" % [name, OS.get_process_id()])
			OS.kill(OS.get_process_id())
			OS.delay_msec(5000)  # never returns: SIGKILL


class ScriptedClient extends OnlineProgressClient:
	var answers: Array = []
	var sent: Array = []

	func is_signed_in() -> bool:
		return _session != null

	func _rpc(id: String, payload: Dictionary) -> Dictionary:
		sent.append({"id": id, "payload": payload.duplicate(true)})
		print("RPC-SENT %s %s" % [id, payload.get("idempotency_key", "")])
		if answers.is_empty():
			return {"status": OnlineProgressClient.UNCERTAIN, "reason": "no scripted answer"}
		var a: Variant = answers.pop_front()
		return a.call(payload) if typeof(a) == TYPE_CALLABLE else a


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var phase := String(args[args.find("--phase") + 1]) if args.has("--phase") else ""
	print("PHASE %s pid=%d user_data=%s" % [phase, OS.get_process_id(), OS.get_user_data_dir()])
	_check(not FileAccess.file_exists(SaveStore.DEFAULT_PATH), "no gameplay save in the isolated user://")
	match phase:
		"trade_after_rename":
			var c := _client(_kill_store("renamed", 1))
			await c.buy("A", "test_good_01", 10)
			_check(false, "phase A must have been killed before vs01_trade")
		"trade_recover":
			var c := _client(OnlinePendingStore.new())
			var pending := c.get_pending_commands()
			_check(pending.size() == 1 and pending.values()[0] == {"action": "buy", "city_id": "A", "good_id": "test_good_01", "quantity": 10}, "fresh process restores the killed process's order (%s)" % str(pending))
			var key: String = pending.keys()[0] if pending.size() == 1 else ""
			c.answers = [_trade_receipt("voided")]
			var rec := await c.recover_pending()
			_check(c.sent.size() == 1 and c.sent[0]["id"] == OnlineProgressClient.RPC_TRADE_RESOLVE and c.sent[0]["payload"]["idempotency_key"] == key, "recovered ONLY through vs01_trade_resolve with the original key")
			_check(rec.size() == 1 and rec[0]["outcome"] == "voided" and OnlinePendingStore.new().load_account(U1)["trade"].is_empty(), "voided: original never executed; entry cleared")
		"trade_second_tmp":
			var c := _client(_kill_store("tmp_written", 2))
			c.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"}]
			var first := await c.buy("A", "test_good_01", 10)
			print("FIRST-KEY %s" % first["idempotency_key"])
			# A 2nd order next to the 1st (B-4A would block a 2nd buy(): the
			# entry is added directly, only to drive a 2nd write of BOTH).
			c._pending["k%031d" % 1] = {"action": "sell", "city_id": "B", "good_id": "test_good_01", "quantity": 1}
			c._pending_state["k%031d" % 1] = {"state": "pending", "reason": ""}
			c._persist()
			_check(false, "phase A must have been killed during the 2nd write")
		"trade_second_check":
			var store := OnlinePendingStore.new()
			var loaded := store.load_account(U1)
			_check(loaded["status"] == OnlinePendingStore.READY, "after a kill mid-write the store is still trusted")
			_check(loaded["trade"].size() == 1 and loaded["trade"].values()[0]["action"] == "buy", "the last COMPLETE file is used: 1st order kept, the 2nd (never sent) absent")
			var tmp_text := FileAccess.get_file_as_string(store.path_for(U1) + ".tmp")
			_check(tmp_text.contains("sell") and tmp_text.contains("buy"), "the killed write left its temp file holding BOTH orders (ignored, never trusted)")
		"trade_clear_tmp":
			var c := _client(_kill_store("tmp_written", 2))
			c.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"}, _trade_receipt("applied")]
			await c.buy("A", "test_good_01", 10)
			await c.recover_pending()  # receipt arrives; the clear write is killed
			_check(false, "phase A must have been killed during the clear")
		"trade_clear_check":
			var c := _client(OnlinePendingStore.new())
			_check(c.get_pending_commands().size() == 1, "killed during the clear: the entry is still there")
			c.answers = [_trade_receipt("applied", true)]
			var rec := await c.recover_pending()
			_check(c.sent[0]["id"] == OnlineProgressClient.RPC_TRADE_RESOLVE and rec[0]["outcome"] == "applied" and rec[0]["replayed"], "resolve replays the SAME receipt (no second trade)")
			_check(OnlinePendingStore.new().load_account(U1)["trade"].is_empty(), "now cleared")
		"combat_after_rename":
			var c := _client(_kill_store("renamed", 1))
			var a := OnlineCombatAdapter.new(c)
			a._ticket = {"ticket_id": T1}
			await a._submit_durable({"outcome": "victory", "kills": 10, "hero_alive": true})
			_check(false, "phase A must have been killed before the claim RPC")
		"combat_recover":
			var c := _client(OnlinePendingStore.new())
			var a := OnlineCombatAdapter.new(c)
			var pending := a.get_pending()
			_check(pending.get("kind") == "claim" and pending.get("ticket_id") == T1 and int(pending["payload"]["kills"]) == 10, "fresh process restores the claim")
			c.answers = [_progression(pending.get("key", "")), _claim_receipt()]
			var r := await a.recover()
			_check(c.sent.size() == 2 and c.sent[1]["id"] == OnlineCombatAdapter.RPC_CLAIM and c.sent[1]["payload"]["idempotency_key"] == pending.get("key"), "resent with the ORIGINAL key after matching the recorded intent")
			_check(r["handling"] == OnlineCombatAdapter.CONFIRMED and OnlinePendingStore.new().load_account(U1)["combat"].is_empty(), "settled once by the server; cleared")
		"trade_mark_journal", "trade_mark_live_tmp":
			var s := _kill_store("tmp_written", 3)  # write 1 = order, 2 = journal, 3 = live mark
			s.kill_after_marks = phase == "trade_mark_journal"
			var c := _client(s)
			c.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"},
				{"status": OnlineProgressClient.REJECTED, "reason": "receipt_unrecognized", "grpc_status": 13}]
			await c.buy("A", "test_good_01", 10)
			await c.recover_pending()
			_check(false, "phase A must have been killed while marking")
		"trade_mark_check":
			var c := _client(OnlinePendingStore.new())
			var states := c.get_pending_states()
			_check(states.size() == 1 and states.values()[0]["state"] == OnlinePendingStore.STATE_QUARANTINED and states.values()[0]["reason"] == "receipt_unrecognized", "fresh process: the order is QUARANTINED, not a normal pending one (%s)" % str(states))
			var rec := await c.recover_pending()
			var r := await c.buy("A", "test_good_01", 1)
			_check(rec.is_empty() and c.sent.is_empty() and r["local"], "fresh process: no automatic retry, no new trade sent")
		"trade_orphan_check":
			# The live metadata is lost after the kill (moved aside, kept as
			# evidence); only the journal mark remains.
			var st := OnlinePendingStore.new()
			var live := st.path_for(U1)
			var aside := live + ".lost"
			_check(FileAccess.file_exists(live) and FileAccess.file_exists(st.marks_path_for(U1)) and DirAccess.rename_absolute(live, aside) == OK, "fresh process setup: journal present, live metadata moved aside")
			var c := _client(OnlinePendingStore.new())
			_check(c.store_block_reason() == "pending_store_untrusted" and c.get_pending_states().is_empty(), "fresh process: unmatched journal mark -> BLOCKED, not READY (%s)" % c.store_block_reason())
			var rec := await c.recover_pending()
			var r := await c.buy("A", "test_good_01", 1)
			_check(rec.is_empty() and r["local"] and c.sent.is_empty() and FileAccess.file_exists(aside) and FileAccess.file_exists(st.marks_path_for(U1)) and not FileAccess.file_exists(live), "fresh process: nothing rebuilt or sent; journal + moved live file kept")
		"combat_hold_journal":
			var s := _kill_store("", 1)
			s.kill_after_marks = true
			var c := _client(s)
			var a := OnlineCombatAdapter.new(c)
			c.answers = [{"status": OnlineProgressClient.OK, "reason": "", "data": {"progression": {"level": 1.0, "exp": 0.0, "exp_to_next": 100.0, "revision": 0.0},
				"unresolved_ticket": {"ticket_id": T1}, "group_available_at_ms": {}, "server_time_ms": 1.0,
				"recorded_intent": {"status": "inconsistent", "ticket_id": T1}}}]
			await a.recover()
			_check(false, "phase A must have been killed while holding the ticket")
		"combat_hold_check":
			var c := _client(OnlinePendingStore.new())
			var a := OnlineCombatAdapter.new(c)
			a._ticket = {"ticket_id": T1}
			var hold := a.get_pending()
			_check(hold == {"kind": "ticket_hold", "ticket_id": T1, "state": OnlinePendingStore.STATE_NEEDS_CHECK, "reason": OnlineCombatAdapter.INTENT_INCONSISTENT}, "fresh process: the claim-less ticket hold is restored from the journal (%s)" % str(hold))
			var s1 := await a._submit_durable({"outcome": "victory", "kills": 10, "hero_alive": true})
			var s2 := await a._abandon_durable(T1)
			_check(s1["handling"] == OnlineCombatAdapter.BLOCKED and s2["handling"] == OnlineCombatAdapter.BLOCKED and c.sent.is_empty(), "fresh process: claim / abandon for the held ticket blocked, nothing sent, no key invented")
		_:
			_check(false, "unknown phase %s" % phase)
	if _failures == 0:
		print("WP01-H process kill phase %s passed (%d checks)" % [phase, _checks])
	quit(1 if _failures > 0 else 0)


func _kill_store(point: String, on_write: int) -> KillStore:
	var s := KillStore.new()
	s.kill_at = point
	s.kill_on_write = on_write
	return s


func _client(store: OnlinePendingStore) -> ScriptedClient:
	var c := ScriptedClient.new()
	root.add_child(c)
	c.enable_pending_store(store)
	c._accept_session(NakamaSession.new(_token(U1), false))
	c._gameplay_session_id = GSID
	return c


## The exact E1 receipts (E2r FIX-03 format) for the request.
func _trade_receipt(status: String, replayed := false) -> Callable:
	return func(p: Dictionary) -> Dictionary:
		var qty := int(p["quantity"])
		var applied := status == "applied"
		var unit := 84.0 if applied else 0.0
		var r := {"idempotency_key": p["idempotency_key"], "request_hash": "%s|%s|%s|%d" % [p["action"], p["city_id"], p["good_id"], qty],
			"user_id": U1, "action": p["action"], "city_id": p["city_id"], "good_id": p["good_id"], "quantity": float(qty), "status": status,
			"reason": "" if applied else "recovery_voided", "unit_price": unit, "total": unit * qty, "money_before": 10000.0,
			"money_after": 10000.0 - unit * qty, "carried_before": 0.0, "carried_after": float(qty) if applied else 0.0,
			"progress_revision": 2.0, "server_time_ms": 1.0}
		if status == "voided":
			r.merge({"contract": "myrial.vs01.wp01.trade_receipt", "contract_version": 2.0, "resolved_by_session_id": GSID}, true)
		else:
			r["gameplay_session_id"] = GSID
		return {"status": OnlineProgressClient.OK, "reason": "", "data": {"replayed": replayed, "receipt": r, "progress": {"money": r["money_after"], "revision": 2.0}}}


func _claim_receipt() -> Callable:
	return func(p: Dictionary) -> Dictionary:
		var kills := int(p["kills"])
		return {"status": OnlineProgressClient.OK, "reason": "", "data": {"replayed": false,
			"receipt": {"contract": "myrial.vs01.wp01e.receipt", "contract_version": 1.0, "kind": "claim", "idempotency_key": p["idempotency_key"],
				"request_hash": "claim|%s|%s|%d|%s" % [p["ticket_id"], p["outcome"], kills, "1" if p["hero_alive"] else "0"],
				"user_id": U1, "gameplay_session_id": GSID, "ticket_id": p["ticket_id"], "status": "applied", "outcome": p["outcome"],
				"kills_claimed": float(kills), "kills_accepted": float(kills), "hero_alive": p["hero_alive"], "exp_awarded": 100.0,
				"level_before": 1.0, "exp_before": 0.0, "level_after": 2.0, "exp_after": 0.0, "progression_revision": 1.0,
				"cooldown_groups": [], "intent_first_seen_at_ms": 1.0, "server_time_ms": 1.0},
			"progression": {"level": 2.0, "exp": 0.0, "exp_to_next": 200.0, "revision": 1.0}}}


func _progression(key: String) -> Dictionary:
	return {"status": OnlineProgressClient.OK, "reason": "", "data": {
		"progression": {"level": 1.0, "exp": 0.0, "exp_to_next": 100.0, "revision": 0.0},
		"unresolved_ticket": {"ticket_id": T1}, "group_available_at_ms": {}, "server_time_ms": 1.0,
		"recorded_intent": {"status": "recorded", "ticket_id": T1, "idempotency_key": key,
			"claim": {"outcome": "victory", "kills": 10.0, "hero_alive": true}, "first_seen_at_ms": 1.0}}}


func _token(user_id: String) -> String:
	var header := Marshalls.utf8_to_base64(JSON.stringify({"alg": "none"}))
	var body := Marshalls.utf8_to_base64(JSON.stringify({"uid": user_id, "usn": "offline", "exp": 4102444800}))
	return "%s.%s.x" % [header.trim_suffix("=").trim_suffix("="), body.trim_suffix("=").trim_suffix("=")]


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
		print("FAILED: " + message)
