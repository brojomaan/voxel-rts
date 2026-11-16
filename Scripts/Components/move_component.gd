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
	set_process(true)


func stop() -> void:
	_moving = false
	_pivoting = false
	set_process(false)


func is_moving() -> bool:
	return _moving


func _process(delta: float) -> void:
	var to_target: Vector3 = _target - _body.global_position
	to_target.y = 0.0
	var distance: float = to_target.length()
	if distance <= arrive_distance:
		stop()
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
	if _pivoting:
		return

	# Straight at the target (not along the nose), so a small heading error can't
	# make it circle the point.
	_body.global_position += to_target / distance * minf(_data.move_speed * delta, distance)
