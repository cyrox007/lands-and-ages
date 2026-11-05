extends RefCounted
## Визуальные признаки рельефа из физических высот WorldMap.
## Не создаёт отдельную геометрию и не изменяет генератор или коллизии.

const SAMPLE_RADIUS := 2
const CONTRAST_START := 0.09
const CONTRAST_FULL := 0.95
const DIRECTIONS := [
	Vector2i(-SAMPLE_RADIUS, 0), Vector2i(SAMPLE_RADIUS, 0),
	Vector2i(0, -SAMPLE_RADIUS), Vector2i(0, SAMPLE_RADIUS)
]


static func sample_at(world: RefCounted, vertex: Vector2i) -> Vector2:
	## Определяем выпуклость вершины относительно ближайших физических
	## соседей: положительная разница означает гребень, отрицательная — впадину.
	## На границе чанка читаем ту же единую карту, что и соседний чанк.
	if not world.config.contains_vertex(vertex):
		return Vector2.ZERO

	var neighbors := 0
	var total := 0.0
	for offset in DIRECTIONS:
		var nearby: Vector2i = vertex + offset
		if not world.config.contains_vertex(nearby):
			continue
		# Не extrapолируем края карты: несуществующей высоты нет.
		total += world.vertex_at(nearby)
		neighbors += 1
	if neighbors == 0:
		return Vector2.ZERO

	# Переводим разницу в высоту сцены, чтобы контраст не зависел
	# от единиц внутренней модели и её коэффициента отображения.
	var center: float = world.vertex_at(vertex)
	var difference: float = (center - total / float(neighbors)) 		* world.config.height_scale
	var ridge: float = smoothstep(CONTRAST_START, CONTRAST_FULL,
		maxf(0.0, difference))
	var ravine: float = smoothstep(CONTRAST_START, CONTRAST_FULL,
		maxf(0.0, -difference))
	return Vector2(ridge, ravine)
