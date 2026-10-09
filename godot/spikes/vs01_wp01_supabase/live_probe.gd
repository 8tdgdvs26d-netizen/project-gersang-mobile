extends SceneTree

## Disposable VS-01 WP01 Godot live probe. Not wired into the game or Save v14.
## Reads MYRIAL_SPIKE_* from the process environment; prints no token, key or password.
## Exit codes: 0 PASS, 1 FAIL, 2 BLOCKED (missing environment).

const SupabaseSpikeClientScript := preload("res://spikes/vs01_wp01_supabase/supabase_spike_client.gd")


func _initialize() -> void:
	var email := OS.get_environment("MYRIAL_SPIKE_EMAIL")
	var password := OS.get_environment("MYRIAL_SPIKE_PASSWORD")
	var session_id := OS.get_environment("MYRIAL_SPIKE_SESSION_ID")
	var client = SupabaseSpikeClientScript.new()
	root.add_child(client)
	if not client.is_configured() or email.is_empty() or password.is_empty() or session_id.is_empty():
		print("GODOT_LIVE_PROBE BLOCKED missing MYRIAL_SPIKE_* environment")
		quit(2)
		return
	var checks := {}
	var auth: Dictionary = await client.sign_in(email, password)
	checks["auth"] = auth.get("ok", false)
	var session: Dictionary = await client.invoke({"action": "start_session", "sessionId": session_id})
	checks["session"] = session.get("ok", false)
	var before: Dictionary = await client.invoke({"action": "get_state"})
	checks["get_state"] = before.get("ok", false)
	var command := {
		"action": "apply_test_command", "sessionId": session_id,
		"idempotencyKey": "godot-%d" % Time.get_unix_time_from_system(),
		"moneyDelta": 1, "itemId": "spike_item", "quantityDelta": 1,
	}
	var first: Dictionary = await client.invoke(command)
	var retry: Dictionary = await client.invoke(command)
	checks["idempotency"] = (
		first.get("ok", false) and retry.get("ok", false)
		and retry.get("body", {}).get("replayed", false) == true
		and first["body"]["state"]["revision"] == retry["body"]["state"]["revision"]
	)
	var failed := checks.values().has(false)
	var summary := {}
	for name in checks:
		summary[name] = "PASS" if checks[name] else "FAIL"
	if checks["idempotency"]:
		summary["revision"] = first["body"]["state"]["revision"]
	print("GODOT_LIVE_PROBE %s %s" % ["FAIL" if failed else "PASS", JSON.stringify(summary)])
	quit(1 if failed else 0)
