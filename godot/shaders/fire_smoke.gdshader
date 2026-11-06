shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never;

uniform vec2 wind_direction = vec2(1.0, 0.0);
varying float source_phase;
varying float wind_strength;

void vertex() {
	source_phase = INSTANCE_CUSTOM.x;
	wind_strength = INSTANCE_CUSTOM.y;
	float height = VERTEX.y + 0.5;
	float scale = length(MODEL_MATRIX[0].xyz);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	float sway = sin(TIME * 0.9 + source_phase * 6.283 + height * 3.0);
	vec3 drift = vec3(wind_direction.x, 0.0, wind_direction.y) *
		height * height * (0.45 + wind_strength * 1.8);
	vec3 world_position = MODEL_MATRIX[3].xyz + scale * (
		right * (VERTEX.x * mix(0.55, 2.1, height) + sway * height * 0.18) +
		vec3(0.0, height * 3.8, 0.0) + drift);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_position, 1.0);
}

void fragment() {
	float height = 1.0 - UV.y;
	float across = UV.x * 2.0 - 1.0;
	float time = TIME * 1.2 + source_phase * 6.283;
	float eddies = sin(height * 24.0 - time * 3.0 + across * 5.0) *
		sin(across * 12.0 - height * 11.0 + time);
	float width = abs(across + eddies * height * 0.18);
	float silhouette = 1.0 - smoothstep(0.15, 0.93, width);
	float fade = smoothstep(0.0, 0.13, height) *
		(1.0 - smoothstep(0.54, 1.0, height));
	ALBEDO = mix(vec3(0.23, 0.20, 0.17), vec3(0.38, 0.39, 0.38), height);
	ALPHA = silhouette * fade * (0.35 + 0.13 * eddies);
}
