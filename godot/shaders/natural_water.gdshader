shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// Физические данные: UV.x — глубина береговой кромки,
// UV.y — промерзание настоящей воды из Surface.
// Рябь и пена только отображаются и не смещают физические вершины.
uniform float ripple_strength : hint_range(0.0, 1.0) = 1.0;
varying vec2 water_position;


void vertex() {
	water_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}


void fragment() {
	float ice = clamp(UV.y, 0.0, 1.0);
	float liquid = 1.0 - ice;
	float nearshore = 1.0 - smoothstep(0.035, 0.72, UV.x);
	float ripple = 0.0;
	vec2 slopes = vec2(0.0);

	// Два пересекающихся направления волн в мировых координатах.
	// Дальняя детализация и промёрзшая вода отключают движение.
	if (ripple_strength > 0.01 && liquid > 0.01) {
		float phase_a = water_position.x * 2.35 +
			water_position.y * 0.53 + TIME * 0.70;
		float phase_b = water_position.y * 3.05 -
			water_position.x * 0.46 - TIME * 0.48;
		float wave_a = sin(phase_a);
		float wave_b = sin(phase_b);
		ripple = wave_a * wave_b;
		slopes = vec2(cos(phase_a) * wave_b * 2.35 -
			wave_a * cos(phase_b) * 0.46,
			cos(phase_a) * wave_b * 0.53 +
			wave_a * cos(phase_b) * 3.05);
		float amplitude = 0.075 * ripple_strength * liquid;
		vec3 water_normal = normalize(vec3(
			-slopes.x * amplitude, 1.0, -slopes.y * amplitude));
		NORMAL = normalize(mat3(VIEW_MATRIX) * water_normal);
	}

	// Неглубокий берег визуально светлеет. Ширина пены зависит
	// от реального пересечения воды с грунтом, а не от маски пляжей.
	float broken = 0.80;
	if (ripple_strength > 0.01 && liquid > 0.01) {
		broken = 0.72 + 0.20 * sin(water_position.x * 4.8 +
			water_position.y * 3.3 + TIME * 0.75);
	}
	float foam = nearshore * broken * liquid;
	vec3 base = COLOR.rgb;
	vec3 shallow = mix(base, vec3(0.30, 0.47, 0.46), nearshore * 0.40);
	vec3 liquid_color = mix(shallow, vec3(0.73, 0.80, 0.76),
		foam * 0.42);
	liquid_color += vec3(0.016, 0.024, 0.026) * ripple *
		ripple_strength * liquid;
	// У промёрзшей воды рябь исчезает, шероховатость увеличивается.
	vec3 ice_color = vec3(0.78, 0.87, 0.90);
	ALBEDO = clamp(mix(liquid_color, ice_color, ice),
		vec3(0.0), vec3(1.0));
	ROUGHNESS = mix(mix(0.18, 0.32, nearshore), 0.84, ice);
	METALLIC = 0.0;
	ALPHA = mix(COLOR.a * (1.0 - nearshore * 0.12), 0.96, ice);
}
