class_name VoxelDebris
extends MultiMeshInstance3D
## Every flying voxel in the world, drawn as one MultiMesh so thousands of pieces are a
## single draw call. Hard cap: when it's full, new pieces reuse old slots instead of
## growing, so a big fight can't run away with memory or frame time.
## Put one in the world at the origin (positions are its local space = world space).
## Pieces bounce on the ground plane (y = 0) only, for now: not on terrain or buildings.

@export var max_pieces: int = 4000
@export var gravity: float = 12.0
## How much upward speed survives a bounce.
@export_range(0.0, 1.0) var bounce: float = 0.3
## How much sideways speed survives a bounce.
@export_range(0.0, 1.0) var ground_friction: float = 0.6
## Seconds a piece takes to shrink away once its life is up.
@export var shrink_time: float = 0.5
## Should match the bodies' voxel_size so debris is the same size as the voxels.
@export var piece_size: float = 0.0625
## Use a material with use_vertex_color on (instance colours arrive the same way).
@export var material: Material

var _pos: PackedVector3Array = PackedVector3Array()
var _vel: PackedVector3Array = PackedVector3Array()
var _col: PackedColorArray = PackedColorArray()
var _age: PackedFloat32Array = PackedFloat32Array()
var _life: PackedFloat32Array = PackedFloat32Array()
var _count: int = 0
var _replace: int = 0
## 12 floats of transform + 4 of colour per piece, sent to the MultiMesh in one go.
var _buffer: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	add_to_group(&"voxel_debris")
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3.ONE * piece_size
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = box
	multimesh.instance_count = max_pieces
	multimesh.visible_instance_count = 0
	material_override = material
	# The MultiMesh's bounds don't follow its pieces, so never let it be culled.
	custom_aabb = AABB(Vector3(-500.0, -10.0, -500.0), Vector3(1000.0, 200.0, 1000.0))
	_pos.resize(max_pieces)
	_vel.resize(max_pieces)
	_col.resize(max_pieces)
	_age.resize(max_pieces)
	_life.resize(max_pieces)
	_buffer.resize(max_pieces * 16)


## Throws one piece. life = seconds at full size before it starts shrinking.
func spawn(at: Vector3, velocity: Vector3, colour: Color, life: float) -> void:
	var slot: int
	if _count < max_pieces:
		slot = _count
		_count += 1
	else:
		slot = _replace
		_replace = (_replace + 1) % max_pieces
	_pos[slot] = at
	_vel[slot] = velocity
	_col[slot] = colour
	_age[slot] = 0.0
	_life[slot] = life


func get_count() -> int:
	return _count


func _process(delta: float) -> void:
	var half: float = piece_size * 0.5
	var i: int = 0
	while i < _count:
		var age: float = _age[i] + delta
		if age >= _life[i] + shrink_time:
			_remove(i)
			continue
		_age[i] = age
		var v: Vector3 = _vel[i]
		v.y -= gravity * delta
		var p: Vector3 = _pos[i] + v * delta
		if p.y < half:
			p.y = half
			if v.y < 0.0:
				v.y = -v.y * bounce
				v.x *= ground_friction
				v.z *= ground_friction
		_pos[i] = p
		_vel[i] = v
		i += 1

	for j: int in _count:
		var age: float = _age[j]
		var s: float = 1.0 if age < _life[j] else maxf(0.0, 1.0 - (age - _life[j]) / shrink_time)
		var p: Vector3 = _pos[j]
		var c: Color = _col[j]
		var b: int = j * 16
		_buffer[b] = s
		_buffer[b + 1] = 0.0
		_buffer[b + 2] = 0.0
		_buffer[b + 3] = p.x
		_buffer[b + 4] = 0.0
		_buffer[b + 5] = s
		_buffer[b + 6] = 0.0
		_buffer[b + 7] = p.y
		_buffer[b + 8] = 0.0
		_buffer[b + 9] = 0.0
		_buffer[b + 10] = s
		_buffer[b + 11] = p.z
		_buffer[b + 12] = c.r
		_buffer[b + 13] = c.g
		_buffer[b + 14] = c.b
		_buffer[b + 15] = 1.0
	if _count > 0:
		multimesh.buffer = _buffer
	multimesh.visible_instance_count = _count


## Swap-removes: the last piece moves into this slot.
func _remove(i: int) -> void:
	var last: int = _count - 1
	_pos[i] = _pos[last]
	_vel[i] = _vel[last]
	_col[i] = _col[last]
	_age[i] = _age[last]
	_life[i] = _life[last]
	_count -= 1
	if _replace >= _count:
		_replace = 0
