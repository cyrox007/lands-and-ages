shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// Модель ветра относится к отрисовке; реальный рост деревьев не зависит от FPS.
uniform sampler2D source_texture : source_color, filter_linear_mipmap;
uniform vec4 source_tint : source_color = vec4(1.0);
uniform bool has_texture = false;
uniform float source_height = 100.0;
uniform float source_base = 0.0;
uniform float source_roughness = 0.85;
uniform bool foliage_surface = false;
uniform vec2 wind_direction = vec2(1.0, 0.0);

varying float foliage_season;
varying float foliage_health;

void vertex() {
    // Только GPU-отображение: сезон и здоровье поступают из физического реестра.
    foliage_season = clamp(INSTANCE_CUSTOM.b, 0.0, 1.0);
    foliage_health = clamp(INSTANCE_CUSTOM.a, 0.0, 1.0);
    float height = clamp((VERTEX.y - source_base) /
        max(source_height, 0.001), 0.0, 1.0);
    float gust = clamp(INSTANCE_CUSTOM.g, 0.0, 1.0);
    float amplitude = source_height * 0.095 * gust * height * height;
    float phase = INSTANCE_CUSTOM.r * 6.283185;
    float wave = sin(TIME * (1.2 + 1.3 * gust) + phase)
        + sin(TIME * 3.8 + phase * 1.4) * 0.25;
    // Вершины отклоняются вдоль фронта; текстуры не изменяются.
    vec2 direction = normalize(wind_direction);
    VERTEX.x += direction.x * wave * amplitude;
    VERTEX.z += direction.y * wave * amplitude;
}

void fragment() {
    vec4 albedo = has_texture ? texture(source_texture, UV) : vec4(1.0);
    ALBEDO = albedo.rgb * source_tint.rgb * COLOR.rgb;
    if (foliage_surface) {
        // Меняется только листва: кора сохраняет исходный цвет и текстуру.
        vec3 autumn = vec3(1.12, 0.73, 0.38);
        vec3 damaged = vec3(0.67, 0.58, 0.37);
        ALBEDO *= mix(vec3(1.0), autumn, foliage_season);
        ALBEDO *= mix(damaged, vec3(1.0), foliage_health);
    }
    ALPHA = albedo.a * source_tint.a * COLOR.a;
    ALPHA_SCISSOR_THRESHOLD = 0.42;
    ROUGHNESS = source_roughness;
    SPECULAR = 0.18;
}
