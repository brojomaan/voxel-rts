class_name Shell
extends Node3D
## A tank shell in flight: flies in a straight line and blows a crater in the first
## voxel body it meets (not the one that fired it), or kicks up dirt where it lands.
## Visual only for now: it doesn't take hit points off anything yet.

## Set these before adding it to the tree.
var velocity: Vector3 = Vector3.FORWARD
## Crater size, in world units.
var crater_radius: float = 0.25
## The body that fired it, which it flies straight through.
var shooter: VoxelBody
## How far it flies before giving up, in world units.
var max_distance: float = 40.0

var _flown: float = 0.0


func _ready() -> void:
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = Vector3(0.09, 0.09, 0.22)
	var visual: MeshInstance3D = MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = load("res://Materials/shell.tres") as Material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(visual)
	if velocity.length() > 0.001:
		look_at(global_position + velocity)


func _process(delta: float) -> void:
	var step: float = velocity.length() * delta
	if step <= 0.0:
		queue_free()
		return
	var dir: Vector3 = velocity / (step / delta)

	# Anything in the stretch it covers this frame?
	var nearest: Dictionary = {}
	var nearest_body: VoxelBody = null
	for node: Node in get_tree().get_nodes_in_group(&"voxel_bodies"):
		var body: VoxelBody = node as VoxelBody
		if body == shooter:
			continue
		var hit: Dictionary = body.raycast(global_position, dir)
		if hit.is_empty() or float(hit.distance) > step:
			continue
		if nearest.is_empty() or float(hit.distance) < float(nearest.distance):
			nearest = hit
			nearest_body = body
	if nearest_body:
		nearest_body.carve(nearest.point, crater_radius / nearest_body.voxel_size, dir)
		queue_free()
		return

	global_position += dir * step
	_flown += step
	if global_position.y <= 0.0:
		_kick_up_dirt(dir)
		queue_free()
	elif _flown >= max_distance:
		queue_free()


func _kick_up_dirt(dir: Vector3) -> void:
	var debris: VoxelDebris = get_tree().get_first_node_in_group(&"voxel_debris") as VoxelDebris
	if debris == null:
		return
	var at: Vector3 = Vector3(global_position.x, 0.05, global_position.z)
	for i: int in 14:
		var fling: Vector3 = Vector3(randf_range(-1.0, 1.0), randf_range(1.5, 3.5), randf_range(-1.0, 1.0)) + dir * 0.8
		var dirt: Color = Color(0.45, 0.36, 0.22).lerp(Color(0.3, 0.42, 0.2), randf())
		debris.spawn(at, fling, dirt, randf_range(0.4, 0.9))
