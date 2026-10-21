extends SceneTree

## VS-01 WP01-F — deterministic checks of the Online Progress Resume TEST mode
## (scenes/online_progress_resume_test_mode.tscn). Needs no server: a gated
## test client answers each RPC with a scripted result and records what was
## sent. Covers: nothing shown as confirmed before the server answers; Trade
## and Hero values with their OWN revisions; partial / unanswered reads keep
## the last confirmed values and never say "confirmed"; a late answer after a
## sign-out or an account switch never reaches the screen; an older revision
## never replaces a newer one; takeover (policy A) and reclaim; the same
## account signing in again reads from the server; a sign-out while the
## sign-in is in flight undoes a late success. Part of the normal Godot
## regression; the live run is tests/live_vs01_wp01f_online_progress_resume.gd.

const SCENE := "res://scenes/online_progress_resume_test_mode.tscn"
const OK := OnlineProgressClient.OK
const UNCERTAIN := OnlineProgressClient.UNCERTAIN
const REJECTED := OnlineProgressClient.REJECTED
const REP := OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID
const Mode := preload("res://scripts/online_progress_resume_test_mode.gd")
## C5: upper bound for every wait in this test, in frames (no clock). Each
## wait is for in-process work that finishes within a few frames; a wait that
## reaches the bound is reported as an explicit FAILED line, never a PASS.
const WAIT_FRAMES := 600

var _checks := 0
var _failures := 0


class GatedClient extends OnlineProgressClient:
	var answers: Array = []
	var sent: Array = []
	var held: Array = []
	## When true, the next sign-in waits until release_sign_in().
	var hold_sign_in := false
	var _sign_in_released := false
	## C5: how many holds gave up at WAIT_FRAMES (each scenario checks it is 0).
	var hold_timeouts := 0

	func release_sign_in() -> void:
		_sign_in_released = true

	func is_signed_in() -> bool:
		return _session != null

	func sign_in_email_test(email: String, _password: String, _create: bool = true) -> Dictionary:
		if hold_sign_in:
			hold_sign_in = false
			var frames := 0
			while not _sign_in_released and frames < WAIT_FRAMES:
				await Engine.get_main_loop().process_frame
				frames += 1
			if not _sign_in_released:
				hold_timeouts += 1
				return {"status": UNCERTAIN, "reason": "gated_sign_in_hold_timed_out"}
			_sign_in_released = false
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
			var frames := 0
			while held.is_empty() and frames < WAIT_FRAMES:
				await Engine.get_main_loop().process_frame
				frames += 1
			if held.is_empty():
				hold_timeouts += 1
				return {"status": UNCERTAIN, "reason": "gated_rpc_hold_timed_out"}
			return held.pop_front()
		return a


func _initialize() -> void:
	await process_frame
	var dev_before := _dev_save_fingerprint()
	print("Isolated user:// for this run: %s" % OS.get_user_data_dir())
	_verify_static()
	await _verify_confirmed_only()
	await _verify_partial_and_unanswered()
	await _verify_late_answer_after_sign_out()
	await _verify_account_switch()
	await _verify_revision_never_goes_back()
	await _verify_takeover_and_reclaim()
	await _verify_same_account_again()
	await _verify_sign_out_during_sign_in()
	_check(_dev_save_fingerprint() == dev_before, "Development Save (%s) is untouched" % SaveStore.DEFAULT_PATH)
	_check(not FileAccess.file_exists(SaveStore.DEFAULT_PATH), "The Resume TEST mode created no local save file")
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-F resume mode verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_static() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/online_progress_resume_test_mode.gd")
	for forbidden in ["SaveStore", "user://", "FileAccess", "main.gd", "TradeService", "Time.", "rpc_async", ".buy(", ".sell(", "submit_battle", "add_exp("]:
		_check(not source.contains(forbidden), "Resume mode only reads: never saves locally, trades, settles EXP, calls RPCs directly or reads the clock (%s)" % forbidden)
	_check(source.contains("OnlineTradeAdapter.new(client)") and source.contains("OnlineCombatAdapter.new(client)"), "Resume mode reuses the existing adapters on ONE shared client")
	var project := FileAccess.get_file_as_string("res://project.godot")
	_check(project.contains('run/main_scene="res://scenes/main.tscn"') and not project.contains("online_progress_resume"), "The game still starts in the offline main scene; the Resume TEST mode is not an autoload")


# --- Scenarios -------------------------------------------------------------------

func _verify_confirmed_only() -> void:
	print("== R1 nothing confirmed before the server answers; separate revisions")
	var c := GatedClient.new()
	var mode := await _new_mode(c)
	_check(mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT and mode.get_hero_text() == Mode.HERO_UNKNOWN_TEXT, "Fresh screen: nothing shown as server data")
	_check(mode.get_snapshot().keys() == ["user_id"], "Fresh screen: no confirmed value held")
	await mode.sign_in("r1@myrial.test", "x", false)
	_check(mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT and mode.get_status_text() != Mode.CONFIRMED_TEXT, "Signed in only: still nothing confirmed")
	c.answer(_begin_answer(9160, 10, 7))
	c.answer(_hero_answer(2, 0, 150, 1))
	var r := await mode.begin_session()
	_check(r["status"] == OK and mode.get_status_text() == Mode.CONFIRMED_TEXT, "Begin + Hero read both answered: confirmed")
	_check(mode.get_trade_text() == Mode.TRADE_TEXT % [9160, 10, 7], "Trade from the server with the TRADE revision (%s)" % mode.get_trade_text())
	_check(mode.get_hero_text() == Mode.HERO_TEXT % [2, 0, 150, 1], "Hero from the server with its OWN revision (%s)" % mode.get_hero_text())
	var snap := mode.get_snapshot()
	_check(snap["trade_revision"] == 7 and snap["hero_revision"] == 1, "Snapshot keeps the two revisions apart (7 / 1)")
	_check(c.sent.map(func(s): return s["id"]) == ["vs01_session_begin", "vs01e_progression_get"], "Only existing read contracts were called (%s)" % str(c.sent.map(func(s): return s["id"])))
	await _free(mode)


func _verify_partial_and_unanswered() -> void:
	print("== R2 partial and unanswered reads")
	var c := GatedClient.new()
	var mode := await _new_mode(c)
	await mode.sign_in("r2@myrial.test", "x", false)
	c.answer(_begin_answer(10000, 0, 1))
	c.answer({"status": UNCERTAIN, "reason": "Request timed out"})
	var r := await mode.begin_session()
	_check(r["status"] != OK and mode.get_status_text() == Mode.PARTIAL_TRADE_TEXT, "Hero read unanswered: only Trade confirmed (%s)" % mode.get_status_text())
	_check(mode.get_hero_text() == Mode.HERO_UNKNOWN_TEXT, "Unanswered Hero read shows no Hero value")
	c.answer(_progress_answer(10000, 0, 1))
	c.answer(_hero_answer(1, 0, 100, 0))
	await mode.refresh_all()
	_check(mode.get_status_text() == Mode.CONFIRMED_TEXT, "A later full read confirms both")
	c.answer({"status": UNCERTAIN, "reason": "Request timed out"})
	c.answer({"status": UNCERTAIN, "reason": "Request timed out"})
	var lost := await mode.refresh_all()
	_check(lost["status"] == UNCERTAIN and mode.get_status_text() == Mode.UNCERTAIN_TEXT, "Both reads unanswered: uncertain, never 'confirmed'")
	_check(mode.get_trade_text() == Mode.TRADE_TEXT % [10000, 0, 1] and mode.get_hero_text() == Mode.HERO_TEXT % [1, 0, 100, 0], "Unanswered reads keep the last server-confirmed values")
	c.answer({"status": UNCERTAIN, "reason": "Request timed out"})
	c.answer(_hero_answer(1, 0, 100, 0))
	await mode.refresh_all()
	_check(mode.get_status_text() == Mode.PARTIAL_HERO_TEXT, "Trade unanswered, Hero answered: says so (%s)" % mode.get_status_text())
	await _free(mode)


func _verify_late_answer_after_sign_out() -> void:
	print("== R3 a late answer after sign-out never reaches the screen")
	var c := GatedClient.new()
	var mode := await _new_mode(c)
	await mode.sign_in("r3@myrial.test", "x", false)
	c.answer(_begin_answer(500, 3, 4))
	c.answer(_hero_answer(3, 10, 200, 2))
	await mode.begin_session()
	c.hold_next()
	var out := []
	_start_refresh(mode, out)
	await process_frame
	_check(mode.is_busy(), "A read is in flight")
	mode.sign_out()
	_check(not mode.is_busy() and mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT and mode.get_hero_text() == Mode.HERO_UNKNOWN_TEXT, "Sign-out clears the screen even while a read is in flight")
	c.release_held(_progress_answer(999999, 99, 50))
	_check(await _wait_for(out, "R3 the late refresh_all() answer"), "R3 the late answer arrived within %d frames" % WAIT_FRAMES)
	await process_frame
	var late: Dictionary = out[0] if not out.is_empty() else {}
	_check(late.get("stale", false), "The late answer is reported as stale")
	_check(mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT and mode.get_snapshot().keys() == ["user_id"], "The late answer did not reach the screen or the snapshot")
	_check(mode.get_account_text() == Mode.SIGNED_OUT_TEXT, "Still signed out")
	_check(c.hold_timeouts == 0, "R3 the held answer was released by the test, not given up at %d frames" % WAIT_FRAMES)
	await _free(mode)


func _verify_account_switch() -> void:
	print("== R4 account switch on one client")
	var c := GatedClient.new()
	var mode := await _new_mode(c)
	await mode.sign_in("r4a@myrial.test", "x", false)
	c.answer(_begin_answer(1234, 5, 6))
	c.answer(_hero_answer(4, 1, 250, 3))
	await mode.begin_session()
	var first_user: String = mode.get_snapshot()["user_id"]
	await mode.sign_in("r4b@myrial.test", "x", false)
	_check(mode.get_snapshot()["user_id"] != first_user, "Another account is signed in")
	_check(mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT and mode.get_hero_text() == Mode.HERO_UNKNOWN_TEXT, "Switching account shows none of the first account's values")
	c.answer(_begin_answer(10000, 0, 1))
	c.answer(_hero_answer(1, 0, 100, 0))
	await mode.begin_session()
	_check(mode.get_trade_text() == Mode.TRADE_TEXT % [10000, 0, 1] and mode.get_hero_text() == Mode.HERO_TEXT % [1, 0, 100, 0], "Second account shows only its own server values")
	await _free(mode)


func _verify_revision_never_goes_back() -> void:
	print("== R5 an older revision never replaces a newer one")
	var c := GatedClient.new()
	var mode := await _new_mode(c)
	await mode.sign_in("r5@myrial.test", "x", false)
	c.answer(_begin_answer(800, 2, 9))
	c.answer(_hero_answer(2, 30, 150, 4))
	await mode.begin_session()
	c.answer(_progress_answer(900, 1, 8))
	c.answer(_hero_answer(2, 10, 150, 3))
	await mode.refresh_all()
	_check(mode.get_trade_text() == Mode.TRADE_TEXT % [800, 2, 9], "Trade stays at revision 9, not the older 8")
	_check(mode.get_hero_text() == Mode.HERO_TEXT % [2, 30, 150, 4], "Hero stays at revision 4, not the older 3")
	await _free(mode)


func _verify_takeover_and_reclaim() -> void:
	print("== R6 takeover (policy A) and reclaim")
	var c := GatedClient.new()
	var mode := await _new_mode(c)
	await mode.sign_in("r6@myrial.test", "x", false)
	c.answer(_begin_answer(700, 1, 3))
	c.answer(_hero_answer(1, 50, 100, 1))
	await mode.begin_session()
	c.answer({"status": REJECTED, "reason": OnlineProgressClient.SUPERSEDED_REASON, "grpc_status": 10})
	var r := await mode.refresh_all()
	_check(mode.get_status_text() == Mode.SUPERSEDED_TEXT and mode.get_panel_button("Reclaim").visible, "Taken over: says so and offers reclaim")
	_check(r["hero"].is_empty(), "Taken over: the Hero read is not attempted")
	_check(mode.get_trade_text() == Mode.TRADE_TEXT % [700, 1, 3], "Taken over: nothing new is shown")
	var sent_before := c.sent.size()
	await mode.refresh_all()
	_check(c.sent.size() == sent_before, "Taken over: refresh sends nothing")
	c.answer(_begin_answer(700, 1, 5))
	c.answer(_hero_answer(1, 50, 100, 1))
	await mode.reclaim_session()
	_check(mode.get_status_text() == Mode.CONFIRMED_TEXT and not mode.get_panel_button("Reclaim").visible, "Reclaim: confirmed again")
	_check(mode.get_trade_text() == Mode.TRADE_TEXT % [700, 1, 5], "Reclaim: the newer Trade revision from the server")
	await _free(mode)


func _verify_same_account_again() -> void:
	print("== R7 the same account signs in again and reads from the server")
	var c := GatedClient.new()
	var mode := await _new_mode(c)
	await mode.sign_in("r7@myrial.test", "x", false)
	c.answer(_begin_answer(4321, 7, 2))
	c.answer(_hero_answer(3, 5, 200, 2))
	await mode.begin_session()
	mode.sign_out()
	_check(mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT, "Signed out: nothing shown")
	await mode.sign_in("r7@myrial.test", "x", false)
	_check(mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT and mode.get_hero_text() == Mode.HERO_UNKNOWN_TEXT, "Signed in again: nothing shown before the server answers")
	c.answer(_begin_answer(4321, 7, 3))
	c.answer(_hero_answer(3, 5, 200, 2))
	await mode.begin_session()
	_check(mode.get_trade_text() == Mode.TRADE_TEXT % [4321, 7, 3] and mode.get_hero_text() == Mode.HERO_TEXT % [3, 5, 200, 2], "Same account: the same values read back from the server")
	await _free(mode)


func _verify_sign_out_during_sign_in() -> void:
	print("== R8 sign-out while the sign-in is still in flight")
	var c := GatedClient.new()
	var mode := await _new_mode(c)
	c.hold_sign_in = true
	var out := []
	_start_sign_in(mode, "r8@myrial.test", out)
	await process_frame
	_check(mode.is_busy(), "A sign-in is in flight")
	mode.sign_out()
	_check((await mode.sign_in("r8-other@myrial.test", "x", false))["reason"] == "busy", "A second sign-in waits for the first one's answer (no overlap)")
	c.release_sign_in()
	_check(await _wait_for(out, "R8 the late sign_in() answer"), "R8 the late sign-in answer arrived within %d frames" % WAIT_FRAMES)
	await process_frame
	var late: Dictionary = out[0] if not out.is_empty() else {}
	_check(late.get("stale", false) and late.get("original_status") == OK, "The late sign-in answer is reported as stale")
	_check(not c.is_signed_in() and mode.get_account_text() == Mode.SIGNED_OUT_TEXT, "The late success is undone: still signed out")
	_check(c.sent.is_empty() and mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT, "Nothing was read or shown for the late sign-in")
	_check((await mode.sign_in("r8@myrial.test", "x", false))["status"] == OK, "A new sign-in works afterwards")
	_check(c.hold_timeouts == 0, "R8 the held sign-in was released by the test, not given up at %d frames" % WAIT_FRAMES)
	await _free(mode)


# --- Helpers ---------------------------------------------------------------------

func _new_mode(client: GatedClient) -> OnlineProgressResumeTestMode:
	var mode: OnlineProgressResumeTestMode = (load(SCENE) as PackedScene).instantiate()
	mode.client_override = client
	root.add_child(mode)
	await process_frame
	return mode


func _free(mode: Node) -> void:
	mode.queue_free()
	await process_frame


## C5: waits until `out` holds a result, at most WAIT_FRAMES frames. False
## (with the reason printed) if it never came; the caller turns that into a
## FAILED check and reads `out` only when it is not empty.
func _wait_for(out: Array, what: String) -> bool:
	var frames := 0
	while out.is_empty() and frames < WAIT_FRAMES:
		await process_frame
		frames += 1
	if out.is_empty():
		print("   wait gave up after %d frames: %s never completed" % [WAIT_FRAMES, what])
		return false
	return true


func _start_sign_in(mode: OnlineProgressResumeTestMode, email: String, out: Array) -> void:
	out.append(await mode.sign_in(email, "x", false))


func _start_refresh(mode: OnlineProgressResumeTestMode, out: Array) -> void:
	out.append(await mode.refresh_all())


static func _view(money: int, goods: int, revision: int) -> Dictionary:
	return {"revision": revision, "money": money, "backpack": {REP: goods} if goods > 0 else {}, "quotes": {}}


static func _begin_answer(money: int, goods: int, revision: int) -> Dictionary:
	return {"status": OK, "reason": "", "data": {"gameplay_session_id": "gs-%d" % revision, "progress": _view(money, goods, revision)}}


static func _progress_answer(money: int, goods: int, revision: int) -> Dictionary:
	return {"status": OK, "reason": "", "data": {"progress": _view(money, goods, revision)}}


static func _hero_answer(level: int, exp: int, exp_to_next: int, revision: int) -> Dictionary:
	return {"status": OK, "reason": "", "data": {"progression": {"level": level, "exp": exp, "exp_to_next": exp_to_next, "revision": revision},
		"unresolved_ticket": null, "server_time_ms": 0}}


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
