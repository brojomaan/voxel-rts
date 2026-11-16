extends Node
## Autoload as "InteractionService".
## The player's mouse in the world: works out what it's over, and turns clicks into
## selection and orders. All world mouse input comes through here.
##
##   Left click a unit          select it
##   Left click nothing         deselect
##   Right click                move the selected unit there
##   A + right click            attack: the unit under the mouse, or that spot
##
## Clicks with Ctrl held are left alone (the voxel test gun uses them).
## The attack key is the "attack_modifier" input action.

## Emitted when an order is given, for feedback (a marker, a sound).
signal move_ordered(unit: Unit, point: Vector3)
signal attack_ordered(unit: Unit, target: Unit, point: Vector3)

const GROUND: Plane = Plane(Vector3.UP, 0.0)


func _process(_delta: float) -> void:
	SelectionService.set_hovered(_unit_under_mouse())


func _unhandled_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button == null or not button.pressed or button.ctrl_pressed:
		return
	if button.button_index == MOUSE_BUTTON_LEFT:
		# Selects what's under the mouse; nothing there clears the selection.
		SelectionService.select(_unit_under_mouse())
	elif button.button_index == MOUSE_BUTTON_RIGHT:
		var selected: Unit = SelectionService.get_selected()
		if selected == null:
			return
		var ground: Variant = _ground_under_mouse()
		if Input.is_action_pressed(&"attack_modifier"):
			var target: Unit = _unit_under_mouse()
			if target != null and target != selected:
				selected.order_attack_unit(target)
				attack_ordered.emit(selected, target, target.global_position)
			elif ground != null:
				selected.order_attack_point(ground)
				attack_ordered.emit(selected, null, ground)
		elif ground != null:
			selected.order_move(ground)
			move_ordered.emit(selected, ground)


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
