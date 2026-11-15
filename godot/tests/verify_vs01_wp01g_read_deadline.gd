extends SceneTree

## C2-E2 deterministic loopback verification. No Nakama, cloud service,
## project save, or Development Save is read or written.
##
## Every case uses its own loopback server and its own client. Every wait is
## bounded (_wait_until); a guard expiry is a FAIL and stops all later cases,
## because an unfinished read could otherwise leak into them.

const REP := OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID
const SCENE := "res://scenes/online_progress_resume_test_mode.tscn"
const Mode := preload("res://scripts/online_progress_resume_test_mode.gd")
const TEST_USER := "00000000-0000-0000-0000-0000000000e2"
const GUARD_USEC := 3_000_000
const RPC_TRADE_READ := "vs01_progress_get"
const RPC_HERO_READ := "vs01e_progression_get"


## Local HTTP endpoint. Per RPC id: "reply" answers once the request is
## complete, "hold" keeps it until release_held(), "stall" never answers.
class LoopbackRPCServer extends RefCounted:
	var server := TCPServer.new()
	var connections: Array = []
	var accepted_requests := 0
	var complete_requests := 0
	var default_policy := "reply"
	var policy_for := {}
	var trade_view := {}
	var hero_view := {}


	func start() -> int:
		return server.get_local_port() if server.listen(0, "127.0.0.1") == OK else -1


	func poll() -> void:
		while server.is_connection_available():
			accepted_requests += 1
			connections.append({"peer": server.take_connection(), "bytes": PackedByteArray(), "complete": false,
				"answered": false, "rpc": "", "policy": ""})
		for item in connections:
			if item["answered"]:
				continue
			var peer: StreamPeerTCP = item["peer"]
			peer.poll()
			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				continue
			var available := peer.get_available_bytes()
			if available > 0:
				var chunk := peer.get_data(available)
				if chunk[0] == OK:
					# PackedByteArray is a value type: write the grown copy back.
					var buffer: PackedByteArray = item["bytes"]
					buffer.append_array(chunk[1])
					item["bytes"] = buffer
			if not item["complete"] and _request_complete(item["bytes"]):
				complete_requests += 1
				item["complete"] = true
				item["rpc"] = _rpc_of(item["bytes"])
				item["policy"] = policy_for.get(item["rpc"], default_policy)
			if item["complete"] and item["policy"] == "reply":
				_answer(item)


	func held_count(rpc_id: String = "") -> int:
		var held := 0
		for item in connections:
			if item["complete"] and not item["answered"] and item["policy"] == "hold" and (rpc_id.is_empty() or item["rpc"] == rpc_id):
				held += 1
		return held


	## Answers held requests with the CURRENT views. Returns how many.
	func release_held() -> int:
		var released := 0
		for item in connections:
			if item["complete"] and not item["answered"] and item["policy"] == "hold":
				_answer(item)
				released += 1
		return released


	func stop() -> void:
		for item in connections:
			(item["peer"] as StreamPeerTCP).disconnect_from_host()
		connections.clear()
		server.stop()


	func _answer(item: Dictionary) -> void:
		item["answered"] = true
		var peer: StreamPeerTCP = item["peer"]
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return
		var payload := ""
		if item["rpc"] == "vs01e_progression_get":
			payload = JSON.stringify({"progression": hero_view, "unresolved_ticket": null, "server_time_ms": 0})
		else:
			payload = JSON.stringify({"progress": trade_view})
		var body := JSON.stringify({"payload": payload}).to_utf8_buffer()
		var header := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.size()
		peer.put_data(header.to_utf8_buffer() + body)


	static func _request_complete(bytes: PackedByteArray) -> bool:
		var text := bytes.get_string_from_utf8()
		var header_end := text.find("\r\n\r\n")
		if header_end < 0:
			return false
		var content_length := 0
		for line in text.substr(0, header_end).split("\r\n"):
			if String(line).to_lower().begins_with("content-length:"):
				content_length = int(String(line).split(":", true, 1)[1].strip_edges())
		return bytes.size() >= header_end + 4 + content_length


	static func _rpc_of(bytes: PackedByteArray) -> String:
		var text := bytes.get_string_from_utf8()
		var request_line := text.substr(0, text.find("\r\n"))
		var parts := request_line.split(" ")
		if parts.size() < 2:
			return ""
		var path := String(parts[1]).split("?")[0]
		return path.get_file()


## Records transport events. Holds request objects by id so a case can drive
## the late boundary of a request that is already decided.
class ReadLog extends RefCounted:
	var transport: OnlineReadTransport
	var started: Array = []
	var finished: Array = []
	var late: Array = []
	var requests := {}


	func attach(p_transport: OnlineReadTransport) -> void:
		transport = p_transport
		transport.read_started.connect(_on_started)
		transport.read_finished.connect(_on_finished)
		transport.late_settlement_dropped.connect(_on_late)


	func finished_for(request_id: int) -> Array:
		return finished.filter(func(entry: Dictionary) -> bool: return entry["id"] == request_id)


	func late_for(request_id: int, event: String, original_status: String) -> int:
		return late.filter(func(entry: Dictionary) -> bool:
			return entry["id"] == request_id and entry["event"] == event and (original_status.is_empty() or entry["original"] == original_status)
		).size()


	func _on_started(request_id: int, rpc_id: String) -> void:
		started.append({"id": request_id, "rpc": rpc_id})
		requests[request_id] = transport.get_active_request(request_id)


	func _on_finished(request_id: int, rpc_id: String, decision: String, status: String) -> void:
		finished.append({"id": request_id, "rpc": rpc_id, "decision": decision, "status": status})


	func _on_late(request_id: int, rpc_id: String, event: String, original_status: String) -> void:
		late.append({"id": request_id, "rpc": rpc_id, "event": event, "original": original_status})


## A successful SDK RPC answer, for driving the late boundary directly.
class FakeRpc extends RefCounted:
	var payload := ""


	func _init(p_payload: String) -> void:
		payload = p_payload


	func is_exception() -> bool:
		return false


	func get_exception() -> Variant:
		return null


var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	for index in range(CASE_COUNT):
		var may_continue: bool = await _run_case(index)
		if not may_continue:
			_fail("stopping: a bounded wait expired, later cases would not be isolated")
			break
	_verify_static_boundaries()
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-G bounded read verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Cases -----------------------------------------------------------------------

const CASE_COUNT := 9


func _run_case(index: int) -> bool:
	match index:
		0:
			return await _case_deadline_low_fps_then_retry()
		1:
			return await _case_deadline_wins_same_frame_reply()
		2:
			return await _case_reply_at_expired_deadline()
		3:
			return await _case_reply_before_deadline()
		4:
			return await _case_superseded_during_trade_read()
		5:
			return await _case_mode_ui_superseded_trade()
		6:
			return await _case_mode_ui_superseded_hero()
		7:
			return await _case_sign_out_then_relogin()
		8:
			return await _case_mode_sign_out_no_new_read()
	return true


## B3 under a low frame rate, the SDK's own cancelled return reaching the late
## boundary, cleanup, and an immediate retry.
func _case_deadline_low_fps_then_retry() -> bool:
	print("== case: deadline at low FPS, late SDK return, retry")
	var server := LoopbackRPCServer.new()
	if not _require(server.start() > 0, "loopback RPC server starts"):
		return true
	server.default_policy = "stall"
	var client := _new_client(server, 5, 0.5)
	var events := ReadLog.new()
	events.attach(client._read_transport)

	var first := _new_state()
	Engine.max_fps = 5
	_run_trade_read(client, first)
	var ok: bool = await _wait_until(server, GUARD_USEC, "stalled read returns", func() -> bool: return first["done"])
	Engine.max_fps = 0
	if not ok:
		return await _finish(server, client, false)
	var first_ms := _elapsed_ms(first)
	var first_id: int = events.started[0]["id"]
	_check(first["result"].get("status") == OnlineProgressClient.UNCERTAIN and first["result"].get("reason") == OnlineReadTransport.DEADLINE_REASON, "stalled read returns UNCERTAIN (read_deadline_exceeded)")
	_check(events.finished_for(first_id).size() == 1 and events.finished_for(first_id)[0]["decision"] == OnlineReadTransport.DECISION_DEADLINE, "the stalled read was decided exactly once, by the deadline")
	_check(first_ms <= 2000, "deadline remains bounded at low FPS (%d ms in test configuration)" % first_ms)
	_check(server.accepted_requests == 1, "one logical read sends one SDK attempt (quota-safe)")
	_check(client.get_confirmed_progress().get("revision") == 1, "timeout preserves the last confirmed cache")

	ok = await _wait_until(server, GUARD_USEC, "SDK return after the deadline reaches the late boundary", func() -> bool: return events.late_for(first_id, OnlineReadTransport.LATE_EVENT_REPLY, "") >= 1)
	if not ok:
		return await _finish(server, client, false)
	_check(events.late_for(first_id, OnlineReadTransport.LATE_EVENT_REPLY, OnlineProgressClient.UNCERTAIN) == 1, "the SDK's cancelled return reached the late boundary once and was dropped")
	_check(events.finished_for(first_id).size() == 1, "the late SDK return did not resume the caller a second time")

	server.default_policy = "reply"
	server.trade_view = _trade_view(300, 3, 10)
	client._read_transport.owner_deadline_sec = 1.5
	var second := _new_state()
	_run_trade_read(client, second)
	ok = await _wait_until(server, GUARD_USEC, "immediate retry returns", func() -> bool: return second["done"])
	if not ok:
		return await _finish(server, client, false)
	_check(second["result"].get("status") == OnlineProgressClient.OK and second["result"].get("decision") == OnlineReadTransport.DECISION_REPLY, "immediate retry completes normally")
	_check(server.accepted_requests == 2, "retry owns a separate single SDK attempt")
	_check(client.get_confirmed_progress().get("revision") == 10, "retry installs its server-confirmed value")

	ok = await _wait_until(server, GUARD_USEC, "read request nodes are freed", func() -> bool: return client._read_transport.get_children().is_empty())
	_check(ok and client._read_transport.active_request_count() == 0, "all request ownership is released; no ReadRequest or HTTPRequest child survives")
	_check(client.get_confirmed_progress().get("revision") == 10, "nothing after cleanup changed the retry cache")
	return await _finish(server, client, ok)


## Fix 1, order deadline -> reply: a successful reply handed to the request in
## the same call chain right after the deadline decision is not accepted.
func _case_deadline_wins_same_frame_reply() -> bool:
	print("== case: deadline decided, reply arrives right after (same frame)")
	var server := LoopbackRPCServer.new()
	if not _require(server.start() > 0, "loopback RPC server starts"):
		return true
	server.default_policy = "hold"
	server.trade_view = _trade_view(900, 9, 99)
	var client := _new_client(server, 5, 0.3)
	var events := ReadLog.new()
	events.attach(client._read_transport)
	var injected := {"done": false}
	client._read_transport.read_finished.connect(func(request_id: int, _rpc_id: String, decision: String, _status: String) -> void:
		if decision == OnlineReadTransport.DECISION_DEADLINE and not injected["done"]:
			injected["done"] = true
			var request: Variant = events.requests.get(request_id)
			if is_instance_valid(request):
				request.on_sdk_returned(FakeRpc.new(JSON.stringify({"progress": _trade_view(800, 8, 98)})))
	)

	var state := _new_state()
	_run_trade_read(client, state)
	var ok: bool = await _wait_until(server, GUARD_USEC, "deadline read returns", func() -> bool: return state["done"])
	if not ok:
		return await _finish(server, client, false)
	var id: int = events.started[0]["id"]
	_check(injected["done"], "a successful reply was delivered to the request right after its deadline decision")
	_check(state["result"].get("status") == OnlineProgressClient.UNCERTAIN and state["result"].get("reason") == OnlineReadTransport.DEADLINE_REASON, "deadline first: the caller gets UNCERTAIN, not the later OK")
	_check(events.late_for(id, OnlineReadTransport.LATE_EVENT_REPLY, OnlineProgressClient.OK) == 1, "the OK reply reached the late boundary and was dropped")
	_check(events.finished_for(id).size() == 1, "the caller was resumed exactly once")
	_check(client.get_confirmed_progress().get("revision") == 1 and client.get_confirmed_progress().get("money") == 100, "the dropped OK reply did not reach the cache")

	# The real held answer is released too: the SDK request was cancelled, so
	# whatever comes back is only the cancelled return, dropped again.
	server.release_held()
	ok = await _wait_until(server, GUARD_USEC, "cancelled SDK return reaches the late boundary", func() -> bool: return events.late_for(id, OnlineReadTransport.LATE_EVENT_REPLY, "") >= 2)
	_check(ok and events.late_for(id, OnlineReadTransport.LATE_EVENT_REPLY, OnlineProgressClient.OK) == 1, "the released server answer never became an accepted OK")
	_check(client.get_confirmed_progress().get("revision") == 1, "cache unchanged after the server answer was released")
	return await _finish(server, client, ok)


## Fix 1, boundary: a reply processed when the deadline timer has already run
## out (time_left == 0) but its timeout was not dispatched yet is too late.
func _case_reply_at_expired_deadline() -> bool:
	print("== case: reply at an expired deadline (time_left == 0)")
	var server := LoopbackRPCServer.new()
	if not _require(server.start() > 0, "loopback RPC server starts"):
		return true
	server.default_policy = "stall"
	var client := _new_client(server, 5, 0.0)
	var events := ReadLog.new()
	events.attach(client._read_transport)
	var probe := {"running": true, "injected": false}
	client._read_transport.read_started.connect(func(request_id: int, _rpc_id: String) -> void:
		var request: Variant = client._read_transport.get_active_request(request_id)
		if is_instance_valid(request):
			probe["running"] = request.deadline_running()
			probe["injected"] = true
			request.on_sdk_returned(FakeRpc.new(JSON.stringify({"progress": _trade_view(700, 7, 97)})))
	)
	var state := _new_state()
	_run_trade_read(client, state)
	var ok: bool = await _wait_until(server, GUARD_USEC, "expired-deadline read returns", func() -> bool: return state["done"])
	if not ok:
		return await _finish(server, client, false)
	var id: int = events.started[0]["id"]
	_check(probe["injected"] and not probe["running"], "the reply was processed while the deadline had run out but not fired")
	_check(state["result"].get("status") == OnlineProgressClient.UNCERTAIN and state["result"].get("decision") == OnlineReadTransport.DECISION_DEADLINE, "a reply at the deadline is refused (decision = deadline)")
	_check(events.late_for(id, OnlineReadTransport.LATE_EVENT_REPLY, OnlineProgressClient.OK) == 1, "the refused OK reply is recorded at the late boundary")
	_check(client.get_confirmed_progress().get("revision") == 1, "the refused reply did not reach the cache")
	for _frame in range(6):
		server.poll()
		await process_frame
	_check(server.accepted_requests == 0, "a read decided before dispatch never reaches the network")
	return await _finish(server, client, true)


## Fix 1, order reply -> deadline: the timer firing after a reply changes nothing.
func _case_reply_before_deadline() -> bool:
	print("== case: reply first, deadline later")
	var server := LoopbackRPCServer.new()
	if not _require(server.start() > 0, "loopback RPC server starts"):
		return true
	server.trade_view = _trade_view(300, 3, 30)
	var client := _new_client(server, 5, 0.8)
	var events := ReadLog.new()
	events.attach(client._read_transport)
	var state := _new_state()
	_run_trade_read(client, state)
	var ok: bool = await _wait_until(server, GUARD_USEC, "read returns", func() -> bool: return state["done"])
	if not ok:
		return await _finish(server, client, false)
	var id: int = events.started[0]["id"]
	_check(state["result"].get("status") == OnlineProgressClient.OK and state["result"].get("decision") == OnlineReadTransport.DECISION_REPLY, "reply before the deadline is accepted")
	var settle_wait := {"until": Time.get_ticks_usec() + 1_000_000}
	ok = await _wait_until(server, GUARD_USEC, "wait past the original deadline", func() -> bool: return Time.get_ticks_usec() >= settle_wait["until"])
	_check(events.finished_for(id).size() == 1 and events.late_for(id, OnlineReadTransport.LATE_EVENT_REPLY, "") == 0, "no second decision and no late reply after the deadline time passed")
	_check(client.get_confirmed_progress().get("revision") == 30, "the accepted value stays")
	return await _finish(server, client, ok)


## Fix 2 + Fix 4: a REAL server answer arrives after this client was told of a
## takeover. It reaches the transport (decision = reply, status OK) and is
## dropped by the owner gate; cache, session and superseded state stay.
func _case_superseded_during_trade_read() -> bool:
	print("== case: takeover notice while a Trade read is in flight")
	var server := LoopbackRPCServer.new()
	if not _require(server.start() > 0, "loopback RPC server starts"):
		return true
	server.default_policy = "hold"
	var client := _new_client(server, 5, 5.0)
	var events := ReadLog.new()
	events.attach(client._read_transport)
	var signals := {"superseded": 0}
	client.gameplay_session_superseded.connect(func() -> void: signals["superseded"] += 1)
	var session_before := client.get_gameplay_session_id()

	var state := _new_state()
	_run_trade_read(client, state)
	var ok: bool = await _wait_until(server, GUARD_USEC, "Trade read reaches the server", func() -> bool: return server.held_count() == 1)
	if not ok:
		return await _finish(server, client, false)
	_notify_takeover(client)
	server.trade_view = _trade_view(5000, 50, 50)
	server.release_held()
	ok = await _wait_until(server, GUARD_USEC, "held Trade read returns", func() -> bool: return state["done"])
	if not ok:
		return await _finish(server, client, false)
	var id: int = events.started[0]["id"]
	_check(events.finished_for(id).size() == 1 and events.finished_for(id)[0]["decision"] == OnlineReadTransport.DECISION_REPLY and events.finished_for(id)[0]["status"] == OnlineProgressClient.OK, "the real server OK answer reached the transport boundary")
	_check(state["result"].get("status") == OnlineProgressClient.REJECTED and state["result"].get("reason") == OnlineProgressClient.SUPERSEDED_REASON and state["result"].get("superseded_during_read", false), "the read is refused as superseded")
	_check(client._read_transport.superseded_dropped_total == 1, "exactly one OK answer was dropped by the superseded gate")
	_check(client.get_confirmed_progress().get("revision") == 1 and client.get_confirmed_progress().get("money") == 100, "the dropped answer did not reach the cache")
	_check(client.is_gameplay_session_superseded() and signals["superseded"] == 1 and client.get_gameplay_session_id() == session_before, "superseded state and session id unchanged; signal emitted once")
	var accepted := server.accepted_requests
	var refused: Dictionary = await client.refresh_progress()
	_check(refused.get("reason") == OnlineProgressClient.SUPERSEDED_REASON and server.accepted_requests == accepted, "after the notice, reads are refused locally without a request")
	return await _finish(server, client, true)


## Fix 2 at the UI: Trade read in flight in the Resume TEST mode.
func _case_mode_ui_superseded_trade() -> bool:
	print("== case: Resume UI, takeover notice during the Trade read")
	var server := LoopbackRPCServer.new()
	if not _require(server.start() > 0, "loopback RPC server starts"):
		return true
	var mode: OnlineProgressResumeTestMode = await _new_mode(server)
	var confirmed: bool = await _mode_confirm(server, mode)
	if not confirmed:
		return await _finish_mode(server, mode, false)
	var snap_before := mode.get_snapshot()
	var trade_text := mode.get_trade_text()
	var hero_text := mode.get_hero_text()
	var hero_requests := _completed_for(server, RPC_HERO_READ)

	server.policy_for = {RPC_TRADE_READ: "hold", RPC_HERO_READ: "reply"}
	var state := _new_state()
	_run_mode_refresh(mode, state)
	var ok: bool = await _wait_until(server, GUARD_USEC, "Trade read reaches the server", func() -> bool: return server.held_count(RPC_TRADE_READ) == 1)
	if not ok:
		return await _finish_mode(server, mode, false)
	_notify_takeover(mode.client)
	server.trade_view = _trade_view(9999, 99, 60)
	server.release_held()
	ok = await _wait_until(server, GUARD_USEC, "refresh_all returns", func() -> bool: return state["done"])
	if not ok:
		return await _finish_mode(server, mode, false)
	_check(state["result"].get("status") == OnlineProgressClient.REJECTED and mode.get_status_text() == Mode.SUPERSEDED_TEXT, "UI shows the takeover, never 'confirmed'")
	_check(mode.get_snapshot() == snap_before and mode.get_trade_text() == trade_text and mode.get_hero_text() == hero_text, "UI and both caches keep the last confirmed values")
	_check(_completed_for(server, RPC_HERO_READ) == hero_requests, "the Hero read is not started after a superseded Trade read")
	_check(not mode.is_busy() and mode.get_panel_button("Reclaim").visible, "busy released; reclaim offered")
	return await _finish_mode(server, mode, true)


## Fix 2 at the UI: Hero read in flight in the Resume TEST mode.
func _case_mode_ui_superseded_hero() -> bool:
	print("== case: Resume UI, takeover notice during the Hero read")
	var server := LoopbackRPCServer.new()
	if not _require(server.start() > 0, "loopback RPC server starts"):
		return true
	var mode: OnlineProgressResumeTestMode = await _new_mode(server)
	var confirmed: bool = await _mode_confirm(server, mode)
	if not confirmed:
		return await _finish_mode(server, mode, false)
	var hero_before: Dictionary = mode.combat_adapter.get_confirmed_progression()
	var hero_text := mode.get_hero_text()

	server.policy_for = {RPC_TRADE_READ: "reply", RPC_HERO_READ: "hold"}
	var state := _new_state()
	_run_mode_refresh(mode, state)
	var ok: bool = await _wait_until(server, GUARD_USEC, "Hero read reaches the server", func() -> bool: return server.held_count(RPC_HERO_READ) == 1)
	if not ok:
		return await _finish_mode(server, mode, false)
	_notify_takeover(mode.client)
	server.hero_view = _hero_view(9, 1, 100, 99)
	server.release_held()
	ok = await _wait_until(server, GUARD_USEC, "refresh_all returns", func() -> bool: return state["done"])
	if not ok:
		return await _finish_mode(server, mode, false)
	_check(state["result"].get("status") == OnlineProgressClient.REJECTED and mode.get_status_text() == Mode.SUPERSEDED_TEXT, "UI shows the takeover, never 'confirmed'")
	_check(mode.combat_adapter.get_confirmed_progression() == hero_before and mode.get_hero_text() == hero_text, "the late Hero answer did not reach the Hero cache or the UI")
	_check(mode.client._read_transport.superseded_dropped_total == 1, "exactly one OK Hero answer was dropped by the superseded gate")
	_check(not mode.is_busy(), "busy released")
	return await _finish_mode(server, mode, true)


## Sign-out cancels the old owner; same-account re-login reads fresh.
func _case_sign_out_then_relogin() -> bool:
	print("== case: sign-out during a read, then re-login")
	var server := LoopbackRPCServer.new()
	if not _require(server.start() > 0, "loopback RPC server starts"):
		return true
	server.default_policy = "stall"
	var client := _new_client(server, 5, 5.0)
	var events := ReadLog.new()
	events.attach(client._read_transport)
	var old_owner := _new_state()
	_run_trade_read(client, old_owner)
	var ok: bool = await _wait_until(server, GUARD_USEC, "old-owner read reaches the server", func() -> bool: return server.accepted_requests >= 1)
	if not ok:
		return await _finish(server, client, false)
	client.sign_out_local()
	ok = await _wait_until(server, GUARD_USEC, "old-owner read returns after sign-out", func() -> bool: return old_owner["done"])
	if not ok:
		return await _finish(server, client, false)
	var id: int = events.started[0]["id"]
	_check(old_owner["result"].get("stale", false) and events.finished_for(id)[0]["decision"] == OnlineReadTransport.DECISION_CANCELLED, "sign-out cancels the old owner and returns a stale result")
	_check(client._read_transport.active_request_count() == 0 and client.get_confirmed_progress().is_empty(), "account boundary releases ownership and clears only that account view")
	ok = await _wait_until(server, GUARD_USEC, "cancelled SDK return reaches the late boundary", func() -> bool: return events.late_for(id, OnlineReadTransport.LATE_EVENT_REPLY, "") >= 1)
	if not ok:
		return await _finish(server, client, false)

	_sign_in_fake(client, "session-c2-e2-relogin")
	server.default_policy = "reply"
	server.trade_view = _trade_view(400, 4, 20)
	var relogin := _new_state()
	_run_trade_read(client, relogin)
	ok = await _wait_until(server, GUARD_USEC, "re-login read returns", func() -> bool: return relogin["done"])
	if not ok:
		return await _finish(server, client, false)
	_check(relogin["result"].get("status") == OnlineProgressClient.OK, "same-account re-login can read with a fresh owner")
	_check(client.get_confirmed_progress().get("revision") == 20, "old owner cannot overwrite the re-login result")
	return await _finish(server, client, true)


## Sign-out while the Trade read of refresh_all() is in flight: the cancelled
## read must not let the Resume mode start a Hero read for the signed-out
## account, and nothing reaches the signed-out screen.
func _case_mode_sign_out_no_new_read() -> bool:
	print("== case: Resume UI, sign-out during the Trade read")
	var server := LoopbackRPCServer.new()
	if not _require(server.start() > 0, "loopback RPC server starts"):
		return true
	var mode: OnlineProgressResumeTestMode = await _new_mode(server)
	var confirmed: bool = await _mode_confirm(server, mode)
	if not confirmed:
		return await _finish_mode(server, mode, false)
	var hero_requests := _completed_for(server, RPC_HERO_READ)
	var accepted_before := server.accepted_requests
	server.policy_for = {RPC_TRADE_READ: "hold", RPC_HERO_READ: "reply"}
	var state := _new_state()
	_run_mode_refresh(mode, state)
	var ok: bool = await _wait_until(server, GUARD_USEC, "Trade read reaches the server", func() -> bool: return server.held_count(RPC_TRADE_READ) == 1)
	if not ok:
		return await _finish_mode(server, mode, false)
	mode.sign_out()
	ok = await _wait_until(server, GUARD_USEC, "refresh_all returns after sign-out", func() -> bool: return state["done"])
	if not ok:
		return await _finish_mode(server, mode, false)
	for _frame in range(6):
		server.poll()
		await process_frame
	_check(state["result"].get("stale", false), "refresh_all reports the cancelled read as stale")
	_check(server.accepted_requests == accepted_before + 1 and _completed_for(server, RPC_HERO_READ) == hero_requests, "no Hero read (no new request at all) is sent for the signed-out account")
	_check(not mode.get_snapshot().has("money") and not mode.get_snapshot().has("level") and mode.get_trade_text() == Mode.TRADE_UNKNOWN_TEXT, "nothing reaches the signed-out screen")
	_check(not mode.is_busy() and mode.client._read_transport.active_request_count() == 0, "busy and read ownership released")
	return await _finish_mode(server, mode, true)


# --- Helpers ---------------------------------------------------------------------

func _new_client(server: LoopbackRPCServer, timeout_sec: int, deadline_sec: float) -> OnlineProgressClient:
	var client := OnlineProgressClient.new()
	root.add_child(client)
	client.configure("127.0.0.1", server.server.get_local_port())
	_sign_in_fake(client, "session-c2-e2")
	client._confirmed = _trade_view(100, 1, 1)
	client._confirmed_revision = 1
	client.enable_bounded_reads()
	client._read_transport.request_timeout_sec = timeout_sec
	client._read_transport.owner_deadline_sec = deadline_sec
	return client


func _new_mode(server: LoopbackRPCServer) -> OnlineProgressResumeTestMode:
	var mode: OnlineProgressResumeTestMode = (load(SCENE) as PackedScene).instantiate()
	mode.host = "127.0.0.1"
	mode.port = server.server.get_local_port()
	root.add_child(mode)
	await process_frame
	_sign_in_fake(mode.client, "session-c2-e2-ui")
	mode.client._read_transport.request_timeout_sec = 5
	mode.client._read_transport.owner_deadline_sec = 5.0
	return mode


## First confirmed read of both contracts through the UI.
func _mode_confirm(server: LoopbackRPCServer, mode: OnlineProgressResumeTestMode) -> bool:
	server.trade_view = _trade_view(300, 3, 10)
	server.hero_view = _hero_view(2, 5, 100, 7)
	var state := _new_state()
	_run_mode_refresh(mode, state)
	var ok: bool = await _wait_until(server, GUARD_USEC, "first UI refresh returns", func() -> bool: return state["done"])
	if not ok:
		return false
	_check(state["result"].get("status") == OnlineProgressClient.OK and mode.get_status_text() == Mode.CONFIRMED_TEXT, "UI first read confirmed both contracts")
	return true


func _sign_in_fake(client: OnlineProgressClient, gameplay_session_id: String) -> void:
	client._session = NakamaSession.new(_unsigned_token(TEST_USER), false)
	client._gameplay_session_id = gameplay_session_id


## What a superseded answer of another request does: the client is told.
func _notify_takeover(client: OnlineProgressClient) -> void:
	client._note_superseded({"status": OnlineProgressClient.REJECTED, "reason": OnlineProgressClient.SUPERSEDED_REASON}, client.get_gameplay_session_id())


func _wait_until(server: LoopbackRPCServer, guard_usec: int, label: String, condition: Callable) -> bool:
	var start := Time.get_ticks_usec()
	while not condition.call():
		if Time.get_ticks_usec() - start >= guard_usec:
			_fail("test guard expired (%d ms): %s" % [int(guard_usec / 1000), label])
			return false
		if server != null:
			server.poll()
		await process_frame
	return true


func _new_state() -> Dictionary:
	return {"done": false, "result": {}, "started": Time.get_ticks_usec(), "ended": 0}


func _run_trade_read(client: OnlineProgressClient, state: Dictionary) -> void:
	state["started"] = Time.get_ticks_usec()
	state["result"] = await client.refresh_progress()
	state["ended"] = Time.get_ticks_usec()
	state["done"] = true


func _run_mode_refresh(mode: OnlineProgressResumeTestMode, state: Dictionary) -> void:
	state["started"] = Time.get_ticks_usec()
	state["result"] = await mode.refresh_all()
	state["ended"] = Time.get_ticks_usec()
	state["done"] = true


static func _elapsed_ms(state: Dictionary) -> int:
	return int((int(state["ended"]) - int(state["started"])) / 1000)


static func _completed_for(server: LoopbackRPCServer, rpc_id: String) -> int:
	return server.connections.filter(func(item: Dictionary) -> bool: return item["complete"] and item["rpc"] == rpc_id).size()


func _finish(server: LoopbackRPCServer, client: OnlineProgressClient, may_continue: bool) -> bool:
	server.stop()
	client.queue_free()
	await process_frame
	return may_continue


func _finish_mode(server: LoopbackRPCServer, mode: OnlineProgressResumeTestMode, may_continue: bool) -> bool:
	server.stop()
	mode.queue_free()
	await process_frame
	return may_continue


func _verify_static_boundaries() -> void:
	_check(OnlineReadTransport.READ_RPC_IDS == [RPC_TRADE_READ, RPC_HERO_READ], "only the two approved read RPCs are whitelisted")
	_check(OnlineReadTransport.DEFAULT_REQUEST_TIMEOUT_SEC == 7 and OnlineReadTransport.DEFAULT_OWNER_DEADLINE_SEC == 8.0, "production read timeout/deadline are below 10 seconds")
	var source := FileAccess.get_file_as_string("res://scripts/online_progress_client.gd")
	_check(source.contains("id in BOUNDED_READ_RPC_IDS"), "shared client uses an explicit read whitelist")
	_check(source.contains("await _get_client().rpc_async"), "the original SDK path remains present for writes")
	for write_rpc in ["RPC_SESSION_BEGIN", "RPC_TRADE", "RPC_COMBAT_REWARD_CLAIM"]:
		_check(source.contains(write_rpc), "write RPC remains on the shared client: %s" % write_rpc)
	var transport_source := FileAccess.get_file_as_string("res://scripts/online_read_transport.gd")
	_check(not transport_source.contains("Time.") and not transport_source.contains("get_ticks"), "production transport does not use the forbidden Time API")
	_check(transport_source.contains("auto_retry = false"), "bounded reads disable SDK retries")


static func _trade_view(money: int, goods: int, revision: int) -> Dictionary:
	return {"money": money, "backpack": {REP: goods}, "revision": revision, "quotes": {}}


static func _hero_view(level: int, exp: int, exp_to_next: int, revision: int) -> Dictionary:
	return {"level": level, "exp": exp, "exp_to_next": exp_to_next, "revision": revision}


static func _unsigned_token(user_id: String) -> String:
	var header := Marshalls.utf8_to_base64(JSON.stringify({"alg": "none"})).trim_suffix("=").trim_suffix("=")
	var body := Marshalls.utf8_to_base64(JSON.stringify({"uid": user_id, "usn": "c2-e2", "exp": 4102444800})).trim_suffix("=").trim_suffix("=")
	return "%s.%s.x" % [header, body]


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if ok:
		print("PASS: %s" % message)
	else:
		_fail(message)


func _require(ok: bool, message: String) -> bool:
	_check(ok, message)
	return ok


func _fail(message: String) -> void:
	_failures += 1
	push_error("FAILED: %s" % message)
