shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// UV.x — реальная глубина у берега, UV.y — доля льда из Surface.
// UV2 — направление/относительная сила реального речного стока из Hydrology.
// Волны и бегущие блики не смещают геометрию и не меняют уровень воды.
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
	float river_highlight = 0.0;
	float river_strength = clamp(length(UV2), 0.0, 1.0) * liquid;

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
		if (river_strength > 0.01) {
			// Гребни бегут по заданному направлению реального стока.
			// Фаза непрерывна в мировых координатах и между чанками.
			vec2 flow_direction = normalize(UV2);
			vec2 across_flow = vec2(-flow_direction.y, flow_direction.x);
			float bend = sin(dot(water_position, across_flow) * 7.0) * 0.35;
			float river_phase = dot(water_position, flow_direction) * 6.5 -
				TIME * (1.8 + river_strength * 2.0) + bend;
			float river_fade = 1.0 - smoothstep(0.65, 1.8,
				fwidth(river_phase));
			float stripe = sin(river_phase) * 0.72 +
				sin(river_phase * 1.7 + bend) * 0.28;
			river_highlight = smoothstep(0.34, 0.82, stripe) *
				river_strength * river_fade;
			slopes += flow_direction * cos(river_phase) *
				0.38 * river_strength * river_fade;
		}
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
	// Живые блики относятся только к руслам, реально отмеченным Hydrology.
	// Моря и озёра получают независимую ветровую систему в W3.
	liquid_color += vec3(0.032, 0.043, 0.040) *
		river_highlight * ripple_strength;
	vec3 ice_color = vec3(0.78, 0.87, 0.90);
	ALBEDO = clamp(mix(liquid_color, ice_color, ice),
		vec3(0.0), vec3(1.0));
	ROUGHNESS = mix(mix(0.18, 0.32, nearshore), 0.84, ice);
	METALLIC = 0.0;
	ALPHA = mix(COLOR.a * (1.0 - nearshore * 0.12), 0.96, ice);
}
