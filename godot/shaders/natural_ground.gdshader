shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Реальные фото-PBR карты хранятся в двух атласах из шести покрытий.
// Маски смешивания приходят с общей физической вершины WorldMap.
uniform sampler2D terrain_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D terrain_normal_roughness : filter_linear_mipmap_anisotropic, repeat_disable;
uniform float detail_strength : hint_range(0.0, 1.0) = 1.0;
uniform float texture_density : hint_range(0.05, 2.0) = 0.35;

varying vec3 ground_position;
varying vec3 ground_world_normal;
varying float ground_steepness;

void vertex() {
	ground_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ground_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
	ground_steepness = 1.0 - clamp(abs(NORMAL.y), 0.0, 1.0);
}

vec2 atlas_uv(vec2 world_uv, int material) {
	// Тайлы 384px: 368px изображения и по 8px периодического бордюра.
	vec2 tile = vec2(float(material % 3), float(material / 3));
	vec2 local_uv = vec2(8.0 / 384.0) +
		fract(world_uv * texture_density) * (368.0 / 384.0);
	return (tile + local_uv) / vec2(3.0, 2.0);
}

void add_layer(int material, float influence, vec3 position, vec3 normal,
		inout vec3 albedo_sum, inout vec3 packed_sum) {
	if (influence < 0.008) {
		return;
	}
	vec2 uv = atlas_uv(position.xz, material);
	vec3 albedo = texture(terrain_albedo, uv).rgb;
	vec3 packed = texture(terrain_normal_roughness, uv).rgb;

	// Скалистые крутые грани не растягивают рисунок по горизонтальной UV.
	float cliff = smoothstep(0.30, 0.61, ground_steepness);
	if (material == 3 && cliff > 0.005) {
		vec3 tri = pow(abs(normal), vec3(5.0));
		tri /= max(tri.x + tri.y + tri.z, 0.0001);
		vec2 uv_x = atlas_uv(position.zy, material);
		vec2 uv_z = atlas_uv(position.xy, material);
		vec3 tri_albedo = texture(terrain_albedo, uv_x).rgb * tri.x +
			albedo * tri.y +
			texture(terrain_albedo, uv_z).rgb * tri.z;
		vec3 tri_packed = texture(terrain_normal_roughness, uv_x).rgb * tri.x +
			packed * tri.y +
			texture(terrain_normal_roughness, uv_z).rgb * tri.z;
		albedo = mix(albedo, tri_albedo, cliff);
		packed = mix(packed, tri_packed, cliff);
	}
	albedo_sum += albedo * influence;
	packed_sum += packed * influence;
}

void fragment() {
	// COLOR.rgb остаётся природной подсказкой влажности/биома.
	// COLOR.a = снег; UV = песок, скала; UV2 = почва, щебень.
	float snow = clamp(COLOR.a, 0.0, 1.0);
	float sand = clamp(UV.x, 0.0, 1.0);
	float rock = clamp(UV.y, 0.0, 1.0);
	float soil = clamp(UV2.x, 0.0, 1.0);
	float gravel = clamp(UV2.y, 0.0, 1.0);
	float grass = max(0.0, 1.0 - snow - sand - rock - soil - gravel);
	float sum = max(grass + soil + sand + rock + gravel + snow, 0.0001);

	vec3 albedo_sum = vec3(0.0);
	vec3 packed_sum = vec3(0.0);
	add_layer(0, grass / sum, ground_position, ground_world_normal,
		albedo_sum, packed_sum);
	add_layer(1, soil / sum, ground_position, ground_world_normal,
		albedo_sum, packed_sum);
	add_layer(2, sand / sum, ground_position, ground_world_normal,
		albedo_sum, packed_sum);
	add_layer(3, rock / sum, ground_position, ground_world_normal,
		albedo_sum, packed_sum);
	add_layer(4, gravel / sum, ground_position, ground_world_normal,
		albedo_sum, packed_sum);
	add_layer(5, snow / sum, ground_position, ground_world_normal,
		albedo_sum, packed_sum);

	// Скалистая геологическая слоистость остаётся лишь слабой деталью.
	float strata = sin(ground_position.y * 9.0 + ground_position.x * 0.42);
	float cliff = smoothstep(0.25, 0.56, ground_steepness) * rock;
	vec3 tint = clamp(COLOR.rgb / vec3(0.55), vec3(0.74), vec3(1.19));
	ALBEDO = clamp(albedo_sum * mix(vec3(1.0), tint, 0.17) *
		(1.0 + strata * cliff * 0.016 * detail_strength),
		vec3(0.0), vec3(1.0));
	ROUGHNESS = clamp(packed_sum.b, 0.25, 1.0);
	METALLIC = 0.0;

	// Карта нормалей сообщает микрорельеф, но не деформирует сетку.
	vec3 bump = vec3(packed_sum.r * 2.0 - 1.0, 0.0,
		packed_sum.g * 2.0 - 1.0);
	NORMAL = normalize(NORMAL + mat3(VIEW_MATRIX) * bump *
		(0.30 * detail_strength * (1.0 - cliff * 0.4)));
}
