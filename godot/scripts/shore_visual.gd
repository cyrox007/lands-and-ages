extends RefCounted
## Общая ТОЛЬКО визуальная геометрия берега для суши и воды.
## WorldMap.height_at, физические вершины и гидрология не меняются.

const SUBDIVISIONS := 3
# Морской и озёрный контур уточняем вдвое; паводковая сетка остаётся 3×3.
const COAST_SUBDIVISIONS := 6
# Только сильно искривлённая береговая седловина получает 12×12.
# Плоский берег и открытая вода не увеличивают число треугольников.
const COMPLEX_COAST_SUBDIVISIONS := 12
const COAST_CURVATURE_THRESHOLD := 0.65


static func height(ha: float, hb: float, hc: float, hd: float,
		u: float, v: float) -> float:
	# Единая билинейная визуальная поверхность грунта и воды.
	return lerpf(lerpf(ha, hb, u), lerpf(hc, hd, u), v)


static func water_context(world: RefCounted, hydro: RefCounted,
		cell: Vector2i) -> Dictionary:
	# Субклеточная визуализация нужна и с сухой стороны физической
	# границы: иначе визуальная кромка обрывается по квадрату клетки.
	# Никакой воды в физический Hydro этот метод не добавляет.
	if hydro == null or not world.config.contains_cell(cell):
		return {}
	var index: int = hydro.cell_index(cell)
	if hydro.has_water(index):
		if hydro.river_at(index) and not hydro.lake_at(index) \
				and not hydro.ocean_at(index):
			return {}
		return {
			"level": hydro.level_at(index), "index": index,
			"ocean": hydro.ocean_at(index), "lake": hydro.lake_at(index),
			"extension": false
		}
	# Визуальный берег может пересекать только четыре соседних
	# физически морских/озёрных клетки, не реку, болотце или поток.
	var selected := -1
	for offset in [Vector2i(-1, 0), Vector2i(1, 0),
			Vector2i(0, -1), Vector2i(0, 1)]:
		var neighbor: Vector2i = cell + offset
		if not world.config.contains_cell(neighbor):
			continue
		var near_index: int = hydro.cell_index(neighbor)
		if not hydro.has_water(near_index):
			continue
		if hydro.ocean_at(near_index):
			selected = near_index
			break
		if hydro.lake_at(near_index) and selected == -1:
			selected = near_index
	if selected == -1:
		return {}
	var level: float = hydro.level_at(selected)
	var ha: float = world.vertex_at(cell)
	var hb: float = world.vertex_at(cell + Vector2i(1, 0))
	var hc: float = world.vertex_at(cell + Vector2i(0, 1))
	var hd: float = world.vertex_at(cell + Vector2i(1, 1))
	# За пределами реального пересечения не рисуем виртуальную воду.
	if minf(minf(ha, hb), minf(hc, hd)) > level \
			or maxf(maxf(ha, hb), maxf(hc, hd)) <= level:
		return {}
	return {
		"level": level, "index": selected,
		"ocean": hydro.ocean_at(selected), "lake": hydro.lake_at(selected),
		"extension": true
	}



static func coast_density(ha: float, hb: float, hc: float, hd: float,
		level: float) -> int:
	# Смешанная производная билинейной поверхности определяет,
	# насколько сильно кромка воды изгибается внутри одной клетки.
	# Нормируем её на перепад высот: правило не зависит от масштаба
	# высот и одинаково применяется сушей и водным мешем.
	var lowest := minf(minf(ha, hb), minf(hc, hd))
	var highest := maxf(maxf(ha, hb), maxf(hc, hd))
	if lowest > level or highest <= level:
		return SUBDIVISIONS
	var span := maxf(highest - lowest, 0.00001)
	var curvature := absf(ha - hb - hc + hd) / span
	return COMPLEX_COAST_SUBDIVISIONS if curvature >= COAST_CURVATURE_THRESHOLD \
		else COAST_SUBDIVISIONS


static func subdivision_count(world: RefCounted, hydro: RefCounted,
		cell: Vector2i) -> int:
	# Усиливаем только действительно пересечённую берегом клетку.
	# Это согласует плотность суши и воды, не увеличивая всю
	# сетку паводков, рек или полностью затопленных площадей.
	var context: Dictionary = water_context(world, hydro, cell)
	if context.is_empty():
		return SUBDIVISIONS
	var level: float = context["level"]
	var ha: float = world.vertex_at(cell)
	var hb: float = world.vertex_at(cell + Vector2i(1, 0))
	var hc: float = world.vertex_at(cell + Vector2i(0, 1))
	var hd: float = world.vertex_at(cell + Vector2i(1, 1))
	return coast_density(ha, hb, hc, hd, level)

static func near_flood(hydro: RefCounted, cell: Vector2i) -> bool:
	# Граница разлива охватывает и прилегающие сухие клетки.
	# Не включаем всю карту в уточнение: только локальные 3×3.
	if hydro == null:
		return false
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var index: int = hydro.cell_index(cell + Vector2i(dx, dy))
			if hydro.flooded_at(index):
				return true
	return false


static func is_coastal_cell(world: RefCounted, hydro: RefCounted,
		cell: Vector2i) -> bool:
	# Пойма тоже использует визуальную сетку 3×3, иначе вода
	# пересекала бы крупные треугольники соседней сухой клетки.
	if near_flood(hydro, cell):
		return true
	var context: Dictionary = water_context(world, hydro, cell)
	if context.is_empty():
		return false
	var level: float = context["level"]
	var ha: float = world.vertex_at(cell)
	var hb: float = world.vertex_at(cell + Vector2i(1, 0))
	var hc: float = world.vertex_at(cell + Vector2i(0, 1))
	var hd: float = world.vertex_at(cell + Vector2i(1, 1))
	return minf(minf(ha, hb), minf(hc, hd)) <= level \
		and maxf(maxf(ha, hb), maxf(hc, hd)) > level
