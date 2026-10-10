extends SceneTree

## VS-01 WP01-B — offline checks for OnlineTradeAdapter. Needs no server:
## part of the normal Godot regression. Live checks against the local Nakama
## server are in tests/live_vs01_wp01b_online_trade.gd.
##
## - The Godot mirror (Wallet / CharacterInventory) changes ONLY from a
##   server-confirmed view: never from a rejection, an uncertain outcome or a
##   superseded session, and is null before the first confirmation.
## - Only the one representative good is ever sent.
## - Results keep TradeService's shape and reason codes.
## - The adapter never prices, applies or saves anything itself.

const REP := OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID

var _checks := 0
var _failures := 0


## Test double: answers the client's RPCs from a script, counting calls.
class ScriptedClient extends OnlineProgressClient:
	var answers: Array = []
	var calls := 0

	func is_signed_in() -> bool:
		return true

	func _rpc(_id: String, _payload: Dictionary) -> Dictionary:
		calls += 1
		return answers.pop_front()


## Test double whose answers are held until the test releases them, so
## responses can complete in any order (PR #133 review: reversed completion).
class GatedClient extends OnlineProgressClient:
	var gates: Array = []

	func is_signed_in() -> bool:
		return true

	func queue(answer: Dictionary) -> void:
		gates.append({"answer": answer, "released": false, "taken": false})

	func release(index: int) -> void:
		gates[index]["released"] = true

	func _rpc(_id: String, _payload: Dictionary) -> Dictionary:
		var gate: Dictionary = {}
		for g in gates:
			if not g["taken"]:
				g["taken"] = true
				gate = g
				break
		while not gate["released"]:
			await Engine.get_main_loop().process_frame
		return gate["answer"]


static func _view_q(money: int, carried: int, revision: int, buy_price: int) -> Dictionary:
	var v := _view(money, carried, revision)
	v["quotes"]["A"][REP]["buy_price"] = buy_price
	return v


static func _view(money: int, carried: int, revision: int) -> Dictionary:
	var backpack := {}
	if carried > 0:
		backpack[REP] = carried
	return {"money": money, "backpack": backpack, "revision": revision,
		"quotes": {"A": {REP: {"buy_price": 84, "buyback_price": 76, "stock": 100}}}}


static func _receipt_answer(status: String, reason: String, total: int, unit: int, view: Dictionary, replayed := false) -> Dictionary:
	return {"status": OnlineProgressClient.OK, "reason": "", "data": {
		"replayed": replayed, "progress": view,
		"receipt": {"status": status, "reason": reason, "total": total, "unit_price": unit}}}


func _initialize() -> void:
	await process_frame
	var dev_before := _dev_save_fingerprint()
	print("Isolated user:// for this run: %s" % OS.get_user_data_dir())
	_verify_static()
	await _verify_mirror_only_from_confirmation()
	await _verify_scope_guard()
	await _verify_superseded_keeps_mirror()
	await _verify_inconsistent_view_is_flagged()
	await _verify_reversed_responses_never_roll_back()
	await _verify_equal_revision_tie_break()
	_check(_dev_save_fingerprint() == dev_before, "Development Save (%s) is untouched" % SaveStore.DEFAULT_PATH)
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-B online trade adapter verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_static() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/online_trade_adapter.gd")
	for forbidden in ["SaveStore", "user://", "FileAccess", "TradeService.", "MarketRules", "MarketState", "main.gd", "get_tree()", "Nakama.create"]:
		_check(not source.contains(forbidden), "Adapter does not price, apply, save or reach into the scene (%s)" % forbidden)
	_check(source.contains("OnlineProgressClient"), "Adapter reuses the WP01 client (no second account / trade system)")
	_check(REP == "test_good_01" and GoodsCatalog.has_good(REP), "Representative good is an existing Prototype good")
	var project := FileAccess.get_file_as_string("res://project.godot")
	_check(not project.contains("OnlineTradeAdapter") and not project.contains("online_trade"), "Adapter is not an autoload")
	for scene in ["res://scenes/main.tscn"]:
		_check(not FileAccess.get_file_as_string(scene).contains("online_"), "No scene uses the online layer (%s)" % scene)


func _verify_mirror_only_from_confirmation() -> void:
	var client := _new_client()
	var adapter := OnlineTradeAdapter.new(client)
	var revisions := []
	adapter.confirmed_state_changed.connect(func(r): revisions.append(r))
	_check(not adapter.has_confirmed_state() and adapter.get_wallet() == null and adapter.get_inventory() == null, "No mirror before the first server confirmation")

	client.answers = [{"status": OnlineProgressClient.OK, "reason": "", "data": {"gameplay_session_id": "00000000-0000-0000-0000-0000000000b1", "progress": _view(10000, 0, 1)}}]
	_check((await adapter.begin())["status"] == OnlineProgressClient.OK, "Session begin passes through")
	_check(adapter.get_wallet().get_balance() == 10000 and adapter.get_inventory().get_quantity(REP) == 0 and adapter.get_confirmed_revision() == 1, "Mirror = server view after session begin")
	_check(adapter.get_quote("A")["buy_price"] == 84 and adapter.get_quote("Z").is_empty(), "Quotes come from the server view")

	client.answers = [_receipt_answer("applied", "", 840, 84, _view(9160, 10, 2))]
	var bought := await adapter.buy("A", 10)
	_check(bought["success"] and bought["total_value"] == 840 and bought["unit_price"] == 84 and bought["reason"] == "", "Applied receipt -> success with server totals")
	for key in ["success", "total_value", "reason", "unit_price"]:
		_check(bought.has(key), "Result keeps the TradeService key %s" % key)
	_check(adapter.get_wallet().get_balance() == 9160 and adapter.get_inventory().get_quantity(REP) == 10, "Mirror follows the confirmed receipt")

	var stale_wallet := adapter.get_wallet()
	stale_wallet.add(5000)  # a caller edits its copy
	client.answers = [_receipt_answer("rejected", "insufficient_money", 37800, 0, _view(9160, 10, 2))]
	var refused := await adapter.buy("A", 10)
	_check(not refused["success"] and refused["reason"] == "insufficient_money", "Rule rejection keeps TradeService's reason code")
	_check(adapter.get_wallet().get_balance() == 9160 and adapter.get_wallet() != stale_wallet, "Mirror is rebuilt from the server, caller edits are not kept")

	client.answers = [{"status": OnlineProgressClient.UNCERTAIN, "reason": "HTTPRequest failed!"}]
	var lost := await adapter.sell("A", 10)
	_check(not lost["success"] and lost["online_status"] == OnlineProgressClient.UNCERTAIN and lost["pending"], "No answer -> not a success, still pending")
	_check(adapter.get_wallet().get_balance() == 9160 and adapter.get_inventory().get_quantity(REP) == 10 and adapter.get_confirmed_revision() == 2, "Uncertain outcome changes nothing locally")
	_check(adapter.pending_count() == 1, "The uncertain sell is pending in the client")

	client.answers = [_receipt_answer("applied", "", 760, 76, _view(9920, 0, 3), true)]
	var recovered := await adapter.recover()
	_check(recovered.size() == 1 and recovered[0]["success"] and recovered[0]["replayed"] and recovered[0]["idempotency_key"] == lost["idempotency_key"], "Recovery reports the original receipt for the same key")
	_check(adapter.get_wallet().get_balance() == 9920 and adapter.get_inventory().get_quantity(REP) == 0 and adapter.pending_count() == 0, "Mirror follows the recovered receipt; nothing pending")
	_check(revisions == [1, 2, 3], "confirmed_state_changed fires once per new server revision: %s" % str(revisions))
	_check(client.calls == 5, "Exactly one request per call (%d)" % client.calls)
	client.queue_free()


func _verify_scope_guard() -> void:
	var client := _new_client()
	var adapter := OnlineTradeAdapter.new(client)
	client._gameplay_session_id = "00000000-0000-0000-0000-0000000000b2"
	for good in ["test_good_02", "test_good_06", "gold", ""]:
		var r := await adapter.trade_good("buy", "A", good, 1)
		_check(not r["success"] and r["reason"] == OnlineTradeAdapter.OUT_OF_SCOPE_REASON, "Good %s is outside WP01-B and refused locally" % good)
	var bad_action := await adapter.trade_good("grant", "A", REP, 1)
	_check(bad_action["reason"] == OnlineTradeAdapter.OUT_OF_SCOPE_REASON, "Unknown action refused locally")
	_check(client.calls == 0 and adapter.pending_count() == 0, "Nothing out of scope reaches the network or the pending list")
	client.queue_free()


func _verify_superseded_keeps_mirror() -> void:
	var client := _new_client()
	var adapter := OnlineTradeAdapter.new(client)
	client.answers = [{"status": OnlineProgressClient.OK, "reason": "", "data": {"gameplay_session_id": "00000000-0000-0000-0000-0000000000b3", "progress": _view(10000, 0, 1)}}]
	await adapter.begin()
	var prompts := [0]
	client.gameplay_session_superseded.connect(func(): prompts[0] += 1)
	client.answers = [{"status": OnlineProgressClient.REJECTED, "reason": "gameplay_session_superseded", "grpc_status": 10}]
	var stale := await adapter.buy("A", 1)
	_check(not stale["success"] and stale["reason"] == "gameplay_session_superseded" and not stale["pending"], "Superseded: refused, a new command is not kept")
	_check(prompts[0] == 1 and client.is_gameplay_session_superseded(), "Superseded signal reaches the adapter's client")
	_check(adapter.get_wallet().get_balance() == 10000, "Superseded: mirror unchanged")
	var read := await adapter.refresh()
	_check(read["reason"] == "gameplay_session_superseded" and client.calls == 2, "Superseded: reads refused locally, nothing sent")
	client.queue_free()


func _verify_inconsistent_view_is_flagged() -> void:
	var client := _new_client()
	var adapter := OnlineTradeAdapter.new(client)
	client.answers = [{"status": OnlineProgressClient.OK, "reason": "", "data": {"gameplay_session_id": "00000000-0000-0000-0000-0000000000b4", "progress": _view(10000, 500, 1)}}]
	await adapter.begin()
	_check(not adapter.is_mirror_consistent(), "A server view the domain types cannot hold (500 > capacity 100) is flagged, not repaired")
	client.queue_free()


## PR #133 review: trade B (revision 3) answers before trade A (revision 2).
## Money, goods and quotes must stay at revision 3.
func _verify_reversed_responses_never_roll_back() -> void:
	var client := GatedClient.new()
	root.add_child(client)
	var adapter := OnlineTradeAdapter.new(client)
	client.queue({"status": OnlineProgressClient.OK, "reason": "", "data": {"gameplay_session_id": "00000000-0000-0000-0000-0000000000b5", "progress": _view_q(10000, 0, 1, 84)}})
	client.release(0)
	await adapter.begin()
	client.queue(_receipt_answer("applied", "", 84, 84, _view_q(9916, 1, 2, 85)))  # trade A -> revision 2
	client.queue(_receipt_answer("applied", "", 85, 85, _view_q(9831, 2, 3, 86)))  # trade B -> revision 3
	var done := []
	var revisions := []
	adapter.confirmed_state_changed.connect(func(r): revisions.append(r))
	_start_buy(adapter, done)  # A issued first
	_start_buy(adapter, done)  # B issued second
	await process_frame
	client.release(2)          # B answers FIRST
	while done.size() < 1:
		await process_frame
	_check(adapter.get_confirmed_revision() == 3 and adapter.get_wallet().get_balance() == 9831, "Reversed order: after B (rev 3) the mirror is at rev 3")
	client.release(1)          # A answers LAST, with the OLDER revision 2
	while done.size() < 2:
		await process_frame
	_check(done.all(func(r): return r["success"]), "Both reversed-order trades report success")
	_check(adapter.get_confirmed_revision() == 3, "Reversed order: an older revision never replaces a newer one (rev %d)" % adapter.get_confirmed_revision())
	_check(adapter.get_wallet().get_balance() == 9831 and adapter.get_inventory().get_quantity(REP) == 2, "Reversed order: money and goods stay at revision 3 (money %d, goods %d)" % [adapter.get_wallet().get_balance(), adapter.get_inventory().get_quantity(REP)])
	_check(adapter.get_quote("A")["buy_price"] == 86, "Reversed order: the stale revision-2 quote does not replace the revision-3 quote (%s)" % str(adapter.get_quote("A")))
	_check(revisions == [3], "confirmed_state_changed fired only for the newer revision: %s" % str(revisions))
	client.queue_free()


## Same revision (no state change in between): money and goods are equal by
## definition; only time-dependent quotes can differ. The answer to the LATER
## issued request wins, whatever order the answers arrive in.
func _verify_equal_revision_tie_break() -> void:
	var client := GatedClient.new()
	root.add_child(client)
	var adapter := OnlineTradeAdapter.new(client)
	client.queue({"status": OnlineProgressClient.OK, "reason": "", "data": {"gameplay_session_id": "00000000-0000-0000-0000-0000000000b6", "progress": _view_q(10000, 0, 1, 84)}})
	client.release(0)
	await adapter.begin()
	client.queue({"status": OnlineProgressClient.OK, "reason": "", "data": {"progress": _view_q(10000, 0, 1, 90)}})  # earlier read
	client.queue({"status": OnlineProgressClient.OK, "reason": "", "data": {"progress": _view_q(10000, 0, 1, 88)}})  # later read
	var done := []
	_start_refresh(adapter, done)
	_start_refresh(adapter, done)
	await process_frame
	client.release(2)  # the later-issued read answers first ...
	while done.size() < 1:
		await process_frame
	client.release(1)  # ... the earlier-issued read answers last
	while done.size() < 2:
		await process_frame
	_check(adapter.get_confirmed_revision() == 1 and adapter.get_quote("A")["buy_price"] == 88, "Equal revision: the later-issued read's quote wins (%s)" % str(adapter.get_quote("A")))
	client.queue_free()


func _start_buy(adapter: OnlineTradeAdapter, done: Array) -> void:
	done.append(await adapter.buy("A", 1))


func _start_refresh(adapter: OnlineTradeAdapter, done: Array) -> void:
	done.append(await adapter.refresh())


func _new_client() -> ScriptedClient:
	var client := ScriptedClient.new()
	root.add_child(client)
	return client


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
