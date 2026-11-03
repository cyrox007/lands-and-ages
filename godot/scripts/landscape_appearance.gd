extends RefCounted
## Только внешний вид грунта. Законы высот, воды и климата не изменяются.

const ROCK := Color(0.39, 0.42, 0.43)
const GRAVEL := Color(0.52, 0.49, 0.43)
const SAND := Color(0.69, 0.61, 0.46)
const CLAY := Color(0.49, 0.42, 0.34)
const LOAM := Color(0.33, 0.45, 0.30)
const WETLAND := Color(0.24, 0.33, 0.27)
const SEA_FLOOR := Color(0.30, 0.37, 0.34)
const SNOW := Color(0.86, 0.90, 0.91)


static func _near_water(cell: Vector2i, world: RefCounted,
		hydro: RefCounted) -> Vector2:
	var sea := 0.0
	var inland := 0.0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var neighbor := cell + Vector2i(dx, dy)
			if not world.config.contains_cell(neighbor):
				continue
			var i: int = hydro.cell_index(neighbor)
			var weight := 1.0 if dx == 0 and dy == 0 else (
				0.78 if dx == 0 or dy == 0 else 0.55)
			if hydro.ocean_at(i):
				sea = maxf(sea, weight)
			elif hydro.has_water(i):
				inland = maxf(inland, weight)
	return Vector2(sea, inland)


static func _cell_color(cell: Vector2i, normal: Vector3,
		height: float, world: RefCounted, surface: RefCounted,
		hydro: RefCounted) -> Color:
	var index: int = hydro.cell_index(cell)
	var color := LOAM
	if surface.rock_at_index(index):
		color = ROCK
	elif surface.exposed_at_index(index):
		color = SAND if surface._type[index] == surface.SAND else GRAVEL
	elif surface._type[index] == surface.CLAY:
		color = CLAY

	var depth: float = surface.soil_depth_at_index(index)
	var slope := 1.0 - clampf(normal.y, 0.0, 1.0)
	var exposed := smoothstep(0.12, 0.49, slope)
	exposed = maxf(exposed, (1.0 - clampf(depth / 1.2, 0.0, 1.0)) * 0.44)
	color = color.lerp(ROCK, exposed * 0.85)
	color = color.lerp(GRAVEL, smoothstep(3.7, 8.3, height) * 0.22)

	var proximity := _near_water(cell, world, hydro)
	if hydro.has_water(index):
		color = color.lerp(SEA_FLOOR, 0.65)
	else:
		var beach: float = proximity.x * (1.0 - exposed)
		color = color.lerp(SAND, beach * 0.65)
		color = color.lerp(WETLAND, proximity.y * 0.22)

	var moisture: float = surface.moisture_at_index(index)
	color = color.lerp(Color(0.21, 0.26, 0.22), moisture * 0.23)
	var snow: float = surface.snow_at_index(index)
	if not hydro.has_water(index):
		color = color.lerp(SNOW, smoothstep(0.04, 0.90, snow))
	return color


static func color_at(vertex: Vector2i, height: float, normal: Vector3,
		world: RefCounted, surface: RefCounted, hydro: RefCounted) -> Color:
	# Четыре соседние клетки образуют один цвет общей вершины.
	# Поэтому соседние GPU-чанки не получают цветовых швов.
	var total := Color(0.0, 0.0, 0.0, 0.0)
	var count := 0
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			var cell := vertex + Vector2i(dx, dy)
			if not world.config.contains_cell(cell):
				continue
			total += _cell_color(cell, normal, height, world, surface, hydro)
			count += 1
	return total / float(maxi(count, 1))
