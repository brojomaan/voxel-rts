class_name VoxelMesher
extends RefCounted
## Turns voxels into meshes with only the faces that touch air, one 16x16x16 section at
## a time. A solid block costs nothing inside; only its skin is drawn.
##
## How it finds faces: the grid keeps one bit per voxel, 16 voxels of a row per word.
## "Solid here, empty next door" is then one AND-NOT per row per direction, and only
## rows with a face in them are looked at voxel by voxel. That's what makes it fast in
## GDScript: the work follows the surface, not the volume.
##
## Meshes are in voxel units (one voxel = 1.0, grid corner at the origin); the body
## scales and places them. Each face carries its voxel's colour per vertex. Faces aren't
## merged into bigger quads: per-voxel colour and scorch would break most merges anyway.
##
## Thread use: build_section and to_mesh only read their arguments and the tables
## below, so workers can run them side by side (the RenderingServer queues mesh creation
## safely from any thread). Call warm_up() on the main thread first (VoxelService does).

## Most quads one mesh surface holds (4 vertices each keeps indices 16-bit).
const MAX_QUADS: int = 16384

## One section's faces, ready to become a mesh surface.
class SectionData extends RefCounted:
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var quads: int = 0
	## Solid voxels in the section (0 = nothing here, now or ever again).
	var solid: int = 0


const DIRECTIONS: Array[Vector3] = [
	Vector3(1, 0, 0), Vector3(-1, 0, 0),
	Vector3(0, 1, 0), Vector3(0, -1, 0),
	Vector3(0, 0, 1), Vector3(0, 0, -1),
]

## Four corners per face direction, in a unit cube, ordered so that the index pattern
## 0-1-2, 0-2-3 winds the way Godot draws as the front (clockwise from outside).
static var _corners: PackedVector3Array = PackedVector3Array()
## 0,1,2, 0,2,3, 4,5,6, 4,6,7 ... for MAX_QUADS quads; meshes take a slice.
static var _quad_indices: PackedInt32Array = PackedInt32Array()
## Position of a single set bit: _bit_position[1 << n] = n, for n < 16.
static var _bit_position: PackedByteArray = PackedByteArray()
## Set bits in a 16-bit word.
static var _bit_count: PackedByteArray = PackedByteArray()
## Running with no renderer (--headless, a dedicated server): there's nothing to draw,
## so no meshes are made. Also the headless renderer can't take mesh creation from
## several threads at once, which the real ones can.
static var _no_renderer: bool = false


## Builds the lookup tables. Main thread, before any worker meshes (a few ms, once).
static func warm_up() -> void:
	if not _quad_indices.is_empty():
		return
	_no_renderer = DisplayServer.get_name() == "headless"
	var raw: Array = [
		[Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
		[Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0), Vector3(0, 0, 0)],
		[Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
		[Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1)],
		[Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1), Vector3(0, 0, 1)],
		[Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)],
	]
	var corners: PackedVector3Array = PackedVector3Array()
	for f: int in 6:
		var a: Vector3 = raw[f][0]
		var b: Vector3 = raw[f][1]
		var c: Vector3 = raw[f][2]
		var d: Vector3 = raw[f][3]
		# Godot's front face is clockwise from outside: the cross product points inward.
		if (b - a).cross(c - a).dot(DIRECTIONS[f]) < 0.0:
			corners.append_array(PackedVector3Array([a, b, c, d]))
		else:
			corners.append_array(PackedVector3Array([a, d, c, b]))
	_corners = corners

	var positions: PackedByteArray = PackedByteArray()
	positions.resize(32769)
	for n: int in 16:
		positions[1 << n] = n
	_bit_position = positions

	var counts: PackedByteArray = PackedByteArray()
	counts.resize(65536)
	for i: int in range(1, 65536):
		counts[i] = counts[i >> 1] + (i & 1)
	_bit_count = counts

	var indices: PackedInt32Array = PackedInt32Array()
	indices.resize(MAX_QUADS * 6)
	var k: int = 0
	for q: int in MAX_QUADS:
		var v: int = q * 4
		indices[k] = v
		indices[k + 1] = v + 1
		indices[k + 2] = v + 2
		indices[k + 3] = v
		indices[k + 4] = v + 2
		indices[k + 5] = v + 3
		k += 6
	_quad_indices = indices


## Meshes one section. section = which one, counted in sections from the grid corner.
## lut = VoxelGrid.vertex_lut(). Neighbouring sections' edge voxels are taken into
## account, so sections meet without gaps or hidden faces between them.
static func build_section(cells: PackedByteArray, shade: PackedByteArray, occ: PackedInt32Array,
		lut: PackedColorArray, size: Vector3i, section: Vector3i) -> SectionData:
	var sx: int = size.x
	var sy: int = size.y
	var sz: int = size.z
	var words_x: int = (sx + 15) >> 4
	var layer_words: int = words_x * sy
	var wx: int = section.x
	var x0: int = wx * 16
	var has_left: bool = wx > 0
	var has_right: bool = wx < words_x - 1
	var bit_position: PackedByteArray = _bit_position
	var bit_count: PackedByteArray = _bit_count

	# Corner offsets as locals: the loop below adds them to every face it emits.
	var k: PackedVector3Array = _corners
	var px0: Vector3 = k[0]
	var px1: Vector3 = k[1]
	var px2: Vector3 = k[2]
	var px3: Vector3 = k[3]
	var nx0: Vector3 = k[4]
	var nx1: Vector3 = k[5]
	var nx2: Vector3 = k[6]
	var nx3: Vector3 = k[7]
	var py0: Vector3 = k[8]
	var py1: Vector3 = k[9]
	var py2: Vector3 = k[10]
	var py3: Vector3 = k[11]
	var ny0: Vector3 = k[12]
	var ny1: Vector3 = k[13]
	var ny2: Vector3 = k[14]
	var ny3: Vector3 = k[15]
	var pz0: Vector3 = k[16]
	var pz1: Vector3 = k[17]
	var pz2: Vector3 = k[18]
	var pz3: Vector3 = k[19]
	var nz0: Vector3 = k[20]
	var nz1: Vector3 = k[21]
	var nz2: Vector3 = k[22]
	var nz3: Vector3 = k[23]

	# Faces are collected per direction, so each group's normals can be filled in one go.
	var v_px: PackedVector3Array = PackedVector3Array()
	var v_nx: PackedVector3Array = PackedVector3Array()
	var v_py: PackedVector3Array = PackedVector3Array()
	var v_ny: PackedVector3Array = PackedVector3Array()
	var v_pz: PackedVector3Array = PackedVector3Array()
	var v_nz: PackedVector3Array = PackedVector3Array()
	var c_px: PackedColorArray = PackedColorArray()
	var c_nx: PackedColorArray = PackedColorArray()
	var c_py: PackedColorArray = PackedColorArray()
	var c_ny: PackedColorArray = PackedColorArray()
	var c_pz: PackedColorArray = PackedColorArray()
	var c_nz: PackedColorArray = PackedColorArray()

	var solid: int = 0
	var y_end: int = mini(section.y * 16 + 16, sy)
	var z_end: int = mini(section.z * 16 + 16, sz)
	for z: int in range(section.z * 16, z_end):
		for y: int in range(section.y * 16, y_end):
			var w: int = wx + words_x * (y + sy * z)
			var m: int = occ[w]
			if m == 0:
				continue
			solid += bit_count[m]

			# ext = this row with one neighbour voxel either side: bit n + 1 is voxel n.
			var ext: int = m << 1
			if has_left:
				ext |= (occ[w - 1] >> 15) & 1
			if has_right:
				ext |= (occ[w + 1] & 1) << 17
			# A face shows where this voxel is solid and the one next door isn't.
			var f_px: int = m & ~(ext >> 2)
			var f_nx: int = m & ~ext
			var f_py: int = m & ~occ[w + words_x] if y < sy - 1 else m
			var f_ny: int = m & ~occ[w - words_x] if y > 0 else m
			var f_pz: int = m & ~occ[w + layer_words] if z < sz - 1 else m
			var f_nz: int = m & ~occ[w - layer_words] if z > 0 else m
			var todo: int = f_px | f_nx | f_py | f_ny | f_pz | f_nz
			if todo == 0:
				continue

			var row: int = x0 + sx * (y + sy * z)
			while todo != 0:
				var bit: int = todo & -todo
				todo ^= bit
				var bx: int = bit_position[bit]
				var i: int = row + bx
				var col: Color = lut[cells[i]]
				var s: int = shade[i]
				if s != 255:
					var dim: float = s / 255.0
					col = Color(col.r * dim, col.g * dim, col.b * dim, col.a)
				var p: Vector3 = Vector3(x0 + bx, y, z)
				if (f_px & bit) != 0:
					v_px.append(p + px0)
					v_px.append(p + px1)
					v_px.append(p + px2)
					v_px.append(p + px3)
					c_px.append(col)
					c_px.append(col)
					c_px.append(col)
					c_px.append(col)
				if (f_nx & bit) != 0:
					v_nx.append(p + nx0)
					v_nx.append(p + nx1)
					v_nx.append(p + nx2)
					v_nx.append(p + nx3)
					c_nx.append(col)
					c_nx.append(col)
					c_nx.append(col)
					c_nx.append(col)
				if (f_py & bit) != 0:
					v_py.append(p + py0)
					v_py.append(p + py1)
					v_py.append(p + py2)
					v_py.append(p + py3)
					c_py.append(col)
					c_py.append(col)
					c_py.append(col)
					c_py.append(col)
				if (f_ny & bit) != 0:
					v_ny.append(p + ny0)
					v_ny.append(p + ny1)
					v_ny.append(p + ny2)
					v_ny.append(p + ny3)
					c_ny.append(col)
					c_ny.append(col)
					c_ny.append(col)
					c_ny.append(col)
				if (f_pz & bit) != 0:
					v_pz.append(p + pz0)
					v_pz.append(p + pz1)
					v_pz.append(p + pz2)
					v_pz.append(p + pz3)
					c_pz.append(col)
					c_pz.append(col)
					c_pz.append(col)
					c_pz.append(col)
				if (f_nz & bit) != 0:
					v_nz.append(p + nz0)
					v_nz.append(p + nz1)
					v_nz.append(p + nz2)
					v_nz.append(p + nz3)
					c_nz.append(col)
					c_nz.append(col)
					c_nz.append(col)
					c_nz.append(col)

	var data: SectionData = SectionData.new()
	data.solid = solid
	var groups: Array[PackedVector3Array] = [v_px, v_nx, v_py, v_ny, v_pz, v_nz]
	var group_colors: Array[PackedColorArray] = [c_px, c_nx, c_py, c_ny, c_pz, c_nz]
	for f: int in 6:
		var count: int = groups[f].size()
		if count == 0:
			continue
		data.verts.append_array(groups[f])
		data.colors.append_array(group_colors[f])
		var normals: PackedVector3Array = PackedVector3Array()
		normals.resize(count)
		normals.fill(DIRECTIONS[f])
		data.normals.append_array(normals)
	@warning_ignore("integer_division")
	data.quads = data.verts.size() / 4
	return data


## One section's mesh, or null if it has no faces.
static func to_mesh(data: SectionData) -> ArrayMesh:
	if data == null or data.quads == 0 or _no_renderer:
		return null
	var mesh: ArrayMesh = ArrayMesh.new()
	_add_surface(mesh, data.verts, data.normals, data.colors)
	return mesh


## Every section joined into one mesh, for a model nobody has damaged yet (one draw
## call for a small model; a big one is split into a few surfaces of MAX_QUADS).
## Returns null if there are no faces at all.
static func merge_to_mesh(sections: Array) -> ArrayMesh:
	if _no_renderer:
		return null
	var mesh: ArrayMesh = ArrayMesh.new()
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var quads: int = 0
	for entry: Variant in sections:
		var data: SectionData = entry as SectionData
		if data == null or data.quads == 0:
			continue
		if quads + data.quads > MAX_QUADS:
			_add_surface(mesh, verts, normals, colors)
			verts = PackedVector3Array()
			normals = PackedVector3Array()
			colors = PackedColorArray()
			quads = 0
		verts.append_array(data.verts)
		normals.append_array(data.normals)
		colors.append_array(data.colors)
		quads += data.quads
	if quads > 0:
		_add_surface(mesh, verts, normals, colors)
	return mesh if mesh.get_surface_count() > 0 else null


static func _add_surface(mesh: ArrayMesh, verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray) -> void:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	@warning_ignore("integer_division")
	arrays[Mesh.ARRAY_INDEX] = _quad_indices.slice(0, verts.size() / 4 * 6)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
