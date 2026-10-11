class_name OnlineCombatTestMode
extends Node

## VS-01 WP01-E E2 — Online Combat TEST mode: an isolated scene
## (scenes/online_combat_test_mode.tscn), never part of the normal game. A
## Hero-only battle of the existing CombatBattle / CombatView is opened from a
## server encounter ticket; its result is submitted to the LOCAL Nakama server,
## which alone computes and confirms the Hero EXP / Level (approved M1: bounded,
## not proof of victory). The normal game scene, the offline services and the
## local save are not used, so nothing online reaches the offline progress or
## the Development Save.
##
## Shown EXP / Level are only the server-confirmed ones; the battle result
## screen shows no EXP preview (CombatView gets no progression). A result that
## is not yet confirmed is shown as pending and resent with the same key.
##
## Local test accounts only (127.0.0.1). Run: nakama/scripts/run_online_combat_ui.sh.

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 17350
## Group selections offered (1, 2 or 3 Prototype groups). The 1- and 2-group
## choices use different groups, so one stays available while the other is in
## its server cooldown (approved R-4).
const GROUP_CHOICES := [["prototype_monster_01"], ["prototype_monster_02", "prototype_monster_03"],
	["prototype_monster_01", "prototype_monster_02", "prototype_monster_03"]]
## Automatic resend delays (seconds) for transient / uncertain answers.
const RETRY_DELAYS := [2.0, 4.0, 8.0, 16.0, 30.0]

const BANNER_TEXT := "ONLINE TEST 戰鬥・本機測試伺服器\n經驗由伺服器確認；不會寫入本機遊戲存檔"
const SIGNED_OUT_TEXT := "未登入（只限本機測試帳號）"
const SIGNED_IN_TEXT := "已登入測試帳號：%s"
const PROGRESSION_TEXT := "主角 Lv %d　經驗 %d / %d（伺服器確認）"
const PROGRESSION_MAX_TEXT := "主角 Lv %d（最高等級，伺服器確認）"
const PROGRESSION_UNKNOWN_TEXT := "主角等級：未讀取"
const PENDING_TEXT := "待確認結果：%s"
const NO_PENDING_TEXT := "待確認結果：無"
const CONFIRMED_TEXT := "伺服器已確認：經驗 +%d（Lv %d → Lv %d）"
const REPLAYED_TEXT := "伺服器已確認（之前已入帳）：經驗 +%d（Lv %d → Lv %d）"
const ABANDONED_TEXT := "已放棄上一場遭遇（不計經驗）"
const TOO_EARLY_TEXT := "戰鬥結束得太快：伺服器最少 10 秒後先確認，結果已保留，稍後自動重新提交"
const RATE_LIMITED_TEXT := "提交太頻密：結果已保留，稍後自動重新提交"
const UNCERTAIN_TEXT := "未能確認結果：可能已入帳或未入帳，結果已保留，稍後自動以原提交核實"
const SUPERSEDED_TEXT := "此帳號已在另一裝置開始遊戲：結果已保留，按「重新接管」後會重新提交"
const UNSETTLED_TEXT := "上一場遭遇仍未結算：可按「重新提交」，或按「放棄上一場」"
const LOST_PENDING_TEXT := "上一場遭遇的結果未能在本裝置找回：只可按「放棄上一場」（今場不計經驗）"
const CONFIRM_ABANDON_TEXT := "確認放棄上一場？今場不計經驗，已確認的經驗不受影響"
const FINAL_TEXTS := {
	"ticket_expired": "遭遇已過期：今場不計經驗",
	"ticket_already_claimed": "此遭遇已經結算：顯示伺服器確認的等級",
	"claim_locked": "此遭遇已有另一個結果在等待確認：今次提交不計",
	"ticket_abandoned": "此遭遇已放棄：不計經驗",
	"ticket_not_found": "找不到此遭遇：不計經驗",
	"invalid_claim": "戰鬥結果不被伺服器接受：不計經驗",
	"cooldown_active": "此敵群剛被擊敗，冷卻中：請稍後再試或選其他敵群",
	"ticket_unsettled": UNSETTLED_TEXT,
}

var host := DEFAULT_HOST
var port := DEFAULT_PORT
## Tests may inject a client before the node enters the tree.
var client_override: OnlineProgressClient

var client: OnlineProgressClient
var adapter: OnlineCombatAdapter
var combat_view: CombatView
var _battle: CombatBattle
var _busy := false
var _retry_index := 0
var _retry_generation := 0
var _confirming_abandon := false
## Raised on sign-out: answers to requests started before it never reach the view.
var _view_epoch := 0
## Tests set this to drive retries themselves.
var auto_retry := true

var _panel: CanvasLayer
var _login_box: VBoxContainer
var _session_box: VBoxContainer
var _email_edit: LineEdit
var _password_edit: LineEdit
var _account_label: Label
var _progression_label: Label
var _pending_label: Label
var _status_label: Label
var _buttons := {}


func _ready() -> void:
	_read_command_line()
	client = client_override if client_override != null else OnlineProgressClient.new()
	client.name = "OnlineProgressClient"
	if client.get_parent() == null:
		add_child(client)
	client.configure(host, port)
	adapter = OnlineCombatAdapter.new(client)
	combat_view = CombatView.new()
	combat_view.name = "CombatView"
	combat_view.visible = false
	add_child(combat_view)
	combat_view.exit_requested.connect(_on_battle_exit)
	client.gameplay_session_superseded.connect(_on_superseded)
	_build_panel()
	_show_signed_out()


# --- Player actions (also driven directly by tests) -------------------------------

func sign_in(email: String, password: String) -> Dictionary:
	if _busy:
		return _busy_result()
	var epoch := _begin_request()
	var result := await client.sign_in_email_test(email, password, true)
	if not _end_request(epoch):
		return result
	if result["status"] == OnlineProgressClient.OK:
		_account_label.text = SIGNED_IN_TEXT % email
		_login_box.visible = false
		_session_box.visible = true
		_set_status("請按「開始遊戲 Session」")
	else:
		_set_status("登入失敗：%s" % result["reason"])
	_render()
	return result


## Starts (or takes back) the gameplay session, reads the server progression
## and resends a pending result kept from before.
func begin_session() -> Dictionary:
	if _busy:
		return _busy_result()
	var epoch := _begin_request()
	var result := await client.begin_gameplay_session()
	if not _end_request(epoch):
		return result
	if result["status"] != OnlineProgressClient.OK:
		_set_status("未能開始 Session：%s" % result["reason"])
		_render()
		return result
	_set_status("遊戲 Session：已開始")
	await refresh()
	if adapter.has_pending():
		await resend()
	return result


func reclaim_session() -> Dictionary:
	return await begin_session()


func refresh() -> Dictionary:
	if _busy:
		return _busy_result()
	var epoch := _begin_request()
	var result := await adapter.refresh()
	if not _end_request(epoch):
		return result
	if result["status"] == OnlineProgressClient.OK:
		if not adapter.get_unresolved_ticket().is_empty() and not adapter.has_pending():
			_set_status(LOST_PENDING_TEXT)
	else:
		_set_status(_text_for(result))
	_render()
	return result


## Asks the server for a ticket and opens a Hero-only battle of its size.
func start_battle(choice: int) -> Dictionary:
	if _busy or _battle != null:
		return _busy_result()
	var epoch := _begin_request()
	var result := await adapter.begin_encounter(GROUP_CHOICES[clampi(choice, 0, GROUP_CHOICES.size() - 1)])
	if not _end_request(epoch):
		return result
	if result["status"] != OnlineProgressClient.OK:
		_set_status(_text_for(result))
		if result.get("reason", "") == "ticket_unsettled":
			await refresh()
		_render()
		return result
	var ticket := adapter.get_ticket()
	_battle = CombatBattle.create_party(int(ticket["enemy_count"]), adapter.hero_stats(), [], {}, {})
	_battle.encounter_id = ticket["ticket_id"]
	var groups: Array[String] = []
	for g in ticket["group_ids"]:
		groups.append(String(g))
	_battle.group_monster_ids = groups
	combat_view.progression = null  # no EXP preview: only the server confirms EXP
	combat_view.open(_battle)
	_set_status("戰鬥中（敵人 %d）" % int(ticket["enemy_count"]))
	_render()
	return result


## The result screen's button: submit the finished battle.
func submit_battle() -> Dictionary:
	if _battle == null or not _battle.is_over() or _busy:
		return _busy_result()
	var battle := _battle
	_battle = null
	combat_view.close()
	var epoch := _begin_request()
	var result := await adapter.submit_battle(battle)
	if not _end_request(epoch):
		return result
	_after_answer(result)
	return result


## Resends the pending result / abandon with its original key and payload.
func resend() -> Dictionary:
	if _busy:
		return _busy_result()
	var epoch := _begin_request()
	var result := await adapter.resend_pending()
	if not _end_request(epoch):
		return result
	_after_answer(result)
	return result


## Explicit abandon of the unresolved ticket, in two steps (the second press
## confirms). Returns {} on the first press.
func abandon_unresolved() -> Dictionary:
	var ticket := adapter.get_unresolved_ticket()
	if ticket.is_empty() or _busy:
		return {}
	if not _confirming_abandon:
		_confirming_abandon = true
		_set_status(CONFIRM_ABANDON_TEXT)
		_render()
		return {}
	_confirming_abandon = false
	var epoch := _begin_request()
	var result := await adapter.abandon(String(ticket["ticket_id"]))
	if not _end_request(epoch):
		return result
	_after_answer(result)
	return result


func sign_out() -> void:
	if _battle != null:
		combat_view.close()
		_battle = null
	client.sign_out_local()
	adapter.forget_view()
	_busy = false
	_view_epoch += 1
	_retry_generation += 1
	_confirming_abandon = false
	_show_signed_out()


func is_busy() -> bool:
	return _busy


func get_status_text() -> String:
	return _status_label.text


func get_progression_text() -> String:
	return _progression_label.text


func get_pending_text() -> String:
	return _pending_label.text


func get_panel_button(button_name: String) -> Button:
	return _buttons.get(button_name)


func get_battle() -> CombatBattle:
	return _battle


# --- Answers ---------------------------------------------------------------------

func _after_answer(result: Dictionary) -> void:
	var handling: String = result.get("handling", OnlineCombatAdapter.FINAL)
	match handling:
		OnlineCombatAdapter.CONFIRMED:
			_retry_index = 0
			var r: Dictionary = result["receipt"]
			if r["kind"] == "abandon":
				_set_status(ABANDONED_TEXT)
			else:
				_set_status((REPLAYED_TEXT if result["replayed"] else CONFIRMED_TEXT) % [int(r["exp_awarded"]), int(r["level_before"]), int(r["level_after"])])
		OnlineCombatAdapter.KEEP:
			_set_status(_text_for(result))
			_schedule_retry()
		OnlineCombatAdapter.SUPERSEDED:
			_set_status(SUPERSEDED_TEXT)
		_:
			_retry_index = 0
			_set_status(_text_for(result))
			if result.get("reason", "") == "ticket_already_claimed":
				refresh.call_deferred()
	_render()


func _text_for(result: Dictionary) -> String:
	var reason := String(result.get("reason", ""))
	if result.get("status") == OnlineProgressClient.UNCERTAIN:
		return UNCERTAIN_TEXT
	if reason == "too_early":
		return TOO_EARLY_TEXT
	if reason in ["rate_limited", "rate_limit_contention", "conflict_retry_exhausted"]:
		return RATE_LIMITED_TEXT
	if reason == OnlineProgressClient.SUPERSEDED_REASON:
		return SUPERSEDED_TEXT
	return FINAL_TEXTS.get(reason, "伺服器拒絕：%s" % reason)


func _schedule_retry() -> void:
	if not auto_retry or not is_inside_tree():
		return
	var delay: float = RETRY_DELAYS[mini(_retry_index, RETRY_DELAYS.size() - 1)]
	_retry_index += 1
	_retry_generation += 1
	var generation := _retry_generation
	await get_tree().create_timer(delay).timeout
	if generation == _retry_generation and adapter.has_pending() and not _busy and not client.is_gameplay_session_superseded():
		await resend()


func _on_battle_exit() -> void:
	await submit_battle()


func _on_superseded() -> void:
	_set_status(SUPERSEDED_TEXT)
	_render()


# --- View ------------------------------------------------------------------------

func _render() -> void:
	var p := adapter.get_confirmed_progression()
	if p.is_empty():
		_progression_label.text = PROGRESSION_UNKNOWN_TEXT
	elif int(p["level"]) >= ProgressionState.MAX_LEVEL:
		_progression_label.text = PROGRESSION_MAX_TEXT % int(p["level"])
	else:
		_progression_label.text = PROGRESSION_TEXT % [int(p["level"]), int(p["exp"]), int(p["exp_to_next"])]
	var pending := adapter.get_pending()
	_pending_label.text = NO_PENDING_TEXT if pending.is_empty() else PENDING_TEXT % ("放棄上一場" if pending["kind"] == "abandon" else "戰鬥結果")
	var signed_in := client.is_signed_in()
	var session := not client.get_gameplay_session_id().is_empty()
	var superseded := client.is_gameplay_session_superseded()
	var fighting := _battle != null
	var unresolved := not adapter.get_unresolved_ticket().is_empty()
	# The battlefield uses the whole screen; the panel returns for the result.
	_panel.visible = not fighting
	_buttons["SignIn"].disabled = _busy
	_buttons["Begin"].visible = not session
	_buttons["Begin"].disabled = _busy or not signed_in
	_buttons["Reclaim"].visible = superseded
	_buttons["Reclaim"].disabled = _busy
	_buttons["Refresh"].disabled = _busy or not session or superseded or fighting
	_buttons["Resend"].disabled = _busy or not session or superseded or pending.is_empty()
	_buttons["Abandon"].visible = unresolved and not fighting
	_buttons["Abandon"].text = "確認放棄（不計經驗）" if _confirming_abandon else "放棄上一場"
	_buttons["Abandon"].disabled = _busy or superseded
	for i in GROUP_CHOICES.size():
		_buttons["Fight%d" % (i + 1)].disabled = _busy or not session or superseded or fighting or unresolved or not pending.is_empty()


func _set_status(text: String) -> void:
	_status_label.text = text


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
	return {"status": OnlineProgressClient.REJECTED, "reason": "busy", "handling": OnlineCombatAdapter.FINAL}


func _show_signed_out() -> void:
	_login_box.visible = true
	_session_box.visible = false
	_account_label.text = SIGNED_OUT_TEXT
	_status_label.text = ""
	# Disposable local test account: random, no clock needed (TimeSource rule).
	_email_edit.text = "combat-%s@myrial.test" % OnlineProgressClient.new_idempotency_key().substr(0, 16)
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
	var root := VBoxContainer.new()
	root.name = "Box"
	root.add_theme_constant_override("separation", 4)
	box.add_child(root)
	root.add_child(_label("Banner", BANNER_TEXT, 16))
	_account_label = _label("AccountLabel", SIGNED_OUT_TEXT, 15)
	root.add_child(_account_label)
	_login_box = VBoxContainer.new()
	_login_box.name = "LoginBox"
	root.add_child(_login_box)
	_email_edit = LineEdit.new()
	_email_edit.name = "EmailEdit"
	_login_box.add_child(_email_edit)
	_password_edit = LineEdit.new()
	_password_edit.name = "PasswordEdit"
	_password_edit.secret = true
	_login_box.add_child(_password_edit)
	_login_box.add_child(_button("SignIn", "登入本機測試帳號", func(): sign_in(_email_edit.text, _password_edit.text)))
	_session_box = VBoxContainer.new()
	_session_box.name = "SessionBox"
	root.add_child(_session_box)
	_progression_label = _label("ProgressionLabel", PROGRESSION_UNKNOWN_TEXT, 20)
	_session_box.add_child(_progression_label)
	_pending_label = _label("PendingLabel", NO_PENDING_TEXT, 15)
	_session_box.add_child(_pending_label)
	var row := HBoxContainer.new()
	row.name = "ActionRow"
	row.add_theme_constant_override("separation", 6)
	row.add_child(_button("Begin", "開始遊戲 Session", func(): begin_session()))
	row.add_child(_button("Reclaim", "重新接管", func(): reclaim_session()))
	row.add_child(_button("Refresh", "重新讀取", func(): refresh()))
	row.add_child(_button("Resend", "重新提交", func(): resend()))
	row.add_child(_button("Abandon", "放棄上一場", func(): abandon_unresolved()))
	_session_box.add_child(row)
	var fights := HBoxContainer.new()
	fights.name = "FightRow"
	fights.add_theme_constant_override("separation", 6)
	for i in GROUP_CHOICES.size():
		fights.add_child(_button("Fight%d" % (i + 1), ["戰鬥：敵群 1", "戰鬥：敵群 2+3", "戰鬥：全部敵群"][i], start_battle.bind(i)))
	_session_box.add_child(fights)
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


## `-- --online-host <host> --online-port <port>` (local hosts only).
func _read_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--online-host":
			host = args[i + 1]
		elif args[i] == "--online-port":
			port = int(args[i + 1])
