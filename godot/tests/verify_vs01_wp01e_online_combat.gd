extends SceneTree

## VS-01 WP01-E E2 — deterministic checks of the Online Combat TEST mode
## (scenes/online_combat_test_mode.tscn + OnlineCombatAdapter). Needs no
## server: a gated test client answers each RPC with a scripted result and
## records what was sent. Covers: EXP shown only when the server confirms,
## pending kept with the SAME key and payload for every transient / uncertain
## answer, superseded -> reclaim -> resend, final refusals, receipt replay,
## explicit abandon, app-kill recovery, sign-out isolation. Part of the normal
## Godot regression; the live run is tests/live_vs01_wp01e_online_combat.gd.

const SCENE := "res://scenes/online_combat_test_mode.tscn"
const OK := OnlineProgressClient.OK
const UNCERTAIN := OnlineProgressClient.UNCERTAIN
const REJECTED := OnlineProgressClient.REJECTED
const TICKET := "0123456789abcdef0123456789abcdef"

var _checks := 0
var _failures := 0


class GatedClient extends OnlineProgressClient:
	var answers: Array = []
	var sent: Array = []
	var held: Array = []

	func is_signed_in() -> bool:
		return _session != null

	func sign_in_email_test(email: String, _password: String, _create: bool = true) -> Dictionary:
		var header := Marshalls.utf8_to_base64(JSON.stringify({"alg": "none"})).trim_suffix("=").trim_suffix("=")
		var body := Marshalls.utf8_to_base64(JSON.stringify({"uid": "ui-" + email, "usn": email, "exp": 4102444800})).trim_suffix("=").trim_suffix("=")
		return _accept_session(NakamaSession.new("%s.%s.x" % [header, body], false))

	func answer(result: Dictionary) -> void:
		answers.append(result)

	## The next RPC waits until release_held() (to answer after a sign-out).
	func hold_next() -> void:
		answers.append({"__hold": true})

	func release_held(result: Dictionary) -> void:
		held.append(result)

	func _rpc(id: String, payload: Dictionary) -> Dictionary:
		sent.append({"id": id, "payload": payload.duplicate(true)})
		if answers.is_empty():
			return {"status": UNCERTAIN, "reason": "no scripted answer"}
		var a: Dictionary = answers.pop_front()
		if a.has("__hold"):
			while held.is_empty():
				await Engine.get_main_loop().process_frame
			return held.pop_front()
		return a


func _initialize() -> void:
	await process_frame
	var dev_before := _dev_save_fingerprint()
	print("Isolated user:// for this run: %s" % OS.get_user_data_dir())
	_verify_static()
	await _verify_flow()
	await _verify_app_kill_recovery()
	await _verify_sign_out_isolation()
	_check(_dev_save_fingerprint() == dev_before, "Development Save (%s) is untouched" % SaveStore.DEFAULT_PATH)
	_check(not FileAccess.file_exists(SaveStore.DEFAULT_PATH), "The Online Combat TEST mode created no local save file")
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-E online combat verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_static() -> void:
	for path in ["res://scripts/online_combat_test_mode.gd", "res://scripts/online_combat_adapter.gd"]:
		var source := FileAccess.get_file_as_string(path)
		for forbidden in ["SaveStore", "user://", "FileAccess", "main.gd", "TradeService", "PartyProgression.apply", ".award(", "add_exp(", "Time."]:
			_check(not source.contains(forbidden), "%s never saves locally, settles EXP itself or reads the clock directly (%s)" % [path.get_file(), forbidden])
	var mode_source := FileAccess.get_file_as_string("res://scripts/online_combat_test_mode.gd")
	_check(mode_source.contains("combat_view.progression = null"), "The battle result screen gets no progression: no local EXP preview")
	var project := FileAccess.get_file_as_string("res://project.godot")
	_check(project.contains('run/main_scene="res://scenes/main.tscn"') and not project.contains("online_combat"), "The game still starts in the offline main scene; the TEST mode is not an autoload")


func _new_mode(client: GatedClient) -> OnlineCombatTestMode:
	var mode: OnlineCombatTestMode = (load(SCENE) as PackedScene).instantiate()
	mode.client_override = client
	mode.auto_retry = false
	root.add_child(mode)
	await process_frame
	return mode


func _verify_flow() -> void:
	var client := GatedClient.new()
	var mode := await _new_mode(client)
	_check(mode.get_progression_text() == OnlineCombatTestMode.PROGRESSION_UNKNOWN_TEXT, "Start: no progression shown before the server answers")
	await mode.sign_in(mode._email_edit.text, mode._password_edit.text)
	client.answer(_session_answer("00000000-0000-0000-0000-000000000001", 1))
	client.answer(_ok({"progression": _prog(1, 0, 0), "unresolved_ticket": null, "group_available_at_ms": {}, "server_time_ms": 1}))
	await mode.begin_session()
	_check(mode.get_progression_text() == "主角 Lv 1　經驗 0 / 100（伺服器確認）", "Server progression shown after the session begins (%s)" % mode.get_progression_text())

	# A Hero-only battle of the server ticket's size.
	client.answer(_ok({"ticket": _ticket(10), "progression": _prog(1, 0, 0)}))
	await mode.start_battle(0)
	var battle := mode.get_battle()
	_check(battle != null and battle.get_friends().size() == 1 and battle.get_enemies().size() == 10, "Hero-only battle with the ticket's 10 enemies")
	_check(battle.get_hero().max_hp == CharacterStats.for_character("hero").get_effective("hp"), "Hero uses Base + Growth at the server Level (no allocation)")
	_check(mode.combat_view.progression == null and mode.combat_view.get_award_preview().is_empty(), "No EXP preview on the battle screen")
	_win(battle)
	_check(mode.combat_view.get_victory_lines().is_empty() and mode.combat_view.get_reward_text() == "", "Victory screen shows no EXP before the server confirms")

	# too_early: kept, nothing shown as earned.
	client.answer(_refused("too_early", 9))
	mode.combat_view.exit_requested.emit()
	await _until_idle(mode)
	var first: Dictionary = client.sent[-1]
	_check(first["id"] == OnlineCombatAdapter.RPC_CLAIM and first["payload"]["outcome"] == "victory" and int(first["payload"]["kills"]) == 10 and first["payload"]["hero_alive"] == true, "The claim carries only {outcome, kills, hero_alive} for the ticket (%s)" % str(first["payload"]))
	_check(not first["payload"].has("exp") and not first["payload"].has("level"), "No client EXP / Level is sent")
	_check(mode.get_status_text() == OnlineCombatTestMode.TOO_EARLY_TEXT and mode.adapter.has_pending(), "too_early: told, result kept")
	_check(mode.get_progression_text() == "主角 Lv 1　經驗 0 / 100（伺服器確認）", "too_early: no EXP shown")

	# Every transient / uncertain answer keeps the SAME key and payload.
	for answer in [_refused("rate_limited", 8), _refused("rate_limit_contention", 8), _refused("conflict_retry_exhausted", 10),
			{"status": UNCERTAIN, "reason": "HTTPRequest failed"}, _refused("storage_unavailable", 14)]:
		client.answer(answer)
		await mode.resend()
		var again: Dictionary = client.sent[-1]
		_check(again["payload"]["idempotency_key"] == first["payload"]["idempotency_key"] and again["payload"] == first["payload"],
			"%s: resent with the same key and payload" % answer["reason"])
		_check(mode.adapter.has_pending() and mode.get_progression_text().contains("Lv 1　經驗 0"), "%s: kept, no EXP shown" % answer["reason"])
	_check(mode.get_status_text() == OnlineCombatTestMode.UNCERTAIN_TEXT, "storage_unavailable is shown as uncertain (may or may not have applied)")

	# Superseded: kept; reclaim resends the same key; the server confirms.
	client.answer(_refused(OnlineProgressClient.SUPERSEDED_REASON, 10))
	await mode.resend()
	_check(mode.get_status_text() == OnlineCombatTestMode.SUPERSEDED_TEXT and mode.get_panel_button("Reclaim").visible and mode.adapter.has_pending(), "Superseded: told, reclaim offered, result kept")
	var sent_before := client.sent.size()
	await mode.resend()
	_check(client.sent.size() == sent_before, "Superseded device sends nothing (policy A)")
	client.answer(_session_answer("00000000-0000-0000-0000-000000000002", 3))
	client.answer(_ok({"progression": _prog(1, 0, 0), "unresolved_ticket": _ticket(10), "group_available_at_ms": {}, "server_time_ms": 2}))
	client.answer(_ok({"replayed": false, "receipt": _receipt("claim", 100, 1, 2), "progression": _prog(2, 0, 1)}))
	await mode.reclaim_session()
	var resent: Dictionary = client.sent[-1]
	_check(resent["payload"]["idempotency_key"] == first["payload"]["idempotency_key"] and resent["payload"]["gameplay_session_id"] == "00000000-0000-0000-0000-000000000002", "After reclaim the same key is resent from the NEW session")
	_check(mode.get_status_text() == OnlineCombatTestMode.CONFIRMED_TEXT % [100, 1, 2] and not mode.adapter.has_pending(), "Confirmed: EXP +100, Lv 1 -> 2, nothing pending")
	_check(mode.get_progression_text() == "主角 Lv 2　經驗 0 / 150（伺服器確認）", "Level 2 shown only now (%s)" % mode.get_progression_text())

	# A replay of an older confirmation never adds EXP twice; an older revision never wins.
	mode.adapter._set_pending({"kind": "claim", "key": first["payload"]["idempotency_key"], "ticket_id": TICKET, "payload": first["payload"]})
	client.answer(_ok({"replayed": true, "receipt": _receipt("claim", 100, 1, 2), "progression": _prog(2, 0, 1)}))
	await mode.resend()
	_check(mode.get_status_text() == OnlineCombatTestMode.REPLAYED_TEXT % [100, 1, 2], "Replay shown as already confirmed")
	_check(mode.adapter.get_confirmed_progression()["revision"] == 1 and mode.get_progression_text() == "主角 Lv 2　經驗 0 / 150（伺服器確認）", "Replay adds no EXP")
	mode.adapter._offer(_prog(1, 50, 0))
	_check(mode.adapter.get_confirmed_progression()["level"] == 2, "An older server revision never replaces a newer one")

	# Final refusals drop the pending result, with a clear message.
	for reason in ["ticket_expired", "claim_locked", "ticket_already_claimed", "ticket_abandoned", "invalid_claim"]:
		mode.adapter._set_pending({"kind": "claim", "key": OnlineProgressClient.new_idempotency_key(), "ticket_id": TICKET, "payload": first["payload"]})
		client.answer(_refused(reason, 9))
		if reason == "ticket_already_claimed":
			client.answer(_ok({"progression": _prog(2, 0, 1), "unresolved_ticket": null, "group_available_at_ms": {}, "server_time_ms": 3}))
		await mode.resend()
		await _until_idle(mode)
		_check(not mode.adapter.has_pending() and mode.get_status_text() == OnlineCombatTestMode.FINAL_TEXTS[reason], "%s: final, pending dropped, told" % reason)

	# ticket_unsettled on a new battle -> the unresolved ticket -> explicit abandon in two steps.
	client.answer(_refused("ticket_unsettled", 9))
	client.answer(_ok({"progression": _prog(2, 0, 1), "unresolved_ticket": _ticket(10), "group_available_at_ms": {}, "server_time_ms": 4}))
	await mode.start_battle(0)
	await _until_idle(mode)
	_check(mode.get_battle() == null and mode.get_panel_button("Abandon").visible and mode.get_panel_button("Fight1").disabled, "ticket_unsettled: no battle, abandon offered, new battles blocked")
	var sent_abandon := client.sent.size()
	await mode.abandon_unresolved()
	_check(client.sent.size() == sent_abandon and mode.get_status_text() == OnlineCombatTestMode.CONFIRM_ABANDON_TEXT, "Abandon needs a second, explicit confirmation")
	client.answer({"status": UNCERTAIN, "reason": "timeout"})
	await mode.abandon_unresolved()
	var ab1: Dictionary = client.sent[-1]
	_check(ab1["id"] == OnlineCombatAdapter.RPC_ABANDON and ab1["payload"]["confirm"] == true and mode.adapter.has_pending(), "Uncertain abandon is kept")
	client.answer(_ok({"replayed": false, "receipt": _receipt("abandon", 0, 2, 2), "progression": _prog(2, 0, 1)}))
	await mode.resend()
	_check(client.sent[-1]["payload"]["idempotency_key"] == ab1["payload"]["idempotency_key"], "Abandon resent with its own same key")
	_check(mode.get_status_text() == OnlineCombatTestMode.ABANDONED_TEXT and not mode.get_panel_button("Fight1").disabled, "Abandoned: new battles allowed; Level unchanged")
	_check(mode.get_progression_text() == "主角 Lv 2　經驗 0 / 150（伺服器確認）", "Abandon changes no confirmed progression")
	mode.queue_free()
	await process_frame


## App killed with a result in RAM: a fresh process shows only the server
## progression and offers explicit abandon for the result it cannot resend.
func _verify_app_kill_recovery() -> void:
	var client := GatedClient.new()
	var mode := await _new_mode(client)
	await mode.sign_in("killed@myrial.test", "localtest-x")
	client.answer(_session_answer("00000000-0000-0000-0000-000000000009", 9))
	client.answer(_ok({"progression": _prog(3, 40, 7), "unresolved_ticket": _ticket(15), "group_available_at_ms": {}, "server_time_ms": 9}))
	await mode.begin_session()
	_check(mode.get_progression_text() == "主角 Lv 3　經驗 40 / 200（伺服器確認）", "After restart: only the server-confirmed progression")
	_check(mode.get_status_text() == OnlineCombatTestMode.LOST_PENDING_TEXT and mode.get_panel_button("Abandon").visible, "Lost RAM result: told, explicit abandon offered")
	_check(not mode.adapter.has_pending() and mode.get_panel_button("Resend").disabled, "Nothing is resent automatically (no result in RAM)")
	mode.queue_free()
	await process_frame


## A claim answered after sign-out never lands in the new view and stays
## filed under its own account.
func _verify_sign_out_isolation() -> void:
	var client := GatedClient.new()
	var mode := await _new_mode(client)
	await mode.sign_in("first@myrial.test", "localtest-x")
	client.answer(_session_answer("00000000-0000-0000-0000-00000000000a", 1))
	client.answer(_ok({"progression": _prog(1, 0, 0), "unresolved_ticket": null, "group_available_at_ms": {}, "server_time_ms": 1}))
	await mode.begin_session()
	client.answer(_ok({"ticket": _ticket(10), "progression": _prog(1, 0, 0)}))
	await mode.start_battle(0)
	_win(mode.get_battle())
	client.hold_next()
	mode.combat_view.exit_requested.emit()
	await process_frame
	var first_user := client.get_user_id()
	mode.sign_out()
	await mode.sign_in("second@myrial.test", "localtest-y")
	client.release_held(_ok({"replayed": false, "receipt": _receipt("claim", 100, 1, 2), "progression": _prog(2, 0, 1)}))
	for i in 5:
		await process_frame
	_check(mode.get_progression_text() == OnlineCombatTestMode.PROGRESSION_UNKNOWN_TEXT, "The first account's answer is not shown to the second account")
	_check(not mode.adapter.has_pending(), "The second account has no pending result")
	_check(mode.adapter._pending_by_user.has(first_user), "The first account's result stays filed under that account")
	mode.queue_free()
	await process_frame


# --- Helpers -------------------------------------------------------------------------

func _win(battle: CombatBattle) -> void:
	battle.advance(CombatConfig.PREPARATION_MS)
	for enemy in battle.get_enemies():
		battle.resolve_damage(battle.get_hero(), enemy, 1000)


static func _ok(data: Dictionary) -> Dictionary:
	return {"status": OK, "reason": "", "data": data}


static func _refused(reason: String, grpc: int) -> Dictionary:
	return {"status": REJECTED, "reason": reason, "grpc_status": grpc}


static func _prog(level: int, exp: int, revision: int) -> Dictionary:
	return {"level": float(level), "exp": float(exp), "exp_to_next": float(ProgressionState.required_exp(level)), "revision": float(revision)}


static func _ticket(enemies: int) -> Dictionary:
	var groups := {10: ["prototype_monster_01"], 15: ["prototype_monster_01", "prototype_monster_02"]}[enemies] as Array
	return {"ticket_id": TICKET, "issued_at_ms": 1.0, "expires_at_ms": 900001.0, "min_claim_at_ms": 10001.0, "group_ids": groups,
		"enemy_count": float(enemies), "status": "OPEN", "intent_recorded": false}


static func _receipt(kind: String, exp: int, before: int, after: int) -> Dictionary:
	return {"kind": kind, "exp_awarded": float(exp), "level_before": float(before), "level_after": float(after), "ticket_id": TICKET}


static func _session_answer(gsid: String, revision: int) -> Dictionary:
	return {"status": OK, "reason": "", "data": {"gameplay_session_id": gsid, "progress": {"revision": float(revision)}}}


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
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
		print("FAILED: " + message)
