extends RefCounted
## Общий физический снимок клеток для цвета и шести PBR-масок.
## Живёт только во время построения одного чанка, не сохраняется между днями.


static func _sample(index: int, surface: RefCounted,
		hydro: RefCounted) -> Dictionary:
	# Читаем одни и те же свойства ровно один раз на клетку.
	# Прежде Appearance и MaterialMix повторяли эти обращения
	# для каждой из четырёх вершин, а также между собой.
	# Сохраняем исходную точность float: PackedFloat32Array
	# здесь мог бы изменить цвета и маски на границах чанков.
	return {
		"rock": surface.rock_at_index(index),
		"exposed": surface.exposed_at_index(index),
		"substrate": surface.substrate_at_index(index),
		"depth": surface.soil_depth_at_index(index),
		"water": hydro.has_water(index),
		"moisture": surface.moisture_at_index(index),
		"snow": surface.snow_at_index(index),
		"waterlogging": surface.waterlogging_at_index(index),
		"frost": surface.frost_at_index(index)
	}


static func grid(bounds: Rect2i, world: RefCounted,
		surface: RefCounted, hydro: RefCounted,
		cancel_check: Callable = Callable()) -> Array[Dictionary]:
	# Вершина пользуется четырьмя соседними клетками, поэтому
	# захватываем ровно одну клетку слева и сверху от чанка.
	# Правая и нижняя границы уже включены в сетку вершин.
	var width := bounds.size.x + 2
	var height := bounds.size.y + 2
	var samples: Array[Dictionary] = []
	samples.resize(width * height)
	for y in range(height):
		# Отмена устаревшего воркера не оставляет полуснимок.
		if cancel_check.is_valid() and cancel_check.call():
			return []
		for x in range(width):
			var cell := bounds.position + Vector2i(x - 1, y - 1)
			var at := y * width + x
			if not world.config.contains_cell(cell):
				# Пустой словарь исключает клетку мира на границе;
				# он не заменяется выдуманной почвой или водой.
				samples[at] = {}
				continue
			samples[at] = _sample(hydro.cell_index(cell), surface, hydro)
	return samples


static func vertex_cells(bounds: Rect2i, vertex: Vector2i,
		samples: Array[Dictionary]) -> Array[Dictionary]:
	# Сохраняем прежний порядок накопления [-1, 0] по Y и X:
	# даже перестановка слагаемых float меняет байты PBR-маски.
	var width := bounds.size.x + 2
	var origin := vertex - bounds.position + Vector2i.ONE
	var result: Array[Dictionary] = []
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			var at := (origin.y + dy) * width + origin.x + dx
			var sample: Dictionary = samples[at]
			if not sample.is_empty():
				result.append(sample)
	return result
