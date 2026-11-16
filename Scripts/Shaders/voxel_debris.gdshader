shader_type spatial;
// The vertex shader places each piece itself (see the include), so Godot's own
// transform is skipped.
render_mode diffuse_lambert, specular_disabled, skip_vertex_transform;

// Flying voxel pieces (VoxelDebris).
#define VOXEL_DEBRIS
#include "res://Scripts/Shaders/pixel_toon.gdshaderinc"
