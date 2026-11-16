class_name VoxelTestGun
extends Node
## Test harness for the voxel prototype, not game code: Ctrl + click things to shoot them
## (plain clicks belong to InteractionService: select and move).
## Ctrl + left click = tank shell, Ctrl + Shift + left click = rifle,
## Ctrl + right click = destroy (crumble),
## F2 = switch detail (quarter res + 1/16 voxels <-> half res + 1/32 voxels),
## F3 = pixel view on/off (off draws the same scene at full resolution),
## T = toon (banded) lighting on/off, O = dark outlines and edge highlights on/off,
## R = reset the scene.
## Lives inside the world's SubViewport, so it gets the input PixelView forwards, and
## aims with ViewService (low-res mouse + world camera).
## Must sit above the camera rig, debris and props in the scene: it sets up the detail
## level in its _ready, before theirs run.

## Crater radius for a shell, in world units (so it's the same size at either detail).
@export var shell_radius: float = 0.25
## Crater radius for a rifle shot, in world units.
@export var rifle_radius: float = 0.075
## 1 = quarter res, 1/16 voxels. 2 = half res, 1/32 voxels. Survives the F2 reload.
static var detail: int = 1
## False draws the world at full resolution, to compare. Survives the F3 reload.
static var pixel_view: bool = true
## False lights the world smoothly instead of in bands, to compare.
static var toon_lighting: bool = true
## False hides the dark outlines and edge highlights (selection lines stay).
static var outlines: bool = true


var _help: Label
var _help_text: String = ""
var _peak_msec: float = 0.0
var _readout_timer: float = 0.0


func _ready() -> void:
	_apply_detail()
	# The camera isn't ready yet, and the outline setting lives on it.
	_apply_look.call_deferred()


## Shows what the voxel work cost the main thread: the worst frame in the last half second.
func _process(delta: float) -> void:
	_peak_msec = maxf(_peak_msec, VoxelService.last_frame_msec)
	_readout_timer -= delta
	if _readout_timer > 0.0 or _help == null:
		return
	_readout_timer = 0.5
	_help.text = "%s\nVoxel edits on the main thread: peak %.2f ms a frame   In progress: %d   FPS: %d" % [
		_help_text, _peak_msec, VoxelService.get_pending_count(), Engine.get_frames_per_second()]
	_peak_msec = 0.0


func _unhandled_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button and button.pressed:
		if not button.ctrl_pressed:
			return
		if button.button_index == MOUSE_BUTTON_LEFT:
			shoot(rifle_radius if button.shift_pressed else shell_radius)
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			destroy()
		return
	var key: InputEventKey = event as InputEventKey
	if key and key.pressed and not key.echo:
		if key.physical_keycode == KEY_R:
			get_tree().reload_current_scene()
		elif key.physical_keycode == KEY_F2:
			detail = 2 if detail == 1 else 1
			get_tree().reload_current_scene()
		elif key.physical_keycode == KEY_F3:
			pixel_view = not pixel_view
			get_tree().reload_current_scene()
		elif key.physical_keycode == KEY_T:
			toon_lighting = not toon_lighting
			_apply_look()
		elif key.physical_keycode == KEY_O:
			outlines = not outlines
			_apply_look()


## Sets the render scale, camera zoom, voxel size and models for the detail level.
## Runs before the other world nodes' _ready, so they start up with these values.
func _apply_detail() -> void:
	var voxel_size: float = 1.0 / (16.0 * detail)
	# PixelView owns our SubViewport.
	var view: PixelView = get_viewport().get_parent() as PixelView
	if view:
		@warning_ignore("integer_division")
		view.pixel_scale = 4 / detail
		view.native_resolution = not pixel_view
	# Same ground on screen: twice the low-res pixels per world unit at half res.
	var rig: CameraRig = get_tree().get_first_node_in_group(&"camera_rig") as CameraRig
	if rig == null:
		rig = get_parent().find_child("CameraRig", false, false) as CameraRig
	if rig:
		var ppu: int = 16 * detail
		var level: int = rig.zoom_levels.find(ppu)
		if level >= 0:
			rig.start_level = level
	var debris: VoxelDebris = get_parent().find_child("VoxelDebris", false, false) as VoxelDebris
	if debris:
		debris.piece_size = voxel_size
	# Every voxel body in the world, units' included: models with a "_hi" version use
	# it at double detail and the plain one otherwise.
	for body: VoxelBody in _bodies_under(get_parent()):
		body.voxel_size = voxel_size
		body.scorch_width = 1.5 * detail
		body.loose_debris_limit = 40 * detail * detail * detail
		var plain_path: String = body.vox_path.replace("_hi.vox", ".vox")
		var hi_path: String = plain_path.get_basename() + "_hi.vox"
		body.vox_path = hi_path if detail > 1 and FileAccess.file_exists(hi_path) else plain_path
	_set_help_text()


## Pushes the lighting and outline choices to the shaders.
func _apply_look() -> void:
	RenderingServer.global_shader_parameter_set(&"pixel_shading_smooth", not toon_lighting)
	var camera: Camera3D = ViewService.get_camera()
	var outline_pass: MeshInstance3D = camera.get_node_or_null("OutlinePass") as MeshInstance3D if camera else null
	var outline_material: ShaderMaterial = outline_pass.material_overlay as ShaderMaterial if outline_pass else null
	if outline_material:
		outline_material.set_shader_parameter(&"outline_enabled", outlines)
		outline_material.set_shader_parameter(&"highlight_enabled", outlines)
	_set_help_text()


func _bodies_under(node: Node) -> Array[VoxelBody]:
	var found: Array[VoxelBody] = []
	for child: Node in node.get_children():
		if child is VoxelBody:
			found.append(child as VoxelBody)
		found.append_array(_bodies_under(child))
	return found


func _set_help_text() -> void:
	var game: Node = get_viewport().get_parent().get_parent() if get_viewport().get_parent() else null
	_help = game.get_node_or_null("TestHelp/Label") as Label if game else null
	var mode: String = "1/16 voxels" if detail == 1 else "1/32 voxels"
	if pixel_view:
		mode = ("Quarter res, " if detail == 1 else "Half res, ") + mode
	else:
		mode = "Pixel view off, " + mode
	mode += ", toon lighting " + ("on" if toon_lighting else "off") + ", outlines " + ("on" if outlines else "off")
	_help_text = "%s\nLeft click: select / deselect   Right click: move   A + right click: attack   Arrows: camera\nTest: Ctrl+click shell   Ctrl+Shift+click rifle   Ctrl+right click destroy   F2 detail   F3 pixel view   T toon lighting   O outlines   R reset" % mode
	if _help:
		_help.text = _help_text


## Fires along the mouse ray at the nearest voxel body. radius in world units.
func shoot(radius: float) -> void:
	var hit: Dictionary = _pick()
	if hit.is_empty():
		return
	var body: VoxelBody = hit.body as VoxelBody
	body.carve(hit.point, radius / body.voxel_size, hit.dir)


func destroy() -> void:
	var hit: Dictionary = _pick()
	if not hit.is_empty():
		(hit.body as VoxelBody).crumble()


## The nearest voxel body under the mouse: {body, point, dir}, or {}.
func _pick() -> Dictionary:
	var camera: Camera3D = ViewService.get_camera()
	if not camera:
		return {}
	var mouse: Vector2 = ViewService.get_mouse_position()
	return pick_along(camera.project_ray_origin(mouse), camera.project_ray_normal(mouse))


func pick_along(from: Vector3, dir: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_distance: float = INF
	for node: Node in get_tree().get_nodes_in_group(&"voxel_bodies"):
		var body: VoxelBody = node as VoxelBody
		var hit: Dictionary = body.raycast(from, dir)
		if not hit.is_empty() and float(hit.distance) < best_distance:
			best_distance = hit.distance
			best = {"body": body, "point": hit.point, "dir": dir}
	return best
