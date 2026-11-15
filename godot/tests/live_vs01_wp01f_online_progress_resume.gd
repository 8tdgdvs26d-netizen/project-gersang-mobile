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
##   t1 t2 t3 t4 dl  WP01-G targeted stress, ONE case per process, each on its
##             own new disposable account: t1 read dropped mid-request, t2
##             server timeout, t3 two devices / takeover, t4 a late answer
##             after sign-out, dl real server answers arriving after the
##             client deadline
##
##   godot --headless --path godot --script res://tests/live_vs01_wp01f_online_progress_resume.gd -- \
##     --phase <probe|seed|readback|t1|t2|t3|t4|dl> [--label <name>] [--host 127.0.0.1] [--port 17350]
##
## The account e-mail / password come from the environment
## (MYRIAL_WP01F_EMAIL / _PASSWORD; stress cases: MYRIAL_WP01F_CASE_EMAIL /
## _PASSWORD, a different account per case) and are never printed. Results
## are printed as one line:
##   WP01F_RESULT {"phase": ..., ...}
## Only the launcher compares results across processes; this script never
## reads a previous run's values from disk.

const SCENE := "res://scenes/online_progress_resume_test_mode.tscn"
const Mode := preload("res://scripts/online_progress_resume_test_mode.gd")
const REP := OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID
## The server confirms a claim only 10 s after the encounter began.
const MIN_AGE_S := 10.5
const FAULT_TIMEOUT_SEC := 2
const PRODUCT_READ_DEADLINE_MS := 10_000
const PRODUCT_REFRESH_DEADLINE_MS := 30_000
const LIVE_WAIT_GUARD_MS := 45_000
## B3 layer 2: login / begin / reclaim / reconnect guards.
const LOGIN_GUARD_MS := 30_000
## DL: the proxy holds each real answer this long after the client connected,
## past the 7 s request timeout and the 8 s owner deadline.
const DL_HOLD_MS := 12_000

var _checks := 0
var _failures := 0
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


## DL only: forwards each client connection to the real local server at once,
## receives the real answer, and passes it on only `hold_ms` after the client
## connected. Records whether the server answered (HTTP 200) and whether the
## client had already given up when the answer was passed on. Owned by this
## process only; loopback only; nothing is logged from the bodies.
class DelayProxy extends RefCounted:
	var server := TCPServer.new()
	var upstream_host := "127.0.0.1"
	var upstream_port := 0
	var hold_ms := 0
	var links: Array = []
	var accepted := 0
	var running := false

	func start(p_host: String, p_port: int, p_hold_ms: int) -> int:
		upstream_host = p_host
		upstream_port = p_port
		hold_ms = p_hold_ms
		if server.listen(0, "127.0.0.1") != 0:
			return -1
		running = true
		return server.get_local_port()

	func poll() -> void:
		var now := Time.get_ticks_msec()
		while server.is_connection_available():
			accepted += 1
			var upstream := StreamPeerTCP.new()
			upstream.connect_to_host(upstream_host, upstream_port)
			links.append({"client": server.take_connection(), "upstream": upstream, "accepted_ms": now,
				"to_upstream": PackedByteArray(), "response": PackedByteArray(), "forwarded": false, "client_open_at_forward": false})
		for link in links:
			var client: StreamPeerTCP = link["client"]
			var upstream: StreamPeerTCP = link["upstream"]
			client.poll()
			upstream.poll()
			if not link["forwarded"] and client.get_status() == StreamPeerTCP.STATUS_CONNECTED and client.get_available_bytes() > 0:
				var got := client.get_data(client.get_available_bytes())
				if got[0] == OK:
					var outgoing: PackedByteArray = link["to_upstream"]
					outgoing.append_array(got[1])
					link["to_upstream"] = outgoing
			if upstream.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				var pending: PackedByteArray = link["to_upstream"]
				if not pending.is_empty() and upstream.put_data(pending) == OK:
					link["to_upstream"] = PackedByteArray()
				if upstream.get_available_bytes() > 0:
					var back := upstream.get_data(upstream.get_available_bytes())
					if back[0] == OK:
						var response: PackedByteArray = link["response"]
						response.append_array(back[1])
						link["response"] = response
			if not link["forwarded"] and _response_complete(link["response"]) and now - int(link["accepted_ms"]) >= hold_ms:
				link["forwarded"] = true
				link["client_open_at_forward"] = client.get_status() == StreamPeerTCP.STATUS_CONNECTED
				if link["client_open_at_forward"]:
					client.put_data(link["response"])

	func forwarded_count() -> int:
		return links.filter(func(l: Dictionary) -> bool: return l["forwarded"]).size()

	func forwarded_to_closed_count() -> int:
		return links.filter(func(l: Dictionary) -> bool: return l["forwarded"] and not l["client_open_at_forward"]).size()

	func upstream_ok_count() -> int:
		return links.filter(func(l: Dictionary) -> bool: return (l["response"] as PackedByteArray).get_string_from_ascii().begins_with("HTTP/1.1 200")).size()

	func stop() -> void:
		for link in links:
			(link["client"] as StreamPeerTCP).disconnect_from_host()
			(link["upstream"] as StreamPeerTCP).disconnect_from_host()
		links.clear()
		server.stop()
		running = false

	static func _response_complete(bytes: PackedByteArray) -> bool:
		var text := bytes.get_string_from_ascii()
		var header_end := text.find("\r\n\r\n")
		if header_end < 0:
			return false
		var headers := text.substr(0, header_end).to_lower()
		if headers.contains("transfer-encoding: chunked"):
			return text.ends_with("0\r\n\r\n")
		for line in headers.split("\r\n"):
			if String(line).begins_with("content-length:"):
				return bytes.size() >= header_end + 4 + int(String(line).split(":", true, 1)[1].strip_edges())
		return false


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
		"t1":
			await _phase_t1()
		"t2":
			await _phase_t2()
		"t3":
			await _phase_t3()
		"t4":
			await _phase_t4()
		"dl":
			await _phase_dl()
		_:
			_check(false, "Known phase (got '%s')" % _phase)
	_check(_dev_save_fingerprint() == dev_before, "No local save file was created or changed")
	_check(not FileAccess.file_exists(SaveStore.DEFAULT_PATH), "No local save file exists in the isolated user data folder")
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


## WP01-G B2 stress cases. Each case runs as its OWN Godot process (launched
## once per case by nakama/scripts/run_wp01f_bounded.mjs) with its OWN new
## disposable account (MYRIAL_WP01F_CASE_EMAIL / _PASSWORD), its own gameplay
## session and its own fault port, and prints exactly one WP01F_RESULT. Every
## wait is bounded (B7): an expired guard is a FAIL, the result is emitted
## with "guard_expired" and the case ends at once; nothing after it runs.

func _phase_t1() -> void:
	var ctx := await _case_start("t1")
	if ctx.is_empty():
		return
	var mode: OnlineProgressResumeTestMode = ctx["mode"]
	var counts: Dictionary = ctx["counts"]
	print("== T1 read dropped mid-request")
	var drop := FaultPort.new()
	var drop_port := drop.start("drop")
	_check(drop_port > 0, "T1 local drop port opened")
	_pump(drop)
	mode.client.timeout_sec = FAULT_TIMEOUT_SEC
	mode.client.configure(_host, drop_port)
	var dropped := await _guarded(mode.refresh_all, LIVE_WAIT_GUARD_MS, "T1 refresh_all over the drop port")
	counts["t1_connections"] = drop.accepted
	counts["t1_dropped"] = drop.dropped
	drop.stop()
	if not dropped["ok"]:
		_case_abort(ctx, "t1_refresh")
		return
	_check(drop.dropped >= 1, "T1 the read reached the port and was cut (%d accepted, %d cut)" % [drop.accepted, drop.dropped])
	_check(dropped["value"]["status"] == OnlineProgressClient.UNCERTAIN and mode.get_status_text() == Mode.UNCERTAIN_TEXT, "T1 dropped read: uncertain, never 'confirmed' (%s)" % mode.get_status_text())
	_check(_same_values(mode.get_snapshot(), ctx["base"]), "T1 dropped read: last server-confirmed values kept")
	mode.client.configure(_host, _port)
	var again := await _guarded(mode.refresh_all, LIVE_WAIT_GUARD_MS, "T1 refresh_all after reconnect")
	if not again["ok"]:
		_case_abort(ctx, "t1_reconnect")
		return
	_check(again["value"]["status"] == OnlineProgressClient.OK and _same_values(mode.get_snapshot(), ctx["base"]), "T1 after reconnect: same values from the server")
	await _case_finish(ctx)


func _phase_t2() -> void:
	var ctx := await _case_start("t2")
	if ctx.is_empty():
		return
	var mode: OnlineProgressResumeTestMode = ctx["mode"]
	var counts: Dictionary = ctx["counts"]
	print("== T2 server timeout")
	_check_production_read_config(mode, counts, "T2")
	var stall := FaultPort.new()
	var stall_port := stall.start("stall")
	_check(stall_port > 0, "T2 local stall port opened")
	_pump(stall)
	mode.client.configure(_host, stall_port)
	var measured := await _measure_refresh(mode, "T2")
	counts["t2_connections"] = stall.accepted
	stall.stop()
	_record_measured(counts, "t2", measured)
	if not measured["ok"]:
		_case_abort(ctx, "t2_refresh")
		return
	_check_read_bounds(measured, "T2")
	_check(stall.accepted >= 1, "T2 the read reached the stalled port (%d connection(s), %d ms)" % [stall.accepted, measured["elapsed_ms"]])
	_check(stall.accepted <= 2, "T2 uses at most one attempt for each of the two read RPCs (%d connections)" % stall.accepted)
	_check(measured["result"]["status"] == OnlineProgressClient.UNCERTAIN and mode.get_status_text() == Mode.UNCERTAIN_TEXT, "T2 timeout: uncertain, never 'confirmed'")
	_check(_same_values(mode.get_snapshot(), ctx["base"]), "T2 timeout: last server-confirmed values kept")
	mode.client.configure(_host, _port)
	var again := await _guarded(mode.refresh_all, LIVE_WAIT_GUARD_MS, "T2 refresh_all after the timeout")
	if not again["ok"]:
		_case_abort(ctx, "t2_retry")
		return
	_check(again["value"]["status"] == OnlineProgressClient.OK, "T2 after the timeout: read confirmed again")
	await _case_finish(ctx)


func _phase_t3() -> void:
	var ctx := await _case_start("t3")
	if ctx.is_empty():
		return
	var mode: OnlineProgressResumeTestMode = ctx["mode"]
	var account: Dictionary = ctx["account"]
	var base: Dictionary = ctx["base"]
	print("== T3 same account on a second device (policy A takeover)")
	var other := OnlineProgressClient.new()
	root.add_child(other)
	other.configure(_host, _port)
	var other_in := await _guarded(other.sign_in_email_test.bind(account["email"], account["password"], false), LOGIN_GUARD_MS, "T3 second device sign-in")
	if not other_in["ok"]:
		_case_abort(ctx, "t3_other_sign_in")
		return
	_check(other_in["value"]["status"] == OnlineProgressClient.OK, "T3 second device signed in to the same account")
	var taken_box := await _guarded(other.begin_gameplay_session, LOGIN_GUARD_MS, "T3 second device takeover")
	if not taken_box["ok"]:
		_case_abort(ctx, "t3_takeover")
		return
	var taken: Dictionary = taken_box["value"]
	_check(taken["status"] == OnlineProgressClient.OK, "T3 second device takes over")
	var taken_view: Dictionary = taken.get("data", {}).get("progress", {})
	_check(int(taken_view.get("money", -1)) == base.get("money") and int(taken_view.get("backpack", {}).get(REP, 0)) == base.get("goods"), "T3 second device reads the same server money / goods")
	var before_takeover := mode.get_snapshot()
	var refused := await _guarded(mode.refresh_all, LIVE_WAIT_GUARD_MS, "T3 first device refresh_all while taken over")
	if not refused["ok"]:
		_case_abort(ctx, "t3_refused_read")
		return
	_check(mode.get_status_text() == Mode.SUPERSEDED_TEXT and mode.get_panel_button("Reclaim").visible, "T3 first device is told it was taken over and offered reclaim")
	_check(refused["value"]["status"] == OnlineProgressClient.REJECTED and mode.get_snapshot() == before_takeover, "T3 first device shows nothing new while taken over")
	var reclaimed := await _guarded(mode.reclaim_session, LOGIN_GUARD_MS, "T3 first device reclaim")
	if not reclaimed["ok"]:
		_case_abort(ctx, "t3_reclaim")
		return
	_check(reclaimed["value"]["status"] == OnlineProgressClient.OK and mode.get_status_text() == Mode.CONFIRMED_TEXT, "T3 first device reclaims and reads both contracts again")
	var after := mode.get_snapshot()
	_check(_same_values(after, base) and int(after.get("trade_revision", -1)) > int(taken_view.get("revision", 0)), "T3 after reclaim: same values, newer Trade revision (%d > %d)" % [int(after.get("trade_revision", -1)), int(taken_view.get("revision", 0))])
	var other_read := await _guarded(other.refresh_progress, LIVE_WAIT_GUARD_MS, "T3 second device read after reclaim")
	if not other_read["ok"]:
		_case_abort(ctx, "t3_other_read")
		return
	_check(other_read["value"].get("reason", "") == OnlineProgressClient.SUPERSEDED_REASON, "T3 the second device is now the superseded one")
	other.queue_free()
	await process_frame
	await _case_finish(ctx)


func _phase_t4() -> void:
	var ctx := await _case_start("t4")
	if ctx.is_empty():
		return
	var mode: OnlineProgressResumeTestMode = ctx["mode"]
	var counts: Dictionary = ctx["counts"]
	var account: Dictionary = ctx["account"]
	print("== T4 a late answer after sign-out")
	var out := []
	_start_refresh(mode, out)
	# Checked in the same frame: the HTTP request cannot have been answered yet.
	var in_flight := mode.is_busy()
	mode.sign_out()
	var t4_wait_ok := await _wait_for_result(out, LIVE_WAIT_GUARD_MS)
	counts["t4_was_in_flight"] = in_flight
	_check(t4_wait_ok, "T4 late response settles inside the 45 s live-test guard")
	if not t4_wait_ok:
		_case_abort(ctx, "t4_late_response")
		return
	await process_frame
	_check(in_flight and out[0].get("stale", false), "T4 the read was in flight and its answer came back as stale")
	_check(not mode.get_snapshot().has("money") and not mode.get_snapshot().has("level") and mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT, "T4 the late answer did not reach the signed-out screen")
	var again := await _guarded(mode.sign_in.bind(account["email"], account["password"], false), LOGIN_GUARD_MS, "T4 sign-in again")
	if not again["ok"]:
		_case_abort(ctx, "t4_sign_in_again")
		return
	var begun := await _guarded(mode.begin_session, LOGIN_GUARD_MS, "T4 begin again")
	if not begun["ok"]:
		_case_abort(ctx, "t4_begin_again")
		return
	_check(again["value"]["status"] == OnlineProgressClient.OK and begun["value"]["status"] == OnlineProgressClient.OK, "T4 signed in again")
	_check(_same_values(mode.get_snapshot(), ctx["base"]), "T4 after signing in again: same values from the server")
	await _case_finish(ctx)


## Deadline-late-response (B2 / G-AC-02, live): a local proxy forwards both
## reads to the real server, receives the real answers and holds them past
## the client limits (7 s request timeout, 8 s owner deadline) before passing
## them on. The read must end UNCERTAIN within the B3 bounds, and the late real
## answers must change nothing: screen, both caches, session, superseded state,
## pending writes and busy. An immediate retry must then read normally. The
## in-process late boundary itself is proven by verify_vs01_wp01g_read_deadline.
func _phase_dl() -> void:
	var ctx := await _case_start("dl")
	if ctx.is_empty():
		return
	var mode: OnlineProgressResumeTestMode = ctx["mode"]
	var counts: Dictionary = ctx["counts"]
	print("== DL deadline-late-response through a delaying proxy")
	_check_production_read_config(mode, counts, "DL")
	var session_before := mode.client.get_gameplay_session_id()
	var pending_before := mode.client.get_pending_commands()
	var trade_text := mode.get_trade_text()
	var hero_text := mode.get_hero_text()
	var proxy := DelayProxy.new()
	var proxy_port := proxy.start(_host, _port, DL_HOLD_MS)
	_check(proxy_port > 0, "DL local delaying proxy opened")
	_pump_proxy(proxy)
	mode.client.configure(_host, proxy_port)
	var measured := await _measure_refresh(mode, "DL")
	_record_measured(counts, "dl", measured)
	if not measured["ok"]:
		proxy.stop()
		_case_abort(ctx, "dl_refresh")
		return
	_check_read_bounds(measured, "DL")
	_check(measured["result"]["status"] == OnlineProgressClient.UNCERTAIN and mode.get_status_text() == Mode.UNCERTAIN_TEXT, "DL read ended UNCERTAIN, never 'confirmed'")
	var forwarded_ok := await _wait_for_condition(func() -> bool: return proxy.forwarded_count() >= 2, DL_HOLD_MS + LIVE_WAIT_GUARD_MS)
	for _frame in range(10):
		await process_frame
	counts["dl_proxy_accepted"] = proxy.accepted
	counts["dl_upstream_ok"] = proxy.upstream_ok_count()
	counts["dl_forwarded"] = proxy.forwarded_count()
	counts["dl_forwarded_after_client_closed"] = proxy.forwarded_to_closed_count()
	counts["dl_late_dropped_total"] = mode.client._read_transport.late_dropped_total
	proxy.stop()
	_check(forwarded_ok, "DL both held answers were passed on inside the guard (%d)" % counts["dl_forwarded"])
	if not forwarded_ok:
		_case_abort(ctx, "dl_forward")
		return
	_check(counts["dl_proxy_accepted"] == 2 and counts["dl_upstream_ok"] == 2, "DL the real server answered both reads (HTTP 200 x %d of %d)" % [counts["dl_upstream_ok"], counts["dl_proxy_accepted"]])
	_check(counts["dl_forwarded_after_client_closed"] == 2, "DL both real answers were passed on only after the client had given up (%d)" % counts["dl_forwarded_after_client_closed"])
	_check(_same_values(mode.get_snapshot(), ctx["base"]) and mode.get_trade_text() == trade_text and mode.get_hero_text() == hero_text, "DL late real answers changed neither screen nor caches")
	_check(mode.client.get_gameplay_session_id() == session_before and not mode.client.is_gameplay_session_superseded(), "DL late real answers changed neither session nor superseded state")
	_check(mode.client.get_pending_commands() == pending_before, "DL pending writes untouched")
	_check(not mode.is_busy() and mode.client._read_transport.active_request_count() == 0, "DL busy and read ownership released")
	mode.client.configure(_host, _port)
	var again := await _guarded(mode.refresh_all, LIVE_WAIT_GUARD_MS, "DL immediate retry")
	if not again["ok"]:
		_case_abort(ctx, "dl_retry")
		return
	_check(again["value"]["status"] == OnlineProgressClient.OK and _same_values(mode.get_snapshot(), ctx["base"]) and mode.get_status_text() == Mode.CONFIRMED_TEXT, "DL immediate retry reads both contracts normally")
	await _case_finish(ctx)


# --- Stress case helpers ---------------------------------------------------------

## New account, signed in and session begun under guards. {} when it failed
## (the FAIL and the result line are already written).
func _case_start(case_id: String) -> Dictionary:
	var counts := {"case": case_id}
	var account := _account("MYRIAL_WP01F_CASE")
	if account.is_empty():
		_emit_case(case_id, {}, counts)
		return {}
	var mode := await _new_mode()
	var ctx := {"case": case_id, "mode": mode, "account": account, "counts": counts, "base": {}}
	var signed := await _guarded(mode.sign_in.bind(account["email"], account["password"], true), LOGIN_GUARD_MS, "%s sign-in" % case_id)
	if not signed["ok"]:
		_case_abort(ctx, "sign_in")
		return {}
	_check(signed["value"]["status"] == OnlineProgressClient.OK, "%s: a new disposable local test account signed in" % case_id)
	if signed["value"]["status"] != OnlineProgressClient.OK:
		_case_abort(ctx, "sign_in_failed", false)
		return {}
	var begun := await _guarded(mode.begin_session, LOGIN_GUARD_MS, "%s begin session" % case_id)
	if not begun["ok"]:
		_case_abort(ctx, "begin_session")
		return {}
	_check(begun["value"]["status"] == OnlineProgressClient.OK, "%s: session begun" % case_id)
	if begun["value"]["status"] != OnlineProgressClient.OK:
		_case_abort(ctx, "begin_session_failed", false)
		return {}
	ctx["base"] = mode.get_snapshot()
	counts["gameplay_session_id_set"] = not mode.client.get_gameplay_session_id().is_empty()
	return ctx


func _case_finish(ctx: Dictionary) -> void:
	_emit_case(ctx["case"], (ctx["mode"] as OnlineProgressResumeTestMode).get_snapshot(), ctx["counts"])
	(ctx["mode"] as OnlineProgressResumeTestMode).sign_out()
	(ctx["mode"] as OnlineProgressResumeTestMode).queue_free()
	await process_frame


## Ends a case after an expired guard or a failed setup: the FAIL is already
## recorded; the result says where it stopped and nothing else runs.
func _case_abort(ctx: Dictionary, stage: String, guard_expired: bool = true) -> void:
	var counts: Dictionary = ctx["counts"]
	counts["guard_expired"] = guard_expired
	counts["stopped_at"] = stage
	var mode: OnlineProgressResumeTestMode = ctx["mode"]
	_emit_case(ctx["case"], mode.get_snapshot() if is_instance_valid(mode) else {}, counts)


func _emit_case(case_id: String, snap: Dictionary, counts: Dictionary) -> void:
	var r := _result(case_id, snap)
	r["cases"] = counts
	_emit(r)


## Runs `c` (a coroutine) under a guard. {"ok": false} after a FAIL.
func _guarded(c: Callable, guard_ms: int, label: String) -> Dictionary:
	var box := []
	_call_into(c, box)
	var ok := await _wait_for_result(box, guard_ms)
	_check(ok, "%s settles inside the %d ms live-test guard" % [label, guard_ms])
	return {"ok": ok, "value": box[0] if ok else {}}


func _call_into(c: Callable, out: Array) -> void:
	out.append(await c.call())


func _wait_for_condition(condition: Callable, guard_ms: int) -> bool:
	var started := Time.get_ticks_msec()
	while not condition.call():
		if Time.get_ticks_msec() - started > guard_ms:
			return false
		await process_frame
	return true


func _check_production_read_config(mode: OnlineProgressResumeTestMode, counts: Dictionary, label: String) -> void:
	var transport: OnlineReadTransport = mode.client._read_transport
	counts["read_request_timeout_sec"] = transport.request_timeout_sec
	counts["read_owner_deadline_sec"] = transport.owner_deadline_sec
	_check(transport.request_timeout_sec == OnlineReadTransport.DEFAULT_REQUEST_TIMEOUT_SEC and transport.owner_deadline_sec == OnlineReadTransport.DEFAULT_OWNER_DEADLINE_SEC, "%s runs with the production read limits (%d s request, %.1f s owner deadline)" % [label, transport.request_timeout_sec, transport.owner_deadline_sec])


## B3: Trade read, Hero read and refresh_all() measured separately, from the
## transport's read_started to read_finished per RPC id; clock in this test only.
func _measure_refresh(mode: OnlineProgressResumeTestMode, label: String) -> Dictionary:
	var transport: OnlineReadTransport = mode.client._read_transport
	var reads := {}
	var on_read_started := func(request_id: int, rpc_id: String) -> void:
		reads[request_id] = {"rpc": rpc_id, "start": Time.get_ticks_msec(), "end": -1, "decision": "", "status": ""}
	var on_read_finished := func(request_id: int, _rpc_id: String, decision: String, status: String) -> void:
		if reads.has(request_id):
			reads[request_id]["end"] = Time.get_ticks_msec()
			reads[request_id]["decision"] = decision
			reads[request_id]["status"] = status
	transport.read_started.connect(on_read_started)
	transport.read_finished.connect(on_read_finished)
	var out := []
	var t0 := Time.get_ticks_msec()
	_start_refresh(mode, out)
	var ok := await _wait_for_result(out, LIVE_WAIT_GUARD_MS)
	var elapsed := Time.get_ticks_msec() - t0
	transport.read_started.disconnect(on_read_started)
	transport.read_finished.disconnect(on_read_finished)
	_check(ok, "%s refresh_all settles inside the 45 s live-test guard (%d ms)" % [label, elapsed])
	return {"ok": ok, "elapsed_ms": elapsed, "reads": reads, "result": out[0] if ok else {},
		"trade": _single_read(reads, OnlineProgressClient.RPC_PROGRESS_GET), "hero": _single_read(reads, OnlineCombatAdapter.RPC_PROGRESSION)}


func _record_measured(counts: Dictionary, prefix: String, m: Dictionary) -> void:
	counts[prefix + "_elapsed_ms"] = m["elapsed_ms"]
	counts[prefix + "_read_count"] = (m["reads"] as Dictionary).size()
	counts[prefix + "_trade_ms"] = _read_ms(m["trade"])
	counts[prefix + "_hero_ms"] = _read_ms(m["hero"])
	counts[prefix + "_trade_decision"] = m["trade"].get("decision", "")
	counts[prefix + "_hero_decision"] = m["hero"].get("decision", "")
	if not m["ok"]:
		counts[prefix + "_guard_expired"] = true


func _check_read_bounds(m: Dictionary, label: String) -> void:
	var trade: Dictionary = m["trade"]
	var hero: Dictionary = m["hero"]
	_check((m["reads"] as Dictionary).size() == 2 and not trade.is_empty() and not hero.is_empty(), "%s exactly one Trade read and one Hero read were measured (%d reads)" % [label, (m["reads"] as Dictionary).size()])
	_check(_read_ms(trade) >= 0 and _read_ms(trade) <= PRODUCT_READ_DEADLINE_MS, "%s Trade read returns within the 10 s product deadline (%d ms, %s)" % [label, _read_ms(trade), trade.get("decision", "")])
	_check(_read_ms(hero) >= 0 and _read_ms(hero) <= PRODUCT_READ_DEADLINE_MS, "%s Hero read returns within the 10 s product deadline (%d ms, %s)" % [label, _read_ms(hero), hero.get("decision", "")])
	_check(int(m["elapsed_ms"]) <= PRODUCT_REFRESH_DEADLINE_MS, "%s refresh_all returns within the 30 s product deadline (%d ms)" % [label, m["elapsed_ms"]])
	_check(trade.get("status") == OnlineProgressClient.UNCERTAIN and hero.get("status") == OnlineProgressClient.UNCERTAIN, "%s both reads ended UNCERTAIN (Trade %s, Hero %s)" % [label, trade.get("status", ""), hero.get("status", "")])


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
	_check(mode.client._read_transport.request_timeout_sec * 1000 < PRODUCT_READ_DEADLINE_MS and mode.client._read_transport.owner_deadline_sec * 1000 < PRODUCT_READ_DEADLINE_MS, "A4-Lite per-read transport limits are below 10 s")
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


func _pump_proxy(proxy: DelayProxy) -> void:
	while proxy.running:
		proxy.poll()
		await process_frame


func _pump(port: FaultPort) -> void:
	while port.running:
		port.poll()
		await process_frame


func _start_refresh(mode: OnlineProgressResumeTestMode, out: Array) -> void:
	out.append(await mode.refresh_all())


func _wait_for_result(out: Array, guard_ms: int) -> bool:
	var started := Time.get_ticks_msec()
	while out.is_empty() and Time.get_ticks_msec() - started <= guard_ms:
		await process_frame
	return not out.is_empty()


## The one measured read of `rpc_id`, or {} when there is none or several.
static func _single_read(reads: Dictionary, rpc_id: String) -> Dictionary:
	var found := []
	for entry in reads.values():
		if entry["rpc"] == rpc_id:
			found.append(entry)
	return found[0] if found.size() == 1 else {}


## Elapsed ms of a measured read, or -1 when it did not finish.
static func _read_ms(entry: Dictionary) -> int:
	if entry.is_empty() or int(entry["end"]) < 0:
		return -1
	return int(entry["end"]) - int(entry["start"])


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
