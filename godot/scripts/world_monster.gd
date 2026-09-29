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

signal player_contacted(monster_id: String)
signal state_changed(monster_id: String, state: int)

enum State { IDLE, CHASE, RETURNING }

## The player must come this close to the idle monster to be chased.
const AGGRO_RADIUS := 200.0
## The chase ends once the player is farther than this from the monster's home.
const LEASH_RADIUS := 450.0
## Chase and return speed in px/s (the player walks at 220 px/s).
const MOVE_SPEED := 160.0
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

var monster_id := WorldLayout.PROTOTYPE_MONSTER_ID
var home_position := WorldLayout.PROTOTYPE_MONSTER_POSITION
var _active := true
var _in_contact := false
var _state := State.IDLE
var _target: Node2D
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
	_state_label.text = STATE_TEXT[_state]


func is_threat_active() -> bool:
	return _active


func is_in_contact() -> bool:
	return _in_contact


func get_state() -> int:
	return _state


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


## Back to the deterministic start: at home, standing still, IDLE.
func reset_to_home() -> void:
	global_position = home_position
	_set_state(State.IDLE)


func _physics_process(delta: float) -> void:
	if not _active:
		return
	match _state:
		State.IDLE:
			if _target != null and global_position.distance_to(_target.global_position) <= AGGRO_RADIUS \
					and not WorldThreatZones.is_in_city_safe_buffer(_target.global_position):
				_set_state(State.CHASE)
		State.CHASE:
			if _target == null or home_position.distance_to(_target.global_position) > LEASH_RADIUS \
					or WorldThreatZones.is_in_city_safe_buffer(_target.global_position) \
					or WorldThreatZones.is_in_city_safe_buffer(global_position):
				_set_state(State.RETURNING)
			else:
				_move_toward(_target.global_position, CHASE_STOP_DISTANCE, delta)
		State.RETURNING:
			if global_position.distance_to(home_position) <= HOME_SNAP_DISTANCE:
				global_position = home_position
				_set_state(State.IDLE)
			else:
				_move_toward(home_position, 0.0, delta)


## One physics step toward `point`, never closer than `stop_distance`,
## sliding along static obstacles and kept inside the world.
func _move_toward(point: Vector2, stop_distance: float, delta: float) -> void:
	var offset := point - global_position
	var distance := offset.length()
	if distance <= stop_distance:
		return
	var motion := offset / distance * minf(MOVE_SPEED * delta, distance - stop_distance)
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
	_state_label.text = STATE_TEXT[state]
	print("Myrial: world threat ", monster_id, " state ", State.keys()[state])
	state_changed.emit(monster_id, state)


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
