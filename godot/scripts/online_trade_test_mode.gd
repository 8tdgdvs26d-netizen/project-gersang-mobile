class_name OnlineTradeTestMode
extends Node

## VS-01 WP01-C — Online TEST mode: the existing city market UI (CityHub)
## driven by the Nakama server through OnlineTradeAdapter, for the ONE
## representative good. A separate scene (scenes/online_trade_test_mode.tscn),
## never part of the normal game: the normal game scene and its script, the
## offline trade service and the local save are not used, so nothing online
## can reach the offline progress or the Development Save.
##
## Only the server decides: buy / sell go to Nakama; money, goods and prices
## shown come only from server-confirmed progress (the adapter's mirror). An
## uncertain answer never shows success and changes nothing; one order at a
## time (buttons locked while it is in flight, so a double tap cannot submit
## twice); a superseded gameplay session is told and can take the character
## back (session policy A).
##
## Local test accounts only (127.0.0.1). Run: nakama/scripts/run_online_trade_ui.sh
## or open the scene in the editor and press F6, with the local server up.

const REP := OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID
## Cities the WP01 server market supports.
const TEST_CITIES := ["A", "B"]
const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 17350

const BANNER_TEXT := "ONLINE TEST 模式・本機測試伺服器\n交易由伺服器確認；不會寫入本機遊戲存檔"
## The market UI is scaled and moved below the online panel (CanvasLayer
## transform only; the market UI itself is unchanged).
const HUB_SCALE := 0.84
const HUB_OFFSET := Vector2(58, 62)
const SIGNED_OUT_TEXT := "未登入（只限本機測試帳號）"
const SIGNED_IN_TEXT := "已登入測試帳號：%s"
const SESSION_TEXT := "遊戲 Session：已開始"
const BUSY_TEXT := "交易處理中…（等待伺服器確認）"
const UNCERTAIN_TEXT := "網絡中斷：未能確認交易結果，金錢及貨物未有更改。請按「重試未確定交易」。"
const SUPERSEDED_TEXT := "此帳號已在另一裝置開始遊戲，本裝置已停止操作。可按「重新接管」取回。"
const RATE_LIMITED_TEXT := "操作太頻密，交易未生效，請稍後再試。"
const OUT_OF_SCOPE_TEXT := "Online TEST 只開放「%s」交易。"
const REJECTED_TEXT := "伺服器拒絕交易（%s），金錢及貨物未有更改。"
const PENDING_TEXT := "未確定交易：%d 單"
const RECOVERED_TEXT := "已確認 %d 單之前未確定的交易"
const STILL_PENDING_TEXT := "仍有 %d 單未能確認，請稍後再試"
const STALE_TEXT := "已登出或切換帳號：舊請求的結果不會套用。"
## Short lines for the market's own feedback row (the full text is in the
## online panel's status line).
const HUB_BUSY_TEXT := "處理中…等待伺服器確認"
const HUB_UNCERTAIN_TEXT := "未能確認結果：未有更改，請重試"
const HUB_SUPERSEDED_TEXT := "已被其他裝置接管，交易未送出"
const HUB_RATE_LIMITED_TEXT := "操作太頻密，交易未生效"
const HUB_REJECTED_TEXT := "伺服器拒絕：%s"
const HUB_STALE_TEXT := "舊請求結果不會套用"

var host := DEFAULT_HOST
var port := DEFAULT_PORT
## Tests may inject a client before the node enters the tree.
var client_override: OnlineProgressClient

var client: OnlineProgressClient
var adapter: OnlineTradeAdapter
var hub: CityHub
var city := "A"
var _busy := false
var _session_started := false

var _panel: CanvasLayer
var _panel_box: PanelContainer
var _login_box: VBoxContainer
var _session_box: VBoxContainer
var _email_edit: LineEdit
var _password_edit: LineEdit
var _account_label: Label
var _status_label: Label
var _pending_label: Label
var _buttons := {}


func _ready() -> void:
	_read_command_line()
	client = client_override if client_override != null else OnlineProgressClient.new()
	client.name = "OnlineProgressClient"
	if client.get_parent() == null:
		add_child(client)
	client.configure(host, port)
	adapter = OnlineTradeAdapter.new(client)
	hub = $CityHub as CityHub
	hub.scale = Vector2(HUB_SCALE, HUB_SCALE)
	hub.offset = HUB_OFFSET
	hub.buy_requested.connect(_on_buy_requested)
	hub.sell_requested.connect(_on_sell_requested)
	hub.leave_requested.connect(sign_out)
	client.gameplay_session_superseded.connect(_on_superseded)
	_build_panel()
	_show_signed_out()


# --- Player actions (also driven directly by tests) ------------------------------

func sign_in(email: String, password: String) -> Dictionary:
	_set_status("登入中…")
	var result := await client.sign_in_email_test(email, password, true)
	if result["status"] == OnlineProgressClient.OK:
		_account_label.text = SIGNED_IN_TEXT % email
		_login_box.visible = false
		_session_box.visible = true
		_set_status("請按「開始遊戲 Session」")
	else:
		_set_status("登入失敗：%s" % result["reason"])
	_update_buttons()
	return result


func begin_session() -> Dictionary:
	_set_status("開始遊戲 Session…")
	var result := await adapter.begin()
	if result["status"] == OnlineProgressClient.OK:
		_session_started = true
		_open_hub(city)
		_set_status(SESSION_TEXT)
	elif result.get("stale", false):
		_set_status(STALE_TEXT)
	else:
		_set_status("未能開始 Session：%s" % result["reason"])
	_render()
	return result


func refresh() -> Dictionary:
	var result := await adapter.refresh()
	if result["status"] == OnlineProgressClient.OK:
		_set_status("已由伺服器重新讀取進度")
	elif result["reason"] == OnlineProgressClient.SUPERSEDED_REASON:
		_set_status(SUPERSEDED_TEXT)
	else:
		_set_status("未能讀取進度：%s" % result["reason"])
	_render()
	return result


func retry_pending() -> Array:
	if _busy:
		return []
	_busy = true
	_update_buttons()
	var results := await adapter.recover()
	_busy = false
	var confirmed := results.filter(func(r): return r["online_status"] == OnlineProgressClient.OK).size()
	if adapter.pending_count() > 0:
		_set_status(STILL_PENDING_TEXT % adapter.pending_count())
	else:
		_set_status(RECOVERED_TEXT % confirmed)
	_render()
	return results


func reclaim_session() -> Dictionary:
	return await begin_session()


func switch_city(new_city: String) -> void:
	if not new_city in TEST_CITIES or _busy:
		return
	city = new_city
	if _session_started:
		_open_hub(city)
	_render()


func sign_out() -> void:
	client.sign_out_local()
	adapter = OnlineTradeAdapter.new(client)  # a new account gets a new mirror
	_session_started = false
	_busy = false
	hub.close()
	_show_signed_out()


func is_busy() -> bool:
	return _busy


func get_status_text() -> String:
	return _status_label.text


func get_pending_text() -> String:
	return _pending_label.text


func get_panel_button(button_name: String) -> Button:
	return _buttons.get(button_name)


# --- Trades --------------------------------------------------------------------------

func _on_buy_requested(good_id: String, quantity: int) -> void:
	await _trade("buy", good_id, quantity)


func _on_sell_requested(good_id: String, quantity: int) -> void:
	await _trade("sell", good_id, quantity)


func _trade(action: String, good_id: String, quantity: int) -> void:
	if _busy:
		return  # one order at a time: a double tap cannot submit twice
	if good_id != REP:
		hub.show_feedback_text(OUT_OF_SCOPE_TEXT % GoodsCatalog.get_good(REP)["display_name"])
		return
	_busy = true
	_update_buttons()
	_set_status(BUSY_TEXT)
	hub.show_feedback_text(HUB_BUSY_TEXT)
	var result: Dictionary
	if action == "buy":
		result = await adapter.buy(city, quantity)
	else:
		result = await adapter.sell(city, quantity)
	_busy = false
	_show_result(action, quantity, result)
	_render()


func _show_result(action: String, quantity: int, result: Dictionary) -> void:
	if result["online_status"] == OnlineProgressClient.OK:
		# A server receipt: success, or a rule rejection with TradeService's code.
		hub.show_trade_feedback(action, REP, quantity, result)
		_set_status("伺服器已確認" + ("（重送結果）" if result["replayed"] else ""))
	elif result["online_status"] == OnlineProgressClient.UNCERTAIN:
		var stale: bool = result.get("stale", false)
		hub.show_feedback_text(HUB_STALE_TEXT if stale else HUB_UNCERTAIN_TEXT)
		_set_status(STALE_TEXT if stale else UNCERTAIN_TEXT)
	elif result["reason"] == OnlineProgressClient.SUPERSEDED_REASON:
		hub.show_feedback_text(HUB_SUPERSEDED_TEXT)
		_set_status(SUPERSEDED_TEXT)
	elif result["reason"] == "rate_limited":
		hub.show_feedback_text(HUB_RATE_LIMITED_TEXT)
		_set_status(RATE_LIMITED_TEXT)
	else:
		hub.show_feedback_text(HUB_REJECTED_TEXT % result["reason"])
		_set_status(REJECTED_TEXT % result["reason"])


func _on_superseded() -> void:
	_set_status(SUPERSEDED_TEXT)
	hub.show_feedback_text(HUB_SUPERSEDED_TEXT)
	_update_buttons()


# --- View ----------------------------------------------------------------------------

func _open_hub(city_id: String) -> void:
	hub.open(city_id)
	# Only the market exists online: hide the other facility tabs.
	for tab in hub.get_node("Center/Content/FacilityTabs").get_children():
		if tab.name != "MarketTabButton":
			(tab as Button).visible = false


## Shows only server-confirmed values (the adapter's mirror).
func _render() -> void:
	_pending_label.text = PENDING_TEXT % adapter.pending_count()
	if _session_started and adapter.has_confirmed_state():
		hub.show_money(adapter.get_wallet().get_balance())
		var inventory := adapter.get_inventory()
		hub.show_cargo_summary(inventory.get_used_capacity(), inventory.get_max_capacity())
		hub.show_market({REP: _whole_numbers(adapter.get_quote(city))}, {REP: inventory.get_quantity(REP)})
	_update_buttons()


## Server JSON numbers arrive as floats; the market UI shows whole prices and
## stock ("84", not "84.0").
static func _whole_numbers(quote: Dictionary) -> Dictionary:
	var whole := {}
	for key in quote:
		whole[key] = int(quote[key]) if typeof(quote[key]) in [TYPE_INT, TYPE_FLOAT] else quote[key]
	return whole


func _update_buttons() -> void:
	var superseded := client.is_gameplay_session_superseded()
	var can_trade := _session_started and not _busy and not superseded and adapter.has_confirmed_state()
	for good_id in hub.get_market_good_ids():
		for action in ["buy", "buy10", "sell", "sell10"]:
			var button := hub.get_market_button(good_id, action)
			if button != null:
				button.disabled = not (can_trade and good_id == REP)
	_buttons["Begin"].disabled = not client.is_signed_in() or _busy
	_buttons["Begin"].visible = not _session_started
	_buttons["Refresh"].disabled = not _session_started or superseded
	_buttons["RetryPending"].disabled = _busy or adapter.pending_count() == 0 or not _session_started or superseded
	_buttons["Reclaim"].visible = superseded
	_buttons["Reclaim"].disabled = _busy
	for c in TEST_CITIES:
		_buttons["City" + c].disabled = _busy or city == c or not _session_started


func _set_status(text: String) -> void:
	_status_label.text = text


func _show_signed_out() -> void:
	_login_box.visible = true
	_session_box.visible = false
	_account_label.text = SIGNED_OUT_TEXT
	_status_label.text = ""
	_email_edit.text = "player-%d%04d@myrial.test" % [Time.get_unix_time_from_system(), randi() % 10000]
	_password_edit.text = "localtest-%08x" % randi()
	_render()


func _build_panel() -> void:
	_panel = CanvasLayer.new()
	_panel.name = "OnlinePanel"
	_panel.layer = 30
	add_child(_panel)
	_panel_box = PanelContainer.new()
	_panel_box.name = "PanelBox"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.16, 0.06, 0.24, 0.96)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	_panel_box.add_theme_stylebox_override("panel", style)
	_panel_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_panel.add_child(_panel_box)
	var root := VBoxContainer.new()
	root.name = "Box"
	root.add_theme_constant_override("separation", 4)
	_panel_box.add_child(root)
	root.add_child(_label("Banner", BANNER_TEXT, 16))
	_account_label = _label("AccountLabel", SIGNED_OUT_TEXT, 15)
	root.add_child(_account_label)

	_login_box = VBoxContainer.new()
	_login_box.name = "LoginBox"
	root.add_child(_login_box)
	_email_edit = LineEdit.new()
	_email_edit.name = "EmailEdit"
	_email_edit.placeholder_text = "本機測試電郵"
	_login_box.add_child(_email_edit)
	_password_edit = LineEdit.new()
	_password_edit.name = "PasswordEdit"
	_password_edit.secret = true
	_login_box.add_child(_password_edit)
	_login_box.add_child(_button("SignIn", "登入本機測試帳號", func(): sign_in(_email_edit.text, _password_edit.text)))

	_session_box = VBoxContainer.new()
	_session_box.name = "SessionBox"
	root.add_child(_session_box)
	var row := HBoxContainer.new()
	row.name = "ActionRow"
	row.add_theme_constant_override("separation", 6)
	row.add_child(_button("Begin", "開始遊戲 Session", func(): begin_session()))
	row.add_child(_button("Reclaim", "重新接管", func(): reclaim_session()))
	row.add_child(_button("Refresh", "重新讀取", func(): refresh()))
	row.add_child(_button("RetryPending", "重試未確定", func(): retry_pending()))
	for c in TEST_CITIES:
		row.add_child(_button("City" + c, "%s 城" % c, switch_city.bind(c)))
	_pending_label = _label("PendingLabel", "", 15)
	_pending_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	row.add_child(_pending_label)
	_session_box.add_child(row)
	_status_label = _label("StatusLabel", "", 15)
	root.add_child(_status_label)


func _label(node_name: String, text: String, size: int) -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _button(node_name: String, text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(0, 44)
	button.add_theme_font_size_override("font_size", 16)
	button.pressed.connect(on_pressed)
	_buttons[node_name] = button
	return button


## `-- --online-host <host> --online-port <port>` (local hosts only; the
## client refuses email test sign-in anywhere else).
func _read_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--online-host":
			host = args[i + 1]
		elif args[i] == "--online-port":
			port = int(args[i + 1])
