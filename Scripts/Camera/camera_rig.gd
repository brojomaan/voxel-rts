class_name CameraRig
extends Node3D
## Pans across the ground plane and zooms in pixel-perfect steps.
## The rig owns yaw; the child camera owns pitch, distance and pixel snapping.

@export var camera: Camera3D
@export var pan_speed: float = 10.0
## Hold Shift to pan this many times faster.
@export var fast_pan_multiplier: float = 2.5
@export var bounds: Vector2 = Vector2(30.0, 30.0)  # half-size of the playable area on X and Z
## Pan when the mouse touches the window's edge (classic RTS). Off while testing in the editor
## is often nicer, since the mouse leaves the game window a lot.
@export var edge_pan: bool = true

@export_group("Zoom")
## Low-res pixels per world unit at each zoom level (at the normal pixel size).
## Must be in ascending order.
@export var zoom_levels: Array[int] = [4, 6, 8, 12, 16, 24, 32, 48, 64]
@export var start_level: int = 6
## Far zoom levels can render with smaller pixels, so far views show detail instead of
## mush: zoom level (pixels per unit, from zoom_levels) -> screen pixels per world pixel.
## Levels not listed use the normal size (4). Step it down gently (4, 3, 2) so no one
## zoom step jumps in pixel size.
@export var level_pixel_scales: Dictionary = {4: 2, 6: 2, 8: 3}
@export var zoom_smoothing: float = 12.0

var _level: int = 6
var _dragging: bool = false
## Screen pixels from the window's edge where edge panning starts (when it's on).
const EDGE_MARGIN: float = 8.0
var _base_pixel_scale: int = 0
var _visual_ppu: float = 32.0


func _ready() -> void:
	add_to_group(&"camera_rig")
	_level = clampi(start_level, 0, zoom_levels.size() - 1)
	_visual_ppu = float(zoom_levels[_level])


## Glide over to look at a point (e.g. jump to an attacked base).
func focus_on(world: Vector3) -> void:
	var target: Vector3 = Vector3(clampf(world.x, -bounds.x, bounds.x), global_position.y, clampf(world.z, -bounds.y, bounds.y))
	var tween: Tween = create_tween()
	tween.tween_property(self, "global_position", target, 0.35).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _unhandled_input(event: InputEvent) -> void:
	# Hold the middle mouse button and drag to pan: the ground follows the mouse.
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button and button.button_index == MOUSE_BUTTON_MIDDLE:
		_dragging = button.pressed
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion and _dragging:
		# Let go somewhere we didn't hear about (over the UI, outside the window).
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			_dragging = false
			return
		_drag(motion.relative)
		return
	if event.is_action_pressed("zoom_in"):
		_level = mini(_level + 1, zoom_levels.size() - 1)
	elif event.is_action_pressed("zoom_out"):
		_level = maxi(_level - 1, 0)


func _process(delta: float) -> void:
	_handle_pan(delta)
	_handle_zoom(delta)


## Move by a mouse drag (in world-view pixels), so the ground stays under the cursor.
func _drag(relative: Vector2) -> void:
	if not camera:
		return
	var view_height: float = camera.get_viewport().get_visible_rect().size.y
	var texel: float = camera.size / maxf(view_height, 1.0)
	var basis: Basis = camera.global_basis
	var right: Vector3 = basis.x
	var look: Vector3 = -basis.z
	# One step up the screen covers this much ground (more than a step, as we look down).
	var up_on_ground: Vector3 = basis.y - look * (basis.y.y / look.y) if absf(look.y) > 0.001 else basis.y
	right.y = 0.0
	up_on_ground.y = 0.0
	global_position -= (right * relative.x - up_on_ground * relative.y) * texel
	global_position.x = clampf(global_position.x, -bounds.x, bounds.x)
	global_position.z = clampf(global_position.z, -bounds.y, bounds.y)


func _handle_pan(delta: float) -> void:
	var input: Vector2 = Input.get_vector("camera_left", "camera_right", "camera_forward", "camera_back")
	if edge_pan and not _dragging:
		input += _edge_input()
	input = input.limit_length(1.0)
	if input == Vector2.ZERO:
		return

	var direction: Vector3 = global_transform.basis * Vector3(input.x, 0.0, input.y)
	direction.y = 0.0
	direction = direction.normalized()

	# Zoomed out (fewer pixels per unit) pans faster, so it feels the same on screen.
	var zoom_factor: float = float(zoom_levels[start_level]) / _visual_ppu
	var fast: bool = Input.is_key_pressed(KEY_SHIFT)
	var boost: float = fast_pan_multiplier if fast else 1.0
	global_position += direction * pan_speed * boost * zoom_factor * delta

	global_position.x = clampf(global_position.x, -bounds.x, bounds.x)
	global_position.z = clampf(global_position.z, -bounds.y, bounds.y)


## Mouse at the window's edge: pan that way (the Options' edge panning).
func _edge_input() -> Vector2:
	var root: Window = get_tree().root
	if not root.has_focus():
		return Vector2.ZERO
	var mouse: Vector2 = root.get_mouse_position()
	var area: Vector2 = root.get_visible_rect().size
	if mouse.x < 0.0 or mouse.y < 0.0 or mouse.x > area.x or mouse.y > area.y:
		return Vector2.ZERO
	var edge: Vector2 = Vector2.ZERO
	if mouse.x <= EDGE_MARGIN:
		edge.x = -1.0
	elif mouse.x >= area.x - EDGE_MARGIN:
		edge.x = 1.0
	if mouse.y <= EDGE_MARGIN:
		edge.y = -1.0
	elif mouse.y >= area.y - EDGE_MARGIN:
		edge.y = 1.0
	return edge


func _handle_zoom(delta: float) -> void:
	if not camera:
		return

	var target: float = float(zoom_levels[_level])
	var weight: float = 1.0 - exp(-zoom_smoothing * delta)
	_visual_ppu = lerpf(_visual_ppu, target, weight)
	if absf(_visual_ppu - target) < 0.01:
		_visual_ppu = target

	# Render at the highest level that's not above the visual zoom, and make up the
	# difference by scaling the finished image. The render's pixel size only ever
	# changes when it lands exactly on a level, so it can't shimmer in between.
	var render_ppu: int = zoom_levels[0]
	for level_ppu: int in zoom_levels:
		if float(level_ppu) <= _visual_ppu + 0.001:
			render_ppu = level_ppu

	# Far out: finer pixels. More pixels per unit, each smaller on screen, so the view
	# covers the same ground.
	if _base_pixel_scale <= 0:
		_base_pixel_scale = ViewService.get_pixel_scale()
	var pixel_scale: int = clampi(int(level_pixel_scales.get(render_ppu, _base_pixel_scale)), 1, _base_pixel_scale)
	ViewService.set_pixel_scale(pixel_scale)
	var density: float = float(_base_pixel_scale) / float(pixel_scale)

	var view_height: float = camera.get_viewport().get_visible_rect().size.y
	camera.size = view_height / (float(render_ppu) * density)
	ViewService.set_zoom_scale(_visual_ppu / float(render_ppu))
