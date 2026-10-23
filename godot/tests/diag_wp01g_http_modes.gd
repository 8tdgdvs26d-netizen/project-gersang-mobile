extends SceneTree

## VS-01 WP01-G Phase B — DIAGNOSTIC harness only (Proposal r2.1).
##
## Not a verify_* script and not an acceptance test: a result from here is
## never a T1-T4, Deadline-late or WP01-G PASS. It changes no game code; it
## only uses the existing HTTPRequest, the existing OnlineProgressClient (and
## the SDK adapter that client creates) and, for D5, the existing Trade /
## Combat adapters against a disposable local Nakama.
##
## nakama/scripts/run_wp01g_diag.mjs runs every case as its OWN Godot process
## on a disposable GitHub runner, owns the fault server (outside Godot), the
## 60 s hard cap and the watchdog, and reads only this script's stdout:
##
##   HB <seq> <ticks_ms>        main-thread heartbeat every 250 ms
##   EV {json}                  one client-side event
##   WP01G_DIAG {json}          the case result (missing if the main thread hangs)
##
##   godot --headless --path godot --script res://tests/diag_wp01g_http_modes.gd -- \
##     --case <probe|D1-R|D1-S|D2-R|D2-S|D3-R|D3-S|D4-R-T|D4-R-F|D4-S-F|D5-F|D5-T> --port <n>
##
## Safety: prints no account, password, session token, Authorization header,
## request or response body (only result codes, timings, byte counts and the
## numeric progress fields). Writes no file. Forces the SDK logger to ERROR
## before any SDK request and refuses to send if that cannot be asserted.
## D5 credentials come only from MYRIAL_WP01G_EMAIL / MYRIAL_WP01G_PASSWORD.

const HOST := "127.0.0.1"
const HB_INTERVAL_S := 0.25
const BASELINE_S := 2.0
## Same timeout as T2.
const DIAG_TIMEOUT_S := 2
## Ends before the runner's 60 s hard cap (startup + 2 s baseline + 45 s), so
## "no completion until the hard cap" (H1) is observed by a live main thread.
const OBSERVE_MAX_MS := 45000
const SETTLE_MS := 4000
const D5_STEP_GUARD_MS := 20000
const D5_CITY := "A"
const D5_STEPS := ["sign_in", "session_begin", "trade_read_1", "buy", "trade_read_2", "hero_read"]
const REP := OnlineTradeAdapter.REPRESENTATIVE_GOOD_ID

## layer R = native HTTPRequest; S = the SDK adapter created by OnlineProgressClient;
## D5 = OnlineProgressClient + Trade / Combat adapters against disposable Nakama.
const CASES := {
	"probe": {"layer": "probe", "threads": false},
	"D1-R": {"layer": "R", "threads": true},
	"D1-S": {"layer": "S", "threads": true},
	"D2-R": {"layer": "R", "threads": false},
	"D2-S": {"layer": "S", "threads": false},
	"D3-R": {"layer": "R", "threads": true},
	"D3-S": {"layer": "S", "threads": true},
	"D4-R-T": {"layer": "R", "threads": true},
	"D4-R-F": {"layer": "R", "threads": false},
	"D4-S-F": {"layer": "S", "threads": false},
	"D5-F": {"layer": "D5", "threads": false},
	"D5-T": {"layer": "D5", "threads": true},
}

var _case := ""
var _port := 0
var _hb_seq := 0
var _hb_running := false
var _harness_ok := true
var _notes: Array = []
var _completions: Array = []
var _attempts: Array = []
var _sdk_out: Array = []
var _sdk_return_ticks := 0
var _ev_seq := 0
## S layer: the SDK's HTTPRequest, captured when it enters the tree (before
## the SDK calls request() on it), and its client status for attempt starts.
var _tracked_req: HTTPRequest = null
var _last_status := -1
var _attempt_starts := 0
var _d5_client: OnlineProgressClient
var _d5_trade: OnlineTradeAdapter
var _d5_combat: OnlineCombatAdapter
var _d5_out: Array = []
var _d5_token := 0


func _initialize() -> void:
	await process_frame
	if not _read_args():
		print("WP01G_DIAG " + JSON.stringify({"case": _case, "harness_ok": false, "error": "bad_arguments"}))
		quit(2)
		return
	var save_before := FileAccess.file_exists(SaveStore.DEFAULT_PATH)
	var conf: Dictionary = CASES[_case]
	var layer: String = conf["layer"]
	var threads: bool = conf["threads"]
	var result := {"case": _case, "pid": OS.get_process_id(), "layer": layer, "use_threads_planned": threads}
	if layer == "probe":
		result["user_data_dir"] = OS.get_user_data_dir()
		result["globalized_user"] = ProjectSettings.globalize_path("user://")
		result["home"] = OS.get_environment("HOME")
		result["godot_version"] = Engine.get_version_info().get("string", "")
	else:
		_hb_running = true
		_heartbeat()
		await create_timer(BASELINE_S, true, false, true).timeout
		var part: Dictionary = {}
		match layer:
			"R":
				part = await _run_raw(threads)
			"S":
				part = await _run_sdk(threads)
			"D5":
				part = await _run_d5(threads)
		result.merge(part, true)
		_ev("case_end", {})
		_hb_running = false
	var save_after := FileAccess.file_exists(SaveStore.DEFAULT_PATH)
	result["save_exists_before"] = save_before
	result["save_exists_after"] = save_after
	if save_after:
		_fail("a local save file exists in the isolated user data folder")
	result["harness_ok"] = _harness_ok
	result["notes"] = _notes
	print("WP01G_DIAG " + JSON.stringify(result))
	await process_frame
	quit(0 if _harness_ok else 3)


# --- R layer: native HTTPRequest -------------------------------------------------

func _run_raw(threads: bool) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = float(DIAG_TIMEOUT_S)
	req.use_threads = threads
	root.add_child(req)
	req.request_completed.connect(_on_raw_completed)
	var status := int(req.get_http_client_status())
	_ev("listener_ready", {"layer": "R", "http_client_status": status, "status_is_disconnected": status == HTTPClient.STATUS_DISCONNECTED,
		"http_request_timeout": req.timeout, "http_request_use_threads": req.use_threads})
	_ev("request_start", {"layer": "R", "use_threads": req.use_threads, "timeout_s": req.timeout})
	var err := req.request(_url(), PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, "{}")
	_ev("request_called", {"error": err})
	var start := Time.get_ticks_msec()
	if err != OK:
		_fail("HTTPRequest.request() returned %d" % err)
	else:
		await _observe(start, _completions)
	# The node is deliberately NOT freed here: freeing a threaded request that
	# never finished would itself wait for its thread (see the RCA).
	return {"completions": _completions.size(), "observe_ms": Time.get_ticks_msec() - start}


func _on_raw_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var rec := _completion_record(result, response_code, body)
	_completions.append(rec)
	_ev("completion", rec)


# --- S layer: the SDK adapter created by OnlineProgressClient --------------------

func _run_sdk(threads: bool) -> Dictionary:
	var out := {}
	var client := OnlineProgressClient.new()
	root.add_child(client)
	if not ("_adapter" in client):
		_fail("OnlineProgressClient has no _adapter member")
		return out
	# T2 order: the adapter already exists (sign-in created it with the default
	# timeout), then the test sets timeout_sec = 2 and calls configure() again.
	client.configure(HOST, _port)
	client._get_client()
	var adapter = client.get("_adapter")
	if adapter == null:
		_fail("OnlineProgressClient did not create an adapter")
		return out
	out["adapter_timeout_initial"] = adapter.get("timeout")
	client.timeout_sec = DIAG_TIMEOUT_S
	client.configure(HOST, _port)
	client._get_client()
	adapter = client.get("_adapter")
	if adapter == null or not _force_quiet_logger(adapter):
		return out
	adapter.set("use_threads", threads)
	var info := {
		"adapter_timeout": adapter.get("timeout"),
		"adapter_use_threads": adapter.get("use_threads"),
		"auto_retry": adapter.get("auto_retry"),
		"auto_retry_count": adapter.get("auto_retry_count"),
		"logger_level": _logger_level(adapter),
	}
	_ev("adapter_ready", info)
	out.merge(info, true)
	# R1: the completion listener is attached BEFORE the SDK starts the request.
	# send_async() creates the HTTPRequest, sets timeout / use_threads, then
	# add_child(req) (NakamaHTTPAdapter.gd L146-L177) and only afterwards
	# _send_async() -> make_request() -> request.request() (L179, L197, L71).
	# add_child() emits child_entered_tree on the adapter synchronously
	# (Godot node.cpp L1711 -> L1701 -> L341 -> L371), so _on_adapter_child()
	# runs while the request is not yet started (status DISCONNECTED, checked).
	(adapter as Node).child_entered_tree.connect(_on_adapter_child)
	_ev("request_start", {"layer": "S", "use_threads": threads})
	var start := Time.get_ticks_msec()
	_start_send(adapter)
	if _tracked_req == null:
		_fail("SDK HTTPRequest was not captured before the request started")
		_ev("listener_missing", {})
	else:
		out["http_request_timeout"] = _tracked_req.timeout
		out["http_request_use_threads"] = _tracked_req.use_threads
		_poll_attempt_status()
	await _observe(start, _sdk_out)
	out["attempts_started"] = _attempt_starts
	out["attempts_completed"] = _attempts.size()
	out["sdk_returned"] = not _sdk_out.is_empty()
	if not _sdk_out.is_empty():
		out["sdk_result"] = _describe_sdk(_sdk_out[0])
	out["observe_ms"] = Time.get_ticks_msec() - start
	return out


## Runs inside add_child(req) in the SDK, before req.request() is called.
func _on_adapter_child(node: Node) -> void:
	if _tracked_req != null or not (node is HTTPRequest):
		return
	_tracked_req = node as HTTPRequest
	_tracked_req.request_completed.connect(_on_attempt_completed)
	var status := int(_tracked_req.get_http_client_status())
	_last_status = status
	_ev("listener_ready", {"layer": "S", "http_client_status": status, "status_is_disconnected": status == HTTPClient.STATUS_DISCONNECTED,
		"http_request_timeout": _tracked_req.timeout, "http_request_use_threads": _tracked_req.use_threads})


## Attempt start = the SDK's HTTPRequest leaves STATUS_DISCONNECTED (polled once
## per frame on the main thread; an attempt that starts and ends inside one
## frame is not seen, which the runner reports as an incomplete timeline).
func _poll_attempt_status() -> void:
	if _tracked_req == null or not is_instance_valid(_tracked_req):
		return
	var status := int(_tracked_req.get_http_client_status())
	if status == _last_status:
		return
	if status != HTTPClient.STATUS_DISCONNECTED and _last_status == HTTPClient.STATUS_DISCONNECTED:
		_attempt_starts += 1
		_ev("attempt_started", {"attempt": _attempt_starts, "http_client_status": status})
	_ev("http_status", {"from": _last_status, "to": status})
	_last_status = status


func _start_send(adapter) -> void:
	var r = await adapter.send_async("POST", _url(), {"Content-Type": "application/json"}, "{}".to_utf8_buffer())
	_sdk_out.append(r)
	_ev("sdk_return", _describe_sdk(r))


func _on_attempt_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var rec := _completion_record(result, response_code, body)
	rec["attempt"] = _attempts.size() + 1
	_attempts.append(rec)
	_ev("attempt_completed", rec)


func _describe_sdk(r) -> Dictionary:
	if r is NakamaException:
		var ex: NakamaException = r
		return {"exception": true, "status_code": ex.status_code, "grpc_status_code": ex.grpc_status_code,
			"cancelled": ex.cancelled, "message": ex.message.left(120)}
	return {"exception": false, "type": typeof(r)}


# --- D5: existing client read / write path, disposable Nakama -------------------

func _run_d5(threads: bool) -> Dictionary:
	var out := {"steps": []}
	var email := OS.get_environment("MYRIAL_WP01G_EMAIL")
	var password := OS.get_environment("MYRIAL_WP01G_PASSWORD")
	if email.is_empty() or password.is_empty():
		_fail("D5 account not provided through the environment")
		return out
	var client := OnlineProgressClient.new()
	root.add_child(client)
	client.configure(HOST, _port)
	client._get_client()
	var adapter = client.get("_adapter")
	if adapter == null or not _force_quiet_logger(adapter):
		return out
	if not threads:
		adapter.set("use_threads", false)
	out["adapter_use_threads"] = adapter.get("use_threads")
	out["adapter_timeout"] = adapter.get("timeout")
	_ev("adapter_ready", {"adapter_use_threads": out["adapter_use_threads"], "adapter_timeout": out["adapter_timeout"], "logger_level": _logger_level(adapter)})
	_d5_client = client
	_d5_trade = OnlineTradeAdapter.new(client)
	_d5_combat = OnlineCombatAdapter.new(client)
	for step in D5_STEPS:
		var rec: Dictionary = await _d5_step(step, email, password)
		(out["steps"] as Array).append(rec)
		if not bool(rec.get("ok", false)):
			break
	client.sign_out_local()
	return out


func _d5_step(step: String, email: String, password: String) -> Dictionary:
	_d5_out.clear()
	_d5_token += 1
	var t0 := Time.get_ticks_msec()
	_ev("d5_step_start", {"step": step})
	_d5_start(step, email, password, _d5_token)
	while _d5_out.is_empty() and Time.get_ticks_msec() - t0 < D5_STEP_GUARD_MS:
		await process_frame
	var rec := {"step": step, "elapsed_ms": Time.get_ticks_msec() - t0}
	if _d5_out.is_empty():
		rec["ok"] = false
		rec["status"] = "harness_step_guard_expired"
		_notes.append("D5 step %s did not return within %d ms" % [step, D5_STEP_GUARD_MS])
	else:
		rec.merge(_d5_values(step, _d5_out[0]), true)
	_ev("d5_step_end", rec)
	return rec


func _d5_start(step: String, email: String, password: String, token: int) -> void:
	var r: Dictionary = {}
	match step:
		"sign_in":
			r = await _d5_client.sign_in_email_test(email, password, true)
		"session_begin":
			r = await _d5_trade.begin()
		"trade_read_1", "trade_read_2":
			r = await _d5_trade.refresh()
		"buy":
			r = await _d5_trade.buy(D5_CITY, 1)
		"hero_read":
			r = await _d5_combat.refresh()
	if token == _d5_token:
		_d5_out.append(r)


## Only result codes and numeric progress fields (never tokens or bodies).
func _d5_values(step: String, r: Dictionary) -> Dictionary:
	var rec := {}
	if step == "buy":
		rec["ok"] = bool(r.get("success", false))
		rec["status"] = str(r.get("online_status", ""))
		rec["total_value"] = int(r.get("total_value", 0))
		rec["pending"] = bool(r.get("pending", false))
		rec["replayed"] = bool(r.get("replayed", false))
	else:
		rec["ok"] = r.get("status") == OnlineProgressClient.OK
		rec["status"] = str(r.get("status", ""))
	rec["reason"] = str(r.get("reason", "")).left(80)
	var view := _d5_client.get_confirmed_progress()
	if not view.is_empty():
		rec["money"] = int(view.get("money", -1))
		var backpack: Variant = view.get("backpack", {})
		rec["goods"] = int((backpack as Dictionary).get(REP, 0)) if typeof(backpack) == TYPE_DICTIONARY else -1
		rec["trade_revision"] = int(view.get("revision", -1))
	if step == "hero_read":
		var hero := _d5_combat.get_confirmed_progression()
		for key in ["level", "exp", "exp_to_next", "revision"]:
			if hero.has(key):
				rec["hero_" + key] = int(hero[key])
	return rec


# --- Helpers -----------------------------------------------------------------------

func _read_args() -> bool:
	var args := OS.get_cmdline_user_args()
	var seen := {}
	var i := 0
	while i < args.size():
		var flag: String = args[i]
		if not flag in ["--case", "--port"] or seen.has(flag) or i + 1 >= args.size():
			return false
		seen[flag] = true
		var value: String = args[i + 1]
		if flag == "--case":
			_case = value
		else:
			if not value.is_valid_int():
				return false
			_port = value.to_int()
		i += 2
	if not CASES.has(_case):
		return false
	if _case != "probe" and (_port < 1 or _port > 65535):
		return false
	return true


func _heartbeat() -> void:
	while _hb_running:
		print("HB %d %d" % [_hb_seq, Time.get_ticks_msec()])
		_hb_seq += 1
		await create_timer(HB_INTERVAL_S, true, false, true).timeout


## Waits on the main thread until `done` has an entry and SETTLE_MS passed
## since the last completion (late second completions are still recorded),
## or until OBSERVE_MAX_MS after `start`.
func _observe(start: int, done: Array) -> void:
	while true:
		_poll_attempt_status()
		var now := Time.get_ticks_msec()
		if now - start >= OBSERVE_MAX_MS:
			_ev("observe_window_end", {"reason": "max"})
			return
		if not done.is_empty():
			var last := _last_event_ticks()
			if now - last >= SETTLE_MS:
				_ev("observe_window_end", {"reason": "settled"})
				return
		await process_frame


func _last_event_ticks() -> int:
	var last := 0
	for list in [_completions, _attempts]:
		for rec in list:
			last = maxi(last, int(rec["t"]))
	if not _sdk_out.is_empty():
		last = maxi(last, _sdk_return_ticks)
	return last


func _completion_record(result: int, response_code: int, body: PackedByteArray) -> Dictionary:
	return {"result": result, "is_timeout": result == HTTPRequest.RESULT_TIMEOUT,
		"is_success": result == HTTPRequest.RESULT_SUCCESS, "http_code": response_code,
		"body_bytes": body.size(), "t": Time.get_ticks_msec()}


func _force_quiet_logger(adapter) -> bool:
	var logger = adapter.get("logger")
	if logger == null or not ("_level" in logger):
		_fail("SDK logger missing; request not sent")
		return false
	logger.set("_level", NakamaLogger.LOG_LEVEL.ERROR)
	var level = logger.get("_level")
	var ok: bool = typeof(level) == TYPE_INT and int(level) <= NakamaLogger.LOG_LEVEL.ERROR
	_ev("logger_assert", {"ok": ok, "level": level})
	if not ok:
		_fail("SDK logger level is above ERROR; request not sent")
	return ok


func _logger_level(adapter) -> int:
	var logger = adapter.get("logger")
	return int(logger.get("_level")) if logger != null else -1


func _url() -> String:
	return "http://%s:%d/wp01g/diag/%s" % [HOST, _port, _case]


func _ev(name: String, fields: Dictionary) -> void:
	var data := fields.duplicate()
	_ev_seq += 1
	data["n"] = _ev_seq
	data["e"] = name
	data["t"] = Time.get_ticks_msec()
	if name == "sdk_return":
		_sdk_return_ticks = int(data["t"])
	print("EV " + JSON.stringify(data))


func _fail(message: String) -> void:
	_harness_ok = false
	_notes.append(message)
	print("WP01G_HARNESS_ERROR " + message)
