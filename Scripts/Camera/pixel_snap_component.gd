class_name PixelSnapComponent
extends Node
## Draws a moving object's visual snapped to the low-res pixel grid, so it steps
## a clean pixel at a time instead of crawling. The object's real position stays
## smooth; only where its visual is drawn gets snapped.

@export var target: Node3D

func _ready() -> void:
	# Lower runs first: after movement (0) and after the camera has snapped (100).
	process_priority = 200

func _process(delta: float) -> void:
	if not target:
		return
	
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return
	
	var anchor: Node3D = target.get_parent() as Node3D
	var texel: float = camera.size / float(get_viewport().get_visible_rect().size.y)
	
	#Same maths as the camera: snaps along the screen right and screen up, keep depth.
	var view_basis: Basis = camera.global_transform.basis
	var local: Vector3 = view_basis.inverse()* anchor.global_position
	var snapped: Vector3 = Vector3(snappedf(local.x, texel), snappedf(local.y, texel), local.z)
	target.global_position = view_basis * snapped
