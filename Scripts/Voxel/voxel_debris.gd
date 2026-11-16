class_name VoxelDebris
extends MultiMeshInstance3D
## Every flying voxel in the world, drawn as one MultiMesh (one draw call).
##
## Throwing a piece writes its start, velocity and timing into its instance once. After
## that the vertex shader works out the whole flight (arc, a few bounces, shrinking
## away), so thousands of pieces in the air cost the CPU nothing per frame.
## Hard cap: slots are reused oldest first, so a big fight can't run away with memory.
##
## Gotchas:
##  - Leave this node at the world origin with no rotation or scale: the shader reads
##    positions as world space.
##  - Pieces bounce on the ground plane (y = 0) only, not on terrain or buildings.
##  - Needs the debris material (Materials/voxel_debris.tres).

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
## Materials/voxel_debris.tres (the shader does the flying).
@export var material: ShaderMaterial

## Seconds since this node started; the shader's clock.
var _now: float = 0.0
var _next: int = 0


func _ready() -> void:
	add_to_group(&"voxel_debris")
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3.ONE * piece_size
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = box
	multimesh.instance_count = max_pieces
	# All zeros: no life, so every slot starts out invisible.
	var empty: PackedFloat32Array = PackedFloat32Array()
	empty.resize(max_pieces * 16)
	multimesh.buffer = empty
	material_override = material
	# The MultiMesh's bounds don't follow its pieces, so never let it be culled.
	custom_aabb = AABB(Vector3(-500.0, -10.0, -500.0), Vector3(1000.0, 200.0, 1000.0))
	if material:
		material.set_shader_parameter(&"gravity", gravity)
		material.set_shader_parameter(&"bounce", bounce)
		material.set_shader_parameter(&"ground_friction", ground_friction)
		material.set_shader_parameter(&"shrink_time", shrink_time)
		material.set_shader_parameter(&"half_size", piece_size * 0.5)
		material.set_shader_parameter(&"now", 0.0)


func _process(delta: float) -> void:
	_now += delta
	if material:
		material.set_shader_parameter(&"now", _now)


## Throws one piece. life = seconds at full size before it starts shrinking.
func spawn(at: Vector3, velocity: Vector3, colour: Color, life: float) -> void:
	# Not a real transform: the shader unpacks it (see pixel_toon.gdshaderinc).
	var packed: Transform3D = Transform3D(Basis(velocity, Vector3(_now, life, 0.0), Vector3.ZERO), at)
	multimesh.set_instance_transform(_next, packed)
	multimesh.set_instance_color(_next, colour)
	_next = (_next + 1) % max_pieces


## Throws a batch given in a body's local space (how edit jobs hand debris over).
func spawn_many(from: Transform3D, positions: PackedVector3Array, velocities: PackedVector3Array,
		colours: PackedColorArray, lives: PackedFloat32Array) -> void:
	var turn: Basis = from.basis
	var mesh: MultiMesh = multimesh
	var slot: int = _next
	for i: int in positions.size():
		mesh.set_instance_transform(slot, Transform3D(
			Basis(turn * velocities[i], Vector3(_now, lives[i], 0.0), Vector3.ZERO), from * positions[i]))
		mesh.set_instance_color(slot, colours[i])
		slot = (slot + 1) % max_pieces
	_next = slot
