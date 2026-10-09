extends SceneTree

## VS-01 WP01 spike client offline checks. No network credentials; never contacts Supabase.
## Regression for the Godot live probe ERR_UNCONFIGURED failure (HTTPRequest used before the
## Scene Tree was ready).

const SupabaseSpikeClientScript := preload("res://spikes/vs01_wp01_supabase/supabase_spike_client.gd")
const UNREACHABLE := "https://127.0.0.1:9/spike"

var _checks := 0
var _failures := 0


func _initialize() -> void:
	var early = SupabaseSpikeClientScript.new()
	root.add_child(early)
	_check(not root.is_inside_tree(), "root is outside the tree during _initialize")
	var refused: Dictionary = await early._request_json(UNREACHABLE, HTTPClient.METHOD_POST, PackedStringArray(), {})
	_check(refused.get("errorCode") == "ERR_NOT_IN_TREE", "request before the tree is ready fails clearly")
	_check(early.get_child_count() == 0, "no HTTPRequest is left behind")

	await process_frame
	_check(root.is_inside_tree(), "root is inside the tree after one frame")
	var started: Dictionary = await early._request_json(UNREACHABLE, HTTPClient.METHOD_POST, PackedStringArray(), {})
	_check(started.get("errorCode") == "ERR_NETWORK", "request starts once in the tree (got %s)" % started)
	await process_frame
	_check(early.get_child_count() == 0, "HTTPRequest is freed after completion")

	_check(not early.is_configured(), "client is unconfigured without environment")
	var sign_in: Dictionary = await early.sign_in("probe@example.invalid", "unused")
	_check(sign_in.get("errorCode") == "ERR_SPIKE_CONFIG", "sign_in refuses without configuration")
	var invoke: Dictionary = await early.invoke({"action": "get_state"})
	_check(invoke.get("errorCode") == "ERR_AUTH_REQUIRED", "invoke refuses without a token")

	if _failures == 0:
		print("VS01 spike client verification passed (%d checks)" % _checks)
	else:
		print("VS01 spike client verification FAILED (%d of %d)" % [_failures, _checks])
	quit(1 if _failures else 0)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: ", label)
