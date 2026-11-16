extends Node
## Autoload as "ViewService".
## Where the game world is drawn. The 3D world renders into a low-res SubViewport,
## so root-level services can't use get_viewport() for the camera or the mouse.
## Without a PixelView it falls back to the root viewport, so nothing depends on it.

var _view: PixelView

func register(view: PixelView) -> void:
	_view = view

func unregister(view: PixelView) -> void:
	if _view == view:
		_view = null

func get_camera() -> Camera3D:
	if is_instance_valid(_view):
		return _view.sub_viewport.get_camera_3d()
	return get_viewport().get_camera_3d()

## The mouse in world-view pixels : what the 3d camera's ray functions expect.
func get_mouse_position() -> Vector2:
	var mouse: Vector2 = get_viewport().get_mouse_position()
	if is_instance_valid(_view):
		return _view.screen_to_view(mouse)
	return mouse

func world_to_screen(world_position: Vector3) -> Vector2:
	var camera: Camera3D = get_camera()
	if not camera:
		return Vector2.ZERO
	
	var view_position: Vector2 = camera.unproject_position(world_position)
	if is_instance_valid(_view):
		return _view.view_to_screen(view_position)
	return view_position

func set_subpixel_offset(offset: Vector2) -> void:
	if is_instance_valid(_view):
		_view.apply_subpixel_offset(offset)

## Screen pixels per world pixel right now (the PixelView's pixel_scale), 4 if none.
func get_pixel_scale() -> int:
	return _view.pixel_scale if is_instance_valid(_view) else 4


## Screen units per world pixel as actually drawn: the pixel scale, or a fraction when
## the view is at native resolution. 4 if there's no PixelView.
func get_view_scale() -> float:
	return _view.get_view_scale() if is_instance_valid(_view) else 4.0


func set_pixel_scale(new_scale: int) -> void:
	if is_instance_valid(_view):
		_view.set_pixel_scale(new_scale)


func set_zoom_scale(scale: float) -> void:
	if is_instance_valid(_view):
		_view.apply_zoom_scale(scale)
