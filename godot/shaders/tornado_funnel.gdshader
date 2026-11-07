shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// Воронка — только изображение уже рассчитанного физического смерча.
// Одному MeshInstance достаточно одного материала и двух треугольников
// на секцию: никаких частиц или событий физики на каждом обороте.
uniform float animation_phase = 0.0;
uniform float severity : hint_range(0.0, 1.0) = 1.0;
uniform vec4 dust_tint : source_color = vec4(0.41, 0.43, 0.44, 1.0);

void fragment() {
    // Местная UV.x — азимут цилиндра, UV.y — высота: шум
    // закручивается по высоте, создавая спираль, а не серую трубу.
    float height_fraction = clamp(UV.y, 0.0, 1.0);
    float spiral = UV.x * 6.28318 * 4.0 - height_fraction * 21.0
        + animation_phase * 2.7;
    float turbulent = sin(spiral) * 0.55
        + sin(spiral * 2.3 + height_fraction * 29.0) * 0.27
        + sin(UV.x * 44.0 - animation_phase * 4.2) * 0.18;
    float veil = smoothstep(-0.62, 0.47, turbulent);

    // Прозрачный верх плавно переходит в более тёмный
    // пылевой низ; чередование полос оставляет просветы сквозь
    // воронку, чтобы рельеф и деревья были видны.
    float lower_dust = 1.0 - smoothstep(0.00, 0.34, height_fraction);
    float top_fade = 1.0 - smoothstep(0.78, 1.0, height_fraction);
    float opacity = (0.055 + veil * 0.43 + lower_dust * 0.12)
        * top_fade * (0.48 + severity * 0.52);
    vec3 shade = mix(dust_tint.rgb * 0.78,
        vec3(0.70, 0.74, 0.76), height_fraction * 0.66);
    ALBEDO = shade;
    ALPHA = clamp(opacity, 0.0, 0.65);
}
