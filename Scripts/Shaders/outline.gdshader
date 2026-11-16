shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled, cull_disabled;

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
// The browser (Compatibility renderer) has no normal buffer, so it gets the outlines
// (from depth) but no crease highlights: working the facing out from depth was too noisy.
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
uniform sampler2D normal_texture : hint_normal_roughness_texture, filter_nearest, repeat_disable;
#define HAS_NORMAL_BUFFER
#endif

group_uniforms Outline;
uniform bool outline_enabled = true;
// World units: how much further away a neighbour must be to count as a silhouette.
uniform float depth_threshold : hint_range(0.01, 2.0) = 0.25;
uniform float outline_strength : hint_range(0.0, 1.0) = 0.5;

group_uniforms Highlight;
uniform bool highlight_enabled = true;
// How sharply the surface must turn to count as a crease.
uniform float normal_threshold : hint_range(0.0, 2.0) = 0.15;
uniform float highlight_strength : hint_range(0.0, 2.0) = 0.4;
// Picks which side of a crease gets the line (roughly "towards the light").
uniform vec3 normal_bias = vec3(1.0, 1.0, 1.0);
group_uniforms;


void vertex() {
	// Full-screen quad: ignore the camera and cover the screen at the near plane.
	// (Godot 4.3+ uses reversed depth, where 1.0 is the near plane.)
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}


// Where the pixel is, in view space.
vec3 view_position(vec2 uv, mat4 inv_projection) {
	float raw = texture(depth_texture, uv).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	float ndc_z = raw * 2.0 - 1.0;  // OpenGL depth runs -1..1
#else
	float ndc_z = raw;
#endif
	vec4 view = inv_projection * vec4(uv * 2.0 - 1.0, ndc_z, 1.0);
	return view.xyz / view.w;
}


float linear_depth(vec2 uv, mat4 inv_projection) {
	return -view_position(uv, inv_projection).z;
}


#ifdef HAS_NORMAL_BUFFER
vec3 view_normal(vec2 uv) {
	return texture(normal_texture, uv).xyz * 2.0 - 1.0;
}
#endif


void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = 1.0 / VIEWPORT_SIZE;  // one low-res pixel

	vec3 color = texture(screen_texture, uv).rgb;
	float depth = linear_depth(uv, INV_PROJECTION_MATRIX);
#ifdef HAS_NORMAL_BUFFER
	vec3 normal = view_normal(uv);
#endif

	vec2 offsets[4] = vec2[4](vec2(px.x, 0.0), vec2(-px.x, 0.0), vec2(0.0, px.y), vec2(0.0, -px.y));

	float depth_edge = 0.0;
	float normal_edge = 0.0;
	for (int i = 0; i < 4; i++) {
		vec2 neighbour_uv = uv + offsets[i];
		float depth_diff = linear_depth(neighbour_uv, INV_PROJECTION_MATRIX) - depth;  // + = neighbour further away

		// Silhouette: we're the near side of a depth jump.
		depth_edge = max(depth_edge, step(depth_threshold, depth_diff));

#ifdef HAS_NORMAL_BUFFER
		// Crease: normals disagree, we're not behind the neighbour,
		// and the bias says this side of the crease draws the line.
		vec3 neighbour_normal = view_normal(neighbour_uv);
		float this_side = step(0.0, dot(normal - neighbour_normal, normal_bias));
		float not_behind = step(-0.01, depth_diff);
		normal_edge += (1.0 - dot(normal, neighbour_normal)) * this_side * not_behind;
#endif
	}
	normal_edge = step(normal_threshold, normal_edge);

	float shade = 1.0;
	if (outline_enabled && depth_edge > 0.0) {
		shade = 1.0 - outline_strength;
	} else if (highlight_enabled && normal_edge > 0.0) {
		shade = 1.0 + highlight_strength;
	}
	ALBEDO = color * shade;
}