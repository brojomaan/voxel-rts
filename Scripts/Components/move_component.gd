class_name MoveComponent
extends Node
## Drives its parent across the ground to a point, the way a tracked vehicle does: if
## it's facing the wrong way it stops, pivots on the spot, then drives straight there.
## Speeds come from the unit's UnitData.
##
## Not here yet: finding a way round things (it drives in a straight line, through
## anything), keeping units apart, and slopes (the ground is flat at y = 0).

signal arrived

## Close enough to the target to stop, in world units.
@export var arrive_distance: float = 0.05
## Once pivoting, how square-on it gets before driving off, in degrees.
@export var aligned_degrees: float = 1.0

var _body: Node3D
var _data: UnitData
var _target: Vector3 = Vector3.ZERO
var _moving: bool = false
var _pivoting: bool = false
## Turning to look at the target without driving to it.
var _facing_only: bool = false


func _ready() -> void:
	_body = get_parent() as Node3D
	set_process(false)


## Call once before giving orders.
func setup(data: UnitData) -> void:
	_data = data


func move_to(point: Vector3) -> void:
	if _body == null or _data == null:
		return
	_target = Vector3(point.x, _body.global_position.y, point.z)
	_moving = true
	_facing_only = false
	set_process(true)


## Pivots on the spot to look at a point, without driving anywhere.
func face(point: Vector3) -> void:
	if _body == null or _data == null:
		return
	_target = Vector3(point.x, _body.global_position.y, point.z)
	_moving = true
	_facing_only = true
	set_process(true)


## How far round it would have to turn to look at a point, in degrees (0 = facing it).
func degrees_off(point: Vector3) -> float:
	var to_point: Vector3 = point - _body.global_position
	if Vector2(to_point.x, to_point.z).length() < 0.001:
		return 0.0
	var wanted_yaw: float = atan2(-to_point.x, -to_point.z)
	return absf(rad_to_deg(wrapf(wanted_yaw - _body.global_rotation.y, -PI, PI)))


func stop() -> void:
	_moving = false
	_pivoting = false
	_facing_only = false
	set_process(false)


## True while driving or turning.
func is_moving() -> bool:
	return _moving


## True while it's only turning on the spot (face()), not driving.
func is_facing_only() -> bool:
	return _moving and _facing_only


func _process(delta: float) -> void:
	var to_target: Vector3 = _target - _body.global_position
	to_target.y = 0.0
	var distance: float = to_target.length()
	if distance <= arrive_distance:
		var was_driving: bool = not _facing_only
		stop()
		if was_driving:
			arrived.emit()
		return

	# Forward is -Z. How far round it has to turn, shortest way: + is anticlockwise.
	var wanted_yaw: float = atan2(-to_target.x, -to_target.z)
	var off_course: float = wrapf(wanted_yaw - _body.global_rotation.y, -PI, PI)
	if absf(off_course) > deg_to_rad(_data.turn_in_place_degrees):
		_pivoting = true
	elif absf(off_course) <= deg_to_rad(aligned_degrees):
		_pivoting = false

	var turn: float = clampf(off_course, -deg_to_rad(_data.turn_speed_degrees) * delta, deg_to_rad(_data.turn_speed_degrees) * delta)
	_body.global_rotation.y += turn
	if _facing_only:
		if absf(off_course) <= deg_to_rad(aligned_degrees):
			stop()
		return
	if _pivoting:
		return

	# Straight at the target (not along the nose), so a small heading error can't
	# make it circle the point.
	_body.global_position += to_target / distance * minf(_data.move_speed * delta, distance)
