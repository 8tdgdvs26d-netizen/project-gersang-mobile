class_name OnlineReadTransport
extends Node

## WP01-G C2-E2 A4-Lite: bounded transport for the two approved READ RPCs.
## Every logical read owns a dedicated SDK adapter/client, so its cancel token
## can never point at another request. Writes never enter this class.
##
## Decision rule (exactly once per logical read, first event wins):
## - REPLY: the SDK call returned while the owner deadline timer is still
##   running (time_left > 0 and its timeout not yet dispatched).
## - DEADLINE: the owner deadline timer fired, OR the SDK call returned when
##   the timer had already run out (time_left <= 0) but its timeout signal was
##   not dispatched yet. A reply at or after the deadline is never accepted.
## - CANCELLED: cancel_all() (sign-out, account change, re-login, session
##   begin, configure) came first. The decision is taken at once (a reply
##   after it is late), but the caller is resumed at the end of the frame, so
##   the sign-out / session change that cancelled it has fully finished
##   (client AND screen) before the caller looks at the result. A resumed
##   caller therefore sees the new state and cannot start a new read under
##   the old owner.
## - LOST: the request node left the tree before any other decision.
## Every later event for the same read (a reply after the deadline, the SDK's
## own "cancelled" return, a timer after a reply) only reaches the late
## boundary below: it is counted and dropped, and never re-enters the caller.
##
## The deadline uses the SceneTree clock (process_always, ignore_time_scale),
## so its resolution is one frame step. No wall-clock API is used here.
##
## Owner gate when a decided result is handed back:
## - lifecycle generation, auth epoch, user, gameplay session id and session
##   object must still match the snapshot taken at dispatch; otherwise the
##   result is reported as stale (read_owner_changed);
## - if THIS client learned of a takeover (gameplay_session_superseded) while
##   the read was in flight, the read is refused as superseded and its data is
##   dropped. A takeover the client has not been told about yet cannot be
##   detected here; only the server can refuse such a read.

signal read_started(request_id: int, rpc_id: String)
signal read_finished(request_id: int, rpc_id: String, decision: String, status: String)
signal late_settlement_dropped(request_id: int, rpc_id: String, event: String, original_status: String)

const READ_RPC_IDS := ["vs01_progress_get", "vs01e_progression_get"]
const DEFAULT_REQUEST_TIMEOUT_SEC := 7
const DEFAULT_OWNER_DEADLINE_SEC := 8.0
const DEADLINE_REASON := "read_deadline_exceeded"
const OWNER_CHANGED_REASON := "read_owner_changed"
const LOST_REASON := "read_request_lost"

const DECISION_REPLY := "reply"
const DECISION_DEADLINE := "deadline"
const DECISION_CANCELLED := "cancelled"
const DECISION_LOST := "lost"

const LATE_EVENT_REPLY := "reply_after_decision"
const LATE_EVENT_DEADLINE := "deadline_after_decision"

var request_timeout_sec := DEFAULT_REQUEST_TIMEOUT_SEC
var owner_deadline_sec := DEFAULT_OWNER_DEADLINE_SEC

var _next_request_id := 0
var _lifecycle_generation := 0
var _active := {}
## Diagnostic counters (read by tests only; no behavior depends on them).
var late_dropped_total := 0
var superseded_dropped_total := 0
var stale_dropped_total := 0


class ReadRequest extends Node:
	signal settled(result: Dictionary)
	signal late_event(event: String, original_status: String)

	const SDKAdapter := preload("res://addons/com.heroiclabs.nakama/client/NakamaHTTPAdapter.gd")

	var request_id := 0
	var rpc_id := ""
	var decision := ""
	var settle_emits := 0
	var _delivered := false
	var _pending_result := {}
	var late_events := 0
	var _adapter: Node
	var _sdk_client: NakamaClient
	var _deadline_timer: SceneTreeTimer
	var _decided := false


	func begin(owner: OnlineProgressClient, p_rpc_id: String, payload: Dictionary, timeout_sec: int, deadline_sec: float) -> void:
		rpc_id = p_rpc_id
		_adapter = SDKAdapter.new()
		_adapter.name = "ReadSDKAdapter"
		_adapter.timeout = timeout_sec
		_adapter.use_threads = false
		_adapter.auto_retry = false
		_adapter.auto_retry_count = 1
		add_child(_adapter)
		_sdk_client = NakamaClient.new(_adapter, owner.server_key, owner.scheme, owner.host, owner.port, timeout_sec)
		_sdk_client.auto_retry = false
		_sdk_client.auto_refresh = false
		# The deadline belongs to this request; it starts before the SDK call.
		_deadline_timer = get_tree().create_timer(deadline_sec, true, false, true)
		_deadline_timer.timeout.connect(_on_deadline)
		_run.call_deferred(owner._session, rpc_id, JSON.stringify(payload))


	func is_decided() -> bool:
		return _decided


	func deadline_running() -> bool:
		return _deadline_timer != null and _deadline_timer.time_left > 0.0


	## Ends the read without an answer (deadline, owner change, scene exit).
	func expire(kind: String, reason: String) -> void:
		if _decided:
			if kind == DECISION_DEADLINE:
				_late(LATE_EVENT_DEADLINE, "")
			return
		var result := {"status": OnlineProgressClient.UNCERTAIN, "reason": reason, "timed_out": kind == DECISION_DEADLINE}
		_decide(kind, result, kind == DECISION_CANCELLED)
		# This adapter belongs to this request alone. Its last token therefore
		# cannot cancel a parallel read or any write request.
		if _adapter != null and _sdk_client != null:
			_sdk_client.cancel_request(_adapter.get_last_token())


	## The single entry for an SDK return. Also the late boundary: anything
	## arriving after the decision is counted and dropped here.
	func on_sdk_returned(response: Variant) -> void:
		var normalized := _normalize(response)
		if _decided:
			_late(LATE_EVENT_REPLY, String(normalized.get("status", "")))
			return
		if not deadline_running():
			# Deadline already reached in this frame: the reply is too late.
			expire(DECISION_DEADLINE, DEADLINE_REASON)
			_late(LATE_EVENT_REPLY, String(normalized.get("status", "")))
			return
		_decide(DECISION_REPLY, normalized)


	func _decide(kind: String, result: Dictionary, deferred: bool = false) -> void:
		_decided = true
		decision = kind
		result["decision"] = kind
		_pending_result = result
		if deferred:
			_deliver.call_deferred()
		else:
			_deliver()


	## Hands the decided result to the caller exactly once.
	func _deliver() -> void:
		if _delivered:
			return
		_delivered = true
		settle_emits += 1
		settled.emit(_pending_result)


	func _late(event: String, original_status: String) -> void:
		late_events += 1
		late_event.emit(event, original_status)


	func _on_deadline() -> void:
		expire(DECISION_DEADLINE, DEADLINE_REASON)


	func _run(session: NakamaSession, p_rpc_id: String, payload: String) -> void:
		if _decided:
			queue_free()
			return
		var response = await _sdk_client.rpc_async(session, p_rpc_id, payload)
		on_sdk_returned(response)
		queue_free()


	func _exit_tree() -> void:
		if not _decided:
			expire(DECISION_LOST, LOST_REASON)
		elif not _delivered:
			# Leaving the tree before a deferred delivery: deliver now.
			_deliver()


	static func _normalize(response: Variant) -> Dictionary:
		if response == null or response.is_exception():
			var error: NakamaException = response.get_exception() if response != null else null
			if error != null and error.grpc_status_code > 0:
				return {"status": OnlineProgressClient.REJECTED, "reason": error.message, "grpc_status": error.grpc_status_code}
			return {"status": OnlineProgressClient.UNCERTAIN, "reason": error.message if error != null else "no_response"}
		var data: Variant = JSON.parse_string(response.payload)
		if typeof(data) != TYPE_DICTIONARY:
			return {"status": OnlineProgressClient.UNCERTAIN, "reason": "unreadable_response"}
		return {"status": OnlineProgressClient.OK, "reason": "", "data": data}


func read_rpc(owner: OnlineProgressClient, rpc_id: String, payload: Dictionary) -> Dictionary:
	if rpc_id not in READ_RPC_IDS:
		return {"status": OnlineProgressClient.REJECTED, "reason": "read_rpc_not_allowed"}
	if not owner.is_signed_in():
		return {"status": OnlineProgressClient.NOT_SIGNED_IN, "reason": "not_signed_in"}

	var owner_snapshot := _capture_owner(owner)
	var generation := _lifecycle_generation
	_next_request_id += 1
	var request := ReadRequest.new()
	request.name = "ReadRequest%d" % _next_request_id
	request.request_id = _next_request_id
	var request_id := request.request_id
	_active[request_id] = request
	add_child(request)

	var box := {"done": false, "result": {}}
	request.settled.connect(func(result: Dictionary) -> void:
		if not box["done"]:
			box["done"] = true
			box["result"] = result
	, CONNECT_ONE_SHOT)
	request.late_event.connect(func(event: String, original_status: String) -> void:
		late_dropped_total += 1
		late_settlement_dropped.emit(request_id, rpc_id, event, original_status)
	)
	request.begin(owner, rpc_id, payload, request_timeout_sec, owner_deadline_sec)
	read_started.emit(request_id, rpc_id)
	# settled is emitted exactly once by reply, deadline, cancel or tree exit.
	if not box["done"]:
		await request.settled

	_active.erase(request_id)
	var result: Dictionary = box["result"]
	var decision := String(result.get("decision", ""))
	read_finished.emit(request_id, rpc_id, decision, String(result.get("status", "")))
	if generation != _lifecycle_generation or not _owner_matches(owner, owner_snapshot):
		if result.get("status") == OnlineProgressClient.OK:
			stale_dropped_total += 1
		return {"status": OnlineProgressClient.UNCERTAIN, "reason": OWNER_CHANGED_REASON, "stale": true, "decision": decision}
	if owner.is_gameplay_session_superseded() and not owner_snapshot["superseded"]:
		# Taken over while in flight (this client was told): drop the data.
		if result.get("status") == OnlineProgressClient.OK:
			superseded_dropped_total += 1
		return {"status": OnlineProgressClient.REJECTED, "reason": OnlineProgressClient.SUPERSEDED_REASON,
			"superseded_during_read": true, "discarded_status": result.get("status"), "decision": decision}
	return result


func cancel_all(reason: String = OWNER_CHANGED_REASON) -> void:
	_lifecycle_generation += 1
	for request in _active.values():
		if is_instance_valid(request):
			(request as ReadRequest).expire(DECISION_CANCELLED, reason)


func active_request_count() -> int:
	return _active.size()


## Test probe only: the live request object for an id, or null.
func get_active_request(request_id: int) -> ReadRequest:
	return _active.get(request_id)


func _exit_tree() -> void:
	cancel_all()


static func _capture_owner(owner: OnlineProgressClient) -> Dictionary:
	return {
		"auth_epoch": owner._auth_epoch,
		"user_id": owner.get_user_id(),
		"gameplay_session_id": owner.get_gameplay_session_id(),
		"session": owner._session,
		"superseded": owner.is_gameplay_session_superseded(),
	}


static func _owner_matches(owner: OnlineProgressClient, snapshot: Dictionary) -> bool:
	return owner._auth_epoch == snapshot["auth_epoch"] \
		and owner.get_user_id() == snapshot["user_id"] \
		and owner.get_gameplay_session_id() == snapshot["gameplay_session_id"] \
		and owner._session == snapshot["session"]
