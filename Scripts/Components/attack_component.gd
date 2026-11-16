class_name AttackComponent
extends Node
## Carries out attack orders for its parent unit: drives into range, turns to face the
## target, and fires a shell each time the gun has reloaded. Keeps going until it's
## cancelled or the target is gone. Numbers come from the unit's UnitData.
##
## The whole unit turns to aim: there's no separate turret yet.
## Uses the unit's MoveComponent for the driving and turning.

## Height above a target unit's feet that shells are aimed at, in world units.
@export var aim_height: float = 0.45
## It stops this far inside its range, so a target edging away isn't out of reach at once.
@export_range(0.5, 1.0) var approach_to: float = 0.9

var _unit: Node3D
var _data: UnitData
var _mover: MoveComponent
var _body: VoxelBody
var _target_unit: Node3D
var _target_point: Vector3 = Vector3.ZERO
var _attacking: bool = false
var _reload: float = 0.0


func _ready() -> void:
	_unit = get_parent() as Node3D
	set_process(false)


## Call once before giving orders.
func setup(data: UnitData, mover: MoveComponent, body: VoxelBody) -> void:
	_data = data
	_mover = mover
	_body = body


func attack_unit(target: Node3D) -> void:
	if not _can_attack() or target == _unit:
		return
	_target_unit = target
	_attacking = true
	set_process(true)


## Keeps shelling a spot on the ground.
func attack_point(point: Vector3) -> void:
	if not _can_attack():
		return
	_target_unit = null
	_target_point = point
	_attacking = true
	set_process(true)


func cancel() -> void:
	_attacking = false
	_target_unit = null


func is_attacking() -> bool:
	return _attacking


func _process(delta: float) -> void:
	# The gun goes on reloading after an attack is called off.
	_reload = maxf(_reload - delta, 0.0)
	if not _attacking:
		if _reload <= 0.0:
			set_process(false)
		return

	var aim: Vector3 = _target_point
	if _target_unit != null:
		if not is_instance_valid(_target_unit) or _target_unit.is_queued_for_deletion():
			cancel()
			_mover.stop()
			return
		aim = _target_unit.global_position + Vector3.UP * aim_height

	var flat: Vector3 = aim - _unit.global_position
	flat.y = 0.0
	if flat.length() > _data.attack_range:
		# Out of range: close in. (Re-sent every frame so it follows a moving target.)
		_mover.move_to(aim)
		return
	if _mover.is_moving() and not _mover.is_facing_only() and flat.length() > _data.attack_range * approach_to:
		return  # still closing in to a comfortable distance

	if _mover.degrees_off(aim) > _data.aim_tolerance_degrees:
		_mover.face(aim)
		return
	_mover.stop()
	if _reload <= 0.0:
		_fire(aim)
		_reload = _data.reload_seconds


func _fire(aim: Vector3) -> void:
	var muzzle: Vector3 = _unit.to_global(_data.muzzle_offset)
	var scatter: float = _data.aim_scatter
	aim += Vector3(randf_range(-scatter, scatter), randf_range(-scatter, scatter) * 0.5, randf_range(-scatter, scatter))
	var shell: Shell = Shell.new()
	shell.velocity = (aim - muzzle).normalized() * _data.shell_speed
	shell.crater_radius = _data.crater_radius
	shell.shooter = _body
	shell.max_distance = _data.attack_range * 2.0
	shell.position = muzzle
	# Beside the unit, not under it: the shell mustn't move with the tank.
	_unit.get_parent().add_child(shell)
	shell.global_position = muzzle

	# A quick flash at the muzzle.
	var debris: VoxelDebris = get_tree().get_first_node_in_group(&"voxel_debris") as VoxelDebris
	if debris:
		var forward: Vector3 = shell.velocity.normalized()
		for i: int in 8:
			var spread: Vector3 = Vector3(randf_range(-0.6, 0.6), randf_range(-0.2, 0.8), randf_range(-0.6, 0.6))
			debris.spawn(muzzle, forward * randf_range(1.0, 3.0) + spread, Color(1.0, 0.85, 0.4), randf_range(0.02, 0.12))


func _can_attack() -> bool:
	return _unit != null and _data != null and _mover != null and _data.attack_range > 0.0
