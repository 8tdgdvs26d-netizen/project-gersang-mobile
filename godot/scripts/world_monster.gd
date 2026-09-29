class_name WorldMonster
extends Area2D

## World Threat: the single prototype monster.
## WT01: stable identity, fixed home position, edge-triggered player contact.
## WT02: a three-state aggro / chase / disengage loop, WORLD mode only:
##   IDLE      -> the player comes within AGGRO_RADIUS of the monster -> CHASE
##   CHASE     -> the player is farther than LEASH_RADIUS from home   -> RETURNING
##   RETURNING -> reaches home (last few pixels snap)                  -> IDLE
## RETURNING ignores the player until it is home; only IDLE can aggro. The
## gap between the two radii keeps the states from flickering at an edge.
## Movement is a straight line at MOVE_SPEED (slower than the player, so the
## player can always escape). Each step is shape-cast against the static
## obstacles one axis at a time: it stops at a wall and slides along it, never
## passes through, and does no pathfinding. The monster stays an Area2D (it
## has no physics body, so it never pushes or blocks the player). Nothing here
## is saved: deactivating the threat (city, travel) puts the monster back at
## home in IDLE, and a load rebuilds it there.
## WT03: city safe buffers are sanctuaries (WorldThreatZones). A player in one
## is never aggroed and reports no contact; a chase ends (-> RETURNING) as soon
## as the player, or the monster itself, is inside one. The home must lie
## outside every safe buffer.
## WT04: while an encounter it triggered is pending (EncounterHandoff), the
## monster is held: its AI stands still in its current state, it shows
## 「遭遇觸發」, and it resumes only when the handoff releases it.
## WT05: an IDLE monster patrols (「巡邏」): it walks its fixed loop of
## patrol_points at PATROL_SPEED, from the first point on, and aggroes as
## before. Reaching home after a chase, or any reset to home, restarts the
## loop from its first point. No patrol points: it stands at home (「待機」).
## E02 fix pass: the patrol is a controlled irregular itinerary (points
## revisited in a varied order) with deterministic pauses (patrol_pauses,
## seconds, counted in physics time) at some stops; aggro still works while
## paused and a chase ends the pause. set_aggro_suppressed() (recovery
## protection) stops all aggro: an IDLE monster keeps patrolling but ignores
## the player, a chasing one turns back.

signal player_contacted(monster_id: String)
signal state_changed(monster_id: String, state: int)

enum State { IDLE, CHASE, RETURNING }

## The player must come this close to the idle monster to be chased.
const AGGRO_RADIUS := 240.0
## The chase ends once the player is farther than this from the monster's home.
const LEASH_RADIUS := 450.0
## Chase and return speed in px/s (the player walks at 220 px/s).
const MOVE_SPEED := 160.0
## Patrol speed in px/s: a slow walk, well under the chase speed.
const PATROL_SPEED := 60.0
## The chase holds this far from the player (inside the 48 px contact area).
const CHASE_STOP_DISTANCE := 24.0
## Within this distance of home the monster settles exactly on it.
const HOME_SNAP_DISTANCE := 4.0
## Radius of the shape that is kept out of obstacles; also the margin kept
## from the world edge.
const BODY_RADIUS := 24.0
## Physics layer of the static obstacles the movement respects.
const OBSTACLE_MASK := 1
## Player-visible state text (minimal prototype indicator).
const STATE_TEXT := {
	State.IDLE: "待機",
	State.CHASE: "追擊",
	State.RETURNING: "返回",
}
## Shown while IDLE with a patrol loop.
const PATROL_TEXT := "巡邏"
## Shown while held for a pending handoff (WT04).
const HOLD_TEXT := "遭遇觸發"

## E02: which prototype World Enemy Group this monster is (index into
## WorldLayout.PROTOTYPE_GROUPS); setting it takes that group's id, home and
## patrol loop. Group 0 (the default) is the WT01–WT05 monster.
@export_range(0, 2) var group_index := 0:
	set(value):
		group_index = value
		var group: Dictionary = WorldLayout.PROTOTYPE_GROUPS[value]
		monster_id = group["id"]
		home_position = group["home"]
		patrol_points = (group["patrol"] as Array).duplicate()
		patrol_pauses = (group["pauses"] as Array).duplicate()
var monster_id := WorldLayout.PROTOTYPE_MONSTER_ID
var home_position := WorldLayout.PROTOTYPE_MONSTER_POSITION
## The patrol loop (world positions), walked in order while IDLE.
var patrol_points: Array = WorldLayout.PROTOTYPE_MONSTER_PATROL.duplicate()
## Pause (seconds) after reaching each patrol point; 0 or missing: none.
var patrol_pauses: Array = WorldLayout.PROTOTYPE_MONSTER_PATROL_PAUSES.duplicate()
var _active := true
var _in_contact := false
var _state := State.IDLE
var _target: Node2D
var _held := false
var _patrol_index := 0
var _pause_left := 0.0
var _aggro_suppressed := false
var _step_query := PhysicsShapeQueryParameters2D.new()

@onready var _state_label := $StateLabel as Label


func _ready() -> void:
	if WorldThreatZones.is_in_city_safe_buffer(home_position):
		push_error("Myrial: world threat %s has its home inside a city safe buffer" % monster_id)
	position = home_position
	var body := CircleShape2D.new()
	body.radius = BODY_RADIUS
	_step_query.shape = body
	_step_query.collision_mask = OBSTACLE_MASK
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_refresh_label()


func is_threat_active() -> bool:
	return _active


func is_in_contact() -> bool:
	return _in_contact


func get_state() -> int:
	return _state


func is_held() -> bool:
	return _held


## Freezes (true) or resumes (false) the AI while a handoff is pending (WT04).
## State, position and contact are kept as they are.
func set_hold(held: bool) -> void:
	_held = held
	_refresh_label()


## The node the monster watches and chases (the player; null: none). Movement
## never collides with it.
func set_chase_target(target: Node2D) -> void:
	_target = target
	_step_query.exclude = [target.get_rid()] if target is CollisionObject2D else []


func set_threat_active(active: bool) -> void:
	_active = active
	if not active:
		_in_contact = false
		reset_to_home()


## Index of the patrol point the monster is walking to.
func get_patrol_index() -> int:
	return _patrol_index


func is_patrol_paused() -> bool:
	return _pause_left > 0.0


## Recovery protection: while true the monster never aggroes or keeps chasing.
func set_aggro_suppressed(suppressed: bool) -> void:
	_aggro_suppressed = suppressed


func is_aggro_suppressed() -> bool:
	return _aggro_suppressed


## Back to the deterministic start: at home, IDLE, patrol loop from its start.
func reset_to_home() -> void:
	global_position = home_position
	_patrol_index = 0
	_pause_left = 0.0
	_set_state(State.IDLE)


func _physics_process(delta: float) -> void:
	if not _active or _held:
		return
	match _state:
		State.IDLE:
			if not _aggro_suppressed and _target != null and global_position.distance_to(_target.global_position) <= AGGRO_RADIUS \
					and not WorldThreatZones.is_in_city_safe_buffer(_target.global_position):
				_pause_left = 0.0
				_set_state(State.CHASE)
			elif not patrol_points.is_empty():
				_patrol(delta)
		State.CHASE:
			if _aggro_suppressed or _target == null or home_position.distance_to(_target.global_position) > LEASH_RADIUS \
					or WorldThreatZones.is_in_city_safe_buffer(_target.global_position) \
					or WorldThreatZones.is_in_city_safe_buffer(global_position):
				_set_state(State.RETURNING)
			else:
				_move_toward(_target.global_position, CHASE_STOP_DISTANCE, delta)
		State.RETURNING:
			if global_position.distance_to(home_position) <= HOME_SNAP_DISTANCE:
				global_position = home_position
				_patrol_index = 0
				_pause_left = 0.0
				_set_state(State.IDLE)
			else:
				_move_toward(home_position, 0.0, delta)


## One patrol step; on reaching the current point, pause there if it has a
## pause, then aim for the next point of the itinerary.
func _patrol(delta: float) -> void:
	if _pause_left > 0.0:
		_pause_left = maxf(_pause_left - delta, 0.0)
		if _pause_left == 0.0:
			_patrol_index = (_patrol_index + 1) % patrol_points.size()
		return
	var point: Vector2 = patrol_points[_patrol_index]
	_move_toward(point, 0.0, delta, PATROL_SPEED)
	if global_position.distance_to(point) <= 0.01:
		global_position = point
		var pause: float = patrol_pauses[_patrol_index] if _patrol_index < patrol_pauses.size() else 0.0
		if pause > 0.0:
			_pause_left = pause
		else:
			_patrol_index = (_patrol_index + 1) % patrol_points.size()


## One physics step toward `point` at `speed`, never closer than
## `stop_distance`, sliding along static obstacles and kept inside the world.
func _move_toward(point: Vector2, stop_distance: float, delta: float, speed := MOVE_SPEED) -> void:
	var offset := point - global_position
	var distance := offset.length()
	if distance <= stop_distance:
		return
	var motion := offset / distance * minf(speed * delta, distance - stop_distance)
	_cast_step(Vector2(motion.x, 0.0))
	_cast_step(Vector2(0.0, motion.y))
	var margin := Vector2(BODY_RADIUS, BODY_RADIUS)
	global_position = global_position.clamp(WorldBoundary.BOUNDS.position + margin, WorldBoundary.BOUNDS.end - margin)


## Moves by `motion`, or only as far as it can before touching an obstacle.
func _cast_step(motion: Vector2) -> void:
	if motion == Vector2.ZERO:
		return
	_step_query.transform = Transform2D(0.0, global_position)
	_step_query.motion = motion
	var safe := get_world_2d().direct_space_state.cast_motion(_step_query)
	global_position += motion * safe[0]


func _set_state(state: State) -> void:
	if state == _state:
		return
	_state = state
	_refresh_label()
	print("Myrial: world threat ", monster_id, " state ", State.keys()[state])
	state_changed.emit(monster_id, state)


func _refresh_label() -> void:
	if _held:
		_state_label.text = HOLD_TEXT
	elif _state == State.IDLE and not patrol_points.is_empty():
		_state_label.text = PATROL_TEXT
	else:
		_state_label.text = STATE_TEXT[_state]


func _on_body_entered(body: Node2D) -> void:
	if not body is Player or not _active or _in_contact:
		return
	if WorldThreatZones.is_in_city_safe_buffer(body.global_position):
		return
	_in_contact = true
	print("Myrial: world threat contact ", monster_id)
	player_contacted.emit(monster_id)


func _on_body_exited(body: Node2D) -> void:
	if body is Player:
		_in_contact = false
