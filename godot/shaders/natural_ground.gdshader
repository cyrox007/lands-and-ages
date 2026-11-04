shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Цвет грунта и высота поступают из физической карты.
// Микрофактура скал отключается вдали без изменения самих мешей.
uniform float detail_strength : hint_range(0.0, 1.0) = 1.0;

varying vec3 ground_position;
varying float ground_steepness;

void vertex() {
	ground_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ground_steepness = 1.0 - clamp(abs(NORMAL.y), 0.0, 1.0);
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
	float cliff = smoothstep(0.12, 0.52, ground_steepness);
	float brightness = 1.0;
	if (detail_strength > 0.01) {
		// Геологическая слоистость читается по высоте и направлению склона.
		float broad = detail_noise(ground_position.xz * 0.52);
		float grain = detail_noise(ground_position.xz * 2.4);
		float strata = sin(ground_position.y * 10.0 +
			ground_position.x * 0.65 + broad * 2.2);
		float breaks = sin(ground_position.y * 4.2 -
			ground_position.z * 1.1 + broad * 3.0);
		float layers = 1.0 - cliff * (0.085 - 0.062 * strata +
			0.022 * breaks);
		brightness = mix(1.0, (0.97 + (grain - 0.5) * 0.13) * layers,
			detail_strength);
	}

	// Снег скрывает мелкие слои породы, в том числе вблизи.
	float snow = smoothstep(0.71, 0.85, min(COLOR.r, min(COLOR.g, COLOR.b)));
	brightness = mix(brightness, 1.0, snow * 0.94);
	ALBEDO = clamp(COLOR.rgb * brightness, vec3(0.0), vec3(1.0));
	ROUGHNESS = mix(0.97, 0.88, cliff);
	METALLIC = 0.0;
}
