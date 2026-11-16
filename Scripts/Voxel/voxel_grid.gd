class_name VoxelGrid
extends RefCounted
## A box of voxels. Y is up; cell (0, 0, 0) is the bottom corner.
## Three arrays describe it:
##  - cells: one palette index per cell (0 = empty)
##  - shade: brightness per cell (255 = full colour, lower = scorched)
##  - occ:   one bit per cell, 16 cells of a row per word. The mesher finds visible
##           faces with a few bit operations per row instead of testing every voxel.
##
## Gotcha: packed arrays are shared by reference. Once a grid is in use its arrays are
## never written in place: an edit builds new arrays (on a worker thread) and the
## owner swaps them in. Use set_cell only while building a grid.

## Edge of a mesh section, in voxels, and the cells per occupancy word. Must be 16.
const SECTION: int = 16

var size: Vector3i = Vector3i.ZERO
## Palette index per cell, 0 = empty. Flat: x + size.x * (y + size.y * z).
var cells: PackedByteArray = PackedByteArray()
## Brightness per cell, 255 = untouched.
var shade: PackedByteArray = PackedByteArray()
## Occupancy bits. Word index: (x >> 4) + words_x * (y + size.y * z); bit: x & 15.
var occ: PackedInt32Array = PackedInt32Array()
## Occupancy words per row.
var words_x: int = 0
## 256 colours in sRGB; index 0 is unused (empty).
var palette: PackedColorArray = PackedColorArray()
## Per palette index: 0 = ordinary colour, otherwise this entry is a team colour
## (one of the reserved magentas) and the value is its brightness, 0..1.
var team_shade: PackedFloat32Array = PackedFloat32Array()


func _init(grid_size: Vector3i = Vector3i.ZERO) -> void:
	size = grid_size
	words_x = (size.x + SECTION - 1) >> 4
	cells.resize(size.x * size.y * size.z)
	shade.resize(cells.size())
	shade.fill(255)
	occ.resize(words_x * size.y * size.z)
	palette.resize(256)
	palette.fill(Color(0.7, 0.7, 0.7))
	team_shade.resize(256)


## A grid around arrays that already exist (a broken-off chunk, an edit's result).
## Palette and team colours come from source.
static func from_arrays(grid_size: Vector3i, new_cells: PackedByteArray, new_shade: PackedByteArray,
		new_occ: PackedInt32Array, source: VoxelGrid) -> VoxelGrid:
	var grid: VoxelGrid = VoxelGrid.new(Vector3i.ZERO)
	grid.size = grid_size
	grid.words_x = (grid_size.x + SECTION - 1) >> 4
	grid.cells = new_cells
	grid.shade = new_shade
	grid.occ = new_occ
	grid.palette = source.palette
	grid.team_shade = source.team_shade
	return grid


func index_of(cell: Vector3i) -> int:
	return cell.x + size.x * (cell.y + size.y * cell.z)


@warning_ignore("integer_division")
func cell_of(index: int) -> Vector3i:
	return Vector3i(index % size.x, (index / size.x) % size.y, index / (size.x * size.y))


func in_bounds(cell: Vector3i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.z >= 0 \
		and cell.x < size.x and cell.y < size.y and cell.z < size.z


## Only while building a grid (see the gotcha above).
func set_cell(cell: Vector3i, colour_index: int) -> void:
	cells[index_of(cell)] = colour_index
	var word: int = (cell.x >> 4) + words_x * (cell.y + size.y * cell.z)
	if colour_index != 0:
		occ[word] |= 1 << (cell.x & 15)
	else:
		occ[word] &= ~(1 << (cell.x & 15))


func count_solid() -> int:
	return cells.size() - cells.count(0)


## How many mesh sections the grid splits into on each axis.
func section_count() -> Vector3i:
	return Vector3i((size.x + SECTION - 1) >> 4, (size.y + SECTION - 1) >> 4, (size.z + SECTION - 1) >> 4)


## The lowest layer with any voxel in it (a model doesn't have to start at the canvas
## floor), or 0 for an empty grid. That layer is what stands on the ground.
func lowest_solid_layer() -> int:
	for y: int in size.y:
		for z: int in size.z:
			var w: int = words_x * (y + size.y * z)
			for wx: int in words_x:
				if occ[w + wx] != 0:
					return y
	return 0


## The highest layer with any voxel in it, or -1 for an empty grid.
func highest_solid_layer() -> int:
	for y: int in range(size.y - 1, -1, -1):
		for z: int in size.z:
			var w: int = words_x * (y + size.y * z)
			for wx: int in words_x:
				if occ[w + wx] != 0:
					return y
	return -1


## Colour per palette index as the mesher writes it into vertices (sRGB): team entries
## are a grey brightness with alpha 0, which tells the shader to multiply the team
## colour in. Ordinary entries have alpha 1.
func vertex_lut() -> PackedColorArray:
	var lut: PackedColorArray = PackedColorArray()
	lut.resize(256)
	for i: int in 256:
		var team: float = team_shade[i]
		if team > 0.0:
			lut[i] = Color(team, team, team, 0.0)
		else:
			lut[i] = Color(palette[i].r, palette[i].g, palette[i].b, 1.0)
	return lut


## Colour per palette index as it looks on screen for this team (sRGB). For debris.
func display_lut(team_color: Color) -> PackedColorArray:
	var lut: PackedColorArray = PackedColorArray()
	lut.resize(256)
	for i: int in 256:
		var team: float = team_shade[i]
		if team > 0.0:
			lut[i] = Color(team_color.r * team, team_color.g * team, team_color.b * team, 1.0)
		else:
			lut[i] = Color(palette[i].r, palette[i].g, palette[i].b, 1.0)
	return lut


## A grid that shares this one's arrays (cheap). Safe because arrays are replaced,
## never written in place.
func share() -> VoxelGrid:
	return VoxelGrid.from_arrays(size, cells, shade, occ, self)
