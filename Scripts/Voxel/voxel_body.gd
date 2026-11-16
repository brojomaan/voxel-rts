class_name VoxelBody
extends Node3D
## A voxel model in the world that can be shot, chipped and crumbled to dust.
## Bodies made from the same file share one grid and mesh until they're first hit;
## only then does a body copy the grid for itself (copy-on-hit), so 200 fresh tanks
## cost the same as 200 ordinary models.
## Visual only: hit points and gameplay live elsewhere, this just shows the damage.
## The model's pivot is its bottom centre, so it stands on whatever it's placed on.

## Finished crumbling and about to be freed.
signal crumbled

@export_file("*.vox") var vox_path: String = ""
## Which model in the file (a .vox can hold several).
@export var model_index: int = 0
## World units per voxel. 1/16 = one voxel per low-res pixel at the camera's 16 ppu zoom.
@export var voxel_size: float = 0.0625
## Use a material with use_vertex_color on (Materials/voxel.tres).
@export var material: Material

@export_group("Damage")
## How far past the crater the scorch spreads, in voxels.
@export var scorch_width: float = 1.5
## How dark scorched voxels get (0 = black, 1 = untouched).
@export_range(0.0, 1.0) var scorch_darkness: float = 0.45
## Buildings: after a hit, anything no longer connected to the ground breaks off and
## falls. Costs a flood fill over the whole model per hit.
@export var check_support: bool = false
## Broken-off pieces at or under this many voxels just become debris; bigger ones
## fall as a whole chunk and crumble when they land.
@export var loose_debris_limit: int = 40
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

## Print how long meshing and support checks take (the prototype's cost question).
@export var log_timings: bool = false

var grid: VoxelGrid
var _mesh_instance: MeshInstance3D
var _owns_grid: bool = false
var _origin: Vector3 = Vector3.ZERO
var _debris: VoxelDebris
var _crumbling: bool = false
var _crumble_timer: float = 0.0
var _crumble_top: int = 0
var _falling: bool = false
var _velocity: Vector3 = Vector3.ZERO
var _spin: Vector3 = Vector3.ZERO
var _lowest_layer: int = 0

## Shared, untouched models: "path#index@size" -> [VoxelGrid, ArrayMesh].
static var _shared: Dictionary = {}


func _ready() -> void:
	add_to_group(&"voxel_bodies")
	_debris = get_tree().get_first_node_in_group(&"voxel_debris") as VoxelDebris
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = material
	add_child(_mesh_instance)

	if grid != null:
		# Made in code (a broken-off chunk): it already owns its grid.
		_owns_grid = true
		_origin = _origin_for(grid)
		_remesh()
		return

	var key: String = "%s#%d@%f" % [vox_path, model_index, voxel_size]
	if not _shared.has(key):
		var loaded: VoxelGrid = VoxReader.load_grid(vox_path, model_index)
		if loaded == null:
			return
		var t0: int = Time.get_ticks_usec()
		var mesh: ArrayMesh = VoxelMesher.build(loaded, voxel_size, _origin_for(loaded))
		_log("first mesh of %s (%d voxels)" % [vox_path.get_file(), loaded.count_solid()], t0)
		_shared[key] = [loaded, mesh]
	var entry: Array = _shared[key]
	grid = entry[0]
	_origin = _origin_for(grid)
	_mesh_instance.mesh = entry[1]


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
	var removed: int = 0

	for z: int in range(lo.z, hi.z + 1):
		for y: int in range(lo.y, hi.y + 1):
			for x: int in range(lo.x, hi.x + 1):
				var i: int = grid.index_of(Vector3i(x, y, z))
				if cells[i] == 0:
					continue
				var dist: float = (Vector3(x, y, z) + Vector3.ONE * 0.5).distance_to(centre)
				if dist <= radius:
					var at: Vector3 = _cell_to_world(Vector3i(x, y, z))
					var outward: Vector3 = (at - world_point).normalized()
					var velocity: Vector3 = dir * debris_speed * randf_range(0.4, 1.1) \
						+ outward * randf_range(0.5, 2.0) + Vector3.UP * randf_range(0.5, 2.5)
					_emit(at, velocity, grid.color_at(i), randf_range(1.5, 3.0))
					cells[i] = 0
					removed += 1
				elif dist <= reach:
					# Darkest at the rim, fading out to untouched.
					var fade: float = (dist - radius) / maxf(scorch_width, 0.001)
					shade[i] = mini(shade[i], int(lerpf(scorch, 255.0, fade)))
	grid.cells = cells
	grid.shade = shade
	_log("carve (%d voxels)" % removed, t0)

	if removed > 0 and check_support:
		_drop_unsupported()
	_remesh()
	return removed


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
	for _l: int in layers:
		if _crumble_top < 0:
			break
		var layer: PackedInt32Array = PackedInt32Array()
		for z: int in grid.size.z:
			for x: int in grid.size.x:
				var i: int = grid.index_of(Vector3i(x, _crumble_top, z))
				if cells[i] != 0:
					layer.append(i)
		# Only some of a layer becomes visible dust; spread the picks across it.
		var stride: int = maxi(1, layer.size() / maxi(1, crumble_debris_per_wave / layers))
		var start: int = randi() % stride
		for k: int in range(start, layer.size(), stride):
			var i: int = layer[k]
			var at: Vector3 = _cell_to_world(grid.cell_of(i))
			var drift: Vector3 = Vector3(randf_range(-1.0, 1.0), randf_range(0.0, 1.2), randf_range(-1.0, 1.0))
			var dust: Color = grid.color_at(i).lerp(Color(0.55, 0.52, 0.48), 0.35)
			_emit(at, drift, dust, randf_range(0.3, 0.9))
		for i: int in layer:
			cells[i] = 0
		_crumble_top -= 1
	grid.cells = cells
	_remesh()
	if _crumble_top < 0:
		crumbled.emit()
		queue_free()


## Anything no longer joined to the bottom layer breaks off: small bits become debris,
## a big piece falls as its own body and crumbles when it lands.
func _drop_unsupported() -> void:
	var t0: int = Time.get_ticks_usec()
	var sx: int = grid.size.x
	var sy: int = grid.size.y
	var sz: int = grid.size.z
	var layer: int = sx * sy
	var cells: PackedByteArray = grid.cells
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(cells.size())
	var queue: PackedInt32Array = PackedInt32Array()

	# Flood fill from every solid voxel touching the ground (y = 0).
	for z: int in sz:
		for x: int in sx:
			var i: int = x + layer * z
			if cells[i] != 0:
				visited[i] = 1
				queue.append(i)
	var head: int = 0
	while head < queue.size():
		var i: int = queue[head]
		head += 1
		var x: int = i % sx
		var y: int = (i / sx) % sy
		var z: int = i / layer
		if x > 0 and cells[i - 1] != 0 and visited[i - 1] == 0:
			visited[i - 1] = 1
			queue.append(i - 1)
		if x < sx - 1 and cells[i + 1] != 0 and visited[i + 1] == 0:
			visited[i + 1] = 1
			queue.append(i + 1)
		if y > 0 and cells[i - sx] != 0 and visited[i - sx] == 0:
			visited[i - sx] = 1
			queue.append(i - sx)
		if y < sy - 1 and cells[i + sx] != 0 and visited[i + sx] == 0:
			visited[i + sx] = 1
			queue.append(i + sx)
		if z > 0 and cells[i - layer] != 0 and visited[i - layer] == 0:
			visited[i - layer] = 1
			queue.append(i - layer)
		if z < sz - 1 and cells[i + layer] != 0 and visited[i + layer] == 0:
			visited[i + layer] = 1
			queue.append(i + layer)

	var loose: PackedInt32Array = PackedInt32Array()
	for i: int in cells.size():
		if cells[i] != 0 and visited[i] == 0:
			loose.append(i)
	_log("support check (%d loose)" % loose.size(), t0)
	if loose.is_empty():
		return

	if loose.size() <= loose_debris_limit:
		for i: int in loose:
			_emit(_cell_to_world(grid.cell_of(i)), Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5)), grid.color_at(i), randf_range(1.5, 3.0))
			cells[i] = 0
		grid.cells = cells
		return

	# One falling chunk: same grid size and transform, holding just the loose voxels.
	var chunk_grid: VoxelGrid = VoxelGrid.new(grid.size)
	chunk_grid.palette = grid.palette
	var lowest: int = sy
	for i: int in loose:
		chunk_grid.cells[i] = cells[i]
		chunk_grid.shade[i] = grid.shade[i]
		lowest = mini(lowest, (i / sx) % sy)
		cells[i] = 0
	grid.cells = cells

	var chunk: VoxelBody = VoxelBody.new()
	chunk.grid = chunk_grid
	chunk.voxel_size = voxel_size
	chunk.material = material
	chunk.crumble_interval = crumble_interval
	chunk.crumble_debris_per_wave = crumble_debris_per_wave
	chunk.fall_gravity = fall_gravity
	chunk.log_timings = log_timings
	chunk._falling = true
	chunk._lowest_layer = lowest
	chunk._velocity = Vector3(randf_range(-0.4, 0.4), 0.0, randf_range(-0.4, 0.4))
	chunk._spin = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * 0.9
	get_parent().add_child(chunk)
	chunk.global_transform = global_transform


func _fall(delta: float) -> void:
	_velocity.y -= fall_gravity * delta
	global_position += _velocity * delta
	# Tip over around the base as it drops, so a broken-off top topples.
	global_basis = Basis.from_euler(_spin * delta) * global_basis
	var bottom: Vector3 = _origin + Vector3(grid.size.x * 0.5, _lowest_layer, grid.size.z * 0.5) * voxel_size
	if to_global(bottom).y <= 0.0:
		crumble()


func _make_unique() -> void:
	if not _owns_grid:
		grid = grid.duplicate_grid()
		_owns_grid = true


func _remesh() -> void:
	var t0: int = Time.get_ticks_usec()
	_mesh_instance.mesh = VoxelMesher.build(grid, voxel_size, _origin)
	_log("remesh", t0)


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
