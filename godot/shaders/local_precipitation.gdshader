shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 particle_color : source_color;
uniform bool snow = false;
uniform sampler2D precipitation_map : filter_linear, repeat_disable;
uniform vec2 map_origin;
uniform float map_span = 1.0;
uniform bool use_map = false;

varying vec2 world_point;

void vertex() {
	world_point = MODEL_MATRIX[3].xz;
	// Billboard в мировом пространстве сохраняет высоту капли при наклоне камеры.
	vec3 right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	float tilt = snow ? 0.0 : 0.21;
	vec3 point = MODEL_MATRIX[3].xyz +
		right * (VERTEX.x + VERTEX.y * tilt) + up * VERTEX.y;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(point, 1.0);
}

void fragment() {
	float strength = 1.0;
	if (use_map) {
		vec2 map_uv = (world_point - map_origin) / map_span;
		if (any(lessThan(map_uv, vec2(0.0))) || any(greaterThan(map_uv, vec2(1.0)))) {
			discard;
		}
		vec2 local_weather = texture(precipitation_map, map_uv).rg;
		strength = smoothstep(0.018, 0.35, snow ? local_weather.g : local_weather.r);
		if (strength <= 0.0) {
			discard;
		}
	}
	vec2 centered = UV * 2.0 - 1.0;
	float shape = snow ? 1.0 - smoothstep(0.25, 1.0, length(centered)) :
		(1.0 - smoothstep(0.18, 1.0, abs(centered.x))) * sin(UV.y * PI);
	ALBEDO = particle_color.rgb;
	ALPHA = particle_color.a * shape * strength;
}
