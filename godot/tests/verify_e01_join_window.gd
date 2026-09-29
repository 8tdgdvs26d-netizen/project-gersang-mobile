extends SceneTree

## Encounter E01: after a WT04 Encounter Trigger the player is locked for a
## fixed 5 s join window (「遭遇準備 X.X...」), then the encounter is LOCKED
## (「遭遇鎖定」). A temporary prototype action ends it before Combat exists.
## Real main scene, physics frames, fixed TimeSource (no sleeps).

const TEST_SAVE := "user://e01_join_window_test_save.json"
const T0 := 1800000000000
const MONSTER_ID := "prototype_monster_01"
const HOME := Vector2(760.0, 650.0)
const CITY_A := Vector2(200.0, 200.0)
## Inside the monster's aggro range, on open ground: the chase catches the
## player standing here.
const CATCH_SPOT := Vector2(900.0, 650.0)
const FAR := Vector2(3000.0, 3000.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _encounters := []
var _phases := []


func _initialize() -> void:
	_delete(TEST_SAVE)
	_verify_static()
	await _verify_join_and_lock()
	await _verify_world_exit()
	await _verify_reload()
	_delete(TEST_SAVE)
	_check(_sections_done.size() == 4, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("E01 join window verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static ------------------------------------------------------------------------------------

func _verify_static() -> void:
	_check(EncounterSession.JOIN_WINDOW_MS == 5000, "Join window is exactly 5000 ms")
	_check(EncounterSession.Phase.keys() == ["NONE", "JOINING", "LOCKED"], "Phases: NONE, JOINING, LOCKED")
	_check(EncounterSession.LOCKED_TEXT == "遭遇鎖定", "Locked text")
	var code := _code_only("res://scripts/encounter_session.gd")
	var lower := code.to_lower()
	for word in ["body_entered", "overlaps_body", "player_contacted", "area2d"]:
		_check(not lower.contains(word), "No contact detection of its own (%s)" % word)
	for word in ["combat", "battle", "damage", "hp ", "health", "reward", "loot", "retreat", "group", "hostile", "passive", "aggressive", "time.", "os.", "save"]:
		_check(not lower.contains(word), "Not in E01: %s" % word)
	for path in ["res://scripts/encounter_handoff.gd", "res://scripts/world_monster.gd"]:
		_check(not _code_only(path).to_lower().contains("group"), "No enemy-group / multi-group logic in %s" % path.get_file())
	_check(not _code_only("res://scripts/save_store.gd").to_lower().contains("encounter"), "The save format knows nothing about encounters")
	_check(SaveStore.VERSION == 8, "Save version still 8")
	var scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_check(scene.count("world_monster.tscn") == 1 and scene.count("[node name=\"PrototypeMonster\"") == 1, "Exactly one monster in the main scene")
	_check(scene.count("encounter_session.gd") == 1 and not scene.to_lower().contains("combat") and not scene.to_lower().contains("battle"), "One encounter session, no combat scene")
	_sections_done.append("static")


# --- Join window, lock, prototype recovery -----------------------------------------------------------

func _verify_join_and_lock() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	var handoff := _handoff(main)
	var session := _session(main)
	var joystick := main.get_node("TouchControls/Joystick") as TouchJoystick
	_listen(main)
	var money: int = main.wallet.get_balance()
	var cargo: int = main.inventory.get_used_capacity()
	_check(session.get_phase() == EncounterSession.Phase.NONE and not player.movement_locked and not _overlay_visible(session), "Before any catch: no encounter, no lock, no overlay")
	_check(session.prototype_end_encounter() == false, "Prototype end with no encounter: nothing to do")
	# Trigger (WT04, unchanged) -> JOINING.
	var context := await _get_caught(player, 1)
	_check(context != null and context.encounter_id == "encounter_1" and handoff.get_pending_encounter() == context, "The existing WT04 trigger fires from a valid contact")
	_check(_phases == [EncounterSession.Phase.JOINING] and session.get_phase() == EncounterSession.Phase.JOINING, "Exactly one JOINING encounter starts")
	_check(session.get_context() == context, "The session holds the WT04 context itself")
	_check(context.triggered_at_ms == T0 and session.get_remaining_ms() == 5000, "The window starts at the catch: 5000 ms left")
	_check(_status_text(session) == "遭遇準備 5.0..." and _overlay_visible(session) and not _end_button(session).visible, "Countdown shows 遭遇準備 5.0...")
	# Locked player, held monster.
	var caught_at := player.global_position
	var monster_at := monster.global_position
	_check(player.movement_locked and monster.is_held(), "Player locked, monster held")
	await _hold_action(player, "move_left", 30)
	_check(player.global_position == caught_at, "Keyboard movement does nothing during JOINING")
	_touch(joystick, 0, Vector2(200, 900), true)
	_drag(joystick, 0, Vector2(290, 900))
	var touch_direction := joystick.get_direction()
	for frame in range(30):
		await physics_frame
	_touch(joystick, 0, Vector2(290, 900), false)
	_check(touch_direction.length() > 0.5 and player.global_position == caught_at, "Joystick movement does nothing during JOINING (input seen: %s)" % touch_direction)
	_check(monster.global_position == monster_at and monster.is_held(), "The monster stays frozen")
	_check(session.prototype_end_encounter() == false and session.get_phase() == EncounterSession.Phase.JOINING, "No escape during the window (prototype end refused)")
	# Countdown on the fixed clock.
	main.time_source.advance_ms(800)
	await process_frame
	await process_frame
	_check(session.get_remaining_ms() == 4200 and _status_text(session) == "遭遇準備 4.2...", "800 ms later: 遭遇準備 4.2... (%s)" % _status_text(session))
	main.time_source.advance_ms(2000)
	await process_frame
	await process_frame
	_check(_status_text(session) == "遭遇準備 2.2...", "2800 ms: 遭遇準備 2.2...")
	main.time_source.advance_ms(2199)
	await process_frame
	await process_frame
	_check(session.get_phase() == EncounterSession.Phase.JOINING and session.get_remaining_ms() == 1 and _status_text(session) == "遭遇準備 0.1...", "4999 ms: still JOINING, 遭遇準備 0.1...")
	# Duplicates while joining: none.
	await _frames(60)
	session._on_encounter_triggered(EncounterContext.new())
	_check(_encounters.size() == 1 and _phases == [EncounterSession.Phase.JOINING] and session.get_context() == context, "No second encounter while one is active")
	# LOCKED at exactly 5000 ms.
	main.time_source.advance_ms(1)
	await process_frame
	await process_frame
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and _phases == [1, 2], "5000 ms: LOCKED")
	_check(_status_text(session) == "遭遇鎖定" and _end_button(session).visible and _end_button(session).text == "返回世界（原型）", "遭遇鎖定 with the prototype end button")
	main.time_source.advance_ms(60000)
	await process_frame
	await process_frame
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and session.get_remaining_ms() == 0 and _status_text(session) == "遭遇鎖定", "Long after: still LOCKED, never a negative countdown")
	# LOCKED: no combat, nothing awarded, context intact for Combat.
	_check(main.location.is_in_world() and not main.is_in_city() and not main.is_traveling() and player.movement_locked and monster.is_held(), "LOCKED: still in WORLD, locked, held; no combat started")
	_check(main.wallet.get_balance() == money and main.inventory.get_used_capacity() == cargo, "LOCKED: nothing awarded")
	_check(session.get_context() == context and handoff.get_pending_encounter() == context and context.monster_id == MONSTER_ID and context.encounter_id == "encounter_1" and context.threat_zone_id == WorldThreatZones.LOW_THREAT_ZONE_01_ID and context.player_world_position == caught_at and context.trigger_world_position == monster_at and context.triggered_at_ms == T0, "LOCKED keeps the full context for Combat")
	_check(_encounters.size() == 1, "Still exactly one trigger")
	# Temporary recovery.
	_end_button(session).pressed.emit()
	_check(session.get_phase() == EncounterSession.Phase.NONE and session.get_context() == null and not _overlay_visible(session), "Prototype end: encounter cleared, overlay hidden")
	_check(not handoff.has_pending_encounter() and not monster.is_held() and monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE and monster.get_patrol_index() == 0, "Prototype end: monster released, home, IDLE")
	_check(not player.movement_locked, "Prototype end: player unlocked")
	await _hold_action(player, "move_left", 10)
	_check(player.global_position != caught_at, "The player moves again")
	_check(main.wallet.get_balance() == money and main.inventory.get_used_capacity() == cargo, "Prototype end: nothing awarded")
	# Another encounter afterwards, with its own id and a fresh window.
	player.global_position = FAR
	await _frames(300)
	var second := await _get_caught(player, 2)
	_check(second != null and second.encounter_id == "encounter_2" and session.get_context() == second and session.get_phase() == EncounterSession.Phase.JOINING and session.get_remaining_ms() == 5000, "A later catch starts a new 5 s window")
	# A long frame (e.g. back from the background): the clock jumps past the
	# window in one step. LOCKED, never a negative countdown.
	main.time_source.advance_ms(7300)
	_check(session.get_remaining_ms() == 0, "Past the window: 0 ms left, never negative")
	await process_frame
	await process_frame
	_check(session.get_phase() == EncounterSession.Phase.LOCKED and _status_text(session) == "遭遇鎖定" and not _status_text(session).contains("-"), "Jumping past 5000 ms: LOCKED")
	await _destroy(main)
	_sections_done.append("join_and_lock")


# --- Leaving WORLD ---------------------------------------------------------------------------------

func _verify_world_exit() -> void:
	var main := await _new_main("")
	var monster := _monster(main)
	var player := _player(main)
	var handoff := _handoff(main)
	var session := _session(main)
	_listen(main)
	# During JOINING: enter City A.
	await _get_caught(player, 1)
	_check(session.get_phase() == EncounterSession.Phase.JOINING, "Test setup: JOINING")
	player.global_position = CITY_A
	await _settle()
	_check(main.try_enter_city(), "Entered City A during JOINING")
	_check(session.get_phase() == EncounterSession.Phase.NONE and not player.movement_locked and not handoff.has_pending_encounter(), "JOINING cancelled: no encounter, no lock, nothing pending")
	_check(not monster.is_held() and monster.global_position == HOME and monster.get_state() == WorldMonster.State.IDLE, "The monster is back home, IDLE")
	_check(main.leave_city() and not player.movement_locked, "Back in WORLD, free to move")
	var at := player.global_position
	await _hold_action(player, "move_right", 10)
	_check(player.global_position != at, "The player moves after the cancel")
	# During LOCKED: start travel.
	var second := await _get_caught(player, 2)
	main.time_source.advance_ms(5000)
	await process_frame
	await process_frame
	_check(second != null and session.get_phase() == EncounterSession.Phase.LOCKED, "Test setup: LOCKED")
	_check(main.location.enter_city("A") and main.request_transport("B", "e01-ride")["success"] and main.is_traveling(), "Travel started from LOCKED")
	_check(session.get_phase() == EncounterSession.Phase.NONE and not player.movement_locked and not handoff.has_pending_encounter() and not monster.is_held() and monster.global_position == HOME, "LOCKED cancelled: no encounter, no lock, monster home")
	_check(not _overlay_visible(session), "Overlay hidden after the cancel")
	await _destroy(main)
	_sections_done.append("world_exit")


# --- Reload ----------------------------------------------------------------------------------------

func _verify_reload() -> void:
	for lock_first in [false, true]:
		var main := await _new_main(TEST_SAVE, T0)
		var player := _player(main)
		var session := _session(main)
		_listen(main)
		await _get_caught(player, 1)
		if lock_first:
			main.time_source.advance_ms(5000)
			await process_frame
			await process_frame
		var phase := session.get_phase()
		var position := player.global_position
		_check(phase == (EncounterSession.Phase.LOCKED if lock_first else EncounterSession.Phase.JOINING), "Test setup: saving while %s" % EncounterSession.Phase.keys()[phase])
		_check(main.save_world_position(), "Exact world position saves")
		var text := FileAccess.get_file_as_string(TEST_SAVE)
		var lower := text.to_lower()
		_check(int(JSON.parse_string(text)["version"]) == 8 and not lower.contains("encounter") and not lower.contains("joining") and not lower.contains("locked") and not lower.contains("monster"), "Save version 8; no encounter state saved")
		await _destroy(main)
		main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
		main.save_path = TEST_SAVE
		main.time_source = TimeSource.fixed(T0 + 10000)
		root.add_child(main)
		_check(main.get_world_position() == position, "Reload restores the exact world position")
		_check(_session(main).get_phase() == EncounterSession.Phase.NONE and not _player(main).movement_locked and not _handoff(main).has_pending_encounter() and not _overlay_visible(_session(main)), "Reload after %s: no encounter, no lock" % EncounterSession.Phase.keys()[phase])
		_check(_monster(main).global_position == HOME and not _monster(main).is_held(), "Reload: the monster rebuilt at home")
		_check(main.find_children("*", "WorldMonster", true, false).size() == 1, "Reload: still exactly one monster")
		await _destroy(main)
		_delete(TEST_SAVE)
	_sections_done.append("reload")


# --- Helpers ------------------------------------------------------------------------------------

## Stands the player at CATCH_SPOT until trigger number `count` (the chase
## catches the player); returns its context.
func _get_caught(player: Player, count: int) -> EncounterContext:
	player.global_position = CATCH_SPOT
	var frames := 0
	while _encounters.size() < count and frames < 600:
		await physics_frame
		frames += 1
	return _encounters[count - 1] as EncounterContext if _encounters.size() >= count else null


func _listen(main: Node) -> void:
	_encounters.clear()
	_phases.clear()
	_handoff(main).encounter_triggered.connect(func(context: EncounterContext) -> void: _encounters.append(context))
	_session(main).phase_changed.connect(func(phase: int) -> void: _phases.append(phase))


func _hold_action(player: Player, action: String, frames: int) -> void:
	Input.action_press(action)
	for frame in range(frames):
		await physics_frame
	Input.action_release(action)
	await physics_frame


func _touch(joystick: TouchJoystick, index: int, position: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = position
	event.pressed = pressed
	joystick.handle_input_event(event)


func _drag(joystick: TouchJoystick, index: int, position: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = position
	joystick.handle_input_event(event)


func _status_text(session: EncounterSession) -> String:
	return (session.get_node("EncounterOverlay").find_children("StatusLabel", "Label", true, false)[0] as Label).text


func _end_button(session: EncounterSession) -> Button:
	return session.get_node("EncounterOverlay").find_children("PrototypeEndButton", "Button", true, false)[0] as Button


func _overlay_visible(session: EncounterSession) -> bool:
	var label := session.get_node("EncounterOverlay").find_children("StatusLabel", "Label", true, false)[0] as Label
	return label.visible or _end_button(session).visible


func _frames(count: int) -> void:
	for frame in range(count):
		await physics_frame


func _monster(main: Node) -> WorldMonster:
	return main.get_node("Actors/PrototypeMonster") as WorldMonster


func _player(main: Node) -> Player:
	return main.get_node("Actors/Player") as Player


func _handoff(main: Node) -> EncounterHandoff:
	return main.get_node("EncounterHandoff") as EncounterHandoff


func _session(main: Node) -> EncounterSession:
	return main.get_node("EncounterSession") as EncounterSession


func _code_only(path: String) -> String:
	var lines := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			lines.append(line)
	return "\n".join(lines)


func _new_main(path: String, now: int = T0) -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
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


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
