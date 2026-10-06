extends SceneTree

## Corrective: post-victory re-engagement. World contact is edge-triggered
## (a group reports the player once, when the overlap begins). A contact
## reported during the 5 s recovery protection is ignored; before this fix
## nothing re-checked it, so an AGGRESSIVE group still on the player when
## protection ended never started an encounter until the player stepped
## away and was touched again. Now the end of protection re-runs the normal
## contact check for every group still in contact.
##
##   1  AGGRESSIVE contact during protection, still overlapping at its end
##      -> a normal encounter starts at once
##   2  contact during protection, separated before its end -> nothing
##   3  PASSIVE overlap -> nothing
##   4  overlap inside a city safe buffer -> nothing
##   5  a pending / active encounter -> no second encounter
##   6-8  after a VICTORY / RETREAT / DEFEAT commit
## Protection itself still blocks every automatic encounter.

const T0 := 1800000000000
const PASSIVE_ONLY := Vector2(950.0, 1080.0)
const G0_HOME := Vector2(800.0, 700.0)

var _checks := 0
var _failures := 0
var _sections_done := []
var _triggers := []


func _initialize() -> void:
	await _verify_overlap_at_end()
	await _verify_separated_before_end()
	await _verify_passive_overlap()
	await _verify_safe_buffer_overlap()
	await _verify_pending_encounter()
	await _verify_after_result(BattleResult.Outcome.VICTORY)
	await _verify_after_result(BattleResult.Outcome.RETREAT)
	await _verify_after_result(BattleResult.Outcome.DEFEAT)
	_check(_sections_done.size() == 8, "Every test section must run to completion (%s)" % str(_sections_done))
	if _failures == 0:
		print("Encounter protection recheck verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- 1. Overlap held through the end of protection ----------------------------------------------

func _verify_overlap_at_end() -> void:
	var main := await _new_main()
	var g0 := _group(main, 0)
	_stand_still(g0)
	_session(main).start_recovery_protection()
	await _overlap_during_protection(main, g0, G0_HOME, "Case 1")
	await _end_protection(main)
	_check(_triggers.size() == 1 and _triggers[0].monster_id == g0.monster_id, "Case 1: protection over while still overlapping: encounter at once, %s primary" % g0.monster_id)
	_check(_session(main).get_phase() == EncounterSession.Phase.JOINING and _handoff(main).has_pending_encounter() and g0.is_held() and _player(main).movement_locked, "Case 1: the normal encounter flow (JOINING, group held, player locked)")
	await _destroy(main)
	_sections_done.append("overlap_at_end")


# --- 2. Separated before protection ends -----------------------------------------------------------

func _verify_separated_before_end() -> void:
	var main := await _new_main()
	var g0 := _group(main, 0)
	_stand_still(g0)
	_session(main).start_recovery_protection()
	await _overlap_during_protection(main, g0, G0_HOME, "Case 2")
	# Out of contact and out of aggro range before the end.
	_player(main).global_position = G0_HOME + Vector2(-300.0, 0.0)
	await _frames(4)
	_check(not g0.is_in_contact() and not g0.overlaps_body(_player(main)), "Case 2: separated during protection (contact cleared)")
	await _end_protection(main)
	await _frames(30)
	_check(_triggers.is_empty() and _session(main).get_phase() == EncounterSession.Phase.NONE, "Case 2: protection over after separating: no encounter")
	await _destroy(main)
	_sections_done.append("separated_before_end")


# --- 3. PASSIVE overlap ----------------------------------------------------------------------------

func _verify_passive_overlap() -> void:
	var main := await _new_main()
	var g3 := _group(main, 2)
	_stand_still(g3)
	_check(g3.is_passive(), "Case 3: group 3 is PASSIVE")
	_session(main).start_recovery_protection()
	await _overlap_during_protection(main, g3, g3.home_position, "Case 3")
	await _end_protection(main)
	await _frames(30)
	_check(_triggers.is_empty() and _session(main).get_phase() == EncounterSession.Phase.NONE and g3.overlaps_body(_player(main)), "Case 3: PASSIVE still overlapping after protection: no encounter")
	await _destroy(main)
	_sections_done.append("passive_overlap")


# --- 4. Safe buffer --------------------------------------------------------------------------------

func _verify_safe_buffer_overlap() -> void:
	var main := await _new_main()
	var g0 := _group(main, 0)
	_stand_still(g0)
	var spot: Vector2 = WorldLayout.CITY_ANCHORS["A"] + Vector2(0.0, 300.0)
	_check(WorldThreatZones.is_in_city_safe_buffer(spot), "Case 4: the spot is inside city A's safe buffer")
	g0.global_position = spot
	_session(main).start_recovery_protection()
	_player(main).global_position = spot
	await _frames(4)
	_check(g0.overlaps_body(_player(main)) and _triggers.is_empty(), "Case 4: overlapping inside the safe buffer during protection, no encounter")
	await _end_protection(main)
	await _frames(30)
	_check(_triggers.is_empty() and _session(main).get_phase() == EncounterSession.Phase.NONE and g0.overlaps_body(_player(main)), "Case 4: safe buffer overlap after protection: no encounter")
	await _destroy(main)
	_sections_done.append("safe_buffer_overlap")


# --- 5. Pending / active encounter ----------------------------------------------------------------

func _verify_pending_encounter() -> void:
	var main := await _new_main()
	var handoff := _handoff(main)
	var g0 := _group(main, 0)
	_stand_still(g0)
	# A challenge started while protected (the handoff itself does not check
	# protection), then the Hero stands on group 1 before protection ends.
	handoff.set_protected(true)
	_player(main).global_position = PASSIVE_ONLY
	await _frames(4)
	var context := handoff.challenge(_group(main, 2).monster_id)
	_check(context != null and _triggers.size() == 1 and handoff.has_pending_encounter(), "Case 5: one pending encounter (challenge)")
	g0.global_position = PASSIVE_ONLY
	await _frames(4)
	_check(g0.overlaps_body(_player(main)), "Case 5: an AGGRESSIVE group overlaps the player too")
	handoff.set_protected(false)
	await _frames(10)
	_check(_triggers.size() == 1 and handoff.get_pending_encounter() == context, "Case 5: protection over with a pending encounter: no second encounter")
	await _destroy(main)
	# Active (LOCKED, in combat): still no second encounter.
	main = await _new_main()
	var locked := await _locked_battle(main)
	_check(locked != null and _session(main).get_phase() == EncounterSession.Phase.LOCKED, "Case 5: an active LOCKED encounter")
	var active := _handoff(main).get_pending_encounter()
	var g0b := _group(main, 0)
	_stand_still(g0b)
	g0b.global_position = _player(main).global_position
	_handoff(main).set_protected(true)
	await _frames(4)
	_handoff(main).set_protected(false)
	await _frames(10)
	_check(_triggers.size() == 1 and _handoff(main).get_pending_encounter() == active and _session(main).get_phase() == EncounterSession.Phase.LOCKED, "Case 5: protection over during an active encounter: no second encounter")
	await _destroy(main)
	_sections_done.append("pending_encounter")


# --- 6-8. After VICTORY / RETREAT / DEFEAT -------------------------------------------------------

func _verify_after_result(outcome: BattleResult.Outcome) -> void:
	var label: String = BattleResult.Outcome.keys()[outcome]
	var main := await _new_main()
	var battle := await _locked_battle(main)
	match outcome:
		BattleResult.Outcome.VICTORY:
			for enemy in battle.get_enemies():
				battle.resolve_damage(battle.get_hero(), enemy, 100000)
		BattleResult.Outcome.RETREAT:
			battle.start_retreat()
			for step in range(100):
				if battle.is_over():
					break
				battle.advance(50)
		BattleResult.Outcome.DEFEAT:
			for friend in battle.get_friends():
				battle.resolve_damage(battle.get_enemies()[0], friend, 100000)
	_check(battle.get_result() != null and battle.get_result().outcome == outcome, "%s reached" % label)
	_triggers.clear()
	(main.get_node("CombatView").get_node("ExitButton") as Button).pressed.emit()
	await _frames(2)
	var session := _session(main)
	_check(session.is_protection_active() and session.get_phase() == EncounterSession.Phase.NONE and main.get_combat() == null, "%s committed: recovery protection running" % label)
	# Stage 10 P03 (approved): a DEFEAT returns the party to the nearest
	# Hospital city; the player walks back out (protection still running)
	# and the same recheck applies in the world.
	if outcome == BattleResult.Outcome.DEFEAT:
		_check(main.is_in_city() and main.current_city_id == "A", "DEFEAT: returned to Hospital city A")
		main.leave_city()
		await _frames(2)
	var g0 := _group(main, 0)
	_stand_still(g0)
	await _overlap_during_protection(main, g0, G0_HOME, label)
	await _end_protection(main)
	_check(_triggers.size() == 1 and _triggers[0].monster_id == g0.monster_id and session.get_phase() == EncounterSession.Phase.JOINING, "%s: protection over while overlapping %s: encounter at once" % [label, g0.monster_id])
	await _destroy(main)
	_sections_done.append("after_%s" % label.to_lower())


# --- Helpers -----------------------------------------------------------------------------------

## The player stands on `monster` at `spot` during protection: the contact is
## reported and ignored (no encounter while protected).
func _overlap_during_protection(main: Node, monster: WorldMonster, spot: Vector2, label: String) -> void:
	_check(_session(main).is_protection_active(), "%s: protection active" % label)
	monster.global_position = spot
	_player(main).global_position = spot
	await _frames(4)
	_check(monster.is_in_contact() and monster.overlaps_body(_player(main)), "%s: contact reported during protection" % label)
	await _frames(30)
	_check(_triggers.is_empty() and _session(main).get_phase() == EncounterSession.Phase.NONE, "%s: no encounter while protected" % label)


## Runs the clock to the end of protection; the session ends it on its next frame.
func _end_protection(main: Node) -> void:
	main.time_source.advance_ms(_session(main).get_protection_remaining_ms())
	await process_frame
	await process_frame
	_check(not _session(main).is_protection_active(), "Protection over")


## A group that stands where it is put (no patrol), so overlaps are stable.
func _stand_still(monster: WorldMonster) -> void:
	monster.patrol_points = []
	monster.reset_to_home()


func _locked_battle(main: Node) -> CombatBattle:
	_player(main).global_position = PASSIVE_ONLY
	await _frames(4)
	_session(main).challenge()
	main.time_source.advance_ms(EncounterSession.JOIN_WINDOW_MS)
	await process_frame
	await process_frame
	var battle: CombatBattle = main.get_combat()
	if battle != null:
		battle.advance(CombatConfig.PREPARATION_MS)
	return battle


func _new_main() -> Node2D:
	_triggers.clear()
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = ""
	main.time_source = TimeSource.fixed(T0)
	root.add_child(main)
	await _frames(4)
	_handoff(main).encounter_triggered.connect(func(context: EncounterContext) -> void: _triggers.append(context))
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


func _frames(count: int) -> void:
	for frame in range(count):
		await physics_frame


func _group(main: Node, index: int) -> WorldMonster:
	for child in main.get_node("Actors").get_children():
		if child is WorldMonster and (child as WorldMonster).group_index == index:
			return child
	return null


func _session(main: Node) -> EncounterSession:
	return main.get_node("EncounterSession") as EncounterSession


func _handoff(main: Node) -> EncounterHandoff:
	return main.get_node("EncounterHandoff") as EncounterHandoff


func _player(main: Node) -> Player:
	return main.get_node("Actors/Player") as Player


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
