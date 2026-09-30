class_name EncounterSession
extends Node

## Encounter E01: the join window and lock that follow a WT04 Encounter
## Trigger. It only observes EncounterHandoff (no contact detection of its own)
## and keeps the handoff's pending context as the one active encounter.
##
##   NONE     no active encounter; the player moves normally
##   JOINING  from the trigger for exactly JOIN_WINDOW_MS (TimeSource): the
##            player cannot move or escape, 「遭遇準備 X.X...」 counts down. The
##            window starts once, from the first catch; nothing resets it
##   LOCKED   the window is over, 「遭遇鎖定」. The future Combat System takes it
##            from here (get_context()); E01 starts no combat
##
## Leaving WORLD (city, travel) cancels the encounter through the WT04 recovery
## and unlocks the player. Before Combat exists, a LOCKED encounter is ended by
## the temporary prototype_end_encounter() (button 「返回世界（原型）」). Nothing
## here is saved: a reload starts with no encounter and no lock.
##
## E02: while JOINING, other World Enemy Groups whose aggro radius holds the
## player join through EncounterHandoff.join_groups_in_range() (up to 3; never
## after LOCKED). Joining never resets or extends the window. From 2 groups on
## the overlay adds 「敵軍加入 ×N」.
##
## E02 fix pass: the prototype end starts a 5 s recovery protection
## (PROTECTION_MS, TimeSource, runtime only): the player moves freely, the
## groups keep patrolling but never aggro, and no contact becomes an encounter
## (EncounterHandoff.set_protected). 「遭遇保護 X.X...」 counts it down.
##
## E03: 「挑戰」 shows while a PASSIVE group can be challenged
## (EncounterHandoff.get_challengeable_group(); only with no encounter).
## Pressing it (challenge()) ends any recovery protection at once — protection
## blocks only automatic aggro — and starts the normal encounter: JOINING,
## player locked, the same 5 s window, AGGRESSIVE groups may join.

signal phase_changed(phase: int)

enum Phase { NONE, JOINING, LOCKED }

const JOIN_WINDOW_MS := 5000
const JOINING_TEXT := "遭遇準備 %.1f..."
const LOCKED_TEXT := "遭遇鎖定"
const GROUPS_TEXT := "敵軍加入 ×%d"
## Recovery protection after the prototype end.
const PROTECTION_MS := 5000
const PROTECTION_TEXT := "遭遇保護 %.1f..."
## TEMPORARY (pre-Combat) recovery button, shown only while LOCKED.
const PROTOTYPE_END_TEXT := "返回世界（原型）"
## E03: manual challenge of a PASSIVE group.
const CHALLENGE_TEXT := "挑戰"

## Off: triggers are ignored (the WT01–WT05 tests, written before the join
## window existed, run with it off).
var enabled := true
## The bare-LOCKED prototype exit (「返回世界（原型）」 / prototype_end_encounter).
## C02: main turns it off in the game, so a LOCKED encounter ends only
## through the world lifecycle (end_resolved_encounter); the E01–E03 tests,
## which observe the bare LOCKED phase, keep it.
var prototype_end_enabled := true

var _handoff: EncounterHandoff
var _player: Player
var _time_source: TimeSource
var _phase := Phase.NONE
var _context: EncounterContext
var _layer: CanvasLayer
var _status_label: Label
var _end_button: Button
var _groups_label: Label
var _protection_label: Label
var _protection_ends_ms := -1
var _challenge_button: Button


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "EncounterOverlay"
	_layer.layer = 15
	add_child(_layer)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	box.offset_top = 120.0
	box.offset_bottom = 260.0
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(box)
	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 34)
	_status_label.add_theme_color_override("font_color", Color(0.95, 0.8, 0.45, 1.0))
	box.add_child(_status_label)
	_groups_label = Label.new()
	_groups_label.name = "GroupsLabel"
	_groups_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_groups_label.add_theme_font_size_override("font_size", 28)
	_groups_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.35, 1.0))
	box.add_child(_groups_label)
	_protection_label = Label.new()
	_protection_label.name = "ProtectionLabel"
	_protection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_protection_label.add_theme_font_size_override("font_size", 26)
	_protection_label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.6, 1.0))
	box.add_child(_protection_label)
	_end_button = Button.new()
	_end_button.name = "PrototypeEndButton"
	_end_button.text = PROTOTYPE_END_TEXT
	_end_button.focus_mode = Control.FOCUS_NONE
	_end_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_end_button.add_theme_font_size_override("font_size", 26)
	_end_button.pressed.connect(prototype_end_encounter)
	box.add_child(_end_button)
	_challenge_button = Button.new()
	_challenge_button.name = "ChallengeButton"
	_challenge_button.text = CHALLENGE_TEXT
	_challenge_button.focus_mode = Control.FOCUS_NONE
	_challenge_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_challenge_button.custom_minimum_size = Vector2(200.0, 72.0)
	_challenge_button.add_theme_font_size_override("font_size", 30)
	_challenge_button.pressed.connect(challenge)
	box.add_child(_challenge_button)
	_refresh_ui()


## Starts following `handoff`; `player` is the one locked during the window.
func watch(handoff: EncounterHandoff, player: Player, time_source: TimeSource) -> void:
	_handoff = handoff
	_player = player
	_time_source = time_source
	_handoff.encounter_triggered.connect(_on_encounter_triggered)


func get_phase() -> int:
	return _phase


## The active encounter's context (the WT04 pending context; null when none).
func get_context() -> EncounterContext:
	return _context


## Join window time left (0 once LOCKED or with no encounter).
func get_remaining_ms() -> int:
	if _phase != Phase.JOINING:
		return 0
	return clampi(JOIN_WINDOW_MS - (_time_source.now_ms() - _context.triggered_at_ms), 0, JOIN_WINDOW_MS)


## Leaving WORLD: WT04 cancels any pending encounter (monster home, IDLE) and
## the join window / lock end with it.
func cancel_for_world_exit() -> void:
	_handoff.cancel_pending_encounter()
	if _phase != Phase.NONE:
		print("Myrial: encounter session cancelled (left WORLD)")
		_clear()


## TEMPORARY, pre-Combat only: ends a LOCKED encounter without any result
## (no reward, nothing saved). The monster goes back home through the WT04
## recovery and the player can move again. Refused while JOINING (no escape
## during the window). Returns whether an encounter was ended.
func prototype_end_encounter() -> bool:
	if _phase != Phase.LOCKED or not prototype_end_enabled:
		return false
	print("Myrial: prototype end of encounter ", _context.encounter_id)
	_handoff.cancel_pending_encounter()
	_clear()
	start_recovery_protection()
	return true


## C02: ends the LOCKED encounter `encounter_id` once the world lifecycle
## has resolved it (its groups already handled): no encounter, player
## unlocked. Returns false (nothing changes) for any other state / id.
func end_resolved_encounter(encounter_id: String) -> bool:
	if _phase != Phase.LOCKED or _context == null or _context.encounter_id != encounter_id:
		return false
	print("Myrial: encounter ", encounter_id, " resolved and ended")
	_clear()
	return true


## The 5 s recovery protection (PROTECTION_MS) from now: no group aggroes and
## no contact becomes an encounter until it runs out.
func start_recovery_protection() -> void:
	_protection_ends_ms = _time_source.now_ms() + PROTECTION_MS
	_handoff.set_protected(true)
	_refresh_ui()


func is_protection_active() -> bool:
	return _protection_ends_ms >= 0


## Recovery protection time left (0 when none).
func get_protection_remaining_ms() -> int:
	if _protection_ends_ms < 0:
		return 0
	return clampi(_protection_ends_ms - _time_source.now_ms(), 0, PROTECTION_MS)


## E03: challenges the PASSIVE group in range, if any: ends recovery
## protection and starts a normal encounter. Returns whether one started.
func challenge() -> bool:
	if not enabled or _phase != Phase.NONE or _handoff == null:
		return false
	var target := _handoff.get_challengeable_group()
	if target == null:
		return false
	_end_protection()
	return _handoff.challenge(target.monster_id) != null


func _end_protection() -> void:
	if _protection_ends_ms < 0:
		return
	_protection_ends_ms = -1
	_handoff.set_protected(false)
	print("Myrial: recovery protection over")
	_refresh_ui()


func _process(_delta: float) -> void:
	_refresh_challenge()
	if _protection_ends_ms >= 0:
		if get_protection_remaining_ms() == 0:
			_end_protection()
		_refresh_ui()
	if _phase == Phase.JOINING:
		if get_remaining_ms() == 0:
			_set_phase(Phase.LOCKED)
		else:
			_handoff.join_groups_in_range()
			_refresh_ui()


func _on_encounter_triggered(context: EncounterContext) -> void:
	if not enabled or _phase != Phase.NONE:
		return
	_context = context
	_player.movement_locked = true
	_set_phase(Phase.JOINING)


func _clear() -> void:
	_context = null
	_player.movement_locked = false
	_set_phase(Phase.NONE)


func _set_phase(phase: Phase) -> void:
	if phase == _phase:
		return
	_phase = phase
	print("Myrial: encounter phase ", Phase.keys()[phase])
	_refresh_ui()
	phase_changed.emit(phase)


func _refresh_ui() -> void:
	if _status_label == null:
		return
	match _phase:
		Phase.JOINING:
			# Rounded up to tenths: 5.0 at the start, 0.1 in the last 100 ms.
			_status_label.text = JOINING_TEXT % (ceili(get_remaining_ms() / 100.0) / 10.0)
		Phase.LOCKED:
			_status_label.text = LOCKED_TEXT
		_:
			_status_label.text = ""
	_status_label.visible = _phase != Phase.NONE
	var groups := _context.get_group_count() if _context != null else 0
	_groups_label.text = GROUPS_TEXT % groups if groups >= 2 else ""
	_groups_label.visible = _phase != Phase.NONE and groups >= 2
	var protected := _protection_ends_ms >= 0
	_protection_label.text = PROTECTION_TEXT % (ceili(get_protection_remaining_ms() / 100.0) / 10.0) if protected else ""
	_protection_label.visible = protected
	_end_button.visible = _phase == Phase.LOCKED and prototype_end_enabled
	_refresh_challenge()


func _refresh_challenge() -> void:
	if _challenge_button == null:
		return
	_challenge_button.visible = enabled and _phase == Phase.NONE and _handoff != null \
			and _handoff.get_challengeable_group() != null
