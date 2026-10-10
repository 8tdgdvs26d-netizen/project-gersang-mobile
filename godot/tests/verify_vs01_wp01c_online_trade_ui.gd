extends SceneTree

## VS-01 WP01-C — UI integration checks for the Online TEST mode
## (scenes/online_trade_test_mode.tscn): the existing city market UI driven by
## OnlineTradeAdapter. Needs no server: a gated test client stands in for
## Nakama and holds each answer until the test releases it. Part of the normal
## Godot regression; the live run against the local server is
## tests/live_vs01_wp01c_online_trade_ui.gd.

const REP := OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID
const SCENE := "res://scenes/online_trade_test_mode.tscn"

var _checks := 0
var _failures := 0


class GatedClient extends OnlineProgressClient:
	var gates: Array = []
	var sent: Array = []

	func is_signed_in() -> bool:
		return _session != null

	## Local stand-in for the email test sign-in (no network).
	func sign_in_email_test(email: String, _password: String, _create: bool = true) -> Dictionary:
		var header := Marshalls.utf8_to_base64(JSON.stringify({"alg": "none"})).trim_suffix("=").trim_suffix("=")
		var body := Marshalls.utf8_to_base64(JSON.stringify({"uid": "ui-" + email, "usn": email, "exp": 4102444800})).trim_suffix("=").trim_suffix("=")
		return _accept_session(NakamaSession.new("%s.%s.x" % [header, body], false))

	func answer(result: Dictionary) -> int:
		gates.append({"answer": result, "released": false, "taken": false})
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
	_verify_static_isolation()
	await _verify_player_flow()
	_check(_dev_save_fingerprint() == dev_before, "Development Save (%s) is untouched" % SaveStore.DEFAULT_PATH)
	_check(not FileAccess.file_exists(SaveStore.DEFAULT_PATH), "The Online TEST mode created no local save file")
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-C online trade UI verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_static_isolation() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/online_trade_test_mode.gd")
	for forbidden in ["SaveStore", "user://", "FileAccess", "main.gd", "main.tscn", "TradeService.", "MarketState", "MarketRules", "Wallet.new", "spend(", ".add("]:
		_check(not source.contains(forbidden), "Online TEST mode never uses offline state, saves or local pricing (%s)" % forbidden)
	_check(source.contains("OnlineTradeAdapter"), "Online TEST mode trades only through OnlineTradeAdapter")
	var project := FileAccess.get_file_as_string("res://project.godot")
	_check(project.contains('run/main_scene="res://scenes/main.tscn"'), "The game still starts in the offline main scene")
	_check(not project.contains("online_trade_test_mode"), "Online TEST mode is not an autoload or the main scene")
	_check(not FileAccess.get_file_as_string("res://scenes/main.tscn").contains("online"), "The offline main scene does not contain the online mode")
	var hub_source := FileAccess.get_file_as_string("res://scripts/city_hub.gd")
	_check(not hub_source.contains("Online") and not hub_source.contains("Nakama"), "The shared market UI stays a pure view (no online code in city_hub.gd)")


func _verify_player_flow() -> void:
	var client := GatedClient.new()
	var mode: OnlineTradeTestMode = (load(SCENE) as PackedScene).instantiate()
	mode.client_override = client
	root.add_child(mode)
	await process_frame
	var hub := mode.hub

	# Start: signed out, no market, nothing tradable.
	_check(mode._login_box.visible and not hub.is_open(), "Start: login panel shown, market closed")
	await mode.sign_in(mode._email_edit.text, mode._password_edit.text)
	_check(mode._session_box.visible and not mode._login_box.visible, "Signed in with a local test account")

	# Session begin -> market of city A with server values only.
	_release_next(client, _begin(_view(10000, 0, 1)))
	await mode.begin_session()
	_check(hub.is_open() and hub.get_city_label_text() == "【A 城】", "Session begun: the existing market UI opens on city A")
	_check(hub.get_money_label_text() == "金錢：10000", "Money shows the server value (%s)" % hub.get_money_label_text())
	var row := hub.get_market_row_texts(REP)
	_check(row["buy_price"] == "買入價 84" and row["buyback_price"] == "賣出價 76" and row["held"] == "持有 0" and row["stock"] == "庫存 100", "Representative good shows server prices, stock and holdings as whole numbers (%s)" % str(row))
	_check(_enabled(hub, REP, "buy10") and _enabled(hub, REP, "sell"), "Representative good can be traded")
	for good_id in hub.get_market_good_ids():
		if good_id != REP:
			_check(not _enabled(hub, good_id, "buy") and not _enabled(hub, good_id, "sell10"), "Other goods are not tradable online (%s)" % good_id)
	var visible_tabs := hub.get_node("Center/Content/FacilityTabs").get_children().filter(func(t): return t.visible).map(func(t): return String(t.name))
	_check(visible_tabs == ["MarketTabButton"], "Only the market tab is shown online (%s)" % str(visible_tabs))

	# A: buy 10 at A. Double tap while in flight sends ONE order.
	var g_buy := client.answer(_trade("applied", "", 840, 84, _view(9160, 10, 2)))
	var sent_before := _trades_sent(client)
	hub.get_market_button(REP, "buy10").pressed.emit()
	await process_frame
	_check(mode.is_busy() and not _enabled(hub, REP, "buy10") and not _enabled(hub, REP, "sell"), "While the order is in flight all trade buttons are locked")
	hub.get_market_button(REP, "buy10").pressed.emit()
	hub.get_market_button(REP, "buy").pressed.emit()
	await process_frame
	_check(_trades_sent(client) - sent_before == 1, "A double tap submits exactly one order")
	_check(hub.get_money_label_text() == "金錢：10000", "Nothing changes before the server confirms")
	client.release(g_buy)
	await _until_idle(mode)
	_check(hub.get_money_label_text() == "金錢：9160" and hub.get_market_row_texts(REP)["held"] == "持有 10", "Buy confirmed: money / goods from the server (9160 / 10)")
	_check(hub.get_feedback_text() == "已買入 10 件測試商品一，支付 840", "Buy feedback from the server receipt (%s)" % hub.get_feedback_text())

	# B: sell 10 at B.
	mode.switch_city("B")
	_check(hub.get_city_label_text() == "【B 城】" and hub.get_market_row_texts(REP)["buyback_price"] == "賣出價 114", "City B market shows B's server prices")
	_release_next(client, _trade("applied", "", 1140, 114, _view(10300, 0, 3)))
	hub.get_market_button(REP, "sell10").pressed.emit()
	await _until_idle(mode)
	_check(hub.get_money_label_text() == "金錢：10300" and hub.get_market_row_texts(REP)["held"] == "持有 0", "Sell confirmed: money / goods from the server (10300 / 0)")
	_check(hub.get_feedback_text().begins_with("已賣出 10 件測試商品一，收入 1140"), "Sell feedback from the server receipt (%s)" % hub.get_feedback_text())

	# C: refresh shows the server's current state.
	_release_next(client, {"status": OnlineProgressClient.OK, "reason": "", "data": {"progress": _view(10300, 0, 3)}})
	await mode.refresh()
	_check(hub.get_money_label_text() == "金錢：10300" and mode.get_status_text() == "已由伺服器重新讀取進度", "Refresh reads the server state")

	# Rule rejection keeps TradeService's message.
	_release_next(client, _trade("rejected", "insufficient_money", 0, 0, _view(10300, 0, 3)))
	hub.get_market_button(REP, "buy10").pressed.emit()
	await _until_idle(mode)
	_check(hub.get_feedback_text() == "金錢不足" and hub.get_money_label_text() == "金錢：10300", "Server rule rejection: existing message, nothing changed")

	# D: network loss never shows success; retry with the same key.
	_release_next(client, {"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"})
	hub.get_market_button(REP, "buy").pressed.emit()
	await _until_idle(mode)
	_check(hub.get_feedback_text() == OnlineTradeTestMode.HUB_UNCERTAIN_TEXT and mode.get_status_text() == OnlineTradeTestMode.UNCERTAIN_TEXT, "Network loss: no success shown (%s)" % hub.get_feedback_text())
	_check(hub.get_money_label_text() == "金錢：10300" and hub.get_market_row_texts(REP)["held"] == "持有 0", "Network loss: money / goods unchanged")
	_check(mode.get_pending_text() == "未確定交易：1 單" and not mode.get_panel_button("RetryPending").disabled, "Network loss: the order is shown as pending, retry offered")
	var lost_key: String = client.sent[-1]["payload"]["idempotency_key"]
	# E: the retry resends the SAME key; the server's replay applies it once.
	_release_next(client, _trade("applied", "", 126, 126, _view(10174, 1, 4), true))
	await mode.retry_pending()
	_check(client.sent[-1]["payload"]["idempotency_key"] == lost_key, "Retry reuses the original idempotency key")
	_check(hub.get_money_label_text() == "金錢：10174" and mode.get_pending_text() == "未確定交易：0 單", "Retry resolves the order once (money 10174, nothing pending)")

	# Rate limit message.
	_release_next(client, {"status": OnlineProgressClient.REJECTED, "reason": "rate_limited", "grpc_status": 8})
	hub.get_market_button(REP, "buy").pressed.emit()
	await _until_idle(mode)
	_check(hub.get_feedback_text() == OnlineTradeTestMode.HUB_RATE_LIMITED_TEXT and mode.get_pending_text() == "未確定交易：0 單", "Rate limit: told, nothing pending, nothing changed")

	# F: session taken over by another device.
	_release_next(client, {"status": OnlineProgressClient.REJECTED, "reason": "gameplay_session_superseded", "grpc_status": 10})
	hub.get_market_button(REP, "buy").pressed.emit()
	await _until_idle(mode)
	_check(hub.get_feedback_text() == OnlineTradeTestMode.HUB_SUPERSEDED_TEXT and mode.get_status_text() == OnlineTradeTestMode.SUPERSEDED_TEXT, "Takeover: the player is told")
	_check(not _enabled(hub, REP, "buy") and not _enabled(hub, REP, "sell") and mode.get_panel_button("Reclaim").visible, "Takeover: trading stops; take-back offered")
	var sent_superseded := _trades_sent(client)
	hub.get_market_button(REP, "buy").pressed.emit()
	await process_frame
	_check(_trades_sent(client) == sent_superseded, "Takeover: no order is sent from the old session")
	_release_next(client, _begin(_view(10174, 1, 6)))
	await mode.reclaim_session()
	_check(_enabled(hub, REP, "buy") and not mode.get_panel_button("Reclaim").visible and mode.get_status_text() == OnlineTradeTestMode.SESSION_TEXT, "Take-back: trading available again")

	# Leaving signs out and closes the market.
	hub.get_node("Center/Content/LeaveButton").pressed.emit()
	await process_frame
	_check(not hub.is_open() and mode._login_box.visible and not client.is_signed_in(), "Leaving signs out and closes the online market")
	mode.queue_free()
	await process_frame


# --- Helpers -----------------------------------------------------------------------

## Numbers as floats, exactly as Godot parses the server's JSON.
static func _view(money: int, carried: int, revision: int) -> Dictionary:
	var backpack := {}
	if carried > 0:
		backpack[REP] = float(carried)
	return {"money": float(money), "backpack": backpack, "revision": float(revision), "used_capacity": float(carried), "max_capacity": 100.0,
		"quotes": {"A": {REP: {"buy_price": 84.0, "buyback_price": 76.0, "stock": 100.0}},
			"B": {REP: {"buy_price": 126.0, "buyback_price": 114.0, "stock": 100.0}}}}


static func _begin(view: Dictionary) -> Dictionary:
	return {"status": OnlineProgressClient.OK, "reason": "", "data": {
		"gameplay_session_id": "00000000-0000-0000-0000-%012d" % int(view["revision"]), "progress": view}}


static func _trade(status: String, reason: String, total: int, unit: int, view: Dictionary, replayed := false) -> Dictionary:
	return {"status": OnlineProgressClient.OK, "reason": "", "data": {"replayed": replayed,
		"receipt": {"status": status, "reason": reason, "total": total, "unit_price": unit, "progress_revision": view["revision"]}, "progress": view}}


static func _release_next(client: GatedClient, result: Dictionary) -> void:
	client.release(client.answer(result))


static func _enabled(hub: CityHub, good_id: String, action: String) -> bool:
	var button := hub.get_market_button(good_id, action)
	return button != null and not button.disabled


static func _trades_sent(client: GatedClient) -> int:
	return client.sent.filter(func(s): return s["id"] == OnlineProgressClient.RPC_TRADE).size()


func _until_idle(mode: OnlineTradeTestMode) -> void:
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
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
		print("FAILED: " + message)
