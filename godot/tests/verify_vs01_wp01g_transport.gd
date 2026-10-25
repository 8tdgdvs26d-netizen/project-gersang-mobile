extends SceneTree

## WP01-G Phase C1 — deterministic offline transport verification.
## A loopback TCP server reads each COMPLETE HTTP request, then deliberately
## never replies. This proves non-threaded timeout/retry behavior without
## Nakama, cloud services, local saves, or gameplay integration.

const CASE_GUARD_USEC := 15_000_000
const MIN_CASE_USEC := 2_900_000
const MAX_CASE_USEC := 5_000_000
const MAX_HEARTBEAT_GAP_USEC := 500_000
const MIN_ATTEMPT_TIMEOUT_USEC := 750_000
const MAX_ATTEMPT_TIMEOUT_USEC := 1_750_000


class StallServer extends RefCounted:
	var server := TCPServer.new()
	var connections: Array = []
	var requests: Array = []

	func start() -> int:
		if server.listen(0, "127.0.0.1") != OK:
			return -1
		return server.get_local_port()

	func poll() -> void:
		while server.is_connection_available():
			var peer := server.take_connection()
			if peer != null:
				connections.append({
					"peer": peer,
					"bytes": PackedByteArray(),
					"complete": false,
					"accepted_usec": Time.get_ticks_usec(),
				})
		for index in range(connections.size()):
			var item: Dictionary = connections[index]
			if item["complete"]:
				continue
			var peer: StreamPeerTCP = item["peer"]
			peer.poll()
			var available := peer.get_available_bytes()
			if available > 0:
				var chunk := peer.get_data(available)
				if chunk[0] == OK:
					var bytes: PackedByteArray = item["bytes"]
					bytes.append_array(chunk[1])
					item["bytes"] = bytes
			_try_record_complete(item)
			connections[index] = item

	func reset_requests() -> void:
		requests.clear()

	func stop() -> void:
		for item in connections:
			(item["peer"] as StreamPeerTCP).disconnect_from_host()
		connections.clear()
		server.stop()

	func _try_record_complete(item: Dictionary) -> void:
		var bytes: PackedByteArray = item["bytes"]
		var text := bytes.get_string_from_utf8()
		var header_end := text.find("\r\n\r\n")
		if header_end < 0:
			return
		var content_length := 0
		for line in text.substr(0, header_end).split("\r\n"):
			var lower := String(line).to_lower()
			if lower.begins_with("content-length:"):
				content_length = int(String(line).split(":", true, 1)[1].strip_edges())
		var body_start := header_end + 4
		if bytes.size() < body_start + content_length:
			return
		var body := bytes.slice(body_start, body_start + content_length).get_string_from_utf8()
		var completed_usec := Time.get_ticks_usec()
		requests.append({
			"request_line": text.get_slice("\r\n", 0),
			"headers": text.substr(0, header_end),
			"body": body,
			"byte_count": body_start + content_length,
			"accepted_usec": int(item["accepted_usec"]),
			"completed_usec": completed_usec,
		})
		item["complete"] = true


var _checks := 0
var _failures := 0
var _abort := false
var _request_observations: Array = []


func _initialize() -> void:
	await process_frame
	await _verify_read_and_after()
	if not _abort:
		await _verify_write()
	await process_frame
	if _failures == 0:
		print("VS-01 WP01-G transport verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_read_and_after() -> void:
	var fault := StallServer.new()
	var port := fault.start()
	_check(port > 0, "T-READ loopback stall server starts")
	if port <= 0:
		_abort = true
		return
	var client := _new_client(port, "00000000-0000-0000-0000-00000000000a")
	_verify_configuration(client)
	var before := {"money": 10000, "backpack": {"test_good_01": 2}, "revision": 9}
	client._confirmed = before.duplicate(true)
	client._confirmed_revision = 9
	_request_observations.clear()
	client._adapter.child_entered_tree.connect(_observe_request_node)
	# Keep one clean frame between setup/import work and the first timeout. This
	# prevents setup-frame delta from being charged against HTTPRequest's timer.
	await process_frame

	var first := await _run_stall_call(fault, client, "read-1")
	_verify_stall_result(first, fault, client, before, 3, "T-READ")
	await _verify_clean(client, fault, "T-AFTER read-1")
	if _abort:
		fault.stop()
		client.queue_free()
		return

	# The same adapter must remain usable after its timed-out HTTPRequest was
	# removed. This second read is intentionally another complete timeout cycle.
	fault.reset_requests()
	_request_observations.clear()
	var second := await _run_stall_call(fault, client, "read-2-after-timeout")
	_verify_stall_result(second, fault, client, before, 3, "T-AFTER follow-up")
	await _verify_clean(client, fault, "T-AFTER follow-up")
	fault.stop()
	client.queue_free()
	await process_frame


func _verify_write() -> void:
	var fault := StallServer.new()
	var port := fault.start()
	_check(port > 0, "T-WRITE loopback stall server starts")
	if port <= 0:
		_abort = true
		return
	var client := _new_client(port, "00000000-0000-0000-0000-00000000000b")
	var before := {"money": 10000, "backpack": {}, "revision": 4}
	client._confirmed = before.duplicate(true)
	client._confirmed_revision = 4
	_request_observations.clear()
	client._adapter.child_entered_tree.connect(_observe_request_node)
	var state := {"done": false, "result": {}, "started_usec": Time.get_ticks_usec(), "completed_usec": 0}
	_run_write(client, state)
	var metrics := await _poll_until_done(fault, state, "write")
	var result: Dictionary = state["result"]
	_verify_common_metrics(metrics, fault.requests.size(), 3, "T-WRITE")
	_verify_attempt_timeline(fault.requests, metrics, 3, "T-WRITE")
	_check(result.get("status") == OnlineProgressClient.UNCERTAIN, "T-WRITE returns UNCERTAIN (%s)" % str(result))
	var pending := client.get_pending_commands()
	var key := String(result.get("idempotency_key", ""))
	_check(not key.is_empty() and pending.size() == 1 and pending.has(key), "T-WRITE keeps exactly one pending command under the returned key")
	_check(client.get_confirmed_progress() == before, "T-WRITE leaves confirmed cache unchanged")
	var seen_keys: Array = []
	for request in fault.requests:
		_check(String(request["request_line"]).begins_with("POST /v2/rpc/vs01_trade"), "T-WRITE received a complete vs01_trade HTTP request")
		var payload := _rpc_payload(String(request["body"]))
		seen_keys.append(String(payload.get("idempotency_key", "")))
	print("IDEMPOTENCY T-WRITE returned_key=%s complete_body_keys=%d all_match=%s" % [key, seen_keys.size(), str(seen_keys.size() == 3 and seen_keys.all(func(value): return value == key))])
	_check(seen_keys.size() == 3 and seen_keys.all(func(value): return value == key), "T-WRITE all three complete request bodies reuse the same idempotency key")
	_verify_request_observations(1, "T-WRITE")
	await _verify_clean(client, fault, "T-AFTER write")
	fault.stop()
	client.queue_free()
	await process_frame


func _verify_configuration(client: OnlineProgressClient) -> void:
	_check(OnlineProgressClient.HTTP_USE_THREADS == false, "T-CFG compile-time transport flag is false")
	_check(client._adapter.use_threads == false, "T-CFG adapter uses non-threaded HTTP")
	_check(client._adapter.timeout == 1, "T-CFG adapter timeout remains 1 second for this test")
	_check(client._client.auto_retry == true, "T-CFG SDK auto_retry remains enabled")
	_check(client._adapter.auto_retry_count == 3, "T-CFG SDK retry count remains three attempts")
	_check(client._adapter.auto_retry_backoff_base == 10, "T-CFG SDK retry backoff base remains 10")


func _run_stall_call(fault: StallServer, client: OnlineProgressClient, label: String) -> Dictionary:
	# Start the measurement before invoking the coroutine: _run_read() reaches
	# its first await synchronously, so starting later would omit request setup.
	var state := {"done": false, "result": {}, "started_usec": Time.get_ticks_usec(), "completed_usec": 0}
	_run_read(client, state)
	var metrics := await _poll_until_done(fault, state, label)
	return {"result": state["result"], "metrics": metrics}


func _run_read(client: OnlineProgressClient, state: Dictionary) -> void:
	state["result"] = await client.refresh_progress()
	state["completed_usec"] = Time.get_ticks_usec()
	state["done"] = true


func _run_write(client: OnlineProgressClient, state: Dictionary) -> void:
	state["result"] = await client.buy("A", "test_good_01", 10)
	state["completed_usec"] = Time.get_ticks_usec()
	state["done"] = true


func _poll_until_done(fault: StallServer, state: Dictionary, label: String) -> Dictionary:
	var started := int(state["started_usec"])
	var previous := started
	var max_gap := 0
	while not state["done"]:
		fault.poll()
		var now := Time.get_ticks_usec()
		max_gap = maxi(max_gap, now - previous)
		previous = now
		if now - started >= CASE_GUARD_USEC:
			_fail("%s exceeded the 15 second in-test guard" % label)
			_abort = true
			break
		await process_frame
	fault.poll()
	# The request can finish during the final process_frame await. Account for
	# that last interval after the loop exits so completion cannot hide a stall.
	var observed_done_usec := Time.get_ticks_usec()
	max_gap = maxi(max_gap, observed_done_usec - previous)
	var request_returned_usec := int(state.get("completed_usec", 0))
	if request_returned_usec <= 0:
		request_returned_usec = observed_done_usec
	return {
		"elapsed_usec": request_returned_usec - started,
		"max_gap_usec": max_gap,
		"request_returned_usec": request_returned_usec,
		"observed_done_usec": observed_done_usec,
	}


func _verify_stall_result(run: Dictionary, fault: StallServer, client: OnlineProgressClient, before: Dictionary, expected_requests: int, label: String) -> void:
	var result: Dictionary = run["result"]
	var metrics: Dictionary = run["metrics"]
	_verify_common_metrics(metrics, fault.requests.size(), expected_requests, label)
	_verify_attempt_timeline(fault.requests, metrics, expected_requests, label)
	_check(result.get("status") == OnlineProgressClient.UNCERTAIN, "%s returns UNCERTAIN (%s)" % [label, str(result)])
	_check(not result.has("stale"), "%s result is not stale" % label)
	_check(client.get_confirmed_progress() == before, "%s leaves confirmed cache unchanged" % label)
	for request in fault.requests:
		_check(String(request["request_line"]).begins_with("POST /v2/rpc/vs01_progress_get"), "%s received a complete progress-read HTTP request" % label)
		_check(not String(request["body"]).is_empty(), "%s complete HTTP request includes its full body" % label)
	# The SDK reuses one HTTPRequest node for all three retry attempts; the
	# server-side complete-request count above proves the three attempts.
	_verify_request_observations(1, label)


func _verify_common_metrics(metrics: Dictionary, complete_requests: int, expected_requests: int, label: String) -> void:
	var elapsed := int(metrics.get("elapsed_usec", 0))
	var max_gap := int(metrics.get("max_gap_usec", CASE_GUARD_USEC))
	print("CASE_METRICS %s complete_requests=%d elapsed_usec=%d max_heartbeat_gap_usec=%d" % [label, complete_requests, elapsed, max_gap])
	_check(complete_requests == expected_requests, "%s server received %d complete requests (got %d)" % [label, expected_requests, complete_requests])
	_check(elapsed >= MIN_CASE_USEC and elapsed <= MAX_CASE_USEC, "%s elapsed 2.9–5.0 seconds (got %.3f s)" % [label, elapsed / 1_000_000.0])
	_check(max_gap < MAX_HEARTBEAT_GAP_USEC, "%s main-thread heartbeat gap stays below 500 ms (got %.3f ms)" % [label, max_gap / 1000.0])


func _verify_attempt_timeline(requests: Array, metrics: Dictionary, expected_requests: int, label: String) -> void:
	if requests.size() != expected_requests:
		print("ATTEMPT_TIMELINE %s unavailable: expected=%d complete_requests=%d" % [label, expected_requests, requests.size()])
		return
	var call_completed_usec := int(metrics.get("request_returned_usec", 0))
	for index in range(expected_requests):
		var request: Dictionary = requests[index]
		var accepted_usec := int(request.get("accepted_usec", 0))
		var completed_usec := int(request.get("completed_usec", 0))
		var interval_end_usec := call_completed_usec
		var interval_end := "call_completed"
		if index + 1 < expected_requests:
			interval_end_usec = int(requests[index + 1].get("accepted_usec", 0))
			interval_end = "retry_%d_accepted" % (index + 2)
		var timeout_window_usec := interval_end_usec - completed_usec
		print("ATTEMPT_TIMELINE %s attempt=%d accepted_usec=%d completed_usec=%d %s_usec=%d timeout_window_usec=%d" % [
			label,
			index + 1,
			accepted_usec,
			completed_usec,
			interval_end,
			interval_end_usec,
			timeout_window_usec,
		])
		_check(accepted_usec > 0 and completed_usec >= accepted_usec, "%s attempt %d records ordered accept/complete timestamps" % [label, index + 1])
		_check(
			timeout_window_usec >= MIN_ATTEMPT_TIMEOUT_USEC and timeout_window_usec <= MAX_ATTEMPT_TIMEOUT_USEC,
			"%s attempt %d independently waits 0.75–1.75 seconds before %s (got %.3f s)" % [label, index + 1, interval_end, timeout_window_usec / 1_000_000.0]
		)


func _verify_request_observations(expected: int, label: String) -> void:
	_check(_request_observations.size() == expected, "%s observed %d HTTPRequest nodes (got %d)" % [label, expected, _request_observations.size()])
	for observation in _request_observations:
		_check(observation["use_threads"] == false, "%s HTTPRequest use_threads is false" % label)
		_check(observation["timeout"] == 1.0, "%s HTTPRequest timeout remains 1 second" % label)


func _verify_clean(client: OnlineProgressClient, fault: StallServer, label: String) -> void:
	for frame in range(3):
		fault.poll()
		await process_frame
	_check(client._adapter._pending.is_empty(), "%s adapter pending map is empty" % label)
	var http_children := 0
	for child in client._adapter.get_children():
		if child is HTTPRequest:
			http_children += 1
	print("CLEANUP %s pending=%d http_request_children=%d" % [label, client._adapter._pending.size(), http_children])
	_check(http_children == 0, "%s leaves no HTTPRequest child" % label)


func _observe_request_node(node: Node) -> void:
	if node is HTTPRequest:
		_request_observations.append({"use_threads": node.use_threads, "timeout": node.timeout})


func _rpc_payload(body: String) -> Dictionary:
	var outer: Variant = JSON.parse_string(body)
	if typeof(outer) != TYPE_STRING:
		return {}
	var inner: Variant = JSON.parse_string(outer)
	return inner if typeof(inner) == TYPE_DICTIONARY else {}


func _new_client(port: int, user_id: String) -> OnlineProgressClient:
	var client := OnlineProgressClient.new()
	client.timeout_sec = 1
	client.configure("127.0.0.1", port)
	root.add_child(client)
	client._session = NakamaSession.new(_unsigned_token(user_id), false)
	client._gameplay_session_id = "00000000-0000-0000-0000-0000000000ff"
	client._get_client()
	return client


func _unsigned_token(user_id: String) -> String:
	var header := Marshalls.utf8_to_base64(JSON.stringify({"alg": "none"}))
	var body := Marshalls.utf8_to_base64(JSON.stringify({"uid": user_id, "usn": "offline", "exp": 4102444800}))
	return "%s.%s.x" % [header.trim_suffix("=").trim_suffix("="), body.trim_suffix("=").trim_suffix("=")]


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	push_error("FAILED: " + message)
	print("FAILED: " + message)
