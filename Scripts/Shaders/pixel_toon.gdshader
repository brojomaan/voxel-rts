shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// Project-wide (Project Settings > Shader Globals), so every material shares one look.
global uniform int pixel_shading_bands;        // light levels, e.g. 3
global uniform bool pixel_shading_use_ramp;    // colour the bands from the ramp?
global uniform sampler2D pixel_shading_ramp;   // darkest band on the left, brightest on the right

// Cloud shadows (CloudService drives these). Dims the sun only.
global uniform sampler2D cloud_noise;
global uniform float cloud_strength;
global uniform float cloud_cover;
global uniform float cloud_softness;
global uniform float cloud_scale;
global uniform vec2 cloud_offset;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_nearest, hint_default_white;

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
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


float cloud_shade(vec3 pos) {
	if (cloud_strength <= 0.0) {
		return 1.0;
	}
	vec2 uv = fract((pos.xz + cloud_offset) / max(cloud_scale, 0.001));
	float c = textureLod(cloud_noise, uv, 0.0).r;
	return 1.0 - cloud_strength * smoothstep(cloud_cover, cloud_cover + cloud_softness, c);
}


void fragment() {
	vec3 base = albedo.rgb * texture(albedo_texture, UV).rgb;
	ALBEDO = base;

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