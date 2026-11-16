class_name VoxelTestGun
extends Node
## Test harness for the voxel prototype, not game code: click things to shoot them.
## Left click = tank shell, Shift + left click = rifle, Right click = destroy (crumble),
## R = reset the scene. Lives inside the world's SubViewport, so it gets the input
## PixelView forwards, and aims with ViewService (low-res mouse + world camera).

## Crater radius in voxels for a shell.
@export var shell_radius: float = 4.0
## Crater radius in voxels for a rifle shot.
@export var rifle_radius: float = 1.2


func _unhandled_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button and button.pressed:
		if button.button_index == MOUSE_BUTTON_LEFT:
			shoot(rifle_radius if button.shift_pressed else shell_radius)
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			destroy()
		return
	var key: InputEventKey = event as InputEventKey
	if key and key.pressed and not key.echo and key.physical_keycode == KEY_R:
		get_tree().reload_current_scene()


## Fires along the mouse ray at the nearest voxel body.
func shoot(radius: float) -> void:
	var hit: Dictionary = _pick()
	if hit.is_empty():
		return
	(hit.body as VoxelBody).carve(hit.point, radius, hit.dir)


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
