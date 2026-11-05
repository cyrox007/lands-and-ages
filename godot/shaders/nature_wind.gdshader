shader_type spatial;
render_mode cull_back, depth_draw_opaque;

// Ветер меняет только видимую геометрию, но не игровую физику.
uniform float wind_amplitude : hint_range(0.0, 0.5) = 0.28;
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_frequency : hint_range(0.0, 3.0) = 1.2;

void vertex() {
    float height_factor = clamp(VERTEX.y / 2.5 + 0.5, 0.0, 1.0);
    float phase = INSTANCE_CUSTOM.r * 6.283185 + float(INSTANCE_ID) * 0.17;
    float gust = clamp(INSTANCE_CUSTOM.g, 0.0, 1.0);
    float wave = sin(TIME * (wind_frequency + gust * 1.4) + phase)
        + 0.28 * sin(TIME * 3.7 + phase * 1.3);
    float strength = wind_amplitude * gust * height_factor * height_factor;
    // Сильный фронт наклоняет верхушку по направлению воздуха.
    vec2 direction = normalize(wind_direction);
    VERTEX.x += direction.x * wave * strength;
    VERTEX.z += direction.y * wave * strength;
}

void fragment() {
    ALBEDO = COLOR.rgb;
    ROUGHNESS = 0.93;
    SPECULAR = 0.18;
}
