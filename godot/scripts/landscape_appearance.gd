extends RefCounted
## Только внешний вид грунта. Законы высот, воды и климата не изменяются.

const SurfaceType = preload("res://scripts/surface.gd")

const ROCK := Color(0.39, 0.42, 0.43)
const GRAVEL := Color(0.52, 0.49, 0.43)
const SAND := Color(0.69, 0.61, 0.46)
const CLAY := Color(0.49, 0.42, 0.34)
const LOAM := Color(0.33, 0.45, 0.30)
const WETLAND := Color(0.24, 0.33, 0.27)
const SEA_FLOOR := Color(0.30, 0.37, 0.34)
const SNOW := Color(0.86, 0.90, 0.91)


static func near_water(cell: Vector2i, world: RefCounted,
		hydro: RefCounted) -> Vector3:
	var level := -INF
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
			var water_level: float = hydro.level_at(i)
			var has_water := not is_nan(water_level)
			if has_water:
				level = maxf(level, water_level)
			if hydro.ocean_at(i):
				sea = maxf(sea, weight)
			elif has_water:
				inland = maxf(inland, weight)
	return Vector3(sea, inland, level)



static func near_water_grid(bounds: Rect2i, world: RefCounted,
		hydro: RefCounted, cancel_check: Callable = Callable()) -> Array[Vector3]:
	# Один PBR-чанк содержит общие вершины соседних клеток.
	# Вместо девяти повторных обращений к Hydrology для каждой
	# вершины читаем флаги и уровень каждой соседней клетки
	# ровно один раз в локальной рамке размером (W+3)×(H+3).
	# Кеш принадлежит только одному вызову, не переживает смену
	# дня/ревизии и безопасен для параллельных CPU-воркеров.
	var sample_width: int = bounds.size.x + 3
	var sample_height: int = bounds.size.y + 3
	var type_grid := PackedByteArray()
	type_grid.resize(sample_width * sample_height)
	var water_grid := PackedFloat32Array()
	water_grid.resize(sample_width * sample_height)

	for y in range(sample_height):
		# При панорамировании устаревшая подготовка прекращает
		# сканирование гидрологии до начала вершин нового чанка.
		if cancel_check.is_valid() and cancel_check.call():
			return []
		for x in range(sample_width):
			var cell := bounds.position + Vector2i(x - 1, y - 1)
			if not world.config.contains_cell(cell):
				continue
			var index: int = hydro.cell_index(cell)
			var level: float = hydro.level_at(index)
			if is_nan(level):
				continue
			var at: int = y * sample_width + x
			# 1 — море, 2 — любая другая физическая вода.
			# Сам уровень нужен даже для стоячей воды без океана.
			type_grid[at] = 1 if hydro.ocean_at(index) else 2
			water_grid[at] = level

	var vertices_width: int = bounds.size.x + 1
	var vertices_height: int = bounds.size.y + 1
	var result: Array[Vector3] = []
	result.resize(vertices_width * vertices_height)
	for y in range(vertices_height):
		# Не возвращаем неполную сетку береговых проб в GPU.
		if cancel_check.is_valid() and cancel_check.call():
			return []
		for x in range(vertices_width):
			var level := -INF
			var sea := 0.0
			var inland := 0.0
			# Точно сохраняем прежние веса: 1 для центра,
			# 0.78 для ортогональных и 0.55 для диагональных
			# клеток, включая границы соседних GPU-чанков.
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var at: int = (y + 1 + dy) * sample_width + x + 1 + dx
					var kind: int = type_grid[at]
					if kind == 0:
						continue
					var weight := 1.0 if dx == 0 and dy == 0 else (
						0.78 if dx == 0 or dy == 0 else 0.55)
					level = maxf(level, water_grid[at])
					if kind == 1:
						sea = maxf(sea, weight)
					else:
						inland = maxf(inland, weight)
			result[y * vertices_width + x] = Vector3(sea, inland, level)
	return result


static func _cell_color(cell: Vector2i, normal: Vector3,
		height: float, _world: RefCounted, surface: RefCounted,
		hydro: RefCounted) -> Color:
	var index: int = hydro.cell_index(cell)
	var color := LOAM
	if surface.rock_at_index(index):
		color = ROCK
	elif surface.exposed_at_index(index):
		color = SAND if surface.substrate_at_index(index) == SurfaceType.SAND else GRAVEL
	elif surface.substrate_at_index(index) == SurfaceType.CLAY:
		color = CLAY

	var depth: float = surface.soil_depth_at_index(index)
	var slope := 1.0 - clampf(normal.y, 0.0, 1.0)
	var exposed := smoothstep(0.12, 0.49, slope)
	exposed = maxf(exposed, (1.0 - clampf(depth / 1.2, 0.0, 1.0)) * 0.44)
	color = color.lerp(ROCK, exposed * 0.85)
	color = color.lerp(GRAVEL, smoothstep(3.7, 8.3, height) * 0.22)

	if hydro.has_water(index):
		color = color.lerp(SEA_FLOOR, 0.65)

	var moisture: float = surface.moisture_at_index(index)
	color = color.lerp(Color(0.21, 0.26, 0.22), moisture * 0.23)
	var snow: float = surface.snow_at_index(index)
	if not hydro.has_water(index):
		color = color.lerp(SNOW, smoothstep(0.04, 0.90, snow))
	return color


static func color_at(vertex: Vector2i, height: float, normal: Vector3,
		world: RefCounted, surface: RefCounted, hydro: RefCounted,
		nearby := Vector3(-1.0, -1.0, -INF)) -> Color:
	# Четыре соседние клетки образуют один цвет общей вершины.
	# Поэтому соседние GPU-чанки не получают цветовых швов.
	var total := Color(0.0, 0.0, 0.0, 0.0)
	var count := 0
	var dry_cells := 0
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			var cell := vertex + Vector2i(dx, dy)
			if not world.config.contains_cell(cell):
				continue
			total += _cell_color(cell, normal, height, world, surface, hydro)
			count += 1
			if not hydro.has_water(hydro.cell_index(cell)):
				dry_cells += 1
	var color := total / float(maxi(count, 1))
	# Береговое влияние достаточно вычислить раз на вершину,
	# а не четыре раза на каждую соседнюю клетку.
	var shore := nearby if nearby.x >= 0.0 else near_water(vertex, world, hydro)
	var land_share := float(dry_cells) / float(maxi(count, 1))
	var gentle := 1.0 - smoothstep(0.14, 0.46,
		1.0 - clampf(normal.y, 0.0, 1.0))
	color = color.lerp(SAND, shore.x * land_share * gentle * 0.60)
	color = color.lerp(WETLAND, shore.y * land_share * 0.20)
	return color
