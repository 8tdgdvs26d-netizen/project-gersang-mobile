extends SceneTree

## VS-01 WP01-E E2 — LIVE risk-based stress of the Online Combat TEST client
## against the LOCAL Nakama server: several battles in a row, each claim reply
## lost three times after the server committed (lossy proxy) and a double-tapped
## submit; every result must be confirmed exactly once with the original
## receipt, and the server EXP must equal the sum of the confirmed receipts.
##
##   godot --headless --path godot --script res://tests/live_vs01_wp01e_combat_stress.gd -- <host> <api-port> <proxy-port>

const SCENE := "res://scenes/online_combat_test_mode.tscn"
const BATTLES := 4
const LOST_REPLIES := 3

var _checks := 0
var _failures := 0
var _host := "127.0.0.1"
var _api_port := 17350
var _proxy_port := 17370


func _initialize() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.size() == 3:
		_host = args[0]
		_api_port = int(args[1])
		_proxy_port = int(args[2])
	var dev_before := _dev_save_fingerprint()
	await _run()
	_check(_dev_save_fingerprint() == dev_before, "Development Save is untouched")
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-E live combat stress passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _run() -> void:
	var mode: OnlineCombatTestMode = (load(SCENE) as PackedScene).instantiate()
	mode.auto_retry = false
	root.add_child(mode)
	await process_frame
	mode.client.configure(_host, _api_port)
	var email := "e2-stress-%s@myrial.test" % OnlineProgressClient.new_idempotency_key().substr(0, 12)
	await mode.sign_in(email, "localtest-%s" % OnlineProgressClient.new_idempotency_key().substr(0, 10))
	await mode.begin_session()
	var awarded := 0
	var revision := 0
	for i in BATTLES:
		await mode.start_battle(i % 2)  # alternate groups: never inside a cooldown
		var battle := mode.get_battle()
		_check(battle != null, "Battle %d opened" % i)
		if battle == null:
			return
		var enemies := battle.get_enemies().size()
		battle.advance(CombatConfig.PREPARATION_MS)
		for enemy in battle.get_enemies():
			battle.resolve_damage(battle.get_hero(), enemy, 1000)
		await create_timer(10.5).timeout
		# Every reply of this claim is lost LOST_REPLIES times (server committed).
		mode.client.configure(_host, _proxy_port)
		var sent_before := int(_proxy_stats().get("claim_requests", 0))
		mode.combat_view.exit_requested.emit()
		mode.combat_view.exit_requested.emit()  # double tap
		await _until_idle(mode)
		# The Nakama Godot SDK itself retries a failed HTTP request, so one
		# client submission reaches the proxy several times: a double tap
		# must cost exactly what one single resend costs.
		var double_tap := int(_proxy_stats().get("claim_requests", 0)) - sent_before
		var key: String = mode.adapter.get_pending().get("key", "")
		for retry in LOST_REPLIES - 1:
			var before_resend := int(_proxy_stats().get("claim_requests", 0))
			await mode.resend()
			if retry == 0:
				var single := int(_proxy_stats().get("claim_requests", 0)) - before_resend
				_check(double_tap == single and single >= 1, "Battle %d: a double tap submits ONE claim (%d proxy requests, a single resend %d)" % [i, double_tap, single])
			_check(mode.adapter.get_pending().get("key", "") == key and mode.get_status_text() == OnlineCombatTestMode.UNCERTAIN_TEXT, "Battle %d retry %d: same key kept, uncertain shown" % [i, retry])
		_check(int(mode.adapter.get_confirmed_progression()["revision"]) == revision, "Battle %d: nothing shown as earned while uncertain" % i)
		mode.client.configure(_host, _api_port)
		var r := await mode.resend()
		# Every SDK retry is charged by the server (claim 12 / replay 30 per
		# 60 s): when throttled the client keeps the result and resends later,
		# as the scene's automatic retry does.
		var waits := 0
		while r.get("handling") == OnlineCombatAdapter.KEEP and waits < 8:
			await create_timer(10.0).timeout
			r = await mode.resend()
			waits += 1
		_check(r.get("handling") == OnlineCombatAdapter.CONFIRMED and r["replayed"], "Battle %d: the original receipt (committed on the first, lost reply)" % i)
		awarded += int(r["receipt"]["exp_awarded"])
		revision += 1
		_check(int(r["receipt"]["exp_awarded"]) == enemies * CombatConfig.EXP_PER_KILL, "Battle %d: server EXP = kills x %d" % [i, CombatConfig.EXP_PER_KILL])
		_check(int(mode.adapter.get_confirmed_progression()["revision"]) == revision, "Battle %d: exactly one award (revision %d)" % [i, revision])
	await mode.refresh()
	var p := mode.adapter.get_confirmed_progression()
	var expected := ProgressionState.advance(1, 0, awarded)
	_check(int(p["level"]) == expected[0] and int(p["exp"]) == expected[1], "Server Level / EXP equal the sum of confirmed receipts (%d EXP -> Lv %d / %d)" % [awarded, expected[0], expected[1]])
	mode.sign_out()
	mode.queue_free()
	await process_frame


func _proxy_stats() -> Dictionary:
	var out := []
	OS.execute("curl", ["-sf", "http://%s:%d/__lossy_proxy/stats" % [_host, _proxy_port]], out)
	var parsed: Variant = JSON.parse_string(out[0] if out.size() > 0 else "")
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _until_idle(mode: OnlineCombatTestMode) -> void:
	await process_frame
	while mode.is_busy():
		await process_frame
	await process_frame


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
