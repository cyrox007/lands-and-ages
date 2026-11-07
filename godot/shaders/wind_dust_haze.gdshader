shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// Мягкая низовая взвесь — видимое проявление перенесённой грунтовой
// массы NaturalDisasters, а не новый источник эрозии или погоды.
uniform float animation_phase = 0.0;
uniform float transported_mass : hint_range(0.0, 1.0) = 0.0;
uniform vec4 dust_tint : source_color = vec4(0.58, 0.51, 0.40, 1.0);

void fragment() {
    // Две шкалы неровных облачных полос движутся по ветру.
    // Рассеянный шлейф раскрывает реальный рельеф под собой,
    // а не рисует непрозрачный прямоугольник поверх карты.
    vec2 drift = vec2(animation_phase * 0.065, animation_phase * 0.016);
    vec2 uv = UV - drift;
    float broad = sin(uv.x * 15.0 + sin(uv.y * 8.0) * 1.8);
    float curls = sin(uv.y * 24.0 - uv.x * 22.0
        + animation_phase * 0.54) * 0.38;
    float small = sin(uv.x * 47.0 + uv.y * 37.0
        + animation_phase * 0.31) * 0.18;
    float cloud = smoothstep(-0.74, 0.78, broad * 0.62 + curls + small);

    // Края и концы шлейфа мягко растворяются. Центральная
    // зона сохраняет лёгкие просветы между облачными складками.
    float edge_x = smoothstep(0.01, 0.22, UV.x)
        * (1.0 - smoothstep(0.76, 0.99, UV.x));
    float edge_y = smoothstep(0.01, 0.27, UV.y)
        * (1.0 - smoothstep(0.73, 0.99, UV.y));
    float veil = edge_x * edge_y;
    float opacity = (0.05 + cloud * 0.24) * veil * transported_mass;
    ALBEDO = mix(dust_tint.rgb * 0.77,
        dust_tint.rgb * 1.12, cloud);
    ALPHA = clamp(opacity, 0.0, 0.40);
}
