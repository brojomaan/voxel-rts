extends Node
## Autoload as "InteractionService".
## The player's mouse in the world: works out what it's over, and turns clicks into
## selection and orders. All world mouse input comes through here.
##
##   Left click on a unit    select it
##   Left click on the ground  order the selected unit to move there
##   Right click             deselect
##
## Clicks with Ctrl held are left alone (the voxel test gun uses them).

## Emitted when a move order is given, for feedback (a marker, a sound).
signal move_ordered(unit: Unit, point: Vector3)

const GROUND: Plane = Plane(Vector3.UP, 0.0)


func _process(_delta: float) -> void:
	SelectionService.set_hovered(_unit_under_mouse())


func _unhandled_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button == null or not button.pressed or button.ctrl_pressed:
		return
	if button.button_index == MOUSE_BUTTON_LEFT:
		var unit: Unit = _unit_under_mouse()
		if unit:
			SelectionService.select(unit)
			return
		var selected: Unit = SelectionService.get_selected()
		if selected == null:
			return
		var point: Variant = _ground_under_mouse()
		if point != null:
			selected.order_move(point)
			move_ordered.emit(selected, point)
	elif button.button_index == MOUSE_BUTTON_RIGHT:
		SelectionService.clear_selection()


## The nearest unit along the mouse ray, voxel-exact, or null.
func _unit_under_mouse() -> Unit:
	var camera: Camera3D = ViewService.get_camera()
	if camera == null:
		return null
	var mouse: Vector2 = ViewService.get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse)
	var dir: Vector3 = camera.project_ray_normal(mouse)
	var best: Unit = null
	var best_distance: float = INF
	for node: Node in get_tree().get_nodes_in_group(&"units"):
		var unit: Unit = node as Unit
		var hit: Dictionary = unit.raycast(from, dir)
		if not hit.is_empty() and float(hit.distance) < best_distance:
			best_distance = hit.distance
			best = unit
	return best


## Where the mouse ray meets the ground (y = 0), or null if it doesn't.
func _ground_under_mouse() -> Variant:
	var camera: Camera3D = ViewService.get_camera()
	if camera == null:
		return null
	var mouse: Vector2 = ViewService.get_mouse_position()
	return GROUND.intersects_ray(camera.project_ray_origin(mouse), camera.project_ray_normal(mouse))
