class_name VoxelBody
extends Node3D
## A voxel model in the world that can be shot, chipped and crumbled to dust.
##
## Undamaged, it draws its model's one shared mesh, so 200 fresh tanks cost the same as
## 200 ordinary models. On its first hit it switches to the model's 16x16x16 section
## meshes (also shared) and from then on owns only the sections that have changed.
##
## Hits don't cost the frame anything: carve() just queues the hit. The crater, the
## check for anything cut loose, and the new meshes are worked out on a background
## thread (VoxelEditJob) and swapped in a frame or two later, with the debris.
## Crumbling is done by the shader (it hides everything above a falling height), so it
## needs no meshing at all.
##
## Visual only: hit points and gameplay live elsewhere, this just shows the damage.
## The pivot is the middle of the model's canvas, at its lowest voxel, so it stands on
## whatever it's placed on.

## Finished crumbling and about to be freed.
signal crumbled

## The line drawn round the body by the camera's outline pass.
enum Outline { NONE, HOVERED, SELECTED }

@export_file("*.vox") var vox_path: String = ""
## Which model in the file (a .vox can hold several).
@export var model_index: int = 0
## World units per voxel. 1/16 = one voxel per low-res pixel at the camera's 16 ppu zoom.
@export var voxel_size: float = 0.0625
## Materials/voxel.tres (the voxel shader: vertex colours, team colour, crumbling).
@export var material: Material
## Replaces the model's reserved magenta shades. Bodies with the same colour share
## one material.
@export var team_color: Color = Color(0.24, 0.44, 0.82)

@export_group("Damage")
## How far past the crater the scorch spreads, in voxels.
@export var scorch_width: float = 1.5
## How dark scorched voxels get (0 = black, 1 = untouched).
@export_range(0.0, 1.0) var scorch_darkness: float = 0.45
## Buildings: after a hit, anything no longer connected to the ground breaks off and
## falls. Searches outward from the crater only, so it stays cheap on big models.
@export var check_support: bool = false
## Broken-off pieces at or under this many voxels just become debris; bigger ones
## fall as a whole chunk and crumble when they land.
@export var loose_debris_limit: int = 40
## Most debris pieces one hit throws (a big crater at double detail removes thousands).
@export var max_debris_per_hit: int = 300
## How fast debris flies off along the shot, in world units per second.
@export var debris_speed: float = 3.0
## Gravity for falling chunks, in world units per second squared.
@export var fall_gravity: float = 12.0

@export_group("Crumble")
## Seconds between crumble waves (each wave eats the top layer or two).
@export var crumble_interval: float = 0.05
## Debris pieces per wave.
@export var crumble_debris_per_wave: int = 90
@export_group("")

## Print what each edit cost: time on the background thread, and time on the main
## thread (the only part that can affect the frame rate).
@export var log_timings: bool = false

var grid: VoxelGrid
var _model: VoxelModel
var _base_y: int = 0
var _origin: Vector3 = Vector3.ZERO
var _material: Material
## Holds the meshes: placed at the grid's corner and scaled from voxels to world units.
var _visual: Node3D
## The single shared mesh while undamaged.
var _whole: MeshInstance3D
## Once damaged: one per section, by section index; null where nothing is drawn.
var _sections: Array[MeshInstance3D] = []
var _section_solid: PackedInt32Array = PackedInt32Array()
var _vertex_lut: PackedColorArray = PackedColorArray()
var _debris_lut: PackedColorArray = PackedColorArray()
## Hits waiting for the next job.
var _queued: Array[VoxelEditJob.Carve] = []
var _job_running: bool = false
var _debris: VoxelDebris
var _crumbling: bool = false
var _crumble_timer: float = 0.0
## Crumbling: everything from this layer up has gone.
var _crumble_top: int = 0
var _falling: bool = false
var _velocity: Vector3 = Vector3.ZERO
var _spin: Vector3 = Vector3.ZERO
var _lowest_layer: int = 0
var _outline: Outline = Outline.NONE
## A broken-off chunk is handed its meshes before it enters the tree: section -> ArrayMesh.
var _initial_meshes: Dictionary = {}

## Team-coloured copies of materials, by material + colour.
static var _team_materials: Dictionary = {}


func _ready() -> void:
	add_to_group(&"voxel_bodies")
	_debris = get_tree().get_first_node_in_group(&"voxel_debris") as VoxelDebris
	_material = _material_for_team()
	_visual = Node3D.new()
	add_child(_visual)

	if grid != null:
		# Made in code (a broken-off chunk): it has its own grid and section meshes.
		var count: Vector3i = grid.section_count()
		_sections.resize(count.x * count.y * count.z)
		for s: int in _initial_meshes:
			_set_section_mesh(s, _initial_meshes[s])
		_initial_meshes.clear()
	else:
		_model = VoxelService.get_model(vox_path, model_index)
		if _model == null:
			set_process(false)
			return
		if log_timings:
			print("[voxel] %s: model %s, %d voxels, loaded and meshed in %.1f ms (once per model)" % [
				name, vox_path.get_file(), _model.grid.count_solid(), _model.build_msec])
		grid = _model.grid
		_base_y = _model.base_y
		_lowest_layer = _base_y
		_whole = MeshInstance3D.new()
		_whole.mesh = _model.whole
		_whole.material_override = _material
		_visual.add_child(_whole)

	_origin = Vector3(-grid.size.x * 0.5, -_base_y, -grid.size.z * 0.5) * voxel_size
	_visual.position = _origin
	_visual.scale = Vector3.ONE * voxel_size
	_vertex_lut = grid.vertex_lut()
	_debris_lut = grid.display_lut(team_color)
	set_process(_falling)


func _process(delta: float) -> void:
	if _falling:
		_fall(delta)
	if _crumbling:
		_crumble_timer -= delta
		if _crumble_timer <= 0.0:
			_crumble_timer = crumble_interval
			_crumble_wave()
	elif not _queued.is_empty() and not _job_running:
		_dispatch()
	if not _falling and not _crumbling and _queued.is_empty():
		set_process(false)


## Where the ray first hits a solid voxel, or {} if it misses.
## Returns {"distance": world units along dir, "point": Vector3, "cell": Vector3i}.
## dir should be normalised. Walks the grid cell by cell (no physics shapes needed).
## Sees the body as of the last finished edit, so a crater made this instant isn't a
## hole yet for a frame or two.
func raycast(from: Vector3, dir: Vector3) -> Dictionary:
	if grid == null or _crumbling:
		return {}
	var local_from: Vector3 = to_local(from)
	var o: Vector3 = (local_from - _origin) / voxel_size
	var d: Vector3 = (to_local(from + dir) - local_from) / voxel_size
	var size: Vector3 = Vector3(grid.size)

	# Where the ray enters and leaves the grid's box.
	var t_enter: float = 0.0
	var t_exit: float = INF
	for axis: int in 3:
		if absf(d[axis]) < 0.000001:
			if o[axis] < 0.0 or o[axis] > size[axis]:
				return {}
		else:
			var t1: float = -o[axis] / d[axis]
			var t2: float = (size[axis] - o[axis]) / d[axis]
			t_enter = maxf(t_enter, minf(t1, t2))
			t_exit = minf(t_exit, maxf(t1, t2))
	if t_enter > t_exit:
		return {}

	# Step through the cells it crosses (Amanatides & Woo).
	var t: float = t_enter + 0.0001
	var p: Vector3 = o + d * t
	var cell: Vector3i = Vector3i(
		clampi(floori(p.x), 0, grid.size.x - 1),
		clampi(floori(p.y), 0, grid.size.y - 1),
		clampi(floori(p.z), 0, grid.size.z - 1))
	var step: Vector3i = Vector3i(int(signf(d.x)), int(signf(d.y)), int(signf(d.z)))
	var t_next: Vector3 = Vector3(INF, INF, INF)
	var t_delta: Vector3 = Vector3(INF, INF, INF)
	for axis: int in 3:
		if step[axis] != 0:
			t_delta[axis] = absf(1.0 / d[axis])
			var boundary: float = float(cell[axis] + (1 if step[axis] > 0 else 0))
			t_next[axis] = t + (boundary - p[axis]) / d[axis]

	var cells: PackedByteArray = grid.cells
	for _i: int in grid.size.x + grid.size.y + grid.size.z + 3:
		if cells[grid.index_of(cell)] != 0:
			return {"distance": t, "point": from + dir * t, "cell": cell}
		var axis: int = 0
		if t_next.y < t_next[axis]:
			axis = 1
		if t_next.z < t_next[axis]:
			axis = 2
		t = t_next[axis]
		t_next[axis] += t_delta[axis]
		cell[axis] += step[axis]
		if not grid.in_bounds(cell):
			break
	return {}


## Blows a crater: voxels within radius (in voxels) of the point fly off along the
## shot, and the rim gets scorched. Returns at once; the damage shows a frame or two
## later, when the background job has worked it out.
func carve(world_point: Vector3, radius: float, shot_dir: Vector3) -> void:
	if grid == null or _crumbling:
		return
	var hit: VoxelEditJob.Carve = VoxelEditJob.Carve.new()
	hit.centre = (to_local(world_point) - _origin) / voxel_size
	hit.radius = radius
	var to_body: Basis = global_basis.inverse()
	hit.dir = (to_body * shot_dir).normalized()
	hit.up = (to_body * Vector3.UP).normalized()
	_queued.append(hit)
	set_process(true)


## Crumbles the whole model to dust, top down, then frees it.
func crumble() -> void:
	if grid == null or _crumbling:
		return
	_crumbling = true
	_falling = false
	_queued.clear()
	_crumble_top = grid.highest_solid_layer() + 1
	_crumble_timer = 0.0
	remove_from_group(&"voxel_bodies")
	set_process(true)


## Shows (or clears) the hover / selection line round the body.
func set_outline(kind: Outline) -> void:
	if kind == _outline:
		return
	_outline = kind
	if _whole:
		_whole.set_instance_shader_parameter(&"outline_mark", float(kind))
	for instance: MeshInstance3D in _sections:
		if instance:
			instance.set_instance_shader_parameter(&"outline_mark", float(kind))


## True while a hit is queued or being worked out.
func is_busy() -> bool:
	return _job_running or not _queued.is_empty()


## Called by VoxelService on the main thread when a job has finished: swaps in the
## edited voxels and the meshes that changed, throws the debris, drops any chunk.
func apply_edit(job: VoxelEditJob) -> void:
	_job_running = false
	if _crumbling:
		return
	var t0: int = Time.get_ticks_usec()
	grid.cells = job.cells
	grid.shade = job.shade
	grid.occ = job.occ
	_section_solid = job.section_solid
	if job.chunk != null:
		_spawn_chunk(job.chunk)
	for s: int in job.sections:
		_set_section_mesh(s, job.sections[s])
	if _debris:
		_debris.spawn_many(global_transform, job.debris_pos, job.debris_vel, job.debris_col, job.debris_life)
	if log_timings:
		var loose: String = ", %d voxels fell" % job.chunk.voxel_count if job.chunk != null else ""
		print("[voxel] %s: %d hit(s), %d voxels removed%s, %d section(s) remeshed. Background %.2f ms, main thread %.2f ms" % [
			name, job.carves.size(), job.removed, loose, job.sections.size(), job.worker_msec,
			(Time.get_ticks_usec() - t0) / 1000.0])


## Sends the queued hits off to a worker thread.
func _dispatch() -> void:
	_make_unique()
	var job: VoxelEditJob = VoxelEditJob.new()
	job.size = grid.size
	job.cells = grid.cells
	job.shade = grid.shade
	job.occ = grid.occ
	job.section_solid = _section_solid
	job.vertex_lut = _vertex_lut
	job.debris_lut = _debris_lut
	job.carves = _queued
	job.base_y = _base_y
	job.voxel_size = voxel_size
	job.origin = _origin
	job.scorch_width = scorch_width
	job.scorch_shade = int(255.0 * scorch_darkness)
	job.check_support = check_support
	job.loose_debris_limit = loose_debris_limit
	job.max_debris_per_hit = max_debris_per_hit
	job.debris_speed = debris_speed
	job.rng_seed = randi()
	_queued = []
	_job_running = true
	VoxelService.submit(job, self)


## First hit: stop sharing. Takes its own (cheap, shared-array) copy of the grid and
## swaps the one whole mesh for the model's section meshes.
func _make_unique() -> void:
	if _model == null:
		return
	var t0: int = Time.get_ticks_usec()
	grid = grid.share()
	_section_solid = _model.section_solid
	_sections.resize(_model.section_meshes.size())
	for s: int in _model.section_meshes.size():
		if _model.section_meshes[s] != null:
			_set_section_mesh(s, _model.section_meshes[s])
	if _whole:
		_whole.queue_free()
		_whole = null
	_model = null
	if log_timings:
		print("[voxel] %s: first hit, switched to sections. Main thread %.2f ms" % [name, (Time.get_ticks_usec() - t0) / 1000.0])


func _set_section_mesh(s: int, mesh: Mesh) -> void:
	var instance: MeshInstance3D = _sections[s]
	if mesh == null:
		if instance:
			instance.queue_free()
			_sections[s] = null
		return
	if instance == null:
		instance = MeshInstance3D.new()
		instance.material_override = _material
		if _outline != Outline.NONE:
			instance.set_instance_shader_parameter(&"outline_mark", float(_outline))
		_visual.add_child(instance)
		_sections[s] = instance
	instance.mesh = mesh


## A big piece has been cut loose: it becomes its own body, falling from where it was.
func _spawn_chunk(data: VoxelEditJob.Chunk) -> void:
	var chunk: VoxelBody = VoxelBody.new()
	chunk.name = "%sChunk" % name
	chunk.grid = VoxelGrid.from_arrays(grid.size, data.cells, data.shade, data.occ, grid)
	chunk.voxel_size = voxel_size
	chunk.material = material
	chunk.team_color = team_color
	chunk.scorch_width = scorch_width
	chunk.scorch_darkness = scorch_darkness
	chunk.max_debris_per_hit = max_debris_per_hit
	chunk.debris_speed = debris_speed
	chunk.crumble_interval = crumble_interval
	chunk.crumble_debris_per_wave = crumble_debris_per_wave
	chunk.fall_gravity = fall_gravity
	chunk.log_timings = log_timings
	chunk._base_y = _base_y
	chunk._section_solid = data.section_solid
	chunk._lowest_layer = data.lowest_layer
	chunk._falling = true
	chunk._velocity = Vector3(randf_range(-0.4, 0.4), 0.0, randf_range(-0.4, 0.4))
	chunk._spin = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * 0.9
	# Sections that are wholly the chunk's and weren't hit: their meshes just move over.
	for s: int in data.transfer:
		if _sections[s] != null:
			chunk._initial_meshes[s] = _sections[s].mesh
			_set_section_mesh(s, null)
	for s: int in data.sections:
		chunk._initial_meshes[s] = data.sections[s]
	get_parent().add_child(chunk)
	chunk.global_transform = global_transform


func _crumble_wave() -> void:
	# About a dozen waves for a model of this height, however many layers that is.
	@warning_ignore("integer_division")
	var layers: int = maxi(1, grid.size.y / 12)
	var new_top: int = maxi(_crumble_top - layers, _lowest_layer)
	# Dust from a scatter of the voxels in the layers that are going.
	var size: Vector3i = grid.size
	var cells: PackedByteArray = grid.cells
	var shade: PackedByteArray = grid.shade
	var made: int = 0
	for _try: int in crumble_debris_per_wave * 6:
		if made >= crumble_debris_per_wave or new_top >= _crumble_top:
			break
		var cell: Vector3i = Vector3i(randi() % size.x, randi_range(new_top, _crumble_top - 1), randi() % size.z)
		var i: int = grid.index_of(cell)
		if cells[i] == 0:
			continue
		var at: Vector3 = to_global(_origin + (Vector3(cell) + Vector3.ONE * 0.5) * voxel_size)
		var drift: Vector3 = Vector3(randf_range(-1.0, 1.0), randf_range(0.0, 1.2), randf_range(-1.0, 1.0))
		var dim: float = shade[i] / 255.0
		var colour: Color = _debris_lut[cells[i]]
		var dust: Color = Color(colour.r * dim, colour.g * dim, colour.b * dim).lerp(Color(0.55, 0.52, 0.48), 0.35)
		if _debris:
			_debris.spawn(at, drift, dust, randf_range(0.3, 0.9))
		made += 1

	_crumble_top = new_top
	_set_clip_height(float(new_top))
	if new_top <= _lowest_layer:
		crumbled.emit()
		queue_free()


## The shader stops drawing everything above this height (in voxels).
func _set_clip_height(height: float) -> void:
	if _whole:
		_whole.set_instance_shader_parameter(&"clip_height", height)
	for instance: MeshInstance3D in _sections:
		if instance:
			instance.set_instance_shader_parameter(&"clip_height", height)


func _fall(delta: float) -> void:
	_velocity.y -= fall_gravity * delta
	global_position += _velocity * delta
	# Tip over around the base as it drops, so a broken-off top topples.
	global_basis = Basis.from_euler(_spin * delta) * global_basis
	var bottom: Vector3 = _origin + Vector3(grid.size.x * 0.5, _lowest_layer, grid.size.z * 0.5) * voxel_size
	if to_global(bottom).y <= 0.0:
		crumble()


func _material_for_team() -> Material:
	var shader_material: ShaderMaterial = material as ShaderMaterial
	if shader_material == null:
		return material
	var key: String = "%d:%s" % [shader_material.get_instance_id(), team_color.to_html()]
	if not _team_materials.has(key):
		var copy: ShaderMaterial = shader_material.duplicate() as ShaderMaterial
		copy.set_shader_parameter(&"team_color", team_color)
		_team_materials[key] = copy
	return _team_materials[key]
