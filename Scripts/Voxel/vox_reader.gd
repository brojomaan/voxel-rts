class_name VoxReader
extends RefCounted
## Reads MagicaVoxel .vox files into a VoxelGrid.
## Handles the model chunks (SIZE, XYZI) and the palette (RGBA). The scene graph,
## materials and layers are skipped, so a file with several models gives each one
## back separately by index, without its placement.
## MagicaVoxel is Z-up with +Y as "forward" in its viewport; we turn that into Godot's
## Y-up with -Z forward, so a barrel modelled pointing +Y points the way Godot faces.
##
## Team colour: palette entries that are pure magenta (any brightness, e.g. FF00FF,
## CC00CC, 990099, 660066) are team colour. The game swaps them for the owner's colour.
##
## Gotcha: .vox isn't a type Godot imports, so exported builds need "*.vox" in the
## export preset's "Filters to export non-resource files". An import plugin that
## turns .vox into a resource would remove that step later.


## Loads one model from a .vox file. Returns null (and reports why) if it can't.
static func load_grid(path: String, model_index: int = 0) -> VoxelGrid:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("VoxReader: can't open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return null
	if file.get_buffer(4).get_string_from_ascii() != "VOX ":
		push_error("VoxReader: %s isn't a MagicaVoxel file" % path)
		return null
	file.get_32()  # file version; 150 and 200 share the chunks we read

	var sizes: Array[Vector3i] = []
	var models: Array[PackedByteArray] = []
	var palette: PackedColorArray = PackedColorArray()
	palette.resize(256)
	palette.fill(Color(0.7, 0.7, 0.7))  # used only if the file has no palette

	# Chunks: 4-char id, content size, children size, content, then any children.
	# Skipping only the content means children (inside MAIN) are read as we go.
	while file.get_position() + 12 <= file.get_length():
		var id: String = file.get_buffer(4).get_string_from_ascii()
		var content_size: int = file.get_32()
		file.get_32()  # children size
		var start: int = file.get_position()
		match id:
			"SIZE":
				var sx: int = file.get_32()
				var sy: int = file.get_32()
				var sz: int = file.get_32()
				sizes.append(Vector3i(sx, sy, sz))
			"XYZI":
				var count: int = file.get_32()
				models.append(file.get_buffer(count * 4))
			"RGBA":
				# Entry i is colour index i + 1 (index 0 means empty).
				for i: int in 255:
					var r: int = file.get_8()
					var g: int = file.get_8()
					var b: int = file.get_8()
					file.get_8()  # alpha, unused
					palette[i + 1] = Color8(r, g, b)
		file.seek(start + content_size)

	if model_index < 0 or model_index >= models.size():
		push_error("VoxReader: %s has %d model(s), asked for #%d" % [path, models.size(), model_index])
		return null

	var mv_size: Vector3i = sizes[model_index]
	var grid: VoxelGrid = VoxelGrid.new(Vector3i(mv_size.x, mv_size.z, mv_size.y))
	grid.palette = palette
	for i: int in range(1, 256):
		var c: Color = palette[i]
		if c.g < 0.05 and c.r > 0.25 and absf(c.r - c.b) < 0.02:
			grid.team_shade[i] = c.r
	# Filled through locals (same arrays, by reference): this loop runs once per voxel.
	var data: PackedByteArray = models[model_index]
	var cells: PackedByteArray = grid.cells
	var occ: PackedInt32Array = grid.occ
	var gx: int = grid.size.x
	var gy: int = grid.size.y
	var words_x: int = grid.words_x
	var flip: int = mv_size.y - 1
	var size_ok: bool = true
	for v: int in range(0, data.size(), 4):
		var x: int = data[v]
		if x >= gx or data[v + 1] > flip or data[v + 2] >= gy:
			size_ok = false
			continue
		# MagicaVoxel (x, y, z) Z-up -> Godot (x, z, flipped y) Y-up.
		var row: int = data[v + 2] + gy * (flip - data[v + 1])
		cells[x + gx * row] = data[v + 3]
		occ[(x >> 4) + words_x * row] |= 1 << (x & 15)
	if not size_ok:
		push_warning("VoxReader: %s has voxels outside its own size; they were skipped" % path)
	return grid
