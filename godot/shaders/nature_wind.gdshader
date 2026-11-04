shader_type spatial;
render_mode cull_back, depth_draw_opaque;

// Ветер меняет только видимую геометрию, но не игровую физику.
uniform float wind_amplitude : hint_range(0.0, 0.1) = 0.045;
uniform float wind_frequency : hint_range(0.0, 3.0) = 1.2;

void vertex() {
    float height_factor = clamp(VERTEX.y / 2.5 + 0.5, 0.0, 1.0);
    float phase = INSTANCE_CUSTOM.r * 6.283185 + float(INSTANCE_ID) * 0.17;
    float wave = sin(TIME * wind_frequency + phase);
    float strength = wind_amplitude * clamp(INSTANCE_CUSTOM.g, 0.0, 1.0);
    VERTEX.x += wave * strength * height_factor * height_factor;
    VERTEX.z += cos(TIME * wind_frequency * 0.77 + phase)
        * strength * 0.5 * height_factor;
}

void fragment() {
    ALBEDO = COLOR.rgb;
    ROUGHNESS = 0.93;
    SPECULAR = 0.18;
}
