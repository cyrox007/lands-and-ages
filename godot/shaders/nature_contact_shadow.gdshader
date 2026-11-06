shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never, fog_disabled;

void fragment() {
	vec2 offset = UV * 2.0 - 1.0;
	float coverage = 1.0 - smoothstep(0.14, 1.0, dot(offset, offset));
	ALBEDO = vec3(0.014, 0.018, 0.020);
	ALPHA = coverage * COLOR.a;
}
