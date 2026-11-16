class_name PixelSnapCamera
extends Camera3D
## Snaps the camera to the low-res pixel grid so static pixels never crawl,
## then hands the leftover fraction of a pixel to the display, which slides
## the upscaled image by that much so movement still looks smooth.

@export var smooth_subpixel: bool = true

var _rest_offset: Vector3 = Vector3.ZERO

func _ready() -> void:
	# Where we sit relative to the rig; the rig moves smoothly, we follow snapped.
	_rest_offset = position
	# Lower runs first, so a high number means "after the rig has moved this frame".
	process_priority = 100

func _process(delta: float) -> void:
	var rig: Node3D = get_parent() as Node3D
	if not rig:
		return
	
	# World units per low-res pixel. Orthographic size is the full view height.
	var texel: float = size / float(get_viewport().get_visible_rect().size.y)
	var true_position: Vector3 = rig.global_transform * _rest_offset
	
	# Snap in the camera's own axes: x is screen right, y is screen up, z is depth.
	var view_basis: Basis = global_transform.basis
	var local: Vector3 = view_basis.inverse() * true_position
	var snapped: Vector3 = Vector3(snappedf(local.x, texel), snapped(local.y, texel), local.z)
	global_position = view_basis * snapped
	
	# What we snapped away, in low res pixels. Screen y points down, hence the flip.
	var remainder: Vector2 = Vector2(local.x - snapped.x, local.y- snapped.y) / texel
	var offset: Vector2 = Vector2(-remainder.x, remainder.y) if smooth_subpixel else Vector2.ZERO
	ViewService.set_subpixel_offset(offset)
