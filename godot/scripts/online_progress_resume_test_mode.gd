class_name OnlineProgressResumeTestMode
extends Node

## VS-01 WP01-F — Online Progress Resume TEST mode: an isolated scene
## (scenes/online_progress_resume_test_mode.tscn), never part of the normal
## game. After the app is closed and opened again, the same disposable local
## test account signs in and this screen reads back, FROM THE SERVER ONLY:
## - Trade progress: money, the representative good and its trade revision
##   (vs01_progress_get through the existing OnlineTradeAdapter);
## - Hero progression: Level / EXP and its own Hero revision
##   (vs01e_progression_get through the existing OnlineCombatAdapter).
## The two are separate server contracts with separate revisions and are
## never merged into one number.
##
## Nothing is shown as confirmed unless the server answered in this run. An
## unanswered read keeps the last server-confirmed values and says so. An
## answer that arrives after a sign-out or an account switch never reaches
## the screen. The normal game scene, the offline services and the local save
## are not used. Local test accounts only (127.0.0.1); no new RPC.

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 17350

const BANNER_TEXT := "ONLINE TEST 進度讀回・本機測試伺服器\n數值只顯示伺服器確認；不會寫入本機遊戲存檔"
const SIGNED_OUT_TEXT := "未登入（只限本機測試帳號）"
const SIGNED_IN_TEXT := "已登入測試帳號：%s"
const TRADE_UNKNOWN_TEXT := "金錢及貨物：未讀取（等待伺服器確認）"
const TRADE_TEXT := "金錢 %d　貨物 %d（伺服器確認・交易版本 %d）"
const HERO_UNKNOWN_TEXT := "主角等級：未讀取（等待伺服器確認）"
const HERO_TEXT := "主角 Lv %d　經驗 %d / %d（伺服器確認・主角版本 %d）"
const HERO_MAX_TEXT := "主角 Lv %d（最高等級，伺服器確認・主角版本 %d）"
const CONFIRMED_TEXT := "已由伺服器讀回：金錢、貨物及主角等級"
const PARTIAL_TRADE_TEXT := "只確認到金錢及貨物；主角等級未能確認，請重新讀取"
const PARTIAL_HERO_TEXT := "只確認到主角等級；金錢及貨物未能確認，請重新讀取"
const UNCERTAIN_TEXT := "未能連接伺服器確認：顯示上次伺服器確認的數值，請重新讀取"
const SUPERSEDED_TEXT := "此帳號已在另一裝置開始遊戲：本裝置不再讀取最新進度，按「重新接管」"
const REFUSED_TEXT := "伺服器拒絕讀取：%s"
const BEGIN_FAILED_TEXT := "未能開始 Session：%s"
const SIGN_IN_FAILED_TEXT := "登入失敗：%s"

var host := DEFAULT_HOST
var port := DEFAULT_PORT
## Tests may inject a client before the node enters the tree.
var client_override: OnlineProgressClient

var client: OnlineProgressClient
var trade_adapter: OnlineTradeAdapter
var combat_adapter: OnlineCombatAdapter
var _busy := false
## A sign-in whose answer has not arrived. Not cleared by sign_out(): a new
## sign-in waits until the old one answered, so the two can never overlap.
var _signing_in := false
## Raised on every sign-out / account change: answers to requests started
## before it never reach the view.
var _view_epoch := 0
var _status := ""
var _account := ""

var _panel: CanvasLayer
var _login_box: VBoxContainer
var _session_box: VBoxContainer
var _email_edit: LineEdit
var _password_edit: LineEdit
var _account_label: Label
var _trade_label: Label
var _hero_label: Label
var _status_label: Label
var _buttons := {}


func _ready() -> void:
	_read_command_line()
	client = client_override if client_override != null else OnlineProgressClient.new()
	client.name = "OnlineProgressClient"
	if client.get_parent() == null:
		add_child(client)
	client.configure(host, port)
	_new_adapters()
	client.gameplay_session_superseded.connect(_on_superseded)
	_build_panel()
	_show_signed_out()


# --- Player actions (also driven directly by tests) -------------------------------

## `create` is false when the account must already exist (a read-back run).
func sign_in(email: String, password: String, create: bool = true) -> Dictionary:
	if _busy or _signing_in:
		return _busy_result()
	var previous_user := client.get_user_id()
	var epoch := _begin_request()
	_signing_in = true
	var result := await client.sign_in_email_test(email, password, create)
	_signing_in = false
	if not _end_request(epoch):
		# Signed out while this sign-in was in flight: the player chose to be
		# signed out, so a late success is undone and never shown.
		if result["status"] == OnlineProgressClient.OK and client.is_signed_in():
			client.sign_out_local()
			_new_adapters()
			_show_signed_out()
		var late := _stale_result()
		late["original_status"] = result["status"]
		return late
	if result["status"] == OnlineProgressClient.OK:
		if client.get_user_id() != previous_user:
			# Another account (or the first one): nothing of the previous view.
			_new_adapters()
			_view_epoch += 1
		_account = email
		_status = "請按「開始遊戲 Session」"
	else:
		_status = SIGN_IN_FAILED_TEXT % result["reason"]
	_render()
	return result


## Starts (or takes back) the gameplay session, then reads both server
## contracts. {"status", "trade", "hero"}.
func begin_session() -> Dictionary:
	if _busy:
		return _busy_result()
	var epoch := _begin_request()
	# C5: hold THIS request's adapters for its whole life. sign_out() replaces
	# the members, and Godot drops a waiting call of a RefCounted that nothing
	# references any more, so the old request would never finish (see
	# verify_vs01_wp01c_online_trade_ui.gd). Held here, it completes, and the
	# _view_epoch checks below still discard its answer.
	var trade_adapter_for_request := trade_adapter
	var combat_adapter_for_request := combat_adapter
	var trade := await trade_adapter_for_request.begin()
	if epoch != _view_epoch:
		return _stale_result()
	if trade["status"] != OnlineProgressClient.OK:
		_end_request(epoch)
		_status = BEGIN_FAILED_TEXT % trade["reason"]
		_render()
		return {"status": trade["status"], "trade": trade, "hero": {}}
	var hero := await combat_adapter_for_request.refresh()
	if not _end_request(epoch):
		return _stale_result()
	_status = _status_for(trade, hero)
	_render()
	return {"status": _overall(trade, hero), "trade": trade, "hero": hero}


func reclaim_session() -> Dictionary:
	return await begin_session()


## Reads both server contracts again under the active gameplay session.
func refresh_all() -> Dictionary:
	if _busy:
		return _busy_result()
	var epoch := _begin_request()
	# C5: hold this request's adapters for its whole life (see begin_session).
	var trade_adapter_for_request := trade_adapter
	var combat_adapter_for_request := combat_adapter
	var trade := await trade_adapter_for_request.refresh()
	if epoch != _view_epoch:
		return _stale_result()
	var hero := {}
	if trade.get("reason", "") != OnlineProgressClient.SUPERSEDED_REASON:
		hero = await combat_adapter_for_request.refresh()
	if not _end_request(epoch):
		return _stale_result()
	_status = _status_for(trade, hero)
	_render()
	return {"status": _overall(trade, hero), "trade": trade, "hero": hero}


## Always allowed, even while a request is in flight: its answer is dropped.
func sign_out() -> void:
	client.sign_out_local()
	_new_adapters()
	_view_epoch += 1
	_busy = false
	_show_signed_out()


func is_busy() -> bool:
	return _busy


func get_status_text() -> String:
	return _status


func get_trade_text() -> String:
	return _trade_label.text


func get_hero_text() -> String:
	return _hero_label.text


func get_account_text() -> String:
	return _account_label.text


func get_panel_button(button_name: String) -> Button:
	return _buttons.get(button_name)


## The server-confirmed values held now. Keys are present only for what the
## server confirmed: {user_id, money, goods, trade_revision} and
## {level, exp, exp_to_next, hero_revision}.
func get_snapshot() -> Dictionary:
	var snap := {"user_id": client.get_user_id()}
	if trade_adapter.has_confirmed_state():
		snap["money"] = trade_adapter.get_wallet().get_balance()
		snap["goods"] = trade_adapter.get_inventory().get_quantity(OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID)
		snap["trade_revision"] = trade_adapter.get_confirmed_revision()
	var p := combat_adapter.get_confirmed_progression()
	if not p.is_empty():
		snap["level"] = int(p["level"])
		snap["exp"] = int(p["exp"])
		snap["exp_to_next"] = int(p["exp_to_next"])
		snap["hero_revision"] = int(p["revision"])
	return snap


# --- Internals -------------------------------------------------------------------

func _new_adapters() -> void:
	trade_adapter = OnlineTradeAdapter.new(client)
	combat_adapter = OnlineCombatAdapter.new(client)


func _status_for(trade: Dictionary, hero: Dictionary) -> String:
	var superseded := OnlineProgressClient.SUPERSEDED_REASON
	if trade.get("reason", "") == superseded or hero.get("reason", "") == superseded or client.is_gameplay_session_superseded():
		return SUPERSEDED_TEXT
	var trade_ok: bool = trade.get("status") == OnlineProgressClient.OK
	var hero_ok: bool = hero.get("status") == OnlineProgressClient.OK
	if trade_ok and hero_ok:
		return CONFIRMED_TEXT
	if trade_ok:
		return PARTIAL_TRADE_TEXT
	if hero_ok:
		return PARTIAL_HERO_TEXT
	if trade.get("status") == OnlineProgressClient.REJECTED:
		return REFUSED_TEXT % trade.get("reason", "")
	return UNCERTAIN_TEXT


static func _overall(trade: Dictionary, hero: Dictionary) -> String:
	if trade.get("status") == OnlineProgressClient.OK and hero.get("status") == OnlineProgressClient.OK:
		return OnlineProgressClient.OK
	if trade.get("status") == OnlineProgressClient.REJECTED or hero.get("status") == OnlineProgressClient.REJECTED:
		return OnlineProgressClient.REJECTED
	return OnlineProgressClient.UNCERTAIN


func _on_superseded() -> void:
	_status = SUPERSEDED_TEXT
	_render()


func _render() -> void:
	var snap := get_snapshot()
	if snap.has("money"):
		_trade_label.text = TRADE_TEXT % [snap["money"], snap["goods"], snap["trade_revision"]]
	else:
		_trade_label.text = TRADE_UNKNOWN_TEXT
	if not snap.has("level"):
		_hero_label.text = HERO_UNKNOWN_TEXT
	elif int(snap["level"]) >= ProgressionState.MAX_LEVEL:
		_hero_label.text = HERO_MAX_TEXT % [snap["level"], snap["hero_revision"]]
	else:
		_hero_label.text = HERO_TEXT % [snap["level"], snap["exp"], snap["exp_to_next"], snap["hero_revision"]]
	_status_label.text = _status
	var signed_in := client.is_signed_in()
	var session := not client.get_gameplay_session_id().is_empty()
	var superseded := client.is_gameplay_session_superseded()
	_account_label.text = SIGNED_IN_TEXT % _account if signed_in else SIGNED_OUT_TEXT
	_login_box.visible = not signed_in
	_session_box.visible = signed_in
	_buttons["SignIn"].disabled = _busy
	_buttons["Begin"].visible = not session
	_buttons["Begin"].disabled = _busy or not signed_in
	_buttons["Reclaim"].visible = superseded
	_buttons["Reclaim"].disabled = _busy
	_buttons["Refresh"].disabled = _busy or not session or superseded
	_buttons["SignOut"].disabled = not signed_in


func _begin_request() -> int:
	_busy = true
	_render()
	return _view_epoch


func _end_request(epoch: int) -> bool:
	if epoch != _view_epoch:
		return false
	_busy = false
	return true


static func _busy_result() -> Dictionary:
	return {"status": OnlineProgressClient.REJECTED, "reason": "busy", "trade": {}, "hero": {}}


static func _stale_result() -> Dictionary:
	return {"status": OnlineProgressClient.UNCERTAIN, "reason": "answer_after_sign_out_or_account_change", "stale": true, "trade": {}, "hero": {}}


func _show_signed_out() -> void:
	_account = ""
	_status = ""
	# Disposable local test account: random, no clock needed.
	_email_edit.text = "resume-%s@myrial.test" % OnlineProgressClient.new_idempotency_key().substr(0, 16)
	_password_edit.text = "localtest-%s" % OnlineProgressClient.new_idempotency_key().substr(0, 12)
	_render()


func _build_panel() -> void:
	_panel = CanvasLayer.new()
	_panel.name = "OnlinePanel"
	_panel.layer = 30
	add_child(_panel)
	var box := PanelContainer.new()
	box.name = "PanelBox"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.14, 0.24, 0.96)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	box.add_theme_stylebox_override("panel", style)
	box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.add_child(box)
	var column := VBoxContainer.new()
	column.name = "Box"
	column.add_theme_constant_override("separation", 4)
	box.add_child(column)
	column.add_child(_label("Banner", BANNER_TEXT, 16))
	_account_label = _label("AccountLabel", SIGNED_OUT_TEXT, 15)
	column.add_child(_account_label)
	_login_box = VBoxContainer.new()
	_login_box.name = "LoginBox"
	column.add_child(_login_box)
	_email_edit = LineEdit.new()
	_email_edit.name = "EmailEdit"
	_login_box.add_child(_email_edit)
	_password_edit = LineEdit.new()
	_password_edit.name = "PasswordEdit"
	_password_edit.secret = true
	_login_box.add_child(_password_edit)
	_login_box.add_child(_button("SignIn", "登入本機測試帳號", func(): sign_in(_email_edit.text, _password_edit.text, true)))
	_session_box = VBoxContainer.new()
	_session_box.name = "SessionBox"
	column.add_child(_session_box)
	_trade_label = _label("TradeLabel", TRADE_UNKNOWN_TEXT, 20)
	_session_box.add_child(_trade_label)
	_hero_label = _label("HeroLabel", HERO_UNKNOWN_TEXT, 20)
	_session_box.add_child(_hero_label)
	var row := HBoxContainer.new()
	row.name = "ActionRow"
	row.add_theme_constant_override("separation", 6)
	row.add_child(_button("Begin", "開始遊戲 Session", func(): begin_session()))
	row.add_child(_button("Reclaim", "重新接管", func(): reclaim_session()))
	row.add_child(_button("Refresh", "重新讀取", func(): refresh_all()))
	row.add_child(_button("SignOut", "登出", func(): sign_out()))
	_session_box.add_child(row)
	_status_label = _label("StatusLabel", "", 15)
	column.add_child(_status_label)


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


## `-- --online-host <host> --online-port <port>` (local hosts only).
func _read_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--online-host":
			host = args[i + 1]
		elif args[i] == "--online-port":
			port = int(args[i + 1])
