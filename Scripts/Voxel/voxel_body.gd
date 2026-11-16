class_name VoxelBody
extends Node3D
## A voxel model in the world that can be shot, chipped and crumbled to dust.
##
## Undamaged, it's one shared mesh (one draw call, shared by every body made from the
## same file). On its first hit it copies the grid for itself (copy-on-hit) and splits
## into sections of section_size³, starting from shared, pre-built section meshes; after
## that a hit only rebuilds the sections it touched, so a big building costs about the
## same per hit as a small tank.
## Visual only: hit points and gameplay live elsewhere, this just shows the damage.
## The pivot is the model's bottom centre, so it stands on whatever it's placed on.

## Finished crumbling and about to be freed.
signal crumbled

@export_file("*.vox") var vox_path: String = ""
## Which model in the file (a .vox can hold several).
@export var model_index: int = 0
## World units per voxel. 1/16 = one voxel per low-res pixel at the camera's 16 ppu zoom.
@export var voxel_size: float = 0.0625
## Use a material with use_vertex_color on (Materials/voxel.tres).
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
## Most debris pieces per wave; the rest just vanish (a solid building has thousands).
@export var crumble_debris_per_wave: int = 90
@export_group("")

## Size of the remesh sections, in voxels. Smaller = cheaper hits, more draw calls
## once damaged.
@export var section_size: int = 16
## Print how long meshing and support checks take (the prototype's cost question).
@export var log_timings: bool = false

var grid: VoxelGrid
var _owns_grid: bool = false
var _origin: Vector3 = Vector3.ZERO
var _material: Material
var _key: String = ""
## The single shared mesh while undamaged.
var _whole: MeshInstance3D
## One per section once damaged (null mesh where a section has nothing to draw).
var _sections: Array[MeshInstance3D] = []
## Solid voxels per section; 0 = empty for good (we only ever remove), so skip it.
var _section_solid: PackedInt32Array = PackedInt32Array()
var _section_count: Vector3i = Vector3i.ZERO
var _dirty: Dictionary = {}
var _debris: VoxelDebris
var _crumbling: bool = false
var _crumble_timer: float = 0.0
var _crumble_top: int = 0
var _falling: bool = false
var _velocity: Vector3 = Vector3.ZERO
var _spin: Vector3 = Vector3.ZERO
var _lowest_layer: int = 0
## For a broken-off chunk: the box (from, to exclusive) its voxels sit in.
var _region_from: Vector3i = Vector3i.ZERO
var _region_to: Vector3i = Vector3i(-1, -1, -1)

## Untouched models, by file + size: {grid, mesh, sections (Array or null), solid}.
static var _shared: Dictionary = {}
## Team-coloured copies of materials, by material + colour.
static var _team_materials: Dictionary = {}


func _ready() -> void:
	add_to_group(&"voxel_bodies")
	_debris = get_tree().get_first_node_in_group(&"voxel_debris") as VoxelDebris
	_material = _material_for_team()

	if grid != null:
		# Made in code (a broken-off chunk): it owns its grid and starts sectioned,
		# building only the sections its voxels are in.
		_owns_grid = true
		_origin = _origin_for(grid)
		_setup_sections()
		var t0: int = Time.get_ticks_usec()
		var meshes: Array = []
		var solid: PackedInt32Array = PackedInt32Array()
		meshes.resize(_section_count.x * _section_count.y * _section_count.z)
		solid.resize(meshes.size())
		var lo: Vector3i = _region_from / section_size
		var hi: Vector3i = (_region_to - Vector3i.ONE) / section_size
		for sz: int in range(lo.z, hi.z + 1):
			for sy: int in range(lo.y, hi.y + 1):
				for sx: int in range(lo.x, hi.x + 1):
					var s: int = _section_index(Vector3i(sx, sy, sz))
					var bounds: Array[Vector3i] = _section_bounds(s)
					meshes[s] = VoxelMesher.build(grid, voxel_size, _origin, bounds[0], bounds[1])
					solid[s] = VoxelMesher.last_solid_count
		_make_section_instances(meshes, solid)
		_log("chunk mesh", t0)
		return

	_key = "%s#%d@%f" % [vox_path, model_index, voxel_size]
	if not _shared.has(_key):
		var loaded: VoxelGrid = VoxReader.load_grid(vox_path, model_index)
		if loaded == null:
			return
		var t0: int = Time.get_ticks_usec()
		var mesh: ArrayMesh = VoxelMesher.build(loaded, voxel_size, _origin_for(loaded))
		_log("first mesh of %s (%d voxels)" % [vox_path.get_file(), loaded.count_solid()], t0)
		_shared[_key] = {"grid": loaded, "mesh": mesh, "sections": null, "solid": null}
	var entry: Dictionary = _shared[_key]
	grid = entry.grid
	_origin = _origin_for(grid)
	_whole = MeshInstance3D.new()
	_whole.mesh = entry.mesh
	_whole.material_override = _material
	add_child(_whole)


func _process(delta: float) -> void:
	if _falling:
		_fall(delta)
	if _crumbling:
		_crumble_timer -= delta
		if _crumble_timer <= 0.0:
			_crumble_timer = crumble_interval
			_crumble_wave()


## Where the ray first hits a solid voxel, or {} if it misses.
## Returns {"distance": world units along dir, "point": Vector3, "cell": Vector3i}.
## dir should be normalised. Walks the grid cell by cell (no physics shapes needed).
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
## shot, the rim gets scorched. Returns how many voxels were removed.
func carve(world_point: Vector3, radius: float, shot_dir: Vector3) -> int:
	if grid == null or _crumbling:
		return 0
	_make_unique()
	var t0: int = Time.get_ticks_usec()
	var centre: Vector3 = (to_local(world_point) - _origin) / voxel_size
	var reach: float = radius + scorch_width
	var lo: Vector3i = Vector3i((centre - Vector3.ONE * reach).floor()).clamp(Vector3i.ZERO, grid.size - Vector3i.ONE)
	var hi: Vector3i = Vector3i((centre + Vector3.ONE * reach).ceil()).clamp(Vector3i.ZERO, grid.size - Vector3i.ONE)
	var dir: Vector3 = shot_dir.normalized()
	var scorch: int = int(255.0 * scorch_darkness)
	var cells: PackedByteArray = grid.cells
	var shade: PackedByteArray = grid.shade
	var removed: PackedInt32Array = PackedInt32Array()

	for z: int in range(lo.z, hi.z + 1):
		for y: int in range(lo.y, hi.y + 1):
			for x: int in range(lo.x, hi.x + 1):
				var i: int = grid.index_of(Vector3i(x, y, z))
				if cells[i] == 0:
					continue
				var dist: float = (Vector3(x, y, z) + Vector3.ONE * 0.5).distance_to(centre)
				if dist <= radius:
					removed.append(i)
				elif dist <= reach:
					# Darkest at the rim, fading out to untouched.
					var fade: float = (dist - radius) / maxf(scorch_width, 0.001)
					shade[i] = mini(shade[i], int(lerpf(scorch, 255.0, fade)))
	grid.shade = shade

	# Debris for some of them (spread evenly), before they're cleared.
	var stride: int = maxi(1, ceili(float(removed.size()) / float(maxi(1, max_debris_per_hit))))
	for k: int in range(randi() % stride, removed.size(), stride):
		var i: int = removed[k]
		var at: Vector3 = _cell_to_world(grid.cell_of(i))
		var outward: Vector3 = (at - world_point).normalized()
		var velocity: Vector3 = dir * debris_speed * randf_range(0.4, 1.1) \
			+ outward * randf_range(0.5, 2.0) + Vector3.UP * randf_range(0.5, 2.5)
		_emit(at, velocity, grid.display_color_at(i, team_color), randf_range(1.5, 3.0))
	for i: int in removed:
		cells[i] = 0
	grid.cells = cells
	_mark_dirty(lo, hi)
	_log("carve (%d voxels)" % removed.size(), t0)

	if not removed.is_empty() and check_support:
		_drop_unsupported(_neighbours_of(removed))
	_flush()
	return removed.size()


## Crumbles the whole model to dust, top down, then frees it.
func crumble() -> void:
	if grid == null or _crumbling:
		return
	_make_unique()
	_crumbling = true
	_falling = false
	_crumble_top = grid.size.y - 1
	_crumble_timer = 0.0
	remove_from_group(&"voxel_bodies")


func _crumble_wave() -> void:
	var layers: int = maxi(1, grid.size.y / 12)
	var cells: PackedByteArray = grid.cells
	var top: int = _crumble_top
	for _l: int in layers:
		if _crumble_top < 0:
			break
		var layer: PackedInt32Array = PackedInt32Array()
		for z: int in grid.size.z:
			var i: int = grid.size.x * (_crumble_top + grid.size.y * z)
			for x: int in grid.size.x:
				if cells[i] != 0:
					layer.append(i)
				i += 1
		# Only some of a layer becomes visible dust; spread the picks across it.
		var stride: int = maxi(1, layer.size() / maxi(1, crumble_debris_per_wave / layers))
		var start: int = randi() % stride
		for k: int in range(start, layer.size(), stride):
			var i: int = layer[k]
			var at: Vector3 = _cell_to_world(grid.cell_of(i))
			var drift: Vector3 = Vector3(randf_range(-1.0, 1.0), randf_range(0.0, 1.2), randf_range(-1.0, 1.0))
			var dust: Color = grid.display_color_at(i, team_color).lerp(Color(0.55, 0.52, 0.48), 0.35)
			_emit(at, drift, dust, randf_range(0.3, 0.9))
		for i: int in layer:
			cells[i] = 0
		_crumble_top -= 1
	grid.cells = cells
	_mark_dirty(Vector3i(0, maxi(_crumble_top, 0), 0), Vector3i(grid.size.x - 1, top, grid.size.z - 1))
	_flush()
	if _crumble_top < 0:
		crumbled.emit()
		queue_free()


## Finds what a hit has cut loose. From each voxel next to the crater it searches,
## heading downward first, until it touches the ground (y = 0) or another voxel already
## known to be grounded. A search that runs out without reaching the ground has walked
## a whole loose piece. Small loose bits become debris; a big one falls as its own body.
func _drop_unsupported(seeds: PackedInt32Array) -> void:
	var t0: int = Time.get_ticks_usec()
	var sx: int = grid.size.x
	var sy: int = grid.size.y
	var sz: int = grid.size.z
	var layer: int = sx * sy
	var cells: PackedByteArray = grid.cells
	# 0 = unknown, 1 = in this search, 2 = grounded, 3 = loose.
	var state: PackedByteArray = PackedByteArray()
	state.resize(cells.size())
	var loose: PackedInt32Array = PackedInt32Array()
	var explored: int = 0

	for seed: int in seeds:
		if cells[seed] == 0 or state[seed] != 0:
			continue
		var stack: PackedInt32Array = PackedInt32Array([seed])
		var found: PackedInt32Array = PackedInt32Array([seed])
		state[seed] = 1
		var grounded: bool = false
		while not stack.is_empty() and not grounded:
			var i: int = stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			var x: int = i % sx
			var y: int = (i / sx) % sy
			var z: int = i / layer
			if y == 0:
				grounded = true
				break
			# Pushed last = searched first, so down goes last.
			var next: PackedInt32Array = PackedInt32Array()
			if y < sy - 1:
				next.append(i + sx)
			if x > 0:
				next.append(i - 1)
			if x < sx - 1:
				next.append(i + 1)
			if z > 0:
				next.append(i - layer)
			if z < sz - 1:
				next.append(i + layer)
			next.append(i - sx)
			for n: int in next:
				if cells[n] == 0:
					continue
				if state[n] == 2:
					grounded = true
					break
				if state[n] == 0:
					state[n] = 1
					stack.append(n)
					found.append(n)
		explored += found.size()
		var mark: int = 2 if grounded else 3
		for i: int in found:
			state[i] = mark
		if not grounded:
			loose.append_array(found)
	_log("support check (%d explored, %d loose)" % [explored, loose.size()], t0)
	if loose.is_empty():
		return

	# Where the loose voxels are, so only those sections get rebuilt.
	var lo: Vector3i = grid.size
	var hi: Vector3i = Vector3i(-1, -1, -1)
	var lowest: int = sy
	for i: int in loose:
		var c: Vector3i = grid.cell_of(i)
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x), maxi(hi.y, c.y), maxi(hi.z, c.z))
		lowest = mini(lowest, c.y)

	if loose.size() <= loose_debris_limit:
		for i: int in loose:
			_emit(_cell_to_world(grid.cell_of(i)), Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5)), grid.display_color_at(i, team_color), randf_range(1.5, 3.0))
			cells[i] = 0
		grid.cells = cells
		_mark_dirty(lo, hi)
		return

	# One falling chunk: same grid size and transform, holding just the loose voxels.
	var chunk_grid: VoxelGrid = VoxelGrid.new(grid.size)
	chunk_grid.palette = grid.palette
	chunk_grid.team_shade = grid.team_shade
	for i: int in loose:
		chunk_grid.cells[i] = cells[i]
		chunk_grid.shade[i] = grid.shade[i]
		cells[i] = 0
	grid.cells = cells
	_mark_dirty(lo, hi)

	var chunk: VoxelBody = VoxelBody.new()
	chunk.name = "%sChunk" % name
	chunk.grid = chunk_grid
	chunk.voxel_size = voxel_size
	chunk.material = material
	chunk.team_color = team_color
	chunk.section_size = section_size
	chunk.crumble_interval = crumble_interval
	chunk.crumble_debris_per_wave = crumble_debris_per_wave
	chunk.fall_gravity = fall_gravity
	chunk.log_timings = log_timings
	chunk._region_from = lo
	chunk._region_to = hi + Vector3i.ONE
	chunk._falling = true
	chunk._lowest_layer = lowest
	chunk._velocity = Vector3(randf_range(-0.4, 0.4), 0.0, randf_range(-0.4, 0.4))
	chunk._spin = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * 0.9
	get_parent().add_child(chunk)
	chunk.global_transform = global_transform


## Solid voxels touching any of these cells (where a support search should start).
func _neighbours_of(removed: PackedInt32Array) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var sx: int = grid.size.x
	var sy: int = grid.size.y
	var layer: int = sx * grid.size.y
	var cells: PackedByteArray = grid.cells
	for i: int in removed:
		var x: int = i % sx
		var y: int = (i / sx) % sy
		var z: int = i / layer
		if x > 0 and cells[i - 1] != 0:
			out.append(i - 1)
		if x < sx - 1 and cells[i + 1] != 0:
			out.append(i + 1)
		if y > 0 and cells[i - sx] != 0:
			out.append(i - sx)
		if y < sy - 1 and cells[i + sx] != 0:
			out.append(i + sx)
		if z > 0 and cells[i - layer] != 0:
			out.append(i - layer)
		if z < grid.size.z - 1 and cells[i + layer] != 0:
			out.append(i + layer)
	return out


func _fall(delta: float) -> void:
	_velocity.y -= fall_gravity * delta
	global_position += _velocity * delta
	# Tip over around the base as it drops, so a broken-off top topples.
	global_basis = Basis.from_euler(_spin * delta) * global_basis
	var bottom: Vector3 = _origin + Vector3(grid.size.x * 0.5, _lowest_layer, grid.size.z * 0.5) * voxel_size
	if to_global(bottom).y <= 0.0:
		crumble()


## First hit: take our own copy of the grid and swap the shared whole mesh for
## sections (built once per model and shared, so the split itself is cheap).
func _make_unique() -> void:
	if _owns_grid:
		return
	var entry: Dictionary = _shared[_key]
	_setup_sections()
	if entry.sections == null:
		var t0: int = Time.get_ticks_usec()
		var meshes: Array = []
		var solid: PackedInt32Array = PackedInt32Array()
		meshes.resize(_section_count.x * _section_count.y * _section_count.z)
		solid.resize(meshes.size())
		for s: int in meshes.size():
			var bounds: Array[Vector3i] = _section_bounds(s)
			meshes[s] = VoxelMesher.build(grid, voxel_size, _origin, bounds[0], bounds[1])
			solid[s] = VoxelMesher.last_solid_count
		entry.sections = meshes
		entry.solid = solid
		_log("first split of %s into %d sections" % [vox_path.get_file(), meshes.size()], t0)
	grid = grid.duplicate_grid()
	_owns_grid = true
	_make_section_instances(entry.sections, (entry.solid as PackedInt32Array).duplicate())
	if _whole:
		_whole.queue_free()
		_whole = null


func _setup_sections() -> void:
	_section_count = Vector3i(
		ceili(float(grid.size.x) / section_size),
		ceili(float(grid.size.y) / section_size),
		ceili(float(grid.size.z) / section_size))


func _make_section_instances(meshes: Array, solid: PackedInt32Array) -> void:
	_section_solid = solid
	for s: int in meshes.size():
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = meshes[s]
		mi.material_override = _material
		add_child(mi)
		_sections.append(mi)


func _section_index(section: Vector3i) -> int:
	return section.x + _section_count.x * (section.y + _section_count.y * section.z)


## [from, to) of a section, in cells.
func _section_bounds(s: int) -> Array[Vector3i]:
	var section: Vector3i = Vector3i(
		s % _section_count.x,
		(s / _section_count.x) % _section_count.y,
		s / (_section_count.x * _section_count.y))
	var from: Vector3i = section * section_size
	return [from, (from + Vector3i.ONE * section_size).min(grid.size)]


## Marks the sections overlapping these cells (inclusive), plus one cell around them
## since removing a voxel uncovers its neighbours' faces.
func _mark_dirty(lo: Vector3i, hi: Vector3i) -> void:
	var a: Vector3i = (lo - Vector3i.ONE).clamp(Vector3i.ZERO, grid.size - Vector3i.ONE) / section_size
	var b: Vector3i = (hi + Vector3i.ONE).clamp(Vector3i.ZERO, grid.size - Vector3i.ONE) / section_size
	for z: int in range(a.z, b.z + 1):
		for y: int in range(a.y, b.y + 1):
			for x: int in range(a.x, b.x + 1):
				_dirty[_section_index(Vector3i(x, y, z))] = true


## Rebuilds the dirty sections. Sections with no solid voxels stay empty for good
## (we only ever remove voxels), so they're skipped.
func _flush() -> void:
	if _dirty.is_empty():
		return
	var t0: int = Time.get_ticks_usec()
	var rebuilt: int = 0
	for s: int in _dirty:
		if _section_solid[s] == 0:
			continue
		var bounds: Array[Vector3i] = _section_bounds(s)
		_sections[s].mesh = VoxelMesher.build(grid, voxel_size, _origin, bounds[0], bounds[1])
		_section_solid[s] = VoxelMesher.last_solid_count
		rebuilt += 1
	_dirty.clear()
	_log("remesh %d section(s)" % rebuilt, t0)


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


func _origin_for(g: VoxelGrid) -> Vector3:
	return Vector3(-g.size.x * 0.5, 0.0, -g.size.z * 0.5) * voxel_size


## A cell's centre in world space.
func _cell_to_world(cell: Vector3i) -> Vector3:
	return to_global(_origin + (Vector3(cell) + Vector3.ONE * 0.5) * voxel_size)


func _emit(at: Vector3, velocity: Vector3, colour: Color, life: float) -> void:
	if _debris:
		_debris.spawn(at, velocity, colour, life)


func _log(what: String, since_usec: int) -> void:
	if log_timings:
		print("[voxel] %s %s: %.2f ms" % [name, what, (Time.get_ticks_usec() - since_usec) / 1000.0])
