extends SceneTree

## World Threat WT04: a valid world-threat contact becomes exactly one pending
## Encounter Trigger + EncounterContext (EncounterHandoff), held until it is
## explicitly consumed. Real main scene, physics frames, fixed TimeSource.

const TEST_SAVE := "user://wt04_encounter_test_save.json"
const T0 := 1800000000000
const MONSTER_ID := "prototype_monster_01"
const ZONE_ID := "low_threat_zone_01"
## E02 fix pass: group 1's home moved from (760, 650) to (800, 700).
const HOME := Vector2(800.0, 700.0)
const CITY_A := Vector2(200.0, 200.0)
const FAR := Vector2(3000.0, 3000.0)
const SAFE_SPOT := Vector2(560.0, 300.0)
## In the zone, inside aggro range: the chase catches a player standing here
## away from home, so a held monster is visibly off its home.
const CATCH_SPOT := Vector2(900.0, 650.0)
## E02 added group_monster_ids (all groups taking part; monster_id stays the
## catching group).
const CONTEXT_FIELDS := ["encounter_id", "group_monster_ids", "monster_id", "player_world_position", "threat_zone_id", "trigger_world_position", "triggered_at_ms"]

var _checks := 0
var _failures := 0
var _sections_done := []
var _events := []
var _states := []
var _encounters := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	await _verify_acceptance_flow()
	await _verify_guards()
	await _verify_world_only()
	await _verify_recovery()
	await _verify_save()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 6, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("WT04 encounter trigger verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(WorldLayout.PROTOTYPE_MONSTER_ID == MONSTER_ID, "Monster id unchanged")
	var fields := []
	for property in EncounterContext.new().get_property_list():
		if property["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			fields.append(property["name"])
	fields.sort()
	_check(fields == CONTEXT_FIELDS, "EncounterContext holds exactly the minimum fields (%s)" % str(fields))
	for path in ["res://scripts/encounter_handoff.gd", "res://scripts/encounter_context.gd"]:
		var code := _code_only(path).to_lower()
		for word in ["randi", "randf", "randomnumbergenerator", "time.", "os.", "combat", "battle", "damage", "hp", "health", "reward", "loot", "attack", "save_store", "change_scene"]:
			# E02: the context carries the approved planned Combat enemy count
			# (planning data only), so "combat" may appear there.
			if word == "combat" and path.ends_with("encounter_context.gd"):
				continue
			_check(not code.contains(word), "%s has no %s" % [path.get_file(), word])
	var monster := _code_only("res://scripts/world_monster.gd")
	_check(not monster.contains("EncounterContext") and not monster.contains("EncounterHandoff") and not monster.to_lower().contains("encounter"), "The monster knows nothing about encounters (only a hold)")
	for unrelated in ["trade_service", "warehouse_service", "market_state", "market_rules", "transport_service", "save_store", "city_hub", "player_location", "trade_cost_ledger"]:
		_check(not _code_only("res://scripts/%s.gd" % unrelated).to_lower().contains("encounter"), "No encounter logic in %s" % unrelated)
	_check(SaveStore.VERSION == 10, "No save schema change (still version 10 (S05))")
	var scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_check(scene.count("[node name=\"PrototypeMonster\"") == 1 and scene.count("encounter_handoff.gd") == 1 and scene.count("[node name=\"EncounterHandoff\" type=\"Node\"") == 1, "One monster, one handoff node (no UI)")
	_sections_done.append("static")


# --- Acceptance flow -------------------------------------------------------------------------------

func _verify_acceptance_flow() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	var handoff := _handoff(main)
	_listen(main)
	var children := main.get_child_count()
	# 1-5: leave City A, safe, walk into the zone and the aggro radius.
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city() and main.leave_city(), "Entered and left City A")
	await _frames(30)
	_check(_states.is_empty() and _encounters.is_empty(), "Safe after leaving City A")
	var frames := await _walk(player, "move_down", func() -> bool: return player.global_position.y >= HOME.y)
	frames = await _walk(player, "move_right", func() -> bool: return not _states.is_empty())
	_check(frames < 300 and _states == [WorldMonster.State.CHASE], "Approaching the monster starts the chase")
	frames = await _walk(player, "move_right", func() -> bool: return player.global_position.x >= 600.0 or not _encounters.is_empty())
	# 6-8: stand still; the monster catches the player: one trigger.
	frames = 0
	while _encounters.is_empty() and frames < 300:
		await physics_frame
		frames += 1
	_check(frames < 300 and _encounters.size() == 1 and _events.size() == 1, "The chase catches the player: exactly one Encounter Trigger (%d frames)" % frames)
	var context := _encounters[0] as EncounterContext
	_check(context != null and context.encounter_id == "encounter_1", "Valid encounter id (%s)" % (context.encounter_id if context else "null"))
	_check(context.monster_id == MONSTER_ID, "Context monster id")
	_check(context.player_world_position == player.global_position, "Context player position (%s)" % context.player_world_position)
	# Contact starts at the edge of the 48 px contact circle (plus the player's
	# half width), before the chase closes to its stop distance.
	_check(context.trigger_world_position == monster.global_position and monster.overlaps_body(player) and context.trigger_world_position.distance_to(context.player_world_position) <= 48.0 + 32.0, "Context trigger (monster) position (%s)" % context.trigger_world_position)
	_check(context.threat_zone_id == ZONE_ID and context.threat_zone_id == WorldThreatZones.LOW_THREAT_ZONE_01_ID, "Context threat zone")
	_check(context.triggered_at_ms == T0, "Context time from the TimeSource")
	_check(handoff.has_pending_encounter() and handoff.get_pending_encounter() == context, "The trigger is pending")
	_check(monster.is_held() and (monster.get_node("StateLabel") as Label).text == "遭遇觸發", "Prototype feedback: 遭遇觸發 on the held monster")
	# 9-10: no combat, no encounter screen, no mode change.
	_check(main.location.is_in_world() and not main.is_in_city() and not main.is_traveling() and player.is_physics_processing() and main.get_child_count() == children, "No encounter screen, combat or mode change")
	# 11: overlap continues while pending: nothing more.
	var frozen := monster.global_position
	await _frames(180)
	_check(_encounters.size() == 1 and _events.size() == 1 and monster.global_position == frozen and monster.get_state() == WorldMonster.State.CHASE, "180 overlapping frames while pending: no new trigger, the monster stays held")
	# A new contact while pending is ignored too.
	frames = await _walk(player, "move_right", func() -> bool: return not monster.is_in_contact())
	player.global_position = monster.global_position + Vector2(10.0, 10.0)
	await _settle()
	_check(_events.size() == 2 and _encounters.size() == 1 and handoff.get_pending_encounter() == context, "Separate + touch again while pending: a contact, no second trigger")
	# 12: consume.
	var taken := handoff.consume_pending_encounter()
	_check(taken == context and not handoff.has_pending_encounter() and handoff.get_pending_encounter() == null, "Consume returns the context and clears it")
	_check(not monster.is_held() and (monster.get_node("StateLabel") as Label).text == "追擊", "Consume releases the monster")
	_check(handoff.consume_pending_encounter() == null, "A second consume has nothing to take")
	await _frames(60)
	_check(_encounters.size() == 1, "Still overlapping after the consume: no new trigger without a new contact")
	# 13-14: separate, get caught again: one new trigger with a new id.
	frames = await _walk(player, "move_right", func() -> bool: return not monster.is_in_contact())
	_check(frames < 300 and _encounters.size() == 1, "Separated")
	frames = 0
	while _encounters.size() == 1 and frames < 300:
		await physics_frame
		frames += 1
	_check(_encounters.size() == 2 and (_encounters[1] as EncounterContext).encounter_id == "encounter_2", "A new contact gives one new trigger")
	_check(_encounters.size() == 2 and (_encounters[1] as EncounterContext).encounter_id != context.encounter_id and _encounters[1] != context, "The new trigger has its own identity")
	await _frames(60)
	_check(_encounters.size() == 2, "Still exactly two triggers")
	# WT02 behaviour with nothing pending: escape past the leash, return home.
	handoff.consume_pending_encounter()
	frames = await _walk(player, "move_right", func() -> bool: return monster.get_state() == WorldMonster.State.RETURNING)
	_check(frames < 300 and _states.back() == WorldMonster.State.RETURNING, "Nothing pending: the leash still ends the chase")
	await _frames(400)
	_check(monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE and _encounters.size() == 2, "Back home, IDLE")
	await _destroy(main)
	_sections_done.append("acceptance")


# --- Guards (valid contact only) ------------------------------------------------------------------

func _verify_guards() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	var handoff := _handoff(main)
	_listen(main)
	monster.set_chase_target(null)
	# Safe buffer: both inside City A's buffer, overlapping.
	monster.global_position = SAFE_SPOT
	player.global_position = SAFE_SPOT + Vector2(0.0, 20.0)
	await _settle()
	_check(WorldThreatZones.safe_buffer_city_at(player.global_position) == "A" and monster.overlaps_body(player), "Test setup: overlapping inside City A's safe buffer")
	_check(_events.is_empty() and _encounters.is_empty(), "Inside a safe buffer: no contact, no trigger")
	handoff._on_player_contacted(MONSTER_ID)
	_check(_encounters.is_empty() and not handoff.has_pending_encounter(), "Handoff rule: a contact inside a safe buffer is never an encounter")
	# Outside safety: the checks one by one.
	monster.global_position = HOME
	player.global_position = FAR
	await _settle()
	handoff._on_player_contacted(MONSTER_ID)
	_check(_encounters.is_empty(), "A contact report without a real overlap (synthetic) is ignored")
	player.global_position = HOME + Vector2(0.0, 30.0)
	await _settle()
	_check(_encounters.size() == 1, "Test setup: a real contact triggers")
	handoff.consume_pending_encounter()
	_encounters.clear()
	handoff._on_player_contacted("")
	handoff._on_player_contacted("prototype_monster_99")
	_check(_encounters.is_empty(), "Missing or foreign monster id: no trigger")
	monster.set_threat_active(false)
	player.global_position = monster.global_position + Vector2(0.0, 30.0)
	await _settle()
	handoff._on_player_contacted(MONSTER_ID)
	_check(_encounters.is_empty(), "Inactive threat: no trigger")
	monster.set_threat_active(true)
	await _destroy(main)
	_sections_done.append("guards")


# --- WORLD only -----------------------------------------------------------------------------------

func _verify_world_only() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var monster := _monster(main)
	var player := _player(main)
	var handoff := _handoff(main)
	_listen(main)
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city(), "Entered City A")
	player.global_position = HOME + Vector2(0.0, 30.0)
	await _frames(60)
	_check(_encounters.is_empty() and _events.is_empty(), "IN_CITY: the player body on the monster: no trigger")
	player.global_position = FAR
	await _settle()
	_check(main.request_transport("B", "wt04-ride")["success"] and main.is_traveling(), "TRAVELING")
	player.global_position = HOME + Vector2(0.0, 30.0)
	await _frames(60)
	_check(_encounters.is_empty() and _events.is_empty(), "TRAVELING: no trigger")
	# Even if the threat were wrongly left on while travelling, no encounter.
	player.global_position = FAR
	await _settle()
	monster.set_threat_active(true)
	player.global_position = HOME + Vector2(0.0, 30.0)
	await _settle()
	_check(_events.size() == 1 and _encounters.is_empty() and not handoff.has_pending_encounter(), "TRAVELING with a stray contact: still no trigger")
	monster.set_threat_active(false)
	player.global_position = FAR
	await _settle()
	main.time_source.advance_ms(90000)
	await process_frame
	_check(main.current_city_id == "B" and main.leave_city() and main.location.is_in_world(), "Arrived in B and back in WORLD")
	# Back in WORLD: a real contact triggers again.
	_events.clear()
	player.global_position = HOME + Vector2(0.0, 30.0)
	await _settle()
	_check(_encounters.size() == 1 and (_encounters[0] as EncounterContext).encounter_id == "encounter_1", "Back in WORLD: a contact triggers")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("world_only")


# --- Recovery: leaving WORLD cancels a pending encounter -----------------------------------------

func _verify_recovery() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var monster := _monster(main)
	var player := _player(main)
	var handoff := _handoff(main)
	_listen(main)
	_check(not handoff.cancel_pending_encounter() and not handoff.has_pending_encounter() and monster.global_position == HOME and _states.is_empty() and _encounters.is_empty(), "Cancel with nothing pending is a safe no-op")
	# Pending in WORLD, the monster held away from home.
	var first := await _get_caught(player, 1)
	_check(first != null and handoff.get_pending_encounter() == first and monster.is_held() and monster.global_position != HOME, "Valid contact: pending, the monster held off home")
	var frozen := monster.global_position
	await _frames(120)
	_check(handoff.get_pending_encounter() == first and monster.is_held() and monster.global_position == frozen, "Staying in WORLD: still pending after 120 frames (no timeout)")
	player.global_position = SAFE_SPOT
	await _settle()
	await _frames(60)
	_check(WorldThreatZones.safe_buffer_city_at(player.global_position) == "A" and main.location.is_in_world() and handoff.get_pending_encounter() == first and monster.is_held() and monster.global_position == frozen, "Crossing into a safe buffer while in WORLD: still pending")
	# WORLD -> IN_CITY: cancelled.
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city() and main.location.is_in_city(), "Entered City A with an encounter pending")
	_check(not handoff.has_pending_encounter() and handoff.get_pending_encounter() == null, "IN_CITY: the pending encounter is cleared")
	_check(not monster.is_held() and (monster.get_node("StateLabel") as Label).text == "待機", "IN_CITY: the hold is released")
	_check(monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE and not monster.is_in_contact(), "IN_CITY: the monster is home, IDLE, no contact latched")
	_check(_encounters.size() == 1, "Cancelling emits no trigger")
	# Back in WORLD: aggro, chase and a new trigger with a new id.
	_check(main.leave_city() and main.location.is_in_world(), "Back in WORLD")
	_states.clear()
	var second := await _get_caught(player, 2)
	_check(_states.size() >= 1 and _states[0] == WorldMonster.State.CHASE, "After the city cancel: the monster aggroes again")
	_check(second != null and second.encounter_id == "encounter_2" and second.encounter_id != first.encounter_id, "After the city cancel: a new trigger with a new id")
	await _frames(60)
	_check(_encounters.size() == 2 and handoff.get_pending_encounter() == second, "Duplicate prevention while pending still holds")
	# WORLD -> TRAVELING: the location switches to the city in data only, so
	# the view goes straight from the world to the travelling screen.
	frozen = monster.global_position
	_check(monster.is_held() and frozen != HOME, "Test setup: held off home again")
	_check(main.location.enter_city("A") and main.request_transport("B", "wt04-recovery-ride")["success"] and main.is_traveling(), "WORLD view straight to TRAVELING")
	_check(not handoff.has_pending_encounter(), "TRAVELING: the pending encounter is cleared")
	_check(not monster.is_held(), "TRAVELING: the hold is released")
	_check(monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE and not monster.is_in_contact(), "TRAVELING: the monster is home, IDLE, no contact latched")
	player.global_position = FAR
	await _settle()
	main.time_source.advance_ms(90000)
	await process_frame
	_check(main.current_city_id == "B" and main.leave_city() and main.location.is_in_world(), "Arrived in B and back in WORLD")
	_states.clear()
	var third := await _get_caught(player, 3)
	_check(_states.size() >= 1 and _states[0] == WorldMonster.State.CHASE, "After the travel cancel: the monster aggroes again")
	_check(third != null and third.encounter_id == "encounter_3" and third.encounter_id != second.encounter_id, "After the travel cancel: a new trigger with a new id")
	# Consume is separate from cancel: it releases in place.
	var held_at := monster.global_position
	_check(handoff.consume_pending_encounter() == third and not monster.is_held() and monster.global_position == held_at and monster.get_state() == WorldMonster.State.CHASE, "Consume still hands back in place (no reset)")
	# The cancel API itself resets the monster, even without a mode change.
	player.global_position = FAR
	await _settle()
	_check(not monster.is_in_contact(), "Test setup: separated")
	_check(await _get_caught(player, 4) != null and monster.is_held(), "Test setup: caught again")
	player.global_position = FAR
	await _settle()
	_check(handoff.cancel_pending_encounter() and not handoff.has_pending_encounter() and not monster.is_held() and monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE, "cancel_pending_encounter(): released, home, IDLE")
	await _frames(30)
	_check(_encounters.size() == 4 and not monster.is_in_contact() and monster.global_position == HOME, "After the cancel: quiet, nothing latched")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("recovery")


# --- Save ----------------------------------------------------------------------------------------

func _verify_save() -> void:
	var main := await _new_main(TEST_SAVE, T0)
	var player := _player(main)
	_listen(main)
	player.global_position = HOME + Vector2(0.0, 30.0)
	await _settle()
	_check(_handoff(main).has_pending_encounter(), "Test setup: an encounter is pending")
	# Walk off (still pending) and save somewhere quiet.
	player.global_position = Vector2(1500.5, 2500.25)
	await _settle()
	_check(_handoff(main).has_pending_encounter() and main.save_world_position(), "Exact world position saves while pending")
	var text := FileAccess.get_file_as_string(TEST_SAVE)
	_check(int(JSON.parse_string(text)["version"]) == 10 and not text.to_lower().contains("encounter") and not text.to_lower().contains("monster"), "Save version 10; no encounter or monster data saved")
	await _destroy(main)
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	_single_group(main)
	_no_patrol(main)
	_no_join_window(main)
	main.save_path = TEST_SAVE
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	_listen(main)
	_check(main.get_world_position() == Vector2(1500.5, 2500.25), "Reload restores the exact position")
	_check(not _handoff(main).has_pending_encounter() and not _monster(main).is_held() and _monster(main).global_position == HOME, "Reload: nothing pending, the monster free at home")
	await _frames(60)
	_check(_encounters.is_empty() and _events.is_empty() and not _handoff(main).has_pending_encounter(), "Reload creates no phantom trigger (60 frames)")
	_check(FileAccess.get_file_as_string(TEST_SAVE) == text, "Loading does not rewrite the save")
	await _destroy(main)
	_delete(TEST_SAVE)
	_sections_done.append("save")


# --- Helpers ------------------------------------------------------------------------------------

func _listen(main: Node) -> void:
	_events.clear()
	_states.clear()
	_encounters.clear()
	_monster(main).player_contacted.connect(func(id: String) -> void: _events.append(id))
	_monster(main).state_changed.connect(func(_id: String, state: int) -> void: _states.append(state))
	_handoff(main).encounter_triggered.connect(func(context: EncounterContext) -> void: _encounters.append(context))


## Stands the player at CATCH_SPOT until the chase makes trigger number `count`.
func _get_caught(player: Player, count: int) -> EncounterContext:
	player.global_position = CATCH_SPOT
	var frames := 0
	while _encounters.size() < count and frames < 300:
		await physics_frame
		frames += 1
	return _encounters[count - 1] as EncounterContext if _encounters.size() >= count else null


## Holds a move action for physics frames until `done` or 300 frames.
func _walk(player: Player, action: String, done: Callable) -> int:
	var frames := 0
	Input.action_press(action)
	while not done.call() and frames < 300:
		await physics_frame
		frames += 1
	Input.action_release(action)
	await physics_frame
	return frames


func _frames(count: int) -> void:
	for frame in range(count):
		await physics_frame


func _monster(main: Node) -> WorldMonster:
	return main.get_node("Actors/PrototypeMonster") as WorldMonster


func _player(main: Node) -> Player:
	return main.get_node("Actors/Player") as Player


func _handoff(main: Node) -> EncounterHandoff:
	return main.get_node("EncounterHandoff") as EncounterHandoff


func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


func _new_main(path: String, now: int = T0) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	_single_group(main)
	_no_patrol(main)
	_no_join_window(main)
	main.save_path = path
	main.time_source = TimeSource.fixed(now)
	root.add_child(main)
	await _settle()
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _delete(path: String) -> void:
	for p in [path, path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _settle() -> void:
	# Area2D overlaps update a few physics frames after a teleport.
	for frame in range(4):
		await physics_frame
	await process_frame


## WT05: the monster stands at home while idle (no patrol loop), the
## premise these checks were written for; verify_wt05_patrol covers patrol.
func _no_patrol(main: Node) -> void:
	(main.get_node("Actors/PrototypeMonster") as WorldMonster).patrol_points = []


## E01: no join window: a caught player keeps moving, the premise these
## checks were written for; verify_e01_join_window covers the lock.
func _no_join_window(main: Node) -> void:
	(main.get_node("EncounterSession") as EncounterSession).enabled = false


## E02: only World Enemy Group 1 (groups 2 and 3 removed before the scene
## starts): the one-group world these checks were written for;
## verify_e02_multi_group covers all three groups.
func _single_group(main: Node) -> void:
	for extra in ["Actors/PrototypeMonster2", "Actors/PrototypeMonster3"]:
		main.get_node(extra).free()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
