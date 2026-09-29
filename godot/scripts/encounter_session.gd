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

signal phase_changed(phase: int)

enum Phase { NONE, JOINING, LOCKED }

const JOIN_WINDOW_MS := 5000
const JOINING_TEXT := "遭遇準備 %.1f..."
const LOCKED_TEXT := "遭遇鎖定"
## TEMPORARY (pre-Combat) recovery button, shown only while LOCKED.
const PROTOTYPE_END_TEXT := "返回世界（原型）"

## Off: triggers are ignored (the WT01–WT05 tests, written before the join
## window existed, run with it off).
var enabled := true

var _handoff: EncounterHandoff
var _player: Player
var _time_source: TimeSource
var _phase := Phase.NONE
var _context: EncounterContext
var _layer: CanvasLayer
var _status_label: Label
var _end_button: Button


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
	_end_button = Button.new()
	_end_button.name = "PrototypeEndButton"
	_end_button.text = PROTOTYPE_END_TEXT
	_end_button.focus_mode = Control.FOCUS_NONE
	_end_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_end_button.add_theme_font_size_override("font_size", 26)
	_end_button.pressed.connect(prototype_end_encounter)
	box.add_child(_end_button)
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
	if _phase != Phase.LOCKED:
		return false
	print("Myrial: prototype end of encounter ", _context.encounter_id)
	_handoff.cancel_pending_encounter()
	_clear()
	return true


func _process(_delta: float) -> void:
	if _phase == Phase.JOINING:
		if get_remaining_ms() == 0:
			_set_phase(Phase.LOCKED)
		else:
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
	_end_button.visible = _phase == Phase.LOCKED
