extends SceneTree

## VS-01 WP01-F — LIVE run of the Online Progress Resume TEST mode against a
## disposable LOCAL Nakama + PostgreSQL started for one run. Not a verify_*
## script: nakama/scripts/run_wp01f_bounded.mjs runs each phase as its OWN
## Godot process (separate memory), in this order, and compares the printed
## results itself:
##
##   probe     print the resolved user data folder (no network)
##   seed      new account: server-confirmed buy + Hero EXP, then exit
##   readback  fresh process, same account: read both back; sign out and in again
##   (the launcher restarts the Nakama container, then runs readback again)
##   stress    targeted cases on a second disposable account: read dropped
##             mid-request, server timeout, two devices / takeover, a late
##             answer after sign-out
##   t2        WP01-G C2-E1 diagnostic only: the server-timeout case (T2) alone,
##             in its own process, on a third disposable account, with the
##             client's REAL read settings (5 s timeout, 3 attempts,
##             non-threaded HTTP). Measures each read; never changes the client.
##
##   godot --headless --path godot --script res://tests/live_vs01_wp01f_online_progress_resume.gd -- \
##     --phase <probe|seed|readback|stress|t2> [--label <name>] [--host 127.0.0.1] [--port 17350]
##
## The account e-mail / password come from the environment
## (MYRIAL_WP01F_EMAIL / _PASSWORD, stress: MYRIAL_WP01F_STRESS_EMAIL /
## _PASSWORD) and are never printed. Results are printed as one line:
##   WP01F_RESULT {"phase": ..., ...}
## Only the launcher compares results across processes; this script never
## reads a previous run's values from disk.

const SCENE := "res://scenes/online_progress_resume_test_mode.tscn"
const Mode := preload("res://scripts/online_progress_resume_test_mode.gd")
const REP := OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID
## The server confirms a claim only 10 s after the encounter began.
const MIN_AGE_S := 10.5
const FAULT_TIMEOUT_SEC := 2

## WP01-G C2-E1 (phase t2). Product limits are assertions only; E1 adds no
## client deadline. Guards are test-safety limits; the launcher kills the
## whole process at 180 s.
const E1_PRODUCT_READ_MS := 10000
const E1_PRODUCT_REFRESH_MS := 30000
const E1_READ_GUARD_MS := 45000
const E1_AUTH_GUARD_MS := 30000
const E1_EXPECTED_TIMEOUT_SEC := 5
const E1_EXPECTED_ATTEMPTS := 3
## The only RPC ids the diagnostic may name in its output.
const E1_READ_RPCS := {"vs01_progress_get": "trade", "vs01e_progression_get": "hero"}

var _checks := 0
var _failures := 0
## C2-E1: the one T2 result, emitted once at the very end (after the save checks).
var _t2_out := {}
var _t2_snap := {}
var _phase := ""
var _label := ""
var _host := "127.0.0.1"
var _port := 17350
var _nonce := ""


## A local port that accepts connections and then either never answers
## ("stall": a server timeout) or cuts the connection once the request
## arrived ("drop": the read is lost mid-request). Owned by this process only.
class FaultPort extends RefCounted:
	var server := TCPServer.new()
	var mode := "stall"
	var peers: Array = []
	var accepted := 0
	var dropped := 0
	var running := false
	## Monotonic time (usec) of each accepted connection; observation only.
	var accept_usec: Array = []

	func start(p_mode: String) -> int:
		mode = p_mode
		if server.listen(0, "127.0.0.1") != 0:
			return -1
		running = true
		return server.get_local_port()

	func poll() -> void:
		while server.is_connection_available():
			peers.append(server.take_connection())
			accepted += 1
			accept_usec.append(Time.get_ticks_usec())
		for peer in peers:
			var p: StreamPeerTCP = peer
			p.poll()
			if mode == "drop" and p.get_status() == StreamPeerTCP.STATUS_CONNECTED and p.get_available_bytes() > 0:
				p.disconnect_from_host()
				dropped += 1

	func stop() -> void:
		for peer in peers:
			(peer as StreamPeerTCP).disconnect_from_host()
		peers.clear()
		server.stop()
		running = false


func _initialize() -> void:
	await process_frame
	_read_args()
	_nonce = OnlineProgressClient.new_idempotency_key()
	print("WP01-F phase=%s label=%s pid=%d" % [_phase, _label, OS.get_process_id()])
	print("Isolated user:// for this run: %s" % OS.get_user_data_dir())
	var dev_before := _dev_save_fingerprint()
	match _phase:
		"probe":
			_phase_probe()
		"seed":
			await _phase_seed()
		"readback":
			await _phase_readback()
		"stress":
			await _phase_stress()
		"t2":
			await _phase_t2()
		_:
			_check(false, "Known phase (got '%s')" % _phase)
	var failures_before_save := _failures
	_check(_dev_save_fingerprint() == dev_before, "No local save file was created or changed")
	_check(not FileAccess.file_exists(SaveStore.DEFAULT_PATH), "No local save file exists in the isolated user data folder")
	if _phase == "t2":
		_finish_t2(_failures == failures_before_save)
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-F live %s passed (%d checks)" % [_phase, _checks])
	quit(1 if _failures > 0 else 0)


# --- Phases ----------------------------------------------------------------------

func _phase_probe() -> void:
	var info := {
		"phase": "probe",
		"pid": OS.get_process_id(),
		"user_data_dir": OS.get_user_data_dir(),
		"globalized_user": ProjectSettings.globalize_path("user://"),
		"home": OS.get_environment("HOME"),
		"godot_version": Engine.get_version_info().get("string", ""),
	}
	_check(not String(info["user_data_dir"]).is_empty(), "Godot reports a user data folder")
	_emit(info)


func _phase_seed() -> void:
	var account := _account("MYRIAL_WP01F")
	if account.is_empty():
		return
	var mode := await _new_mode()
	_check((await mode.sign_in(account["email"], account["password"], true))["status"] == OnlineProgressClient.OK, "Seed: a NEW disposable local test account signed in")
	var begun := await mode.begin_session()
	_check(begun["status"] == OnlineProgressClient.OK and mode.get_status_text() == Mode.CONFIRMED_TEXT, "Seed: session begun, both contracts confirmed")
	var start := mode.get_snapshot()
	_check(start.get("money") == 10000 and start.get("goods") == 0, "Seed: new account starts at server money 10000 / goods 0 (%s)" % str(start))
	_check(start.get("level") == 1 and start.get("exp") == 0, "Seed: new Hero starts at server Lv 1 / EXP 0")
	var bought := await mode.trade_adapter.buy("A", 10)
	_check(bought["success"], "Seed: server-confirmed buy of 10 x %s in city A (%s)" % [REP, str(bought.get("receipt", {}))])
	var began := await mode.combat_adapter.begin_encounter(["prototype_monster_01"])
	_check(began["status"] == OnlineProgressClient.OK, "Seed: server encounter ticket for one Prototype group")
	if began["status"] == OnlineProgressClient.OK:
		var ticket := mode.combat_adapter.get_ticket()
		var battle := CombatBattle.create_party(int(ticket["enemy_count"]), mode.combat_adapter.hero_stats(), [], {}, {})
		battle.encounter_id = ticket["ticket_id"]
		_win(battle)
		await create_timer(MIN_AGE_S).timeout
		var claim := await mode.combat_adapter.submit_battle(battle)
		for attempt in range(3):
			if claim.get("handling") != OnlineCombatAdapter.KEEP:
				break
			print("   claim kept (%s), resending the same key" % claim.get("reason", ""))
			await create_timer(2.0).timeout
			claim = await mode.combat_adapter.resend_pending()
		_check(claim.get("handling") == OnlineCombatAdapter.CONFIRMED and int(claim.get("receipt", {}).get("exp_awarded", 0)) > 0, "Seed: server-confirmed Hero EXP award (%s)" % str(claim.get("receipt", {})))
	var final := await mode.refresh_all()
	_check(final["status"] == OnlineProgressClient.OK and mode.get_status_text() == Mode.CONFIRMED_TEXT, "Seed: a final read confirms both contracts")
	var snap := mode.get_snapshot()
	_check(snap.get("money") == 10000 - int(bought.get("total_value", 0)) and snap.get("goods") == 10, "Seed: server money / goods after the buy (%d / %d)" % [int(snap.get("money", -1)), int(snap.get("goods", -1))])
	_check(int(snap.get("level", 1)) > 1 or int(snap.get("exp", 0)) > 0, "Seed: server Hero progressed beyond Lv 1 / EXP 0")
	_check(not mode.combat_adapter.has_pending() and mode.combat_adapter.get_unresolved_ticket().is_empty(), "Seed: nothing pending or unresolved before exit")
	_emit(_result("seed", snap))
	mode.queue_free()
	await process_frame


func _phase_readback() -> void:
	var account := _account("MYRIAL_WP01F")
	if account.is_empty():
		return
	var mode := await _new_mode()
	_check(mode.client.get_confirmed_progress().is_empty() and not mode.get_snapshot().has("money") and not mode.get_snapshot().has("level"), "Readback: fresh process holds no progress in memory")
	_check(mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT and mode.get_hero_text() == Mode.HERO_UNKNOWN_TEXT, "Readback: the screen shows nothing before the server answers")
	_check((await mode.sign_in(account["email"], account["password"], false))["status"] == OnlineProgressClient.OK, "Readback: the SAME account signs in (no account creation)")
	var begun := await mode.begin_session()
	_check(begun["status"] == OnlineProgressClient.OK and mode.get_status_text() == Mode.CONFIRMED_TEXT, "Readback: both contracts confirmed by the server")
	var first := mode.get_snapshot()
	_check(first.has("money") and first.has("level"), "Readback: Trade and Hero values present (%s)" % str(first))
	_check(not mode.combat_adapter.has_pending() and mode.combat_adapter.get_unresolved_ticket().is_empty(), "Readback: nothing pending or unresolved on the server")
	_emit(_result("readback", first))
	# Sign out and back in on the same process: read from the server again.
	mode.sign_out()
	_check(not mode.get_snapshot().has("money") and mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT, "Readback: signed out, nothing shown")
	_check((await mode.sign_in(account["email"], account["password"], false))["status"] == OnlineProgressClient.OK, "Readback: the same account signs in again")
	_check(not mode.get_snapshot().has("money"), "Readback: signed in again, nothing shown before the server answers")
	var again := await mode.begin_session()
	_check(again["status"] == OnlineProgressClient.OK, "Readback: second session begun")
	var second := mode.get_snapshot()
	_check(second.get("money") == first.get("money") and second.get("goods") == first.get("goods"), "Readback: re-login money / goods unchanged")
	_check(second.get("level") == first.get("level") and second.get("exp") == first.get("exp") and second.get("hero_revision") == first.get("hero_revision"), "Readback: re-login Hero Level / EXP / Hero revision unchanged")
	_check(int(second.get("trade_revision", -1)) == int(first.get("trade_revision", -2)) + 1, "Readback: Trade revision +1 only for the new session begin (%s -> %s)" % [str(first.get("trade_revision")), str(second.get("trade_revision"))])
	_emit(_result("relogin", second))
	mode.sign_out()
	mode.queue_free()
	await process_frame


func _phase_stress() -> void:
	var account := _account("MYRIAL_WP01F_STRESS")
	if account.is_empty():
		return
	var mode := await _new_mode()
	_check((await mode.sign_in(account["email"], account["password"], true))["status"] == OnlineProgressClient.OK, "Stress: a second disposable local test account signed in")
	_check((await mode.begin_session())["status"] == OnlineProgressClient.OK, "Stress: session begun")
	var base := mode.get_snapshot()
	var counts := {}

	print("== T1 read dropped mid-request")
	var drop := FaultPort.new()
	var drop_port := drop.start("drop")
	_check(drop_port > 0, "T1 local drop port opened")
	_pump(drop)
	mode.client.timeout_sec = FAULT_TIMEOUT_SEC
	mode.client.configure(_host, drop_port)
	var dropped := await mode.refresh_all()
	counts["t1_connections"] = drop.accepted
	counts["t1_dropped"] = drop.dropped
	drop.stop()
	_check(drop.dropped >= 1, "T1 the read reached the port and was cut (%d accepted, %d cut)" % [drop.accepted, drop.dropped])
	_check(dropped["status"] == OnlineProgressClient.UNCERTAIN and mode.get_status_text() == Mode.UNCERTAIN_TEXT, "T1 dropped read: uncertain, never 'confirmed' (%s)" % mode.get_status_text())
	_check(_same_values(mode.get_snapshot(), base), "T1 dropped read: last server-confirmed values kept")
	mode.client.configure(_host, _port)
	_check((await mode.refresh_all())["status"] == OnlineProgressClient.OK and _same_values(mode.get_snapshot(), base), "T1 after reconnect: same values from the server")

	print("== T2 server timeout")
	var stall := FaultPort.new()
	var stall_port := stall.start("stall")
	_check(stall_port > 0, "T2 local stall port opened")
	_pump(stall)
	mode.client.configure(_host, stall_port)
	var t0 := Time.get_ticks_msec()
	var timed_out := await mode.refresh_all()
	counts["t2_elapsed_ms"] = Time.get_ticks_msec() - t0
	counts["t2_connections"] = stall.accepted
	stall.stop()
	_check(stall.accepted >= 1, "T2 the read reached the stalled port (%d connection(s), %d ms)" % [stall.accepted, counts["t2_elapsed_ms"]])
	_check(timed_out["status"] == OnlineProgressClient.UNCERTAIN and mode.get_status_text() == Mode.UNCERTAIN_TEXT, "T2 timeout: uncertain, never 'confirmed'")
	_check(_same_values(mode.get_snapshot(), base), "T2 timeout: last server-confirmed values kept")
	mode.client.configure(_host, _port)
	_check((await mode.refresh_all())["status"] == OnlineProgressClient.OK, "T2 after the timeout: read confirmed again")

	print("== T3 same account on a second device (policy A takeover)")
	var other := OnlineProgressClient.new()
	root.add_child(other)
	other.configure(_host, _port)
	_check((await other.sign_in_email_test(account["email"], account["password"], false))["status"] == OnlineProgressClient.OK, "T3 second device signed in to the same account")
	var taken := await other.begin_gameplay_session()
	_check(taken["status"] == OnlineProgressClient.OK, "T3 second device takes over")
	var taken_view: Dictionary = taken.get("data", {}).get("progress", {})
	_check(int(taken_view.get("money", -1)) == base.get("money") and int(taken_view.get("backpack", {}).get(REP, 0)) == base.get("goods"), "T3 second device reads the same server money / goods")
	var before_takeover := mode.get_snapshot()
	var refused := await mode.refresh_all()
	_check(mode.get_status_text() == Mode.SUPERSEDED_TEXT and mode.get_panel_button("Reclaim").visible, "T3 first device is told it was taken over and offered reclaim")
	_check(refused["status"] == OnlineProgressClient.REJECTED and mode.get_snapshot() == before_takeover, "T3 first device shows nothing new while taken over")
	_check((await mode.reclaim_session())["status"] == OnlineProgressClient.OK and mode.get_status_text() == Mode.CONFIRMED_TEXT, "T3 first device reclaims and reads both contracts again")
	var after := mode.get_snapshot()
	_check(_same_values(after, base) and int(after.get("trade_revision", -1)) > int(taken_view.get("revision", 0)), "T3 after reclaim: same values, newer Trade revision (%d > %d)" % [int(after.get("trade_revision", -1)), int(taken_view.get("revision", 0))])
	_check((await other.refresh_progress()).get("reason", "") == OnlineProgressClient.SUPERSEDED_REASON, "T3 the second device is now the superseded one")
	other.queue_free()
	await process_frame

	print("== T4 a late answer after sign-out")
	var out := []
	_start_refresh(mode, out)
	# Checked in the same frame: the HTTP request cannot have been answered yet.
	var in_flight := mode.is_busy()
	mode.sign_out()
	while out.is_empty():
		await process_frame
	await process_frame
	counts["t4_was_in_flight"] = in_flight
	_check(in_flight and out[0].get("stale", false), "T4 the read was in flight and its answer came back as stale")
	_check(not mode.get_snapshot().has("money") and not mode.get_snapshot().has("level") and mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT, "T4 the late answer did not reach the signed-out screen")
	_check((await mode.sign_in(account["email"], account["password"], false))["status"] == OnlineProgressClient.OK and (await mode.begin_session())["status"] == OnlineProgressClient.OK, "T4 signed in again")
	_check(_same_values(mode.get_snapshot(), base), "T4 after signing in again: same values from the server")

	var summary := _result("stress", mode.get_snapshot())
	summary["cases"] = counts
	_emit(summary)
	mode.sign_out()
	mode.queue_free()
	await process_frame


## WP01-G C2-E1: T2 (server accepts, never answers) alone, real client read
## settings. Every await is bounded; a failed setup step or an expired guard
## ends the diagnostic at once (no stall / no reconnect). The single result is
## emitted by _finish_t2() after the save checks, from an allowlist of safe
## fields: no e-mail, password, token, header, URI or body is ever printed.
func _phase_t2() -> void:
	var out := {"case_id": "E1-T2", "classification": "", "product_acceptance": "NOT OBSERVED",
		"setup_failure": "", "guard_stage": "", "config": {}, "trade_read": {}, "hero_read": {},
		"refresh_all": {}, "fault_port": {}, "heartbeat": {}, "observer": "NOT RUN",
		"state_checks": {}, "reconnect": "NOT RUN"}
	_t2_out = out
	var account := _account("MYRIAL_WP01F_DIAG")
	if account.is_empty():
		_t2_setup_fail(out, "credentials")
		return
	var mode := await _new_mode()
	var signed := await _bounded(mode.sign_in.bind(account["email"], account["password"], true), E1_AUTH_GUARD_MS)
	if not _t2_guard_ok(signed, "sign_in", out):
		return
	var signed_ok: bool = signed["value"].get("status") == OnlineProgressClient.OK
	_check(signed_ok, "E1-T2: a third disposable local test account signed in")
	if not signed_ok:
		_t2_setup_fail(out, "sign_in")
		return
	var begun := await _bounded(mode.begin_session, E1_AUTH_GUARD_MS)
	if not _t2_guard_ok(begun, "begin_session", out):
		return
	var begun_ok: bool = begun["value"].get("status") == OnlineProgressClient.OK and mode.get_status_text() == Mode.CONFIRMED_TEXT
	_check(begun_ok, "E1-T2: session begun, both contracts confirmed")
	if not begun_ok:
		_t2_setup_fail(out, "begin_session")
		return
	var base := mode.get_snapshot()
	_t2_snap = base

	# Stall port first; nothing is pointed at it unless it really listens.
	var stall := FaultPort.new()
	var stall_port := stall.start("stall")
	_check(stall_port > 0, "E1-T2: local stall port opened")
	if stall_port <= 0:
		stall.stop()
		_t2_setup_fail(out, "fault_port")
		return
	_pump(stall)
	# Real read settings, read back from the objects that send the request.
	mode.client.configure(_host, stall_port)
	mode.client._get_client() # builds the SDK client for this port; no request is sent
	var adapter = mode.client._adapter
	var cfg := {
		"client_timeout_sec": mode.client.timeout_sec,
		"adapter_timeout_sec": adapter.timeout,
		"use_threads": adapter.use_threads,
		"auto_retry": mode.client._client.auto_retry,
		"auto_retry_count": adapter.auto_retry_count,
		"auto_retry_backoff_base": adapter.auto_retry_backoff_base,
		"logger_level": int(adapter.logger._level),
	}
	out["config"] = cfg
	var cfg_ok: bool = cfg["client_timeout_sec"] == E1_EXPECTED_TIMEOUT_SEC and cfg["adapter_timeout_sec"] == E1_EXPECTED_TIMEOUT_SEC \
		and cfg["use_threads"] == false and cfg["auto_retry"] == true and cfg["auto_retry_count"] == E1_EXPECTED_ATTEMPTS \
		and cfg["logger_level"] <= NakamaLogger.LOG_LEVEL.ERROR
	_check(cfg_ok, "E1-T2: real read settings 5 s / 3 attempts / non-threaded / logger ERROR or quieter (%s)" % JSON.stringify(cfg))
	if not cfg_ok:
		stall.stop()
		out["classification"] = "CONFIG_MISMATCH"
		return

	# The stalled read, observed per request and per frame.
	var trace := _new_trace()
	_observe(adapter, trace)
	var t2 := await _bounded(mode.refresh_all, E1_READ_GUARD_MS)
	# Final sweep in the frame refresh_all returned, before the observer stops,
	# so the last request's completion is never lost.
	_observe_sample(adapter, trace, Time.get_ticks_usec())
	trace["stop"] = true
	var waited := 0
	while not trace["observer_done"] and waited < 10:
		await process_frame
		waited += 1
	out["observer"] = "STOPPED" if trace["observer_done"] else "NOT STOPPED"
	stall.stop()
	out["fault_port"] = {"accepted": stall.accepted, "accept_offsets_ms": _offsets_ms(stall.accept_usec)}
	out["heartbeat"] = {"frames": trace["frames"], "max_frame_gap_ms": int(trace["max_frame_gap_usec"] / 1000)}
	out["trade_read"] = _read_summary(trace, "trade")
	out["hero_read"] = _read_summary(trace, "hero")
	out["refresh_all"] = {"returned": t2["done"], "elapsed_ms": int(t2["elapsed_usec"] / 1000)}
	if not _t2_guard_ok(t2, "refresh_all_stalled", out):
		return
	var r: Dictionary = t2["value"]
	out["refresh_all"]["status"] = r.get("status", "")
	var st := {
		"uncertain": r.get("status") == OnlineProgressClient.UNCERTAIN and mode.get_status_text() == Mode.UNCERTAIN_TEXT,
		"values_kept": _same_values(mode.get_snapshot(), base),
		"not_busy": not mode.is_busy(),
		"port_reached": stall.accepted >= 1,
		"observer_stopped": trace["observer_done"],
	}
	_check(st["port_reached"], "E1-T2: the read reached the stalled port (%d connection(s))" % stall.accepted)
	_check(st["uncertain"], "E1-T2: stalled read is uncertain, never 'confirmed'")
	_check(st["values_kept"], "E1-T2: last server-confirmed values kept")
	_check(st["not_busy"], "E1-T2: not busy after the stalled read returned")
	_check(st["observer_stopped"], "E1-T2: request observer stopped after the final sweep")
	var observed: bool = out["trade_read"]["observed"] == "COMPLETE" and out["hero_read"]["observed"] == "COMPLETE"
	var product_ok := true
	for read_key in ["trade_read", "hero_read"]:
		var read: Dictionary = out[read_key]
		if read["observed"] != "COMPLETE":
			product_ok = false
			_check(false, "E1-T2: %s NOT OBSERVED (%s); no 10 s claim" % [read_key, read["observed"]])
		else:
			var ok_read: bool = read["elapsed_ms"] <= E1_PRODUCT_READ_MS
			product_ok = product_ok and ok_read
			_check(ok_read, "E1-T2: %s within the 10 s product limit (%d ms)" % [read_key, read["elapsed_ms"]])
	var ok_total: bool = out["refresh_all"]["elapsed_ms"] <= E1_PRODUCT_REFRESH_MS
	product_ok = product_ok and ok_total
	_check(ok_total, "E1-T2: refresh_all within the 30 s product limit (%d ms)" % out["refresh_all"]["elapsed_ms"])

	# Reconnect to the real server (bounded) and read both contracts again.
	mode.client.configure(_host, _port)
	var again := await _bounded(mode.refresh_all, E1_READ_GUARD_MS)
	if not _t2_guard_ok(again, "refresh_all_reconnect", out):
		out["state_checks"] = st
		return
	st["reconnect_ok"] = again["value"].get("status") == OnlineProgressClient.OK and _same_values(mode.get_snapshot(), base)
	st["not_busy_after_reconnect"] = not mode.is_busy()
	out["reconnect"] = "OK_SAME_VALUES" if st["reconnect_ok"] else "FAIL"
	_check(st["reconnect_ok"], "E1-T2: after reconnect both contracts read again with the same values")
	_check(st["not_busy_after_reconnect"], "E1-T2: not busy after reconnect")
	out["state_checks"] = st
	_t2_snap = mode.get_snapshot()

	# One classification from ALL results above (state, busy, reconnect,
	# observation, product limits). State/safety problems win over timing.
	var state_ok: bool = st["uncertain"] and st["values_kept"] and st["not_busy"] and st["reconnect_ok"] and st["not_busy_after_reconnect"]
	if not state_ok:
		out["classification"] = "FUNCTIONAL_FAIL_SUSPECT_EVIDENCE"
	elif not observed or not st["port_reached"] or not st["observer_stopped"]:
		out["classification"] = "DIAGNOSTIC_INCONCLUSIVE"
	elif not product_ok:
		out["classification"] = "PRODUCT_DEADLINE_FAIL"
	else:
		out["classification"] = "WITHIN_PRODUCT_LIMITS"
	if out["classification"] == "WITHIN_PRODUCT_LIMITS":
		out["product_acceptance"] = "PASS_OBSERVED"
	elif out["classification"] == "PRODUCT_DEADLINE_FAIL":
		out["product_acceptance"] = "FAIL"
	else:
		out["product_acceptance"] = "NOT OBSERVED"
	mode.sign_out()
	mode.queue_free()
	await process_frame


## Runs `fn` (a coroutine) while counting frames against `guard_ms`. Never
## cancels the request: if the guard expires the coroutine is left pending
## and the caller ends the process.
func _bounded(fn: Callable, guard_ms: int) -> Dictionary:
	var box := {"done": false, "value": {}}
	_run_into(fn, box)
	var start := Time.get_ticks_usec()
	while not box["done"]:
		if Time.get_ticks_usec() - start > guard_ms * 1000:
			return {"done": false, "value": {}, "elapsed_usec": Time.get_ticks_usec() - start}
		await process_frame
	return {"done": true, "value": box["value"], "elapsed_usec": Time.get_ticks_usec() - start}


func _run_into(fn: Callable, box: Dictionary) -> void:
	var value = await fn.call()
	box["value"] = value if typeof(value) == TYPE_DICTIONARY else {}
	box["done"] = true


## On an expired guard: report DIAGNOSTIC_GUARD_FAIL and stop this phase.
func _t2_guard_ok(r: Dictionary, stage: String, out: Dictionary) -> bool:
	if r["done"]:
		return true
	out["classification"] = "DIAGNOSTIC_GUARD_FAIL"
	out["guard_stage"] = stage
	out["product_acceptance"] = "NOT OBSERVED"
	_check(false, "E1-T2: guard expired at %s after %d ms; process ends without reconnect" % [stage, int(r["elapsed_usec"] / 1000)])
	return false


## A setup step (credentials, sign-in, session, stall port) failed: stop the
## diagnostic at once; nothing about T2 is claimed.
func _t2_setup_fail(out: Dictionary, stage: String) -> void:
	out["classification"] = "DIAGNOSTIC_INCONCLUSIVE"
	out["setup_failure"] = stage
	out["product_acceptance"] = "NOT OBSERVED"
	_check(false, "E1-T2: setup failed at %s; diagnostic stopped before the stall" % stage)


func _new_trace() -> Dictionary:
	var re := RegEx.new()
	re.compile("/v2/rpc/([a-z0-9_]+)")
	return {"requests": {}, "max_frame_gap_usec": 0, "frames": 0, "stop": false, "observer_done": false, "re": re}


## Test-only probe of the SDK adapter's private request table (read only),
## sampled once per frame until trace.stop. The caller takes a final sample
## itself before setting stop, so the loop's exit can never drop an end time.
func _observe(adapter, trace: Dictionary) -> void:
	var last := Time.get_ticks_usec()
	while not trace["stop"]:
		var now := Time.get_ticks_usec()
		trace["frames"] += 1
		trace["max_frame_gap_usec"] = maxi(int(trace["max_frame_gap_usec"]), now - last)
		last = now
		_observe_sample(adapter, trace, now)
		await process_frame
	trace["observer_done"] = true


## Keeps only: request id, read RPC name, first/last time seen, attempt.
## The request object itself (token, headers, URI, body) is never stored.
func _observe_sample(adapter, trace: Dictionary, now: int) -> void:
	var re: RegEx = trace["re"]
	var pending: Dictionary = adapter.get("_pending")
	var seen: Dictionary = trace["requests"]
	for id in pending.keys():
		var req = pending[id]
		if not seen.has(id):
			var m := re.search(String(req.uri))
			var rpc := m.get_string(1) if m != null else ""
			seen[id] = {"contract": E1_READ_RPCS.get(rpc, "other"), "start_usec": now, "end_usec": -1, "max_try": 0}
		seen[id]["max_try"] = maxi(int(seen[id]["max_try"]), int(req.cur_try))
	for id in seen.keys():
		if seen[id]["end_usec"] < 0 and not pending.has(id):
			seen[id]["end_usec"] = now


func _read_summary(trace: Dictionary, contract: String) -> Dictionary:
	var found: Array = []
	for id in trace["requests"].keys():
		if trace["requests"][id]["contract"] == contract:
			found.append(trace["requests"][id])
	if found.is_empty():
		return {"observed": "NOT OBSERVED (no request sent)"}
	if found.size() > 1:
		return {"observed": "NOT OBSERVED (%d requests, ambiguous)" % found.size()}
	var r: Dictionary = found[0]
	if r["end_usec"] < 0:
		return {"observed": "NOT OBSERVED (request did not settle)", "attempts_seen": r["max_try"]}
	return {"observed": "COMPLETE", "elapsed_ms": int((r["end_usec"] - r["start_usec"]) / 1000), "attempts_seen": r["max_try"], "precision": "1 frame"}


static func _offsets_ms(usec: Array) -> Array:
	var outv: Array = []
	for t in usec:
		outv.append(int((int(t) - int(usec[0])) / 1000))
	return outv


## Emits the ONE T2 result after the save checks, so the classification
## agrees with every check of this process and with its exit code.
func _finish_t2(save_ok: bool) -> void:
	var out := _t2_out
	if out.is_empty():
		out = {"case_id": "E1-T2", "product_acceptance": "NOT OBSERVED"}
	if not save_ok:
		out["classification"] = "SAFETY_STOP"
		out["product_acceptance"] = "NOT OBSERVED"
	elif String(out.get("classification", "")).is_empty():
		out["classification"] = "DIAGNOSTIC_INCONCLUSIVE"
		out["product_acceptance"] = "NOT OBSERVED"
	if _failures > 0 and out["classification"] == "WITHIN_PRODUCT_LIMITS":
		out["classification"] = "DIAGNOSTIC_INCONCLUSIVE"
		out["product_acceptance"] = "NOT OBSERVED"
	out["save_checks_ok"] = save_ok
	out["checks"] = _checks
	out["failures"] = _failures
	out["exit_code"] = 1 if _failures > 0 else 0
	var r := _result("t2", _t2_snap)
	for key in out.keys():
		r[key] = out[key]
	_emit(r)


# --- Helpers ---------------------------------------------------------------------

func _read_args() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--phase":
				_phase = args[i + 1]
			"--label":
				_label = args[i + 1]
			"--host":
				_host = args[i + 1]
			"--port":
				_port = int(args[i + 1])
	if _label.is_empty():
		_label = _phase


func _account(prefix: String) -> Dictionary:
	var email := OS.get_environment(prefix + "_EMAIL")
	var password := OS.get_environment(prefix + "_PASSWORD")
	_check(not email.is_empty() and not password.is_empty(), "Account credentials provided through the environment (%s_*)" % prefix)
	if email.is_empty() or password.is_empty():
		return {}
	return {"email": email, "password": password}


func _new_mode() -> OnlineProgressResumeTestMode:
	var mode: OnlineProgressResumeTestMode = (load(SCENE) as PackedScene).instantiate()
	root.add_child(mode)
	await process_frame
	mode.client.configure(_host, _port)
	return mode


func _result(name: String, snap: Dictionary) -> Dictionary:
	var r := {"phase": name, "label": _label, "pid": OS.get_process_id(), "nonce": _nonce, "user_data_dir": OS.get_user_data_dir()}
	for key in ["user_id", "money", "goods", "trade_revision", "level", "exp", "exp_to_next", "hero_revision"]:
		if snap.has(key):
			r[key] = snap[key]
	return r


func _emit(data: Dictionary) -> void:
	print("WP01F_RESULT " + JSON.stringify(data))


## Money, goods, Level and EXP equal (revisions may move forward).
static func _same_values(a: Dictionary, b: Dictionary) -> bool:
	for key in ["money", "goods", "level", "exp"]:
		if not a.has(key) or not b.has(key) or a[key] != b[key]:
			return false
	return true


func _pump(port: FaultPort) -> void:
	while port.running:
		port.poll()
		await process_frame


func _start_refresh(mode: OnlineProgressResumeTestMode, out: Array) -> void:
	out.append(await mode.refresh_all())


func _win(battle: CombatBattle) -> void:
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)


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
