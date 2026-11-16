shader_type spatial;
// Both sides are drawn so a crumbling model shows a cut face, not a see-through shell.
render_mode diffuse_lambert, specular_disabled, cull_disabled;

// Voxel models (VoxelBody): colour per vertex, team colour, crumble clipping.
#define VOXEL
#include "res://Scripts/Shaders/pixel_toon.gdshaderinc"
