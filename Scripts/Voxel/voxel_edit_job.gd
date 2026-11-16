class_name VoxelEditJob
extends RefCounted
## One body's hits, worked out on a worker thread so the frame never waits for them.
##
## The body fills in the inputs and hands the job to VoxelService. run() then, off the
## main thread: copies the voxel arrays, carves the craters, finds anything that's been
## cut loose, and meshes just the sections that changed. The body picks the results up
## a frame or two later (VoxelBody.apply_edit) and swaps them in.
##
## Rules that keep this safe:
##  - run() touches only this object: no nodes, no scene tree, no shared state. (It
##    does create meshes; the RenderingServer queues that safely from any thread.)
##  - The input arrays are shared with the main thread, which only reads them. run()
##    copies before writing.
##  - A body has one job in flight at a time, so results always arrive in order.

## A crater to make, in the body's own space.
class Carve extends RefCounted:
	## Centre, in voxel coordinates.
	var centre: Vector3 = Vector3.ZERO
	## In voxels.
	var radius: float = 1.0
	## The way the shot was travelling.
	var dir: Vector3 = Vector3.FORWARD
	## World up, as the body sees it (debris gets a kick upwards).
	var up: Vector3 = Vector3.UP


## A piece that's been cut loose and is big enough to fall as one.
class Chunk extends RefCounted:
	var cells: PackedByteArray = PackedByteArray()
	var shade: PackedByteArray = PackedByteArray()
	var occ: PackedInt32Array = PackedInt32Array()
	var section_solid: PackedInt32Array = PackedInt32Array()
	## Sections that had to be meshed for it: section index -> ArrayMesh.
	var sections: Dictionary = {}
	## Sections that are wholly part of the chunk and untouched by the hit: the body's
	## existing meshes for them simply move over to the chunk.
	var transfer: PackedInt32Array = PackedInt32Array()
	var lowest_layer: int = 0
	var voxel_count: int = 0


# --- Inputs (set by the body before submitting) ---
var size: Vector3i = Vector3i.ZERO
var cells: PackedByteArray = PackedByteArray()
var shade: PackedByteArray = PackedByteArray()
var occ: PackedInt32Array = PackedInt32Array()
## Solid voxels per section.
var section_solid: PackedInt32Array = PackedInt32Array()
var vertex_lut: PackedColorArray = PackedColorArray()
var debris_lut: PackedColorArray = PackedColorArray()
var carves: Array[Carve] = []
## Voxels on or below this layer count as standing on the ground.
var base_y: int = 0
## For turning voxel coordinates into the body's local space (debris positions).
var voxel_size: float = 0.0625
var origin: Vector3 = Vector3.ZERO
var scorch_width: float = 1.5
## 0..255: the darkest a scorched voxel gets.
var scorch_shade: int = 115
var check_support: bool = false
var loose_debris_limit: int = 40
var max_debris_per_hit: int = 300
var debris_speed: float = 3.0
var rng_seed: int = 0

# --- Results (read by the body once the task has finished) ---
## The arrays above are replaced with the edited copies. Plus:
var removed: int = 0
## Sections whose mesh changed: section index -> ArrayMesh (null = nothing left to draw).
var sections: Dictionary = {}
## Debris to throw, in the body's local space.
var debris_pos: PackedVector3Array = PackedVector3Array()
var debris_vel: PackedVector3Array = PackedVector3Array()
var debris_col: PackedColorArray = PackedColorArray()
var debris_life: PackedFloat32Array = PackedFloat32Array()
## Set if a big piece broke off.
var chunk: Chunk = null
## How long run() took, for the timing log.
var worker_msec: float = 0.0

var _count: Vector3i = Vector3i.ZERO
var _dirty: PackedByteArray = PackedByteArray()
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


## Runs on a worker thread.
func run() -> void:
	var t0: int = Time.get_ticks_usec()
	_rng.seed = rng_seed
	# Our own copies: the originals belong to the main thread.
	cells = cells.duplicate()
	shade = shade.duplicate()
	occ = occ.duplicate()
	section_solid = section_solid.duplicate()
	_count = Vector3i((size.x + 15) >> 4, (size.y + 15) >> 4, (size.z + 15) >> 4)
	_dirty.resize(_count.x * _count.y * _count.z)

	var seeds: PackedInt32Array = PackedInt32Array()
	for carve: Carve in carves:
		_carve(carve, seeds)
	if check_support and not seeds.is_empty():
		var loose: PackedInt32Array = _find_loose(seeds)
		if not loose.is_empty():
			_drop(loose)
	_mesh_dirty()
	worker_msec = (Time.get_ticks_usec() - t0) / 1000.0


## Removes the voxels within the crater, scorches the rim, and queues debris.
## Appends the solid voxels left around the hole to seeds (where a collapse could start).
@warning_ignore("integer_division")
func _carve(carve: Carve, seeds: PackedInt32Array) -> void:
	var c: PackedByteArray = cells
	var sh: PackedByteArray = shade
	var o: PackedInt32Array = occ
	var sx: int = size.x
	var sy: int = size.y
	var sz: int = size.z
	var layer: int = sx * sy
	var words_x: int = (sx + 15) >> 4
	var centre: Vector3 = carve.centre
	var radius: float = carve.radius
	var reach: float = radius + scorch_width
	var r2: float = radius * radius
	var reach2: float = reach * reach
	var fade_width: float = maxf(scorch_width, 0.001)

	# Cells whose centre can be within reach.
	var top: Vector3i = size - Vector3i.ONE
	var lo: Vector3i = Vector3i((centre - Vector3.ONE * (reach + 0.5)).ceil())
	var hi: Vector3i = Vector3i((centre + Vector3.ONE * (reach - 0.5)).floor())
	if lo.x > top.x or lo.y > top.y or lo.z > top.z or hi.x < 0 or hi.y < 0 or hi.z < 0:
		return
	lo = lo.clamp(Vector3i.ZERO, top)
	hi = hi.clamp(Vector3i.ZERO, top)

	var gone: PackedInt32Array = PackedInt32Array()
	for z: int in range(lo.z, hi.z + 1):
		var dz: float = z + 0.5 - centre.z
		var dz2: float = dz * dz
		if dz2 > reach2:
			continue
		for y: int in range(lo.y, hi.y + 1):
			var dy: float = y + 0.5 - centre.y
			var d2_row: float = dz2 + dy * dy
			if d2_row > reach2:
				continue
			# Only the stretch of this row that's inside the sphere.
			var half: float = sqrt(reach2 - d2_row)
			var xa: int = maxi(lo.x, ceili(centre.x - half - 0.5))
			var xb: int = mini(hi.x, floori(centre.x + half - 0.5))
			var i: int = xa + sx * (y + sy * z)
			for x: int in range(xa, xb + 1):
				if c[i] != 0:
					var dx: float = x + 0.5 - centre.x
					var d2: float = d2_row + dx * dx
					if d2 <= r2:
						gone.append(i)
					else:
						# Darkest at the rim, fading out to untouched.
						var fade: float = (sqrt(d2) - radius) / fade_width
						var dark: int = int(lerpf(scorch_shade, 255.0, fade))
						if dark < sh[i]:
							sh[i] = dark
				i += 1

	# Debris for an even spread of what's going (a big crater removes thousands).
	var stride: int = maxi(1, ceili(float(gone.size()) / float(maxi(1, max_debris_per_hit))))
	var pick: int = _rng.randi() % stride
	while pick < gone.size():
		var i: int = gone[pick]
		var at: Vector3 = Vector3(i % sx + 0.5, (i / sx) % sy + 0.5, i / layer + 0.5)
		var outward: Vector3 = (at - centre).normalized()
		debris_pos.append(origin + at * voxel_size)
		debris_vel.append(carve.dir * debris_speed * _rng.randf_range(0.4, 1.1)
			+ outward * _rng.randf_range(0.5, 2.0) + carve.up * _rng.randf_range(0.5, 2.5))
		debris_col.append(_shaded(debris_lut[c[i]], sh[i]))
		debris_life.append(_rng.randf_range(1.5, 3.0))
		pick += stride

	for i: int in gone:
		c[i] = 0
		var x: int = i % sx
		o[(x >> 4) + words_x * (i / sx)] &= ~(1 << (x & 15))
	removed += gone.size()

	if check_support:
		for i: int in gone:
			var x: int = i % sx
			var y: int = (i / sx) % sy
			var z: int = i / layer
			if x > 0 and c[i - 1] != 0:
				seeds.append(i - 1)
			if x < sx - 1 and c[i + 1] != 0:
				seeds.append(i + 1)
			if y > 0 and c[i - sx] != 0:
				seeds.append(i - sx)
			if y < sy - 1 and c[i + sx] != 0:
				seeds.append(i + sx)
			if z > 0 and c[i - layer] != 0:
				seeds.append(i - layer)
			if z < sz - 1 and c[i + layer] != 0:
				seeds.append(i + layer)

	# Sections to remesh: everything scorched or removed, plus one voxel beyond the
	# crater itself, since removing a voxel uncovers its neighbours' faces.
	var edge: float = maxf(reach, radius + 1.0)
	var dirty_lo: Vector3i = Vector3i((centre - Vector3.ONE * (edge + 0.5)).ceil()).clamp(Vector3i.ZERO, top)
	var dirty_hi: Vector3i = Vector3i((centre + Vector3.ONE * (edge - 0.5)).floor()).clamp(Vector3i.ZERO, top)
	for z: int in range(dirty_lo.z >> 4, (dirty_hi.z >> 4) + 1):
		for y: int in range(dirty_lo.y >> 4, (dirty_hi.y >> 4) + 1):
			for x: int in range(dirty_lo.x >> 4, (dirty_hi.x >> 4) + 1):
				_dirty[x + _count.x * (y + _count.y * z)] = 1


## What the hit has cut loose. From each seed it searches through connected voxels,
## heading downward first, until it reaches the ground or a voxel an earlier search
## already tied to the ground. A search that runs out without getting there has walked
## a whole loose piece. Returns every loose voxel (possibly several pieces).
@warning_ignore("integer_division")
func _find_loose(seeds: PackedInt32Array) -> PackedInt32Array:
	var c: PackedByteArray = cells
	var sx: int = size.x
	var sy: int = size.y
	var sz: int = size.z
	var layer: int = sx * sy
	var ground: int = base_y
	# Which search reached each voxel (0 = none yet), and how each search ended.
	var owner: PackedInt32Array = PackedInt32Array()
	owner.resize(c.size())
	var grounded: PackedByteArray = PackedByteArray([0])
	var stack: PackedInt32Array = PackedInt32Array()
	stack.resize(4096)
	var loose: PackedInt32Array = PackedInt32Array()
	var id: int = 0

	for start: int in seeds:
		if c[start] == 0 or owner[start] != 0:
			continue
		id += 1
		grounded.append(0)
		owner[start] = id
		var found: PackedInt32Array = PackedInt32Array([start])
		stack[0] = start
		var top: int = 1
		var reached: bool = false
		while top > 0 and not reached:
			top -= 1
			var i: int = stack[top]
			var row: int = i / sx
			var y: int = row % sy
			if y <= ground:
				reached = true
				break
			var x: int = i - row * sx
			var z: int = row / sy
			if top + 6 > stack.size():
				stack.resize(stack.size() * 2)
			var n: int
			var w: int
			# Pushed last is searched first, so "down" goes last.
			if y < sy - 1:
				n = i + sx
				if c[n] != 0:
					w = owner[n]
					if w == 0:
						owner[n] = id
						found.append(n)
						stack[top] = n
						top += 1
					elif w != id and grounded[w] == 1:
						reached = true
			if x > 0:
				n = i - 1
				if c[n] != 0:
					w = owner[n]
					if w == 0:
						owner[n] = id
						found.append(n)
						stack[top] = n
						top += 1
					elif w != id and grounded[w] == 1:
						reached = true
			if x < sx - 1:
				n = i + 1
				if c[n] != 0:
					w = owner[n]
					if w == 0:
						owner[n] = id
						found.append(n)
						stack[top] = n
						top += 1
					elif w != id and grounded[w] == 1:
						reached = true
			if z > 0:
				n = i - layer
				if c[n] != 0:
					w = owner[n]
					if w == 0:
						owner[n] = id
						found.append(n)
						stack[top] = n
						top += 1
					elif w != id and grounded[w] == 1:
						reached = true
			if z < sz - 1:
				n = i + layer
				if c[n] != 0:
					w = owner[n]
					if w == 0:
						owner[n] = id
						found.append(n)
						stack[top] = n
						top += 1
					elif w != id and grounded[w] == 1:
						reached = true
			n = i - sx
			if c[n] != 0:
				w = owner[n]
				if w == 0:
					owner[n] = id
					found.append(n)
					stack[top] = n
					top += 1
				elif w != id and grounded[w] == 1:
					reached = true
		if reached:
			grounded[id] = 1
		else:
			loose.append_array(found)
	return loose


## Takes the loose voxels out of the body. A few become debris; a lot become a Chunk.
## Loose voxels never touch ones that stay (they'd be connected), so taking them out
## uncovers no new faces: a section that's wholly loose and wasn't hit keeps its mesh.
@warning_ignore("integer_division")
func _drop(loose: PackedInt32Array) -> void:
	var c: PackedByteArray = cells
	var sh: PackedByteArray = shade
	var o: PackedInt32Array = occ
	var sx: int = size.x
	var sy: int = size.y
	var layer: int = sx * sy
	var words_x: int = (sx + 15) >> 4

	if loose.size() <= loose_debris_limit:
		for i: int in loose:
			var x: int = i % sx
			var y: int = (i / sx) % sy
			var z: int = i / layer
			debris_pos.append(origin + Vector3(x + 0.5, y + 0.5, z + 0.5) * voxel_size)
			debris_vel.append(Vector3(_rng.randf_range(-0.5, 0.5), 0.0, _rng.randf_range(-0.5, 0.5)))
			debris_col.append(_shaded(debris_lut[c[i]], sh[i]))
			debris_life.append(_rng.randf_range(1.5, 3.0))
			c[i] = 0
			o[(x >> 4) + words_x * (i / sx)] &= ~(1 << (x & 15))
			_dirty[(x >> 4) + _count.x * ((y >> 4) + _count.y * (z >> 4))] = 1
		removed += loose.size()
		return

	var sections_total: int = _dirty.size()
	chunk = Chunk.new()
	chunk.voxel_count = loose.size()
	chunk.cells.resize(c.size())
	chunk.shade.resize(c.size())
	chunk.occ.resize(o.size())
	chunk.section_solid.resize(sections_total)
	var chunk_cells: PackedByteArray = chunk.cells
	var chunk_shade: PackedByteArray = chunk.shade
	var chunk_occ: PackedInt32Array = chunk.occ
	var loose_count: PackedInt32Array = PackedInt32Array()
	loose_count.resize(sections_total)
	var lowest: int = sy
	for i: int in loose:
		var x: int = i % sx
		var row: int = i / sx
		var y: int = row % sy
		var word: int = (x >> 4) + words_x * row
		var bit: int = 1 << (x & 15)
		chunk_cells[i] = c[i]
		chunk_shade[i] = sh[i]
		chunk_occ[word] |= bit
		c[i] = 0
		o[word] &= ~bit
		loose_count[(x >> 4) + _count.x * ((y >> 4) + _count.y * ((row / sy) >> 4))] += 1
		if y < lowest:
			lowest = y
	chunk.lowest_layer = lowest

	for s: int in sections_total:
		var count: int = loose_count[s]
		if count == 0:
			continue
		if _dirty[s] == 0 and count == section_solid[s]:
			# All of it is loose and the hit didn't touch it: hand the mesh over as it is.
			chunk.transfer.append(s)
			chunk.section_solid[s] = count
			section_solid[s] = 0
		else:
			var data: VoxelMesher.SectionData = VoxelMesher.build_section(
				chunk_cells, chunk_shade, chunk_occ, vertex_lut, size, _section_at(s))
			var mesh: ArrayMesh = VoxelMesher.to_mesh(data)
			if mesh != null:
				chunk.sections[s] = mesh
			chunk.section_solid[s] = data.solid
			_dirty[s] = 1


## Remeshes the sections the edit touched. A section that had nothing in it before
## still has nothing (edits only remove), so it's skipped.
func _mesh_dirty() -> void:
	for s: int in _dirty.size():
		if _dirty[s] == 0 or section_solid[s] == 0:
			continue
		var data: VoxelMesher.SectionData = VoxelMesher.build_section(
			cells, shade, occ, vertex_lut, size, _section_at(s))
		# The mesh is packed here too, on the worker: that's most of what making one costs.
		sections[s] = VoxelMesher.to_mesh(data)
		section_solid[s] = data.solid


@warning_ignore("integer_division")
func _section_at(s: int) -> Vector3i:
	return Vector3i(s % _count.x, (s / _count.x) % _count.y, s / (_count.x * _count.y))


func _shaded(colour: Color, amount: int) -> Color:
	if amount == 255:
		return colour
	var dim: float = amount / 255.0
	return Color(colour.r * dim, colour.g * dim, colour.b * dim, colour.a)
