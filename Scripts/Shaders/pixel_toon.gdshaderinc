// The pixel toon look: banded lighting, shared by every variant so they can't drift
// apart. A variant sets shader_type and render_mode, optionally one of the defines
// below, then includes this file.
//
//   pixel_toon.gdshader    (no define)            ordinary models
//   voxel_toon.gdshader    #define VOXEL          voxel models: colour per vertex,
//                                                 team colour, crumbling
//   voxel_debris.gdshader  #define VOXEL_DEBRIS   flying voxel pieces

// Project-wide (Project Settings > Shader Globals), so every material shares one look.
global uniform int pixel_shading_bands;        // light levels, e.g. 3
global uniform bool pixel_shading_use_ramp;    // colour the bands from the ramp?
global uniform sampler2D pixel_shading_ramp;   // darkest band on the left, brightest on the right
global uniform bool pixel_shading_smooth;      // ordinary smooth lighting instead of bands (for comparing)

// Cloud shadows (CloudService drives these). Dims the sun only.
global uniform sampler2D cloud_noise;
global uniform float cloud_strength;
global uniform float cloud_cover;
global uniform float cloud_softness;
global uniform float cloud_scale;
global uniform vec2 cloud_offset;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_nearest, hint_default_white;

#ifdef VOXEL
// Vertex colours with alpha 0 are team colour: their grey is a brightness for this.
uniform vec4 team_color : source_color = vec4(1.0, 0.0, 1.0, 1.0);
// Crumbling: everything above this height (in voxels, model space) isn't drawn.
// Per instance, so bodies sharing a material crumble on their own.
instance uniform float clip_height = 100000.0;
// Selection outline: 0 = none, 1 = hovered, 2 = selected. The outline pass can't see
// which object a pixel belongs to, so this is passed to it through ROUGHNESS (which
// this look doesn't otherwise use). The values must match outline.gdshader.
instance uniform float outline_mark = 0.0;
varying float model_y;
varying vec3 cap_normal;
#endif

#ifdef VOXEL_DEBRIS
// VoxelDebris sets these. A piece's start, velocity and timing ride in its instance
// transform (see voxel_debris.gd), and its whole flight is worked out here, so pieces
// cost the CPU nothing after they're thrown.
uniform float now = 0.0;
uniform float gravity = 12.0;
uniform float bounce = 0.3;
uniform float ground_friction = 0.6;
uniform float shrink_time = 0.5;
uniform float half_size = 0.03125;
#endif

group_uniforms Emission;
// Glows regardless of lighting (fairy lights, windows, the star). Black = off.
uniform vec4 emission : source_color = vec4(0.0, 0.0, 0.0, 1.0);
// Above 1.0 starts to bloom with the environment's glow.
uniform float emission_energy : hint_range(0.0, 16.0, 0.01) = 1.0;
// Paint where it glows (white = full). Leave empty to glow everywhere the colour is set.
uniform sampler2D emission_texture : source_color, filter_nearest, hint_default_white;
// Multiply the glow by the albedo colour/texture, so one mask can light several colours.
uniform bool emission_uses_albedo = false;
group_uniforms;

varying vec3 world_pos;


void vertex() {
#ifdef VOXEL_DEBRIS
	// The instance "transform" is data, not a transform (the variant skips Godot's own
	// vertex transform): column 0 = velocity, column 1 = (thrown at, life), origin = start.
	vec3 p = MODEL_MATRIX[3].xyz;
	vec3 v = MODEL_MATRIX[0].xyz;
	float age = now - MODEL_MATRIX[1].x;
	float life = MODEL_MATRIX[1].y;

	// Fly, land, bounce: a few arcs in closed form, then it lies where it stopped.
	float t = max(age, 0.0);
	bool flying = true;
	for (int i = 0; i < 4 && flying; i++) {
		float height = max(p.y - half_size, 0.0);
		float t_land = (v.y + sqrt(v.y * v.y + 2.0 * gravity * height)) / gravity;
		if (t < t_land) {
			p += v * t;
			p.y -= 0.5 * gravity * t * t;
			flying = false;
		} else {
			p.xz += v.xz * t_land;
			p.y = half_size;
			v = vec3(v.x * ground_friction, (gravity * t_land - v.y) * bounce, v.z * ground_friction);
			t -= t_land;
		}
	}

	// Full size for its life, then it shrinks away. Unused slots have no life: size 0.
	float size = clamp(1.0 - (age - life) / shrink_time, 0.0, 1.0);
	if (age < 0.0) {
		size = 0.0;
	}
	world_pos = p + VERTEX * size;
	VERTEX = (VIEW_MATRIX * vec4(world_pos, 1.0)).xyz;
	NORMAL = normalize(mat3(VIEW_MATRIX) * NORMAL);
#else
#ifdef VOXEL
	model_y = VERTEX.y;
	cap_normal = normalize(MODELVIEW_NORMAL_MATRIX * vec3(0.0, 1.0, 0.0));
#endif
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
#endif
}


float cloud_shade(vec3 pos) {
	if (cloud_strength <= 0.0) {
		return 1.0;
	}
	vec2 uv = fract((pos.xz + cloud_offset) / max(cloud_scale, 0.001));
	float c = textureLod(cloud_noise, uv, 0.0).r;
	return 1.0 - cloud_strength * smoothstep(cloud_cover, cloud_cover + cloud_softness, c);
}


vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}


void fragment() {
	vec3 base = albedo.rgb * texture(albedo_texture, UV).rgb;

#ifdef VOXEL
	if (model_y > clip_height + 0.001) {
		discard;
	}
	// The model is a skin with nothing inside. Where crumbling has opened it, the
	// inside of the far wall shows; lit as if it faced up, it reads as a solid cut.
	if (!FRONT_FACING) {
		NORMAL = cap_normal;
	}
#endif

#if defined(VOXEL) || defined(VOXEL_DEBRIS)
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	// Compatibility already turns vertex colours linear; converting again darkens them.
	vec3 vertex_colour = COLOR.rgb;
#else
	vec3 vertex_colour = srgb_to_linear(COLOR.rgb);
#endif
#ifdef VOXEL
	if (COLOR.a < 0.5) {
		vertex_colour *= team_color.rgb;
	}
#endif
	base *= vertex_colour;
#endif

	ALBEDO = base;
	ROUGHNESS = 1.0;
#ifdef VOXEL
	if (outline_mark > 1.5) {
		ROUGHNESS = 0.65;
	} else if (outline_mark > 0.5) {
		ROUGHNESS = 0.35;
	}
#endif

	vec3 glow = emission.rgb * texture(emission_texture, UV).rgb;
	if (emission_uses_albedo) {
		glow *= base;
	}
	EMISSION = glow * emission_energy;
}


void light() {
	// How lit this point is by this light, shadows included.
	float lit = clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION;
	if (LIGHT_IS_DIRECTIONAL) {
		lit *= cloud_shade(world_pos);
	}

	if (pixel_shading_smooth) {
		DIFFUSE_LIGHT += lit * LIGHT_COLOR / PI;
	} else {
	// Hard steps. ceil keeps anything lit at all off the darkest band.
	float bands = float(max(pixel_shading_bands, 1));
	float stepped = ceil(lit * bands) / bands;

	vec3 tint = vec3(stepped);
	if (pixel_shading_use_ramp) {
		// The ramp is read at the band values only (0, 1/3, 2/3, 1 for three bands),
		// so even a smooth gradient gives one flat colour per band.
		tint = texture(pixel_shading_ramp, vec2(stepped, 0.5)).rgb;
	}

	// LIGHT_COLOR includes a factor of PI in Godot 4, so divide it back out.
	DIFFUSE_LIGHT += tint * LIGHT_COLOR / PI;
	}
}
