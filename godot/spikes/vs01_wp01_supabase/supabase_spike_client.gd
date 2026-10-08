class_name SupabaseSpikeClient
extends Node

## Disposable VS-01 WP01 probe. It is not wired into the game or Save v14.
## Public URL/key come from the process environment; no secret/service key is accepted.

var _url := OS.get_environment("MYRIAL_SPIKE_SUPABASE_URL").trim_suffix("/")
var _publishable_key := OS.get_environment("MYRIAL_SPIKE_SUPABASE_PUBLISHABLE_KEY")
var _access_token := ""


func is_configured() -> bool:
	return _url.begins_with("https://") and not _publishable_key.is_empty()


func sign_in(email: String, password: String) -> Dictionary:
	if not is_configured():
		return {"ok": false, "errorCode": "ERR_SPIKE_CONFIG"}
	var result := await _request_json(
		"%s/auth/v1/token?grant_type=password" % _url,
		HTTPClient.METHOD_POST,
		PackedStringArray(["apikey: %s" % _publishable_key]),
		{"email": email, "password": password}
	)
	if result.get("ok", false) and result["body"] is Dictionary:
		_access_token = str(result["body"].get("access_token", ""))
		if _access_token.is_empty():
			return {"ok": false, "errorCode": "ERR_AUTH_TOKEN"}
	return result


func invoke(payload: Dictionary) -> Dictionary:
	if _access_token.is_empty():
		return {"ok": false, "errorCode": "ERR_AUTH_REQUIRED"}
	return await _request_json(
		"%s/functions/v1/command" % _url,
		HTTPClient.METHOD_POST,
		PackedStringArray(["apikey: %s" % _publishable_key, "authorization: Bearer %s" % _access_token]),
		payload
	)


func _request_json(url: String, method: int, extra_headers: PackedStringArray, payload: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	var headers := PackedStringArray(["content-type: application/json"])
	for header in extra_headers:
		headers.append(header)
	var start_error := http.request(url, headers, method, JSON.stringify(payload))
	if start_error != OK:
		http.queue_free()
		return {"ok": false, "errorCode": "ERR_HTTP_START", "code": start_error}
	var completed: Array = await http.request_completed
	http.queue_free()
	var transport_result := int(completed[0])
	var status := int(completed[1])
	var bytes := completed[3] as PackedByteArray
	if transport_result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "errorCode": "ERR_NETWORK", "transport": transport_result}
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not parsed is Dictionary:
		return {"ok": false, "errorCode": "ERR_RESPONSE_JSON", "status": status}
	return {"ok": status >= 200 and status < 300, "status": status, "body": parsed}
