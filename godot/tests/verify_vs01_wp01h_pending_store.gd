extends SceneTree

## VS-01 WP01-H E2 — OnlinePendingStore (Blueprint v0.1r3 §3, B-3A, PR-04).
## Offline, isolated user:// only, synthetic accounts and data. Part of the
## normal Godot regression (no server).
##   E2-AC01 durable write / read back, schema, multiple entries
##   E2-AC02 account isolation (file per account, user_id must match)
##   E2-AC03 invalid / corrupt / unknown-version / other-account -> quarantine
##           (moved aside, never deleted), the account stays BLOCKED
##   E2-AC04 write failure -> false (caller sends nothing); a stray temp file
##           from a killed write is ignored
## E2 Targeted Revision:
##   FIX-04 mark journal: escalation only, applied on every load, a damaged /
##          other-account journal -> quarantine + BLOCKED; durable HOLD marker
##          blocks the account across restarts and keeps the live file as is
##   FIX-05 a combat mark with no live command -> claim-less ticket_hold;
##          a live command for ANOTHER ticket next to a mark -> BLOCKED

const U1 := "11111111-1111-1111-1111-111111111111"
const U2 := "22222222-2222-2222-2222-222222222222"
const K1 := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const K2 := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const K3 := "cccccccccccccccccccccccccccccccc"
const T1 := "0123456789abcdef0123456789abcdef"

var _checks := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	print("Isolated user:// for this run: %s" % OS.get_user_data_dir())
	var save_existed := FileAccess.file_exists(SaveStore.DEFAULT_PATH)
	_case_round_trip_and_schema()
	_case_multiple_entries_kept()
	_case_account_isolation()
	_case_corrupt_files_quarantined()
	_case_invalid_entries_refused_on_write()
	_case_write_failure_and_stray_temp()
	_case_marks_journal()
	_case_hold_marker()
	_case_ticket_hold_entry()
	_case_fsf_unmatched_trade_marks()
	_check(FileAccess.file_exists(SaveStore.DEFAULT_PATH) == save_existed and not save_existed, "no gameplay save exists or was created in the isolated user://")
	_check(not _any_file_outside_store(), "nothing written outside user://online_pending/")
	if _failures == 0:
		print("VS-01 WP01-H pending store verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _fresh() -> OnlinePendingStore:
	_wipe("user://online_pending")
	return OnlinePendingStore.new()


static func trade(action := "buy", qty := 10, state := "pending", reason := "") -> Dictionary:
	return {"action": action, "city_id": "A", "good_id": "test_good_01", "quantity": qty, "state": state, "reason": reason}


static func claim(key := K3, state := "pending") -> Dictionary:
	return {"kind": "claim", "key": key, "ticket_id": T1, "payload": {"ticket_id": T1, "outcome": "victory", "kills": 10, "hero_alive": true}, "state": state, "reason": ""}


func _case_round_trip_and_schema() -> void:
	var s := _fresh()
	_check(s.load_account(U1)["status"] == OnlinePendingStore.READY and s.load_account(U1)["trade"].is_empty(), "AC01: no file yet -> READY and empty")
	_check(s.save_account(U1, {K1: trade()}, claim()), "AC01: save succeeds")
	var path := s.path_for(U1)
	_check(path == "user://online_pending/v1/%s.json" % U1.sha256_text(), "AC01: path is per account hash (%s)" % path)
	_check(not FileAccess.file_exists(path + ".tmp"), "AC01: no temp file left after a complete write")
	var outer: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(outer.keys().size() == 4 and outer["format"] == OnlinePendingStore.FORMAT and int(outer["schema_version"]) == 1, "AC01: versioned envelope")
	_check(String(outer["body"]).sha256_text() == outer["body_sha256"], "AC01: checksum over the exact body text")
	var body: Dictionary = JSON.parse_string(outer["body"])
	_check(body["user_id"] == U1 and not body.has("money") and not str(body).contains("money"), "AC01: metadata only (no money / goods / EXP authority)")
	var fresh := OnlinePendingStore.new()  # a new process view
	var loaded := fresh.load_account(U1)
	_check(loaded["status"] == OnlinePendingStore.READY, "AC01: reload READY")
	_check(loaded["trade"] == {K1: trade()}, "AC01: trade entry back exactly, quantity as int (%s)" % str(loaded["trade"]))
	_check(typeof(loaded["trade"][K1]["quantity"]) == TYPE_INT and typeof(loaded["combat"]["payload"]["kills"]) == TYPE_INT, "AC01: whole numbers come back as ints")
	_check(loaded["combat"] == claim(), "AC01: combat entry back exactly")
	_check(fresh.save_account(U1, {}, {}) and fresh.load_account(U1)["trade"].is_empty(), "AC01: clearing is a durable write too")


func _case_multiple_entries_kept() -> void:
	var s := _fresh()
	var t := {}
	for i in range(OnlinePendingStore.MAX_TRADE_ENTRIES):
		t["k%031d" % i] = trade("buy", 1 if i % 2 == 0 else 10)
	_check(s.save_account(U1, t, {}), "AC01: %d pending orders saved together" % t.size())
	var loaded := OnlinePendingStore.new().load_account(U1)
	_check(loaded["trade"].size() == OnlinePendingStore.MAX_TRADE_ENTRIES, "AC01: none lost or overwritten")
	var more := t.duplicate(true)
	more["x".repeat(32)] = trade()
	_check(not s.save_account(U1, more, {}), "AC01: more than the bound is refused (nothing sent then)")
	_check(OnlinePendingStore.new().load_account(U1)["trade"].size() == OnlinePendingStore.MAX_TRADE_ENTRIES, "AC01: a refused write changes nothing")


func _case_account_isolation() -> void:
	var s := _fresh()
	s.save_account(U1, {K1: trade()}, {})
	s.save_account(U2, {K2: trade("sell", 1)}, {})
	_check(s.path_for(U1) != s.path_for(U2), "AC02: one file per account")
	_check(OnlinePendingStore.new().load_account(U1)["trade"].keys() == [K1], "AC02: U1 sees only its own order")
	_check(OnlinePendingStore.new().load_account(U2)["trade"].keys() == [K2], "AC02: U2 sees only its own order")
	# U2's file placed under U1's name: refused (user_id inside must match).
	DirAccess.copy_absolute(s.path_for(U2), s.path_for(U1))
	var r := OnlinePendingStore.new().load_account(U1)
	_check(r["status"] == OnlinePendingStore.BLOCKED and r["trade"].is_empty(), "AC02: another account's metadata under this name -> BLOCKED, nothing imported")
	_check(OnlinePendingStore.new().load_account(U2)["status"] == OnlinePendingStore.READY, "AC02: the other account is not affected")
	_check(OnlinePendingStore.new().load_account("")["status"] == OnlinePendingStore.BLOCKED, "AC02: no account -> BLOCKED")


func _case_corrupt_files_quarantined() -> void:
	var good := ""
	var cases := {
		"truncated": func(t: String) -> String: return t.substr(0, t.length() / 2),
		"garbage": func(_t: String) -> String: return "\u0000ÿ not json",
		"empty file": func(_t: String) -> String: return "",
		"unknown schema version": func(t: String) -> String: return t.replace("\"schema_version\":1", "\"schema_version\":2"),
		"unknown format": func(t: String) -> String: return t.replace(OnlinePendingStore.FORMAT, "other.format"),
		"checksum mismatch (body edited)": func(t: String) -> String: return t.replace("test_good_01", "test_good_02"),
		"extra envelope field": func(t: String) -> String: return t.replace("{\"body\"", "{\"x\":1,\"body\""),
	}
	for name in cases:
		var s := _fresh()
		s.save_account(U1, {K1: trade()}, {})
		good = FileAccess.get_file_as_string(s.path_for(U1))
		var bad: String = cases[name].call(good)
		_write(s.path_for(U1), bad)
		var r := OnlinePendingStore.new().load_account(U1)
		_check(r["status"] == OnlinePendingStore.BLOCKED and r["reason"] == "pending_store_quarantined" and r["trade"].is_empty(), "AC03 %s: BLOCKED + quarantined, nothing trusted (%s)" % [name, str(r)])
		_check(not FileAccess.file_exists(s.path_for(U1)), "AC03 %s: moved out of the live path" % name)
		var q := DirAccess.get_files_at(OnlinePendingStore.QUARANTINE_DIR)
		_check(q.size() == 1 and q[0].begins_with(U1.sha256_text() + ".") and FileAccess.get_file_as_string(OnlinePendingStore.QUARANTINE_DIR + "/" + q[0]) == bad, "AC03 %s: kept byte for byte in quarantine (never deleted)" % name)
		_check(OnlinePendingStore.new().load_account(U1)["status"] == OnlinePendingStore.BLOCKED, "AC03 %s: still BLOCKED after a restart" % name)
		_check(not OnlinePendingStore.new().save_account(U1, {}, {}), "AC03 %s: no new write while quarantined" % name)
		_check(OnlinePendingStore.new().load_account(U2)["status"] == OnlinePendingStore.READY, "AC03 %s: other accounts unaffected" % name)
	# A well-formed file whose ENTRY is invalid (re-signed, so only the entry is wrong).
	for entry_name in ["bad key", "extra entry field", "quantity 2.5", "unknown state"]:
		var s2 := _fresh()
		var body := {"user_id": U1, "seq": 1, "trade": {K1: trade()}, "combat": {}}
		match entry_name:
			"bad key": body["trade"] = {"short": trade()}
			"extra entry field": body["trade"][K1]["price"] = 84
			"quantity 2.5": body["trade"][K1]["quantity"] = 2.5
			"unknown state": body["trade"][K1]["state"] = "done"
		var body_text := JSON.stringify(body, "", true)
		DirAccess.make_dir_recursive_absolute(OnlinePendingStore.ROOT_DIR)
		_write(s2.path_for(U1), JSON.stringify({"format": OnlinePendingStore.FORMAT, "schema_version": 1, "body": body_text, "body_sha256": body_text.sha256_text()}))
		_check(OnlinePendingStore.new().load_account(U1)["status"] == OnlinePendingStore.BLOCKED, "AC03 entry %s: strict schema -> BLOCKED / quarantined" % entry_name)


func _case_invalid_entries_refused_on_write() -> void:
	var s := _fresh()
	_check(not s.save_account(U1, {"short": trade()}, {}), "AC03: an invalid key is never written")
	_check(not s.save_account(U1, {K1: trade("steal")}, {}), "AC03: an invalid action is never written")
	var c := claim()
	c["payload"]["ticket_id"] = "f".repeat(32)
	_check(not s.save_account(U1, {}, c), "AC03: a claim whose payload ticket differs is never written")
	_check(not FileAccess.file_exists(s.path_for(U1)), "AC03: refused writes leave no file")


func _case_write_failure_and_stray_temp() -> void:
	var s := _fresh()
	s.save_account(U1, {K1: trade()}, {})
	var before := FileAccess.get_file_as_string(s.path_for(U1))
	# Make the temp path a directory: the write cannot be done.
	DirAccess.make_dir_recursive_absolute(s.path_for(U1) + ".tmp")
	_check(not s.save_account(U1, {K1: trade(), K2: trade()}, {}), "AC04/PR-04: a failed write returns false")
	_check(FileAccess.get_file_as_string(s.path_for(U1)) == before, "AC04: a failed write leaves the last complete file unchanged")
	DirAccess.remove_absolute(s.path_for(U1) + ".tmp")
	# A temp file from a killed write (complete or half): ignored on load.
	_write(s.path_for(U1) + ".tmp", "{\"half\":")
	var r := OnlinePendingStore.new().load_account(U1)
	_check(r["status"] == OnlinePendingStore.READY and r["trade"].keys() == [K1], "AC04: a stray temp file is ignored; the last complete file is used")
	_check(s.save_account(U1, {K2: trade()}, {}) and OnlinePendingStore.new().load_account(U1)["trade"].keys() == [K2], "AC04: the next write replaces the stray temp file")


func _case_marks_journal() -> void:
	var s := _fresh()
	s.save_account(U1, {K1: trade(), K2: trade("sell", 1)}, claim())
	_check(s.record_marks(U1, {K1: {"state": "quarantined", "reason": "receipt_mismatch"}}, {}), "FIX-04: a mark is recorded")
	var r := OnlinePendingStore.new().load_account(U1)
	_check(r["status"] == OnlinePendingStore.READY and r["trade"][K1]["state"] == "quarantined" and r["trade"][K1]["reason"] == "receipt_mismatch", "FIX-04: a fresh process applies the journal over the live pending entry")
	_check(r["trade"][K2]["state"] == "pending", "FIX-04: unmarked entries untouched")
	_check(s.record_marks(U1, {K1: {"state": "needs_check", "reason": "x"}}, {}) and OnlinePendingStore.new().load_account(U1)["trade"][K1]["state"] == "quarantined", "FIX-04: escalation only (needs_check never lowers quarantined)")
	_check(not s.record_marks(U1, {K1: {"state": "pending", "reason": ""}}, {}), "FIX-04: a pending mark (= release) is refused")
	_check(not s.record_marks(U1, {"short": {"state": "quarantined", "reason": ""}}, {}), "FIX-04: an invalid key is refused")
	_check(s.save_account(U1, {K1: trade(), K2: trade("sell", 1)}, claim()) and OnlinePendingStore.new().load_account(U1)["trade"][K1]["state"] == "quarantined", "FIX-04: a later live write of 'pending' cannot undo a journal mark")
	_check(s.record_marks(U1, {}, {"ticket_id": T1, "state": "needs_check", "reason": "intent_inconsistent"}) and OnlinePendingStore.new().load_account(U1)["combat"]["state"] == "needs_check", "FIX-04: a combat mark on the same ticket escalates the command")
	# Damaged / other-account journals.
	for name in ["garbage", "checksum", "other account"]:
		var s2 := _fresh()
		s2.save_account(U1, {K1: trade()}, {})
		s2.record_marks(U1, {K1: {"state": "quarantined", "reason": "r"}}, {})
		var good := FileAccess.get_file_as_string(s2.marks_path_for(U1))
		var bad := good
		match name:
			"garbage": bad = "{not json"
			"checksum": bad = good.replace("quarantined", "needs_check")
			"other account":
				s2.record_marks(U2, {K1: {"state": "quarantined", "reason": "r"}}, {})
				bad = FileAccess.get_file_as_string(s2.marks_path_for(U2))
		_write(s2.marks_path_for(U1), bad)
		var b := OnlinePendingStore.new().load_account(U1)
		_check(b["status"] == OnlinePendingStore.BLOCKED and b["trade"].is_empty(), "FIX-04 journal %s: BLOCKED, nothing trusted (%s)" % [name, str(b)])
		_check(not FileAccess.file_exists(s2.marks_path_for(U1)) and FileAccess.file_exists(s2.path_for(U1)), "FIX-04 journal %s: journal moved to quarantine, live evidence left in place" % name)
		_check(OnlinePendingStore.new().load_account(U1)["status"] == OnlinePendingStore.BLOCKED, "FIX-04 journal %s: still BLOCKED after a restart" % name)
	# The journal cannot be written -> false (caller then holds the account).
	var s3 := _fresh()
	s3.save_account(U1, {K1: trade()}, {})
	DirAccess.make_dir_recursive_absolute(s3.marks_path_for(U1) + ".tmp")
	_check(not s3.record_marks(U1, {K1: {"state": "quarantined", "reason": "r"}}, {}), "FIX-04: a failed journal write returns false")
	DirAccess.remove_absolute(s3.marks_path_for(U1) + ".tmp")


func _case_hold_marker() -> void:
	var s := _fresh()
	s.save_account(U1, {K1: trade()}, {})
	var live := FileAccess.get_file_as_string(s.path_for(U1))
	_check(not s.has_hold(U1) and s.hold_account(U1, "mark_write_failed") and s.has_hold(U1), "FIX-04: HOLD marker written and read back")
	var r := OnlinePendingStore.new().load_account(U1)
	_check(r["status"] == OnlinePendingStore.BLOCKED and r["reason"] == OnlinePendingStore.HELD_REASON and r["trade"].is_empty(), "FIX-04: a fresh process sees the account HELD (not a normal retry)")
	_check(FileAccess.get_file_as_string(s.path_for(U1)) == live, "FIX-04: the original pending evidence is left byte for byte")
	var names := DirAccess.get_files_at(OnlinePendingStore.QUARANTINE_DIR)
	var marker: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OnlinePendingStore.QUARANTINE_DIR + "/" + names[0]))
	_check(names.size() == 1 and marker["live_file_sha256"] == live.sha256_text() and marker["reason"] == "mark_write_failed" and not str(marker).contains(U1), "FIX-04: the marker records why + the live file hash, no raw user id")
	_check(not OnlinePendingStore.new().save_account(U1, {}, {}), "FIX-04: no write (no clearing) while HELD")
	_check(OnlinePendingStore.new().load_account(U2)["status"] == OnlinePendingStore.READY, "FIX-04: other accounts unaffected")
	var s2 := _fresh()
	_write("user://online_pending", "not a dir")
	_check(not s2.hold_account(U1, "x"), "FIX-04: a HOLD that cannot be written returns false (caller keeps an in-process block)")
	DirAccess.remove_absolute("user://online_pending")


func _case_ticket_hold_entry() -> void:
	var s := _fresh()
	_check(s.record_marks(U1, {}, {"ticket_id": T1, "state": "needs_check", "reason": "recorded_intent_inconsistent"}), "FIX-05: a claim-less mark is recorded")
	var r := OnlinePendingStore.new().load_account(U1)
	_check(r["status"] == OnlinePendingStore.READY and r["combat"] == {"kind": "ticket_hold", "ticket_id": T1, "state": "needs_check", "reason": "recorded_intent_inconsistent"}, "FIX-05: restored as a ticket_hold with no key / payload (%s)" % str(r["combat"]))
	_check(s.save_account(U1, {}, r["combat"]) and OnlinePendingStore.new().load_account(U1)["combat"]["kind"] == "ticket_hold", "FIX-05: the ticket_hold round-trips through the live file")
	var hp := {"kind": "ticket_hold", "ticket_id": T1, "state": "pending", "reason": ""}
	_check(not s.save_account(U1, {}, hp), "FIX-05: a ticket_hold can never be 'pending' (never resendable)")
	var extra: Dictionary = (r["combat"] as Dictionary).duplicate()
	extra["key"] = K3
	_check(not s.save_account(U1, {}, extra), "FIX-05: a ticket_hold with an invented key is refused")
	var other := claim()
	other["ticket_id"] = "f".repeat(32)
	other["payload"]["ticket_id"] = "f".repeat(32)
	_check(s.save_account(U1, {}, other) and OnlinePendingStore.new().load_account(U1)["status"] == OnlinePendingStore.BLOCKED, "FIX-05: a live command for another ticket next to the mark -> BLOCKED")


## Final Safety Fix: a trade journal mark must match a trusted live entry.
func _case_fsf_unmatched_trade_marks() -> void:
	var mark := {K1: {"state": "quarantined", "reason": "receipt_mismatch"}}
	# FSF-01: mark, no live file.
	var s := _fresh()
	_check(s.record_marks(U1, mark, {}), "FSF-01: journal mark recorded")
	var journal := FileAccess.get_file_as_string(s.marks_path_for(U1))
	var r := OnlinePendingStore.new().load_account(U1)
	_check(r["status"] == OnlinePendingStore.BLOCKED and r["reason"] == "pending_store_untrusted" and r["trade"].is_empty() and r["combat"].is_empty(), "FSF-01: journal mark without a live file -> BLOCKED, never READY (%s)" % str(r))
	_check(not FileAccess.file_exists(s.path_for(U1)), "FSF-01: no live file / order rebuilt, no key made")
	_check(FileAccess.get_file_as_string(s.marks_path_for(U1)) == journal, "FSF-01: journal kept byte for byte (evidence)")
	_check(OnlinePendingStore.new().load_account(U1)["status"] == OnlinePendingStore.BLOCKED, "FSF-01/04: still BLOCKED in a fresh process")
	_check(OnlinePendingStore.new().load_account(U2)["status"] == OnlinePendingStore.READY, "FSF-01: other accounts unaffected")
	# FSF-02: live file present, but without the marked entry (other entries trusted).
	s = _fresh()
	s.save_account(U1, {K2: trade("sell", 1)}, {})
	s.record_marks(U1, mark, {})
	var live := FileAccess.get_file_as_string(s.path_for(U1))
	journal = FileAccess.get_file_as_string(s.marks_path_for(U1))
	r = OnlinePendingStore.new().load_account(U1)
	_check(r["status"] == OnlinePendingStore.BLOCKED and r["reason"] == "pending_store_untrusted" and r["trade"].is_empty(), "FSF-02: mark whose entry is missing from the live file -> BLOCKED (%s)" % str(r))
	_check(FileAccess.get_file_as_string(s.path_for(U1)) == live and FileAccess.get_file_as_string(s.marks_path_for(U1)) == journal, "FSF-02: live metadata and journal left unchanged (no clearing / overwrite)")
	_check(DirAccess.get_files_at(OnlinePendingStore.QUARANTINE_DIR).is_empty() if DirAccess.dir_exists_absolute(OnlinePendingStore.QUARANTINE_DIR) else true, "FSF-02: nothing moved or released")
	_check(OnlinePendingStore.new().load_account(U1)["status"] == OnlinePendingStore.BLOCKED, "FSF-02/04: still BLOCKED in a fresh process")
	# Also with a live combat command next to it.
	s = _fresh()
	s.save_account(U1, {}, claim())
	s.record_marks(U1, mark, {})
	_check(OnlinePendingStore.new().load_account(U1)["status"] == OnlinePendingStore.BLOCKED, "FSF-02: mark without its entry blocks even with only a combat command live")
	# FSF-03: journal and live entry agree -> marks applied, other trusted data kept.
	s = _fresh()
	s.save_account(U1, {K1: trade(), K2: trade("sell", 1)}, claim())
	s.record_marks(U1, mark, {})
	r = OnlinePendingStore.new().load_account(U1)
	_check(r["status"] == OnlinePendingStore.READY and r["trade"][K1]["state"] == "quarantined" and r["trade"][K2]["state"] == "pending" and r["combat"] == claim(), "FSF-03: matching mark applied, other entries + combat kept (%s)" % str(r))
	# A combat-only journal (FIX-05) is not affected by the trade rule.
	s = _fresh()
	s.record_marks(U1, {}, {"ticket_id": T1, "state": "needs_check", "reason": "recorded_intent_inconsistent"})
	_check(OnlinePendingStore.new().load_account(U1)["combat"].get("kind") == "ticket_hold", "FSF-03: a combat-only mark still restores the approved ticket_hold")


# --- helpers ---------------------------------------------------------------------

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		_wipe(dir + "/" + sub)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)
	DirAccess.remove_absolute(dir)


func _any_file_outside_store() -> bool:
	for f in DirAccess.get_files_at("user://"):
		if not f.begins_with("."):
			return true
	for d in DirAccess.get_directories_at("user://"):
		if d != "online_pending" and d != "logs" and d != "shader_cache" and d != "vulkan":
			return true
	return false


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
		print("FAILED: " + message)
