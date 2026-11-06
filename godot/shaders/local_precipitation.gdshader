shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

// Только камерное изображение: климат, количество осадков и
// положение речных/земных клеток шейдер не изменяет.
uniform vec4 particle_color : source_color;
uniform bool snow = false;
uniform int particle_kind = 0; // 0 дождь, 1 снег, 2 мокрый снег, 3 град, 4 брызги, 5 позёмка
uniform float visual_intensity = 1.0;
uniform sampler2D precipitation_map : filter_linear, repeat_disable;
uniform vec2 map_origin;
uniform float map_span = 1.0;
uniform bool use_map = false;

varying vec2 world_point;

void vertex() {
    // Наклон дождевой полосы и мелкие частицы отрисовываются
    // одной плоскостью GPU без отдельных узлов сцены на каплю.
    world_point = MODEL_MATRIX[3].xz;
    vec3 right = normalize(INV_VIEW_MATRIX[0].xyz);
    vec3 up = INV_VIEW_MATRIX[1].xyz;
    float tilt = (particle_kind == 0 || particle_kind == 3)
        ? 0.17 + 0.09 * clamp(visual_intensity, 0.0, 1.8) : 0.0;
    vec3 point = MODEL_MATRIX[3].xyz +
        right * (VERTEX.x + VERTEX.y * tilt) + up * VERTEX.y;
    POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(point, 1.0);
}

void fragment() {
    // Маска соответствует физическому месту частицы, а не
    // центру камеры: сухой фронт не получает чужие осадки.
    float strength = 1.0;
    if (use_map) {
        vec2 map_uv = (world_point - map_origin) / map_span;
        if (any(lessThan(map_uv, vec2(0.0))) ||
                any(greaterThan(map_uv, vec2(1.0)))) {
            discard;
        }
        vec4 local_weather = texture(precipitation_map, map_uv);
        float local_amount = local_weather.r;
        if (particle_kind == 1 || particle_kind == 5 || snow) {
            local_amount = local_weather.g;
        } else if (particle_kind == 2) {
            local_amount = local_weather.a;
        } else if (particle_kind == 3) {
            local_amount = local_weather.b;
        }
        strength = smoothstep(0.012, 0.30, local_amount);
        if (strength <= 0.0) {
            discard;
        }
    }

    vec2 centered = UV * 2.0 - 1.0;
    float shape = 0.0;
    if (particle_kind == 1 || snow) {
        // Снег — широкая мягкая хлопьевидная частица.
        shape = 1.0 - smoothstep(0.32, 0.98, length(centered));
    } else if (particle_kind == 2) {
        // Мокрый снег — более тяжёлая вытянутая капля-хлопья.
        shape = 1.0 - smoothstep(0.36, 1.0,
            length(centered * vec2(1.05, 0.68)));
    } else if (particle_kind == 3) {
        // Град — компактная резкая светлая гранула.
        shape = 1.0 - smoothstep(0.42, 0.84,
            abs(centered.x) + abs(centered.y));
    } else if (particle_kind == 4) {
        // Брызги — короткая полукруглая вспышка у земли.
        float arc = length(centered * vec2(0.8, 1.55));
        shape = (1.0 - smoothstep(0.63, 1.0, arc))
            * smoothstep(-0.9, -0.12, centered.y);
    } else if (particle_kind == 5) {
        // Позёмка — длинная низкая полоса с мягкими краями.
        shape = (1.0 - smoothstep(0.24, 1.0, abs(centered.y)))
            * (1.0 - smoothstep(0.55, 1.0, abs(centered.x)));
    } else {
        // Морось тоньше ливня; плотность и длина управляются
        // одним параметром визуальной интенсивности.
        float thickness = mix(0.22, 0.42,
            clamp(visual_intensity / 1.6, 0.0, 1.0));
        shape = (1.0 - smoothstep(thickness, 1.0, abs(centered.x)))
            * sin(UV.y * PI);
    }
    ALBEDO = particle_color.rgb;
    ALPHA = clamp(particle_color.a * visual_intensity * shape * strength,
        0.0, 1.0);
}
