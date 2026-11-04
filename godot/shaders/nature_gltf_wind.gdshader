shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// Модель ветра относится к отрисовке; реальный рост деревьев не зависит от FPS.
uniform sampler2D source_texture : source_color, filter_linear_mipmap;
uniform vec4 source_tint : source_color = vec4(1.0);
uniform bool has_texture = false;
uniform float source_height = 100.0;
uniform float source_base = 0.0;
uniform float source_roughness = 0.85;

void vertex() {
    float height = clamp((VERTEX.y - source_base) /
        max(source_height, 0.001), 0.0, 1.0);
    float amplitude = source_height * 0.016 *
        clamp(INSTANCE_CUSTOM.g, 0.0, 1.0) * height * height;
    float phase = INSTANCE_CUSTOM.r * 6.283185;
    VERTEX.x += sin(TIME * 1.1 + phase) * amplitude;
    VERTEX.z += cos(TIME * 0.73 + phase) * amplitude * 0.45;
}

void fragment() {
    vec4 albedo = has_texture ? texture(source_texture, UV) : vec4(1.0);
    ALBEDO = albedo.rgb * source_tint.rgb * COLOR.rgb;
    ALPHA = albedo.a * source_tint.a * COLOR.a;
    ALPHA_SCISSOR_THRESHOLD = 0.42;
    ROUGHNESS = source_roughness;
    SPECULAR = 0.18;
}
