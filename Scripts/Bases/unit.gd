class_name Unit
extends Node3D
## Anything the player can select and give orders to. The unit itself is just the
## hub: what it looks like is its VoxelBody child, how it moves is its MoveComponent
## child, how it fights is its AttackComponent child, and its numbers are its UnitData.
## A new order replaces the one before it.
## The unit sits at ground level; the body stands on it.

@export var data: UnitData
## Passed on to the body (the model's magenta parts take this colour).
@export var team_color: Color = Color(0.24, 0.44, 0.82)

var body: VoxelBody
var mover: MoveComponent
var attacker: AttackComponent
var _hovered: bool = false
var _selected: bool = false


func _enter_tree() -> void:
	# Before the children are ready, so the body builds its material in our colour.
	body = _find_body()
	if body:
		body.team_color = team_color


func _ready() -> void:
	add_to_group(&"units")
	for child: Node in get_children():
		if child is MoveComponent:
			mover = child as MoveComponent
		elif child is AttackComponent:
			attacker = child as AttackComponent
	if mover and data:
		mover.setup(data)
	if attacker and data:
		attacker.setup(data, mover, body)
	if body:
		# No body, no unit (for now: later, hit points decide when it dies).
		body.crumbled.connect(queue_free)


func set_hovered(on: bool) -> void:
	_hovered = on
	_refresh_outline()


func set_selected(on: bool) -> void:
	_selected = on
	_refresh_outline()


func order_move(point: Vector3) -> void:
	if attacker:
		attacker.cancel()
	if mover:
		mover.move_to(point)


## Attack another unit until it's gone or a new order comes.
func order_attack_unit(target: Unit) -> void:
	if attacker:
		attacker.attack_unit(target)


## Shell a spot on the ground until a new order comes.
func order_attack_point(point: Vector3) -> void:
	if attacker:
		attacker.attack_point(point)


## Where a ray hits the unit's body, or {} (see VoxelBody.raycast).
func raycast(from: Vector3, dir: Vector3) -> Dictionary:
	if body == null or not is_instance_valid(body):
		return {}
	return body.raycast(from, dir)


func _refresh_outline() -> void:
	if body == null or not is_instance_valid(body):
		return
	if _selected:
		body.set_outline(VoxelBody.Outline.SELECTED)
	elif _hovered:
		body.set_outline(VoxelBody.Outline.HOVERED)
	else:
		body.set_outline(VoxelBody.Outline.NONE)


func _find_body() -> VoxelBody:
	for child: Node in get_children():
		if child is VoxelBody:
			return child as VoxelBody
	return null
