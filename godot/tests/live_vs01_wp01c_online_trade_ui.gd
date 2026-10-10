extends SceneTree

## VS-01 WP01-C — LIVE UI run: the Online TEST mode scene (existing city market
## UI + OnlineTradeAdapter + OnlineProgressClient + Nakama Godot SDK) against
## the LOCAL Nakama server, pressing the market's own buttons. Not a verify_*
## script: run by nakama/scripts/run_live_tests.sh with the lossy proxy up.
##
##   godot --headless --path godot --script res://tests/live_vs01_wp01c_online_trade_ui.gd -- <host> <api-port> <proxy-port>

const REP := OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID
const SCENE := "res://scenes/online_trade_test_mode.tscn"

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
	_check(_dev_save_fingerprint() == dev_before, "H: Development Save is untouched")
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-C live online trade UI passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _run() -> void:
	var mode: OnlineTradeTestMode = (load(SCENE) as PackedScene).instantiate()
	root.add_child(mode)
	await process_frame
	mode.client.configure(_host, _api_port)
	var hub := mode.hub
	var email := "wp01c-ui-%d%04d@myrial.test" % [Time.get_unix_time_from_system(), randi() % 10000]
	var password := "localtest-%08x" % randi()

	_check((await mode.sign_in(email, password))["status"] == OnlineProgressClient.OK, "Signed in with a disposable local test account")
	_check((await mode.begin_session())["status"] == OnlineProgressClient.OK and hub.is_open(), "Gameplay session begun; market open")
	_check(hub.get_money_label_text() == "金錢：10000" and hub.get_market_row_texts(REP)["buy_price"] == "買入價 84" and hub.get_market_row_texts(REP)["stock"] == "庫存 100", "Server values shown (10000, buy 84): %s %s" % [hub.get_money_label_text(), str(hub.get_market_row_texts(REP))])

	# A: buy 10 at A through the market's own button.
	await _press(mode, "buy10")
	_check(hub.get_feedback_text() == "已買入 10 件測試商品一，支付 840", "A: buy confirmed by the server (%s)" % hub.get_feedback_text())
	_check(hub.get_money_label_text() == "金錢：9160" and hub.get_market_row_texts(REP)["held"] == "持有 10", "A: money / goods from the server (9160 / 10)")

	# B: sell 10 at B.
	mode.switch_city("B")
	await _press(mode, "sell10")
	_check(hub.get_feedback_text().begins_with("已賣出 10 件測試商品一，收入 1140"), "B: sell confirmed by the server (%s)" % hub.get_feedback_text())
	_check(hub.get_money_label_text() == "金錢：10300" and hub.get_market_row_texts(REP)["held"] == "持有 0", "B: money / goods from the server (10300 / 0)")

	# C: refresh = a fresh server read; the screen matches it.
	var read := await mode.refresh()
	var server: Dictionary = read.get("data", {}).get("progress", {})
	_check(read["status"] == OnlineProgressClient.OK and hub.get_money_label_text() == "金錢：%d" % int(server.get("money", -1)) and hub.get_market_row_texts(REP)["held"] == "持有 %d" % int(server.get("backpack", {}).get(REP, 0)), "C: after refresh the screen equals the server (%s)" % hub.get_money_label_text())

	# D: network loss after the server committed: no success shown, nothing changed.
	mode.switch_city("A")
	mode.client.configure(_host, _proxy_port)
	await _press(mode, "buy")
	_check(hub.get_feedback_text() == OnlineTradeTestMode.HUB_UNCERTAIN_TEXT and mode.get_status_text() == OnlineTradeTestMode.UNCERTAIN_TEXT, "D: lost answer shows 'not confirmed', not success (%s)" % hub.get_feedback_text())
	_check(hub.get_money_label_text() == "金錢：10300" and hub.get_market_row_texts(REP)["held"] == "持有 0", "D: screen keeps the last server-confirmed values")
	_check(mode.get_pending_text() == "未確定交易：1 單", "D: the order is pending")
	mode.client.configure(_host, _api_port)

	# E: retry = same idempotency key; the server applied it once.
	var recovered := await mode.retry_pending()
	_check(recovered.size() == 1 and recovered[0]["replayed"] and recovered[0]["success"], "E: retry returns the ORIGINAL server receipt (replayed)")
	_check(hub.get_market_row_texts(REP)["held"] == "持有 1" and mode.get_pending_text() == "未確定交易：0 單", "E: the lost order counted once (goods 1), nothing pending")
	var money_after_one := hub.get_money_label_text()
	_check((await mode.retry_pending()).is_empty() and hub.get_money_label_text() == money_after_one, "E: retrying again changes nothing")
	await mode.refresh()
	_check(hub.get_money_label_text() == money_after_one and hub.get_market_row_texts(REP)["held"] == "持有 1", "E: a fresh server read confirms one purchase, not two")

	# F: another device takes over the character (policy A).
	var other := OnlineProgressClient.new()
	other.configure(_host, _api_port)
	root.add_child(other)
	_check((await other.sign_in_email_test(email, password, false))["status"] == OnlineProgressClient.OK and (await other.begin_gameplay_session())["status"] == OnlineProgressClient.OK, "F: a second device takes over the account")
	await _press(mode, "buy")
	_check(mode.get_status_text() == OnlineTradeTestMode.SUPERSEDED_TEXT and hub.get_feedback_text() == OnlineTradeTestMode.HUB_SUPERSEDED_TEXT, "F: the old device is told it was taken over")
	_check(hub.get_market_button(REP, "buy").disabled and mode.get_panel_button("Reclaim").visible, "F: trading stops on the old device; take-back offered")
	_check(hub.get_market_row_texts(REP)["held"] == "持有 1", "F: no order went through from the old session")
	await mode.reclaim_session()
	_check(not hub.get_market_button(REP, "buy").disabled, "F: after taking back, trading is available again")
	await _press(mode, "buy")
	_check(hub.get_market_row_texts(REP)["held"] == "持有 2", "F: the reclaimed session trades normally (goods 2)")
	other.queue_free()

	mode.sign_out()
	_check(not hub.is_open(), "Signed out; market closed")
	mode.queue_free()
	await process_frame


func _press(mode: OnlineTradeTestMode, action: String) -> void:
	var button := mode.hub.get_market_button(REP, action)
	if button != null and not button.disabled:
		button.pressed.emit()
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
