class_name OnlinePendingStore
extends RefCounted

## VS-01 WP01-H (E2) — per-account, versioned Pending Metadata Store
## (Blueprint v0.1r3 §3, WP01-H-①A; B-3A: independent, NON-authoritative
## recovery metadata, NOT a gameplay Development Save).
##
## Holds only what is needed to ask the server for the ONE recorded outcome
## of an operation whose answer was lost: the original idempotency key and
## the original command. Never money, goods, prices or EXP (the server is
## the only authority), never anything of user://myrial_save.json.
##
## Files (one per account, never shared):
##   user://online_pending/v1/<sha256(user_id)>.json        current metadata
##   user://online_pending/v1/<sha256(user_id)>.json.tmp    write in progress
##   user://online_pending/v1/<sha256(user_id)>.marks.json  mark journal (FIX-04)
##   user://online_pending/quarantine/<sha256>.<random>.json      set aside
##   user://online_pending/quarantine/<sha256>.<random>.hold.json HOLD marker
##
## File format (strict; any other shape is untrusted):
##   {"format": FORMAT, "schema_version": 1,
##    "body": "<JSON text>", "body_sha256": "<sha256 of that exact text>"}
## body: {"user_id", "seq", "trade": {key: entry}, "combat": {} or entry}
##
## Durability target (Charlie, 2026-11-20 Risk Acceptance): recovery after an
## APP PROCESS KILL. Godot 4.7.2 FileAccess has no fsync, so an OS crash or
## power loss is NOT covered. Writes: temp file, store_string() result,
## flush() + get_error(), close, read back, rename over the old file
## (DirAccess.rename_absolute), read back again. A kill at any point leaves
## either the old or the new complete file; a stray temp file is ignored and
## overwritten by the next write.
##
## Untrusted, damaged, other-account or unknown-version files are MOVED to
## quarantine (never deleted, never repaired, never guessed). While any
## quarantined file of an account exists, that account's store is BLOCKED
## (B-4A: no new trade / combat writes; reading confirmed progress goes on).
##
## HOLD (E2 FIX-04): when a quarantine / needs-check mark cannot be written
## into the live file, hold_account() writes a small marker into quarantine
## instead; the live file is left untouched as evidence. A held account is
## BLOCKED exactly like a quarantined one, also after a restart. Nothing in
## this store removes a quarantined file or a hold (no automatic release,
## no unlock function: release needs the approved manual review).
##
## MARK JOURNAL (E2 FIX-04): a quarantine / needs-check decision is first
## recorded (atomically) in the account's mark journal, then in the live
## file. load_account() applies the journal to the live entries: a mark can
## only ESCALATE an entry (pending -> needs_check / quarantined), never undo
## one. So once the journal write is complete, a process kill before (or a
## failure of) the live write cannot bring the entry back as a plain pending
## one after a restart. The journal is never removed; a damaged or
## other-account journal blocks the account like a damaged live file.
##
## Combat slot kinds: "claim" / "abandon" (an original command) or, FIX-05,
## "ticket_hold" {kind, ticket_id, state, reason}: a ticket blocked for
## review WITHOUT any claim (none is ever invented for it).

const FORMAT := "myrial.vs01.wp01h.pending_metadata"
const SCHEMA_VERSION := 1
const ROOT_DIR := "user://online_pending/v1"
const QUARANTINE_DIR := "user://online_pending/quarantine"
const MAX_TRADE_ENTRIES := 32
const HOLD_FORMAT := "myrial.vs01.wp01h.pending_hold"
const HELD_REASON := "pending_store_held"
const QUARANTINED_REASON := "pending_store_quarantined"
const MAX_SAFE := 9007199254740991
const MARKS_FORMAT := "myrial.vs01.wp01h.pending_marks"
const MARK_KEYS := ["state", "reason"]
const COMBAT_MARK_KEYS := ["ticket_id", "state", "reason"]

## load_account() status.
const READY := "ready"        # trusted (or no file yet): entries are usable
const BLOCKED := "blocked"    # untrusted / quarantined / unreadable: block writes

## Entry states.
const STATE_PENDING := "pending"          # outcome unknown: recover with the original key
const STATE_NEEDS_CHECK := "needs_check"  # server could not decide it (resolve_command_invalid, inconsistent intent)
const STATE_QUARANTINED := "quarantined"  # conflicting / untrusted answer: no automatic retry or clearing
const ENTRY_STATES := [STATE_PENDING, STATE_NEEDS_CHECK, STATE_QUARANTINED]

const TRADE_KEYS := ["action", "city_id", "good_id", "quantity", "state", "reason"]
const COMBAT_KEYS := ["kind", "key", "ticket_id", "payload", "state", "reason"]
const TICKET_HOLD_KEYS := ["kind", "ticket_id", "state", "reason"]
const CLAIM_PAYLOAD_KEYS := ["ticket_id", "outcome", "kills", "hero_alive"]
const ABANDON_PAYLOAD_KEYS := ["ticket_id", "confirm"]
const OUTCOMES := ["victory", "retreat", "defeat"]
const MAX_INT := 1000000

var root_dir := ROOT_DIR
var quarantine_dir := QUARANTINE_DIR
## Last written / loaded seq per account (monotonic write counter).
var _seq := {}
var _key_regex := RegEx.create_from_string("^[A-Za-z0-9_-]{16,64}$")
var _ticket_regex := RegEx.create_from_string("^[0-9a-f]{32}$")


static func account_hash(user_id: String) -> String:
	return user_id.sha256_text()


func path_for(user_id: String) -> String:
	return "%s/%s.json" % [root_dir, account_hash(user_id)]


func marks_path_for(user_id: String) -> String:
	return "%s/%s.marks.json" % [root_dir, account_hash(user_id)]


## Reads and strictly validates one account's metadata.
## {"status": READY|BLOCKED, "reason", "trade": {key: entry}, "combat": {} or entry}
func load_account(user_id: String) -> Dictionary:
	var empty := {"status": READY, "reason": "", "trade": {}, "combat": {}}
	if user_id.is_empty():
		return _blocked("no_account")
	if has_hold(user_id):
		return _blocked(HELD_REASON)
	if has_quarantine(user_id):
		return _blocked(QUARANTINED_REASON)
	var path := path_for(user_id)
	if not FileAccess.file_exists(path):
		_seq[user_id] = int(_seq.get(user_id, 0))
		return _apply_marks(user_id, {}, {})
	var text := FileAccess.get_file_as_string(path)
	if FileAccess.get_open_error() != OK:
		return _blocked("pending_store_unreadable")
	var parsed := _parse(text, user_id)
	if not parsed["ok"]:
		if quarantine_file(user_id, path, String(parsed["reason"])):
			return _blocked(QUARANTINED_REASON)
		return _blocked("pending_store_untrusted")
	_seq[user_id] = int(parsed["seq"])
	return _apply_marks(user_id, parsed["trade"], parsed["combat"])


## Persists the WHOLE metadata of one account. Refuses (false) anything that
## would not pass load_account() again, and a blocked account. A false
## result means nothing new is durable: the caller must not send the RPC.
func save_account(user_id: String, trade: Dictionary, combat: Dictionary) -> bool:
	if user_id.is_empty() or has_quarantine(user_id):
		return false
	if trade.size() > MAX_TRADE_ENTRIES:
		return false
	for key in trade:
		if not valid_trade_entry(key, trade[key]):
			return false
	if not combat.is_empty() and not valid_combat_entry(combat):
		return false
	var seq := int(_seq.get(user_id, 0)) + 1
	var body := {"user_id": user_id, "seq": seq, "trade": trade.duplicate(true), "combat": combat.duplicate(true)}
	var body_text := JSON.stringify(body, "", true)
	var text := JSON.stringify({"format": FORMAT, "schema_version": SCHEMA_VERSION, "body": body_text, "body_sha256": body_text.sha256_text()}, "", true)
	if not _atomic_write(path_for(user_id), text):
		return false
	_seq[user_id] = seq
	return true


## FIX-04: records quarantine / needs-check marks durably BEFORE the live
## file is rewritten. `trade_marks`: key -> {"state", "reason"};
## `combat_mark`: {} or {"ticket_id", "state", "reason"}. Merged with the
## marks already recorded (escalation only). True only if written + read back.
func record_marks(user_id: String, trade_marks: Dictionary, combat_mark: Dictionary) -> bool:
	if user_id.is_empty():
		return false
	var current := _read_marks(user_id)
	if not current["ok"]:
		return false
	var trade: Dictionary = current["trade"]
	for key in trade_marks:
		var m: Dictionary = trade_marks[key]
		if not _valid_mark(m, MARK_KEYS) or typeof(key) != TYPE_STRING or _key_regex.search(key) == null:
			return false
		if not trade.has(key) or _rank(m["state"]) > _rank(trade[key]["state"]):
			trade[key] = {"state": m["state"], "reason": m["reason"]}
	var combat: Dictionary = current["combat"]
	if not combat_mark.is_empty():
		if not _valid_mark(combat_mark, COMBAT_MARK_KEYS) or _ticket_regex.search(String(combat_mark["ticket_id"])) == null:
			return false
		if combat.is_empty() or combat["ticket_id"] != combat_mark["ticket_id"] or _rank(combat_mark["state"]) > _rank(combat["state"]):
			combat = {"ticket_id": combat_mark["ticket_id"], "state": combat_mark["state"], "reason": combat_mark["reason"]}
	if trade.size() > 4 * MAX_TRADE_ENTRIES:
		return false
	var body_text := JSON.stringify({"user_id": user_id, "trade": trade, "combat": combat}, "", true)
	var text := JSON.stringify({"format": MARKS_FORMAT, "schema_version": SCHEMA_VERSION, "body": body_text, "body_sha256": body_text.sha256_text()}, "", true)
	return _atomic_write(marks_path_for(user_id), text)


static func _rank(state: String) -> int:
	return {STATE_PENDING: 0, STATE_NEEDS_CHECK: 1, STATE_QUARANTINED: 2}.get(state, -1)


func _valid_mark(m: Variant, keys: Array) -> bool:
	return typeof(m) == TYPE_DICTIONARY and _keys_exactly(m, keys) and typeof(m["state"]) == TYPE_STRING \
		and m["state"] in [STATE_NEEDS_CHECK, STATE_QUARANTINED] and typeof(m["reason"]) == TYPE_STRING and (m["reason"] as String).length() <= 64


## {"ok", "trade", "combat"}; ok=false for a damaged / other-account journal.
func _read_marks(user_id: String) -> Dictionary:
	var path := marks_path_for(user_id)
	if not FileAccess.file_exists(path):
		return {"ok": true, "trade": {}, "combat": {}}
	var outer: Variant = _json(FileAccess.get_file_as_string(path))
	if typeof(outer) != TYPE_DICTIONARY or not _keys_exactly(outer, ["format", "schema_version", "body", "body_sha256"]) \
			or outer["format"] != MARKS_FORMAT or not _is_whole(outer["schema_version"], 0) or int(outer["schema_version"]) != SCHEMA_VERSION \
			or typeof(outer["body"]) != TYPE_STRING or String(outer["body"]).sha256_text() != outer["body_sha256"]:
		return {"ok": false}
	var body: Variant = _json(outer["body"])
	if typeof(body) != TYPE_DICTIONARY or not _keys_exactly(body, ["user_id", "trade", "combat"]) or body["user_id"] != user_id \
			or typeof(body["trade"]) != TYPE_DICTIONARY or typeof(body["combat"]) != TYPE_DICTIONARY:
		return {"ok": false}
	for key in body["trade"]:
		if typeof(key) != TYPE_STRING or _key_regex.search(key) == null or not _valid_mark(body["trade"][key], MARK_KEYS):
			return {"ok": false}
	var combat: Dictionary = body["combat"]
	if not combat.is_empty() and (not _valid_mark(combat, COMBAT_MARK_KEYS) or typeof(combat["ticket_id"]) != TYPE_STRING or _ticket_regex.search(combat["ticket_id"]) == null):
		return {"ok": false}
	return {"ok": true, "trade": body["trade"], "combat": combat}


## Applies the journal to the live entries (escalation only). A damaged
## journal is moved to quarantine and the account is BLOCKED.
func _apply_marks(user_id: String, trade: Dictionary, combat: Dictionary) -> Dictionary:
	var marks := _read_marks(user_id)
	if not marks["ok"]:
		if quarantine_file(user_id, marks_path_for(user_id), "bad_marks"):
			return _blocked(QUARANTINED_REASON)
		return _blocked("pending_store_untrusted")
	for key in marks["trade"]:
		if not trade.has(key):
			# Final Safety Fix: a trade mark is only ever written for an entry
			# that is durable in the live file, and a marked entry is never
			# cleared. A mark without its live entry (live file missing, or
			# entry missing) is an untrusted state: BLOCKED, never READY.
			# Journal and live file are left in place as evidence; nothing is
			# rebuilt, no key is made, nothing is resent.
			return _blocked("pending_store_untrusted")
	for key in marks["trade"]:
		if _rank(marks["trade"][key]["state"]) > _rank(trade[key]["state"]):
			trade[key]["state"] = marks["trade"][key]["state"]
			trade[key]["reason"] = marks["trade"][key]["reason"]
	var cm: Dictionary = marks["combat"]
	if not cm.is_empty():
		if combat.is_empty():
			# FIX-05: a ticket marked with no live command -> claim-less hold.
			combat = {"kind": "ticket_hold", "ticket_id": cm["ticket_id"], "state": cm["state"], "reason": cm["reason"]}
		elif combat["ticket_id"] == cm["ticket_id"]:
			if _rank(cm["state"]) > _rank(combat["state"]):
				combat["state"] = cm["state"]
				combat["reason"] = cm["reason"]
		else:
			# A marked ticket is never cleared, so a live command for another
			# ticket next to it is inconsistent: fail closed.
			return _blocked("pending_store_untrusted")
	return {"status": READY, "reason": "", "trade": trade, "combat": combat}


func has_quarantine(user_id: String) -> bool:
	if not DirAccess.dir_exists_absolute(quarantine_dir):
		return false
	var prefix := account_hash(user_id) + "."
	for name in DirAccess.get_files_at(quarantine_dir):
		if name.begins_with(prefix):
			return true
	return false


func has_hold(user_id: String) -> bool:
	if not DirAccess.dir_exists_absolute(quarantine_dir):
		return false
	var prefix := account_hash(user_id) + "."
	for name in DirAccess.get_files_at(quarantine_dir):
		if name.begins_with(prefix) and name.ends_with(".hold.json"):
			return true
	return false


## FIX-04: durable HOLD of an account (see the header). The marker records
## why, and the sha256 of the live file as it is now (left untouched). True
## only if the marker is written and read back.
func hold_account(user_id: String, reason: String) -> bool:
	if user_id.is_empty():
		return false
	var live := path_for(user_id)
	var live_text := FileAccess.get_file_as_string(live) if FileAccess.file_exists(live) else ""
	var text := JSON.stringify({"format": HOLD_FORMAT, "schema_version": SCHEMA_VERSION, "user_id_sha256": account_hash(user_id),
		"reason": reason.substr(0, 64), "live_file_present": FileAccess.file_exists(live), "live_file_sha256": live_text.sha256_text()}, "", true)
	var target := "%s/%s.%s.hold.json" % [quarantine_dir, account_hash(user_id), Crypto.new().generate_random_bytes(8).hex_encode()]
	return _atomic_write(target, text, quarantine_dir) and has_hold(user_id)


## Moves a file aside (never deletes it). Only files of this store's root.
func quarantine_file(user_id: String, path: String, _reason: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(quarantine_dir) != OK and not DirAccess.dir_exists_absolute(quarantine_dir):
		return false
	# A random suffix keeps every quarantined file (no clock read: TimeSource rule).
	var target := "%s/%s.%s.json" % [quarantine_dir, account_hash(user_id), Crypto.new().generate_random_bytes(8).hex_encode()]
	return DirAccess.rename_absolute(path, target) == OK and FileAccess.file_exists(target)


# --- Validation ----------------------------------------------------------------

func valid_trade_entry(key: Variant, e: Variant) -> bool:
	if typeof(key) != TYPE_STRING or _key_regex.search(key) == null or typeof(e) != TYPE_DICTIONARY:
		return false
	if not _keys_exactly(e, TRADE_KEYS):
		return false
	if not e["action"] in ["buy", "sell"]:
		return false
	if typeof(e["city_id"]) != TYPE_STRING or (e["city_id"] as String).length() > 16:
		return false
	if typeof(e["good_id"]) != TYPE_STRING or (e["good_id"] as String).length() > 32:
		return false
	if not _is_whole(e["quantity"], 1):
		return false
	return _valid_state(e)


func valid_combat_entry(e: Variant) -> bool:
	if typeof(e) == TYPE_DICTIONARY and e.get("kind") == "ticket_hold":
		# FIX-05: a blocked ticket without any claim.
		return _keys_exactly(e, TICKET_HOLD_KEYS) and typeof(e["ticket_id"]) == TYPE_STRING and _ticket_regex.search(e["ticket_id"]) != null \
			and _valid_state(e) and e["state"] != STATE_PENDING
	if typeof(e) != TYPE_DICTIONARY or not _keys_exactly(e, COMBAT_KEYS):
		return false
	if not e["kind"] in ["claim", "abandon"]:
		return false
	if typeof(e["key"]) != TYPE_STRING or _key_regex.search(e["key"]) == null:
		return false
	if typeof(e["ticket_id"]) != TYPE_STRING or _ticket_regex.search(e["ticket_id"]) == null:
		return false
	var p: Variant = e["payload"]
	if typeof(p) != TYPE_DICTIONARY or p.get("ticket_id") != e["ticket_id"]:
		return false
	if e["kind"] == "claim":
		if not _keys_exactly(p, CLAIM_PAYLOAD_KEYS) or not p["outcome"] in OUTCOMES:
			return false
		if not _is_whole(p["kills"], 0) or typeof(p["hero_alive"]) != TYPE_BOOL:
			return false
	elif not _keys_exactly(p, ABANDON_PAYLOAD_KEYS) or not (typeof(p["confirm"]) == TYPE_BOOL and p["confirm"]):
		return false
	return _valid_state(e)


func _valid_state(e: Dictionary) -> bool:
	return typeof(e["state"]) == TYPE_STRING and e["state"] in ENTRY_STATES and typeof(e["reason"]) == TYPE_STRING and (e["reason"] as String).length() <= 64


## JSON numbers come back as floats; whole numbers are turned into ints.
## Whole number up to 2^53 - 1 (server money / revisions / times).
static func _is_whole_any(v: Variant, minimum: int) -> bool:
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return false
	var f := float(v)
	return is_finite(f) and floor(f) == f and f >= minimum and f <= MAX_SAFE


static func _is_whole(v: Variant, minimum: int) -> bool:
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return false
	var f := float(v)
	return is_finite(f) and floor(f) == f and f >= minimum and f <= MAX_INT


static func _keys_exactly(d: Dictionary, keys: Array) -> bool:
	if d.size() != keys.size():
		return false
	for k in keys:
		if not d.has(k):
			return false
	return true


static func _normalize_trade(e: Dictionary) -> Dictionary:
	return {"action": e["action"], "city_id": e["city_id"], "good_id": e["good_id"], "quantity": int(e["quantity"]), "state": e["state"], "reason": e["reason"]}


static func _normalize_combat(e: Dictionary) -> Dictionary:
	if e["kind"] == "ticket_hold":
		return {"kind": "ticket_hold", "ticket_id": e["ticket_id"], "state": e["state"], "reason": e["reason"]}
	var p: Dictionary = e["payload"]
	var payload := {"ticket_id": p["ticket_id"], "confirm": true} if e["kind"] == "abandon" else {"ticket_id": p["ticket_id"], "outcome": p["outcome"], "kills": int(p["kills"]), "hero_alive": p["hero_alive"]}
	return {"kind": e["kind"], "key": e["key"], "ticket_id": e["ticket_id"], "payload": payload, "state": e["state"], "reason": e["reason"]}


func _parse(text: String, user_id: String) -> Dictionary:
	var bad := func(reason: String) -> Dictionary: return {"ok": false, "reason": reason}
	var outer: Variant = _json(text)
	if typeof(outer) != TYPE_DICTIONARY or not _keys_exactly(outer, ["format", "schema_version", "body", "body_sha256"]):
		return bad.call("not_pending_metadata")
	if outer["format"] != FORMAT:
		return bad.call("unknown_format")
	if not _is_whole(outer["schema_version"], 0) or int(outer["schema_version"]) != SCHEMA_VERSION:
		return bad.call("unknown_schema_version")
	if typeof(outer["body"]) != TYPE_STRING or typeof(outer["body_sha256"]) != TYPE_STRING:
		return bad.call("not_pending_metadata")
	var body_text: String = outer["body"]
	if body_text.sha256_text() != outer["body_sha256"]:
		return bad.call("checksum_mismatch")
	var body: Variant = _json(body_text)
	if typeof(body) != TYPE_DICTIONARY or not _keys_exactly(body, ["user_id", "seq", "trade", "combat"]):
		return bad.call("bad_body")
	if body["user_id"] != user_id:
		return bad.call("other_account")
	if not _is_whole(body["seq"], 0) or typeof(body["trade"]) != TYPE_DICTIONARY or typeof(body["combat"]) != TYPE_DICTIONARY:
		return bad.call("bad_body")
	if (body["trade"] as Dictionary).size() > MAX_TRADE_ENTRIES:
		return bad.call("too_many_entries")
	var trade := {}
	for key in body["trade"]:
		if not valid_trade_entry(key, body["trade"][key]):
			return bad.call("bad_trade_entry")
		trade[key] = _normalize_trade(body["trade"][key])
	var combat := {}
	if not (body["combat"] as Dictionary).is_empty():
		if not valid_combat_entry(body["combat"]):
			return bad.call("bad_combat_entry")
		combat = _normalize_combat(body["combat"])
	return {"ok": true, "seq": int(body["seq"]), "trade": trade, "combat": combat}


## Parses without printing an engine error for damaged input (null if bad).
static func _json(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null


# --- Durable write ---------------------------------------------------------------

## Test seam only: named points between the write steps, used by the WP01-H
## process-kill tests (a subclass kills the process there). No effect here.
func _crash_point(_name: String) -> void:
	pass


func _atomic_write(path: String, text: String, dir: String = "") -> bool:
	var parent := root_dir if dir.is_empty() else dir
	if not DirAccess.dir_exists_absolute(parent) and DirAccess.make_dir_recursive_absolute(parent) != OK:
		return false
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	var stored := f.store_string(text)  # Godot 4.7.2: returns bool (ClassDB-verified, E2 preflight)
	f.flush()
	stored = stored and f.get_error() == OK
	f.close()
	if not stored or FileAccess.get_file_as_string(tmp) != text:
		return false
	_crash_point("tmp_written")
	if DirAccess.rename_absolute(tmp, path) != OK:
		return false
	_crash_point("renamed")
	return FileAccess.get_file_as_string(path) == text


func _blocked(reason: String) -> Dictionary:
	return {"status": BLOCKED, "reason": reason, "trade": {}, "combat": {}}
