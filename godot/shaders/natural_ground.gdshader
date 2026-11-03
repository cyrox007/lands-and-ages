shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Цвет вершин хранит реальную почву, снег и береговую влажность.
// Только мелкая фактура создаётся на GPU и не влияет на физику.
varying vec2 ground_position;

void vertex() {
	ground_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

float detail_noise(vec2 position) {
	vec2 cell = floor(position);
	vec2 weight = fract(position);
	weight = weight * weight * (3.0 - 2.0 * weight);
	float a = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
	float b = fract(sin(dot(cell + vec2(1.0, 0.0), vec2(127.1, 311.7))) * 43758.5453);
	float c = fract(sin(dot(cell + vec2(0.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
	float d = fract(sin(dot(cell + vec2(1.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
	return mix(mix(a, b, weight.x), mix(c, d, weight.x), weight.y);
}

void fragment() {
	float grain = detail_noise(ground_position * 1.3);
	ALBEDO = clamp(COLOR.rgb * (0.90 + grain * 0.18), vec3(0.0), vec3(1.0));
	ROUGHNESS = 0.97;
	METALLIC = 0.0;
}