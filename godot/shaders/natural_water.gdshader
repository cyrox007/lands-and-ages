shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// Береговая глубина хранится в UV.x, а геометрия не меняется.
// На далёком масштабе не вычисляем мелкую анимацию ряби.
uniform float ripple_strength : hint_range(0.0, 1.0) = 1.0;
varying vec2 water_position;

void vertex() {
	water_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	float ripple = 0.0;
	if (ripple_strength > 0.01) {
		ripple = sin(water_position.x * 2.6 + TIME * 0.68)
			* sin(water_position.y * 3.1 - TIME * 0.51);
	}
	float edge = 1.0 - smoothstep(0.02, 0.68, UV.x);
	float shimmer = ripple * 0.045 * ripple_strength;
	vec3 shore = vec3(0.28, 0.32, 0.30) * edge *
		(0.48 + 0.20 * abs(ripple) * ripple_strength);
	ALBEDO = clamp(COLOR.rgb + vec3(shimmer * 0.38, shimmer * 0.67, shimmer)
		+ shore, vec3(0.0), vec3(1.0));
	ROUGHNESS = mix(0.25, 0.38, edge);
	METALLIC = 0.0;
	ALPHA = COLOR.a * (1.0 - edge * 0.15);
}
