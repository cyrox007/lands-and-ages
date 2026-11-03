extends RefCounted
## Геометрические показатели поверхности. Не хранит грунты, биомы и климат.

const TerrainV2 = preload("res://scripts/terrain_v2.gd")


static func profile_at(world: RefCounted, point: Vector2) -> Dictionary:
	var cfg = world.config
	if not cfg.contains_point(point):
		return {}
	var height: float = world.height_at(point)
	var step := 0.75
	var west := world.height_at(cfg.clamp_point(point - Vector2(step, 0.0)))
	var east := world.height_at(cfg.clamp_point(point + Vector2(step, 0.0)))
	var north := world.height_at(cfg.clamp_point(point - Vector2(0.0, step)))
	var south := world.height_at(cfg.clamp_point(point + Vector2(0.0, step)))
	var span_x := cfg.clamp_point(point + Vector2(step, 0.0)).x \
		- cfg.clamp_point(point - Vector2(step, 0.0)).x
	var span_y := cfg.clamp_point(point + Vector2(0.0, step)).y \
		- cfg.clamp_point(point - Vector2(0.0, step)).y
	var dx := (east - west) / maxf(span_x, 0.001)
	var dy := (south - north) / maxf(span_y, 0.001)
	var grade := Vector2(dx, dy).length()
	var bearing := Vector2(-dx, -dy).normalized()
	var low := height
	var high := height
	var mean := 0.0
	var samples := 0
	for offset in [
		Vector2(12, 0), Vector2(-12, 0), Vector2(0, 12), Vector2(0, -12),
		Vector2(9, 9), Vector2(-9, 9), Vector2(9, -9), Vector2(-9, -9)
	]:
		var neighbour := world.height_at(cfg.clamp_point(point + offset))
		low = minf(low, neighbour)
		high = maxf(high, neighbour)
		mean += neighbour
		samples += 1
	mean /= float(samples)
	var origin := "старый генератор"
	var influence := 0.0
	if cfg.generator_version == 2:
		var feature := TerrainV2.sample(point.x, point.y, cfg.seed)
		origin = str(feature["form"])
		influence = float(feature["influence"])
	return {
		"height": height,
		"grade": grade,
		"slope_degrees": rad_to_deg(atan(grade * cfg.height_scale)),
		"descent": bearing,
		"relief_24": high - low,
		"relative_height": height - mean,
		"form": origin,
		"form_influence": influence
	}


static func relief_color(elevation: float, normal: Vector3) -> Color:
	# Это только учебная цветовая шкала высот, не модель воды/грунтов.
	var low := Color(0.37, 0.39, 0.26)
	var middle := Color(0.44, 0.49, 0.32)
	var upland := Color(0.64, 0.56, 0.37)
	var summit := Color(0.62, 0.61, 0.58)
	var color := low.lerp(middle, smoothstep(-2.4, 0.8, elevation))
	color = color.lerp(upland, smoothstep(1.5, 4.4, elevation))
	color = color.lerp(summit, smoothstep(4.6, 8.0, elevation))
	var steepness := 1.0 - clampf(normal.y, 0.0, 1.0)
	var shade := 0.98 - steepness * 0.24
	return Color(color.r * shade, color.g * shade, color.b * shade)
