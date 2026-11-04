shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// UV.x — реальная глубина воды у берега, UV.y — доля льда из Surface.
// Световые волны не смещают геометрию, физический уровень неизменен.
uniform float ripple_strength : hint_range(0.0, 1.0) = 1.0;
varying vec2 water_position;


void vertex() {
	water_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}


void fragment() {
	float ice = clamp(UV.y, 0.0, 1.0);
	float liquid = 1.0 - ice;
	float nearshore = 1.0 - smoothstep(0.01, 0.42, UV.x);
	float ripple = 0.0;

	// Сумма разнонаправленных волн вместо произведения двух синусов:
	// произведение давало отчётливую шахматную сетку на поверхности.
	if (ripple_strength > 0.01 && liquid > 0.01) {
		float phase_a = dot(water_position, vec2(1.42, 0.58)) +
			TIME * 0.83 + sin(water_position.y * 0.20) * 0.30;
		float phase_b = dot(water_position, vec2(-0.78, 1.72)) -
			TIME * 0.71 + sin(water_position.x * 0.24) * 0.22;
		float phase_c = dot(water_position, vec2(2.71, -1.31)) +
			TIME * 1.12;
		// На дальнем масштабе фазы мельче пикселя: фильтруем их
		// производными экрана вместо муара и неподвижной «ткани».
		float screen_frequency = max(
			max(fwidth(phase_a), fwidth(phase_b)), fwidth(phase_c));
		float wave_fade = 1.0 - smoothstep(0.55, 1.75,
			screen_frequency);
		ripple = (sin(phase_a) * 0.55 +
			sin(phase_b) * 0.28 + sin(phase_c) * 0.10) * wave_fade;
		vec2 slopes = vec2(1.42, 0.58) * cos(phase_a) * 0.55 +
			vec2(-0.78, 1.72) * cos(phase_b) * 0.28 +
			vec2(2.71, -1.31) * cos(phase_c) * 0.10;
		float amplitude = 0.025 * ripple_strength * liquid * wave_fade;
		vec3 water_normal = normalize(vec3(
			-slopes.x * amplitude, 1.0, -slopes.y * amplitude));
		NORMAL = normalize(mat3(VIEW_MATRIX) * water_normal);
	}

	// Пена появляется тонкой полосой внутри береговой воды.
	// На самой линии обрезки она затухает: так не подсвечиваются
	// целиком треугольники, пересекающие крутой склон.
	float foam_band = smoothstep(0.005, 0.07, UV.x) *
		(1.0 - smoothstep(0.13, 0.33, UV.x));
	float broken = 0.68;
	if (ripple_strength > 0.01 && liquid > 0.01) {
		broken = 0.59 + 0.13 * sin(water_position.x * 3.8 +
			water_position.y * 2.1 + TIME * 0.45);
	}
	float foam = foam_band * broken * liquid;
	vec3 base = COLOR.rgb;
	vec3 shallow = mix(base, vec3(0.27, 0.42, 0.42), nearshore * 0.22);
	vec3 liquid_color = mix(shallow, vec3(0.48, 0.60, 0.57),
		foam * 0.20);
	liquid_color += vec3(0.008, 0.012, 0.013) * ripple *
		ripple_strength * liquid;
	vec3 ice_color = vec3(0.78, 0.87, 0.90);
	ALBEDO = clamp(mix(liquid_color, ice_color, ice),
		vec3(0.0), vec3(1.0));
	ROUGHNESS = mix(mix(0.18, 0.32, nearshore), 0.84, ice);
	METALLIC = 0.0;
	ALPHA = mix(COLOR.a * (1.0 - nearshore * 0.12), 0.96, ice);
}
