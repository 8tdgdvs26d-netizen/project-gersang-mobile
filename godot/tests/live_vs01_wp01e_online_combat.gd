extends SceneTree

## VS-01 WP01-E E2 — LIVE run of the Online Combat TEST mode against the LOCAL
## Nakama server (E1 RPCs): real scene, real CombatBattle (driven to its end
## by the test), server-confirmed EXP / Level, re-login read-back, a lost
## claim reply (lossy proxy), session takeover + reclaim, app kill + explicit
## abandon. Not a verify_* script: run by nakama/scripts/run_live_tests.sh.
##
##   godot --headless --path godot --script res://tests/live_vs01_wp01e_online_combat.gd -- <host> <api-port> <proxy-port>

const SCENE := "res://scenes/online_combat_test_mode.tscn"
const MIN_AGE_S := 10.5

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
	print("Isolated user:// for this run: %s" % OS.get_user_data_dir())
	await _run()
	_check(_dev_save_fingerprint() == dev_before, "Development Save is untouched")
	_check(not FileAccess.file_exists(SaveStore.DEFAULT_PATH), "No local save file was created")
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-E live online combat passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _new_mode() -> OnlineCombatTestMode:
	var mode: OnlineCombatTestMode = (load(SCENE) as PackedScene).instantiate()
	mode.auto_retry = false
	root.add_child(mode)
	await process_frame
	mode.client.configure(_host, _api_port)
	return mode


func _run() -> void:
	var email := "e2-live-%s@myrial.test" % OnlineProgressClient.new_idempotency_key().substr(0, 12)
	var password := "localtest-%s" % OnlineProgressClient.new_idempotency_key().substr(0, 10)
	var mode := await _new_mode()
	_check((await mode.sign_in(email, password))["status"] == OnlineProgressClient.OK, "Signed in with a disposable local account")
	await mode.begin_session()
	_check(mode.get_progression_text() == "主角 Lv 1　經驗 0 / 100（伺服器確認）", "New account: server Lv 1 / 0 (%s)" % mode.get_progression_text())

	# 1. A fast legitimate win: too_early, kept, then confirmed once.
	await mode.start_battle(0)
	var battle := mode.get_battle()
	_check(battle != null and battle.get_enemies().size() == 10 and battle.get_friends().size() == 1, "Hero-only battle with the server's 10 enemies")
	_win(battle)
	mode.combat_view.exit_requested.emit()
	await _until_idle(mode)
	_check(mode.get_status_text() == OnlineCombatTestMode.TOO_EARLY_TEXT and mode.adapter.has_pending(), "Fast win: too_early, result kept (%s)" % mode.get_status_text())
	_check(mode.get_progression_text().contains("Lv 1　經驗 0"), "No EXP shown before the server confirms")
	var key: String = mode.adapter.get_pending()["key"]
	await create_timer(MIN_AGE_S).timeout
	var r := await mode.resend()
	_check(r.get("handling") == OnlineCombatAdapter.CONFIRMED and not r["replayed"], "After 10 s the same key is confirmed")
	_check(mode.get_progression_text() == "主角 Lv 2　經驗 0 / 150（伺服器確認）", "Server-confirmed Lv 2 shown (%s)" % mode.get_progression_text())

	# 2. The same key again is a replay: no second EXP.
	mode.adapter._set_pending({"kind": "claim", "key": key, "ticket_id": r["receipt"]["ticket_id"],
		"payload": {"ticket_id": r["receipt"]["ticket_id"], "outcome": "victory", "kills": 10, "hero_alive": true}})
	var replay := await mode.resend()
	_check(replay.get("handling") == OnlineCombatAdapter.CONFIRMED and replay["replayed"], "Same key -> replayed receipt")
	_check(int(mode.adapter.get_confirmed_progression()["revision"]) == 1, "Replay added no EXP (revision 1)")

	# 3. Sign out and back in: the confirmed progression is read back from the server.
	mode.sign_out()
	_check(mode.get_progression_text() == OnlineCombatTestMode.PROGRESSION_UNKNOWN_TEXT, "Signed out: nothing shown")
	await mode.sign_in(email, password)
	await mode.begin_session()
	_check(mode.get_progression_text() == "主角 Lv 2　經驗 0 / 150（伺服器確認）", "Re-login reads back Lv 2 from the server")

	# 4. The claim reply is lost after the server committed (lossy proxy): kept,
	#    the retry through the direct port returns the original receipt.
	await mode.start_battle(0)
	_check(mode.get_battle() == null and mode.get_status_text() == OnlineCombatTestMode.FINAL_TEXTS["cooldown_active"], "Same group within 10 s of a positive award: cooldown_active")
	await mode.start_battle(1)
	battle = mode.get_battle()
	_check(battle != null and battle.get_enemies().size() == 15, "Two groups: 15 enemies")
	_retreat_with_kills(battle, 4)
	await create_timer(MIN_AGE_S).timeout
	mode.client.configure(_host, _proxy_port)
	mode.combat_view.exit_requested.emit()
	await _until_idle(mode)
	_check(mode.get_status_text() == OnlineCombatTestMode.UNCERTAIN_TEXT and mode.adapter.has_pending(), "Lost reply: uncertain, kept, no EXP shown")
	_check(mode.get_progression_text().contains("Lv 2　經驗 0"), "Lost reply: the screen keeps the last confirmed values")
	mode.client.configure(_host, _api_port)
	var after_loss := await mode.resend()
	_check(after_loss.get("handling") == OnlineCombatAdapter.CONFIRMED and after_loss["replayed"], "Retry returns the ORIGINAL receipt (the server had committed)")
	_check(int(after_loss["receipt"]["exp_awarded"]) == 40 and mode.get_progression_text() == "主角 Lv 2　經驗 40 / 150（伺服器確認）", "RETREAT with 4 kills: +40 once (%s)" % mode.get_progression_text())
	await mode.refresh()
	_check(mode.get_progression_text() == "主角 Lv 2　經驗 40 / 150（伺服器確認）", "A fresh server read confirms one award, not two")

	# 5. Another device takes over mid-claim; the original device reclaims and resends.
	await mode.start_battle(2)
	_check(mode.get_battle() == null, "Three groups include the cooled groups: refused")
	var other := OnlineProgressClient.new()
	other.configure(_host, _api_port)
	root.add_child(other)
	mode.client.configure(_host, _api_port)
	await create_timer(1.0).timeout
	await mode.refresh()
	# Wait for the cooldown (10 s) and fight one group.
	await create_timer(10.5).timeout
	await mode.start_battle(0)
	battle = mode.get_battle()
	_check(battle != null, "Battle after the cooldown")
	_win(battle)
	await create_timer(MIN_AGE_S).timeout
	_check((await other.sign_in_email_test(email, password, false))["status"] == OnlineProgressClient.OK and (await other.begin_gameplay_session())["status"] == OnlineProgressClient.OK, "A second device takes over")
	mode.combat_view.exit_requested.emit()
	await _until_idle(mode)
	_check(mode.get_status_text() == OnlineCombatTestMode.SUPERSEDED_TEXT and mode.get_panel_button("Reclaim").visible and mode.adapter.has_pending(), "Old device: superseded, result kept, reclaim offered")
	await mode.reclaim_session()
	await _until_idle(mode)
	_check(not mode.adapter.has_pending() and mode.get_status_text().begins_with("伺服器已確認"), "After reclaim the same result is confirmed once (%s)" % mode.get_status_text())
	_check(mode.get_progression_text() == "主角 Lv 2　經驗 140 / 150（伺服器確認）", "Lv 2, 40 + 100 = 140 (%s)" % mode.get_progression_text())
	other.queue_free()

	# 6. App kill with an unconfirmed result in RAM: a new process shows only the
	#    server progression and offers explicit abandon.
	await create_timer(10.5).timeout
	await mode.start_battle(0)
	_win(mode.get_battle())
	mode.combat_view.exit_requested.emit()
	await _until_idle(mode)
	_check(mode.get_status_text() == OnlineCombatTestMode.TOO_EARLY_TEXT, "Result sent too early (intent recorded on the server)")
	mode.queue_free()  # "app kill": RAM pending lost
	await process_frame
	var revived := await _new_mode()
	await revived.sign_in(email, password)
	await revived.begin_session()
	_check(revived.get_progression_text() == "主角 Lv 2　經驗 140 / 150（伺服器確認）", "After the kill: only the server-confirmed progression")
	_check(revived.get_status_text() == OnlineCombatTestMode.LOST_PENDING_TEXT and revived.get_panel_button("Abandon").visible, "Lost result: explicit abandon offered")
	await revived.abandon_unresolved()
	var abandoned := await revived.abandon_unresolved()
	# Abandon consumes the encounter_begin quota (approved MC-2 Q1: 6 per
	# rolling 60 s), which this run has used up: refused for now, KEPT, and
	# resent with the same key when the window rolls.
	if abandoned.get("reason", "") == "rate_limited":
		var kept := revived.adapter.get_pending()
		_check(abandoned.get("handling") == OnlineCombatAdapter.KEEP and kept.get("kind") == "abandon", "Throttled abandon: kept, not dropped")
		await create_timer(61.0).timeout
		abandoned = await revived.resend()
		_check(revived.adapter.get_pending().is_empty() and abandoned.get("handling") == OnlineCombatAdapter.CONFIRMED, "The kept abandon is confirmed after the window rolls")
	_check(abandoned.get("handling") == OnlineCombatAdapter.CONFIRMED and abandoned["receipt"]["kind"] == "abandon", "Explicit abandon confirmed by the server")
	_check(revived.get_progression_text() == "主角 Lv 2　經驗 140 / 150（伺服器確認）", "Abandon changes no confirmed progression")
	await revived.start_battle(1)
	_check(revived.get_battle() != null, "A new battle is possible after the abandon")
	revived.sign_out()
	revived.queue_free()
	await process_frame


func _win(battle: CombatBattle) -> void:
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)


## A RETREAT after exactly `kills` kills (the C04 rules: the Hero walks to the
## Retreat Zone while enemies are left).
func _retreat_with_kills(battle: CombatBattle, kills: int) -> void:
	battle.advance(CombatConfig.PREPARATION_MS)
	for i in kills:
		battle.resolve_damage(battle.get_hero(), battle.get_enemies()[i], 1000)
	battle.start_retreat()
	var guard := 0
	while not battle.is_over() and guard < 2000:
		battle.advance(50)
		guard += 1


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
