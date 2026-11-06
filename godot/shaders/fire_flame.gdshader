shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never;

uniform vec2 wind_direction = vec2(1.0, 0.0);
varying float phase;

void vertex() {
	phase = INSTANCE_CUSTOM.x * 6.283;
	float height = VERTEX.y + 0.5;
	float flicker = sin(TIME * 9.0 + phase) * 0.09;
	float scale = length(MODEL_MATRIX[0].xyz);
	vec3 lean = vec3(wind_direction.x, 0.0, wind_direction.y) *
		INSTANCE_CUSTOM.y * height * height * 0.45;
	vec3 position = MODEL_MATRIX[3].xyz + scale * (
		INV_VIEW_MATRIX[0].xyz * VERTEX.x * 0.95 +
		vec3(0.0, height * (1.40 + flicker), 0.0) + lean);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(position, 1.0);
}

void fragment() {
	float height = 1.0 - UV.y;
	float x = UV.x * 2.0 - 1.0;
	float t = TIME * 6.0 + phase;
	float sway = sin(t + height * 6.5) * height * 0.23;
	float tongue = sin(x * 11.0 + t - height * 9.0) * height * 0.18;
	float core = abs(x + sway);
	float edge = 0.85 - height * 0.76 + tongue;
	float coverage = 1.0 - smoothstep(edge - 0.12, edge + 0.05, core);
	float tip = 1.0 - smoothstep(0.69, 0.99, height + tongue * 0.45);
	vec3 hot = vec3(1.0, 0.83, 0.26);
	vec3 edge_color = vec3(1.0, 0.21, 0.025);
	ALBEDO = mix(hot, edge_color, clamp(core * 0.75 + height * 0.8, 0.0, 1.0));
	ALPHA = coverage * tip * smoothstep(0.0, 0.10, height) * 0.94;
}
