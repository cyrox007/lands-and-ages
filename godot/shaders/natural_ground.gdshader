shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Атласы CC0: по шесть PBR-покрытий. Веса берём из физической карты.
uniform sampler2D terrain_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D terrain_normal_roughness : filter_linear_mipmap_anisotropic, repeat_disable;
uniform float detail_strength : hint_range(0.0, 1.0) = 1.0;
uniform float macro_strength : hint_range(0.0, 1.0) = 1.0;
uniform float texture_density : hint_range(0.05, 2.0) = 0.35;
// Контраст формы действует даже издалека; выключение не меняет физические высоты.
uniform float relief_contrast : hint_range(0.0, 1.0) = 0.92;
// L3: направление существующего солнца, без дополнительных карт теней.
// Крупные формы берутся из физической нормали и признаков WorldMap.
uniform vec3 far_light_direction = vec3(0.0, 1.0, 0.0);
// L4: облачность из Climate; рисунок не является вторым источником погоды.
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_wind : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_time = 0.0;

varying vec3 ground_position;
varying vec3 ground_world_normal;
varying float ground_steepness;
varying vec4 ground_conditions;
varying vec4 ground_shape;


void vertex() {
	ground_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ground_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
	ground_steepness = 1.0 - clamp(abs(NORMAL.y), 0.0, 1.0);
	// CUSTOM0 из меша: вода в почве, морской берег, мороз и речной берег.
	ground_conditions = CUSTOM0;
	// CUSTOM1: выпуклость, вогнутость; остальные каналы зарезервированы.
	ground_shape = CUSTOM1;
}


vec2 atlas_uv(vec2 world_uv, int material) {
	// Берём только внутреннюю область с повторённым 8px бордюром.
	vec2 tile = vec2(float(material % 3), float(material / 3));
	vec2 local_uv = vec2(8.0 / 384.0) +
		fract(world_uv * texture_density) * (368.0 / 384.0);
	return (tile + local_uv) / vec2(3.0, 2.0);
}


float terrain_hash(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
}


float terrain_noise(vec2 position) {
	// Непрерывный шум в мировых координатах, независимый от чанка.
	vec2 cell = floor(position);
	vec2 blend = fract(position);
	blend = blend * blend * (3.0 - 2.0 * blend);
	float a = terrain_hash(cell);
	float b = terrain_hash(cell + vec2(1.0, 0.0));
	float c = terrain_hash(cell + vec2(0.0, 1.0));
	float d = terrain_hash(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, blend.x), mix(c, d, blend.x), blend.y);
}


vec2 domain_warp(vec2 position, vec2 signal, float strength) {
	// Сдвигаем координаты изображения плавно, а не случайно на границе тайла.
	return position + (signal - vec2(0.5)) * (3.6 * strength);
}


void add_layer(int material, float influence, vec3 position, vec3 normal,
		inout vec3 albedo_sum, inout vec3 bump_sum,
		inout float roughness_sum) {
	if (influence < 0.008) {
		return;
	}

	vec2 uv = atlas_uv(position.xz, material);
	vec3 albedo = texture(terrain_albedo, uv).rgb;
	// Вдали мелкая нормаль уже не участвует в освещении. Сохраняем
	// типичную шероховатость покрытия без чтения атласа по каждому слою.
	bool use_pbr_detail = detail_strength > 0.01;
	float base_roughness = material == 5 ? 0.76 : 0.88;
	vec3 packed = vec3(0.5, 0.5, base_roughness);
	if (use_pbr_detail) {
		packed = mix(packed, texture(terrain_normal_roughness, uv).rgb,
			smoothstep(0.01, 0.20, detail_strength));
	}

	// Нормаль XZ относится к мировым осям X/Z, не к неверной UV-тангенте.
	vec3 bump = vec3(packed.r * 2.0 - 1.0, 0.0,
		packed.g * 2.0 - 1.0);

	// На крутых скалах проецируем и цвет, и нормали на три плоскости.
	float cliff = smoothstep(0.30, 0.61, ground_steepness);
	if (material == 3 && cliff > 0.005) {
		vec3 tri = pow(abs(normal), vec3(5.0));
		tri /= max(tri.x + tri.y + tri.z, 0.0001);
		vec2 uv_x = atlas_uv(position.zy, material);
		vec2 uv_z = atlas_uv(position.xy, material);
		vec3 color_x = texture(terrain_albedo, uv_x).rgb;
		vec3 color_z = texture(terrain_albedo, uv_z).rgb;
		vec3 packed_x = packed;
		vec3 packed_z = packed;
		if (use_pbr_detail) {
			float pbr_detail = smoothstep(0.01, 0.20, detail_strength);
			packed_x = mix(vec3(0.5, 0.5, base_roughness),
				texture(terrain_normal_roughness, uv_x).rgb, pbr_detail);
			packed_z = mix(vec3(0.5, 0.5, base_roughness),
				texture(terrain_normal_roughness, uv_z).rgb, pbr_detail);
		}
		vec3 normal_x = vec3(0.0, packed_x.g * 2.0 - 1.0,
			packed_x.r * 2.0 - 1.0);
		vec3 normal_z = vec3(packed_z.r * 2.0 - 1.0,
			packed_z.g * 2.0 - 1.0, 0.0);
		vec3 triplanar_normal = normal_x * tri.x +
			bump * tri.y + normal_z * tri.z;
		vec3 triplanar_albedo = color_x * tri.x +
			albedo * tri.y + color_z * tri.z;
		float triplanar_roughness = packed_x.b * tri.x +
			packed.b * tri.y + packed_z.b * tri.z;
		albedo = mix(albedo, triplanar_albedo, cliff);
		bump = mix(bump, triplanar_normal, cliff);
		packed.b = mix(packed.b, triplanar_roughness, cliff);
	}

	albedo_sum += albedo * influence;
	bump_sum += bump * influence;
	roughness_sum += packed.b * influence;
}


void fragment() {
	// COLOR.a — снег, UV — песок/скала, UV2 — почва/щебень.
	// Все исходные веса получены из Surface, WorldMap и Hydrology.
	float snow = clamp(COLOR.a, 0.0, 1.0);
	float sand = clamp(UV.x, 0.0, 1.0);
	float rock = clamp(UV.y, 0.0, 1.0);
	float soil = clamp(UV2.x, 0.0, 1.0);
	float gravel = clamp(UV2.y, 0.0, 1.0);
	float grass = max(0.0, 1.0 - snow - sand - rock - soil - gravel);

	vec3 position = ground_position;
	float macro = 0.5;
	if (detail_strength > 0.01 && macro_strength > 0.01) {
		vec2 signal = vec2(
			terrain_noise(ground_position.xz * 0.057),
			terrain_noise(ground_position.xz * 0.071 + vec2(23.1, 11.7)));
		float amount = macro_strength * detail_strength;
		vec2 warped = domain_warp(position.xz, signal, amount);
		position.xz = warped;
		position.y += (signal.x - 0.5) * 0.6 * amount;
		macro = mix(signal.x, signal.y, 0.4);

		// Разбиваем прямые переходы только там, где физические покрытия
		// уже смешиваются. Чистый снег/камень остаётся своим материалом.
		float maximum = max(max(max(grass, soil), max(sand, rock)),
			max(gravel, snow));
		float mixing = smoothstep(0.015, 0.45, 1.0 - maximum);
		float variation = (macro - 0.5) * 1.5 * amount * mixing;
		grass *= 1.0 + variation;
		soil *= 1.0 - variation * 0.55;
		sand *= 1.0 - variation * 0.7;
		rock *= 1.0 + variation * 0.5;
		gravel *= 1.0 - variation * 0.4;
		snow *= 1.0 + variation * 0.2;
	}
	// Снежная кромка слегка размывается макрофактурой;
	// снег никогда не появляется на полностью бесснежном грунте.
	float snow_border = smoothstep(0.015, 0.35, snow) *
		(1.0 - smoothstep(0.65, 0.99, snow));
	snow = clamp(snow + (macro - 0.5) * snow_border *
		0.35 * detail_strength, 0.0, 1.0);
	float sum = max(grass + soil + sand + rock + gravel + snow, 0.0001);

	vec3 albedo_sum = vec3(0.0);
	vec3 bump_sum = vec3(0.0);
	float roughness_sum = 0.0;
	add_layer(0, grass / sum, position, ground_world_normal,
		albedo_sum, bump_sum, roughness_sum);
	add_layer(1, soil / sum, position, ground_world_normal,
		albedo_sum, bump_sum, roughness_sum);
	add_layer(2, sand / sum, position, ground_world_normal,
		albedo_sum, bump_sum, roughness_sum);
	add_layer(3, rock / sum, position, ground_world_normal,
		albedo_sum, bump_sum, roughness_sum);
	add_layer(4, gravel / sum, position, ground_world_normal,
		albedo_sum, bump_sum, roughness_sum);
	add_layer(5, snow / sum, position, ground_world_normal,
		albedo_sum, bump_sum, roughness_sum);

	// Небольшая геологическая слоистость на камнях, без смещения сетки.
	float strata = 0.0;
	if (detail_strength > 0.01) {
		strata = sin(ground_position.y * 9.0 + ground_position.x * 0.42);
	}
	float cliff = smoothstep(0.25, 0.56, ground_steepness) * rock;
	vec3 tint = clamp(COLOR.rgb / vec3(0.55), vec3(0.74), vec3(1.19));
	float macro_tint = 1.0 + (macro - 0.5) * 0.12 *
		macro_strength * detail_strength;
	// Мокрая земля темнее и чуть менее шероховатая: величина
	// зависит от реальной влажности, заболачивания и береговой воды.
	// Обычная почвенная влажность не должна выглядеть как затопление.
	// Только насыщенный грунт и реальное заболачивание темнеют заметно.
	float moisture = smoothstep(0.38, 0.94, ground_conditions.x);
	float coastal_wet = ground_conditions.y *
		(0.38 + 0.55 * sand) + ground_conditions.w * 0.38;
	float thawed = 1.0 - smoothstep(0.22, 0.82, ground_conditions.z);
	float wet = clamp(max(moisture, coastal_wet) *
		thawed * (1.0 - snow * 0.94), 0.0, 1.0);
	float absorbency = clamp(soil + sand + grass * 0.65 +
		gravel * 0.40, 0.0, 1.0);
	float wet_material = wet * (0.35 + 0.65 * absorbency);
	vec3 base_albedo = albedo_sum * mix(vec3(1.0), tint, 0.17) *
		(1.0 + strata * cliff * 0.055 * detail_strength) * macro_tint;
	// Подсветка реального гребня и затемнение настоящей впадины
	// основаны только на высотах WorldMap: никакой новой поверхности.
	float ridge = smoothstep(0.05, 0.90, ground_shape.r);
	float ravine = smoothstep(0.05, 0.90, ground_shape.g);
	float escarpment = smoothstep(0.15, 0.57, ground_steepness);
	float relief_light = clamp(1.0 + relief_contrast * (
		0.21 * ridge - 0.35 * ravine - 0.10 * escarpment), 0.65, 1.14);
	// L3: дешёвая панорамная светотень использует настоящую
	// геометрическую нормаль и направление DirectionalLight3D.
	// При приближении вклад плавно исчезает, не дублируя ближние тени.
	float far_blend = clamp(1.0 - detail_strength, 0.0, 1.0);
	float sun_facing = dot(normalize(ground_world_normal),
		normalize(far_light_direction));
	float slope_light = smoothstep(0.02, 0.78, sun_facing);
	// Дополнительное чтение физического гребня и врезанного оврага
	// не создаёт собственных высот, ландшафта и новых источников света.
	float far_relief = mix(0.63, 1.12, slope_light) +
		0.035 * ridge - 0.075 * ravine - 0.060 * escarpment;
	float far_light = mix(1.0, clamp(far_relief, 0.56, 1.16),
		far_blend * relief_contrast);
	// На реальном облачном фронте слегка движутся крупные пятна света.
	// Мировые координаты непрерывны на границах чанков, а покрытие
	// задаёт только физическая погода; без облаков маска равна нулю.
	float cloud_dimming = 0.0;
	if (cloud_coverage > 0.015) {
		vec2 drift = vec2(0.018, -0.006) * cloud_time *
			(0.28 + cloud_wind * 0.72);
		float cloud_field = terrain_noise(ground_position.xz * 0.012 + drift);
		cloud_dimming = cloud_coverage *
			smoothstep(0.38, 0.70, cloud_field) * 0.28;
	}
	ALBEDO = clamp(base_albedo * relief_light * far_light *
		(1.0 - cloud_dimming) * mix(1.0, 0.67, wet_material),
		vec3(0.0), vec3(1.0));
	ROUGHNESS = clamp(mix(roughness_sum, 0.34, wet_material * 0.72),
		0.25, 1.0);
	METALLIC = 0.0;

	// Переносим касательную микрофактуру из мировых осей в видовую систему.
	// Склон и физические нормали вершин остаются источником основной формы.
	if (detail_strength > 0.01) {
		NORMAL = normalize(NORMAL + mat3(VIEW_MATRIX) * bump_sum *
			(0.30 * detail_strength * (1.0 - cliff * 0.4)));
	}
}
