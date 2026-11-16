class_name VoxelGrid
extends RefCounted
## A box of voxels: one palette index per cell (0 = empty) and a shade byte per cell
## (255 = full colour, lower = scorched). Dense arrays, since our models are small
## (a tank is a few thousand cells). Y is up; cell (0, 0, 0) is the bottom corner.

var size: Vector3i = Vector3i.ZERO
## Palette index per cell, 0 = empty. Flat: x + size.x * (y + size.y * z).
var cells: PackedByteArray = PackedByteArray()
## Brightness per cell, 255 = untouched. Scorch marks lower it.
var shade: PackedByteArray = PackedByteArray()
## 256 colours in sRGB; index 0 is unused (empty).
var palette: PackedColorArray = PackedColorArray()


func _init(grid_size: Vector3i = Vector3i.ZERO) -> void:
	size = grid_size
	cells.resize(size.x * size.y * size.z)
	shade.resize(cells.size())
	shade.fill(255)
	palette.resize(256)
	palette.fill(Color(0.7, 0.7, 0.7))


func index_of(cell: Vector3i) -> int:
	return cell.x + size.x * (cell.y + size.y * cell.z)


func cell_of(index: int) -> Vector3i:
	var x: int = index % size.x
	var y: int = (index / size.x) % size.y
	var z: int = index / (size.x * size.y)
	return Vector3i(x, y, z)


func in_bounds(cell: Vector3i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.z >= 0 \
		and cell.x < size.x and cell.y < size.y and cell.z < size.z


func is_solid(cell: Vector3i) -> bool:
	return in_bounds(cell) and cells[index_of(cell)] != 0


## The cell's colour with its scorch applied (sRGB).
func color_at(index: int) -> Color:
	var base: Color = palette[cells[index]]
	var s: float = float(shade[index]) / 255.0
	return Color(base.r * s, base.g * s, base.b * s)


func count_solid() -> int:
	return cells.size() - cells.count(0)


## A separate copy that can be changed without touching this one.
func duplicate_grid() -> VoxelGrid:
	var copy: VoxelGrid = VoxelGrid.new(Vector3i.ZERO)
	copy.size = size
	copy.cells = cells.duplicate()
	copy.shade = shade.duplicate()
	copy.palette = palette.duplicate()
	return copy
