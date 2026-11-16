class_name VoxelMesher
extends RefCounted
## Turns a VoxelGrid into a mesh with only the faces that touch air, the way Minecraft
## does: a solid block of voxels costs nothing inside, only its skin is drawn.
## Each face carries its voxel's colour as a vertex colour (use a material with
## use_vertex_color on). Faces aren't merged (no greedy meshing) yet: simpler, and
## per-voxel faces are what the build-up and scorch effects will want anyway.

const DIRECTIONS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## The four corners of each face, in a unit cube, matching DIRECTIONS.
const CORNERS: Array = [
	[Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
	[Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0), Vector3(0, 0, 0)],
	[Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
	[Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1)],
	[Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1), Vector3(0, 0, 1)],
	[Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)],
]

## Triangle order per face, worked out once so every face winds the way Godot draws
## as its front (clockwise seen from outside).
static var _winding: Array[PackedInt32Array] = []


## Builds the mesh. origin = where the grid's (0, 0, 0) corner sits, in local units.
## Returns null for an empty grid.
static func build(grid: VoxelGrid, voxel_size: float, origin: Vector3) -> ArrayMesh:
	_ensure_winding()
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colours: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()

	var sx: int = grid.size.x
	var sy: int = grid.size.y
	var sz: int = grid.size.z
	var cells: PackedByteArray = grid.cells
	var layer: int = sx * sy
	# Index steps to each neighbour, so the inner loop is plain arithmetic.
	var steps: PackedInt32Array = PackedInt32Array([1, -1, sx, -sx, layer, -layer])

	var i: int = 0
	for z: int in sz:
		for y: int in sy:
			for x: int in sx:
				if cells[i] != 0:
					var colour: Color = grid.color_at(i)
					var base: Vector3 = Vector3(x, y, z)
					for f: int in 6:
						# Is the neighbour on this side empty (or off the grid)?
						var open: bool
						match f:
							0: open = x == sx - 1
							1: open = x == 0
							2: open = y == sy - 1
							3: open = y == 0
							4: open = z == sz - 1
							_: open = z == 0
						if not open and cells[i + steps[f]] != 0:
							continue
						var first: int = verts.size()
						var corners: Array = CORNERS[f]
						var normal: Vector3 = Vector3(DIRECTIONS[f])
						for c: int in 4:
							verts.append(origin + (base + (corners[c] as Vector3)) * voxel_size)
							normals.append(normal)
							colours.append(colour)
						for k: int in _winding[f]:
							indices.append(first + k)
				i += 1

	if verts.is_empty():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _ensure_winding() -> void:
	if not _winding.is_empty():
		return
	for f: int in 6:
		var c: Array = CORNERS[f]
		var a: Vector3 = c[0]
		var b: Vector3 = c[1]
		var d: Vector3 = c[2]
		var facing: float = (b - a).cross(d - a).dot(Vector3(DIRECTIONS[f]))
		# Godot's front face is clockwise from outside: the cross product points inward.
		if facing < 0.0:
			_winding.append(PackedInt32Array([0, 1, 2, 0, 2, 3]))
		else:
			_winding.append(PackedInt32Array([0, 2, 1, 0, 3, 2]))
