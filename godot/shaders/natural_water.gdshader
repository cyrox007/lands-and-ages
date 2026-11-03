shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// Лёгкая рябь не сдвигает вершины: уровень воды остаётся физическим.
varying vec2 water_position;

void vertex() {
	water_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	float ripple = sin(water_position.x * 2.6 + TIME * 0.68)
		* sin(water_position.y * 3.1 - TIME * 0.51);
	float shimmer = ripple * 0.045;
	ALBEDO = clamp(COLOR.rgb + vec3(shimmer * 0.38, shimmer * 0.67, shimmer),
		vec3(0.0), vec3(1.0));
	ROUGHNESS = 0.25;
	METALLIC = 0.0;
	ALPHA = COLOR.a;
}