extends SceneTree

## VS-01 WP01-E — the existing GDScript combat EXP / Level rules still produce
## the server golden vectors (nakama/tests/fixtures/wp01e_vectors.json), so the
## isolated Online TEST server copy cannot drift from the offline game. Reads
## rules only: no save, no network.

const CombatVectors := preload("res://tests/vs01_wp01e_combat_vectors.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	var path := ProjectSettings.globalize_path("res://").path_join("../nakama/tests/fixtures/wp01e_vectors.json").simplify_path()
	var text := FileAccess.get_file_as_string(path)
	_check(not text.is_empty(), "Golden vectors exist at %s" % path)
	var stored: Variant = JSON.parse_string(text)
	_check(typeof(stored) == TYPE_DICTIONARY, "Golden vectors parse as JSON")
	if typeof(stored) == TYPE_DICTIONARY:
		# Round-trip the fresh vectors through JSON so int / float typing matches.
		var fresh: Variant = JSON.parse_string(JSON.stringify(CombatVectors.build_vectors()))
		for section in fresh:
			_check(stored.has(section), "Golden vectors have section %s" % section)
			_check(JSON.stringify(stored.get(section)) == JSON.stringify(fresh[section]),
				"GDScript rules still produce the WP01-E golden vectors (%s); regenerate only for an approved rule change" % section)
		_check((stored["gain"] as Array).size() > 500, "Level-gain vectors cover the parameter grid")
		_check((stored["settlement"] as Array).size() > 100, "Settlement vectors cover outcomes, kills and Levels")
	if _failures == 0:
		print("VS-01 WP01-E combat vectors verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
		print("FAILED: " + message)
