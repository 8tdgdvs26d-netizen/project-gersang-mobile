extends SceneTree

## VS-01 WP01-B-S01 — deterministic checks that the SHARED OnlineProgressClient
## keeps its server-confirmed cache consistent when answers arrive late or in
## any order. Needs no server: part of the normal Godot regression.
##
## A gated test client holds every answer until the test releases it, so each
## case fixes the exact completion order:
##   A revision 3 answers before revision 2
##   B same revision, quote answers reversed (later-issued request wins)
##   C sign-out, then an old request answers
##   D another account signs in, then an old request answers
##   E session taken over by another device (policy A), and a late
##     "superseded" answer for an OLD local session after this device took
##     the character back
##   F taking the character back: late answers of the old session never undo it
##   G network loss and retry with the same idempotency key
##   H pending recovery running concurrently with new trades
##   I the SAME account signs in again while requests are in flight
##     (PR #135 review): their late answers must not change the state

const GOOD := "test_good_01"

var _checks := 0
var _failures := 0


## Holds each answer until released; records what was sent.
class GatedClient extends OnlineProgressClient:
	var gates: Array = []
	var sent: Array = []

	func is_signed_in() -> bool:
		return _session != null

	func queue(answer: Dictionary) -> int:
		gates.append({"answer": answer, "released": false, "taken": false})
		return gates.size() - 1

	func release(index: int) -> void:
		gates[index]["released"] = true

	func _rpc(id: String, payload: Dictionary) -> Dictionary:
		sent.append({"id": id, "payload": payload.duplicate(true)})
		var gate: Dictionary = {}
		for g in gates:
			if not g["taken"]:
				g["taken"] = true
				gate = g
				break
		if gate.is_empty():
			return {"status": OnlineProgressClient.UNCERTAIN, "reason": "no scripted answer"}
		while not gate["released"]:
			await Engine.get_main_loop().process_frame
		return gate["answer"]


func _initialize() -> void:
	await process_frame
	var dev_before := _dev_save_fingerprint()
	print("Isolated user:// for this run: %s" % OS.get_user_data_dir())
	await _case_a_reversed_revisions()
	await _case_b_equal_revision_quotes()
	await _case_c_answer_after_sign_out()
	await _case_d_answer_after_account_switch()
	await _case_e_takeover_and_late_superseded()
	await _case_f_reclaim_not_undone_by_old_session()
	await _case_g_network_loss_and_retry()
	await _case_h_recovery_concurrent_with_trades()
	await _case_i_same_account_reauth()
	_check(_dev_save_fingerprint() == dev_before, "Development Save (%s) is untouched" % SaveStore.DEFAULT_PATH)
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-B-S01 client consistency verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Cases -------------------------------------------------------------------------

func _case_a_reversed_revisions() -> void:
	var c := await _signed_in_client("a1", 10000, 1)
	var g2 := c.queue(_trade_ok(9916, 1, 2, 85))
	var g3 := c.queue(_trade_ok(9831, 2, 3, 86))
	var done := []
	_start_buy(c, done)
	_start_buy(c, done)
	await process_frame
	await _release_and_wait(c, g3, done, 1)  # revision 3 first
	await _release_and_wait(c, g2, done, 2)  # older revision 2 last
	var p := c.get_confirmed_progress()
	_check(int(p.get("revision", -1)) == 3 and int(p.get("money", -1)) == 9831 and int(p["backpack"].get(GOOD, 0)) == 2, "A: revision 3 is kept when revision 2 answers later (%s)" % _short(p))
	_check(int(p["quotes"]["A"][GOOD]["buy_price"]) == 86, "A: quotes stay at revision 3")
	_check(done.all(func(r): return r["status"] == OnlineProgressClient.OK), "A: both trades still report their own receipts")
	c.queue_free()


func _case_b_equal_revision_quotes() -> void:
	var c := await _signed_in_client("b1", 10000, 1)
	var early := c.queue(_read_ok(10000, 0, 1, 90))   # earlier-issued read
	var late := c.queue(_read_ok(10000, 0, 1, 88))    # later-issued read
	var done := []
	_start_refresh(c, done)
	_start_refresh(c, done)
	await process_frame
	await _release_and_wait(c, late, done, 1)
	await _release_and_wait(c, early, done, 2)
	var q := int(c.get_confirmed_progress()["quotes"]["A"][GOOD]["buy_price"])
	_check(q == 88, "B: at the same revision the LATER-issued read's quote wins (%d)" % q)
	c.queue_free()


func _case_c_answer_after_sign_out() -> void:
	var c := await _signed_in_client("c1", 10000, 1)
	var g := c.queue(_trade_ok(9160, 10, 2, 89))
	var done := []
	_start_buy(c, done)
	await process_frame
	var key: String = c.get_pending_commands().keys()[0]
	c.sign_out_local()
	await _release_and_wait(c, g, done, 1)
	_check(c.get_confirmed_progress().is_empty(), "C: an answer arriving after sign-out does not refill the cache (%s)" % _short(c.get_confirmed_progress()))
	_check(not c.is_gameplay_session_superseded() and c.get_gameplay_session_id() == "", "C: no session state comes back after sign-out")
	_check(done[0]["status"] != OnlineProgressClient.OK, "C: the late answer is reported as not applicable to the current state (%s)" % done[0]["status"])
	_check(c.get_pending_commands().is_empty(), "C: signed out: no pending command is exposed")
	c._accept_session(NakamaSession.new(_token("c1"), false))
	_check(c.get_pending_commands().has(key), "C: signing the SAME account back in still has its uncertain order pending")
	c.queue_free()


func _case_d_answer_after_account_switch() -> void:
	var c := await _signed_in_client("d-old", 10000, 1)
	var g_old := c.queue(_trade_ok(5000, 60, 7, 99))  # the OLD account's state
	var done := []
	_start_buy(c, done)
	await process_frame
	var old_key: String = c.get_pending_commands().keys()[0]
	# Another account signs in on this client and starts its own session.
	c._accept_session(NakamaSession.new(_token("d-new"), false))
	_check(c.get_confirmed_progress().is_empty(), "D: a different account starts with an empty cache")
	_check(c.get_pending_commands().is_empty(), "D: the old account's pending order is not visible to the new account")
	var g_begin := c.queue(_begin_ok(10000, 0, 1, 84))
	var begun := []
	_start_begin(c, begun)
	await process_frame
	await _release_and_wait(c, g_begin, begun, 1)
	await _release_and_wait(c, g_old, done, 1)  # old account's answer arrives now
	var p := c.get_confirmed_progress()
	_check(int(p.get("money", -1)) == 10000 and int(p.get("revision", -1)) == 1 and p["backpack"].is_empty(), "D: the old account's late answer never reaches the new account's cache (%s)" % _short(p))
	_check(c.get_pending_commands().is_empty(), "D: no old-account command can be recovered under the new account")
	var recovered := await c.recover_pending()
	_check(recovered.is_empty() and _sent_trade_keys(c).count(old_key) == 1, "D: recover_pending() never resends the old account's order")
	c._accept_session(NakamaSession.new(_token("d-old"), false))
	_check(c.get_pending_commands().has(old_key), "D: switching back, the old account's own pending order is still there")
	c.queue_free()


func _case_e_takeover_and_late_superseded() -> void:
	var c := await _signed_in_client("e1", 10000, 1)
	var prompts := [0]
	c.gameplay_session_superseded.connect(func(): prompts[0] += 1)
	# E1: another device took over; this device's next request is refused.
	c.queue({"status": OnlineProgressClient.REJECTED, "reason": "gameplay_session_superseded", "grpc_status": 10})
	c.release(c.gates.size() - 1)
	await c.buy("A", GOOD, 1)
	_check(c.is_gameplay_session_superseded() and prompts[0] == 1, "E: takeover by another device marks this session (signal once)")
	_check((await c.refresh_progress())["reason"] == "gameplay_session_superseded", "E: reads are refused while superseded (policy A)")
	# E2: this device takes the character back while an OLD-session request is
	# still in flight; that request's late "superseded" answer must not undo it.
	c.queue(_begin_ok(9916, 1, 5, 85))
	c.release(c.gates.size() - 1)
	await c.begin_gameplay_session()
	var g_old := c.queue({"status": OnlineProgressClient.REJECTED, "reason": "gameplay_session_superseded", "grpc_status": 10})
	var done := []
	c._gameplay_session_id = "00000000-0000-0000-0000-0000000000e1"  # request sent under an older local session
	_start_refresh(c, done)
	await process_frame
	c._gameplay_session_id = "00000000-0000-0000-0000-0000000000e2"  # this device re-began meanwhile
	await _release_and_wait(c, g_old, done, 1)
	_check(not c.is_gameplay_session_superseded() and prompts[0] == 1, "E: a late superseded answer for an OLD local session does not mark the current one")
	c.queue_free()


func _case_f_reclaim_not_undone_by_old_session() -> void:
	var c := await _signed_in_client("f1", 10000, 1)
	var g_old := c.queue(_trade_ok(9916, 1, 2, 85))   # answer of the old session, revision 2
	var done := []
	_start_buy(c, done)
	await process_frame
	c.queue(_begin_ok(9916, 1, 3, 85))                # taking back: revision 3
	c.release(c.gates.size() - 1)
	await c.begin_gameplay_session()
	await _release_and_wait(c, g_old, done, 1)
	var p := c.get_confirmed_progress()
	_check(int(p.get("revision", -1)) == 3, "F: the old session's late answer (revision 2) does not replace the reclaimed view (revision 3)")
	_check(not c.is_gameplay_session_superseded(), "F: still the active session after the late answer")
	# F2: two session begins in flight; the NEWER one (revision 6) answers
	# first, the older one (revision 5, already superseded on the server) last.
	var g_b5 := c.queue({"status": OnlineProgressClient.OK, "reason": "", "data": {"gameplay_session_id": "00000000-0000-0000-0000-0000000000f5", "progress": _view(9916, 1, 5, 85)}})
	var g_b6 := c.queue({"status": OnlineProgressClient.OK, "reason": "", "data": {"gameplay_session_id": "00000000-0000-0000-0000-0000000000f6", "progress": _view(9916, 1, 6, 85)}})
	var begun := []
	_start_begin(c, begun)
	_start_begin(c, begun)
	await process_frame
	await _release_and_wait(c, g_b6, begun, 1)
	await _release_and_wait(c, g_b5, begun, 2)
	_check(c.get_gameplay_session_id() == "00000000-0000-0000-0000-0000000000f6", "F2: a late older begin does not bring back its superseded session id (%s)" % c.get_gameplay_session_id())
	_check(int(c.get_confirmed_progress()["revision"]) == 6, "F2: the cache stays at the newest begin's revision")
	c.queue_free()


func _case_g_network_loss_and_retry() -> void:
	var c := await _signed_in_client("g1", 10000, 1)
	c.queue({"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"})
	c.release(c.gates.size() - 1)
	var lost := await c.buy("A", GOOD, 10)
	_check(lost["pending"] and int(c.get_confirmed_progress()["revision"]) == 1, "G: no answer: pending, cache unchanged")
	# The retry (same key) and a NEW trade overlap; the newer revision answers first.
	var g_retry := c.queue(_trade_ok(9160, 10, 2, 89, true))
	var g_new := c.queue(_trade_ok(9071, 11, 3, 90))
	var done := []
	_start_recover(c, done)
	_start_buy(c, done)
	await process_frame
	await _release_and_wait(c, g_new, done, 1)
	await _release_and_wait(c, g_retry, done, 2)
	var p := c.get_confirmed_progress()
	_check(int(p["revision"]) == 3 and int(p["money"]) == 9071, "G: retry answered last does not roll back the newer trade (%s)" % _short(p))
	_check(c.get_pending_commands().is_empty(), "G: the retried order is resolved, nothing pending")
	_check(_sent_trade_keys(c).count(lost["idempotency_key"]) == 2, "G: the retry reused the SAME idempotency key")
	c.queue_free()


func _case_h_recovery_concurrent_with_trades() -> void:
	var c := await _signed_in_client("h1", 10000, 1)
	for i in range(2):
		c.queue({"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"})
		c.release(c.gates.size() - 1)
		await c.buy("A", GOOD, 1)
	_check(c.get_pending_commands().size() == 2, "H: two uncertain orders pending")
	# Recovery resends both orders (answers: revisions 2 and 4) while a new
	# trade runs (revision 3). The new trade answers LAST, after both retries.
	var g_r1 := c.queue(_trade_ok(9916, 1, 2, 85, true))
	var g_new := c.queue(_trade_ok(9831, 2, 3, 86))
	var recovered := []
	var bought := []
	_start_recover(c, recovered)
	await process_frame
	_start_buy(c, bought)
	await process_frame
	var g_r2 := c.queue(_trade_ok(9745, 3, 4, 87, true))
	c.release(g_r1)
	# recover_pending sends the second retry only after the first resolved.
	while c.sent.size() < 6:
		await process_frame
	await _release_and_wait(c, g_r2, recovered, 2)
	await _release_and_wait(c, g_new, bought, 1)
	var p := c.get_confirmed_progress()
	_check(int(p["revision"]) == 4 and int(p["money"]) == 9745 and int(p["backpack"][GOOD]) == 3, "H: the cache ends at the newest revision (%s)" % _short(p))
	_check(c.get_pending_commands().is_empty(), "H: both recovered orders resolved, nothing pending")
	c.queue_free()


## PR #135 review: same-account re-authentication (for example a new token)
## is an auth boundary too. Requests sent before it may answer after it; those
## answers must not change the cache, the superseded flag or the session id.
## The account's own pending orders (idempotency keys) are kept.
func _case_i_same_account_reauth() -> void:
	var c := await _signed_in_client("i1", 10000, 1)
	var prompts := [0]
	c.gameplay_session_superseded.connect(func(): prompts[0] += 1)
	var g_trade := c.queue(_trade_ok(9160, 10, 2, 89))       # I1 trade in flight
	var g_refresh := c.queue({"status": OnlineProgressClient.REJECTED, "reason": "gameplay_session_superseded", "grpc_status": 10})  # I2
	var g_begin := c.queue(_begin_ok(9160, 10, 3, 89))       # I3 begin in flight
	var traded := []
	var refreshed := []
	var begun := []
	_start_buy(c, traded)
	_start_refresh(c, refreshed)
	_start_begin(c, begun)
	await process_frame
	var key: String = c.get_pending_commands().keys()[0]
	c._accept_session(NakamaSession.new(_token("i1"), false))  # SAME account signs in again
	_check(c.get_gameplay_session_id() == "", "I: re-sign-in clears the gameplay session (unchanged behaviour)")
	await _release_and_wait(c, g_trade, traded, 1)
	await _release_and_wait(c, g_refresh, refreshed, 1)
	await _release_and_wait(c, g_begin, begun, 1)
	var p := c.get_confirmed_progress()
	_check(int(p.get("revision", -1)) == 1 and int(p.get("money", -1)) == 10000, "I1: a trade answer from before the re-sign-in does not change the cache (%s)" % _short(p))
	_check(traded[0]["status"] == OnlineProgressClient.UNCERTAIN and traded[0].get("stale", false), "I1: it is reported as uncertain (stale), not as a fresh result")
	_check(c.get_pending_commands().has(key), "I1: the account keeps that order pending (same idempotency key)")
	_check(not c.is_gameplay_session_superseded() and prompts[0] == 0, "I2: a superseded answer from before the re-sign-in does not mark the client")
	_check(c.get_gameplay_session_id() == "", "I3: a begin answer from before the re-sign-in does not install its session id (%s)" % c.get_gameplay_session_id())
	# I4: the account begins a new session and recovers its order by key.
	c.queue(_begin_ok(9160, 10, 4, 89))
	c.release(c.gates.size() - 1)
	await c.begin_gameplay_session()
	_check(c.get_gameplay_session_id() == "00000000-0000-0000-0000-000000000004" and int(c.get_confirmed_progress()["revision"]) == 4, "I4: a new begin after the re-sign-in works normally")
	c.queue(_trade_ok(9160, 10, 4, 89, true))
	c.release(c.gates.size() - 1)
	var recovered := await c.recover_pending()
	_check(recovered.size() == 1 and recovered[0]["status"] == OnlineProgressClient.OK and recovered[0]["replayed"] and c.get_pending_commands().is_empty(), "I4: the pending order is recovered once with its original key")
	_check(_sent_trade_keys(c).count(key) == 2, "I4: the recovery reused the same idempotency key")
	c.queue_free()


# --- Helpers -----------------------------------------------------------------------

func _signed_in_client(user: String, money: int, revision: int) -> GatedClient:
	var c := GatedClient.new()
	root.add_child(c)
	c._accept_session(NakamaSession.new(_token(user), false))
	c.queue(_begin_ok(money, 0, revision, 84))
	c.release(c.gates.size() - 1)
	await c.begin_gameplay_session()
	return c


static func _view(money: int, carried: int, revision: int, buy_price: int) -> Dictionary:
	var backpack := {}
	if carried > 0:
		backpack[GOOD] = carried
	return {"money": money, "backpack": backpack, "revision": revision,
		"quotes": {"A": {GOOD: {"buy_price": buy_price, "buyback_price": 76, "stock": 100}}}}


static func _begin_ok(money: int, carried: int, revision: int, buy_price: int) -> Dictionary:
	return {"status": OnlineProgressClient.OK, "reason": "", "data": {
		"gameplay_session_id": "00000000-0000-0000-0000-%012d" % revision, "progress": _view(money, carried, revision, buy_price)}}


static func _read_ok(money: int, carried: int, revision: int, buy_price: int) -> Dictionary:
	return {"status": OnlineProgressClient.OK, "reason": "", "data": {"progress": _view(money, carried, revision, buy_price)}}


static func _trade_ok(money: int, carried: int, revision: int, buy_price: int, replayed := false) -> Dictionary:
	return {"status": OnlineProgressClient.OK, "reason": "", "data": {"replayed": replayed,
		"receipt": {"status": "applied", "progress_revision": revision}, "progress": _view(money, carried, revision, buy_price)}}


func _release_and_wait(c: GatedClient, gate: int, done: Array, count: int) -> void:
	c.release(gate)
	while done.size() < count:
		await process_frame


func _start_buy(c: OnlineProgressClient, done: Array) -> void:
	done.append(await c.buy("A", GOOD, 1))


func _start_refresh(c: OnlineProgressClient, done: Array) -> void:
	done.append(await c.refresh_progress())


func _start_begin(c: OnlineProgressClient, done: Array) -> void:
	done.append(await c.begin_gameplay_session())


func _start_recover(c: OnlineProgressClient, done: Array) -> void:
	for r in await c.recover_pending():
		done.append(r)


static func _sent_trade_keys(c: GatedClient) -> Array:
	var keys := []
	for s in c.sent:
		if s["id"] == OnlineProgressClient.RPC_TRADE:
			keys.append(s["payload"]["idempotency_key"])
	return keys


static func _short(p: Dictionary) -> String:
	return "rev %s money %s goods %s" % [p.get("revision"), p.get("money"), p.get("backpack", {}).get(GOOD, 0)]


## Syntactically valid UNSIGNED token far in the future; never sent anywhere.
static func _token(user: String) -> String:
	var header := Marshalls.utf8_to_base64(JSON.stringify({"alg": "none"})).trim_suffix("=").trim_suffix("=")
	var body := Marshalls.utf8_to_base64(JSON.stringify({"uid": "user-" + user, "usn": user, "exp": 4102444800})).trim_suffix("=").trim_suffix("=")
	return "%s.%s.x" % [header, body]


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
