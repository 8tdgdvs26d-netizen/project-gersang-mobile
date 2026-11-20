extends SceneTree

## VS-01 WP01-H E3 LIVE (client layer): the E2 Godot client (OnlineProgressClient,
## OnlinePendingStore, OnlineCombatAdapter) against the REAL Nakama of ONE
## isolated run (Blueprint v0.1r2). ONE phase per Godot process; the launcher
## (nakama/scripts/run_wp01h_e3_bounded.mjs) runs the phases in order, kills /
## restarts nothing itself, takes the database snapshots (S0 / S1) and the
## lossy-proxy counters between phases, and judges each case.
##
##   godot --headless --path godot --script res://tests/live_vs01_wp01h_recovery.gd -- \
##     --phase <phase> --label <case-label> [--variant <v>] --host 127.0.0.1 --port <api> \
##     --proxy-port <lossy proxy>
##
## Isolation: Godot runs with HOME / XDG_* / TMPDIR inside the run root, so
## user:// is a disposable folder; this script never reads or writes a save
## (SaveStore.DEFAULT_PATH must not exist) and never runs docker.
## State shared by the phases of ONE case lives in user://wp01h_e3/<label>.json
## (disposable test password included; it is never printed).
##
## Phases (case -> phases, in order):
##   probe                          isolation probe only
##   AC-04      ac04
##   AC-05a     a05_prep / a05_blocked / a05_recover    --variant a1a|a1b|a2|a3|a4|a5
##   AC-05b     b05_prep / b05_check, b05_prep / b05_kill / b05_kill_check
##   AC-06      ac06
##   AC-13 / FS-K1  k_prep / k_check                   --variant tmp|rename|clear|claim
##   FS-K2      k2_lossy
##   FS-K5      k5_switch
##   FS-K8      k8_prep / k8_check
##   AC-18      ac18_prep (E1 server) / ac18_check (BASELINE server)
## Each phase prints one line "WP01H_RESULT {json}" and, when it passes and is
## not a kill phase, "VS-01 WP01-H live <phase> passed".

const CLOSED_PORT := 1
const GOOD := "test_good_01"
const STATE_DIR := "user://wp01h_e3"
const RESULT_TAG := "WP01H_RESULT "

var _checks := 0
var _failures := 0
var _phase := ""
var _label := ""
var _variant := ""
var _host := "127.0.0.1"
var _port := 17350
var _proxy_port := 17370
var _nonce := ""
var _result := {}


class KillStore extends OnlinePendingStore:
	var kill_at := ""
	var kill_on_write := 1
	var _writes := 0

	func _crash_point(name: String) -> void:
		if name == "tmp_written":
			_writes += 1
		if name == kill_at and _writes >= kill_on_write:
			print("KILL-POINT %s write %d; killing pid %d" % [name, _writes, OS.get_process_id()])
			OS.kill(OS.get_process_id())
			OS.delay_msec(5000)


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	_phase = _arg(args, "--phase", "")
	_label = _arg(args, "--label", _phase)
	_variant = _arg(args, "--variant", "")
	_host = _arg(args, "--host", _host)
	_port = int(_arg(args, "--port", str(_port)))
	_proxy_port = int(_arg(args, "--proxy-port", str(_proxy_port)))
	_nonce = Crypto.new().generate_random_bytes(8).hex_encode()
	_result = {"phase": _phase, "label": _label, "variant": _variant, "pid": OS.get_process_id(), "nonce": _nonce,
		"user_data_dir": OS.get_user_data_dir(), "killed": false}
	print("Godot reports a user data folder: %s" % OS.get_user_data_dir())
	_check(not FileAccess.file_exists(SaveStore.DEFAULT_PATH), "No local save file exists in the isolated user data folder")
	if not _label.is_valid_identifier() and not _label.replace("-", "_").is_valid_identifier():
		_check(false, "label must be a plain identifier")
	else:
		await _run_phase()
	_check(not FileAccess.file_exists(SaveStore.DEFAULT_PATH), "No local save file was created or changed")
	_finish()


func _run_phase() -> void:
	match _phase:
		"probe": _result["save_exists"] = FileAccess.file_exists(SaveStore.DEFAULT_PATH)
		"ac04": await _ac04()
		"a05_prep": await _a05_prep()
		"a05_blocked": await _a05_blocked()
		"a05_recover": await _a05_recover()
		"b05_prep": await _b05_prep()
		"b05_check": await _b05_check(false)
		"b05_kill": await _b05_kill()
		"b05_kill_check": await _b05_check(true)
		"ac06": await _ac06()
		"k_prep": await _k_prep()
		"k_check": await _k_check()
		"k2_lossy": await _k2_lossy()
		"k5_switch": await _k5_switch()
		"k8_prep": await _k8_prep()
		"k8_check": await _k8_check()
		"ac18_prep": await _ac18_prep()
		"ac18_check": await _ac18_check()
		_: _check(false, "unknown phase %s" % _phase)


# --- AC-04 write-ahead -------------------------------------------------------------

func _ac04() -> void:
	var st := await _new_account()
	var c := await _signed_in(st, OnlinePendingStore.new(), CLOSED_PORT)
	var r := await c.buy("A", GOOD, 1)
	var key: String = r.get("idempotency_key", "")
	_check(r["status"] == OnlineProgressClient.UNCERTAIN, "AC-04 (a) no server answer -> uncertain")
	var disk := OnlinePendingStore.new().load_account(c.get_user_id())
	_check((disk["trade"] as Dictionary).has(key), "AC-04 (a) the order was on disk before the RPC attempt")
	_result["ac04_unsent_key"] = key
	# (b) the store cannot be written: the order is refused locally, no RPC.
	c.queue_free()
	var st2 := await _new_account("b")
	var probe := await _signed_in(st2, OnlinePendingStore.new(), _port)
	var path := OnlinePendingStore.new().path_for(probe.get_user_id())
	DirAccess.make_dir_recursive_absolute(path + ".tmp")  # a directory where the temp file must go
	var refused := await probe.buy("A", GOOD, 1)
	_check(refused.get("local", false) and refused["status"] == OnlineProgressClient.REJECTED, "AC-04 (b) store write failed -> refused locally, nothing sent (%s)" % str(refused.get("reason")))
	_result["ac04_refused_key"] = refused.get("idempotency_key", "")
	_result["user_ids"] = [c.get_user_id(), probe.get_user_id()]
	_result["user_id"] = probe.get_user_id()
	DirAccess.remove_absolute(path + ".tmp")


# --- AC-05a: untrusted / unresolved pending blocks new trades ------------------

func _a05_prep() -> void:
	var st := await _new_account()
	var port := _proxy_port if _variant in ["a1a", "a2", "a4", "a5"] else CLOSED_PORT
	var c := await _signed_in(st, OnlinePendingStore.new(), port)
	var uid := c.get_user_id()
	if _variant == "a3":
		# FSF: a journal mark whose live entry does not exist (no order ever filed).
		_check(OnlinePendingStore.new().record_marks(uid, {OnlineProgressClient.new_idempotency_key(): {"state": "quarantined", "reason": "e3_fixture"}}, {}), "a3 orphan journal mark recorded")
	else:
		var r := await c.buy("A", GOOD, 10)
		_check(r["status"] == OnlineProgressClient.UNCERTAIN, "%s original order has an unknown outcome (%s)" % [_variant, str(r.get("reason"))])
		st["original_key"] = r.get("idempotency_key", "")
	_save(st)
	_result["user_id"] = uid
	_kill_now("a05_prep %s" % _variant)


func _a05_blocked() -> void:
	var st := _load()
	var uid: String = st["user_id"]
	var store := OnlinePendingStore.new()
	match _variant:
		"a2":
			_check(_overwrite(store.path_for(uid), "{corrupt"), "a2 live pending file damaged")
		"a4":
			_check(store.record_marks(uid, {String(st["original_key"]): {"state": "needs_check", "reason": "e3_fixture"}}, {}), "a4 entry marked needs_check")
		"a5":
			_check(store.hold_account(uid, "e3_fixture"), "a5 HOLD marker written")
	var c := await _signed_in(st, OnlinePendingStore.new(), _port)
	var refused := await c.buy("A", GOOD, 1)
	_check(refused.get("local", false) and refused["status"] == OnlineProgressClient.REJECTED, "%s new trade refused locally (B-4A): %s" % [_variant, str(refused.get("reason"))])
	var want := {"a1a": OnlineProgressClient.TRADE_UNRESOLVED, "a1b": OnlineProgressClient.TRADE_UNRESOLVED,
		"a4": OnlineProgressClient.TRADE_NEEDS_CHECK, "a2": OnlinePendingStore.QUARANTINED_REASON,
		"a3": "pending_store_untrusted", "a5": OnlinePendingStore.HELD_REASON}
	_check(str(refused.get("reason")) == want[_variant], "%s refused for %s (got %s)" % [_variant, want[_variant], str(refused.get("reason"))])
	if _variant in ["a2", "a3", "a5"]:
		_check(c.store_block_reason() == want[_variant], "%s store blocked with %s (got %s)" % [_variant, want[_variant], c.store_block_reason()])
	var read := await c.refresh_progress()
	_check(read["status"] == OnlineProgressClient.OK, "%s safe read still works" % _variant)
	_result["user_id"] = uid
	_result["blocked_reason"] = str(refused.get("reason"))
	_result["store_block"] = c.store_block_reason()
	_result["refused_key"] = refused.get("idempotency_key", "")


func _a05_recover() -> void:
	var st := _load()
	var c := await _signed_in(st, OnlinePendingStore.new(), _proxy_port)  # through the proxy: a vs01_trade would be counted
	var outcomes := await c.recover_pending()
	if _variant in ["a1a", "a1b"]:
		_check(outcomes.size() == 1 and outcomes[0]["status"] == OnlineProgressClient.OK, "%s the original order resolves once (%s)" % [_variant, str(outcomes)])
		var want := "applied" if _variant == "a1a" else "voided"
		_check(not outcomes.is_empty() and str(outcomes[0].get("outcome", outcomes[0].get("receipt", {}).get("status", ""))) == want, "%s outcome %s" % [_variant, want])
		_check(c.get_pending_states().is_empty(), "%s nothing left pending" % _variant)
	else:
		_check(outcomes.is_empty() or outcomes.all(func(o): return o.get("local", false)), "%s still blocked: no recovery RPC" % _variant)
	_result["user_id"] = c.get_user_id()
	_result["outcomes"] = outcomes.map(func(o): return {"status": o.get("status"), "reason": o.get("reason"), "outcome": o.get("outcome", "")})


# --- AC-05b: legitimate multi-pending recovery ---------------------------------

func _b05_prep() -> void:
	var st := await _new_account()
	var c := await _signed_in(st, OnlinePendingStore.new(), _port)
	var k1 := OnlineProgressClient.new_idempotency_key()
	var k2 := OnlineProgressClient.new_idempotency_key()
	var k3 := OnlineProgressClient.new_idempotency_key()
	var cmd1 := {"action": "buy", "city_id": "A", "good_id": GOOD, "quantity": 10}
	var cmd3 := {"action": "sell", "city_id": "A", "good_id": "test_good_02", "quantity": 1}
	# Server side: K1 applied and K3 rejected straight through the RPC (not
	# filed as pending by this client), K2 never sent.
	var r1 := await c.gameplay_rpc(OnlineProgressClient.RPC_TRADE, _with_key(cmd1, k1))
	var r3 := await c.gameplay_rpc(OnlineProgressClient.RPC_TRADE, _with_key(cmd3, k3))
	_check(r1["status"] == OnlineProgressClient.OK and r1["data"]["receipt"]["status"] == "applied", "b K1 applied on the server")
	_check(r3["status"] == OnlineProgressClient.OK and r3["data"]["receipt"]["status"] == "rejected", "b K3 rejected on the server")
	var uid := c.get_user_id()
	c.sign_out_local()
	# Test-constructed fixture through the PUBLIC store API (not hand-written JSON).
	var entries := {}
	for pair in [[k1, cmd1], [k2, {"action": "buy", "city_id": "A", "good_id": GOOD, "quantity": 1}], [k3, cmd3]]:
		var e: Dictionary = (pair[1] as Dictionary).duplicate()
		e["state"] = OnlinePendingStore.STATE_PENDING
		e["reason"] = ""
		entries[pair[0]] = e
	_check(OnlinePendingStore.new().save_account(uid, entries, {}), "b three pending entries written via save_account()")
	st["k1"] = k1
	st["k2"] = k2
	st["k3"] = k3
	_save(st)
	_result["user_id"] = uid
	_result["keys"] = [k1, k2, k3]


func _b05_check(after_kill: bool) -> void:
	var st := _load()
	var c := await _signed_in(st, OnlinePendingStore.new(), _proxy_port)
	var want_keys := [st["k2"], st["k3"]] if after_kill else [st["k1"], st["k2"], st["k3"]]
	_check(c.get_pending_states().keys().size() == want_keys.size(), "b fresh process restores %d pending entries" % want_keys.size())
	var blocked := await c.buy("A", GOOD, 1)
	_check(blocked.get("local", false), "b B-4A: a new buy is refused before recovery")
	var outcomes := await c.recover_pending()
	var by_key := {}
	for o in outcomes:
		by_key[o.get("idempotency_key", "")] = str(o.get("outcome", ""))
	_check(outcomes.size() == want_keys.size(), "b one resolve per remaining original key (%d)" % outcomes.size())
	if not after_kill:
		_check(by_key.get(st["k1"]) == "applied", "b K1 replays applied")
	_check(by_key.get(st["k2"]) == "voided", "b K2 (never sent) is voided")
	_check(by_key.get(st["k3"]) == "rejected", "b K3 replays rejected")
	_check(c.get_pending_states().is_empty(), "b all cleared")
	var after := await c.buy("A", GOOD, 1)
	_check(after["status"] == OnlineProgressClient.OK and not after.get("local", false), "b a new buy is allowed only after all are cleared")
	_result["user_id"] = c.get_user_id()
	_result["outcomes"] = by_key


func _b05_kill() -> void:
	var st := _load()
	var c := await _signed_in(st, OnlinePendingStore.new(), _port)
	var k1: String = st["k1"]
	var cmd := (c.get_pending_commands() as Dictionary).get(k1, {}) as Dictionary
	var r := await c._trade(cmd, k1)  # an existing pending key is only ever resolved
	_check(str(r.get("outcome", "")) == "applied" and not c.get_pending_states().has(k1), "b K1 resolved and cleared before the kill")
	_result["user_id"] = c.get_user_id()
	_kill_now("b05_kill after K1")


# --- AC-06 account switch on one client ------------------------------------------

func _ac06() -> void:
	var a := await _new_account("a")
	var c := await _signed_in(a, OnlinePendingStore.new(), CLOSED_PORT)
	var r := await c.buy("A", GOOD, 1)
	_check(r["status"] == OnlineProgressClient.UNCERTAIN, "AC-06 account A has an unknown-outcome order")
	var uid_a := c.get_user_id()
	c.sign_out_local()
	var b := await _new_account("b")
	c.configure(_host, _proxy_port)
	var sb := await c.sign_in_email_test(b["email"], b["password"], true)
	_check(sb["status"] == OnlineProgressClient.OK and c.get_user_id() != uid_a, "AC-06 account B signed in on the same client")
	await c.begin_gameplay_session()
	_check(c.get_pending_states().is_empty(), "AC-06 B sees none of A's pending orders")
	_check((await c.recover_pending()).is_empty(), "AC-06 B's recovery sends nothing of A")
	_check((OnlinePendingStore.new().load_account(uid_a)["trade"] as Dictionary).has(r.get("idempotency_key", "")), "AC-06 A's order is still in A's own store file")
	_result["user_id"] = c.get_user_id()
	_result["user_ids"] = [uid_a, c.get_user_id()]


# --- AC-13 / FS-K1 kill points against the real server ---------------------------

func _k_prep() -> void:
	var st := await _new_account()
	match _variant:
		"tmp":
			var c := await _signed_in(st, _kill_store("tmp_written", 1), _port)
			_save(st)
			await c.buy("A", GOOD, 1)
		"rename":
			var c := await _signed_in(st, _kill_store("renamed", 1), _port)
			_save(st)
			await c.buy("A", GOOD, 1)
		"clear":
			var c := await _signed_in(st, _kill_store("tmp_written", 2), _port)  # 1 = order, 2 = the clear after the receipt
			_save(st)
			await c.buy("A", GOOD, 1)
		"claim":
			var c := await _signed_in(st, _kill_store("renamed", 1), _port)
			var adapter := OnlineCombatAdapter.new(c)
			var b := await adapter.begin_encounter([OnlineCombatAdapter.GROUP_IDS[0]])
			_check(b["status"] == OnlineProgressClient.OK, "claim ticket begun")
			await create_timer(10.3).timeout
			_save(st)
			await adapter._submit_durable({"outcome": "victory", "kills": 10, "hero_alive": true})
	_check(false, "k_prep %s must have been killed" % _variant)


func _k_check() -> void:
	var st := _load()
	# Trades recover through the proxy (a vs01_trade would be counted, AC-17);
	# the claim goes direct (the proxy drops every claim answer).
	var c := await _signed_in(st, OnlinePendingStore.new(), _port if _variant == "claim" else _proxy_port)
	var states := c.get_pending_states()
	match _variant:
		"tmp":
			_check(states.is_empty(), "tmp: killed before the order was durable -> nothing pending, nothing was sent")
		"rename", "clear":
			_check(states.size() == 1, "%s: the durable order is restored" % _variant)
			var out := await c.recover_pending()
			var want := "voided" if _variant == "rename" else "applied"
			_check(out.size() == 1 and str(out[0].get("outcome", "")) == want, "%s: resolved to %s exactly once (%s)" % [_variant, want, str(out)])
			_check(c.get_pending_states().is_empty(), "%s: cleared" % _variant)
		"claim":
			var adapter := OnlineCombatAdapter.new(c)
			_check(adapter.has_pending() and not c.is_combat_pending_verified(), "claim: restored, unverified (FIX-02)")
			var r := await adapter.recover()
			_check(r["handling"] == OnlineCombatAdapter.CONFIRMED, "claim: verified against the recorded intent, then confirmed once (%s)" % str(r.get("reason")))
	_result["user_id"] = c.get_user_id()


# --- FS-K2 / FS-K5 / FS-K8 ---------------------------------------------------------

func _k2_lossy() -> void:
	var st := await _new_account()
	var c := await _signed_in(st, OnlinePendingStore.new(), _proxy_port)  # the proxy drops every trade answer after commit
	var applied := 0
	for i in 5:
		var r := await c.buy("A", GOOD, 1)
		_check(r["status"] == OnlineProgressClient.UNCERTAIN, "K2 round %d: answer lost after commit" % i)
		var out := await c.recover_pending()
		_check(out.size() == 1 and str(out[0].get("outcome", "")) == "applied", "K2 round %d: resolved as applied once" % i)
		if not out.is_empty() and str(out[0].get("outcome", "")) == "applied":
			applied += 1
		_check(c.get_pending_states().is_empty(), "K2 round %d: cleared" % i)
	_result["user_id"] = c.get_user_id()
	_result["applied"] = applied


func _k5_switch() -> void:
	var a := await _new_account("a")
	var c := await _signed_in(a, OnlinePendingStore.new(), _proxy_port)
	var uid_a := c.get_user_id()
	_late_done = false
	_late_buy.call_deferred(c)  # in flight; its answer will be dropped by the proxy
	await process_frame
	await process_frame
	c.sign_out_local()
	var b := await _new_account("b")
	var sb := await c.sign_in_email_test(b["email"], b["password"], true)
	await c.begin_gameplay_session()
	while not _late_done:
		await process_frame
	var answer := _late_answer
	_check(sb["status"] == OnlineProgressClient.OK and c.get_user_id() != uid_a, "K5 switched to B while A's order was in flight")
	_check(c.get_pending_states().is_empty(), "K5 the late answer of A's order touched nothing of B")
	_check((OnlinePendingStore.new().load_account(uid_a)["trade"] as Dictionary).size() <= 1, "K5 A's order stays in A's own file")
	_result["user_id"] = c.get_user_id()
	_result["user_ids"] = [uid_a, c.get_user_id()]
	_result["late_status"] = answer.get("status")


var _late_done := false
var _late_answer := {}


func _late_buy(c: OnlineProgressClient) -> void:
	_late_answer = await c.buy("A", GOOD, 1)
	_late_done = true


func _k8_prep() -> void:
	var st := await _new_account()
	var c := await _signed_in(st, OnlinePendingStore.new(), _proxy_port)
	var adapter := OnlineCombatAdapter.new(c)
	var b := await adapter.begin_encounter([OnlineCombatAdapter.GROUP_IDS[0]])
	_check(b["status"] == OnlineProgressClient.OK, "K8 ticket begun")
	await create_timer(10.3).timeout
	var cl := await adapter._submit_durable({"outcome": "victory", "kills": 10, "hero_alive": true})
	_check(cl["handling"] == OnlineCombatAdapter.KEEP, "K8 claim answer lost after commit -> kept (%s)" % str(cl.get("reason")))
	c.configure(_host, CLOSED_PORT)
	var t := await c.buy("A", GOOD, 1)
	_check(t["status"] == OnlineProgressClient.UNCERTAIN, "K8 trade outcome unknown too")
	_save(st)
	_result["user_id"] = c.get_user_id()
	_kill_now("k8_prep")


func _k8_check() -> void:
	var st := _load()
	var c := await _signed_in(st, OnlinePendingStore.new(), _port)
	var adapter := OnlineCombatAdapter.new(c)
	var tr := await c.recover_pending()
	_check(tr.size() == 1 and str(tr[0].get("outcome", "")) == "voided", "K8 trade resolved (voided) after the kill")
	var cr := await adapter.recover()
	_check(cr["handling"] == OnlineCombatAdapter.CONFIRMED and not adapter.has_pending(), "K8 combat claim verified and confirmed once")
	_result["user_id"] = c.get_user_id()


# --- AC-18 new client + baseline (old) server -----------------------------------

func _ac18_prep() -> void:
	var st := await _new_account()
	var c := await _signed_in(st, OnlinePendingStore.new(), _port)
	var adapter := OnlineCombatAdapter.new(c)
	var b := await adapter.begin_encounter([OnlineCombatAdapter.GROUP_IDS[0]])
	_check(b["status"] == OnlineProgressClient.OK, "AC-18 ticket begun on the E1 server")
	c.configure(_host, CLOSED_PORT)
	var cl := await adapter._submit_durable({"outcome": "victory", "kills": 10, "hero_alive": true})
	_check(cl["handling"] == OnlineCombatAdapter.KEEP, "AC-18 claim filed, outcome unknown")
	var t := await c.buy("A", GOOD, 1)
	_check(t["status"] == OnlineProgressClient.UNCERTAIN, "AC-18 trade filed, outcome unknown")
	_save(st)
	_result["user_id"] = c.get_user_id()
	_kill_now("ac18_prep")


func _ac18_check() -> void:
	var st := _load()
	var c := await _signed_in(st, OnlinePendingStore.new(), _proxy_port)
	var before := c.get_pending_states().size()
	var out := await c.recover_pending()
	_check(not out.is_empty() and out.all(func(o): return o.get("outcome", "") == ""), "AC-18 baseline server: the resolve is not answered with an outcome (%s)" % str(out))
	_check(not c.get_pending_states().is_empty() and c.get_pending_states().size() == before, "AC-18 the trade stays pending (never cleared, never vs01_trade)")
	var adapter := OnlineCombatAdapter.new(c)
	var r := await adapter.recover()
	_check(r["handling"] == OnlineCombatAdapter.BLOCKED and r.get("reason") == OnlineCombatAdapter.RECOVERY_UNSUPPORTED, "AC-18 combat recovery BLOCKED recovery_capability_missing (%s)" % str(r.get("reason")))
	_check(adapter.has_pending(), "AC-18 the claim is kept")
	_result["user_id"] = c.get_user_id()


# --- helpers --------------------------------------------------------------------

func _arg(args: PackedStringArray, flag: String, fallback: String) -> String:
	var i := args.find(flag)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _new_account(suffix := "") -> Dictionary:
	var tag := ("%s_%s" % [_label, suffix]) if not suffix.is_empty() else _label
	var st := {"email": "wp01h-%s-%s@myrial.test" % [tag.to_lower().replace("_", "-"), _nonce],
		"password": "localtest-" + Crypto.new().generate_random_bytes(12).hex_encode()}
	return st


func _signed_in(st: Dictionary, store: OnlinePendingStore, port: int) -> OnlineProgressClient:
	var c := OnlineProgressClient.new()
	root.add_child(c)
	c.enable_pending_store(store)
	c.configure(_host, _port)
	var s := await c.sign_in_email_test(st["email"], st["password"], true)
	_check(s["status"] == OnlineProgressClient.OK, "signed in (%s)" % str(s.get("reason")))
	var g := await c.begin_gameplay_session()
	_check(g["status"] == OnlineProgressClient.OK, "gameplay session begun")
	st["user_id"] = c.get_user_id()
	c.configure(_host, port)  # after sign-in: the chosen path (server / lossy proxy / closed port)
	return c


func _kill_store(point: String, on_write: int) -> KillStore:
	var s := KillStore.new()
	s.kill_at = point
	s.kill_on_write = on_write
	return s


func _with_key(cmd: Dictionary, key: String) -> Dictionary:
	var p := cmd.duplicate()
	p["idempotency_key"] = key
	return p


func _state_path() -> String:
	return "%s/%s.json" % [STATE_DIR, _label]


func _save(st: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(STATE_DIR)
	var f := FileAccess.open(_state_path(), FileAccess.WRITE)
	_check(f != null and f.store_string(JSON.stringify(st)), "case state saved in the isolated user://")
	if f != null:
		f.close()


func _load() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_state_path()))
	_check(typeof(parsed) == TYPE_DICTIONARY, "case state of %s found" % _label)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {"email": "", "password": ""}


func _overwrite(path: String, text: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	var ok := f.store_string(text)
	f.close()
	return ok


func _kill_now(where: String) -> void:
	_result["killed"] = true
	_result["checks"] = _checks
	_result["failures"] = _failures
	print(RESULT_TAG + JSON.stringify(_result))
	print("KILL-POINT %s; killing pid %d" % [where, OS.get_process_id()])
	OS.kill(OS.get_process_id())
	OS.delay_msec(5000)


func _finish() -> void:
	_result["checks"] = _checks
	_result["failures"] = _failures
	print(RESULT_TAG + JSON.stringify(_result))
	if _failures == 0:
		print("VS-01 WP01-H live %s passed (%d checks)" % [_phase, _checks])
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("ok   - " + message)
	else:
		_failures += 1
		push_error("FAILED: " + message)
		print("FAILED: " + message)
