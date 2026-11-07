shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// Один лёгкий лист визуализирует реальный ветровой фронт:
// 0 — пылевая буря, 1 — шторм, 2 — шквал, 3 — ураган.
// Код не создаёт событий и не меняет физический климат.
uniform float animation_phase = 0.0;
uniform float transported_mass : hint_range(0.0, 1.0) = 0.0;
uniform int event_mode = 0;

void fragment() {
    // Направление листа задаёт Climate:UV.x — продольная ось.
    // Шторм и шквал читаются как ветровые полосы, ураган —
    // как несколько несимметричных закрученных рукавов.
    vec2 uv = UV - vec2(animation_phase * 0.032, 0.0);
    vec2 p = UV - vec2(0.5);
    float radius = length(p * vec2(1.0, 1.18));
    float angle = atan(p.y, p.x);
    float broad = sin(uv.x * 15.0 + sin(uv.y * 8.0) * 1.7);
    float folds = sin(uv.y * 23.0 - uv.x * 21.0
        + animation_phase * 0.58) * 0.38;
    float fine = sin(uv.x * 44.0 + uv.y * 35.0
        + animation_phase * 0.28) * 0.16;
    float pattern = smoothstep(-0.72, 0.72,
        broad * 0.63 + folds + fine);
    vec3 color = vec3(0.57, 0.50, 0.39);
    float alpha_scale = 0.28;

    if (event_mode == 1) {
        // Шторм: широкие серо-голубые ветровые полосы.
        color = vec3(0.68, 0.75, 0.79);
        alpha_scale = 0.31;
        pattern = smoothstep(-0.49, 0.60,
            sin(uv.x * 24.0 + uv.y * 4.0
                + animation_phase * 0.56) * 0.75 + folds);
    } else if (event_mode == 2) {
        // Шквал: быстрый, узкий и контрастный фронт.
        color = vec3(0.78, 0.84, 0.86);
        alpha_scale = 0.44;
        pattern = smoothstep(-0.54, 0.52,
            sin(uv.x * 32.0 + animation_phase * 0.95) * 0.82
                + folds * 0.55);
    } else if (event_mode == 3) {
        // Ураган: крупные вращательные облачные спирали с
        // прозрачным просветом в центре, без новых GPU-карт.
        color = vec3(0.57, 0.65, 0.72);
        alpha_scale = 0.41;
        float spiral = sin(angle * 3.0 + radius * 25.0
            - animation_phase * 1.45);
        float eyewall = smoothstep(0.06, 0.15, radius);
        pattern = smoothstep(-0.58, 0.64, spiral * 0.83
            + sin(radius * 35.0 + angle * 2.0) * 0.19) * eyewall;
    }

    // Независимо от режима край растворяется в окружающем
    // воздухе. Грунт и деревья остаются различимыми.
    float edge_x = smoothstep(0.02, 0.20, UV.x)
        * (1.0 - smoothstep(0.80, 0.99, UV.x));
    float edge_y = smoothstep(0.01, 0.23, UV.y)
        * (1.0 - smoothstep(0.77, 0.99, UV.y));
    float veil = edge_x * edge_y;
    if (event_mode == 3) {
        veil *= 1.0 - smoothstep(0.40, 0.58, radius);
    }
    float opacity = (0.055 + pattern * alpha_scale)
        * veil * transported_mass;
    ALBEDO = color * (0.78 + pattern * 0.30);
    ALPHA = clamp(opacity, 0.0, 0.46);
}
