class_name TouchJoystick
extends Control

## Developer-prototype floating joystick. It only turns one finger into a
## direction; the moving character owns speed and physics.

@export_range(16.0, 400.0, 1.0) var radius: float = 96.0
@export_range(0.0, 0.9, 0.01) var dead_zone: float = 0.15
@export_range(0.1, 1.0, 0.05) var control_area_ratio: float = 0.5

const NO_POINTER := -1
const IDLE_MARGIN := Vector2(160.0, 160.0)
const BASE_COLOR := Color(0.88, 0.75, 0.36, 0.22)
const RING_COLOR := Color(0.88, 0.75, 0.36, 0.6)
const KNOB_COLOR := Color(0.88, 0.75, 0.36, 0.75)
const IDLE_COLOR := Color(0.73, 0.79, 0.78, 0.12)

var _pointer_index := NO_POINTER
var _origin := Vector2.ZERO
var _knob_offset := Vector2.ZERO
var _direction := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _input(event: InputEvent) -> void:
	handle_input_event(event)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED, \
		NOTIFICATION_WM_WINDOW_FOCUS_OUT, NOTIFICATION_EXIT_TREE:
			release()
		NOTIFICATION_VISIBILITY_CHANGED:
			if not is_visible_in_tree():
				release()


func get_direction() -> Vector2:
	return _direction


func is_active() -> bool:
	return _pointer_index != NO_POINTER


func handle_input_event(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)


func release() -> void:
	_pointer_index = NO_POINTER
	_knob_offset = Vector2.ZERO
	_direction = Vector2.ZERO
	queue_redraw()


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		# A second press from the movement finger restarts it; any other
		# finger is ignored while the movement finger is held.
		if is_active() and event.index != _pointer_index:
			return
		if not _is_in_control_area(event.position):
			return
		_pointer_index = event.index
		_origin = event.position
		_update_direction(event.position)
	elif event.index == _pointer_index:
		# Covers both a normal release and a system-cancelled touch.
		release()


func _handle_drag(event: InputEventScreenDrag) -> void:
	if event.index != _pointer_index:
		return
	_update_direction(event.position)


func _update_direction(pointer_position: Vector2) -> void:
	_knob_offset = (pointer_position - _origin).limit_length(radius)
	var strength := _knob_offset.length() / radius
	if strength <= dead_zone:
		_direction = Vector2.ZERO
	else:
		var scaled := (strength - dead_zone) / (1.0 - dead_zone)
		_direction = (_knob_offset.normalized() * scaled).limit_length(1.0)
	queue_redraw()


func _is_in_control_area(pointer_position: Vector2) -> bool:
	return pointer_position.x <= get_viewport_rect().size.x * control_area_ratio


func _draw() -> void:
	if not is_active():
		var idle_centre := Vector2(IDLE_MARGIN.x, get_viewport_rect().size.y - IDLE_MARGIN.y)
		draw_arc(idle_centre, radius, 0.0, TAU, 48, IDLE_COLOR, 2.0)
		return
	draw_circle(_origin, radius, BASE_COLOR)
	draw_arc(_origin, radius, 0.0, TAU, 48, RING_COLOR, 2.0)
	draw_circle(_origin + _knob_offset, radius * 0.4, KNOB_COLOR)
