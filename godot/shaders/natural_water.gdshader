shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// UV.x — реальная глубина у берега, UV.y — доля льда из Surface.
// UV2 — речной сток (длина <= 1), озеро (0, 2) либо море (2, 0).
// Волны и бегущие блики не смещают геометрию и не меняют уровень воды.
uniform float ripple_strength : hint_range(0.0, 1.0) = 1.0;
// Значения берутся из климатического снимка камеры, не создают погоду.
uniform float wind_strength : hint_range(0.0, 1.0) = 0.0;
uniform float storm_strength : hint_range(0.0, 1.0) = 0.0;
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
	float wind_highlight = 0.0;
	float ocean = step(1.5, UV2.x);
	float lake = step(1.5, UV2.y);
	float standing = clamp(ocean + lake, 0.0, 1.0);
	float river_strength = clamp(length(UV2), 0.0, 1.0) *
		(1.0 - standing) * liquid;

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
		// Климат пока даёт скорость и преобладающий западный ветер.
		// Океан получает длинные волны, озеро — более короткую рябь.
		// Геометрия и физический уровень воды остаются неизменными.
		// На физически мелком берегу разгон волн меньше, чем на глубине.
		// Полную ветровую тень за островами добавим после модели 11.3.
		float shoreline_shelter = mix(0.42, 1.0,
			clamp(UV.x, 0.0, 1.0));
		float wind_energy = clamp(wind_strength * 0.8 +
			storm_strength * 0.45, 0.0, 1.0) * standing * shoreline_shelter;
		if (wind_energy > 0.01) {
			float along = mix(1.10, 0.46, ocean);
			float wind_phase = dot(water_position, vec2(along, 0.12)) -
				TIME * (0.38 + wind_strength * 0.9 + storm_strength * 0.5);
			float side_phase = dot(water_position, vec2(-0.22, 0.73)) +
				TIME * (0.14 + wind_strength * 0.3);
			float wind_fade = 1.0 - smoothstep(0.55, 1.75,
				max(fwidth(wind_phase), fwidth(side_phase)));
			float large_wave = sin(wind_phase) * 0.78 +
				sin(side_phase) * 0.22;
			ripple += large_wave * wind_energy * wind_fade *
				mix(0.45, 0.85, ocean);
			slopes += (vec2(along, 0.12) * cos(wind_phase) * 0.78 +
				vec2(-0.22, 0.73) * cos(side_phase) * 0.22) *
				wind_energy * wind_fade * mix(0.5, 1.0, ocean);
			wind_highlight = smoothstep(0.52, 0.96, large_wave) *
				wind_energy * wind_fade;
		}
		float amplitude = 0.025 * ripple_strength * liquid * wave_fade;
		vec3 water_normal = normalize(vec3(
			-slopes.x * amplitude, 1.0, -slopes.y * amplitude));
		NORMAL = normalize(mat3(VIEW_MATRIX) * water_normal);
	}

	// W4: пена существует только на реальной прибрежной глубине,
	// не появляется посреди озера и гаснет точно на обрезке берега.
	// fwidth сглаживает тонкую полосу при удалении камеры, без муара.
	float shoreline_aa = max(fwidth(UV.x) * 1.4, 0.012);
	float foam_band = smoothstep(0.004, 0.055 + shoreline_aa, UV.x) *
		(1.0 - smoothstep(0.13, 0.30 + shoreline_aa, UV.x)) * standing;
	float shoreline_foam = 0.0;
	float shoreline_glint = 0.0;
	float shoreline_wash = 0.0;
	if (foam_band > 0.001 && liquid > 0.01) {
		// Мировая координата непрерывна между соседними чанками:
		// полосы прибоя не должны обрываться на квадратных границах.
		float shore_phase = dot(water_position, vec2(0.76, 0.29)) -
			TIME * (0.35 + wind_strength * 0.56 + storm_strength * 0.27);
		float shore_warp = sin(dot(water_position, vec2(-0.21, 0.43)) +
			TIME * 0.20) * 0.32;
		float crest_phase = shore_phase + shore_warp;
		float crest = sin(crest_phase);
		float crest_fade = 1.0 - smoothstep(0.6, 2.0,
			fwidth(crest_phase));
		float surge = clamp(0.14 + wind_strength * 0.55 +
			storm_strength * 0.50, 0.0, 1.0);
		float foam_crest = smoothstep(0.08, 0.70, crest) *
			crest_fade * surge;
		shoreline_foam = foam_band * (0.24 + foam_crest * 0.74) * liquid;
		// Отражающая полоса следует за тем же фронтом, но уже пены.
		shoreline_glint = foam_band * smoothstep(0.52, 0.90, crest) *
			crest_fade * surge * liquid;
		shoreline_wash = foam_band * crest * crest_fade *
			surge * liquid;
	}
	vec3 base = COLOR.rgb;
	vec3 shallow = mix(base, vec3(0.27, 0.42, 0.42), nearshore * 0.22);
	vec3 liquid_color = mix(shallow, vec3(0.48, 0.60, 0.57),
		shoreline_foam * 0.26);
	liquid_color += vec3(0.008, 0.012, 0.013) * ripple *
		ripple_strength * liquid;
	// Направленные блики рек и ветровые блики водоёмов независимы.
	// При нулевом ветре/грозе добавочная ветровая волна отсутствует.
	liquid_color += vec3(0.032, 0.043, 0.040) *
		river_highlight * ripple_strength;
	liquid_color += vec3(0.036, 0.050, 0.052) *
		wind_highlight * ripple_strength * liquid;
	// Белёсая кромка и блики движутся согласованно со штормовым фронтом.
	liquid_color += vec3(0.045, 0.061, 0.060) * shoreline_glint +
		vec3(0.012, 0.019, 0.021) * shoreline_wash;
	vec3 ice_color = vec3(0.78, 0.87, 0.90);
	ALBEDO = clamp(mix(liquid_color, ice_color, ice),
		vec3(0.0), vec3(1.0));
	ROUGHNESS = mix(clamp(mix(0.18, 0.32, nearshore) +
		shoreline_foam * 0.15, 0.0, 1.0), 0.84, ice);
	METALLIC = 0.0;
	ALPHA = mix(COLOR.a * (1.0 - nearshore * 0.12), 0.96, ice);
}
