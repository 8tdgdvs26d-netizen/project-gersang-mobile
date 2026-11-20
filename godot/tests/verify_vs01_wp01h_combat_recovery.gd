extends SceneTree

## VS-01 WP01-H E2 — Combat claim write-ahead and Recorded Intent recovery in
## OnlineCombatAdapter with a Pending Store (Blueprint v0.1r3 §7, C-B1 / C-A1,
## PR-02, PR-03 client side, PR-04, B-4A). Offline: scripted server answers,
## isolated user://, synthetic accounts. Normal Godot regression.
##   E2-AC01 the claim is durable BEFORE the first claim RPC; write failure -> no RPC
##   E2-AC05 restart: recorded intent must match the local claim; original key resent
##   E2-AC06 inconsistent / mismatch / trust errors -> needs check / quarantine
##   E2-AC07 claim / abandon conflicts blocked; takeover; stale reply
##   E2-AC08 old server without recorded_intent: FAIL CLOSED (E2r FIX-02), never local EXP
## E2 Targeted Revision v0.1:
##   FIX-02 a claim loaded in a fresh process is never resent before recover()
##          has read and checked the recorded intent (ticket / key / claim)
##   FIX-03 the exact E1 encounter receipt only (22 fields, hash, claim)
##   FIX-04 mark write failures: journal / hold, fresh-process read back
##   FIX-05 inconsistent intent with no local claim: claim-less ticket hold

const U1 := "11111111-1111-1111-1111-111111111111"
const U2 := "22222222-2222-2222-2222-222222222222"
const GSID := "00000000-0000-0000-0000-0000000000c1"
const T1 := "0123456789abcdef0123456789abcdef"
const T2 := "fedcba9876543210fedcba9876543210"
const CLAIM := {"outcome": "victory", "kills": 10, "hero_alive": true}

var _checks := 0
var _failures := 0


class ScriptedClient extends OnlineProgressClient:
	var answers: Array = []
	var sent: Array = []
	var hold := false

	func is_signed_in() -> bool:
		return _session != null

	func _rpc(id: String, payload: Dictionary) -> Dictionary:
		var on_disk := false
		if _store != null and payload.has("idempotency_key"):
			on_disk = _store.load_account(get_user_id())["combat"].get("key", "") == payload["idempotency_key"]
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
	await _case_write_ahead_and_failure()
	await _case_answers_handling()
	await _case_restart_recorded_intent()
	await _case_intent_conflicts()
	await _case_old_server_and_read_errors()
	await _case_claim_abandon_conflicts()
	await _case_takeover_and_stale()
	await _case_fix02_verify_before_resend()
	await _case_fix03_strict_receipts()
	await _case_fix04_mark_failures()
	await _case_fix05_ticket_hold()
	await _case_test_mode_prompts()
	_check(FileAccess.file_exists(SaveStore.DEFAULT_PATH) == save_existed and not save_existed, "no gameplay save exists or was created")
	if _failures == 0:
		print("VS-01 WP01-H combat recovery verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Cases -----------------------------------------------------------------------

func _case_write_ahead_and_failure() -> void:
	_wipe("user://online_pending")
	var a := _adapter(U1)
	var c: ScriptedClient = a.get_client()
	c.answers = [_claim_receipt()]
	var r := await a._submit_durable(CLAIM)
	_check(c.sent.size() == 1 and c.sent[0]["id"] == OnlineCombatAdapter.RPC_CLAIM and c.sent[0]["on_disk"], "AC01/PR-04: the claim was durable BEFORE the first claim RPC")
	_check(r["handling"] == OnlineCombatAdapter.CONFIRMED and _disk(U1).is_empty(), "AC01: matching receipt clears it on disk")
	_check(a.get_confirmed_progression()["level"] == 2, "AC01: Level comes from the server answer only")
	c.queue_free()
	_wipe("user://online_pending")
	a = _adapter(U1)
	c = a.get_client()
	DirAccess.make_dir_recursive_absolute(OnlinePendingStore.new().path_for(U1) + ".tmp")
	r = await a._submit_durable(CLAIM)
	_check(r["reason"] == OnlineProgressClient.STORE_WRITE_FAILED and c.sent.is_empty() and not a.has_pending(), "AC01/PR-04: write failure -> NO claim RPC, nothing pending")
	DirAccess.remove_absolute(OnlinePendingStore.new().path_for(U1) + ".tmp")
	c.queue_free()


func _case_answers_handling() -> void:
	var cases := [
		["applied, other key", func(p): return _claim_receipt({"idempotency_key": "z".repeat(32)}).call(p), OnlineCombatAdapter.CONFLICT, "quarantined"],
		["applied, other ticket", func(p): return _claim_receipt({"ticket_id": T2}).call(p), OnlineCombatAdapter.CONFLICT, "quarantined"],
		["applied, other account", func(p): return _claim_receipt({"user_id": U2}).call(p), OnlineCombatAdapter.CONFLICT, "quarantined"],
		["applied, wrong kind", func(p): return _claim_receipt({"kind": "abandon"}).call(p), OnlineCombatAdapter.CONFLICT, "quarantined"],
		["claim_locked", _refusal(6, "claim_locked"), OnlineCombatAdapter.CONFLICT, "quarantined"],
		["idempotency_key_reused", _refusal(3, "idempotency_key_reused"), OnlineCombatAdapter.CONFLICT, "quarantined"],
		["wp01e_object_not_trusted", _refusal(13, "wp01e_object_not_trusted"), OnlineCombatAdapter.CONFLICT, "quarantined"],
		["wp01e_intent_inconsistent", _refusal(13, "wp01e_intent_inconsistent"), OnlineCombatAdapter.CONFLICT, "quarantined"],
		["invalid_claim", _refusal(3, "invalid_claim"), OnlineCombatAdapter.CONFLICT, "quarantined"],
		["ticket_expired", _refusal(9, "ticket_expired"), OnlineCombatAdapter.FINAL, ""],
		["ticket_abandoned", _refusal(9, "ticket_abandoned"), OnlineCombatAdapter.FINAL, ""],
		["ticket_not_found", _refusal(5, "ticket_not_found"), OnlineCombatAdapter.FINAL, ""],
		["unidentified gRPC 13", _refusal(13, "some internal error"), OnlineCombatAdapter.KEEP, "pending"],
		["unknown refusal", _refusal(9, "something_new"), OnlineCombatAdapter.KEEP, "pending"],
		["too_early", _refusal(9, "too_early"), OnlineCombatAdapter.KEEP, "pending"],
		["no answer", {"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"}, OnlineCombatAdapter.KEEP, "pending"],
	]
	for case in cases:
		_wipe("user://online_pending")
		var a := _adapter(U1)
		var c: ScriptedClient = a.get_client()
		c.answers = [case[1]]
		var r := await a._submit_durable(CLAIM)
		var stored: Dictionary = _disk(U1)
		_check(r["handling"] == case[2], "AC06 %s -> %s (%s)" % [case[0], case[2], str(r.get("handling"))])
		if case[3] == "":
			_check(stored.is_empty() and not a.has_pending(), "AC06 %s: server-final, cleared" % case[0])
		else:
			_check(stored.get("state") == case[3] and a.get_pending().get("state") == case[3], "AC06 %s: kept as %s on disk" % [case[0], case[3]])
		_check(a.get_confirmed_progression().is_empty() or case[2] != OnlineCombatAdapter.CONFLICT, "AC06 %s: no EXP shown from a rejected / mismatching answer" % case[0])
		if case[3] == "quarantined":
			var again := await a.resend_pending()
			_check(again["handling"] == OnlineCombatAdapter.BLOCKED and c.sent.size() == 1, "AC06 %s: no automatic retry" % case[0])
		c.queue_free()


func _case_restart_recorded_intent() -> void:
	_wipe("user://online_pending")
	var key := await _left_pending_claim(U1)
	# App killed. A fresh process: client, adapter and store from disk only.
	var a := _adapter(U1)
	var c: ScriptedClient = a.get_client()
	_check(a.get_pending()["key"] == key, "AC05: the fresh process restores the claim from the store")
	c.answers = [_progression_answer(_intent(key)), _claim_receipt()]
	var r := await a.recover()
	_check(_sent_ids(c) == [OnlineCombatAdapter.RPC_PROGRESSION, OnlineCombatAdapter.RPC_CLAIM], "AC05: read, then ONE claim")
	_check(c.sent[1]["payload"]["idempotency_key"] == key and c.sent[1]["payload"]["ticket_id"] == T1 and int(c.sent[1]["payload"]["kills"]) == 10, "AC05: resent with the ORIGINAL key and claim")
	_check(r["handling"] == OnlineCombatAdapter.CONFIRMED and _disk(U1).is_empty(), "AC05: settled once, cleared")
	c.queue_free()
	# Adopt: the server holds the recorded intent, this install has none.
	_wipe("user://online_pending")
	a = _adapter(U1)
	c = a.get_client()
	c.answers = [_progression_answer(_intent("s".repeat(32))), _claim_receipt({"idempotency_key": "s".repeat(32)})]
	r = await a.recover()
	_check(c.sent.size() == 2 and c.sent[1]["payload"]["idempotency_key"] == "s".repeat(32) and c.sent[1]["on_disk"], "AC05: no local claim -> the server's recorded intent is adopted, written first, resent with ITS key")
	_check(r["handling"] == OnlineCombatAdapter.CONFIRMED, "AC05: adopted claim settles")
	c.queue_free()


func _case_intent_conflicts() -> void:
	var cases := [
		["intent with another key", func(k): return _intent("q".repeat(32)), OnlinePendingStore.STATE_QUARANTINED],
		["intent with another claim", func(k): return _intent(k, {"outcome": "retreat", "kills": 3, "hero_alive": true}), OnlinePendingStore.STATE_QUARANTINED],
		["server says inconsistent", func(_k): return {"status": "inconsistent", "ticket_id": T1}, OnlinePendingStore.STATE_NEEDS_CHECK],
		["intent for another ticket", func(k): var i := _intent(k); i["ticket_id"] = T2; return i, OnlinePendingStore.STATE_NEEDS_CHECK],
		["intent missing its claim", func(k): var i := _intent(k); i.erase("claim"); return i, OnlinePendingStore.STATE_NEEDS_CHECK],
		["intent with a bad key format", func(_k): return _intent("short"), OnlinePendingStore.STATE_NEEDS_CHECK],
	]
	for case in cases:
		_wipe("user://online_pending")
		var key := await _left_pending_claim(U1)
		var a := _adapter(U1)
		var c: ScriptedClient = a.get_client()
		c.answers = [_progression_answer(case[1].call(key))]
		var r := await a.recover()
		_check(_sent_ids(c) == [OnlineCombatAdapter.RPC_PROGRESSION], "AC06 %s: no claim sent" % case[0])
		_check(r["handling"] == OnlineCombatAdapter.CONFLICT and _disk(U1).get("state") == case[2], "AC06 %s -> %s, local claim kept (%s)" % [case[0], case[2], str(_disk(U1).get("state"))])
		_check(_disk(U1).get("key") == key, "AC06 %s: the original claim is never replaced by the server's" % case[0])
		c.queue_free()
	# inconsistent with NO local claim: nothing adopted, nothing sent.
	_wipe("user://online_pending")
	var a2 := _adapter(U1)
	var c2: ScriptedClient = a2.get_client()
	c2.answers = [_progression_answer({"status": "inconsistent", "ticket_id": T1})]
	var r2 := await a2.recover()
	_check(r2["handling"] == OnlineCombatAdapter.CONFLICT and _disk(U1).get("kind") == "ticket_hold" and not _disk(U1).has("key") and c2.sent.size() == 1, "AC06/FIX-05: inconsistent without local claim -> claim-less ticket hold, nothing adopted or sent")
	c2.queue_free()


func _case_old_server_and_read_errors() -> void:
	_wipe("user://online_pending")
	var key := await _left_pending_claim(U1)
	var a := _adapter(U1)
	var c: ScriptedClient = a.get_client()
	c.answers = [_progression_answer(null, false), _claim_receipt()]
	var r := await a.recover()
	_check(_sent_ids(c) == [OnlineCombatAdapter.RPC_PROGRESSION], "AC08/FIX-02: old server (no recorded_intent): the claim cannot be checked -> NOT resent")
	_check(r["handling"] == OnlineCombatAdapter.BLOCKED and r["reason"] == OnlineCombatAdapter.RECOVERY_UNSUPPORTED and _disk(U1).get("key") == key, "AC08/FIX-02: fail closed, the claim is kept untouched")
	c.queue_free()
	_wipe("user://online_pending")
	a = _adapter(U1)
	c = a.get_client()
	c.answers = [_progression_answer(null, false)]
	r = await a.recover()
	_check(c.sent.size() == 1 and r["reason"] == "nothing_pending" and a.get_confirmed_progression()["level"] == 1, "AC08: old server, nothing local: nothing sent, no EXP made up")
	c.queue_free()
	for refusal in [_refusal(13, "wp01e_object_not_trusted"), _refusal(10, "gameplay_session_superseded"), {"status": OnlineProgressClient.UNCERTAIN, "reason": "read_deadline_exceeded"}]:
		_wipe("user://online_pending")
		key = await _left_pending_claim(U1)
		a = _adapter(U1)
		c = a.get_client()
		c.answers = [refusal]
		r = await a.recover()
		_check(c.sent.size() == 1 and r["handling"] == OnlineCombatAdapter.KEEP and _disk(U1).get("key") == key and _disk(U1).get("state") == "pending", "AC06 read %s: nothing guessed, claim kept, not cleared" % refusal["reason"])
		c.queue_free()


func _case_claim_abandon_conflicts() -> void:
	_wipe("user://online_pending")
	var a := _adapter(U1)
	var c: ScriptedClient = a.get_client()
	var key := await _in_process_claim(a)  # created in THIS process (verified)
	c.sent.clear()
	var r := await a._abandon_durable(T1)
	_check(r["reason"] == OnlineCombatAdapter.PENDING_CLAIM_UNRESOLVED and c.sent.is_empty() and _disk(U1)["kind"] == "claim" and _disk(U1)["key"] == key, "AC07: a new abandon never overwrites the pending claim (nothing sent)")
	a._ticket = {"ticket_id": T2}
	r = await a._submit_durable(CLAIM)
	_check(r["reason"] == OnlineCombatAdapter.PENDING_COMBAT_UNRESOLVED and c.sent.is_empty() and _disk(U1)["ticket_id"] == T1, "AC07: another ticket's claim never replaces it")
	a._ticket = {"ticket_id": T1}
	c.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "x"}]
	r = await a._submit_durable({"outcome": "retreat", "kills": 1, "hero_alive": true})
	_check(c.sent.size() == 1 and int(c.sent[0]["payload"]["kills"]) == 10 and c.sent[0]["payload"]["idempotency_key"] == key, "AC07: the same ticket resends the FIRST claim, never a new payload")
	c.queue_free()
	_wipe("user://online_pending")
	a = _adapter(U1)
	c = a.get_client()
	c.answers = [_claim_receipt({"kind": "abandon"})]
	r = await a._abandon_durable(T1)
	_check(c.sent.size() == 1 and c.sent[0]["id"] == OnlineCombatAdapter.RPC_ABANDON and c.sent[0]["on_disk"] and r["handling"] == OnlineCombatAdapter.CONFIRMED, "AC07: an abandon with nothing pending is written first, then sent")
	c.queue_free()


func _case_takeover_and_stale() -> void:
	_wipe("user://online_pending")
	var a := _adapter(U1)
	var c: ScriptedClient = a.get_client()
	var key := await _in_process_claim(a)  # created in THIS process (verified)
	c.answers = [_refusal(10, "gameplay_session_superseded")]
	var r := await a.resend_pending()
	_check(r["handling"] == OnlineCombatAdapter.SUPERSEDED and _disk(U1)["key"] == key, "AC07: superseded keeps the claim")
	c._superseded = false
	c.hold = true
	c.answers = [_claim_receipt()]
	var done := []
	_start_resend(a, done)
	await process_frame
	c._accept_session(NakamaSession.new(_token(U2), false))
	c._gameplay_session_id = GSID
	c.hold = false
	while done.is_empty():
		await process_frame
	_check(done[0]["handling"] == OnlineCombatAdapter.KEEP, "AC07: an answer after an account switch is not filed")
	_check(OnlinePendingStore.new().load_account(U1)["combat"]["key"] == key, "AC07: U1's claim is still on disk")
	_check(a.get_pending().is_empty(), "AC07: U2 sees no claim of U1")
	c.queue_free()


func _case_test_mode_prompts() -> void:
	_wipe("user://online_pending")
	var mode: OnlineCombatTestMode = load("res://scenes/online_combat_test_mode.tscn").instantiate()
	mode.client_override = ScriptedClient.new()
	mode.auto_retry = false
	root.add_child(mode)
	_check(mode.client.has_pending_store(), "test mode: the store is enabled")
	mode._after_answer({"status": OnlineProgressClient.REJECTED, "reason": "claim_locked", "handling": OnlineCombatAdapter.CONFLICT})
	_check(mode.get_status_text() == OnlineCombatTestMode.CONFLICT_TEXT, "test mode: conflict -> 需要核對 prompt, not 'final'")
	mode._after_answer({"status": OnlineProgressClient.REJECTED, "reason": OnlineCombatAdapter.PENDING_CLAIM_UNRESOLVED, "handling": OnlineCombatAdapter.BLOCKED})
	_check(mode.get_status_text() == OnlineCombatTestMode.CLAIM_UNRESOLVED_TEXT, "test mode: abandon refused while a claim is pending")
	mode._after_answer({"status": OnlineProgressClient.REJECTED, "reason": OnlineProgressClient.STORE_WRITE_FAILED, "handling": OnlineCombatAdapter.BLOCKED})
	_check(mode.get_status_text() == OnlineCombatTestMode.STORE_WRITE_FAILED_TEXT, "test mode: write failure -> not sent prompt")
	_check(mode.get_panel_button("Recover") != null, "test mode: a recover action exists")
	mode.queue_free()
	await process_frame


func _case_fix02_verify_before_resend() -> void:
	_wipe("user://online_pending")
	var key := await _left_pending_claim(U1)
	var a := _adapter(U1)  # fresh process: loaded, UNVERIFIED
	var c: ScriptedClient = a.get_client()
	c.answers = [_claim_receipt()]
	var r := await a.resend_pending()
	_check(r["reason"] == OnlineCombatAdapter.PENDING_UNVERIFIED and c.sent.is_empty(), "FIX-02: resend before recover() is refused (nothing sent)")
	r = await a._submit_durable(CLAIM)
	_check(r["reason"] == OnlineCombatAdapter.PENDING_UNVERIFIED and c.sent.is_empty(), "FIX-02: re-submitting the same ticket before recover() sends nothing")
	r = await a._abandon_durable(T1)
	_check(r["handling"] == OnlineCombatAdapter.BLOCKED and c.sent.is_empty() and _disk(U1)["key"] == key, "FIX-02: no abandon over it either")
	# No intent, the server's open ticket is ours -> C-A1 resend with the original key.
	c.answers = [_progression_answer(null), _claim_receipt()]
	r = await a.recover()
	_check(_sent_ids(c) == [OnlineCombatAdapter.RPC_PROGRESSION, OnlineCombatAdapter.RPC_CLAIM] and c.sent[1]["payload"]["idempotency_key"] == key, "FIX-02: read first; no intent + our open ticket -> original key resent")
	_check(r["handling"] == OnlineCombatAdapter.CONFIRMED, "FIX-02: settled by the server")
	c.queue_free()
	# No intent, the server's open ticket is ANOTHER ticket -> needs check, nothing sent.
	_wipe("user://online_pending")
	key = await _left_pending_claim(U1)
	a = _adapter(U1)
	c = a.get_client()
	var other := _progression_answer(null)
	other["data"]["unresolved_ticket"] = {"ticket_id": T2}
	c.answers = [other]
	r = await a.recover()
	_check(c.sent.size() == 1 and r["handling"] == OnlineCombatAdapter.CONFLICT and _disk(U1)["state"] == OnlinePendingStore.STATE_NEEDS_CHECK, "FIX-02: open ticket differs -> needs check, not resent")
	c.queue_free()
	# No intent and no open ticket -> the original key may only replay / be refused finally.
	_wipe("user://online_pending")
	key = await _left_pending_claim(U1)
	a = _adapter(U1)
	c = a.get_client()
	var closed := _progression_answer(null)
	closed["data"]["unresolved_ticket"] = null
	c.answers = [closed, _refusal(9, "ticket_expired")]
	r = await a.recover()
	_check(_sent_ids(c) == [OnlineCombatAdapter.RPC_PROGRESSION, OnlineCombatAdapter.RPC_CLAIM] and c.sent[1]["payload"]["idempotency_key"] == key and r["handling"] == OnlineCombatAdapter.FINAL, "FIX-02: ticket closed on the server -> original key, server's final answer")
	c.queue_free()


func _case_fix03_strict_receipts() -> void:
	var cases := {
		"wrong contract name": {"contract": "myrial.vs01.wp01e.encounter_receipt"},
		"wrong contract version": {"contract_version": 2.0},
		"request hash differs": {"request_hash": "claim|x|victory|10|1"},
		"kills differ": {"kills_claimed": 3.0, "kills_accepted": 3.0},
		"outcome differs": {"outcome": "retreat"},
		"hero_alive differs": {"hero_alive": false},
		"extra field": {"bonus": 1.0},
		"status not applied": {"status": "pending"},
		"negative EXP": {"exp_awarded": -5.0},
		"level goes down": {"level_after": 0.0},
		"cooldown_groups not a list": {"cooldown_groups": "x"},
	}
	for name in cases:
		_wipe("user://online_pending")
		var a := _adapter(U1)
		var c: ScriptedClient = a.get_client()
		c.answers = [_claim_receipt(cases[name])]
		var r := await a._submit_durable(CLAIM)
		_check(r["handling"] == OnlineCombatAdapter.CONFLICT and _disk(U1).get("state") == OnlinePendingStore.STATE_QUARANTINED, "FIX-03 %s: not trusted, claim kept quarantined" % name)
		_check(a.get_confirmed_progression().is_empty(), "FIX-03 %s: no EXP shown from it" % name)
		c.queue_free()
	_wipe("user://online_pending")
	var b := _adapter(U1)
	var cb: ScriptedClient = b.get_client()
	cb.answers = [_claim_receipt({"exp_awarded": 5.0})]
	var bad_abandon := await b._abandon_durable(T1)
	_check(bad_abandon["handling"] == OnlineCombatAdapter.CONFLICT, "FIX-03: an abandon receipt that awards EXP is not trusted")
	cb.queue_free()


func _case_fix04_mark_failures() -> void:
	var path := OnlinePendingStore.new().path_for(U1)
	var marks := OnlinePendingStore.new().marks_path_for(U1)
	_wipe("user://online_pending")
	var key := await _left_pending_claim(U1)
	var a := _adapter(U1)
	var c: ScriptedClient = a.get_client()
	DirAccess.make_dir_recursive_absolute(path + ".tmp")
	c.answers = [_progression_answer(_intent("q".repeat(32)))]
	var r := await a.recover()
	_check(r["handling"] == OnlineCombatAdapter.CONFLICT and a.get_pending()["state"] == OnlinePendingStore.STATE_QUARANTINED, "FIX-04: mismatch quarantined in memory although the live write failed")
	c.queue_free()
	DirAccess.remove_absolute(path + ".tmp")
	var fresh := _adapter(U1)
	_check(fresh.get_pending().get("state") == OnlinePendingStore.STATE_QUARANTINED and fresh.get_pending().get("key") == key, "FIX-04: a fresh process reads it back QUARANTINED (journal), original claim kept")
	var fc: ScriptedClient = fresh.get_client()
	fc.answers = [_progression_answer(_intent(key))]
	await fresh.recover()
	_check(_sent_ids(fc) == [OnlineCombatAdapter.RPC_PROGRESSION] or fc.sent.size() <= 1, "FIX-04: the fresh process never resends it")
	fc.queue_free()
	# Journal and live write fail -> HOLD.
	_wipe("user://online_pending")
	await _left_pending_claim(U1)
	a = _adapter(U1)
	c = a.get_client()
	DirAccess.make_dir_recursive_absolute(path + ".tmp")
	DirAccess.make_dir_recursive_absolute(marks + ".tmp")
	c.answers = [_progression_answer({"status": "inconsistent", "ticket_id": T1})]
	await a.recover()
	_check(c.store_block_reason() == OnlinePendingStore.HELD_REASON, "FIX-04: both writes failed -> account HELD")
	c.queue_free()
	DirAccess.remove_absolute(path + ".tmp")
	DirAccess.remove_absolute(marks + ".tmp")
	fresh = _adapter(U1)
	_check(fresh.get_client().store_block_reason() == OnlinePendingStore.HELD_REASON, "FIX-04: still held after a restart")
	var held := await fresh._submit_durable(CLAIM)
	_check(held["handling"] == OnlineCombatAdapter.BLOCKED and (fresh.get_client() as ScriptedClient).sent.is_empty(), "FIX-04: held: nothing sent")
	fresh.get_client().queue_free()


func _case_fix05_ticket_hold() -> void:
	_wipe("user://online_pending")
	var a := _adapter(U1)
	var c: ScriptedClient = a.get_client()
	c.answers = [_progression_answer({"status": "inconsistent", "ticket_id": T1})]
	var r := await a.recover()
	var stored := _disk(U1)
	_check(r["handling"] == OnlineCombatAdapter.CONFLICT and stored == {"kind": "ticket_hold", "ticket_id": T1, "state": OnlinePendingStore.STATE_NEEDS_CHECK, "reason": OnlineCombatAdapter.INTENT_INCONSISTENT}, "FIX-05: a claim-less ticket hold is written (%s)" % str(stored))
	_check(not stored.has("key") and not stored.has("payload") and c.sent.size() == 1, "FIX-05: no claim key or claim invented, no claim / abandon sent")
	c.queue_free()
	var fresh := _adapter(U1)
	var fc: ScriptedClient = fresh.get_client()
	_check(fresh.get_pending().get("kind") == "ticket_hold", "FIX-05: the hold survives a restart")
	var s1 := await fresh._submit_durable(CLAIM)
	var s2 := await fresh._abandon_durable(T1)
	fc.answers = [_progression_answer(_intent("r".repeat(32)))]
	var s3 := await fresh.recover()
	_check(s1["handling"] == OnlineCombatAdapter.BLOCKED and s2["handling"] == OnlineCombatAdapter.BLOCKED and s3["handling"] == OnlineCombatAdapter.BLOCKED, "FIX-05: claim / abandon / recover for that ticket stay blocked (no automatic release)")
	_check(_sent_ids(fc) == [OnlineCombatAdapter.RPC_PROGRESSION] and fresh.get_confirmed_progression()["level"] == 1, "FIX-05: nothing but the read is sent; no EXP")
	fc.queue_free()
	# The hold written via the journal only (live write failed) is restored too.
	_wipe("user://online_pending")
	a = _adapter(U1)
	c = a.get_client()
	DirAccess.make_dir_recursive_absolute(OnlinePendingStore.new().path_for(U1) + ".tmp")
	c.answers = [_progression_answer({"status": "inconsistent", "ticket_id": T1})]
	await a.recover()
	c.queue_free()
	DirAccess.remove_absolute(OnlinePendingStore.new().path_for(U1) + ".tmp")
	_check(_disk(U1).get("kind") == "ticket_hold", "FIX-05/04: hold restored from the journal after a failed live write")
	# Defence in depth: even a (non-storable) ticket_hold marked "pending" in
	# memory is never resent - it carries no key / claim to send.
	_wipe("user://online_pending")
	var d := _adapter(U1)
	var dc: ScriptedClient = d.get_client()
	var bad_hold := {"kind": "ticket_hold", "ticket_id": T1, "state": OnlinePendingStore.STATE_PENDING, "reason": ""}
	dc._combat_pending = bad_hold.duplicate()  # test-only: bypasses the store, which refuses it
	dc.mark_combat_pending_verified()
	var r4 := await d._resend_durable(bad_hold)
	_check(r4["handling"] == OnlineCombatAdapter.BLOCKED and dc.sent.is_empty(), "FIX-05: a ticket_hold is never resent, whatever its state")
	dc.queue_free()


# --- helpers -----------------------------------------------------------------------

func _adapter(user: String) -> OnlineCombatAdapter:
	var c := ScriptedClient.new()
	root.add_child(c)
	c.enable_pending_store(OnlinePendingStore.new())
	c._accept_session(NakamaSession.new(_token(user), false))
	c._gameplay_session_id = GSID
	var a := OnlineCombatAdapter.new(c)
	a._ticket = {"ticket_id": T1}
	return a


## A pending claim created by `a` in this process (no answer); returns its key.
func _in_process_claim(a: OnlineCombatAdapter) -> String:
	var c: ScriptedClient = a.get_client()
	c.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"}]
	await a._submit_durable(CLAIM)
	return a.get_pending()["key"]


## Leaves a pending claim for T1 on disk, as an app kill would; returns its key.
func _left_pending_claim(user: String) -> String:
	var a := _adapter(user)
	var c: ScriptedClient = a.get_client()
	c.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"}]
	await a._submit_durable(CLAIM)
	var key: String = a.get_pending()["key"]
	c.queue_free()
	return key


## The exact E1 encounter receipt (wp01e.ts E_RECEIPT_KEYS, contract v1) for
## the request: key, ticket, claim (or abandon) and request hash.
func _claim_receipt(over := {}) -> Callable:
	return func(payload: Dictionary) -> Dictionary:
		var abandon := payload.has("confirm")
		var kills := int(payload.get("kills", 0))
		var r := {"contract": "myrial.vs01.wp01e.receipt", "contract_version": 1.0, "kind": "abandon" if abandon else "claim",
			"idempotency_key": payload.get("idempotency_key", ""), "user_id": U1, "gameplay_session_id": GSID,
			"ticket_id": payload["ticket_id"], "status": "applied", "cooldown_groups": [], "intent_first_seen_at_ms": -1.0, "server_time_ms": 1.0,
			"progression_revision": 1.0, "exp_before": 0.0, "level_before": 1.0}
		if abandon:
			r.merge({"request_hash": "abandon|" + payload["ticket_id"], "outcome": null, "kills_claimed": null, "kills_accepted": null,
				"hero_alive": null, "exp_awarded": 0.0, "level_after": 1.0, "exp_after": 0.0}, true)
		else:
			r.merge({"request_hash": "claim|%s|%s|%d|%s" % [payload["ticket_id"], payload["outcome"], kills, "1" if payload["hero_alive"] else "0"],
				"outcome": payload["outcome"], "kills_claimed": float(kills), "kills_accepted": float(kills), "hero_alive": payload["hero_alive"],
				"exp_awarded": 100.0, "level_after": 2.0, "exp_after": 0.0}, true)
		r.merge(over, true)
		return {"status": OnlineProgressClient.OK, "reason": "", "data": {"replayed": false, "receipt": r,
			"progression": {"level": 2.0, "exp": 0.0, "exp_to_next": 200.0, "revision": 1.0}}}


func _intent(key: String, claim := CLAIM) -> Dictionary:
	return {"status": "recorded", "ticket_id": T1, "idempotency_key": key,
		"claim": {"outcome": claim["outcome"], "kills": float(claim["kills"]), "hero_alive": claim["hero_alive"]}, "first_seen_at_ms": 1.0}


func _progression_answer(intent: Variant, with_field := true) -> Dictionary:
	var data := {"progression": {"level": 1.0, "exp": 0.0, "exp_to_next": 100.0, "revision": 0.0},
		"unresolved_ticket": {"ticket_id": T1, "enemy_count": 10.0}, "group_available_at_ms": {}, "server_time_ms": 1.0}
	if with_field:
		data["recorded_intent"] = intent
	return {"status": OnlineProgressClient.OK, "reason": "", "data": data}


static func _refusal(grpc: int, reason: String) -> Dictionary:
	return {"status": OnlineProgressClient.REJECTED, "reason": reason, "grpc_status": grpc}


func _disk(user: String) -> Dictionary:
	return OnlinePendingStore.new().load_account(user)["combat"]


static func _sent_ids(c: ScriptedClient) -> Array:
	return c.sent.map(func(s: Dictionary) -> String: return s["id"])


func _start_resend(a: OnlineCombatAdapter, done: Array) -> void:
	done.append(await a.resend_pending())


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
