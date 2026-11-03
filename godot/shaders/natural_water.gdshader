shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// UV.x задаёт глубину у берега: 0 на пересечении с сушей, 1 в глубине.
// Рябь и светлая кромка не сдвигают вершины и не влияют на гидрологию.
varying vec2 water_position;

void vertex() {
	water_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	float ripple = sin(water_position.x * 2.6 + TIME * 0.68)
		* sin(water_position.y * 3.1 - TIME * 0.51);
	float edge = 1.0 - smoothstep(0.02, 0.68, UV.x);
	float glint = ripple * 0.045;
	vec3 foam = vec3(0.28, 0.32, 0.30) * edge *
		(0.48 + 0.20 * abs(ripple));
	ALBEDO = clamp(COLOR.rgb + vec3(glint * 0.38, glint * 0.67, glint)
		+ foam, vec3(0.0), vec3(1.0));
	ROUGHNESS = mix(0.25, 0.38, edge);
	METALLIC = 0.0;
	ALPHA = COLOR.a * (1.0 - edge * 0.15);
}
