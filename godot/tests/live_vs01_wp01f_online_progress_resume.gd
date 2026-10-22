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
##
##   godot --headless --path godot --script res://tests/live_vs01_wp01f_online_progress_resume.gd -- \
##     --phase <probe|seed|readback|stress> [--label <name>] [--host 127.0.0.1] [--port 17350]
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
