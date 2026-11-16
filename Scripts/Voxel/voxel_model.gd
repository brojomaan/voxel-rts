class_name VoxelModel
extends RefCounted
## A voxel model as loaded from a file, shared by every body made from it: the voxels,
## one mesh of the whole thing (what undamaged bodies draw), and the same thing cut
## into sections (what a body switches to when it's first hit, so that hit only has to
## rebuild the sections it touched).
## Nothing here changes after build(); bodies copy what they need to alter.

var grid: VoxelGrid
## The lowest layer with voxels in it: the layer that stands on the ground.
var base_y: int = 0
## The whole model as one mesh (null if the model is empty).
var whole: ArrayMesh
## One mesh per section, by section index; null where a section has no faces.
var section_meshes: Array[ArrayMesh] = []
## Solid voxels per section.
var section_solid: PackedInt32Array = PackedInt32Array()
## How long build() took, for the timing log.
var build_msec: float = 0.0

var _lut: PackedColorArray = PackedColorArray()
var _count: Vector3i = Vector3i.ZERO
var _data: Array = []


## Meshes every section, spread across the worker threads, and waits for them. Blocks
## for a moment, once per model, at load. (An import step could bake this later.)
func build(source: VoxelGrid) -> void:
	var t0: int = Time.get_ticks_usec()
	grid = source
	base_y = grid.lowest_solid_layer()
	_lut = grid.vertex_lut()
	_count = grid.section_count()
	var total: int = _count.x * _count.y * _count.z
	_data.resize(total)
	section_meshes.resize(total)
	section_solid.resize(total)
	if total > 0:
		var task: int = WorkerThreadPool.add_group_task(_mesh_section, total, -1, true, "Voxel model")
		WorkerThreadPool.wait_for_group_task_completion(task)

	for s: int in total:
		section_solid[s] = (_data[s] as VoxelMesher.SectionData).solid
	whole = VoxelMesher.merge_to_mesh(_data)
	_data.clear()
	build_msec = (Time.get_ticks_usec() - t0) / 1000.0


## Runs on worker threads; each call fills its own slot.
@warning_ignore("integer_division")
func _mesh_section(s: int) -> void:
	var section: Vector3i = Vector3i(s % _count.x, (s / _count.x) % _count.y, s / (_count.x * _count.y))
	var data: VoxelMesher.SectionData = VoxelMesher.build_section(
		grid.cells, grid.shade, grid.occ, _lut, grid.size, section)
	_data[s] = data
	section_meshes[s] = VoxelMesher.to_mesh(data)
